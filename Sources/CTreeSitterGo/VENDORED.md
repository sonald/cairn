# Vendored tree-sitter-go grammar

- Upstream: https://github.com/tree-sitter/tree-sitter-go
- Release tag: `v0.25.0` (tag time 2025-08-29T06:17:40Z)
- Obtained as the Go module `github.com/tree-sitter/tree-sitter-go@v0.25.0`
  from the module proxy, because GitHub was unreachable on the vendoring
  day. The module zip is the repository tree at that tag; `go mod download`
  verified it against the Go checksum database.
- Module hash (`go.sum`): `h1:cEB0Q3LHgZtS+ECHx9wcP7AwzoOddJFQCVmytX42cVU=`
- Module zip SHA-256: `e4501d10db1aee5f0b15354f4ae31296d8d8a93282a85d12302e6c682944438a`
- Vendored date: 2026-11-11
- Vendoring method: copied by hand; `scripts/vendor-treesitter.sh` does not
  cover this target.
- License: MIT; see `LICENSE` in this directory.

The generated `parser.c` and `node-types.json` are vendored along with the
generated `tree_sitter/parser.h`, `tree_sitter/alloc.h` and
`tree_sitter/array.h` headers needed to compile them without Node or Cargo.
The grammar has no external scanner. It is ABI 15.

Known gaps measured on Go 1.27.3's standard library (6,827 files, 7 with
error nodes; see `docs/evidence/go-feasibility-2026-11`): `new(expression)`
and methods with type parameters are not parsed.
