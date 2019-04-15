# Copy process
For example:

```bash
$ perl -I. -Mpushback -e '
    my $flow1 = pushback::flow->new;
    my $seq   = pushback::seq->new($flow1);
    my $flow2 = pushback::flow->new;
    my $copy  = pushback::copy->new($flow1, $flow2);
    my @xs;
    $flow2->read(undef, 0, 4, \@xs);
    print "$_\n" for @xs'
0
1
2
3
```


```perl
package pushback::copy;
push our @ISA, qw/pushback::process/;

sub new
{
  my ($class, $from, $to) = @_;
  my $self = bless { from => $from,
                     to   => $to }, $class;
  $from->add_reader($self);
  $to->add_writer($self);
  $self;
}

sub name
{
  my $self = shift;
  "copy($$self{from} -> $$self{to})";
}

sub jit_read
{
  my $self = shift;
  my $jit  = shift;
  shift;
  $$self{from}->jit_read_fragment($jit, $self, @_);
}

sub jit_write
{
  my $self = shift;
  my $jit  = shift;
  shift;
  $$self{to}->jit_write_fragment($jit, $self, @_);
}

sub eof
{
  my ($self, $flow, $error) = @_;
  $$self{from}->remove_reader($self);
  $$self{to}->remove_writer($self);
  delete $$self{from};
  delete $$self{to};
  $self;
}

sub invalidate_jit_reader
{
  my $self = shift;
  $$self{from}->invalidate_jit_readers;
  $self;
}

sub invalidate_jit_writer
{
  my $self = shift;
  $$self{to}->invalidate_jit_writers;
  $self;
}
```
