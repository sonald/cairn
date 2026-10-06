@preconcurrency import AppKit
import CodeInsightCore
import CodeInsightReaderCore
import Foundation
import Testing
@testable import CodeInsightReaderUI

private func readonlyCommitFixture() -> ReaderDocument {
    let source = (0..<400).map { "\tlet v\($0) = \"中文🚀e\u{301}\";\r\n" }.joined()
    let bytes = Array(source.utf8)
    let lines = LineTable(bytes: bytes)
    func fold(_ id: UInt32, _ lower: Int, _ upper: Int) -> FoldRegion {
        FoldRegion(id: .init(rawValue: id), kind: .declaration,
            headerRange: .init(lowerBound: lines.lineStarts[lower - 1], upperBound: lines.lineStarts[lower]),
            bodyRange: .init(lowerBound: lines.lineStarts[lower], upperBound: lines.lineStarts[upper]),
            outlineDepth: 0, summary: .init(hiddenLineCount: upper - lower))
    }
    return ReaderDocument(bytes: bytes, lineTable: lines, byteUTF16Map: ByteUTF16Map(validUTF8: bytes),
        highlightSpans: [.init(range: .init(lowerBound: 0, upperBound: UInt32(bytes.count)), kind: .comment)],
        outlineFacets: [], foldRegions: [fold(1, 200, 204), fold(2, 300, 304)])
}

@MainActor
private func readonlyCommitReader(_ document: ReaderDocument) -> (ReaderTextView, NSWindow) {
    _ = NSApplication.shared
    var settings = ReaderSettings(humanistComments: true)
    settings.wrapLines = true
    let reader = ReaderTextView(settings: settings)
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 180))
    scroll.documentView = reader.view
    reader.view.frame = scroll.contentView.bounds
    let window = NSWindow(contentRect: scroll.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
    window.contentView = scroll
    reader.display(document: document)
    reader.configureGutter(in: scroll, lineNumbers: true)
    reader.view.textLayoutManager?.textViewportLayoutController.layoutViewport()
    window.displayIfNeeded()
    return (reader, window)
}

@MainActor
private func readonlyCopiedText(_ view: NSTextView) throws -> String {
    let board = NSPasteboard(name: .init("readonly-projection-copy-\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    // Native TextKit uses legacy NSStringPboardType in this SDK. Request the
    // view's advertised types, exactly like its own copy service.
    #expect(view.writeSelection(to: board, types: view.writablePasteboardTypes))
    return try #require(board.string(forType: .string))
}

@MainActor @Test(.isolatedReaderWorkCounters)
func readonlyProjectionNativeSmallPatchVisitsOnlyChangedParagraphs() async throws {
    let document = readonlyCommitFixture()
    let (reader, window) = readonlyCommitReader(document)
    defer { window.close() }
    await reader.waitForIdentifierPreparation()
    let before = ReaderWorkCounters.snapshot()
    let installs = reader.projectionInstallCount
    #expect(reader.toggleFold(id: .init(rawValue: 1)))
    let folded = ReaderWorkCounters.snapshot()
    #expect(folded.fullTextReplacementCount == before.fullTextReplacementCount)
    #expect(folded.partialTextReplacementCount == before.partialTextReplacementCount + 1)
    #expect(folded.materializedUTF8Bytes - before.materializedUTF8Bytes < 500)
    #expect(folded.attributeUpdatedUTF16Units - before.attributeUpdatedUTF16Units < 800)
    #expect(folded.paragraphRecordsVisited - before.paragraphRecordsVisited < 12)
    #expect(reader.projectionInstallCount == installs)
    #expect(reader.view.string == ReadonlyDisplayMapOracle(
        document: document, renderedFoldIDs: [.init(rawValue: 1)])?.projectedString)
    let beforeExpansion = ReaderWorkCounters.snapshot()
    #expect(reader.toggleFold(id: .init(rawValue: 1)))
    let expanded = ReaderWorkCounters.snapshot()
    #expect(expanded.fullTextReplacementCount == beforeExpansion.fullTextReplacementCount)
    #expect(expanded.materializedUTF8Bytes - beforeExpansion.materializedUTF8Bytes < 500)
    #expect(expanded.paragraphRecordsVisited - beforeExpansion.paragraphRecordsVisited < 16)
    #expect(reader.view.string == String(decoding: document.bytes, as: UTF8.self))
}

@MainActor @Test
func readonlyProjectionNativeMultipleHiddenSelectionsRestoreEndpointsAndCopy() async throws {
    let document = readonlyCommitFixture()
    let source = String(decoding: document.bytes, as: UTF8.self)
    let (reader, window) = readonlyCommitReader(document)
    defer { window.close() }
    await reader.waitForIdentifierPreparation()
    let firstRange = (source as NSString).range(of: "v201")
    let firstLine = (source as NSString).paragraphRange(for: firstRange)
    let unicodeRange = (source as NSString).range(of: "🚀e\u{301}", options: [], range: firstLine)
    let ranges = [firstRange, unicodeRange, (source as NSString).range(of: "v202"),
        NSRange(location: (source as NSString).length - 3, length: 3)]
    reader.view.setSelectedRanges(ranges.map(NSValue.init(range:)), affinity: .upstream, stillSelecting: false)
    let original = reader.view.selectedRanges
    // Design §8.5 / P04 requires raw source-slice concatenation. AppKit's
    // default multi-copy injects visual-row newlines, even at soft wraps.
    let expected = "v201🚀e\u{301}v202;\r\n"
    let actualCopy = try readonlyCopiedText(reader.view)
    #expect(actualCopy == expected)
    #expect(reader.toggleFold(id: .init(rawValue: 1)))
    let foldedCopy = try readonlyCopiedText(reader.view)
    #expect(foldedCopy == expected)
    #expect(reader.view.selectionAffinity == .upstream)
    #expect(reader.toggleFold(id: .init(rawValue: 1)))
    #expect(reader.view.selectedRanges == original)
    #expect(reader.view.selectionAffinity == .upstream)
    let expandedCopy = try readonlyCopiedText(reader.view)
    #expect(expandedCopy == expected)
    reader.view.setFrameSize(NSSize(width: 180, height: reader.view.frame.height))
    reader.view.textLayoutManager?.textViewportLayoutController.layoutViewport()
    let narrowCopy = try readonlyCopiedText(reader.view)
    #expect(narrowCopy == expected)
    #expect(reader.view.selectedRanges == original)
}

@MainActor @Test
func readonlyProjectionExplicitPlaceholderCopyUsesWholeBodyAfterNavigation() async throws {
    let document = readonlyCommitFixture()
    let (reader, window) = readonlyCommitReader(document)
    defer { window.close() }
    await reader.waitForIdentifierPreparation()
    #expect(reader.toggleFold(id: .init(rawValue: 1)))
    reader.reveal(byteOffset: 0) // An explicit navigation clears old latent endpoints.
    let placeholder = (reader.view.string as NSString).range(of: "\u{FFFC}")
    reader.view.setSelectedRange(placeholder)
    let fold = document.foldRegions[0]
    let expected = String(decoding: document.bytes[Int(fold.bodyRange.lowerBound)..<Int(fold.bodyRange.upperBound)], as: UTF8.self)
    #expect(try readonlyCopiedText(reader.view) == expected)
    #expect(reader.toggleFold(id: fold.id))
    #expect(try readonlyCopiedText(reader.view) == expected)
}

@MainActor @Test
func readonlyProjectionPreflightFallbackAndDisabledPathKeepTextAndSelections() async throws {
    let document = readonlyCommitFixture()
    let (reader, window) = readonlyCommitReader(document)
    defer { window.close() }
    await reader.waitForIdentifierPreparation()
    let selection = (reader.view.string as NSString).range(of: "v201")
    reader.view.setSelectedRange(selection)
    reader.forceProjectionPreflightFailureForTesting = true
    #expect(reader.toggleFold(id: .init(rawValue: 1)))
    #expect(reader.projectionFallbackReason == "forced-preflight")
    #expect(reader.projectionFallbackCount == 1)
    #expect(reader.view.string == ReadonlyDisplayMapOracle(
        document: document, renderedFoldIDs: [.init(rawValue: 1)])?.projectedString)
    #expect(try readonlyCopiedText(reader.view) == "v201")
    reader.forceProjectionPreflightFailureForTesting = false
    reader.localProjectionUpdatesEnabled = false
    #expect(reader.toggleFold(id: .init(rawValue: 1)))
    #expect(reader.projectionFallbackReason == "disabled")
    #expect(reader.view.selectedRange() == selection)
    let before = reader.view.string
    #expect(!reader.toggleFold(id: .init(rawValue: .max)))
    #expect(reader.view.string == before)
}

@MainActor @Test
func readonlyProjectionShiftedAttachmentGetsItsNewNativeLocation() async throws {
    let document = readonlyCommitFixture()
    let (reader, window) = readonlyCommitReader(document)
    defer { window.close() }
    await reader.waitForIdentifierPreparation()
    #expect(reader.toggleFold(id: .init(rawValue: 2)))
    let oldOffset = (reader.view.string as NSString).range(of: "\u{FFFC}").location
    let old = try #require(reader.view.textStorage?.attribute(.attachment, at: oldOffset, effectiveRange: nil) as? NSTextAttachment)
    #expect(reader.toggleFold(id: .init(rawValue: 1)))
    let string = reader.view.string as NSString
    let first = string.range(of: "\u{FFFC}")
    let second = string.range(of: "\u{FFFC}", range: NSRange(location: NSMaxRange(first), length: string.length - NSMaxRange(first)))
    let moved = try #require(reader.view.textStorage?.attribute(.attachment, at: second.location, effectiveRange: nil) as? NSTextAttachment)
    #expect(moved === old) // TextKit updates opaque locations or recreates the current provider
    let manager = try #require(reader.view.textLayoutManager)
    let content = try #require(manager.textContentManager)
    var offsets: [Int] = []
    manager.enumerateTextLayoutFragments(from: content.documentRange.location, options: [.ensuresLayout]) { fragment in
        for provider in fragment.textAttachmentViewProviders {
            offsets.append(content.offset(from: content.documentRange.location, to: provider.location))
        }
        return true
    }
    #expect(offsets.contains(second.location))
    #expect(!offsets.contains(oldOffset))
    #expect(reader.view.string == ReadonlyDisplayMapOracle(document: document,
        renderedFoldIDs: [.init(rawValue: 1), .init(rawValue: 2)])?.projectedString)
}

@MainActor @Test
func readonlyProjectionParagraphRangeMatchesFullUnicodeCRLFAndTabLayout() {
    let source = "top\r\n\t中文🚀e\u{301} body\r\n    tail\r\n"
    let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    let full = NSMutableAttributedString(string: source, attributes: [.font: font, .paragraphStyle: NSParagraphStyle.default])
    let partial = NSMutableAttributedString(attributedString: full)
    let layout = ReaderParagraphLayout()
    _ = layout.apply(to: full, wrap: true, width: 180, font: font)
    let changed = (source as NSString).range(of: "中文🚀e\u{301}")
    _ = layout.apply(to: partial, wrap: true, width: 180, font: font, in: changed)
    let paragraph = (source as NSString).paragraphRange(for: changed)
    #expect((full.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle)
        == (partial.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle))
    _ = layout.apply(to: partial, wrap: false, width: 180, font: font, in: changed)
    #expect((partial.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle)?.headIndent == 0)
}

@MainActor @Test
func readonlyProjectionMultiplePatchesMatchFullInstallAttributes() async throws {
    let document = readonlyCommitFixture()
    let (local, localWindow) = readonlyCommitReader(document)
    let (full, fullWindow) = readonlyCommitReader(document)
    defer { localWindow.close(); fullWindow.close() }
    await local.waitForIdentifierPreparation()
    await full.waitForIdentifierPreparation()
    full.localProjectionUpdatesEnabled = false
    let before = local.partialProjectionCommitCount
    #expect(local.setReadingHeightLevel(.overview))
    #expect(full.setReadingHeightLevel(.overview))
    #expect(local.partialProjectionCommitCount == before + 1)
    #expect(local.view.string == full.view.string)
    let left = try #require(local.view.textStorage)
    let right = try #require(full.view.textStorage)
    for offset in 0..<left.length {
        #expect((left.attribute(.font, at: offset, effectiveRange: nil) as? NSFont)
            == (right.attribute(.font, at: offset, effectiveRange: nil) as? NSFont))
        #expect((left.attribute(.paragraphStyle, at: offset, effectiveRange: nil) as? NSParagraphStyle)
            == (right.attribute(.paragraphStyle, at: offset, effectiveRange: nil) as? NSParagraphStyle))
    }
    #expect(local.setReadingHeightLevel(.full))
    #expect(full.setReadingHeightLevel(.full))
    #expect(local.view.string == full.view.string)
}

@MainActor
private final class ReadonlyProjectionEditObserver: NSObject {
    let reader: ReaderTextView
    let board = NSPasteboard(name: .init("readonly-projection-barrier-\(UUID().uuidString)"))
    var checks: [(mappingBlocked: Bool, copyRejected: Bool, validatorSuspended: Bool)] = []
    init(reader: ReaderTextView) {
        self.reader = reader
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(edited),
            name: NSTextStorage.didProcessEditingNotification, object: reader.view.textStorage)
    }
    @objc private func edited(_ note: Notification) {
        board.declareTypes([.string], owner: nil)
        board.setString("unchanged", forType: .string)
        let exported = reader.view.writeSelection(to: board, types: reader.view.writablePasteboardTypes)
        checks.append((reader.byteOffset(forCharacterIndex: 0) == nil,
            !exported && board.string(forType: .string) == "unchanged",
            reader.view.textLayoutManager?.renderingAttributesValidator == nil))
    }
    func stop() {
        NotificationCenter.default.removeObserver(self)
        board.releaseGlobally()
    }
}

@MainActor @Test
func readonlyProjectionFullAndPartialCommitsBlockIntermediateMappingAndCopy() async throws {
    let document = readonlyCommitFixture()
    let (reader, window) = readonlyCommitReader(document)
    defer { window.close() }
    await reader.waitForIdentifierPreparation()
    let observer = ReadonlyProjectionEditObserver(reader: reader)
    defer { observer.stop() }
    reader.view.setSelectedRange(NSRange(location: 0, length: 3))
    #expect(reader.toggleFold(id: .init(rawValue: 1)))
    #expect(!observer.checks.isEmpty)
    #expect(observer.checks.allSatisfy { $0.mappingBlocked && $0.copyRejected && $0.validatorSuspended })
    observer.checks.removeAll()
    reader.forceProjectionPreflightFailureForTesting = true
    #expect(reader.toggleFold(id: .init(rawValue: 1)))
    #expect(!observer.checks.isEmpty)
    #expect(observer.checks.allSatisfy { $0.mappingBlocked && $0.copyRejected && $0.validatorSuspended })
    observer.checks.removeAll()
    reader.display(document: document)
    #expect(!observer.checks.isEmpty)
    #expect(observer.checks.allSatisfy { $0.mappingBlocked && $0.copyRejected && $0.validatorSuspended })
    reader.forceProjectionPreflightFailureForTesting = false
    #expect(reader.toggleFold(id: .init(rawValue: 1)))
    observer.checks.removeAll()
    let fold = document.foldRegions[0]
    let changedFold = FoldRegion(id: fold.id, kind: fold.kind, headerRange: fold.headerRange,
        bodyRange: .init(lowerBound: fold.bodyRange.lowerBound + 1, upperBound: fold.bodyRange.upperBound),
        outlineDepth: fold.outlineDepth, summary: fold.summary)
    let changed = ReaderDocument(bytes: document.bytes, lineTable: document.lineTable,
        byteUTF16Map: document.byteUTF16Map, highlightSpans: document.highlightSpans,
        outlineFacets: document.outlineFacets, foldRegions: [changedFold, document.foldRegions[1]])
    reader.updateSyntax(document: changed)
    #expect(reader.projectionFallbackReason == "syntax-projection-change")
    #expect(!observer.checks.isEmpty)
    #expect(observer.checks.allSatisfy { $0.mappingBlocked && $0.copyRejected && $0.validatorSuspended })

}

@MainActor @Test
func readonlyProjectionActivationTracksPrimaryStyleThroughVisibleAndHiddenMoves() async throws {
    let source = """
        fn first() {
            let seed = 1;
            let second = seed;
            let third = second;
        }
        fn second() {
            target();
            target();
        }
        fn target() {}
        """
    let document = try DocumentLoader(source: { _ in Array(source.utf8) })
        .load(file: URL(fileURLWithPath: "/readonly-primary.rs")).document
    let (reader, window) = readonlyCommitReader(document)
    defer { window.close() }
    await reader.waitForIdentifierPreparation()
    let first = try #require(document.foldRegions.first { $0.headerRange.lowerBound == 0 })
    let secondHeader = UInt32((source as NSString).range(of: "fn second()").location)
    let second = try #require(document.foldRegions.first { $0.headerRange.lowerBound == secondHeader })
    let selected = (source as NSString).range(of: "target();")
    #expect(reader.activate(atByteOffset: UInt32(selected.location)) == 3)
    #expect(try readonlyCopiedText(reader.view) == "target")

    #expect(reader.toggleFold(id: first.id))
    let shifted = (reader.view.string as NSString).range(of: "target();")
    #expect(reader.primarySelectionRange == NSRange(location: shifted.location, length: 6))
    #expect((reader.view.string as NSString).substring(with: try #require(reader.primarySelectionRange)) == "target")
    #expect(try readonlyCopiedText(reader.view) == "target")

    #expect(reader.toggleFold(id: second.id))
    #expect(reader.primarySelectionRange == nil)
    #expect((reader.view.string as NSString).substring(with: reader.view.selectedRange()) == "\u{FFFC}")
    #expect((reader.view.selectedTextAttributes[.backgroundColor] as? NSColor)?.alphaComponent ?? 0 > 0)
    #expect(try readonlyCopiedText(reader.view) == "target")
    #expect(reader.toggleFold(id: second.id))
    let visibleAgain = (reader.view.string as NSString).range(of: "target();")
    #expect(reader.primarySelectionRange == NSRange(location: visibleAgain.location, length: 6))
    #expect((reader.view.selectedTextAttributes[.backgroundColor] as? NSColor)?.alphaComponent == 0)

    // Deliver a real key event through ClickTextView, not a programmatic range
    // assignment. The user's selection must disable the custom primary style.
    let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: .shift, timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, characters: "\u{F702}",
        charactersIgnoringModifiers: "\u{F702}", isARepeat: false, keyCode: 123))
    reader.view.keyDown(with: key)
    #expect(reader.primarySelectionRange == nil)
    #expect((reader.view.selectedTextAttributes[.backgroundColor] as? NSColor)?.alphaComponent ?? 0 > 0)
    #expect(reader.toggleFold(id: second.id))
    #expect(reader.toggleFold(id: second.id))
    #expect(reader.primarySelectionRange == nil)
}

@MainActor @Test
func readonlyProjectionStalePreparedTargetCannotOverwriteNewDocumentOrAnalysis() async throws {
    let original = readonlyCommitFixture()
    let replacementBytes = Array("fn replacement() { /* B stays visible */ }\n".utf8)
    let replacement = ReaderDocument(bytes: replacementBytes, highlightSpans: [], outlineFacets: [])
    for forceFallback in [false, true] {
        let (reader, window) = readonlyCommitReader(original)
        defer { window.close() }
        await reader.waitForIdentifierPreparation()
        reader.forceProjectionPreflightFailureForTesting = forceFallback
        let fallbacks = reader.projectionFallbackCount
        reader.projectionPreflightHookForTesting = { reader.display(document: replacement) }
        #expect(!reader.toggleFold(id: .init(rawValue: 1)))
        #expect(reader.projectionCommitRejectionReason == "stale-target")
        #expect(reader.projectionRejectedCount == 1)
        #expect(reader.projectionFallbackCount == fallbacks)
        #expect(reader.displayedBytes == replacementBytes)
        #expect(reader.view.string == String(decoding: replacementBytes, as: UTF8.self))
        #expect(reader.logicalFoldIDsForTesting.isEmpty)
        #expect(reader.byteOffset(forCharacterIndex: 0) == 0)
    }

    // Same bytes and same projection, but a newly published analysis also
    // invalidates a prepared transaction. It must not apply the old fold intent.
    let (reader, window) = readonlyCommitReader(original)
    defer { window.close() }
    await reader.waitForIdentifierPreparation()
    let analysis = ReaderDocument(bytes: original.bytes, lineTable: original.lineTable,
        byteUTF16Map: original.byteUTF16Map, highlightSpans: [],
        outlineFacets: original.outlineFacets, foldRegions: original.foldRegions)
    reader.projectionPreflightHookForTesting = { reader.updateSyntax(document: analysis) }
    #expect(!reader.toggleFold(id: .init(rawValue: 1)))
    #expect(reader.projectionCommitRejectionReason == "stale-target")
    #expect(reader.projectionFallbackCount == 0)
    #expect(reader.view.string == String(decoding: original.bytes, as: UTF8.self))
    #expect(reader.logicalFoldIDsForTesting.isEmpty)
}

@MainActor @Test
func readonlyProjectionSelectionEndingAtFoldBodyStartExcludesPlaceholder() async throws {
    let document = readonlyCommitFixture()
    let (reader, window) = readonlyCommitReader(document)
    defer { window.close() }
    await reader.waitForIdentifierPreparation()
    let fold = document.foldRegions[0]
    let selection = try #require(document.byteUTF16Map.nsRange(
        byteLowerBound: Int(fold.headerRange.lowerBound), byteUpperBound: Int(fold.bodyRange.lowerBound)))
    reader.view.setSelectedRange(selection)
    let expected = try readonlyCopiedText(reader.view)
    #expect(reader.toggleFold(id: fold.id))
    #expect(reader.view.selectedRange() == selection)
    #expect(!(reader.view.string as NSString).substring(with: reader.view.selectedRange()).contains("\u{FFFC}"))
    #expect(try readonlyCopiedText(reader.view) == expected)
    #expect(reader.toggleFold(id: fold.id))
    #expect(reader.view.selectedRange() == selection)
}

@MainActor @Test
func readonlyProjectionFoldRoundTripPreservesNativeShiftExtensionDirection() async throws {
    let document = readonlyCommitFixture()
    let source = String(decoding: document.bytes, as: UTF8.self) as NSString
    let line = source.paragraphRange(for: source.range(of: "v201"))
    let token = source.range(of: "中文🚀e\u{301}", options: [], range: line)
    for reverse in [false, true] {
        let (reader, window) = readonlyCommitReader(document)
        let (reference, referenceWindow) = readonlyCommitReader(document)
        defer { window.close(); referenceWindow.close() }
        await reader.waitForIdentifierPreparation()
        await reference.waitForIdentifierPreparation()
        func extend(_ view: NSTextView) {
            if reverse { view.moveLeftAndModifySelection(nil) }
            else { view.moveRightAndModifySelection(nil) }
        }
        let caret = reverse ? NSMaxRange(token) : token.location
        for view in [reader.view, reference.view] {
            view.setSelectedRange(NSRange(location: caret, length: 0))
            for _ in 0..<3 { extend(view) }
        }
        let original = reader.view.selectedRanges
        let affinity = reader.view.selectionAffinity
        #expect(reader.toggleFold(id: .init(rawValue: 1)))
        #expect(reader.toggleFold(id: .init(rawValue: 1)))
        #expect(reader.view.selectedRanges == original)
        #expect(reader.view.selectionAffinity == affinity)
        extend(reader.view)
        extend(reference.view)
        #expect(reader.view.selectedRanges == reference.view.selectedRanges)
        #expect(try readonlyCopiedText(reader.view) == readonlyCopiedText(reference.view))
    }
}

@MainActor @Test
func readonlyProjectionMultipleRangesKeepNativeShiftBehaviorAfterFoldRoundTrip() async throws {
    let document = readonlyCommitFixture()
    let source = String(decoding: document.bytes, as: UTF8.self) as NSString
    let selections = [source.range(of: "v201"), source.range(of: "v202")].map(NSValue.init(range:))
    for reverse in [false, true] {
        for initialShift in [false, true] {
            let (reader, window) = readonlyCommitReader(document)
            let (reference, referenceWindow) = readonlyCommitReader(document)
            defer { window.close(); referenceWindow.close() }
            await reader.waitForIdentifierPreparation()
            await reference.waitForIdentifierPreparation()
            func extend(_ view: NSTextView) {
                if reverse { view.moveLeftAndModifySelection(nil) }
                else { view.moveRightAndModifySelection(nil) }
            }
            for view in [reader.view, reference.view] {
                view.setSelectedRanges(selections, affinity: reverse ? .upstream : .downstream,
                    stillSelecting: false)
                if initialShift { extend(view) }
            }
            let original = reader.view.selectedRanges
            let affinity = reader.view.selectionAffinity
            #expect(original.count == 2)
            #expect(reader.toggleFold(id: .init(rawValue: 1)))
            #expect(reader.toggleFold(id: .init(rawValue: 1)))
            #expect(reader.view.selectedRanges == original)
            #expect(reader.view.selectionAffinity == affinity)
            extend(reader.view)
            extend(reference.view)
            #expect(reader.view.selectedRanges == reference.view.selectedRanges)
            #expect(try readonlyCopiedText(reader.view) == readonlyCopiedText(reference.view))
        }
    }
}

// Regression: switching to Structure from deep inside a long method left the
// clip past the shorter document's end (only the last rows, stalled wheel).
@MainActor @Test(arguments: [true, false])
func readonlyProjectionStructureSwitchKeepsViewportInsideShorterDocument(wrap: Bool) async throws {
    _ = NSApplication.shared
    func method(_ name: String, _ lines: Int) -> String {
        "    def \(name)(self, context: List[str] | str | List[Dict[str, str]], query: Optional[str] = None) -> str:\n"
            + "        \"\"\"Docstring.\"\"\"\n"
            + (0..<lines).map { "        value_\($0) = self.compute(context, query, iteration=\($0))\n" }.joined()
    }
    let source = "class Reader:\n" + method("setup", 26) + "\n" + method("completion", 44) + "\n"
        + method("summary", 30) + "\nif __name__ == \"__main__\":\n    pass\n"
    let bytes = Array(source.utf8)
    let document = try DocumentLoader(source: { _ in bytes })
        .load(file: URL(fileURLWithPath: "/structure.py"), languageMode: LanguageMode(language: .python))
        .document
    var settings = ReaderSettings()
    settings.wrapLines = wrap
    let reader = ReaderTextView(settings: settings)
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 1000, height: 520))
    scroll.hasVerticalScroller = true
    scroll.documentView = reader.view
    reader.view.frame = scroll.contentView.bounds
    let window = NSWindow(contentRect: scroll.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
    window.contentView = scroll
    defer { reader.stopPendingReaderWork(); window.close() }
    reader.configureGutter(in: scroll, lineNumbers: true)
    reader.display(document: document, fileURL: URL(fileURLWithPath: "/structure.py"))
    window.displayIfNeeded()
    // Setup: user-style scrolling into the middle of `completion`'s body.
    let clip = scroll.contentView
    while reader.firstVisibleByteOffset().flatMap({ document.lineTable.lineColumn(at: $0)?.line }).map({ $0 < 50 }) ?? true {
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: clip.bounds.minY + 100))
        scroll.reflectScrolledClipView(clip)
        reader.view.textLayoutManager?.textViewportLayoutController.layoutViewport()
        try #require(clip.bounds.maxY < reader.view.frame.height)
    }

    #expect(reader.setReadingHeightLevel(.structure))

    let maxY = reader.view.frame.height - clip.bounds.height + clip.contentInsets.bottom
    #expect(clip.bounds.minY <= maxY + 0.5, "clip=\(clip.bounds.minY) max=\(maxY)")
    let header = (reader.view.string as NSString).range(of: "def completion").location
    let row = try #require(ReaderViewportGeometry.rowRect(containingDisplayLocation: header, in: reader.view))
    #expect(reader.view.visibleRect.intersects(row))
}
