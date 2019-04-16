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
  my $n = -100;
  my $data;
  $$self{fn} = $fn;
  $$self{fn}->($n, $data) while $n = $self->flow_fn('from')->($n, $data);
  $self;
}

sub jit_flow
{
  my $self  = shift;
  my $point = shift;
  my $jit   = shift;
  my $flag  = \shift;
  my $n     = \shift;
  my $data  = \shift;
  $jit->code(
    q{
      if ($n > 0)
      {
        &$fn($n, $data);
        $n = -$n;
      }
      else
      {
        $n = 0;
      }
    },
    fn   => $$self{fn},
    data => $$data,
    n    => $$n);
}
```
