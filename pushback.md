# Pushback: evented IO for Perl, but with backpressure
```perl
# Documentation at https://github.com/spencertipping/pushback.
#
# Copyright 2019 Spencer Tipping
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

use v5.14;
use strict;
use warnings;
```


## Stream objects
A stream is a series of events terminated either by "successful" EOF or
"unsuccessful" error. Streams are connected directly to each other rather than
using callbacks, although an adapter exists to invoke callbacks on stream events
(in that case, backpressure comes from CPU time spent in the callbacks).

Streams can be arranged into graphs that describe IO dependencies. For example,
suppose you're implementing the UNIX `join` command; the read-side blocks on the
intersection of the two inputs. Pushback would model this as two input IO
resources (each with an fd) joined with an "intersect" stream.


### IO negotiation
In principle this is trivial: each stream can tell you whether it's readable and
writable at any given point in time. Nothing to it.

...except, of course, that for IO resources each of those questions involves a
round-trip to the kernel. That gets really slow if we have a bunch of things
going on. We should batch things up into `select()` bitvectors when we can.

...except that you might not want to use `select()`. First, not every
stream-of-stuff backs into an IO resource at all; what if you have a UNIX shared
memory segment or a stream of periodic events generated from a timer? Second,
`select()` itself isn't always the right choice for nonblocking IO; on Linux
`epoll` can be faster, but it's not portable.

So a stream's readability and writability is sometimes discoverable, sometimes
updated asynchronously, and may involve a conversation about one or more FDs.


### Edge triggers, IO actions, and sharing
node.js uses read-side edge triggering and assumes the destination is always
writable. Pushback doesn't have the always-writable level state, so edge
triggers need to be bidirectional. IO will happen when a readable edge trigger
meets a writable level state or vice versa, and that in turn means that
FD-backed streams keep track of previous `select()` results.

...but let's complicate matters a little by making a topology with a join point:

```
input_1 --> |
            | join_union --> output_1
input_2 --> |
```

If `output_1` broadcasts writability leftwards, `join_union` needs to pass that
information along to its inputs. But that writability isn't a firm promise; if,
for instance, both inputs consider their output to be writable and `input_1`
then writes something, `input_2` can't jump on the bandwagon and also try to
write stuff. It needs to wait for another writability event. And that means we
need another edge trigger, "I'm not writable anymore."


### Catalyst streams
Nonblocking IO doesn't mean "nobody blocks"; if it did, any nonblocking program
would consume 100% CPU. Instead, it means "no one IO thing blocks other IO
things" -- or to put it differently, a single thread multiplexes IO with minimal
latency.

The reason I bring this up is that nonblocking IO still involves blocking, just
on a `select` or `epoll` output instead of a single file descriptor. If we think
about it this way, we don't really need a whole framework to implement
nonblocking IO; we just need an action scheduler. Instead of _doing_ things, our
scheduler _produces_ things to do: it's a stream of functions.

So, all we need to do is create a single `select_catalyst`, ask it for a bunch
of individual FD streams, hook them up, and then `$catalyst->read->() while 1`,
right?

Almost. It's really tempting to run with what we have but we can simplify a lot,
handle some edge cases, and improve performance if we retroactively admit to
some dishonesty.


## Flow control
Until now I've been describing streams as objects that handle data; that's how
we think of them, after all. But there's no reason they should work this way --
and a number of reasons they really shouldn't. For one thing, if streams are a
polymorphic abstraction then we're doing a polymorphic method call for every IO
event; that's not going to give us fast code. Streams-as-objects also don't make
it efficient to propagate read/write availability; we're walking the object
graph for every state change, and a lot of intermediate objects are just
cut-through elements that don't have independent state.

The good news is that the real world is simpler than the world of stream
objects. In stream terms we might do something like
`input -> map(fn1) -> map(fn2) -> output`, which involves a bunch of negotiation
before any data can move. If `input` and `output` are the only availability
variables, though, then the fundamental logic is really simple:

```pl
whenever ($input->readable && $output->writable)
{
  my @stuff = $input->read;
  @stuff = $fn1->(@stuff);
  @stuff = $fn2->(@stuff);
  $output->write(@stuff);
}
```

All we have to do is reduce our stream graph to a series of these `whenever`
blocks and find a way to schedule them.


### Blocking vs cancellation
Let's take something simple like the `pv` tool. `pv` is `cat`, but it prints a
throughput meter to `stderr` every second while it's running. Starting with
`cat`, here's how we'd build it up:

```
stdin --> stdout                                # cat

stdin --+--> stdout                             #
        |                                       # pv
        +--> measure --> format --> stderr      #
```

This raises an interesting question, though. We've forked `stdin` to go to two
destinations, which seems reasonable enough; but should `stdin -> stdout` block
on `stderr`'s writability? In `pv`'s case, definitely not. If `stderr` isn't
writable, we should just drop the formatting rather than creating backpressure.
So our real topology is more like this:

```
stdin --+--> stdout
        |
        +--> measure --> format --> dropper --> stderr
```

`dropper` advertises that it's always writable, but forwards data only when its
downstream is available. Fair enough.

...but now we have a new suboptimality: `format` does some work to generate its
output. If `dropper` is just going to discard the data, why go to the effort?

The answer, of course, is that we shouldn't. Our logic should look like this:

```pl
whenever ($stdin->readable && $stdout->writable)
{
  my $data = $stdin->read;

  # Top fork output
  $stdout->write($data);

  # Bottom fork output
  my $next = $measurement_fn->($data);
  if ($stderr->writable)
  {
    $next = $format_fn->($next);
    $stderr->write($next);
  }
}
```

In this case `stderr` isn't blocking a stream segment, it's cancelling one.

**FIXME:** the above is totally wrong. We want buffering elements, not
cancellation.
