# Fiber compiler
OK, let's implement `pv` and talk about how it works. Structurally we have this:

```pl
my $catalyst    = pushback::select_catalyst->new;
my $measurement = pushback::reducer([0, 0], "AB", "+");

my $in = $catalyst->r(\*STDIN)->broadcast;
$in >> $catalyst->w(\*STDOUT);
$in->map(sub { (length($_[0]), $dt) })  # numeric pairs
    >> $measurement;                    # ... send to measurement reducer

$catalyst->interval(1)                  # timed output (emit elapsed time)
  ->map(sub { @$measurement })          # ... return measurement output
  ->grep(sub { $_[1] > 2 })             # ... when two seconds have passed
  ->map(sub { sprintf(...) })           # ... format it
  >> $catalyst->w(\*STDERR);            # ... and print to stderr

$catalyst->loop;                        # run while we have open files
```

This results in two fibers:

```
stdin -> broadcast[stdout, map -> measurement]
interval -> map -> grep -> map -> stderr
```

That means we'll block and then run either fiber depending on what the scheduler
tell us: we might get `stdin->stdout` or we might get `interval->stderr`.
