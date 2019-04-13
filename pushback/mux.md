# Pushback micro-processes
Pushback is driven by a low-latency scheduler that negotiates dependencies and
figures out which processes can be run at any given moment.


## Multiplexer
This is where scheduling happens. The multiplexer holds two vector references:
one for resource availability and one for resource error.

```perl
package pushback::mux;
sub new
{
  my $class = shift;
  my $avail = \shift;
  my $error = \shift;
  bless { pid_usage      => "\0",
          process_fns    => [],
          process_deps   => [],
          processes      => [],
          run_hints      => [],
          check_errors   => 0,
          resource_index => [],
          resource_avail => $avail,
          resource_error => $error }, $class;
}
```


### Process management
```perl
sub add
{
  my ($self, $p) = @_;
  my $pid = pushback::next_zero_bit $$self{pid_usage};

  push @{$$self{process_fns}},  undef until $#{$$self{process_fns}}  >= $pid;
  push @{$$self{process_deps}}, undef until $#{$$self{process_deps}} >= $pid;

  $$self{processes}[$pid]    = $p;
  $$self{process_fns}[$pid]  = $p->fn;
  $$self{process_deps}[$pid] = [$p->deps];

  $self->update_index($pid);
  vec($$self{pid_usage}, $pid, 1) = 1;
  $p->set_pid($self => $pid);
}

sub remove
{
  my ($self, $pid) = @_;
  my $p    = $$self{processes}[$pid];
  my $deps = $$self{process_deps}[$pid];

  $$self{processes}[$pid]    = undef;
  $$self{process_fns}[$pid]  = undef;
  $$self{process_deps}[$pid] = undef;

  $self->update_index($pid, @$deps);
  vec($$self{pid_usage}, $pid, 1) = 0;
  $p->set_pid($self => undef);
}
```


## JIT insertion points
**TODO**


## Resource indexing
```perl
use constant EMPTY => [];
sub update_index
{
  my $self = shift;
  my $pid  = shift;
  my $ri   = $$self{resource_index};
  $$ri[$_] = [grep $_ != $pid, @{$$ri[$_] // EMPTY}] for @_;
  push @{$$ri[$_] //= []}, $pid for @{$$self{process_deps}[$pid]};
}
```


## Scheduling
```perl
sub step
{
  my $self  = shift;
  my $deps  = $$self{process_deps};
  my $fns   = $$self{process_fns};
  my $avail = $$self{resource_avail};
  my %pids_seen;

  OUTER:
  for my $pid (grep !$pids_seen{$_}++,
               map  @{$_ // EMPTY},
                    @{$$self{resource_index}}
                     [pushback::bit_indexes $$avail])
  {
    vec $$avail, $_, 1 or next OUTER for @{$$deps[$pid]};
    eval { $$fns[$pid]->() };
    $$self{processes}[$pid]->fail($@) if $@;
  }

  if ($$self{check_errors})
  {
    %pids_seen = ();
    for my $pid (grep !$pids_seen{$_}++,
                 map  @{$_ // EMPTY},
                      @{$$self{resource_index}}
                       [pushback::bit_indexes ${$$self{resource_error}}])
    {
      eval { $$fns[$pid]->() };
      $$self{processes}[$pid]->fail($@) if $@;
    }
  }

  $self;
}
```
