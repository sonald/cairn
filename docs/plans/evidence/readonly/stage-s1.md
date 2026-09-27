# S1 — prepared identifier queries and shared builds

Status: S1 complete. Functional, native work-count and lifecycle checks passed.

## Behavior and ownership

`IdentifierIndex` scans once on a worker, interns names with Swift String equality,
merges excluded syntax intervals, and publishes source-ordered tokens and contiguous
posting slices. Queries binary-search token positions. Tests compare every byte of
Rust/Python/TypeScript/TSX, canonical-equivalent names, comments, numeric prefixes,
raw identifiers, EOF and generated Unicode inputs with the frozen S0 oracle.

`ReaderAnalysisKey` includes content, full language mode, Reader version and explicit
plain/syntax/custom phase. Loader analyses can share keys; manually built documents
get independent custom identities. Empty highlights do not imply plain text.

The application delegate owns the store and injects it into main/secondary Reader,
Context and Settings. Standalone public Reader construction gets an isolated store.
Reading Set has no identifier-query consumer and is unchanged. The store registers
subscriptions before awaiting, coalesces shared workers and protects publication by
generation and subscription. One cancellation does not cancel another subscriber.

The idle cache is limited to 32 MiB and 128 entries. Active entries may exceed these
soft limits; statistics expose active bytes and excess. Estimates include retained
source storage conservatively even when COW-shared. Closing the last subscriber
cancels pending work; completed cache entries contain bytes/index arrays, not Reader
or ReaderDocument objects. A weak-reference test verifies actual object release.

Reader clicks while building save the latest intent. Completion checks document
analysis and view generation before publishing. Clearing intent, native selection,
file switching and teardown prevent stale selection updates. Main/secondary status
appears independently from focus/syntax notices; Context/Settings expose localized
help. Pending is never treated as a prepared empty result.

All production synchronous identifier calls were removed. The deprecated public
compatibility method builds explicitly; only compatibility/oracle tests call it.
CI now checks this boundary. `CAIRN_READONLY_IDENTIFIER_CACHE=0` disables shared
reuse/coalescing and releases each completed subscription after use; worker-built
prepared queries remain available. This fallback tests cache behavior without
reintroducing a main-thread scan or a second production lexical algorithm.

## Lifecycle fixes found during integration

- Settings now invalidates queued preview work on close and explicitly resumes on
  reopen. A retained closed NSWindow cannot restart subscriptions through layout.
- Main/secondary teardown invalidates pending syntax and reading-position callbacks;
  Context rejects queued model observations after teardown. Text stays available
  for the final session checkpoint.
- Async readiness exposed a native find-indicator exception in an existing navigation
  test: an unattached text view requested an effect with no valid native geometry.
  The original two-test and single-test repros aborted with
  `NSCountableTextLocation compare: ... unmatching type (null)`.
  Calling the zero-length cancellation API did not fix it and was discarded.
  The common ClickTextView entry now requests the effect only for a visible window.
  Visible readers retain the native effect. Both repro tests and the full affected
  regression collection then passed.

## Validation

- Index/shared state/interaction first pass: 21 tests passed.
- Final affected regression collection: 45 tests passed across three targets
  (1 + 33 + 11), with complete summaries. It includes all new tests except the
  separately added object-release check, plus existing click/find/navigation/style
  contracts updated to wait for actual readiness without weakening assertions.
- Native mouse isolation: 1 test passed (0.497 seconds).
- Actual Reader/document release: 1 test passed (0.076 seconds).
- Localization: 795 bilingual keys passed. `git diff --check` passed.
- Debug native workload: all six fixture captures passed; every hot interaction had
  zero identifier scan/build increments. Release results are recorded below. Timings remain diagnostic single samples, not a performance budget.

- Real main-window status: 1 test passed (0.525 seconds). The test blocks the worker
  with an explicit gate, verifies the visible status label and its window geometry,
  shows a Focus notice concurrently, then releases the gate and verifies the label
  disappears. Focus remains available through its independent, transient channel.
  Screenshot: `.build/readonly/s1-status/identifier-building-with-focus-notice.png`.
- Release `all` suite: all six fixture captures passed. Each hot lookup reports zero
  scan/build deltas. `stage-s1-results.json` retains raw diagnostic comparisons and
  hashes; `.build/readonly/s1-release/test-logs/` retains test summaries and the
  original/fixed native navigation repro.

New test count: 26 (6 index, 9 store/identity, 6 interaction/lifetime, 5 host).
CI main expected count is 1,058; original isolation batches remain 2/2/1.

## Measurement boundary

S0's early full-suite driver was subsequently corrected for syntax-arrival and
absent-viewport preconditions, so full-suite footprint differences are not attributed
to the index. A second identifiers-only comparison uses an isolated, fixed S0
worktree at `4fdabe3` with identical fixture hashes. It still exposes a difference:
the candidate pumps the native runloop while awaiting prepared data; S0 stays mostly
synchronous. A controlled baseline pump experiment confirmed the effect for `workload.rs`. Cold draw durations are not stable first-paint
latencies, and neither pair is the S7 repeated performance gate.


The same S0 probe binary ran three times without pumping (peak median 45.56 MiB)
and three times with about 75ms of native runloop processing (peak median 169.14
MiB; post-pump median 168.58 MiB). The S1 sample was 168.28 MiB. Pumping caused
exactly two additional real background draws, two decoration builds and 1,600
ruler-record visits; other work counters were unchanged. This isolates the Rust
sample's roughly 120 MiB difference to harness timing/native work, not index
storage. It does not generalize a memory bound to all inputs and is not the S7
stable-layout gate. Probe source and the original S0 executable were restored;
`stage-s1-footprint-probe.json` records their hashes and raw evidence locations.

The S0 worktree is retained at
`/Users/siancao/.codex/worktrees/readonly-baseline/codeinsight` for S7 alternating
measurements. Do not archive it while the comparison work still needs it.
