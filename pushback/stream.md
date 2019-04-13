# Stream API
Streams wrap IO resource identifiers.

```perl
package pushback::stream;
use overload qw/ >> into /;

sub io  { shift->{io} }
sub in  { shift->{in} }
sub out { shift->{out} }
sub deps
{
  my $self = shift;
  grep defined, @$self{qw/ in out /};
}

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
```


## File streams
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

sub jit_read_op
{
  my ($self, $jit, $data) = @_;
  my $read_bit = \vec ${$$self{io}{avail}}, $$self{in}, 1;
  my $err_bit  = \vec ${$$self{io}{error}}, $$self{in}, 1;
  my $code =
  q{
    defined(sysread $fd, $$data[0] //= "", 65536) or die $!;
    $read_bit = 0;
  };

  $jit->code($code, fd       => $$self{fd},
                    buf      => $$self{buf},
                    read_bit => $$read_bit,
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
    defined(syswrite $fd, $$data[0]) or die $!;
    $write_bit = 0;
  };

  $jit->code($code, fd        => $$self{fd},
                    write_bit => $$write_bit,
                    data      => $data);
}
```
