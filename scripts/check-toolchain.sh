#!/usr/bin/env bash
set -euo pipefail

# Shared local/CI baseline. Update together with the workflow Xcode selection.
expected_xcode=$'Xcode 27.0\nBuild version 27A266a'
expected_swift='swift-driver version: 1.168.6 Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)'
expected_sdk='27.0'

xcode_version="$(xcodebuild -version)"
swift_version="$(swift --version 2>&1)"
xcode_swift_version="$(xcrun swift --version 2>&1)"
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
sw_vers
uname -m
printf 'Developer directory: %s\n' "${DEVELOPER_DIR:-$(xcode-select -p)}"
printf '%s\n%s\nmacOS SDK: %s\n' "$xcode_version" "$swift_version" "$sdk_version"

if [[ "$xcode_version" != "$expected_xcode" ||
      "${swift_version%%$'\n'*}" != "$expected_swift" ||
      "$swift_version" != "$xcode_swift_version" ||
      "$sdk_version" != "$expected_sdk" ]]; then
    echo 'FAIL: Cairn requires Xcode 27.0 (27A266a), bundled Swift 6.4, macOS SDK 27.0.' >&2
    echo 'Select that Xcode with DEVELOPER_DIR; remove PATH/TOOLCHAINS overrides for other Swift installations.' >&2
    echo 'See docs/development.md. Do not substitute a runner default or latest Xcode.' >&2
    exit 1
fi
echo 'PASS: local/CI toolchain baseline matches'
