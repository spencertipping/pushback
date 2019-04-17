# Impedance calculation interface
This is purely a DSL for declaratively defining JIT functions for admittance
calculations.

```perl
package pushback::admittance::value;
use overload qw/ + plus
                 | union
                 & intersect /;

sub jit;                # ($jit, $n, $flow) -> $jit
sub plus      { pushback::admittance::sum         ->new(shift, shift) }
sub union     { pushback::admittance::union       ->new(shift, shift) }
sub intersect { pushback::admittance::intersection->new(shift, shift) }
```
