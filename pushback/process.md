# Process
A process has one or more connections to [flow points](flow.md) and provides JIT
fragments to compile read/write logic.

```perl
package pushback::process;
```


## Flow-facing API
```perl
sub jit_read;               # ($jit, $flow, $offset, $n, $data) -> $jit
sub jit_write;              # ($jit, $flow, $offset, $n, $data) -> $jit
sub eof;                    # ($flow, $error | undef) -> $self
sub invalidate_jit;         # ($flow) -> $self
```
