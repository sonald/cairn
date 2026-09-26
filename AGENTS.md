# Repository Guidelines

## Project Structure & Module Organization

Cairn (package name CodeInsight) is a native, read-only macOS code reader built with Swift Package Manager.

- `Sources/CodeInsightApp` and `CodeInsightCLI` contain application and CLI entry points.
- `CodeInsightCore`, `CodeInsightGit`, `CodeInsightEngine`, and `CodeInsightExact` provide domain types, snapshots, indexing, and language-server integration. Language extractors and `TreeSitterKit` handle syntax.
- `CodeInsightAppModel`, `CodeInsightReaderCore`, and `CodeInsightReaderUI` separate application state, reader logic, and rendering.
- `Tests/` mirrors modules; `fixtures/` and `goldset/` hold acceptance inputs.
- `Resources/` contains the app icon; module `Resources/` directories contain localizations. `site/` holds the website, `docs/plans/` contains plans and acceptance records, and `scripts/` contains build and quality tools.

## Build, Test, and Development Commands

Requires macOS 14+, Swift 6, and Homebrew `libgit2` (`brew install libgit2`). Run commands from the repository root:

- `swift build` — build package targets.
- `swift run codeinsight --help` — inspect CLI commands.
- `CAIRN_LIBGIT2=brew bash scripts/make-app.sh` — package a local development app.
- `open .build/distribution/Cairn.app` — launch the packaged app.
- `swift test --filter tabStripFocusesDuplicatesAndPreservesAnchors` — run a focused test.
- `CODEX_SANDBOX=1 bash scripts/ci.sh` — run localization checks, isolated test batches, architecture checks, app self-tests, and fold-performance gates.

## Coding Style & Naming Conventions

Match existing Swift style: four-space indentation, `UpperCamelCase` types, and `lowerCamelCase` members. Name files after their principal type or responsibility. No SwiftLint or SwiftFormat configuration is checked in.

Keep AppKit/SwiftUI imports in UI targets; CI forbids them in core and model targets. Reuse existing helpers and native APIs; add types or abstractions only for a concrete need. Do not manually edit generated `Sources/CLibGit2Vendored` files.

## Testing Guidelines

Use Swift Testing (`@Test`, `#expect`) in `*Tests.swift`, with descriptive behavior-based function names. Add meaningful regression checks for changed logic; avoid tests that merely duplicate trivial edits. Update CI's expected batch counts when adding tests. Require completed test summaries; an exit code alone is insufficient. Verify UI changes in the native app and record blocked or skipped checks explicitly.

## Commit & Pull Request Guidelines

Follow history: `fix: ...`, `feat: ...`, `docs: ...`, or scoped subjects such as `fix(reader): preserve selection`. Keep commits focused. PRs should describe behavior changes, link relevant issues or plans, list validation, and include screenshots or native acceptance evidence for UI changes.
