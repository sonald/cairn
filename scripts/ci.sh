#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
    cat <<'EOF'
usage: bash scripts/ci.sh <static|core|reader|engine|exact|app|full> [...]
  static  localization and architecture checks only
  core    domain types, Git snapshots, parser transport
  reader  reader algorithms and native reader integration
  engine  extractors, indexing, cache, search and navigation
  exact   language-server protocol and process boundaries
  app     application model, persistence and native app integration
  full    all above plus app self-tests and fold performance gate
No default full run. Choose the domains affected by your change.
EOF
}
if [[ $# -eq 0 ]]; then usage; exit 2; fi
run_static=false
run_full=false
filters=()
for domain in "$@"; do
    case "$domain" in
        -h|--help) usage; exit 0 ;;
        static) run_static=true ;;
        core) filters+=('CodeInsightCoreTests\.|CodeInsightGitTests\.|TreeSitterKitTests\.') ;;
        reader) filters+=('CodeInsightReaderCoreTests\.|CodeInsightReaderUITests\.') ;;
        engine) filters+=('CodeInsightEngineTests\.|RustExtractorTests\.|PythonExtractorTests\.|TypeScriptExtractorTests\.') ;;
        exact) filters+=('CodeInsightExactTests\.') ;;
        app) filters+=('CodeInsightAppModelTests\.|CodeInsightAppTests\.') ;;
        full) run_static=true; run_full=true; filters+=('.*') ;;
        *) echo "Unknown domain: $domain" >&2; usage >&2; exit 2 ;;
    esac
done

if "$run_static"; then
for script in scripts/*.sh; do bash -n "$script"; done
python3 scripts/check-localizations.py
# Interactive readers must consume prepared data, never the synchronous compatibility builder.
if identifier_scan_hits=$(rg -n 'identifierOccurrences\(' Sources/CodeInsightReaderUI Sources/CodeInsightApp); then
    echo "$identifier_scan_hits"
    echo "FAIL: Reader interaction calls the synchronous identifier builder" >&2
    exit 1
elif [[ $? -ne 1 ]]; then
    echo "FAIL: identifier boundary search failed" >&2
    exit 1
fi

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

# Self-test entry points live in Sources/CodeInsightApp/SelfTest/, not beside AppDelegate.
if self_test_hits=$(rg -n 'func run[A-Za-z]*SelfTest' \
    Sources/CodeInsightApp/CodeInsightApp.swift 2>&1); then
    echo "$self_test_hits"
    echo "FAIL: CodeInsightApp.swift 不得定义 run*SelfTest，自测放在 SelfTest/" >&2
    exit 1
else
    self_test_rc=$?
    if [[ $self_test_rc -eq 1 ]]; then
        echo "PASS: CodeInsightApp.swift 不含 run*SelfTest"
    else
        echo "FAIL: rg 基础设施错误 rc=$self_test_rc" >&2
        exit 1
    fi
fi

# K0a: key equivalents come from the key binding table (KeyBindings.swift).
# Outside the AppKit adapter, no literal key equivalent or direct
# keyEquivalentModifierMask write may appear; chords are applied through the
# adapter (KeyBindings+AppKit.swift).
keybinding_gate_regex='keyEquivalent:[[:space:]]*"[^"]+"|keyEquivalentModifierMask[[:space:]]*=[[:space:]]*[^=]|\.keyEquivalent[[:space:]]*=[[:space:]]*"'
keybinding_gate_samples=(
    'NSMenuItem(title: "X", action: nil, keyEquivalent: "p")'
    'menuItem.keyEquivalentModifierMask = .command'
    'openButton.keyEquivalent = "\r"'
)
for sample in "${keybinding_gate_samples[@]}"; do
    if ! grep -Eq "$keybinding_gate_regex" <<<"$sample"; then
        echo "快捷键门禁 regex 覆盖不全: $sample" >&2
        exit 1
    fi
done
if keybinding_hits=$(rg -n "$keybinding_gate_regex" \
    Sources/CodeInsightApp \
    --glob '!Sources/CodeInsightApp/KeyBindings+AppKit.swift' 2>&1); then
    echo "$keybinding_hits"
    echo "FAIL: 快捷键必须来自 KeyBindings.swift 定义表（适配文件除外）" >&2
    exit 1
else
    keybinding_rc=$?
    if [[ $keybinding_rc -eq 1 ]]; then
        echo "PASS: App 层快捷键全部来自定义表"
    else
        echo "FAIL: rg 基础设施错误 rc=$keybinding_rc" >&2
        exit 1
    fi
fi

# Model keys live in CodeInsightAppModel's bundle (see the script).
python3 scripts/check-model-key-usage.py

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

fi

if [[ ${#filters[@]} -eq 0 ]]; then exit 0; fi
bash scripts/check-toolchain.sh
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$PWD/.build/clang-module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$PWD/.build/swift-module-cache}"
swift_options=()
if [[ -n "${CODEX_SANDBOX:-}" ]]; then
    swift_options=(--disable-sandbox --cache-path .build/cache --config-path .build/config
        --security-path .build/security --manifest-cache local)
fi
mkdir -p .build
# Discovery builds the current tests. Never count source annotations or keep a
# frozen total: deleted tests and parameterized tests are toolchain concerns.
swift test ${swift_options[@]+"${swift_options[@]}"} list > .build/ci-test-list.txt
filter="^($(IFS='|'; echo "${filters[*]}"))"
# Shared window/font state and process-wide work counters require a fresh process.
# AppKit state previously caused exit 0 without completing all targets.
isolated=(
    'CodeInsightEngineTests\.readonlyCallOwnershipRepeatedQueriesHaveNoRegionScanOrRebuild'
    'CodeInsightAppTests\.bookmarkPanelClearsInvalidFilteredAndDeletedSelectionsBeforeEditingANote'
    'CodeInsightAppTests\.bookmarkPanelSelfTestActionsTargetRowsByUUIDAndExposeTheirStatus'
    'CodeInsightAppTests\.productPolishRestoresUserPanelWidthsAcrossWindowRebuild'
    'CodeInsightAppTests\.productPolishOutlineUsesNativeHierarchyAndPreservesCollapsedBranches'
    'CodeInsightReaderUITests\.nativeMouseDragKeepsOperatorSelectionInsteadOfActivatingClick'
    'CodeInsightReaderUITests\.nativeBlankClicksKeepTheReadingPositionAndFoldState'
    'readonlyFontProcessReplacementChangesRealFontWithoutChangingReaderSource'
    'readonlyFontDistributedNotificationRoutesToAppDelegateWithoutInstallingFonts'
)
isolated_filter="$(IFS='|'; echo "${isolated[*]}")"
if ! grep -E "$filter" .build/ci-test-list.txt > .build/ci-selected-tests.txt; then
    echo "FAIL: selected domains discovered no tests" >&2; exit 1
fi
expected_total=$(wc -l < .build/ci-selected-tests.txt | tr -d ' ')
completed_total=0
run_swift_test_batch() {
    local name="$1" expected="$2" summary actual log_file=".build/ci-swift-test-$1.log"
    shift 2
    if [[ "$expected" -eq 0 ]]; then
        echo "FAIL: empty test batch: $name" >&2; return 1
    fi
    if ! swift test --skip-build --no-parallel ${swift_options[@]+"${swift_options[@]}"} "$@" \
            2>&1 | tee "$log_file" >/dev/null; then
        cat "$log_file" >&2
        echo "FAIL: swift test command failed: $log_file" >&2; return 1
    fi
    if grep -qE '^✘ Test run' "$log_file"; then
        cat "$log_file" >&2; return 1
    fi
    summary="$(grep -E '^✔ Test run with [1-9][0-9]* tests?( in [0-9]+ suites?)? passed after ' "$log_file" || true)"
    actual="$(sed -n -E 's/^✔ Test run with ([0-9]+) tests?.*/\1/p' <<< "$summary" | awk '{s+=$1} END {print s+0}')"
    if [[ "$actual" != "$expected" ]]; then
        cat "$log_file" >&2
        echo "FAIL: discovered $expected tests but only $actual completed: $log_file" >&2; return 1
    fi
    completed_total=$((completed_total + actual))
    echo "PASS: $name $actual tests ($log_file)"
}
main_count=$(grep -Ev "$isolated_filter" .build/ci-selected-tests.txt | wc -l | tr -d ' ')
run_swift_test_batch selected "$main_count" --filter "$filter" --skip "$isolated_filter"
index=0
for isolated_test in "${isolated[@]}"; do
    count=$(grep -Ec "$isolated_test" .build/ci-selected-tests.txt || true)
    if [[ "$count" -gt 0 ]]; then
        run_swift_test_batch "isolated-$index" "$count" --filter "$isolated_test"
    fi
    index=$((index + 1))
done
if [[ "$completed_total" != "$expected_total" ]]; then
    echo "FAIL: discovered $expected_total tests, completed $completed_total" >&2; exit 1
fi
echo "PASS: selected domains total=$completed_total"

if ! "$run_full"; then exit 0; fi
swift build ${swift_options[@]+"${swift_options[@]}"}
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
