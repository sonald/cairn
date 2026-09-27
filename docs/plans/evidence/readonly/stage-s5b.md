# S5b — local projection commits

Status: complete.

ProjectionDelta compares folded source intervals, splits unchanged source windows,
and emits reverse-order storage patches. Same-content plans retain distinct UUIDs;
preflight verifies document/analysis/settings identity, lengths, boundaries and
attachments before mutation. A stale target is rejected. Recoverable failures on
the current target use a measured full install; invalid targets retain the screen.
`CAIRN_READONLY_LOCAL_REPLACEMENT=0` exercises that full-install path.

The UI materializes only changed ranges, applies typography to intersecting spans,
and updates affected paragraphs plus join neighbors. Existing attachments survive
moves; actual TextKit fragment providers supply their current location. All text
installation paths suppress mapping/copy/rendering callbacks during mutation.
The selected logical fold state and public display map are published together.

Placeholder lookups use display-range binary search. The new
`projectionPlaceholderRecordsVisited` counts both full enumerations and bounded
comparisons/hits, so decoded-byte improvements cannot hide P×F metadata scans.
Whole-document fold metadata refresh still occurs at explicit fold transitions.
A single huge paragraph can still require large native layout/paragraph work.

Selections retain every source endpoint and affinity, including several ranges
that AppKit normalizes into one hidden placeholder. Explicit native gestures clear
latent state. An exact half-open endpoint at a fold body's start excludes the chip.
The public AppKit selection delegate plus one native Shift command restores a
reverse single-selection anchor; ordinary range setters lose that anchor. Multiple
ranges retain native setter behavior, verified against an unchanged reference.

Copy and drag's plain-text export concatenate the original source ranges, including
hidden source selected by a placeholder. They never export U+FFFC. Initial tests
incorrectly used default NSTextView multi-copy as their byte oracle. Independent
probes showed it inserts LF at visual rows, including soft wraps. Design §8.5/P04
requires source-slice concatenation, so the test now checks fixed original bytes
before/after folding and after changing width. Production copy was not changed to
emulate layout-dependent text. Probe results are retained in
`stage-s5b-native-probes.json`, including rejected restoration experiments.

The focused projection batch passed 28 tests (22 new plus six prior/oracle checks).
The full regression exposed an existing independent selection/viewport-anchor test:
after a partial shrink, TextKit's old viewport could lie beyond the new extent.
The shared source restore now relocates lazy viewport layout to the target before
requesting its line rectangle. The unchanged regression and 28 projection tests
then passed together (29 tests).
The final ReaderCore regression passed 218 tests; ReaderUI passed 32, and the
isolated mouse batch passed one. Release compilation and all fixed native captures
completed. CI main expected count is 1,112; original isolated batches remain 2/2/1.
Raw logs use `.build/readonly/s5b-*`.

The native runner now rejects a failed toggle and labels absent visible handles
NOT_RUN. The frozen Python fixture has only ineligible short folds; its previous
no-op projection events were not valid folding proof. A deterministic 600-line
Python supplement exercised 100 real folds, with input recipe/hash in the results.
The 1 MiB fixture has no folds; its cold display is measured, folding is NOT_RUN.

Rust/TypeScript/TSX small collapse events each decoded zero source bytes, replaced
one range, and updated one attribute unit/paragraph. The 50,000-line fixture's small
collapse also used one patch; overview/full used 10,000 patches. Overview placeholder
visits were 287,236, not an F×P full scan. All local transitions made zero full text
replacements. Native timings are single-run diagnostics, not S7 p50/p95 evidence.

The final Release captures, PNGs and raw counters are in `s5b-release-final`,
`s5b-50000-final` and `s5b-python-native` under `.build/readonly/`. The Python overview
PNG was inspected. The explicit rollback capture `s5b-fallback` passed, reporting
one full replacement per fold/preset event. `stage-s5b-results.json` retains all
work deltas and the supplementary fixture recipe.
