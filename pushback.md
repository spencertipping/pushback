# Pushback
Quick table of contents, starting with the internals:

- [Internal bits](pushback/bits.md)
- [JIT compiler](pushback/jit.md)
- [Process multiplexer](pushback/mux.md)
- [IO selector](pushback/io-select.md)

Public API:

- [IO container](pushback/io.md)
- [Process object](pushback/process.md)
- [Stream API](pushback/stream.md)


## Multiplexer
Pushback is built around a [process multiplexer](pushback/mux.md) that manages a
series of Perl code functions.


## IO
The [IO selector](pushback/io-select.md) uses `select()` to inform the process
multiplexer about IO device availability.


## Streams
The [stream API](pushback/stream.md) is a high-level interface to IO and
multiplexed processes. It uses a [JIT compiler](pushback/jit.md) to produce
optimized processes that bypass OOP hash lookups, function calls, and other
inefficiencies that are common in Perl code.
