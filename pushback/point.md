# Flow point
Flow points manage JIT aggregation across multiple paths. If a flow point has
exactly two paths then it becomes monomorphic and is erased; otherwise it
compiles an intermediate function to provide one flow result per invocation. (We
do this not because we have to, but because otherwise we could have an
exponential fanout of inlined logic.)


## Flow negotiation and impedance
Any data supplier needs to be able to sense impedance, which in this context
translates roughly to "an offer of (or request for) size N will be serviced by a
flow of size F." |F| can be either larger or smaller than |N|, although the two
won't be of opposite polarity.

Impedance queries are a way to sample points on the [I-V
curve](https://en.wikipedia.org/wiki/Current%E2%80%93voltage_characteristic) of
a flow point. We could insist that spanners figure it out reactively, but that
doesn't work well with cut-through transformations. We'd end up repeating a lot
of work unless we had a destination buffer, at which point we'd have an
unbounded-inflow problem.


## High-level interface
```perl
package pushback::point;
use overload qw/ "" id == equals /;
use Scalar::Util qw/refaddr/;

sub new;                # pushback::point->new($id // undef)
sub id;                 # () -> $id_string
sub is_static;          # () -> $static?
sub is_monomorphic;     # () -> $monomorphic?
sub connect;            # ($spanner) -> $self!
sub disconnect;         # ($spanner) -> $self!

sub invalidate_jit;     # () -> $self
sub jit_impedance;      # ($spanner, $jit, $flag, $n, $flow) -> $jit!
sub jit_flow;           # ($spanner, $jit, $flag, $n, $data) -> $jit!
```


## Implementation
```perl
our $point_id = 0;
sub new
{
  my ($class, $id) = @_;
  bless { id        => $id // "_" . $point_id++,
          spanners  => [],
          jit_flags => {} }, $class;
}

sub equals         { refaddr shift == refaddr shift }
sub id             { shift->{id} }
sub is_static      { @{shift->{spanners}} == 1 }
sub is_monomorphic { @{shift->{spanners}} == 2 }

sub connect
{
  my ($self, $s) = @_;
  die "$s is already connected to $self"
    if grep refaddr($s) == refaddr($_), @{$$self{spanners}};

  $self->invalidate_jit;
  push @{$$self{spanners}}, $s;
  $self;
}

sub disconnect
{
  my ($self, $s) = @_;
  my $ss = $$self{spanners};
  my ($i) = grep refaddr($$ss[$_]) == refaddr($s), 0..$#$ss
    or die "$s isn't connected to $self";

  $self->invalidate_jit;
  splice @{$$self{spanners}}, $i, 1;
  $self;
}
```


## JIT interface
```perl
sub invalidate_jit
{
  my $self = shift;
  $$_ = 1 for values %{$$self{jit_flags}};
  %{$$self{jit_flags}} = ();
  $self;
}

sub jit_impedance
{
  my $self = shift;
  my $s    = shift;
  my $jit  = shift;
  my $flag = \shift;
  my $n    = \shift;
  my $flow = \shift;

  # TODO: weaken this reference
  $$self{jit_flags}{refaddr $flag} = $flag;

  # Calculate total impedance, which in our case is the sum of all connected
  # spanners' impedances. We skip the requesting spanner. If none are connected,
  # we return 0.
  $jit->code('$f = 0;', f => $$flow);

  my $fi = 0;
  for (grep refaddr($_) != refaddr($s), @{$$self{spanners}})
  {
    $_->jit_impedance($self, $jit, $$flag, $$n, $fi)
      ->code('$f += $fi;', f => $$flow, fi => $fi);
  }
  $jit;
}

sub jit_flow
{
  my $self = shift;
  my $s    = shift;
  my $jit  = shift;
  my $flag = \shift;
  my $n    = \shift;
  my $data = \shift;

  # TODO: weaken this reference
  $$self{jit_flags}{refaddr $flag} = $flag;

  if ($self->is_static)
  {
    $jit->code(q{ $n = 0; }, n => $$n);
  }
  elsif ($self->is_monomorphic)
  {
    my ($other) = grep refaddr($_) != refaddr($s), @{$$self{spanners}};
    $other->jit_flow($self, $jit, $$flag, $$n, $$data);
  }
  else
  {
    # Round-robin through the other spanners. Any of them might return 0 from a
    # flow request, so we automatically proceed to the next one until we've
    # gotten zeroes from everyone.
    #
    # Technically it's wasteful to recompile all flow paths when this flow point
    # changes, but it keeps the logic simple and correctly handles monomorphic
    # inlining.
    my $f   = 0;
    my @fns = map $_->jit_flow($self, pushback::jit->new->code('sub {'),
                               $$flag, $f, $$data)
                    ->code('}')->compile,
              grep refaddr($_) != refaddr($s), @{$$self{spanners}};
    $jit->code(
      q{
        $v = 0;
        until ($f || $v++ >= $#$fns)
        {
          $f = $n;
          $$fns[$i %= @$fns]->();
          ++$i;
        }
        $n = $f;
      },
      n   => $$n,
      f   => $f,
      i   => my $i = 0,
      v   => my $v = 0,
      fns => \@fns);
  }
}
```
