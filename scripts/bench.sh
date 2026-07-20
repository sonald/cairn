#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "usage: bash scripts/bench.sh <repo-path> [runs=5] | --app <corpus-dir>" >&2
    exit 2
fi

mode="index"
if [[ "$1" == "--app" ]]; then
    if [[ $# -ne 2 || ! -d "$2" ]]; then
        echo "usage: bash scripts/bench.sh --app <corpus-dir>" >&2
        exit 2
    fi
    mode="app"
    repo_path="$(cd "$2" && pwd -P)"
    runs=3
else
    repo_path="$1"
    runs="${2:-5}"
    if [[ ! -d "$repo_path" ]]; then
        echo "not a directory: $repo_path" >&2
        exit 2
    fi
    case "$runs" in
        ''|*[!0-9]*|0) echo "runs must be a positive integer" >&2; exit 2 ;;
    esac
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

swift build -c release ${swift_options[@]+"${swift_options[@]}"} >&2
bin_path="$(swift build -c release --show-bin-path ${swift_options[@]+"${swift_options[@]}"})"

if [[ "$mode" == "app" ]]; then
    binary="$bin_path/codeinsight-app"
    open_file="$(find "$repo_path" -type f -name '*.rs' -print | LC_ALL=C sort | sed -n '1p')"
    if [[ -z "$open_file" ]]; then
        echo "no Rust file found in: $repo_path" >&2
        exit 2
    fi

    run_app_case() {
        label="$1"
        shift
        values=()
        run=1
        while [[ $run -le 3 ]]; do
            values[${#values[@]}]="$("$binary" "$@")"
            run=$((run + 1))
        done
        printf '%s\n' "${values[@]}" | python3 -c '
import json, sys
rows = [json.loads(line) for line in sys.stdin if line.strip()]
p50 = {}
for key in rows[0]:
    values = [row[key] for row in rows]
    p50[key] = sorted(values)[1] if isinstance(values[0], (int, float)) else values[0]
print(f"| `{sys.argv[1]}` | 3 | `{json.dumps(p50, sort_keys=True, separators=(chr(44), chr(58)))}` |")
' "$label"
    }

    run_app_case "--self-test" --self-test
    run_app_case "--self-test-open $open_file" --self-test-open "$open_file"
    run_app_case "--self-test-project $repo_path" --self-test-project "$repo_path"
    exit 0
fi

binary="$bin_path/codeinsight"

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
