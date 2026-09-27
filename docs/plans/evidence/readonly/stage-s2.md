# S2 — gutter data lifecycle

Status: complete. Prepared gutter data is consumed by both native drawing and hit testing.

## Changes

Reused the existing visible-fold and declaration caches; added five per-view fields
for rendered regions, source-line fold lookup and projected diff/bookmark summaries.
No new domain type or permanent duplicate FoldID dictionary was needed. S3 will
supply shared static topology queries.

Document/syntax/projection changes refresh fold maps and marker summaries. Diff and
bookmark changes refresh only their own summaries, and identical values do not
rebuild them. Settings change geometry/appearance without invalidating source data.
Clear removes all prepared data. Drawing and hover now share the same source-line
priority and the existing first-visual-row geometry. Accessibility reads the same
bookmark summaries.

`CAIRN_READONLY_DECORATION_CACHE=0` restores preparation on draw/hit-test. It preserves
markers and reports the actual work instead of disabling counters. The ordinary
runner enforces zero decoration-build and global-record-visit deltas during stable
scroll and hover.

Integration also avoids starting an identifier worker after its Reader task was
already cancelled before registration. The existing delayed-syntax teardown test
now asserts zero builds, not only zero surviving subscriptions.

## Verification

- 9 gutter/marker tests passed in 0.287 seconds, including five new tests for native
  draw/hover work, marker revisions, source replacement, stable scroll and fallback.
- Delayed syntax teardown: 1 test passed in 1.651 seconds.
- Existing native geometry/provider checks: 6 tests passed in 2.692 seconds, covering
  first visual rows, scrolled-out first rows, wrapped fold hit testing, Python gutter,
  and attachment-provider accessibility.
- Release build succeeded; localization (795 bilingual keys), shell syntax and
  `git diff --check` passed. Main CI expected count is 1,063; isolation remains 2/2/1.

Release capture ran four fixed language fixtures and a generated 50,000-line Rust
file (50,001 logical lines including terminal EOF, 10,000 fold regions). Every
stable-scroll and hover event had `decorationBuildCount=0` and
`drawGlobalRecordVisits=0` deltas. The large case recorded eight actual hover hits.
Python's short-body fixture still has no visible handle hit and reports NOT_RUN
for that hit condition, as in S0; the separate Python native gutter test passed.

Artifacts:

- `.build/readonly/s2-release/result.json`, language captures and cold native PNGs.
- `.build/readonly/s2-50000/result.json`, including actual input hash and work deltas.
- `.build/readonly/s2-release/test-logs/` for completed summaries.
- `stage-s2-results.json` for the compact checked-in results.

Generate the large valid function fixture with
`python3 scripts/generate-readonly-fixtures.py --scales --out .build/readonly-scales`.
The default six frozen fixture contents are unchanged. These captures establish
functional/work-count gates; they do not claim the S7 repeated latency budget.
