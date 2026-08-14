#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 2 || ! -d "$1" || ! -d "$2" ]]; then
    echo "usage: bash scripts/run-product-gates.sh <python-git-repo> <typescript-git-repo>" >&2
    exit 2
fi

python_repo="$(cd "$1" && pwd -P)"
typescript_repo="$(cd "$2" && pwd -P)"

cd "$(dirname "$0")/.."

required_tools=(
    git jq rg swift rust-analyzer pyright pyright-langserver
    node npm typescript-language-server tsserver
)
for tool in "${required_tools[@]}"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "missing required product-gate tool: $tool" >&2
        exit 1
    fi
done

echo "--- product toolchain ---"
sw_vers
xcodebuild -version
swift --version
rust-analyzer --version
pyright --version
typescript-language-server --version
node --version
npm list --global --depth=0 pyright typescript-language-server typescript
echo "--- end product toolchain ---"

fixture_root="$(mktemp -d "${TMPDIR:-/private/tmp}/codeinsight-product-gates.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
non_git_root="$fixture_root/non-git"
cache_root="$fixture_root/index-cache"
mkdir -p "$non_git_root" "$cache_root"
open_file="$PWD/Tests/CodeInsightExactTests/Fixtures/exact_fixture/src/lib.rs"
cp "$open_file" "$non_git_root/main.rs"

bash scripts/ci.sh

self_test_log="$fixture_root/self-tests.log"
if ! CODEINSIGHT_INDEX_CACHE_ROOT="$cache_root" \
        bash scripts/run-self-tests.sh \
        "$PWD" \
        "$non_git_root" \
        "$open_file" \
        "$python_repo" \
        "$typescript_repo" >"$self_test_log" 2>&1
then
    cat "$self_test_log"
    exit 1
fi
cat "$self_test_log"

self_test_artifacts="$(sed -n 's/^artifacts: //p' "$self_test_log")"
exact_output="$self_test_artifacts/exact.stdout"
if [[ -z "$self_test_artifacts" || ! -f "$exact_output" ]] || \
   ! jq -e '
        select(.step == "summary")
        | .realProvider == "passed"
            and .realOfflineCoverage == "passed"
    ' "$exact_output" >/dev/null
then
    echo "FAIL real rust-analyzer product coverage was skipped or failed" >&2
    [[ -f "$exact_output" ]] && jq -c '
        select(.step == "summary")
        | {realProvider, realOfflineCoverage}
    ' "$exact_output" >&2
    exit 1
fi
echo "PASS real rust-analyzer and offline coverage"

bash scripts/run-gold-gates.sh \
    --python-corpus "$python_repo" \
    --python-revision "$(git -C "$python_repo" rev-parse HEAD)" \
    --typescript-corpus "$typescript_repo" \
    --typescript-revision "$(git -C "$typescript_repo" rev-parse HEAD)"
