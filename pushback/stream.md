# Stream API
```perl
package pushback::stream;
use overload qw/ >> into /;
sub new
{
  my ($class, $in, $out) = @_;
  bless { in  => $in,
          out => $out,
          ops => [] }, $class;
}
```
