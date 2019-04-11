# Stream connections
If we say something like `$stdin >> $stdout`, who owns the fact that these two
things are connected? Presumably whoever's multiplexing FDs. What's the API to
add/remove connections from inside other streams?


## Constraints
1. All graph endpoints are process-entangled.
2. Closed topologies should be first-class data.
3. Graphs should be incrementally constructable, although the IO multiplexer
   doesn't need to care about this.
4. IO multiplexers should consume topology edits as inputs.

One of the big problems here is that these things are independent processes, so
any externally visible degrees of freedom are possible race conditions.

**Q:** is there an explicit compilation step before we delegate to the
multiplexer? That might simplify a lot of this.

**Every negotiation point should have an ID so we can add new connections to
it.**


## Streams are compilers
...that produce `($source_id, $dest_id, $code)` tuples for the multiplexer. Each
such tuple becomes a process.

`$code` erases stream polymorphism by inlining logic for reads and writes. This
makes sense given that the source and destination are already known.


## A webserver that serves files
```pl
my $server_process = $io->(
  $io->tcp_server($port)                # stream of (socket)
    ->map(http)                         # stream of (headers, socket)
    ->map(sub {
        my ($http, $socket) = @_;
        $io->read($http->path) >> $socket;
      })                                # stream of (process constructor)
    >> $io);                            # process constructor

$io->loop;                              # multiplex all active processes
```


## A chat server
```pl
my $broadcast = $io->drop_broadcast;
my $server = $io->tcp_server($port)
  ->map(http)
  ->map(websocket_upgrade)
  ->map(sub {
      my ($http, $socket) = @_;
      ($socket >> ws_messages >> $broadcast,
       $broadcast->map(\&ws_text) >> $socket);
    });

$io << $server;                         # == $io->($server >> $io)
$io->loop;
```
