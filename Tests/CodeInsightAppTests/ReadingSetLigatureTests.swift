import AppKit
import CodeInsightAppModel
import CodeInsightCore
import CodeInsightReaderCore
import CodeInsightReaderUI
import Testing
@testable import CodeInsightApp

@MainActor
@Test
func readingSetFontChangesRemeasureWithoutChangingSourceSelectionOrAnchor() async throws {
    _ = NSApplication.shared
    let view = ReadingSetView()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = view
    defer { window.orderOut(nil) }
    var settings = ReaderSettings()
    settings.wrapLines = true
    view.apply(settings: settings)
    let source = String(repeating: "    let result = value != other && limit >= 2; // 中文 👩🏽‍💻 e\u{301} -> => !== ::\n", count: 8)
    let bytes = Array(source.utf8)
    let inspector = ReadingSetExcerpt.FrozenInspectorDisplay(
        nodeTitle: "operators", badge: .verified, why: "fixture", sourceBody: "fixture",
        verificationTitle: "fixture", verificationBody: "fixture", correctionBody: "",
        availabilityBody: "", environmentBody: "", auditRows: [], accessibilityValue: "fixture",
        capturedAt: Date(timeIntervalSince1970: 0), formerCandidateAvailable: false
    )
    let excerpt = ReadingSetExcerpt(
        role: "DEFINITION", symbol: "operators", path: "operators.rs", line: 1, column: 1, firstLine: 1,
        byteRange: ByteRange(lowerBound: 0, upperBound: UInt32(bytes.count)), sourceText: source,
        contentID: .sha256(of: bytes), revision: nil, capturedAt: Date(timeIntervalSince1970: 0),
        sourceKind: .worktreeCaptured, inspector: inspector, caveat: nil
    )
    view.display(title: "Ligatures", excerpts: Array(repeating: excerpt, count: 4))
    await settleLigatureReadingSet(window)
    let text = view.selfTestTextViews[2]
    let selection = NSRange(location: (source as NSString).range(of: "!=").location + 1, length: 1)
    text.setSelectedRanges([NSValue(range: selection)], affinity: .upstream, stillSelecting: false)
    view.restoreScrollOffset(Double(view.selfTestCardFrames[2].minY + 45))
    await settleLigatureReadingSet(window)
    let anchor = try #require(view.selfTestViewportAnchor)
    let font = try #require(NSFont(name: "Menlo-Regular", size: settings.fontSize))
    settings.codeFont = .postScriptName(font.fontName)
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    for mode in CodeLigatureMode.allCases {
        let before = view.selfTestMeasurementCount
        text.setSelectedRange(NSRange(location: NSMaxRange(selection), length: 0))
        text.moveLeftAndModifySelection(nil)
        settings.codeLigatures = mode
        view.apply(settings: settings)
        await settleLigatureReadingSet(window)
        #expect(view.selfTestMeasurementCount > before)
        #expect(text.string == source)
        #expect(text.selectedRange() == selection)
        #expect(text.selectionAffinity == .upstream)
        #expect((text.string as NSString).substring(with: text.selectedRange()) == "=")
        // Native NSTextView advertises the legacy plain-text type; its normal
        // copy entry point declares those types and also provides modern .string.
        #expect(text.writeSelection(to: pasteboard, types: text.writablePasteboardTypes))
        #expect(pasteboard.string(forType: .string) == "=")
        text.moveLeftAndModifySelection(nil)
        #expect((text.string as NSString).substring(with: text.selectedRange()) == "!=")
        text.setSelectedRanges([NSValue(range: selection)], affinity: .upstream, stillSelecting: false)
        let resolved = ReaderFontResolver.shared.resolve(theme: ReaderTheme(settings: settings))
        #expect(text.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont == resolved.font)
        #expect(text.textStorage?.attribute(.ligature, at: 0, effectiveRange: nil) as? Int
            == resolved.attributes[.ligature] as? Int)
        let after = try #require(view.selfTestViewportAnchor)
        #expect(after.card == anchor.card)
        #expect(after.location == anchor.location)
        #expect(abs(after.offset - anchor.offset) <= 2)
        #expect(view.selfTestLayoutState.allSatisfy { $0.heightConstraints == 1 && $0.contentBottom <= $0.documentHeight })
        let measured = view.selfTestMeasurementCount
        view.apply(settings: settings)
        await settleLigatureReadingSet(window)
        #expect(view.selfTestMeasurementCount == measured)
    }
    let beforeRefresh = view.selfTestMeasurementCount
    ReaderFontResolver.shared.refresh()
    view.apply(settings: settings)
    await settleLigatureReadingSet(window)
    #expect(view.selfTestMeasurementCount > beforeRefresh)
    #expect(text.selectedRange() == selection)
}

@MainActor
private func settleLigatureReadingSet(_ window: NSWindow) async {
    for _ in 0..<5 {
        window.contentView?.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(10))
        window.displayIfNeeded()
    }
}
