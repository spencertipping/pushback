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
