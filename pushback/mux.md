# Pushback micro-processes
Pushback is driven by a low-latency scheduler that negotiates dependencies and
figures out which processes can be run at any given moment.


## Process object
This interfaces with the multiplexer state but otherwise isn't involved in
scheduling.

```perl
package pushback::process;
sub new
{
  my ($class, $fn, @deps) = @_;
  bless { fn   => $fn,
          time => 0,
          n    => 0,
          deps => \@deps }, $class;
}

sub fn
{
  my $self = shift;
  my $jit = pushback::jit->new
    ->code('use Time::HiRes qw/time/;')
    ->code('++$n; $t -= time();', n => $$self{n}, t => $$self{time});

  ref $$self{fn} eq "CODE"
    ? $jit->code('&$f();', f => $$self{fn})
    : $jit->code($$self{fn});

  $jit->code('$t += time();', t => $$self{time})
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
          resource_index => [],
          resource_avail => $avail,
          resource_error => $error }, $class;
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


## Scheduling
```perl
sub step
{
  my $self = shift;
  my $run  = 0;
  my ($is, $os, $fs, $r, $w, $re, $we)
    = @$self{qw/ inputs outputs fns rvec wvec revec wevec /};

  my @errors;
  for my $i (0..$#$fs)
  {
    my ($in, $out, $fn) = ($$is[$i], $$os[$i], $$fs[$i]);
    ++$run, &$fn($r, $w, $in, $out) while vec $$r, $in, 1 and vec $$w, $out, 1;
    push @errors, $i if vec $$re, $in, 1 or vec $$we, $out, 1;
  }

  if (@errors)
  {
    @$is[@errors] = ();
    @$os[@errors] = ();
    @$fs[@errors] = ();
    @$is = grep defined, @$is;
    @$os = grep defined, @$os;
    @$fs = grep defined, @$fs;
  }

  $run;
}

sub loop
{
  my $self = shift;
  return 0 unless $self->step;
  1 while $self->step;
}
```
