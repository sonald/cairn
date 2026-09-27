import AppKit
import CodeInsightCore
import Foundation
import Testing

/// Optional artifacts from existing native host tests, not another workload runner.
/// A test summary remains the pass/fail authority; JSON stores observed facts only.
@MainActor
func readonlyCaptureSurfaceEvidence(
    _ name: String, textView: NSTextView, expectedSource: String,
    provenance: [String: String] = [:], drawView: NSView? = nil, drawCount: () -> Int
) throws {
    guard let directory = ProcessInfo.processInfo.environment["CAIRN_READONLY_SURFACE_EVIDENCE_DIR"] else { return }
    if let snapshot = provenance["snapshotID"] { try #require(snapshot != "missing") }
    let window = try #require(textView.window)
    try #require(!textView.isHiddenOrHasHiddenAncestor)
    try #require(textView.string == expectedSource)
    try #require(!textView.isEditable)
    window.contentView?.layoutSubtreeIfNeeded()
    textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
    let visible = textView.visibleRect.intersection(textView.bounds)
    try #require(!visible.isEmpty)
    let selected = textView.selectedRange()
    try #require(selected.length > 0 && NSMaxRange(selected) <= (expectedSource as NSString).length)
    let expectedCopy = (expectedSource as NSString).substring(with: selected)
    let board = NSPasteboard(name: .init("readonly-host-evidence-\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    try #require(textView.writeSelection(to: board, types: textView.writablePasteboardTypes))
    let copied = try #require(board.string(forType: .string))
    try #require(copied == expectedCopy)

    // This invokes the actual AppKit draw path; do not substitute view models,
    // cached test booleans, or an empty window screenshot for rendered content.
    let surface = drawView ?? textView
    let drawRect = surface.visibleRect.intersection(surface.bounds)
    try #require(!drawRect.isEmpty)
    let beforeDraw = drawCount()
    let bitmap = try #require(surface.bitmapImageRepForCachingDisplay(in: drawRect))
    surface.cacheDisplay(in: drawRect, to: bitmap)
    window.displayIfNeeded()
    let afterDraw = drawCount()
    try #require(afterDraw > beforeDraw)
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    try #require(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0 && !png.isEmpty)
    var sampledColors = Set<[CGFloat]>()
    for y in stride(from: 0, to: bitmap.pixelsHigh, by: max(1, bitmap.pixelsHigh / 60)) {
        for x in stride(from: 0, to: bitmap.pixelsWide, by: max(1, bitmap.pixelsWide / 80)) {
            if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                sampledColors.insert([color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent])
            }
        }
    }
    try #require(sampledColors.count > 1)
    let output = URL(fileURLWithPath: directory)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let label = name.map { $0.isLetter || $0.isNumber || $0 == "-" ? String($0) : "-" }.joined()
    let image = output.appendingPathComponent(label + ".png")
    try png.write(to: image, options: .atomic)
    func hash(_ bytes: [UInt8]) -> String { ContentID.sha256(of: bytes).bytes.map { String(format: "%02x", $0) }.joined() }
    let facts: [String: Any] = [
        "surface": name, "sourceSHA256": hash(Array(expectedSource.utf8)),
        "displayTextSHA256": hash(Array(textView.string.utf8)), "pngSHA256": hash(Array(png)),
        "sourceByteCount": expectedSource.utf8.count, "provenance": provenance,
        "selectedRanges": textView.selectedRanges.map { [$0.rangeValue.location, $0.rangeValue.length] },
        "selectionAffinity": textView.selectionAffinity.rawValue,
        "copiedUTF8": Array(copied.utf8), "isEditable": textView.isEditable,
        "usesTextKit2": textView.textLayoutManager != nil,
        "visibleRect": NSStringFromRect(visible), "windowVisible": window.isVisible,
        "pixelSize": [bitmap.pixelsWide, bitmap.pixelsHigh], "image": image.path,
        "drawCountBefore": beforeDraw, "drawCountAfter": afterDraw, "sampledDistinctColors": sampledColors.count,
        "fontName": (textView.textStorage?.attribute(.font, at: selected.location, effectiveRange: nil) as? NSFont)?.fontName ?? "",
    ]
    try JSONSerialization.data(withJSONObject: facts, options: [.prettyPrinted, .sortedKeys])
        .write(to: output.appendingPathComponent(label + ".json"), options: .atomic)
}
