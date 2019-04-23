# Flowable projection
If you're doing IO on byte arrays, you'll usually have signatures like this:

```c
ssize_t read(fd,  void *buf, size_t n);
ssize_t write(fd, void *buf, size_t n);
```

In Perl we'd say `read(fd, $buf, $n, $offset)` since we can't just make a
pointer to an arbitrary location. If we want to stream data around, we just pass
`\$buf, $n, $offset` to the JIT context (`fd` is provided by the receiver). Easy
enough, right?

Almost. The problem is that all of this stuff about byte arrays is only one way
to do IO. Pushback streams don't need to have anything to do with byte arrays;
they could be arrays of any sort, references, side effects, anything really. And
that complicates our life a bit if we want to use a standard interface to deal
with data flow.


## Negotiation and admittance
All streams in pushback are negotiated, which means moving data through them is
a two-step process. I'll outline the equivalent process in C-style IO before
talking about how pushback negotiation works:

```c
// Start with some amount of data we want to move...
stream *s = ...;
void *buf = ...;
size_t n  = 1048576;

// Ordinarily we might write() it here, but this is a negotiated-IO world so
// let's get the actual amount of data we can move right now. This is the stream
// admittance, which may be larger than n.
size_t admitted = figure_out_how_much_we_can_move(s, buf, n);

// Now move just that much if we still have any capacity to move things.
if (admitted)
{
  size_t moved = write_to_somewhere(s, buf, admitted);

  // We don't get short writes because everything was negotiated up front. Any
  // truncation indicates an IO or execution error.
  if (moved != admitted) perror(...);
}
```

Pushback works almost this way, but with two important differences:

1. The same negotiation pathway handles both reads and writes. C would work this
   way if `n` could take on negative values for reads.
2. Pushback doesn't just negotiate byte arrays; it's generalized to negotiate
   any type of operation on any type of value.


## Generalizing negotiation and flow
At its core pushback is doing this:

```pl
my $requested = ...;
my $admitted  = $process->admittance($port, $requested);
if ($admitted->nonzero)
{
  my $committed = $process->flow($port, $admitted);
  # $admitted == $committed unless something went wrong
}
```

This basic pattern can be modified a couple of ways to handle things like unions
and intersections:

```pl
# intersected flow, e.g. for cut-through broadcasting
my $requested = ...;
my $admitted1 = $process1->admittance($port1, $requested);
if ($admitted1->nonzero)
{
  my $admitted2 = $process2->admittance($port2, $admitted1);
  if ($admitted2->nonzero)
  {
    $process1->flow($port1, $admitted2);
    $process2->flow($port2, $admitted2);
  }
}
```

```pl
# unioned flow, e.g. for cut-through input merging
my $requested = ...;
my $admitted1 = $process1->admittance($port1, $requested);
if ($admitted1->nonzero)
{
  $process1->flow($admitted1);
}
else
{
  my $admitted2 = $process2->admittance($port2, $requested);
  if ($admitted2->nonzero)
  {
    $process2->flow($admitted2);
  }
}
```

Pushback doesn't natively combine writes, although some types of process might.
This simplifies the flow logic.


## Problems with negotiation
Negotiation isn't perfect. It's fairly straightforward to construct a situation
that will cause negotiation to mispredict flow; for example:

```
                +-----------+     +-------+
                | broadcast |     | union |
+---------+     |          >|-----|>      |     +--------------+
| source >|-----|>          |     |      >|-----|> destination |
+---------+     |          >|-----|>      |     +--------------+
                +-----------+     +-------+
```

It's easy to see why if we work out how the admittances are calculated:

```
source admittance = broadcast input admittance
  = (broadcast out1 admittance) intersect (broadcast out2 admittance)
  = (union in1 admittance)      intersect (union in2 admittance)
  = (destination in admittance) intersect (destination in admittance)
  = destination in admittance
```

...but this will overcommit `union` because `destination` will accept only the
first of the two broadcasted writes. The second is likely to fail entirely,
leaving `union`, and in turn `broadcast`, with uncommitted data.

It isn't at all impossible to construct pipelines like the one above, but
anytime you have these joint-admittance problems you'll need to provide some
slack by using buffers:

```
             +-----------+                +-------+
             | broadcast |  +----------+  | union |
+---------+  |          >|--|> buffer >|--|>      |  +--------------+
| source >|--|>          |  +----------+  |      >|--|> destination |
+---------+  |           |  +----------+  |       |  +--------------+
             |          >|--|> buffer >|--|>      |
             +-----------+  +----------+  +-------+
```

In this case the buffers just need one flow's worth of data; we don't need a
queue with any depth to it.
