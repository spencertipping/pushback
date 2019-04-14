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
      $code =~ s/([\$@%&\*])($vs)/"$1\{\$$v{$2}\}"/eg;
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
          code    => [],
          end     => $end // "" }, ref $self;
}

sub end
{
  my $self = shift;
  $$self{parent}->code(join"\n", @{$$self{code}}, $$self{end});
}
#line 9 "pushback/flow.md"
package pushback::flow;
use Scalar::Util qw/refaddr/;

# read()/write() results (also used in JIT fragments)
use constant PENDING => 0;
use constant EOF     => -1;
use constant RETRY   => -2;

our $flowpoint_id = 0;
sub new
{
  my ($class, $name) = @_;
  bless { name      => $name // "_" . $flowpoint_id++,
          readers   => {},
          writers   => {},
          read_fns  => {},
          write_fns => {},
          queue     => [],
          closed    => 0,
          pressure  => 0 }, $class;
}
#line 35 "pushback/flow.md"
sub add_reader;             # ($proc) -> $self
sub add_writer;             # ($proc) -> $self
sub remove_reader;          # ($proc) -> $self
sub remove_writer;          # ($proc) -> $self
sub invalidate_jit_readers; # () -> $self
sub invalidate_jit_writers; # () -> $self

# Non-JIT entry points
sub handle_eof;             # ($proc) -> $early_exit?
sub process_read_fn;        # ($proc) -> $fn
sub process_write_fn;       # ($proc) -> $fn
sub read;                   # ($proc, $offset, $n, $data) -> $n
sub write;                  # ($proc, $offset, $n, $data) -> $n
sub close;                  # ($error?) -> $self

# JIT inliners for monomorphic reads/writes
sub jit_read_fragment;      # ($jit, $proc, $offset, $n, $data) -> $jit
sub jit_write_fragment;     # ($jit, $proc, $offset, $n, $data) -> $jit
#line 58 "pushback/flow.md"
sub add_reader
{
  my ($self, $proc) = @_;
  $$self{readers}{$proc->name} = $proc;
  $self->invalidate_jit_writers if keys %{$$self{readers}} < 3;
  $self;
}

sub add_writer
{
  my ($self, $proc) = @_;
  $$self{writers}{$proc->name} = $proc;
  $self->invalidate_jit_readers if keys %{$$self{writers}} < 3;
  $self;
}

sub remove_reader
{
  my ($self, $proc) = @_;
  delete $$self{readers}{$proc->name};
  $self->invalidate_jit_writers if keys %{$$self{readers}} < 2;
  $self;
}

sub remove_writer
{
  my ($self, $proc) = @_;
  delete $$self{writers}{$proc->name};
  $self->invalidate_jit_readers if keys %{$$self{writers}} < 2;
  $self;
}

sub invalidate_jit_readers
{
  my $self = shift;
  $_->invalidate_jit_reader($self) for values %{$$self{readers}};
  %{$$self{read_fns}} = ();
  $self;
}

sub invalidate_jit_writers
{
  my $self = shift;
  $_->invalidate_jit_writer($self) for values %{$$self{writers}};
  %{$$self{write_fns}} = ();
  $self;
}

sub close
{
  my ($self, $error) = @_;
  $_->eof($self, $error) for values %{$$self{readers}};
  delete @{$$self}{qw/ readers writers read_fns write_fns /};
  $$self{closed} = 1;
  $self->invalidate_jit_writers;
}
#line 121 "pushback/flow.md"
sub process_read_fn
{
  my ($self, $proc) = @_;
  $$self{read_fns}{refaddr $proc} //= $self->jit_read_fn_for_($proc);
}

sub jit_read_fn_for_
{
  my ($self, $proc) = @_;
  my ($offset, $n, $data);
  my $jit = pushback::jit->new
    ->code("#line 1 \"$self/$proc JIT reader\"")
    ->code('sub { ($offset, $n, $data) = @_;',
           offset => $offset,
           n      => $n,
           data   => $data);
  $proc->jit_read($jit->child('}'), $self, $offset, $n, $data);
  $jit->end->compile;
}

sub process_write_fn
{
  my ($self, $proc) = @_;
  $$self{write_fns}{refaddr $proc} //= $self->jit_write_fn_for_($proc);
}

sub jit_write_fn_for_
{
  my ($self, $proc) = @_;
  my ($offset, $n, $data);
  my $jit = pushback::jit->new
    ->code("#line 1 \"$self/$proc JIT writer\"")
    ->code('sub { ($offset, $n, $data) = @_;',
           offset => $offset,
           n      => $n,
           data   => $data);
  $proc->jit_write($jit->child('}'), $self, $offset, $n, $data);
  $jit->end->compile;
}

sub read
{
  my $self = shift;
  my $proc = shift;
  die "$proc cannot read from closed flow $self" if $$self{closed};
  if ($$self{pressure} <= 0)
  {
    $$self{pressure} -= $_[0];
    push @{$$self{queue}}, $proc;
    return PENDING;
  }

  # The queue contains writers. Go through their write functions and pull data
  # until the read is complete or we run out of queue entries; at that point
  # we'll return a partial success.
  my $offset = shift;
  my $n      = shift;
  my ($total, $r, $writer) = (0, undef, undef);
  while ($n && defined($writer = shift @{$$self{queue}}))
  {
  retry:
    $r = $self->process_write_fn($writer)->($offset, $n, $_[0]);
    die "$writer overwrote data into $self/$proc: requested $n but got $r"
      if $r > $n;
    goto retry if $r == RETRY;
    return EOF if $r == EOF && $self->handle_eof($writer);
    $total += $r;
    $offset += $r;
    $n -= $r;
  }
  $$self{pressure} -= $total;
  $total;
}

sub write
{
  my $self = shift;
  my $proc = shift;
  die "$proc cannot write to closed flow $self" if $$self{closed};
  if ($$self{pressure} >= 0)
  {
    $$self{pressure} += $_[0];
    push @{$$self{queue}}, $proc;
    return PENDING;
  }

  my $offset = shift;
  my $n      = shift;
  my ($total, $w, $reader) = (0, undef, undef);
  while ($n && defined($reader = shift @{$$self{queue}}))
  {
  retry:
    $w = $self->process_read_fn($reader)->($offset, $n, $_[0]);
    die "$reader overread data from $self/$proc: requested $n but got $w"
      if $w > $n;
    goto retry if $w == RETRY;
    return EOF if $w == EOF && $self->process_eof($reader);
    $total += $w;
    $offset += $w;
    $n -= $w;
  }
  $$self{pressure} += $total;
  $total;
}
#line 230 "pushback/flow.md"
sub jit_read_fragment
{
  my $self   = shift;
  my $jit    = shift;
  my $proc   = shift;
  my $offset = \shift;
  my $n      = \shift;
  my $data   = \shift;

  if (keys %{$$self{readers}} == 1)
  {
    my ($r) = values %{$$self{readers}};
    $r->jit_read($jit, $self, $$offset, $$n, $$data);
  }
  else
  {
    $jit->code('$n = &$f($flow, $proc, $offset, $n, $data);',
      f      => $self->can('read'),
      flow   => $self,
      proc   => $proc,
      offset => $$offset,
      n      => $$n,
      data   => $$data);
  }
}

sub jit_write_fragment
{
  my $self   = shift;
  my $jit    = shift;
  my $proc   = shift;
  my $offset = \shift;
  my $n      = \shift;
  my $data   = \shift;

  if (keys %{$$self{writers}} == 1)
  {
    my ($r) = values %{$$self{writers}};
    $r->jit_write($jit, $self, $$offset, $$n, $$data);
  }
  else
  {
    $jit->code('$n = &$f($flow, $proc, $offset, $n, $data);',
      f      => $self->can('write'),
      flow   => $self,
      proc   => $proc,
      offset => $$offset,
      n      => $$n,
      data   => $$data);
  }
}
#line 6 "pushback/process.md"
package pushback::process;
#line 12 "pushback/process.md"
sub jit_read;               # ($jit, $flow, $offset, $n, $data) -> $jit
sub jit_write;              # ($jit, $flow, $offset, $n, $data) -> $jit
sub eof;                    # ($flow, $error | undef) -> $self
sub invalidate_jit_reader;  # ($flow) -> $self
sub invalidate_jit_writer;  # ($flow) -> $self
1;
__END__
