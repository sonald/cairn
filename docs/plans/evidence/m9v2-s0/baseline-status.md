# M9 S0 baseline status (2026-08-06)

## Reproducible environment

- repository: this worktree; the M9 change set is uncommitted;
- corpus preflight: `bash scripts/provision-corpora.sh --check` passed;
  tokio `be8ee45` (717 Rust files), ripgrep `4649aa9` (98 Rust files);
- rust-analyzer: `0.0.0 (12c3381f0b 2026-07-26)`;
- automated AppKit geometry: `codeinsight-app --self-test` passed after the
  M9 changes, including 1600×1000 content geometry and sidebar 65/35 checks.

## What was measured before UI replay

The offscreen base self-test measured a 1600×1000 content view with a 702pt
sidebar split area: Files 457pt and Outline 245pt (within the existing 65/35
tolerance). It also confirms both placeholders remain centered and the manual
divider survives placeholder refresh. This is enough to retain the fixed
default; no content-aware divider adjustment was added.

`--self-test-reading` additionally exercised a real `NSWindow`/`NSScrollView`
route: programmatic navigation selects the native primary range, a viewport
follow callback is blocked during that navigation, and posting the actual
`NSScrollView.didLiveScrollNotification` releases the arbitration. The three
new checks were true; the full reading self-test finished with exit 0.

## Live UI evidence

The unlocked desktop replay used the fresh `.build/m9-ui-app/Cairn.app` bundle
on tokio `src/sync/mutex.rs`. Light, Dark, and SI Classic were selected through
Settings and rendered in the actual reader; Files, Outline, Reader, Context,
and the exact-status footer remained readable without overlap. The evidence is
kept in [ui-replay.md](ui-replay.md) and `ui/`.

The host display could render the wide window and a compact resized window, but
not a full 1600×1000 on-screen screenshot. That exact geometry remains covered
by the real `NSWindow` self-test above, not inferred from the screenshot.

Relations' panel and Callers / Calls / Implements / References controls were
visible, but its rows are deliberately **BLOCKED**: the live status says
`deps unavailable (offline)`. No empty state was treated as a relationship
result.
