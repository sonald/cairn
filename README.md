# CodeInsight / Cairn

<p align="center">
  <a href="https://github.com/sonald/cairn/actions/workflows/product-quality.yml"><img src="https://github.com/sonald/cairn/actions/workflows/product-quality.yml/badge.svg" alt="Product quality checks" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License" /></a>
</p>

<p align="center">English · <a href="README.zh-CN.md">简体中文</a></p>

**Cairn** is a native, read-only macOS code reader for understanding unfamiliar projects. CodeInsight remains the Swift package and module name. Browse source, follow symbols and relations, and compare Git snapshots without editing files or checking out another commit.

- Rust, Python, and TypeScript/TSX syntax indexing, symbol search, and text search.
- A Context window that follows symbols or the enclosing function, previews binding types, and can be pinned.
- Optional rust-analyzer, Pyright, and typescript-language-server analysis, with explicit sources and limitations.
- Read-only Git snapshots, comparisons, branching reading trails, frozen Reading Sets, bookmarks, and per-project session restoration.
- Multiple project windows, configurable shortcuts, code fonts and ligatures, Light/Dark/SI Classic themes, and English/Simplified Chinese UI.
- Read-only Markdown, restricted HTML, image, PDF, and UTF-8 text previews.

Safe mode is the default: no network access, and Rust build scripts and proc macros are disabled. Explicitly trusting a project can enable those analysis steps and permit writes to its `target` directory; it does not enable network access. Providers and dependencies must already be available locally.

## Build and run

Requires macOS 14+, Swift 6, and Homebrew libgit2:

```bash
brew install libgit2
CAIRN_LIBGIT2=brew bash scripts/make-app.sh
open .build/distribution/Cairn.app
```

For a bundle with static, network-disabled vendored libgit2:

```bash
bash scripts/vendor-libgit2.sh
bash scripts/make-app.sh
```

Packaging defaults to ad-hoc signing. Developer ID signing, notarization, and stapling require separate configuration and verification. Generated files in `Sources/CLibGit2Vendored` must not be edited manually.

## Start reading

1. Open a project and select its languages. `⌘P` finds files; prefix with `>` for commands, `@` for file symbols, `#` for project symbols, or `:` for a line.
2. Click a symbol to update Context. For a binding, Context can show its type; `⌘`-click still opens the binding declaration, while `⇧⌘`-click or `⌃⌘J` opens its type. Clicking the receiver in `ps.get()` selects `ps`; clicking `get` selects the method.
3. Follow Relations and inspect the evidence behind a result. Freeze a result or trail as a Reading Set to preserve source and explanations.
4. Reopen the project to restore its reading session. A new project gets its own window; reopening an already-open project activates that window.

These are default shortcuts; Settings → Keybindings shows effective bindings. A single file click opens a reusable preview tab; double-click or Keep Open retains it. Fonts, ligatures, and folding change presentation, while copying preserves the original source.

Source indexing currently classifies `.rs`, `.py`, `.ts`, and `.tsx`; JavaScript/JSX and declaration-only or alternate extensions are not full source-analysis modes. Non-source previews do not offer relations, folding, bookmarks, comparison, or search controls. Exact results depend on provider capabilities and the local environment; “Verified” is not a claim of complete runtime knowledge.

## CLI

```bash
swift build --product codeinsight
.build/debug/codeinsight --help
.build/debug/codeinsight index /path/to/project --stats
.build/debug/codeinsight resolve src/main.rs:12:9 --project /path/to/project --type-hop
```

Positions use 1-based UTF-8 byte columns. Use each command's `--help` for supported options and languages.

## Development

Start with the [documentation index](docs/README.md):

- [Current product behavior and limitations](docs/product.md)
- [Architecture and source entry points](docs/architecture.md)
- [Build, debugging, and performance reproduction](docs/development.md)
- [Test selection and verification policy](docs/testing.md)

Choose checks for the affected behavior; full product and performance gates are for explicit broader validation. See [AGENTS.md](AGENTS.md) for repository rules. Historical milestone requirements have been consolidated into the current documents; Git retains their history.

## License

First-party source is [MIT](LICENSE). Vendored tree-sitter runtime and grammars retain their upstream licenses and provenance in their own `LICENSE` and `VENDORED.md` files.
