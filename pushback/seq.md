# `seq`: emit integers
For example:

```bash
$ perl -I. -Mpushback -e '
    use strict;
    use warnings;
    pushback::seq->new->out->each(sub {
      my ($offset, $n, $data) = @_;
      print "$n\t$_\n" for @$data[$offset .. $offset+$n-1];
    })->run([])' | head -n100
1024	0
1024	1
1024	2
1024	3
1024	4
```

```perl
pushback::router->new('pushback::seq', qw/ out /)
  ->stream('out')
  ->state(i => 0)
  ->flow('<out', '$flow = 1;', q{ $$data[$offset] = $i++ })
  ->package;
```
