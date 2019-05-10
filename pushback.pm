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
#line 58 "pushback/jit.md"
package pushback::jitclass;
use Scalar::Util;
sub new
{
  my ($class, $package, $ivars) = @_;
  bless { package => $package,
          ivars   => [split/\s+/, $ivars] }, $class;
}
#line 78 "pushback/jit.md"
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
#line 101 "pushback/jit.md"
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
#line 135 "pushback/jit.md"
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
#line 220 "pushback/jit.md"
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
#line 10 "pushback/surface.md"
package pushback::surface;
use overload qw/ "" describe /;

sub describe;   # ($self) -> string
sub manifold;   # ($self) -> $manifold
#line 23 "pushback/surface.md"
package pushback::io_surface;
push our @ISA, 'pushback::surface';
use overload qw/ | fuse /;

sub fuse;       # ($self, $manifold) -> $surface
#line 63 "pushback/manifold.md"
package pushback::manifold;
use overload qw/ "" describe /;

sub new
{
  my $class = shift;
  bless { links => {} }, $class;
}

sub describe;       # ($self) -> string
sub connection;     # ($self, $portname) -> ([$manifold, $port], ...)
#line 87 "pushback/manifold.md"
package pushback::manifoldclass;
push our @ISA, 'pushback::jitclass';
sub new
{
  pushback::jitclass::new(@_)->isa('pushback::manifold');
}
#line 58 "pushback.md"
1;
