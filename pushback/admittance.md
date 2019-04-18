# Impedance calculation interface
This is purely a DSL for declaratively defining JIT functions for admittance
calculations.

```perl
package pushback::admittance;
use Scalar::Util qw/ looks_like_number /;

sub jit;                # ($jit, $flag, $n, $flow) -> $jit

use overload qw/ + plus
                 | union
                 & intersect /;

BEGIN
{
  no strict 'refs';
  eval "sub $_ { bless [shift, shift], 'pushback::admittance::$_' }"
        for qw/ plus union intersect if /;
  push @{"pushback::admiitance::$_\::ISA"}, 'pushback::admittance'
        for qw/ plus union intersect if n jit fn point /;
}

# Value coercion
sub create
{
  my $type = shift;
  "pushback::admittance::$type"->new(@_);
}

sub from
{
  my $class = shift;
  my $val   = shift;
  my $r     = ref $val;

  return create n     => $val        if !$r && looks_like_number $val;
  return create jit   => $val, @_    if !$r;
  return create fn    => $val        if  $r eq 'CODE';
  return create point => $val, shift if  $r =~ /^pushback::point/;
  return $val                        if  $r =~ /^pushback::admittance/;

  die "don't know how to turn $val ($r) into an admittance calculator";
}
```


## JIT proxy
```perl
sub pushback::admittance::jit::new
{
  my $class    = shift;
  my $code     = shift;
  my $bindings = shift;
  bless { code        => $code,
          bindings    => $bindings,
          ro_bindings => { @_ } }, $class;
}

sub pushback::admittance::jit::jit
{
  my $self = shift;
  my $jit  = shift;
  my $flag = \shift;
  my $n    = \shift;
  my $flow = \shift;
  $jit->code($$self{code}, %{$$self{bindings}},
                           %{$$self{ro_bindings}},
                           flag => $$flag,
                           n    => $$n,
                           flow => $$flow);
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
  $jit->code('$flow = $lflow > $rflow ? $lflow : $rflow;',
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
  $jit->code('  $flow = $rflow < $flow ? $rflow : $flow;',
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
