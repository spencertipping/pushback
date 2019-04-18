# `each`: invoke a callback per flow event
```perl
pushback::router->new('pushback::each', qw/ in /)
  ->streamctor(each => 'in')
  ->state(fn => undef)
  ->init(sub { my $self = shift; $$self{fn} = shift })
  ->flow('>in', 1, q{ &$fn($offset, $n, $flow); })
  ->def(run => sub
    {
      my $self = shift;
      my ($offset, $n, $data) = (0, $self->admittance('in', -1), shift);
      1 while $n = $self->flow('in', $offset, $n, $data);
      $self;
    })
  ->package;
```
