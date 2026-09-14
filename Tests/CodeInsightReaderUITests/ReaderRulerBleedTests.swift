import AppKit
import CodeInsightCore
import CodeInsightReaderCore
@testable import CodeInsightReaderUI
import Foundation
import Testing

@MainActor
@Test
func gutterReservesOneWidthBeforeTheFirstGlyph() throws {
    _ = NSApplication.shared
    let source = "fn sample(value: usize) {\n    value;\n}\n"
    let file = URL(fileURLWithPath: "/gutter.rs")
    let document = try DocumentLoader(source: { _ in Array(source.utf8) })
        .load(file: file).document
    for style: NSScroller.Style in [.legacy, .overlay] {
        for size: Double in [10, 13, 24] {
            let reader = ReaderTextView(settings: ReaderSettings(fontSize: size))
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
            scroll.scrollerStyle = style
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = false
            scroll.documentView = reader.view
            reader.view.frame = scroll.contentView.bounds
            let window = NSWindow(contentRect: scroll.frame, styleMask: .borderless,
                                  backing: .buffered, defer: false)
            window.contentView = scroll
            reader.display(document: document, fileURL: file)
            reader.setBookmarkMarkers([1: ["Sample"]])
            reader.setDiffMarkers([1: .changed])
            for numbers in [true, false] {
                reader.configureGutter(in: scroll, lineNumbers: numbers)
                window.layoutIfNeeded()
                window.displayIfNeeded()
                reader.view.textLayoutManager?.textViewportLayoutController.layoutViewport()
                let ruler = try #require(scroll.verticalRulerView)
                let gutter = ruler.convert(ruler.bounds, to: scroll)
                let glyph = scroll.convert(window.convertFromScreen(reader.view.firstRect(
                    forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil
                )), from: nil)
                let gap = glyph.minX - gutter.maxX
                print("GUTTER_GEOMETRY style=\(style.rawValue) size=\(size) numbers=\(numbers) gutter=\(gutter) clip=\(scroll.contentView.frame) insets=\(scroll.contentInsets) glyph=\(glyph) gap=\(gap)")
                #expect((8...12).contains(gap), "first glyph gap: \(gap)")
            }
            withExtendedLifetime(window) {}
        }
    }
}

// Regression: the ruler must draw its line numbers without letting either its
// own drawing or NSRulerView's built-in edge hairline reach the header above it.
// This renders the real hierarchy and checks both pixel outcomes without screen
// capture permission.
@MainActor
@Test
func rulerShowsLineNumbersWithoutBleedingAboveTheScrollView() async throws {
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
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentView = container
    window.orderFront(nil)
    window.layoutIfNeeded()
    window.displayIfNeeded()
    try await Task.sleep(for: .milliseconds(100))

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

    ruler.wantsLayer = true
    reader.apply(settings: ReaderSettings(fontSize: 24, theme: .dark))
    window.displayIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    reader.apply(settings: ReaderSettings())
    window.displayIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    reader.apply(settings: ReaderSettings(theme: .dark))
    window.displayIfNeeded()
    try await Task.sleep(for: .milliseconds(100))

    let replacement = (1...180).map { "fn switched\($0)() {}" }.joined(separator: "\n")
    let replacementDocument = try DocumentLoader(source: { _ in Array(replacement.utf8) })
        .load(file: URL(fileURLWithPath: "/switched.rs")).document
    reader.view.frame = NSRect(origin: .zero, size: scrollView.contentView.bounds.size)
    reader.display(document: replacementDocument)
    window.displayIfNeeded()
    try await Task.sleep(for: .milliseconds(100))

    // A normal ruler-only repaint has a narrow dirty rect. The text's x
    // position must not exclude its line numbers or gutter markers.
    ruler.needsDisplay = true
    ruler.displayIfNeeded()
    try await Task.sleep(for: .milliseconds(100))

    // Read the cached layer. cacheDisplay could request a wider draw and
    // hide the failure of the preceding ruler-only repaint.
    let cached = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(ceil(ruler.bounds.width * 2)),
        pixelsHigh: Int(ceil(ruler.bounds.height * 2)),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ))
    let graphics = try #require(NSGraphicsContext(bitmapImageRep: cached))
    graphics.cgContext.scaleBy(x: 2, y: 2)
    try #require(ruler.layer).render(in: graphics.cgContext)
    let expected = try #require(NSColor(
        srgbRed: 133.0 / 255, green: 133.0 / 255, blue: 133.0 / 255, alpha: 1
    ).usingColorSpace(cached.colorSpace))
    var refreshedNumberPixels = 0
    for y in 0..<cached.pixelsHigh {
        for x in 0..<cached.pixelsWide {
            guard let pixel = cached.colorAt(x: x, y: y),
                  abs(pixel.redComponent - expected.redComponent) < 0.05,
                  abs(pixel.greenComponent - expected.greenComponent) < 0.05,
                  abs(pixel.blueComponent - expected.blueComponent) < 0.05
            else { continue }
            refreshedNumberPixels += 1
        }
    }
    #expect(refreshedNumberPixels >= 4,
            "No line-number pixels after font/theme reset and switching documents: \(refreshedNumberPixels)")
}
