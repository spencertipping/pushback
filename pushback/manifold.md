# Manifolds

Manifolds present two APIs.

When you're building them, they consume and create [surfaces](surface.md) to
manage their connections. This makes it possible to construct nontrivially
complex topologies without manually connecting a bunch of loose ends. If you
haven't read [surface.md](surface.md) yet, you should probably take a quick look
before continuing.

Once they're built, manifolds create [JIT processes](jit.md) to negotiate and
then flow [data volumes](volume.md). Negotiation involves backpressure and
admittance; see [volume.md](volume.md) for the full story.


## Generality and type variance

Manifolds, surfaces, and volumes comprise three degrees of abstraction
generality, only some of which are covariant. Here's the structure of that
interaction.

First, surfaces and volumes don't interact because they involve two disjoint
modes of manifolds. Surfaces can describe the types of volumes their manifolds
will carry, but they won't work with any volume objects directly.

**TODO:** explain this better and more concisely
