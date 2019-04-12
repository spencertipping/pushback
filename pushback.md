# Pushback
Quick table of contents:

- [Process multiplexer](pushback/mux.md)
- [IO selector](pushback/io-select.md)
- [JIT compiler](pushback/jit.md)
- [Stream API](pushback/stream.md)


## Multiplexer
Pushback is built around a [process multiplexer](pushback/mux.md) that manages a
series of Perl code functions. Each such function defines two resource
dependencies and will run when (and while) those dependencies are available:

```pl
my $process = [$input_dependency, $output_dependency, sub { ... }];
```

**TODO:** this spec is wrong; multiplexers should probably support any number of
resources per process.


## IO
The [IO selector](pushback/io-select.md) uses `select()` to inform the process
multiplexer about IO device availability.


## Streams
The [stream API](pushback/stream.md) is a high-level interface to IO and
multiplexed processes. It uses a [JIT compiler](pushback/jit.md) to produce
optimized processes that bypass OOP hash lookups, function calls, and other
inefficiencies that are common in Perl code.
