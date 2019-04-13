# Pushback micro-processes
Pushback is driven by a low-latency scheduler that negotiates dependencies and
figures out which processes can be run at any given moment.


## Process object
This interfaces with the multiplexer state but otherwise isn't involved in
scheduling. You could create these objects directly, but `mux->when(@deps, $f)`
will do it for you.

```perl
package pushback::process;
sub new
{
  my ($class, $mux, $fn, @deps) = @_;
  bless { fn    => $fn,
          time  => 0,
          n     => 0,
          mux   => $mux,
          pid   => undef,
          error => undef,
          deps  => \@deps }, $class;
}

sub set_pid
{
  my $self = shift;
  $$self{pid} = shift;
  $self;
}

sub kill
{
  my $self = shift;
  die "process is not running (has no PID)" unless defined $$self{pid};
  $$self{mux}->remove($$self{pid});
  $self;
}

sub fail
{
  my $self = shift;
  $$self{error} = shift;
  $self->kill;
}

sub fn
{
  my $self = shift;
  my $jit = pushback::jit->new
    ->code('sub {')
    ->code('use Time::HiRes qw/time/;')
    ->code('++$n; $t -= time();', n => $$self{n}, t => $$self{time});

  ref $$self{fn} eq "CODE"
    ? $jit->code('&$f();', f => $$self{fn})
    : $jit->code($$self{fn});

  $jit->code('$t += time();', t => $$self{time})
      ->code('}')
      ->compile;
}
```


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
          check_errors   => 0,
          resource_index => [],
          resource_avail => $avail,
          resource_error => $error }, $class;
}
```


### Process API
```perl
sub when
{
  my $self = shift;
  my $fn   = pop;
  die "processes must be predicated on at least one resource ID" unless @_;
  $self->add_process(pushback::process->new($self, $fn, @_));
}
```


### Process management
```perl
sub add_process
{
  my ($self, $p) = @_;
  my $pid = $self->next_free_pid;

  push @{$$self{process_fns}},  undef until $#{$$self{process_fns}}  >= $pid;
  push @{$$self{process_deps}}, undef until $#{$$self{process_deps}} >= $pid;

  $$self{processes}[$pid]    = $p;
  $$self{process_fns}[$pid]  = $p->fn;
  $$self{process_deps}[$pid] = [$p->deps];

  $self->update_index($pid);
  vec($$self{pid_usage}, $pid, 1) = 1;
  $p->set_pid($pid);
}

sub remove_process
{
  my ($self, $pid) = @_;
  my $p    = $$self{processes}[$pid];
  my $deps = $$self{process_deps}[$pid];

  $$self{processes}[$pid]    = undef;
  $$self{process_fns}[$pid]  = undef;
  $$self{process_deps}[$pid] = undef;

  $self->update_index($pid, @$deps);
  vec($$self{pid_usage}, $pid, 1) = 0;
  $p->set_pid(undef);
}

sub next_free_pid
{
  my $self = shift;
  pos($$self{pid_usage}) = 0;
  if ($$self{pid_usage} =~ /([^\xff])/g)
  {
    my $i = pos($$self{pid_usage}) - 1 << 3;
    my $c = ord $1;
    ++$i, $c >>= 1 while $c & 1;
    $i;
  }
  else
  {
    length($$self{pid_usage}) << 3;
  }
}
```


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
  my $self = shift;
  my $deps  = $$self{process_deps};
  my $fns   = $$self{process_fns};
  my $avail = $$self{resource_avail};
  my %pids_seen;

  OUTER:
  for my $pid (grep !$pids_seen{$_}++,
               map  @$_, @{$$self{resource_index}}
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
                 map  @$_, @{$$self{resource_index}}
                            [pushback::bit_indexes ${$$self{resource_error}}])
    {
      eval { $$fns[$pid]->() };
      $$self{processes}[$pid]->fail($@) if $@;
    }
  }

  $self;
}
```
