# Readonly optimization baseline (S0)

Status: S0 complete; see `stage-s0.md` for results and explicit baseline gaps.
No optimization or full product acceptance is claimed.

- Design baseline: `6a54ef1562282c8852c3038022c12720b96d9fc0`.
- Implementation/oracle baseline: `f5e116d6477fe20ed9bd83b08b82f4a0512594a7`.
- Intervening change: Follow now shows complete functions and comments; five files,
  74 insertions and 34 deletions. Existing behavior is retained in this project.
- Initial working tree: the supplied design and implementation plan were untracked;
  no source changes were present.
- Host: arm64 macOS 27.0 (26A428), Apple Swift 6.4
  (`swiftlang-6.4.0.34.1`, clang 2100.3.34.1), Homebrew libgit2.
- Baseline CI started with `CODEX_SANDBOX=1 bash scripts/ci.sh`;
  original output: `/private/tmp/cairn-readonly-baseline-ci.log`.
  The original main batch completed 1,028 tests: 5 test functions failed (31
  issues) in CodeInsightAppTests, all other targets passed. The five failures
  concerned native sheets and pasteboard access. A subsequent unsandboxed
  focused run passed all five tests (6.595 seconds).
  Later CI batches overlapped S0 harness development: bookmarks passed 2 tests;
  panels/mouse hit a new optional-count compile error, now corrected. Those
  batches are not baseline behavior failures. Fresh panel and mouse runs passed
  2 and 1 tests respectively, with complete summaries.
- S0 oracle checks: 4 tests passed in 0.112 seconds, complete Swift Testing summary.
- Release build completed after allowing dsymutil access outside the sandbox.
- Bilingual localization validation: 793 keys passed.
- Raw logs are retained in `.build/readonly/s0-baseline/test-logs/` and
  `.build/readonly/s0-verified/test-logs/`; see `stage-s0.md` for native artifacts.

## Counter meanings

`ReaderWorkCounters` is opt-in and process-wide, protected by an NSLock.
Scenario runners enable it and compare snapshots around actual operations.
It never controls application behavior. Existing per-view counters are unchanged.
Only isolated runs provide attributable deltas; simultaneous windows/workers may
contribute to the same process counters.

- `identifierDecodedBytes`: bytes submitted to full-source UTF-8 decoding, including
  queries later rejected as keywords. `identifierScannedBytes`: bytes actually
  traversed by the occurrence token scan, read from its final byte cursor.
- `projectionPlanBuildCount`: DisplayMap construction attempts.
- `materializedUTF8Bytes`: source bytes actually decoded into visible projection
  slices; placeholder characters are not source bytes.
- `fullTextReplacementCount`, `replacedUTF16Units`: full storage installations
  and old storage units replaced (an initial empty installation replaces zero).
- `attributeUpdatedUTF16Units`: ranges receiving base or specialized typography
  and paragraph attributes; overlapping attribute passes count separately.
- `paragraphRecordsVisited`: actual paragraph traversal, distinct from the old
  changed-paragraph counter.
- `decorationBuildCount`: document declaration map and gutter fold map builds.
- `drawGlobalRecordVisits`: global fold/diff/bookmark records inspected during
  ruler drawing, including dictionaries and rendered-region filters.
- `regionQueryRecordVisits`: executable-region records visited by Calls/Callers.
- `applicationFullLayoutCount`: application-requested full extent enumeration;
  not framework-internal layout or a single-anchor ensureLayout.
- Prepared-index, topology, ownership and partial replacement counters remain
  zero until those paths exist; zero alone does not prove an optimization.

## Frozen reference

`Tests/CodeInsightReaderCoreTests/Readonly*Oracle.swift` freezes the old identifier,
DisplayMap and structural selection algorithms. They do not call the replacement
algorithms. Four deterministic baseline tests compare multilingual identifier and
Unicode projection results and record structural tie-break/truncation semantics.

Native workload JSON must retain actual font, viewport, source hashes, before/after
work counts and explicit limitations. A draw does not establish stable reflow;
synchronous operation durations are not stable interaction latencies.
