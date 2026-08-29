# S2 session-scoped Reading Trail evidence

Date: 2026-08-29

## RED / GREEN

- RED: `swift test --disable-sandbox --filter RelationNavigationTests` ran 34
  tests and failed only the new Trail copy test against the old empty text,
  accessibility value, and `⑂` button titles.
- GREEN: the same command passed 34 / 34 after changing only
  `ReadingTrailView` copy and the corresponding existing test file.
- The new test covers empty, linear, one branch point, and two branch points.
  It locks `Trail Details`, `Branches · 1`, `Branches · 2`, the existing tooltip,
  and the session-only empty-state accessibility value.
- The existing branch/restore test still proves that restoring A after creating
  sibling B leaves both recorded edges intact.

## AppKit evidence

- `s2-trail-900x600.png` is a real `MainWindowController` render with one branch
  point. Visual inspection confirms the readable `Branches · 1` button does not
  overlap or truncate the cause-aware breadcrumb at the minimum window size.
- The existing AX label remains `Show Reading Trail branches`; the tooltip remains
  `Show the semantic trail and its branches (⌥⌘T)`.
- The 1280 x 820 offscreen `cacheDisplay` attempt repeatedly produced unpainted
  black layer regions after resize, even after forcing layout and display. The
  invalid image was discarded. This screenshot is **BLOCKED by the test capture
  harness** and must be replaced by a live-bundle screen capture in V0.

## Scope audit

- `ReadingTrail`, `SessionCodec`, `AppModel`, and persistence are unchanged.
- No production type, dependency, state source, or feature flag was added.
