#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 2 || ! -d "$1" || ! -d "$2" ]]; then
    echo "usage: bash scripts/run-product-gates.sh <python-git-repo> <typescript-git-repo>" >&2
    exit 2
fi

python_repo="$(cd "$1" && pwd -P)"
typescript_repo="$(cd "$2" && pwd -P)"

cd "$(dirname "$0")/.."

fixture_root="$(mktemp -d "${TMPDIR:-/private/tmp}/codeinsight-product-gates.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
non_git_root="$fixture_root/non-git"
cache_root="$fixture_root/index-cache"
mkdir -p "$non_git_root" "$cache_root"
open_file="$PWD/Tests/CodeInsightExactTests/Fixtures/exact_fixture/src/lib.rs"
cp "$open_file" "$non_git_root/main.rs"

bash scripts/ci.sh

CODEINSIGHT_INDEX_CACHE_ROOT="$cache_root" \
    bash scripts/run-self-tests.sh \
    "$PWD" \
    "$non_git_root" \
    "$open_file" \
    "$python_repo" \
    "$typescript_repo"

bash scripts/run-gold-gates.sh \
    --python-corpus "$python_repo" \
    --python-revision "$(git -C "$python_repo" rev-parse HEAD)" \
    --typescript-corpus "$typescript_repo" \
    --typescript-revision "$(git -C "$typescript_repo" rev-parse HEAD)"
