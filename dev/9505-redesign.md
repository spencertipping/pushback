# Let's rethink the role of connections
It just seems wrong to have a connection-as-a-thing in many cases. On the
flipside, having connections gives you a switching fabric you can rearrange
easily -- and there's a lot to recommend that.

If we do go with first-class connection objects, let's fix up the metaphor to
feel less clunky.


## What's wrong with process/port/connection?
- "Process" is good but misleading
- "Port" is more general than 95% of use cases require
- "Connection" is an annoyance most of the time

For example, a filter process is really really simple. While `grep` and `sort`
(in UNIX terms) can and do involve more fds for administrative reasons, their
functional interface consists of just three.


## A philosophical tangent about `stdin`/`stdout`/`stderr`
There's an analog to unary functions: `stdin` is a function's input value,
`stdout` is its output value, and `stderr` is a stream of its side effects. We
see this because `f | g | h` composes the outputs and aggregates the side
effects.

If you want to do anything else in bash things go downhill quickly. You end up
either masquerading streams as files (`join <(...) <(...)`) or doing horrific
fd-redirection stuff (`cmd <foo 3<&1 <bar`).

Languages that deviate from linear IO patterns get awkward: VHDL and other
build-graphs-from-text types of things. The worst case is stuff like SPICE
where you're naming connection points. I guess it's a bias we inherit from
treating `f(x)` as its result -- you don't need to explicitly say "the output of
evaluating `f(x)`". Bash is a little more explicit about the distinction between
processes and their results: you say things like `$(echo hi)` to specify the
context under which the process is to be used.

...of course, part of that is that bash's syntax is _really_ overloaded. Maybe
it's a bad example.


## Fluent flow-network definitions
Expression-oriented languages _aren't_ fluent, we've just culturally acclimated
to the idea that they are. None of them handles multiple return values in any
palatable way, so we write functions that don't return multiple values. Anything
beyond a simple-value return is done with side effects of some sort.

You could imagine a world where functions took their _outputs_ in a list:

```
y | f(x, z)                   # y is the input, x and z are outputs
y | f(g(x), z)                # composition still works
```

This feels kind of like a flow network even though it's just the usual
expression-linearity stuff going in reverse. I guess the reason we don't write
code like this is just that real-world functions tend to reduce the number of
values rather than expand them. This creates a bias towards structuring as
opposed to destructuring (and, incidentally, we see that bias reversed somewhat
in languages with pattern matching constructs).


## Directional surfaces and flow geometry
Let's say flow is driven by amoeba-shaped things that connect directly to each
other -- there's no concept of a connection-as-an-object. We can manage this
linguistically by referring to a context-specific interface surface: it's a
subset of the amoeba that corresponds to the next things you would naturally
want to connect. A lot of amoebas are just stdin -> stdout with a possible
stderr, but others are more involved. Amoebas generalize their connectable
things as surfaces, and other amoebas consume and produce complementary
surfaces.

...I think that makes sense.

Each link fuses things together; there's no reconfiguration possible here.
That's a feature: otherwise we need JIT invalidation and it turns into a slow
mess. Any reconfigurability is a degree of freedom within an amoeba. Then JIT
chains drop out of scope naturally along with their endpoints. No machinery
required.
