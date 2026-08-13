import AppKit
import CodeInsightCore
import CodeInsightReaderCore
@testable import CodeInsightReaderUI
import Foundation
import Testing

// Regression: NSRulerView strokes its built-in edge hairline across the full
// dirty rect, and macOS 14+ views no longer clip to bounds by default. Without
// clipping, the ruler paints a short vertical line at x == ruleThickness into
// sibling views laid out above the scroll view (the reader tab strip).
// This renders the real view hierarchy and pixel-scans the header band above
// the ruler without depending on screen-capture permission.
@MainActor
@Test
func rulerEdgeLineDoesNotBleedAboveTheScrollView() throws {
    let source = (1...120).map { "let value\($0) = \($0);" }.joined(separator: "\n")
    let file = URL(fileURLWithPath: "/bleed.rs")
    let document = try DocumentLoader(source: { _ in Array(source.utf8) })
        .load(file: file).document

    let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 232))
    container.wantsLayer = true
    container.layer?.backgroundColor = NSColor.white.cgColor

    // 32pt header band at the top, mirroring readerHeader in the app.
    let header = NSView(frame: NSRect(x: 0, y: 200, width: 400, height: 32))
    header.wantsLayer = true
    header.layer?.backgroundColor = NSColor.white.cgColor

    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    let reader = ReaderTextView()
    scrollView.documentView = reader.view
    reader.view.frame = scrollView.contentView.bounds
    reader.configureGutter(in: scrollView, lineNumbers: true)
    reader.display(document: document, fileURL: file)

    container.addSubview(header)
    container.addSubview(scrollView)

    _ = NSApplication.shared
    let window = NSWindow(
        contentRect: NSRect(x: 100, y: 100, width: 400, height: 232),
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    window.contentView = container
    window.layoutIfNeeded()
    window.displayIfNeeded()

    let bitmap = try #require(
        container.bitmapImageRepForCachingDisplay(in: container.bounds)
    )
    container.cacheDisplay(in: container.bounds, to: bitmap)
    let scale = max(1, bitmap.pixelsWide / 400)
    let ruler = try #require(scrollView.verticalRulerView)
    let gutterFrame = ruler.convert(ruler.bounds, to: container)
    let scanColumns = max(0, Int(gutterFrame.minX) * scale)..<min(
        bitmap.pixelsWide,
        Int(gutterFrame.maxX.rounded(.up)) * scale + 1
    )

    // The header band occupies the top 32pt of the window. Any column with a
    // near-full-height run of non-white pixels at the gutter edge is a bleed.
    var bledColumns: [Int] = []
    for px in scanColumns {
        var dark = 0
        for py in (202 * scale)..<(230 * scale) {
            guard let color = bitmap.colorAt(x: px, y: py)?
                .usingColorSpace(.sRGB) else { continue }
            if color.brightnessComponent < 0.97 { dark += 1 }
        }
        if dark > 20 * scale / 2 { bledColumns.append(px) }
    }
    #expect(bledColumns.isEmpty, "vertical line bled into header at pixel columns \(bledColumns)")
}
