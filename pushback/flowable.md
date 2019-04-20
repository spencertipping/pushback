# Flowable projection
If you're doing IO on byte arrays, you'll usually have signatures like this:

```c
ssize_t read(fd,  void *buf, size_t n);
ssize_t write(fd, void *buf, size_t n);
```

In Perl we'd say `read(fd, $buf, $n, $offset)` since we can't just make a
pointer to an arbitrary location. If we want to stream data around, we just pass
`\$buf, $n, $offset` to the JIT context (`fd` is provided by the receiver). Easy
enough, right?

Almost. The problem is that all of this stuff about byte arrays is only one way
to do IO. Pushback streams don't need to have anything to do with byte arrays;
they could be arrays of any sort, references, side effects, anything really. And
that complicates our life a bit if we want to use a standard interface to deal
with data flow.


## Negotiation and admittance
All streams in pushback are negotiated, which means moving data through them is
a two-step process. I'll outline the equivalent process in C-style IO before
talking about how pushback negotiation works:

```c
// Start with some amount of data we want to move...
stream *s = ...;
void *buf = ...;
size_t n  = 1048576;

// Ordinarily we might write() it here, but this is a negotiated-IO world so
// let's get the actual amount of data we can move right now. This is the stream
// admittance, which may be larger than n.
size_t admitted = figure_out_how_much_we_can_move(s, buf, n);
size_t to_move  = min(admitted, n);

// Now move just that much if we still have any capacity to move things.
if (to_move)
{
  size_t moved = write_to_somewhere(s, buf, to_move);

  // We don't get short writes because everything was negotiated up front. Any
  // truncation indicates an IO or execution error.
  if (moved != to_move) perror(...);
}
```

Pushback works exactly the same way, except that it generalizes
`buf`/`n`/`size_t` with flowables to accommodate Perl's sometimes-nonlinear data
structures.


## Flowable algebra and API
We don't need to know very much about a dataflow to negotiate it. There are
three logical operations involved:

1. `$flowable->intersect($flowable)`: take the minimum admittance
2. `$flowable->union($flowable)`: take the maximum admittance
3. `if ($flowable > 0) { ... }`: condition on nonzero admittance
4. `$flowable->zero`: set admittance to zero to disable dataflow

Anything else is up to type-specific streams.


## Byte array flowable
```perl
pushback::jitclass->new('pushback::flowable::bytes', qw/ data offset n /)
  ->def(new =>
    sub {
      my $class = shift;
      bless { data   => @_ ? \shift : \(my $buf = ""),
              offset => 0,
              n      => 0 }, $class;
    })

  ->defjit(intersect => ['$fn'], '$n = $fn if $fn < $n;')
  ->defjit(union     => ['$fn'], '$n = $fn if $fn > $n;')
  ->defjit(zero      => [], '$n = 0;')
  ->defjit(if_start  => [], 'if ($n) {')
  ->defjit(if_end    => [], '}')
  ->def(if => sub
    {
      my ($self, $jit, $fn) = @_;
      $self->if_start($jit);
      &$fn($jit, $self);
      $self->if_end($jit);
      $self;
    });
```
