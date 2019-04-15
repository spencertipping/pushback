# Pushback: flow control as control flow
# Pushback is a fully negotiated IO/control multiplexer for Perl. See
# https://github.com/spencertipping/pushback for details.

# Copyright 2019 Spencer Tipping
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

use v5.14;
use strict;
use warnings;
#line 16 "pushback/jit.md"
package pushback::jit;
our $gensym = 0;

sub new
{
  my $class = shift;
  bless { parent => undef,
          shared => {},
          refs   => {},
          code   => [],
          end    => "" }, $class;
}

sub compile
{
  my $self = shift;
  die "$$self{name}: must compile the parent JIT context"
    if defined $$self{parent};

  my @args  = sort keys %{$$self{shared}};
  my $setup = sprintf "my (%s) = \@_;", join",", map "\$$_", @args;
  my $code  = join"\n", "use strict;use warnings;",
                        "sub{", $setup, @{$$self{code}}, "}";

  my $sub = eval $code;
  die "$@ compiling $code" if $@;
  $sub->(@{$$self{shared}}{@args});
}
#line 48 "pushback/jit.md"
sub gensym { "g" . $gensym++ }
sub code
{
  my ($self, $code) = (shift, shift);
  if (ref $code && $code->isa('pushback::jit'))
  {
    %{$$self{shared}} = (%{$$self{shared}}, %{$$code{shared}});
    $$self{refs}{$_} //= $$code{refs}{$_} for keys %{$$code{refs}};
    push @{$$self{code}}, join"\n", @{$$code{code}}, $$code{end};
  }
  else
  {
    my %v;
    while (@_)
    {
      $$self{shared}{$v{$_[0]} = $$self{refs}{\$_[1]} //= gensym} = \$_[1];
      shift;
      shift;
    }
    if (keys %v)
    {
      my $vs = join"|", keys %v;
      $code =~ s/([\$@%&\*])($vs)\b/"$1\{\$$v{$2}\}"/eg;
    }
    push @{$$self{code}}, $code;
  }
  $self;
}
#line 80 "pushback/jit.md"
sub child
{
  my ($self, $end) = @_;
  bless { parent  => $self,
          closure => $$self{closure},
          shared  => $$self{shared},
          code    => [],
          end     => $end // "" }, ref $self;
}

sub end
{
  my $self = shift;
  $$self{parent}->code(join"\n", @{$$self{code}}, $$self{end});
}
#line 12 "pushback/simplex.md"
package pushback::simplex;
use Scalar::Util qw/refaddr/;

# read()/write() results (also used in JIT fragments)
use constant NOP     =>  0;
use constant PENDING => -1;
use constant EOF     => -2;
use constant RETRY   => -3;

sub new
{
  my ($class, $mode, $queue) = @_;
  bless { mode          => $mode,
          availability  => 0,
          responder_idx => {},
          responders    => [],
          responder_fns => [] }, $class;
}

sub is_monomorphic { @{shift->{responders}} == 1 }
sub responders     { @{shift->{responders}} }
#line 38 "pushback/simplex.md"
sub add;                    # ($proc) -> $invalidate_jit?
sub remove;                 # ($proc) -> $invalidate_jit?
sub invalidate_jit;         # () -> $self
sub request;                # ($flow, $proc, $offset, $n, $data) -> $n
sub available;              # ($flow, $proc) -> $self

sub jit_request;            # ($flow, $jit, $proc, $offset, $n, $data) -> $jit
sub jit_available;          # ($flow, $jit, $proc) -> $jit
#line 51 "pushback/simplex.md"
sub add
{
  my ($self, $proc) = @_;
  my $rs = $$self{responders};
  $$self{responder_idx}{refaddr $proc} = push(@$rs, $proc) - 1;
  push @{$$self{responder_fns}}, undef;

  die "can't add more than 64 processes to a flow simplex" if @$rs > 64;
  @$rs < 3;
}

sub remove
{
  my ($self, $proc) = @_;
  my $rs = $$self{responders};
  my $i  = $$self{responder_idx}{refaddr $proc}
    // die "$proc is not present, so can't be removed";

  # TODO: don't move any responders; just create a hole in the array. That will
  # cut down on the amount of JIT invalidation required.
  splice @$rs, $i, 1;
  splice @{$$self{responder_fns}}, $i, 1;

  # Reindex any responders whose positions have changed
  $$self{responder_idx}{refaddr $$rs[$_]} = $_ for $i..$#$rs;

  # Splice the availability bitvector to shift indexes
  my $keep_bits  = $$self{availability} & ~(-1 << $i);
  my $shift_bits = $$self{availability} &   -2 << $i;
  $$self{availability} = $shift_bits >> 1 | $keep_bits;

  @$rs < 2;
}

sub invalidate_jit
{
  my $self = shift;
  @{$$self{responder_fns}} = map undef, @{$$self{responders}};
  $self;
}
#line 99 "pushback/simplex.md"
sub process_fn
{
  my ($self, $flow, $i) = @_;
  $$self{responder_fns}[$i] //= $self->jit_fn_for($flow, $i);
}

sub jit_fn_for
{
  my ($self, $flow, $i) = @_;
  my $proc   = $$self{responders}[$i];
  my $method = "jit_$$self{mode}";
  my $jit    = pushback::jit->new
    ->code("#line 1 \"$flow/$proc JIT source\"")
    ->code('sub { ($offset, $n, $data) = @_;',
           offset => my $offset,
           n      => my $n,
           data   => my $data);
  $proc->$method($jit->child('}'), $flow, $offset, $n, $data)->end->compile;
}

sub request
{
  my $self = shift;
  my $a    = \$$self{availability};

  # Requests are served from available responders. If we have none, turn this
  # request into a responder on the opposing simplex by returning PENDING.
  return PENDING unless $$a;

  my $flow   = shift;
  my $proc   = shift;
  my $offset = shift;
  my $len    = shift;

  my $total  = 0;
  my $n      = 0;
  my $fn     = undef;
  my $rs     = $$self{responders};
  my $r      = undef;
  my $i      = 0;
  my $mask   = 0;

  while ($len && $i < @$rs && $$a >> $i)
  {
    # Seek to the next available responder and use it as long as it continues to
    # indicate availability.
    $i++ until $$a >> $i & 1;
    $mask = 1 << $i;
    $fn   = $$self{responder_fns}[$i] //= $self->jit_fn_for($flow, $i);
    $r    = $$self{responders}[$i];

    while ($$a & $mask && $len)
    {
      # Clear availability when we commit to a request. The responder can set
      # the flag while it's running to indicate that further requests are
      # possible.
      $$a &= ~$mask;
      $n   = &$fn($offset, $len, $_[0]);

      die "$r can't reply to flow point $flow with PENDING" if $n == PENDING;
      die "$r over-replied to $flow/$proc: requested $len but got $n"
        if $n > $len;
      return $n if $n == RETRY
                || $n == EOF && $flow->remove_writer($r)->handle_eof($r);

      $total  += $n;
      $offset += $n;
      $len    -= $n;
    }
  }

  $total;
}

sub available
{
  my ($self, $flow, $proc) = @_;
  my $i = $$self{responder_idx}{refaddr $proc}
    // die "$flow can't indicate availability of unmanaged proc $proc";
  $$self{availability} |= 1 << $i;
  $self;
}
#line 186 "pushback/simplex.md"
sub jit_request
{
  my $self   = shift;
  my $flow   = shift;
  my $jit    = shift;
  my $proc   = shift;
  my $offset = \shift;
  my $n      = \shift;
  my $data   = \shift;

  if ($self->is_monomorphic)
  {
    my $method = "jit_$$self{mode}";
    ${$$self{responders}}[0]->$method($jit, $flow, $$offset, $$n, $$data);
  }
  else
  {
    $jit->code('$n = &$f($flow, $proc, $offset, $n, $data);',
      f      => $flow->can($$self{mode}),
      flow   => $flow,
      proc   => $proc,
      offset => $$offset,
      n      => $$n,
      data   => $$data);
  }
}

sub jit_available
{
  my ($self, $flow, $jit, $proc) = @_;
  $jit->code('$availability |= '
           . (1 << $$self{responder_idx}{refaddr $proc}) . ';',
           availability => $$self{availability});
}
#line 15 "pushback/flow.md"
package pushback::flow;
use overload qw/ "" name /;

use constant FLAG_CLOSED        => 0x01;
use constant FLAG_REMAIN_OPEN   => 0x02;
#use constant FLAG_NO_SPECIALIZE => 0x04;   TODO

our $flowpoint_id = 0;
sub new
{
  my ($class, $name) = @_;
  bless { name          => $name // "_" . $flowpoint_id++,
          read_simplex  => pushback::simplex->new('read'),
          write_simplex => pushback::simplex->new('write'),
          flags         => 0 }, $class;
}

sub read_monomorphic  { shift->{read_simplex}->is_monomorphic }
sub write_monomorphic { shift->{write_simplex}->is_monomorphic }
sub name              { shift->{name} }

sub remain_open
{
  my $self = shift;
  $$self{flags} |= FLAG_REMAIN_OPEN;
  $self;
}
#line 47 "pushback/flow.md"
sub add_reader;             # ($proc) -> $self
sub add_writer;             # ($proc) -> $self
sub remove_reader;          # ($proc) -> $self
sub remove_writer;          # ($proc) -> $self
sub invalidate_jit_readers; # ($transitively?) -> $self
sub invalidate_jit_writers; # ($transitively?) -> $self

# Non-JIT entry points
sub handle_eof;             # ($proc) -> $early_exit?
sub read;                   # ($proc, $offset, $n, $data) -> $n
sub write;                  # ($proc, $offset, $n, $data) -> $n
sub close;                  # ($error?) -> $self
sub readable;               # ($proc) -> $self
sub writable;               # ($proc) -> $self
#line 68 "pushback/flow.md"
sub jit_read;               # ($jit, $proc, $offset, $n, $data) -> $jit
sub jit_write;              # ($jit, $proc, $offset, $n, $data) -> $jit
sub jit_readable;           # ($jit, $proc) -> $jit
sub jit_writable;           # ($jit, $proc) -> $jit
#line 77 "pushback/flow.md"
sub add_reader
{
  my ($self, $proc) = @_;
  $self->invalidate_jit_writers if $$self{read_simplex}->add($proc);
  $self;
}

sub add_writer
{
  my ($self, $proc) = @_;
  $self->invalidate_jit_readers if $$self{write_simplex}->add($proc);
  $self;
}

sub remove_reader
{
  my ($self, $proc) = @_;
  $self->invalidate_jit_writers if $$self{read_simplex}->remove($proc);
  $self;
}

sub remove_writer
{
  my ($self, $proc) = @_;
  $self->invalidate_jit_readers if $$self{write_simplex}->remove($proc);
  $self->handle_eof($proc) unless $$self{write_simplex}->responders;
  $self;
}

sub invalidate_jit_readers
{
  my ($self, $transitively) = @_;
  $_->invalidate_jit_reader($self, $transitively)
    for $$self{read_simplex}->responders;
  $$self{read_simplex}->invalidate_jit;
  $self;
}

sub invalidate_jit_writers
{
  my ($self, $transitively) = @_;
  $_->invalidate_jit_writer($self, $transitively)
    for $$self{write_simplex}->responders;
  $$self{write_simplex}->invalidate_jit;
  $self;
}
#line 134 "pushback/flow.md"
sub handle_eof
{
  my ($self, $proc) = @_;
  return 0 if $$self{flags} & FLAG_REMAIN_OPEN
           || $$self{write_simplex}->responders;
  $self->close;
  1;
}

sub close
{
  my ($self, $error) = @_;
  $_->eof($self, $error) for $$self{read_simplex}->responders;
  $self->invalidate_jit_writers;
  delete $$self{read_queue};
  delete $$self{write_queue};
  delete $$self{read_simplex};
  delete $$self{write_simplex};
  $$self{flags} = FLAG_CLOSED;
  $self;
}
#line 163 "pushback/flow.md"
sub read
{
  my $self = shift;
  my $proc = shift;

  die "usage: read(\$proc, \$offset, \$n, \$data)" if @_ < 3;
  die "$proc cannot read from closed flow $self" if $$self{flags} & FLAG_CLOSED;

  my $n = $$self{write_simplex}->request($self, $proc, @_);
  $$self{read_simplex}->available($self, $proc)
    if defined $proc and $n == pushback::simplex::PENDING;
  $n;
}

sub write
{
  my $self = shift;
  my $proc = shift;

  die "usage: write(\$proc, \$offset, \$n, \$data)" if @_ < 3;
  die "$proc cannot write to closed flow $self" if $$self{flags} & FLAG_CLOSED;

  my $n = $$self{read_simplex}->request($self, $proc, @_);
  $$self{write_simplex}->available($self, $proc)
    if defined $proc and $n == pushback::simplex::PENDING;
  $n;
}

sub readable
{
  my ($self, $proc) = @_;
  $$self{read_simplex}->available($self, $proc);
  $self;
}

sub writable
{
  my ($self, $proc) = @_;
  $$self{write_simplex}->available($self, $proc);
  $self;
}
#line 209 "pushback/flow.md"
sub jit_read
{
  my $self = shift;
  $$self{read_simplex}->jit_request($self, @_);
}

sub jit_write
{
  my $self = shift;
  $$self{write_simplex}->jit_request($self, @_);
}

sub jit_readable
{
  my ($self, $jit, $proc) = @_;
  $$self{read_simplex}->jit_available($self, $jit, $proc);
}

sub jit_writable
{
  my ($self, $jit, $proc) = @_;
  $$self{write_simplex}->jit_available($self, $jit, $proc);
}
#line 6 "pushback/process.md"
package pushback::process;
use overload qw/ "" name /;
#line 13 "pushback/process.md"
sub name;                   # ($self) -> $name

sub jit_read;               # ($jit, $flow, $offset, $n, $data) -> $jit
sub jit_write;              # ($jit, $flow, $offset, $n, $data) -> $jit
sub jit_readable;           # ($jit, $flow) -> $jit
sub jit_writable;           # ($jit, $flow) -> $jit
sub invalidate_jit_reader;  # ($flow) -> $self
sub invalidate_jit_writer;  # ($flow) -> $self

sub eof;                    # ($flow, $error | undef) -> $self
#line 21 "pushback/copy.md"
package pushback::copy;
push our @ISA, qw/pushback::process/;

sub new
{
  my ($class, $from, $to) = @_;
  my $self = bless { from => $from,
                     to   => $to }, $class;
  $from->add_reader($self);
  $to->add_writer($self);
  $self;
}

sub name
{
  my $self = shift;
  "copy($$self{from} -> $$self{to})";
}

sub jit_read
{
  my $self = shift;
  my $jit  = shift;
  shift;
  $$self{from}->jit_read_fragment($jit, $self, @_);
}

sub jit_write
{
  my $self = shift;
  my $jit  = shift;
  shift;
  $$self{to}->jit_write_fragment($jit, $self, @_);
}

sub eof
{
  my ($self, $flow, $error) = @_;
  $$self{from}->remove_reader($self);
  $$self{to}->remove_writer($self);
  delete $$self{from};
  delete $$self{to};
  $self;
}

sub invalidate_jit_reader
{
  my $self = shift;
  $$self{from}->invalidate_jit_readers;
  $self;
}

sub invalidate_jit_writer
{
  my $self = shift;
  $$self{to}->invalidate_jit_writers;
  $self;
}
#line 19 "pushback/seq.md"
package pushback::seq;
push our @ISA, qw/pushback::process/;

sub new
{
  my ($class, $into, $from, $inc) = @_;
  my $self = bless { into => $into,
                     from => $from // 0,
                     inc  => $inc  // 1 }, $class;
  $into->add_writer($self);
  $into->writable($self);
  $self;
}

sub name
{
  my $self = shift;
  "seq($$self{from} x $$self{inc} -> $$self{into})";
}

sub invalidate_jit_writer { shift }

sub jit_write
{
  my $self   = shift;
  my $jit    = shift;
  my $flow   = shift;
  my $offset = \shift;
  my $n      = \shift;
  my $data   = \shift;

  $flow->jit_writable($jit, $self)
       ->code(
    q{
      if ($inc == 1)
      {
        @$data[$offset..$offset+$n-1] = $start..$start+$n-1;
        $start += $n;
      }
      else
      {
        $$data[$offset + $i++] = $start += $inc while $i < $n;
      }
      $n;
    },
    i      => my $i = 0,
    start  => $$self{from},
    inc    => $$self{inc},
    into   => $$self{into},
    self   => $self,
    offset => $$offset,
    n      => $$n,
    data   => $$data);
}
#line 17 "pushback/each.md"
package pushback::each;
push our @ISA, qw/pushback::process/;

sub new
{
  my ($class, $from, $fn) = @_;
  my $self = bless { from => $from,
                     fn   => $fn }, $class;
  $from->add_reader($self);
  $from->readable($self);
  $self;
}

sub name
{
  my $self = shift;
  "each($$self{from} -> sub { ... })";
}

sub invalidate_jit_reader { shift }

sub jit_read
{
  my $self   = shift;
  my $jit    = shift;
  my $flow   = shift;
  my $offset = \shift;
  my $n      = \shift;
  my $data   = \shift;

  $flow->jit_readable($jit, $self)
       ->code(
    q{
      &$fn(@$data[$offset .. $offset + $n - 1]);
      $n;
    },
    from   => $$self{from},
    self   => $self,
    fn     => $$self{fn},
    offset => $$offset,
    n      => $$n,
    data   => $$data);
}
1;
__END__
