# Pushback: flow control as control flow
# Pushback is a fully negotiated IO multiplexer for Perl. See
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


# JIT compiler object
# Compiles code into the current runtime, sharing state across the compilation
# boundary using lexical closure.

package pushback::jit;
sub new
{
  my ($class, $name) = shift;
  my $gensym = 0;
  bless { parent => undef,
          name   => $name,
          shared => {},
          gensym => \$gensym,
          code   => [],
          end    => undef }, $class;
}

sub compile
{
  my $self  = shift;
  my @args  = sort keys %{$$self{shared}};
  my $setup = sprintf "my (%s) = \@_;", join",", map "\$$_", @args;
  my $code  = join"\n", "sub{", $setup, @{$$self{code}}, "}";
  my $sub   = eval $code;
  die "$@ compiling $code" if $@;
  $sub->(@{$$self{shared}}{@args});
}

# Code rewriting
sub gensym { "g" . ${shift->{gensym}}++ }
sub code
{
  my $self = shift;
  my $code = shift;
  my %vars;
  ${$$self{shared}}{$vars{+shift} = $self->gensym} = shift while @_ >= 2;
  my $vars = join"|", keys %vars;
  push @{$$self{code}},
       keys(%vars) ? $code =~ s/\$($vars)/"\$" . $vars{$1}/egr : $code;
  $self;
}

# Macros
sub mark
{
  my $self = shift;
  $self->code("#line 1 \"$$self{name} @_\"");
}
sub if    { shift->block(if    => @_) }
sub while { shift->block(while => @_) }
sub block
{
  my $self = shift;
  my $type = shift;
  $self->code("$type(")->code(@_)->code("){")
       ->child($name, "}");
}

# Parent/child linkage
sub child
{
  my ($self, $name, $end) = @_;
  bless { parent  => $self,
          name    => "$$self{name} $name",
          closure => $$self{closure},
          gensym  => $$self{gensym},
          code    => [],
          end     => $end }, ref $self;
}
sub end
{
  my $self = shift;
  $$self{parent}->code(join"\n", @{$$self{code}}, $$self{end});
}
