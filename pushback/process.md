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


## Ports and flow paths
Let's take a simple example like `cat`, which has two ports `in` and `out` and
passes data from `in` to `out`. Any writes to `in` are passed through, as are
any reads from `out` -- just like what you'd expect. Here's a picture:

```
       +---------------+
       |  cat process  |
       |               |
...----|>in        out>|----...
       +---------------+
```

If we wanted to describe the logic for handling a write to `in`, we might be
tempted to write something like this:

```pl
$cat->defadmittance('>in' => '>out');   # NOPE; see below
```

...which is completely wrong, or at the very least is a lot more ambiguous than
we want. The problem is that the above definition assumes two different frames
of reference: `>in` presumably means "us writing into `cat`'s `in`", whereas
`>out` is "`cat` writing into the destination of its `out`". Although uncommon
in practice, there's no particular reason a process wouldn't forward input from
a port to another port on itself: `>in1` -> `>in2` -- and in that case we
obviously don't intend to write to whoever's connected to `in2`.

We need a way to indicate the reference frame, port, and direction all in one
string, which results in the following grammar:

```pl
'<out'          # we are reading from a process's "out" port
'>in'           # we are writing to a process's "in" port
'in<'           # we (the process) are reading from the other end of our "in"
'out>'          # we (the process) are writing to the other end of our "out"
```

These strings all take the form _subject-verb-object_, but with only the
process-side noun actually specified.

That means the right way to describe `cat` flow is this:

```pl
$cat->defadmittance('>in' => 'out>');
```

The above can be read as "someone writing to `cat`'s `in` has the same
admittance as `cat` writing to the endpoint of its `out`".


## Process base class
```perl
package pushback::process;
use overload qw/ == eq_by_refaddr
                 "" describe /;

use Scalar::Util;

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

sub describe
{
  my $self = shift;
  sprintf "[%s, pid=%d, ports=%s]",
    ref($self),
    $$self{process_id},
    join",", map $self->port_name($_) . ($$self{ports}[$_] ? "*" : ""),
                 0..$#{$$self{ports}};
}

sub eq_by_refaddr { Scalar::Util::refaddr shift == Scalar::Util::refaddr shift }

sub io          { shift->{io} }
sub ports       { shift->{ports} }
sub process_id  { shift->{process_id} }
sub host_id     { shift->{process_id} & HOST_MASK }

sub process_for { shift->{io}->process_for(shift) }
sub port_id_for
{
  my ($self, $port) = @_;
  $$self{process_id} | $self->numeric_port($port);
}

sub numeric_port
{
  no strict 'refs';
  my ($self, $port) = @_;
  Scalar::Util::looks_like_number $port
    ? $port
    : ${ref($self) . "::ports"}{$port}
      // die "$self doesn't define a port named $port";
}

sub connect
{
  my ($self, $port, $destination) = @_;
  $port = $self->numeric_port($port);
  return 0 if $$self{ports}[$port];
  $$self{ports}[$port] = $destination;
  $self->process_for($destination)
       ->connect($destination & PORT_MASK, $self->port_id_for($port));
  $self;
}

sub disconnect
{
  my ($self, $port) = @_;
  $port = $self->numeric_port($port);
  my $destination = $$self{ports}[$port];
  return 0 unless $destination;
  $$self{ports}[$port] = 0;
  $self->process_for($destination)->disconnect($destination & PORT_MASK);
  $self;
}

sub connection
{
  my ($self, $port) = @_;
  $port = $self->numeric_port($port);
  my $destination = $$self{ports}[$port];
  $destination ? ($self->process_for($destination), $destination & PORT_MASK)
               : ();
}
```


### Admittance and flow handlers
Before I get into the details here, let's talk about the setup we inherit from
the metaclass.

`pushback::processclass`, defined below, binds two hashes into the package of
the derived class. One is `%package::admittance`, which maps declarative port
specifications like `>in` to the JIT delegates that handle admittance for those
ports along those directions. The other is `%package::flow`, which does the same
thing for flow JIT functions.

It's possible to ask about other end of a connection; for instance, you can say
`$proc->admittance('out>', ...)` to refer to "the write-admittance for whatever
your `out` port is connected to". If the port isn't connected, the admittance
will be zero.

The last complication is that we can refer to ports either by name or by number.

Here's the API:

```pl
sub parse_portspec;             # ($port) -> ($process, $direction, $portname)
sub port_name;                  # ($port_id) -> $port_name | undef
sub jit_admittance;             # ($port, $jit, $flowable) -> $jit
sub jit_flow;                   # ($port, $jit, $flowable) -> $jit
```

```perl
sub zero_flow
{
  my ($proc, $jit, $flowable) = @_;
  $jit->debug("#line 1 \"zero_flow\"");
  $flowable->set_to($jit, 0);
}

sub jit_admittance
{
  no strict 'refs';
  my ($self, $port, $jit, $flowable) = @_;
  $jit->debug("#line 1 \"$self\::admittance($port)\"");

  my ($proc, $direction, $portname) = $self->parse_portspec($port);
  return $proc->jit_admittance("$direction$portname", $jit, $flowable)
    unless $proc == $self;

  my $admittance = \%{ref($self) . "::admittance"};
  ($$admittance{"=$portname"} // $$admittance{"$direction$portname"}
                              // \&zero_flow)->($self, $jit, $flowable);
}

sub jit_flow
{
  no strict 'refs';
  my ($self, $port, $jit, $flowable) = @_;
  $jit->debug("#line 1 \"$self\::flow($port)\"");

  my ($proc, $direction, $portname) = $self->parse_portspec($port);
  return $proc->jit_flow("$direction$portname", $jit, $flowable)
    unless $proc == $self;

  my $flow = \%{ref($self) . "::flow"};
  ($$flow{"=$portname"} // $$flow{"$direction$portname"}
                        // \&zero_flow)->($self, $jit, $flowable);
}
```

Some port handling logic:

```perl
sub parse_portspec
{
  no strict 'refs';
  my ($self, $port) = @_;
  my ($portname, $direction);

  # Handle remote port references: follow and delegate to the endpoint. Preserve
  # direction by prepending it to the destination portspec.
  if (($portname, $direction) = $port =~ /^(\w+)([<>=])$/)
  {
    my ($endpoint, $endport) = $self->connection(
      Scalar::Util::looks_like_number($portname)
        ? $portname
        : ${ref($self) . "::ports"}{$portname}
            // die "$self doesn't define named port $portname");
    return $endpoint->parse_portspec("$direction$endport");
  }

  # We have a local port. Resolve it to a name and infer direction.
  ($portname, $direction) = ($port, "=")
    unless ($direction, $portname) = $port =~ /^([<>=])(\w+)$/;

  if (Scalar::Util::looks_like_number $portname)
  {
    $portname = $self->port_name($portname)
      // die "$self doesn't define $portname";
  }
  else
  {
    die "$self doesn't define named port $portname"
      unless exists ${ref($self) . "::ports"}{$portname};
  }

  ($self, $direction, $portname);
}

sub port_name
{
  no strict 'refs';
  my ($self, $port_index) = @_;
  my $ports = \%{ref($self) . "::ports"};
  $$ports{$_} == $port_index and return $_ for keys %$ports;
  undef;
}
```


## Process metaclass
`pushback::processclass` is a metaclass that extends `pushback::jitclass`,
although process classes are children of `pushback::process` and are unrelated
to any JIT bases.

```perl
package pushback::processclass;
push our @ISA, 'pushback::jitclass';
sub new
{
  my ($class, $name, $vars, $ports) = @_;
  my $self = pushback::jitclass::new $class,
               $name =~ /::/ ? $name : "pushback::processes::$name", $vars;
  $self->isa('pushback::process');
  {
    no strict 'refs';
    no warnings 'once';
    $$self{ports}      = \%{"$$self{package}\::ports"};
    $$self{admittance} = \%{"$$self{package}\::admittance"};
    $$self{flow}       = \%{"$$self{package}\::flow"};
  }

  $$self{port_index} = 0;       # next free port number
  $self->defport($_) for split/\s+/, $ports;
  $self;
}
```


### Defining ports
```pl
sub defport;            # ($name, $name, ...) -> $class
sub defportrange;       # ($name => $size) -> $class
sub defadmittance;      # ($name => $adm) -> $class
sub defflow;            # ($name => $flow) -> $class
```

Port definitions happen in three parts. First, you use `defport` or
`defportrange` to specify that a port exists. This creates named aliases and
makes it possible for other processes to `->connect` to this one using that
port. I'll talk more about ranges below; for now let's discuss single ports.

The second step is to define the admittance of flow through the new port using
`defadmittance`. You can do this in three ways:

1. Refer to another port, e.g. `defadmittance('>in' => 'out>')`
2. Refer to an expression, e.g. `defadmittance('>in' => q{ $cap - @$buf })`
3. Define a JIT handler, discussed below

Lastly you need to define flow behavior for the port using `defflow`, which
provides options (1) and (3) from the list above. (Referring to an expression
wouldn't make sense because flow is a side effect.)

```perl
sub defport
{
  my $self = shift;
  for my $port (@_)
  {
    my $index = $$self{ports}{$port} = $$self{port_index}++;
    $self->def("connect_$port"    => sub { shift->connect($index, @_) })
         ->def("disconnect_$port" => sub { shift->disconnect($index) })
         ->def("$port\_port_id"   => sub { shift->port_id_for($index) });
  }
  $self;
}

sub defadmittance
{
  my ($self, $port, $a) = @_;
  my ($direction, $portname) = $port =~ /^([<>=])(\w+)$/
    or die "defadmittance: '$port' must begin with a direction indicator";
  die "$self doesn't define port $portname"
    unless exists $$self{ports}{$portname};

  my ($aname, $adir);
  if (ref $a)
  {
    $$self{admittance}{$port} = $a;
  }
  elsif (($adir, $aname) = $a =~ /^([<>=])(\w+)$/
      or ($aname, $adir) = $a =~ /^(\w+)([<>=])$/)
  {
    die "$self doesn't define port $aname" unless exists $$self{ports}{$aname};
    die "admittance from $port to $a modifies flow direction"
      unless $adir eq $direction;

    $$self{admittance}{$port} = sub
    {
      my ($proc, $jit, $flowable) = @_;
      $proc->jit_admittance($a, $jit, $flowable);
    };
  }
  else # compile expression
  {
    my $method = "$port\_admittance";
    $self->defjit($method, 'result_', qq{ \$result_ = ($a); });
    $$self{admittance}{$port} = sub
    {
      my ($proc, $jit, $flowable) = @_;
      $proc->$method($jit, my $result);
      $flowable->set_to($jit, $result);
    };
  }

  $self;
}

sub defflow
{
  my ($self, $port, $f) = @_;
  my ($direction, $portname) = $port =~ /^([<>=])(\w+)$/
    or die "defadmittance: '$port' must begin with a direction indicator";
  die "$self doesn't define port $portname"
    unless exists $$self{ports}{$portname};

  my ($fname, $fdir);
  if (ref $f)
  {
    $$self{flow}{$port} = $f;
  }
  elsif (($fdir, $fname) = $f =~ /^([<>=])(\w+)$/
      or ($fname, $fdir) = $f =~ /^(\w+)([<>=])$/)
  {
    die "$self doesn't define port $fname" unless exists $$self{ports}{$fname};
    die "flow from $port to $f modifies direction" unless $fdir eq $direction;

    $$self{flow}{$port} = sub
    {
      my ($proc, $jit, $flowable) = @_;
      $proc->jit_flow($f, $jit, $flowable);
    };
  }
  else
  {
    die "unknown flow delegation spec: '$f' (expecting function, self-route, "
      . "or connection-route)";
  }

  $self;
}
```


### JIT handlers
JIT handlers let you define nontrivial logic to be run prior to JIT
specialization. For example, to define a process whose inflow is the lesser of
two output flows:

```pl
defadmittance('>in', sub
{
  my ($self, $jit, $flowable) = @_;
  $self->admittance('out1>', $jit, my $out1 = $flowable->copy($jit));
  $self->admittance('out2>', $jit, my $out2 = $flowable->copy($jit));
  $out1->intersect($jit, $out2)
       ->intersect($jit, $flowable)
       ->copy($jit, $flowable);
});
```


### Port ranges
You can define a range of ports that share admittance and flow characteristics.
For example, a broadcast process would probably have a range of output ports,
allowing users to connect or disconnect an unspecified number of processes.

**TODO**
