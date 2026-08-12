#!/usr/bin/env bash

set -euo pipefail

TREE_SITTER_TAG="v0.25.8"
TREE_SITTER_RUST_TAG="v0.24.0"
TREE_SITTER_PYTHON_TAG="v0.25.0"

TREE_SITTER_URL="https://github.com/tree-sitter/tree-sitter/archive/refs/tags/${TREE_SITTER_TAG}.tar.gz"
TREE_SITTER_RUST_URL="https://github.com/tree-sitter/tree-sitter-rust/archive/refs/tags/${TREE_SITTER_RUST_TAG}.tar.gz"
TREE_SITTER_PYTHON_RELEASE_URL="https://github.com/tree-sitter/tree-sitter-python/archive/refs/tags/${TREE_SITTER_PYTHON_TAG}.tar.gz"
TREE_SITTER_PYTHON_RELEASE_SHA256="4609a3665a620e117acf795ff01b9e965880f81745f287a16336f4ca86cf270c"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME_TARGET="$REPO_ROOT/Sources/CTreeSitter"
RUST_TARGET="$REPO_ROOT/Sources/CTreeSitterRust"
PYTHON_TARGET="$REPO_ROOT/Sources/CTreeSitterPython"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codeinsight-vendor.XXXXXX")"
VENDORED_DATE="$(date +%F)"

PYTHON_ONLY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --python-only)
            PYTHON_ONLY=1
            shift
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

if [[ $PYTHON_ONLY -eq 0 ]]; then
    curl -fL --retry 3 -o "$WORK_DIR/tree-sitter.tar.gz" "$TREE_SITTER_URL"
    curl -fL --retry 3 -o "$WORK_DIR/tree-sitter-rust.tar.gz" "$TREE_SITTER_RUST_URL"
    tar -xzf "$WORK_DIR/tree-sitter.tar.gz" -C "$WORK_DIR"
    tar -xzf "$WORK_DIR/tree-sitter-rust.tar.gz" -C "$WORK_DIR"

    RUNTIME_SOURCE="$WORK_DIR/tree-sitter-${TREE_SITTER_TAG#v}"
    RUST_SOURCE="$WORK_DIR/tree-sitter-rust-${TREE_SITTER_RUST_TAG#v}"

    rm -rf "$RUNTIME_TARGET" "$RUST_TARGET"
    mkdir -p \
        "$RUNTIME_TARGET/include/tree_sitter" \
        "$RUNTIME_TARGET/src" \
        "$RUST_TARGET/include" \
        "$RUST_TARGET/src/tree_sitter"

    rsync -a --prune-empty-dirs \
        --include '*/' --include '*.c' --include '*.h' --exclude '*' \
        "$RUNTIME_SOURCE/lib/src/" "$RUNTIME_TARGET/src/"
    cp "$RUNTIME_SOURCE/lib/include/tree_sitter/"*.h \
        "$RUNTIME_TARGET/include/tree_sitter/"
    cp "$RUNTIME_SOURCE/LICENSE" "$RUNTIME_TARGET/LICENSE"

    cp "$RUST_SOURCE/src/parser.c" "$RUST_TARGET/src/parser.c"
    cp "$RUST_SOURCE/src/scanner.c" "$RUST_TARGET/src/scanner.c"
    cp "$RUST_SOURCE/src/node-types.json" "$RUST_TARGET/src/node-types.json"
    cp "$RUST_SOURCE/src/tree_sitter/parser.h" \
        "$RUST_TARGET/src/tree_sitter/parser.h"
    cp "$RUST_SOURCE/src/tree_sitter/alloc.h" \
        "$RUST_TARGET/src/tree_sitter/alloc.h"
    cp "$RUST_SOURCE/LICENSE" "$RUST_TARGET/LICENSE"

    cat > "$RUST_TARGET/include/tree_sitter_rust.h" <<'EOF'
#ifndef TREE_SITTER_RUST_H_
#define TREE_SITTER_RUST_H_

#include <tree_sitter/api.h>

#ifdef __cplusplus
extern "C" {
#endif

const TSLanguage *tree_sitter_rust(void);

#ifdef __cplusplus
}
#endif

#endif
EOF

    cat > "$RUNTIME_TARGET/VENDORED.md" <<EOF
# Vendored tree-sitter runtime

- Upstream: https://github.com/tree-sitter/tree-sitter
- Release tag: \`$TREE_SITTER_TAG\`
- Download URL: $TREE_SITTER_URL
- Vendored date: $VENDORED_DATE
- Vendoring method: downloaded by \`scripts/vendor-treesitter.sh\`
- License: MIT; see \`LICENSE\` in this directory.

\`src/lib.c\` is the upstream unity build and is the only C source compiled by
SwiftPM. The remaining upstream \`.c\` files are retained because \`lib.c\`
includes them.
EOF

    cat > "$RUST_TARGET/VENDORED.md" <<EOF
# Vendored tree-sitter-rust grammar

- Upstream: https://github.com/tree-sitter/tree-sitter-rust
- Release tag: \`$TREE_SITTER_RUST_TAG\`
- Download URL: $TREE_SITTER_RUST_URL
- Vendored date: $VENDORED_DATE
- Vendoring method: downloaded by \`scripts/vendor-treesitter.sh\`
- License: MIT; see \`LICENSE\` in this directory.

The generated \`parser.c\`, \`scanner.c\`, and \`node-types.json\` are vendored
along with the generated \`tree_sitter/parser.h\` and
\`tree_sitter/alloc.h\` headers needed to compile them without Node or Cargo.
EOF

    exit 0
fi

curl -fL --retry 3 -o "$WORK_DIR/tree-sitter-python.tar.gz" "$TREE_SITTER_PYTHON_RELEASE_URL"
ACTUAL_SHA="$(shasum -a 256 "$WORK_DIR/tree-sitter-python.tar.gz" | awk '{print $1}')"
if [[ "$ACTUAL_SHA" != "$TREE_SITTER_PYTHON_RELEASE_SHA256" ]]; then
    echo "error: python archive SHA-256 mismatch: expected $TREE_SITTER_PYTHON_RELEASE_SHA256 got $ACTUAL_SHA" >&2
    exit 1
fi
tar -xzf "$WORK_DIR/tree-sitter-python.tar.gz" -C "$WORK_DIR"

PYTHON_SOURCE="$WORK_DIR/tree-sitter-python-${TREE_SITTER_PYTHON_TAG#v}"

rm -rf "$PYTHON_TARGET"
mkdir -p "$PYTHON_TARGET/include" "$PYTHON_TARGET/src/tree_sitter"
cp "$PYTHON_SOURCE/src/parser.c" "$PYTHON_TARGET/src/parser.c"
cp "$PYTHON_SOURCE/src/scanner.c" "$PYTHON_TARGET/src/scanner.c"
cp "$PYTHON_SOURCE/src/node-types.json" "$PYTHON_TARGET/src/node-types.json"
cp "$PYTHON_SOURCE/src/tree_sitter/alloc.h" \
    "$PYTHON_TARGET/src/tree_sitter/alloc.h"
cp "$PYTHON_SOURCE/src/tree_sitter/array.h" \
    "$PYTHON_TARGET/src/tree_sitter/array.h"
cp "$PYTHON_SOURCE/src/tree_sitter/parser.h" \
    "$PYTHON_TARGET/src/tree_sitter/parser.h"
cp "$RUNTIME_TARGET/src/ts_assert.h" \
    "$PYTHON_TARGET/src/tree_sitter/ts_assert.h"
cp "$PYTHON_SOURCE/LICENSE" "$PYTHON_TARGET/LICENSE"

cat > "$PYTHON_TARGET/include/tree_sitter_python.h" <<'EOF'
#ifndef TREE_SITTER_PYTHON_H_
#define TREE_SITTER_PYTHON_H_

#include <tree_sitter/api.h>

#ifdef __cplusplus
extern "C" {
#endif

const TSLanguage *tree_sitter_python(void);

#ifdef __cplusplus
}
#endif

#endif
EOF

cat > "$PYTHON_TARGET/VENDORED.md" <<EOF
# Vendored tree-sitter-python grammar

- Upstream: https://github.com/tree-sitter/tree-sitter-python
- Release tag: \`$TREE_SITTER_PYTHON_TAG\`
- Release commit: \`293fdc02038ee2bf0e2e206711b69c90ac0d413f\`
- Download URL: $TREE_SITTER_PYTHON_RELEASE_URL
- Archive SHA-256: $TREE_SITTER_PYTHON_RELEASE_SHA256
- Vendored date: $VENDORED_DATE
- Vendoring method: downloaded by \`scripts/vendor-treesitter.sh\`
- License: MIT; see \`LICENSE\` in this directory.

The generated \`parser.c\`, \`scanner.c\`, and \`node-types.json\` are vendored
along with the generated \`tree_sitter/parser.h\` and
\`tree_sitter/alloc.h\` headers needed to compile them without Node or Cargo.
EOF
