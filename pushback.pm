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
#line 251 "pushback/jit.md"
package pushback::jitcompiler;
sub new
{
  my $class = shift;
  bless { fragments    => [],
          invalidation => \shift,
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
#line 71 "pushback/flowable.md"
pushback::jitclass->new('pushback::flowable::bytes', qw/ data offset n /)
  ->def(new =>
    sub {
      my $class = shift;
      bless { data   => @_ ? \shift : \(my $buf = ""),
              offset => 0,
              n      => 0 }, $class;
    })

  ->defjit(intersect_ => ['$fn'], '$n = $fn if $fn < $n;')
  ->defjit(add_       => ['$fn'], '$n += $fn;')
  ->defjit(zero_      => [],      '$n = 0;')
  ->defjit(if_start_  => [],      'if ($n) {')
  ->defjit(if_end_    => [],      '}')

  ->def(if => sub
    {
      my ($self, $jit, $fn) = @_;
      $self->if_start_($jit);
      &$fn($jit, $self);
      $self->if_end_($jit);
      $self;
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
1;