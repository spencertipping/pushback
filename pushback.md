# Pushback
Quick table of contents, starting with the internals:

- [Internal bits](pushback/bits.md)
- [JIT compiler](pushback/jit.md)
- [Process multiplexer](pushback/mux.md)

Public API:

- [IO container](pushback/io.md)
- [Process object](pushback/process.md)
- [Stream API](pushback/stream.md)

Specific types of streams:

- [Callback streams](pushback/callback-stream.md)
- [File streams](pushback/file-stream.md)
- [TCP server streams](pushback/tcpserver-stream.md)


```perl
package pushback;
use Exporter qw/import/;
use constant io => pushback::io::->new;
our @EXPORT = our @EXPORT_OK = qw/io/;
```
