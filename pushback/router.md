# Router: a declarative way to write spanners
`pushback::router` is a metaclass: instances of `router` create instances of
`spanner` and create constructors in `pushback::stream`.

```perl
package pushback::router;
use overload qw/ "" name /;

sub new             # (name, qw/ point1 point2 ... pointN /) -> $router
{
  # new() is both a class and an instance method; branch off up front if it's
  # being called on an instance.
  my $class = shift;
  return $class->instantiate(@_) if ref $class;

  my $name = shift;
  bless { name        => $name,
          init        => undef,
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
sub name      { "router $_[0]->{name}" }
```


## API
```perl
sub new;            # (...) -> $spanner

sub init;           # ($fn) -> $self!
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
sub const { my $v = shift; sub { $v } }
sub state
{
  my $self = shift;
  my %s    = @_;

  die "'$_' is reserved for JIT interfacing and can't be bound as state"
    for grep /^(?:flow|n|data|flag|offset|self)$/,
        keys %s;

  die "'$_' is used by spanners and can't be bound as state"
    for grep /^(?:points|point_lookup|flow_fns|admittance_fns)$/,
        keys %s;

  die "$_ will be aliased across instances, creating coupled state; "
    . "if you really want to do this, wrap it in a closure before passing it "
    . "to ->state()"
    for grep ref() && ref() != 'CODE',
        values %s;

  %{$$self{state}} = (
    %{$$self{state}},
    map +($_ => ref($s{$_}) eq 'CODE' ? $s{$_} : const $s{$_}), keys %s);

  $self;
}

sub def
{
  my $self = shift;
  %{$$self{methods}} = (%{$$self{methods}}, @_);
  $self;
}

sub init
{
  my $self = shift;
  $$self{init} = shift;
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
  $self;
}

sub stream
{
  my ($self, $name, $point) = @_;
  $point //= $name;
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
sub instantiate
{
  my $pkg = shift->package_name;
  $pkg->new(@_);
}

sub package_name { shift->{name} }
sub package
{
  no strict 'refs';
  my $self = shift;
  my $package = $self->package_name;
  push @{"$package\::ISA"}, 'pushback::spanner'
    unless grep /^pushback::spanner$/, @{"$package\::ISA"};

  $self->package_bind(%{$$self{methods}},
                      new            => $self->gen_ctor,
                      from_stream    => $self->gen_stream_ctor,
                      jit_flow       => $self->gen_jit_flow,
                      jit_admittance => $self->gen_jit_admittance);

  for my $k (keys %{$$self{streamctors}})
  {
    ${pushback::stream::}{$k} = sub { $package->from_stream($k, @_) };
  }

  for my $k (keys %{$$self{streams}})
  {
    $self->package_bind($k => sub { shift->point($k) });
  }

  $package;
}

sub package_bind
{
  no strict 'refs';
  my $self = shift;
  my $destination_package = $self->package_name;
  while (@_)
  {
    my $name = shift;
    *{"$destination_package\::$name"} = shift;
  }
  $self;
}

sub gen_ctor
{
  my $router = shift;
  my $id = 0;
  sub {
    my $class  = shift;
    my $self   = $class->connected_to(
                   map +($_ => pushback::point->new("$class\::$_\[$id]")),
                       @{$$router{points}});
    $$self{$_} = $$router{state}{$_}->($self) for keys %{$$router{state}};
    $$router{init}->($self, @_) if defined $$router{init};
    $self;
  };
}

sub gen_stream_ctor
{
  my $router = shift;
  sub {
    my $instream          = shift;
    my $ctorname          = shift;
    my ($point, $init_fn) = @{$$router{streamctors}{$ctorname}};
    my $self              = $router->instantiate($ctorname, @_);
    $self->point($point)->copy($instream);
    $init_fn->($self, $instream, @_) if defined $init_fn;
    $self;
  };
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

  my $a = $$router{admittances}{$path}
       // return $jit->code('$flow = 0;', flow => $$flow);

  return pushback::admittance->from($spanner->point(substr $a, 1), $spanner)
                             ->jit($jit, $$flag, $$n, $$flow)
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
    $jit->code('} else { $n = -$n;', n => $$n);
    $router->jit_path_admittance(
      $self, "<$point_name", $jit, $$flag, $$n, $$flow);
    $jit->code('}');
  };
}
```


### Flow JIT
```perl
sub jit_path_flow
{
  my $router  = shift;
  my $spanner = shift;
  my $path    = shift;
  my $jit     = shift;
  my $flag    = \shift;
  my $offset  = \shift;
  my $n       = \shift;
  my $data    = \shift;

  my $f = $$router{flows}{$path} // return $jit->code('$n = 0;', n => $$n);

  # Compose JITs if we have an array. This is useful for doing a transform and
  # then delegating to a point flow.
  if (ref $f eq 'ARRAY')
  {
    $router->jit_path_flow($spanner, $_, $jit, $$flag, $$offset, $$n, $$data)
      for @$f;
    $jit;
  }
  else
  {
    my $r = ref $f;
    return &$f($spanner, $jit, $$flag, $$offset, $$n, $$data) if $r eq 'CODE';
    return $spanner->point($f)
                   ->jit_flow($spanner, $jit, $$flag, $$offset, $$n, $$data)
      if !$r && exists $$spanner{points}{$f};

    return $router->jit_path_flow(
      $spanner, $f, $jit, $$flag, $$offset, $$n, $$data)
      if is_path $f;

    return $jit->code($f, %$spanner,
                          self   => $spanner,
                          flag   => $$flag,
                          offset => $$offset,
                          n      => $$n,
                          data   => $$data)
      unless $r;

    die "$router: unrecognized path flow spec $f for $path";
  }
}

sub gen_jit_flow
{
  my $router = shift;
  sub {
    my $self   = shift;
    my $point  = shift;
    my $jit    = shift;
    my $flag   = \shift;
    my $offset = \shift;
    my $n      = \shift;
    my $data   = \shift;

    my $point_name = $$self{point_lookup}{$point}
      // die "$self isn't connected to $point";

    $jit->code('if ($n > 0) {', n => $$n);
    $router->jit_path_flow(
      $self, ">$point_name", $jit, $$flag, $$offset, $$n, $$data);
    $jit->code('} else { $n = -$n;', n => $$n);
    $router->jit_path_flow(
      $self, "<$point_name", $jit, $$flag, $$offset, $$n, $$data);
    $jit->code('}');
  };
}
```
