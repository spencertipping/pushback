# Flow point
An omnidirectional cut-through switch for processes to exchange data. Flow
points provide JIT read/write proxies and propagate invalidation when switching
between monomorphic and polymorphic modes.

Most of the mechanics of flow negotiation are delegated to [simplex
objects](simplex.md).

**TODO:** push more duplicated logic into simplex

**TODO:** clean up JIT invalidation, especially around availability

```perl
package pushback::flow;
use overload qw/ "" name /;

use constant FLAG_CLOSED        => 0x01;
use constant FLAG_REMAIN_OPEN   => 0x02;
#use constant FLAG_NO_SPECIALIZE => 0x04;   TODO

our $flowpoint_id = 0;
sub new
{
  my ($class, $name) = @_;
  bless { name          => $name // "_" . $flowpoint_id++,
          read_simplex  => pushback::simplex->new('read'),
          write_simplex => pushback::simplex->new('write'),

          readable_fn   => undef,
          writable_fn   => undef,
          flags         => 0 }, $class;
}

sub read_monomorphic  { shift->{read_simplex}->is_monomorphic }
sub write_monomorphic { shift->{write_simplex}->is_monomorphic }
sub name              { shift->{name} }

sub remain_open
{
  my $self = shift;
  $$self{flags} |= FLAG_REMAIN_OPEN;
  $self;
}
```


## Process-facing API
```perl
sub add_reader;             # ($proc) -> $self
sub add_writer;             # ($proc) -> $self
sub remove_reader;          # ($proc) -> $self
sub remove_writer;          # ($proc) -> $self
sub invalidate_jit_readers; # ($transitively?) -> $self
sub invalidate_jit_writers; # ($transitively?) -> $self

# Non-JIT entry points
sub handle_eof;             # ($proc) -> $early_exit?
sub read;                   # ($proc, $offset, $n, $data) -> $n
sub write;                  # ($proc, $offset, $n, $data) -> $n
sub close;                  # ($error?) -> $self
sub readable;               # ($proc) -> $self
sub writable;               # ($proc) -> $self
```


### JIT interface
Processes use this to JIT their read/write ops for better throughput.

```perl
sub jit_read;               # ($jit, $proc, $offset, $n, $data) -> $jit
sub jit_write;              # ($jit, $proc, $offset, $n, $data) -> $jit
sub jit_readable;           # ($jit, $proc) -> $jit
sub jit_writable;           # ($jit, $proc) -> $jit
```


## Process connections
```perl
sub add_reader
{
  my ($self, $proc) = @_;
  $self->invalidate_jit_writers if $$self{read_simplex}->add($proc);
  $$self{writable_fn} = undef;
  $self->writable if $$self{read_simplex}->is_available;
  $self;
}

sub add_writer
{
  my ($self, $proc) = @_;
  $self->invalidate_jit_readers if $$self{write_simplex}->add($proc);
  $$self{readable_fn} = undef;
  $self->readable if $$self{write_simplex}->is_available;
  $self;
}

sub remove_reader
{
  my ($self, $proc) = @_;
  $self->invalidate_jit_writers if $$self{read_simplex}->remove($proc);
  $self;
}

sub remove_writer
{
  my ($self, $proc) = @_;
  $self->invalidate_jit_readers if $$self{write_simplex}->remove($proc);
  $self->handle_eof($proc) unless $$self{write_simplex}->responders;
  $self;
}

sub invalidate_jit_readers
{
  my ($self, $transitively) = @_;
  $_->invalidate_jit_reader($self, $transitively)
    for $$self{read_simplex}->responders;
  $$self{read_simplex}->invalidate_jit;
  $self;
}

sub invalidate_jit_writers
{
  my ($self, $transitively) = @_;
  $_->invalidate_jit_writer($self, $transitively)
    for $$self{write_simplex}->responders;
  $$self{write_simplex}->invalidate_jit;
  $self;
}
```

## EOF
This is kind of subtle. Readers can ignore one writer's EOF in either of two
cases:

1. There are more writers
2. The flow point is set to remain open after the last writer returns EOF
   (presumably more writers will be added later)

```perl
sub handle_eof
{
  my ($self, $proc) = @_;
  return 0 if $$self{flags} & FLAG_REMAIN_OPEN
           || $$self{write_simplex}->responders;
  $self->close;
  1;
}

sub close
{
  my ($self, $error) = @_;
  $_->eof($self, $error) for $$self{read_simplex}->responders;
  $self->invalidate_jit_writers;
  delete $$self{read_queue};
  delete $$self{write_queue};
  delete $$self{read_simplex};
  delete $$self{write_simplex};
  $$self{flags} = FLAG_CLOSED;
  $self;
}
```


## Non-JIT IO
This is used when the node is polymorphic. Monomorphic IO is inlined through the
single responder, erasing this flow point from the resulting code.

```perl
sub read
{
  my $self = shift;
  my $proc = shift;

  die "usage: read(\$proc, \$offset, \$n, \$data)" if @_ < 3;
  die "$proc cannot read from closed flow $self" if $$self{flags} & FLAG_CLOSED;

  my $n = $$self{write_simplex}->request($self, $proc, @_);
  $$self{read_simplex}->available($self, $proc)
    if defined $proc and $n == pushback::simplex::PENDING;
  $n;
}

sub write
{
  my $self = shift;
  my $proc = shift;

  die "usage: write(\$proc, \$offset, \$n, \$data)" if @_ < 3;
  die "$proc cannot write to closed flow $self" if $$self{flags} & FLAG_CLOSED;

  my $n = $$self{read_simplex}->request($self, $proc, @_);
  $$self{write_simplex}->available($self, $proc)
    if defined $proc and $n == pushback::simplex::PENDING;
  $n;
}

sub readable
{
  my ($self, $proc) = @_;
  $$self{read_simplex}->available($self, $proc) if defined $proc;

  if (!defined $$self{readable_fn})
  {
    my $jit = pushback::jit->new
      ->code('sub {');
    $_->jit_flow_readable($jit, $self) for $$self{write_simplex}->responders;
    ($$self{readable_fn} = $jit->code('}')->compile)->();
  }
  else
  {
    $$self{readable_fn}->();
  }
  $self;
}

sub writable
{
  my ($self, $proc) = @_;
  $$self{write_simplex}->available($self, $proc) if defined $proc;

  if (!defined $$self{writable_fn})
  {
    my $jit = pushback::jit->new
      ->code('sub {');
    $_->jit_flow_writable($jit, $self) for $$self{read_simplex}->responders;
    ($$self{writable_fn} = $jit->code('}')->compile)->();
  }
  else
  {
    $$self{writable_fn}->();
  }
  $self;
}
```


## JIT logic
```perl
sub jit_read
{
  my $self = shift;
  $$self{read_simplex}->jit_request($self, @_);
}

sub jit_write
{
  my $self = shift;
  $$self{write_simplex}->jit_request($self, @_);
}

sub jit_readable
{
  my ($self, $jit, $proc) = @_;
  $$self{read_simplex}->jit_available($self, $jit, $proc);

  # Notify writers that someone will reply to their read requests.
  $_->jit_flow_readable($jit, $self) for $$self{write_simplex}->responders;
  $jit;
}

sub jit_writable
{
  my ($self, $jit, $proc) = @_;
  $$self{write_simplex}->jit_available($self, $jit, $proc);

  # Notify readers that someone will reply to their write requests.
  $_->jit_flow_writable($jit, $self) for $$self{read_simplex}->responders;
  $jit;
}
```
