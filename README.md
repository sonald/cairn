# CodeInsight / Cairn

<p align="center">
  <a href="https://github.com/sonald/cairn/actions/workflows/product-quality.yml"><img src="https://github.com/sonald/cairn/actions/workflows/product-quality.yml/badge.svg" alt="Product quality checks" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License" /></a>
</p>

<p align="center">English · <a href="README.zh-CN.md">简体中文</a> · <a href="https://cairn.sonald.me/">Cairn website</a></p>

**Cairn** is a native, read-only macOS code reader for understanding unfamiliar projects. CodeInsight remains the Swift package and module name. Browse source, follow symbols and relations, and compare Git snapshots without editing files or changing your working tree or repository.

- Rust, Python, TypeScript/TSX, and Go syntax indexing, symbol search, and composable project queries.
- A Context window that follows symbols or the enclosing function, previews binding types, and can be pinned.
- Optional rust-analyzer, Pyright, typescript-language-server, and gopls analysis, with explicit sources and limitations.
- Read-only Git snapshots, comparisons, branching reading trails, frozen Reading Sets, bookmarks, and per-project session restoration.
- An AI panel that answers questions about the open snapshot with a model you configure (OpenAI-compatible or Anthropic API, or your ChatGPT plan through Sign in with ChatGPT). The model reads code only through Cairn's read-only tools (file reading, search, symbol lookup backed by the language server where available, and Git history), and the steps it took fold into one line above the answer, from which the code it read opens in the reader. Select code and click the gutter icon, or press `⌘I`, to ask about that code.
- A Guide panel that follows the open file: the model reads the file through the same tools and writes how it is put together — its flows (with step-by-step playback), the role of each part, a sequence diagram and follow-up questions. Every piece of code it cites is checked against the file's real lines and opens in the reader. Guides are saved locally by file content and marked out of date when the file changes.
- Read a directory on another machine over ssh (File → Open Remote Folder…, `host:/absolute/path`) without cloning it: authentication is left to the system `ssh`, no copy of the remote files is kept on this Mac, and Cairn writes nothing on the remote host. File tree, reading, search, outline, project symbols, syntax-level Context, AI questions and guides work there; Exact analysis and Git history do not.
- Multiple project windows, configurable shortcuts, code fonts and ligatures, Light/Dark/SI Classic themes plus bundled and user-supplied base16 themes, and English/Simplified Chinese UI.
- Read-only Markdown, Jupyter notebook, restricted HTML, image, PDF, and UTF-8 text previews. Markdown preserves embedded HTML headings, paragraphs, and tables, with images scaled to fit and alt text for remote images. Configuration, scripts, and unanalyzed languages such as C/C++, Java, and JS are syntax-colored.

Exact analysis of a past commit runs in a checkout directory Cairn owns (one per window, deleted when the window closes) and borrows the workspace's `node_modules` and virtual environment; language servers follow commit switches without restarting when nothing but the commit and configuration content changed.

Safe mode is the default: no network access, and Rust build scripts and proc macros are disabled. Explicitly trusting a project can enable those analysis steps and permit writes to its `target` directory; it does not enable network access. Providers and dependencies must already be available locally. When dependencies are missing, clicking the Exact status shows the install command for the unit; for a Rust project with a `Cargo.lock`, Download Dependencies runs `cargo fetch --locked`, and for a Go module with a `go.sum` and no `vendor/` it runs `go mod download` against a copy of the manifests outside the repository — apart from AI questions, the Overview scoring below and remote folders you open over ssh, the only network access Cairn makes, and only on that click. TypeScript and Python installs run package scripts, so Cairn copies the command and opens Terminal instead of running them.

AI questions go to the address set in Settings → AI, with the API key kept in the Keychain; with the ChatGPT plan they go to api.openai.com, and the sign-in tokens are kept in the Keychain. Before the first question in a project, Cairn asks whether that project's code, commit messages and past changes may be sent there (author names and email trailers are not sent) (a model on localhost is not asked about). Answers load no remote images or other resources. With a Jev key saved in Settings → AI, opening a Rust, Python or TypeScript file's Overview sends that file's code (comments, docstrings and blank lines removed) to TypeSafe's Jev service (api.typesafe.ai), which chooses the functions and statements the skeleton keeps; only the scores are stored locally. Without a key, Overview uses local rules only and does not go online.

## Build and run

The app supports macOS 14+. Builds use Xcode 27.1 (27A9275), its bundled Swift 6.4, Homebrew libgit2, and a Rust toolchain (rustup) for the AI helper. Local checks and CI verify this same toolchain; see [development setup](docs/development.md).

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

1. Open a project; Cairn detects its Rust, Python, TypeScript, and Go sources (a project with none, such as a pure C repository, opens browse-only: file tree and colored previews, no analysis). `⌘P` finds files; prefix with `>` for commands, `@` for file symbols, `#` for project symbols, or `:` for a line. Click a name in the file outline to jump to it, including Python module-level constants and variables. `⌃⌘S` lists every declaration in the project by kind or module without typing a name.
2. Click a symbol to update Context. For a binding, Context can show its type; `⌘`-click still opens the binding declaration, while `⇧⌘`-click or `⌃⌘J` opens its type. When the index has no declaration, stops at the import of the clicked name, or does not know the identifier at all, `⌘`-click opens the language server's definition, including dependency files, once Exact analysis is ready. Clicking the receiver in `ps.get()` selects `ps`; clicking `get` selects the method.
3. Follow Relations and inspect the evidence behind a result. Freeze a result or trail as a Reading Set to preserve source and explanations.
4. Reopen the project to restore its reading session. A new project gets its own window; reopening an already-open project activates that window.

These are default shortcuts; Settings → Keybindings shows effective bindings. A single file click opens a reusable preview tab; double-click or Keep Open retains it. Fonts, ligatures, and folding change presentation, while copying preserves the original source. Overview shows a Rust, Python or TypeScript file as a skeleton in source order (functions on its main line with their key statements, the others as signatures) numbered with the source lines it came from; copying there gives the skeleton text.

Source indexing currently classifies `.rs`, `.py`, `.ts`, `.tsx`, and `.go`; JavaScript/JSX and declaration-only or alternate extensions are not full source-analysis modes; dependency `.d.ts` and `.pyi` files open read-only with highlighting as jump targets but are never indexed. Syntax-colored previews fold by syntax, section, or indentation, and Markdown previews fold by heading; HTML and plain-text documents do not fold. Non-source previews do not offer relations, bookmarks, comparison, or search controls. Exact results depend on provider capabilities and the local environment; “Verified” is not a claim of complete runtime knowledge.

Use `⇧⌘F` for the project search panel: `lock await same:fn`, `lock OR mutex`, `-path:tests/`, and `in:code` combine text, paths, and syntax regions. Query history restores with the project; `⌥⌘G` / `⇧⌥⌘G` browse results. See [query behavior and current validation limits](docs/product.md#搜索选项).

## CLI

```bash
swift build --product codeinsight
.build/debug/codeinsight --help
.build/debug/codeinsight index /path/to/project --stats
.build/debug/codeinsight search 'lock await same:fn -path:tests/' --project /path/to/project --json
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

First-party source is [MIT](LICENSE). Vendored tree-sitter runtime and grammars retain their upstream licenses and provenance in their own `LICENSE` and `VENDORED.md` files. The bundled base16 themes keep their MIT license in `Sources/CodeInsightReaderCore/Themes/LICENSE`. The decode-only part of Zstandard 1.5.7, used to read remote folder captures, is used under its BSD license in `Sources/CZstd/LICENSE`, with provenance in `Sources/CZstd/VENDORED.md`. The app links libgit2 (GPL-2.0 with a linking exception): release bundles link it statically from `Vendor/libgit2`, where `scripts/vendor-libgit2.sh` places its `LICENSE`; `CAIRN_LIBGIT2=brew` bundles copy Homebrew's libgit2 and the libraries it links into `Contents/Frameworks`.
