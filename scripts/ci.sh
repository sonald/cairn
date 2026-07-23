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
swift test ${swift_options[@]+"${swift_options[@]}"}

if grep -rnE 'import AppKit|import SwiftUI' \
    Sources/CodeInsightCore Sources/TreeSitterKit \
    Sources/CodeInsightAppModel Sources/CodeInsightReaderCore \
    Sources/CodeInsightRustExtractor Sources/CodeInsightEngine \
    Sources/CodeInsightGit Sources/CodeInsightExact; then
    echo "AppKit/SwiftUI imports are not allowed in core targets." >&2
    exit 1
fi

if grep -rnE '\.indices,[[:space:]]*id:' Sources; then
    echo "SwiftUI ForEach/List must not use collection.indices as identity; index identity can crash after mutation." >&2
    exit 1
fi

.build/debug/codeinsight-app --self-test-exact .
.build/debug/codeinsight-app --self-test-diff .
