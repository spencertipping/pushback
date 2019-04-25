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
#line 59 "pushback/jit.md"
package pushback::jitclass;
use Scalar::Util;
sub new
{
  my ($class, $package, $ivars) = @_;
  my $self = bless { package => $package,
                     ivars   => [split/\s+/, $ivars] }, $class;
  $self->bind_invalidation_methods;
}
#line 80 "pushback/jit.md"
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
#line 108 "pushback/jit.md"
sub bind_invalidation_methods
{
  no strict 'refs';
  my $class = shift;
  *{"$$class{package}\::add_invalidation_flag"} = sub
  {
    my $self = shift;
    my $name = shift;
    my $flags = $$self{jit_invalidation_flags_}{$name} //= [];
    push @$flags, \shift;
    Scalar::Util::weaken $$flags[-1];
    $self;
  };

  *{"$$class{package}\::invalidate_jit_for"} = sub
  {
    my $self = shift;
    my $name = shift;
    my $flags = $$self{jit_invalidation_flags_}{$name};
    return $self unless defined $flags;
    defined and $$_ = 1 for @$flags;
    delete $$self{jit_invalidation_flags_}{$name};
    $self;
  };

  $class;
}
#line 144 "pushback/jit.md"
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
#line 178 "pushback/jit.md"
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

      $self->add_invalidation_flag($name, $jit->invalidation_flag);
      $jit->code(&$method($self, \@_,
                          $jit->refs, $jit->gensym_id, $jit->ref_gensyms));
    };
  }

  $self;
}
#line 264 "pushback/jit.md"
package pushback::jitcompiler;
sub new
{
  my $class = shift;
  bless { fragments    => [],
          invalidation => \(shift // my $iflag),
          gensym_id    => \(my $gensym = 0),
          refs         => {},
          ref_gensyms  => {} }, $class;
}

sub gensym_id         { shift->{gensym_id} }
sub refs              { shift->{refs} }
sub ref_gensyms       { shift->{ref_gensyms} }
sub invalidation_flag { shift->{invalidation} }

sub code
{
  my $self = shift;
  push @{$$self{fragments}}, shift;
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
#line 179 "pushback/flowable.md"
package pushback::flowable;

sub if_nonzero
{
  my ($self, $jit, $f) = @_;
  $self->if_nonzero_($jit);
  &$f();
  $self->end_($jit);
}

sub if_positive
{
  my ($self, $jit, $f) = @_;
  $self->if_positive_($jit);
  &$f();
  $self->end_($jit);
}

sub is_negative
{
  my ($self, $jit, $f) = @_;
  $self->if_negative_($jit);
  &$f();
  $self->end_($jit);
}
#line 209 "pushback/flowable.md"
pushback::jitclass->new('pushback::flowable::array', 'xs n offset')
  ->isa('pushback::flowable')
  ->def(new => sub
    {
      my $class   = shift;
      my $xs      = shift;
      my $n       = shift // 0;
      my $offset  = shift // 0;
      bless { xs     => $xs,
              n      => $n,
              offset => $offset }, $class;
    })

  ->def(xs      => sub { shift->{xs} })
  ->def(n       => sub { shift->{n} })
  ->def(offset  => sub { shift->{offset} })

  ->defjit(assign_from_ => 'xs_ n_ offset_',
    q{ $xs     = $xs_;
       $n      = $n_;
       $offset = $offset_; })

  ->defjit(if_nonzero_  => '', q[ if ($n) { ])
  ->defjit(if_positive_ => '', q[ if ($n > 0) { ])
  ->defjit(if_negative_ => '', q[ if ($n < 0) { ])
  ->defjit(end_         => '', q[ } ])

  ->defjit(intersect_   => 'n_', q{ $n = abs($n_) < abs($n) ? $n_ : $n; })
  ->defjit(set_to       => 'n_', q{ $n = $n_; })

  ->def(copy => sub
    {
      my $self = shift;
      my $jit  = shift;
      my $into = shift // ref($self)->new;
      $into->assign_from_($jit, $$self{xs}, $$self{n}, $$self{offset});
      $into;
    })

  ->def(intersect => sub
    {
      my ($self, $jit, $rhs) = @_;
      $self->intersect_($jit, $$rhs{n});
    });
#line 260 "pushback/flowable.md"
pushback::jitclass->new('pushback::flowable::string', 'str n offset')
  ->isa('pushback::flowable')
  ->def(new => sub
    {
      my $class   =  shift;
      my $str_ref = \shift;
      my $n       =  shift // 0;
      my $offset  =  shift // 0;
      bless { str_ref => $str_ref,
              n       => $n,
              offset  => $offset }, $class;
    })

  ->def(str_ref => sub { shift->{str_ref} })
  ->def(n       => sub { shift->{n} })
  ->def(offset  => sub { shift->{offset} })

  ->defjit(assign_from_ => 'str_ref_ n_ offset_',
    q{ $str_ref = $str_ref_;
       $n       = $n_;
       $offset  = $offset_; })

  # Used by base class methods
  ->defjit(if_nonzero_  => '', q[ if ($n) { ])
  ->defjit(if_positive_ => '', q[ if ($n > 0) { ])
  ->defjit(if_negative_ => '', q[ if ($n < 0) { ])
  ->defjit(end_         => '', q[ } ])

  # TODO: update to handle offsets correctly
  # TODO: modify jit class base to support some destructuring
  ->defjit(intersect_   => 'n_', q{ $n = abs($n_) < abs($n) ? $n_ : $n; })

  ->defjit(set_to => 'n_', q{ $n = $n_; })

  ->def(copy => sub
    {
      my $self = shift;
      my $jit  = shift;
      my $into = shift // ref($self)->new;
      $into->assign_from_($jit, $$self{str_ref}, $$self{n}, $$self{offset});
      $into;
    })

  ->def(intersect => sub
    {
      my ($self, $jit, $rhs) = @_;
      $self->intersect_($jit, $$rhs{n});
    });
#line 22 "pushback/objectset.md"
package pushback::objectset;
use Scalar::Util qw/weaken/;

sub new { bless ["\x01"], shift }

sub add
{
  my $id = (my $self = shift)->next_id;
  vec($$self[0], $id, 1) = 1;
  weaken($$self[$id] = \shift);
  $id;
}

sub remove
{
  my ($self, $id) = @_;
  vec($$self[0], $id, 1) = 0;
  delete $$self[$id];
  $$self[$id];
}

sub next_id
{
  my $self = shift;
  if ($$self[0] =~ /([^\xff])/g)
  {
    my $byte = pos $$self[0];
    my $v    = ord $1;
    my $bit  = 0;
    ++$bit while $v & 1 << $bit;
    $byte - 1 << 3 | $bit;
  }
  else
  {
    ++$#$self;
  }
}
#line 127 "pushback/process.md"
package pushback::process;
use Scalar::Util;

no warnings 'portable';
use constant HOST_MASK => 0xffff_f000_0000_0000;
use constant PROC_MASK => 0x0000_0fff_ffff_0000;
use constant PORT_MASK => 0x0000_0000_0000_ffff;

sub new
{
  my ($class, $io) = @_;
  my $self = bless { ports      => [],
                     pins       => {},
                     process_id => 0,
                     io         => $io }, $class;
  $$self{process_id} = $io->add_process($self);
  $self;
}

sub DESTROY
{
  my $self = shift;
  $$self{io}->remove_process($$self{process_id});
  die "TODO: disconnect ports";
}

sub io          { shift->{io} }
sub ports       { shift->{ports} }
sub process_id  { shift->{process_id} }
sub host_id     { shift->{process_id} & HOST_MASK }

sub port_id_for { shift->{process_id} | shift }
sub process_for { shift->{io}->process_for(shift) }

sub connect
{
  my ($self, $port, $destination) = @_;
  return 0 if $$self{ports}[$port];
  $$self{ports}[$port] = $destination;
  $self->process_for($destination)
       ->connect($self, $destination & PORT_MASK, $self->port_id_for($port));
  $self;
}

sub connection
{
  my ($self, $port) = @_;
  my $destination = $$self{ports}[$port];
  $destination ? ($self->process_for($destination), $destination & PORT_MASK)
               : ();
}

sub disconnect
{
  my ($self, $port) = @_;
  my $destination = $$self{ports}[$port];
  return 0 unless $destination;
  $$self{ports}[$port] = 0;
  $self->process_for($destination)->disconnect($destination & PORT_MASK);
  $self;
}
#line 218 "pushback/process.md"
sub zero_flow
{
  my ($proc, $jit, $flowable) = @_;
  $flowable->set_to($jit, 0);
}

sub admittance
{
  no strict 'refs';
  my ($self, $port, $jit, $flowable) = @_;
  my ($proc, $direction, $portname) = $self->parse_portspec($port);
  return $proc->admittance("$direction$portname", $jit, $flowable)
    unless Scalar::Util::refaddr $proc eq Scalar::Util::refaddr $self;

  my $admittance = \%{ref($self) . "::admittance"};
  ($$admittance{"=$portname"} // $$admittance{"$direction$portname"}
                              // \&zero_flow)->($self, $jit, $flowable);
}

sub flow
{
  no strict 'refs';
  my ($self, $port, $jit, $flowable) = @_;
  my ($proc, $direction, $portname) = $self->parse_portspec($port);
  return $proc->flow("$direction$portname", $jit, $flowable)
    unless Scalar::Util::refaddr $proc eq Scalar::Util::refaddr $self;

  my $flow = \%{ref($self) . "::flow"};
  ($$flow{"=$portname"} // $$flow{"$direction$portname"}
                        // \&zero_flow)->($self, $jit, $flowable);
}
#line 254 "pushback/process.md"
sub parse_portspec
{
  no strict 'refs';
  my ($self, $port) = @_;
  my ($portname, $direction);

  # Handle remote port references: follow and delegate to the endpoint. Preserve
  # direction by prepending it to the destination portspec.
  if (($portname, $direction) = $port =~ /^(\w+)([<>=])$/)
  {
    my ($endpoint, $endport) = $self->connection(
      Scalar::Util::looks_like_number($portname)
        ? $portname
        : ${ref($self) . "::ports"}{$portname}
            // die "$self doesn't define named port $portname");
    return $endpoint->parse_portspec("$direction$endport");
  }

  # We have a local port. Resolve it to a name and infer direction.
  ($portname, $direction) = ($port, "=")
    unless ($portname, $direction) = $port =~ /^([<>=])(\w+)$/;

  $portname = $self->port_name($portname)
    // die "$self doesn't define $portname"
    if Scalar::Util::looks_like_number $portname;

  ($self, $direction, $portname);
}

sub port_name
{
  no strict 'refs';
  my ($self, $port_index) = @_;
  my $ports = \%{ref($self) . "::ports"};
  $$ports{$_} == $port_index and return $_ for keys %$$ports;
  undef;
}
#line 300 "pushback/process.md"
package pushback::processclass;
push our @ISA, 'pushback::jitclass';
sub new
{
  my ($class, $name, $vars, $ports) = @_;
  my $self = pushback::jitclass::new $class,
               $name =~ /::/ ? $name : "pushback::processes::$name", $vars;
  {
    no strict 'refs';
    $$self{ports}      = \%{"$$self{package}\::ports"};
    $$self{admittance} = \%{"$$self{package}\::admittance"};
    $$self{flow}       = \%{"$$self{package}\::flow"};
  }

  $$self{port_index} = 0;       # next free port number
  $self->defport($_) for split/\s+/, $ports;
  $self;
}
#line 346 "pushback/process.md"
sub defport
{
  my $self = shift;
  for my $port (@_)
  {
    my $index = $$self{ports}{$port} = $$self{port_index}++;
    $self->def("connect_$port"    => sub { shift->connect($index, @_) })
         ->def("disconnect_$port" => sub { shift->disconnect($index) })
         ->def("$port\_port_id"   => sub { shift->port_id_for($index) });
  }
  $self;
}

sub defadmittance
{
  my ($self, $port, $a) = @_;
  my ($direction, $portname) = $port =~ /^([<>=])(\w+)$/
    or die "defadmittance: '$port' must begin with a direction indicator";
  die "$self doesn't define port $portname"
    unless exists $$self{ports}{$portname};

  my ($aname, $adir);
  if (ref $a)
  {
    $$self{admittance}{$port} = $a;
  }
  elsif (($adir, $aname) = $a =~ /^([<>=])(\w+)$/
      or ($aname, $adir) = $a =~ /^(\w+)([<>=])$/)
  {
    die "$self doesn't define port $aname" unless exists $$self{ports}{$aname};
    die "admittance from $port to $a modifies flow direction"
      unless $adir eq $direction;

    $$self{admittance}{$port} = sub
    {
      my ($proc, $jit, $flowable) = @_;
      $proc->admittance($a, $jit, $flowable);
    };
  }
  else # compile expression
  {
    my $method = "$port\_admittance";
    $self->defjit($method, 'result_', qq{ \$result_ = ($a); });
    $$self{admittance}{$port} = sub
    {
      my ($proc, $jit, $flowable) = @_;
      $proc->$method($jit, my $result);
      $flowable->set_to($jit, $result);
    };
  }

  $self;
}

sub defflow
{
  my ($self, $port, $f) = @_;
  my ($direction, $portname) = $port =~ /^([<>=])(\w+)$/
    or die "defadmittance: '$port' must begin with a direction indicator";
  die "$self doesn't define port $portname"
    unless exists $$self{ports}{$portname};

  my ($fname, $fdir);
  if (ref $f)
  {
    $$self{flow}{$port} = $f;
  }
  elsif (($fdir, $fname) = $f =~ /^([<>=])(\w+)$/
      or ($fname, $fdir) = $f =~ /^(\w+)([<>=])$/)
  {
    die "$self doesn't define port $fname" unless exists $$self{ports}{$fname};
    die "flow from $port to $f modifies direction" unless $fdir eq $direction;

    $$self{flow}{$port} = sub
    {
      my ($proc, $jit, $flowable) = @_;
      $proc->flow($f, $jit, $flowable);
    };
  }
  else
  {
    die "unknown flow delegation spec: '$f' (expecting function, self-route, "
      . "or connection-route)";
  }

  $self;
}
#line 7 "pushback/io.md"
package pushback::io;
use overload qw/ @{} processes /;
sub new
{
  my ($class, $host_id) = @_;
  bless { host_id       => $host_id // 0,
          processes     => pushback::objectset->new,
          owned_objects => {} }, $class;
}

sub processes { shift->{processes} }
sub host_id   { shift->{host_id} }

sub add_process
{
  my ($self, $proc) = @_;
  $$self{host_id} << 44 | $$self{processes}->add($proc) << 16;
}

sub remove_process
{
  my ($self, $proc) = @_;
  $proc = $proc->process_id if ref $proc;
  $$self{processes}->remove(($proc & pushback::process::PROC_MASK) >> 16);
  $self;
}

sub process_for
{
  my ($self, $pid) = @_;
  $pid >> 44 == $$self{host_id}
    ? $$self{processes}[($pid & pushback::process::PROC_MASK) >> 16]
    : $self->rpc_for($pid);
}

sub rpc_for { ... }
#line 58 "pushback.md"
package pushback;
use Exporter qw/import/;
use constant io => pushback::io->new;
our @EXPORT = our @EXPORT_OK = qw/io/;
1;
