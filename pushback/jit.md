# JIT metaclass

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
sequential side effects.


## JIT calling convention

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
use Scalar::Util;
sub new
{
  my ($class, $package, $ivars) = @_;
  bless { package => $package,
          ivars   => [split/\s+/, $ivars] }, $class;
}
```


### Metaclass API

```pl
sub isa;                      # (@base_classes...) -> $class
sub def;                      # ($name => sub {...}) -> $class
sub defvar;                   # (@vars...) -> $class
sub defjit;                   # ($name => [@args], q{...}) -> $class
```

```perl
sub isa
{
  no strict 'refs';
  my $class = shift;
  push @{"$$class{package}\::ISA"}, @_;
  $class;
}

sub defvar
{
  my $class = shift;
  push @{$$class{ivars}}, map split(/\s+/), @_;
  $class;
}
```


### Normal method definition

Not all methods need to involve JIT. `->def` will create a regular non-JIT
function in the class. We don't interact with this from a JIT perspective, so we
can just drop it into the destination package and call it a day.

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

JIT methods are just like regular methods, except that they trace themselves
into a JIT compiler provided as the first argument. That is:

```pl
my $x = $obj->method(1, 2, 3);          # non-JIT
$obj->jitmethod($jit, 1, 2, 3);         # JIT
```

`defjit` manages the machinery of identifying and closing over instance
variables, which means we need to convert a string into a string-generating
function. Our resulting function takes `$self`, `\@arg_refs`, `\%refs`,
`\$gensym`, and `\%ref_gensyms`, updates `\%refs`, `\$gensym_id`, and
`\%ref_gensyms`, and returns a new code snippet that includes the gensyms it
bound.

...and because performance is something we care about (including for JIT
compilation itself), we JIT this function. Our JIT compiler is JIT compiled.

```perl
sub jit_op_arg
{
  my ($arg, $index) = @_;
  my $sigil = $arg =~ s/^\^// ? '$' : '$$';
  qq{
    \$ref = Scalar::Util::refaddr \\\$\$arg_refs[$index];
    \$\$refs{\$ref} = \\\$\$arg_refs[$index];
    push \@code, '$sigil' .
      (\$\$ref_gensyms{\$ref} //= \"_\" . ++\$\$gensym);
  };
}

sub jit_op_ivar
{
  my $name = shift;
  qq{
    \$ref = Scalar::Util::refaddr \\\$\$self{$name};
    \$\$refs{\$ref} = \\\$\$self{$name};
    push \@code, '\$\$' .
      (\$\$ref_gensyms{\$ref} //= \"_\" . ++\$\$gensym);
  };
}

sub defjit
{
  my ($self, $name, $args, $code) = @_;
  $args = [map split(/\s+/), ref $args ? @$args : $args];

  my $all_vars  = join"|", @{$$self{ivars}}, map +("\\^$_", $_), @$args;
  my $var_regex = qr/\$($all_vars)\b/;
  my %args      = map +(  $$args[$_]  => $_,
                        "^$$args[$_]" => $_), 0..$#$args;
  my @constants;
  my @fragments = (q[
  sub {
    my $constants = shift;
    sub {
      my ($self, $arg_refs, $refs, $gensym, $ref_gensyms) = @_;
      my $ref; ],
    "my \@code = q{#line 1 \"$$self{package}\::$name\"};");

  my $last = 0;
  while ($code =~ /$var_regex/g)
  {
    my $v = $1;
    push @constants, substr $code, $last, pos($code) - length($v) - 1 - $last;
    push @fragments, "push \@code, \$\$constants[$#constants];",
                     exists $args{$v} ? jit_op_arg($v, $args{$v})
                                      : jit_op_ivar($v);
    $last = pos $code;
  }

  push @constants, substr $code, $last;
  push @fragments, "push \@code, \$\$constants[$#constants];",
                   q[
      join"\n", @code;
    }
  }];

  my $fn = eval join"\n", "#line 1 \"$$self{package}\::$name'\"", @fragments;
  die "$@ compiling @fragments" if $@;
  my $method = &$fn(\@constants);
  {
    no strict 'refs';
    *{"$$self{package}\::$name"} = sub
    {
      my $self = shift;
      my $jit  = shift;
      die "$$self{package}\::$name: expected @$args but got " . scalar(@_)
        . " argument(s)" unless @_ == @$args;

      $jit->code(&$method($self, \@_,
                          $jit->refs, $jit->gensym_id, $jit->ref_gensyms));
    };
  }

  $self;
}
```


## JIT compiler

This is where we collect operations and references. It's surprisingly boring.

```perl
package pushback::jitcompiler;
use Scalar::Util qw/refaddr/;
use overload qw/ "" describe /;

sub new
{
  my $class = shift;
  bless { fragments   => [],
          gensym_id   => \(my $gensym = 0),
          debug       => 0,
          refs        => {},
          ref_gensyms => {} }, $class;
}

sub enable_debugging { $_[0]->{debug} = 1; shift }
sub debug
{
  my $self = shift;
  $$self{debug} ? $self->code(@_) : $self;
}

sub describe
{
  my $self = shift;
  my $code = join"\n", @{$$self{fragments}};
  my $vars = join", ", map "\$$$self{ref_gensyms}{$_} = \\${$$self{refs}{$_}}",
                       sort keys %{$$self{ref_gensyms}};
  "jit( $vars ) {\n$code\n}";
}

sub gensym_id   { shift->{gensym_id} }
sub refs        { shift->{refs} }
sub ref_gensyms { shift->{ref_gensyms} }

sub code
{
  my $self = shift;
  if (@_ == 1) { push @{$$self{fragments}}, shift }
  else
  {
    # Slow path: bind named references and rewrite variables.
    my $code = shift;
    my %rewrites;
    while (@_)
    {
      my $name =  shift;
      my $ref  = \shift;
      ${$$self{refs}}{refaddr $ref} = $ref;
      $rewrites{$name} =
        ${$$self{ref_gensyms}}{refaddr $ref} //= '_' . ++${$$self{gensym_id}};
    }
    my $subst = join"|", keys %rewrites;
    push @{$$self{fragments}}, $code =~ s/\$($subst)\b/"\$\$$rewrites{$1}"/egr;
  }
  $self;
}

sub compile
{
  my $self        = shift;
  my @gensyms     = sort keys %{$$self{ref_gensyms}};
  my $gensym_vars = sprintf "my (%s) = \@_;",
                    join",", map "\$$_", @{$$self{ref_gensyms}}{@gensyms};
  my $code        = join"\n", "sub{", $gensym_vars, @{$$self{fragments}}, "}";
  my $fn          = eval "use strict;use warnings;$code";
  die "$@ compiling $code" if $@;
  &$fn(@{$$self{refs}}{@gensyms});
}
```


## An impenetrable excuse for an example

```bash
$ perl -I. -Mpushback -e '
    use strict;
    use warnings;

    pushback::jitclass->new("foo", "x y")
      ->def(normal => sub { shift->{x} })
      ->defjit(inc_x => "by", q{ $x += $by; });

    my $foo_inst = bless { x => 0, y => 0 }, "foo";
    print "initial x: " . $foo_inst->normal . "\n";

    my $jit = pushback::jitcompiler->new;
    $foo_inst->inc_x($jit, 1);
    $foo_inst->inc_x($jit, 2);
    $jit->compile;
    print "post-jit x: " . $foo_inst->normal . "\n";
  '
initial x: 0
post-jit x: 3
```
