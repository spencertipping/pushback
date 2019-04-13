# IO container
An object that manages resource availability/error vectors for real file
descriptors, virtual resources, and timers.

```perl
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
```


## File API
```perl
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
```


## Processes
```perl
sub add
{
  my ($self, $p) = @_;
  $$self{multiplexer}->add($p);
  $self;
}
```


## Virtual resources
**TODO:** do we want owner objects for these?

```perl
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
```


## Timers
```perl
sub time_to_next
{
  undef;          # TODO
}
```


## `select()` interfacing
This class doesn't call `select` -- or at least, doesn't insist on it. Instead,
it gives you the arguments you should use for `select` and gives you an entry
point for the result. For example:

```pl
my ($r, $w, $e, $timeout) = $io->select_args;
select $$r, $$w, $$e, $timeout;
$io->step;
```

```perl
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
```
