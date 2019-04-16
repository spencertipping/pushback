# `map`: link two flow points by transforming flow events
For example:

```bash
$ perl -I. -Mpushback -e '
    use strict;
    use warnings;
    pushback::stream::seq->map(sub { shift() ** 2 })->each(sub {
      print "$_\n" for @{$_[1]};
    })' | head -n5
0
1
4
9
16
```

```perl
package pushback::map;
push our @ISA, 'pushback::spanner';

sub pushback::stream::map
{
  my ($self, $fn) = @_;
  my $dest = pushback::point->new;
  pushback::map->new($self, $dest, $fn);
  $dest;
}

sub new
{
  my ($class, $from, $to, $fn) = @_;
  my $self = $class->connected_to(from => $from, to => $to);
  $$self{fn} = $fn;
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
  $self->point($point == $self->point('to') ? 'from' : 'to')
    ->jit_flow($self, $jit, $$flag, $$n, $$data)
    ->code(q{ @$data[0..$n-1] = map &$fn($_), @$data[0..$n-1]; },
           fn   => $$self{fn},
           n    => $$n,
           data => $$data);
}
```
