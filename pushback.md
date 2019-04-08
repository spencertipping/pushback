# Pushback: evented IO for Perl, but with backpressure
```perl
# Documentation at https://github.com/spencertipping/pushback.
#
# Copyright 2019 Spencer Tipping
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

use v5.14;
use strict;
use warnings;
```


### `select` catalyst
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


### Fibers and stream availability
OK, let's implement `pv` and talk about how it works. Structurally we have this:

```pl
my $catalyst    = pushback::select_catalyst->new;
my $measurement = pushback::reducer([0, 0], "AB", "+");

$catalyst->r(\*STDIN)
  ->into($catalyst->w(\*STDOUT))        # stdin -> stdout...
  ->map(sub { (length($_[0]), $dt) })   # ... numeric pairs
    ->into($measurement);               # ... send to measurement reducer

$catalyst->interval(1)                  # timed output (emit elapsed time)
  ->map(sub { @$measurement })          # ... return measurement output
  ->grep(sub { $_[1] > 2 })             # ... when two seconds have passed
  ->map(sub { sprintf(...) })           # ... format it
  ->into($catalyst->w(\*STDERR));       # ... and print to stderr

$catalyst->loop;                        # run while frontier exists
```

This results in two fibers:

```
stdin -> [stdout, map -> measurement]
interval -> map -> grep -> map -> stderr
```

That means we'll block and then run either fiber depending on what the scheduler
tell us: we might get `stdin->stdout` or we might get `interval->stderr`.

Fibers run automatically when (and while) all relevant endpoints are available.
Because a fiber may have many endpoints, we pack endpoint availability into a
bit vector per fiber. This results in skeletal logic like this:

```pl
while ($avail0 == 0x... [&& $avail1 == 0x... && ...])
{
  ...
  if (...) {                            # grep compiles to this
    ...
    $availN &= ~0x...;                  # write() calls may compile to this
    ...
  }
}
```

Catalysts call stream methods that run `$availN |= 0x...` to activate specific
endpoints in response to `select()` or other promises that things won't block.
Each such transition tries the `while` loop.

```perl
package pushback::compiler;
sub new
{
  my ($class, $name) = shift;
  my $gensym = 0;
  bless { parent  => undef,
          name    => $name,
          closure => {},
          gensym  => \$gensym,
          code    => [],
          end     => undef }, $class;
}

sub child
{
  my ($self, $name, $end) = @_;
  bless { parent  => $self,
          name    => "$$self{name} $name",
          closure => $$self{closure},
          gensym  => $$self{gensym},
          code    => [],
          end     => $end }, ref $self;
}

sub gensym { "g" . ${shift->{gensym}}++ }
sub code
{
  my $self = shift;
  my $code = shift;
  my %vars;
  ${$$self{closure}}{$vars{+shift} = $self->gensym} = shift while @_ >= 2;
  my $vars = join"|", keys %vars;
  push @{$$self{code}},
       keys(%vars) ? $code =~ s/\$($vars)/"\$" . ${$$self{scope}}{$1}/egr
                   : $code;
  $self;
}

sub mark
{
  my $self = shift;
  $self->code("#line 1 \"$$self{name} @_\"");
}

sub block
{
  my $self = shift;
  my $type = shift;
  $self->code("$type(")->code(@_)->code("){")
       ->child($name, "}");
}

sub if    { shift->block(if    => @_) }
sub while { shift->block(while => @_) }
sub end
{
  my $self = shift;
  $$self{parent}->code(join"\n", @{$$self{code}, $$self{end});
}

sub compile
{
  my $self    = shift;
  my @closure = sort keys %{$$self{closure}};
  my $setup   = sprintf "my (%s) = \@_;", join",", map "\$$_", @closure;
  my $code    = join"\n", "sub{", $setup, @{$$self{code}}, "}";
  my $sub     = eval $code;
  die "$@ compiling $code" if $@;
  $sub->(@{$$self{closure}}{@closure});
}
```


## Fiber-backed streams
In the world of fibers and catalysts, a stream is just a thin wrapper around
fiber state. It provides accessors to the fiber's availability flag vectors and
manages state-sharing across the JIT boundary.

From an API perspective, though, streams represent logical data sources (or
sinks), so let's talk about how that works for a minute.


### Stream example: `cat`
```pl
my $catalyst = pushback::select_catalyst->new;
my $stdin    = $catalyst->r(\*STDIN);
my $stdout   = $catalyst->w(\*STDOUT);
$stdin->into($stdout);                  # connect two streams
$catalyst->loop;                        # run all connections
```


### Stream example: "what time is it" TCP server
Pushback models TCP servers as streams of `($client, $paddr)` pairs, of which
the important information is the `$client` socket datastream. So we have a
stream of streams.

```pl
my $catalyst = pushback::select_catalyst->new;
my $server   = $catalyst->tcp_server(3000, '0.0.0.0');


```
