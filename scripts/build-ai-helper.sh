#!/usr/bin/env bash
# Builds the cairn-ai helper (Helpers/cairn-ai) into .build/cairn-ai/release,
# where a `swift run` build of Cairn looks for it; make-app.sh copies it into
# the app bundle. Needs a Rust toolchain (rustup).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cargo build --release --locked \
    --manifest-path "$REPO_ROOT/Helpers/cairn-ai/Cargo.toml" \
    --target-dir "$REPO_ROOT/.build/cairn-ai"
echo "$REPO_ROOT/.build/cairn-ai/release/cairn-ai"
