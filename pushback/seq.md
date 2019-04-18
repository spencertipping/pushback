# `seq`: emit integers
For example:

```bash
$ perl -I. -Mpushback -e '
    use strict;
    use warnings;
    pushback::stream::seq->copy->each(sub {
      my ($offset, $n, $data) = @_;
      print "$n\t$_\n" for @$data[$offset..$offset+$n-1];
    })' | head -n5
1024	0
1024	1
1024	2
1024	3
1024	4
```

```perl
package pushback::seq;
push our @ISA, 'pushback::spanner';

sub pushback::stream::seq
{
  my $p = pushback::point->new;
  pushback::seq->new($p);
  $p;
}

sub new
{
  my ($class, $into) = @_;
  my $self = $class->connected_to(into => $into);
  $$self{i} = 0;
  $self;
}

sub jit_admittance
{
  my $self  = shift;
  my $point = shift;
  my $jit   = shift;
  my $flag  = \shift;
  my $n     = \shift;
  my $flow  = \shift;

  # Always return data. Our target flow per request is 1k elements.
  $jit->code(q{ $f = $n < 0 ? -1024 : 0; }, n => $$n, f => $$flow);
}

sub jit_flow
{
  my $self   = shift;
  my $point  = shift;
  my $jit    = shift;
  my $flag   = \shift;
  my $offset = \shift;
  my $n      = \shift;
  my $data   = \shift;

  $jit->code(
    q{
      if ($n < 0)
      {
        $n *= -1;
        $offset = 0;
        @$data = $i .. $i+$n-1;
        $i += $n;
      }
      else
      {
        $n = 0;
      }
    },
    offset => $$offset,
    data   => $$data,
    n      => $$n,
    i      => $$self{i});
}
```
