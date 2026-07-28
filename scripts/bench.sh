#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 1 || $# -gt 3 ]]; then
    echo "usage: bash scripts/bench.sh <repo-path> [runs=5] | --app <corpus-dir> | --m2 <tokio-dir> [runs=5] | --m4 <rust-repo> [runs=5] | --m5 <tokio-dir> [runs=5] | --m6 [runs=5]" >&2
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
elif [[ "$1" == "--m2" ]]; then
    if [[ $# -lt 2 || $# -gt 3 || ! -d "$2" ]]; then
        echo "usage: bash scripts/bench.sh --m2 <tokio-dir> [runs=5]" >&2
        exit 2
    fi
    mode="m2"
    repo_path="$(cd "$2" && pwd -P)"
    runs="${3:-5}"
elif [[ "$1" == "--m4" ]]; then
    if [[ $# -lt 2 || $# -gt 3 || ! -d "$2" ]]; then
        echo "usage: bash scripts/bench.sh --m4 <rust-repo> [runs=5]" >&2
        exit 2
    fi
    mode="m4"
    repo_path="$(cd "$2" && pwd -P)"
    runs="${3:-5}"
elif [[ "$1" == "--m5" ]]; then
    if [[ $# -lt 2 || $# -gt 3 || ! -d "$2" ]]; then
        echo "usage: bash scripts/bench.sh --m5 <tokio-dir> [runs=5]" >&2
        exit 2
    fi
    mode="m5"
    repo_path="$(cd "$2" && pwd -P)"
    runs="${3:-5}"
elif [[ "$1" == "--m6" ]]; then
    if [[ $# -gt 2 ]]; then
        echo "usage: bash scripts/bench.sh --m6 [runs=5]" >&2
        exit 2
    fi
    mode="m6"
    runs="${2:-5}"
else
    if [[ $# -gt 2 ]]; then
        echo "usage: bash scripts/bench.sh <repo-path> [runs=5]" >&2
        exit 2
    fi
    repo_path="$1"
    runs="${2:-5}"
    if [[ ! -d "$repo_path" ]]; then
        echo "not a directory: $repo_path" >&2
        exit 2
    fi
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
    switch_repo="$repo_path"
    if ! git -C "$switch_repo" rev-parse --verify 'HEAD~1^{commit}' >/dev/null 2>&1; then
        switch_repo="$PWD"
    fi
    run_app_case "--self-test-switch $switch_repo" \
        --self-test-switch "$switch_repo"
    exit 0
fi

if [[ "$mode" == "m2" ]]; then
    calls_file="tokio/src/runtime/task/harness.rs"
    calls_line="$(awk '/pub\(super\) fn poll\(self\)/ { print NR; exit }' "$repo_path/$calls_file")"
    if [[ -z "$calls_line" ]]; then
        echo "tokio poll function not found: $calls_file" >&2
        exit 2
    fi

    benchmark_command() {
        label="$1"
        shift
        python3 - "$label" "$runs" "$@" <<'PY'
import math, subprocess, sys, time
label, runs, *command = sys.argv[1:]
values = []
for _ in range(int(runs)):
    started = time.perf_counter()
    subprocess.run(command, stdout=subprocess.DEVNULL, check=True)
    values.append((time.perf_counter() - started) * 1000)
values.sort()
rank = lambda percentile: values[math.ceil(len(values) * percentile) - 1]
print(f"| `{label}` | {runs} | {values[0]:.1f}ms | {rank(0.5):.1f}ms | {rank(0.95):.1f}ms |")
PY
    }

    echo '| CLI 场景（含索引） | runs | min | p50 | p95 |'
    echo '|---|---:|---:|---:|---:|'
    benchmark_command "callers poll" \
        "$bin_path/codeinsight" callers poll --project "$repo_path" --json
    benchmark_command "calls $calls_file:$calls_line" \
        "$bin_path/codeinsight" calls --project "$repo_path" \
        --file "$calls_file" --line "$calls_line" --json
    benchmark_command "search block_on" \
        "$bin_path/codeinsight" search block_on --project "$repo_path" --json
    exit 0
fi

if [[ "$mode" == "m4" ]]; then
    binary="$bin_path/codeinsight-app"
    # Cross-commit diff needs a Git repo whose worktree differs from HEAD~1.
    # A Rust corpus unpacked from a tarball has no Git history, so the diff
    # section runs against this repository (same fallback as --app --switch).
    diff_repo="$repo_path"
    if ! git -C "$diff_repo" rev-parse --verify 'HEAD~1^{commit}' >/dev/null 2>&1; then
        diff_repo="$PWD"
    fi

    cache_root="$(mktemp -d "${TMPDIR:-/tmp}/codeinsight-m4-cache.XXXXXX")"
    trap 'rm -rf "$cache_root"' EXIT

    percentile_row() {
        # label unit   (numeric values on stdin, one per line) -> markdown row.
        # Uses python -c so the piped values stay on stdin (a heredoc would
        # redirect stdin to the script source and swallow the values).
        python3 -c 'import math, sys
label, unit = sys.argv[1], sys.argv[2]
vals = sorted(float(x) for x in sys.stdin if x.strip())
if not vals:
    print(f"| `{label}` | 0 | — | — | — |")
    raise SystemExit
rank = lambda p: vals[math.ceil(len(vals) * p) - 1]
print(f"| `{label}` | {len(vals)} | {vals[0]:.3f}{unit} | {rank(0.5):.3f}{unit} | {rank(0.95):.3f}{unit} |")
' "$1" "$2"
    }

    json_field() {
        python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1"
    }

    # --- persistence: cold (empty cache) vs hot (warm cache), isolated root ---
    cold_ready=(); hot_ready=(); cold_extracted="?"; hot_reused="?"
    run=1
    while [[ $run -le $runs ]]; do
        rm -rf "$cache_root"; mkdir -p "$cache_root"
        cold_json="$(CODEINSIGHT_INDEX_CACHE_ROOT="$cache_root" \
            "$binary" --self-test-project "$repo_path")"
        hot_json="$(CODEINSIGHT_INDEX_CACHE_ROOT="$cache_root" \
            "$binary" --self-test-project "$repo_path")"
        cold_ready[${#cold_ready[@]}]="$(printf '%s' "$cold_json" | json_field indexReadyMS)"
        hot_ready[${#hot_ready[@]}]="$(printf '%s' "$hot_json" | json_field indexReadyMS)"
        cold_extracted="$(printf '%s' "$cold_json" | json_field extracted)"
        hot_reused="$(printf '%s' "$hot_json" | json_field reused)"
        run=$((run + 1))
    done

    # --- exact fake path: fuzzy first answer + fuzzy->exact upgrade latency ---
    # The exact self-test drives the built-in Tests/.../exact_fixture, so its
    # root must be this repository (like ci.sh), not the indexing corpus.
    exact_root="$PWD"
    fuzzy_ms=(); upgrade_ms=(); real_provider="not-run"
    run=1
    while [[ $run -le $runs ]]; do
        exact_json="$("$binary" --self-test-exact "$exact_root" 2>/dev/null || true)"
        fuzzy_ms[${#fuzzy_ms[@]}]="$(printf '%s' "$exact_json" \
            | python3 -c 'import json,sys
for line in sys.stdin:
    o=json.loads(line)
    if o.get("step")=="fuzzy" and o.get("variant")=="fake":
        print(o.get("fuzzyFirstAnswerMS","")); break')"
        upgrade_ms[${#upgrade_ms[@]}]="$(printf '%s' "$exact_json" \
            | python3 -c 'import json,sys
for line in sys.stdin:
    o=json.loads(line)
    if o.get("step")=="exact" and o.get("variant")=="fake":
        print(o.get("exactUpgradeMS","")); break')"
        real_provider="$(printf '%s' "$exact_json" \
            | python3 -c 'import json,sys
v="not-run"
for line in sys.stdin:
    o=json.loads(line)
    if o.get("step")=="summary": v=o.get("realProvider",v)
print(v)')"
        run=$((run + 1))
    done

    # --- cross-commit diff compute cost (DiffCore, best-of-5 per run) ---
    diff_ms=(); diff_lines="?"
    run=1
    while [[ $run -le $runs ]]; do
        diff_json="$("$binary" --self-test-diff "$diff_repo" 2>/dev/null || true)"
        diff_ms[${#diff_ms[@]}]="$(printf '%s' "$diff_json" \
            | python3 -c 'import json,sys
for line in sys.stdin:
    o=json.loads(line)
    if o.get("step")=="gutter":
        print(o.get("diffComputeMS","")); break')"
        diff_lines="$(printf '%s' "$diff_json" \
            | python3 -c 'import json,sys
for line in sys.stdin:
    o=json.loads(line)
    if o.get("step")=="gutter":
        print(str(o.get("leftLineCount"))+"->"+str(o.get("rightLineCount"))); break')"
        run=$((run + 1))
    done

    repo_name="$(basename "$repo_path")"
    diff_name="$(basename "$diff_repo")"
    echo "### 持久化冷/热（\`--self-test-project $repo_name\`，隔离 cache root）"
    echo
    echo '| 场景 | runs | min | p50 | p95 |'
    echo '|---|---:|---:|---:|---:|'
    printf '%s\n' "${cold_ready[@]}" \
        | percentile_row "indexReadyMS cold (extracted=$cold_extracted, reused=0)" "ms"
    printf '%s\n' "${hot_ready[@]}" \
        | percentile_row "indexReadyMS hot (extracted=0, reused=$hot_reused)" "ms"
    echo
    echo "### Exact 原位升级（\`--self-test-exact\` 内置 exact_fixture，fake provider；真实 RA=$real_provider）"
    echo
    echo '| 场景 | runs | min | p50 | p95 |'
    echo '|---|---:|---:|---:|---:|'
    printf '%s\n' "${fuzzy_ms[@]}" | percentile_row "fuzzy first answer" "ms"
    printf '%s\n' "${upgrade_ms[@]}" | percentile_row "fuzzy->exact upgrade (fake 250ms inject)" "ms"
    echo
    echo "### 跨 commit diff 计算（\`--self-test-diff $diff_name\`，DiffCore，行数 $diff_lines）"
    echo
    echo '| 场景 | runs | min | p50 | p95 |'
    echo '|---|---:|---:|---:|---:|'
    printf '%s\n' "${diff_ms[@]}" | percentile_row "DiffCore compute" "ms"
    exit 0
fi

if [[ "$mode" == "m5" ]]; then
    binary="$bin_path/codeinsight-app"
    cli="$bin_path/codeinsight"

    percentile_row() {
        python3 -c 'import math, sys
label, unit = sys.argv[1], sys.argv[2]
vals = sorted(float(x) for x in sys.stdin if x.strip())
if not vals:
    raise SystemExit(f"no values for {label}")
rank = lambda p: vals[math.ceil(len(vals) * p) - 1]
print(f"| `{label}` | {len(vals)} | {vals[0]:.3f}{unit} | {rank(0.5):.3f}{unit} | {rank(0.95):.3f}{unit} |")
' "$1" "$2"
    }

    json_line_field() {
        python3 -c 'import json, sys
step, key = sys.argv[1:3]
for line in sys.stdin:
    value = json.loads(line)
    if value.get("step") == step:
        print(value[key])
        raise SystemExit
raise SystemExit(f"missing {step}.{key}")
' "$1" "$2"
    }

    # AppKit channels are each launched once, independently. Repeating them in
    # a shell loop is a known intermittent hang shape; see m5-backlog.md.
    exact_json="$("$binary" --self-test-exact "$PWD")"
    context_ready_ms="$(printf '%s\n' "$exact_json" \
        | json_line_field feature-switch contextReadyMS)"
    context_relations_ready_ms="$(printf '%s\n' "$exact_json" \
        | json_line_field relations contextAndRelationsReadyMS)"
    reprofile_extracted="$(printf '%s\n' "$exact_json" \
        | json_line_field relations extracted)"

    reading_json="$("$binary" --self-test-reading)"
    huge_first_visible_ms="$(printf '%s\n' "$reading_json" \
        | json_line_field huge firstVisibleMS)"
    styled_fragments="$(printf '%s\n' "$reading_json" \
        | json_line_field huge styledFragments)"
    visible_lines="$(printf '%s\n' "$reading_json" \
        | json_line_field huge visibleLines)"

    receiver_values=()
    run=1
    while [[ $run -le $runs ]]; do
        output="$("$cli" index "$repo_path" --stats)"
        elapsed="$(printf '%s\n' "$output" \
            | awk -F': *' '$1 == "elapsedMilliseconds" { print $2; exit }')"
        case "$elapsed" in
            ''|*[!0-9]*) echo "could not parse elapsedMilliseconds" >&2; exit 1 ;;
        esac
        receiver_values[${#receiver_values[@]}]="$elapsed"
        run=$((run + 1))
    done
    receiver_p50="$(printf '%s\n' "${receiver_values[@]}" | python3 -c '
import math, sys
values = sorted(float(line) for line in sys.stdin if line.strip())
print(values[math.ceil(len(values) * 0.5) - 1])
')"
    # Historical M0 parallel-index p50, preserved in docs/benchmarks.md.
    receiver_baseline_ms=704
    receiver_delta_percent="$(python3 -c '
baseline, current = map(float, __import__("sys").argv[1:3])
print(f"{(current - baseline) / baseline * 100:+.1f}%")
' "$receiver_baseline_ms" "$receiver_p50")"

    search_test_output="$(swift test -c release \
        ${swift_options[@]+"${swift_options[@]}"} \
        --filter searchPanelCapsDisplayedMatchesAndReportsTrueTotal 2>&1)"
    search_json="$(printf '%s\n' "$search_test_output" \
        | sed -n 's/^.*M5_SEARCH_CAP //p' | sed -n '$p')"
    if [[ -z "$search_json" ]]; then
        echo "could not parse SearchPanel cap benchmark" >&2
        exit 1
    fi
    search_displayed="$(printf '%s' "$search_json" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["displayedMatches"])')"
    search_rows="$(printf '%s' "$search_json" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["displayedRows"])')"
    search_total="$(printf '%s' "$search_json" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["totalMatches"])')"

    echo '### Profile 切换（`--self-test-exact` fake provider，单次独立进程）'
    echo
    echo '| 场景 | runs | min | p50 | p95 |'
    echo '|---|---:|---:|---:|---:|'
    printf '%s\n' "$context_ready_ms" \
        | percentile_row "reprofile -> Context ready (extracted=$reprofile_extracted)" "ms"
    printf '%s\n' "$context_relations_ready_ms" \
        | percentile_row "reprofile -> Context + Relations ready (extracted=$reprofile_extracted)" "ms"
    echo
    echo '### receiver 解析开销（tokio 全量索引）'
    echo
    echo '| 场景 | runs | min | p50 | p95 |'
    echo '|---|---:|---:|---:|---:|'
    printf '%s\n' "${receiver_values[@]}" \
        | percentile_row "tokio index with targetHint" "ms"
    echo
    echo '| 既有并行索引 p50 基线 | 当前 p50 | 相对变化 |'
    echo '|---:|---:|---:|'
    printf '| %.1fms | %.1fms | %s |\n' \
        "$receiver_baseline_ms" "$receiver_p50" "$receiver_delta_percent"
    echo
    echo '### 10 万行行号 + 同名高亮（`--self-test-reading`，单次独立进程）'
    echo
    echo '| 场景 | runs | min | p50 | p95 |'
    echo '|---|---:|---:|---:|---:|'
    printf '%s\n' "$huge_first_visible_ms" \
        | percentile_row "first visible" "ms"
    printf '%s\n' "$styled_fragments" \
        | percentile_row "styledFragmentCount" ""
    printf '%s\n' "$visible_lines" \
        | percentile_row "visible lines" ""
    echo
    echo '### SearchPanel 5000+ 命中 cap'
    echo
    echo '| cap 前匹配行 | cap 后匹配行 | 含截断提示的显示行 | totalMatches |'
    echo '|---:|---:|---:|---:|'
    printf '| %s | %s | %s | %s |\n' \
        "$search_total" "$search_displayed" "$search_rows" "$search_total"
    exit 0
fi

if [[ "$mode" == "m6" ]]; then
    binary="$bin_path/codeinsight-app"

    percentile_row() {
        python3 -c 'import math, sys
label, unit = sys.argv[1], sys.argv[2]
vals = sorted(float(x) for x in sys.stdin if x.strip())
if not vals:
    raise SystemExit(f"no values for {label}")
rank = lambda p: vals[math.ceil(len(vals) * p) - 1]
print(f"| `{label}` | {len(vals)} | {vals[0]:.3f}{unit} | {rank(0.5):.3f}{unit} | {rank(0.95):.3f}{unit} |")
' "$1" "$2"
    }

    test_marker_values() {
        filter="$1"
        marker="$2"
        run=1
        while [[ $run -le $runs ]]; do
            output="$(swift test \
                ${swift_options[@]+"${swift_options[@]}"} \
                --filter "$filter" 2>&1)"
            printf '%s\n' "$output" | python3 -c '
import re, sys
marker = sys.argv[1]
lines = [line for line in sys.stdin if marker in line]
if not lines:
    raise SystemExit(f"missing benchmark marker: {marker}")
match = re.search(r"\belapsedMS=([-+0-9.]+)", lines[-1])
if not match:
    raise SystemExit(f"missing elapsedMS: {marker}")
print(match.group(1))
' "$marker"
            run=$((run + 1))
        done
    }

    echo '### implementations（fake provider 响应请求 + 解析）'
    echo
    echo '| 响应形态 | runs | min | p50 | p95 |'
    echo '|---|---:|---:|---:|---:|'
    test_marker_values \
        rustAnalyzerParsesSingleLocationImplementation \
        'M6_IMPLEMENTATIONS shape=Location elapsedMS=' \
        | percentile_row "Location" "ms"
    test_marker_values \
        rustAnalyzerParsesEveryLocationImplementation \
        'M6_IMPLEMENTATIONS shape=Location[] elapsedMS=' \
        | percentile_row "Location[]" "ms"
    test_marker_values \
        rustAnalyzerParsesEveryLocationLinkImplementation \
        'M6_IMPLEMENTATIONS shape=LocationLink[] elapsedMS=' \
        | percentile_row "LocationLink[]" "ms"
    test_marker_values \
        rustAnalyzerTreatsNullImplementationAsNoResult \
        'M6_IMPLEMENTATIONS shape=null elapsedMS=' \
        | percentile_row "null" "ms"
    echo

    echo '### callHierarchy（fake provider 响应请求 + 解析）'
    echo
    echo '| 步骤 | runs | min | p50 | p95 |'
    echo '|---|---:|---:|---:|---:|'
    test_marker_values \
        rustAnalyzerPreparesEveryItemAndUsesSourceURIForOutgoingCallSites \
        'M6_CALL_HIERARCHY step=prepare elapsedMS=' \
        | percentile_row "prepare" "ms"
    test_marker_values \
        rustAnalyzerParsesIncomingCallHierarchyRelation \
        'M6_CALL_HIERARCHY step=incoming elapsedMS=' \
        | percentile_row "incoming" "ms"
    test_marker_values \
        rustAnalyzerPreparesEveryItemAndUsesSourceURIForOutgoingCallSites \
        'M6_CALL_HIERARCHY step=outgoing elapsedMS=' \
        | percentile_row "outgoing" "ms"
    echo

    local_index_output="$(swift test \
        ${swift_options[@]+"${swift_options[@]}"} \
        --filter m6FixtureLocalReferenceIndexMetrics 2>&1)"
    local_index_line="$(printf '%s\n' "$local_index_output" \
        | sed -n 's/^.*\(M6_LOCAL_REFERENCE_INDEX .*$\)/\1/p' \
        | sed -n '$p')"
    if [[ -z "$local_index_line" ]]; then
        echo "could not parse M6 local reference index benchmark" >&2
        exit 1
    fi
    printf '%s\n' "$local_index_line" | python3 -c '
import re, sys
line = sys.stdin.read()
fields = dict(re.findall(r"(\w+)=([-+0-9.]+)", line))
required = ["parseMS", "buildMS", "baselineMB", "afterMB", "deltaMB",
            "bindings", "references", "tokens"]
missing = [key for key in required if key not in fields]
if missing:
    raise SystemExit("missing local index fields: " + ", ".join(missing))
delta = float(fields["deltaMB"])
print("### 局部引用索引（m6_reference_density.rust，单次独立进程）")
print()
print("| parse | index build | baseline footprint | after footprint | delta | bindings | references | indexed tokens |")
print("|---:|---:|---:|---:|---:|---:|---:|---:|")
print("| {parseMS}ms | {buildMS}ms | {baselineMB}MB | {afterMB}MB | {delta:+.3f}MB | {bindings} | {references} | {tokens} |".format(delta=delta, **fields))
'
    echo

    reading_json="$("$binary" --self-test-reading)"
    printf '%s\n' "$reading_json" | python3 -c '
import json, sys
summary = next(
    value for value in map(json.loads, sys.stdin)
    if value.get("step") == "summary"
)
metrics = summary["metrics"]
runs = int(metrics["referenceAttributeRunCount"])
fragments = int(metrics["referenceStyledFragmentCount"])
scanned = int(metrics["referenceScannedCount"])
print("### Reference Styles 写属性量（单次独立进程）")
print()
print("| referenceAttributeRunCount | referenceStyledFragmentCount | referenceScannedCount |")
print("|---:|---:|---:|")
print(f"| {runs} | {fragments} | {scanned} |")
'
    echo
    echo '> 只报客观耗时与计数；帧率、卡顿与阅读手感必须真机人工判定。'
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
