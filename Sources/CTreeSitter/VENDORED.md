# Vendored tree-sitter runtime

- Upstream: https://github.com/tree-sitter/tree-sitter
- Release tag: `v0.25.8`
- Download URL: https://github.com/tree-sitter/tree-sitter/archive/refs/tags/v0.25.8.tar.gz
- Vendored date: 2026-07-19
- Vendoring method: 经由本地缓存 vendor
- License: MIT; see `LICENSE` in this directory.

`src/lib.c` is the upstream unity build and is the only C source compiled by
SwiftPM. The remaining upstream `.c` files are retained because `lib.c`
includes them.
