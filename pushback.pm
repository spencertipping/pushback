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
#line 59 "pushback/jitobject.md"
package pushback::jitclass;
use Scalar::Util qw/refaddr/;
sub new
{
  my ($class, $package, @ivars) = @_;
  bless { package => $package,
          methods => {},
          jit_ops => {},
          ivars   => \@ivars }, $class;
}
#line 74 "pushback/jitobject.md"
sub def;                      # ($name => sub {...}) -> $class
sub defop;                    # ($name => [@args], q{...}) -> $class
sub defjit;                   # ($name => sub {...}) -> $class
#line 86 "pushback/jitobject.md"
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
#line 113 "pushback/jitobject.md"
our $gensym_id = 0;
sub gensym { "_" . ++$gensym_id }

sub jit_op_arg
{
  my ($arg, $index) = @_;
  my $sigil = $arg =~ s/^\^// ? '$' : '$$';
  "push \@code, '$sigil' . ("
    . "\$\$ref_gensyms{Scalar::Util::refaddr \$\$arg_refs[$index]}"
    . " //= " . __PACKAGE__ . "::gensym);";
}

sub jit_op_ivar
{
  my $name = shift;
  "push \@code, '\$' . ("
    . "\$\$ref_gensyms{Scalar::Util::refaddr \\\$\$self{$name}}"
    . " //= " . __PACKAGE__ . "::gensym);";
}

sub defop
{
  my ($self, $name, $args, $code) = @_;
  my $all_vars  = join"|", @{$$self{ivars}}, map +("\\^$_", $_), @$args;
  my $var_regex = qr/\$($all_vars)\b/;
  my %args      = map +(  $$args[$_]  => $_,
                        "^$$args[$_]" => $_), 0..$#$args;
  my @constants;
  my @fragments = q[
  sub {
    my @constants = @_;
    sub {
      my ($self, $arg_refs, $ref_gensyms) = @_;
      my @code; ];

  my $last = 0;
  while ($code =~ /$var_regex/g)
  {
    my $v = $1;
    my $n = @constants;
    push @constants, substr $code, $last, pos($code) - length($v) - 1 - $last;
    push @fragments, "push \@code, \$constants[$n];",
                     exists $args{$v} ? jit_op_arg($v, $args{$v})
                                      : jit_op_ivar($v);
    $last = pos $code;
  }

  push @constants, substr $code, $last;
  push @fragments, q[
      join"\n", @code;
    }
  }];

  my $fn = eval join"\n", "#line 1 \"$$self{package} defop $name\"", @fragments;
  die "$@ compiling @fragments" if $@;
  $$self{jit_ops}{$name} = &$fn(@constants);
  $self;
}
1;