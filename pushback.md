# Pushback
As mentioned in the README, pushback is a control flow driver based on data
mobility. The basic premise is that you have a series of objects connected
together by data paths and those objects do things when data moves through them.

Perl is pathologically slow, so this type of abstraction isn't practical to use
for general application development. Pushback works around this by flattening
all of its logic using JIT (into Perl code). Objects exist as data accessors,
but flow paths are all monomorphically specialized to minimize interpreter
overhead. The result is that creating and modifying object connections is
somewhat expensive, but data movement is comparable to optimal hand-written
code.


## License/header
```text
# Pushback: flow control as control flow
# Pushback is a fully negotiated IO/control multiplexer for Perl. See
# https://github.com/spencertipping/pushback for details.

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


## Internals: design patterns
- [JIT metaclass and compiler](pushback/jit.md)
- [Flowable projection](pushback/flowable.md)
- [Object address sets](pushback/objectset.md)
- [Process metaclass](pushback/process.md)


## Footer
```text
1;
```
