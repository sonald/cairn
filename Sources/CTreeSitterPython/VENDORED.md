# Vendored tree-sitter-python grammar

- Upstream: https://github.com/tree-sitter/tree-sitter-python
- Release tag: `v0.25.0`
- Release commit: `293fdc02038ee2bf0e2e206711b69c90ac0d413f`
- Download URL: https://github.com/tree-sitter/tree-sitter-python/archive/refs/tags/v0.25.0.tar.gz
- Archive SHA-256: 4609a3665a620e117acf795ff01b9e965880f81745f287a16336f4ca86cf270c
- Vendored date: 2026-08-11
- Vendoring method: downloaded by `scripts/vendor-treesitter.sh`
- License: MIT; see `LICENSE` in this directory.

The generated `parser.c`, `scanner.c`, and `node-types.json` are vendored
along with the generated `tree_sitter/parser.h` and
`tree_sitter/alloc.h` headers needed to compile them without Node or Cargo.
