# `seq` process: generate numbers
For example:

```bash
$ perl -I. -Mpushback -e '
    my $flow = pushback::flow->new;
    my $seq  = pushback::seq->new($flow);
    my @xs;
    $flow->read($seq, 0, 4, \@xs);
    print "$_\n" for @xs'
0
1
2
3
```


```perl
package pushback::seq;
push our @ISA, qw/pushback::process/;

sub new
{
  my ($class, $into, $from, $inc) = @_;
  my $self = bless { into => $into,
                     from => $from // 0,
                     inc  => $inc  // 1 }, $class;
  $into->add_writer($self);
  $into->writable($self);
  $self;
}

sub name
{
  my $self = shift;
  "seq($$self{from} x $$self{inc} -> $$self{into})";
}

sub invalidate_jit_writer { shift }
sub jit_flow_writable { $_[1] }
sub jit_flow_readable { $_[1] }

sub jit_write
{
  my $self   = shift;
  my $jit    = shift;
  my $flow   = shift;
  my $offset = \shift;
  my $n      = \shift;
  my $data   = \shift;

  $flow->jit_writable($jit, $self)
       ->code(
    q{
      if ($inc == 1)
      {
        @$data[$offset..$offset+$n-1] = $start..$start+$n-1;
        $start += $n;
      }
      else
      {
        $$data[$offset + $i++] = $start += $inc while $i < $n;
      }
      $n;
    },
    i      => my $i = 0,
    start  => $$self{from},
    inc    => $$self{inc},
    into   => $$self{into},
    self   => $self,
    offset => $$offset,
    n      => $$n,
    data   => $$data);
}
```
