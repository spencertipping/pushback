# IO selector
```perl
package pushback::io_select;

sub new
{
  my $class = shift;
  my $self = bless { rfds => "\0" x 128,
                     wfds => "\0" x 128,
                     efds => "\0" x 128,
                     rbuf => "\0" x 128,
                     wbuf => "\0" x 128,
                     ebuf => "\0" x 128,
                     ra   => "\0" x 128,
                     wa   => "\0" x 128,
                     ea   => "\0" x 128 }, $class;
  $$self{mux} = pushback::mux->new(
    $$self{ra}, $$self{wa}, $$self{ea}, $$self{ea});
  $self;
}

sub mux { shift->{mux} }

sub read
{
  my ($self, $file) = @_;
  vec($$self{rfds}, fileno $file, 1) = 1;
  vec($$self{efds}, fileno $file, 1) = 1;
  $self;
}

sub write
{
  my ($self, $file) = @_;
  vec($$self{wfds}, fileno $file, 1) = 1;
  vec($$self{efds}, fileno $file, 1) = 1;
  $self;
}

sub step
{
  my ($self, $timeout) = @_;
  $$self{rbuf} = $$self{rfds}; $$self{rbuf} ^= $$self{ra};
  $$self{wbuf} = $$self{wfds}; $$self{wbuf} ^= $$self{wa};
  $$self{ebuf} = $$self{efds}; $$self{ebuf} ^= $$self{ea};

  return 0 unless $$self{rbuf} =~ /[^\0]/ || $$self{wbuf} =~ /[^\0]/;
  defined(select $$self{rbuf}, $$self{wbuf}, $$self{ebuf}, $timeout) or die $!;

  $$self{ra} |= $$self{rbuf};
  $$self{wa} |= $$self{wbuf};
  $$self{ea} |= $$self{ebuf};
  $self;
}

sub loop
{
  my $self = shift;
  $self->step;
  $self->step while $self->mux->loop;
}
```
