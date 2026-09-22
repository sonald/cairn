import AppKit
import CodeInsightCore
import CodeInsightReaderCore
import Testing
@testable import CodeInsightReaderUI

@MainActor
private func ligatureReader(_ source: String, settings: ReaderSettings = ReaderSettings()) -> (ReaderTextView, NSWindow) {
    let reader = ReaderTextView(settings: settings)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
        styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
    scroll.hasVerticalScroller = true
    scroll.documentView = reader.view
    window.contentView = scroll
    reader.view.frame = scroll.contentView.bounds
    reader.configureGutter(in: scroll, lineNumbers: settings.lineNumbers)
    let plain = ReaderDocument(bytes: Array(source.utf8))
    reader.display(document: (try? DocumentLoader().loadSyntax(for: plain)) ?? plain)
    reader.view.textLayoutManager?.textViewportLayoutController.layoutViewport()
    return (reader, window)
}

@MainActor @Test
func ligatureChangesReuseProjectionAndPreservePartialSourceSelections() throws {
    let source = "fn check() { let value = a != b; }\r\n// 中文 😀 e\u{301}\t!== -> =>\r\n"
    let (reader, window) = ligatureReader(source)
    defer { window.close() }
    let equals = (source as NSString).range(of: "!=").location + 1
    let selection = NSRange(location: equals, length: 1)
    reader.view.setSelectedRanges([NSValue(range: selection)], affinity: .upstream, stillSelecting: false)
    let installs = reader.projectionInstallCount
    var settings = ReaderSettings()
    for mode in [CodeLigatureMode.enabled, .disabled, .fontDefault, .enabled] {
        settings.codeLigatures = mode
        reader.apply(settings: settings)
        #expect(reader.projectionInstallCount == installs)
        #expect(reader.view.string == source)
        #expect(reader.view.selectedRange() == selection)
        #expect(reader.view.selectionAffinity == .upstream)
        #expect(reader.sourceText(forDisplaySelection: selection) == "=")
        let changes = reader.typographyAttributeUpdateCount
        let paragraphs = reader.paragraphUpdateCount
        reader.apply(settings: settings)
        #expect(reader.typographyAttributeUpdateCount == changes)
        #expect(reader.paragraphUpdateCount == paragraphs)
    }
}

@MainActor @Test
func ligatureTypographyClearsOverridesAndKeepsHumanistCommentsIndependent() throws {
    let source = "fn check() { let a = 2; }\n// prose -> !=\n"
    var settings = ReaderSettings(humanistComments: true)
    settings.codeLigatures = .disabled
    let (reader, window) = ligatureReader(source, settings: settings)
    defer { window.close() }
    let comment = (source as NSString).range(of: "prose").location
    let storage = try #require(reader.view.textStorage)
    #expect(storage.attribute(.ligature, at: 0, effectiveRange: nil) as? Int == 0)
    #expect(storage.attribute(.ligature, at: comment, effectiveRange: nil) == nil)
    settings.syntaxFormatting = false
    reader.apply(settings: settings)
    #expect(storage.attribute(.ligature, at: comment, effectiveRange: nil) as? Int == 0)
    settings.codeLigatures = .fontDefault
    reader.apply(settings: settings)
    #expect(storage.attribute(.ligature, at: 0, effectiveRange: nil) == nil)
    #expect(storage.attribute(.kern, at: (source as NSString).range(of: "check").location, effectiveRange: nil) == nil)
}

@MainActor @Test
func ligatureChangesPreserveLargeDocumentSelectionAndInvalidateOnFontRefresh() throws {
    let source = String(repeating: "let a = x != y;\n", count: 8_001)
    let (reader, window) = ligatureReader(source)
    defer { window.close() }
    let selection = NSRange(location: 12, length: 1)
    reader.view.setSelectedRange(selection)
    var settings = ReaderSettings()
    settings.codeLigatures = .disabled
    reader.apply(settings: settings)
    #expect(reader.view.selectedRange() == selection)
    #expect(reader.view.string == source)
    let installs = reader.projectionInstallCount
    let changes = reader.typographyAttributeUpdateCount
    ReaderFontResolver.shared.refresh()
    reader.apply(settings: settings)
    #expect(reader.typographyAttributeUpdateCount == changes + 1)
    #expect(reader.projectionInstallCount == installs)
    #expect(reader.view.selectedRange() == selection)
}

@MainActor
private func settleLigatureLayout(_ reader: ReaderTextView) {
    for _ in 0..<12 {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        reader.view.textLayoutManager?.textViewportLayoutController.layoutViewport()
        reader.processPendingViewportRestoresForTesting()
    }
}

@MainActor @Test
func ligatureAndFontReflowsKeepAnIndependentlyMeasuredViewportAnchor() throws {
    let source = (0..<200).map {
        "fn item\($0)() { let value = left != right; let other = left <= right; }"
    }.joined(separator: "\n")
    let (reader, window) = ligatureReader(source)
    defer { window.close() }
    let scroll = try #require(reader.view.enclosingScrollView)
    settleLigatureLayout(reader)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 800))
    scroll.reflectScrolledClipView(scroll.contentView)
    settleLigatureLayout(reader)
    let selectionProbe = reader.view.visibleRect
    let selectionLocation = reader.view.characterIndexForInsertion(at: NSPoint(
        x: selectionProbe.midX, y: selectionProbe.minY + selectionProbe.height * 0.25))
    let line = (source as NSString).lineRange(for: NSRange(location: selectionLocation, length: 0))
    let selection = (source as NSString).range(of: "left != right", options: [], range: line)
    try #require(selection.location != NSNotFound)
    reader.view.setSelectedRanges([NSValue(range: selection)], affinity: .upstream, stillSelecting: false)
    settleLigatureLayout(reader)
    // Establish the reference after selection, using the same live viewport
    // that apply(settings:) will capture, rather than selecting line one.
    let visible = reader.view.visibleRect
    let anchor = reader.view.characterIndexForInsertion(at: NSPoint(
        x: visible.midX, y: visible.minY + visible.height * 0.25))
    let initialRow = try #require(ReaderViewportGeometry.rowRect(
        containingDisplayLocation: anchor, in: reader.view))
    let offset = initialRow.minY - scroll.contentView.bounds.minY
    let font = try #require(NSFont(name: "Menlo-Regular", size: 13))
    let installs = reader.projectionInstallCount
    var settings = ReaderSettings()
    for (mode, size, wrap) in [
        (CodeLigatureMode.enabled, 13.0, false),
        (.disabled, 17.0, true),
        (.fontDefault, 15.0, true),
        (.enabled, 13.0, false),
    ] {
        settings.codeFont = .postScriptName(font.fontName)
        settings.codeLigatures = mode
        settings.fontSize = size
        settings.wrapLines = wrap
        reader.apply(settings: settings)
        settleLigatureLayout(reader)
        let row = try #require(ReaderViewportGeometry.rowRect(
            containingDisplayLocation: anchor, in: reader.view),
            "mode=\(mode), size=\(size), wrap=\(wrap), anchor=\(anchor), clip=\(scroll.contentView.bounds)")
        let error = abs(row.minY - scroll.contentView.bounds.minY - offset)
        #expect(error <= 2, "mode=\(mode), size=\(size), wrap=\(wrap), anchor error=\(error)pt")
        #expect(reader.projectionInstallCount == installs)
        #expect(reader.view.selectedRange() == selection)
        #expect(reader.view.selectionAffinity == .upstream)
    }
}

@MainActor @Test
func ligaturePendingRestoreYieldsToUserScroll() throws {
    let source = String(repeating: "let value = left != right;\n", count: 200)
    let (reader, window) = ligatureReader(source)
    defer { window.close() }
    let scroll = try #require(reader.view.enclosingScrollView)
    settleLigatureLayout(reader)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 500))
    scroll.reflectScrolledClipView(scroll.contentView)
    settleLigatureLayout(reader)
    reader.apply(settings: ReaderSettings(fontSize: 17, codeLigatures: .enabled))
    // Apply schedules corrections; a subsequent clip-view scroll is the same
    // bounds-change notification route used by actual wheel/trackpad input.
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 100))
    scroll.reflectScrolledClipView(scroll.contentView)
    let requestedY = scroll.contentView.bounds.minY
    let restores = reader.viewportRestorePassCount
    settleLigatureLayout(reader)
    #expect(reader.viewportRestorePassCount == restores)
    #expect(abs(scroll.contentView.bounds.minY - requestedY) <= 2)
}

@MainActor @Test
func ligaturePendingRestoreCannotAffectAReplacementDocument() throws {
    let (reader, window) = ligatureReader(String(repeating: "let value = a != b;\n", count: 200))
    defer { window.close() }
    let scroll = try #require(reader.view.enclosingScrollView)
    settleLigatureLayout(reader)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 600))
    scroll.reflectScrolledClipView(scroll.contentView)
    reader.apply(settings: ReaderSettings(fontSize: 18, codeLigatures: .disabled))
    let replacement = "new document 😀 e\u{301} !=\nsecond line\n"
    reader.display(document: ReaderDocument(bytes: Array(replacement.utf8)))
    let selection = (replacement as NSString).range(of: "second")
    reader.view.setSelectedRange(selection)
    let restores = reader.viewportRestorePassCount
    settleLigatureLayout(reader)
    #expect(reader.view.string == replacement)
    #expect(reader.view.selectedRange() == selection)
    #expect(reader.sourceText(forDisplaySelection: selection) == "second")
    #expect(reader.viewportRestorePassCount == restores)
}

@MainActor @Test
func ligatureReflowsPreserveFoldAttachmentAndSourceCopyAcrossIt() throws {
    let source = "fn folded() {\n    let one = a != b;\n    let two = a <= b;\n}\nfn after() {}\n"
    let bytes = Array(source.utf8)
    let document = try DocumentLoader(source: { _ in bytes })
        .load(file: URL(fileURLWithPath: "/ligature-fold-copy.rs")).document
    let fold = try #require(document.foldRegions.first { $0.kind == .declaration })
    let (reader, window) = ligatureReader(source)
    defer { window.close() }
    reader.display(document: document)
    #expect(reader.toggleFold(id: fold.id))
    settleLigatureLayout(reader)
    let display = reader.view.string as NSString
    let placeholder = display.range(of: "\u{FFFC}")
    try #require(placeholder.location != NSNotFound)
    let storage = try #require(reader.view.textStorage)
    let attachment = try #require(storage.attribute(.attachment,
        at: placeholder.location, effectiveRange: nil) as? NSTextAttachment)
    let start = display.range(of: "folded").location
    let end = display.range(of: "fn after").location + 2
    let selection = NSRange(location: start, length: end - start)
    reader.view.setSelectedRange(selection)
    let sourceStart = (source as NSString).range(of: "folded").location
    let sourceEnd = (source as NSString).range(of: "fn after").location + 2
    let expected = (source as NSString).substring(with: NSRange(
        location: sourceStart, length: sourceEnd - sourceStart))
    let installs = reader.projectionInstallCount
    for mode in [CodeLigatureMode.enabled, .disabled, .fontDefault] {
        let settings = ReaderSettings(lineHeightMultiple: 1.7, fontSize: 17,
            codeFont: .postScriptName("Menlo-Regular"), codeLigatures: mode)
        reader.apply(settings: settings)
        settleLigatureLayout(reader)
        #expect(reader.view.string == (display as String))
        #expect(reader.projectionInstallCount == installs)
        #expect(reader.renderedFoldIDsForTesting.contains(fold.id))
        #expect(reader.view.selectedRange() == selection)
        #expect(reader.sourceText(forDisplaySelection: selection) == expected)
        #expect((storage.attribute(.attachment, at: placeholder.location,
            effectiveRange: nil) as? NSTextAttachment) === attachment)
        let resolved = ReaderFontResolver.shared.resolve(theme: ReaderTheme(settings: settings))
        #expect(storage.attribute(.font, at: placeholder.location, effectiveRange: nil) as? NSFont == resolved.font)
        #expect(storage.attribute(.ligature, at: placeholder.location, effectiveRange: nil) as? Int
            == resolved.attributes[.ligature] as? Int)
        let paragraph = try #require(storage.attribute(.paragraphStyle, at: placeholder.location,
            effectiveRange: nil) as? NSParagraphStyle)
        #expect(abs(paragraph.lineHeightMultiple - settings.lineHeightMultiple) < 0.001)
    }
}

@MainActor @Test
func ligatureGeometryTreatsSurrogatesAndCombiningSequencesAsWholeCharacters() throws {
    let source = "let text = \"中文 😀 e\u{301} 👨‍👩‍👧‍👦\"; // != !==\r\n"
    let (reader, window) = ligatureReader(source)
    defer { window.close() }
    for mode in CodeLigatureMode.allCases {
        reader.apply(settings: ReaderSettings(codeLigatures: mode))
        settleLigatureLayout(reader)
        for grapheme in ["😀", "e\u{301}", "👨‍👩‍👧‍👦"] {
            let range = (source as NSString).range(of: grapheme)
            let whole = try #require(ReaderViewportGeometry.characterRect(
                displayLocation: range.location, in: reader.view))
            #expect(whole.width > 0 && whole.height > 0)
            for offset in range.location..<NSMaxRange(range) {
                let part = try #require(ReaderViewportGeometry.characterRect(
                    displayLocation: offset, in: reader.view))
                #expect(part == whole, "UTF-16 offset \(offset) split \(grapheme)")
            }
            #expect(reader.sourceText(forDisplaySelection: range) == grapheme)
        }
        let operatorRange = (source as NSString).range(of: "!==")
        let partial = NSRange(location: operatorRange.location + 1, length: 1)
        #expect(!ReaderViewportGeometry.visibleRects(forDisplayRange: partial, in: reader.view).isEmpty)
        #expect(reader.sourceText(forDisplaySelection: partial) == "=")
        #expect(reader.view.string == source)
    }
}

@MainActor @Test
func ligatureModeAndFontChangesPreserveNativeShiftExtensionDirection() throws {
    let source = "let value = left !== right;\n"
    let operatorRange = (source as NSString).range(of: "!==")
    let (reader, window) = ligatureReader(source)
    defer { window.close() }
    #expect(window.makeFirstResponder(reader.view))
    let font = try #require(NSFont(name: "Menlo-Regular", size: 13))
    for reverse in [false, true] {
        for (beforeMode, afterMode) in [
            (CodeLigatureMode.fontDefault, CodeLigatureMode.enabled),
            (.enabled, .disabled),
            (.disabled, .fontDefault),
        ] {
            reader.apply(settings: ReaderSettings(codeLigatures: beforeMode))
            settleLigatureLayout(reader)
            let caret = reverse ? NSMaxRange(operatorRange) : operatorRange.location
            reader.view.setSelectedRange(NSRange(location: caret, length: 0))
            if reverse {
                reader.view.moveLeftAndModifySelection(nil)
            } else {
                reader.view.moveRightAndModifySelection(nil)
            }
            let selected = NSRange(location: reverse ? caret - 1 : caret, length: 1)
            #expect(reader.view.selectedRange() == selected)
            let affinity = reader.view.selectionAffinity
            reader.apply(settings: ReaderSettings(
                codeFont: .postScriptName(font.fontName), codeLigatures: afterMode))
            settleLigatureLayout(reader)
            #expect(reader.view.selectedRange() == selected)
            #expect(reader.view.selectionAffinity == affinity)
            // Use AppKit's native Shift-arrow command, not a synthesized range:
            // a redundant selection assignment flips reverse extension into shrink.
            if reverse {
                reader.view.moveLeftAndModifySelection(nil)
            } else {
                reader.view.moveRightAndModifySelection(nil)
            }
            let extended = NSRange(location: reverse ? caret - 2 : caret, length: 2)
            #expect(reader.view.selectedRange() == extended,
                "reverse=\(reverse), \(beforeMode) -> \(afterMode)")
            #expect(reader.sourceText(forDisplaySelection: reader.view.selectedRange())
                == (source as NSString).substring(with: extended))
        }
    }
}


@MainActor @Test
func ligatureMegaLineKeepsSelectionWithoutSynchronousCaretGeometry() throws {
    let source = "const WALL: &str = \"" + String(repeating: "wall", count: 20_000) + " !=\";\n"
    var settings = ReaderSettings()
    settings.wrapLines = true
    let (reader, window) = ligatureReader(source, settings: settings)
    defer { window.close() }
    settleLigatureLayout(reader)
    let selection = (source as NSString).range(of: "const")
    reader.view.setSelectedRanges([NSValue(range: selection)], affinity: .upstream, stillSelecting: false)
    let restores = reader.viewportRestorePassCount
    let installs = reader.projectionInstallCount
    settings.wrapLines = false
    settings.codeLigatures = .disabled
    reader.apply(settings: settings)
    settleLigatureLayout(reader)
    #expect(reader.lastViewportRestoreWasLimited)
    #expect(reader.lastViewportAnchorErrorPt == nil)
    #expect(reader.viewportRestorePassCount == restores)
    #expect(reader.projectionInstallCount == installs)
    #expect(reader.view.selectedRange() == selection)
    #expect(reader.sourceText(forDisplaySelection: selection) == "const")
    #expect(reader.view.string == source)
}
