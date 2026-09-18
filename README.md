# CodeInsight / Cairn

<p align="center">
  <a href="https://github.com/sonald/cairn/actions/workflows/product-quality.yml">
    <img src="https://github.com/sonald/cairn/actions/workflows/product-quality.yml/badge.svg" alt="Mixed-language product gate" />
  </a>
  <a href="./LICENSE">
    <img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License" />
  </a>
</p>

<p align="center">
  English · <a href="README.zh-CN.md">简体中文</a>
</p>

CodeInsight is a native, read-only code reader for macOS, released as **Cairn**. It is designed for understanding unfamiliar code: open a project to build a symbol index, move between reading, search, and call relationships, and switch virtually across Git snapshots.

This is not an editor. Cairn does not save files, run builds, or modify your working tree; it makes evidence and uncertainty in the reading workflow explicit.

## Features

- **Native read-only Reader**: file tree, outline, Context Window, relations panel, folding, and navigation history built with AppKit/Swift.
- **Multilingual indexing**: syntax extraction, symbol indexing, and the reading surface currently support Rust, Python, TypeScript, and TSX.
- **Symbol and content search**: fuzzy symbol lookup, literal/regex content search, definition candidates, callers, outgoing calls, implementations, and overrides.
- **Exact analysis**: optional rust-analyzer, Pyright, and typescript-language-server integration, with provider and environment attribution on results.
- **Safe Reading Mode**: network access is denied by default, project build scripts and proc macros are disabled, and these limitations are surfaced as part of results.
- **Git time travel**: inspect worktree or commit snapshots and compare versions without checkout or repository mutation.
- **Index consistency**: index-derived jumps verify the target's content identity before navigating; when a file changed since indexing, Cairn shows `File changed since indexing` and offers Refresh Index, which recaptures the working tree without losing tabs, Reading Sets, bookmarks, the trail, or your layout.
- **Import preselection**: the Choose Languages dialog preselects a stored Recents preference or the languages a bounded filename probe actually finds (plain `.js`/`.jsx` never selects TypeScript); manual choice always wins.
- **CLI toolkit**: index projects, query semantics, inspect snapshots, measure cache-switch reuse, and evaluate gold sets.

## Non-source previews

Cairn's file tree shows regular non-symlink files outside skipped directories. Source indexing and Exact analysis still recognize only the existing Rust, Python, TypeScript, and TSX language modes.

- Markdown (`.md`, `.markdown`) is rendered as read-only attributed text.
- HTML (`.html`, `.htm`) is rendered in a read-only WebKit view with JavaScript, network access, and local subresources closed.
- Decodable images and PDFs are shown read-only; other strict UTF-8 files use a selectable plain-text preview.
- Markdown and HTML project-local links can open files in the project; Back and Forward work across those previews, and commit tabs read the selected snapshot bytes.
- Unknown or invalid binary content is reported as unsupported instead of being rendered as garbled text.

Non-source previews do not provide outline, folding, relations, bookmarks, compare/diff, Reading Height, or search controls. External links and inline local resources are not opened.

## Reading controls

- `⌘P` opens a file by name or project-relative path. Prefix the query with `>` for commands, `@` for file symbols, `#` for project symbols, or `:` for a line.
- A single click opens an italic preview tab. Double-click a file, choose **Open in New Tab**, or use a tab's **Keep Open** menu to retain it. Further browsing reuses the preview and preserves retained tabs; restored session tabs are retained.
- Close a comparison with its **×** button or **View → Close Comparison** (`⌃⌘W`) to clear the comparison and return to the saved reading layout.
- Files and Outline have separate collapse controls. Drag their separator or the Relations boundary to adjust space; the app remembers the layout. Outline can expand to members and shows type/signature details.
- The status bar's **Context** button shows or hides the definition preview. An empty preview stays out of the way until requested. The information button explains the current analysis status.
- Settings puts theme, font size, line height, wrapping and line numbers first, with a live code preview. **Advanced typography** keeps the other controls available. **Restore Reader Defaults** applies the current defaults without affecting project data.

## Explainable Reading Workflow

1. Open a project and choose the languages present in it.
2. In Relations, select a published result to navigate semantically; use `⌘I` to open the Resolution Inspector and review source and verification evidence.
3. Use `⌥⌘T` to open Trail Details or Branches, inspect the current route, and restore an earlier node without discarding sibling branches.
4. Use **Freeze Results** in Relations or **Freeze Path as Reading Set** in the Trail. The resulting Reading Set keeps frozen source and evidence and can be restored after restarting Cairn.

Each project keeps its own reading session: tabs (with their preview state and recency order), the current file and position, the Reading Trail with its branches, and Back/Forward state all return when the project reopens after quitting, closing the window, or switching projects. Restored trail evidence is labeled as frozen in an earlier session; re-query a relation for current evidence. **File → Clear Reading Session…** discards a project's saved scene after an explicit confirmation. A Reading Set is a frozen evidence set, not an editable curation list. Folding applies only to a file Reader: `⌥⌘0/1/2` selects Full, Structure, or Overview, and `⌥⌘F` focuses the current scope. Product UI labels are currently English; Cairn does not yet provide full localization.

## Multiple Projects and Windows

- One process reads several projects side by side: `⌘N` opens a blank window, and each project owns its window, tabs, navigation history, index, and Exact session. Reopening an already-open project (menu, Recents, or `open -a Cairn <dir>`) activates its existing window — including through symlinked or `.`/`..`-decorated paths — instead of building a duplicate.
- Opening a project reuses a still-blank window when one is at hand, then falls back to a new window. `⌘W` closes the active tab, and closes the window once no tabs remain; `⌘⇧W` closes the window. Titles read `project — Cairn` and the system Window menu lists every window.
- Trust, bookmarks, and the materialized-snapshot cache are shared application state: bookmark edits from one window appear in the other, revoking trust stops the affected project's analysis, and clearing the cache from Settings stops all Exact work first. Closing a single window only releases its own resources.

## Bookmarks and Notes

- In a primary project file, press `⌘⇧M` to toggle a bookmark; press `⌘⌥B` to open Bookmarks.
- Bookmarks are exact snapshot anchors: matching captured content is **Exact content**; changed worktree content is **Drifted** and requires an explicit **Re-anchor**; missing revisions/files or invalid offsets remain honest statuses and never silently jump.
- Up to 32 records are persisted in `bookmarks.json`; each plain-text note is capped at 2 KiB and written atomically.
- Bookmarks are unavailable in dependency files, Compare, Reading Sets, empty states, and mini readers. Cross-commit symbol mapping is not implemented; commit bookmarks remain tied to their saved snapshot and full object ID.

## Repository Layout

| Path | Purpose |
| --- | --- |
| `Sources/CodeInsightApp` | macOS application entry point for Cairn |
| `Sources/CodeInsightCLI` | `codeinsight` command-line tool |
| `Sources/CodeInsightEngine` | project indexing, relation resolution, and queries |
| `Sources/CodeInsightExact` | rust-analyzer / Pyright / TypeScript language server integration |
| `Sources/CodeInsightReader*` | Reader data models and AppKit rendering layers |
| `docs/plans` | staged implementation plans and acceptance records |

## Build and Run

Requires macOS 14+, a Swift 6 toolchain, and Homebrew `libgit2`:

```bash
brew install libgit2
CAIRN_LIBGIT2=brew bash scripts/make-app.sh
open .build/distribution/Cairn.app
```

To build a distributable Cairn.app, use static network-disabled vendored libgit2:

```bash
bash scripts/vendor-libgit2.sh
bash scripts/make-app.sh
open .build/distribution/Cairn.app
```

`scripts/make-app.sh` defaults to ad-hoc signing and does not notarize or staple. Developer ID signing and notarization require an explicit identity or Apple credentials; they have not been executed for this repository.

## CLI Examples

Build the command-line entry point:

```bash
swift build --product codeinsight
.build/debug/codeinsight --help
```

Common queries:

```bash
# Index a Rust project and print statistics.
.build/debug/codeinsight index /path/to/rust-project --stats

# Search symbols fuzzily.
.build/debug/codeinsight symsearch spawn \
  --project /path/to/project \
  --limit 20

# Resolve a source position. The column is a UTF-8 byte column.
.build/debug/codeinsight resolve Sources/Foo/Bar.rs:120:9 \
  --project /path/to/project
```

The full subcommand set includes `parse`, `index`, `dump`, `defs`, `callers`, `calls`, `impls`, `overrides`, `resolve`, `search`, `symsearch`, `snapshot`, `switch-stats`, `goldset`, and `exact-def`.

## Exact Providers

| Language | Reader/indexing | Exact provider |
| --- | --- | --- |
| Rust | Built-in tree-sitter extractor | rust-analyzer |
| Python | Built-in tree-sitter extractor | Pyright |
| TypeScript / TSX | Built-in tree-sitter extractor | typescript-language-server |
| JavaScript / JSX | Deferred / unsupported | — |

Providers are installed locally; Cairn does not install project dependencies for you. Missing offline dependencies and Safe Mode limitations are displayed as result states rather than silently treated as exact and complete.

## Testing and Quality Gates

Run Swift tests:

```bash
swift test
```

Run local CI, including self-tests and release fold-performance gates:

```bash
CODEX_SANDBOX=1 bash scripts/ci.sh
```

The mixed-language product gate requires three clean Git corpora:

```bash
bash scripts/run-product-gates.sh \
  /path/to/python-repo \
  /path/to/typescript-repo \
  /path/to/mixed-language-repo
```

GitHub Actions installs pinned tools, clones frozen corpora, and runs the same gates automatically.
The product gate also runs an isolated bookmark/restart check and validates non-empty Light, Dark, and SI Classic captures.

## Documentation

- [Requirements and design](docs/design.md)
- [Benchmarks](docs/benchmarks.md)
- [Gold set baseline](docs/goldset-baseline.md)
- [Implementation plans and acceptance records](docs/plans/)

## License

First-party source code is released under the [MIT License](./LICENSE). Vendored tree-sitter runtime and language grammars retain their upstream licenses; see each directory's `LICENSE` and `VENDORED.md`.
