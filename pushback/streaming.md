# Streaming objects
I highly recommend `pv`. It's `cat`, but every second it prints the data rate to
stderr. It wouldn't be hard to write a tool like it; something like this:

```pl
my $total_bytes;
my $start_time = time();
my $last_print = 0;
while ($n = sysread(STDIN, $buf, 65536))
{
  $total_bytes += $n;
  $last_print = time(),
  STDERR->printf("...", $total_bytes / (time() - $start_time))
    if time() - $last_print > 1;
  syswrite STDOUT, $buf;
}
```

...but this implementation of `pv` doesn't IO-negotiate stderr. If you used it
over a pathologically slow terminal connection it could easily block just
printing its status updates. Pushback, of course, solves this problem.


## How would `pv` work in pushback?
Like this, give or take:

```
             io::interval(1) -----+
                                  V
            +-> timing state --> gate --> drop --> map(status) --> io::fd(2)
            |
io::fd(0) --+-> io::fd(1)
```

Timing outputs are gated on a one-second interval and run through a `drop`
element, which always accepts input but deletes those inputs whenever the output
is unavailable. We can also avoid the work required to format the output string
(`map(status)`) if stderr is blocked.

The forked output from `io::fd(0)` will cause each flow to be duplicated and
sent to both downstream consumers. This is why we need flowables to support
intersection: we want to send the lower of the two admittances. (If we try to
send more, one of the writes will be truncated and we'll be forced to either
buffer or drop the data.)


## Connecting objects together
Let's state a few obvious things:

1. An object can (and usually does) have multiple connection ports
2. A connection port can have multiple connections to different places
3. Connections are uniquely identified by port pairs
4. Objects can't be involved in reference cycles, although ports/edges can
5. Edges must link their endpoints bidirectionally since IO can come from either
   direction
6. Connection ports may be bidirectional, although they tend not to be

Perl gives us a lot of latitude in terms of memory management because we have
precise destructors and weak references. We could, for example, maintain a
global hashtable of all objects and use a packed addressing scheme. We can also
have evented disconnect-on-destroy, and we can calculate reference strength
based on graph topology if we want to.

Having a lookup would allow objects to be addressible over RPC connections. I'm
not sure I want to fully predicate the graph stuff on this, but it's
independently useful enough that it may be justifiable.


### Object lifecycle and reference structure
This is a lot more subtle than it sounds.

We can start with a couple of basic lifecycle models. One is that streaming
objects live until you call `->close` on one of their ports, at which point they
self-destruct and `->close` the things they're connected to. This makes it easy
to leak space without any way to reclaim it, which I don't like at all.

The other model is to start with all objects being weakly referenced and have
some anchored to IO containers or other endpoints that pin them. Anchored
objects refer strongly to their derivatives (and this propagates transitively),
but those derivatives refer weakly in reverse. We transitively weaken references
when the underlying IO pin goes away. This is more or less an external GC
strategy that makes graphs reclaimable when nobody refers to them anymore, even
if they contain cycles.

There are some strange middle-cases too. If we `->map(...)` a stream of things
and then do nothing with it, should the mapped derivative persist? Arguably not
because `map` is a cut-through element that won't consume any data or create any
side effects until it has a destination. So maybe we use an insertion point
structure where backlinks are strongly referenced and forward links are weak. If
you then terminate with a side effect like `->each(sub)`, we go back and
strengthen the forward pointers in the source graph leading to it. `each` is
pinned by its input(s).
