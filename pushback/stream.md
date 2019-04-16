# Stream metaphor
Flow points are like streams, so let's write a class for monkey-patched
extension methods that applies to all flow points. The goal is to create an API
that's easier to use than manually creating flow points and spanners.

```perl
package pushback::stream;
use overload qw/ >> into /;
push @pushback::point::ISA, 'pushback::stream';
```

Stream methods are created by specific types of spanners.
