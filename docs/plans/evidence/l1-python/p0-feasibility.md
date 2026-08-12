# L1 Python P0 feasibility evidence

> Date: 2026-08-11 (Asia/Shanghai)
> Repository baseline: `0add42056b8f8dfd618d82371b211072c2f90899`
> Result: **GO, with the frozen boundaries below**
> Scope: read-only architecture and tool feasibility; no production or test code was changed.

## 1. Decision

Python is feasible as the first complete single-language slice on the M12 architecture.
The gate is not merely “tree-sitter can parse Python”: the current host also proved that an
installed Pyright can provide the minimum Exact path while offline and with a read-only project.

The approved L1 boundary is:

- source files: lowercase `.py` only;
- excluded: `.pyi`, `.pyw`, notebooks, non-UTF-8 Python source, mixed-language projects;
- fuzzy/Reader: tree-sitter-python `v0.25.0`, vendored beside the existing Rust grammar;
- Exact provider: a locally installed official Pyright distribution; Cairn does not install,
  bundle, or update Node/Pyright;
- Exact capabilities: definition, references, incoming calls, and outgoing calls;
- Exact implementations: unsupported because Pyright `1.1.411` did not advertise
  `implementationProvider`; L1's provider-supported maximum remains the observed three capabilities,
  so a future server advertisement does not silently enable an unaccepted product path;
- no dependency install, venv creation, package-manager execution, or project-code execution is
  part of L1;
- App opening remains explicit. `Open Project…` keeps its Rust compatibility behavior and a new
  `Open Python Project…` path selects Python without root-marker guessing.

The result is not permission to open the App preflight now. Product support remains locked until
extractor, module resolution, Reader/Diff, Exact, App persistence, and the real-project gate all
pass.

## 2. Baseline and protected scope

The checkout was clean before and after the P0 probes:

```text
branch: main
HEAD: 0add42056b8f8dfd618d82371b211072c2f90899
relative to origin/main: ahead 2, behind 0
tracked worktree diff: empty
index: empty
untracked files: empty
```

Current protected identities:

| Scope | Git object at L1 baseline |
|---|---|
| `Sources/CodeInsightEngine/CanonicalDump.swift` | `20ddd6f08d326d7e15074a7fb684680e7a8477bf` |
| `Prototypes/` | `27ff155fede12ff663030e1dd0cf52e6f8458887` |
| `goldset/tokio.gold` | `debbe499edd3bf6c3c75a37c2e59aa6e8e0f3db4` |
| `goldset/ripgrep.gold` | `b67ce3150035f29ce4aa3162bd15de65c9a5d159` |
| `goldset/fixtures/` | `c3ecb4ec45e3c7ab2c6733b5fd72b16bbbf70c47` |
| `Tests/RustExtractorTests/Fixtures/` | `82f1d4251fb71da9ec20a904e6427c0c39451e6a` |
| `Tests/CodeInsightExactTests/Fixtures/` | `57d053cf1845fe174c1f894be74e1ac484a80cf8` |
| `docs/plans/evidence/m11/` | `4b1b7c00dddc18077c16d4b2cd555704f5f059e4` |
| `Sources/CTreeSitter/` | `14a506fa4b2a3712efb34cdbc42ccd4d10a8e033` |
| `Sources/CTreeSitterRust/` | `61f5fb9e9a0ffcdca398eae02b338592f7e45b94` |
| `Package.resolved` | `a24e48a32ea8f7c994a712f1265ba1b3104a374e` |

The parent `goldset/` tree at P0 was
`9353e29663e6a754bf7ddd71ba74a8230b15abfb`, but it is reference-only because adding the allowed
Python gold file must change that parent tree. L1 may add a Python grammar target, Python
extractor/tests/fixtures, and a new Python gold file. It must not rewrite the protected child
objects above or existing Rust gold content.

## 3. Existing architecture seam

The M12 result already supplies the identities and publication gates L1 needs:

```text
AppModel(root + language + generation)
  -> Snapshot / ProjectIndexer(language)
    -> AnalysisProfile(language)
      -> SnapshotView(active language + extractor)
        -> EngineSession(active-language view)
          -> Reader/Diff(LanguageMode)
          -> ExactCoordinator(language + profile + trust + tool)
```

No new top-level language container is required. The remaining Rust-only switches are concrete:

1. no C tree-sitter Python target or `PythonExtractor`;
2. `LanguageMode.classify` returns nil for Python;
3. worktree capture, profile detection, and `ProjectIndexer` reject Python;
4. `ModuleMap` preconditions Rust and `Resolver` filters Rust declaration kinds;
5. Reader/Folding/Diff construct Rust parsing paths;
6. Exact provider/profile construction and App product preflight reject Python.

This matches the M12 extension contract: add one complete branch at each existing boundary, not a
registry, adapter family, plugin system, or multi-session workspace.

## 4. Parser dependency gate

The repository already vendors tree-sitter runtime `v0.25.8`. Its C headers accept grammar ABI
versions 13 through 15. The official tree-sitter-python `v0.25.0` release uses ABI 15, so no runtime
upgrade is required.

Implementation must pin the release and record the downloaded asset SHA-256 before copying its
generated `parser.c`, `scanner.c`, `node-types.json`, headers, license, and provenance file. The
existing runtime and Rust grammar must remain byte-identical.

Official sources:

- [tree-sitter-python releases](https://github.com/tree-sitter/tree-sitter-python/releases)
- [tree-sitter-python repository](https://github.com/tree-sitter/tree-sitter-python)
- [v0.25.0 generated parser](https://github.com/tree-sitter/tree-sitter-python/blob/v0.25.0/src/parser.c)
- [v0.25.0 node types](https://github.com/tree-sitter/tree-sitter-python/blob/v0.25.0/src/node-types.json)
- [tree-sitter parser list](https://github.com/tree-sitter/tree-sitter/wiki/List-of-parsers)
- [tree-sitter runtime](https://github.com/tree-sitter/tree-sitter)

Result: **PASS**. One new C grammar target and one `PythonExtractor` are justified; no additional
SwiftPM package is needed.

## 5. Installed tool snapshot

The live host reported:

```text
/opt/homebrew/bin/pyright
/opt/homebrew/bin/pyright-langserver
/opt/homebrew/bin/python3
/opt/homebrew/bin/node

pyright 1.1.411
Python 3.14.6
Node v26.7.0
npm/npx 11.19.0
basedpyright: not installed
python: not installed
```

Pyright's official installation documentation names the npm package as the direct official
command-line distribution; the similarly named Python package is community maintained. L1 only
discovers existing `pyright-langserver` and companion `pyright` executables and never runs an
installer. See [Pyright installation](https://github.com/microsoft/pyright/blob/main/docs/installation.md).

One App-specific discovery gap was also reproduced:

```text
shell command -v pyright-langserver: /opt/homebrew/bin/pyright-langserver
launchctl getenv PATH: empty
```

Therefore shell `PATH` discovery alone is not a product proof. L1 must reuse one internal
executable-candidate function for both Exact providers: absolute entries from a sanitized `PATH`,
then `/opt/homebrew/bin` and `/usr/local/bin`. Pyright still requires both executables in the same
directory. The final bundle gate must launch normally through LaunchServices without temporarily
enriching `PATH`, and must prove both providers are discoverable in that process.

## 6. Existing ExactProbe refresh

The first refresh attempt failed before compiling because SwiftPM tried to write the user-level
Clang module cache, which is outside the current filesystem sandbox:

```text
error opening '/Users/siancao/.cache/clang/ModuleCache/...': Operation not permitted
unable to load standard library for target 'arm64-apple-macosx14.0'
```

The same protected probe was rerun with absolute repo-local module/scratch paths:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/exactprobe-clang" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/exactprobe-swift" \
swift run --disable-sandbox \
  --scratch-path "$PWD/.build/exactprobe-build" \
  --package-path Prototypes/ExactProbe exactprobe py
```

Result:

```text
exit: 0
provider=pyright-langserver
initialize=109.9 ms
definitions=167.8,0.4,0.3 ms
definition=.../definition.py:1:5
requests=3
config fingerprint changed=true, restored=true
environment fingerprint=<empty>
```

The build products stayed under ignored root `.build/`; tracked `Prototypes/` remained unchanged.
This refresh confirms the older probe still works, but the expanded P0 below is the capability and
trust decision source.

## 7. Offline JSON-RPC probe

The expanded transient probe lived outside the repository at
`/private/tmp/codeinsight-pyright-p0.MgubEL/`. It launched the language server under a macOS sandbox
that denied all network access, allowed all reads, and allowed writes only below an isolated temp
root plus `/dev/null`:

```sh
/usr/bin/sandbox-exec \
  -p '(version 1) (deny default) (import "system.sb") (allow process*) \
      (allow file-read*) \
      (allow file-write* \
        (subpath "/private/tmp/codeinsight-pyright-p0.MgubEL/env-final") \
        (literal "/dev/null")) \
      (deny network*)' \
  /opt/homebrew/bin/python3 \
  /private/tmp/codeinsight-pyright-p0.MgubEL/probe.py \
  /private/tmp/codeinsight-pyright-p0.MgubEL/project \
  /opt/homebrew/bin/pyright-langserver \
  /private/tmp/codeinsight-pyright-p0.MgubEL/env-final
```

Observed protocol result:

| Check | Result |
|---|---|
| probe process | exit 0 |
| `pyright-langserver` close | exit 0 after `shutdown` / `exit` |
| cross-file definition | 1 target |
| references | 2 targets |
| incoming calls | 1 relation |
| outgoing calls | 3 relations |
| implementation request | null |
| project bytes before/after | unchanged |
| isolated home/cache/tmp files | none in the ordinary arm |
| network | denied by sandbox profile |

Negotiated server fields:

```text
definitionProvider = { workDoneProgress: true }
referencesProvider = { workDoneProgress: true }
callHierarchyProvider = true
implementationProvider = absent
serverInfo = absent
```

The absence of `serverInfo` means provider construction must read the companion CLI version inside
the same Safe sandbox:

```text
/opt/homebrew/bin/pyright --version
pyright 1.1.411
```

Pyright's server declarations match the observed capability set; they do not advertise an
implementation provider. See [Pyright language server source](https://github.com/microsoft/pyright/blob/main/packages/pyright-internal/src/languageServerBase.ts#L606-L653).

Result: **PASS** for definition, references, and call hierarchy; **unsupported by capability** for
implementations. Session negotiation is `server advertised ∩ provider supported`; the App must
display that distinction instead of a generic all-capabilities-ready state.

## 8. Readiness and lifecycle finding

The generic `LSPClient` framing, initialize request, server-request responses, cancellation frames,
UTF-16 position mapping, shutdown, and process reaping are reusable.

The existing `RustAnalyzerSession` is not reusable as-is:

- rust-analyzer emits `experimental/serverStatus.quiescent`;
- Pyright does not emit that notification;
- waiting through the existing `waitForQuiescence` path would time out every Python request;
- rust-analyzer has a specific `-32801 content modified` retry path that the Pyright probe did not
  require;
- Pyright can emit missing-import diagnostics, but project configuration can disable them and the
  current client does not retain `textDocument/publishDiagnostics`; they are evidence, not a safe
  completeness gate.

The minimum implementation is a concrete `PyrightProvider` plus `PyrightSession` reusing
`LSPClient`; it is not a generic LSP-provider framework. Shared Location/LocationLink/call-hierarchy
JSON conversion may move to internal free functions in `LSP.swift` only when both concrete sessions
consume it.

Two deterministic lifecycle proofs remain implementation gates rather than P0 claims:

- cancel a fake no-response request and then prove a new request succeeds;
- crash a fake Pyright helper, restart exactly once, then make the second crash unavailable.

The live requests finished too quickly to prove cancellation preemption. This is not a feasibility
blocker, but product cutover remains blocked until both fake-server tests are green.

## 9. Trust, interpreter, diagnostics, and writes

The offline arm proved useful project-internal Exact navigation with:

- project read-only;
- network denied;
- only private cache/temp paths writable;
- no venv creation or dependency installation.

Pyright did launch `python3 -c ...` from the project root to inspect interpreter search paths.
Transient `json.py` and `sitecustomize.py` marker files in the project were not executed; the
observed command removes the current directory from `sys.path` before importing `json`, matching
Pyright's [FullAccessHost source](https://github.com/microsoft/pyright/blob/main/packages/pyright-internal/src/common/fullAccessHost.ts).

L1 must still treat environment input as a trust boundary. `PyrightProvider` must not send a
project interpreter path. Before launch it must remove inherited project-relative `PATH` entries,
clear `PYTHONPATH`, `PYTHONHOME`, `PYTHONSTARTUP`, `VIRTUAL_ENV`, `CONDA_PREFIX`, `NODE_PATH`, and
`NODE_OPTIONS`, and set `PYTHONNOUSERSITE=1`, `PYTHONDONTWRITEBYTECODE=1`, and
`PYTHONSAFEPATH=1`.

A `.venv/bin/python` marker alone is not sufficient: Pyright `1.1.411` enumerates configured venv
site-packages but the observed child probe still resolves `python3`/`python` through `PATH`. The
deterministic gate must place fake `python3`, `python`, `node`, `pyright-langserver`, and `pyright`
markers behind empty, relative, project-absolute, and symlink-alias `PATH` entries. Provider
discovery and the launched child environment must canonicalize and exclude all entries inside the
project. A `.venv` marker remains a supplemental assertion. If any marker runs, Python Exact stays
off until the sandbox or launch environment denies it; trusted mode is not permission to waive the
test.

The same sanitized child `PATH` must resolve `python3` and then `python`. The first executable's
canonical path and version, or an explicit unavailable sentinel, are concatenated into the existing
provider `toolVersion`. This uses the reuse key already present in ExactCoordinator and makes an
interpreter path or version change miss the overlay without adding an identity field or resolver
type.

Python uses the existing Safe sandbox profile in both requested trust modes. The requested
`TrustMode` remains in attribution and overlay identity, but Python receives neither network access
nor the Rust-specific `<project>/target` write allowance. No `Sandbox` policy generalization is
needed unless the marker test proves otherwise.

This profile protects project integrity, network access, and write scope; it is not a host
confidentiality boundary. The existing policy allows `file-read*` and `process*`, so Pyright and
paths referenced by project configuration can still read files outside the project that the host
user may read. Neither the UI nor acceptance evidence may describe this as secret isolation.

When a dependency is absent, the probe observed:

- definition returns null;
- `publishDiagnostics` contains `reportMissingImports`.

This notification is only an observed symptom: `reportMissingImports` can be configured to `none`.
The minimum honest product behavior is therefore to include the existing
`dependenciesUnavailableOffline` limitation in every Python Exact base environment, including both
default configuration and diagnostics-disabled tests. No diagnostic observer or framework is
needed.

Pyright supports `pyrightconfig.json` and `[tool.pyright]` in `pyproject.toml`, with the JSON file
taking precedence. It also ships a fallback typeshed. See
[Pyright configuration](https://github.com/microsoft/pyright/blob/main/docs/configuration.md) and
[Pyright README](https://github.com/microsoft/pyright).

The architecture audit found one historical-snapshot constraint: the existing Materializer rejects
an empty config fingerprint as an unsafe path component. Python therefore hashes the fixed bytes
`python-config\0<none>` when neither root config exists. This keeps the current Materializer and
cache layout unchanged while giving no-config Python snapshots the fixed nonempty identity
`ad63780a0cbd089b3305c2cf137e6b6bf21da9bd79e5c110172db574a847be12`.
At the Exact boundary, existing `ExactProfileKey(projectURL/snapshot, language:)` must recompute the
same Python config/uv identity and compare it with the active `AnalysisProfile`; merely copying the
profile fields would miss a changed or mismatched snapshot. Both consumers use one package free
function over a read-bytes closure; no Python profile/config type is needed.

Result: **PASS with mandatory adversarial discovery/environment tests before product cutover**.

## 10. Real-project acceptance target

The selected local real project is:

```text
path: /Users/siancao/work/ai/mcp/mcp-python-sdk
HEAD: f55831ee798cd4d7bafab4d50d6dba46e6fce387
branch: main, matches origin/main
commits: 530
tracked .py files: 204
worktree/index: clean
root config: pyproject.toml + uv.lock
[tool.pyright]: include src/mcp, tests, examples/servers
configured venv: .venv (currently absent)
```

`HEAD~1` differs in two Python files, including `src/mcp/server/fastmcp/server.py`, so the same
project can validate Reader/Diff, commit switching, and return to worktree. The stable
project-internal symbol `create_client_server_memory_streams` occurs in `src/mcp/shared/memory.py`
and tests and is suitable for definition and references without installing dependencies. The later
product probe showed Pyright does not expose call-hierarchy edges for this decorated
async-context-manager. Call-hierarchy acceptance therefore uses the existing top-level
`src/mcp/cli/cli.py:_parse_file_path`, for which Pyright 1.1.411 returns three incoming and ten
outgoing relations in the same fixed corpus.

The product gate must compare `git status --porcelain`, HEAD, and project file hashes before and
after. The real project is an acceptance input, not a vendored fixture.

## 11. GO conditions carried into implementation

The plan may proceed only under all of these conditions:

1. App preflight is the last switch changed.
2. Pyright absence affects Exact availability, not Python fuzzy/Reader project opening.
3. `implementationProvider` remains capability-driven and currently unsupported.
4. Python never calls `waitForQuiescence`.
5. every Python Exact base environment carries the existing offline-dependencies limitation,
   independent of diagnostics configuration.
6. Safe and Trusted Python sessions keep project read-only and network denied; this is not a host
   confidentiality claim.
7. fake cancellation, one-restart-only, adversarial project `PATH` non-execution, and forced-close
   tests pass before V0; real Pyright separately proves graceful shutdown.
8. Rust full CI, 14 existing self-test processes, two existing gold sets, cache vectors, and final
   App journey do not regress.
9. the interpreter resolved from the sanitized child `PATH` contributes canonical path and version
   to the existing provider `toolVersion`, so path/version changes miss overlay reuse without a new
   identity field.
10. `.pyi`, mixed projects, interpreter/venv management, dependency installation, general LSP
   abstractions, registries, and future TypeScript hooks remain out of scope.
11. A normally launched final bundle discovers Pyright without mutating the user's LaunchServices
    environment; shell-only discovery is insufficient.
