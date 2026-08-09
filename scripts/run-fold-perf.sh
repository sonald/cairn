#!/usr/bin/env bash
set -euo pipefail

app_bin=""
fixture=""
manifest=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app-bin) app_bin="$2"; shift 2 ;;
        --fixture) fixture="$2"; shift 2 ;;
        --manifest) manifest="$2"; shift 2 ;;
        --help|-h)
            echo "usage: $0 --app-bin BIN --fixture RS --manifest JSON"
            exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

if [[ -z "$app_bin" || -z "$fixture" || -z "$manifest" ]]; then
    echo "usage: $0 --app-bin BIN --fixture RS --manifest JSON" >&2
    exit 2
fi
if [[ ! -x "$app_bin" || ! -f "$fixture" || ! -f "$manifest" ]]; then
    echo "fold perf input missing or app is not executable" >&2
    exit 2
fi

actual_sha="$(shasum -a 256 "$fixture" | awk '{print $1}')"
actual_bytes="$(wc -c < "$fixture" | tr -d ' ')"
actual_newlines="$(wc -l < "$fixture" | tr -d ' ')"
jq -e \
    --arg sha "$actual_sha" \
    --argjson bytes "$actual_bytes" \
    --argjson newlines "$actual_newlines" \
    '
    .schemaVersion == 1 and
    .seed == "m11-fold-perf-v1" and
    .fixtureSHA256 == $sha and
    .byteCount == $bytes and
    .newlineCount == $newlines and
    .newlineCount == 50000 and
    .lineCount == 50001 and
    .candidateCount == 8400 and
    .acceptedFoldCount == 8400 and
    .kindCounts == {
        "cfgTest": 0, "container": 200, "declaration": 4000,
        "block": 4000, "comment": 0, "imports": 200, "attributes": 0
    } and
    .depthCounts == {"0": 200, "1": 4200, "2": 4000} and
    .presets.structure == {"logical": 4200, "rendered": 4200} and
    .presets.overview == {"logical": 4400, "rendered": 200} and
    .perfPreset == "Overview"
    ' "$manifest" >/dev/null
[[ "$actual_bytes" -ge 2097152 ]]

result_dir="${FOLD_PERF_RESULT_DIR:-.build/m11-fold-perf}"
mkdir -p "$result_dir"
control_json="$result_dir/control.json"
fold_json="$result_dir/fold.json"
result_json="$result_dir/result.json"
rm -f "$control_json" "$fold_json" "$result_json"

control_status=0
"$app_bin" \
    --fold-perf-mode control \
    --fold-perf-fixture "$fixture" \
    --fold-perf-out "$control_json" || control_status=$?
fold_status=0
"$app_bin" \
    --fold-perf-mode fold \
    --fold-perf-fixture "$fixture" \
    --fold-perf-out "$fold_json" || fold_status=$?

if [[ ! -s "$control_json" || ! -s "$fold_json" ]]; then
    jq -n \
        --argjson controlExit "$control_status" \
        --argjson foldExit "$fold_status" \
        '{schemaVersion:1,status:"fail",error:"app output missing",controlExit:$controlExit,foldExit:$foldExit}' \
        | tee "$result_json"
    exit 1
fi

common_filter='
    .schemaVersion == 1 and
    .status == "ok" and
    .fixtureSHA256 == $sha and
    .samplePeriodMs == 25 and
    .observed.candidateCount == 8400 and
    .observed.acceptedFoldCount == 8400 and
    .resolutionMs >= 0 and .resolutionMs <= 500 and
    .peakPhysBytes > 0 and
    .perfConfig.wrapLines == false and
    .perfConfig.resolvedFontName != "" and
    .perfConfig.resolvedFontSizePt == 13 and
    .perfConfig.windowPt == [1440,900] and
    .perfConfig.viewportPt == [1200,760] and
    .perfConfig.lineNumbers == true and
    .perfConfig.theme == "SI Classic"
'

valid=true
jq -e --arg sha "$actual_sha" "$common_filter and
    .mode == \"control\" and
    .observed.logicalFoldCount == 0 and
    .observed.renderedFoldCount == 0" "$control_json" >/dev/null || valid=false
jq -e --arg sha "$actual_sha" "$common_filter and
    .mode == \"fold\" and
    .observed.logicalFoldCount == 4400 and
    .observed.renderedFoldCount == 200 and
    .foldLatencyMs >= 0 and .foldLatencyMs <= 400" "$fold_json" >/dev/null || valid=false

same_config="$(jq -n \
    --slurpfile control "$control_json" \
    --slurpfile fold "$fold_json" \
    '$control[0].perfConfig.resolvedFontName == $fold[0].perfConfig.resolvedFontName and
     $control[0].perfConfig.resolvedFontSizePt == $fold[0].perfConfig.resolvedFontSizePt and
     $control[0].perfConfig.windowPt == $fold[0].perfConfig.windowPt and
     $control[0].perfConfig.viewportPt == $fold[0].perfConfig.viewportPt')"
[[ "$same_config" == "true" ]] || valid=false
[[ "$control_status" -eq 0 && "$fold_status" -eq 0 ]] || valid=false

delta_bytes="$(jq -n \
    --slurpfile control "$control_json" \
    --slurpfile fold "$fold_json" \
    '[$fold[0].peakPhysBytes - $control[0].peakPhysBytes, 0] | max')"
[[ "$delta_bytes" -le 83886080 ]] || valid=false

status="fail"
exit_code=1
if [[ "$valid" == "true" ]]; then
    status="pass"
    exit_code=0
fi

result_tmp="$(mktemp "$result_dir/.result.XXXXXX")"
jq -n \
    --slurpfile control "$control_json" \
    --slurpfile fold "$fold_json" \
    --arg status "$status" \
    --argjson delta "$delta_bytes" \
    '{
        schemaVersion: 1,
        control: {
            resolutionMs: $control[0].resolutionMs,
            observed: $control[0].observed,
            peakPhysBytes: $control[0].peakPhysBytes
        },
        fold: {
            resolutionMs: $fold[0].resolutionMs,
            observed: $fold[0].observed,
            peakPhysBytes: $fold[0].peakPhysBytes,
            foldLatencyMs: $fold[0].foldLatencyMs
        },
        deltaBytes: $delta,
        status: $status
    }' > "$result_tmp"
mv "$result_tmp" "$result_json"
cat "$result_json"
echo "fold perf artifacts: $result_dir" >&2
exit "$exit_code"
