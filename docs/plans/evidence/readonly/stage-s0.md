# S0 — reference algorithms and workload capture

Status: S0 complete, with the baseline NOT_RUN items listed below. This stage adds
observations and a runner, not an optimization. S1–S7 acceptance remains open.

## Changes

- Frozen identifier, DisplayMap, fold selection and call ownership references at
  `f5e116d6477fe20ed9bd83b08b82f4a0512594a7`; four deterministic comparison tests.
- Opt-in, thread-safe work counters at actual decoding/scanning, projection,
  paragraph, gutter, storage and region-query sites. Existing counters retain
  their meanings. Counter definitions are in `baseline.md`.
- Deterministic Rust/Python/TypeScript/TSX fixtures, a 9,002-line file and a >1 MiB
  line. Manifest records hashes, language, bytes, logical lines and longest line.
  The generator can also emit 10k/30k/50k/100k inputs outside the checkout.
- Native `--self-test-readonly` and `scripts/run-readonly-workload.sh` support
  identifiers/gutter/projection/reflow/lifetime/all suites, a frozen manifest and
  output directory. Each fixture has a bounded 120-second process deadline.
- Each event captures real draw callbacks, before/after work, selection, occurrence
  count, source size and viewport. PNGs show native cold/Overview rendering.
  Process footprint is sampled every 25 ms; raw samples are retained.
- Runner records source-tree hashes as well as HEAD so a dirty build cannot be
  mistaken for the baseline commit. Timeout output retains the pending scenario
  and completed events. Missing native support is `blocked`, never a pass.

## Verification

- Swift Testing: 4 oracle tests passed (0.117 seconds), complete summary.
- Initial existing main suite: 1,028 tests completed. Five native sheet/pasteboard
  tests failed in the sandbox; all five passed outside it (6.595 seconds).
- Release build succeeded. dsymutil required unsandboxed access.
- Localization: all 793 bilingual keys passed. Shell syntax and `git diff --check`
  passed. Deterministic regeneration and fixture hashes were checked.
- Runner negative checks reject missing app output and uncalibrated
  `--enforce-budgets` rather than reporting success.

## Limits and follow-up

`pass` is a valid baseline capture, not completion of the S1–S7 functional/work
budgets. Timings are one diagnostic sample per event, not p50/p95, first-paint or
stable-layout latency. S7 owns the alternating 30-sample dedicated measurement.
Native rendering evidence does not cover VoiceOver, application watcher/session
routing or retained-object release. Those remain explicit S7 checks.

The 1 MiB line exposes substantial existing layout cost. A preliminary run
completed; a later run overlapping compilation exceeded 120 seconds during
font-only reflow. Both raw records remain available. That intermediate run also
revealed an inherited MainActor annotation on the timer callback; the callback
now has an explicit Sendable function type, matching the existing ligature probe.
No product workaround or timeout increase was introduced.

The initial CI attempt's later panel/mouse batches overlapped runner development
and hit a now-fixed optional-count compile error. They are not labelled historical
product regressions. Fresh isolated checks passed: panels 2 tests in 3.736 seconds,
mouse 1 test in 0.417 seconds; both emitted complete summaries.

## Native baseline evidence

- `.build/readonly/s0-verified/result.json`: six fixtures completed, capture status
  PASS, with no actor-isolation warnings. `stage-s0-results.json` retains the
  result hash and selected raw work deltas. This is diagnostic data, not a timing
  gate. Reflow-specific follow-up passed all six fixture captures in
  `.build/readonly/s0-reflow/` and supersedes its
  syntax-arrival and absent-viewport scenarios.
- `.build/readonly/s0-verified/environment.json`: Mac15,6 / Apple M3 Pro, AC power,
  full battery. Each report records OS, actual resolved font, viewport and memory.
- Native screenshots: `workload.rs.cold-display.png` and
  `workload.rs.overview.png` under that directory (and each other fixture).
- Rust warm identifier activation (10 repetitions): 251,800 scanned source bytes.
  Stable scrolling: 18,400 global gutter-record visits. Color-only update:
  one full storage replacement. These counts establish the work to eliminate.
- Long-line baseline: 12.4 seconds cold display, 39.3 seconds stable-scroll sequence,
  sampled peak physical footprint 2,308,820,016 bytes. A single run is diagnostic;
  the native TextKit cost remains part of S6/S8 decision evidence.
- Python hover had no visible handle hit and is explicitly NOT_RUN; Rust/TS/TSX
  exercised hover. The long-line fixture has no fold regions, recorded NOT_RUN.
- The refined absent-viewport scenario observed that TextKit creates a viewport
  even before mounting the zero-size scroll view. It therefore records NOT_RUN
  with `hadPreviousViewport=true`; this does not claim coverage of L05's absent
  viewport branch. S6 must supply a deterministic check for that strategy branch.

Run again with `bash scripts/run-readonly-workload.sh --app-bin
.build/release/codeinsight-app --suite all --manifest fixtures/readonly/manifest.json
--out .build/readonly/<run-name>`. Use a dedicated run without concurrent builds
for timing comparisons. The metadata hashes identify each captured source state.
