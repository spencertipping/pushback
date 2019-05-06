# Volume

In our metaphor data has volume and is pushed through manifolds, where it
encounters backpressure that reduces its flow rate. Our volume is
incompressible, so to model this accurately we first "offer" an amount of data,
then we collect backpressure, then we commit only as much flow as the manifold
has capacity.

A physical system would construct a flow-admittance matrix and equalize forward
and backpressure. We could do that here, but it's a lot simpler to have
manifolds implicitly handle this step. We don't care about backpressure for its
own sake; our goal is to get the right amount of flow. So manifolds return
modified flow volumes instead of dealing directly in backpressure.
