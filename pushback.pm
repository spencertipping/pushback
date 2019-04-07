#line 3 "pushback.md"
# Documentation at https://github.com/spencertipping/pushback.
#
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
#line 171 "pushback.md"
package pushback::select_catalyst;
use constant epoch => int time();
use Time::HiRes qw/time/;

sub new
{
  my $class = shift;
  bless { read_fds   => [],             # bit-packed
          write_fds  => [],             # bit-packed
          fibers     => [],             # index is significant
          perl_files => [],             # index == fileno($fh)
          timeline   => [] }, $class;   # sorted _descending_ by time
}
#line 239 "pushback.md"
package pushback::compiler;
sub new
{
  my ($class, $name) = shift;
  my $gensym = 0;
  my @code;
  bless { parent  => undef,
          name    => $name,
          closure => {},
          gensym  => \$gensym,
          code    => \@code,
          end     => undef }, $class;
}

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

sub gensym { "g" . ${shift->{gensym}}++ }
sub code
{
  my $self = shift;
  my $code = shift;
  my %vars;
  ${$$self{closure}}{$vars{+shift} = $self->gensym} = shift while @_ >= 2;
  my $vars = join"|", keys %vars;
  push @{$$self{code}},
       keys(%vars) ? $code =~ s/\$($vars)/"\$" . ${$$self{scope}}{$1}/egr
                   : $code;
  $self;
}

sub mark
{
  my $self = shift;
  $self->code("#line 1 \"$$self{name} @_\"");
}

sub block
{
  my ($self, $type, $name) = @_;
  $self->code("$type(")->code(@_)->code("){")
       ->child($name // $type,
               "}");
}

sub if    { shift->block(if => @_) }
sub while { shift->block(while => @_) }
sub end
{
  my $self = shift;
  $$self{parent}->code(join"\n", @{$$self{code}, $$self{end});
}

sub compile
{
  my $self    = shift;
  my @closure = sort keys %{$$self{closure}};
  my $setup   = sprintf "my (%s) = \@_;", join",", map "\$$_", @closure;
  my $code    = join"\n", "sub{", $setup, @{$$self{code}}, "}";
  my $sub     = eval $code;
  die "$@ compiling $code" if $@;
  $sub->(@{$$self{closure}}{@closure});
}
