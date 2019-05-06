# Manifold surfaces

Surfaces are the API you use to build fused manifolds. A surface works like a
calling convention; for example, `cat file | grep foo | sort | wc -l` involves
joining four manifolds using the stdin/stdout pipe convention. Pushback would
represent `|` as a method call against the surface provided by each manifold.
