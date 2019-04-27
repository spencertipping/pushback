# Design's good, just some coordinated changes
- Add port range support
- Improve precision of JIT invalidation
- Refactor `process::admittance` and `process::flow` to use a managed
  auto-recompiling JIT abstraction
- Do something better with port number/name mapping for processes
  - Do connections need to be objects that capture their named behavior?


## Connection objects

