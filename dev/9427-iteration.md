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
