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
printing its status updates.


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
