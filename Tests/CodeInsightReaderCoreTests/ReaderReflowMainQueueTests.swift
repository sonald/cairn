@preconcurrency import AppKit
import CodeInsightCore
import CodeInsightReaderCore
import CodeInsightReaderUI
import Foundation
import Testing

@MainActor
private func readonlyAwaitQueuedReflowWork() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}

@MainActor
@Test
func readonlyReflowSupersededWidthTaskDrainsOnActualMainQueue() async {
    _ = NSApplication.shared
    let document = ReaderDocument(bytes: Array(String(repeating: "// source line for resizing\n", count: 100).utf8))
    var settings = ReaderSettings()
    settings.wrapLines = true
    let reader = ReaderTextView(settings: settings)
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 700, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { reader.stopPendingReaderWork(); window.close() }
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
    scroll.hasVerticalScroller = true
    scroll.documentView = reader.view
    window.contentView = scroll
    reader.view.frame = scroll.contentView.bounds
    reader.configureGutter(in: scroll, lineNumbers: true)
    reader.display(document: document)
    window.makeKeyAndOrderFront(nil)
    window.layoutIfNeeded()
    reader.view.textLayoutManager?.textViewportLayoutController.layoutViewport()
    await readonlyAwaitQueuedReflowWork()

    // These execute in one main-actor turn: the first width task cannot run
    // before the font transaction supersedes its captured generation.
    reader.view.setFrameSize(NSSize(width: 620, height: reader.view.frame.height))
    #expect(reader.reflowDiagnostics.widthPending)
    let generation = reader.reflowDiagnostics.generation
    settings.fontSize += 1
    reader.apply(settings: settings)
    #expect(reader.reflowDiagnostics.generation != generation)
    await readonlyAwaitQueuedReflowWork()
    #expect(!reader.reflowDiagnostics.widthPending)

    // A lost hasScheduledWidthReflow flag would suppress this new task too.
    reader.view.setFrameSize(NSSize(width: 560, height: reader.view.frame.height))
    #expect(reader.reflowDiagnostics.widthPending)
    await readonlyAwaitQueuedReflowWork()
    #expect(!reader.reflowDiagnostics.widthPending)
}

@MainActor
@Test(.isolatedReaderWorkCounters)
func readonlyReflowZeroGeometryPreservesDeferredUnwrappedExtentTransition() {
    _ = NSApplication.shared
    var settings = ReaderSettings()
    settings.wrapLines = false
    let reader = ReaderTextView(settings: settings)
    let document = ReaderDocument(bytes: Array(("// " + String(repeating: "wide ", count: 120) + "\n").utf8))
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 700, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { reader.stopPendingReaderWork(); window.close() }
    let scroll = NSScrollView(frame: .zero)
    scroll.hasVerticalScroller = true
    scroll.documentView = reader.view
    reader.configureGutter(in: scroll, lineNumbers: true)
    reader.display(document: document)
    // Keep the entire surface genuinely unmounted and zero-sized. Shrinking
    // only an attached clip view is undone immediately by NSScrollView tiling.
    reader.view.textContainer?.containerSize = NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude)
    let before = ReaderWorkCounters.snapshot().applicationFullLayoutCount
    reader.configureWrappingForTesting(previousViewportStart: nil)
    #expect(reader.lastViewportRestoreLimitation == "zero-geometry")
    #expect(reader.view.textContainer?.size.width == 100)
    #expect(ReaderWorkCounters.snapshot().applicationFullLayoutCount == before)

    window.contentView = scroll
    window.makeKeyAndOrderFront(nil)
    window.layoutIfNeeded()
    reader.configureWrappingForTesting(previousViewportStart: nil)
    #expect(ReaderWorkCounters.snapshot().applicationFullLayoutCount == before + 1)
    #expect(reader.view.frame.width > scroll.contentView.bounds.width + 200)
    scroll.contentView.scroll(to: NSPoint(x: 200, y: 0))
    scroll.reflectScrolledClipView(scroll.contentView)
    #expect(scroll.contentView.bounds.minX > 100)
    #expect(reader.displayedBytes == document.bytes)
}
