# Simplex negotiators
```perl
package pushback::simplex;
sub new
{
  my ($class, $mode, $queue) = @_;
  bless { mode       => $mode,
          queue      => $queue,
          sources    => {},
          source_fns => {} }, $class;
}

sub is_monomorphic { keys   %{shift->{sources}} == 1 }
sub sources        { values %{shift->{sources}} }
```


## Flow-facing API
```perl
sub add;                    # ($proc) -> $self
sub remove;                 # ($proc) -> $self
sub invalidate_jit;         # () -> $self
sub request;                # ($flow, $proc, $offset, $n, $data) -> $n
sub jit_fragment;           # ($flow, $jit, $proc, $offset, $n, $data) -> $n
```


## Process connections
```perl
sub add
{
  my ($self, $proc) = @_;
  $$self{sources}{$proc->name} = $proc;
  keys %{$$self{sources}} < 3;
}

sub remove
{
  my ($self, $proc) = @_;
  delete $$self{sources}{$proc->name};
  keys %{$$self{sources}} < 2;
}

sub invalidate_jit
{
  my $self = shift;
  %{$$self{source_fns}} = ();
  $self;
}
```


## Non-JIT IO
This is used when a simplex is multi-sourced, or for an initial entry point.

```perl
sub process_fn
{
  my ($self, $flow, $proc) = @_;
  $$self{source_fns}{refaddr $proc} //= $self->jit_fn_for($flow, $proc);
}

sub jit_fn_for
{
  my ($self, $flow, $proc) = @_;
  my ($offset, $n, $data);
  my $jit = pushback::jit->new
    ->code("#line 1 \"$flow/$proc JIT source\"")
    ->code('sub { ($offset, $n, $data) = @_;',
           offset => $offset,
           n      => $n,
           data   => $data);
  $proc->"jit_$$self{mode}"($jit->child('}'), $flow, $offset, $n, $data);
  $jit->end->compile;
}

sub request
{
  my $self = shift;
  my $flow = shift;
  my $proc = shift;

  # Requests are served from the offer queue. If we have none, turn this request
  # into an offer on the opposing queue by returning PENDING.
  my $q;
  return pushback::flow::PENDING unless @{$q = $$self{queue}};

  my $offset = shift;
  my $len    = shift;
  my ($total, $n, $responder) = (0, undef, undef);
  while ($len && defined($responder = shift @$q))
  {
  retry:
    $n = $self->process_fn($responder)->($offset, $len, $_[0]);
    die "$responder over-replied to $flow/$proc: requested $len but got $n"
      if $n > $len;
    return $n if $n == pushback::flow::RETRY
              || $n == pushback::flow::EOF && $flow->handle_eof($responder);
    $total  += $n;
    $offset += $n;
    $len    -= $n;
  }
  $total;
}
```


## JIT logic
```perl
sub jit_fragment
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
    my ($s) = values %{$$self{sources}};
    $s->"jit_$$self{mode}"($jit, $flow, $$offset, $$n, $$data);
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
```
