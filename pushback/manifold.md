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
```


## Manifold metaclass
...is a child of the [JIT metaclass](jit.md).

```perl
package pushback::manifoldclass;
push our @ISA, 'pushback::jitclass';
sub new
{
  pushback::jitclass::new(@_)->isa('pushback::manifold');
}
```
