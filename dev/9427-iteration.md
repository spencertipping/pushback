# Design's good, just some coordinated changes
- Add port range support
- Do something better with port number/name mapping for processes
  - Do connections need to be objects that capture their named behavior?
- Improve precision of JIT invalidation
- Refactor `process::admittance` and `process::flow` to use a managed
  auto-recompiling JIT abstraction


## Connection objects and port ranges
Let's start here because it's the biggest change.

Processes shouldn't care about port names or the negotiation around them. All of
the JIT functions that interface with them are specialized to specific port
numbers, so names just provide JIT templates.

**NB:** we need to re-specialize each port within a range, even though they all
behave the same way. The reason is that each port can close over a different set
of process state.

A completely different way to look at it is that a connection gets specialized
as soon as you make it. (In practice we wait until the first IO because there
are intermediate states, but conceptually this is true.) So there's a
make-a-connection negotiation process followed by JIT-specialized flow paths. As
far as the process _instance_ is concerned, a connection is just a function that
produces a JIT specialization.

**Q:** what's the point of port IDs?


## Processes and port IDs
Port IDs let you refer back to a specific entry point for a process, but I don't
think we want this. A port ID is usable only from within an established
connection, and by that point someone holds a hard reference to the relevant
state. If we have an RPC jump to make, we can locally assign resource IDs to the
endpoints -- no need to have the processes participate in that negotiation.

...so let's get rid of port IDs.

Similarly, no reason to have processes have IDs, nor hosts. IDs imply a level of
addressibility that we have no use for.

How do we connect stuff in a post-ID world? Seems like we have
`$process->connect` that registers a `connection` object with each endpoint.


## JIT invalidation
Simple enough: don't kill every JIT specialization when a single port changes.
Some processes are JIT terminators anyway, so it wouldn't make sense to cross
ports this way.


## Automatic JIT recompilation
JIT classes should be able to offer entry points without manually going through
the shenanigans involved. I think an entry point is defined by two things:

1. A function that takes arguments and returns a key
2. A function that JITs the function body into a compiler
