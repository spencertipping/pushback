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
#line 3 "pushback/simplex.md"
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
  bless { mode       => $mode,
          queue      => $queue,
          sources    => {},
          source_fns => {} }, $class;
}

sub is_monomorphic { keys   %{shift->{sources}} == 1 }
sub sources        { values %{shift->{sources}} }
#line 28 "pushback/simplex.md"
sub add;                    # ($proc) -> $self
sub remove;                 # ($proc) -> $self
sub invalidate_jit;         # () -> $self
sub request;                # ($flow, $proc, $offset, $n, $data) -> $n
sub jit_fragment;           # ($flow, $jit, $proc, $offset, $n, $data) -> $n
#line 38 "pushback/simplex.md"
sub add
{
  my ($self, $proc) = @_;
  $$self{sources}{refaddr $proc} = $proc;
  keys %{$$self{sources}} < 3;
}

sub remove
{
  my ($self, $proc) = @_;
  delete $$self{sources}{refaddr $proc};
  keys %{$$self{sources}} < 2;
}

sub invalidate_jit
{
  my $self = shift;
  %{$$self{source_fns}} = ();
  $self;
}
#line 65 "pushback/simplex.md"
sub process_fn
{
  my ($self, $flow, $proc) = @_;
  $$self{source_fns}{refaddr $proc} //= $self->jit_fn_for($flow, $proc);
}

sub jit_fn_for
{
  my ($self, $flow, $proc) = @_;
  my ($offset, $n, $data);
  my $method = "jit_$$self{mode}";
  my $jit = pushback::jit->new
    ->code("#line 1 \"$flow/$proc JIT source\"")
    ->code('sub { ($offset, $n, $data) = @_;',
           offset => $offset,
           n      => $n,
           data   => $data);
  $proc->$method($jit->child('}'), $flow, $offset, $n, $data)->end->compile;
}

sub request
{
  my $self = shift;
  my $flow = shift;
  my $proc = shift;

  # Requests are served from the offer queue. If we have none, turn this request
  # into an offer on the opposing queue by returning PENDING.
  my $q;
  return PENDING unless @{$q = $$self{queue}};

  my $offset = shift;
  my $len    = shift;
  my ($total, $n, $responder) = (0, undef, undef);
  while ($len && defined($responder = shift @$q))
  {
    $n = $self->process_fn($flow, $responder)->($offset, $len, $_[0]);
    die "$responder over-replied to $flow/$proc: requested $len but got $n"
      if $n > $len;
    if ($n < 0)
    {
      die "process $responder cannot respond to flow point $flow with PENDING"
        if $n == PENDING;
      return $n if $n == RETRY
                || $n == EOF
                   && $flow->remove_writer($responder)->handle_eof($responder);
    }
    $total  += $n;
    $offset += $n;
    $len    -= $n;
  }
  $total;
}
#line 123 "pushback/simplex.md"
sub jit_fragment
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
    my ($s) = values %{$$self{sources}};
    my $method = "jit_$$self{mode}";
    $s->$method($jit, $flow, $$offset, $$n, $$data);
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
#line 12 "pushback/flow.md"
package pushback::flow;

our $flowpoint_id = 0;
sub new
{
  my ($class, $name) = @_;
  my @read_queue;
  my @write_queue;
  bless { name          => $name // "_" . $flowpoint_id++,
          read_queue    => \@read_queue,
          write_queue   => \@write_queue,
          read_simplex  => pushback::simplex->new(read  => \@read_queue),
          write_simplex => pushback::simplex->new(write => \@write_queue),
          remain_open   => 0,
          closed        => 0 }, $class;
}

sub remain_open
{
  my ($self, $remain_open) = @_;
  $$self{remain_open} = $remain_open // 1;
  $self;
}
#line 40 "pushback/flow.md"
sub add_reader;             # ($proc) -> $self
sub add_writer;             # ($proc) -> $self
sub remove_reader;          # ($proc) -> $self
sub remove_writer;          # ($proc) -> $self
sub invalidate_jit_readers; # () -> $self
sub invalidate_jit_writers; # () -> $self

# Non-JIT entry points
sub handle_eof;             # ($proc) -> $early_exit?
sub read;                   # ($proc, $offset, $n, $data) -> $n
sub write;                  # ($proc, $offset, $n, $data) -> $n
sub close;                  # ($error?) -> $self
sub readable;               # ($proc) -> $self
sub writable;               # ($proc) -> $self

# JIT inliners for monomorphic reads/writes
sub jit_read_fragment;      # ($jit, $proc, $offset, $n, $data) -> $jit
sub jit_write_fragment;     # ($jit, $proc, $offset, $n, $data) -> $jit
#line 63 "pushback/flow.md"
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
  $$self{read_queue}
    = [grep refaddr($_) != refaddr($proc), @{$$self{read_queue}}];
  $self;
}

sub remove_writer
{
  my ($self, $proc) = @_;
  $self->invalidate_jit_readers if $$self{write_simplex}->remove($proc);
  $$self{write_queue}
    = [grep refaddr($_) != refaddr($proc), @{$$self{write_queue}}];

  $self->handle_eof($proc) unless $$self{write_simplex}->sources;
  $self;
}

sub invalidate_jit_readers
{
  my $self = shift;
  $_->invalidate_jit_reader($self) for $$self{read_simplex}->sources;
  $$self{read_simplex}->invalidate_jit;
  $self;
}

sub invalidate_jit_writers
{
  my $self = shift;
  $_->invalidate_jit_writer($self) for $$self{write_simplex}->sources;
  $$self{write_simplex}->invalidate_jit;
  $self;
}
#line 123 "pushback/flow.md"
sub handle_eof
{
  my ($self, $proc) = @_;
  return 0 if $$self{remain_open} || $$self{write_simplex}->sources;
  $self->close;
  1;
}

sub close
{
  my ($self, $error) = @_;
  $_->eof($self, $error) for $$self{read_simplex}->sources;
  $self->invalidate_jit_writers;
  delete $$self{read_simplex};
  delete $$self{write_simplex};
  $$self{closed} = 1;
}
#line 147 "pushback/flow.md"
sub read
{
  my $self = shift;
  my $proc = shift;
  die "usage: read(\$proc, \$offset, \$n, \$data)" unless ref $proc;
  die "$proc cannot read from closed flow $self" if $$self{closed};
  my $n = $$self{write_simplex}->request($self, $proc, @_);
  push @{$$self{read_queue}}, $proc if $n == pushback::simplex::PENDING;
  $n;
}

sub write
{
  my $self = shift;
  my $proc = shift;
  die "usage: write(\$proc, \$offset, \$n, \$data)" unless ref $proc;
  die "$proc cannot write to closed flow $self" if $$self{closed};
  my $n = $$self{read_simplex}->request($self, $proc, @_);
  push @{$$self{write_queue}}, $proc if $n == pushback::simplex::PENDING;
  $n;
}

sub readable
{
  my ($self, $proc) = @_;
  push @{$$self{read_queue}}, $proc;
  $self;
}

sub writable
{
  my ($self, $proc) = @_;
  push @{$$self{write_queue}}, $proc;
  $self;
}
#line 187 "pushback/flow.md"
sub jit_read_fragment
{
  my $self = shift;
  $$self{read_simplex}->jit_fragment($self, @_);
}

sub jit_write_fragment
{
  my $self = shift;
  $$self{write_simplex}->jit_fragment($self, @_);
}
#line 6 "pushback/process.md"
package pushback::process;
#line 12 "pushback/process.md"
sub jit_read;               # ($jit, $flow, $offset, $n, $data) -> $jit
sub jit_write;              # ($jit, $flow, $offset, $n, $data) -> $jit
sub eof;                    # ($flow, $error | undef) -> $self
sub invalidate_jit_reader;  # ($flow) -> $self
sub invalidate_jit_writer;  # ($flow) -> $self
#line 3 "pushback/copy.md"
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

sub invalidate_jit_writer { shift }

sub jit_write
{
  my $self   = shift;
  my $jit    = shift;
  my $flow   = shift;
  my $offset = \shift;
  my $n      = \shift;
  my $data   = \shift;

  $jit->code(
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
      $into->writable($self);
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

sub invalidate_jit_reader { shift }

sub jit_read
{
  my $self   = shift;
  my $jit    = shift;
  my $flow   = shift;
  my $offset = \shift;
  my $n      = \shift;
  my $data   = \shift;

  $jit->code(
    q{
      &$fn(@$data[$offset .. $offset + $n - 1]);
      $from->readable($self);
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
