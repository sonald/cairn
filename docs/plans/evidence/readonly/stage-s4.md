# S4 — paint, typography and projection updates

Status: complete. Changes are classified using the existing typography/environment
key and explicit geometry changes; no additional plan type was necessary.

## Behavior

Pure color/opacity changes refresh rendering attributes, gutter paint and attachment
appearance without rebuilding projection, replacing storage characters, configuring
the gutter or capturing/restoring the viewport. Font/ligature/environment and mixed
font+color+wrap changes take one typography transaction and preserve characters.
Identical settings return before application work.

Same-content syntax updates compare canonical visible fold geometry, not only IDs
or array order. Unchanged geometry retains the map/storage; relevant metric changes
update typography, summary changes update attachment attributes, and actual fold
body changes construct a new projection. Source and language guards remain.

RenderingAttributesCoordinator caches pure range calculations (at most 128 ranges /
8,192 runs), never NSTextLayoutFragment objects. Every framework validator callback
still submits base foreground and current attributes, including empty-syntax text;
cache hits cannot skip the TextKit protocol. Scroll revalidation supplies current
colors to newly visible text.

Attachments preserve object identity when kind/summary remain unchanged. Font
changes update their font/features and measured dimensions; a small standard-library
lock provides a coherent size snapshot to the SDK's nonisolated geometry callback.
Appearance/provider state remains MainActor-owned. Existing and later providers
read current appearance. Summary changes can create a replacement attachment as an
attribute change, without replacing text characters.

## Verification and corrections

- Eight new native tests passed, including a 16-case font/color/wrap/gutter matrix,
  font-then-color vs combined updates, empty-syntax colors, validator cache replay,
  early/late attachment providers, font environment changes, automatic appearance
  raster changes and reordered-fold metadata.
- The ReaderCore regression batch passed 190 tests; application font propagation
  passed three tests. ReaderUI originally found one attachment-identity regression.
  It was fixed by updating metrics on the retained attachment; the full ReaderUI
  batch then passed all 32 tests, and the failing copy/ligature test passed directly.
- The new test fixture's NSWindow release policy was corrected after a combined-run
  crash; its six-test run then passed. No product check was weakened for that issue.
- Release and localization (795 keys) passed. CI main expected count is 1,085;
  original isolated batches remain 2/2/1. `git diff --check` passed.

Native PNG evidence is in `.build/readonly/s4-native/` (light/dark attachment rasters
and the dark Reader). Raw Release results and completed summaries are under
`.build/readonly/s4-release/`; `stage-s4-results.json` retains the measured deltas.
All six fixed input captures passed the new color/font/combined/syntax work gates.

## Honest work accounting

`attributeUpdatedUTF16Units` retains its backing-storage typography/paragraph meaning.
The new `renderingAttributeUpdatedUTF16Units` counts actual TextKit rendering writes,
including overlapping base/style passes. Color-only updates have zero projection,
character replacement and application full-layout deltas, but nonzero paint work.
The 1 MiB single-line case still submitted 1,500,007 rendering UTF-16 units in its
color event. That native paragraph limitation is not hidden by the zero replacement
counter and remains input for S6/S8. Timings are diagnostic, not the S7 repeated gate.
