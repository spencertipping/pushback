# Internals
## Bit selection
We use a lot of bit vectors in pushback; Perl's bitwise string operations are
insanely fast (for things available in an interpreted language), which makes
them a good basis for performance-critical applications like this.

```perl
sub pushback::bit_indexes
{
  my @r;
  pos($_[0]) = undef;
  while ($_[0] =~ /([^\0])/g)
  {
    my $i = pos($_[0]) - 1 << 3;
    my $c = ord $1;
    do
    {
      push @r, $i if $c & 1;
      ++$i;
    } while $c >>= 1;
  }
  @r;
}
```

For example:

```bash
$ perl -I. -Mpushback \
       -e 'print join(",", pushback::bit_indexes "\x81\x00\x1c"), "\n"'
0,7,18,19,20
```


## Resource sets
```perl
sub pushback::next_zero_bit
{
  pos($_[0]) = 0;
  if ($_[0] =~ /([^\xff])/g)
  {
    my $i = pos($_[0]) - 1 << 3;
    my $c = ord $1;
    ++$i, $c >>= 1 while $c & 1;
    $i;
  }
  else
  {
    length($_[0]) << 3;
  }
}
```
