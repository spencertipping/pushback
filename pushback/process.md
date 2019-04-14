# Process
A process has one or more connections to [flow points](flow.md) and provides JIT
fragments to compile read/write logic.

```perl
package pushback::process;
```


## Flow-facing API
```perl
sub jit_read;               # ($jit, $node, $n, $data) -> _
sub jit_write;              # ($jit, $node, $n, $data) -> _
sub eof;                    # ($node, $error | undef) -> _
sub invalidate_jit_reader;  # ($node) -> _
sub invalidate_jit_writer;  # ($node) -> _
```
