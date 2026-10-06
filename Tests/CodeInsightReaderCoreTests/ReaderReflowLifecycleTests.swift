import AppKit
import CodeInsightCore
import CodeInsightReaderCore
import Testing
import os
@testable import CodeInsightReaderUI

@MainActor
@Test
func readonlyCostGateRunsBeforeNativeAnchorCapture() {
    _ = NSApplication.shared
    let document = ReaderDocument(bytes: Array(("// " + String(repeating: "long ", count: 100)).utf8))
    let reader = ReaderTextView(derivedDataStore: ReaderDerivedDataStore(),
                              reflowPolicy: ReaderReflowPolicy(maximumSynchronousLineBytes: 64))
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 700, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { reader.stopPendingReaderWork(); window.close() }
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
    scroll.documentView = reader.view
    window.contentView = scroll
    reader.view.frame = scroll.contentView.bounds
    reader.configureGutter(in: scroll, lineNumbers: true)
    reader.display(document: document)
    let captures = reader.viewportGeometryCaptureCount
    var settings = ReaderSettings()
    settings.fontSize += 1
    reader.apply(settings: settings)
    #expect(reader.viewportGeometryCaptureCount == captures)
    #expect(reader.lastViewportRestoreWasLimited)
    #expect(reader.lastViewportAnchorErrorPt == nil)
    #expect(reader.lastViewportRestoreLimitation == "cost-limited-capture")
}

@MainActor
@Test
func readonlyTerminalStopCancelsQueuedWidthRestoreWithoutClearingText() {
    _ = NSApplication.shared
    var settings = ReaderSettings()
    settings.wrapLines = true
    let reader = ReaderTextView(settings: settings)
    let bytes = Array(String(repeating: "fn line() { let value = 42; }\n", count: 100).utf8)
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 700, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
    scroll.documentView = reader.view
    window.contentView = scroll
    reader.view.frame = scroll.contentView.bounds
    reader.configureGutter(in: scroll, lineNumbers: true)
    reader.display(document: ReaderDocument(bytes: bytes))
    reader.view.setFrameSize(NSSize(width: 600, height: reader.view.frame.height))
    #expect(reader.reflowDiagnostics.widthPending)
    let passes = reader.viewportRestorePassCount
    reader.stopPendingReaderWork()
    reader.processPendingViewportRestoresForTesting()
    reader.view.setFrameSize(NSSize(width: 500, height: reader.view.frame.height))
    reader.processPendingViewportRestoresForTesting()
    #expect(reader.viewportRestorePassCount == passes)
    #expect(reader.displayedBytes == bytes)
}

@MainActor
@Test
func readonlyResizeUserScrollResizeUsesTheUsersNewPosition() async throws {
    let document = ReaderDocument(bytes: Array((0..<400).map { "// row \($0): source text\n" }.joined().utf8))
    let (reader, scroll, window) = s6NativeReader(document)
    defer { reader.stopPendingReaderWork(); window.close() }
    func turn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
    func nativePaintTurn() {
        window.layoutIfNeeded()
        window.displayIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
    }
    for _ in 0..<3 { nativePaintTurn(); await turn() }
    window.setContentSize(NSSize(width: 620, height: 400))
    window.layoutIfNeeded()
    reader.configureGutter(in: scroll, lineNumbers: true)
    #expect(reader.reflowDiagnostics.widthCapture)
    let original = scroll.contentView.bounds.minY
    let cgEvent = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                      wheelCount: 1, wheel1: -320, wheel2: 0, wheel3: 0))
    let wheel = try #require(NSEvent(cgEvent: cgEvent))
    var expectedBounds = scroll.contentView.bounds
    expectedBounds.origin.y -= wheel.scrollingDeltaY
    let expectedY = scroll.contentView.constrainBoundsRect(expectedBounds).minY
    // Cancellation is synchronous; AppKit applies the actual wheel delta on its run loop.
    try readonlyWaitForWheelTarget(scroll, expectedY: expectedY) {
        reader.view.scrollWheel(with: wheel)
        #expect(!reader.reflowDiagnostics.widthCapture)
    }
    for _ in 0..<4 { nativePaintTurn(); await turn() }
    #expect(scroll.contentView.bounds.minY > original + 10)
    let beforeQueryBounds = scroll.contentView.bounds
    let beforeQueryFrame = reader.view.frame
    let desiredByte = try #require(reader.firstVisibleByteOffset())
    #expect(scroll.contentView.bounds == beforeQueryBounds)
    #expect(reader.view.frame == beforeQueryFrame)
    #expect(scroll.contentView.bounds.minY > original + 10, "Reading the visible source must not undo completed user scrolling")
    let desiredLine = try #require(document.lineTable.lineColumn(at: desiredByte)?.line)
    window.setContentSize(NSSize(width: 560, height: 400))
    window.layoutIfNeeded()
    reader.configureGutter(in: scroll, lineNumbers: true)
    for _ in 0..<4 { nativePaintTurn(); await turn() }
    let actualByte = try #require(reader.firstVisibleByteOffset())
    let actualLine = try #require(document.lineTable.lineColumn(at: actualByte)?.line)
    #expect(abs(Int(actualLine) - Int(desiredLine)) <= 1)
}

@MainActor
@Test
func readonlyNaturalBoundsMovementDoesNotCancelReflow() {
    let document = ReaderDocument(bytes: Array(String(repeating: "// short source line\n", count: 200).utf8))
    let (reader, scroll, window) = s6NativeReader(document)
    defer { reader.stopPendingReaderWork(); window.close() }
    reader.view.setFrameSize(NSSize(width: 620, height: reader.view.frame.height))
    let before = reader.reflowDiagnostics
    #expect(before.widthCapture && before.widthPending)
    // Same notification emitted by TextKit when document geometry converges;
    // no wheel/keyboard/live-scroll input has happened.
    scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: 12))
    #expect(reader.reflowDiagnostics.generation == before.generation)
    #expect(reader.reflowDiagnostics.widthCapture)
    #expect(reader.reflowDiagnostics.widthPending)
}

@MainActor
@Test(.readerFontEnvironment)
func readonlyFontEnvironmentChangeRejectsQueuedOldCorrection() {
    let document = ReaderDocument(bytes: Array(String(repeating: "// source line\n", count: 100).utf8))
    let (reader, _, window) = s6NativeReader(document)
    defer { reader.stopPendingReaderWork(); window.close() }
    var settings = ReaderSettings()
    settings.fontSize += 1
    reader.apply(settings: settings)
    let passes = reader.viewportRestorePassCount
    ReaderFontResolver.shared.refresh()
    reader.processPendingViewportCorrection()
    #expect(reader.viewportRestorePassCount == passes)
    #expect(!reader.reflowDiagnostics.correctionPending)
}

@MainActor
@Test
func readonlyLimitedLongLineRetainsHorizontalPositionAcrossWrapRoundTrip() throws {
    let document = ReaderDocument(bytes: Array(("// " + String(repeating: "wide ", count: 240)).utf8))
    var settings = ReaderSettings()
    settings.wrapLines = false
    let (reader, scroll, window) = s6NativeReader(document, settings: settings,
        policy: ReaderReflowPolicy(maximumSynchronousLineBytes: 64))
    defer { reader.stopPendingReaderWork(); window.close() }
    scroll.contentView.scroll(to: NSPoint(x: 140, y: 0))
    let originalX = scroll.contentView.bounds.minX
    try #require(originalX > 100)
    let ranges = reader.view.selectedRanges
    settings.wrapLines = true
    reader.apply(settings: settings)
    settings.wrapLines = false
    reader.apply(settings: settings)
    #expect(abs(scroll.contentView.bounds.minX - originalX) < 1)
    #expect(reader.view.selectedRanges == ranges)
    #expect(reader.lastViewportRestoreWasLimited)
    #expect(reader.lastViewportAnchorErrorPt == nil)
}

@MainActor
private func s6NativeReader(
    _ document: ReaderDocument,
    settings: ReaderSettings = { var value = ReaderSettings(); value.wrapLines = true; return value }(),
    policy: ReaderReflowPolicy = ReaderReflowPolicy()
) -> (ReaderTextView, NSScrollView, NSWindow) {
    _ = NSApplication.shared
    let reader = ReaderTextView(settings: settings, derivedDataStore: ReaderDerivedDataStore(), reflowPolicy: policy)
    let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 700, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
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
    reader.processPendingViewportRestoresForTesting()
    return (reader, scroll, window)
}

@MainActor
@Test(.isolatedReaderWorkCounters)
func readonlyMissingPreviousViewportNeverEnumeratesFullExtentForHighCostDocument() {
    var settings = ReaderSettings()
    settings.wrapLines = false
    let document = ReaderDocument(bytes: Array(String(repeating: "// line\n", count: 200).utf8))
    let (reader, _, window) = s6NativeReader(document, settings: settings,
        policy: ReaderReflowPolicy(maximumSynchronousLineCount: 100))
    defer { reader.stopPendingReaderWork(); window.close() }
    // Force a width transition and inject missing OLD viewport state. The
    // current native viewport may exist; this explicitly tests the nil branch.
    reader.view.textContainer?.containerSize = NSSize(width: 700, height: CGFloat.greatestFiniteMagnitude)
    let before = ReaderWorkCounters.snapshot()
    reader.configureWrappingForTesting(previousViewportStart: nil)
    let after = ReaderWorkCounters.snapshot()
    let costAware = ProcessInfo.processInfo.environment["CAIRN_READONLY_REFLOW"] != "0"
    #expect(after.applicationFullLayoutCount - before.applicationFullLayoutCount == (costAware ? 0 : 1))
    #expect(reader.displayedBytes == document.bytes)
    #expect(reader.view.textLayoutManager != nil)
    if costAware {
        #expect(reader.lastViewportRestoreLimitation == "no-previous-viewport")
        #expect(reader.lastViewportRestoreWasLimited)
        #expect(reader.lastViewportAnchorErrorPt == nil)
    }
}

@MainActor
func readonlyWaitForWheelTarget(_ scroll: NSScrollView, expectedY: CGFloat, action: () -> Void) throws {
    let ended = OSAllocatedUnfairLock(initialState: false)
    let observer = NotificationCenter.default.addObserver(
        forName: NSScrollView.didEndLiveScrollNotification, object: scroll, queue: nil
    ) { _ in ended.withLock { $0 = true } }
    defer { NotificationCenter.default.removeObserver(observer) }
    action()
    let deadline = Date(timeIntervalSinceNow: 1)
    // Reaching the target can precede AppKit's end-of-scroll notification.
    // Starting a new layout then would overlap two different test actions.
    while (!ended.withLock({ $0 }) || abs(scroll.contentView.bounds.minY - expectedY) > 1), Date() < deadline {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
    }
    try #require(ended.withLock { $0 }, "Native wheel tracking did not finish")
    try #require(abs(scroll.contentView.bounds.minY - expectedY) <= 1)
}
