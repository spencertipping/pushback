# Spanner: connect flow points to things
Spanners issue flow requests and move data. `pushback::spanner` is an abstract
base class that manages things like JIT invalidation for you, and it includes a
metaprogramming layer that helps create multiway-routed components (**TODO**).


## Base spanner class
```perl
package pushback::spanner;
use Scalar::Util qw/refaddr/;
use overload qw/ == equals /;

sub connected_to
{
  my $class = shift;
  my $self  = bless { points        => {@_},
                      flow_fns      => {},
                      impedance_fns => {} }, $class;
  $_->connect($self) for values %{$$self{points}};
  $self;
}

sub equals { refaddr(shift) == refaddr(shift) }
sub name   { "anonymous " . ref shift }
sub point  { $_[0]->{points}->{$_[1]} }

sub flow
{
  my $self  = shift;
  my $point = shift;
  ($$self{flow_fns}{$point} // $self->jit_flow_fn($point))->(@_);
}

sub impedance
{
  my $self  = shift;
  my $point = shift;
  ($$self{impedance_fns}{$point} // $self->jit_impedance_fn($point))->(@_);
}
```


## JIT mechanics
```perl
sub jit_autoinvalidation
{
  my ($self, $jit, $regen_method, $point) = @_;
  my $flag = 0;
  $jit->code(q{ return &$fn($self, $point)->(@_) if $invalidated; },
    fn          => $self->can($regen_method),
    self        => $self,
    point       => $point,
    invalidated => $flag);
  \$flag;
}

sub jit_impedance_fn
{
  my ($self, $point) = @_;
  my $jit = pushback::jit->new
    ->code('#line 1 "' . $self->name . '::impedance_fn"')
    ->code('sub {');

  my $n;
  my $flow;
  my $flag = $self->jit_autoinvalidation($jit, 'jit_impedance_fn', $point);
  $jit->code(q{ $n = shift; }, n => $n);

  $$self{impedance_fns}{$point} =
    $self->point($point)
      ->jit_impedance($self, $jit, $$flag, $n, $flow)
      ->code('$_[0] = $flow; }', flow => $flow)
      ->compile;
}

sub jit_flow_fn
{
  my ($self, $point) = @_;
  my $jit = pushback::jit->new
    ->code('#line 1 "' . $self->name . '::flow_fn"')
    ->code('sub {');

  my ($offset, $n, $data);
  my $flag = $self->jit_autoinvalidation($jit, 'jit_flow_fn', $point);
  $jit->code('($offset, $n, $data) = @_;',
    offset => $offset,
    n      => $n,
    data   => $data);

  $$self{flow_fns}{$point} =
    $self->point($point)
      ->jit_flow($self, $jit, $$flag, $offset, $n, $data)
      ->code('$_[2] = $data; $_[0] = $offset; $_[1] = $n }',
          offset => $offset,
          n      => $n,
          data   => $data)
      ->compile;
}
```
