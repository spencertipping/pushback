# Yep, another redesign
I'm not sure exactly what I want yet, but whatever it is should be much simpler
than what exists now.

There's no point to having `router` and `spanner`, nor is there any point to
having both `point` and `stream`. We should focus on `router` and `stream`, but
they're probably due for a rename.

Data direction needs to be handled a lot more consistently than it is now. I
don't love signed ints for direction, although it is simple. From an IO
perspective it demands some erasure or other clunkiness, which seems like a
problem. Maybe we should condense flow down to signed stuff but always present
it as `inflow` or `outflow` with a positive length.

I'm certain the current implementation creates circular references.

Routers can provide stream endpoints and may default to different endpoints for
different-direction operations: `$stream >> $map` vs `$map >> $stream`, for
example.

...that's a start. **TODO:** elaborate
