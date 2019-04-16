# Spanner: connect flow points to things
Spanners issue flow requests and move data. `pushback::spanner` is an abstract
base class that manages things like JIT invalidation for you.

```perl
package pushback::spanner;
use Scalar::Util qw/refaddr/;
use overload qw/ == equals /;

sub connected_to
{
  my $class = shift;
  my $self  = bless { points   => {@_},
                      flow_fns => {} }, $class;
  $_->connect($self) for values %{$$self{points}};
  $self;
}

sub equals { refaddr(shift) == refaddr(shift) }
sub name   { "anonymous spanner (override sub name)" }
sub point  { $_[0]->{points}->{$_[1]} }
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
```
