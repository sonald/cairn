#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 2 || ! -d "$1" ]]; then
    echo "usage: bash scripts/stress-switch.sh <repo-path> <runs>" >&2
    exit 2
fi

case "$2" in
    ''|*[!0-9]*|0) echo "runs must be a positive integer" >&2; exit 2 ;;
esac

repo_path="$(cd "$1" && pwd -P)"
runs="$2"
timeout_seconds=40

cd "$(dirname "$0")/.."

if ! git -C "$repo_path" rev-parse --verify 'HEAD~1^{commit}' >/dev/null 2>&1; then
    echo "repository needs at least two commits: $repo_path" >&2
    exit 2
fi

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

swift build -c release ${swift_options[@]+"${swift_options[@]}"}
bin_path="$(swift build -c release --show-bin-path ${swift_options[@]+"${swift_options[@]}"})"
binary="$bin_path/codeinsight-app"
output_dir="$PWD/.build/stress-switch-$(date '+%Y%m%d-%H%M%S')-$$"
mkdir -p "$output_dir"

run_once() {
    label="$1"
    run="$2"
    shift 2
    stdout_file="$output_dir/$label-$run.stdout"
    stderr_file="$output_dir/$label-$run.stderr"
    timeout_marker="$output_dir/$label-$run.timeout"
    sample_file="$output_dir/$label-$run.sample.txt"

    "$binary" "$@" >|"$stdout_file" 2>|"$stderr_file" &
    pid=$!
    (
        sleep "$timeout_seconds"
        if kill -0 "$pid" 2>/dev/null; then
            : >|"$timeout_marker"
            /usr/bin/sample "$pid" 1 1 -file "$sample_file" \
                >|"$sample_file.log" 2>&1 || true
            kill -TERM "$pid" 2>/dev/null || true
            sleep 1
            kill -KILL "$pid" 2>/dev/null || true
        fi
    ) &
    watchdog=$!

    status=0
    wait "$pid" || status=$?
    kill "$watchdog" 2>/dev/null || true
    wait "$watchdog" 2>/dev/null || true

    if [[ -f "$timeout_marker" ]]; then
        echo "HANG $label $run/$runs sample=$sample_file"
        return 124
    fi
    if [[ $status -ne 0 ]]; then
        echo "ERROR $label $run/$runs status=$status stderr=$stderr_file"
        return "$status"
    fi
    echo "PASS $label $run/$runs"
}

switch_hangs=0
switch_errors=0
history_hangs=0
history_errors=0
run=1
while [[ $run -le $runs ]]; do
    if run_once switch "$run" --self-test-switch "$repo_path"; then
        :
    else
        status=$?
        if [[ $status -eq 124 ]]; then
            switch_hangs=$((switch_hangs + 1))
        else
            switch_errors=$((switch_errors + 1))
        fi
    fi

    if run_once history "$run" --self-test-history "$repo_path"; then
        :
    else
        status=$?
        if [[ $status -eq 124 ]]; then
            history_hangs=$((history_hangs + 1))
        else
            history_errors=$((history_errors + 1))
        fi
    fi
    run=$((run + 1))
done

echo "switch: hangs=$switch_hangs/$runs errors=$switch_errors/$runs"
echo "history: hangs=$history_hangs/$runs errors=$history_errors/$runs"
echo "artifacts: $output_dir"

if [[ $switch_hangs -ne 0 || $switch_errors -ne 0 \
    || $history_hangs -ne 0 || $history_errors -ne 0 ]]; then
    exit 1
fi
