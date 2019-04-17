# `copy`: link two flow points by transferring all flow events
```perl
package pushback::copy;
push our @ISA, 'pushback::spanner';

sub pushback::stream::into
{
  my ($self, $dest) = @_;
  pushback::copy->new($self, $dest);
  $dest;
}

sub pushback::stream::copy
{
  shift->into(pushback::point->new);
}

sub new
{
  my ($class, $from, $to) = @_;
  $class->connected_to(from => $from, to => $to);
}

sub jit_admittance
{
  my $self  = shift;
  my $point = shift;
  $self->point($point == $self->point('from') ? 'to' : 'from')
    ->jit_admittance($self, @_);
}

sub jit_flow
{
  my $self  = shift;
  my $point = shift;
  $self->point($point == $self->point('from') ? 'to' : 'from')
    ->jit_flow($self, @_);
}
```
