# Flow point
An omnidirectional cut-through negotiation point for processes to exchange data.
Flow points provide JIT read/write proxies and propagate invalidation when
switching between monomorphic and polymorphic modes.

```perl
package pushback::flow;
sub new
{
  my $class = shift;
  bless { readers  => [],
          writers  => [],
          queue    => [],
          pressure => 0 }, $class;
}
```


## Process-facing API
```perl
sub add_reader;             # ($proc) -> $self
sub add_writer;             # ($proc) -> $self
sub remove_reader;          # ($proc) -> $self
sub remove_writer;          # ($proc) -> $self
sub jit_read_fragment;      # ($jit, $n, $data) -> $self
sub jit_write_fragment;     # ($jit, $n, $data) -> $self
sub invalidate_jit_readers; # () -> _
sub invalidate_jit_writers; # () -> _
```
