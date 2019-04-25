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
  ->defadmittance('>in' => q{})
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

    $cat->connect(1, $each->port_id_for(0));
    $$each{fn} = sub { print "each flow: ${shift->{str_ref}}\n" };

    my $jit = pushback::jitcompiler->new;
    $cat->jit_admittance(0, $jit, $f);
    $jit->compile;
    print "admittance: $$f{n}\n";

    $jit = pushback::jitcompiler->new;
    $cat->jit_flow(0, $jit, $f);
    $jit->compile'
each pid: 65536
cat pid: 131072
admittance: 3
each flow: foo
```
