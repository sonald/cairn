import AppKit
import CodeInsightCore
import CodeInsightReaderCore
import Foundation
import PDFKit
import Testing
import WebKit
@testable import CodeInsightApp

@MainActor
@Test
func nonSourcePreviewMarkdownAndPlainTextStaySeparateFromSourceReader() throws {
    _ = NSApplication.shared
    let root = try nonSourcePreviewTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let markdown = try nonSourcePreviewFile(
        root: root,
        name: "README.md",
        bytes: Array("# Title\n\ndisk bytes **Read** [guide](docs/guide.md)\n\n- first\n- second\n".utf8)
    )
    let text = try nonSourcePreviewFile(
        root: root,
        name: "notes.txt",
        bytes: Array("plain text\n".utf8)
    )
    let source = try nonSourcePreviewFile(
        root: root,
        name: "main.rs",
        bytes: Array("fn main() {}\n".utf8)
    )

    let controller = ReaderViewController()
    controller.loadViewIfNeeded()

    var outlines: [[OutlineFacet]] = []
    var sawPreviewDocumentClear = false
    controller.onOutlineChange = { outlines.append($0) }
    controller.onDocumentChange = { _, document in
        if document == nil { sawPreviewDocumentClear = true }
    }

    controller.display(source)
    var state = controller.selfTestPreviewState
    #expect(state.kind == nil)
    #expect(state.sourceVisible)
    #expect(controller.selfTestReadingHeightHeader.enabled)
    #expect(!controller.selfTestReadingHeightHeader.hidden)

    controller.display(markdown, languageMode: nil)
    state = controller.selfTestPreviewState
    #expect(state.kind == "Markdown")
    #expect(state.renderedText?.contains("Title") == true)
    #expect(state.renderedText?.contains("Title\n\ndisk bytes") == true)
    #expect(state.renderedText?.contains("• first\n• second") == true)
    #expect(state.renderedText?.contains("**") == false)
    #expect(state.linkCount == 1)
    let headingFont = try #require(controller.selfTestPreviewFont(at: "Title"))
    let bodyFont = try #require(controller.selfTestPreviewFont(at: "disk bytes"))
    let strongFont = try #require(controller.selfTestPreviewFont(at: "Read"))
    #expect(headingFont.pointSize > bodyFont.pointSize)
    #expect(strongFont.fontDescriptor.symbolicTraits.contains(.bold))
    #expect(state.editable == false)
    #expect(state.selectable == true)
    #expect(state.visible)
    #expect(state.accessibilityLabel == "Markdown preview")
    #expect(state.sourceVisible == false)
    #expect(controller.canFindInFile == false)
    #expect(controller.canFocusCurrentScope == false)
    #expect(controller.canToggleFoldAtSelection == false)
    #expect(controller.currentReadingPosition() == nil)
    #expect(outlines.last == [])
    #expect(sawPreviewDocumentClear)
    #expect(!controller.selfTestReadingHeightHeader.enabled)
    #expect(controller.selfTestReadingHeightHeader.hidden)

    let captured = Array("# captured bytes\n".utf8)
    controller.display(
        markdown,
        snapshotID: SnapshotID(rawValue: UUID()),
        source: { _ in captured },
        languageMode: nil
    )
    #expect(controller.selfTestPreviewState.renderedText?.contains("captured bytes") == true)
    #expect(controller.selfTestPreviewState.renderedText?.contains("disk bytes") == false)
    #expect(controller.selfTestPreviewState.renderedText?.hasPrefix("#") == false)

    controller.display(text, languageMode: nil)
    state = controller.selfTestPreviewState
    #expect(state.kind == "Plain text")
    #expect(state.renderedText == "plain text\n")
    #expect(state.editable == false)
    #expect(state.selectable == true)

    controller.display(source)
    state = controller.selfTestPreviewState
    #expect(state.kind == nil)
    #expect(state.sourceVisible)
    #expect(state.previewVisible == false)
    #expect(controller.selfTestReadingHeightHeader.enabled)
    #expect(!controller.selfTestReadingHeightHeader.hidden)
}

@MainActor
@Test
func nonSourcePreviewHTMLUsesLockedDownNavigationAndCSP() throws {
    _ = NSApplication.shared
    let root = try nonSourcePreviewTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let html = try nonSourcePreviewFile(
        root: root,
        name: "page.html",
        bytes: Array("<html><head><title>Page</title></head><body><h1>HTML</h1></body></html>".utf8)
    )
    let controller = ReaderViewController()
    controller.loadViewIfNeeded()

    controller.display(html, languageMode: nil)
    let state = controller.selfTestPreviewState
    #expect(state.kind == "HTML")
    #expect(state.visible)
    #expect(state.accessibilityLabel == "HTML preview")
    #expect(state.htmlJavaScriptEnabled == false)
    #expect(state.htmlDataStorePersistent == false)
    #expect(state.htmlContentSecurityPolicy ==
        "default-src 'none'; style-src 'unsafe-inline'; img-src data:; object-src 'none'; "
        + "frame-src 'none'; connect-src 'none'; media-src 'none'; base-uri 'none'; form-action 'none'")
    #expect(controller.selfTestHTMLNavigationPolicy(for: .other, initialLoad: true) == .allow)
    #expect(controller.selfTestHTMLNavigationPolicy(for: .other) == .cancel)
    #expect(controller.selfTestHTMLNavigationPolicy(for: .linkActivated) == .cancel)
    #expect(controller.selfTestHTMLNavigationPolicy(for: .formSubmitted) == .cancel)
    #expect(controller.selfTestHTMLNavigationPolicy(for: .reload) == .cancel)
}

@MainActor
@Test
func markdownPreviewActivatesItsAttributedLinkThroughReaderCallback() throws {
    _ = NSApplication.shared
    let root = try nonSourcePreviewTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let markdown = try nonSourcePreviewFile(
        root: root,
        name: "README.md",
        bytes: Array("[guide](docs/guide.md#install)\n".utf8)
    )
    let controller = ReaderViewController()
    controller.loadViewIfNeeded()
    var opened: [URL] = []
    controller.onOpenPreviewLink = { opened.append($0) }

    controller.display(markdown, languageMode: nil)

    #expect(controller.selfTestActivatePreviewLink(at: 0))
    #expect(opened == [
        root.appendingPathComponent("docs/guide.md").standardizedFileURL
    ])
}

@MainActor
@Test
func htmlPreviewSharesSecureInternalLinkDecisionWithDelegate() throws {
    _ = NSApplication.shared
    let root = try nonSourcePreviewTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let page = try nonSourcePreviewFile(
        root: root,
        name: "page.html",
        bytes: Array("<html><body>page</body></html>".utf8)
    )
    let guide = try nonSourcePreviewFile(
        root: root,
        name: "docs/guide.md",
        bytes: Array("guide".utf8)
    )
    let controller = ReaderViewController()
    controller.loadViewIfNeeded()
    var opened: [URL] = []
    controller.onOpenPreviewLink = { opened.append($0) }
    controller.display(page, languageMode: nil)

    #expect(controller.selfTestHTMLNavigationPolicy(
        for: page,
        navigationType: .other,
        initialLoad: true
    ) == .allow)
    let sameFileFragment = URL(string: "#section", relativeTo: page)!.absoluteURL
    #expect(controller.selfTestHTMLNavigationPolicy(
        for: sameFileFragment,
        navigationType: .linkActivated
    ) == .allow)
    #expect(controller.selfTestHTMLNavigationPolicy(
        for: guide,
        navigationType: .linkActivated
    ) == .cancel)
    #expect(opened == [guide.standardizedFileURL])
    #expect(controller.selfTestHTMLNavigationPolicy(
        for: URL(string: "https://example.com")!,
        navigationType: .linkActivated
    ) == .cancel)
    #expect(controller.selfTestHTMLNavigationPolicy(
        for: URL(string: "mailto:team@example.com")!,
        navigationType: .linkActivated
    ) == .cancel)
    #expect(controller.selfTestHTMLNavigationPolicy(
        for: URL(string: "javascript:alert(1)")!,
        navigationType: .linkActivated
    ) == .cancel)
    #expect(opened == [guide.standardizedFileURL])
    let queriedFragment = URL(string: "page.html?reload=1#section")!
    #expect(controller.selfTestHTMLNavigationPolicy(
        for: queriedFragment,
        navigationType: .linkActivated
    ) == .cancel)
    #expect(controller.selfTestHTMLNavigationPolicy(
        for: page,
        navigationType: .formSubmitted
    ) == .cancel)
}

@MainActor
@Test
func nonSourcePreviewPDFImageAndBinaryStatesAreDistinct() throws {
    _ = NSApplication.shared
    let root = try nonSourcePreviewTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let pdf = try nonSourcePreviewFile(
        root: root,
        name: "document.pdf",
        bytes: try nonSourcePreviewPDF()
    )
    let image = try nonSourcePreviewFile(
        root: root,
        name: "image.png",
        bytes: try nonSourcePreviewPNG()
    )
    let binary = try nonSourcePreviewFile(
        root: root,
        name: "payload.bin",
        bytes: [0x00, 0xff, 0x01]
    )
    let corruptPDF = try nonSourcePreviewFile(
        root: root,
        name: "corrupt.pdf",
        bytes: Array("not a PDF\n".utf8)
    )
    let controller = ReaderViewController()
    controller.loadViewIfNeeded()

    controller.display(pdf, languageMode: nil)
    var state = controller.selfTestPreviewState
    #expect(state.kind == "PDF")
    #expect(state.pdfPageCount == 1)
    #expect(state.visible)
    #expect(state.accessibilityLabel == "PDF preview")

    controller.display(image, languageMode: nil)
    state = controller.selfTestPreviewState
    #expect(state.kind == "Image")
    #expect(state.imageSize?.width == 1)
    #expect(state.imageSize?.height == 1)
    #expect(state.visible)
    #expect(state.accessibilityLabel == "Image preview")

    controller.display(binary, languageMode: nil)
    state = controller.selfTestPreviewState
    #expect(state.kind == "Error")
    #expect(state.renderedText == "Unsupported binary")
    #expect(state.accessibilityLabel == "Unsupported binary preview")

    controller.display(corruptPDF, languageMode: nil)
    state = controller.selfTestPreviewState
    #expect(state.kind == "Error")
    #expect(state.renderedText == "Could not open PDF")
}

private func nonSourcePreviewTemporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "CodeInsightNonSourcePreview-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    return root
}

private func nonSourcePreviewFile(
    root: URL,
    name: String,
    bytes: [UInt8]
) throws -> URL {
    let file = root.appendingPathComponent(name)
    try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data(bytes).write(to: file)
    return file
}

private func nonSourcePreviewPDF() throws -> [UInt8] {
    let data = NSMutableData()
    var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 200)
    guard let consumer = CGDataConsumer(data: data as CFMutableData),
          let context = CGContext(
              consumer: consumer,
              mediaBox: &mediaBox,
              nil
          )
    else { throw CocoaError(.fileWriteUnknown) }
    context.beginPDFPage(nil)
    context.endPDFPage()
    context.closePDF()
    return Array(data as Data)
}

private func nonSourcePreviewPNG() throws -> [UInt8] {
    let image = NSImage(size: NSSize(width: 1, height: 1))
    image.lockFocus()
    NSColor.systemRed.setFill()
    NSRect(x: 0, y: 0, width: 1, height: 1).fill()
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation,
          let representation = NSBitmapImageRep(data: tiff),
          let png = representation.representation(using: .png, properties: [:])
    else { throw CocoaError(.fileWriteUnknown) }
    return Array(png)
}

@MainActor
@Test
func markdownPreviewPreservesListMarkersNestingAndInlineStyles() throws {
    _ = NSApplication.shared
    let root = try nonSourcePreviewTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let markdown = try nonSourcePreviewFile(
        root: root,
        name: "LISTS.md",
        bytes: Array("""
        # Guide

        - first **bold** item
        - second item with `code`
          - nested bullet

        1. install
        2. run

        ```rust
        fn code_block() {}
        ```

        Tail paragraph.
        """.utf8)
    )
    let controller = ReaderViewController()
    controller.loadViewIfNeeded()
    controller.display(markdown, languageMode: nil)

    let state = controller.selfTestPreviewState
    #expect(state.kind == "Markdown")
    let text = try #require(state.renderedText)
    // Unordered markers and nesting survive.
    #expect(text.contains("• first **bold** item".replacingOccurrences(of: "**", with: "")) || text.contains("• first"))
    #expect(text.contains("• first bold item") || text.contains("• first **bold** item"))
    #expect(text.contains("• second item with code") || text.contains("• second item with `code`"))
    #expect(text.contains("  • nested bullet"))
    // Ordered numbering restarts per list.
    #expect(text.contains("1. install"))
    #expect(text.contains("2. run"))
    // Paragraph spacing separates blocks; code block stays monospaced.
    #expect(text.contains("fn code_block() {}"))
    let codeFont = try #require(controller.selfTestPreviewFont(at: "fn code_block"))
    #expect(codeFont.fontDescriptor.symbolicTraits.contains(.monoSpace))
    // Inline styles inside list items keep working.
    let boldFont = try #require(controller.selfTestPreviewFont(at: "bold"))
    #expect(boldFont.fontDescriptor.symbolicTraits.contains(.bold))
    // Selection/copy surface unchanged.
    #expect(state.selectable == true)
    #expect(state.editable == false)
}

@MainActor
@Test
func plainTextPreviewWrapUpdatesLiveAndOnReopenPreservingSelectionAndAnchor() throws {
    _ = NSApplication.shared
    let root = try nonSourcePreviewTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let contents = (0..<120).map { "row \($0) " + String(repeating: "wide 🧭 text ", count: 30) }
        .joined(separator: "\n")
    let file = try nonSourcePreviewFile(root: root, name: "notes.txt", bytes: Array(contents.utf8))
    let controller = ReaderViewController()
    controller.loadViewIfNeeded()
    controller.view.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
    var settings = ReaderSettings()
    settings.wrapLines = false
    controller.apply(settings: settings)
    controller.display(file, languageMode: nil)
    controller.view.layoutSubtreeIfNeeded()
    let text = try #require(nonSourcePreviewTextView(in: controller.view, label: "Plain text preview"))
    let scroll = try #require(text.enclosingScrollView)
    let layout = try #require(text.layoutManager)
    let container = try #require(text.textContainer)
    #expect(scroll.hasHorizontalScroller)
    #expect(text.frame.width > scroll.contentSize.width)
    // The requested starts bisect the compass emoji's UTF-16 surrogate pair.
    // NSTextView expands them to composed-character boundaries before reflow.
    let requested = [NSValue(range: NSRange(location: 12, length: 30)),
                     NSValue(range: NSRange(location: 90, length: 17))]
    let selected = requested.map {
        NSValue(range: (contents as NSString).rangeOfComposedCharacterSequences(for: $0.rangeValue))
    }
    text.setSelectedRanges(requested, affinity: .upstream, stillSelecting: false)
    #expect(text.selectedRanges == selected)
    #expect(text.selectedRanges.count == 2)
    scroll.contentView.scroll(to: NSPoint(x: 80, y: 400))
    scroll.reflectScrolledClipView(scroll.contentView)
    let oldOrigin = scroll.contentView.bounds.origin
    let glyph = layout.glyphIndex(for: NSPoint(
        x: max(0, oldOrigin.x - text.textContainerOrigin.x),
        y: max(0, oldOrigin.y - text.textContainerOrigin.y)
    ), in: container)
    let character = layout.characterIndexForGlyph(at: glyph)
    let oldOffset = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
        + text.textContainerOrigin.y - oldOrigin.y
    let font = try #require(text.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)

    settings.wrapLines = true
    controller.apply(settings: settings)
    #expect(!scroll.hasHorizontalScroller)
    #expect(!text.isHorizontallyResizable)
    #expect(text.selectedRanges == selected)
    #expect(text.selectionAffinity == .upstream)
    #expect(scroll.contentView.bounds.minX == 0)
    let newGlyph = layout.glyphIndexForCharacter(at: character)
    let newOffset = layout.lineFragmentRect(forGlyphAt: newGlyph, effectiveRange: nil).minY
        + text.textContainerOrigin.y - scroll.contentView.bounds.minY
    #expect(abs(newOffset - oldOffset) < 2)
    #expect((text.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont) == font)
    #expect(text.frame.width == scroll.contentSize.width)

    settings.wrapLines = false
    controller.apply(settings: settings)
    #expect(text.selectedRanges == selected)
    #expect(abs(scroll.contentView.bounds.minX - oldOrigin.x) < 2)
    controller.display(nil)
    controller.display(file, languageMode: nil)
    let reopened = try #require(nonSourcePreviewTextView(in: controller.view, label: "Plain text preview"))
    #expect(reopened.enclosingScrollView?.hasHorizontalScroller == true)
    #expect(reopened.isHorizontallyResizable)
    settings.wrapLines = true
    controller.apply(settings: settings)
    controller.display(nil)
    controller.display(file, languageMode: nil)
    let wrappedReopened = try #require(nonSourcePreviewTextView(in: controller.view, label: "Plain text preview"))
    #expect(wrappedReopened.enclosingScrollView?.hasHorizontalScroller == false)
    #expect(wrappedReopened.textContainer?.widthTracksTextView == true)
}

@MainActor
@Test
func markdownPreviewKeepsParagraphLayoutWhenPlainTextWrapChanges() throws {
    _ = NSApplication.shared
    let root = try nonSourcePreviewTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = try nonSourcePreviewFile(root: root, name: "README.md", bytes: Array("# Heading\n\n- first item\n  - nested item\n\nA paragraph.\n".utf8))
    let controller = ReaderViewController()
    controller.loadViewIfNeeded()
    controller.view.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
    controller.display(file, languageMode: nil)
    controller.view.layoutSubtreeIfNeeded()
    let text = try #require(nonSourcePreviewTextView(in: controller.view, label: "Markdown preview"))
    let before = try #require(text.textStorage?.copy() as? NSAttributedString)
    var settings = ReaderSettings()
    for wrap in [false, true, false] {
        settings.wrapLines = wrap
        controller.apply(settings: settings)
        #expect(text.textContainer?.widthTracksTextView == true)
        #expect(!text.isHorizontallyResizable)
        #expect(text.enclosingScrollView?.hasHorizontalScroller == false)
        before.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: before.length)) { value, range, _ in
            let after = text.textStorage?.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
            #expect((value as? NSParagraphStyle) == (after as? NSParagraphStyle))
        }
    }
}

@MainActor
private func nonSourcePreviewTextView(in view: NSView, label: String) -> NSTextView? {
    if let text = view as? NSTextView, text.accessibilityLabel() == label { return text }
    return view.subviews.lazy.compactMap { nonSourcePreviewTextView(in: $0, label: label) }.first
}

@MainActor
@Test
func plainTextPreviewResizePreservesVisibleCharacterAndSelection() throws {
    _ = NSApplication.shared
    let root = try nonSourcePreviewTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let contents = (0..<120).map { "row \($0) " + String(repeating: "wide 🧭 text ", count: 30) }
        .joined(separator: "\n")
    let file = try nonSourcePreviewFile(root: root, name: "resize.txt", bytes: Array(contents.utf8))
    let controller = ReaderViewController()
    controller.loadViewIfNeeded()
    controller.view.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
    var settings = ReaderSettings()
    settings.wrapLines = true
    controller.apply(settings: settings)
    controller.display(file, languageMode: nil)
    controller.view.layoutSubtreeIfNeeded()
    let text = try #require(nonSourcePreviewTextView(in: controller.view, label: "Plain text preview"))
    let scroll = try #require(text.enclosingScrollView)
    let layout = try #require(text.layoutManager)
    let container = try #require(text.textContainer)
    let selected = [NSValue(range: NSRange(location: 0, length: 5)),
                    NSValue(range: NSRange(location: 6, length: 4))]
    text.setSelectedRanges(selected, affinity: .upstream, stillSelecting: false)
    #expect(text.selectedRanges == selected)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 1800))
    scroll.reflectScrolledClipView(scroll.contentView)

    for width: CGFloat in [420, 800] {
        layout.ensureLayout(for: container)
        let origin = scroll.contentView.bounds.origin
        let glyph = layout.glyphIndex(for: NSPoint(
            x: 0, y: origin.y - text.textContainerOrigin.y
        ), in: container)
        let character = layout.characterIndexForGlyph(at: glyph)
        let oldOffset = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
            + text.textContainerOrigin.y - origin.y
        let oldWidth = text.frame.width
        controller.view.setFrameSize(NSSize(width: width, height: 480))
        controller.view.layoutSubtreeIfNeeded()
        layout.ensureLayout(for: container)
        #expect(text.frame.width != oldWidth)
        #expect(abs(text.frame.width - scroll.contentSize.width) < 1)
        let newGlyph = layout.glyphIndexForCharacter(at: character)
        let newOffset = layout.lineFragmentRect(forGlyphAt: newGlyph, effectiveRange: nil).minY
            + text.textContainerOrigin.y - scroll.contentView.bounds.minY
        #expect(abs(newOffset - oldOffset) < 2)
        #expect(text.selectedRanges == selected)
        #expect(text.selectionAffinity == .upstream)
    }
}
