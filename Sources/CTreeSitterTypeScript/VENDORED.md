# Vendored tree-sitter-typescript grammar (TypeScript + TSX)

- Upstream: https://github.com/tree-sitter/tree-sitter-typescript
- Release tag: `v0.23.2`
- Release commit: `f975a621f4e7f532fe322e13c4f79495e0a7b2e7`
- Download URL: https://github.com/tree-sitter/tree-sitter-typescript/releases/download/v0.23.2/tree-sitter-typescript.tar.xz
- Archive SHA-256: `2d324af0616a692cc6fcaea35442a816decb2ef0d05242953cb1feb15a5dc72d`
- Vendored date: 2026-08-12
- Vendoring method: released tar.xz; manual layout under this SwiftPM C target
- License: MIT; see `LICENSE` in this directory.

Both generated parsers compile into one C target (`CTreeSitterTypeScript`)
linked against the existing `CTreeSitter` runtime. The archived grammar root
prefix is dropped because SwiftPM uses `Sources/CTreeSitterTypeScript` as the
build root. The 14 P0 allow-listed archive paths are vendored here:

```text
LICENSE
common/scanner.h
typescript/src/parser.c
typescript/src/scanner.c
typescript/src/node-types.json
typescript/src/tree_sitter/parser.h
typescript/src/tree_sitter/alloc.h
typescript/src/tree_sitter/array.h
tsx/src/parser.c
tsx/src/scanner.c
tsx/src/node-types.json
tsx/src/tree_sitter/parser.h
tsx/src/tree_sitter/alloc.h
tsx/src/tree_sitter/array.h
```

Two public C entry headers are also vendored
(`include/tree_sitter_typescript.h` and `include/tree_sitter_tsx.h`) so SwiftPM
can expose `tree_sitter_typescript()`/`tree_sitter_tsx()` to Swift; both are
the archived `bindings/c` headers, not new generated declarations.

Plan F1a requires both `LICENSE` and `VENDORED.md`, so the on-disk file count
is the 14 archive paths plus 2 bindings headers plus this file.
