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
#line 8 "pushback/bits.md"
sub pushback::bit_indexes
{
  my @r;
  local $_ = shift;
  pos() = undef;
  while (/([^\0])/g)
  {
    my $i = pos() - 1 << 3;
    my $c = ord $1;
    do
    {
      push @r, $i if $c & 1;
      ++$i;
    } while $c >>= 1;
  }
  @r;
}
#line 6 "pushback/jit.md"
package pushback::jit;
our $gensym = 0;

sub new
{
  my ($class, $name) = @_;
  bless { parent => undef,
          name   => $name,
          shared => {},
          refs   => {},
          code   => [],
          end    => "" }, $class;
}

sub compile
{
  my $self  = shift;
  die "$$self{name}: must compile the parent JIT context"
    if defined $$self{parent};

  my @args  = sort keys %{$$self{shared}};
  my $setup = sprintf "my (%s) = \@_;", join",", map "\$$_", @args;
  my $code  = join"\n", "use strict;use warnings;",
                        "sub{", $setup, @{$$self{code}}, "}";
  my $sub   = eval $code;
  die "$@ compiling $code" if $@;
  $sub->(@{$$self{shared}}{@args});
}
#line 38 "pushback/jit.md"
sub gensym { "g" . $gensym++ }
sub code
{
  my ($self, $code) = (shift, shift);
  if (ref $code && $code->isa('pushback::jit'))
  {
    %{$$self{shared}} = (%{$$self{shared}}, %{$$code{shared}});
    push @{$$self{code}}, join"\n", @{$$code{code}}, $$code{end};
  }
  else
  {
    my %v;
    while (@_)
    {
      $$self{shared}
            {$v{$_[0]} = $$self{refs}{\$_[1]} //= $self->gensym} = \$_[1];
      shift;
      shift;
    }
    if (keys %v)
    {
      my $vs = join"|", keys %v;
      $code =~ s/([\$@%&])($vs)/"$1\{\$$v{$2}\}"/eg;
    }
    push @{$$self{code}}, $code;
  }
  $self;
}
#line 70 "pushback/jit.md"
sub mark
{
  my $self = shift;
  $self->code("#line 1 \"$$self{name} @_\"");
}
sub if    { shift->block(if    => @_) }
sub while { shift->block(while => @_) }
sub block
{
  my ($self, $type) = (shift, shift);
  $self->code("$type(")->code(@_)->code("){")
       ->child($type, "}");
}
#line 87 "pushback/jit.md"
sub child
{
  my ($self, $name, $end) = @_;
  bless { parent  => $self,
          name    => "$$self{name} $name",
          closure => $$self{closure},
          code    => [],
          end     => $end // "" }, ref $self;
}

sub end
{
  my $self = shift;
  $$self{parent}->code(join"\n", @{$$self{code}}, $$self{end});
}
#line 11 "pushback/mux.md"
package pushback::process;
sub new
{
  my ($class, $fn, @deps) = @_;
  bless { fn   => $fn,
          time => 0,
          n    => 0,
          deps => \@deps }, $class;
}

sub fn
{
  my $self = shift;
  my $jit = pushback::jit->new
    ->code('use Time::HiRes qw/time/;')
    ->code('++$n; $t -= time();', n => $$self{n}, t => $$self{time});

  ref $$self{fn} eq "CODE"
    ? $jit->code('&$f();', f => $$self{fn})
    : $jit->code($$self{fn});

  $jit->code('$t += time();', t => $$self{time})
      ->compile;
}
#line 44 "pushback/mux.md"
package pushback::mux;
sub new
{
  my $class = shift;
  my $avail = \shift;
  my $error = \shift;

  bless { pid_usage      => "\0",
          process_fns    => [],
          process_deps   => [],
          resource_index => [],
          resource_avail => $avail,
          resource_error => $error }, $class;
}

sub next_free_pid
{
  my $self = shift;
  pos($$self{pid_usage}) = 0;
  if ($$self{pid_usage} =~ /([^\xff])/g)
  {
    my $i = pos($$self{pid_usage}) - 1 << 3;
    my $c = ord $1;
    ++$i, $c >>= 1 while $c & 1;
    $i;
  }
  else
  {
    length($$self{pid_usage}) << 3;
  }
}


#line 82 "pushback/mux.md"
sub step
{
  my $self = shift;
  my $run  = 0;
  my ($is, $os, $fs, $r, $w, $re, $we)
    = @$self{qw/ inputs outputs fns rvec wvec revec wevec /};

  my @errors;
  for my $i (0..$#$fs)
  {
    my ($in, $out, $fn) = ($$is[$i], $$os[$i], $$fs[$i]);
    ++$run, &$fn($r, $w, $in, $out) while vec $$r, $in, 1 and vec $$w, $out, 1;
    push @errors, $i if vec $$re, $in, 1 or vec $$we, $out, 1;
  }

  if (@errors)
  {
    @$is[@errors] = ();
    @$os[@errors] = ();
    @$fs[@errors] = ();
    @$is = grep defined, @$is;
    @$os = grep defined, @$os;
    @$fs = grep defined, @$fs;
  }

  $run;
}

sub loop
{
  my $self = shift;
  return 0 unless $self->step;
  1 while $self->step;
}
#line 3 "pushback/io-select.md"
package pushback::io_select;

sub new
{
  my $class = shift;
  my $self = bless { rfds => "\0" x 128,
                     wfds => "\0" x 128,
                     efds => "\0" x 128,
                     rbuf => "\0" x 128,
                     wbuf => "\0" x 128,
                     ebuf => "\0" x 128,
                     ra   => "\0" x 128,
                     wa   => "\0" x 128,
                     ea   => "\0" x 128 }, $class;
  $$self{mux} = pushback::mux->new(
    $$self{ra}, $$self{wa}, $$self{ea}, $$self{ea});
  $self;
}

sub mux { shift->{mux} }

sub read
{
  my ($self, $file) = @_;
  vec($$self{rfds}, fileno $file, 1) = 1;
  vec($$self{efds}, fileno $file, 1) = 1;
  $self;
}

sub write
{
  my ($self, $file) = @_;
  vec($$self{wfds}, fileno $file, 1) = 1;
  vec($$self{efds}, fileno $file, 1) = 1;
  $self;
}

sub step
{
  my ($self, $timeout) = @_;
  $$self{rbuf} = $$self{rfds}; $$self{rbuf} ^= $$self{ra};
  $$self{wbuf} = $$self{wfds}; $$self{wbuf} ^= $$self{wa};
  $$self{ebuf} = $$self{efds}; $$self{ebuf} ^= $$self{ea};

  return 0 unless $$self{rbuf} =~ /[^\0]/ || $$self{wbuf} =~ /[^\0]/;
  defined(select $$self{rbuf}, $$self{wbuf}, $$self{ebuf}, $timeout) or die $!;

  $$self{ra} |= $$self{rbuf};
  $$self{wa} |= $$self{wbuf};
  $$self{ea} |= $$self{ebuf};
  $self;
}

sub loop
{
  my $self = shift;
  $self->step;
  $self->step while $self->mux->loop;
}
#line 3 "pushback/stream.md"
package pushback::stream;
use overload qw/ >> into /;
sub new
{
  my ($class, $in, $out) = @_;
  bless { in  => $in,
          out => $out,
          ops => [] }, $class;
}
1;
__END__
