# Router: a declarative way to write spanners
Routers are spanner compilers.

```perl
package pushback::router;
sub new             # (name, qw/ point1 point2 ... pointN /) -> $router
{
  # new() is both a class and an instance method; branch off up front if it's
  # being called on an instance.
  my $class = shift;
  return $class->instantiate(@_) if ref $class;

  my $name = shift;
  bless { name         => $name,
          points       => [@_],     # [$pointname, $pointname, ...]
          state        => {},       # var => $init_fn
          methods      => {},       # name => $fn
          streams      => {},       # name => $pointname
          streamctors  => {},       # name => [$in_flowname, $init_fn]
          path_aliases => {},       # path => $path
          admittances  => {},       # path => $calculator
          flows        => {} },     # path => $code
        $class;
}

sub has_point { grep $_ eq $_[1], @{$_[0]->{points}} }
```


## API
`pushback::router` is a metaclass: instances of `router` create instances of
`spanner`.

```perl
sub new;            # (...) -> $spanner

sub state;          # ($name => $init, ...) -> $self!
sub flow;           #   ($path, $admittance, $onflow) -> $self!
                    # | ($path, $path) -> $self!
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

  # Two possibilities here. If we have two more arguments, we're defining a path
  # in terms of admittance and flow; otherwise we're creating a path alias.
  if (@_ == 2)
  {
    $$self{admittances}{$path} = shift;
    $$self{flows}{$path}       = shift;
  }
  elsif (@_ == 1)
  {
    my $alias = shift;
    my ($apoint, $apol) = parse_path $alias;
    die "alias $path -> $alias refers to a nonexistent point $apoint"
      unless $self->has_point($apoint);
    $$self{path_aliases}{$path} = $alias;
  }
  else
  {
    die "$self\->flow: expected (path, path) or (path, admittance, flow) "
      . "but got ($path, " . join(", ", @_) . ")";
  }

  $self;
}
```
