# Router: a declarative way to write spanners
`pushback::router` is a metaclass: instances of `router` create instances of
`spanner` and create constructors in `pushback::stream`.

```perl
package pushback::router;
sub new             # (name, qw/ point1 point2 ... pointN /) -> $router
{
  # new() is both a class and an instance method; branch off up front if it's
  # being called on an instance.
  my $class = shift;
  return $class->instantiate(@_) if ref $class;

  my $name = shift;
  bless { name        => $name,
          prefix      => "pushback::router::",
          points      => [@_],      # [$pointname, $pointname, ...]
          state       => {},        # var => $init_fn
          methods     => {},        # name => $fn
          streams     => {},        # name => $pointname
          streamctors => {},        # name => [$in_flowname, $init_fn]
          admittances => {},        # path => $calculator
          flows       => {} },      # path => $code
        $class;
}

sub has_point { grep $_ eq $_[1], @{$_[0]->{points}} }
sub prefix
{
  my ($self, $prefix) = @_;
  $$self{prefix} = $prefix;
  $self;
}
```


## API
```perl
sub new;            # (...) -> $spanner

sub state;          # ($name => $init, ...) -> $self!
sub flow;           # ($path, $admittance, $onflow) -> $self!
sub def;            # ($name => $method, ...) -> $self!

sub streamctor;     # ($name, $in_flowpoint[, $init_fn]) -> $self!
sub stream;         # ($name, $path) -> $self!
```


## State definition
State is just instance variables, but routers take care of mapping them into all
JIT contexts for you. This allows you to write code as strings and have a common
lexical reference frame.

```perl
sub state
{
  my $self = shift;
  %{$$self{state}} = (%{$$self{state}}, @_);
  die "'$_' is reserved for JIT interfacing and can't be bound as state"
    for grep /^(?:flow|n|data|flag)$/, keys %{$$self{state}};
  $self;
}

sub def
{
  my $self = shift;
  %{$$self{methods}} = (%{$$self{methods}}, @_);
  $self;
}
```


## Stream interfacing
A thin layer to make it possible to create the resulting spanner using the
`pushback::stream` API.

```perl
sub streamctor
{
  my ($self, $name, $inpoint, $init_fn) = @_;
  die "$self doesn't define $inpoint" unless $self->has_point($inpoint);

  $$self{streamctors}{$name} = [$inpoint, $init_fn];
  *{"pushback::stream::$name"} = sub { $self->from_stream($name, @_) };
  $self;
}

sub stream
{
  my ($self, $name, $point) = @_;
  die "$self doesn't define $point" unless $self->has_point($point);

  $$self{streams}{$name} = $point;
  $self;
}
```


## Paths and flow routing
If you're writing a cut-through component like `map`, you'll quickly run into
some redundancy in that spanners allow flow requests to be either in or out, and
they can be to either flow point. More specifically, if you have two endpoints
`source` and `dest` then there are four possible flow requests:

```
source, positive flow (inbound data) -- we want this
source, negative flow (outbound data) -- we block this
dest, positive flow -- same as source-negative
dest, negative flow -- same as source-positive
```

Routers don't fundamentally change this, but they do provide a way to handle
multiple cases at once by describing flow in terms of paths.

```perl
sub is_path { shift =~ /^[<>](.*)/ }
sub parse_path
{
  local $_ = shift;
  ($_, s/^>// ? 1 : s/^<// ? -1 : die "$_ doesn't look like a path");
}

sub flow
{
  my $self = shift;
  my $path = shift;
  my ($point, $polarity) = parse_path $path;
  die "$self doesn't have a flow point corresponding to $path"
    unless $self->has_point($point);

  if (@_ == 2)
  {
    $$self{admittances}{$path} = shift;
    $$self{flows}{$path}       = shift;
  }
  else
  {
    die "$self\->flow: expected (path, admittance, flow) "
      . "but got ($path, " . join(", ", @_) . ")";
  }

  $self;
}
```


## Class compilation
OK, this is where we get to use the data we built in the methods above. First
let's talk about how things get translated.

- `points` are created and/or taken from `->from_stream`
- `state` becomes the toplevel object
- `methods` are emitted into the destination package
- `streams` become methods that return individual points
- `streamctors` are emitted into `pushback::stream` as constructors
- `flows`, `admittances`, and `path_aliases` are used to create `jit_admittance`
  and `jit_flow`

Here's a quick sketch of the API we'll use to compile stuff.

```perl
sub package;                # () -> $our_new_class
sub package_bind;           # ($name => $val, ...) -> $self

sub gen_ctor;               # () -> $class_new_fn
sub gen_stream_ctor;        # () -> $stream_ctor_fn
sub gen_jit_flow;           # () -> $jit_flow_fn
sub gen_jit_admittance;     # () -> $jit_admittance_fn
```


### Boring stuff
```perl
sub package_name { $_[0]->{prefix} . $_[0]->{name} }
sub package
{
  my $self = shift;
  my $package = $self->package_name;
  push @{"$package\::ISA"}, 'pushback::spanner'
    unless grep /^pushback::spanner$/, @{"$package\::ISA"};

  $self->package_bind(%{$$self{methods}},
                      new            => $self->gen_ctor,
                      from_stream    => $self->gen_stream_ctor,
                      jit_flow       => $self->gen_jit_flow,
                      jit_admittance => $self->gen_jit_admittance);
}

sub package_bind
{
  my $self = shift;
  my $destination_package = $self->package_name;
  while (@_)
  {
    my $name = shift;
    my $val  = shift;
    *{"$destination_package\::$name"} = $val;
  }
  $self;
}
```


### Admittance JIT
```perl
sub jit_path_admittance
{
  my $router  = shift;
  my $spanner = shift;
  my $path    = shift;
  my $jit     = shift;
  my $flag    = \shift;
  my $n       = \shift;
  my $flow    = \shift;

  return $jit->code('$flow = 0;', flow => $$flow)
    unless exists $$router{admittances}{$path};

  my $a = $$router{admittances}{$path};
  return $router->jit_path_admittance($spanner, $a, $jit, $$flag, $$n, $$flow)
    if is_path $a;

  pushback::admittance->from($a, $spanner)->jit($jit, $$flag, $$n, $$flow);
}

sub gen_jit_admittance
{
  my $router = shift;
  sub {
    my $self  = shift;
    my $point = shift;
    my $jit   = shift;
    my $flag  = \shift;
    my $n     = \shift;
    my $flow  = \shift;

    my $point_name = $$self{point_lookup}{$point}
      // die "$self isn't connected to $point";

    $jit->code('if ($n > 0) {', n => $$n);
    $router->jit_path_admittance(
      $self, ">$point_name", $jit, $$flag, $$n, $$flow);
    $jit->code('} else {');
    $router->jit_path_admittance(
      $self, "<$point_name", $jit, $$flag, $$n, $$flow);
    $jit->code('}');
  };
}
```
