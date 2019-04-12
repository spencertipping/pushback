# Internals
## Bit selection
We use a lot of bit vectors in pushback; Perl's bitwise string operations are
insanely fast (for things available in an interpreted language), which makes
them a good basis for performance-critical applications like this.

```perl
sub pushback::bit_indexes
{
  my @r;
  local $_ = shift;
  pos() = undef;
  while (/([^\0])/g)
  {
    my $i = pos() - 1 << 3;
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
