# M12 acceptance evidence

## F0 — implementation baseline

- Date: 2026-08-11 (Asia/Shanghai)
- Branch: `main`
- Draft baseline before the approved plan: `a83f55fd264cec1a0d25dc14c697bb003738cb62`
- `M12_BASE`: `4d8ac32a08425a48c9f1614957769f1e4805ae36`
- Baseline commit scope: only `docs/plans/m12-plan.md` (800 insertions)
- Before the baseline commit: `main` matched `origin/main` (`+0/-0`); the only
  untracked file was `docs/plans/m12-plan.md`; the index was empty.
- Immediately after the baseline commit: `main` was `+1/-0`; worktree and index
  were empty.
- `RECORD`: UNSET.

### Live CI

```text
CODEX_SANDBOX=1 bash scripts/ci.sh
exit: 0
started: 2026-08-11 13:14:45 +08:00
finished: 2026-08-11 13:15:59 +08:00
```

- The test inventory at `M12_BASE` contained 517 Swift Testing cases.
- Existing `exact`, `diff`, `reading`, `projector`, and `fold` self-test channels
  all emitted `passed: true` and exited 0.
- The real rust-analyzer safe/offline probes reported the existing permitted
  `sandbox-exec` unavailable skip; the exact aggregate still emitted
  `passed: true` and exited 0.
- Fold fixture verification passed:
  `sha=86bf0fac91bd7556b2ea49b9a6426d3d31de17cf1d81491972500371761f9578`,
  `bytes=3115800`, `newlines=50000`.
- Release fold performance emitted `status: pass`, `resolutionMs=25.389417`,
  `foldLatencyMs=379.188417`, and `deltaBytes=6570008`.

### Green characterization

The following seven existing contracts were rerun together and passed
(`exit 0`, 7/7, 0.112 seconds):

- `persistentDraftRoundTripMatchesDirectExtractionFieldForField`
- `extractorVersionMismatchRebuildsTheWholeDatabase`
- `analysisProfileIDMatchesTheCrossLanguageV1Vector`
- `sessionCodecRoundTripsTaggedTabsAndEveryFrozenInspectorField`
- `rustHighlighterMatchesFixtureSnapshot`
- `lineDiffMarksAddedRemovedAndChangedLines`
- `exactOverlayReusesVersionProfileAndToolButNotSnapshotID`

F0 added one repair-before-green characterization without changing production
code:

```text
rustCacheKeyMatchesM12BaselineVector
expected: 1:00ab:0:-:1:7
exit: 0
result: 1/1 passed in 0.001 seconds
```

This makes the working test inventory 518 before the first F1 red test.

### Protected baseline identities

| Protected scope | Git object at `M12_BASE` |
|---|---|
| `Sources/CodeInsightEngine/CanonicalDump.swift` | `20ddd6f08d326d7e15074a7fb684680e7a8477bf` |
| `Prototypes/` | `27ff155fede12ff663030e1dd0cf52e6f8458887` |
| `goldset/` | `9353e29663e6a754bf7ddd71ba74a8230b15abfb` |
| `fixtures/` | `7dc98497059f6590d8d3a28843d70ce7b150739f` |
| `Tests/Fixtures/` | `0bf01b2d933cc801e6ad3a49df24c4e0ce9fce57` |
| `Tests/RustExtractorTests/Fixtures/` | `82f1d4251fb71da9ec20a904e6427c0c39451e6a` |
| `Tests/CodeInsightExactTests/Fixtures/` | `57d053cf1845fe174c1f894be74e1ac484a80cf8` |
| `docs/plans/evidence/m11/` | `4b1b7c00dddc18077c16d4b2cd555704f5f059e4` |

All scopes above had an empty diff from `M12_BASE` when F0 completed.

## F1 — stable language and cache identity

### Red

The final mode/key/schema tests were first run against the F0 implementation:

```text
exit: 1
error: String cannot be converted to StringID
error: LanguageMode has no member classify
```

### Green

- `LanguageID` now has fixed raw values `0/1/2/3`.
- `LanguageMode.variant` is a normalized stable `String?`; one classifier maps
  Rust `.rs` paths and rejects unsupported languages.
- The schema-2 cache key uses byte-length framing and distinguishes nil, empty,
  delimiter-containing, and canonically equivalent Unicode variants.
- `ContentIndexDraftCodec` format/magic is version 2.
- Cache metadata contains only schema version 2; extractor-version entries can
  coexist, while schema mismatch rebuilds the derived database.

```text
focused F1 contracts: 7/7 passed, exit 0, 0.141 seconds
Core + Engine: 81/81 passed, exit 0, 2.529 seconds
adjacent commit cache reuse: 57/57, 100.0 percent
git diff --check: exit 0
protected-path diff: empty
```

## F2 — extractor boundary and explicit indexing language

### Red

The first focused build failed because the existing Rust-only extractor and
snapshot entry points could not accept an explicit language. The unsupported
snapshot test also observed repository access before rejection.

### Green

- `LanguageExtractor` owns the extractor/grammar identity, diagnostics, and
  mode-aware identifier ranges used by indexing and search.
- `WorktreeSnapshot` and `ProjectIndexer` take an explicit language. Their old
  public/package entry points remain Rust conveniences.
- `ProjectIndexer` selects one extractor, classifies paths once, and validates
  cache/profile/extractor identity without a registry or adapter layer.
- Python and TypeScript fail before repository traversal.

```text
focused extractor/indexer contracts: exit 0
Rust cache/profile fixed vectors: unchanged
new production adapter/registry/protocol types: 0
```

## F3 — project/session language and publication identity

### Red

The initial AppModel tests failed to compile until language was propagated
through index, snapshot capture/prepare, session persistence, and restore.
Wrong-language sessions were then injected at the initial-index and snapshot
completion sinks; both were publishable before the final guards.

A direct `ProjectIndexService` test additionally proved that unsupported index
requests could create the persistent cache, and unsupported commit capture
could enter Git, before the bottom guard was moved to the start of both service
entry points.

### Green

- `openProject(root:language:)` rejects non-Rust before changing root, language,
  state, or generation.
- Every asynchronous open/snapshot/compare publication gate validates the same
  root + language + generation identity; wrong-language sessions fail instead
  of becoming ready.
- `SessionCodec.Snapshot.language` is required for new payloads. Its private
  decoding envelope alone is optional so schema-1 payloads without the key
  restore as Rust; the schema version remains 1.
- Direct unsupported index/capture calls create neither the project root nor
  the cache SQLite, WAL, or SHM files and do not access Git.

```text
AppModel test inventory: 206
focused propagation, restore, wrong-session, and no-I/O contracts: exit 0
ProjectIndexService unsupported direct-call contract: 1/1 passed
```

## F4 — active-language Engine view

### Red

Active-view tests first exposed manifest-wide path/content lookup in search,
module resolution, postings, aliases, and impl edges. A final same-content
collision test used an active `.rs` occurrence and foreign `.py` occurrence
with the same `ContentID`; the foreign path became the Rust module parent and
degraded `super` resolution.

### Green

- `SnapshotView` carries the selected extractor and active
  `ContentIndexKey`-by-path view; `EngineSession` derives postings, aliases,
  impl edges, search, module maps, and coverage from that view.
- `ModuleMap` filters manifest occurrences with the shared classifier before
  constructing roots, children, or parents. The same-content foreign-path
  regression is green.
- `SnapshotSearch` keeps the old public Rust initializer, while the explicit
  extractor initializer is internal; no public injection API was added.

```text
CodeInsightEngine test inventory: 76
same-content active .rs / foreign .py ModuleMap regression: 1/1 passed
final Engine focused suite: exit 0
```

## F5 — Reader, diff, compare, context, and relation language mode

### Red

The Reader/Diff callers first failed to compile when explicit mode was required.
Stale-completion tests then exercised mode changes across document loading,
compare generation, context resolution, snapshot replay, and reading-position
restore.

### Green

- `DocumentLoader` and `DiffCore` have explicit mode entry points and retain
  Rust conveniences only at compatibility/test boundaries.
- Reader document identity, regular/large/huge syntax loading, compare,
  Reading Set construction, context/dependency mini-readers, relation local
  bindings, replay, and restoration all preserve and revalidate mode.
- Unknown extensions fail honestly rather than silently becoming Rust or plain
  syntax. The reading/diff self-test files were renamed to `.rs`; the large
  self-test files remain under ignored `target/` and are not indexed.
- No language field was added to tabs or Reading Set excerpts.

```text
ReaderCore test inventory: 86
ReaderUI test inventory: 11
known pre-existing M11 recorded issue: ReaderUITests.swift:631 adds FoldID 5
all M12 Reader/Diff focused contracts: exit 0
```

## F6 — Exact profile/provider/reuse language identity

### Red

Focused builds failed until the Exact profile, provider factory, and reuse key
received explicit language/profile identity. Runtime red tests showed provider
language mismatch and language/profile/environment changes could otherwise
reuse an overlay.

### Green

- `ExactProfileKey`, provider construction, coordinator preflight, and reuse
  identity include language; reuse also includes analysis profile ID and the
  existing exact-environment fingerprint, but not `SnapshotID`.
- Unsupported languages fail before snapshot factory, materializer, provider,
  overlay, process, or state mutation.
- The existing Rust Cargo/lock, tool, materializer, and fresh-SnapshotID reuse
  identities remain unchanged.
- `Sandbox.swift` and `Materializer.swift` have no M12 diff.

```text
CodeInsightExact test inventory: 56
Exact coordinator focused suite: 20/20 passed
Exact overlay focused suite: 4/4 passed
materializer focused suite: 3/3 passed
```

## V0 — final acceptance

### Automated gates

```text
CODEX_SANDBOX=1 bash scripts/ci.sh
exit: 0
Swift Testing inventory: 548
release fold resolutionMs: 25.377375
release fold latencyMs: 399.397833
release fold deltaBytes: 7602176
release fold status: pass
```

One immediately preceding full-CI run reached all functional/self-test/release
stages but exited 1 when the same fold-perf binary measured 404.643125 ms
against the 400 ms hard limit. A direct rerun passed at 390.961834 ms, and the
final full CI above passed at 399.397833 ms. No functional test failed in that
run; this is recorded as timing jitter, not hidden as a green first attempt.

```text
CODEINSIGHT_INDEX_CACHE_ROOT=.build/m12-v0-index-cache \
CODEX_SANDBOX=1 bash scripts/run-self-tests.sh \
  /Users/siancao/work/ai/vibecoding/codeinsight \
  /private/tmp/codeinsight-m12-final-non-git.jhzyJH \
  /Users/siancao/work/ai/vibecoding/codeinsight/Tests/CodeInsightExactTests/Fixtures/exact_fixture/src/lib.rs
exit: 0
summary: pass=14 fail=0 hang=0
artifacts: .build/self-test-run-20260811-152737-57259
hot project cache: reused=57 extracted=0 elapsedMs=528.344583
```

The first non-Git attempt used an empty directory and failed the project
channel as designed; the final directory contained `main.rs`. The default
cache location is outside the Codex filesystem sandbox, so the final run used
the repo-local cache root above instead of treating repeated cold extraction
as cache reuse.

```text
CODEX_SANDBOX=1 bash scripts/run-gold-gates.sh
exit: 0
gold unexpected failures: 0
tokio: total=17 top1=8/8 top5=3/3 known-fail=0 unexpected=0
ripgrep: total=16 top1=5/6 top5=2/3 known-fail=3 unexpected=0
gold fold resolutionMs: 25.060875
gold fold latencyMs: 364.266791
gold fold deltaBytes: 6062080
gold fold status: pass
```

### Final macOS bundle product gate

```text
CODEX_SANDBOX=1 CAIRN_OUTPUT_DIR=.build/m12-distribution \
  bash scripts/make-app.sh
exit: 0
bundle: .build/m12-distribution/Cairn.app
zip: .build/m12-distribution/Cairn.zip
Info.plist: OK
codesign --verify --strict: passed
signing: ad-hoc; notarization intentionally not requested
```

The generated bundle was launched and inspected through the real AppKit UI.
Against the real Tokio Git checkout it completed this one product journey:

1. opened `tokio-tokio-1.47.1` and observed Exact ready with the installed
   rust-analyzer;
2. searched `#File`, opened `tokio/src/fs/file.rs:90`, then searched `#open`
   and navigated the Reader to line 152;
3. activated `OpenOptions`; the context pane returned
   `tokio/src/fs/open_options.rs:82:12`, `Exact·direct`, provider
   `rust-analyzer`;
4. opened References from the Reader context menu; the relation tree completed
   with an expanded `OpenOptions` root and 87 possible matches;
5. switched to commit `be8ee45`, then selected Working Tree; the Version
   popover marked `Working Tree — Current files on disk` as current and Exact
   returned to ready.

No visible M12 regression was observed, so the plan did not require new theme
screenshots.

### Structure and scope gates

```text
swift test list --skip-build: exit 0, 548 tests
git diff --check: exit 0
production LanguageAdapter/registry/plugin/capability/multi-session types: 0
new production struct/enum/protocol/class/actor declarations: 0
CanonicalDump/gold fixtures/Prototypes/M11 evidence diff: empty
Package.swift / Package.resolved diff: empty
git index: empty
RECORD: UNSET
publish/tag/push: not performed
implementation commit: not performed
```

Two existing function typealiases were extended for the explicit loader and
provider-factory signatures; no speculative abstraction was introduced.
