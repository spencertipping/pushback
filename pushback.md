# Pushback: evented IO for Perl, but with backpressure
```perl
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

