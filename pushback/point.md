# Flow point
Flow points manage JIT aggregation across multiple paths. If a flow point has
exactly two paths then it becomes monomorphic and is erased; otherwise it
compiles an intermediate function to provide one flow result per invocation. (We
do this not because we have to, but because otherwise we could have an
exponential fanout of inlined logic.)

Three things happen when a process connects to a flow point:

1. All JIT paths through the flow point are invalidated
2. The flow point informs the process about the current data pressure
3. The process optionally issues a flow request, which modifies the flow point's
   data pressure
