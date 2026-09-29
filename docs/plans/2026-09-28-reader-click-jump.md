# Reader click / navigation viewport regression

## Reproduction and cause

The supplied recording shows jumps in a Python reader with wrapping enabled. The installed `/Applications/Cairn.app` executable was built at 14:05 on September 28; the checkout was at `efcb225` (19:14). Testing this checkout is not proof of replaying the installed app.

A self-contained native AppKit regression reproduces a related jump through the production window controller: open a 405-line Rust document with long wrapped comments, navigate between distant symbols, then alternate a symbol with a Context candidate and whitespace without a candidate. Track the same source character relative to the clip's top, rather than comparing scroll coordinates alone.

Before the fix, the anchor moved from 90 pt to 220.67 pt (130.67 pt drift). Activation itself did not move it; the subsequent observed window render did. `render()` resends bookmark and diff markers even when unchanged. Their setters skipped rebuilding marker data but still called `configureGutter`, which retiled and reconfigured wrapping/viewport layout.

Both setters now return for equivalent marker contents. Real changes, including removal, still take the existing update path. Initial mounting, document changes, folding and settings changes already configure the gutter separately. No new scrolling correction or state type was added.

## Validation

- **PASS**: the same regression after the fix, measured drift under 0.5 pt (2 pt assertion tolerance).
- **PASS**: 14 focused tests with completed summaries (3 ReaderUI, 10 ReaderCore, 1 App). Covers bookmarks, diff markers, gutter caches, wrap resize, fold navigation, horizontal reset and the new window regression.
- **PASS**: the regression asserts selected navigation targets remain visible after layout and Context changes do not displace the clicked source character.
- **BLOCKED**: visible replay of the original recording in the rebuilt app; Computer Use reports the Mac is locked. The window regression drives Reader activation and the real Context lookup/render callbacks; it does not drive native mouse tracking. A temporary full-window mouse-tracking probe exited without a test summary, including outside the sandbox; it is not accepted as a pass.
- **PASS**: release app packaging and code-signature verification via `CODEX_SANDBOX=1 CAIRN_LIBGIT2=brew bash scripts/make-app.sh`. Initial sandboxed dSYM generation was denied; the same build completed with normal filesystem permissions. Output: `.build/distribution/Cairn.app` and `.build/distribution/Cairn.zip`; the installed app was not replaced.
- **NOT RUN**: full CI. Focused verification is proportional to the two marker-setter changes; the main CI expected count is updated by one.

Focused command (with the repository-local Swift cache environment used by `scripts/ci.sh`):

```sh
swift test --disable-sandbox --cache-path .build/cache --config-path .build/config \
  --security-path .build/security --manifest-cache local --no-parallel \
  --filter 'contextCandidateChangesPreserveTheReadersVisibleSourceAnchor|ReadonlyGutterTests|bookmarkMarkers|diffGutterStoresMarkers|foldedDiffIsExposed|revealResetsHorizontal|navigationUnfolds|wrapWidthChangeKeepsAnchor|gutterRepaints'
```

Evidence: `evidence/reader-click-jump/before-fix.log` and `evidence/reader-click-jump/focused-tests.log`.

## Follow-up: centered navigation and unlocked native replay

The user clarified that outline navigation should center the selected symbol. Native replay on the rebuilt app confirmed that `_finalize_iteration` was visible but near the top. The shared reveal path now exposes the target character (not an entire potentially wrapped logical line), centers its actual rectangle, and clamps at the document edges. Main-window rendering settles the trail/header layout before navigating; otherwise the first 26pt trail bar changes the viewport after the destination is computed.

The existing regression now asserts centering, including nearby targets and document edges. Its first run failed with a 26pt error; after ordering the trail layout before navigation it passed. The final focused batch completed **18 tests** (3 ReaderUI + 10 ReaderCore + 5 App), adding Markdown/plain-text separation, non-source panel round-trips and trail layout checks. The release bundle was rebuilt at 20:40 and its signature verified.

Native Computer Use replay used an isolated `dev.cairn.ClickJumpQA` bundle with the same compiled changes and the actual `jaz` project. Wrapping was enabled and serif comments disabled. Verified through screenshots and current accessibility state:

- `_finalize_iteration` (line 542), `invoke` (line 866), and `__init__` (line 73) each landed in the vertical center; the matching outline item remained selected.
- Ordinary whitespace clicks and selecting `Config` did not move the top code line; the Context panel opened with the expected definition.
- Eight alternating selections (`README.md`, `config.py`, `LICENSE`, `_agent.py`, `CHANGELOG.md`, `grammar.txt`, `pyproject.toml`, `_agent.py`) showed the expected Markdown/plain-text/source surface, with no observed stale preview or crash.

The user clarified a possible leftover separator after the outline closes for Markdown, and supplied the earlier Desktop recording `录屏2026-09-28 19.17.53.mov`. Its dark-to-light theme transition around 66 seconds visibly leaves dark chrome strips in the older installed app. The Markdown frame around 18 seconds does not establish a persistent old outline divider. These are distinct observations; do not claim they have the same cause. The Mac locked again before interactive theme-transition replay could finish. The separator/theme follow-up remains unverified pending that replay.

### Outline divider follow-up

A real offscreen `SidebarViewController` probe established a separate, repeatable defect: with a 720pt sidebar, hiding Outline left Files at 719pt. The hidden pane no longer painted its old middle boundary, but the native divider still reserved 1pt at the bottom. This occurred in both Dark and SI Classic. Theme layer colors and the old divider location repainted correctly; this does **not** establish that the older recording's broad dark strips have the same cause.

`SidebarViewController` now implements the native `shouldHideDividerAt` delegate method and hides the divider when the Outline surface is hidden. After the fix, Files occupies all 720pt and both the old boundary and bottom edge render as pane background. The permanent regression covers Dark→SI Classic→Dark→SI Classic, hiding/showing Outline each time, asserting geometry and comparing actual rendered pixels.

**PASS**: `hiddenOutlineRemovesItsDividerAcrossThemeChanges` and `nonSourceSurfacesRetireSourcePanelsAndRestoreThemOnReturn`, completed 2-test summary. Together with the 18-test batch above, 19 unique focused checks were exercised. Temporary probes were removed. The main CI expected count is now 1192 (two tests added since the original baseline).

The centered-navigation behavior has unlocked, visible native proof. The final 1pt divider fix has native offscreen geometry/pixel proof; visible theme-transition replay remains **BLOCKED** by the second desktop lock. Evidence: `sidebar-divider-before.log`, `sidebar-divider-after.log`, and `divider-final-tests.log` in the evidence directory.

Final release packaging after the divider fix completed successfully with `CODEX_SANDBOX=1 CAIRN_LIBGIT2=brew bash scripts/make-app.sh`; signature validation passed. Final artifacts remain `.build/distribution/Cairn.app` and `.build/distribution/Cairn.zip`. `/Applications/Cairn.app` has not been replaced.

## Explicit whitespace-click follow-up

The user clarified that ordinary clicks on blank areas sometimes move the reading position. Added `nativeBlankClicksKeepTheReadingPositionAndFoldState`, an isolated AppKit mouse-tracking regression driven by actual `mouseDown` plus a queued native mouse-up event. It uses a wrapped, multi-screen source file, keeps the previous selection offscreen, and checks short-line trailing whitespace, an empty line, indentation, and three blank positions beside a fold chip. Click points are required to lie inside the visible reader. The same source character must retain its viewport offset within 2pt; the fold set must remain unchanged.

**PASS**, completed one-test summary (3.360s). An earlier variant with the current selection on screen also passed. The suspected nearest-character/fold fallback was not reproduced by these checks; no speculative production hit-testing change was made. CI runs this new native mouse test separately, like the existing native drag test, so the main batch remains 1192 and the native mouse batches total 2.

Visible replay of this exact whitespace scenario remains **BLOCKED** because Computer Use still reports the Mac locked. `/Applications/Cairn.app` was rechecked and still has the 14:05:41 executable; the fixed distribution bundle is from 20:52:24. Do not interpret a continuing report from the installed older build as proof that the latest code still fails, or these passing synthetic checks as proof that every reported click is fixed. Evidence: `blank-click-tests.log`.

## Final unlocked acceptance

After the user unlocked again, the isolated QA bundle was replaced from the final signed distribution app. More than twenty whitespace clicks were exercised in the actual `jaz/src/jaz/_agent.py` reader: empty lines, trailing whitespace, indentation, large right-side whitespace, and first clicks after wheel-scrolling the previous selection offscreen. No large whitespace-triggered navigation jump was reproduced in this run.

A visually suspicious first-click sample was checked with temporary scalar-only instrumentation at before-hit-test, after-hit-test, after-native-mouse-processing, after-app-handler and 200ms-settled phases. The same laid-out fragment and clip origin remained unchanged in all phases: `clip=20033.600000`, `fragment=20016.100000`. Scrollbar fractions changed as TextKit refined its document-extent estimate; scope-header visibility could cover/reveal the top rows. This sample therefore does not demonstrate a source-anchor jump. An initial batched symbol-click trial navigated to `Config`; separate explicit single-click trials only opened Context, and trailing-whitespace clicks closed Context without moving the source. The initial symbol-navigation event was not reproduced or attributed to a root cause.

All temporary `[DEBUG-jump]` instrumentation was removed. The ReaderUI source blob returned exactly to `1775ace` (the tested production change), and the QA bundle was restored from the signed distribution app.

Previously blocked theme/divider acceptance is now **PASS** for the exercised native flow: Dark code→README, Dark→SI Classic while showing README, then `_agent.py`→README→`config.py`→README. The original outline divider position did not remain in the file list, and the broad dark chrome strips from the older recording were not seen. Screenshots and current AX state were inspected in this chat.

These results close the lock-related verification gap for the sampled workflows; they are not a guarantee that every intermittent input sequence is fixed. The installed `/Applications/Cairn.app` remains the older build; no installation or push was performed.
