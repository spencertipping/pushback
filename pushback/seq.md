# `seq`: emit integers
For example:

```bash
$ perl -I. -Mpushback -e '
    use strict;
    use warnings;
    pushback::stream::seq->copy->each(sub {
      my ($n, $data) = @_;
      print "$n\n";
      print "$_\n" for @$data[0..$n];
    })' | head -n5
100
0
1
2
3
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

sub jit_flow
{
  my $self  = shift;
  my $point = shift;
  my $jit   = shift;
  my $flag  = \shift;
  my $n     = \shift;
  my $data  = \shift;
  $jit->code(
    q{
      if ($n < 0)
      {
        $n = -$n;
        @$data = $i..$i + $n;
        $i += $n;
      }
      else
      {
        $n = 0;
      }
    },
    data => $$data,
    n    => $$n,
    i    => $$self{i});
}
```
