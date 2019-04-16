# Redesign: positive/negative flow and impedance
A massive API simplification: processes and flow points interact through just
one method, `->[jit_]flow($n, $data) = ($n, $!)`. `read()` uses negative values
of `$n`; `write()` uses positive values. Zero is a no-op.

This raises the question of how we measure and implement flow impedance. In an
IO context, impedance is obviously a lack of flow despite an offer: for instance
if `flow(1000, ...)` consistently returns small `$n` like `5`.

Impedance is a joint proposition: who's asking for flow and how often do they
get the amount they ask for? I'm not sure this matters much.


## Amplification and resource impedance (nope)
`each(sub { ... })` is a good example of something with effectively zero
impedance. How does it indicate this upstream? Probably by repeating its IO
requests. It waits for the first event, then re-requests at the same or larger
`$n`.

`$n` is a memory commitment, though. There's a natural limit to how much memory
we trade for performance if it comes to that. Ultimately it's an optimization
problem involving three variables:

1. Per-IO overhead (in time)
2. Cost of memory use
3. Cache locality, if we're dealing in byte quantities

I don't think we want to get into this though; it involves a lot of complexity
or broken simplifying assumptions.


## Edge triggering and the first-event problem (not a problem)
If I connect an unbounded `seq(...)` to `each(...)`, I should get a CPU-bound
loop as soon as that connection happens. Sounds simple but the mechanics aren't
completely straightforward:

1. Does each initiating node provide a `$data`?
2. Flow points remember the flow request and repeat it on behalf of the process
   when someone new connects

(2) isn't a problem, but let's talk about (1) for a minute.


## Where does `$data` come from? (the positive flow element)
Everything shares a heap, so it's wrong to think of `$data` as belonging to a
process. `->flow()` doesn't need to _move_ data anywhere; it just needs to
specify where to access a result.

...so if you issue `->flow(-100, $data)` to `seq(...)` and get `100` back, the
expectation is that `@$data[0..99]` would contain stuff until you yield control
back to the multiplexer.

Similarly, `->flow(100, $data)` means "`@$data[0..99]` contains stuff for
whoever wants it" (assuming array output). If someone returns `-47` to that flow
request, it's the equivalent of them having started the conversation with
`->flow(-47, $data)`.

**Data is stored by the provider.** Negative-flow requests should expect `$data`
to be modified. Positive-flow requests shouldn't expect this.

**Anyone initiating a flow request should size their data to a value that fits
into L1 cache, give or take.** So `seq` should offer something like 4096
elements per iteration. We [don't do this for
performance](hackery/scalar-cache), but rather because it's just a sensible
amount of data to be moving around and doesn't risk consuming tons of memory.


## Write combining and offsets (unsupported)
Perl doesn't make offsets easy, so let's not do them. If you ask for data you'll
get a pointer to that data with no shenanigans.

This isn't great for file IO where `sysread` and `syswrite` accept offsets, but
those are exceptional cases. We can also stuff an offset into `$data` by
pointing to a compound value, e.g. `[$offset, $buf]`, although this is a useful
output only when the data is going straight into an offset-consuming function
like `syswrite`.

If we have no offsets, we also have no write combining. I think that's fine; it
gives the reading process control over how it consumes incremental data and we
should get better memory usage for it. JIT will take care of most or all of the
overhead.


## Can/should we JIT data generation? (nope)
`seq` is a good example of where this would be useful. Why even allocate an
array when we can JIT `$start..$end` and just update the endpoints? Arguably
because we can't point to that result, and whoever's asking for flow expects a
pointer saying "here's your data." (Also, perl does in fact compute the full
range even if you do something like `(1..100)[5..6]`.)

Philosophically this seems like a strict-vs-lazy question. I think it's fine for
us to say that if you request `$n` items, they'll be strictly evaluated and you
can then access them in `O($n)` time or something. We lose a lot of the benefits
of vectorization if we start getting into questions about per-item computation.
