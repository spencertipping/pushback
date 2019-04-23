# IO container
Anything that interfaces with the outside world or otherwise involves side
effects is owned by an IO container. IO containers don't themselves do IO; this
is delegated to a process that offers data on ports.

```perl
package pushback::io;
use overload qw/ @{} processes /;
sub new
{
  my ($class, $host_id) = @_;
  bless { host_id       => $host_id // 0,
          processes     => pushback::objectset->new,
          owned_objects => {} }, $class;
}

sub processes { shift->{processes} }
sub host_id   { shift->{host_id} }

sub add_process
{
  my ($self, $proc) = @_;
  $$self{host_id} << 44 | $$self{processes}->add($proc) << 16;
}

sub remove_process
{
  my ($self, $proc) = @_;
  $proc = $proc->process_id if ref $proc;
  $$self{processes}->remove(($proc & pushback::process::PROC_MASK) >> 16);
  $self;
}

sub process_for
{
  my ($self, $pid) = @_;
  $pid >> 44 == $$self{host_id}
    ? $$self{processes}[($pid & pushback::process::PROC_MASK) >> 16]
    : $self->rpc_for($pid);
}

sub rpc_for { ... }
```
