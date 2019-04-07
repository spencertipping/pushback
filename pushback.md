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


## Stream objects
A stream is a series of events terminated either by "successful" EOF or
"unsuccessful" error. Streams are connected directly to each other rather than
using callbacks, although an adapter exists to invoke callbacks on stream events
(in that case, backpressure comes from CPU time spent in the callbacks).

Streams can be arranged into graphs that describe IO dependencies. For example,
suppose you're implementing the UNIX `join` command; the read-side blocks on the
intersection of the two inputs. Pushback would model this as two input IO
resources (each with an fd) joined with an "intersect" stream.


### IO negotiation
In principle this is trivial: each stream can tell you whether it's readable and
writable at any given point in time. Nothing to it.

...except, of course, that for IO resources each of those questions involves a
round-trip to the kernel. That gets really slow if we have a bunch of things
going on. We should batch things up into `select()` bitvectors when we can.

...except that you might not want to use `select()`. First, not every
stream-of-stuff backs into an IO resource at all; what if you have a UNIX shared
memory segment or a stream of periodic events generated from a timer? Second,
`select()` itself isn't always the right choice for nonblocking IO; on Linux
`epoll` can be faster, but it's not portable.

So a stream's readability and writability is sometimes discoverable, sometimes
updated asynchronously, and may involve a conversation about one or more FDs.


### Edge triggers, IO actions, and sharing
node.js uses read-side edge triggering and assumes the destination is always
writable. Pushback doesn't have the always-writable level state, so edge
triggers need to be bidirectional. IO will happen when a readable edge trigger
meets a writable level state or vice versa, and that in turn means that
FD-backed streams keep track of previous `select()` results.

...but let's complicate matters a little by making a topology with a join point:

```
input_1 --> |
            | join_union --> output_1
input_2 --> |
```

If `output_1` broadcasts writability leftwards, `join_union` needs to pass that
information along to its inputs. But that writability isn't a firm promise; if,
for instance, both inputs consider their output to be writable and `input_1`
then writes something, `input_2` can't jump on the bandwagon and also try to
write stuff. It needs to wait for another writability event. And that means we
need another edge trigger, "I'm not writable anymore."


### Catalyst streams
Nonblocking IO doesn't mean "nobody blocks"; if it did, any nonblocking program
would consume 100% CPU. Instead, it means "no one IO thing blocks other IO
things" -- or to put it differently, a single thread multiplexes IO with minimal
latency.

The reason I bring this up is that nonblocking IO still involves blocking, just
on a `select` or `epoll` output instead of a single file descriptor. If we think
about it this way, we don't really need a whole framework to implement
nonblocking IO; we just need an action scheduler. Instead of _doing_ things, our
scheduler _produces_ things to do: it's a stream of functions.

So, all we need to do is create a single `select_catalyst`, ask it for a bunch
of individual FD streams, hook them up, and then `$catalyst->read->() while 1`,
right?

Almost. It's really tempting to run with what we have but we can simplify a lot,
handle some edge cases, and improve performance if we retroactively admit to
some dishonesty.


## Flow control
Until now I've been describing streams as objects that handle data; that's how
we think of them, after all. But there's no reason they should work this way --
and a number of reasons they really shouldn't. For one thing, if streams are a
polymorphic abstraction then we're doing a polymorphic method call for every IO
event; that's not going to give us fast code. Streams-as-objects also don't make
it efficient to propagate read/write availability; we're walking the object
graph for every state change, and a lot of intermediate objects are just
cut-through elements that don't have independent state.

The good news is that the real world is simpler than the world of stream
objects. In stream terms we might do something like
`input -> map(fn1) -> map(fn2) -> output`, which involves a bunch of negotiation
before any data can move. If `input` and `output` are the only availability
variables, though, then the fundamental logic is really simple:

```pl
whenever ($input_readable && $output_writable)
{
  sysread $input_fd, my $data;
  $data = $fn1->($data);
  $data = $fn2->($data);
  syswrite $output_fd, $data;
}
```

All we have to do is reduce our stream graph to a series of these `whenever`
blocks and find a way to schedule them.


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

Catalysts are readable and writable iff the frontier is nonempty.

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
  my @code;
  bless { parent  => undef,
          name    => $name,
          scope   => {},
          closure => {},
          gensym  => \$gensym,
          code    => \@code,
          end     => undef }, $class;
}

sub child
{
  my ($self, $name, $end) = @_;
  bless { parent  => $self,
          name    => "$$self{name} $name",
          scope   => $$self{scope},
          closure => $$self{closure},
          gensym  => $$self{gensym},
          code    => $$self{code},
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
  my ($self, $type, $name) = @_;
  $self->code("$type(")->code(@_)->code("){")
       ->child($name // $type,
               "}");
}

sub if    { shift->block(if => @_) }
sub while { shift->block(while => @_) }
sub end
{
  my $self = shift;
  $self->code($$self{end});
  $$self{parent};
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
