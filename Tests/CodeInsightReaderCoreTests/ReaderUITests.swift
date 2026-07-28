import AppKit
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
        #expect(renderedBackgroundColors(
            in: reader,
            intersecting: range
        ).contains { colorsEqual($0, theme.occurrenceColor) })
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
    #expect(reader.activate(atByteOffset: paramByteOffset) == 3)
    #expect(!renderedBackgroundColors(
        in: reader,
        intersecting: paramRange
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
