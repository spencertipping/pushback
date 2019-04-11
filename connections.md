# Stream connections
If we say something like `$stdin >> $stdout`, who owns the fact that these two
things are connected? Presumably whoever's multiplexing FDs. What's the API to
add/remove connections from inside other streams?


## Constraints
1. All graph endpoints are process-entangled.
2. Closed topologies should be first-class data.
3. Graphs should be incrementally constructable, although the IO multiplexer
   doesn't need to care about this.
4. IO multiplexers should consume topology edits as inputs.

One of the big problems here is that these things are independent processes, so
any externally visible degrees of freedom are possible race conditions.

**Q:** is there an explicit compilation step before we delegate to the
multiplexer? That might simplify a lot of this.

**Every negotiation point should have an ID so we can add new connections to
it.**


## Use case: async RPC
Trivially, `source -> fn -> destination` seems reasonable; `fn` can contain
subgraphs/etc. But how do we apply `fn` to every element of an array? We need to
back it into an existing pattern like pooled execution.
