# S3 frozen Reading Set evidence

Date: 2026-08-29

## RED / GREEN

- RED: the targeted Reading Set / Relations run executed 48 tests and reported
  14 expected copy failures against the old Relations CTA, Trail CTA, Chinese
  excerpt count/actions, and shorter empty state. Capture order, 50-excerpt cap,
  source drift, skipped reasons, and restore tests remained green.
- GREEN: `swift test --disable-sandbox --filter
  'ReadingSetViewTests|RelationNavigationTests|ReadingSetTests'` passed 48 / 48.
- `swift test --disable-sandbox --filter
  appModelBookmarkEligibilityNamesUnsupportedSurfaces` passed 1 / 1 and preserves
  the `Reading Sets cannot be bookmarked.` eligibility boundary.

## Product copy and AX

- Relations: `Freeze Results`; AX `Freeze Results as Reading Set`; tooltip
  `Freeze up to 50 published locations as a Reading Set`.
- Trail: `Freeze Path as Reading Set` for both title and AX label.
- Reading Set: `N excerpts · frozen at capture`.
- Card actions: `Open File`, `Expand Context`, `View Evidence`; the AppKit test
  reads the same three values through button AX labels.
- Empty state: `No excerpts could be frozen. Review the skipped reasons above.`
- A source search confirms `ReadingSetView.swift` contains no remaining Han copy.

## Visual evidence

- The five-segment Light / Dark / SI Classic offscreen `cacheDisplay` captures
  rendered their nested scroll layers as black and were discarded.
- A second attempt using the repository's real-window
  `CGWindowListCreateImage` route failed with `NSCocoaErrorDomain 512` under the
  current host permissions. The three-theme screenshot item is **BLOCKED by the
  capture environment** and remains a V0 live-bundle task; no invalid image is
  committed as evidence.

## Scope audit

- Excerpt capture, producer/path order, 50 cap, skipped-reason aggregation,
  source drift gates, tab/session codec, folding, Focus, and bookmarks are unchanged.
- No localization framework, dependency, production type, or state source was added.
