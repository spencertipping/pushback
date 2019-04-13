# Process object
This interfaces with the multiplexer state but otherwise isn't involved in
scheduling.

```perl
package pushback::process;
sub new
{
  my ($class, $fn, @deps) = @_;
  bless { fn    => $fn,
          time  => 0,
          n     => 0,
          mux   => undef,
          pid   => undef,
          error => undef,
          deps  => \@deps }, $class;
}

sub running { defined shift->{pid} }
sub deps    { @{shift->{deps}} }
```


## Management functions
```perl
sub kill
{
  my $self = shift;
  die "process is not managed by a multiplexer" unless defined $$self{mux};
  die "process is not running (has no PID)" unless defined $$self{pid};
  $$self{mux}->remove($$self{pid});
  $self;
}
```


## Compilation
This is the function the process supplies to the multiplexer, invoked once per
quantum.

```perl
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


## Multiplexer-facing interface
```perl
sub set_pid
{
  my $self = shift;
  $$self{mux} = shift;
  $$self{pid} = shift;
  $self;
}

sub fail
{
  my $self = shift;
  $$self{error} = shift;
  $self->kill;
}
```
