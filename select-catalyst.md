# `select` catalyst
The goal is to lift blocking calls like `select()` as far as we can so you can
always combine/defer them. As a result, the `select` catalyst never calls
`select()`. Instead, it describes the `select` call you should make to resolve
frontier dependencies.

_Catalysts are streams of bitvector sets._ Reading a select-catalyst gives you
its current frontier, and writing to it updates streams' availability. For
example, here's how you would create a normal `select` loop:

```pl
while (1)
{
  my ($r, $w, $e, $dt) = $catalyst->read;
  select $r, $w, $e, $dt;
  $catalyst->write($r, $w, $e);
}
```

Catalysts are readable iff the frontier is nonempty. (If they were always
readable, they would cause the same frontier to be read indefinitely.)

Internally, the `select` catalyst stores mappings between file descriptors and
fibers using a packed encoding:

```
$read_fds[$i] = $fd        << 20 | $fiber_idx << 6 | $bit & 0x3f
$timeline[$i] = $dt_millis << 20 | $fiber_idx << 6 | $bit & 0x3f
```

The catalyst also holds a reference to the perl file object for each fd. This
lets us use `sysread` and `syswrite` instead of `POSIX::read` and
`POSIX::write`. Normally we could go straight to POSIX, but perl's POSIX module
doesn't support offsets within the scalar. That means we can't do any circular
buffering.

```perl
package pushback::select_catalyst;
use constant epoch => int time();
use Time::HiRes qw/time/;

sub new
{
  my $class = shift;
  bless { read_fds   => [],             # bit-packed
          write_fds  => [],             # bit-packed
          fibers     => [],             # index is significant
          perl_files => [],             # index == fileno($fh)
          timeline   => [] }, $class;   # sorted _descending_ by time
}
```
