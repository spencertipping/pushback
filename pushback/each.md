# `each` process: consume and invoke a callback
For example:

```bash
$ perl -I. -Mpushback -e '
    my $flow = pushback::flow->new;
    my $each = pushback::each->new($flow, sub { print "$_\n" for @_ });
    $flow->write($each, 0, 1, ["foo$_"]) for 1..4'
foo1
foo2
foo3
foo4
```


```perl
package pushback::each;
push our @ISA, qw/pushback::process/;

sub new
{
  my ($class, $from, $fn) = @_;
  my $self = bless { from => $from,
                     fn   => $fn }, $class;
  $from->add_reader($self);
  $from->readable($self);
  $self;
}

sub invalidate_jit_reader { shift }

sub jit_read
{
  my $self   = shift;
  my $jit    = shift;
  my $flow   = shift;
  my $offset = \shift;
  my $n      = \shift;
  my $data   = \shift;

  $jit->code(
    q{
      &$fn(@$data[$offset .. $offset + $n - 1]);
      $from->readable($self);
      $n;
    },
    from   => $$self{from},
    self   => $self,
    fn     => $$self{fn},
    offset => $$offset,
    n      => $$n,
    data   => $$data);
}
```
