# Examples
These do more or less what you'd expect, but are implemented in pushback.

```bash
$ echo hi | examples/cat
hi
$ { echo hi; echo there; } | examples/cat
hi
there
```

```bash
$ echo hi | examples/pipecat
hi
$ { echo hi; echo there; } | examples/pipecat
hi
there
```


## Let's verify data integrity
```bash
$ dd if=/dev/zero bs=1M count=4 2>/dev/null | sha256sum
bb9f8df61474d25e71fa00722318cd387396ca1736605e1248821cc0de3d3af8  -
$ dd if=/dev/zero bs=1M count=4 2>/dev/null | examples/cat | sha256sum
bb9f8df61474d25e71fa00722318cd387396ca1736605e1248821cc0de3d3af8  -
$ dd if=/dev/zero bs=1M count=4 2>/dev/null | examples/pipecat | sha256sum
bb9f8df61474d25e71fa00722318cd387396ca1736605e1248821cc0de3d3af8  -
```
