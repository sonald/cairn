@preconcurrency import AppKit
import CodeInsightReaderCore
import Foundation
import Testing
@testable import CodeInsightReaderUI

@MainActor
private func readonlyMergedTicketMainQueueTurn() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}

@MainActor
@Test
func readonlyReflowWidthFontWidthBeforeQueueDrainPreservesSourceAndPixelAnchor() async throws {
    _ = NSApplication.shared
    let source = (0..<160).map { i in
        "// row \(i): " + String(repeating: "alpha_beta != gamma_delta; ", count: 12) + "\n"
    }.joined()
    let document = ReaderDocument(bytes: Array(source.utf8))
    var settings = ReaderSettings()
    settings.wrapLines = true
    settings.fontSize = 13
    let reader = ReaderTextView(settings: settings)
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 760, height: 420),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { reader.stopPendingReaderWork(); window.close() }
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 760, height: 420))
    scroll.hasVerticalScroller = true
    scroll.documentView = reader.view
    window.contentView = scroll
    reader.view.frame = scroll.contentView.bounds
    reader.configureGutter(in: scroll, lineNumbers: true)
    reader.display(document: document)
    window.makeKeyAndOrderFront(nil)
    for _ in 0..<3 {
        window.layoutIfNeeded()
        reader.view.textLayoutManager?.textViewportLayoutController.layoutViewport()
        await readonlyMergedTicketMainQueueTurn()
    }
    // Setup only: the subsequent mutations must preserve this nonzero reading position.
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 900))
    scroll.reflectScrolledClipView(scroll.contentView)
    reader.view.textLayoutManager?.textViewportLayoutController.layoutViewport()
    await readonlyMergedTicketMainQueueTurn()
    let visible = reader.view.visibleRect
    try #require(visible.minY > 400)
    let anchorDisplay = reader.view.characterIndexForInsertion(at: NSPoint(
        x: visible.midX, y: visible.minY + visible.height * 0.25))
    let anchorByte = try #require(reader.byteOffset(forCharacterIndex: anchorDisplay))
    let originalRow = try #require(ReaderViewportGeometry.rowRect(containingDisplayLocation: anchorDisplay, in: reader.view))
    let originalPixelOffset = originalRow.minY - scroll.contentView.bounds.minY
    let beforeContainerWidth = try #require(reader.view.textContainer?.size.width)

    // No await/run-loop pump between these operations. The final width must
    // inherit the original source anchor while using the newest font/geometry.
    window.setContentSize(NSSize(width: 620, height: 420))
    window.layoutIfNeeded()
    reader.configureGutter(in: scroll, lineNumbers: true)
    #expect(reader.reflowDiagnostics.widthPending)
    settings.fontSize = 19
    reader.apply(settings: settings)
    window.setContentSize(NSSize(width: 460, height: 420))
    window.layoutIfNeeded()
    reader.configureGutter(in: scroll, lineNumbers: true)
    #expect((reader.view.textContainer?.size.width ?? beforeContainerWidth) < beforeContainerWidth - 200)

    // Drive real native layout and the dispatched callbacks; never invoke a
    // processPending... test seam that would hide a lost queued ticket.
    for _ in 0..<12 {
        await readonlyMergedTicketMainQueueTurn()
        window.layoutIfNeeded()
        reader.view.textLayoutManager?.textViewportLayoutController.layoutViewport()
        window.displayIfNeeded()
        if !reader.reflowDiagnostics.widthPending && !reader.reflowDiagnostics.correctionPending,
           let row = ReaderViewportGeometry.rowRect(containingDisplayLocation: anchorDisplay, in: reader.view),
           abs(row.minY - scroll.contentView.bounds.minY - originalPixelOffset) <= 2 { break }
    }
    let finalRow = try #require(ReaderViewportGeometry.rowRect(containingDisplayLocation: anchorDisplay, in: reader.view))
    #expect(reader.byteOffset(forCharacterIndex: anchorDisplay) == anchorByte)
    #expect(abs(finalRow.minY - scroll.contentView.bounds.minY - originalPixelOffset) <= 2,
            "anchor=\(anchorByte), beforeOffset=\(originalPixelOffset), row=\(finalRow.minY), clip=\(scroll.contentView.bounds.minY)")

    // A later setting in the same uninterrupted sequence must keep that anchor,
    // not the intermediate geometry sampled between the first two widths.
    settings.fontSize = 17
    reader.apply(settings: settings)
    for _ in 0..<12 {
        await readonlyMergedTicketMainQueueTurn()
        reader.view.textLayoutManager?.textViewportLayoutController.layoutViewport()
        window.displayIfNeeded()
        if !reader.reflowDiagnostics.correctionPending { break }
    }
    let nextRow = try #require(ReaderViewportGeometry.rowRect(containingDisplayLocation: anchorDisplay, in: reader.view))
    #expect(abs(nextRow.minY - scroll.contentView.bounds.minY - originalPixelOffset) <= 2)
}
