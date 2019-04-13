# File streams
**TODO:** allocate resources here, not in IO.

```perl
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
```
