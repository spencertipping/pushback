# Flow point
Flow points manage JIT aggregation across multiple paths. If a flow point has
exactly two paths then it becomes monomorphic and is erased; otherwise it
compiles an intermediate function to provide one flow result per invocation. (We
do this not because we have to, but because otherwise we could have an
exponential fanout of inlined logic.)


## State
```perl
package pushback::point;
use overload qw/ "" id == equals /;
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

sub equals { refaddr(shift) == refaddr(shift) }

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
```
