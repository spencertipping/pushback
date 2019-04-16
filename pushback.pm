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
          processes => [],
          jit_flags => [] }, $class;
}

sub id             { shift->{id} }
sub is_static      { @{shift->{processes}} == 1 }
sub is_monomorphic { @{shift->{processes}} == 2 }

sub connect
{
  my ($self, $p) = @_;
  die "$p is already connected to $self"
    if grep refaddr($p) == refaddr($_), @{$$self{processes}};

  $self->invalidate_jit;
  push @{$$self{processes}}, $p;
  $self;
}

sub disconnect
{
  my ($self, $p) = @_;
  my $ps = $$self{processes};
  my ($i) = grep refaddr($$ps[$_]) == refaddr($p), 0..$#$ps
    or die "$p isn't connected to $self";

  $self->invalidate_jit;
  splice @{$$self{processes}}, $i, 1;
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

sub jit_flow                # ($proc, $jit, $flag, $n, $data) -> $jit
{
  my $self = shift;
  my $proc = shift;
  my $jit  = shift;
  my $flag = \shift;
  my $n    = \shift;
  my $data = \shift;

  my $jit_flags = $$self{jit_flags};
  push @$jit_flags, $flag;
  weaken $$jit_flags[-1];

  if ($self->is_static)
  {
    # No flow is possible against a point with only one connection; flow points
    # themselves don't have any capacity.
    $jit->code(q{ $n = 0; }, n => $n);
  }
  elsif ($self->is_monomorphic)
  {
    # Passthrough to the only other process. No need to update flow pressure
    # since nobody will use it.
    my ($other) = grep refaddr($_) != refaddr($proc), @{$$self{processes}};
    $other->jit_flow($self, $jit, $$flag, $$n, $$data);
  }
  else
  {
    # Round-robin through the other processes. Any of them might return 0 from a
    # flow request, so we automatically proceed to the next one until we've
    # gotten zeroes from everyone.
    #
    # Technically it's wasteful to recompile all flow paths when this flow point
    # changes, but it keeps the logic simple and correctly handles monomorphic
    # inlining.
    my @fns = map $_->jit_flow($self, pushback::jit->new->code('sub {'),
                               $$flag, $$n, $$data)
                    ->code('}')->compile,
              grep refaddr($_) != refaddr($proc), @{$$self{processes}};
    $jit->code(
      q{
        $v  = 0;
        $n0 = $n;
        until ($f || $v++ >= $#$fns)
        {
          $n = $n0;
          $$fns[$i++ %= @$fns]->();
          $f = $n;
        }
      },
      n   => $$n,
      f   => my $f = 0,
      n0  => my $n0 = 0,
      i   => my $i = 0,
      v   => my $v = 0,
      fns => \@fns);
  }
}
1;
__END__
