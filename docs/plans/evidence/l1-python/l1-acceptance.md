# L1 Python implementation acceptance

> Started: 2026-08-11 (Asia/Shanghai)
> L1 base: `0add42056b8f8dfd618d82371b211072c2f90899`
> Architecture parent: `0add42056b8f8dfd618d82371b211072c2f90899`
> Status: F0-F7, C1-C3, and V0 PASS

## F0 live baseline

The implementation started from `main`, ahead of `origin/main` by two commits and behind by zero.
The index and tracked worktree were clean. The only untracked inputs were the approved plan and P0
evidence:

```text
docs/plans/l1-python-plan.md
docs/plans/evidence/l1-python/p0-feasibility.md
```

`RECORD` was unset. No production or test file had changed before F0.

### Full CI

Command:

```sh
CODEX_SANDBOX=1 bash scripts/ci.sh
```

Result: **PASS**, exit `0` on 2026-08-11. `swift test list` reported 548 tests. Exact, diff,
reading, projector, and fold self-tests reached `SELF_TEST_FINISH ... exit=0`. The real
rust-analyzer self-test arm reported the existing sandbox-unavailable skip; the in-process Exact
arm passed. Release fold performance passed with:

```text
candidateCount=8400
logicalFoldCount=4400
renderedFoldCount=200
foldLatencyMs=363.168167
deltaBytes=6455248
status=pass
```

The release linker repeated the existing warning that Homebrew `libgit2.1.9.dylib` was built for a
newer macOS version. It did not fail the build.

An optional post-CI count-only command initially omitted the repository-local Clang/Swift module
cache environment and failed while compiling the manifest. Re-running with the same cache
environment as `scripts/ci.sh` succeeded; this was a harness invocation error, not a product test
failure.

### M12 fixed characterizations

Each focused rerun passed 1/1:

- `cacheKeyUsesStableLengthFramedLanguageModeIdentity`
- `analysisProfileIDMatchesTheCrossLanguageV1Vector`
- `rustHighlighterMatchesFixtureSnapshot`
- `compareModelUsesTheExplicitModeForDiffAndFunctionChanges`
- `exactOverlayReusesVersionProfileAndToolButNotSnapshotID`

### Protected objects

| Scope | Object |
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

### Local tool and acceptance corpus

```text
pyright 1.1.411
node v26.7.0
corpus HEAD f55831ee798cd4d7bafab4d50d6dba46e6fce387
corpus commits 530
tracked .py files 204
corpus status clean
```

F0 conclusion: **PASS**. Production implementation may start at F1a; the App Python product
validator remains closed until F7c.

## F1 grammar and core identity checkpoint

### F1a Python grammar boundary

Red evidence: after adding the Python named-field characterization, the first focused build failed
with `no such module 'CTreeSitterPython'`.

The scoped implementation vendors the official `tree-sitter-python` v0.25.0 complete-source
archive (commit `293fdc02038ee2bf0e2e206711b69c90ac0d413f`, SHA-256
`4609a3665a620e117acf795ff01b9e965880f81745f287a16336f4ca86cf270c`, MIT), adds only the
internal C target, and adds one package `Node.child(namedField:)` wrapper. The legacy no-argument
vendor script still updates only the runtime and Rust grammar; `--python-only` removes and rebuilds
only `Sources/CTreeSitterPython/` and verifies the fixed archive hash.

Focused verification:

```text
swift test --filter 'TreeSitterKitTests|RustExtractorTests': PASS, 35 tests
swift build --target TreeSitterKitTests: PASS
parser ABI: 15 (runtime accepts 13...15)
scripts/vendor-treesitter.sh mode: 100755
Sources/CTreeSitter and Sources/CTreeSitterRust before/after objects: unchanged
git diff --check: PASS
```

### F1b language and declaration identity

The Python classifier accepts only lowercase `.py`; `.pyi`, `.pyw`, and `.PY` remain unsupported.
`DeclarationKind` appends only `pythonFunction = 11` and `pythonClass = 12`. The two corresponding
`EngineSession.kindWeight` cases use the already-planned function/class weights and are the only
early Engine seam needed to keep the exhaustive switch compiling.

Focused verification:

```text
swift build --target CodeInsightCoreTests: PASS
swift build --target CodeInsightEngine: PASS
classifier matrix, raw-value vector, Codable round-trip, and cross-language key isolation: built
git diff --check: PASS
```

F1a/F1b conclusion: **PASS at focused checkpoint**. The combined test run remains scheduled after
the concurrently edited F2 and F6 targets are stable.

## F2 Python extractor checkpoint

### F2a minimal extractor

`PythonExtractor` is the only production type added by the target. It uses the vendored Python
grammar's named fields and emits the existing `ContentIndex` records directly; no builder,
adapter, registry, provider, or Python-specific error type was added. The completed test matrix
locks decorated/async ranges, declaration and lexical parents, class methods, lambdas, parameters,
RHS-before-binding traversal, nested shadowing, direct/method/computed calls, imports, Unicode byte
ranges, error-tree partial indexes, stable repeated extraction, key pass-through, and unsupported
language/mode rejection.

The first linked run exposed two real red cases: the fixture expected the wrong `importedName` for
`from pkg import model`, and the lambda scope assertion did not match the extracted parameter
range. Both were corrected without widening the production model. Independent review then found
an uncovered contract violation: a method function scope still had the class scope as its lexical
parent. The implementation now selects the nearest non-class scope, with a test proving method to
module and nested function to method parentage.

### F2b five-file package fixture

`Tests/PythonExtractorTests/Fixtures/basic_package/` contains exactly the planned five files. The
fixture covers a class, methods, factory function, simple locals, absolute and relative named alias
imports, and direct and method calls. `PythonExtractorTests` excludes the fixture directory from
source compilation; no sixth fixture or new dependency was added.

Focused verification:

```text
swift test --filter PythonExtractorTests: PASS, 11 tests
production type audit: PythonExtractor only
git diff --check: PASS
```

F2a/F2b conclusion: **PASS**.

## F3a capture and profile checkpoint

Python worktree capture accepts only classifier-selected `.py` sources, captures only the three
root configuration inputs, and rejects TypeScript/JavaScript before repository traversal. Profile
detection has an explicit language entry while the compatibility entry remains Rust. Python
identity uses one package free function and a fixed non-empty no-config sentinel; no profile type
or TOML parser was introduced.

Focused verification:

```text
swift test --filter 'ProfileDetectorTests|GitSnapshotTests': PASS, 29 tests
worktree/commit profile identity and unsupported preflight tests: included
git diff --check: PASS
```

F3a conclusion: **PASS**.

## F3b module map and fuzzy resolver checkpoint

The existing `ModuleMap` now selects its private Rust or Python construction branch from the
active language. Python maps only unique root/src module identities, requires real package
`__init__.py` segments, and resolves supported absolute/relative named imports without guessing
namespace, external, ambiguous, or module-object targets. Resolver reuses the existing candidate
and evidence model; Python constructor candidates may be Strong, while dynamic method candidates
are capped at Possible. No resolution protocol, registry, or production type was added.

The first full run exposed a test-fixture range bug rather than a product crash: one source used a
different module spelling than its import record, and several call ranges selected an alias or
declaration instead of the call site. The fixture now uses exact call needles; the shared range
helper was not weakened.

Focused verification:

```text
8 Python resolver tests: PASS
Rust crate/super module regression: PASS
swift test --filter CodeInsightEngineTests: PASS, 90 tests
git diff --check: PASS
```

F3b conclusion: **PASS**.

## F4a index, cache, search, and view checkpoint

`ProjectIndexer` now imports the Python extractor, selects it for `.python`, and delegates both
worktree and snapshot profile construction to the existing explicit-language detector. The rest
of extraction, remapping, persistence, snapshot preparation/completion, search, and view assembly
continues through the existing shared pipeline. The production diff is an exhaustive switch and
dependency wiring; no Python indexer, pipeline, cache, or registry type was added.

The cache characterization uses one real Python key and one real Rust key in the same persistent
cache. It proves Python cold extraction and hot reuse, a Python-only extractor-version miss, and
continued Rust reuse after that miss. A separate same-byte `.py`/`.rs` fixture proves the content
digest can match while the language-mode keys remain isolated.

```text
4 F4a Python index/cache/search tests: PASS
swift test --filter CodeInsightEngineTests: PASS, 94 tests
Python cold extracted=1; hot reused=1/extracted=0
Python version miss extracted=1; Rust remained reused=1/extracted=0
git diff --check: PASS
```

F4a conclusion: **PASS**.

### F4b Python gold gate

The existing evaluator now accepts an explicit language while retaining Rust as the default. Only
the `goldset` CLI command adds `--language python`. The gate script's Python corpus arguments are
optional; when provided, it requires the fixed approved revision, a clean worktree, 204 tracked
`.py` files, both root configuration files, and unchanged HEAD/status/index blob identities before
and after the run.

The six-assertion Python gold covers all planned contracts: same-file definition, absolute named
alias plus constructor, relative named alias, local bind, dynamic method `nostrong`, and
module-object unresolved. It has no known failures.

```text
tokio gold: PASS
ripgrep gold: PASS
mcp-python-sdk gold: PASS, total=6, def top1=3/3, unexpected failures=0
legacy no-Python-argument two-corpus gate: PASS
Python corpus before/after: fixed HEAD, clean, tracked .py=204
protected Rust gold/fixtures: unchanged
```

F4b conclusion: **PASS**. The combined C1 target run remains scheduled after concurrent Exact
orchestration edits are stable.

## F5 Reader and diff checkpoint

### F5a/F5b Reader syntax and presentation

Python Reader syntax uses one parse tree for spans, outline, folds, and local references. The
implementation adds only private/package free functions plus the existing `DocumentLoader` debug
observer seam; it does not add a Python Reader type or error hierarchy. Class presentation reuses
the existing type-like colors, marker, symbol image, palette group, and fold summary ordering.

```text
swift test --filter CodeInsightReaderCoreTests.pythonReader: PASS, 4 tests
swift test --filter PaletteTests: PASS, 9 tests
python class outline/gutter/fold summary test: PASS
Python class palette ordering test: PASS
```

The full ReaderCore target still records the frozen M11 issue at `ReaderUITests.swift:705`: fold
ID 5 remains additionally unfolded. The Python work did not add another Reader failure.

### F5c line and function diff

`DiffCore` selects the existing Rust or Python extractor by mode, includes only
`pythonFunction` in Python function summaries, and uses `.` for Python name chains while keeping
Rust `::`. It adds no adapter or language field. After Python became supported, the stale-mode
CompareModel test's unsupported example was changed from Python to TypeScript; no production
CompareModel seam was needed.

```text
Python line/function/signature/body/add/remove/nested-name/truncation tests: PASS
focused Rust diff regressions: PASS
CompareModel explicit-mode and stale-mode tests: PASS
git diff --check: PASS
```

F5a/F5b/F5c conclusion: **PASS at focused checkpoint**. C2 full self-tests remain scheduled.

## F6a Pyright provider checkpoint

`PyrightProvider` and `PyrightSession` are the two required production types. They reuse the
existing LSP client, position mapping, batching, sandbox, attribution, and provider protocol.
Discovery and child environments exclude canonical project paths, clean Python/Node environment
inputs, and keep both trust requests on the Safe launch path. Pyright does not inherit the
rust-analyzer quiescence algorithm; supported capabilities are capped at definition, references,
and call hierarchy, with the existing offline dependency limitation always present.

```text
swift test --filter pyright: PASS, 13 tests
swift test --filter CodeInsightExactTests: PASS, 73 tests
project PATH marker launch control: PASS
graceful/restart/force-kill lifecycle tests: PASS
Rust Exact regression tests in the same target: PASS
```

F6a conclusion: **PASS**. Real installed-Pyright deny-network acceptance and F6b orchestration
remain scheduled for C3/V0.

## F6b Exact orchestration checkpoint

The coordinator now selects Pyright only for Python, builds default worktree snapshots with the
captured language, and recomputes exact configuration identity from the actual worktree or commit
before any materialization or provider launch. Explicit `AnalysisProfile` calls compare language,
config, environment, and feature selection; the older Rust convenience remains compatible and
does not pretend its historical placeholder fingerprints were explicit input. Python definitions
and relations are filtered through the active classifier, so `.pyi` and other unsupported targets
cannot be published.

Two test-input defects were exposed while running the full group: materialization tests still used
the old Rust-only prepare overload, and the overlay reuse test changed Cargo inputs without updating
its explicit analysis fingerprint. The tests now pass the matching profile identity; production
validation was not weakened. The temporary extra snapshot-factory test type was removed.

```text
Python/provider focused orchestration tests: PASS, 6 tests
Rust and no-config Python commit materialization: PASS, 1 test each
explicit unsupported/profile/provider mismatch: PASS, 3 tests
swift test --filter ExactCoordinatorTests: PASS, 30 tests
git diff --check: PASS
```

F6b conclusion: **PASS**. C3 still requires the full Exact/AppModel groups and the real installed
Pyright deny-network probe.

## C1-C3 combined checkpoints

### C1 core/index/search

```text
swift test --filter 'CodeInsightCoreTests|CodeInsightGitTests|PythonExtractorTests|CodeInsightEngineTests'
PASS, 131 tests, exit 0
```

This combined run includes the Python/Rust same-content cache isolation, Python cold/hot/version
miss characterization, module/import resolution, profile identity, search filtering, and all Rust
Engine regressions.

### C2 Reader/UI/Diff

`CodeInsightReaderCoreTests` exited `0` with 96 listed tests. Its only recorded issue remains the
frozen M11 navigation-fold expectation at `ReaderUITests.swift:705` (extra fold ID 5); no Python
Reader or Diff test added another issue. The full AppModel group initially exposed one stale test
that still expected Python Reading Set capture to be unsupported. It now uses valid Python source
and proves the explicit mode freezes only the target function. A second full run passed 212/212;
the independently rerun Reading Set and snapshot-cancellation tests passed 2/2.

The built debug product self-tests all completed normally:

```text
--self-test-reading: SELF_TEST_FINISH ... channel=reading exit=0
--self-test-fold:    SELF_TEST_FINISH ... channel=fold exit=0
--self-test-diff .:  SELF_TEST_FINISH ... channel=diff exit=0
```

C2 conclusion: **PASS**, with only the pre-existing M11 recorded issue.

### C3 Exact and real Pyright

The first full Exact run found one stale negative assertion that still called Python fingerprinting
unsupported. The negative case now uses TypeScript while preserving the Rust fixed SHA vectors.
The rerun passed 73/73. The full AppModel rerun passed 212/212, including the atomic Python product
rejection; the F7c validator remains closed.

The installed Pyright 1.1.411 probe was rerun under `sandbox-exec` with network denied and writes
limited to `/private/tmp/codeinsight-pyright-c3.womRA2`. It completed with server exit `0` and:

```text
definition targets=1
references=2
incoming relations=1
outgoing relations=3
implementation=null
serverInfo=null
post-cancellation definition targets=1
isolated HOME/cache/tmp files=0
project hashes unchanged
```

The 73-test Exact run also passed deterministic cancel/restart/force-kill/reap and adversarial
canonical project/PATH marker tests. Both Python trust requests route through the same production
Safe launch; attribution still records the requested trust mode without expanding project writes.

C3 conclusion: **PASS**. F7 product-facing slices may begin.

## F7 product cutover checkpoint

### F7a project language identity

Recent projects retain the existing path array and use one private parallel map from standardized
path to `LanguageID.rawValue`; no recent-project DTO was added. Missing, invalid, and non-exact
numeric entries decode as Rust. Recording the same path replaces its language and moves it to the
front, while the eight-entry prune and clear operations keep both values synchronized.

`MainWindowController` now carries one language scalar beside each existing last-opened and
pending-recent root. Explicit open, retry, restore, and recent selection forward that identity;
the legacy no-language entry remains Rust. Focused tests cover migration, overwrite/order/prune,
clear, forwarding, and SessionCodec restore identity.

```text
RecentProjectsStoreTests + MainWindowControllerTests: PASS, 9 tests
SessionCodecTests + SessionRestoreTests: PASS, 10 tests
CodeInsightApp target build: PASS
git diff --check: PASS
```

### F7b feature behavior and F7c AppModel gate

For an active Python profile, the existing feature-selection surface returns only
`defaultFeatures`; switching to another Cargo feature is a no-op and does not advance generation
or rebuild the session. Rust behavior remains unchanged.

The final product cutover changes only the shared file-private validator: Rust and Python are
allowed, while TypeScript and JavaScript remain unsupported. `AppModel.openProject`, direct index,
and snapshot capture still use that one validator. The negative tests now inject TypeScript and
JavaScript and retain the state/root/language/generation and no-cache/no-root-I/O assertions.

A real Python AppModel integration creates a project containing `.py` and `.rs`, reaches
`fullReady`, exposes only `.py`, and succeeds in symbol and content search. Saved-session restore
also returns a Python `fullReady` session and a Python-only tree.

```text
Python feature-selection focused test: PASS
F7c AppModel focused tests: PASS, 5 tests
swift test --filter CodeInsightAppModelTests: PASS, 218 tests, exit 0
git diff --check: PASS
```

The provider-neutral UI uses the existing analysis-profile language directly. Python profile title,
menu, Exact status, and Context provenance omit Cargo feature/edition text; Rust retains its current
feature detail. Relation, history, and tooltip copy now says `exact provider` rather than naming
rust-analyzer, while actual provider identity continues to come from the existing attribution.
The previously unsafe MainWindow catch no longer retries a rejected explicit language as Rust.

```text
MainWindowControllerTests: PASS, 6 tests
Python Context badge + relation status focused tests: PASS, 3 tests
codeinsight-app product build: PASS
CodeInsightAppModelTests target build: PASS
git diff --check: PASS
```

F7a, F7b, and the AppModel portion of F7c: **PASS**. Explicit app menu/drop identity and the Python
product self-test remain in progress.

The AppKit entry is now explicit without marker inference. `Open Project…` is Rust,
`Open Python Project…` is Python, and both reuse one directory chooser. Recent menu selection uses
the saved language map. Empty-state and sidebar choose actions, plus folder drop, use one
Rust/Python/Cancel prompt; recent click and drop are separate closures. No language was duplicated
into tabs or excerpts.

```text
codeinsight-app product build: PASS
MainWindowControllerTests: PASS, 6 tests
--self-test base: PASS, fileMenuHasRustAndPythonOpen=true,
  paletteCollectsRustAndPythonOpen=true, exit=0
git diff --check: PASS
```

F7c menu/recent/drop identity: **PASS**.

### F7c Python product self-test

The single Python channel runs through the existing AppModel, Reader, Context, Relation, Exact,
Compare, snapshot, recent-project, and session-restore paths. Its local async poll yields the main
actor while those existing tasks publish; the first black-box run exposed and fixed synchronous
self-test starvation rather than adding a product scheduler seam. A second product defect was also
found: the Rust-only implementations expansion rule prevented a Python function from reaching the
capability-driven unsupported state. The shared gate now allows Python declarations to query that
state, while the existing Rust trait/method rule is unchanged and a focused Python regression test
locks the exact UI text.

Pyright 1.1.411 did not produce call-hierarchy edges for the decorated async-context-manager used
for definition/reference acceptance. A direct LSP probe over the fixed corpus selected the existing
top-level `_parse_file_path` function instead: Pyright returned three incoming and ten outgoing
relations. The product channel uses that fixed symbol for call hierarchy while continuing to use
`create_client_server_memory_streams` for definition and references. Product filtering keeps only
supported `.py` targets, so the verified UI result is three callers and no supported outgoing
targets; builtins and typeshed `.pyi` targets are intentionally rejected.

The final cold-cache run used
`CODEINSIGHT_INDEX_CACHE_ROOT=/private/tmp/codeinsight-python-final.pn7MAs/index` and the fixed clean
`mcp-python-sdk` corpus. It completed in 3.395 seconds with:

```text
cold open: files=204, extracted=190, reused=0, Python-only tree/manifest
search: content + symbol hit src/mcp/shared/memory.py
Reader: outline=2, folds=9, bindings=14, local references=15, styled fragments=63
Exact: definition=1, references=4, callers=3, supported outgoing calls=0
implementations: Verified unavailable: server does not support implementations
Compare HEAD~1: hunks=1, truncated=false, right bytes match commit and differ from worktree
commit switch: reused=188, extracted=2; worktree return: reused=190, extracted=0
recent reopen: files=204, reused=190, extracted=0
session restore: Python fullReady + Exact ready
summary checks: 20/20 true
SELF_TEST_FINISH ... channel=python exit=0
```

The shell harness accepts an optional fourth Python Git repository. Three arguments still schedule
the original 14 channels; four arguments add exactly one `python` channel after validating the
fixed files, clean worktree, and availability of `HEAD~1`.

```text
swift build --product codeinsight-app: PASS
bash -n scripts/run-self-tests.sh: PASS
python RelationTreeModel implementations focused test: PASS
fresh-cache --self-test-python: PASS, exit 0
git diff --check: PASS
```

F7c Python product self-test: **PASS**. F7 is complete.

## V0 final acceptance — 2026-08-12

The final gate used baseline `0add42056b8f8dfd618d82371b211072c2f90899`, unset `RECORD`, and
the clean fixed corpus `mcp-python-sdk@f55831ee798cd4d7bafab4d50d6dba46e6fce387` with 204 tracked
`.py` files.

### Automated gates

```text
CODEX_SANDBOX=1 bash scripts/ci.sh: PASS, exit 0
Swift Testing: 422 passed; one pre-existing recorded M11 issue at ReaderUITests.swift:705
recorded issue: rendered folds contain the frozen extra FoldID 5
fold perf: PASS, fold latency 377.36625 ms, memory delta 8,880,104 bytes

fresh-cache host harness: pass=15 fail=0 hang=0
artifacts: .build/self-test-run-20260812-133533-59155
target outcomes: all SwiftPM targets passed; per-test target detail is retained in the CI log

tokio gold: total=17, unexpected failures=0
ripgrep gold: total=16, KNOWN-FAIL=3, unexpected failures=0
mcp-python-sdk gold: total=6, unexpected failures=0
gold fold perf: PASS, fold latency 393.801833 ms, memory delta 7,684,096 bytes
```

The host harness used a fresh cache root and fresh non-Git fixture because macOS rejects the exact
providers' nested `sandbox-exec` under the Codex outer sandbox. All 15 processes passed. The first
post-fix CI fold probe measured 406.04775 ms while an obsolete acceptance bundle was still consuming
about 198% CPU. That process was terminated; the unchanged release binary then measured 362.264167 ms
on the host, and the two complete final gates above passed without changing code or thresholds.

The final signed bundle was rebuilt after the cross-group relation identity fix with one unused
identity:

```text
bundle id: dev.cairn.Cairn.l1v0.20260812133706
app: .build/l1-distribution-v0-20260812133706/Cairn.app
zip: .build/l1-distribution-v0-20260812133706/Cairn.zip
zip bytes: 3,198,472
zip SHA-256: 4cade3a849c3170c200fbb8a5f2d2a53ee1a3d1a12641fa306d71058675e2421
Info.plist bundle identifier: exact match
codesign --verify --deep --strict: PASS
```

Before first launch, both its UserDefaults domain and
`~/Library/Application Support/Cairn/dev.cairn.Cairn.l1v0.20260812133706` were absent.
`launchctl getenv PATH` was empty. The app was opened only with `open -n` for the first-launch and
restart journey.

### Final-bundle AppKit/AX journey

Real AX state and visible frames established:

- the File menu exposes distinct `Open Project…` and `Open Python Project…` entries;
- the Python entry opened the fixed corpus, showed only `.py` files, and displayed
  `mcp-python-sdk · Safe` with no Cargo feature or edition;
- normal LaunchServices discovery reached `pyright 1.1.411` with Python 3.14.6; the status exposed
  `dependencies unavailable offline` and did not claim dependency completeness;
- `src/mcp/shared/memory.py` rendered Python highlighting, two function outline rows, fold markers,
  and local-scope selection;
- the main snapshot switched to historical commit `3abefee`, retained the Python Reader and Pyright
  state, then returned to Working Tree;
- normal `Quit Cairn` removed the process; relaunching the same bundle ID restored
  `mcp-python-sdk`, selected `memory.py`, Python profile, and ready Pyright; Open Recent preserved
  the Python corpus identity.

The same bundle binary passed the structured Python product channel 21/21 in 2.892 seconds.
The counts below are from that bundle invocation; the separate fresh-cache 15-channel artifact
reported four references because it started from an empty index cache:

```text
files=204; reused=190; extracted=0
definition=1; references=1; callers=3; supported outgoing calls=0
implementations=unsupported
compare hunks=1; right reader matches HEAD~1 and differs from worktree
commit/worktree switch, recent reopen, and session restore: PASS
SELF_TEST_FINISH ... channel=python exit=0
```

Its release Exact channel also passed with real rust-analyzer definition, references,
incoming/outgoing calls, and implementations. This is the final-bundle Rust provider proof; the
in-process fake evidence remains identified separately in its own rows.

The final RelationTree regression has explicit behavioral TDD evidence: with the duplicate
post-reuse filter restored, `relationTreePreservesCorrectedGroupChildIdentityAfterGroupMigration`
failed at its final group-presence assertion; after deleting only that redundant filter, the focused
test passed and the full `CodeInsightAppModelTests` target passed 225/225.

Both repositories retained their original HEADs and status after the journey. Protected Git
objects, the index, existing Rust fixtures/gold, `Package.resolved`, and the existing tree-sitter
runtime/Rust grammar remained unchanged. `git diff --check` passed. No publish, tag, push, stage, or
commit was performed.

V0: **PASS**.
