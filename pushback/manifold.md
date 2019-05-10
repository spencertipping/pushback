# Manifolds
Manifolds move data and negotiate data movement.

When you're building them, they consume and create [surfaces](surface.md) to
manage their connections. This makes it possible to construct nontrivially
complex topologies without manually connecting a bunch of loose ends. If you
haven't read [surface.md](surface.md) yet, you should probably take a quick look
before continuing.

Once they're built, manifolds create [JIT processes](jit.md) to negotiate and
then flow [data volumes](volume.md). Negotiation involves backpressure and
admittance; see [volume.md](volume.md) for the full story.


## Type variance
Surfaces and volumes don't interact directly. All covariance relationships are
between surfaces/manifolds and volumes/manifolds.

Manifolds typically consume a generic surface base class and produce a child of
that class. Most of the time the base is very general, e.g. "a stdin/stdout
surface". Specializations dictate how that idea translates to any particular
manifold.

Some manifolds are designed to work with a specific type of data volume (for
instance, "read from a file" produces strings), but many are fully generic,
requiring only that the volume offer some basic algebraic structure like
supporting a min-flow operation. These algebraic contracts are defined as base
classes and volumes opt into them.


## Quick example: `map($fn)`
`map` is simple because it has a stdio surface and three ports, `in`, `out`, and
`err`. Flow capacity isn't quite 1:1 between `in` and `out` because `$fn` might
produce an error; what we have is `in>out` gated on `err` if `err` is connected,
passthrough if it isn't.

Before I get into the details, let's talk about how we describe flow paths.

`in>out` is simple enough: move data from `in` and into `out`. Data presumably
wouldn't flow in reverse because `>` specifies direction.

If we want to incorporate `err`, we need to capture the idea that an input can
become either an output or an error. We can do this by intersecting `out` and
`err`: `in>(out^err)`. Our grammar flow grammar doesn't support parentheses, nor
does it need to: we're describing a single path along which data moves. So we
can just write `in>out^err` and `>` will take lowest precedence.

```pl
pushback::manifoldclass
  ->new('pushback::manifold::map', 'fn')  # no prefix on 'fn' == ctor arg
  ->defsurface('pushback::stdio')         # adds 'in', 'out', 'err' monoports
  ->defflow('in>out^err', sub
    {
      # This function defines the actual flow logic. '(in>out)^err' describes
      # the admittance calculations for us.
      my ($self, $jit, $volume) = @_;
    })
```


## Manifold base class
```perl
package pushback::manifold;
use overload qw/ "" describe /;

sub new
{
  my $class = shift;
  bless { links => {} }, $class;
}

sub describe;       # ($self) -> string
sub connection;     # ($self, $portname) -> ([$manifold, $port], ...)
```


## Manifold metaclass
...is a child of the [JIT metaclass](jit.md). Here's the API:

```pl
sub defmonoport;    # ($self, $name) -> $self'
sub defmultiport;   # ($self, $name) -> $self'
sub defsurface;     # ($self, $surface) -> $self'
```

```perl
package pushback::manifoldclass;
push our @ISA, 'pushback::jitclass';
sub new
{
  pushback::jitclass::new(@_)->isa('pushback::manifold');
}
```
