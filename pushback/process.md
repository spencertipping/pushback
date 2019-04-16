# Process
A process has one or more connections to [flow points](flow.md) and provides JIT
fragments to compile read/write logic.

```perl
package pushback::process;
use overload qw/ "" name /;
```


## Flow-facing API
```perl
sub name;                   # ($self) -> $name
sub fp_eof;                 # ($flow, $error | undef) -> $self

sub jit_fp;                 # ($jit, $flow, $offset, $n, $data) -> $jit
sub jit_pf;                 # ($jit, $flow, $offset, $n, $data) -> $jit
sub jit_fp_ready;           # ($jit, $flow) -> $jit
sub jit_pf_ready;           # ($jit, $flow) -> $jit
sub invalidate_fp_jit;      # ($flow) -> $self
sub invalidate_pf_jit;      # ($flow) -> $self
```


## Default implementations
```perl
sub jit_fp_ready { $_[1] }  # nop: readiness is mostly for passthrough.
sub jit_pf_ready { $_[1] }
```
