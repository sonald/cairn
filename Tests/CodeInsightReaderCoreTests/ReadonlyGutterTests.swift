@preconcurrency import AppKit
import CodeInsightCore
import CodeInsightReaderCore
import Foundation
import Testing
@testable import CodeInsightReaderUI

private func readonlyGutterDocument(duplicateHeader: Bool = false) -> (ReaderDocument, FoldRegion) {
    let bytes = Array("fn example() {\n    alpha();\n    beta();\n    gamma();\n}\nfn after() {}\n".utf8)
    let lines = LineTable(bytes: bytes)
    let fold = FoldRegion(
        id: FoldID(rawValue: 811), kind: .declaration,
        headerRange: ByteRange(lowerBound: 0, upperBound: lines.lineStarts[1]),
        bodyRange: ByteRange(lowerBound: lines.lineStarts[1], upperBound: lines.lineStarts[4]),
        outlineDepth: 0, summary: FoldSummary(hiddenLineCount: 3)
    )
    let duplicate = FoldRegion(
        id: FoldID(rawValue: 812), kind: .block,
        headerRange: fold.headerRange, bodyRange: fold.bodyRange,
        outlineDepth: 1, summary: fold.summary
    )
    return (ReaderDocument(
        bytes: bytes, lineTable: lines, byteUTF16Map: ByteUTF16Map(validUTF8: bytes),
        highlightSpans: [], outlineFacets: [], foldRegions: duplicateHeader ? [fold, duplicate] : [fold]
    ), fold)
}

@MainActor
private func readonlyGutterRender(_ document: ReaderDocument) -> (ReaderTextView, NSScrollView, NSWindow) {
    let reader = ReaderTextView()
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 180))
    scroll.hasVerticalScroller = true
    scroll.documentView = reader.view
    reader.view.frame = scroll.contentView.bounds
    let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = scroll
    reader.apply(settings: ReaderSettings())
    reader.display(document: document)
    reader.view.textLayoutManager?.textViewportLayoutController.layoutViewport()
    window.displayIfNeeded()
    return (reader, scroll, window)
}

@MainActor
private func readonlyGutterDraw(_ reader: ReaderTextView, _ scroll: NSScrollView) throws -> NSRulerView {
    reader.view.textLayoutManager?.textViewportLayoutController.layoutViewport()
    let ruler = try #require(scroll.verticalRulerView)
    let bitmap = try #require(ruler.bitmapImageRepForCachingDisplay(in: ruler.bounds))
    ruler.cacheDisplay(in: ruler.bounds, to: bitmap)
    return ruler
}

@MainActor
@Test(.isolatedReaderWorkCounters)
func readonlyGutterWarmNativeDrawAndHoverReadPreparedData() throws {
    let (document, fold) = readonlyGutterDocument(duplicateHeader: true)
    let (reader, scroll, window) = readonlyGutterRender(document)
    defer { reader.clear(); withExtendedLifetime(window) {} }
    let ruler = try readonlyGutterDraw(reader, scroll)
    let row = try #require(reader.lastRulerFirstRowRectsForTesting[1])
    let hit = NSPoint(x: reader.rulerThickness - 6,
                      y: ruler.convert(NSPoint(x: 0, y: row.midY), from: reader.view).y)
    let before = ReaderWorkCounters.snapshot()
    for _ in 0..<5 {
        reader.setFoldGutterHoverForTesting(hit)
        #expect(reader.foldGutterHoveredFoldID == fold.id)
        _ = try readonlyGutterDraw(reader, scroll)
        #expect(reader.lastRulerFirstRowRectsForTesting[1] != nil)
        reader.setFoldGutterHoverForTesting(nil)
    }
    let after = ReaderWorkCounters.snapshot()
    #expect(after.decorationBuildCount == before.decorationBuildCount)
    #expect(after.drawGlobalRecordVisits == before.drawGlobalRecordVisits)
    #expect(reader.visibleLineNumbers.filter { $0 == 1 }.count == 1)
}

@MainActor
@Test(.isolatedReaderWorkCounters)
func readonlyGutterMarkerRevisionsAndProjectionRefreshTheirSummaries() throws {
    let (document, fold) = readonlyGutterDocument()
    let (reader, scroll, window) = readonlyGutterRender(document)
    defer { reader.clear(); withExtendedLifetime(window) {} }
    reader.setDiffMarkers([3: .added])
    reader.setBookmarkMarkers([2: ["Bookmark"]])
    #expect(reader.bookmarkMarkerLabelsForTesting == [2: ["Bookmark"]])
    #expect(reader.foldedDiffMarkersForTesting.isEmpty)
    #expect(reader.toggleFold(id: fold.id))
    #expect(reader.bookmarkMarkerLabelsForTesting == [1: ["Bookmark"]])
    #expect(reader.foldedDiffMarkersForTesting[1]?.rawValue == DiffCore.MarkerKind.added.rawValue)
    #expect(reader.foldExposureTextForTesting(fold.id) == " · diff")
    let before = ReaderWorkCounters.snapshot()
    reader.setDiffMarkers([3: .removed])
    #expect(ReaderWorkCounters.snapshot().decorationBuildCount - before.decorationBuildCount == 1)
    let afterDiff = ReaderWorkCounters.snapshot()
    reader.setBookmarkMarkers([4: ["Next"]])
    #expect(ReaderWorkCounters.snapshot().decorationBuildCount - afterDiff.decorationBuildCount == 1)
    #expect(reader.bookmarkMarkerLabelsForTesting == [1: ["Next"]])
    #expect(reader.foldedDiffMarkersForTesting[1]?.rawValue == DiffCore.MarkerKind.removed.rawValue)
    let unchanged = ReaderWorkCounters.snapshot()
    reader.setDiffMarkers([3: .removed])
    reader.setBookmarkMarkers([4: ["Next"]])
    #expect(ReaderWorkCounters.snapshot().decorationBuildCount == unchanged.decorationBuildCount)
    var settings = ReaderSettings()
    settings.lineNumbers = false
    reader.apply(settings: settings)
    _ = try readonlyGutterDraw(reader, scroll)
    #expect(reader.bookmarkMarkerAccessibilityLabel == nil)
    #expect(reader.visibleLineNumbers.isEmpty)
    #expect(reader.foldedDiffMarkersForTesting[1]?.rawValue == DiffCore.MarkerKind.removed.rawValue)
    settings.lineNumbers = true
    reader.apply(settings: settings)
    #expect(reader.bookmarkMarkerAccessibilityLabel?.contains("Next") == true)
    #expect(reader.toggleFold(id: fold.id))
    #expect(reader.bookmarkMarkerLabelsForTesting == [4: ["Next"]])
    #expect(reader.foldedDiffMarkersForTesting.isEmpty)
}

@MainActor
@Test
func readonlyGutterSyntaxUpgradeNewDocumentAndClearInvalidatePreparedData() throws {
    let (syntax, fold) = readonlyGutterDocument()
    let plain = ReaderDocument(bytes: syntax.bytes)
    let (reader, scroll, window) = readonlyGutterRender(plain)
    defer { reader.clear(); withExtendedLifetime(window) {} }
    #expect(reader.visibleFoldHandleLinesForTesting.isEmpty)
    reader.setDiffMarkers([2: .changed])
    reader.setBookmarkMarkers([3: ["Saved"]])
    reader.updateSyntax(document: syntax)
    #expect(reader.visibleFoldHandleLinesForTesting == [1])
    #expect(reader.toggleFold(id: fold.id))
    #expect(reader.bookmarkMarkerLabelsForTesting == [1: ["Saved"]])
    #expect(reader.foldedDiffMarkersForTesting[1]?.rawValue == DiffCore.MarkerKind.changed.rawValue)
    _ = try readonlyGutterDraw(reader, scroll)
    reader.display(document: ReaderDocument(bytes: Array("other\n".utf8)))
    #expect(reader.visibleFoldHandleLinesForTesting.isEmpty)
    #expect(reader.bookmarkMarkerLabelsForTesting.isEmpty)
    #expect(reader.foldedDiffMarkersForTesting.isEmpty)
    reader.clear()
    #expect(reader.visibleFoldHandleLinesForTesting.isEmpty)
    #expect(reader.bookmarkMarkerLabelsForTesting.isEmpty)
    #expect(reader.foldedDiffMarkersForTesting.isEmpty)
}

@MainActor
@Test(.isolatedReaderWorkCounters)
func readonlyGutterStableNativeScrollDoesNotBuildDocumentDecorations() throws {
    let source = (0..<200).map { "fn function\($0)() {\n    alpha();\n    beta();\n    gamma();\n}\n" }.joined()
    let document = try DocumentLoader(source: { _ in Array(source.utf8) })
        .load(file: URL(fileURLWithPath: "/readonly-gutter.rs")).document
    let (reader, scroll, window) = readonlyGutterRender(document)
    defer { reader.clear(); withExtendedLifetime(window) {} }
    reader.setBookmarkMarkers([2: ["Start"], 602: ["Later"]])
    reader.setDiffMarkers([3: .added, 603: .changed])
    _ = try readonlyGutterDraw(reader, scroll)
    let before = ReaderWorkCounters.snapshot()
    for y in [CGFloat(80), 160, 240, 0] {
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        _ = try readonlyGutterDraw(reader, scroll)
        #expect(!reader.lastRulerFirstRowRectsForTesting.isEmpty)
    }
    let after = ReaderWorkCounters.snapshot()
    #expect(after.decorationBuildCount == before.decorationBuildCount)
    #expect(after.drawGlobalRecordVisits == before.drawGlobalRecordVisits)
}

@MainActor
@Test(.isolatedReaderWorkCounters)
func readonlyGutterCacheRollbackPreservesMarkersAndCountsItsWork() throws {
    let (document, fold) = readonlyGutterDocument()
    let (reader, scroll, window) = readonlyGutterRender(document)
    defer { reader.clear(); withExtendedLifetime(window) {} }
    reader.setBookmarkMarkers([2: ["Saved"]])
    reader.setDiffMarkers([3: .changed])
    #expect(reader.toggleFold(id: fold.id))
    let expected = reader.bookmarkMarkerLabelsForTesting
    reader.usesPreparedDecorations = false
    let before = ReaderWorkCounters.snapshot()
    _ = try readonlyGutterDraw(reader, scroll)
    #expect(reader.bookmarkMarkerLabelsForTesting == expected)
    #expect(reader.foldedDiffMarkersForTesting[1] == .changed)
    #expect(ReaderWorkCounters.snapshot().decorationBuildCount > before.decorationBuildCount)
    #expect(ReaderWorkCounters.snapshot().drawGlobalRecordVisits > before.drawGlobalRecordVisits)
}

/// Flipped like the gutter ruler; drawn through the view path, whose text
/// positioning differs from a bare bitmap context.
private final class ReadonlyGutterLabelView: NSView {
    var body: (NSRect) -> Void = { _ in }
    var top: CGFloat = 0
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        // Wide enough for every label, as the gutter column always is.
        body(NSRect(x: 2, y: top, width: 90, height: 30))
    }
}

@MainActor
private func readonlyGutterLabelPixels(
    in view: ReadonlyGutterLabelView, top: CGFloat, _ draw: @escaping (NSRect) -> Void
) -> Data {
    view.top = top
    view.body = draw
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: rep)
    return Data(bytes: rep.bitmapData!, count: rep.bytesPerRow * rep.pixelsHigh)
}

@MainActor @Test
func readonlyGutterCachedLabelsMatchStringDrawingPixelForPixel() {
    let labels = LineNumberLabels()
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .right
    let view = ReadonlyGutterLabelView(frame: NSRect(x: 0, y: 0, width: 100, height: 60))
    let window = NSWindow(
        contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
    window.contentView = view
    defer { window.close() }
    // The gutter font spans 10...22pt; string drawing's baseline rule changes
    // shape around 16pt, and row tops are fractional while scrolling.
    for size in [10.0, 11, 15, 16, 22] {
        let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
        for line in [7, 42, 1_234] {
            for step in 0..<10 {
                let top = 5 + CGFloat(step) / 10
                let expected = readonlyGutterLabelPixels(in: view, top: top) { rect in
                    ("\(line)" as NSString).draw(in: rect, withAttributes: [
                        .font: font, .foregroundColor: NSColor.black, .paragraphStyle: paragraph,
                    ])
                }
                let actual = readonlyGutterLabelPixels(in: view, top: top) { rect in
                    labels.draw(line, font: font, color: .black, rightAlignedIn: rect, flipped: true)
                }
                #expect(actual == expected, "size \(size) line \(line) top \(top)")
            }
        }
    }
}
