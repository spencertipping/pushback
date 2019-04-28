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


## JIT invalidation
Simple enough: don't kill every JIT specialization when a single port changes.
Some processes are JIT terminators anyway, so it wouldn't make sense to cross
ports this way.


## Automatic JIT recompilation
JIT classes should be able to offer entry points without manually going through
the shenanigans involved. I think an entry point is defined by two things:

1. A function that takes arguments and returns a key
2. A function that JITs the function body into a compiler
