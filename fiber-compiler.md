# Fiber compiler
OK, let's implement `pv` and talk about how it works. Structurally we have this:

```pl
my $catalyst    = pushback::select_catalyst->new;
my $measurement = pushback::reducer([0, 0], "AB", "+");

$catalyst->r(\*STDIN)
  ->into($catalyst->w(\*STDOUT))        # stdin -> stdout...
  ->map(sub { (length($_[0]), $dt) })   # ... numeric pairs
    ->into($measurement);               # ... send to measurement reducer

$catalyst->interval(1)                  # timed output (emit elapsed time)
  ->map(sub { @$measurement })          # ... return measurement output
  ->grep(sub { $_[1] > 2 })             # ... when two seconds have passed
  ->map(sub { sprintf(...) })           # ... format it
  ->into($catalyst->w(\*STDERR));       # ... and print to stderr

$catalyst->loop;                        # run while frontier exists
```

This results in two fibers:

```
stdin -> [stdout, map -> measurement]
interval -> map -> grep -> map -> stderr
```

That means we'll block and then run either fiber depending on what the scheduler
tell us: we might get `stdin->stdout` or we might get `interval->stderr`.

Fibers run automatically when (and while) all relevant endpoints are available.
Because a fiber may have many endpoints, we pack endpoint availability into a
bit vector per fiber. This results in skeletal logic like this:

```pl
while ($avail0 == 0x... [&& $avail1 == 0x... && ...])
{
  ...
  if (...) {                            # grep compiles to this
    ...
    $availN &= ~0x...;                  # write() calls may compile to this
    ...
  }
}
```

Catalysts call stream methods that run `$availN |= 0x...` to activate specific
endpoints in response to `select()` or other promises that things won't block.
Each such transition tries the `while` loop.

```perl
package pushback::compiler;
sub new
{
  my ($class, $name) = shift;
  my $gensym = 0;
  bless { parent  => undef,
          name    => $name,
          closure => {},
          gensym  => \$gensym,
          code    => [],
          end     => undef }, $class;
}

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

sub gensym { "g" . ${shift->{gensym}}++ }
sub code
{
  my $self = shift;
  my $code = shift;
  my %vars;
  ${$$self{closure}}{$vars{+shift} = $self->gensym} = shift while @_ >= 2;
  my $vars = join"|", keys %vars;
  push @{$$self{code}},
       keys(%vars) ? $code =~ s/\$($vars)/"\$" . ${$$self{scope}}{$1}/egr
                   : $code;
  $self;
}

sub mark
{
  my $self = shift;
  $self->code("#line 1 \"$$self{name} @_\"");
}

sub block
{
  my $self = shift;
  my $type = shift;
  $self->code("$type(")->code(@_)->code("){")
       ->child($name, "}");
}

sub if    { shift->block(if    => @_) }
sub while { shift->block(while => @_) }
sub end
{
  my $self = shift;
  $$self{parent}->code(join"\n", @{$$self{code}, $$self{end});
}

sub compile
{
  my $self    = shift;
  my @closure = sort keys %{$$self{closure}};
  my $setup   = sprintf "my (%s) = \@_;", join",", map "\$$_", @closure;
  my $code    = join"\n", "sub{", $setup, @{$$self{code}}, "}";
  my $sub     = eval $code;
  die "$@ compiling $code" if $@;
  $sub->(@{$$self{closure}}{@closure});
}
```
