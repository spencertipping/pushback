# Pushback: flow control as control flow
A fully-negotiated IO/control multiplexer for Perl. The OS multiplexes userspace
processes onto the CPU, and pushback multiplexes Perl code onto the interpreter.


## Streams: negotiated suppliers and consumers
Callbacks and futures provide flow control on the supply side, but not for
consumers. Programs that use these patterns are usually write-optimistic and can
run out of memory or IO-block if reads are faster than writes. Pushback is
designed to avoid this by making sure backpressure is propagated from data
consumers, which means we need an end-to-end stream abstraction.
