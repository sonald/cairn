#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 3 || ! -d "$1" || ! -d "$2" || ! -d "$3" ]]; then
    echo "usage: bash scripts/run-product-gates.sh <python-git-repo> <typescript-git-repo> <mixed-git-repo>" >&2
    exit 2
fi

python_repo="$(cd "$1" && pwd -P)"
typescript_repo="$(cd "$2" && pwd -P)"
mixed_repo="$(cd "$3" && pwd -P)"

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

provider_baseline="$(mktemp "$fixture_root/provider-baseline.XXXXXX")"
collect_provider_pids() {
    if command -v pgrep >/dev/null 2>&1; then
        {
            pgrep -x rust-analyzer || true
            pgrep -f "pyright-langserver" || true
            pgrep -f "typescript-language-server|/lib/cli\.mjs|tsserver\.js" || true
        } | sort -n -u
    else
        ps -axo pid=,command= | awk '
            /rust-analyzer/ || /pyright-langserver/ || /tsserver/ || /typescript-language-server/ {
                print $1
            }
        ' | sort -n -u
    fi
}
collect_provider_pids >"$provider_baseline"

bash scripts/ci.sh

self_test_log="$fixture_root/self-tests.log"
if ! CODEINSIGHT_INDEX_CACHE_ROOT="$cache_root" \
        bash scripts/run-self-tests.sh \
        "$PWD" \
        "$non_git_root" \
        "$open_file" \
        "$python_repo" \
        "$typescript_repo" \
        "$mixed_repo" >"$self_test_log" 2>&1
then
    cat "$self_test_log"
    exit 1
fi
cat "$self_test_log"

self_test_artifacts="$(sed -n 's/^artifacts: //p' "$self_test_log")"
if [[ -z "$self_test_artifacts" ]]; then
    echo "FAIL no self-test artifacts line in $self_test_log" >&2
    exit 1
fi

channel_summary="$(sed -n 's/^summary: //p' "$self_test_log")"
if [[ "$channel_summary" != "pass=17 fail=0 hang=0" ]]; then
    echo "FAIL expected 17-channel summary pass=17 fail=0 hang=0 got $channel_summary" >&2
    exit 1
fi

exact_output="$self_test_artifacts/exact.stdout"
python_output="$self_test_artifacts/python.stdout"
typescript_output="$self_test_artifacts/typescript.stdout"
mixed_output="$self_test_artifacts/mixed.stdout"
if [[ ! -f "$exact_output" || ! -f "$python_output" || \
      ! -f "$typescript_output" || ! -f "$mixed_output" ]]; then
    echo "FAIL missing required self-test stdout artifacts" >&2
    exit 1
fi

if [[ ! -f "$self_test_artifacts/mixed.stderr" ]] || \
   ! grep -q "^SELF_TEST_FINISH .* exit=0$" \
        "$self_test_artifacts/mixed.stderr"; then
    echo "FAIL mixed self-test did not finish with exit=0" >&2
    exit 1
fi

if ! jq -e '
        select(.step == "MIXED_SELF_TEST_SUMMARY")
        | .passed == true
            and (.checks | to_entries | all(.value == true))
            and (.coldSnapshot | type == "string") and (.coldSnapshot | length > 0)
            and (.commitSnapshot | type == "string") and (.commitSnapshot | length > 0)
            and (.worktreeSnapshot | type == "string") and (.worktreeSnapshot | length > 0)
            and ([.coldSnapshot, .commitSnapshot, .worktreeSnapshot] | unique | length) == 3
            and (.coldStats | to_entries | length) == 3
            and (.hotStats | to_entries | length) == 3
            and (.providerVersions | length) == 3
            and ([.providerVersions[].provider] | sort) == ["pyright", "rust-analyzer", "typescript-language-server"]
            and ([.providerVersions[].toolVersion] | all(type == "string" and length > 0))
            and .coldStats.rust.files == 11
            and .coldStats.python.files == 8
            and .coldStats.typescript.files == 26
            and .coldStats.rust.extracted == 11
            and .coldStats.python.extracted == 8
            and .coldStats.typescript.extracted == 26
            and .coldStats.rust.reused == 0
            and .coldStats.python.reused == 0
            and .coldStats.typescript.reused == 0
            and .hotStats.rust.files == 11
            and .hotStats.python.files == 8
            and .hotStats.typescript.files == 26
            and .hotStats.rust.reused == 11
            and .hotStats.python.reused == 8
            and .hotStats.typescript.reused == 26
            and ([.providerVersions[].readyMS] | all(. >= 0 and . < 30000))
            and .commitSwitchMS >= 0 and .commitSwitchMS < 30000
            and .worktreeSwitchMS >= 0 and .worktreeSwitchMS < 30000
    ' "$mixed_output" >/dev/null; then
    echo "FAIL mixed summary/checks/provider/stats mismatch" >&2
    exit 1
fi

if ! jq -e '
        select(.step == "MIXED_SELF_TEST_EXACT")
        | .passed == true
            and (.exact | length) == 3
            and ([.exact[].definitionCount] | all(. > 0))
            and ([.exact[].verifiedReferenceCount] | all(. > 0))
    ' "$mixed_output" >/dev/null; then
    echo "FAIL mixed exact definition/reference counts missing" >&2
    exit 1
fi

if ! jq -e '
        select(.step == "MIXED_SELF_TEST_COMPARE")
        | .leftLineCount == 62
            and .rightLineCount == 45
            and .changeCount == 17
            and .truncated == false
            and .hunkCount > 0
    ' "$mixed_output" >/dev/null; then
    echo "FAIL mixed compare counts not 62/45/17" >&2
    exit 1
fi

echo "PASS mixed product self-test"

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

if ! jq -e '
        select(.step == "real-python-exact")
        | .provider == "pyright"
            and .definitionTargets > 0
            and .references > 0
    ' "$python_output" >/dev/null; then
    echo "FAIL Python real Pyright exact coverage" >&2
    exit 1
fi
echo "PASS real Pyright coverage"

if ! jq -e '
        select(.step == "real-typescript-exact")
        | .provider == "typescript-language-server"
            and .definitionTargets > 0
            and .exactReferences == true
    ' "$typescript_output" >/dev/null; then
    echo "FAIL TypeScript real TLS exact coverage" >&2
    exit 1
fi
echo "PASS real TypeScript coverage"

new_provider_pids="$(comm -13 <(sort -u "$provider_baseline") <(collect_provider_pids))"
if [[ -n "$new_provider_pids" ]]; then
    echo "FAIL new provider processes remained after self-tests: $new_provider_pids" >&2
    exit 1
fi
echo "PASS no new provider processes after product gates"

bash scripts/run-gold-gates.sh \
    --python-corpus "$python_repo" \
    --python-revision "$(git -C "$python_repo" rev-parse HEAD)" \
    --typescript-corpus "$typescript_repo" \
    --typescript-revision "$(git -C "$typescript_repo" rev-parse HEAD)"
