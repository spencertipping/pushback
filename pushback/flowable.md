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
Pushback doesn't need to care about where your data lives or how it's arranged.
All it needs to do is negotiate flow and pass that information on to the streams
that actually move things. This means we just need a simple set of operations:

- `$flowable <=> $flowable`
- `$flowable -> bool`: true if nonzero

...and that's it.
