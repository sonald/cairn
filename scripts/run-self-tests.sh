#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 3 || $# -gt 4 || ! -d "$1" || ! -d "$2" || ! -f "$3" || \
      ($# -eq 4 && ! -d "$4") ]]; then
    echo "usage: bash scripts/run-self-tests.sh <git-repo> <non-git-dir> <open-file> [<python-git-repo>]" >&2
    exit 2
fi

git_repo="$(cd "$1" && pwd -P)"
non_git_root="$(cd "$2" && pwd -P)"
open_file="$(cd "$(dirname "$3")" && pwd -P)/$(basename "$3")"

python_repo=""
if [[ $# -eq 4 ]]; then
    python_repo="$(cd "$4" && pwd -P)"
    if ! git -C "$python_repo" rev-parse --verify 'HEAD~1^{commit}' >/dev/null 2>&1; then
        echo "python-git-repo needs at least two commits: $python_repo" >&2
        exit 2
    fi
    if [[ -n "$(git -C "$python_repo" status --porcelain)" ]]; then
        echo "python-git-repo must be clean: $python_repo" >&2
        exit 2
    fi
    if [[ ! -f "$python_repo/src/mcp/shared/memory.py" || \
          ! -f "$python_repo/src/mcp/server/fastmcp/server.py" ]]; then
        echo "python-git-repo missing fixed corpus files: $python_repo" >&2
        exit 2
    fi
fi

if ! git -C "$git_repo" rev-parse --verify 'HEAD~1^{commit}' >/dev/null 2>&1; then
    echo "git-repo needs at least two commits: $git_repo" >&2
    exit 2
fi
if git -C "$non_git_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "non-git-dir must not be inside a git worktree: $non_git_root" >&2
    exit 2
fi

cd "$(dirname "$0")/.."

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$PWD/.build/clang-module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$PWD/.build/swift-module-cache}"

swift_options=()
if [[ -n "${CODEX_SANDBOX:-}" ]]; then
    swift_options=(
        --disable-sandbox
        --cache-path .build/cache
        --config-path .build/config
        --security-path .build/security
        --manifest-cache local
    )
fi

swift build ${swift_options[@]+"${swift_options[@]}"}
binary="$PWD/.build/debug/codeinsight-app"
output_dir="$PWD/.build/self-test-run-$(date '+%Y%m%d-%H%M%S')-$$"
mkdir -p "$output_dir"

timeout_seconds="${CODEINSIGHT_SELF_TEST_TIMEOUT_SECONDS:-90}"
pass_count=0
fail_count=0
hang_count=0

run_case() {
    label="$1"
    shift
    stdout_file="$output_dir/$label.stdout"
    stderr_file="$output_dir/$label.stderr"
    timeout_marker="$output_dir/$label.timeout"
    sample_file="$output_dir/$label.sample.txt"
    case_tmp="$output_dir/$label.tmp"
    mkdir -p "$case_tmp"

    TMPDIR="$case_tmp/" "$binary" "$@" >"$stdout_file" 2>"$stderr_file" &
    pid=$!
    (
        sleep "$timeout_seconds"
        if kill -0 "$pid" 2>/dev/null; then
            : >"$timeout_marker"
            /usr/bin/sample "$pid" 1 1 -file "$sample_file" \
                >"$sample_file.log" 2>&1 || true
            kill -TERM "$pid" 2>/dev/null || true
            sleep 1
            kill -KILL "$pid" 2>/dev/null || true
        fi
    ) &
    watchdog=$!

    exit_code=0
    wait "$pid" || exit_code=$?
    kill "$watchdog" 2>/dev/null || true
    wait "$watchdog" 2>/dev/null || true
    rm -rf "$case_tmp"

    if [[ -f "$timeout_marker" ]]; then
        hang_count=$((hang_count + 1))
        if grep -q "^SELF_TEST_FINISH " "$stderr_file"; then
            echo "HANG_AFTER_FINISH $label sample=$sample_file"
        else
            echo "HANG_BEFORE_FINISH $label sample=$sample_file"
        fi
    elif [[ $exit_code -ne 0 ]]; then
        fail_count=$((fail_count + 1))
        echo "FAIL $label exit=$exit_code stderr=$stderr_file"
    elif ! grep -q "^SELF_TEST_FINISH .* exit=0$" "$stderr_file"; then
        fail_count=$((fail_count + 1))
        echo "FAIL_NO_FINISH_MARKER $label stderr=$stderr_file"
    else
        pass_count=$((pass_count + 1))
        echo "PASS $label"
    fi
}

# Keep each channel as an explicit independent process. The historical hang was
# observed when unlike channels were hidden inside a shell for-loop.
run_case base --self-test
run_case project-git --self-test-project "$git_repo"
run_case project-non-git --self-test-project "$non_git_root"
run_case tabs --self-test-tabs
run_case search --self-test-search
run_case reading --self-test-reading
run_case projector --self-test-projector
run_case fold --self-test-fold
run_case diff --self-test-diff "$git_repo"
run_case pin --self-test-pin "$git_repo"
run_case history --self-test-history "$git_repo"
run_case exact --self-test-exact "$git_repo"
run_case switch --self-test-switch "$git_repo"
run_case open --self-test-open "$open_file"

if [[ -n "$python_repo" ]]; then
    python_head_before="$(git -C "$python_repo" rev-parse HEAD)"
    python_status_before="$(git -C "$python_repo" status --porcelain)"
    run_case python --self-test-python "$python_repo"
    python_head_after="$(git -C "$python_repo" rev-parse HEAD)"
    python_status_after="$(git -C "$python_repo" status --porcelain)"
    if [[ "$python_head_before" != "$python_head_after" || \
          "$python_status_before" != "$python_status_after" || \
          -n "$python_status_after" ]]; then
        fail_count=$((fail_count + 1))
        echo "FAIL python repo changed during self-test repo=$python_repo" >&2
    fi
fi

echo "summary: pass=$pass_count fail=$fail_count hang=$hang_count"
echo "artifacts: $output_dir"

if [[ $fail_count -ne 0 || $hang_count -ne 0 ]]; then
    exit 1
fi
