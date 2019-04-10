# Pushback: flow control as control flow
**TODO:** summarize this


## Backpressure
`cat` couples `stdin` and `stdout` by using the same process for both. Either
can influence the IO rate of the other by delaying the process.

If we want backpressure in a nonblocking/multiplexed world, we need to gather
flow impedance from all relevant endpoints and schedule CPU time only when
nothing opposes it. This is different from callback-based IO, which models
impedance only on one end:

```js
stdin.on('data', (data, err) => {       // read-side impedance
  stdout.write(data);                   // ...but no write-side impedance
});
```

The problem with the above isn't so much that buffers take up any slack, but
rather that they take up a potentially _unbounded_ amount of slack. Fixing this
involves modeling the joint `stdin -> stdout` impedance and scheduling the
callback on that intersected timeline.


### Obvious problems with joint impedance
Anytime there's code between `stdin` and `stdout` there's potential to create
problems for negotiated IO. For example, `countcat`:

```pl
while (<STDIN>)                         # read a number...
{
  print "$_\n" for 1..$_;               # ...and count up to it on stdout
}
```

There are two reasons we have a problem here:

1. `select()` and other IO multiplexers return momentary state; you can't
   negotiate a specific amount of non-blocking capacity.
2. Even if you could negotiate a specific amount of capacity with the OS, opaque
   code has unpredictable impact on data volume.


### Transactions and cooperative multiplexing
We can't preempt things without coroutines or multithreading. Given that we
never want to block, this means our commitments are end-to-end even with
arbitrary data expansion. Any given transaction, then, behaves like a
callback-driven IO system: buffers provide zero-impedance output capacity. The
difference in our case is that we consider the output to be subsequently
unavailable until its buffers are cleared.


## Streams and availability zones
**TODO**
