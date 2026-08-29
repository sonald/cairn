# S1 first-run language picker evidence

Date: 2026-08-29

`PLAN_BASE`: `7ec7c6c3b185b3085aef621cf62d6a3ffcaa38b1`

## Automated AppKit check

- RED: after adding the geometry assertions but before sizing the accessory stack,
  `swift build --disable-sandbox --product codeinsight-app` passed and
  `.build/debug/codeinsight-app --self-test` exited 1 with
  `languagePickerFramesDoNotOverlap=false`.
- GREEN: after sizing and laying out the existing `NSStackView`, the same build and
  self-test exited 0 with `languagePickerLabelsFit`,
  `languagePickerFramesDoNotOverlap`, `languagePickerOrderMatches`, and
  `languagePickerOpenGate` all true.
- The Open gate covers 0 selected (disabled), 1 selected (enabled), 3 selected
  (enabled), and clearing all selections (disabled).

## Signed bundle

- Bundle id: `dev.cairn.Cairn.m10m11productization.20260829.s1`
- Bundle: `.build/m10-m11-productization/s1/Cairn.app`
- Before launch, both the bundle-specific Application Support directory and
  Preferences plist were absent.
- `scripts/make-app.sh` completed with exit 0; `plutil` and
  `codesign --verify --strict --verbose=2` passed.
- Screenshot: `s1-first-run-language-picker.png` (260 x 299).

The live AX order matched the rendered order:

```text
dialog: alert
text: Choose Languages / Choose 1 to 3 languages for codeinsight.
checkbox: Rust, value 0
checkbox: Python, value 0
checkbox: TypeScript, value 0
button: Cancel
button: Open, disabled
```

## Task result

| Step | Status | Evidence |
|---|---|---|
| New isolated bundle opens with no restored session | PASS | Empty Cairn window was captured before opening a project. |
| Open Project opens the real `NSOpenPanel` | PASS | The panel navigated to the repository root without a prewritten session or defaults. |
| All three language options are visible and ordered | PASS | Live screenshot and AX tree above. |
| Zero-selection Open state | PASS | Live AX reports Open disabled; self-test locks all 0/1/3 transitions. |
| Mouse/keyboard select Rust, Open, files visible | BLOCKED | The Computer Use channel closed on direct checkbox actions; host Full Keyboard Access did not move focus to the checkboxes. No product failure was observed, but this task is not claimed as PASS. |
