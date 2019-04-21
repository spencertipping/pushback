# Process metaclass
A process is an object that has a 28-bit numeric ID and up to 65536 ports, each
of which may be connected to one other port on one other process. (Multiway
connections involve delegating to a dedicated process to manage
multicast/round-robin/etc.) Processes participate in a 64-bit address space that
describes their location in a distributed context:

```
<host_id : 20> <object_id : 28> <port_id : 16>
```


## Connecting to ports
A connection has exactly two endpoints and monopolizes each port it's connected
to. Connections are encoded as numbers assigned to port vectors within
processes:

```
# connect (object 4: port 43) to (object 91: port 7)
$$object4{ports}[43] = $localhost << 44 | 91 << 16 | 7;
$$object91{ports}[7] = $localhost << 44 | 4  << 16 | 43;
```

```perl
package pushback::process;
no warnings 'portable';
use constant HOST_MASK => 0xffff_f000_0000_0000;
use constant PROC_MASK => 0x0000_0fff_ffff_0000;
use constant PORT_MASK => 0x0000_0000_0000_ffff;

sub new
{
  my ($class, $io) = @_;
  bless { ports => [],
          io    => $io }, $class;
}

sub io         { shift->{io} }
sub ports      { shift->{ports} }
sub object_for { ${shift->{io}}[shift >> 16 & PROC_MASK >> 16] }

sub connect
{
  my ($self, $port, $destination) = @_;
  return 0 if $$self{ports}[$port];
  $$self{ports}[$port] = $destination;
  $self->object_for($destination)
       ->connect($self, $destination & PORT_MASK, $self->port_id($port));
  $self;
}

sub disconnect
{
  my ($self, $port) = @_;
  my $destination = $$self{ports}[$port];
  return 0 unless $destination;
  $$self{ports}[$port] = 0;
  $self->object_for($destination)->disconnect($destination & PORT_MASK);
  $self;
}
```
