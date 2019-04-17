# `each`: invoke a callback per flow event
```perl
package pushback::each;
push our @ISA, 'pushback::spanner';

sub pushback::stream::each
{
  my ($self, $fn) = @_;
  pushback::each->new($self, $fn);
  $self;
}

sub new
{
  my ($class, $from, $fn) = @_;
  my $self = $class->connected_to(from => $from);
  my $n = $self->admittance('from', -1);
  my $offset;
  my $data;
  $$self{fn} = $fn;
  &$fn($offset, $n, $data) while $n = $self->flow('from', $offset, $n, $data);
  $self;
}

sub jit_admittance
{
  my $self  = shift;
  my $point = shift;
  my $jit   = shift;
  my $flag  = \shift;
  my $n     = \shift;
  my $flow  = \shift;

  # No admittance modifications for inflow to this spanner.
  $jit->code(q{ $f = $n > 0 ? $n : 0; }, f => $$flow, n => $$n);
}

sub jit_flow
{
  my $self   = shift;
  my $point  = shift;
  my $jit    = shift;
  my $flag   = \shift;
  my $offset = \shift;
  my $n      = \shift;
  my $data   = \shift;
  $jit->code(
    q{
      if ($n > 0)
      {
        &$fn($offset, $n, $data);
        $n = -$n;
      }
      else
      {
        $n = 0;
      }
    },
    fn     => $$self{fn},
    offset => $$offset,
    n      => $$n,
    data   => $$data);
}
```
