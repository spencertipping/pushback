# Process metaclass
A process is an object that has a 28-bit numeric ID and up to 65536 ports, each
of which may be connected to one other port on one other process. (Multiway
connections involve delegating to a dedicated process to manage
multicast/round-robin/etc.) Processes participate in a 64-bit address space that
describes their location in a distributed context:

```
<host_id : 20> <object_id : 28> <port_id : 16>
```

Processes jointly JIT their admittance and flow logic, which means
process/process interaction is for the most part inlined. It's much more
expensive to change port connections than it is to move lots of data within a
fixed topology. (You can mitigate the impact of changes by breaking the inlining
chains, which will cause shorter sections of JIT to be invalidated.)


## Connecting to ports
A connection has exactly two endpoints and monopolizes each port it's connected
to. Connections are encoded as numbers assigned to port vectors within
processes:

```
# connect (process 4: port 43) to (process 91: port 7)
$$object4{ports}[43] = $localhost << 44 | 91 << 16 | 7;
$$object91{ports}[7] = $localhost << 44 | 4  << 16 | 43;
```

Process IDs are always nonzero, so connected ports will have truthy values. `0`
represents a disconnected port.


## Topology changes and JIT
**If you change a port connection inside flow code, that change won't be
reflected until the next flow operation.** Specifically, the contract is that
you have to _enter_ a JIT context to deoptimize an inlined topology. We don't
have a zero-latency retry mechanism, in part because re-entry violates the
transactional nature of negotiated IO.

For the most part this shouldn't cause problems; it's uncommon to change the
topology of a connection while that connection is moving data.


## Processes and port allocation
As far as pushback is concerned, ports are just numbers and they're all the
same. Ports can have bidirectional admittance and flow, although most of the
time processes don't use them this way. Just like file descriptors for a Linux
process.

Also like file descriptors, processes refer to ports in two ways. Some ports
have fixed roles, e.g. `stdin` and `stdout` for a simple process. Other ports
are allocated on the fly, for instance `out[i]` for a broadcast process. A
port-management API shouldn't assume a fixed number of ports, but rather should
support assigning a routing role to each port it allocates.


```perl
package pushback::process;
no warnings 'portable';
use constant HOST_MASK => 0xffff_f000_0000_0000;
use constant PROC_MASK => 0x0000_0fff_ffff_0000;
use constant PORT_MASK => 0x0000_0000_0000_ffff;

sub new
{
  my ($class, $id, $io) = @_;
  bless { ports      => [],
          pins       => {},
          process_id => $io->host_id << 44 | $id << 16,
          io         => $io }, $class;
}

sub io          { shift->{io} }
sub ports       { shift->{ports} }
sub process_id  { shift->{process_id} }
sub port_id     { shift->{process_id} | shift }
sub host_id     { shift->{process_id} >> 44 }

sub process_for { shift->{io}->process_for(shift) }

sub connect
{
  my ($self, $port, $destination) = @_;
  return 0 if $$self{ports}[$port];
  $$self{ports}[$port] = $destination;
  $self->process_for($destination)
       ->connect($self, $destination & PORT_MASK, $self->port_id($port));
  $self;
}

sub disconnect
{
  my ($self, $port) = @_;
  my $destination = $$self{ports}[$port];
  return 0 unless $destination;
  $$self{ports}[$port] = 0;
  $self->process_for($destination)->disconnect($destination & PORT_MASK);
  $self;
}
```


## Admittance and flow
Ports don't specify a flow direction; in theory they're fully bidirectional if
the process doesn't limit them.

```perl
sub admittance
{
  # TODO
}

sub flow
{
  # TODO
}
```
