# Pushback: evented IO for Perl, but with backpressure
**TODO:** document the library


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
data-out.
