# JIT compiler object
Compiles code into the current runtime, sharing state across the compilation
boundary using lexical closure.

```perl
package pushback::jit;
sub new
{
  my ($class, $name) = @_;
  my $gensym = 0;
  bless { parent => undef,
          name   => $name,
          shared => {},
          gensym => \$gensym,
          code   => [],
          end    => undef }, $class;
}

sub compile
{
  my $self  = shift;
  die "$$self{name}: must compile the parent JIT context"
    if defined $$self{parent};

  my @args  = sort keys %{$$self{shared}};
  my $setup = sprintf "my (%s) = \@_;", join",", map "\$$_", @args;
  my $code  = join"\n", "use strict;use warnings;",
                        "sub{", $setup, @{$$self{code}}, "}";
  my $sub   = eval $code;
  die "$@ compiling $code" if $@;
  $sub->(@{$$self{shared}}{@args});
}
```

## Code rewriting
```perl
sub gensym { "g" . ${shift->{gensym}}++ }
sub code
{
  my ($self, $code, %v) = (shift, shift);
  $$self{shared}{$v{$_[0]} = $self->gensym} = \$_[1], shift, shift while @_;
  if (keys %v) { my $vs = join"|", keys %v;
                 $code =~ s/([\$@%&])($vs)/"$1\{\$$v{$2}\}"/eg }
  push @{$$self{code}}, $code;
  $self;
}
```

## Macros
```perl
sub mark
{
  my $self = shift;
  $self->code("#line 1 \"$$self{name} @_\"");
}
sub if    { shift->block(if    => @_) }
sub while { shift->block(while => @_) }
sub block
{
  my ($self, $type) = (shift, shift);
  $self->code("$type(")->code(@_)->code("){")
       ->child($type, "}");
}
```

## Parent/child linkage
```perl
sub child
{
  my ($self, $name, $end) = @_;
  bless { parent  => $self,
          name    => "$$self{name} $name",
          closure => $$self{closure},
          gensym  => $$self{gensym},
          code    => [],
          end     => $end }, ref $self;
}
sub end
{
  my $self = shift;
  $$self{parent}->code(join"\n", @{$$self{code}}, $$self{end});
}
```
