# Standard processes
Basic stream-manipulation stuff.


## `cat`: a one-way check valve
```perl
pushback::processclass->new(cat => '', 'in out')
  ->defadmittance('>in' => 'out>')
  ->defadmittance('<out' => 'in<')
  ->defflow('>in' => 'out>')
  ->defflow('<out' => 'in<');
```


## `each`: call a function on each flow
```perl
pushback::processclass->new(each => 'fn', 'in')
  ->defjit(invoke => 'flowable', q{ &$fn($flowable); })
  ->defadmittance('>in' => sub {})      # nop: preserve existing admittance
  ->defflow('>in' => sub
    {
      my ($self, $jit, $flowable) = @_;
      $self->invoke($jit, $flowable);
    });
```

```bash
$ perl -I. -Mpushback -e '
    use strict;
    use warnings;
    my $f    = pushback::flowable::string->new("foo");
    my $each = pushback::processes::each->new(pushback::io);
    my $cat  = pushback::processes::cat->new(pushback::io);

    print "each pid: $$each{process_id}\n";
    print "cat pid: $$cat{process_id}\n";

    $cat->connect(out => $each->port_id_for("in"));
    $$each{fn} = sub { print "each flow: ${shift->{str_ref}}\n" };
    my $a = $cat->admittance(">in", $f);
    print "admittance: $$a{n}\n";

    my $moved = $cat->flow(">in", $a);
    print "moved: $$moved{n}\n";
  '
each pid: 65536
cat pid: 131072
admittance: 3
each flow: foo
moved: 3
```
