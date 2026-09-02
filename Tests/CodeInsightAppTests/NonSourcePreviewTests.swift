import AppKit
import CodeInsightCore
import CodeInsightReaderCore
import Foundation
import PDFKit
import Testing
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
        bytes: Array("# Title\n\ndisk bytes **Read** [guide](docs/guide.md)\n".utf8)
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
    #expect(state.renderedText?.contains("**") == false)
    #expect(state.linkCount == 1)
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
