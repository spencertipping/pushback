# Callback stream
You can use this to terminate a stream into a side effect or other reducer.

```perl
package pushback::callback_stream;
push our @ISA, 'pushback::stream';

sub pushback::io::each
{
  my ($io, $fn) = @_;
  pushback::callback_stream->new($io, $fn);
}

sub new
{
  my ($class, $io, $fn) = @_;
  bless { io => $io,
          fn => $fn }, $class;
}

sub jit_write_op
{
  my ($self, $jit, $data) = @_;
  $jit->code(q{ &$fn(@$data); }, fn => $$self{fn}, data => $data);
}
```
