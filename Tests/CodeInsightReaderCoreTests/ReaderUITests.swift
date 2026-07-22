import AppKit
import CodeInsightReaderCore
import CodeInsightReaderUI
import Foundation
import Testing

@MainActor
@Test
func regularDocumentRendersSyntaxColorsOffscreen() throws {
    let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Tests/RustExtractorTests/Fixtures/use_alias/db.rs")
    let loaded = try DocumentLoader().load(file: fixture)
    let (reader, _, window) = renderOffscreen(loaded.document)
    withExtendedLifetime(window) {
        #expect(loaded.tier == .regular)
        #expect(reader.renderingCoordinator.styledFragmentCount > 0)
        #expect(renderedColors(in: reader).contains { colorsEqual(
            $0,
            ReaderTheme(settings: ReaderSettings()).color(for: .keyword)
        ) })
    }
}

@MainActor
@Test
func scrollingRendersNewlyVisibleSyntaxColors() throws {
    let source = (0..<500)
        .map { "let value\($0) = \($0);" }
        .joined(separator: "\n")
    let bytes = Array(source.utf8)
    let highlighted = try RustHighlighter().highlight(bytes: bytes)
    let document = ReaderDocument(
        bytes: bytes,
        highlightSpans: highlighted.spans,
        outlineFacets: highlighted.outlineFacets
    )
    let (reader, scrollView, window) = renderOffscreen(document)
    let before = reader.renderingCoordinator.styledFragmentCount
    let lastLine = (source as NSString).range(of: "let value499")
    let lastKeyword = NSRange(location: lastLine.location, length: 3)

    reader.view.setFrameSize(NSSize(width: reader.view.frame.width, height: 10_000))
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: 9_000))
    scrollView.reflectScrolledClipView(scrollView.contentView)
    reader.view.textLayoutManager?.textViewportLayoutController.layoutViewport()
    window.displayIfNeeded()

    #expect(reader.renderingCoordinator.styledFragmentCount > before)
    #expect(renderedColors(in: reader, intersecting: lastKeyword).contains { colorsEqual(
        $0,
        ReaderTheme(settings: ReaderSettings()).color(for: .keyword)
    ) })
}

@MainActor
@Test
func diffGutterStoresMarkersAndHunkRevealSelectsTheLine() {
    let document = ReaderDocument(bytes: Array("one\ntwo\nthree\n".utf8))
    let reader = ReaderTextView()
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 180))
    scrollView.documentView = reader.view
    reader.installDiffGutter(in: scrollView)
    reader.display(document: document)
    reader.setDiffMarkers([2: .changed, 3: .added])

    #expect(reader.diffMarkerCounts == [.changed: 1, .added: 1])
    #expect(reader.revealDiffLine(3))
    #expect(reader.selectedLineNumber == 3)
}

@MainActor
private func renderOffscreen(
    _ document: ReaderDocument
) -> (ReaderTextView, NSScrollView, NSWindow) {
    let reader = ReaderTextView()
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 180))
    scrollView.hasVerticalScroller = true
    scrollView.documentView = reader.view
    reader.view.frame = scrollView.contentView.bounds
    let window = NSWindow(
        contentRect: scrollView.frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.contentView = scrollView
    reader.display(document: document)
    reader.view.textLayoutManager?.textViewportLayoutController.layoutViewport()
    window.displayIfNeeded()
    return (reader, scrollView, window)
}

@MainActor
private func renderedColors(
    in reader: ReaderTextView,
    intersecting expectedRange: NSRange? = nil
) -> [NSColor] {
    guard let manager = reader.view.textLayoutManager,
          let content = manager.textContentManager
    else { return [] }
    var colors: [NSColor] = []
    manager.enumerateRenderingAttributes(
        from: content.documentRange.location,
        reverse: false
    ) { _, attributes, textRange in
        let lower = content.offset(
            from: content.documentRange.location,
            to: textRange.location
        )
        let upper = content.offset(
            from: content.documentRange.location,
            to: textRange.endLocation
        )
        let range = NSRange(location: lower, length: upper - lower)
        let intersects = expectedRange.map {
            NSIntersectionRange($0, range).length > 0
        } ?? true
        if intersects,
           let color = attributes[.foregroundColor] as? NSColor
        {
            colors.append(color)
        }
        return true
    }
    return colors
}

@MainActor
private func colorsEqual(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
    let appearance = NSAppearance(named: .aqua)!
    var left: [CGFloat] = []
    var right: [CGFloat] = []
    appearance.performAsCurrentDrawingAppearance {
        if let lhs = lhs.usingColorSpace(.deviceRGB) {
            var red = CGFloat.zero
            var green = CGFloat.zero
            var blue = CGFloat.zero
            var alpha = CGFloat.zero
            lhs.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            left = [red, green, blue, alpha]
        }
        if let rhs = rhs.usingColorSpace(.deviceRGB) {
            var red = CGFloat.zero
            var green = CGFloat.zero
            var blue = CGFloat.zero
            var alpha = CGFloat.zero
            rhs.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            right = [red, green, blue, alpha]
        }
    }
    return left == right
}
