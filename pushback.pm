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
#line 16 "pushback/jit.md"
package pushback::jit;
our $gensym = 0;

sub new
{
  my $class = shift;
  bless { parent => undef,
          shared => {},
          refs   => {},
          code   => [],
          end    => "" }, $class;
}

sub compile
{
  my $self = shift;
  die "$$self{name}: must compile the parent JIT context"
    if defined $$self{parent};

  my @args  = sort keys %{$$self{shared}};
  my $setup = sprintf "my (%s) = \@_;", join",", map "\$$_", @args;
  my $code  = join"\n", "use strict;use warnings;",
                        "sub{", $setup, @{$$self{code}}, "}";

  my $sub = eval $code;
  die "$@ compiling $code" if $@;
  $sub->(@{$$self{shared}}{@args});
}
#line 48 "pushback/jit.md"
sub gensym { "g" . $gensym++ }
sub code
{
  my ($self, $code) = (shift, shift);
  if (ref $code && $code->isa('pushback::jit'))
  {
    %{$$self{shared}} = (%{$$self{shared}}, %{$$code{shared}});
    $$self{refs}{$_} //= $$code{refs}{$_} for keys %{$$code{refs}};
    push @{$$self{code}}, join"\n", @{$$code{code}}, $$code{end};
  }
  else
  {
    my %v;
    while (@_)
    {
      $$self{shared}{$v{$_[0]} = $$self{refs}{\$_[1]} //= gensym} = \$_[1];
      shift;
      shift;
    }
    if (keys %v)
    {
      my $vs = join"|", keys %v;
      $code =~ s/([\$@%&\*])($vs)\b/"$1\{\$$v{$2}\}"/eg;
    }
    push @{$$self{code}}, $code;
  }
  $self;
}
#line 80 "pushback/jit.md"
sub child
{
  my ($self, $end) = @_;
  bless { parent  => $self,
          closure => $$self{closure},
          shared  => $$self{shared},
          code    => [],
          end     => $end // "" }, ref $self;
}

sub end
{
  my $self = shift;
  $$self{parent}->code(join"\n", @{$$self{code}}, $$self{end});
}
#line 25 "pushback/point.md"
package pushback::point;
use overload qw/ "" id == equals /;
use Scalar::Util qw/ refaddr weaken /;

sub new;                # pushback::point->new($id // undef)
sub id;                 # () -> $id_string
sub is_static;          # () -> $static?
sub is_monomorphic;     # () -> $monomorphic?
sub connect;            # ($spanner) -> $self!
sub disconnect;         # ($spanner) -> $self!

sub invalidate_jit;     # () -> $self
sub jit_admittance;     # ($spanner, $jit, $flag, $n, $flow) -> $jit!
sub jit_flow;           # ($spanner, $jit, $flag, $offset, $n, $data) -> $jit!
#line 44 "pushback/point.md"
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
#line 85 "pushback/point.md"
sub invalidate_jit
{
  my $self = shift;
  $$_ = 1 for values %{$$self{jit_flags}};
  %{$$self{jit_flags}} = ();
  $self;
}

sub jit_admittance
{
  die 'jit_admittance expects 6 args' unless @_ == 6;
  my $self = shift;
  my $s    = shift;
  my $jit  = shift;
  my $flag = \shift;
  my $n    = \shift;
  my $flow = \shift;

  weaken($$self{jit_flags}{refaddr $flag} = $flag);

  # Calculate total admittance, which in our case is the sum of all connected
  # spanners' admittances. We skip the requesting spanner. If none are
  # connected, we return 0.
  $jit->code('$f = 0;', f => $$flow);

  my $fi = 0;
  for (grep refaddr($_) != refaddr($s), @{$$self{spanners}})
  {
    $_->jit_admittance($self, $jit, $$flag, $$n, $fi)
      ->code('$f += $fi;', f => $$flow, fi => $fi);
  }
  $jit;
}

sub jit_flow
{
  die 'jit_flow expects 7 args' unless @_ == 7;
  my $self   = shift;
  my $s      = shift;
  my $jit    = shift;
  my $flag   = \shift;
  my $offset = \shift;
  my $n      = \shift;
  my $data   = \shift;

  weaken($$self{jit_flags}{refaddr $flag} = $flag);

  if ($self->is_static)
  {
    $jit->code(q{ $n = 0; }, n => $$n);
  }
  elsif ($self->is_monomorphic)
  {
    my ($other) = grep refaddr($_) != refaddr($s), @{$$self{spanners}};
    $other->jit_flow($self, $jit, $$flag, $$offset, $$n, $$data);
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
                               $$flag, $$offset, $f, $$data)
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
#line 9 "pushback/spanner.md"
package pushback::spanner;
use Scalar::Util qw/refaddr/;
use overload qw/ "" name == equals /;

sub connected_to;           # pushback::spanner->connected_to(%points)
sub point;                  # ($key) -> $point
sub flow;                   # ($point, $offset, $n, $data) -> $n
sub admittance;             # ($point, $n) -> $flow
#line 22 "pushback/spanner.md"
sub connected_to
{
  my $class = shift;
  my $self  = bless { points         => {@_},
                      flow_fns       => {},
                      admittance_fns => {} }, $class;
  $_->connect($self) for values %{$$self{points}};
  $self;
}

sub equals { refaddr shift == refaddr shift }
sub name   { "anonymous " . ref shift }
sub point  { $_[0]->{points}->{$_[1]} // die "$_[0]: undefined point $_[1]" }

sub flow
{
  my $self  = shift;
  my $point = shift;
  ($$self{flow_fns}{$point} // $self->jit_flow_fn($point))->(@_);
}

sub admittance
{
  my $self  = shift;
  my $point = shift;
  ($$self{admittance_fns}{$point} // $self->jit_admittance_fn($point))->(@_);
}
#line 54 "pushback/spanner.md"
sub jit_autoinvalidation
{
  my ($self, $jit, $regen_method, $point) = @_;
  my $flag = 0;
  $jit->code(q{ return &$fn($self, $point)->(@_) if $invalidated; },
    fn          => $self->can($regen_method),
    self        => $self,
    point       => $point,
    invalidated => $flag);
  \$flag;
}

sub jit_admittance_fn
{
  my ($self, $point) = @_;
  my $jit = pushback::jit->new
    ->code('#line 1 "' . $self->name . '::admittance_fn"')
    ->code('sub {');

  my $n;
  my $flow;
  my $flag = $self->jit_autoinvalidation($jit, 'jit_admittance_fn', $point);
  $jit->code(q{ $n = shift; }, n => $n);

  $$self{admittance_fns}{$point} =
    $self->point($point)
      ->jit_admittance($self, $jit, $$flag, $n, $flow)
      ->code('@_ ? $_[0] = $flow : $flow; }', flow => $flow)
      ->compile;
}

sub jit_flow_fn
{
  my ($self, $point) = @_;
  my $jit = pushback::jit->new
    ->code('#line 1 "' . $self->name . '::flow_fn"')
    ->code('sub {');

  my ($offset, $n, $data);
  my $flag = $self->jit_autoinvalidation($jit, 'jit_flow_fn', $point);
  $jit->code('($offset, $n, $data) = @_;',
    offset => $offset,
    n      => $n,
    data   => $data);

  $$self{flow_fns}{$point} =
    $self->point($point)
      ->jit_flow($self, $jit, $$flag, $offset, $n, $data)
      ->code('$_[2] = $data; $_[0] = $offset; $_[1] = $n }',
          offset => $offset,
          n      => $n,
          data   => $data)
      ->compile;
}
#line 6 "pushback/admittance.md"
package pushback::admittance::value;
use Scalar::Util qw/ looks_like_number /;

sub jit;                # ($jit, $flag, $n, $flow) -> $jit

use overload qw/ + plus
                 | union
                 & intersect /;

# Binary ops
BEGIN { eval "sub $_ { bless [shift, shift], 'pushback::admittance::$_' }"
        for qw/ plus union intersect if / }

# Value coercion
sub from
{
  my ($class, $val) = @_;
  my $r = ref $val;
  return pushback::admittance::n->new($val)  if !$r && looks_like_number $val;
  return pushback::admittance::fn->new($val) if $r eq 'CODE';
  return pushback::admittance::point->new($val, shift)
    if $r =~ /^pushback::point/;
  die "don't know how to turn $val of type $r into an admittance calculator";
}
#line 35 "pushback/admittance.md"
sub pushback::admittance::n::new     { bless \(my $x = $_[1]), $_[0] }
sub pushback::admittance::fn::new    { bless \(my $x = $_[1]), $_[0] }
sub pushback::admittance::point::new { bless { point   => $_[1],
                                               spanner => $_[2] }, $_[0] }

sub pushback::admittance::n::jit
{
  my $self = shift;
  my $jit  = shift;
  my $flag = \shift;
  my $n    = \shift;
  my $flow = \shift;
  $jit->code('$flow = $n * $a;', flow => $$flow, n => $$n, a => $$self);
}

sub pushback::admittance::fn::jit
{
  my $self = shift;
  my $jit  = shift;
  my $flag = \shift;
  my $n    = \shift;
  my $flow = \shift;
  $jit->code('$flow = &$fn($n);', flow => $$flow, n => $$n, fn => $$self);
}

sub pushback::admittance::point::jit
{
  my $self = shift;
  my $jit  = shift;
  my $flag = \shift;
  my $n    = \shift;
  my $flow = \shift;
  $$self{point}->jit_admittance($$self{spanner}, $jit, $$flag, $$n, $$flow);
}
#line 74 "pushback/admittance.md"
sub pushback::admittance::plus::jit
{
  my $self = shift;
  my $jit  = shift;
  my $flag = \shift;
  my $n    = \shift;
  my $flow = \shift;
  my $lflow;
  my $rflow;
  $$self[0]->jit($jit, $$flag, $$n, $lflow);
  $$self[1]->jit($jit, $$flag, $$n, $rflow);
  $jit->code('$flow = $lflow + $rflow;',
    flow => $$flow, lflow => $lflow, rflow => $rflow);
}

sub pushback::admittance::union::jit
{
  my $self = shift;
  my $jit  = shift;
  my $flag = \shift;
  my $n    = \shift;
  my $flow = \shift;
  my $lflow;
  my $rflow;
  $$self[0]->jit($jit, $$flag, $$n, $lflow);
  $$self[1]->jit($jit, $$flag, $$n, $rflow);
  $jit->code('$flow = abs($lflow) > abs($rflow) ? $lflow : $rflow;',
    flow => $$flow, lflow => $lflow, rflow => $rflow);
}

sub pushback::admittance::intersection::jit
{
  my $self = shift;
  my $jit  = shift;
  my $flag = \shift;
  my $n    = \shift;
  my $flow = \shift;
  my $rflow;
  $$self[0]->jit($jit, $$flag, $$n, $$flow);
  $jit->code('if ($flow) {', flow => $$flow);
  $$self[1]->jit($jit, $$flag, $$n, $rflow);
  $jit->code('  $flow = abs($rflow) < abs($flow) ? $rflow : $flow;',
               rflow => $rflow, flow => $$flow)
      ->code('}');
}

sub pushback::admittance::if::jit
{
  my $self = shift;
  my $jit  = shift;
  my $flag = \shift;
  my $n    = \shift;
  my $flow = \shift;
  $$self[1]->jit($jit, $$flag, $$n, $$flow);
  $jit->code('if ($flow) {', flow => $$flow);
  $$self[0]->jit($jit, $$flag, $$n, $$flow)->code('}');
}
#line 5 "pushback/router.md"
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
#line 35 "pushback/router.md"
sub new;            # (...) -> $spanner

sub state;          # ($name => $init, ...) -> $self!
sub flow;           #   ($path, $admittance, $onflow) -> $self!
                    # | ($path, $path) -> $self!
sub def;            # ($name => $method, ...) -> $self!

sub streamctor;     # ($name, $in_flowpoint[, $init_fn]) -> $self!
sub stream;         # ($name, $path) -> $self!
#line 53 "pushback/router.md"
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
#line 74 "pushback/router.md"
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
#line 112 "pushback/router.md"
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
#line 7 "pushback/stream.md"
package pushback::stream;
use overload qw/ >> into /;
push @pushback::point::ISA, 'pushback::stream';
#line 20 "pushback/seq.md"
package pushback::seq;
push our @ISA, 'pushback::spanner';

sub pushback::stream::seq
{
  my $p = pushback::point->new;
  pushback::seq->new($p);
  $p;
}

sub new
{
  my ($class, $into) = @_;
  my $self = $class->connected_to(into => $into);
  $$self{i} = 0;
  $self;
}

sub jit_admittance
{
  my $self  = shift;
  my $point = shift;
  my $jit   = shift;
  my $flag  = \shift;
  my $n     = \shift;
  my $flow  = \shift;

  # Always return data. Our target flow per request is 1k elements.
  $jit->code(q{ $f = $n < 0 ? -1024 : 0; }, n => $$n, f => $$flow);
}

sub jit_flow
{
  my $self   = shift;
  my $point  = shift;
  my $jit    = shift;
  my $flag   = \shift;
  my $offset = \shift;
  my $n      = \shift;
  my $data   = \shift;
  $jit->code('#line 1 seq')
      ->code(
    q{
      if ($n < 0)
      {
        $n = -$n;
        $offset = 0;
        @$data = $i .. $i+$n-1;
        $i += $n;
      }
      else
      {
        $n = 0;
      }
    },
    offset => $$offset,
    data   => $$data,
    n      => $$n,
    i      => $$self{i});
}
#line 20 "pushback/map.md"
package pushback::map;
push our @ISA, 'pushback::spanner';

sub pushback::stream::map
{
  my ($self, $fn) = @_;
  my $dest = pushback::point->new;
  pushback::map->new($self, $dest, $fn);
  $dest;
}

sub new
{
  my ($class, $from, $to, $fn) = @_;
  my $self = $class->connected_to(from => $from, to => $to);
  $$self{fn} = $fn;
  $self;
}

sub jit_admittance
{
  my $self  = shift;
  my $point = shift;
  my $jit   = shift;
  my $flag  = \shift;
  my $n     = \shift;
  my $flow  = \shift;
  $self->point($point == $self->point('to') ? 'from' : 'to')
    ->jit_admittance($self, $jit, $$flag, $$n, $$flow);
}

sub jit_flow
{
  my $self   = shift;
  my $point  = shift;
  my $jit    = shift;
  my $flag   = \shift;
  my $offset = \shift;
  my $n      = \shift;
  my $data   = \shift;
  $self->point($point == $self->point('to') ? 'from' : 'to')
    ->jit_flow($self, $jit, $$flag, $$offset, $$n, $$data)
    ->code('#line 1 "' . $self->name . ' flow')
    ->code(q{ @$data[$offset .. $offset+$n-1]
                = map &$fn($_), @$data[$offset .. $offset+$n-1]; },
           fn     => $$self{fn},
           offset => $$offset,
           n      => $$n,
           data   => $$data);
}
#line 3 "pushback/copy.md"
package pushback::copy;
push our @ISA, 'pushback::spanner';

sub pushback::stream::into
{
  my ($self, $dest) = @_;
  pushback::copy->new($self, $dest);
  $dest;
}

sub pushback::stream::copy
{
  shift->into(pushback::point->new);
}

sub new
{
  my ($class, $from, $to) = @_;
  $class->connected_to(from => $from, to => $to);
}

sub jit_admittance
{
  my $self  = shift;
  my $point = shift;
  $self->point($point == $self->point('from') ? 'to' : 'from')
    ->jit_admittance($self, @_);
}

sub jit_flow
{
  my $self  = shift;
  my $point = shift;
  $self->point($point == $self->point('from') ? 'to' : 'from')
    ->jit_flow($self, @_);
}
#line 3 "pushback/each.md"
package pushback::each;
push our @ISA, 'pushback::spanner';

sub pushback::stream::each
{
  my ($self, $fn) = @_;
  pushback::each->new($self, $fn);
  $self;
}

sub new
{
  my ($class, $from, $fn) = @_;
  my $self = $class->connected_to(from => $from);
  my $n = $self->admittance('from', -1);
  my $offset;
  my $data;
  $$self{fn} = $fn;
  &$fn($offset, $n, $data) while $n = $self->flow('from', $offset, $n, $data);
  $self;
}

sub jit_admittance
{
  my $self  = shift;
  my $point = shift;
  my $jit   = shift;
  my $flag  = \shift;
  my $n     = \shift;
  my $flow  = \shift;

  # No admittance modifications for inflow to this spanner.
  $jit->code(q{ $f = $n > 0 ? $n : 0; }, f => $$flow, n => $$n);
}

sub jit_flow
{
  my $self   = shift;
  my $point  = shift;
  my $jit    = shift;
  my $flag   = \shift;
  my $offset = \shift;
  my $n      = \shift;
  my $data   = \shift;
  $jit->code(
    q{
      if ($n > 0)
      {
        &$fn($offset, $n, $data);
        $n = -$n;
      }
      else
      {
        $n = 0;
      }
    },
    fn     => $$self{fn},
    offset => $$offset,
    n      => $$n,
    data   => $$data);
}
1;
__END__
