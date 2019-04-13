# IO container
An object that manages resource availability/error vectors for real file
descriptors, virtual resources, and timers.

```perl
package pushback::io;
use Time::HiRes qw/time/;

sub new
{
  my ($class, $max_fds) = @_;
  $max_fds //= 1024;
  my $fdset_bytes = $max_fds + 7 >> 3;
  my $avail = "\0" x ($fdset_bytes * 2);
  my $error = "\0" x ($fdset_bytes * 2);

  bless { virtual_usage => "\0",
          timer_queue   => [],
          multiplexer   => pushback::mux->new($avail, $error),
          files         => [],

          avail         => \$avail,
          error         => \$error,
          max_fds       => $max_fds,
          fdset_bytes   => $fdset_bytes,

          fd_read       => \substr($avail, 0,            $fdset_bytes),
          fd_write      => \substr($avail, $fdset_bytes, $fdset_bytes),
          fd_rerror     => \substr($error, 0,            $fdset_bytes),
          fd_werror     => \substr($error, $fdset_bytes, $fdset_bytes),

          fd_rbuf       => "\0" x $fdset_bytes,
          fd_wbuf       => "\0" x $fdset_bytes,
          fd_ebuf       => "\0" x $fdset_bytes }, $class;
}
```


## File IO
```perl
sub read
{
  
}
```
