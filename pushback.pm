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
#line 3 "pushback/bits.md"
package pushback;
#line 9 "pushback/bits.md"
use Fcntl qw/ :DEFAULT /;
sub set_nonblock
{
  my $fh = shift;
  my $flags = fcntl $fh, F_GETFL, 0 or die $!;
  fcntl $fh, F_SETFL, $flags | O_NONBLOCK;
}
#line 25 "pushback/bits.md"
sub bit_indexes
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
#line 54 "pushback/bits.md"
sub next_zero_bit
{
  pos($_[0]) = 0;
  if ($_[0] =~ /([^\xff])/g)
  {
    my $i = pos($_[0]) - 1 << 3;
    my $c = ord $1;
    ++$i, $c >>= 1 while $c & 1;
    $i;
  }
  else
  {
    length($_[0]) << 3;
  }
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
  my $self = shift;
  die "$$self{name}: must compile the parent JIT context"
    if defined $$self{parent};

  my @args  = sort keys %{$$self{shared}};
  my $setup = sprintf "my (%s) = \@_;", join",", map "\$$_", @args;
  my $code  = join"\n", "use strict;use warnings;",
                        "sub{", $setup, @{$$self{code}}, "}";

  my $sub = eval $code;
  die "$@ compiling $code" if $@;
  $sub->(@{$$self{shared}}{@args});
}
#line 49 "pushback/jit.md"
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
#line 81 "pushback/jit.md"
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
#line 98 "pushback/jit.md"
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
#line 6 "pushback/process.md"
package pushback::process;
sub new
{
  my ($class, $fn, @deps) = @_;
  bless { fn    => $fn,
          time  => 0,
          n     => 0,
          mux   => undef,
          pid   => undef,
          error => undef,
          deps  => [grep defined, @deps] }, $class;
}

sub pid     { shift->{pid} }
sub running { defined shift->{pid} }
sub deps    { @{shift->{deps}} }
#line 27 "pushback/process.md"
sub kill
{
  my $self = shift;
  die "process is not managed by a multiplexer" unless defined $$self{mux};
  die "process is not running (has no PID)" unless defined $$self{pid};
  $$self{mux}->remove($$self{pid});
  $self;
}
#line 43 "pushback/process.md"
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
#line 64 "pushback/process.md"
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
#line 13 "pushback/mux.md"
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

sub running { unpack "%32b*", shift->{pid_usage} }
#line 36 "pushback/mux.md"
sub add
{
  my ($self, $p) = @_;
  my $pid = pushback::next_zero_bit $$self{pid_usage};

  push @{$$self{process_fns}},  undef until $#{$$self{process_fns}}  >= $pid;
  push @{$$self{process_deps}}, undef until $#{$$self{process_deps}} >= $pid;

  my @deps = $p->deps;
  die "no dependencies defined for $p; if you try to run this, it will create "
    . "a tight CPU loop and lock up your multiplexer" unless @deps;

  $$self{processes}[$pid]    = $p;
  $$self{process_fns}[$pid]  = $p->fn;
  $$self{process_deps}[$pid] = \@deps;

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
#line 80 "pushback/mux.md"
use constant EMPTY => [];
sub update_index
{
  my $self = shift;
  my $pid  = shift;
  my $ri   = $$self{resource_index};
  $$ri[$_] = [grep $_ != $pid, @{$$ri[$_] // EMPTY}] for @_;
  push @{$$ri[$_] //= []}, $pid for @{$$self{process_deps}[$pid]};
}
#line 94 "pushback/mux.md"
sub step
{
  my $self  = shift;
  my $deps  = $$self{process_deps};
  my $fns   = $$self{process_fns};
  my $avail = $$self{resource_avail};
  my %pids_seen;

  OUTER:
  for my $pid (grep !$pids_seen{$_}++,
               map  @{$_ // EMPTY},
                    @{$$self{resource_index}}
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
                 map  @{$_ // EMPTY},
                      @{$$self{resource_index}}
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
#line 6 "pushback/io.md"
package pushback::io;
use overload qw/ << add /;
use Time::HiRes qw/time/;

sub new
{
  my ($class, $max_fds) = @_;
  $max_fds //= 1024;
  die "max_fds must be a multiple of 8" if $max_fds & 7;
  my $fdset_bytes = $max_fds + 7 >> 3;
  my $avail = "\0" x ($fdset_bytes * 2);
  my $error = "\0" x ($fdset_bytes * 2);

  bless { virtual_usage  => "\0",
          virtual_offset => $max_fds * 2,
          timers         => [],
          next_timer     => undef,
          multiplexer    => pushback::mux->new($avail, $error),
          files          => [],
          max_fds        => $max_fds,
          fdset_bytes    => $fdset_bytes,

          fds_to_read    => "\0" x $fdset_bytes,
          fds_to_write   => "\0" x $fdset_bytes,
          fds_to_error   => "\0" x $fdset_bytes,
          avail          => \$avail,
          error          => \$error,

          # Views of substrings to enable fast vector operations against parts
          # of $avail and $error.
          fd_ravail => \substr($avail, 0,            $fdset_bytes),
          fd_wavail => \substr($avail, $fdset_bytes, $fdset_bytes),
          fd_rerror => \substr($error, 0,            $fdset_bytes),
          fd_werror => \substr($error, $fdset_bytes, $fdset_bytes),

          # Preallocated memory so we can use in-place bitvector operations.
          fd_rbuf => "\0" x $fdset_bytes,
          fd_wbuf => "\0" x $fdset_bytes,
          fd_ebuf => "\0" x $fdset_bytes }, $class;
}

sub running { shift->{multiplexer}->running }
sub select_loop
{
  my $self = shift;
  while ($self->running)
  {
    my ($r, $w, $e, $timeout) = $self->select_args;

    printf STDERR "r = %s ; w = %s ; e = %s... ",
      join(",", pushback::bit_indexes $$r),
      join(",", pushback::bit_indexes $$w),
      join(",", pushback::bit_indexes $$e);

    select $$r, $$w, $$e, $timeout;

    printf STDERR " -> r = %s ; w = %s ; e = %s\n",
      join(",", pushback::bit_indexes $$r),
      join(",", pushback::bit_indexes $$w),
      join(",", pushback::bit_indexes $$e);

    $self->step;
  }
  $self;
}
#line 76 "pushback/io.md"
sub read
{
  my ($self, $f) = @_;
  my $fd = fileno $f;
  pushback::set_nonblock $f;
  $$self{files}[$fd] = $f;
  vec($$self{fds_to_read}, $fd, 1) = 1;
  vec($$self{fds_to_error}, $fd, 1) = 1;
  pushback::fd_stream->reader($self, $fd, $fd);
}

sub write
{
  my ($self, $f) = @_;
  my $fd = fileno $f;
  pushback::set_nonblock $f;
  $$self{files}[$fd] = $f;
  vec($$self{fds_to_write}, $fd, 1) = 1;
  vec($$self{fds_to_error}, $fd, 1) = 1;
  pushback::fd_stream->writer($self, $fd, $fd + $$self{max_fds});
}

sub file
{
  my ($self, $fd) = @_;
  $$self{files}[$fd];
}
#line 108 "pushback/io.md"
sub add
{
  my ($self, $p) = @_;
  $$self{multiplexer}->add($p);
  $self;
}
#line 121 "pushback/io.md"
sub create_virtual
{
  my $self  = shift;
  my $index = pushback::next_zero_bit $$self{pid_usage};
  my $id    = $index + $$self{virtual_offset};
  vec($$self{virtual_usage}, $index, 1) = 1;
  vec($$self{avail}, $id, 1) = 0;
  vec($$self{error}, $id, 1) = 0;
  $id;
}

sub delete_virtual
{
  my ($self, $id) = @_;
  vec($$self{virtual_usage}, $id - $$self{virtual_offset}, 1) = 0;
  $self;
}
#line 143 "pushback/io.md"
sub time_to_next
{
  undef;          # TODO
}
#line 162 "pushback/io.md"
sub select_args
{
  my $self = shift;
  $$self{fd_rbuf} = $$self{fds_to_read};
  $$self{fd_wbuf} = $$self{fds_to_write};
  $$self{fd_ebuf} = $$self{fds_to_error};

  # Remove any fds whose status is already known.
  $$self{fd_rbuf} ^= ${$$self{fd_ravail}};
  $$self{fd_wbuf} ^= ${$$self{fd_wavail}};
  $$self{fd_ebuf} ^= ${$$self{fd_rerror}};

  (\$$self{fd_rbuf}, \$$self{fd_wbuf}, \$$self{fd_ebuf}, $self->time_to_next);
}

sub step
{
  my $self = shift;

  # Assume an external call has updated $$self{fd_rbuf} etc with new fd
  # availability.
  ${$$self{fd_ravail}} |= $$self{fd_rbuf};
  ${$$self{fd_wavail}} |= $$self{fd_wbuf};
  ${$$self{fd_rerror}} |= $$self{fd_ebuf};
  ${$$self{fd_werror}}  = ${$$self{fd_rerror}};

  $$self{multiplexer}->step;
  $self;
}
#line 5 "pushback/stream.md"
package pushback::stream;
use overload qw/ >> into /;

sub io  { shift->{io} }
sub in  { shift->{in} }
sub out { shift->{out} }
sub deps { grep defined, @{+shift}{qw/ in out /} }

sub jit_read_op  { die "unimplemented JIT read op for $_[0]" }
sub jit_write_op { die "unimplemented JIT write op for $_[0]" }

sub into
{
  my ($self, $dest) = @_;
  my @data;
  my $jit = pushback::jit->new;
  $self->jit_read_op($jit, \@data);
  $dest->jit_write_op($jit, \@data);
  pushback::process->new($jit, $$self{in}, $$dest{out});
}
#line 5 "pushback/callback-stream.md"
package pushback::callback_stream;
push our @ISA, 'pushback::stream';

sub pushback::io::each
{
  my ($io, $fn) = @_;
  pushback::callback_stream->new($io, $fn);
}

sub new
{
  my ($class, $io, $fn) = @_;
  bless { io => $io,
          fn => $fn }, $class;
}

sub jit_write_op
{
  my ($self, $jit, $data) = @_;
  $jit->code(q{ &$fn(@$data); }, fn => $$self{fn}, data => $data);
}
#line 5 "pushback/file-stream.md"
package pushback::fd_stream;
push our @ISA, 'pushback::stream';

sub reader
{
  my ($class, $io, $fd, $resource) = @_;
  bless { io  => $io,
          fd  => $fd,
          in  => $resource,
          out => undef }, $class;
}

sub writer
{
  my ($class, $io, $fd, $resource) = @_;
  bless { io  => $io,
          fd  => $fd,
          in  => undef,
          out => $resource }, $class;
}

sub no_errors
{
  my $self = shift;
  vec($$self{io}{fds_to_error}, $$self{fd}, 1) = 0;
  vec(${$$self{io}{fd_rerror}}, $$self{fd}, 1) = 0;
  vec(${$$self{io}{fd_werror}}, $$self{fd}, 1) = 0;
  $self;
}

sub jit_read_op
{
  my ($self, $jit, $data) = @_;
  my $read_bit = \vec ${$$self{io}{avail}}, $$self{in}, 1;
  my $err_bit  = \vec ${$$self{io}{error}}, $$self{in}, 1;
  my $code =
  q{
    if ($read_bit && defined fileno $fh)
    {
      @$data = ("", undef);
      printf STDERR "read(%d)...", fileno $fh;
      sysread($fh, $$data[0], 65536) or @$data = (undef, $!);
      printf STDERR "done\n";
    }
    else
    {
      sysread $fh, $$data[0] = "", 0;
      @$data = (undef, $!);
      $err_bit = 0;
    }
    $read_bit = 0;
    close $fh, $fh = undef unless defined $$data[0];
    print STDERR "$$data[1]\n" if defined $$data[1];
  };

  $jit->code($code, fh       => $$self{io}->file($$self{fd}),
                    read_bit => $$read_bit,
                    err_bit  => $$err_bit,
                    data     => $data);
}

sub jit_write_op
{
  my ($self, $jit, $data) = @_;
  my $write_bit = \vec ${$$self{io}{avail}}, $$self{out}, 1;
  my $err_bit   = \vec ${$$self{io}{error}}, $$self{out}, 1;

  # TODO: buffer for incomplete writes; this involves allocating a virtual
  # resource for buffer writability.
  my $code =
  q{
    if ($write_bit && defined fileno $fh)
    {
      printf STDERR "write(%d)...", fileno $fh;
      defined(syswrite $fh, $$data[0]) or die $! if defined $$data[0];
      printf STDERR "done\n";
    }
    else
    {
      close $fh if defined fileno $fh;
      $err_bit = 0;
      die;
    }
    $write_bit = 0;
  };

  $jit->code($code, fh        => $$self{io}->file($$self{fd}),
                    write_bit => $$write_bit,
                    err_bit   => $$err_bit,
                    data      => $data);
}
#line 3 "pushback/tcpserver-stream.md"
package pushback::tcp_stream;
push our @ISA, 'pushback::stream';

use Socket;

sub pushback::io::tcp_server
{
  my ($io, $port, $host) = @_;
  pushback::tcp_stream->listen($io, $port, $host);
}

sub listen
{
  my ($class, $io, $port, $host) = @_;
  $host //= 'localhost';
  socket  my $s, PF_INET, SOCK_STREAM, getprotobyname 'tcp' or die $!;
  setsockopt $s, SOL_SOCKET, SO_REUSEADDR, pack l => 1      or die $!;
  bind       $s, pack_sockaddr_in $port, inet_aton $host    or die $!;
  listen     $s, SOMAXCONN                                  or die $!;

  pushback::set_nonblock $s;

  bless { io   => $io,
          in   => fileno $s,
          out  => undef,
          sock => $s,
          r    => $io->read($s)->no_errors,
          host => $host,
          port => $port }, $class;
}

sub jit_read_op
{
  my ($self, $jit, $data) = @_;
  my $read_bit = \vec ${$$self{io}{avail}}, $$self{in}, 1;
  my $err_bit  = \vec ${$$self{io}{error}}, $$self{in}, 1;
  my $code =
  q{
    @$data = (undef, undef, undef, undef);
    printf STDERR "accept(%d)... ", fileno $sock;
    if ($$data[2] = accept $$data[0], $sock)
    {
      $$data[1] = $io->write($$data[0]);
      $$data[0] = $io->read($$data[0]);
    }
    else
    {
      $$data[3] = $!;
    }
    print STDERR "done\n";
    $read_bit = $err_bit = 0;
  };

  $jit->code($code, sock     => $$self{sock},
                    io       => $$self{io},
                    read_bit => $$read_bit,
                    err_bit  => $$err_bit,
                    data     => $data);
}
1;
__END__
