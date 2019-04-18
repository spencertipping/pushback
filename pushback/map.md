# `map`: link two flow points by transforming flow events
For example:

```bash
$ perl -I. -Mpushback -e '
    use strict;
    use warnings;
    pushback::seq->new->out->map(sub { shift() ** 2 })->out->each(sub {
      my ($offset, $n, $data) = @_;
      print "$_\n" for @$data[$offset..$offset+$n-1]
    })->run([])' | head -n5
0
1
4
9
16
```

```perl
pushback::router->new('pushback::map', qw/ in out /)
  ->streamctor(map => 'in')
  ->stream('out')
  ->state(fn => undef)
  ->init(sub { my $self = shift; $$self{fn} = shift })
  ->flow('>in', '>out', q{
      print "offset = $offset, n = $n, data = @$data\n";
      @$data[$offset .. $offset+$n-1]
        = map &$fn($_), @$data[$offset .. $offset+$n-1];
    })
  ->flow('<out', '<in', '>in')
  ->package;
```
