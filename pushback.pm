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
#line 11 "pushback/point.md"
package pushback::point;
use overload qw/ "" id /;
use Scalar::Util qw/refaddr/;

our $point_id = 0;
sub new
{
  my ($class, $id) = @_;
  bless { id        => $id // ++$point_id,
          spanners  => [],
          jit_flags => [] }, $class;
}

sub id             { shift->{id} }
sub is_static      { @{shift->{spanners}} == 1 }
sub is_monomorphic { @{shift->{spanners}} == 2 }

sub connect
{
  my ($self, $s) = @_;
  die "$s is already connected to $self"
    if grep refaddr($s) == refaddr($_), @{$$self{spanners}};

  $self->invalidate_jit;
  push @{$$self{spanners}}, $s;
  $self;
}

sub disconnect
{
  my ($self, $s) = @_;
  my $ss = $$self{spanners};
  my ($i) = grep refaddr($$ss[$_]) == refaddr($s), 0..$#$ss
    or die "$s isn't connected to $self";

  $self->invalidate_jit;
  splice @{$$self{spanners}}, $i, 1;
  $self;
}
#line 55 "pushback/point.md"
sub invalidate_jit
{
  my $self = shift;
  $$_ = 1 for @{$$self{jit_flags}};
  @{$$self{jit_flags}} = ();
  $self;
}

sub jit_flow                # ($spanner, $jit, $flag, $n, $data) -> $jit
{
  my $self = shift;
  my $s    = shift;
  my $jit  = shift;
  my $flag = \shift;
  my $n    = \shift;
  my $data = \shift;

  my $jit_flags = $$self{jit_flags};
  push @$jit_flags, $flag;

  if ($self->is_static)
  {
    # No flow is possible against a point with only one connection; flow points
    # themselves don't have any capacity.
    $jit->code(q{ $n = 0; }, n => $$n);
  }
  elsif ($self->is_monomorphic)
  {
    # Passthrough to the only other spanner. No need to update flow pressure
    # since nobody will use it.
    my ($other) = grep refaddr($_) != refaddr($s), @{$$self{spanners}};
    $other->jit_flow($self, $jit, $$flag, $$n, $$data);
  }
  else
  {
    # Round-robin through the other spanners. Any of them might return 0 from a
    # flow request, so we automatically proceed to the next one until we've
    # gotten zeroes from everyone.
    #
    # Technically it's wasteful to recompile all flow paths when this flow point
    # changes, but it keeps the logic simple and correctly handles monomorphic
    # inlining.
    my $f   = 0;
    my @fns = map $_->jit_flow($self, pushback::jit->new->code('sub {'),
                               $$flag, $f, $$data)
                    ->code('}')->compile,
              grep refaddr($_) != refaddr($s), @{$$self{spanners}};
    $jit->code(
      q{
        $v = 0;
        until ($f || $v++ >= $#$fns)
        {
          $f = $n;
          $$fns[$i %= @$fns]->();
          ++$i;
        }
        $n = $f;
      },
      n   => $$n,
      f   => $f,
      i   => my $i = 0,
      v   => my $v = 0,
      fns => \@fns);
  }
}
#line 6 "pushback/spanner.md"
package pushback::spanner;
sub connected_to
{
  my $class = shift;
  my $self  = bless { points   => {@_},
                      flow_fns => {} }, $class;
  $_->connect($self) for values %{$$self{points}};
  $self;
}

sub name  { "anonymous spanner (override sub name)" }
sub point { $_[0]->{points}->{$_[1]} }
sub flow_fn
{
  my ($self, $point) = @_;
  $$self{flow_fns}{$point} // $self->jit_flow_fn($point);
}

sub jit_flow_fn
{
  my ($self, $point) = @_;
  my $invalidation_flag = 0;

  # Major voodoo here: we're producing a JIT function (fair enough), but that
  # function needs to recompile itself and invoke the new one if it becomes
  # invalidated.
  my $jit = pushback::jit->new
    ->code('#line 1 "' . $self->name . '"')
    ->code('sub {')
    ->code('return &$fn($self, $point)->(@_) if $invalidated;',
      fn          => $self->can('jit_flow_fn'),
      self        => $self,
      point       => $point,
      invalidated => $invalidation_flag)
    ->code('($n, $data) = @_;', n => my $n, data => my $data);

  $$self{flow_fns}{$point} =
    $self->point($point)
      ->jit_flow($self, $jit, $invalidation_flag, $n, $data)
      ->code('$_[1] = $data; $_[0] = $n }', n => $n, data => $data)
      ->compile;
}
#line 24 "pushback/seq.md"
package pushback::seq;
push our @ISA, 'pushback::spanner';
sub new
{
  my ($class, $into) = @_;
  my $self = $class->connected_to(into => $into);
  $$self{i} = 0;
  $self;
}

sub jit_flow
{
  my $self  = shift;
  my $point = shift;
  my $jit   = shift;
  my $flag  = \shift;
  my $n     = \shift;
  my $data  = \shift;
  $jit->code(
    q{
      if ($n < 0)
      {
        $n = -$n;
        @$data = $i..$i + $n;
        $i += $n;
      }
      else
      {
        $n = 0;
      }
    },
    data => $$data,
    n    => $$n,
    i    => $$self{i});
}
#line 3 "pushback/each.md"
package pushback::each;
push our @ISA, 'pushback::spanner';
sub new
{
  my ($class, $from, $fn) = @_;
  my $self = $class->connected_to(from => $from);
  my $n = -100;
  my $data;
  $$self{fn} = $fn;
  $$self{fn}->($n, $data) while $n = $self->flow_fn('from')->($n, $data);
  $self;
}

sub jit_flow
{
  my $self  = shift;
  my $point = shift;
  my $jit   = shift;
  my $flag  = \shift;
  my $n     = \shift;
  my $data  = \shift;
  $jit->code(
    q{
      if ($n > 0)
      {
        &$fn($n, $data);
        $n = -$n;
      }
      else
      {
        $n = 0;
      }
    },
    fn   => $$self{fn},
    data => $$data,
    n    => $$n);
}
1;
__END__
