# Impedance calculation interface
This is purely a DSL for declaratively defining JIT functions for admittance
calculations.

```perl
package pushback::admittance::value;
use Scalar::Util qw/ looks_like_number /;

sub jit;                # ($jit, $flag, $n, $flow) -> $jit

use overload qw/ + plus
                 | union
                 & intersect /;

# Binary ops
BEGIN { eval "sub $_ { bless [shift, shift], 'pushback::admittance::$_' }"
        for qw/ plus union intersect if / }

# Value coercion
sub from
{
  my ($class, $val) = @_;
  my $r = ref $val;
  return pushback::admittance::n->new($val)  if !$r && looks_like_number $val;
  return pushback::admittance::fn->new($val) if $r eq 'CODE';
  return pushback::admittance::point->new($val, shift)
    if $r =~ /^pushback::point/;
  die "don't know how to turn $val of type $r into an admittance calculator";
}
```


## Direct values
```perl
sub pushback::admittance::n::new     { bless \(my $x = $_[1]), $_[0] }
sub pushback::admittance::fn::new    { bless \(my $x = $_[1]), $_[0] }
sub pushback::admittance::point::new { bless { point   => $_[1],
                                               spanner => $_[2] }, $_[0] }

sub pushback::admittance::n::jit
{
  my $self = shift;
  my $jit  = shift;
  my $flag = \shift;
  my $n    = \shift;
  my $flow = \shift;
  $jit->code('$flow = $n * $a;', flow => $$flow, n => $$n, a => $$self);
}

sub pushback::admittance::fn::jit
{
  my $self = shift;
  my $jit  = shift;
  my $flag = \shift;
  my $n    = \shift;
  my $flow = \shift;
  $jit->code('$flow = &$fn($n);', flow => $$flow, n => $$n, fn => $$self);
}

sub pushback::admittance::point::jit
{
  my $self = shift;
  my $jit  = shift;
  my $flag = \shift;
  my $n    = \shift;
  my $flow = \shift;
  $$self{point}->jit_admittance($$self{spanner}, $jit, $$flag, $$n, $$flow);
}
```


## Binary ops
```perl
sub pushback::admittance::plus::jit
{
  my $self = shift;
  my $jit  = shift;
  my $flag = \shift;
  my $n    = \shift;
  my $flow = \shift;
  my $lflow;
  my $rflow;
  $$self[0]->jit($jit, $$flag, $$n, $lflow);
  $$self[1]->jit($jit, $$flag, $$n, $rflow);
  $jit->code('$flow = $lflow + $rflow;',
    flow => $$flow, lflow => $lflow, rflow => $rflow);
}

sub pushback::admittance::union::jit
{
  my $self = shift;
  my $jit  = shift;
  my $flag = \shift;
  my $n    = \shift;
  my $flow = \shift;
  my $lflow;
  my $rflow;
  $$self[0]->jit($jit, $$flag, $$n, $lflow);
  $$self[1]->jit($jit, $$flag, $$n, $rflow);
  $jit->code('$flow = abs($lflow) > abs($rflow) ? $lflow : $rflow;',
    flow => $$flow, lflow => $lflow, rflow => $rflow);
}

sub pushback::admittance::intersection::jit
{
  my $self = shift;
  my $jit  = shift;
  my $flag = \shift;
  my $n    = \shift;
  my $flow = \shift;
  my $rflow;
  $$self[0]->jit($jit, $$flag, $$n, $$flow);
  $jit->code('if ($flow) {', flow => $$flow);
  $$self[1]->jit($jit, $$flag, $$n, $rflow);
  $jit->code('  $flow = abs($rflow) < abs($flow) ? $rflow : $flow;',
               rflow => $rflow, flow => $$flow)
      ->code('}');
}

sub pushback::admittance::if::jit
{
  my $self = shift;
  my $jit  = shift;
  my $flag = \shift;
  my $n    = \shift;
  my $flow = \shift;
  $$self[1]->jit($jit, $$flag, $$n, $$flow);
  $jit->code('if ($flow) {', flow => $$flow);
  $$self[0]->jit($jit, $$flag, $$n, $$flow)->code('}');
}
```
