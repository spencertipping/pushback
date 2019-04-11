# Multiplexer
Maintains a list of processes and schedules them according to resource
availability.

**TODO:** optimize this a lot

```perl
package pushback::mux;
sub new
{
  my $class = shift;
  bless { inputs  => [],
          outputs => [],
          fns     => [],
          rvec    => \$_[0],
          wvec    => \$_[1],
          revec   => \$_[2],
          wevec   => \$_[3] }, $class;
}

sub add
{
  # TODO: come up with a stable process identifier; array indexes aren't stable
  my ($self, $in, $out, $fn) = @_;
  push @{$$self{inputs}}, $in;
  push @{$$self{outputs}}, $out;
  push @{$$self{fns}}, $fn;
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
