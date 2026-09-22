# Reader ligatures environment

Date: 2026-09-22. Deployment target: macOS 14. Baseline CI: Debug tests plus Release fold performance.

Baseline CI started before product source edits. `baseline-ci.log` / `baseline-tests.log`: sandbox run failed with 4 issues in 3 AppKit tests (no NSScreen / attachedSheet). The same compiled tests all passed outside the sandbox: `baseline-desktop-recheck.log` (3 tests, one with 2 cases). No product code had changed when these test binaries were built. Full candidate CI must run with native desktop access; this baseline attempt does not establish a full CI pass.

`git rev-parse HEAD`

```text
5a9800be5ac8523bb16ca0ae03da7dd9bb3d4092
```

`sw_vers`

```text
ProductName:		macOS
ProductVersion:		27.0
BuildVersion:		26A428
```

`system_profiler SPHardwareDataType`

```text
Model Name: MacBook Pro
      Model Identifier: Mac15,6
      Chip: Apple M3 Pro
      Total Number of Cores: 11 (5 Performance and 6 Efficiency)
      Memory: 36 GB
```

`xcodebuild -version`

```text
Xcode 27.0
Build version 27A266a
```

`swift --version`

```text
Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)
Target: arm64-apple-macosx27.0.0
swift-driver version: 1.168.6
```

`git diff d1f68eee3300df8525ce914b2fb37760c82c65a3 HEAD --stat -- Sources/CodeInsightReaderUI Sources/CodeInsightReaderCore/ReaderSettings.swift Sources/CodeInsightApp/ReadingSetView.swift scripts/ci.sh`

```text
Sources/CodeInsightApp/ReadingSetView.swift        |  45 +--
 .../CodeInsightReaderUI/CodeInsightReaderUI.swift  |  48 +--
 Sources/CodeInsightReaderUI/Localization.swift     |  15 +
 .../Resources/en.lproj/Localizable.strings         |  13 +
 .../Resources/en.lproj/Localizable.stringsdict     | 342 +++++++++++++++++++++
 .../Resources/zh-Hans.lproj/Localizable.strings    |  13 +
 .../zh-Hans.lproj/Localizable.stringsdict          | 300 ++++++++++++++++++
 scripts/ci.sh                                      |   4 +-
 8 files changed, 733 insertions(+), 47 deletions(-)
```
