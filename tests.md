```bash
$ examples/cat-lowlevel <<'EOF'
asdf
bif
baz
EOF
asdf
bif
baz
$ { echo hi; echo there; } | examples/cat-lowlevel
hi
there
```
