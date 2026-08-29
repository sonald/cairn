# S4 Reading Height availability evidence

Date: 2026-08-29

## RED / GREEN

- RED: `swift test --disable-sandbox --filter MainWindowControllerTests`
  recorded four Testing issues showing the control remained enabled for no
  project, indexing, Reading Set, and a missing file. SwiftPM incorrectly
  returned exit 0 for that failed Swift Testing run, so the visible issues were
  treated as authoritative FAIL evidence.
- GREEN: the same command completed with no Testing issues after the fix.
- `swift test --disable-sandbox --filter
  'MainWindowControllerTests|ReaderUITests'` completed with exit 0 and no issues.
  The run included the existing Reading Height, fold, Focus, hidden-find,
  selection/copy, ruler, occurrence, and navigation-unfold contracts.

## AppKit state replay

The new `MainWindowControllerTests` case drives the existing
`ReaderViewController` through one continuous sequence:

| State | Hidden | Enabled | Result |
|---|---:|---:|---|
| No project | false | false | PASS |
| Indexing placeholder | false | false | PASS |
| File first paint | false | true | PASS |
| Reading Set | true | false | PASS |
| Switch back to file | false | true | PASS |
| Missing file | false | false | PASS |

## Scope audit

- State is assigned only in the existing empty/indexing, Reading Set, file-load,
  and failure branches.
- No reader enum, store, reducer, shortcut, menu command, production type, or
  dependency was added.
