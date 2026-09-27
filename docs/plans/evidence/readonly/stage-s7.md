# S7 — integrated readonly acceptance

Status: **development verification complete at the user-adjusted scope**. This is not full release approval.

The user explicitly requested restrained testing for this early-stage project.
Further sampling and the unrun extended resource observation were stopped.
Existing correctness/native evidence is retained; no new full test run is needed
without a relevant code change or new failure.

## Verified implementation and CI

The current product includes S0–S6 and three small integration repairs:

- AppDelegate observes both local and distributed CoreText font notifications,
  using the same existing refresh handler and explicit teardown.
- `firstVisibleByteOffset` reads existing viewport state without forcing layout.
  Explicit restore/navigation owns its layout before calibrating the source anchor.
  No extent cache, height clamp or extra geometry scan was introduced.
- Identifier subscription/build starts independently of synchronous AppKit drawing;
  one guarded MainActor publication accepts the result and its subscription token.

`CODEX_SANDBOX=1 bash scripts/ci.sh` completed with **1,138 tests**:
1,131 main + 2 bookmark + 2 panel + 1 mouse + 1 process-font + 1 distributed-font.
All summaries were complete. The 795 bilingual-key checks, architecture gates,
exact/diff/reading/projector/fold native self-tests and existing Release fold
workload also passed. Fold timing has `budgetsEnforced=false`; it is not a newly
calibrated timing budget. The Exact self-test uses an explicitly named fake
provider; the operator workflow below separately used real rust-analyzer.

[Verified source/log hashes](stage-s7-ci.json) bind this result to the final product changes.
Raw CI: `.build/readonly/s7-ci-scheduling.log`; preserved batches:
`.build/readonly/s7-scheduling-test-logs/`. The [requirement matrix](stage-s7-requirements.md)
distinguishes native, model, AX, copy and performance evidence.

## Native surfaces and actual workflow

[Seventeen host captures](stage-s7-hosts.json) cover main, secondary, Context,
Settings, Reading Set, plain text, and frozen-card recreation. Each requires actual
draw-count growth, nonblank pixels, independent expected source hashes and native
private-pasteboard export. Representative PNGs are retained in `native-surfaces/`.
Frozen offscreen captures do not claim an onscreen restart; the following separate
operator workflow proves that boundary.

The ad-hoc local `.build/readonly/s7-operator-bundle/Cairn.app` uses isolated bundle
identifier `dev.cairn.readonly-acceptance`; bundle/signature checks passed. Native
menus/Find/symbol picker/relation rows/version picker completed:

1. Open Rust project; real rust-analyzer ready in Safe mode, build scripts/proc
   macros disabled. Find two `leaf_target` occurrences, navigate its definition
   and verified caller, then focus `caller_one`.
2. Select historical `9aef36e`: helper changes +20→+10. Verify and freeze its two
   callers, then quit normally.
3. Change only the generated worktree to +101/+202/+999 and launch a new process.
   Frozen callers still contain +1/+2 and historical provenance. Historical helper
   remains +10; selecting worktree shows +999 and the changed caller values.
4. Compare persisted sessions: captured source/content IDs/byte ranges/revisions
   and frozen inspector evidence are unchanged; quit the test app.

[Operator record](stage-s7-operator.json) preserves exact commits and identities.
Native AX observations/screenshots are inline in the task; fixture/session records
are `.build/readonly/s7-operator/`. CUA connection latency/transient AX failures are
not app-performance evidence; successful actions were verified from fresh state.
The existing `run-session-acceptance.sh` also passed a separate two-process
normal-termination/viewport/caret/trail/Back-Forward check
(`.build/readonly/s7-session-scheduling.log`), using the final scheduling candidate.
The historical/frozen operator captures precede the S7 repairs; final CI and
targeted native regressions validate their affected entry points.

## Additional integration checks and discovered defects

Three native tests close middle/end deferred syntax, simultaneous 500/790pt
windows with shared derived data, and same-body summary geometry. Independent
source-row drift stays <=2pt; source/selection/affinity/copy remain unchanged.
Summary width changes 132→244pt with a new provider and actual drawing. These
checks passed individually and in final CI. The test host resolves English; the
packaged operator app uses Chinese. An attempted nonpersistent language override
changed preferred languages but not the test host bundle's language, so it is not
Chinese geometry proof. Live language switching is not an existing product feature.

The font review found a missing distributed subscription from `3cd489f5`
(2026-09-22). Original synthetic process-only fonts keep one PostScript name while
changing actual Reader font URL/hmtx/advance (6.5→11.7pt), preserving source,
selection, native drawing and copy. A fresh process separately proves distributed
routing; no session/persistent font installation is claimed. See
[font evidence](stage-s7-font-registration.json) and retained rectangle-glyph PNGs.
CI isolates both font tests so a delayed unregister cannot satisfy the route test.

One intermediate CI failed W17's lower clip-origin bound. Twenty isolated
repetitions and a full-context trace then passed, so the original numeric failure
was not reconstructed. The trace did prove its helper returned before native
`didEndLiveScroll`; it now waits for both that event and the target position,
without weakening the bounds assertions.

Stronger sequencing exposed a separate reproducible query side effect: on a real
620pt window, completed scrolling had source byte 312 at y=320, frame height 8539.
The getter's forced viewport layout shrank native height to 394 and clamped source/y
to zero, with no application restore pending. Natural paint/run-loop turns did not
cause it; the legacy reflow flag also reproduced it. The forced query layout dates
to `b2e10062` (2026-07-20). Making the getter pure required moving its previously
hidden synchronization into the existing restore write path. Final targeted tests
**6/6** and ReaderCore **233/233** passed before the complete CI above.
[Scroll-query evidence](stage-s7-scroll-query.json) retains all failures, traces and
intermediate experiments; they were not silently discarded.

## Rollback checks

All four rollback paths retain their functional evidence. Fresh Release processes
with `CAIRN_READONLY_IDENTIFIER_CACHE=0` and `CAIRN_READONLY_DECORATION_CACHE=0`
each passed all six fixed fixtures (**12/12**). [Records](stage-s7-rollback.json)
retain binary/source hashes and actual counters; decoration fallback has the
expected nonzero preparation/global visits. Identifier fallback retains asynchronous
prepared queries while disabling cache/coalescing. S5b's valid-fold supplemental
Python capture verifies `CAIRN_READONLY_LOCAL_REPLACEMENT=0`; S6's six captures and
injected missing-viewport check verify `CAIRN_READONLY_REFLOW=0`. The six identifier-cache-off fixtures were also rechecked after the final
scheduling change. Other flags retain their earlier captures and final CI checks.

## Matched measurement generations

Baseline: `4fdabe38eb364f9e9d7aa6507aa445fb636ad485` (S0).
Current candidate: `a99f10b2ec09c27c2610f3a651a638c070075470` (r5), a local
frozen measurement branch based on S6 plus the three product repairs above.
Root-only host observation accessors are not part of this binary.
`scripts/readonly-matched/` seals source/overlay/binary/resource hashes, uses fixed
Aqua/light appearance, records canonical input setup, checks fresh geometry and
preserves failures. The first draw marker is a native draw callback, not compositor
delivery.

S6/r3 (`2c1bd4800f7ea68777ca2785ae8c318048720fe2`) is **superseded and incomplete**:
134 raw processes, 11 full pairs for each fixture plus one extra long-line pair.
It stopped at a complete fixture pair for correctness investigation. Its partial
report is `.build/readonly/s7-matched-r3/partial-generation-report.json`; the last
raw baseline completed but was not registered in the paused collector's journal.
No parent completion time was invented. Earlier r1/r2 protocol-development failures
also remain excluded.

R4 (`62644e8c701185ffb9d7b6790563fd143877c58e`) completed 30 pairs per fixture.
Its [versioned report and raw archive](stage-s7-performance-r4.md) retain cold-tail
warnings; the scheduling follow-up below was investigated before final acceptance.
R3/r4 samples are never merged into the current candidate's results.

R5 original collection completed 30 groups at `.build/readonly/s7-matched-r5`.
Power history revealed a battery-to-AC transition during pair007's long-line
candidate; the following baseline ran on AC. All original data is retained.
The fixed-AC population uses common complete groups008–029 and the completed
registered pairs from `.build/readonly/s7-matched-r5-ac-supplement`. The population
rule was fixed before group018 completed, independent of performance outcomes.

The user then requested restraint in performance testing. Further dispatch was
stopped without adding runs to fill the original quota. Final accounting uses
**29 paired observations each for Rust and the long-line input, 30 each for
Python/TypeScript/TSX/large**: 178 pairs / 356 registered processes. The last
unregistered long-line raw results remain separate and do not raise those counts.
Battery/transition samples remain separate. This is early-development evidence,
not a claim that every original 30-sample release gate was satisfied.

S0 Python's known fresh-anchor failures remain failures; source-classified
high-cost precision limits remain explicit NOT_RUN. Operation/draw and stable
metrics are reported separately. Cold and peak-memory comparisons use the stated qualified population and retain
limitations; no additional campaign is scheduled.

The [final performance report](stage-s7-performance.md) contains actual n and
all retained metrics. Hot queries and pure colors improve substantially; ordinary
cold readiness improves while first draw/large-input cold costs are not uniformly
better. Twelve correlated cold-p95 warnings remain explicit. No further diagnostic
campaign is scheduled under the user's early-development testing guidance.

## Resource verification and final review

A separate read-only review checked the three S7 product repairs, their callers
and regression tests. It found no confirmed correctness defect; it ran no build
or native process while the matched collector owned the environment.

The existing lifetime workload performs one A→B→A/refresh/close sequence and
fresh-process matched peaks do not prove extended same-process resource release.
A twenty-switch observation overlay was prepared but **not built or run**. It was
cancelled after the user's testing-scope correction; drafts remain under
`.build/readonly/s7-lifetime-draft-tools/` and unbuilt scratch directories. It is
not product code, a committed testing framework, or acceptance evidence. Existing
cancellation/weak-reference/bounded-cache regressions remain valid within their
stated scope. Extended resource observation is deferred to a concrete leak report
or release need.

## Remaining acceptance boundary

Actual VoiceOver navigation requires the pending confirmation to temporarily
change the OS accessibility setting and restore it. AX getters, CUA accessibility
inspection and native copy/mouse tests do not substitute for VoiceOver operation.
The user-adjusted development delivery does not claim full release acceptance.
Actual VoiceOver remains NOT_RUN; enabling it still needs the earlier requested
OS-setting authorization. No further test expansion is part of this delivery. The independent [S8 investigation](stage-s8.md) is complete and defers
adoption because the corrected chunking prototype changes source-position geometry.

## Cold subscription scheduling follow-up

The complete r4 report retains its cold-tail regressions. A separate instrumented
Release diagnostic explains one avoidable serialization: the view's inherited
MainActor task did not subscribe until synchronous display/draw returned. For the
1 MiB input, request was at 4.6ms, task start at 14.63s, actual builder only 58.9ms,
then publication waited another 1.94s. This cannot explain r4's first-draw regression,
because the index had not started at that point.

The per-view task now subscribes and awaits the shared store detached, keeping its
Reader weak. Only a current generation/analysis identity can take ownership of the
token and index in the final MainActor publication. Cancellation, stale results,
errors and a vanished Reader release that token; store entry checks reject already
cancelled callers before starting work. No new coordinator type was introduced.
Three deterministic regressions check start before MainActor yields, pre-cancelled
subscription, and dropping a Reader with an unpublished token.

The same diagnostic now starts long-line construction at 3.5ms and finishes by
61ms, before display returns at about 5.17s. Publication follows synchronous drawing
by 9ms, and native turns fall 6→4. Single-run total stable time only changes
16.654→16.453s, so this is scheduling evidence, not a solved p95 claim. Ordinary
input shows the same overlap. [Raw timelines and source hashes](stage-s7-index-scheduling.json)
retain both runs. Final CI passed as recorded above; the newly frozen r5
measurement uses the actual retained sample counts above. R4 remains intact and separate.

## Current verified scheduling candidate

Complete post-scheduling CI passed **1,138 tests** (1,131 main plus the existing
seven isolated tests), 795 bilingual keys, architecture/native self-tests and the
Release fold workload. Latest packaged two-process restoration and all six
identifier-cache-off native fixtures also pass. Current source/log/session hashes
are in [CI](stage-s7-ci.json), [session](stage-s7-session.json) and
[rollback](stage-s7-rollback.json); their earlier r4 records remain separately saved.

The current frozen candidate is `a99f10b2ec09c27c2610f3a651a638c070075470` (r5),
with three product files changed from S6. Its protocol/harness fingerprints match
the S0 baseline. The [complete r4 report](stage-s7-performance-r4.md) and raw archive
retain their cold warnings; the new generation is reported independently at the user-adjusted scope. No further product/test edits are planned during collection.
