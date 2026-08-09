@preconcurrency import AppKit
import CodeInsightCore
import CodeInsightReaderCore
import Foundation
import Testing
@testable import CodeInsightReaderUI

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
    reader.view.scrollRangeToVisible(lastKeyword)
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
    let lineNumberThickness = reader.rulerThickness
    reader.setDiffMarkers([2: .changed, 3: .added])

    #expect(reader.diffMarkerCounts == [.changed: 1, .added: 1])
    #expect(reader.gutterShowsLineNumbersAndDiff)
    #expect(reader.rulerThickness == lineNumberThickness + 7)
    #expect(reader.revealDiffLine(3))
    #expect(reader.selectedLineNumber == 3)
    reader.reveal(byteOffset: document.lineTable.lineStarts[1])
    #expect(reader.currentLineNumber == 2)
}

@MainActor
@Test
func readerInstallsLineNumberRulerByDefault() {
    let reader = ReaderTextView()
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 180))
    scrollView.documentView = reader.view

    reader.apply(settings: ReaderSettings())

    #expect(scrollView.hasVerticalRuler)
    #expect((scrollView.verticalRulerView?.ruleThickness ?? 0) > 0)
}

@MainActor
@Test
func readingGeometryUsesClipWidthWithLegacyScroller() {
    let reader = ReaderTextView()
    let scrollView = NSScrollView(
        frame: NSRect(x: 0, y: 0, width: 480, height: 180)
    )
    scrollView.scrollerStyle = .legacy
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = false
    scrollView.documentView = reader.view
    reader.view.frame = scrollView.contentView.bounds
    let window = NSWindow(
        contentRect: scrollView.frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.contentView = scrollView
    reader.apply(settings: ReaderSettings())
    scrollView.tile()
    window.displayIfNeeded()

    let rulerWidth = scrollView.verticalRulerView?.frame.width ?? 0
    let clipWidth = scrollView.contentView.frame.width
    let readerWidth = reader.view.visibleRect.width - rulerWidth
    let availableWidth = clipWidth - rulerWidth
    let oldEquationWidth = scrollView.bounds.width - rulerWidth

    #expect(abs(readerWidth - availableWidth) <= 1)
    #expect(abs(readerWidth - oldEquationWidth) > 1)

    reader.apply(settings: ReaderSettings(lineNumbers: false))
    scrollView.tile()
    window.displayIfNeeded()

    let disabledAvailableWidth = scrollView.contentView.frame.width
    let disabledReaderWidth = reader.view.visibleRect.width
    #expect(abs(disabledReaderWidth - disabledAvailableWidth) <= 1)
    #expect(abs(disabledReaderWidth - readerWidth - rulerWidth) <= 1)
    #expect(abs(disabledAvailableWidth - availableWidth - rulerWidth) <= 1)
    withExtendedLifetime(window) {}
}

@MainActor
@Test
func wrapProbeKeepsLogicalLineDecorationsUniqueInRealReaderTextView() throws {
    let longBody = Array(repeating: "value += compute(value);", count: 24)
        .joined(separator: " ")
    let source = "fn one() {}\nfn wrapped() { \(longBody) }\nfn three() {}\n"
    let bytes = Array(source.utf8)
    let highlighted = try RustHighlighter().highlight(bytes: bytes)
    let document = ReaderDocument(
        bytes: bytes,
        highlightSpans: highlighted.spans,
        outlineFacets: highlighted.outlineFacets
    )
    let (reader, _, window) = renderOffscreen(document)
    reader.setDiffMarkers([2: .changed])
    reader.reveal(byteOffset: document.lineTable.lineStarts[1])

    var wrappedSettings = ReaderSettings()
    wrappedSettings.wrapLines = true
    reader.apply(settings: wrappedSettings)
    window.displayIfNeeded()
    reader.captureVisibleDecorationState()

    let manager = try #require(reader.view.textLayoutManager)
    let content = try #require(manager.textContentManager)
    var fragmentsByLine: [Int: [NSRect]] = [:]
    manager.enumerateTextLayoutFragments(
        from: content.documentRange.location,
        options: [.ensuresLayout]
    ) { fragment in
        let display = content.offset(
            from: content.documentRange.location,
            to: fragment.rangeInElement.location
        )
        guard display != NSNotFound,
              let byte = reader.byteOffset(forCharacterIndex: display),
              let line = document.lineTable.lineColumn(at: byte)?.line
        else { return true }
        fragmentsByLine[Int(line), default: []].append(fragment.layoutFragmentFrame)
        return true
    }

    let firstHeight = try #require(fragmentsByLine[1]?.first?.height)
    let wrappedHeight = try #require(fragmentsByLine[2]?.first?.height)
    #expect(fragmentsByLine.keys.sorted() == [1, 2, 3])
    #expect(fragmentsByLine.values.allSatisfy { $0.count == 1 })
    #expect(wrappedHeight > firstHeight * 2)
    #expect(reader.visibleLineNumbers.filter { $0 == 2 }.count == 1)
    #expect(reader.visibleCurrentLineNumbers == [2])
    #expect(reader.visibleDeclarationMarkerLines.filter { $0 == 2 }.count == 1)
    #expect(reader.diffMarkerCounts == [.changed: 1])
    print(
        "M11_WRAP_PROBE fragments=\(fragmentsByLine.values.reduce(0) { $0 + $1.count }) "
            + "wrappedHeight=\(wrappedHeight) lineHeight=\(firstHeight) "
            + "line2RulerCount=\(reader.visibleLineNumbers.filter { $0 == 2 }.count)"
    )
    withExtendedLifetime(window) {}
}

@MainActor
@Test
func wrapSettingReversesEveryTextKitAndScrollerProperty() {
    let reader = ReaderTextView()
    let scrollView = NSScrollView(
        frame: NSRect(x: 0, y: 0, width: 480, height: 180)
    )
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

    var wrappedSettings = ReaderSettings()
    wrappedSettings.wrapLines = true
    reader.apply(settings: wrappedSettings)
    let wrappedWidth = scrollView.contentView.bounds.width

    #expect(!scrollView.hasHorizontalScroller)
    #expect(!reader.view.isHorizontallyResizable)
    #expect(reader.view.autoresizingMask.contains(.width))
    #expect(reader.view.textContainer?.widthTracksTextView == true)
    #expect(reader.view.frame.width == wrappedWidth)
    #expect(reader.view.textContainer?.containerSize.width == wrappedWidth)

    window.setContentSize(NSSize(width: 360, height: 180))
    scrollView.tile()
    window.displayIfNeeded()
    let resizedDocumentWidth = scrollView.contentView.frame.width
        - (scrollView.verticalRulerView?.ruleThickness ?? 0)
    #expect(reader.view.frame.width == resizedDocumentWidth)
    #expect(reader.view.textContainer?.containerSize.width == (
        resizedDocumentWidth - reader.view.textContainerInset.width * 2
    ))

    reader.apply(settings: ReaderSettings())
    #expect(scrollView.hasHorizontalScroller)
    #expect(reader.view.isHorizontallyResizable)
    #expect(!reader.view.autoresizingMask.contains(.width))
    #expect(reader.view.textContainer?.widthTracksTextView == false)
    #expect(reader.view.textContainer?.containerSize.width == CGFloat.greatestFiniteMagnitude)
    withExtendedLifetime(window) {}
}

@MainActor
@Test
func foldAttachmentProviderSpikeCreatesUpdatesClicksAndExposesAX() throws {
    let source = """
        fn probe() {
            let one = 1;
            let two = 2;
            let three = one + two;
        }
        """
    let bytes = Array(source.utf8)
    let document = try DocumentLoader(source: { _ in bytes })
        .load(file: URL(fileURLWithPath: "/fold-spike.rs"))
        .document
    let fold = try #require(document.foldRegions.first { $0.kind == .declaration })
    let (reader, _, window) = renderOffscreen(document)
    #expect(reader.toggleFold(id: fold.id))
    reader.view.textLayoutManager?.textViewportLayoutController.layoutViewport()
    window.displayIfNeeded()

    let manager = try #require(reader.view.textLayoutManager)
    let content = try #require(manager.textContentManager)
    var providers: [NSTextAttachmentViewProvider] = []
    manager.enumerateTextLayoutFragments(
        from: content.documentRange.location,
        options: [.ensuresLayout]
    ) { fragment in
        providers.append(contentsOf: fragment.textAttachmentViewProviders)
        return true
    }
    let provider = try #require(providers.first)
    let providerView = try #require(provider.view)
    #expect(providers.count == 1)
    let initialSize = providerView.bounds.size
    func attachmentLineWidth() -> CGFloat {
        var width: CGFloat = 0
        manager.enumerateTextLayoutFragments(
            from: content.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            guard !fragment.textAttachmentViewProviders.isEmpty else { return true }
            for line in fragment.textLineFragments {
                width = max(width, line.typographicBounds.width)
            }
            return false
        }
        return width
    }
    let initialLineWidth = attachmentLineWidth()
    #expect(initialLineWidth >= initialSize.width)

    reader.setFoldMatchCount(3, for: fold.id)
    #expect(providerView.accessibilityLabel()?.contains("3 matches") == true)
    let threeSize = providerView.bounds.size
    let threeLineWidth = attachmentLineWidth()
    reader.setFoldMatchCount(999, for: fold.id)
    let nineNineNineSize = providerView.bounds.size
    let nineNineNineLineWidth = attachmentLineWidth()
    #expect(initialSize == threeSize)
    #expect(threeSize == nineNineNineSize)
    #expect(initialLineWidth == threeLineWidth)
    #expect(threeLineWidth == nineNineNineLineWidth)
    let lineHeight = try #require(manager.textLayoutFragment(for: .zero))
        .layoutFragmentFrame.height
    #expect(providerView.bounds.height <= lineHeight)

    let localPoint = reader.view.convert(
        NSPoint(x: providerView.bounds.midX, y: providerView.bounds.midY),
        from: providerView
    )
    #expect(providerView.hitTest(
        NSPoint(x: providerView.bounds.midX, y: providerView.bounds.midY)
    ) == nil)
    let event = try #require(NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: reader.view.convert(localPoint, to: nil),
        modifierFlags: [],
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 1,
        clickCount: 1,
        pressure: 1
    ))
    let mouseUp = try #require(NSEvent.mouseEvent(
        with: .leftMouseUp,
        location: reader.view.convert(localPoint, to: nil),
        modifierFlags: [],
        timestamp: 0.01,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 2,
        clickCount: 1,
        pressure: 0
    ))
    NSApp.postEvent(mouseUp, atStart: true)
    reader.view.mouseDown(with: event)
    #expect(!reader.renderedFoldIDsForTesting.contains(fold.id))
    #expect(!reader.view.string.contains("\u{FFFC}"))

    #expect(providerView.accessibilityLabel()?.contains("Collapsed, hides") == true)
    print(
        "M11_ATTACHMENT_SPIKE providerCreated=true countUpdated=true "
            + "clickExpanded=true axLabel=\(providerView.accessibilityLabel() ?? "nil") "
            + "hitTesting=NSTextView"
    )
    withExtendedLifetime(window) {}
}

@MainActor
@Test
func copyingASelectAllAcrossFoldsWritesTheCompleteSource() throws {
    let source = """
        fn first() {
            let one = 1;
            let two = 2;
        }

        fn second() {
            let three = 3;
            let four = 4;
        }
        """
    let bytes = Array(source.utf8)
    let document = try DocumentLoader(source: { _ in bytes })
        .load(file: URL(fileURLWithPath: "/fold-copy-all.rs"))
        .document
    let (reader, _, window) = renderOffscreen(document)
    for fold in document.foldRegions where fold.kind == .declaration {
        #expect(reader.toggleFold(id: fold.id))
    }
    #expect(reader.view.string.contains("\u{FFFC}"))
    reader.view.selectAll(nil)
    let selectedSource = reader.sourceText(
        forDisplaySelection: reader.view.selectedRange()
    )
    #expect(selectedSource == source)
    #expect(selectedSource?.contains("\u{FFFC}") == false)

    let pasteboard = NSPasteboard.withUniqueName()
    if preparePasteboardForCopyTest(pasteboard) {
        #expect(reader.view.writeSelection(to: pasteboard, type: .string))
        let copied = pasteboard.string(forType: .string)
        #expect(copied == source)
        #expect(copied?.contains("\u{FFFC}") == false)
    } else {
        print("M11_COPY_PASTEBOARD unavailable; source mapping verified")
    }
    pasteboard.releaseGlobally()
    withExtendedLifetime(window) {}
}

@MainActor
@Test
func copyingAPartialSelectionExpandsTheCrossedFoldToSourceBytes() throws {
    let source = """
        fn before() {
            let zero = 0;
        }

        fn folded() {
            let one = 1;
            let two = 2;
        }

        fn after() {
            let three = 3;
        }
        """
    let bytes = Array(source.utf8)
    let document = try DocumentLoader(source: { _ in bytes })
        .load(file: URL(fileURLWithPath: "/fold-copy-partial.rs"))
        .document
    let foldedHeaderOffset = (source as NSString).range(of: "fn folded").location
    let fold = try #require(document.foldRegions.first {
        $0.kind == .declaration
            && Int($0.headerRange.lowerBound) == foldedHeaderOffset
    })
    let (reader, _, window) = renderOffscreen(document)
    #expect(reader.toggleFold(id: fold.id))

    let display = reader.view.string as NSString
    let displayStart = display.range(of: "fn folded").location + 3
    let displayEnd = display.range(of: "fn after").location + 2
    let selection = NSRange(
        location: displayStart,
        length: displayEnd - displayStart
    )
    reader.view.setSelectedRange(selection)
    let sourceStart = foldedHeaderOffset + 3
    let sourceEnd = (source as NSString).range(of: "fn after").location + 2
    let expected = (source as NSString).substring(with: NSRange(
        location: sourceStart,
        length: sourceEnd - sourceStart
    ))
    let selectedSource = reader.sourceText(forDisplaySelection: selection)
    #expect(selectedSource == expected)
    #expect(selectedSource?.contains("\u{FFFC}") == false)

    let pasteboard = NSPasteboard.withUniqueName()
    if preparePasteboardForCopyTest(pasteboard) {
        #expect(reader.view.writeSelection(to: pasteboard, type: .string))
        let copied = pasteboard.string(forType: .string)
        #expect(copied == expected)
        #expect(copied?.contains("\u{FFFC}") == false)
    } else {
        print("M11_COPY_PASTEBOARD unavailable; source mapping verified")
    }
    pasteboard.releaseGlobally()
    withExtendedLifetime(window) {}
}

@MainActor
@Test
func foldReducerRendersOnlyMaximalRegionsAndScopesOverridesByFileAndContent() throws {
    let source = """
        mod outer {
            fn first() {
                let one = 1;
                let two = 2;
                let three = one + two;
            }

            fn second() {
                let four = 4;
                let five = 5;
                let six = four + five;
            }
        }
        """
    let bytes = Array(source.utf8)
    let loader = DocumentLoader(source: { _ in bytes })
    let oldDocument = try loader.load(file: URL(fileURLWithPath: "/scope.rs"))
        .document
    let outer = try #require(oldDocument.foldRegions.first { $0.kind == .container })
    let inner = try #require(oldDocument.foldRegions.first {
        $0.kind == .declaration
            && outer.bodyRange.lowerBound <= $0.bodyRange.lowerBound
            && $0.bodyRange.upperBound <= outer.bodyRange.upperBound
    })
    let reader = ReaderTextView()
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 180))
    scrollView.documentView = reader.view
    let oldURL = URL(fileURLWithPath: "/scope.rs")
    reader.display(document: oldDocument, fileURL: oldURL)

    #expect(reader.toggleFold(id: inner.id))
    #expect(reader.renderedFoldIDsForTesting == [inner.id])
    #expect(reader.toggleFold(id: outer.id))
    #expect(reader.logicalFoldIDsForTesting == [outer.id, inner.id])
    #expect(reader.renderedFoldIDsForTesting == [outer.id])
    #expect(reader.toggleFold(id: outer.id))
    #expect(reader.logicalFoldIDsForTesting == [inner.id])
    #expect(reader.renderedFoldIDsForTesting == [inner.id])

    let newBytes = Array((source + "\nfn added() {\n    work();\n    work();\n}\n").utf8)
    let newDocument = try DocumentLoader(source: { _ in newBytes })
        .load(file: oldURL)
        .document
    reader.display(document: newDocument, fileURL: oldURL)
    #expect(reader.logicalFoldIDsForTesting.isEmpty)
    reader.display(document: oldDocument, fileURL: oldURL)
    #expect(reader.logicalFoldIDsForTesting == [inner.id])
    reader.display(
        document: oldDocument,
        fileURL: URL(fileURLWithPath: "/different-file.rs")
    )
    #expect(reader.logicalFoldIDsForTesting.isEmpty)
}

@MainActor
@Test
func readingHeightLevelsUseTheSpecifiedKindsAndSkipSmallRegions() throws {
    let (document, regions) = readingHeightLevelDocument()
    let reader = ReaderTextView()
    reader.display(document: document, fileURL: URL(fileURLWithPath: "/levels.rs"))

    #expect(reader.readingHeightLevel == .full)
    #expect(reader.logicalFoldIDsForTesting.isEmpty)
    #expect(reader.renderedFoldIDsForTesting.isEmpty)

    #expect(reader.setReadingHeightLevel(.structure))
    #expect(reader.readingHeightLevel == .structure)
    #expect(
        reader.logicalFoldIDsForTesting
            == Set([
                regions.declaration.id,
                regions.imports.id,
                regions.cfgTest.id,
                regions.topLevelDeclaration.id,
            ]))
    #expect(reader.renderedFoldIDsForTesting == reader.logicalFoldIDsForTesting)
    #expect(!reader.logicalFoldIDsForTesting.contains(regions.smallDeclaration.id))
    for manualOnly in [regions.block, regions.comment, regions.attributes] {
        #expect(!reader.logicalFoldIDsForTesting.contains(manualOnly.id))
    }

    #expect(reader.setReadingHeightLevel(.overview))
    #expect(reader.readingHeightLevel == .overview)
    #expect(
        reader.logicalFoldIDsForTesting
            == Set([
                regions.container.id,
                regions.declaration.id,
                regions.imports.id,
                regions.cfgTest.id,
                regions.topLevelDeclaration.id,
            ]))
    #expect(
        reader.renderedFoldIDsForTesting
            == Set([
                regions.container.id,
                regions.imports.id,
                regions.cfgTest.id,
                regions.topLevelDeclaration.id,
            ]))
}

@MainActor
@Test
func manualFoldsArbitrateInBothDirectionsAndLevelSwitchClearsEveryPair() throws {
    let (document, regions) = readingHeightLevelDocument()
    let fileA = URL(fileURLWithPath: "/level-a.rs")
    let fileB = URL(fileURLWithPath: "/level-b.rs")
    let reader = ReaderTextView()

    reader.display(document: document, fileURL: fileA)
    #expect(reader.toggleFold(id: regions.block.id))
    #expect(reader.renderedFoldIDsForTesting.contains(regions.block.id))
    reader.display(document: document, fileURL: fileB)
    #expect(reader.toggleFold(id: regions.comment.id))
    #expect(reader.renderedFoldIDsForTesting.contains(regions.comment.id))

    #expect(reader.setReadingHeightLevel(.overview))
    #expect(reader.renderedFoldIDsForTesting.contains(regions.topLevelDeclaration.id))
    #expect(reader.toggleFold(id: regions.topLevelDeclaration.id))
    #expect(!reader.logicalFoldIDsForTesting.contains(regions.topLevelDeclaration.id))
    #expect(!reader.renderedFoldIDsForTesting.contains(regions.topLevelDeclaration.id))

    #expect(reader.setReadingHeightLevel(.full))
    #expect(reader.logicalFoldIDsForTesting.isEmpty)
    reader.display(document: document, fileURL: fileA)
    #expect(reader.logicalFoldIDsForTesting.isEmpty)
    reader.display(document: document, fileURL: fileB)
    #expect(reader.logicalFoldIDsForTesting.isEmpty)
}

@MainActor
@Test
func navigationUnfoldsManualAndBaselineAncestorsWithoutCrossingDirections() throws {
    let (document, regions) = readingHeightLevelDocument()
    let reader = ReaderTextView()
    reader.display(
        document: document,
        fileURL: URL(fileURLWithPath: "/level-navigation.rs")
    )

    #expect(reader.toggleFold(id: regions.block.id))
    #expect(
        reader.foldOverrideMembershipForTesting(regions.block.id)
            == (forcedFolded: true, forcedUnfolded: false)
    )
    reader.reveal(byteOffset: regions.block.bodyRange.lowerBound + 1)
    #expect(!reader.logicalFoldIDsForTesting.contains(regions.block.id))
    #expect(
        reader.foldOverrideMembershipForTesting(regions.block.id)
            == (forcedFolded: false, forcedUnfolded: false)
    )
    #expect(reader.foldOverridesAreDisjointForTesting)

    #expect(reader.setReadingHeightLevel(.overview))
    let nestedOffset = regions.declaration.bodyRange.lowerBound + 1
    #expect(reader.logicalFoldIDsForTesting.contains(regions.container.id))
    #expect(reader.logicalFoldIDsForTesting.contains(regions.declaration.id))
    _ = reader.activate(atByteOffset: nestedOffset)
    for region in [regions.container, regions.declaration] {
        #expect(!reader.logicalFoldIDsForTesting.contains(region.id))
        #expect(
            reader.foldOverrideMembershipForTesting(region.id)
                == (forcedFolded: false, forcedUnfolded: true)
        )
    }
    #expect(reader.foldOverridesAreDisjointForTesting)
    #expect(
        reader.renderedFoldIDsForTesting
            == Set([
                regions.imports.id,
                regions.cfgTest.id,
                regions.topLevelDeclaration.id,
            ]))
}

@MainActor
@Test
func focusSelectsTheSmallestFacetAtItsHeaderAndClosingBrace() throws {
    let (document, regions) = readingHeightLevelDocument()
    let reader = ReaderTextView()
    reader.display(document: document, fileURL: URL(fileURLWithPath: "/focus.rs"))

    #expect(reader.focusCurrentScope(at: 20))
    #expect(reader.isFocusMode)
    #expect(reader.focusedFoldIDForTesting == regions.declaration.id)
    #expect(!reader.logicalFoldIDsForTesting.contains(regions.container.id))
    #expect(!reader.logicalFoldIDsForTesting.contains(regions.declaration.id))
    for outside in [
        regions.imports,
        regions.cfgTest,
        regions.block,
        regions.comment,
        regions.attributes,
        regions.topLevelDeclaration,
    ] {
        #expect(reader.logicalFoldIDsForTesting.contains(outside.id))
    }
    #expect(!reader.logicalFoldIDsForTesting.contains(regions.smallDeclaration.id))
    #expect(reader.exitFocusMode())

    #expect(reader.focusCurrentScope(at: 79))
    #expect(reader.focusedFoldIDForTesting == regions.declaration.id)
}

@MainActor
@Test
func focusIsIndependentAndEscapeRestoresHeightAndOverridesExactly() throws {
    let (document, regions) = readingHeightLevelDocument()
    let reader = ReaderTextView()
    reader.display(document: document, fileURL: URL(fileURLWithPath: "/focus-restore.rs"))
    #expect(reader.setReadingHeightLevel(.structure))
    #expect(reader.toggleFold(id: regions.topLevelDeclaration.id))
    let savedLogical = reader.logicalFoldIDsForTesting
    let savedOverride = reader.foldOverrideMembershipForTesting(
        regions.topLevelDeclaration.id
    )

    #expect(reader.activate(atByteOffset: 20) > 0)
    let savedOccurrenceCount = reader.occurrenceCount
    #expect(reader.focusCurrentScope(at: 20))
    #expect(reader.readingHeightLevel == .structure)
    reader.view.cancelOperation(nil)

    #expect(!reader.isFocusMode)
    #expect(reader.occurrenceCount == savedOccurrenceCount)
    #expect(reader.readingHeightLevel == .structure)
    #expect(reader.logicalFoldIDsForTesting == savedLogical)
    #expect(
        reader.foldOverrideMembershipForTesting(regions.topLevelDeclaration.id)
            == savedOverride
    )
    reader.view.cancelOperation(nil)
    #expect(reader.occurrenceCount == 0)
}

@MainActor
@Test
func focusTreatsCfgTestAsAContainerAndNoScopeDoesNotFold() throws {
    let (document, regions) = readingHeightLevelDocument()
    let reader = ReaderTextView()
    reader.display(document: document, fileURL: URL(fileURLWithPath: "/focus-cfg.rs"))

    #expect(reader.focusCurrentScope(at: 295))
    #expect(reader.focusedFoldIDForTesting == regions.cfgTest.id)
    #expect(!reader.logicalFoldIDsForTesting.contains(regions.cfgTest.id))
    #expect(reader.exitFocusMode())

    #expect(!reader.focusCurrentScope(at: 260))
    #expect(!reader.isFocusMode)
    #expect(reader.logicalFoldIDsForTesting.isEmpty)
}

@MainActor
@Test
func focusFollowsExplicitCrossFileNavigationButNotLiveScroll() throws {
    let (document, regions) = readingHeightLevelDocument()
    let reader = ReaderTextView()
    reader.display(document: document, fileURL: URL(fileURLWithPath: "/focus-a.rs"))
    #expect(reader.focusCurrentScope(at: 20))

    reader.didLiveScrollWhileFocused()
    #expect(reader.isFocusMode)
    #expect(!reader.focusFollowsExplicitNavigationForTesting)

    reader.display(document: document, fileURL: URL(fileURLWithPath: "/focus-b.rs"))
    #expect(reader.followFocusForExplicitNavigation(to: 475))
    #expect(reader.isFocusMode)
    #expect(reader.focusFollowsExplicitNavigationForTesting)
    #expect(reader.focusedFoldIDForTesting == regions.topLevelDeclaration.id)

    reader.display(document: document, fileURL: URL(fileURLWithPath: "/focus-c.rs"))
    #expect(!reader.followFocusForExplicitNavigation(to: 260))
    #expect(!reader.isFocusMode)
    #expect(reader.logicalFoldIDsForTesting.isEmpty)

    #expect(reader.focusCurrentScope(at: 20))
    reader.clear()
    #expect(!reader.isFocusMode)
}

@MainActor
@Test
func focusUsesTheExplicitLandingPointAfterDeferredSyntaxLoads() throws {
    let (document, regions) = readingHeightLevelDocument()
    let reader = ReaderTextView()
    reader.display(document: document, fileURL: URL(fileURLWithPath: "/focus-loaded.rs"))
    #expect(reader.focusCurrentScope(at: 20))

    let plain = ReaderDocument(
        bytes: document.bytes,
        lineTable: document.lineTable,
        byteUTF16Map: document.byteUTF16Map,
        highlightSpans: [],
        outlineFacets: [],
        foldRegions: []
    )
    reader.display(document: plain, fileURL: URL(fileURLWithPath: "/focus-plain.rs"))
    reader.updateSyntax(document: document, focusByteOffset: 475)

    #expect(reader.isFocusMode)
    #expect(reader.focusedFoldIDForTesting == regions.topLevelDeclaration.id)
    #expect(!reader.logicalFoldIDsForTesting.contains(regions.topLevelDeclaration.id))
    #expect(reader.logicalFoldIDsForTesting.contains(regions.declaration.id))
}

@MainActor
@Test
func optionFoldHandleRecursivelyTogglesSiblingRegions() throws {
    let source = """
        fn first() {
            let one = 1;
            let two = 2;
            let three = one + two;
        }

        fn second() {
            let four = 4;
            let five = 5;
            let six = four + five;
        }
        """
    let bytes = Array(source.utf8)
    let document = try DocumentLoader(source: { _ in bytes })
        .load(file: URL(fileURLWithPath: "/siblings.rs"))
        .document
    let siblings = document.foldRegions.filter { $0.kind == .declaration }
    #expect(siblings.count == 2)
    let first = try #require(siblings.first)
    let line = try #require(document.lineTable.lineColumn(
        at: first.headerRange.lowerBound
    )).line
    let reader = ReaderTextView()
    reader.display(document: document)

    #expect(reader.toggleFold(atLine: Int(line), recursiveSiblings: true))
    #expect(reader.logicalFoldIDsForTesting == Set(siblings.map(\.id)))
    #expect(reader.toggleFold(atLine: Int(line), recursiveSiblings: true))
    #expect(reader.logicalFoldIDsForTesting.isEmpty)
}

@MainActor
@Test
func foldingKeepsRulerWhenLineNumbersAndDiffAreOff() throws {
    let source = """
        fn visible_handle() {
            let one = 1;
            let two = 2;
            let three = one + two;
        }
        """
    let bytes = Array(source.utf8)
    let document = try DocumentLoader(source: { _ in bytes })
        .load(file: URL(fileURLWithPath: "/gutter.rs"))
        .document
    let fold = try #require(document.foldRegions.first {
        $0.summary.hiddenLineCount >= 2
    })
    let (reader, scrollView, window) = renderOffscreen(document)
    reader.apply(settings: ReaderSettings(lineNumbers: false))
    let line = try #require(document.lineTable.lineColumn(
        at: fold.headerRange.lowerBound
    )).line

    #expect(scrollView.hasVerticalRuler)
    #expect(reader.visibleFoldHandleLinesForTesting.contains(Int(line)))
    #expect(reader.toggleFold(atLine: Int(line)))
    #expect(reader.renderedFoldIDsForTesting.contains(fold.id))

    let smallBytes = Array("fn x() {\n    a();\n}\n".utf8)
    let smallFold = FoldRegion(
        id: FoldID(rawValue: 0),
        kind: .declaration,
        headerRange: ByteRange(lowerBound: 0, upperBound: 8),
        bodyRange: ByteRange(
            lowerBound: 8,
            upperBound: UInt32(smallBytes.count - 2)
        ),
        outlineDepth: 0,
        summary: FoldSummary(hiddenLineCount: 1)
    )
    let smallDocument = ReaderDocument(
        bytes: smallBytes,
        lineTable: LineTable(bytes: smallBytes),
        byteUTF16Map: ByteUTF16Map(validUTF8: smallBytes),
        highlightSpans: [],
        outlineFacets: [],
        foldRegions: [smallFold]
    )
    reader.display(document: smallDocument)
    reader.apply(settings: ReaderSettings(lineNumbers: false))
    #expect(!scrollView.hasVerticalRuler)
    #expect(reader.visibleFoldHandleLinesForTesting.isEmpty)
    withExtendedLifetime(window) {}
}

@MainActor
@Test
func foldMutationRestoresIndependentSelectionAndViewportLatentAnchors() throws {
    let firstBody = (0..<32).map { "    let first_\($0) = \($0);" }
        .joined(separator: "\n")
    let secondBody = (0..<32).map { "    let second_\($0) = \($0);" }
        .joined(separator: "\n")
    let source = "fn first() {\n\(firstBody)\n}\n\nfn second() {\n\(secondBody)\n}\n"
    let bytes = Array(source.utf8)
    let document = try DocumentLoader(source: { _ in bytes })
        .load(file: URL(fileURLWithPath: "/anchors.rs"))
        .document
    let declarations = document.foldRegions.filter { $0.kind == .declaration }
    let first = try #require(declarations.first { region in
        let range = Int(region.headerRange.lowerBound)..<Int(region.headerRange.upperBound)
        return String(decoding: bytes[range], as: UTF8.self).contains("first")
    })
    let second = try #require(declarations.first { region in
        let range = Int(region.headerRange.lowerBound)..<Int(region.headerRange.upperBound)
        return String(decoding: bytes[range], as: UTF8.self).contains("second")
    })
    let selectionByte = UInt32((source as NSString).range(of: "first_20").location)
    let requestedViewportByte = UInt32(
        (source as NSString).range(of: "second_20").location
    )
    let (reader, _, window) = renderOffscreen(document)
    reader.restore(
        scrollByteOffset: requestedViewportByte,
        selectionByteOffset: selectionByte
    )
    let viewportByte = try #require(reader.firstVisibleByteOffset())
    #expect(first.bodyRange.contains(selectionByte))
    #expect(second.bodyRange.contains(viewportByte))

    #expect(reader.toggleFold(id: first.id))
    #expect(reader.latentSelectionAnchorForTesting?.0 == selectionByte)
    #expect(reader.latentSelectionAnchorForTesting?.1 == first.id)
    #expect(reader.latentViewportAnchorForTesting == nil)

    #expect(reader.toggleFold(id: second.id))
    #expect(reader.latentSelectionAnchorForTesting?.1 == first.id)
    #expect(reader.latentViewportAnchorForTesting?.0 == viewportByte)
    #expect(reader.latentViewportAnchorForTesting?.1 == second.id)

    #expect(reader.toggleFold(id: first.id))
    #expect(reader.latentSelectionAnchorForTesting == nil)
    #expect(reader.latentViewportAnchorForTesting?.1 == second.id)
    #expect(reader.byteOffset(
        forCharacterIndex: reader.view.selectedRange().location
    ) == selectionByte)

    #expect(reader.toggleFold(id: second.id))
    #expect(reader.latentViewportAnchorForTesting == nil)
    #expect(reader.firstVisibleByteOffset() == viewportByte)
    withExtendedLifetime(window) {}
}

@MainActor
@Test
func foldedReferenceScanningDoesNotGrowWithHiddenBody() throws {
    func counts(lineCount: Int) throws -> (visible: Int, folded: Int) {
        let body = (0..<lineCount).map { "    value += \($0);" }
            .joined(separator: "\n")
        let source = "fn scan() {\n    let mut value = 0;\n\(body)\n}\n"
        let bytes = Array(source.utf8)
        let document = try DocumentLoader(source: { _ in bytes })
            .load(file: URL(fileURLWithPath: "/scan-\(lineCount).rs"))
            .document
        let fold = try #require(document.foldRegions.first {
            $0.kind == .declaration
        })
        let (reader, _, window) = renderOffscreen(document)
        let visible = reader.renderingCoordinator.referenceScannedCount
        #expect(reader.toggleFold(id: fold.id))
        reader.view.textLayoutManager?.textViewportLayoutController.layoutViewport()
        window.displayIfNeeded()
        let folded = reader.renderingCoordinator.referenceScannedCount
        withExtendedLifetime(window) {}
        return (visible, folded)
    }

    let small = try counts(lineCount: 80)
    let large = try counts(lineCount: 800)
    #expect(small.visible > 0)
    #expect(large.visible > 0)
    #expect(small.folded == large.folded)
    #expect(large.folded < large.visible)
}

@MainActor
@Test
func lineNumberRulerDrawsOnlyVisibleKnownLinesAndCanBeDisabled() throws {
    let source = "fn one() {}\nfn two() {}\nfn three() {}"
    let bytes = Array(source.utf8)
    let highlighted = try RustHighlighter().highlight(bytes: bytes)
    let document = ReaderDocument(
        bytes: bytes,
        highlightSpans: highlighted.spans,
        outlineFacets: highlighted.outlineFacets
    )
    let (reader, scrollView, window) = renderOffscreen(document)
    withExtendedLifetime(window) {
        #expect(scrollView.hasVerticalRuler)
        #expect(reader.visibleLineNumbers.contains(1))
        #expect(reader.visibleLineNumbers.allSatisfy { (1...3).contains($0) })
        #expect(reader.visibleDeclarationMarkerLines == [1, 2, 3])

        reader.apply(settings: ReaderSettings(lineNumbers: false))
        window.displayIfNeeded()

        #expect(!scrollView.hasVerticalRuler)
        #expect(scrollView.verticalRulerView == nil)
    }
}

@MainActor
@Test
func clickingIdentifiersReplacesOccurrencesAndTracksOneCurrentLine() throws {
    let source = """
        fn alpha() {}
        fn beta() { alpha(); }
        fn gamma() { alpha(); beta(); }
        """
    let bytes = Array(source.utf8)
    let highlighted = try RustHighlighter().highlight(bytes: bytes)
    let document = ReaderDocument(
        bytes: bytes,
        highlightSpans: highlighted.spans,
        outlineFacets: highlighted.outlineFacets
    )
    let (reader, _, window) = renderOffscreen(document)
    let alpha = try #require(source.range(of: "alpha"))
    let alphaOffset = UInt32(source[..<alpha.lowerBound].utf8.count)
    let beta = try #require(source.range(of: "beta"))
    let betaOffset = UInt32(source[..<beta.lowerBound].utf8.count)

    #expect(reader.activate(atByteOffset: alphaOffset) == 3)
    window.displayIfNeeded()
    #expect(reader.currentLineNumber == 1)
    #expect(reader.visibleCurrentLineNumbers == [1])
    #expect(reader.view.textStorage?.attribute(
        .backgroundColor,
        at: Int(alphaOffset),
        effectiveRange: nil
    ) == nil)
    #expect(renderedBackgroundColors(in: reader).contains { colorsEqual(
        $0,
        ReaderTheme(settings: ReaderSettings()).occurrenceColor
    ) })
    let alphaCharacterOffset = try #require(
        document.byteUTF16Map.utf16Offset(forByte: Int(alphaOffset))
    )
    let alphaCharacterRange = NSRange(
        location: alphaCharacterOffset,
        length: "alpha".utf16.count
    )
    #expect(renderedColors(
        in: reader,
        intersecting: alphaCharacterRange
    ).contains { colorsEqual(
        $0,
        ReaderTheme(settings: ReaderSettings()).color(for: .functionName)
    ) })

    #expect(reader.activate(atByteOffset: betaOffset) == 2)
    #expect(reader.currentLineNumber == 2)
    #expect(reader.occurrenceCount == 2)
    #expect(!renderedBackgroundRanges(in: reader).contains {
        $0.contains(Int(alphaOffset))
    })

    reader.view.cancelOperation(nil)
    #expect(reader.occurrenceCount == 0)
    #expect(reader.currentLineNumber == 2)

    #expect(reader.activate(atByteOffset: 2) == 0)
    #expect(reader.currentLineNumber == 1)
}

@MainActor
@Test
func occurrenceHighlightsPreserveDifferentSyntaxForegroundColors() throws {
    let source = "struct Widget;\nfn make(value: Widget) -> Widget { value }\n"
    let bytes = Array(source.utf8)
    let highlighted = try RustHighlighter().highlight(bytes: bytes)
    let document = ReaderDocument(
        bytes: bytes,
        highlightSpans: highlighted.spans,
        outlineFacets: highlighted.outlineFacets
    )
    let (reader, _, window) = renderOffscreen(document)
    let theme = ReaderTheme(settings: ReaderSettings())

    func range(for kind: HighlightKind) throws -> NSRange {
        let span = try #require(highlighted.spans.first {
            $0.kind == kind
                && String(
                    bytes: bytes[Int($0.range.lowerBound)..<Int($0.range.upperBound)],
                    encoding: .utf8
                ) == (kind == .functionName ? "make" : "Widget")
        })
        return try #require(document.byteUTF16Map.nsRange(
            byteLowerBound: Int(span.range.lowerBound),
            byteUpperBound: Int(span.range.upperBound)
        ))
    }

    let declaration = try range(for: .declarationTitle)
    let typeReference = try range(for: .typeName)
    let untouchedFunction = try range(for: .functionName)
    #expect(reader.activate(atByteOffset: UInt32(declaration.location)) == 3)
    window.displayIfNeeded()

    for (range, kind) in [
        (declaration, HighlightKind.declarationTitle),
        (typeReference, HighlightKind.typeName),
    ] {
        #expect(renderedColors(in: reader, intersecting: range).contains {
            colorsEqual($0, theme.color(for: kind))
        })
        let backgrounds = renderedBackgroundColors(
            in: reader,
            intersecting: range
        )
        if range == declaration {
            #expect(!backgrounds.contains { colorsEqual($0, theme.occurrenceColor) })
        } else {
            #expect(backgrounds.contains { colorsEqual($0, theme.occurrenceColor) })
        }
    }
    #expect(renderedColors(
        in: reader,
        intersecting: untouchedFunction
    ).contains { colorsEqual($0, theme.color(for: .functionName)) })
    #expect(renderedBackgroundColors(
        in: reader,
        intersecting: untouchedFunction
    ).isEmpty)
}

@MainActor
@Test
func semanticLocalAndParamReferencesUseDistinctViewportStyles() throws {
    let source = """
        fn demo(param: i32) -> i32 {
            let local = param;
            local + param
        }
        """
    let bytes = Array(source.utf8)
    let highlighted = try RustHighlighter().highlight(bytes: bytes)
    let document = ReaderDocument(
        bytes: bytes,
        highlightSpans: highlighted.spans,
        outlineFacets: highlighted.outlineFacets,
        localBindings: highlighted.bindings,
        referencesByBinding: highlighted.referencesByBinding
    )
    let paramIndex = try #require(highlighted.bindings.indices.first {
        if case .param = highlighted.bindings[$0].kind { true } else { false }
    })
    let localIndex = try #require(highlighted.bindings.indices.first {
        if case .letBinding = highlighted.bindings[$0].kind { true } else { false }
    })
    let paramRange = try #require(document.byteUTF16Map.nsRange(
        byteLowerBound: Int(highlighted.referencesByBinding[paramIndex][0].lowerBound),
        byteUpperBound: Int(highlighted.referencesByBinding[paramIndex][0].upperBound)
    ))
    let localRange = try #require(document.byteUTF16Map.nsRange(
        byteLowerBound: Int(highlighted.referencesByBinding[localIndex][0].lowerBound),
        byteUpperBound: Int(highlighted.referencesByBinding[localIndex][0].upperBound)
    ))
    let (reader, _, window) = renderOffscreen(document)
    let localColor = try #require(
        renderedColors(in: reader, intersecting: localRange).first
    )
    let paramColor = try #require(
        renderedColors(in: reader, intersecting: paramRange).first
    )
    let referenceRanges = highlighted.referencesByBinding.flatMap { $0 }
    let declarationSpan = try #require(highlighted.spans.first {
        $0.kind == .functionName
    })
    let declarationRange = try #require(document.byteUTF16Map.nsRange(
        byteLowerBound: Int(declarationSpan.range.lowerBound),
        byteUpperBound: Int(declarationSpan.range.upperBound)
    ))
    let declarationFont = try #require(reader.view.textStorage?.attribute(
        .font,
        at: declarationRange.location,
        effectiveRange: nil
    ) as? NSFont)

    #expect(localColor.alphaComponent == 1)
    #expect(paramColor.alphaComponent < localColor.alphaComponent)
    #expect(reader.renderingCoordinator.referenceStyledFragmentCount > 0)
    #expect(reader.renderingCoordinator.referenceAttributeRunCount > 0)
    #expect(referenceRanges.allSatisfy { reference in
        document.highlightSpans.allSatisfy {
            !$0.range.overlaps(reference)
        }
    })
    #expect(abs(
        declarationFont.pointSize - ReaderTheme(
            settings: ReaderSettings()
        ).functionNameFontSize
    ) < 0.01)
    for range in [localRange, paramRange] {
        #expect(renderedAttributes(
            in: reader,
            intersecting: range
        ).allSatisfy {
            $0.attributes[.font] == nil
                && $0.attributes[.paragraphStyle] == nil
                && $0.attributes[.baselineOffset] == nil
                && $0.attributes[.kern] == nil
        })
        #expect(renderedBackgroundColors(
            in: reader,
            intersecting: range
        ).isEmpty)
    }

    let paramByteOffset = highlighted.referencesByBinding[paramIndex][0].lowerBound
    let otherParamReference = highlighted.referencesByBinding[paramIndex][1]
    let otherParamRange = try #require(document.byteUTF16Map.nsRange(
        byteLowerBound: Int(otherParamReference.lowerBound),
        byteUpperBound: Int(otherParamReference.upperBound)
    ))
    #expect(reader.activate(atByteOffset: paramByteOffset) == 3)
    #expect(renderedBackgroundColors(
        in: reader,
        intersecting: paramRange
    ).isEmpty)
    #expect(!renderedBackgroundColors(
        in: reader,
        intersecting: otherParamRange
    ).isEmpty)
    #expect(try #require(
        renderedColors(in: reader, intersecting: paramRange).first
    ).alphaComponent < 1)

    reader.view.cancelOperation(nil)
    reader.apply(settings: ReaderSettings(syntaxFormatting: false))
    window.displayIfNeeded()
    #expect(reader.renderingCoordinator.referenceStyledFragmentCount == 0)
    #expect(reader.renderingCoordinator.referenceAttributeRunCount == 0)
    #expect(renderedColors(in: reader, intersecting: paramRange).isEmpty)
    let typeSpan = try #require(highlighted.spans.first { $0.kind == .typeName })
    let typeRange = try #require(document.byteUTF16Map.nsRange(
        byteLowerBound: Int(typeSpan.range.lowerBound),
        byteUpperBound: Int(typeSpan.range.upperBound)
    ))
    #expect(!renderedColors(in: reader, intersecting: typeRange).isEmpty)
    withExtendedLifetime(window) {}
}

@MainActor
@Test
func defaultVisualSettingsMatchLegacyRenderingSnapshotByteForByte() throws {
    let fixture = try visualSettingsFixture()
    let (reader, _, window) = renderOffscreen(fixture.document)
    let storage = try #require(reader.view.textStorage)
    let parameterColor = try #require(
        renderedColors(in: reader, intersecting: fixture.parameterReference).first
    )
    let functionAttributes = storage.attributes(
        at: fixture.functionName.location,
        effectiveRange: nil
    )
    let emphasisAttributes = storage.attributes(
        at: fixture.declarationEmphasis.location,
        effectiveRange: nil
    )
    let actual = visualSnapshotData(
        parameterColor: parameterColor,
        markerColor: reader.declarationMarkerColor(for: .fn),
        functionFont: try #require(functionAttributes[.font] as? NSFont),
        functionKern: try #require(functionAttributes[.kern] as? NSNumber).doubleValue,
        emphasisFont: try #require(emphasisAttributes[.font] as? NSFont)
    )
    let legacyTheme = ReaderTheme(settings: ReaderSettings())
    let expected = visualSnapshotData(
        parameterColor: legacyTheme.foregroundColor.withAlphaComponent(0.72),
        markerColor: legacyTheme.color(for: .functionName).withAlphaComponent(0.7),
        functionFont: .monospacedSystemFont(
            ofSize: legacyTheme.functionNameFontSize,
            weight: .semibold
        ),
        functionKern: 0.15,
        emphasisFont: .monospacedSystemFont(
            ofSize: legacyTheme.fontSize,
            weight: .semibold
        )
    )

    #expect(actual == expected)
    withExtendedLifetime(window) {}
}

@MainActor
@Test
func visualSettingsImmediatelyRedrawAnOpenReader() throws {
    let fixture = try visualSettingsFixture()
    let (reader, _, window) = renderOffscreen(fixture.document)
    let storage = try #require(reader.view.textStorage)
    let oldParameterAlpha = try #require(
        renderedColors(in: reader, intersecting: fixture.parameterReference).first
    ).alphaComponent
    let oldMarkerAlpha = reader.declarationMarkerColor(for: .fn).alphaComponent
    let oldFunctionFont = try #require(storage.attribute(
        .font,
        at: fixture.functionName.location,
        effectiveRange: nil
    ) as? NSFont)
    let oldEmphasisFont = try #require(storage.attribute(
        .font,
        at: fixture.declarationEmphasis.location,
        effectiveRange: nil
    ) as? NSFont)

    reader.apply(settings: ReaderSettings(
        parameterReferenceAlpha: 0.4,
        declarationMarkerAlpha: 0.25,
        functionDeclarationFontWeight: Double(NSFont.Weight.regular.rawValue),
        declarationEmphasisFontWeight: Double(NSFont.Weight.bold.rawValue)
    ))
    window.displayIfNeeded()

    let newParameterAlpha = try #require(
        renderedColors(in: reader, intersecting: fixture.parameterReference).first
    ).alphaComponent
    let newMarkerAlpha = reader.declarationMarkerColor(for: .fn).alphaComponent
    let newFunctionFont = try #require(storage.attribute(
        .font,
        at: fixture.functionName.location,
        effectiveRange: nil
    ) as? NSFont)
    let newEmphasisFont = try #require(storage.attribute(
        .font,
        at: fixture.declarationEmphasis.location,
        effectiveRange: nil
    ) as? NSFont)

    #expect(abs(newParameterAlpha - 0.4) < 0.001)
    #expect(newParameterAlpha != oldParameterAlpha)
    #expect(abs(newMarkerAlpha - 0.25) < 0.001)
    #expect(newMarkerAlpha != oldMarkerAlpha)
    #expect(newFunctionFont.fontName == NSFont.monospacedSystemFont(
        ofSize: 14,
        weight: .regular
    ).fontName)
    #expect(newFunctionFont.fontName != oldFunctionFont.fontName)
    #expect(newEmphasisFont.fontName == NSFont.monospacedSystemFont(
        ofSize: 13,
        weight: .bold
    ).fontName)
    #expect(newEmphasisFont.fontName != oldEmphasisFont.fontName)
    withExtendedLifetime(window) {}
}

@Test
func m6ReferenceDensityStylesOnlyViewportFragments() async throws {
    let (_, document) = try await m6ReferenceDocument()
    let totalReferences = document.referencesByBinding.lazy
        .map(\.count)
        .reduce(0, +)
    let (runs, fragments, backingFontRuns) = await MainActor.run {
        let (reader, _, window) = renderOffscreen(document)
        let runs = reader.renderingCoordinator.referenceAttributeRunCount
        let fragments =
            reader.renderingCoordinator.referenceStyledFragmentCount
        var backingFontRuns = 0
        reader.view.textStorage?.enumerateAttribute(
            .font,
            in: NSRange(
                location: 0,
                length: reader.view.textStorage?.length ?? 0
            )
        ) { _, _, _ in
            backingFontRuns += 1
        }
        withExtendedLifetime(window) {}
        return (runs, fragments, backingFontRuns)
    }

    #expect(totalReferences == 35_000)
    #expect(runs > 0 && runs < 350)
    #expect(fragments > 0 && fragments < 350)
    #expect(runs * 100 < totalReferences)
    #expect(backingFontRuns < 5_000)
    print(
        "M6_REFERENCE_RENDER totalReferences=\(totalReferences) "
            + "backingFontRuns=\(backingFontRuns) "
            + "referenceAttributeRuns=\(runs) "
            + "referenceStyledFragments=\(fragments)"
    )
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
    reader.apply(settings: ReaderSettings())
    reader.display(document: document)
    reader.view.textLayoutManager?.textViewportLayoutController.layoutViewport()
    reader.captureVisibleDecorationState()
    window.displayIfNeeded()
    scrollView.verticalRulerView?.needsDisplay = true
    window.displayIfNeeded()
    return (reader, scrollView, window)
}

private func preparePasteboardForCopyTest(_ pasteboard: NSPasteboard) -> Bool {
    pasteboard.clearContents()
    guard pasteboard.writeObjects(["probe" as NSString]) else { return false }
    pasteboard.declareTypes([.string], owner: nil)
    return true
}

private func readingHeightLevelDocument() -> (
    document: ReaderDocument,
    regions: (
        container: FoldRegion,
        declaration: FoldRegion,
        imports: FoldRegion,
        cfgTest: FoldRegion,
        block: FoldRegion,
        comment: FoldRegion,
        attributes: FoldRegion,
        smallDeclaration: FoldRegion,
        topLevelDeclaration: FoldRegion
    )
) {
    let bytes = Array(String(repeating: "line\n", count: 120).utf8)
    func region(
        _ rawID: UInt32,
        _ kind: FoldKind,
        _ header: UInt32,
        _ body: Range<UInt32>,
        _ depth: Int,
        hiddenLines: Int = 3
    ) -> FoldRegion {
        FoldRegion(
            id: FoldID(rawValue: rawID),
            kind: kind,
            headerRange: ByteRange(lowerBound: header, upperBound: header + 4),
            bodyRange: ByteRange(
                lowerBound: body.lowerBound,
                upperBound: body.upperBound
            ),
            outlineDepth: depth,
            summary: FoldSummary(hiddenLineCount: hiddenLines)
        )
    }
    let regions = (
        container: region(0, .container, 0, 5..<250, 0),
        declaration: region(1, .declaration, 20, 25..<80, 1),
        imports: region(2, .imports, 255, 260..<290, 0),
        cfgTest: region(3, .cfgTest, 295, 300..<360, 0),
        block: region(4, .block, 365, 370..<400, 0),
        comment: region(5, .comment, 400, 405..<430, 0),
        attributes: region(6, .attributes, 430, 435..<460, 0),
        smallDeclaration: region(
            7,
            .declaration,
            460,
            465..<470,
            0,
            hiddenLines: 1
        ),
        topLevelDeclaration: region(8, .declaration, 475, 480..<520, 0)
    )
    return (
        ReaderDocument(
            bytes: bytes,
            lineTable: LineTable(bytes: bytes),
            byteUTF16Map: ByteUTF16Map(validUTF8: bytes),
            highlightSpans: [],
            outlineFacets: [
                OutlineFacet(
                    kind: .mod,
                    name: "outer",
                    range: ByteRange(lowerBound: 0, upperBound: 250),
                    nameRange: ByteRange(lowerBound: 0, upperBound: 4),
                    depth: 0
                ),
                OutlineFacet(
                    kind: .fn,
                    name: "target",
                    range: ByteRange(lowerBound: 20, upperBound: 80),
                    nameRange: ByteRange(lowerBound: 20, upperBound: 24),
                    depth: 1
                ),
                OutlineFacet(
                    kind: .mod,
                    name: "tests",
                    range: ByteRange(lowerBound: 295, upperBound: 360),
                    nameRange: ByteRange(lowerBound: 295, upperBound: 299),
                    depth: 0
                ),
                OutlineFacet(
                    kind: .fn,
                    name: "top_level",
                    range: ByteRange(lowerBound: 475, upperBound: 520),
                    nameRange: ByteRange(lowerBound: 475, upperBound: 479),
                    depth: 0
                ),
            ],
            foldRegions: [
                regions.container,
                regions.declaration,
                regions.imports,
                regions.cfgTest,
                regions.block,
                regions.comment,
                regions.attributes,
                regions.smallDeclaration,
                regions.topLevelDeclaration,
            ]
        ),
        regions
    )
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
private func renderedAttributes(
    in reader: ReaderTextView,
    intersecting expectedRange: NSRange
) -> [(range: NSRange, attributes: [NSAttributedString.Key: Any])] {
    guard let manager = reader.view.textLayoutManager,
          let content = manager.textContentManager
    else { return [] }
    var result: [
        (range: NSRange, attributes: [NSAttributedString.Key: Any])
    ] = []
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
        if NSIntersectionRange(expectedRange, range).length > 0 {
            result.append((range, attributes))
        }
        return true
    }
    return result
}

@MainActor
private func renderedBackgroundColors(
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
           let color = attributes[.backgroundColor] as? NSColor
        {
            colors.append(color)
        }
        return true
    }
    return colors
}

@MainActor
private func renderedBackgroundRanges(in reader: ReaderTextView) -> [NSRange] {
    guard let manager = reader.view.textLayoutManager,
          let content = manager.textContentManager
    else { return [] }
    var ranges: [NSRange] = []
    manager.enumerateRenderingAttributes(
        from: content.documentRange.location,
        reverse: false
    ) { _, attributes, textRange in
        guard attributes[.backgroundColor] != nil else { return true }
        let lower = content.offset(
            from: content.documentRange.location,
            to: textRange.location
        )
        let upper = content.offset(
            from: content.documentRange.location,
            to: textRange.endLocation
        )
        ranges.append(NSRange(location: lower, length: upper - lower))
        return true
    }
    return ranges
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

private func visualSettingsFixture() throws -> (
    document: ReaderDocument,
    parameterReference: NSRange,
    functionName: NSRange,
    declarationEmphasis: NSRange
) {
    let source = """
        fn demo(param: i32) -> i32 { param }
        const LIMIT: i32 = 1;
        """
    let bytes = Array(source.utf8)
    let highlighted = try RustHighlighter().highlight(bytes: bytes)
    let document = ReaderDocument(
        bytes: bytes,
        highlightSpans: highlighted.spans,
        outlineFacets: highlighted.outlineFacets,
        localBindings: highlighted.bindings,
        referencesByBinding: highlighted.referencesByBinding
    )
    let parameterBinding = try #require(highlighted.bindings.indices.first {
        if case .param = highlighted.bindings[$0].kind { true } else { false }
    })
    let parameterReference = try #require(
        highlighted.referencesByBinding[parameterBinding].first
    )
    let functionSpan = try #require(highlighted.spans.first {
        $0.kind == .functionName
    })
    let emphasisSpan = try #require(highlighted.spans.first {
        $0.kind == .declarationEmphasis
    })
    return (
        document,
        try #require(document.byteUTF16Map.nsRange(
            byteLowerBound: Int(parameterReference.lowerBound),
            byteUpperBound: Int(parameterReference.upperBound)
        )),
        try #require(document.byteUTF16Map.nsRange(
            byteLowerBound: Int(functionSpan.range.lowerBound),
            byteUpperBound: Int(functionSpan.range.upperBound)
        )),
        try #require(document.byteUTF16Map.nsRange(
            byteLowerBound: Int(emphasisSpan.range.lowerBound),
            byteUpperBound: Int(emphasisSpan.range.upperBound)
        ))
    )
}

@MainActor
private func visualSnapshotData(
    parameterColor: NSColor,
    markerColor: NSColor,
    functionFont: NSFont,
    functionKern: Double,
    emphasisFont: NSFont
) -> Data {
    let appearance = NSAppearance(named: .aqua)!
    var colorComponents: [CGFloat] = []
    appearance.performAsCurrentDrawingAppearance {
        for color in [parameterColor, markerColor] {
            guard let rgb = color.usingColorSpace(.deviceRGB) else { continue }
            var red = CGFloat.zero
            var green = CGFloat.zero
            var blue = CGFloat.zero
            var alpha = CGFloat.zero
            rgb.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            colorComponents.append(contentsOf: [red, green, blue, alpha])
        }
    }
    let fields = colorComponents.map { String(format: "%.17g", Double($0)) } + [
        functionFont.fontName,
        String(format: "%.17g", Double(functionFont.pointSize)),
        String(format: "%.17g", functionKern),
        emphasisFont.fontName,
        String(format: "%.17g", Double(emphasisFont.pointSize)),
    ]
    return Data(fields.joined(separator: "\u{1f}").utf8)
}
