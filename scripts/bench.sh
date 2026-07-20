#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "usage: bash scripts/bench.sh <repo-path> [runs=5]" >&2
    exit 2
fi

repo_path="$1"
runs="${2:-5}"
if [[ ! -d "$repo_path" ]]; then
    echo "not a directory: $repo_path" >&2
    exit 2
fi
case "$runs" in
    ''|*[!0-9]*|0) echo "runs must be a positive integer" >&2; exit 2 ;;
esac

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

swift build -c release ${swift_options[@]+"${swift_options[@]}"} >&2
binary="$(swift build -c release --show-bin-path ${swift_options[@]+"${swift_options[@]}"})/codeinsight"

elapsed_values=()
run=1
while [[ $run -le $runs ]]; do
    output="$("$binary" index "$repo_path" --stats)"
    elapsed="$(printf '%s\n' "$output" | awk -F': *' '$1 == "elapsedMilliseconds" { print $2; exit }')"
    case "$elapsed" in
        ''|*[!0-9]*) echo "could not parse elapsedMilliseconds" >&2; exit 1 ;;
    esac
    elapsed_values[${#elapsed_values[@]}]="$elapsed"
    run=$((run + 1))
done

sorted_values=($(printf '%s\n' "${elapsed_values[@]}" | sort -n))
p50_index=$(((runs * 50 + 99) / 100 - 1))
p95_index=$(((runs * 95 + 99) / 100 - 1))

time_output="$(mktemp "${TMPDIR:-/tmp}/codeinsight-bench.XXXXXX")"
trap 'rm -f "$time_output"' EXIT
time_status=0
/usr/bin/time -l "$binary" index "$repo_path" --stats \
    >/dev/null 2>"$time_output" || time_status=$?
rss_bytes="$(awk '/maximum resident set size/ { print $1; exit }' "$time_output")"
case "$rss_bytes" in
    ''|*[!0-9]*)
        echo "warning: time -l unavailable; measuring ru_maxrss with wait4" >&2
        rss_bytes="$(python3 -c '
import os, sys
pid = os.fork()
if pid == 0:
    os.dup2(os.open(os.devnull, os.O_WRONLY), 1)
    os.execv(sys.argv[1], sys.argv[1:])
_, status, usage = os.wait4(pid, 0)
print(usage.ru_maxrss)
raise SystemExit(os.waitstatus_to_exitcode(status))
' "$binary" index "$repo_path" --stats)"
        ;;
    *)
        if [[ $time_status -ne 0 ]]; then
            exit "$time_status"
        fi
        ;;
esac
case "$rss_bytes" in
    ''|*[!0-9]*) echo "could not measure maximum resident set size" >&2; exit 1 ;;
esac

parallelism="$(/usr/sbin/sysctl -n hw.activecpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
rss_mib="$(awk -v bytes="$rss_bytes" 'BEGIN { printf "%.1f", bytes / 1048576 }')"
repo_name="$(basename "$repo_path")"

printf '| %s | %s | %s | %sms | %sms | %sms | %sms | %s MiB (%s B) |\n' \
    "$repo_name" "$runs" "$parallelism" \
    "${sorted_values[0]}" "${sorted_values[$p50_index]}" \
    "${sorted_values[$p95_index]}" "${sorted_values[$((runs - 1))]}" \
    "$rss_mib" "$rss_bytes"
