# Object set

An associative structure that holds weak references to objects and allows you to
dereference compact integer IDs that refer back to them. For example:

```bash
$ perl -I. -Mpushback -e '
    my $obj = "foo";
    my $set = pushback::objectset->new;
    my $id  = $set->add($obj);
    my $id2 = $set->add("bar");
    print "$id: $$set[$id]\n";
    print "$id2: $$set[$id2]\n";
    $set->remove($id);
    $id = $set->add("bif");
    print "$id: $$set[$id]\n"'
1: foo
2: bar
1: bif
```

```perl
package pushback::objectset;
use Scalar::Util qw/weaken/;

sub new { bless ["\x01"], shift }

sub add
{
  my $id = (my $self = shift)->next_id;
  vec($$self[0], $id, 1) = 1;
  $$self[$id] = shift;
  weaken $$self[$id] if ref $$self[$id];
  $id;
}

sub remove
{
  my ($self, $id) = @_;
  vec($$self[0], $id, 1) = 0;
  delete $$self[$id];
  $$self[$id];
}

sub next_id
{
  my $self = shift;
  if ($$self[0] =~ /([^\xff])/g)
  {
    my $byte = pos $$self[0];
    my $v    = ord $1;
    my $bit  = 0;
    ++$bit while $v & 1 << $bit;
    $byte - 1 << 3 | $bit;
  }
  else
  {
    ++$#$self;
  }
}
```
