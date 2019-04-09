# Pushback: flow control as control flow
A fully-negotiated IO/control multiplexer for Perl. The OS multiplexes userspace
processes onto the CPU, and pushback multiplexes Perl code onto the interpreter.


## Streams: negotiated suppliers and consumers
Callbacks and futures provide flow control on the supply side, but not for
consumers.
