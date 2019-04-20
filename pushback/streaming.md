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
intersection: we want to send the lower of the two admittances.


## Ports
`io::fd(0)` delegates its connected-ness to an output port, which is a blessed
hash that maintains its connections and distributes admittance and data flow.
Similarly, `io::fd(1)` uses an input port. Port objects don't do a lot, but they
do contain logic that we'd otherwise have to duplicate so I've pulled them into
their own abstraction to save some work later on.

**TODO:** who cares about flow direction?

```perl
package pushback::port::sum;
sub new { bless {}, shift }
```

```perl
package pushback::port::broadcast;
sub new { bless {}, shift }
```
