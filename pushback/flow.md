# Flow point
An omnidirectional cut-through switch for processes to exchange data. Flow
points provide JIT fp/pf proxies and propagate invalidation when switching
between monomorphic and polymorphic modes.

Flow points act as switches, which means they match fps and pfs. This
results in confusing language unless we're careful, so all methods specify
either `fp` (flowpoint to process) or `pf` (process to flowpoint). Any other
terminology is always from the flow point's perspective; "egress" would always
mean `fp`.

Most of the mechanics of flow negotiation are delegated to [simplex
objects](simplex.md).

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
  my $fp_simplex = pushback::simplex->new('fp');
  my $pf_simplex = pushback::simplex->new('pf');
  $fp_simplex->link($pf_simplex);
  $pf_simplex->link($fp_simplex);

  bless { name       => $name // "_" . $flowpoint_id++,
          fp_simplex => $fp_simplex,
          pf_simplex => $pf_simplex,
          flags      => 0 }, $class;
}

sub name { shift->{name} }

sub remain_open
{
  my $self = shift;
  $$self{flags} |= FLAG_REMAIN_OPEN;
  $self;
}
```


## Process-facing API
```perl
sub add_fp;                 # ($proc) -> $self
sub add_pf;                 # ($proc) -> $self
sub remove_fp;              # ($proc) -> $self
sub remove_pf;              # ($proc) -> $self
sub invalidate_fp_jit;      # ($transitively?) -> $self
sub invalidate_pf_jit;      # ($transitively?) -> $self

# Non-JIT entry points
sub close;                  # ($error?) -> $self
sub handle_eof;             # ($proc) -> $early_exit?
```


### JIT interface
Processes use this to JIT their fp/pf ops for better throughput.

```perl
sub jit_fp;                 # ($jit, $proc, $offset, $n, $data) -> $jit
sub jit_pf;                 # ($jit, $proc, $offset, $n, $data) -> $jit
sub jit_fp_set_fpy;         # ($jit, $proc) -> $jit
sub jit_pf_set_fpy;         # ($jit, $proc) -> $jit
```


## Process connections
```perl
sub add_fp
{
  my ($self, $proc) = @_;
  $self->invalidate_jit_pfs if $$self{fp_simplex}->add($proc);
  $$self{writable_fn} = undef;
  $self->writable if $$self{fp_simplex}->is_available;
  $self;
}

sub add_pf
{
  my ($self, $proc) = @_;
  $self->invalidate_jit_fps if $$self{pf_simplex}->add($proc);
  $$self{fpable_fn} = undef;
  $self->fpable if $$self{pf_simplex}->is_available;
  $self;
}

sub remove_fp
{
  my ($self, $proc) = @_;
  $self->invalidate_jit_pfs if $$self{fp_simplex}->remove($proc);
  $self;
}

sub remove_pf
{
  my ($self, $proc) = @_;
  $self->invalidate_jit_fps if $$self{pf_simplex}->remove($proc);
  $self->handle_eof($proc) unless $$self{pf_simplex}->responders;
  $self;
}

sub invalidate_jit_fps
{
  my ($self, $transitively) = @_;
  $_->invalidate_jit_fp($self, $transitively)
    for $$self{fp_simplex}->responders;
  $$self{fp_simplex}->invalidate_jit;
  $self;
}

sub invalidate_jit_pfs
{
  my ($self, $transitively) = @_;
  $_->invalidate_jit_pf($self, $transitively)
    for $$self{pf_simplex}->responders;
  $$self{pf_simplex}->invalidate_jit;
  $self;
}
```

## EOF
This is kind of subtle. Readers can ignore one pf's EOF in either of two
cases:

1. There are more pfs
2. The flow point is set to remain open after the last pf returns EOF
   (presumably more pfs will be added later)

```perl
sub handle_eof
{
  my ($self, $proc) = @_;
  return 0 if $$self{flags} & FLAG_REMAIN_OPEN
           || $$self{pf_simplex}->responders;
  $self->close;
  1;
}

sub close
{
  my ($self, $error) = @_;
  $_->eof($self, $error) for $$self{fp_simplex}->responders;
  $self->invalidate_jit_pfs;
  delete $$self{fp_queue};
  delete $$self{pf_queue};
  delete $$self{fp_simplex};
  delete $$self{pf_simplex};
  $$self{flags} = FLAG_CLOSED;
  $self;
}
```


## Non-JIT IO
This is used when the node is polymorphic. Monomorphic IO is inlined through the
single responder, erasing this flow point from the resulting code.

```perl
sub fp
{
  my $self = shift;
  my $proc = shift;

  die "usage: fp(\$proc, \$offset, \$n, \$data)" if @_ < 3;
  die "$proc cannot fp from closed flow $self" if $$self{flags} & FLAG_CLOSED;

  my $n = $$self{pf_simplex}->request($self, $proc, @_);
  $$self{fp_simplex}->available($self, $proc)
    if defined $proc and $n == pushback::simplex::PENDING;
  $n;
}

sub pf
{
  my $self = shift;
  my $proc = shift;

  die "usage: pf(\$proc, \$offset, \$n, \$data)" if @_ < 3;
  die "$proc cannot pf to closed flow $self" if $$self{flags} & FLAG_CLOSED;

  my $n = $$self{fp_simplex}->request($self, $proc, @_);
  $$self{pf_simplex}->available($self, $proc)
    if defined $proc and $n == pushback::simplex::PENDING;
  $n;
}

sub fpable
{
  my ($self, $proc) = @_;
  $$self{fp_simplex}->available($self, $proc) if defined $proc;

  if (!defined $$self{fpable_fn})
  {
    my $jit = pushback::jit->new
      ->code('sub {');
    $_->jit_flow_fpable($jit, $self) for $$self{pf_simplex}->responders;
    ($$self{fpable_fn} = $jit->code('}')->compile)->();
  }
  else
  {
    $$self{fpable_fn}->();
  }
  $self;
}

sub writable
{
  my ($self, $proc) = @_;
  $$self{pf_simplex}->available($self, $proc) if defined $proc;

  if (!defined $$self{writable_fn})
  {
    my $jit = pushback::jit->new
      ->code('sub {');
    $_->jit_flow_writable($jit, $self) for $$self{fp_simplex}->responders;
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
sub jit_fp
{
  my $self = shift;
  $$self{fp_simplex}->jit_request($self, @_);
}

sub jit_pf
{
  my $self = shift;
  $$self{pf_simplex}->jit_request($self, @_);
}

sub jit_fpable
{
  my ($self, $jit, $proc) = @_;
  $$self{fp_simplex}->jit_available($self, $jit, $proc);

  # Notify pfs that someone will reply to their fp requests.
  $_->jit_flow_fpable($jit, $self) for $$self{pf_simplex}->responders;
  $jit;
}

sub jit_writable
{
  my ($self, $jit, $proc) = @_;
  $$self{pf_simplex}->jit_available($self, $jit, $proc);

  # Notify fps that someone will reply to their pf requests.
  $_->jit_flow_writable($jit, $self) for $$self{fp_simplex}->responders;
  $jit;
}
```
