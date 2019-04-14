# Flow point
An omnidirectional cut-through negotiation point for processes to exchange data.
Flow points provide JIT read/write proxies and propagate invalidation when
switching between monomorphic and polymorphic modes.

Most of the mechanics of flow negotiation are delegated to [simplex
objects](simplex.md).

**FIXME:** process -> flow JIT invalidation is too aggressive

```perl
package pushback::flow;

our $flowpoint_id = 0;
sub new
{
  my ($class, $name) = @_;
  my @read_queue;
  my @write_queue;
  bless { name          => $name // "_" . $flowpoint_id++,
          read_queue    => \@read_queue,
          write_queue   => \@write_queue,
          read_simplex  => pushback::simplex->new(read  => \@read_queue),
          write_simplex => pushback::simplex->new(write => \@write_queue),
          remain_open   => 0,
          closed        => 0 }, $class;
}

sub remain_open
{
  my ($self, $remain_open) = @_;
  $$self{remain_open} = $remain_open // 1;
  $self;
}
```


## Process-facing API
```perl
sub add_reader;             # ($proc) -> $self
sub add_writer;             # ($proc) -> $self
sub remove_reader;          # ($proc) -> $self
sub remove_writer;          # ($proc) -> $self
sub invalidate_jit_readers; # () -> $self
sub invalidate_jit_writers; # () -> $self

# Non-JIT entry points
sub handle_eof;             # ($proc) -> $early_exit?
sub read;                   # ($proc, $offset, $n, $data) -> $n
sub write;                  # ($proc, $offset, $n, $data) -> $n
sub close;                  # ($error?) -> $self
sub readable;               # ($proc) -> $self
sub writable;               # ($proc) -> $self

# JIT inliners for monomorphic reads/writes
sub jit_read_fragment;      # ($jit, $proc, $offset, $n, $data) -> $jit
sub jit_write_fragment;     # ($jit, $proc, $offset, $n, $data) -> $jit
```


## Process connections
```perl
sub add_reader
{
  my ($self, $proc) = @_;
  $self->invalidate_jit_writers if $$self{read_simplex}->add($proc);
  $self;
}

sub add_writer
{
  my ($self, $proc) = @_;
  $self->invalidate_jit_readers if $$self{write_simplex}->add($proc);
  $self;
}

sub remove_reader
{
  my ($self, $proc) = @_;
  $self->invalidate_jit_writers if $$self{read_simplex}->remove($proc);
  $$self{read_queue}
    = [grep refaddr($_) != refaddr($proc), @{$$self{read_queue}}];
  $self;
}

sub remove_writer
{
  my ($self, $proc) = @_;
  $self->invalidate_jit_readers if $$self{write_simplex}->remove($proc);
  $$self{write_queue}
    = [grep refaddr($_) != refaddr($proc), @{$$self{write_queue}}];

  $self->handle_eof($proc) unless $$self{write_simplex}->sources;
  $self;
}

sub invalidate_jit_readers
{
  my $self = shift;
  $_->invalidate_jit_reader($self) for $$self{read_simplex}->sources;
  $$self{read_simplex}->invalidate_jit;
  $self;
}

sub invalidate_jit_writers
{
  my $self = shift;
  $_->invalidate_jit_writer($self) for $$self{write_simplex}->sources;
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
  return 0 if $$self{remain_open} || $$self{write_simplex}->sources;
  $self->close;
  1;
}

sub close
{
  my ($self, $error) = @_;
  $_->eof($self, $error) for $$self{read_simplex}->sources;
  $self->invalidate_jit_writers;
  delete $$self{read_simplex};
  delete $$self{write_simplex};
  $$self{closed} = 1;
}
```


## Non-JIT IO
This is used when the node is polymorphic.

```perl
sub read
{
  my $self = shift;
  my $proc = shift;
  die "usage: read(\$proc, \$offset, \$n, \$data)" unless ref $proc;
  die "$proc cannot read from closed flow $self" if $$self{closed};
  my $n = $$self{write_simplex}->request($self, $proc, @_);
  push @{$$self{read_queue}}, $proc if $n == pushback::simplex::PENDING;
  $n;
}

sub write
{
  my $self = shift;
  my $proc = shift;
  die "usage: write(\$proc, \$offset, \$n, \$data)" unless ref $proc;
  die "$proc cannot write to closed flow $self" if $$self{closed};
  my $n = $$self{read_simplex}->request($self, $proc, @_);
  push @{$$self{write_queue}}, $proc if $n == pushback::simplex::PENDING;
  $n;
}

sub readable
{
  my ($self, $proc) = @_;
  push @{$$self{read_queue}}, $proc;
  $self;
}

sub writable
{
  my ($self, $proc) = @_;
  push @{$$self{write_queue}}, $proc;
  $self;
}
```


## JIT logic
```perl
sub jit_read_fragment
{
  my $self = shift;
  $$self{read_simplex}->jit_fragment($self, @_);
}

sub jit_write_fragment
{
  my $self = shift;
  $$self{write_simplex}->jit_fragment($self, @_);
}
```
