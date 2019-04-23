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
use Scalar::Util qw/refaddr/;
sub new
{
  my ($class, $package, @ivars) = @_;
  my $self = bless { package => $package,
                     ivars   => \@ivars }, $class;
  $self->bind_invalidation_methods;
}
#line 79 "pushback/jit.md"
sub isa
{
  no strict 'refs';
  my $class = shift;
  push @{"$$class{package}\::ISA"}, @_;
  $class;
}
#line 100 "pushback/jit.md"
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
#line 136 "pushback/jit.md"
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
#line 170 "pushback/jit.md"
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
      $self->add_invalidation_flag($name, $jit->invalidation_flag);
      $jit->code(&$method($self, \@_,
                          $jit->refs, $jit->gensym_id, $jit->ref_gensyms));
    };
  }

  $self;
}
#line 253 "pushback/jit.md"
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
#line 76 "pushback/process.md"
package pushback::process;
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

sub disconnect
{
  my ($self, $port) = @_;
  my $destination = $$self{ports}[$port];
  return 0 unless $destination;
  $$self{ports}[$port] = 0;
  $self->process_for($destination)->disconnect($destination & PORT_MASK);
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
