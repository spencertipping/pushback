# Redesign
Multiplexer-centric design, IO is one or more processes that provide read/write
offers. s/multiplexer/flow/ most likely. Two big questions around flow
mechanics:

1. Do flow points have capacity, or are they strictly cut-through?
2. Does negotiation involve quantities or is it just stop/go flow control?

No clue. Let's explore some possibilities.


## Omnidirectional, quantified flow negotiation with cut-through IO
Flow points with in/out exchange negotiation around `offer` and `ask`-style
things. I think both `ask` and `offer` are hard commitments, promising capacity
for the corresponding `read`/`write`. They provide upper bounds.

Each process/object is notified per connection to the flow network. This means
the flow network has no idea which things are connected to which other things.

Something like this in terms of API:

- `read($n, $data)` -> `offered` | `ok($n)` | `eof` | `fail($error)`
- `write($n, $data)` -> `offered` | `ok($n)` | `fail($error)`

If we do this, the handoff looks like this:

```
process 1                           process 2
-----------------------------------------------------------------------
read(50, _) -> offered
                                    write(100, ...) -> ok(50)
read(50, _) -> ok(50)
```

This pushes a lot of flow control logic into each process, which may or may not
be a problem.


## Flow -> process eventing
Processes are connected to flow points. This means they'll be alerted when those
flow points change in polarity or order of magnitude.

**Complex process functions are better than complex multiplexer logic.**

Processes can provide JIT contexts for IO operations against different flow
points. This allows the flow network to opportunistically specialize for common
IO paths.
