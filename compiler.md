# Compiler
```bash
$ perl <<'EOF'
do './pushback.pm' or die $@;
print pushback::jit->new->code('$x', x => 4)->compile, "\n";
EOF
4
```

```bash
$ perl <<'EOF'
do './pushback.pm' or die $@;
my $x = 10;
pushback::jit->new->code('$y++', y => $x)->compile;
print "$x\n";
EOF
11
```
