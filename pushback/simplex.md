# Simplex negotiators
[Flow points](flow.md) match every `read` request with a corresponding `write`
response and vice versa. That logic is managed by simplexes, which negotiate one
side of a full-duplex flow point.

There's some optimization that can happen here. If either simplex of a flow
point has only one source of replies, then we can inline its logic directly into
callers' JIT contexts. This effectively erases the flow point and availability
negotiation from the resulting code.

```perl
package pushback::simplex;
use Scalar::Util qw/refaddr/;

# read()/write() results (also used in JIT fragments)
use constant NOP     =>  0;
use constant PENDING => -1;
use constant EOF     => -2;
use constant RETRY   => -3;

sub new
{
  my ($class, $mode, $queue) = @_;
  bless { mode          => $mode,
          availability  => 0,
          responder_idx => {},
          responders    => [],
          responder_fns => [] }, $class;
}

sub availability   { shift->{availability} }
sub is_monomorphic { @{shift->{responders}} == 1 }
sub responders     { @{shift->{responders}} }
```


## Flow-facing API
```perl
sub add;                    # ($proc) -> $invalidate_jit?
sub remove;                 # ($proc) -> $invalidate_jit?
sub invalidate_jit;         # () -> $self
sub request;                # ($flow, $proc, $offset, $n, $data) -> $n
sub available;              # ($flow, $proc) -> $self

sub jit_request;            # ($flow, $jit, $proc, $offset, $n, $data) -> $jit
sub jit_available;          # ($flow, $jit, $proc) -> $jit
```


## Process connections
```perl
sub add
{
  my ($self, $proc) = @_;
  my $rs = $$self{responders};
  $$self{responder_idx}{refaddr $proc} = push(@$rs, $proc) - 1;
  push @{$$self{responder_fns}}, undef;

  die "can't add more than 64 processes to a flow simplex" if @$rs > 64;
  @$rs < 3;
}

sub remove
{
  my ($self, $proc) = @_;
  my $rs = $$self{responders};
  my $i  = $$self{responder_idx}{refaddr $proc}
    // die "$proc is not present, so can't be removed";

  # TODO: don't move any responders; just create a hole in the array. That will
  # cut down on the amount of JIT invalidation required.
  splice @$rs, $i, 1;
  splice @{$$self{responder_fns}}, $i, 1;

  # Reindex any responders whose positions have changed
  $$self{responder_idx}{refaddr $$rs[$_]} = $_ for $i..$#$rs;

  # Splice the availability bitvector to shift indexes
  my $keep_bits  = $$self{availability} & ~(-1 << $i);
  my $shift_bits = $$self{availability} &   -2 << $i;
  $$self{availability} = $shift_bits >> 1 | $keep_bits;

  @$rs < 2;
}

sub invalidate_jit
{
  my $self = shift;
  @{$$self{responder_fns}} = map undef, @{$$self{responders}};
  $self;
}
```


## Non-JIT IO
This is used when a simplex is negotiated across multiple responders or for an
initial entry point.

```perl
sub process_fn
{
  my ($self, $flow, $i) = @_;
  $$self{responder_fns}[$i] //= $self->jit_fn_for($flow, $i);
}

sub jit_fn_for
{
  my ($self, $flow, $i) = @_;
  my $proc   = $$self{responders}[$i];
  my $method = "jit_$$self{mode}";
  my $jit    = pushback::jit->new
    ->code("#line 1 \"$flow/$proc JIT source\"")
    ->code('sub { ($offset, $n, $data) = @_;',
           offset => my $offset,
           n      => my $n,
           data   => my $data);
  $proc->$method($jit->child('}'), $flow, $offset, $n, $data)->end->compile;
}

sub request
{
  my $self = shift;
  my $a    = \$$self{availability};

  # Requests are served from available responders. If we have none, turn this
  # request into a responder on the opposing simplex by returning PENDING.
  return PENDING unless $$a;

  my $flow   = shift;
  my $proc   = shift;
  my $offset = shift;
  my $len    = shift;

  my $total  = 0;
  my $n      = 0;
  my $fn     = undef;
  my $rs     = $$self{responders};
  my $r      = undef;
  my $i      = 0;
  my $mask   = 0;

  while ($len && $i < @$rs && $$a >> $i)
  {
    # Seek to the next available responder and use it as long as it continues to
    # indicate availability.
    $i++ until $$a >> $i & 1;
    $mask = 1 << $i;
    $fn   = $$self{responder_fns}[$i] //= $self->jit_fn_for($flow, $i);
    $r    = $$self{responders}[$i];

    while ($$a & $mask && $len)
    {
      # Clear availability when we commit to a request. The responder can set
      # the flag while it's running to indicate that further requests are
      # possible.
      $$a &= ~$mask;
      $n   = &$fn($offset, $len, $_[0]);

      die "$r can't reply to flow point $flow with PENDING" if $n == PENDING;
      die "$r over-replied to $flow/$proc: requested $len but got $n"
        if $n > $len;
      return $n if $n == RETRY
                || $n == EOF && $flow->remove_writer($r)->handle_eof($r);

      $total  += $n;
      $offset += $n;
      $len    -= $n;
    }
  }

  $total;
}

sub available
{
  my ($self, $flow, $proc) = @_;
  my $i = $$self{responder_idx}{refaddr $proc}
    // die "$flow can't indicate availability of unmanaged proc $proc";
  $$self{availability} |= 1 << $i;
  $self;
}
```


## JIT logic
```perl
sub jit_request
{
  my $self   = shift;
  my $flow   = shift;
  my $jit    = shift;
  my $proc   = shift;
  my $offset = \shift;
  my $n      = \shift;
  my $data   = \shift;

  if ($self->is_monomorphic)
  {
    my $method = "jit_$$self{mode}";
    ${$$self{responders}}[0]->$method($jit, $flow, $$offset, $$n, $$data);
  }
  else
  {
    $jit->code('$n = &$f($flow, $proc, $offset, $n, $data);',
      f      => $flow->can($$self{mode}),
      flow   => $flow,
      proc   => $proc,
      offset => $$offset,
      n      => $$n,
      data   => $$data);
  }
}

sub jit_available
{
  my ($self, $flow, $jit, $proc) = @_;
  $jit->code('$availability |= '
           . (1 << $$self{responder_idx}{refaddr $proc}) . ';',
           availability => $$self{availability});
}
```
