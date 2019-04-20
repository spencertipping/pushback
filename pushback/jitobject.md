# JIT-flattening object
The idea here is that we have normal OOP-style objects, but we want to
specialize some call paths between them to eliminate both Perl's OOP overhead
and its function calling overhead. Perl gives us a lot of latitude because we
can alias the scalars that comprise an object's state. All we need to do is
define a calling convention for JIT specialization.

This calling convention is implemented in two parts. First we have a metaclass
that defines JIT-specializable methods for objects; this precompiles
code-as-text and handles the mechanics of aliasing object state into compiled
outputs.

Second, we introduce a call tracer that follows the topology of connected
objects and inlines their logic fragments. Because we're inlining subroutines we
address all data as mutable lvalues. Function composition is flattened into
sequential side effects. The call tracer also manages cross-object invalidation;
I'll explain this in more detail below.


## JIT metaclass
Before I get into how the metaclass works, let's talk about what a JIT object
does. A normal object uses Perl's standard calling convention: values come in as
`@_` and are returned the way you'd expect. No surprises there. A JIT object
doesn't work that way; its calling convention is strictly less flexible.

As a quick example, let's suppose we want to JIT-flatten stream transformers so
we can efficiently do things like `$xs->map('$_ ** 2')->reduce('$r += $_')`. The
JIT output would be something like this:

```pl
sub run
{
  my $xs = shift;             # adapt to default calling convention
  my ($r1, $r2);
  for (@$xs)                  # this is all JIT inlined
  {
    $r1 = $_ ** 2;
    $r2 += $r1;
  }
  $r2;                        # ...and back to standard
}
```

The interaction between `$xs`, `->map`, and `->reduce` is linear and involves
building up a series of side effects within a JIT object. Instead of returning a
result, each side effect can bind a new local and define that as its return
value; future side effects will default to using it as input.

Object state can also be flattened into local variable bindings, but this is
where things start to get interesting. `$$self{x}` can't be mapped directly to
`$x` in our generated code because multiple objects might have a field called
`x`. But `$x` can't even be mapped to a single gensym because any given JIT
trace might refer to multiple instances of the same object. Gensym allocation
needs to be 1:1 with reference closure, and for this to be remotely efficient
we'll need an intermediate representation for code-as-text that allows us to
drop new variables into position without reparsing everything.

```perl
package pushback::jitclass;
sub new
{
  my ($class, $package, @ivars) = @_;
  bless { package => $package,
          methods => {},
          ivars   => \@ivars }, $class;
}
```


### Metaclass API
```perl
sub def;                      # ($name => sub {...}) -> $class
sub defjit;                   # ([@args], [@ret], $name => q{...}) -> $class
```


### Normal method definition
Not all methods need to involve JIT. `->def` will create a regular non-JIT
function in the class.

```perl
sub def
{
  no strict 'refs';
  my $class = shift;
  while (@_)
  {
    my $name = shift;
    *{"$$class{package}\::$name"} = shift;
  }
  $class;
}
```


### JIT method definition
Technically all we need to do here is parse the code into something we can
easily drop references into, but this involves some subtlety.

```perl
sub defjit
{
}
```


## JIT compiler
This is where we collect operations and references.
