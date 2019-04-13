# Stream API
Streams generate JIT-compiled processes run by a multiplexer.

```perl
package pushback::stream;
use overload qw/ >> into /;

sub io  { shift->{io} }
sub in  { shift->{in} }
sub out { shift->{out} }
sub deps { grep defined, @{+shift}{qw/ in out /} }

sub jit_read_op  { die "unimplemented JIT read op for $_[0]" }
sub jit_write_op { die "unimplemented JIT write op for $_[0]" }

sub into
{
  my ($self, $dest) = @_;
  my @data;
  my $jit = pushback::jit->new;
  $self->jit_read_op($jit, \@data);
  $dest->jit_write_op($jit, \@data);
  pushback::process->new($jit, $$self{in}, $$dest{out});
}
```
