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
#line 61 "pushback/jit.md"
package pushback::jitclass;
use Scalar::Util;
sub new
{
  my ($class, $package, $ivars) = @_;
  my $self = bless { package => $package,
                     ivars   => [split/\s+/, $ivars] }, $class;
  $self->bind_invalidation_methods;
}
#line 83 "pushback/jit.md"
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
#line 112 "pushback/jit.md"
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
#line 149 "pushback/jit.md"
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
#line 184 "pushback/jit.md"
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
#line 271 "pushback/jit.md"
package pushback::jitcompiler;
use Scalar::Util qw/refaddr/;
use overload qw/ "" describe /;

sub new
{
  my $class = shift;
  bless { fragments    => [],
          invalidation => \(shift // my $iflag),
          gensym_id    => \(my $gensym = 0),
          debug        => 0,
          refs         => {},
          ref_gensyms  => {} }, $class;
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

sub gensym_id         { shift->{gensym_id} }
sub refs              { shift->{refs} }
sub ref_gensyms       { shift->{ref_gensyms} }
sub invalidation_flag { shift->{invalidation} }

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
#line 188 "pushback/flowable.md"
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
#line 222 "pushback/flowable.md"
package pushback::flowableclass;
sub new
{
  my ($metaclass, $class, $state) = @_;
  pushback::jitclass->new($class, $state)->isa('pushback::flowable');
}
#line 234 "pushback/flowable.md"
pushback::flowableclass->new('pushback::flowable::array', 'xs n offset')
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

  ->def(copy_nonjit => sub
    {
      my ($self, $into) = @_;
      $into //= ref($self)->new;
      $$into{xs}     = $$self{xs};
      $$into{n}      = $$self{n};
      $$into{offset} = $$self{offset};
      $into;
    })

  ->def(copy => sub
    {
      my ($self, $jit, $into) = @_;
      ($into //= ref($self)->new)
        ->assign_from_($jit, $$self{xs}, $$self{n}, $$self{offset});
      $into;
    })

  ->def(intersect => sub
    {
      my ($self, $jit, $rhs) = @_;
      $self->intersect_($jit, $$rhs{n});
    });
#line 294 "pushback/flowable.md"
pushback::flowableclass->new('pushback::flowable::string', 'str n offset')
  ->def(new => sub
    {
      my $class   =  shift;
      my $str_ref = \shift;
      my $n       =  shift // length $$str_ref;
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

  ->def(copy_nonjit => sub
    {
      my ($self, $into) = @_;
      $into //= ref($self)->new;
      $$into{str_ref} = $$self{str_ref};
      $$into{n}       = $$self{n};
      $$into{offset}  = $$self{offset};
      $into;
    })

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
#line 23 "pushback/objectset.md"
package pushback::objectset;
use Scalar::Util qw/weaken/;

sub new { bless ["\x01"], shift }

sub add
{
  my $id = (my $self = shift)->next_id;
  vec($$self[0], $id, 1) = 1;
  $$self[$id] = shift;
  weaken $$self[$id] if ref $$self[$id];
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
#line 57 "pushback.md"
1;
