# M14 Non-source preview acceptance

Date: 2026-09-03

## Baseline and commits

The plan baseline is `43d8f1b1018b99cea13388ca3861af535ca9e3e8`.

- S1 discovery and snapshots: `a30034f86732d922e25edd5777150cd46ec3334a`
- S1 legacy expectation alignment: `4a526eb8370efb52f0d3db2aa8896345b3e875e1`
- S2 read-only rendering: `dd4b62d5630eff1dca55c9c1f4600c9ee3eb5f1b`
- S3 secure links and history/session restore: `5229124251be847030f41c06f3d816b416d131db`
- S4 bounded/readable previews: `4f300ceb2cabef14767ac28342951f8566173854`
- S4 bundle acceptance and CI count: `6ba68ac5ab01523dcf8159f902a5c92bba66b915`

## RED/GREEN evidence

The S3 behavior tests first produced the expected RED for missing preview-link callbacks, HTML URL policy seams, and non-source replay/session paths. The final focused S4 preview run was 5/5 GREEN. Markdown tests cover block separation, heading hierarchy, strong emphasis, list breaks, and preserved links.

The repository CI gate then passed:

```text
main:     849 tests / 3 suites, 223.573 s
isolated:   2 tests / 0 suites, 0.396 s
total:    851 tests, exit 0
```

Exact, diff, reading, projector, and fold self-tests all finished with exit 0. Fold performance finished with `status=pass`, resolution 24.322 ms, fold latency 256.876 ms, and delta physical footprint 1,867,776 bytes.

## Host bundle acceptance

The host-validated bundle was:

```text
.build/m14-final-bundle/Cairn.app
bundle id: dev.cairn.Cairn.M14NonSourceFinal
codesign: valid
```

Its non-source self-test exited 0 with every check true. Project ready time was 67.6466 ms; recorded RSS/physical footprint was 284,329,232 bytes; the window content stayed at 900x600 pt. The test verified the file tree, Markdown link navigation, Back/Forward, HTML `didFinish`, JavaScript disabled, non-persistent WebKit storage, image/PDF/plain-text previews, source-surface restoration, and zero Reading Trail edges.

The host capture methods were `WKWebView.takeSnapshot` for HTML and `PDFPage.thumbnail` for PDF:

- [light-markdown.png](light-markdown.png)
- [dark-html.png](dark-html.png)
- [si-image.png](si-image.png)
- [si-pdf.png](si-pdf.png)

All four captures have visible pixels and the same 900x600 pt window geometry. The PDF fixture contains a visible dark rectangle and text; the image capture shows proportional scaling.

## Real UI flow and accessibility

Computer Use validated the normal app entry point: NSOpenPanel, Rust language selection, and file-tree publication; actual Markdown link click to `guide.md`; Back/Forward; HTML Preview and Image Preview; PDF AX page text; and quit. The app's isolated AppSupport directory only received `session.json`.

Preview surfaces expose distinct AX labels (`Markdown preview`, `HTML preview`, `Image preview`, `PDF preview`, and `Plain text preview`), remain read-only/selectable where applicable, and hide source-only controls. Tabs, sidebar selection, and file palette remain available.

## Safety and zero-write evidence

The fixture contained 43 files including `.git`, a symlink, a remote-image/meta-refresh HTML page, PNG, PDF, Markdown, and text. Before/after sorted SHA-256 lists, `HEAD`, index state, and status were identical. The app did not write the fixture, project, or `.git` directory.

The default sandbox raw debug-binary probe is recorded separately as `BLOCKED`: HTML WebKit `didFinish=false` with no application error, and therefore no snapshot was attempted. This is a WebContent sandbox limitation of that runner, not a host-bundle result; the host bundle above completed the HTML load and snapshot checks.

## Deliberate defers

External links are not opened. Inline local Markdown/HTML resources are not promised. QuickLook, editing, plugins/registries, and arbitrary binary viewers remain deferred. Unsupported or invalid binary content is reported explicitly rather than shown as text.
