# S6 — shared reflow ownership and explicit layout cost

Status: complete.

ReaderDocument records immutable byte/line/span/fold cost, derived from its existing
line table. The existing 8,000-line and 64 KiB source-line limits are centralized in
an injectable ReaderReflowPolicy. They are inherited conservative thresholds,
not newly calibrated latency budgets. Projection length stays with the current
projection/storage. FileTier, parser eligibility and preview/security rules are
unchanged.

Reflow reuses existing state and generation fields instead of adding a coordinator
type. Width, settings and font changes share their earliest source anchor. Merged
width tasks use the latest compatible generation and always drain queue ownership;
a superseding font update cannot strand the scheduled flag. Width capture uses
the old width supplied by AppKit, because the clip can already have its new width
while glyph geometry still uses the old one. Width hooks also respect the text
commit barrier. Corrections verify content, projection, surface, typography,
font-environment and target-width identity, and actual layout callbacks can drain
bounded pending correction work.

Actual wheel/live-scroll input cancels recovery synchronously; ordinary TextKit
bounds changes only refresh visible rendering. Cancellation clears stale width
captures. Terminal host teardown cancels pending reflow and identifier work while
retaining text/selection for the final reading-position checkpoint. Identifier
refresh itself does not incorrectly cancel reflow.

High-cost documents skip the initial expensive caret probe, not merely the later
restore. They retain horizontal state without inventing a source/pixel anchor.
Missing old viewports take an estimated native extent path rather than full
synchronous enumeration. Zero-sized surfaces defer before consuming the pending
container-width transition, so mounting later still computes reachable extent.
Unavailable precision is reported with a reason and null anchor error.

`CAIRN_READONLY_REFLOW=0` restores the former capture/precision/extent policy;
correctness guards, explicit input provenance and lifecycle cancellation remain.
The CLI records source cost, projected UTF-16 length and restore limitations.

Validation notes so far:

- Initial test compilation required explicit CGFloat finite-limit literals.
- A manually zeroed attached clip was immediately retiled by AppKit. The stronger
  test now uses a genuinely unmounted zero-sized scroll surface, then mounts it
  and verifies actual horizontal extent/scroll reachability.
- Native wheel dispatch is asynchronous: an independent probe showed immediate
  y=0 and actual y=320 after native turns. Tests assert immediate cancellation,
  then wait for the observed clamped target, not a fixed sleep or synthetic bounds.
- Two old tests assumed all bounds changes were user input or that an oversized
  paragraph always reported precision. Edge scrolling now uses actual wheel input
  with its original position assertion. The >64 KiB trailing-row case still checks
  native rows, and additionally requires zero caret captures and explicit limited
  precision; the ordinary Unicode case still requires <=1 pt anchor error.
- A genuine width→font→width test first lost its source anchor. Refreshing the
  merged generation alone left 85.8 pt drift; reusing the width anchor reduced it
  to one 28.6 pt row. Restoring the pre-change horizontal probe then passed the
  original <=2 pt assertion. A subsequent font change also preserves that anchor.

Completed regression and native results follow below.

Reading Set now separates paint from typography/wrap/environment changes, skips
paint-only anchor capture/layout scheduling, and reuses source/font-dependent
gutter width. An existing native test verifies actual color/foreground changes
with no pending layout/remeasurement and unchanged source/selection/copy/anchor.
Terminal teardown also stops its queued layout and late bounds-publication Tasks,
removes observers/monitors, and preserves frozen content and the final offset.
The retained-closed-host test proves no subsequent measurement or scroll callback.

Completed so far: ReaderCore 230 tests, ReaderUI 32 plus isolated mouse 1; native
App host batch 15 tests, with 4 Core and 8 model checks reported separately. The
final Reading Set close/paint tests passed 2, and the missing-viewport case passed
under both policies: optimized=zero full enumeration, explicit rollback=one.

Ten Release captures passed work gates: six frozen fixtures and 10k/30k/50k/100k
line fixtures. High-cost font/mixed reflow performed zero synchronous caret
captures and zero application full-extent enumerations. The 1,050,017-byte fixture
still took about 14.5s for font-only operation+draw and peaked near 1.35 GB in this
single run. No stable-layout precision or statistically reliable speedup is claimed
for that paragraph; it remains S7/S8 input. Naturally absent old viewports remain
NOT_RUN in the CLI when TextKit creates one, while the injected-nil native branch
is explicitly tested in both modes. Raw evidence is `.build/readonly/s6-*`.

The final Release rollback run passed all six captures with the legacy cost policy,
and the optimized/legacy missing-old-viewport native test passed both expected
branches. The 100k-line cold PNG was inspected. `stage-s6-results.json` retains
source identities, native work deltas, layout/capture limitations and rollback
results. Full S7 integration, repeated matched samples and operator workflow
acceptance remain separate; S6 capture PASS does not claim those are complete.
CI main expected count is 1,124; original isolated batches remain 2/2/1.
