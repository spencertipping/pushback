# Spanner: micro-processes that connect flow points
Spanners issue flow requests and move data. `pushback::spanner` is an abstract
base class that helps with things like JIT invalidation, directional flow, and
admittance negotiation.


## Declarative admittance
It's a major bummer to write admittance logic by hand. It usually ends up
looking like `$flow = $n > 0 ? $n : 0` in the best case, and in the worst case
you're writing complicated logic to incorporate multiple JIT results.

What we really want is to say something like this:

```pl
defadmittance(
  '>source' => '>destination',      # source passes through to destination
  '<source' => 0);                  # ...but blocks reverse flow
```

...and in most cases we'd assume a component would block flow, so we could drop
the `<source` definition.


## Base API
```perl
package pushback::spanner;
use Scalar::Util qw/refaddr/;
use overload qw/ "" name == equals /;

sub connected_to;           # pushback::spanner->connected_to(%points)
sub point;                  # ($key) -> $point
sub flow;                   # ($point, $offset, $n, $data) -> $n
sub admittance;             # ($point, $n) -> $flow
```


## Flow point management
```perl
sub connected_to
{
  my $class = shift;
  my $self  = bless { points         => {@_},
                      flow_fns       => {},
                      admittance_fns => {} }, $class;
  $_->connect($self) for values %{$$self{points}};
  $self;
}

sub equals { refaddr shift == refaddr shift }
sub name   { "anonymous " . ref shift }
sub point  { $_[0]->{points}->{$_[1]} // die "$_[0]: undefined point $_[1]" }

sub flow
{
  my $self  = shift;
  my $point = shift;
  ($$self{flow_fns}{$point} // $self->jit_flow_fn($point))->(@_);
}

sub admittance
{
  my $self  = shift;
  my $point = shift;
  ($$self{admittance_fns}{$point} // $self->jit_admittance_fn($point))->(@_);
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

sub jit_admittance_fn
{
  my ($self, $point) = @_;
  my $jit = pushback::jit->new
    ->code('#line 1 "' . $self->name . '::admittance_fn"')
    ->code('sub {');

  my $n;
  my $flow;
  my $flag = $self->jit_autoinvalidation($jit, 'jit_admittance_fn', $point);
  $jit->code(q{ $n = shift; }, n => $n);

  $$self{admittance_fns}{$point} =
    $self->point($point)
      ->jit_admittance($self, $jit, $$flag, $n, $flow)
      ->code('@_ ? $_[0] = $flow : $flow; }', flow => $flow)
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
