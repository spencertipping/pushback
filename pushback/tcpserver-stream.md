# TCP server streams
```perl
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
```
