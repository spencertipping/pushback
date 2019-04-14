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

This means everything is based on events; there's no process-poll loop. That's
great because it takes a lot of latency out of serial chains.

What's the flow/process conversation?

```
my $n = read(50, ...);                  # create a flow vacuum or move data
if ($n > 0)                             # $n > 0 : success
elsif ($n == 0)                         # $n == 0 : offered
elsif ($n == -1)                        # $n == -1 : eof
elsif ($n == -2) { die $! }             # $n == -2 : error, problem in $!
```

Same deal for writes:

```
my $n = write(...);                     # create flow pressure or move data
if ($n > 0) ...                         # success
elsif ($n == 0)                         # offered
elsif ($n == -2) { die $! }             # error, problem in $!
```

This seems like a lot of overhead, but it allows negotiated vectorization and
should easily be worth it.


## JIT-based API
No sense in running an `if` chain if we already know the value of `$n`. In that
case each process provides different entry points per flow port:

- Non-JIT setup
  - `init`: connect to the flow network
  - `deinit($! | undef)`: disconnect, either successfully or not
- JIT fragments
  - `read_ok($from, $n, $data)`: negotiated read from somewhere
  - `write_ok($to, $n, $data)`: negotiated write to somewhere

Each of the JIT fragment compilers gets a corresponding flow-network API to
issue inlined `read`/`write` negotiations to flow nodes. `read_ok` and
`write_ok` JIT points may be invoked multiple times with different flow-network
API generators to specialize hot IO paths.

I think this reduces our monomorphic overhead to zero, which means we get
cut-through `map`/`grep`/etc with no graph analysis at all. That's pretty
awesome.


## ...so what does our flow network look like?
**TODO**
