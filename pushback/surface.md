# Manifold surfaces

Surfaces are the API you use to fuse manifolds. A surface works like a calling
convention; for example, `cat file | grep foo | sort | wc -l` involves joining
four manifolds using the stdin/stdout pipe convention. Pushback would represent
`|` as a method call against the surface provided by each manifold.


## Surface base class

```perl
package pushback::surface;
use overload qw/ "" describe /;

sub describe;   # ($self) -> string
sub manifold;   # ($self) -> $manifold
```


## `io` surface base

Any surface that supports simple composition should have this as a base class.
The operative method is `|`, which takes and fuses a manifold.

```perl
package pushback::io_surface;
push our @ISA, 'pushback::surface';
use overload qw/ | fuse /;

sub fuse;       # ($self, $manifold) -> $surface
```
