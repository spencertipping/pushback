# Yep, another redesign
I'm not sure exactly what I want yet, but whatever it is should be much simpler
than what exists now.

There's no point to having `router` and `spanner`, nor is there any point to
having both `point` and `stream`. We should focus on `router` and `stream`, but
they're probably due for a rename.

Data direction needs to be handled a lot more consistently than it is now. I
don't love signed ints for direction, although it is simple. From an IO
perspective it demands some erasure or other clunkiness, which seems like a
problem. Maybe we should condense flow down to signed stuff but always present
it as `inflow` or `outflow` with a positive length.

I'm certain the current implementation creates circular references.

Routers can provide stream endpoints and may default to different endpoints for
different-direction operations: `$stream >> $map` vs `$map >> $stream`, for
example.

...that's a start.


## Flow, admittance, and JIT
I want to cut down on the number of entry points we have to this logic. Ideally
each thing has a single JIT point that handles both admittance and flow.

Can we factor flow/admittance down to process-relative paths? e.g. `>proc/foo`.
Then the path takes up read/write slack and we can use positive flows. Paths are
erased at runtime; they just route the JIT.

Same deal with `admittance` vs `flow`; `?>proc/foo` routes to an admittance
endpoint (for which `$data` is expected to be `undef`), whereas `>proc/foo` is
an actioned flow.


## `$n`, `$offset`, and `$data`
...are all wrong. There's no reason to commit to any specific calling convention
around sequential data. This should be abstracted into a `flowable` IO container
that JITs the appropriate data logic and specifies things like data itemization.
Some process endpoints will fix their `flowable` types, so `flowable` becomes an
ad-hoc type system.

What are the core operations here?

- Basic flow algebra
  - Combine flow
  - Min-flow
  - Max-flow
  - Nonzero?
- Data movement
  - Type-specific data conversions?
  - Vectorized data accessors
  - ...?

This is a slippery boundary; before long the flowable stuff is going to start
assuming process responsibilities.

`flowable` objects represent the dimensional size of data relative to some
container. Strings, arrays, etc are flowable. Flowability _isn't_ for people
using data; it's for people bundling it. Flowability is a shipping container.


## Redirection syntax options
```pl
my $foo = pushback::file('< foo');
my $bar = pushback::file('> bar');

pushback::cat(in => $foo, out => $bar);
pushback::cat < $foo > $bar;
$foo | pushback::cat | $bar;
$foo >> pushback::cat >> $bar;
pushback::cat < './foo' > './bar';
'<file://foo' | pushback::cat | '>file://bar';
```


## While we're at it: JIT stuff
JIT is pretty good but has a few problems:

1. It's slow
2. We have to rebind variables for every `->code` call
3. We have to bind `my` variables for abstract gensyms...
4. ...which are difficult to share across `->code` snippets
5. We can't reuse the same `eval` result across multiple objects (with direct
   scalar access)

A big part of (1) is just that we re-gensym everything per JIT operation, which
is hugely wasteful if we know the scope ahead of time.

(3) fixes (5); basically, we just need custom lvalues. I think we can get there
if we have two layers of context, one where `$x` becomes `${$g0}` (what we have
now) and one where it just becomes `$g0`. Maybe we just have `$^x -> $g0` or
something.


### JIT per object
This makes a lot of sense, especially if we `defjit` or similar. Then we can
potentially automate stuff like code reuse and we can share gensyms per class.
If we do it right we can also get entry points and invalidation logic for free.
Put differently, JIT lifecycles are more closely related to objects than they
are to individual specializations.
