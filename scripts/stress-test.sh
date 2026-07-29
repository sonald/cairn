#!/usr/bin/env bash

set -uo pipefail

# macOS has no `timeout`; coreutils installs it as `gtimeout`. Timed commands
# therefore run in the background and are polled against a wall-clock deadline.
# zsh's `noclobber` makes plain `>` fail on an existing file and can fake
# exit=1, so every reusable artifact is written with `>|`.
# The real executable names are `codeinsight-app` and `codeinsight`, not
# `CodeInsightApp` or `codeinsight-cli`.
# Never measure with stale binaries: the preflight build below refreshes them
# before checking both real executable paths.

usage() {
    echo "usage: bash scripts/stress-test.sh [--runs N] [--load N] [--timeout SECONDS]"
}

positive_integer() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

nonnegative_integer() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

runs=5
load_count=8
timeout_seconds=180

while [[ $# -gt 0 ]]; do
    case "$1" in
        --runs)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            runs="$2"
            shift 2
            ;;
        --load)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            load_count="$2"
            shift 2
            ;;
        --timeout)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            timeout_seconds="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
done

positive_integer "$runs" || { echo "--runs must be a positive integer" >&2; exit 2; }
nonnegative_integer "$load_count" || { echo "--load must be a nonnegative integer" >&2; exit 2; }
positive_integer "$timeout_seconds" \
    || { echo "--timeout must be a positive integer" >&2; exit 2; }

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

output_dir="$PWD/.build/stress-test-$(date '+%Y%m%d-%H%M%S')-$$"
mkdir -p "$output_dir"

load_marker="codeinsight-m8-stress-load-$$-$(date '+%s')"
load_pids=()
all_load_pids=()
current_pid=""
overall_watchdog_pid=""
timed_out=0
command_status=0
feature_scan_status=0
feature_residual_count=0

kill_process_tree() {
    local root="$1"

    # run_with_timeout gives each command its own process group, so one signal
    # reaches SwiftPM, the test runner, and their descendants.
    kill -TERM -- "-$root" 2>/dev/null || kill -TERM "$root" 2>/dev/null || true
    sleep 1
    kill -KILL -- "-$root" 2>/dev/null || kill -KILL "$root" 2>/dev/null || true
}

cleanup_loads() {
    local pid

    for pid in ${load_pids[@]+"${load_pids[@]}"}; do
        kill -TERM "$pid" 2>/dev/null || true
    done
    sleep 1
    for pid in ${load_pids[@]+"${load_pids[@]}"}; do
        kill -KILL "$pid" 2>/dev/null || true
    done

    # Feature fallback catches a PID missed by bookkeeping without touching
    # unrelated zsh processes; the marker is unique to this invocation.
    pkill -TERM -f "$load_marker" 2>/dev/null || true
    sleep 1
    pkill -KILL -f "$load_marker" 2>/dev/null || true
    sleep 1
    load_pids=()
}

residual_load_count() {
    local pid
    local count=0

    for pid in ${all_load_pids[@]+"${all_load_pids[@]}"}; do
        kill -0 "$pid" 2>/dev/null && count=$((count + 1))
    done
    echo "$count"
}

scan_feature_residuals() {
    local residual_pids

    residual_pids="$(pgrep -f "$load_marker" 2>/dev/null)"
    feature_scan_status=$?
    if [[ $feature_scan_status -eq 0 ]]; then
        feature_residual_count="$(wc -w <<<"$residual_pids" | tr -d ' ')"
    elif [[ $feature_scan_status -eq 1 ]]; then
        feature_residual_count=0
    else
        feature_residual_count=0
    fi
}

cleanup_all() {
    local incoming_status=$?
    local exit_code="${1:-$incoming_status}"
    local residual

    trap - EXIT INT TERM
    if [[ -n "$current_pid" ]] && kill -0 "$current_pid" 2>/dev/null; then
        kill_process_tree "$current_pid"
    fi
    cleanup_loads
    if [[ -n "$overall_watchdog_pid" ]]; then
        kill "$overall_watchdog_pid" 2>/dev/null || true
    fi

    residual="$(residual_load_count)"
    scan_feature_residuals
    if [[ $feature_scan_status -le 1 && $feature_residual_count -gt $residual ]]; then
        residual="$feature_residual_count"
    fi
    if [[ $feature_scan_status -le 1 ]]; then
        echo "residual_load_processes=$residual feature_scan=available"
    else
        echo "residual_load_processes=$residual feature_scan=unavailable(exit=$feature_scan_status)"
    fi
    [[ "$residual" -eq 0 ]] || exit_code=1
    exit "$exit_code"
}

trap cleanup_all EXIT
trap 'cleanup_all 130' INT
trap 'cleanup_all 143' TERM

run_with_timeout() {
    local limit="$1"
    local log_file="$2"
    shift 2
    local deadline
    local status_file="$log_file.status"

    timed_out=0
    command_status=0
    set -m
    (
        "$@"
        status=$?
        echo "$status" >|"$status_file"
        exit "$status"
    ) >|"$log_file" 2>&1 &
    current_pid=$!
    set +m
    deadline=$((SECONDS + limit))

    while kill -0 "$current_pid" 2>/dev/null; do
        if [[ $SECONDS -ge $deadline ]]; then
            timed_out=1
            kill_process_tree "$current_pid"
            break
        fi
        sleep 1
    done

    if [[ -f "$status_file" ]]; then
        command_status="$(<"$status_file")"
    elif [[ $timed_out -eq 0 ]]; then
        command_status=1
    fi
    current_pid=""
}

start_loads() {
    local load_lifetime=$((timeout_seconds + 10))
    local index
    local alive=0

    load_pids=()
    for ((index = 0; index < load_count; index++)); do
        /bin/zsh -c \
            'marker=$1; lifetime=$2; end=$((SECONDS + lifetime)); while (( SECONDS < end )); do :; done' \
            codeinsight-stress-worker "$load_marker" "$load_lifetime" &
        load_pids+=("$!")
        all_load_pids+=("$!")
    done
    sleep 1
    for index in ${load_pids[@]+"${load_pids[@]}"}; do
        kill -0 "$index" 2>/dev/null && alive=$((alive + 1))
    done
    if [[ $alive -ne $load_count ]]; then
        echo "load startup failed: expected=$load_count alive=$alive" >&2
        return 1
    fi
}

overall_timeout=$(((runs + 1) * timeout_seconds + runs * 10 + 60))
script_pid=$$
/bin/zsh -c \
    'sleep "$1"; if [[ $PPID -eq $2 ]] && kill -0 "$2" 2>/dev/null; then print -u2 -- "overall HANG timeout=${1}s"; kill -TERM "$2"; fi' \
    "$overall_timeout" "$script_pid" &
overall_watchdog_pid=$!

preflight_log="$output_dir/preflight-build.log"
run_with_timeout "$timeout_seconds" "$preflight_log" \
    swift build ${swift_options[@]+"${swift_options[@]}"}
if [[ $timed_out -eq 1 ]]; then
    echo "preflight: HANG duration=${timeout_seconds}s log=$preflight_log"
    exit 1
fi
if [[ $command_status -ne 0 ]]; then
    echo "preflight: ERROR exit=$command_status log=$preflight_log"
    exit 1
fi
for binary in .build/debug/codeinsight-app .build/debug/codeinsight; do
    if [[ ! -x "$binary" ]]; then
        echo "preflight: missing executable $binary" >&2
        exit 1
    fi
done
echo "preflight: PASS binaries=codeinsight-app,codeinsight"
echo "config: runs=$runs load=$load_count timeout=${timeout_seconds}s overall_timeout=${overall_timeout}s"

total_failures=0
hangs=0
errors=0
experiment_start=$SECONDS

for ((run = 1; run <= runs; run++)); do
    log_file="$output_dir/run-$run.log"
    run_start=$SECONDS
    if ! start_loads; then
        cleanup_loads
        exit 1
    fi

    run_with_timeout "$timeout_seconds" "$log_file" \
        swift test ${swift_options[@]+"${swift_options[@]}"}
    duration=$((SECONDS - run_start))
    cleanup_loads

    if [[ $timed_out -eq 1 ]]; then
        hangs=$((hangs + 1))
        echo "run=$run HANG failures=unknown duration=${duration}s log=$log_file"
        continue
    fi

    failures="$(
        sed -nE \
            's/.*Test run with [0-9]+ tests.*failed.*with ([0-9]+) issues?.*/\1/p' \
            "$log_file" | tail -1
    )"
    if [[ -z "$failures" ]]; then
        failures="$(
            sed -nE \
                's/.*Executed [0-9]+ tests, with ([0-9]+) failures.*/\1/p' \
                "$log_file" | tail -1
        )"
    fi
    if [[ -z "$failures" && $command_status -eq 0 ]]; then
        failures=0
    elif [[ -z "$failures" ]]; then
        failures=1
        errors=$((errors + 1))
    fi

    total_failures=$((total_failures + failures))
    echo "run=$run failures=$failures duration=${duration}s exit=$command_status log=$log_file"
done

experiment_duration=$((SECONDS - experiment_start))
echo "summary: runs=$runs failures=$total_failures hangs=$hangs errors=$errors duration=${experiment_duration}s"
echo "artifacts: $output_dir"

if [[ $total_failures -ne 0 || $hangs -ne 0 || $errors -ne 0 ]]; then
    exit 1
fi
