@preconcurrency import AppKit
import CodeInsightCore
import CodeInsightReaderCore
import Foundation
import Testing
@testable import CodeInsightReaderUI

@MainActor
private func readonlyInvalidationReader(_ document: ReaderDocument) -> (ReaderTextView, NSWindow) {
    _ = NSApplication.shared
    let reader = ReaderTextView()
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 180))
    scroll.hasVerticalScroller = true
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

private func readonlyInvalidationDocument() throws -> ReaderDocument {
    let source = "fn sample(value: i32) -> i32 {\n    let other = value;\n    other + value\n}\n"
    return try DocumentLoader(source: { _ in Array(source.utf8) })
        .load(file: URL(fileURLWithPath: "/readonly-invalidation.rs")).document
}

@MainActor
private func readonlyForeground(at offset: Int, reader: ReaderTextView) -> NSColor? {
    guard let manager = reader.view.textLayoutManager, let content = manager.textContentManager else { return nil }
    var color: NSColor?
    manager.enumerateRenderingAttributes(from: content.documentRange.location, reverse: false) { _, attributes, range in
        let lower = content.offset(from: content.documentRange.location, to: range.location)
        let upper = content.offset(from: content.documentRange.location, to: range.endLocation)
        if lower <= offset, offset < upper { color = attributes[.foregroundColor] as? NSColor; return false }
        return true
    }
    return color
}

@MainActor
private func readonlyRGBA(_ color: NSColor) -> [CGFloat] {
    var result: [CGFloat] = []
    NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
        if let resolved = color.usingColorSpace(.deviceRGB) {
            result = [resolved.redComponent, resolved.greenComponent, resolved.blueComponent, resolved.alphaComponent]
        }
    }
    return result
}

@MainActor @Test(.isolatedReaderWorkCounters)
func readonlyInvalidationNativeSettingsMatrixNeverReplacesCharacters() throws {
    let document = try readonlyInvalidationDocument()
    // Exercise independent and combined font/color/wrap/gutter changes.
    for mask in 0..<16 {
        let (reader, window) = readonlyInvalidationReader(document)
        defer { window.close() }
        var settings = ReaderSettings()
        if mask & 1 != 0 { settings.theme = .dark }
        if mask & 2 != 0 { settings.fontSize += 2 }
        if mask & 4 != 0 { settings.wrapLines.toggle() }
        if mask & 8 != 0 { settings.lineNumbers.toggle() }
        let before = ReaderWorkCounters.snapshot()
        let installs = reader.projectionInstallCount
        let typography = reader.typographyAttributeUpdateCount
        let text = reader.view.string
        reader.apply(settings: settings)
        let after = ReaderWorkCounters.snapshot()
        #expect(reader.view.string == text)
        #expect(reader.projectionInstallCount == installs)
        #expect(after.projectionPlanBuildCount == before.projectionPlanBuildCount)
        #expect(after.fullTextReplacementCount == before.fullTextReplacementCount)
        #expect(reader.typographyAttributeUpdateCount - typography == (mask & 2 != 0 ? 1 : 0))
        if mask == 0 || mask == 1 {
            #expect(after.applicationFullLayoutCount == before.applicationFullLayoutCount)
            #expect(after.paragraphRecordsVisited == before.paragraphRecordsVisited)
            #expect(after.attributeUpdatedUTF16Units == before.attributeUpdatedUTF16Units)
        }
        let settled = ReaderWorkCounters.snapshot()
        reader.apply(settings: settings)
        #expect(ReaderWorkCounters.snapshot() == settled)
    }
}

@MainActor @Test
func readonlyInvalidationFontThenColorAndCombinedSettingsAgree() throws {
    let document = try readonlyInvalidationDocument()
    let (sequential, firstWindow) = readonlyInvalidationReader(document)
    let (combined, secondWindow) = readonlyInvalidationReader(document)
    defer { firstWindow.close(); secondWindow.close() }
    var settings = ReaderSettings()
    settings.fontSize = 18
    settings.codeLigatures = .disabled
    sequential.apply(settings: settings)
    let typography = sequential.typographyAttributeUpdateCount
    settings.theme = .dark
    settings.parameterReferenceAlpha = 0.4
    settings.declarationMarkerAlpha = 0.2
    sequential.apply(settings: settings)
    #expect(sequential.typographyAttributeUpdateCount == typography)
    combined.apply(settings: settings)
    #expect(combined.typographyAttributeUpdateCount == 1)
    #expect(sequential.view.string == combined.view.string)
    let offset = document.highlightSpans.first { $0.kind == .functionName }!.range.lowerBound
    let firstFont = try #require(sequential.font(atByteOffset: offset))
    let secondFont = try #require(combined.font(atByteOffset: offset))
    #expect(firstFont.fontName == secondFont.fontName)
    #expect(firstFont.pointSize == secondFont.pointSize)
    let left = try #require(readonlyForeground(at: Int(offset), reader: sequential))
    let right = try #require(readonlyForeground(at: Int(offset), reader: combined))
    #expect(readonlyRGBA(left) == readonlyRGBA(right))
}

@MainActor @Test
func readonlyInvalidationPlainTextAndValidatorRepublishCachedColors() throws {
    let bytes = Array("plain words\nmore plain words\n".utf8)
    let document = ReaderDocument(bytes: bytes, highlightSpans: [], outlineFacets: [])
    let (reader, window) = readonlyInvalidationReader(document)
    defer { window.close() }
    var settings = ReaderSettings()
    settings.theme = .dark
    reader.apply(settings: settings)
    let expected = readonlyRGBA(ReaderTheme(settings: settings).foregroundColor)
    #expect(readonlyRGBA(try #require(readonlyForeground(at: 2, reader: reader))) == expected)
    let manager = try #require(reader.view.textLayoutManager)
    let content = try #require(manager.textContentManager)
    let fragment = try #require(manager.textLayoutFragment(for: content.documentRange.location))
    let validator = try #require(manager.renderingAttributesValidator)
    validator(manager, fragment)
    let calculations = reader.renderingCoordinator.rangeCalculationCount
    let hits = reader.renderingCoordinator.rangeCacheHitCount
    manager.invalidateRenderingAttributes(for: fragment.rangeInElement)
    manager.setRenderingAttributes([.foregroundColor: NSColor.red], for: fragment.rangeInElement)
    validator(manager, fragment)
    #expect(reader.renderingCoordinator.rangeCalculationCount == calculations)
    #expect(reader.renderingCoordinator.rangeCacheHitCount > hits)
    #expect(readonlyRGBA(try #require(readonlyForeground(at: 2, reader: reader))) == expected)
}

@MainActor
private func readonlyProvider(_ reader: ReaderTextView) throws -> NSTextAttachmentViewProvider {
    let manager = try #require(reader.view.textLayoutManager)
    let content = try #require(manager.textContentManager)
    var provider: NSTextAttachmentViewProvider?
    manager.enumerateTextLayoutFragments(from: content.documentRange.location, options: [.ensuresLayout]) { fragment in
        provider = fragment.textAttachmentViewProviders.first
        return provider == nil
    }
    return try #require(provider)
}

@MainActor
private func readonlyPixels(_ view: NSView) throws -> Data {
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
        pixelsWide: Int(ceil(view.bounds.width)), pixelsHigh: Int(ceil(view.bounds.height)),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { view.draw(view.bounds) }
    return try #require(bitmap.representation(using: .png, properties: [:]))
}

@MainActor @Test
func readonlyInvalidationFoldProvidersUseLatestColorsAndTypography() throws {
    let document = try readonlyInvalidationDocument()
    let (reader, window) = readonlyInvalidationReader(document)
    defer { window.close() }
    let fold = try #require(document.foldRegions.first)
    #expect(reader.toggleFold(id: fold.id))
    reader.view.textLayoutManager?.textViewportLayoutController.layoutViewport()
    let initialProvider = try readonlyProvider(reader)
    let originalView = try #require(initialProvider.view)
    reader.apply(settings: ReaderSettings(theme: .light))
    let beforePixels = try readonlyPixels(originalView)
    let originalSize = originalView.bounds.size
    let installs = reader.projectionInstallCount
    var settings = ReaderSettings()
    settings.theme = .dark
    reader.apply(settings: settings)
    #expect(initialProvider.view === originalView)
    #expect(originalView.bounds.size == originalSize)
    let darkPixels = try readonlyPixels(originalView)
    #expect(darkPixels != beforePixels)
    let evidence = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/readonly/s4-native", isDirectory: true)
    try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
    try beforePixels.write(to: evidence.appendingPathComponent("attachment-light.png"), options: .atomic)
    try darkPixels.write(to: evidence.appendingPathComponent("attachment-dark.png"), options: .atomic)
    let content = try #require(window.contentView)
    let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
    content.cacheDisplay(in: content.bounds, to: bitmap)
    try #require(bitmap.representation(using: .png, properties: [:]))
        .write(to: evidence.appendingPathComponent("reader-dark.png"), options: .atomic)
    // Create a provider after the color transaction; its attachment must carry
    // the current appearance, independent of the old provider's construction.
    let attachment = try #require(initialProvider.textAttachment)
    let manager = try #require(reader.view.textLayoutManager)
    let location = try #require(manager.textContentManager?.documentRange.location)
    let later = try #require(attachment.viewProvider(
        for: reader.view, location: location, textContainer: reader.view.textContainer))
    later.loadView()
    let laterView = try #require(later.view)
    #expect(try readonlyPixels(laterView) == darkPixels)
    settings.fontSize = 24
    reader.apply(settings: settings)
    reader.view.textLayoutManager?.textViewportLayoutController.layoutViewport()
    let resized = try readonlyProvider(reader)
    #expect(resized.textAttachment === attachment)
    #expect(try #require(resized.view).bounds.height > originalSize.height)
    #expect(reader.projectionInstallCount == installs)
}

@MainActor @Test(.isolatedReaderWorkCounters)
func readonlyInvalidationSyntaxReusesUnchangedFoldProjection() throws {
    let highlighted = try readonlyInvalidationDocument()
    let plain = ReaderDocument(bytes: highlighted.bytes, lineTable: highlighted.lineTable,
        byteUTF16Map: highlighted.byteUTF16Map, highlightSpans: [], outlineFacets: highlighted.outlineFacets,
        foldRegions: highlighted.foldRegions)
    let (reader, window) = readonlyInvalidationReader(plain)
    defer { window.close() }
    let fold = try #require(plain.foldRegions.first)
    #expect(reader.toggleFold(id: fold.id))
    let installs = reader.projectionInstallCount
    let projected = reader.view.string
    let before = ReaderWorkCounters.snapshot()
    reader.updateSyntax(document: highlighted)
    let after = ReaderWorkCounters.snapshot()
    #expect(reader.view.string == projected)
    #expect(reader.projectionInstallCount == installs)
    #expect(after.projectionPlanBuildCount == before.projectionPlanBuildCount)
    #expect(after.fullTextReplacementCount == before.fullTextReplacementCount)

    // A reused FoldID with a different source body is a different projection.
    let changedFold = FoldRegion(id: fold.id, kind: fold.kind, headerRange: fold.headerRange,
        bodyRange: ByteRange(lowerBound: fold.bodyRange.lowerBound + 1, upperBound: fold.bodyRange.upperBound),
        outlineDepth: fold.outlineDepth, summary: fold.summary)
    let changed = ReaderDocument(bytes: highlighted.bytes, lineTable: highlighted.lineTable,
        byteUTF16Map: highlighted.byteUTF16Map, highlightSpans: highlighted.highlightSpans,
        outlineFacets: highlighted.outlineFacets, foldRegions: [changedFold])
    reader.updateSyntax(document: changed)
    #expect(reader.projectionInstallCount == installs + 1)
    #expect(reader.view.string != projected)
}

@MainActor @Test(.readerFontEnvironment)
func readonlyInvalidationFontEnvironmentRefreshesAttributesWithoutCharacters() throws {
    let document = try readonlyInvalidationDocument()
    let (reader, window) = readonlyInvalidationReader(document)
    defer { window.close() }
    let installs = reader.projectionInstallCount
    let updates = reader.typographyAttributeUpdateCount
    ReaderFontResolver.shared.refresh()
    reader.apply(settings: ReaderSettings())
    #expect(reader.typographyAttributeUpdateCount == updates + 1)
    #expect(reader.projectionInstallCount == installs)
}

@MainActor @Test(.isolatedReaderWorkCounters)
func readonlyInvalidationAutomaticAppearanceRepaintsWithoutTextOrLayoutWork() throws {
    let document = try readonlyInvalidationDocument()
    let (reader, window) = readonlyInvalidationReader(document)
    defer { window.close() }
    #expect(reader.toggleFold(id: try #require(document.foldRegions.first).id))
    reader.view.textLayoutManager?.textViewportLayoutController.layoutViewport()
    func pixels() throws -> Data {
        let bitmap = try #require(reader.view.bitmapImageRepForCachingDisplay(in: reader.view.bounds))
        reader.view.cacheDisplay(in: reader.view.bounds, to: bitmap)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
    window.appearance = NSAppearance(named: .aqua)
    let light = try pixels()
    let text = reader.view.string
    let before = ReaderWorkCounters.snapshot()
    window.appearance = NSAppearance(named: .darkAqua)
    let dark = try pixels()
    let after = ReaderWorkCounters.snapshot()
    #expect(light != dark)
    #expect(reader.view.string == text)
    #expect(after.fullTextReplacementCount == before.fullTextReplacementCount)
    #expect(after.projectionPlanBuildCount == before.projectionPlanBuildCount)
    #expect(after.applicationFullLayoutCount == before.applicationFullLayoutCount)
}

@MainActor @Test
func readonlyInvalidationReorderedFoldMetadataPreservesTheVisibleProjection() throws {
    let sample = try readonlyInvalidationDocument()
    let bytes = sample.bytes + sample.bytes
    let document = try DocumentLoader(source: { _ in bytes })
        .load(file: URL(fileURLWithPath: "/reordered.rs")).document
    let (reader, window) = readonlyInvalidationReader(document)
    defer { window.close() }
    #expect(reader.setReadingHeightLevel(.overview))
    try #require(reader.foldPerformanceCounts.rendered >= 2)
    let text = reader.view.string
    let installs = reader.projectionInstallCount
    let reordered = ReaderDocument(bytes: bytes, lineTable: document.lineTable,
        byteUTF16Map: document.byteUTF16Map, highlightSpans: document.highlightSpans,
        outlineFacets: document.outlineFacets, foldRegions: Array(document.foldRegions.reversed()))
    reader.updateSyntax(document: reordered)
    #expect(reader.view.string == text)
    #expect(reader.projectionInstallCount == installs)
}

private func readonlyScrollDocument() throws -> ReaderDocument {
    let source = (0..<400).map { "fn item\($0)(value: i32) -> i32 {\n    value + \($0)\n}\n" }.joined()
    return try DocumentLoader(source: { _ in Array(source.utf8) })
        .load(file: URL(fileURLWithPath: "/readonly-scroll.rs")).document
}

@MainActor
private func readonlyScroll(_ reader: ReaderTextView, window: NSWindow, to y: CGFloat) throws {
    let clipView = try #require(reader.view.enclosingScrollView?.contentView)
    clipView.scroll(to: NSPoint(x: 0, y: y))
    window.contentView?.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
}

@MainActor @Test(.isolatedReaderWorkCounters)
func readonlyScrollRepublishesOnlyNewlyVisibleFragments() throws {
    let document = try readonlyScrollDocument()
    let (reader, window) = readonlyInvalidationReader(document)
    defer { window.close() }
    try readonlyScroll(reader, window: window, to: 600)
    let manager = try #require(reader.view.textLayoutManager)
    let lineHeight = try #require(manager.textLayoutFragment(for: manager.documentRange.location))
        .layoutFragmentFrame.height
    let before = ReaderWorkCounters.snapshot().renderingAttributeUpdatedUTF16Units
    let steps = 20
    for step in 1...steps {
        try readonlyScroll(reader, window: window, to: 600 + CGFloat(step) * lineHeight)
    }
    // A one-line scroll brings in about one short line; republishing the
    // whole viewport on every scroll is the regression this guards against.
    let perStep = (ReaderWorkCounters.snapshot().renderingAttributeUpdatedUTF16Units - before) / steps
    #expect(perStep < 120, "republished \(perStep) UTF-16 units per one-line scroll")
}

@MainActor @Test
func readonlyScrollStylesFragmentsTextKitValidatedOutsideTheViewport() throws {
    let document = try readonlyScrollDocument()
    let (reader, window) = readonlyInvalidationReader(document)
    defer { window.close() }
    let manager = try #require(reader.view.textLayoutManager)
    let content = try #require(manager.textContentManager)
    let targetLine = 901
    let lineStart = document.lineTable.lineStarts[targetLine - 1]
    let target = try #require(content.location(
        content.documentRange.location,
        offsetBy: Int(lineStart)
    ))
    manager.ensureLayout(for: NSTextRange(location: target))
    let fragment = try #require(manager.textLayoutFragment(for: target))
    #expect(fragment.layoutFragmentFrame.minY > 10_000)
    // TextKit may validate far-away fragments during layout. The coordinator
    // skips them there, and TextKit will not ask again when they scroll in.
    let validator = try #require(manager.renderingAttributesValidator)
    validator(manager, fragment)
    try readonlyScroll(reader, window: window, to: fragment.layoutFragmentFrame.minY)
    let span = try #require(document.highlightSpans.first {
        $0.kind == .functionName && $0.range.lowerBound >= lineStart
    })
    #expect(document.lineTable.lineColumn(at: span.range.lowerBound).map { Int($0.line) } == targetLine)
    let color = try #require(readonlyForeground(at: Int(span.range.lowerBound), reader: reader))
    let expected = ReaderTheme(settings: ReaderSettings()).color(for: .functionName)
    #expect(readonlyRGBA(color) == readonlyRGBA(expected))
}

@MainActor
private func readonlyBackground(at offset: Int, reader: ReaderTextView) -> NSColor? {
    guard let manager = reader.view.textLayoutManager, let content = manager.textContentManager else { return nil }
    var color: NSColor?
    manager.enumerateRenderingAttributes(from: content.documentRange.location, reverse: false) { _, attributes, range in
        let lower = content.offset(from: content.documentRange.location, to: range.location)
        let upper = content.offset(from: content.documentRange.location, to: range.endLocation)
        if lower <= offset, offset < upper { color = attributes[.backgroundColor] as? NSColor; return false }
        return true
    }
    return color
}

/// Regression (2026-10-04 native acceptance 1.4): a highlight change made
/// from a menu moves no selection; the fills changed but lines already on
/// screen kept their old paint until they scrolled away. TextKit 2 draws
/// fragments in subviews, so every one of them must be asked to redraw.
@MainActor @Test
func highlightChangesClearFillsAndRedrawEveryRenderedFragment() async throws {
    let document = try readonlyInvalidationDocument()
    let (reader, window) = readonlyInvalidationReader(document)
    defer { window.close() }
    await reader.waitForIdentifierPreparation()
    let other = (String(decoding: document.bytes, as: UTF8.self) as NSString).range(of: "other").location
    func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }

    // Fragment views are layer-backed; the pending redraw lives on the layer.
    func undrawn() -> [NSView] { descendants(reader.view).filter { $0.layer?.needsDisplay() != true } }
    window.displayIfNeeded()
    #expect(!descendants(reader.view).isEmpty, "TextKit renders fragments in subviews")

    reader.setHighlightedNames(["other": 1])
    #expect(readonlyBackground(at: other, reader: reader) != nil)
    #expect(undrawn().isEmpty, "an added fill redraws every rendered fragment")
    window.displayIfNeeded()

    reader.setHighlightedNames([:])
    #expect(readonlyBackground(at: other, reader: reader) == nil, "a cleared name keeps no fill")
    #expect(undrawn().isEmpty, "a removed fill redraws every rendered fragment")
}
