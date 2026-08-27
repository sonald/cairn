import AppKit
import CodeInsightCore
import CodeInsightReaderCore
@testable import CodeInsightReaderUI
import Foundation
import Testing

// Regression: the ruler must draw its line numbers without letting either its
// own drawing or NSRulerView's built-in edge hairline reach the header above it.
// This renders the real hierarchy and checks both pixel outcomes without screen
// capture permission.
@MainActor
@Test
func rulerShowsLineNumbersWithoutBleedingAboveTheScrollView() throws {
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
    let reader = ReaderTextView(settings: ReaderSettings(theme: .light))
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

    // NSBitmapImageRep uses a top-left pixel origin for cached NSView output.
    let headerRows = max(
        0,
        Int((container.bounds.maxY - header.frame.maxY + 2) * CGFloat(scale))
    )..<min(
        bitmap.pixelsHigh,
        Int((container.bounds.maxY - header.frame.minY - 2) * CGFloat(scale))
    )
    var bledColumns: [Int] = []
    for px in scanColumns {
        var dark = 0
        for py in headerRows {
            guard let color = bitmap.colorAt(x: px, y: py)?
                .usingColorSpace(.sRGB) else { continue }
            if color.brightnessComponent < 0.97 { dark += 1 }
        }
        if dark > 20 * scale / 2 { bledColumns.append(px) }
    }
    #expect(bledColumns.isEmpty, "vertical line bled into header at pixel columns \(bledColumns)")

    let lineNumberRGB = ReaderTheme(settings: ReaderSettings(theme: .light))
        .lineNumberRGB(isDark: false)
    let target = (
        red: CGFloat((lineNumberRGB >> 16) & 0xFF) / 255,
        green: CGFloat((lineNumberRGB >> 8) & 0xFF) / 255,
        blue: CGFloat(lineNumberRGB & 0xFF) / 255
    )
    let numberColumns = max(0, Int(gutterFrame.minX) * scale)..<min(
        bitmap.pixelsWide,
        Int(gutterFrame.minX + 34) * scale
    )
    let readerRows = min(bitmap.pixelsHigh, 34 * scale)..<min(
        bitmap.pixelsHigh,
        120 * scale
    )
    var lineNumberPixels = 0
    for px in numberColumns {
        for py in readerRows {
            guard let color = bitmap.colorAt(x: px, y: py)?
                .usingColorSpace(.sRGB),
                  abs(color.redComponent - target.red) < 0.12,
                  abs(color.greenComponent - target.green) < 0.12,
                  abs(color.blueComponent - target.blue) < 0.12
            else { continue }
            lineNumberPixels += 1
        }
    }
    #expect(lineNumberPixels >= 4, "line-number pixels were not rendered")
}
