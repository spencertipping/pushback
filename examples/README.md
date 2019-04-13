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
