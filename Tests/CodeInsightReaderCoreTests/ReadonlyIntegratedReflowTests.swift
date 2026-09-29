@preconcurrency import AppKit
import CodeInsightCore
import CodeInsightReaderCore
import Foundation
import Testing
@testable import CodeInsightReaderUI

private func readonlyIntegratedSource() -> String {
    (0..<180).map { index in
        "pub fn entry_\(index)(value: usize) -> usize {\n"
            + "    // 中文🚀e\u{301} " + String(repeating: "source anchor before deferred syntax; ", count: 7) + "\n"
            + "    let result = value + \(index);\n    result\n}\n"
    }.joined()
}

private func readonlyIntegratedPlain(_ source: String) -> ReaderDocument {
    let bytes = Array(source.utf8)
    return ReaderDocument(bytes: bytes, lineTable: LineTable(bytes: bytes),
        byteUTF16Map: ByteUTF16Map(validUTF8: bytes), highlightSpans: [], outlineFacets: [],
        foldRegions: [], analysisPhase: .plain)
}

/// Uses the real detached DocumentLoader callback, not a synchronous test substitute.
private func readonlyIntegratedSyntax(_ plain: ReaderDocument) async throws -> ReaderDocument {
    try await withCheckedThrowingContinuation { continuation in
        DocumentLoader().loadSyntax(for: plain) { result in continuation.resume(with: result) }
    }
}

@MainActor
private func readonlyIntegratedReader(
    document: ReaderDocument, settings: ReaderSettings, width: CGFloat, x: CGFloat,
    store: ReaderDerivedDataStore
) -> (reader: ReaderTextView, scroll: NSScrollView, window: NSWindow) {
    _ = NSApplication.shared
    let reader = ReaderTextView(settings: settings, derivedDataStore: store)
    let window = NSWindow(contentRect: NSRect(x: x, y: 100, width: width, height: 340),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: 340))
    scroll.hasVerticalScroller = true
    scroll.documentView = reader.view
    window.contentView = scroll
    reader.view.frame = scroll.contentView.bounds
    reader.configureGutter(in: scroll, lineNumbers: true)
    reader.display(document: document)
    window.makeKeyAndOrderFront(nil)
    return (reader, scroll, window)
}

/// Same real main-queue/layout pattern as ReaderReflowMergedTicketTests. A turn
/// does not imply success: callers also require the measured row/selection state.
@MainActor
private func readonlyIntegratedTurn(_ readers: [ReaderTextView], windows: [NSWindow]) async {
    for window in windows { window.layoutIfNeeded() }
    for reader in readers {
        reader.view.textLayoutManager?.textViewportLayoutController.layoutViewport()
        let visible = reader.view.visibleRect.intersection(reader.view.bounds)
        if !visible.isEmpty, let bitmap = reader.view.bitmapImageRepForCachingDisplay(in: visible) {
            reader.view.cacheDisplay(in: visible, to: bitmap)
        }
    }
    for window in windows { window.displayIfNeeded() }
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}

@MainActor
private func readonlyIntegratedReadingPosition(
    _ reader: ReaderTextView, window: NSWindow, source: String, entry: Int
) async throws -> (display: Int, byte: UInt32, offset: CGFloat, selection: NSRange) {
    let string = source as NSString
    let header = string.range(of: "pub fn entry_\(entry)(")
    try #require(header.location != NSNotFound)
    let comment = string.range(of: "中文🚀e\u{301}", options: [],
        range: NSRange(location: NSMaxRange(header), length: string.length - NSMaxRange(header)))
    try #require(comment.location != NSNotFound)
    let readingByte = try #require(reader.byteOffset(forCharacterIndex: comment.location))
    // Use the Reader's real navigation entry point so this new reading
    // position ends any previous reflow sequence, just as application navigation does.
    reader.reveal(byteOffset: readingByte)
    reader.view.setSelectedRanges([NSValue(range: comment)], affinity: .upstream, stillSelecting: false)
    for _ in 0..<4 { await readonlyIntegratedTurn([reader], windows: [window]) }
    let visible = reader.view.visibleRect
    try #require(visible.minY > 400)
    let display = reader.view.characterIndexForInsertion(at: NSPoint(
        x: visible.midX, y: visible.minY + visible.height * 0.25))
    let byte = try #require(reader.byteOffset(forCharacterIndex: display))
    let row = try #require(ReaderViewportGeometry.rowRect(containingDisplayLocation: display, in: reader.view))
    let scroll = try #require(reader.view.enclosingScrollView)
    return (display, byte, row.minY - scroll.contentView.bounds.minY, comment)
}

@MainActor
private func readonlyIntegratedAnchorError(_ reader: ReaderTextView, display: Int, offset: CGFloat) -> CGFloat? {
    guard let scroll = reader.view.enclosingScrollView,
          let row = ReaderViewportGeometry.rowRect(containingDisplayLocation: display, in: reader.view) else { return nil }
    return abs(row.minY - scroll.contentView.bounds.minY - offset)
}

@MainActor
private func readonlyIntegratedCopy(_ reader: ReaderTextView) throws -> String {
    let board = NSPasteboard(name: .init("readonly-integrated-copy-\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    try #require(reader.view.writeSelection(to: board, types: reader.view.writablePasteboardTypes))
    return try #require(board.string(forType: .string))
}

@MainActor
@Test(.timeLimit(.minutes(2)))
func readonlyIntegratedDeferredSyntaxKeepsMiddleAndEndSourceAnchors() async throws {
    let source = readonlyIntegratedSource()
    for entry in [90, 172] {
        let plain = readonlyIntegratedPlain(source)
        var settings = ReaderSettings(functionNameDelta: 3, humanistComments: true)
        settings.wrapLines = true
        let (reader, _, window) = readonlyIntegratedReader(document: plain, settings: settings,
            width: 650, x: 100, store: ReaderDerivedDataStore())
        defer { reader.stopPendingReaderWork(); window.close() }
        await reader.waitForIdentifierPreparation()
        for _ in 0..<3 { await readonlyIntegratedTurn([reader], windows: [window]) }
        let anchor = try await readonlyIntegratedReadingPosition(reader, window: window, source: source, entry: entry)
        let position = Double(anchor.byte) / Double(plain.bytes.count)
        if entry == 90 { #expect(position > 0.35 && position < 0.65) }
        else { #expect(position > 0.8) }
        #expect(plain.highlightSpans.isEmpty)
        #expect(plain.analysisKey.phase == .plain)
        let selected = reader.view.selectedRanges
        let affinity = reader.view.selectionAffinity
        let copied = try readonlyIntegratedCopy(reader)
        #expect(copied == "中文🚀e\u{301}")
        let installs = reader.projectionInstallCount
        let updates = reader.typographyAttributeUpdateCount
        let draws = reader.backgroundDrawCount

        // Parsing starts only after the plain Reader has a measured nonzero
        // source position and selection. Resume on MainActor to deliver it.
        let syntax = try await readonlyIntegratedSyntax(plain)
        try #require(!syntax.highlightSpans.isEmpty && !syntax.outlineFacets.isEmpty)
        #expect(syntax.analysisKey.phase == .syntax)
        #expect(syntax.contentID == plain.contentID)
        #expect(reader.view.selectedRanges == selected)
        let clip = try #require(reader.view.enclosingScrollView?.contentView)
        let clipBefore = clip.bounds
        let capturesBefore = reader.viewportGeometryCaptureCount
        let passesBefore = reader.viewportRestorePassCount
        let preUpdateDrift = readonlyIntegratedAnchorError(reader, display: anchor.display, offset: anchor.offset)
        let preVisible = reader.view.visibleRect
        let preProbe = reader.view.characterIndexForInsertion(
            at: NSPoint(x: preVisible.midX, y: preVisible.minY + preVisible.height * 0.25))
        reader.updateSyntax(document: syntax)
        let clipAfterUpdate = clip.bounds
        let restoreAfterUpdate = "\(reader.viewportRestorePassCount - passesBefore)/"
            + "\(reader.lastViewportAnchorErrorPt.map { "\($0)" } ?? "nil")/"
            + (reader.lastViewportRestoreLimitation ?? "-")
        await reader.waitForIdentifierPreparation()
        var trace: [String] = []
        for _ in 0..<24 {
            await readonlyIntegratedTurn([reader], windows: [window])
            let turnError = readonlyIntegratedAnchorError(reader, display: anchor.display, offset: anchor.offset)
            let flags = reader.reflowDiagnostics
            trace.append(String(format: "%.2f", Double(turnError ?? -1))
                + "\(flags.widthPending ? "w" : "")\(flags.correctionPending ? "c" : "")")
            if !flags.widthPending, !flags.correctionPending,
               let error = turnError, error <= 2, reader.backgroundDrawCount > draws { break }
        }
        let error = try #require(readonlyIntegratedAnchorError(reader, display: anchor.display, offset: anchor.offset))
        let row = ReaderViewportGeometry.rowRect(containingDisplayLocation: anchor.display, in: reader.view)
        #expect(error <= 2, """
            entry=\(entry), source=\(anchor.byte), drift=\(error)pt, offset=\(anchor.offset), \
            row=\(String(describing: row)), draws=\(draws)->\(reader.backgroundDrawCount), \
            reflow=\(reader.reflowDiagnostics), limited=\(reader.lastViewportRestoreWasLimited), \
            scale=\(window.backingScaleFactor), trace=\(trace), \
            preUpdateDrift=\(String(describing: preUpdateDrift)), \
            probe=\(anchor.display)->\(preProbe), \
            clip=\(clipBefore)->\(clipAfterUpdate)->\(clip.bounds), doc=\(reader.view.frame.size), \
            captures=\(reader.viewportGeometryCaptureCount - capturesBefore), \
            restore(passes/error/limit) update=\(restoreAfterUpdate) final=\(reader.viewportRestorePassCount - passesBefore)/\
            \(reader.lastViewportAnchorErrorPt.map { "\($0)" } ?? "nil")/\(reader.lastViewportRestoreLimitation ?? "-")
            """)
        #expect(!reader.reflowDiagnostics.widthPending && !reader.reflowDiagnostics.correctionPending)
        #expect(!reader.lastViewportRestoreWasLimited)
        #expect(reader.byteOffset(forCharacterIndex: anchor.display) == anchor.byte)
        #expect(reader.view.selectedRanges == selected)
        #expect(reader.view.selectionAffinity == affinity)
        #expect(try readonlyIntegratedCopy(reader) == copied)
        #expect(reader.displayedBytes == plain.bytes)
        #expect(reader.view.string == source)
        #expect(reader.projectionInstallCount == installs)
        #expect(reader.typographyAttributeUpdateCount > updates)
        #expect(reader.backgroundDrawCount > draws)
    }
}

@MainActor
@Test(.timeLimit(.minutes(2)))
func readonlyIntegratedTwoWindowFontEnvironmentKeepsIndependentAnchorsAndSelections() async throws {
    let source = readonlyIntegratedSource()
    let document = try await readonlyIntegratedSyntax(readonlyIntegratedPlain(source))
    let store = ReaderDerivedDataStore()
    var narrowSettings = ReaderSettings(fontSize: 13, codeFont: .postScriptName("Menlo-Regular"))
    narrowSettings.wrapLines = true
    var wideSettings = ReaderSettings(fontSize: 17, codeFont: .postScriptName("Menlo-Regular"))
    wideSettings.wrapLines = true
    let first = readonlyIntegratedReader(document: document, settings: narrowSettings, width: 500, x: 40, store: store)
    let second = readonlyIntegratedReader(document: document, settings: wideSettings, width: 790, x: 570, store: store)
    defer {
        first.reader.stopPendingReaderWork(); second.reader.stopPendingReaderWork()
        first.window.close(); second.window.close()
    }
    await first.reader.waitForIdentifierPreparation()
    await second.reader.waitForIdentifierPreparation()
    for _ in 0..<3 { await readonlyIntegratedTurn([first.reader, second.reader], windows: [first.window, second.window]) }
    #expect(first.window.isVisible && second.window.isVisible)
    #expect(abs(first.scroll.contentView.bounds.width - second.scroll.contentView.bounds.width) > 200)
    #expect(await store.statistics.buildCount == 1)
    #expect(await store.statistics.subscriptionCount == 2)
    let firstAnchor = try await readonlyIntegratedReadingPosition(first.reader, window: first.window, source: source, entry: 45)
    let secondAnchor = try await readonlyIntegratedReadingPosition(second.reader, window: second.window, source: source, entry: 135)
    #expect(firstAnchor.byte != secondAnchor.byte)
    let firstSelection = first.reader.view.selectedRanges
    let secondSelection = second.reader.view.selectedRanges
    let firstAffinity = first.reader.view.selectionAffinity
    let secondAffinity = second.reader.view.selectionAffinity
    let firstCopy = try readonlyIntegratedCopy(first.reader)
    let secondCopy = try readonlyIntegratedCopy(second.reader)
    let updates = [first.reader.typographyAttributeUpdateCount, second.reader.typographyAttributeUpdateCount]
    let installs = [first.reader.projectionInstallCount, second.reader.projectionInstallCount]
    let draws = [first.reader.backgroundDrawCount, second.reader.backgroundDrawCount]
    let oldRevision = ReaderFontResolver.shared.fontEnvironmentRevision
    ReaderFontResolver.shared.refresh()
    #expect(ReaderFontResolver.shared.fontEnvironmentRevision > oldRevision)
    // The existing app notification path broadcasts current settings in this
    // order. Host propagation has a separate AppDelegate test; this checks both
    // simultaneously mounted native Readers against their independent anchors.
    first.reader.apply(settings: narrowSettings)
    second.reader.apply(settings: wideSettings)
    for _ in 0..<24 {
        await readonlyIntegratedTurn([first.reader, second.reader], windows: [first.window, second.window])
        if !first.reader.reflowDiagnostics.correctionPending, !second.reader.reflowDiagnostics.correctionPending,
           !first.reader.reflowDiagnostics.widthPending, !second.reader.reflowDiagnostics.widthPending,
           let a = readonlyIntegratedAnchorError(first.reader, display: firstAnchor.display, offset: firstAnchor.offset),
           let b = readonlyIntegratedAnchorError(second.reader, display: secondAnchor.display, offset: secondAnchor.offset),
           a <= 2, b <= 2 { break }
    }
    for (reader, anchor, selected, affinity, copied, size, index) in [
        (first.reader, firstAnchor, firstSelection, firstAffinity, firstCopy, narrowSettings.fontSize, 0),
        (second.reader, secondAnchor, secondSelection, secondAffinity, secondCopy, wideSettings.fontSize, 1),
    ] {
        let error = try #require(readonlyIntegratedAnchorError(reader, display: anchor.display, offset: anchor.offset))
        #expect(error <= 2, "window=\(index), source=\(anchor.byte), drift=\(error)pt")
        #expect(!reader.reflowDiagnostics.widthPending && !reader.reflowDiagnostics.correctionPending)
        #expect(!reader.lastViewportRestoreWasLimited)
        #expect(reader.byteOffset(forCharacterIndex: anchor.display) == anchor.byte)
        #expect(reader.view.selectedRanges == selected)
        #expect(reader.view.selectionAffinity == affinity)
        #expect(try readonlyIntegratedCopy(reader) == copied)
        #expect(reader.displayedBytes == document.bytes && reader.view.string == source)
        #expect(reader.typographyAttributeUpdateCount == updates[index] + 1)
        #expect(reader.projectionInstallCount == installs[index])
        #expect(reader.backgroundDrawCount > draws[index])
        let font = try #require(reader.view.textStorage?.attribute(.font, at: anchor.selection.location, effectiveRange: nil) as? NSFont)
        // The anchor sits in a prose comment, which renders one point larger.
        #expect(font.pointSize == ReaderTextView.proseCommentFont(size: size).pointSize)
    }
    #expect(await store.statistics.buildCount == 1)
    #expect(await store.statistics.subscriptionCount == 2)
}

@MainActor
private func readonlyIntegratedFoldProvider(_ reader: ReaderTextView) throws -> NSTextAttachmentViewProvider {
    let manager = try #require(reader.view.textLayoutManager)
    let content = try #require(manager.textContentManager)
    var result: NSTextAttachmentViewProvider?
    manager.enumerateTextLayoutFragments(from: content.documentRange.location, options: [.ensuresLayout]) { fragment in
        result = fragment.textAttachmentViewProviders.first
        return result == nil
    }
    return try #require(result)
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func readonlyIntegratedLocalizedFoldSummaryUpdatesGeometryWithoutCharacters() async throws {
    let source = "fn demo() {\n    let first = 1;\n    let second = first;\n    first + second\n}\n"
    let parsed = try await readonlyIntegratedSyntax(readonlyIntegratedPlain(source))
    let parsedFold = try #require(parsed.foldRegions.first { $0.kind == .declaration })
    func document(leadingText: String?) -> ReaderDocument {
        let fold = FoldRegion(id: parsedFold.id, kind: parsedFold.kind, headerRange: parsedFold.headerRange,
            bodyRange: parsedFold.bodyRange, outlineDepth: parsedFold.outlineDepth,
            summary: FoldSummary(hiddenLineCount: parsedFold.summary.hiddenLineCount, leadingText: leadingText))
        return ReaderDocument(bytes: parsed.bytes, lineTable: parsed.lineTable, byteUTF16Map: parsed.byteUTF16Map,
            highlightSpans: parsed.highlightSpans, outlineFacets: parsed.outlineFacets, foldRegions: [fold])
    }
    let original = document(leadingText: nil)
    var settings = ReaderSettings()
    settings.wrapLines = true
    let (reader, _, window) = readonlyIntegratedReader(document: original, settings: settings,
        width: 700, x: 100, store: ReaderDerivedDataStore())
    defer { reader.stopPendingReaderWork(); window.close() }
    await reader.waitForIdentifierPreparation()
    for _ in 0..<3 { await readonlyIntegratedTurn([reader], windows: [window]) }
    #expect(reader.toggleFold(id: parsedFold.id))
    await readonlyIntegratedTurn([reader], windows: [window])
    let oldProvider = try readonlyIntegratedFoldProvider(reader)
    let oldAttachment = try #require(oldProvider.textAttachment)
    let oldView = try #require(oldProvider.view)
    let oldWidth = oldView.bounds.width
    let projection = reader.view.string
    let installs = reader.projectionInstallCount
    let draws = reader.backgroundDrawCount
    let updated = document(leadingText: "A deliberately long semantic summary for the same captured source body")
    #expect(updated.contentID == original.contentID)
    #expect(updated.foldRegions[0].bodyRange == original.foldRegions[0].bodyRange)
    reader.updateSyntax(document: updated)
    await reader.waitForIdentifierPreparation()
    for _ in 0..<8 { await readonlyIntegratedTurn([reader], windows: [window]) }
    let provider = try readonlyIntegratedFoldProvider(reader)
    let chip = try #require(provider.view)
    #expect(provider.textAttachment !== oldAttachment)
    #expect(chip.bounds.width > oldWidth)
    #expect(chip.bounds.width.isFinite && chip.bounds.height > 0)
    #expect(reader.view.string == projection)
    #expect(reader.displayedBytes == original.bytes)
    #expect(reader.projectionInstallCount == installs)
    #expect(reader.backgroundDrawCount > draws)
    #expect(chip.accessibilityLabel() == CodeInsightReaderUI.localizedFormat(
        "reader.collapsed.lines", Int64(parsedFold.summary.hiddenLineCount)))
    let bitmap = try #require(chip.bitmapImageRepForCachingDisplay(in: chip.bounds))
    chip.cacheDisplay(in: chip.bounds, to: bitmap)
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0 && !png.isEmpty)
    print("READONLY_LOCALIZED_SUMMARY languages=\(Locale.preferredLanguages) oldWidth=\(oldWidth) newWidth=\(chip.bounds.width) label=\(chip.accessibilityLabel() ?? "") pngBytes=\(png.count)")
}
