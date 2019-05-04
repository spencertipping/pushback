# IO container
Anything that interfaces with the outside world or otherwise involves side
effects is owned by an IO container. IO containers don't themselves do IO; this
is delegated to a process that offers data on ports.

```perl
package pushback::io;
use overload qw/ @{} processes /;
sub new
{
  my ($class) = @_;
  bless { processes     => pushback::objectset->new,
          owned_objects => {} }, $class;
}

sub processes { shift->{processes} }

sub add_process
{
  my ($self, $proc) = @_;
  $$self{processes}->add($proc);
}

sub remove_process
{
  my ($self, $proc) = @_;
  TODO_add_objectset_remove_by_reference_not_by_index();
  $self;
}
```
