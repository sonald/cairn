#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 3 || $# -gt 6 || ! -d "$1" || ! -d "$2" || ! -f "$3" || \
      ($# -ge 4 && ! -d "$4") || ($# -ge 5 && ! -d "$5") || \
      ($# -eq 6 && ! -d "$6") ]]; then
    cat >&2 <<'EOF'
usage: bash scripts/run-self-tests.sh <git-repo> <non-git-dir> <open-file> [<python-git-repo> [<typescript-git-repo> [<mixed-git-repo>]]]

Positional channels are frozen:
  3 args            = 14 base channels
  4th arg must be   Python (channel 15)
  5th arg must be   Python then TypeScript (channel 16)
  6th arg must be   Python then TypeScript then Mixed (channel 17)
Passing TypeScript as the 4th arg or mixed as the 5th is not supported.
EOF
    exit 2
fi

git_repo="$(cd "$1" && pwd -P)"
non_git_root="$(cd "$2" && pwd -P)"
open_file="$(cd "$(dirname "$3")" && pwd -P)/$(basename "$3")"

python_repo=""
if [[ $# -ge 4 ]]; then
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

typescript_repo=""
if [[ $# -ge 5 ]]; then
    typescript_repo="$(cd "$5" && pwd -P)"
    if ! git -C "$typescript_repo" rev-parse --verify 'HEAD~1^{commit}' >/dev/null 2>&1; then
        echo "typescript-git-repo needs at least two commits: $typescript_repo" >&2
        exit 2
    fi
    if [[ -n "$(git -C "$typescript_repo" status --porcelain)" ]]; then
        echo "typescript-git-repo must be clean: $typescript_repo" >&2
        exit 2
    fi
    ts_count="$(git -C "$typescript_repo" ls-files '*.ts' | \
        grep -vc '\.d\.ts$' || true)"
    tsx_count="$(git -C "$typescript_repo" ls-files '*.tsx' | wc -l | tr -d ' ')"
    if [[ "$ts_count" -ne 2 || "$tsx_count" -ne 51 ]]; then
        echo "typescript-git-repo must be pinned morphic ts=2 tsx=51 got ts=$ts_count tsx=$tsx_count" >&2
        exit 2
    fi
    if [[ ! -f "$typescript_repo/tsconfig.json" || \
          ! -f "$typescript_repo/package.json" || \
          ! -f "$typescript_repo/bun.lockb" ]]; then
        echo "typescript-git-repo missing tsconfig.json, package.json, or bun.lockb" >&2
        exit 2
    fi
fi

mixed_repo=""
if [[ $# -eq 6 ]]; then
    mixed_repo="$(cd "$6" && pwd -P)"
    mixed_fixed_commit="457b66e72da1967c2432131a7ff8adc4341eb337"
    mixed_fixed_history="6cc5b52f9f1bef28b27133155bbb858b2891c829"
    if [[ "$(git -C "$mixed_repo" rev-parse HEAD 2>/dev/null)" \
            != "$mixed_fixed_commit" ]]; then
        echo "mixed-git-repo must be at fixed commit $mixed_fixed_commit: $mixed_repo" >&2
        exit 2
    fi
    if ! git -C "$mixed_repo" rev-list --first-parent HEAD \
            | grep -x "$mixed_fixed_history" >/dev/null; then
        echo "mixed-git-repo historical revision is not an ancestor of HEAD: $mixed_repo" >&2
        exit 2
    fi
    if [[ -n "$(git -C "$mixed_repo" status --porcelain=v1)" || \
          -n "$(git -C "$mixed_repo" ls-files --others --exclude-standard)" ]]; then
        echo "mixed-git-repo must be clean: $mixed_repo" >&2
        exit 2
    fi
    if [[ -n "$(git -C "$mixed_repo" ls-files --others --ignored --exclude-standard)" ]]; then
        echo "mixed-git-repo must have no untracked or ignored files: $mixed_repo" >&2
        exit 2
    fi
    mixed_rust="$(git -C "$mixed_repo" ls-files '*.rs' | wc -l | tr -d ' ')"
    mixed_python="$(git -C "$mixed_repo" ls-files '*.py' | wc -l | tr -d ' ')"
    mixed_ts="$(git -C "$mixed_repo" ls-files '*.ts' | \
        grep -vc '\.d\.ts$' || true)"
    mixed_tsx="$(git -C "$mixed_repo" ls-files '*.tsx' | wc -l | tr -d ' ')"
    mixed_dts="$(git -C "$mixed_repo" ls-files '*.d.ts' | wc -l | tr -d ' ')"
    mixed_js="$(git -C "$mixed_repo" ls-files '*.js' '*.jsx' | wc -l | tr -d ' ')"
    if [[ "$mixed_rust" -ne 11 || "$mixed_python" -ne 8 || \
          "$mixed_ts" -ne 22 || "$mixed_tsx" -ne 4 || \
          "$mixed_dts" -ne 1 || "$mixed_js" -ne 0 ]]; then
        echo "mixed-git-repo counts want rust=11 python=8 ts=22 tsx=4 dts=1 js=0 got rust=$mixed_rust python=$mixed_python ts=$mixed_ts tsx=$mixed_tsx dts=$mixed_dts js=$mixed_js" >&2
        exit 2
    fi
    mixed_configs=(
        "pyproject.toml 0c48694c3cc9668d7e062a03e98ab41d53a5b68a7500bd977da826e5f01273e6"
        "uv.lock 562ebad06578ceca1bbcd1888942fcb8bf001340dbd63ce6c4d5737c144dbe4c"
        "crates/qrcode2txt/Cargo.toml e0079b229039a8a02b440878c4235f6ac05a0c5e6db71b6cf61fcf28eee947a2"
        "tools/model-files-web/tsconfig.json 770b4140bbb581e2dfd9ea9946ffc9c75a1d86ba7d2db5f77c83e37cbdf9d808"
        "tools/model-files-web/package.json 798565f0dc3bcb30375457bd8e003d7c30b14679f0e79bc6a1c50ddd0d63eb6c"
        "tools/model-files-web/package-lock.json 8373619bda0840fb24893976201504404cd0fde71f61621057b529dfc1719d31"
    )
    for entry in "${mixed_configs[@]}"; do
        read -r path want <<< "$entry"
        got="$(shasum -a 256 "$mixed_repo/$path" | awk '{print $1}')"
        if [[ "$got" != "$want" ]]; then
            echo "mixed config hash mismatch $path want=$want got=$got" >&2
            exit 2
        fi
    done
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

if [[ -n "$typescript_repo" ]]; then
    typescript_head_before="$(git -C "$typescript_repo" rev-parse HEAD)"
    typescript_status_before="$(git -C "$typescript_repo" status --porcelain)"
    run_case typescript --self-test-typescript "$typescript_repo"
    typescript_head_after="$(git -C "$typescript_repo" rev-parse HEAD)"
    typescript_status_after="$(git -C "$typescript_repo" status --porcelain)"
    if [[ "$typescript_head_before" != "$typescript_head_after" || \
          "$typescript_status_before" != "$typescript_status_after" || \
          -n "$typescript_status_after" ]]; then
        fail_count=$((fail_count + 1))
        echo "FAIL typescript repo changed during self-test repo=$typescript_repo" >&2
    fi
fi

if [[ -n "$mixed_repo" ]]; then
    mixed_head_before="$(git -C "$mixed_repo" rev-parse HEAD)"
    mixed_status_before="$(git -C "$mixed_repo" status --porcelain=v1)"
    mixed_ignored_before="$(git -C "$mixed_repo" ls-files --others --ignored --exclude-standard)"
    mixed_index_before="$(git -C "$mixed_repo" ls-files -s)"
    run_case mixed --self-test-mixed "$mixed_repo"
    mixed_head_after="$(git -C "$mixed_repo" rev-parse HEAD)"
    mixed_status_after="$(git -C "$mixed_repo" status --porcelain=v1)"
    mixed_ignored_after="$(git -C "$mixed_repo" ls-files --others --ignored --exclude-standard)"
    mixed_index_after="$(git -C "$mixed_repo" ls-files -s)"
    if [[ "$mixed_head_before" != "$mixed_head_after" || \
          "$mixed_status_before" != "$mixed_status_after" || \
          "$mixed_ignored_before" != "$mixed_ignored_after" || \
          "$mixed_index_before" != "$mixed_index_after" || \
          -n "$mixed_status_after" ]]; then
        fail_count=$((fail_count + 1))
        echo "FAIL mixed repo changed during self-test repo=$mixed_repo" >&2
    fi
fi

echo "summary: pass=$pass_count fail=$fail_count hang=$hang_count"
echo "artifacts: $output_dir"

if [[ -n "$mixed_repo" && ( $pass_count -ne 17 || $fail_count -ne 0 || \
      $hang_count -ne 0 ) ]]; then
    echo "mixed 17-channel gate requires pass=17 fail=0 hang=0" >&2
    exit 1
fi

if [[ $fail_count -ne 0 || $hang_count -ne 0 ]]; then
    exit 1
fi
