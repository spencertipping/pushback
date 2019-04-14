# Flow point
An omnidirectional cut-through negotiation point for processes to exchange data.
Flow points provide JIT read/write proxies and propagate invalidation when
switching between monomorphic and polymorphic modes.

**TODO:** implement as two half-duplex pieces to reduce code duplication

```perl
package pushback::flow;
use Scalar::Util qw/refaddr/;

# read()/write() results (also used in JIT fragments)
use constant PENDING => 0;
use constant EOF     => -1;
use constant RETRY   => -2;

our $flowpoint_id = 0;
sub new
{
  my ($class, $name) = @_;
  bless { name      => $name // "_" . $flowpoint_id++,
          readers   => {},
          writers   => {},
          read_fns  => {},
          write_fns => {},
          queue     => [],
          closed    => 0,
          pressure  => 0 }, $class;
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
sub process_read_fn;        # ($proc) -> $fn
sub process_write_fn;       # ($proc) -> $fn
sub read;                   # ($proc, $offset, $n, $data) -> $n
sub write;                  # ($proc, $offset, $n, $data) -> $n
sub close;                  # ($error?) -> $self

# JIT inliners for monomorphic reads/writes
sub jit_read_fragment;      # ($jit, $proc, $offset, $n, $data) -> $jit
sub jit_write_fragment;     # ($jit, $proc, $offset, $n, $data) -> $jit
```


## Process connections
```perl
sub add_reader
{
  my ($self, $proc) = @_;
  $$self{readers}{$proc->name} = $proc;
  $self->invalidate_jit_writers if keys %{$$self{readers}} < 3;
  $self;
}

sub add_writer
{
  my ($self, $proc) = @_;
  $$self{writers}{$proc->name} = $proc;
  $self->invalidate_jit_readers if keys %{$$self{writers}} < 3;
  $self;
}

sub remove_reader
{
  my ($self, $proc) = @_;
  delete $$self{readers}{$proc->name};
  $self->invalidate_jit_writers if keys %{$$self{readers}} < 2;
  $self;
}

sub remove_writer
{
  my ($self, $proc) = @_;
  delete $$self{writers}{$proc->name};
  $self->invalidate_jit_readers if keys %{$$self{writers}} < 2;
  $self;
}

sub invalidate_jit_readers
{
  my $self = shift;
  $_->invalidate_jit_reader($self) for values %{$$self{readers}};
  %{$$self{read_fns}} = ();
  $self;
}

sub invalidate_jit_writers
{
  my $self = shift;
  $_->invalidate_jit_writer($self) for values %{$$self{writers}};
  %{$$self{write_fns}} = ();
  $self;
}

sub close
{
  my ($self, $error) = @_;
  $_->eof($self, $error) for values %{$$self{readers}};
  delete @{$$self}{qw/ readers writers read_fns write_fns /};
  $$self{closed} = 1;
  $self->invalidate_jit_writers;
}
```


## Non-JIT IO
This is used when the node is polymorphic.

```perl
sub process_read_fn
{
  my ($self, $proc) = @_;
  $$self{read_fns}{refaddr $proc} //= $self->jit_read_fn_for_($proc);
}

sub jit_read_fn_for_
{
  my ($self, $proc) = @_;
  my ($offset, $n, $data);
  my $jit = pushback::jit->new
    ->code("#line 1 \"$self/$proc JIT reader\"")
    ->code('sub { ($offset, $n, $data) = @_;',
           offset => $offset,
           n      => $n,
           data   => $data);
  $proc->jit_read($jit->child('}'), $self, $offset, $n, $data);
  $jit->end->compile;
}

sub process_write_fn
{
  my ($self, $proc) = @_;
  $$self{write_fns}{refaddr $proc} //= $self->jit_write_fn_for_($proc);
}

sub jit_write_fn_for_
{
  my ($self, $proc) = @_;
  my ($offset, $n, $data);
  my $jit = pushback::jit->new
    ->code("#line 1 \"$self/$proc JIT writer\"")
    ->code('sub { ($offset, $n, $data) = @_;',
           offset => $offset,
           n      => $n,
           data   => $data);
  $proc->jit_write($jit->child('}'), $self, $offset, $n, $data);
  $jit->end->compile;
}

sub read
{
  my $self = shift;
  my $proc = shift;
  die "$proc cannot read from closed flow $self" if $$self{closed};
  if ($$self{pressure} <= 0)
  {
    $$self{pressure} -= $_[0];
    push @{$$self{queue}}, $proc;
    return PENDING;
  }

  # The queue contains writers. Go through their write functions and pull data
  # until the read is complete or we run out of queue entries; at that point
  # we'll return a partial success.
  my $offset = shift;
  my $n      = shift;
  my ($total, $r, $writer) = (0, undef, undef);
  while ($n && defined($writer = shift @{$$self{queue}}))
  {
  retry:
    $r = $self->process_write_fn($writer)->($offset, $n, $_[0]);
    die "$writer overwrote data into $self/$proc: requested $n but got $r"
      if $r > $n;
    goto retry if $r == RETRY;
    return EOF if $r == EOF && $self->handle_eof($writer);
    $total += $r;
    $offset += $r;
    $n -= $r;
  }
  $$self{pressure} -= $total;
  $total;
}

sub write
{
  my $self = shift;
  my $proc = shift;
  die "$proc cannot write to closed flow $self" if $$self{closed};
  if ($$self{pressure} >= 0)
  {
    $$self{pressure} += $_[0];
    push @{$$self{queue}}, $proc;
    return PENDING;
  }

  my $offset = shift;
  my $n      = shift;
  my ($total, $w, $reader) = (0, undef, undef);
  while ($n && defined($reader = shift @{$$self{queue}}))
  {
  retry:
    $w = $self->process_read_fn($reader)->($offset, $n, $_[0]);
    die "$reader overread data from $self/$proc: requested $n but got $w"
      if $w > $n;
    goto retry if $w == RETRY;
    return EOF if $w == EOF && $self->process_eof($reader);
    $total += $w;
    $offset += $w;
    $n -= $w;
  }
  $$self{pressure} += $total;
  $total;
}
```


## JIT logic
```perl
sub jit_read_fragment
{
  my $self   = shift;
  my $jit    = shift;
  my $proc   = shift;
  my $offset = \shift;
  my $n      = \shift;
  my $data   = \shift;

  if (keys %{$$self{readers}} == 1)
  {
    my ($r) = values %{$$self{readers}};
    $r->jit_read($jit, $self, $$offset, $$n, $$data);
  }
  else
  {
    $jit->code('$n = &$f($flow, $proc, $offset, $n, $data);',
      f      => $self->can('read'),
      flow   => $self,
      proc   => $proc,
      offset => $$offset,
      n      => $$n,
      data   => $$data);
  }
}

sub jit_write_fragment
{
  my $self   = shift;
  my $jit    = shift;
  my $proc   = shift;
  my $offset = \shift;
  my $n      = \shift;
  my $data   = \shift;

  if (keys %{$$self{writers}} == 1)
  {
    my ($r) = values %{$$self{writers}};
    $r->jit_write($jit, $self, $$offset, $$n, $$data);
  }
  else
  {
    $jit->code('$n = &$f($flow, $proc, $offset, $n, $data);',
      f      => $self->can('write'),
      flow   => $self,
      proc   => $proc,
      offset => $$offset,
      n      => $$n,
      data   => $$data);
  }
}
```
