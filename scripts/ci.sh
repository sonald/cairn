#!/usr/bin/env bash

set -euo pipefail

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
swift_test_log=.build/ci-swift-test.log
isolated_test_log=.build/ci-swift-test-isolated.log
panel_test_log=.build/ci-swift-test-panels.log
swift_test_summary_regex='^✔ Test run with [1-9][0-9]* tests?( in [0-9]+ suites)? passed after '
bookmark_test_one='CodeInsightAppTests.bookmarkPanelClearsInvalidFilteredAndDeletedSelectionsBeforeEditingANote'
bookmark_test_two='CodeInsightAppTests.bookmarkPanelSelfTestActionsTargetRowsByUUIDAndExposeTheirStatus'
panel_test_one='CodeInsightAppTests.productPolishRestoresUserPanelWidthsAcrossWindowRebuild'
panel_test_two='CodeInsightAppTests.productPolishOutlineUsesNativeHierarchyAndPreservesCollapsedBranches'
# AppKit window-state isolation: the bookmark pair and the panel-rebuild pair
# each finish in their own SwiftPM process. Mixing the rebuild pair with a later
# async inspector test can exit 0 before the Swift Testing summary. Never accept
# that exit code alone. All 949 tests must report completion exactly once.
expected_main_test_count=945
expected_isolated_test_count=2
expected_panel_test_count=2

run_swift_test_batch() {
    local log_file="$1" expected="$2" summary actual
    shift 2
    if ! swift test --no-parallel ${swift_options[@]+"${swift_options[@]}"} "$@" \
            2>&1 | tee "$log_file" >/dev/null; then
        cat "$log_file" >&2
        echo "FAIL: swift test command failed: $log_file" >&2
        exit 1
    fi
    if grep -qE '^✘ Test run' "$log_file"; then
        cat "$log_file" >&2
        echo "FAIL: swift test reported a failed run: $log_file" >&2
        exit 1
    fi
    summary="$(grep -E "$swift_test_summary_regex" "$log_file" || true)"
    if [[ -z "$summary" ]]; then
        cat "$log_file" >&2
        echo "FAIL: swift test did not report a complete successful run: $log_file" >&2
        exit 1
    fi
    # Older toolchains print one aggregate summary line; newer ones print
    # one per test target. Summing the passing summary lines matches both
    # shapes without ever counting a failed or partial run.
    actual="$(sed -n -E 's/^✔ Test run with ([0-9]+) tests?.*/\1/p' <<< "$summary" \
        | awk '{s+=$1} END {print s}')"
    if [[ "$actual" != "$expected" ]]; then
        cat "$log_file" >&2
        echo "FAIL: swift test expected $expected tests got $actual: $log_file" >&2
        exit 1
    fi
    echo "PASS: batch total=$actual ($log_file)"
}

run_swift_test_batch "$swift_test_log" "$expected_main_test_count" \
    --skip "$bookmark_test_one" --skip "$bookmark_test_two" \
    --skip "$panel_test_one" --skip "$panel_test_two"
run_swift_test_batch "$isolated_test_log" "$expected_isolated_test_count" \
    --filter "$bookmark_test_one|$bookmark_test_two"
run_swift_test_batch "$panel_test_log" "$expected_panel_test_count" \
    --filter "$panel_test_one|$panel_test_two"
total_swift_test_count=$((expected_main_test_count + expected_isolated_test_count + expected_panel_test_count))
echo "PASS: swift test total=$total_swift_test_count (main=$expected_main_test_count isolated=$expected_isolated_test_count panels=$expected_panel_test_count)"

if reader_map_hits=$(rg -n 'ByteUTF16Map|byteUTF16Map' \
    Sources/CodeInsightReaderUI/ \
    --glob '!Sources/CodeInsightReaderUI/DisplayMap.swift' 2>&1); then
    echo "$reader_map_hits"
    echo "FAIL: 发现禁用 ByteUTF16Map 引用" >&2
    exit 1
else
    reader_map_rc=$?
    if [[ $reader_map_rc -eq 1 ]]; then
        echo "PASS: ReaderUI ByteUTF16Map 引用仅限 DisplayMap.swift"
    else
        echo "FAIL: rg 基础设施错误 rc=$reader_map_rc" >&2
        exit 1
    fi
fi

if grep -rnE 'import AppKit|import SwiftUI' \
    Sources/CodeInsightCore Sources/TreeSitterKit \
    Sources/CodeInsightAppModel Sources/CodeInsightReaderCore \
    Sources/CodeInsightRustExtractor Sources/CodeInsightEngine \
    Sources/CodeInsightPythonExtractor Sources/CodeInsightTypeScriptExtractor \
    Sources/CodeInsightGit Sources/CodeInsightExact; then
    echo "AppKit/SwiftUI imports are not allowed in core targets." >&2
    exit 1
fi

swiftui_unstable_identity_regex='(ForEach|List)\([[:space:]]*0[[:space:]]*\.\.<|(ForEach|List)\([^)]*\.enumerated\(\)|\.indices,[[:space:]]*id:'
swiftui_unstable_identity_samples=(
    'List(0..<items.count, id: \.self)'
    'ForEach( 0 ..< items.count, id: \.self)'
    'ForEach(Array(items.enumerated()), id: \.offset)'
    'List(items.enumerated(), id: \.offset)'
    'List(items.indices, id: \.self)'
)
for sample in "${swiftui_unstable_identity_samples[@]}"; do
    if ! grep -Eq "$swiftui_unstable_identity_regex" <<<"$sample"; then
        echo "禁令 regex 覆盖不全: $sample" >&2
        exit 1
    fi
done

if grep -rnE "$swiftui_unstable_identity_regex" Sources; then
    echo "SwiftUI ForEach/List must not use unstable index/range/enumerated identity; it can crash after mutation." >&2
    exit 1
fi

.build/debug/codeinsight-app --self-test-exact .
.build/debug/codeinsight-app --self-test-diff .
reading_cache="$(mktemp -d "${TMPDIR:-/private/tmp}/codeinsight-ci-reading-cache.XXXXXX")"
trap 'rm -rf "$reading_cache"' EXIT
CODEINSIGHT_INDEX_CACHE_ROOT="$reading_cache" \
    .build/debug/codeinsight-app --self-test-reading
rm -rf "$reading_cache"
trap - EXIT
.build/debug/codeinsight-app --self-test-projector
.build/debug/codeinsight-app --self-test-fold

bash scripts/provision-corpora.sh \
    --verify-fold-fixture fixtures/fold_perf.rs \
    --manifest fixtures/fold_perf.manifest.json
swift build -c release ${swift_options[@]+"${swift_options[@]}"} \
    --product codeinsight-app
bash scripts/run-fold-perf.sh \
    --app-bin .build/release/codeinsight-app \
    --fixture fixtures/fold_perf.rs \
    --manifest fixtures/fold_perf.manifest.json
