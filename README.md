# Pushback: evented IO for Perl, but with backpressure
**TODO:** document this


## Why Perl?
Because it's awesome, but more importantly because it uses reference counting
for memory management. In this case that's a big feature.

Pushback is built on stream objects that maintain a bidirectional conversation,
which means they hold references to each other. A common problem with designs
like this is that streams are more closely coupled to the IO resource lifecycle
than they are to a mark/sweep GC lifecycle; you want things to be closed as soon
as nobody refers to them.


## Why do you need backpressure?
One of the big problems with nonblocking/evented IO is that it's easy to run out
of memory if your IO resources have very different performance characteristics.
For example, let's suppose you have a node.js webserver that accepts data and
writes it back to the client (`cat`, more or less):

```js
http.createServer((req, res) => {
  // ...
  req.on('data', (d) => res.write(d));
  req.on('end',  ()  => res.end());
});
```

Because `write()` has a nonblocking API contract, it has no way to create
backpressure against reads from `req`. As a result, node.js will run out of
memory if you try to use this server in an environment where data-in outruns
data-out. If we want to do nonblocking IO responsibly, we need a way for reads
and writes to be coordinated. That's what `pushback` does.
