# Process metaclass
A process is an object that has a 28-bit numeric ID and up to 65536 ports, each
of which may be connected to one other port on one other process. (Multiway
connections involve delegating to a dedicated process to manage
multicast/round-robin/etc.) Processes participate in a 64-bit address space that
describes their location in a distributed context:

```
<host_id : 20> <object_id : 28> <port_id : 16>
```

Individual ID components are always referred to in their final bit locations.
This means host IDs will always have their low 44 bits set to zero.


## Background and architectural considerations
Processes jointly JIT their admittance and flow logic, which means
process/process interaction is for the most part inlined. It's much more
expensive to change port connections than it is to move lots of data within a
fixed topology. (You can mitigate the impact of changes by breaking the inlining
chains, which will cause shorter sections of JIT to be invalidated.)


### Connecting to ports
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


### Topology changes and JIT
**If you change a port connection inside flow code, that change won't be
reflected until the next flow operation.** Specifically, the contract is that
you have to _enter_ a JIT context to deoptimize an inlined topology. We don't
have a zero-latency retry mechanism, in part because re-entry violates the
transactional nature of negotiated IO.

For the most part this shouldn't cause problems; it's uncommon to change the
topology of a connection while that connection is moving data.


### Memory management and dependency pinning
Most references to processes, particularly through process IDs, aren't strong
enough to pin them into the live set. There are three ways for a process to
persist beyond you holding onto it:

1. It's a "core service" for the IO container, e.g. file IO. Most processes
   aren't core services.
2. It's considered to be an IO-owned side effect, e.g. `each($fn)`. It's then up
   to you to un-pin the process to free it.
3. It's a dependency of a process that's pinned by rules (1) or (2).

...so what's a dependency given that flow direction is ambiguous? The short
answer is that input-like things are dependencies. If I say something like
`$stdin->map(...)->grep(...)`, `grep` depends on `map`, which depends on
`$stdin`. `grep` (and by extension, `map`) will go away if I drop my reference
to it.

If, on the other hand, I connect it to `$stdout` (which let's assume is an IO
side effect), then `$stdout` will pin `grep` as a dependency and hold the
reference. At this point the IO container has a full-circuit reference
structure, which is appropriate because it's managing side effects that
presumably live beyond our lexical scope.


## Process base class
```perl
package pushback::process;
no warnings 'portable';
use constant HOST_MASK => 0xffff_f000_0000_0000;
use constant PROC_MASK => 0x0000_0fff_ffff_0000;
use constant PORT_MASK => 0x0000_0000_0000_ffff;

sub new
{
  my ($class, $io) = @_;
  my $self = bless { ports      => [],
                     pins       => {},
                     process_id => 0,
                     io         => $io }, $class;
  $$self{process_id} = $io->add_process($self);
  $self;
}

sub DESTROY
{
  my $self = shift;
  $$self{io}->remove_process($$self{process_id});
  die "TODO: disconnect ports";
}

sub io          { shift->{io} }
sub ports       { shift->{ports} }
sub process_id  { shift->{process_id} }
sub host_id     { shift->{process_id} & HOST_MASK }

sub port_id_for { shift->{process_id} | shift }
sub process_for { shift->{io}->process_for(shift) }

sub connect
{
  my ($self, $port, $destination) = @_;
  return 0 if $$self{ports}[$port];
  $$self{ports}[$port] = $destination;
  $self->process_for($destination)
       ->connect($self, $destination & PORT_MASK, $self->port_id_for($port));
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


## Writing a process
Let's start with the simplest possible thing: a cut-through version of `cat`
with two ports, `in` and `out`, and one flow path from `in` to `out`. Super,
super simple.

```pl
my $cat = pushback::processclass->new('cat', 'in out');
```

Both flow and admittance into `in` and out of `out` are passed straight through
to the opposite port. Admittance out of `in` and into `out` are both zero since
that would be a backflow of data. We don't have to specify those flow
directions; any path we don't explicitly handle will have zero admittance.
