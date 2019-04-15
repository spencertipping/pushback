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

sub jit_read;               # ($jit, $flow, $offset, $n, $data) -> $jit
sub jit_write;              # ($jit, $flow, $offset, $n, $data) -> $jit
sub jit_flow_readable;      # ($jit, $flow) -> $jit
sub jit_flow_writable;      # ($jit, $flow) -> $jit
sub invalidate_jit_reader;  # ($flow) -> $self
sub invalidate_jit_writer;  # ($flow) -> $self

sub eof;                    # ($flow, $error | undef) -> $self
```
