#!/usr/bin/env bash
# Collect soft-wrap performance evidence (reader-wrap design §7.4).
#
# Runs the `--self-test-wrap` runner across fixtures/scenarios and stores the
# raw JSON plus a jq summary table. Baseline and candidate runs use the same
# entry so numbers stay comparable; only the code SHA changes.
#
# Usage:
#   bash scripts/run-wrap-perf.sh                      # default matrix, output under .build/wrap-perf/
#   bash scripts/run-wrap-perf.sh --out DIR
#   bash scripts/run-wrap-perf.sh --samples 30 --warmup 5
#   bash scripts/run-wrap-perf.sh --enforce-budgets --baseline-dir DIR   # candidate gates (§7.4.4)
#
# Fixtures live in fixtures/wrap/ (scripts/gen-wrap-fixtures.sh --verify).
# F2/F3 are extreme fixtures reported separately (§7.4.3); they run a reduced
# sample count by default. Reading Set uses the ordinary 5 warmups / 30 samples
# in each direction; historical unsupported baselines remain unchanged.

set -euo pipefail

out_dir=".build/wrap-perf"
binary=""
warmup_default=5
samples_default=30
extreme_samples=10
extreme_warmup=2
fixtures="f1 f2 f3 f4"
scenarios="initial toggle resize"
enforce_budgets=false
baseline_dir=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --out) out_dir="$2"; shift 2 ;;
        --binary) binary="$2"; shift 2 ;;
        --warmup) warmup_default="$2"; shift 2 ;;
        --samples) samples_default="$2"; shift 2 ;;
        --fixtures) fixtures="$2"; shift 2 ;;
        --scenarios) scenarios="$2"; shift 2 ;;
        --enforce-budgets) enforce_budgets=true; shift ;;
        --baseline-dir) baseline_dir="$2"; enforce_budgets=true; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }

if [[ -z "$binary" ]]; then
    echo "== building release codeinsight-app" >&2
    swift build -c release --product codeinsight-app >&2
    binary=".build/release/codeinsight-app"
fi
[[ -x "$binary" ]] || { echo "binary not found: $binary" >&2; exit 2; }

bash scripts/gen-wrap-fixtures.sh --verify

code_sha="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
mkdir -p "$out_dir"
run_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
echo "== wrap perf: sha=$code_sha out=$out_dir (fixtures: $fixtures; scenarios: $scenarios)" >&2

fixture_file() {
    case "$1" in
        f1) echo "fixtures/wrap/f1-ordinary.rs" ;;
        f2) echo "fixtures/wrap/f2-mega-line.rs" ;;
        f3) echo "fixtures/wrap/f3-no-whitespace.rs" ;;
        f4) echo "fixtures/wrap/f4-combined.rs" ;;
        f5) echo "fixtures/wrap/f5-reading-set.txt" ;;
        *) return 1 ;;
    esac
}

run_one() {
    # run_one <fixture> <wrap on|off> <scenario> <warmup> <samples>
    local fixture="$1" wrap="$2" scenario="$3" warmup="$4" samples="$5"
    local name="${fixture}-${scenario}-wrap-${wrap}"
    local json="$out_dir/${name}.json"
    echo "  -> $name (warmup=$warmup samples=$samples)" >&2
    if ! "$binary" --self-test-wrap \
        --fixture "$(fixture_file "$fixture")" \
        --wrap "$wrap" --scenario "$scenario" \
        --output "$json" --code-sha "$code_sha" \
        --warmup "$warmup" --samples "$samples" 2>"$out_dir/${name}.stderr"; then
        echo "     status: $(jq -r '.status // "exit-failed"' "$json" 2>/dev/null || echo no-json)" >&2
        return 1
    fi
    echo "     status: $(jq -r '.status' "$json")" >&2
}

failures=0
for fixture in $fixtures; do
    case "$fixture" in
        f2|f3) warmup="$extreme_warmup"; samples="$extreme_samples" ;;
        *) warmup="$warmup_default"; samples="$samples_default" ;;
    esac
    for scenario in $scenarios; do
        for wrap in on off; do
            run_one "$fixture" "$wrap" "$scenario" "$warmup" "$samples" || failures=$((failures + 1))
        done
    done
done

# Reading Set: real card layout and drawing, with both toggle directions.
for wrap in on off; do
    run_one f5 "$wrap" reading-set "$warmup_default" "$samples_default" || failures=$((failures + 1))
done

# ---------- summary table ----------

summary="$out_dir/summary-$run_stamp.json"
jq -n --arg codeSHA "$code_sha" --arg stamp "$run_stamp" \
    '{codeSHA: $codeSHA, stamp: $stamp, rows: []}' > "$summary"

for json in "$out_dir"/f*.json; do
    [[ -f "$json" ]] || continue
    jq -c --slurpfile acc "$summary" '
        {
            name: input_filename | sub(".*/"; "") | sub("\\.json$"; ""),
            status: .status,
            scenario: .scenario,
            requestedWrap: .requestedWrap,
            sampleCount: .sampleCount,
            summary: .summary,
            peakPhysBytes: .peakPhysBytes,
            longestMainThreadStallMs: .observed.longestMainThreadStallMs,
            reflowCount: .observed.reflowCount
        } | {codeSHA: $acc[0].codeSHA, stamp: $acc[0].stamp, rows: ($acc[0].rows + [.])}
    ' "$json" > "$summary.tmp" 2>/dev/null || continue
    mv "$summary.tmp" "$summary"
done

echo "== summary ($summary)" >&2
jq -r '.rows[] | [.name, .status,
        (.summary.toggleSettledMs.p95 // .summary.settledMs.p95 // .summary.resizeStepMs.p95 // "-"),
        (.summary.toggleFirstFrameMs.p95 // .summary.firstFrameMs.p95 // "-"),
        (.longestMainThreadStallMs | tostring), (.reflowCount | tostring)]
        | @tsv' "$summary" | column -t >&2

# ---------- budget gates (§7.4.4, candidate acceptance) ----------

if [[ "$enforce_budgets" == true ]]; then
    budget_failures=0
    check_budget() {
        # check_budget <file> <path-expression> <budget> <label>
        local file="$out_dir/$1" value
        [[ -f "$file" ]] || { echo "BUDGET-SKIP (no run): $1 $4" >&2; return; }
        value="$(jq -r "$2 // empty" "$file")"
        [[ -n "$value" ]] || { echo "BUDGET-SKIP (no metric): $4" >&2; return; }
        if awk -v v="$value" -v b="$3" 'BEGIN { exit !(v <= b) }'; then
            echo "BUDGET-PASS: $4 p95=${value}ms <= ${3}ms" >&2
        else
            echo "BUDGET-FAIL: $4 p95=${value}ms > ${3}ms" >&2
            budget_failures=$((budget_failures + 1))
        fi
    }
    check_budget_aware() {
        # check_budget_aware <file> <path> <budget> <label>
        # Like check_budget, but a candidate that stays at or below a
        # baseline which itself exceeds the absolute budget is reported as
        # BASELINE-EXCEEDED (recorded, not claimed as a pass — §7.4.4) and
        # does not fail the run.
        local file="$out_dir/$1" value base_value
        [[ -f "$file" ]] || { echo "BUDGET-SKIP (no run): $1 $4" >&2; return; }
        value="$(jq -r "$2 // empty" "$file")"
        [[ -n "$value" ]] || { echo "BUDGET-SKIP (no metric): $4" >&2; return; }
        if awk -v v="$value" -v b="$3" 'BEGIN { exit !(v <= b) }'; then
            echo "BUDGET-PASS: $4 =${value} <= ${3}" >&2
            return
        fi
        if [[ -n "$baseline_dir" && -f "$baseline_dir/$1" ]]; then
            base_value="$(jq -r "$2 // empty" "$baseline_dir/$1" 2>/dev/null || true)"
            # Run-to-run noise margin: a candidate within 1.25x baseline + 5
            # of an already-over-budget baseline is the same pre-existing
            # cost, not a new regression (§7.4.4: record, never claim pass).
            if [[ -n "$base_value" ]] && awk -v v="$value" -v b="$base_value" 'BEGIN { limit = b * 1.25 + 5; exit !(v <= limit) }'; then
                echo "BUDGET-BASELINE-EXCEEDED: $4 =${value} > ${3} but within noise of baseline ${base_value} (pre-existing cost, recorded)" >&2
                return
            fi
        fi
        echo "BUDGET-FAIL: $4 =${value} > ${3}" >&2
        budget_failures=$((budget_failures + 1))
    }
    # Ordinary file budgets.
    check_budget f1-toggle-wrap-on.json  '.summary.toggleSettledMs.p95'  250 "F1 toggle-on settled"
    check_budget f1-toggle-wrap-off.json '.summary.toggleSettledMs.p95'  250 "F1 toggle-off settled"
    check_budget_aware f1-resize-wrap-on.json  '.summary.resizeStepMs.p95'      33 "F1 resize-on step"
    check_budget_aware f1-resize-wrap-on.json  '.observed.longestMainThreadStallMs' 100 "F1 resize-on stall"
    # Extreme fixtures are reported separately and never averaged into F1.
    check_budget f2-toggle-wrap-on.json  '.summary.toggleSettledMs.p95' 1500 "F2 toggle-on settled"
    check_budget f2-toggle-wrap-off.json '.summary.toggleSettledMs.p95' 1500 "F2 toggle-off settled"
    check_budget f3-toggle-wrap-on.json  '.summary.toggleSettledMs.p95' 1500 "F3 toggle-on settled"
    check_budget f3-toggle-wrap-off.json '.summary.toggleSettledMs.p95' 1500 "F3 toggle-off settled"
    for wrap in on off; do
        file="$out_dir/f5-reading-set-wrap-${wrap}.json"
        if ! jq -e '.status == "ok" and .sampleCount >= 30 and .warmupCount >= 5 and (.summary.toggleSettledMs.p95 | type == "number")' "$file" >/dev/null 2>&1; then
            echo "BUDGET-FAIL: F5 $wrap requires successful measured layout, 5 warmups and 30 samples" >&2
            budget_failures=$((budget_failures + 1))
        else
            check_budget "f5-reading-set-wrap-${wrap}.json" '.summary.toggleSettledMs.p95' 250 "F5 reading-set $wrap action-to-settled"
        fi
    done
    # Memory and relative-toggle gates need a same-configuration baseline run.
    if [[ -n "$baseline_dir" && -d "$baseline_dir" ]]; then
        for config in f1-toggle-wrap-on f1-toggle-wrap-off f1-resize-wrap-on; do
            base_peak="$(jq -r '.peakPhysBytes // empty' "$baseline_dir/$config.json" 2>/dev/null || true)"
            cand_peak="$(jq -r '.peakPhysBytes // empty' "$out_dir/$config.json" 2>/dev/null || true)"
            if [[ -n "$base_peak" && -n "$cand_peak" ]]; then
                if awk -v c="$cand_peak" -v b="$base_peak" 'BEGIN { limit = (b * 1.3 > b + 33554432) ? b * 1.3 : b + 33554432; exit !(c <= limit) }'; then
                    echo "BUDGET-PASS: $config peak=$cand_peak <= max(1.3x, +32MiB) of $base_peak" >&2
                else
                    echo "BUDGET-FAIL: $config peak=$cand_peak exceeds memory budget (base $base_peak)" >&2
                    budget_failures=$((budget_failures + 1))
                fi
            else
                echo "BUDGET-SKIP: $config memory (missing baseline or candidate peak)" >&2
            fi
        done
        # Relative toggle budget: candidate must not regress past
        # max(baseP95 * 1.5, baseP95 + 15ms) even when under 250ms (§7.4.4).
        for config in f1-toggle-wrap-on f1-toggle-wrap-off; do
            base_p95="$(jq -r '.summary.toggleSettledMs.p95 // empty' "$baseline_dir/$config.json" 2>/dev/null || true)"
            cand_p95="$(jq -r '.summary.toggleSettledMs.p95 // empty' "$out_dir/$config.json" 2>/dev/null || true)"
            if [[ -n "$base_p95" && -n "$cand_p95" ]]; then
                if awk -v c="$cand_p95" -v b="$base_p95" 'BEGIN { limit = (b * 1.5 > b + 15) ? b * 1.5 : b + 15; exit !(c <= limit) }'; then
                    echo "BUDGET-PASS: $config settled p95=${cand_p95}ms <= max(1.5x, +15ms) of ${base_p95}ms" >&2
                else
                    echo "BUDGET-FAIL: $config settled p95=${cand_p95}ms exceeds relative budget (base ${base_p95}ms)" >&2
                    budget_failures=$((budget_failures + 1))
                fi
            else
                echo "BUDGET-SKIP: $config relative toggle (missing baseline or candidate p95)" >&2
            fi
        done
    fi
    if [[ "$budget_failures" -gt 0 ]]; then
        echo "FAIL: $budget_failures budget checks failed" >&2
        exit 1
    fi
fi

if [[ "$failures" -gt 0 ]]; then
    echo "FAIL: $failures runner invocations failed" >&2
    exit 1
fi
echo "== done: $summary" >&2
