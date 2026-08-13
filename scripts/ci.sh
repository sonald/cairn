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
swift test ${swift_options[@]+"${swift_options[@]}"} 2>&1 | tee "$swift_test_log"
if ! grep -Eq '^✔ Test run with [1-9][0-9]* tests? .* passed after ' "$swift_test_log"; then
    echo "FAIL: swift test 未报告完整成功的测试运行" >&2
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
.build/debug/codeinsight-app --self-test-reading
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
