# Flow point
Flow points manage JIT aggregation across multiple paths. If a flow point has
exactly two paths then it becomes monomorphic and is erased; otherwise it
compiles an intermediate function to provide one flow result per invocation. (We
do this not because we have to, but because otherwise we could have an
exponential fanout of inlined logic.)


## State
```perl
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
```


## JIT interface
```perl
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
```
