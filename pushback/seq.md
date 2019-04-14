# `seq` process: generate numbers
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
  $into->readable($self);
  $self;
}

sub invalidate_jit_writer { shift }

sub jit_write
{
  my $self   = shift;
  my $jit    = shift;
  my $flow   = shift;
  my $offset = \shift;
  my $n      = \shift;
  my $data   = \shift;

  $jit->code(
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
      $into->readable($self);
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
