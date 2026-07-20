# Vendored tree-sitter-rust grammar

- Upstream: https://github.com/tree-sitter/tree-sitter-rust
- Release tag: `v0.24.0`
- Download URL: https://github.com/tree-sitter/tree-sitter-rust/archive/refs/tags/v0.24.0.tar.gz
- Vendored date: 2026-07-19
- Vendoring method: 经由本地缓存 vendor
- License: MIT; see `LICENSE` in this directory.

The generated `parser.c`, `scanner.c`, and `node-types.json` are vendored along
with the generated `tree_sitter/parser.h` and `tree_sitter/alloc.h` headers
needed to compile them without Node or Cargo.
