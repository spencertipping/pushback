# Pushback: flow control as control flow
A fully-negotiated IO multiplexer for Perl.


## Background
From an API perspective we want the world to be expressed as a dataflow graph,
although we don't want to deal with the overhead of graph structures at runtime.
Instead of driving IO, streams drive compilers and manage data shared across a
JIT boundary.

Pushback uses _negotiated_ IO, which means that in order for data to move from
point A to point B, both points must be "available" -- i.e. ready to produce or
consume data. File descriptors detect availability using `select`, `epoll`, or
another such multiplexed IO mechanism, but not all availability points have
underlying IO resources.


### Why do you need negotiation?
One of the big problems with nonblocking/evented IO is that it's easy to run out
of memory if your IO resources have very different performance characteristics.
For example, let's suppose you have a node.js webserver that accepts data and
writes it back to the client (`cat`, more or less):

```js
http.createServer((req, res) => {
  // ...
  req.on('data', (d) => res.write("got some data: " + d));
  req.on('end',  ()  => res.end());
});
```

Because `write()` has a nonblocking API contract, it has no way to create
backpressure against reads from `req`. As a result, node.js will run out of
memory if you try to use this server in an environment where data-in outruns
data-out. If we want to do nonblocking IO responsibly, we need a way for reads
and writes to be coordinated. That's what `pushback` does.


### Streams
Pushback would represent the above webserver like this:

```pl
my $server = ...;
$server->each(sub {
  my ($req, $res) = @_;
  $req->map(sub { "got some data: " . shift }) >> $res;
});
```

In the code above, `$server` is a stream of HTTP socket pairs and `$req` and
`$res` are streams of binary data. We can run out of file descriptors because no
negotiation happens with `$server`, but `$req->map() >> $res` waits until both
endpoints are ready. I'll address the file descriptor problem in a bit.

We might have an arbitrary number of `$req->map() >> $res` forwards active at
any given time. `$req` and `$res` can't negotiate IO between themselves; in
order to do anything we need an event loop driver. Pushback calls this a
catalyst.


### Catalysts
A catalyst detects successful negotiation states and initiates IO actions.
Perhaps counterintuitively, pushback catalysts are themselves streams of
availability states; for example, its `select_catalyst` (the default) is a
stream of `select()` bitvectors:

```pl
my $catalyst = pushback::select_catalyst->new;
my $file1 = $catalyst->...;     # create some IO streams to negotiate
# ...

while ($catalyst->readable)     # run the event loop
{
  my ($r, $w, $e, $t) = $catalyst->read;
  select $r, $w, $e, $t;
  $catalyst->write($r, $w, $e);
}
```


### Forks and joins
Let's suppose we're using pushback to write `tee`:

```pl
my $stdin   = $catalyst->r(\*STDIN);
my $stdout  = $catalyst->w(\*STDOUT);
my $outfile = $catalyst->w(shift @ARGV);

my $fork = $stdin->broadcast;
$fork >> $stdout;
      >> $outfile;

$catalyst->loop;                # shorthand for the while loop
```

Both `$stdout` and `$outfile` have the potential to block `$stdin`, behavior
controlled by the broadcast stream. In this case broadcasting is a cut-through
operation: inputs are blocked until all outputs are available for writes. This
means `->broadcast` incurs no independent buffer overhead and holds no data. It
exists purely for negotiation.

Joins are similar. We can write an interleaving `cat` (which is useless) like
this:

```pl
my $in1 = $catalyst->r(\*STDIN);
my $in2 = $catalyst->r(shift @ARGV);
my $out = $catalyst->w(\*STDOUT);

my $join = $out->union;
$in1 >> $join;
$in2 >> $join;

$catalyst->loop;
```
