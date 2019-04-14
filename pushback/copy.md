# Copy process
```perl
package pushback::copy;
push our @ISA, qw/pushback::process/;

sub new
{
  my ($class, $from, $to) = @_;
  bless { from => $from,
          to   => $to }, $class;
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
