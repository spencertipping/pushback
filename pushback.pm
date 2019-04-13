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
  pos($_[0]) = undef;
  while ($_[0] =~ /([^\0])/g)
  {
    my $i = pos($_[0]) - 1 << 3;
    my $c = ord $1;
    do
    {
      push @r, $i if $c & 1;
      ++$i;
    } while $c >>= 1;
  }
  @r;
}
#line 16 "pushback/jit.md"
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
      $code =~ s/([\$@%&\*])($vs)/"$1\{\$$v{$2}\}"/eg;
    }
    push @{$$self{code}}, $code;
  }
  $self;
}
#line 80 "pushback/jit.md"
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
#line 97 "pushback/jit.md"
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
package pushback::mux;
sub new
{
  my $class = shift;
  my $avail = \shift;
  my $error = \shift;
  bless { pid_usage      => "\0",
          process_fns    => [],
          process_deps   => [],
          processes      => [],
          run_hints      => [],
          check_errors   => 0,
          resource_index => [],
          resource_avail => $avail,
          resource_error => $error }, $class;
}
#line 32 "pushback/mux.md"
sub add
{
  my ($self, $p) = @_;
  my $pid = $self->next_free_pid;

  push @{$$self{process_fns}},  undef until $#{$$self{process_fns}}  >= $pid;
  push @{$$self{process_deps}}, undef until $#{$$self{process_deps}} >= $pid;

  $$self{processes}[$pid]    = $p;
  $$self{process_fns}[$pid]  = $p->fn;
  $$self{process_deps}[$pid] = [$p->deps];

  $self->update_index($pid);
  vec($$self{pid_usage}, $pid, 1) = 1;
  $p->set_pid($self => $pid);
}

sub remove
{
  my ($self, $pid) = @_;
  my $p    = $$self{processes}[$pid];
  my $deps = $$self{process_deps}[$pid];

  $$self{processes}[$pid]    = undef;
  $$self{process_fns}[$pid]  = undef;
  $$self{process_deps}[$pid] = undef;

  $self->update_index($pid, @$deps);
  vec($$self{pid_usage}, $pid, 1) = 0;
  $p->set_pid($self => undef);
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
#line 89 "pushback/mux.md"
use constant EMPTY => [];
sub update_index
{
  my $self = shift;
  my $pid  = shift;
  my $ri   = $$self{resource_index};
  $$ri[$_] = [grep $_ != $pid, @{$$ri[$_] // EMPTY}] for @_;
  push @{$$ri[$_] //= []}, $pid for @{$$self{process_deps}[$pid]};
}
#line 103 "pushback/mux.md"
sub step
{
  my $self = shift;
  my $deps  = $$self{process_deps};
  my $fns   = $$self{process_fns};
  my $avail = $$self{resource_avail};
  my %pids_seen;

  OUTER:
  for my $pid (grep !$pids_seen{$_}++,
               map  @$_, @{$$self{resource_index}}
                          [pushback::bit_indexes $$avail])
  {
    vec $$avail, $_, 1 or next OUTER for @{$$deps[$pid]};
    eval { $$fns[$pid]->() };
    $$self{processes}[$pid]->fail($@) if $@;
  }

  if ($$self{check_errors})
  {
    %pids_seen = ();
    for my $pid (grep !$pids_seen{$_}++,
                 map  @$_, @{$$self{resource_index}}
                            [pushback::bit_indexes ${$$self{resource_error}}])
    {
      eval { $$fns[$pid]->() };
      $$self{processes}[$pid]->fail($@) if $@;
    }
  }

  $self;
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
#line 6 "pushback/process.md"
package pushback::process;
sub when
{
  my ($class, $fn, @deps) = @_;
  bless { fn    => $fn,
          time  => 0,
          n     => 0,
          mux   => undef,
          pid   => undef,
          error => undef,
          deps  => \@deps }, $class;
}
#line 23 "pushback/process.md"
sub kill
{
  my $self = shift;
  die "process is not managed by a multiplexer" unless defined $$self{mux};
  die "process is not running (has no PID)" unless defined $$self{pid};
  $$self{mux}->remove($$self{pid});
  $self;
}
#line 39 "pushback/process.md"
sub fn
{
  my $self = shift;
  my $jit = pushback::jit->new
    ->code('sub {')
    ->code('use Time::HiRes qw/time/;')
    ->code('++$n; $t -= time();', n => $$self{n}, t => $$self{time});

  ref $$self{fn} eq "CODE"
    ? $jit->code('&$f();', f => $$self{fn})
    : $jit->code($$self{fn});

  $jit->code('$t += time();', t => $$self{time})
      ->code('}')
      ->compile;
}
#line 60 "pushback/process.md"
sub set_pid
{
  my $self = shift;
  $$self{mux} = shift;
  $$self{pid} = shift;
  $self;
}

sub fail
{
  my $self = shift;
  $$self{error} = shift;
  $self->kill;
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
