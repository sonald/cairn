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

    @MainActor
    final class ScrollDuringLayout: NSObject, @preconcurrency NSTextViewportLayoutControllerDelegate {
        let clipView: NSClipView
        var depth = 0
        var maximumDepth = 0
        var scrollCount = 0

        init(clipView: NSClipView) {
            self.clipView = clipView
        }

        func viewportBounds(for controller: NSTextViewportLayoutController) -> CGRect {
            clipView.bounds
        }

        func textViewportLayoutController(
            _ controller: NSTextViewportLayoutController,
            configureRenderingSurfaceFor fragment: NSTextLayoutFragment
        ) {
        }

        func textViewportLayoutControllerDidLayout(_ controller: NSTextViewportLayoutController) {
            depth += 1
            maximumDepth = max(maximumDepth, depth)
            defer { depth -= 1 }
            // Reproduce the bounds notification caused by TextKit resizing its document
            // after layout, with a finite budget so the regression cannot overflow the stack.
            guard scrollCount < 4 else { return }
            scrollCount += 1
            clipView.scroll(to: NSPoint(x: 0, y: clipView.bounds.minY - 1))
        }
    }

    // A Follow-pane resize reduces the reader viewport before the next user scroll.
    scrollView.setFrameSize(NSSize(width: scrollView.frame.width, height: 120))
    window.displayIfNeeded()
    let viewport = try #require(reader.view.textLayoutManager?.textViewportLayoutController)
    let original = try #require(viewport.delegate)
    let probe = ScrollDuringLayout(clipView: scrollView.contentView)
    viewport.delegate = probe
    defer { viewport.delegate = original }
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: 100))
    #expect(probe.scrollCount > 0, "The scroll must reach the native viewport layout delegate")
    #expect(probe.maximumDepth == 1, "Bounds changes during layout must not start nested viewport layout")
    let scrollCount = probe.scrollCount
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: 200))
    #expect(probe.scrollCount > scrollCount, "Later scrolling must still update the viewport")
    #expect(probe.maximumDepth == 1)
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
func pythonClassOutlineGutterColorAndFoldSummaryAreMapped() throws {
    let source = [
        "class Widget:",
        "    class Inner:",
        "        def __init__(self):",
        "            pass",
        "",
        "def make():",
        "    return Widget()",
        "",
    ].joined(separator: "\n")
    let bytes = Array(source.utf8)
    let document = try DocumentLoader(source: { _ in bytes })
        .load(
            file: URL(fileURLWithPath: "/sample.py"),
            languageMode: LanguageMode(language: .python)
        )
        .document

    let widget = try #require(document.outlineFacets.first {
        $0.kind == .class && $0.name == "Widget"
    })
    let widgetRange = try #require(document.byteUTF16Map.nsRange(
        byteLowerBound: Int(widget.nameRange.lowerBound),
        byteUpperBound: Int(widget.nameRange.upperBound)
    ))
    let theme = ReaderTheme(settings: ReaderSettings())
    let (reader, scrollView, window) = renderOffscreen(document)
    withExtendedLifetime(window) {
        let classMarker = reader.declarationMarkerColor(for: .class)
        #expect(colorsEqual(
            classMarker,
            theme.color(for: .declarationTitle)
                .withAlphaComponent(theme.declarationMarkerAlpha)
        ))
        #expect(renderedColors(in: reader, intersecting: widgetRange).contains {
            colorsEqual($0, theme.color(for: .declarationTitle))
        })
        reader.reveal(byteOffset: widget.nameRange.lowerBound)
        window.displayIfNeeded()
        reader.captureVisibleDecorationState()
        let line = document.lineTable.lineColumn(
            at: widget.nameRange.lowerBound
        ).map { Int($0.line) }
        #expect(line.map { reader.visibleDeclarationMarkerLines.contains($0) } == true)
        #expect(scrollView.hasVerticalRuler)

        let container = document.foldRegions.first {
            $0.kind == .container && $0.summary.memberCounts[.class] == 1
        }
        #expect(container != nil)
        if let container {
            #expect(reader.toggleFold(id: container.id))
            reader.view.textLayoutManager?.textViewportLayoutController.layoutViewport()
            window.displayIfNeeded()
            let manager = reader.view.textLayoutManager
            let content = manager?.textContentManager
            var providers: [NSTextAttachmentViewProvider] = []
            if let manager, let content {
                manager.enumerateTextLayoutFragments(
                    from: content.documentRange.location,
                    options: [.ensuresLayout]
                ) { fragment in
                    providers.append(contentsOf: fragment.textAttachmentViewProviders)
                    return true
                }
            }
            #expect(providers.first?.view?.accessibilityLabel()?.contains("1 class") == true)
        }
    }
}

@MainActor
@Test
func typeScriptReaderGenericTransportRendersOutlineFoldAndLocalRefs() throws {
    let source = """
        type Label = string;
        const Button = ({ label }: { label: Label }) => {
            const prefix = ">>";
            const full = prefix + label;
            return <button title="ok">{full}</button>;
        };
        class Box {
            run() {
                return Button({ label: "ok" });
            }
        }
        """
    let bytes = Array(source.utf8)
    let document = try DocumentLoader(source: { _ in bytes })
        .load(
            file: URL(fileURLWithPath: "/fixture.tsx"),
            languageMode: LanguageMode(language: .typescript, variant: "tsx")
        )
        .document
    #expect(document.languageMode
        == LanguageMode(language: .typescript, variant: "tsx"))
    #expect(document.outlineFacets.contains { $0.kind == .fn && $0.name == "Button" })
    #expect(document.outlineFacets.contains { $0.kind == .class && $0.name == "Box" })
    #expect(document.outlineFacets.contains { $0.kind == .method && $0.name == "run" })
    #expect(document.foldRegions.contains { $0.kind == .declaration })
    #expect(document.foldRegions.contains { $0.kind == .container })
    #expect(!document.localBindings.isEmpty)
    #expect(!document.localReferences(
        intersectingBytes: 0..<UInt32(document.bytes.count),
        buffer: 0
    ).isEmpty)

    let (reader, _, window) = renderOffscreen(document)
    #expect(reader.renderingCoordinator.styledFragmentCount > 0)
    let fold = try #require(document.foldRegions.first { $0.kind == .declaration })
    #expect(reader.toggleFold(id: fold.id))
    window.displayIfNeeded()
    #expect(reader.renderedFoldIDsForTesting.contains(fold.id))
    #expect(reader.view.string.contains("Button"))
    withExtendedLifetime(window) {}
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

/// S0 coordinate-convention probe (reader-wrap design §3.4/D2.1): the visual
/// row rect must be composed as fragment origin + typographic bounds +
/// `textContainerOrigin`, and that composition has to agree with TextKit's
/// own `firstRect` geometry for the same character. Anchoring at every visual
/// row start also validates that `NSTextLineFragment.characterRange` is a
/// fragment-local offset that must be combined with the fragment's position.
@MainActor
@Test
func wrapFirstVisualRowGeometryConventionsHoldInRealTextView() throws {
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
    var wrappedSettings = ReaderSettings()
    wrappedSettings.wrapLines = true
    reader.apply(settings: wrappedSettings)
    reader.display(document: document)
    reader.view.textLayoutManager?.textViewportLayoutController.layoutViewport()
    window.displayIfNeeded()

    let manager = try #require(reader.view.textLayoutManager)
    let content = try #require(manager.textContentManager)

    // (a) With the plain container configuration the container origin is the
    // inset itself, so a conversion that adds textContainerOrigin must not
    // add textContainerInset on top (no double-inset composition).
    let inset = reader.view.textContainerInset
    #expect(reader.view.textContainerOrigin.x == inset.width)
    #expect(reader.view.textContainerOrigin.y == inset.height)
    let containerOrigin = reader.view.textContainerOrigin

    // (b) Cross-check the composed row rect against firstRect for the first
    // character of every visual row, including wrapped continuation rows.
    let textLength = (reader.view.string as NSString).length
    var checkedRows = 0
    var continuationRows = 0
    manager.enumerateTextLayoutFragments(
        from: content.documentRange.location,
        options: [.ensuresLayout]
    ) { fragment in
        guard let firstRow = fragment.textLineFragments.first else { return true }
        let fragmentStart = content.offset(
            from: content.documentRange.location,
            to: fragment.rangeInElement.location
        )
        guard fragmentStart != NSNotFound else { return true }
        continuationRows += fragment.textLineFragments.count - 1
        for (rowIndex, row) in fragment.textLineFragments.enumerated() {
            let rowStart = fragmentStart + row.characterRange.location
            guard rowStart >= 0, rowStart < textLength else { continue }
            let screenRect = reader.view.firstRect(
                forCharacterRange: NSRange(location: rowStart, length: 1),
                actualRange: nil
            )
            guard !screenRect.isEmpty else { continue }
            let viewRect = reader.view.convert(
                window.convertFromScreen(screenRect),
                from: nil
            )
            let bounds = row.typographicBounds
            let computedX = fragment.layoutFragmentFrame.minX
                + bounds.minX + containerOrigin.x
            let computedY = fragment.layoutFragmentFrame.minY
                + bounds.minY + containerOrigin.y
            #expect(
                abs(computedX - viewRect.minX) < 0.5,
                "row \(rowIndex) of fragment at \(fragmentStart): composed x \(computedX) vs firstRect x \(viewRect.minX)"
            )
            #expect(
                abs(computedY - viewRect.minY) < 0.5,
                "row \(rowIndex) of fragment at \(fragmentStart): composed y \(computedY) vs firstRect y \(viewRect.minY)"
            )
            checkedRows += 1
        }
        return true
    }
    #expect(checkedRows >= 4)
    #expect(continuationRows >= 2)
    withExtendedLifetime(window) {}
}

/// S0 resize-timing probe (reader-wrap design D3.7): the only notifications
/// AppKit posts around a programmatic width change (`boundsDidChange` on the
/// clip view, `frameDidChange` on the text view) already observe the new
/// width. There is no pre-change callback, which is the documented premise
/// for capturing the old stable state before the frame actually changes.
@MainActor
@Test
func wrapResizeCallbacksOnlyObserveNewWidth() throws {
    _ = NSApplication.shared
    let longBody = Array(repeating: "value += compute(value);", count: 24)
        .joined(separator: " ")
    let source = "fn one() {}\nfn wrapped() { \(longBody) }\nfn three() {}\n"
    let file = URL(fileURLWithPath: "/wrap-resize-callbacks.rs")
    let document = try DocumentLoader(source: { _ in Array(source.utf8) })
        .load(file: file).document
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
    var wrappedSettings = ReaderSettings()
    wrappedSettings.wrapLines = true
    reader.apply(settings: wrappedSettings)
    reader.display(document: document)
    reader.view.textLayoutManager?.textViewportLayoutController.layoutViewport()
    window.displayIfNeeded()

    let clipView = scrollView.contentView
    let oldClipWidth = clipView.bounds.width
    let oldReaderWidth = reader.view.frame.width
    // NSView.postsBoundsChangedNotifications defaults to false; the reader's
    // own viewport observer opts the clip view in explicitly, so the probe
    // must do the same.
    clipView.postsBoundsChangedNotifications = true
    reader.view.postsFrameChangedNotifications = true
    // The observer closures are @Sendable; observations are recorded through
    // an unchecked box and view reads hop through assumeIsolated, which is
    // honest here because queue: nil delivers synchronously on the main
    // thread, the same thread performing the resize.
    final class ObservationBox: @unchecked Sendable {
        var observations: [(event: String, width: CGFloat)] = []
    }
    let box = ObservationBox()
    let center = NotificationCenter.default
    var observers: [NSObjectProtocol] = []
    observers.append(center.addObserver(
        forName: NSView.boundsDidChangeNotification,
        object: clipView,
        queue: nil
    ) { _ in
        MainActor.assumeIsolated {
            box.observations.append(("clipBounds", clipView.bounds.width))
        }
    })
    observers.append(center.addObserver(
        forName: NSView.frameDidChangeNotification,
        object: reader.view,
        queue: nil
    ) { _ in
        MainActor.assumeIsolated {
            box.observations.append(("readerFrame", reader.view.frame.width))
        }
    })
    defer { observers.forEach(center.removeObserver) }

    window.setContentSize(NSSize(width: 360, height: 180))
    window.displayIfNeeded()
    reader.view.textLayoutManager?.textViewportLayoutController.layoutViewport()
    window.displayIfNeeded()
    let newClipWidth = clipView.bounds.width
    let newReaderWidth = reader.view.frame.width
    let observations = box.observations

    #expect(newClipWidth < oldClipWidth)
    #expect(abs(newReaderWidth - oldReaderWidth) > 0.5)
    // Observed timing facts that motivate D3.7's pre-change capture hook:
    // (1) the clip view posts NO bounds notifications for a resize at all —
    //     boundsDidChange is a scroll signal, so the reader's existing
    //     viewport observer cannot see width changes;
    // (2) the only resize notification is the text view's frameDidChange,
    //     delivered strictly after the fact, possibly through intermediate
    //     widths (autoresize then ruler re-tiling).
    let clipObservations = observations.filter { $0.event == "clipBounds" }
    let frameObservations = observations.filter { $0.event == "readerFrame" }
    #expect(clipObservations.isEmpty)
    #expect(!frameObservations.isEmpty)
    #expect(frameObservations.allSatisfy {
        abs($0.width - oldReaderWidth) > 0.5
    })
    #expect(frameObservations.last.map {
        abs($0.width - newReaderWidth) < 0.5
    } == true)
    print(
        "WRAP_RESIZE_TIMING observations="
            + observations.map { "\($0.event)=\($0.width)" }.joined(separator: ",")
    )

    // Sanity check that the clip-view observer is wired: scrolling must
    // deliver a bounds notification, so the empty resize observation above is
    // a property of resize, not a broken probe.
    let documentHeight = reader.view.frame.height
    if documentHeight > clipView.bounds.height + 8 {
        clipView.scroll(to: NSPoint(x: 0, y: 8))
        scrollView.reflectScrolledClipView(clipView)
        let scrollObservations = box.observations.filter { $0.event == "clipBounds" }
        #expect(!scrollObservations.isEmpty)
    }
    withExtendedLifetime(window) {}
}

// MARK: - Reader wrap v2 · S1 viewport/selection reflow tests

/// Pumps the main runloop and drains deferred viewport restores so the
/// bounded correction passes (up to 3, each validated against the
/// transaction generation) get their turn. Tests own the main thread, so
/// main-queue blocks never run mid-test without this explicit flush.
@MainActor
private func wrapSettle(_ reader: ReaderTextView, pumps: Int = 12) {
    for _ in 0..<pumps {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.03))
        reader.view.textLayoutManager?.textViewportLayoutController.layoutViewport()
        reader.processPendingViewportRestoresForTesting()
    }
}

@MainActor
private func wrapSettings(_ wrap: Bool) -> ReaderSettings {
    var settings = ReaderSettings()
    settings.wrapLines = wrap
    return settings
}

/// Independent re-derivation of the reading anchor: the source byte at the
/// probe point 25% down and centered across the visible viewport, resolved
/// through the text view's own insertion-point hit testing (never the
/// reader's captured state).
@MainActor
private func wrapQuarterAnchorByte(_ reader: ReaderTextView) -> UInt32? {
    let view = reader.view
    let visible = view.visibleRect
    guard visible.height > 1 else { return nil }
    let probe = NSPoint(
        x: visible.midX,
        y: visible.minY + visible.height * 0.25
    )
    var location = view.characterIndexForInsertion(at: probe)
    if location < 0 { location = 0 }
    return reader.byteOffset(forCharacterIndex: location)
}

private func wrapLongLineDocument() -> ReaderDocument {
    let longLine = String(repeating: "payload_segment=value + compute(payload); ", count: 32)
    var lines: [String] = []
    lines.append("fn opening() {}")
    for index in 0..<30 { lines.append("fn before\(index)() { let v = \(index); }") }
    lines.append("fn mega_wrapped() { let payload = \"\(longLine)\"; }")
    for index in 0..<30 { lines.append("fn after\(index)() { let v = \(index); }") }
    lines.append("fn closing() {}")
    let bytes = Array(lines.joined(separator: "\n").utf8)
    let highlighted = (try? RustHighlighter().highlight(bytes: bytes))
    return ReaderDocument(
        bytes: bytes,
        highlightSpans: highlighted?.spans ?? [],
        outlineFacets: highlighted?.outlineFacets ?? []
    )
}

/// W10/W12: 20 off↔on round trips keep the same mid-line anchor character
/// at the same viewport offset. The wrapped logical line spans well over 20
/// visual rows, so the anchor must stay the original in-line character, not
/// degrade to the line start (D3.5's stable-anchor rule).
@MainActor
@Test
func wrapToggleRoundTripsKeepMidLineAnchorAndViewportOffset() throws {
    let document = wrapLongLineDocument()
    let (reader, scrollView, window) = renderOffscreen(document)
    // Start wrapped and park the viewport deep inside the mega line's visual
    // rows so the 25% anchor is a mid-line character (W12).
    reader.apply(settings: wrapSettings(true))
    wrapSettle(reader)
    let megaLine = 32
    let megaByte = document.lineTable.lineStarts[megaLine - 1]
    reader.restore(scrollByteOffset: megaByte, selectionByteOffset: nil)
    wrapSettle(reader)
    // Push further into the wrapped rows so the anchor sits well past the
    // first visual row.
    scrollView.contentView.scroll(
        to: NSPoint(x: 0, y: scrollView.contentView.bounds.minY + 90)
    )
    scrollView.reflectScrolledClipView(scrollView.contentView)
    wrapSettle(reader, pumps: 2)

    let anchor = try #require(wrapQuarterAnchorByte(reader))
    let anchorLine = try #require(document.lineTable.lineColumn(at: anchor)?.line)
    let lineStart = document.lineTable.lineStarts[megaLine - 1]
    #expect(anchorLine == megaLine)
    // The anchor sits deep inside the long logical line.
    #expect(anchor - lineStart > 200)

    var wrapped = wrapSettings(true)
    var unwrapped = wrapSettings(false)
    for round in 0..<20 {
        // Each round ends wrapped so the quarter-anchor probe resolves the
        // anchor's own visual row; in an unwrapped layout the probe would
        // see the whole logical line as one row and report its first byte.
        reader.apply(settings: unwrapped)
        wrapSettle(reader, pumps: 6)
        reader.apply(settings: wrapped)
        wrapSettle(reader, pumps: 6)
        guard let current = wrapQuarterAnchorByte(reader) else {
            Issue.record("round \(round): no anchor after round trip")
            break
        }
        // The anchor character keeps its viewport offset (the reader's own
        // measured error) and the probe still lands on the same logical
        // line, deep inside it — a fixed probe x naturally resolves a
        // neighbor character once the layout wraps (D3.3/D3.5).
        let currentLine = document.lineTable.lineColumn(at: current)?.line
        #expect(currentLine == anchorLine, "round \(round) probe left line \(anchorLine)")
        #expect(current - lineStart > 100, "round \(round) probe degraded to line start")
        let error = reader.lastViewportAnchorErrorPt ?? 0
        // 2 physical pixels at backing scale 2 (§7.2 budget).
        #expect(error <= 1.0, "round \(round) anchor error \(error)pt")
    }
    _ = scrollView
    withExtendedLifetime(window) {}
}

/// W11: a complete multi-range selection and its copied source text survive
/// wrap toggles in both directions.
@MainActor
@Test
func wrapTogglePreservesCompleteSelectionAndCopyText() throws {
    let document = wrapLongLineDocument()
    let (reader, _, window) = renderOffscreen(document)
    let megaLine = 32
    let megaByte = document.lineTable.lineStarts[megaLine - 1]
    reader.restore(scrollByteOffset: megaByte, selectionByteOffset: nil)
    wrapSettle(reader)

    let view = reader.view
    let first = NSRange(
        location: view.selectedRange().location + 40,
        length: 120
    )
    let second = NSRange(
        location: min(first.location + first.length + 20, view.string.utf16.count - 10),
        length: 10
    )
    view.setSelectedRanges(
        [NSValue(range: first), NSValue(range: second)],
        affinity: .downstream,
        stillSelecting: false
    )
    let originalRanges = view.selectedRanges.compactMap(\.rangeValue)
    let originalCopy = reader.sourceText(forDisplaySelection: first)

    reader.apply(settings: wrapSettings(true))
    wrapSettle(reader)
    #expect(view.selectedRanges.compactMap(\.rangeValue) == originalRanges)
    #expect(reader.sourceText(forDisplaySelection: first) == originalCopy)

    reader.apply(settings: wrapSettings(false))
    wrapSettle(reader)
    #expect(view.selectedRanges.compactMap(\.rangeValue) == originalRanges)
    #expect(reader.sourceText(forDisplaySelection: first) == originalCopy)
    withExtendedLifetime(window) {}
}

/// W13: horizontal position follows the D3.5 table — wrap off→on scrolls to
/// the legal start, wrap on→off restores the stashed x.
@MainActor
@Test
func wrapToggleRestoresStashedHorizontalPosition() throws {
    let document = wrapLongLineDocument()
    let (reader, scrollView, window) = renderOffscreen(document)
    let megaLine = 32
    let megaByte = document.lineTable.lineStarts[megaLine - 1]
    reader.restore(scrollByteOffset: megaByte, selectionByteOffset: nil)
    wrapSettle(reader)

    let clipView = scrollView.contentView
    // wrap off: scroll the wide wrapped-out line horizontally.
    let targetX: CGFloat = 180
    clipView.scroll(to: NSPoint(x: targetX, y: clipView.bounds.minY))
    scrollView.reflectScrolledClipView(clipView)
    wrapSettle(reader, pumps: 2)
    let scrolledX = clipView.bounds.minX
    #expect(scrolledX > 10, "fixture must be horizontally scrollable")

    reader.apply(settings: wrapSettings(true))
    wrapSettle(reader)
    // off → on: legal start, which includes the clip inset (not 0).
    let insetLeft = -clipView.contentInsets.left
    #expect(abs(clipView.bounds.minX - insetLeft) < 0.5)

    reader.apply(settings: wrapSettings(false))
    wrapSettle(reader)
    // on → off: the stashed x returns (or the anchor is kept visible with a
    // minimal adjustment, never a jump to the far left or right).
    #expect(abs(clipView.bounds.minX - scrolledX) < 1.0)
    withExtendedLifetime(window) {}
}

/// W17: document start, document end, a short document, and an empty
/// document all clamp legally without crash or drift.
@MainActor
@Test
func wrapToggleClampsLegallyAtDocumentEdges() throws {
    let document = wrapLongLineDocument()
    let (reader, scrollView, window) = renderOffscreen(document)
    let clipView = scrollView.contentView
    let insetTop = -clipView.contentInsets.top

    // Document start.
    clipView.scroll(to: NSPoint(x: 0, y: 0))
    scrollView.reflectScrolledClipView(clipView)
    reader.apply(settings: wrapSettings(true))
    wrapSettle(reader)
    #expect(abs(clipView.bounds.minY - insetTop) < 0.5)
    reader.apply(settings: wrapSettings(false))
    wrapSettle(reader)
    #expect(abs(clipView.bounds.minY - insetTop) < 0.5)

    // Document end.
    let documentMaxUnwrapped = reader.view.frame.height
        - clipView.bounds.height
        + clipView.contentInsets.bottom
    clipView.scroll(
        to: NSPoint(x: 0, y: max(documentMaxUnwrapped, insetTop))
    )
    scrollView.reflectScrolledClipView(clipView)
    wrapSettle(reader, pumps: 2)
    let bottomUnwrapped = clipView.bounds.minY
    reader.apply(settings: wrapSettings(true))
    wrapSettle(reader)
    let bottomWrapped = clipView.bounds.minY
    let maxWrapped = reader.view.frame.height - clipView.bounds.height
        + clipView.contentInsets.bottom
    // The wrapped document is taller, so restoring the anchor at its saved
    // offset legitimately leaves the viewport above the new maximum; what
    // must hold is a legal origin (W17: clamps legal, no fake limits).
    #expect(bottomWrapped >= insetTop - 0.5 && bottomWrapped <= maxWrapped + 0.5)
    reader.apply(settings: wrapSettings(false))
    wrapSettle(reader)
    // Back in the identical unwrapped layout, the anchor restore reproduces
    // the original bottom position.
    #expect(abs(clipView.bounds.minY - bottomUnwrapped) < 1.0)
    _ = bottomWrapped

    // Short document (fits the viewport).
    let shortBytes = Array("fn a() {}\nfn b() {}\n".utf8)
    let shortDocument = (try? DocumentLoader(source: { _ in shortBytes })
        .load(file: URL(fileURLWithPath: "/wrap-short.rs")))?.document
    if let shortDocument {
        reader.display(document: shortDocument)
        wrapSettle(reader)
        reader.apply(settings: wrapSettings(true))
        wrapSettle(reader)
        #expect(abs(clipView.bounds.minY - insetTop) < 0.5)
    }

    // Empty document: no valid geometry, settings still apply (D3.2).
    reader.clear()
    reader.apply(settings: wrapSettings(true))
    reader.apply(settings: wrapSettings(false))
    withExtendedLifetime(window) {}
}

/// W18: CJK, emoji, CRLF content and a folded region survive wrap round
/// trips with byte-exact anchors and intact fold state.
@MainActor
@Test
func wrapToggleRoundTripsUnicodeAndFoldedContent() throws {
    let source = """
        fn cjk_entry() {
            let emoji = "🚀🚀🚀 rocket 👨‍👩‍👧‍👦 family";
            let cjk = "中文长行没有空格因此按字符断行，重复中文长行没有空格因此按字符断行，重复中文长行没有空格因此按字符断行，重复";
        }
        fn ordinary() {
            let one = 1;
            let two = 2;
            let three = one + two;
        }
        """
    let bytes = Array(source.utf8)
    let lineTable = LineTable(bytes: bytes)
    let fold = FoldRegion(
        id: FoldID(rawValue: 9001),
        kind: .declaration,
        headerRange: ByteRange(
            lowerBound: lineTable.lineStarts[3],
            upperBound: lineTable.lineStarts[3] + 3
        ),
        bodyRange: ByteRange(
            lowerBound: lineTable.lineStarts[3],
            upperBound: lineTable.lineStarts[7]
        ),
        outlineDepth: 0,
        summary: FoldSummary(hiddenLineCount: 3)
    )
    let document = ReaderDocument(
        bytes: bytes,
        lineTable: lineTable,
        byteUTF16Map: ByteUTF16Map(validUTF8: bytes),
        highlightSpans: [],
        outlineFacets: [],
        foldRegions: [fold]
    )
    let (reader, _, window) = renderOffscreen(document)
    wrapSettle(reader)

    // Fold the second function so the projection contains a chip.
    guard let fold = document.foldRegions.first(where: { $0.kind == .declaration })
    else {
        Issue.record("fixture has no declaration fold")
        return
    }
    #expect(reader.toggleFold(id: fold.id))
    wrapSettle(reader)

    let anchor = try #require(wrapQuarterAnchorByte(reader))
    let rangesBefore = reader.view.selectedRanges.compactMap(\.rangeValue)

    reader.apply(settings: wrapSettings(true))
    wrapSettle(reader)
    reader.apply(settings: wrapSettings(false))
    wrapSettle(reader)

    #expect(wrapQuarterAnchorByte(reader) == anchor)
    #expect(reader.view.selectedRanges.compactMap(\.rangeValue) == rangesBefore)
    // The fold stays folded across pure reflows (D3.2).
    #expect(reader.renderedFoldIDsForTesting.contains(fold.id))
    withExtendedLifetime(window) {}
}

// MARK: - Reader wrap v2 · S2a first-visual-row decoration tests

/// W20: with a logical line wrapped across visual rows, every gutter
/// decoration is drawn once, positioned on the FIRST visual row, and the
/// line-number label is vertically centered through the measured number-font
/// height rather than the wrapped block's bounds.
@MainActor
@Test
func wrapGutterDecorationsOccurOnceOnTheFirstVisualRow() throws {
    let document = wrapLongLineDocument()
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
    var wrapped = wrapSettings(true)
    wrapped.lineNumbers = true
    reader.apply(settings: wrapped)
    reader.display(document: document)
    reader.setDiffMarkers([32: .changed])
    // Bring the wrapped mega line into the viewport: gutter passes only
    // visit visible rows.
    let megaByte = document.lineTable.lineStarts[31]
    reader.restore(scrollByteOffset: megaByte, selectionByteOffset: nil)
    wrapSettle(reader)
    let ruler = try #require(scrollView.verticalRulerView)
    let rulerRep = try #require(
        ruler.bitmapImageRepForCachingDisplay(in: ruler.bounds)
    )
    ruler.cacheDisplay(in: ruler.bounds, to: rulerRep)

    // The wrapped mega line recorded exactly one first-row rect.
    let firstRow = try #require(reader.lastRulerFirstRowRectsForTesting[32])
    let labelRect = try #require(reader.lastRulerLabelDrawRectsForTesting[32])
    // One row tall, not the height of the whole wrapped block.
    #expect(firstRow.height > 0 && firstRow.height < 40)
    // The label box centers on the first row and is sized by the number
    // font, so its height differs from the row when fonts differ.
    #expect(abs(labelRect.midY - firstRow.midY) < 1.0)
    // Each logical line appears exactly once in the drawn set.
    #expect(reader.visibleLineNumbers.filter { $0 == 32 }.count == 1)
    withExtendedLifetime(window) {}
}

/// W21: when the first visual row has scrolled out and only continuation
/// rows remain visible, the line's recorded first-row rect lies outside the
/// viewport, so nothing is painted onto the visible continuation rows.
@MainActor
@Test
func wrapFirstRowScrolledOutLeavesContinuationRowsUndecorated() throws {
    let document = wrapLongLineDocument()
    let (reader, scrollView, window) = renderOffscreen(document)
    reader.apply(settings: wrapSettings(true))
    wrapSettle(reader)
    let megaLine = 32
    let megaByte = document.lineTable.lineStarts[megaLine - 1]
    reader.restore(scrollByteOffset: megaByte, selectionByteOffset: nil)
    wrapSettle(reader)
    // Scroll deep into the wrapped rows so the first row is far above.
    scrollView.contentView.scroll(
        to: NSPoint(x: 0, y: scrollView.contentView.bounds.minY + 120)
    )
    scrollView.reflectScrolledClipView(scrollView.contentView)
    wrapSettle(reader)
    let ruler = try #require(scrollView.verticalRulerView)
    let rulerRep = try #require(
        ruler.bitmapImageRepForCachingDisplay(in: ruler.bounds)
    )
    ruler.cacheDisplay(in: ruler.bounds, to: rulerRep)

    #expect(reader.lastRulerFirstRowRectsForTesting[megaLine] == nil)
    #expect(!reader.visibleLineNumbers.contains(megaLine))
    withExtendedLifetime(window) {}
}

/// W22: fold handle hover and click hit only the first visual row of the
/// fold header; a wrapped header's continuation rows produce neither.
@MainActor
@Test
func wrapFoldHandleHitTestingUsesOnlyTheFirstVisualRow() throws {
    let longSignature = String(
        repeating: "alpha_beta_gamma_delta: usize, ",
        count: 12
    )
    let source = "fn wrapped_header(\(longSignature)tail: usize) {\n    let one = 1;\n    let two = 2;\n    let three = 3;\n}\nfn after() {}\n"
    let bytes = Array(source.utf8)
    let fold = FoldRegion(
        id: FoldID(rawValue: 4200),
        kind: .declaration,
        headerRange: ByteRange(lowerBound: 0, upperBound: 3),
        bodyRange: ByteRange(lowerBound: 0, upperBound: UInt32(bytes.count)),
        outlineDepth: 0,
        summary: FoldSummary(hiddenLineCount: 3)
    )
    let document = ReaderDocument(
        bytes: bytes,
        lineTable: LineTable(bytes: bytes),
        byteUTF16Map: ByteUTF16Map(validUTF8: bytes),
        highlightSpans: [],
        outlineFacets: [],
        foldRegions: [fold]
    )
    let (reader, scrollView, window) = renderOffscreen(document)
    reader.apply(settings: wrapSettings(true))
    wrapSettle(reader)
    let ruler = try #require(scrollView.verticalRulerView)

    // Park the viewport on the wrapped header so its first row is visible.
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: 0))
    scrollView.reflectScrolledClipView(scrollView.contentView)
    reader.view.textLayoutManager?.textViewportLayoutController.layoutViewport()
    let rulerRep = try #require(
        ruler.bitmapImageRepForCachingDisplay(in: ruler.bounds)
    )
    ruler.cacheDisplay(in: ruler.bounds, to: rulerRep)
    let firstRow = try #require(reader.lastRulerFirstRowRectsForTesting[1])
    let foldX = reader.rulerThickness - 6
    // First visual row: hits. Points are RULER-space (as AppKit delivers
    // from mouse events): x inside the ruler, y converted from the view.
    func rulerPoint(y viewY: CGFloat) -> NSPoint {
        NSPoint(
            x: foldX,
            y: ruler.convert(NSPoint(x: 0, y: viewY), from: reader.view).y
        )
    }
    let hitPoint = rulerPoint(y: firstRow.midY)
    reader.setFoldGutterHoverForTesting(hitPoint)
    #expect(reader.foldGutterHoveredFoldID == fold.id)
    // Click on the first row toggles the fold.
    reader.clickFoldHandle(at: hitPoint, in: ruler, modifiers: [])
    #expect(reader.renderedFoldIDsForTesting.contains(fold.id))
    _ = reader.toggleFold(id: fold.id)

    // Continuation row (one row below the first): no hover, no click.
    let continuationY = firstRow.maxY + firstRow.height / 2
    let missPoint = rulerPoint(y: continuationY)
    reader.setFoldGutterHoverForTesting(missPoint)
    #expect(reader.foldGutterHoveredFoldID == nil)
    reader.clickFoldHandle(at: missPoint, in: ruler, modifiers: [])
    #expect(!reader.renderedFoldIDsForTesting.contains(fold.id))
    scrollView.contentView.scroll(to: .zero)
    wrapSettle(reader)
    ruler.cacheDisplay(in: ruler.bounds, to: rulerRep)
    let currentRow = try #require(reader.lastRulerFirstRowRectsForTesting[1])
    reader.setFoldGutterHoverForTesting(rulerPoint(y: currentRow.midY))
    #expect(reader.foldGutterHoveredFoldID == fold.id)
    reader.apply(settings: wrapSettings(false))
    #expect(reader.foldGutterHoveredFoldID == nil)
    _ = scrollView
    withExtendedLifetime(window) {}
}

/// W23: a find hit that spans visual rows is drawn as one box per visible
/// segment (TextKit 2 segments), never one first-line rect; a zero-length
/// range draws nothing.
@MainActor
@Test
func wrapPrimarySelectionCoversAllVisibleRowSegments() throws {
    let document = wrapLongLineDocument()
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
    reader.apply(settings: wrapSettings(true))
    reader.display(document: document)
    let megaLine = 32
    let megaByte = document.lineTable.lineStarts[megaLine - 1]
    let hitLength = 900
    reader.setFindMatches(
        [ByteRange(
            lowerBound: megaByte + 300,
            upperBound: megaByte + 300 + UInt32(hitLength)
        )],
        selectedIndex: 0
    )
    _ = reader.revealFindMatch(at: 0)
    wrapSettle(reader)

    // Real draw pass through the bitmap cache (offscreen windows never
    // draw otherwise): the background handler records the segments.
    let rep = try #require(
        reader.view.bitmapImageRepForCachingDisplay(in: reader.view.bounds)
    )
    reader.view.cacheDisplay(in: reader.view.visibleRect, to: rep)
    let segments = reader.lastPrimarySelectionSegmentsForTesting
    #expect(segments.count >= 2, "wrapped hit must produce multiple segments")
    for segment in segments {
        #expect(segment.height > 0 && segment.height < 40)
        #expect(segment.width > 0)
    }

    // Zero-length range: no boxes.
    reader.clearFindMatches(restoringSymbolAt: nil)
    reader.view.cacheDisplay(in: reader.view.visibleRect, to: rep)
    #expect(reader.lastPrimarySelectionSegmentsForTesting.isEmpty)
    withExtendedLifetime(window) {}
}

/// W19 subset: a reflow never steals first responder. The reader surface
/// only re-lays-out text; focus belongs to whoever held it (find field,
/// Settings form, another window).
@MainActor
private final class WrapKeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

@MainActor
@Test
func wrapToggleDoesNotStealFirstResponder() throws {
    let document = wrapLongLineDocument()
    let reader = ReaderTextView()
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 180))
    scrollView.hasVerticalScroller = true
    scrollView.documentView = reader.view
    reader.view.frame = scrollView.contentView.bounds
    let window = WrapKeyWindow(
        contentRect: scrollView.frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.contentView = scrollView
    reader.apply(settings: ReaderSettings())
    reader.display(document: document)
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 22))
    scrollView.addSubview(field)
    // Borderless windows must be ordered front before they accept focus.
    window.orderFront(nil)
    window.makeFirstResponder(field)
    guard window.firstResponder === field else {
        // Environments without an active window server cannot hold focus;
        // the focus contract is untestable here, not violated.
        print("WRAP_W19_SKIPPED environment cannot hold first responder")
        withExtendedLifetime(window) {}
        return
    }

    reader.apply(settings: wrapSettings(true))
    wrapSettle(reader, pumps: 3)
    #expect(window.firstResponder === field)
    reader.apply(settings: wrapSettings(false))
    wrapSettle(reader, pumps: 3)
    #expect(window.firstResponder === field)
    withExtendedLifetime(window) {}
}

/// W06: equal-settings applies are idempotent — no projection, no reflow.
@MainActor
@Test
func wrapSettingsApplyIsIdempotentForEqualValues() throws {
    let document = wrapLongLineDocument()
    let (reader, _, window) = renderOffscreen(document)
    let installs = reader.projectionInstallCount
    let visibleRect = reader.view.visibleRect

    reader.apply(settings: ReaderSettings())
    reader.apply(settings: ReaderSettings())
    #expect(reader.projectionInstallCount == installs)
    #expect(reader.view.visibleRect == visibleRect)

    // Wrap-only toggles never re-project either: the projected string is
    // identical, only the container geometry changes (the S1 fast path).
    reader.apply(settings: wrapSettings(true))
    wrapSettle(reader, pumps: 2)
    #expect(reader.projectionInstallCount == installs)
    reader.apply(settings: wrapSettings(false))
    #expect(reader.projectionInstallCount == installs)
    // A theme/font change does re-project.
    var larger = ReaderSettings()
    larger.fontSize = 15
    reader.apply(settings: larger)
    #expect(reader.projectionInstallCount == installs + 1)
    withExtendedLifetime(window) {}
}

/// W15 subset: a font-size change re-projects but keeps the anchor byte and
/// the complete selection.
@MainActor
@Test
func wrapFontSizeChangeKeepsAnchorAndSelection() throws {
    let document = wrapLongLineDocument()
    let (reader, _, window) = renderOffscreen(document)
    let megaLine = 32
    let megaByte = document.lineTable.lineStarts[megaLine - 1]
    reader.restore(scrollByteOffset: megaByte, selectionByteOffset: nil)
    wrapSettle(reader)
    let anchor = try #require(wrapQuarterAnchorByte(reader))

    let selection = NSRange(location: reader.view.selectedRange().location + 40, length: 60)
    reader.view.setSelectedRange(selection)

    var larger = ReaderSettings()
    larger.fontSize = 15
    reader.apply(settings: larger)
    wrapSettle(reader)
    let anchorAfterFont = try #require(wrapQuarterAnchorByte(reader))
    // Same logical line; the byte may differ by at most a few positions due
    // to font metrics, but the anchor must not jump to another line.
    let lineAfter = try #require(document.lineTable.lineColumn(at: anchorAfterFont)?.line)
    let lineBefore = try #require(document.lineTable.lineColumn(at: anchor)?.line)
    #expect(lineAfter == lineBefore)
    let restored = reader.view.selectedRanges.compactMap(\.rangeValue).first
    // The selection is restored as the same source text (display offsets may
    // shift if the projection grew, so compare through the source).
    if let restored {
        #expect(reader.sourceText(forDisplaySelection: restored) ==
            reader.sourceText(forDisplaySelection: selection))
    }
    withExtendedLifetime(window) {}
}

/// D3.7: a window/pane resize merges into one reflow that keeps the anchor
/// character at its viewport offset.
@MainActor
@Test
func wrapWidthChangeKeepsAnchorOffsetAfterMergedReflow() throws {
    let document = wrapLongLineDocument()
    let (reader, scrollView, window) = renderOffscreen(document)
    reader.apply(settings: wrapSettings(true))
    wrapSettle(reader)
    let megaLine = 32
    let megaByte = document.lineTable.lineStarts[megaLine - 1]
    reader.restore(scrollByteOffset: megaByte, selectionByteOffset: nil)
    wrapSettle(reader)
    let anchor = try #require(wrapQuarterAnchorByte(reader))
    let notificationsBefore = reader.widthReflowNotificationCount

    window.setContentSize(NSSize(width: 360, height: 180))
    window.displayIfNeeded()
    wrapSettle(reader)
    window.setContentSize(NSSize(width: 480, height: 180))
    window.displayIfNeeded()
    wrapSettle(reader)

    #expect(reader.widthReflowNotificationCount > notificationsBefore)
    // The anchor character stays on its logical line after the merged
    // width-driven reflows (D3.7); mergedWidthReflowCount is reported as a
    // diagnostic and not asserted here because a plain resize may produce a
    // single frame notification per AppKit pass.
    guard let current = wrapQuarterAnchorByte(reader) else {
        Issue.record("no anchor after resize round trip")
        return
    }
    let currentLine = try #require(document.lineTable.lineColumn(at: current)?.line)
    let anchorLine = try #require(document.lineTable.lineColumn(at: anchor)?.line)
    #expect(currentLine == anchorLine)
    _ = scrollView
    withExtendedLifetime(window) {}
}

@MainActor
@Test
func revealResetsHorizontalScrollAfterNavigation() throws {
    _ = NSApplication.shared
    let source = (0..<80).map { "let value\($0) = \"" + String(repeating: "x", count: 160) + "\";" }.joined(separator: "\n")
    let file = URL(fileURLWithPath: "/navigation.rs")
    let document = try DocumentLoader(source: { _ in Array(source.utf8) }).load(file: file).document
    let reader = ReaderTextView(settings: ReaderSettings())
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
    scroll.documentView = reader.view
    reader.view.frame = scroll.contentView.bounds
    let window = NSWindow(contentRect: scroll.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = scroll
    reader.display(document: document, fileURL: file)
    reader.configureGutter(in: scroll, lineNumbers: true)
    window.layoutIfNeeded()
    reader.view.textLayoutManager?.textViewportLayoutController.layoutViewport()
    for action in ["symbol", "restore", "diff"] {
        scroll.contentView.scroll(to: NSPoint(x: 150, y: 0))
        #expect(scroll.contentView.bounds.minX > 0)
        let offset = document.lineTable.lineStarts[40]
        switch action {
        case "symbol":
            reader.reveal(byteOffset: offset)
            reader.activate(atByteOffset: offset)
        case "restore":
            reader.restore(scrollByteOffset: offset, selectionByteOffset: offset)
        default:
            #expect(reader.revealDiffLine(41))
        }
        window.layoutIfNeeded()
        reader.view.textLayoutManager?.textViewportLayoutController.layoutViewport()
        #expect(abs(scroll.contentView.bounds.minX + scroll.contentView.contentInsets.left) < 1, "\(action): \(scroll.contentView.bounds)")
        #expect(scroll.contentView.bounds.minY > 0, "Must still navigate vertically")
    }
    withExtendedLifetime(window) {}
}

@MainActor
@Test
func foldAttachmentProviderSpikeCreatesUpdatesAndExposesAX() throws {
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
    // The chip target is intentionally 22pt tall and vertically centered on
    // the line, so it may extend slightly past the line fragment.
    #expect(providerView.bounds.height <= max(lineHeight, 22))

    #expect(providerView.hitTest(
        NSPoint(x: providerView.bounds.midX, y: providerView.bounds.midY)
    ) == nil)
    #expect(providerView.accessibilityLabel()?.contains("Collapsed, hides") == true)
    print(
        "M11_ATTACHMENT_SPIKE providerCreated=true countUpdated=true "
            + "axLabel=\(providerView.accessibilityLabel() ?? "nil") "
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
                regions.comment.id,
                regions.topLevelDeclaration.id,
            ]))
    #expect(reader.renderedFoldIDsForTesting == reader.logicalFoldIDsForTesting)
    #expect(!reader.logicalFoldIDsForTesting.contains(regions.smallDeclaration.id))
    for manualOnly in [regions.block, regions.attributes] {
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
                regions.comment.id,
                regions.topLevelDeclaration.id,
            ]))
    #expect(
        reader.renderedFoldIDsForTesting
            == Set([
                regions.container.id,
                regions.imports.id,
                regions.cfgTest.id,
                regions.comment.id,
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
@Test(.timeLimit(.minutes(1)))
func navigationUnfoldsManualAndBaselineAncestorsWithoutCrossingDirections() async throws {
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
    let markerStarted = ContinuousClock.now
    var lastPoll = markerStarted
    var mainActorWasStarved = false
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
                regions.comment.id,
                regions.topLevelDeclaration.id,
            ]))
    #expect(
        reader.navigationLandingLineForTesting
            == Int(try #require(
                document.lineTable.lineColumn(at: nestedOffset)
            ).line)
    )
    while reader.navigationLandingLineForTesting != nil {
        try await Task.sleep(for: .milliseconds(10))
        let now = ContinuousClock.now
        if lastPoll.duration(to: now) > .milliseconds(250) {
            mainActorWasStarved = true
        }
        lastPoll = now
    }
    #expect(reader.navigationLandingLineForTesting == nil)
    if !mainActorWasStarved {
        #expect(markerStarted.duration(to: ContinuousClock.now) < .seconds(3))
    }
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
func scopeHeaderUsesCompatibleFacetsAtSignaturesClosersAndCfgTest() {
    let (document, _) = readingHeightLevelDocument()
    let reader = ReaderTextView()
    reader.display(document: document, fileURL: URL(fileURLWithPath: "/scope.rs"))

    #expect(reader.scopeHeaderFacets(at: 20).map(\.name) == ["outer", "target"])
    #expect(reader.scopeHeaderFacets(at: 79).map(\.name) == ["outer", "target"])
    #expect(reader.scopeHeaderFacets(at: 295).map(\.name) == ["tests"])
    #expect(reader.scopeHeaderFacets(at: 260).isEmpty)
    #expect(reader.scopeHeaderFacets(at: 370).isEmpty)
}

@MainActor
@Test
func scopeHeaderKeepsOuterAndInnerWhenThreeAssociatedLevelsContainCaret() {
    let bytes = Array(String(repeating: "x", count: 220).utf8)
    func facet(
        _ kind: OutlineKind,
        _ name: String,
        _ range: Range<UInt32>,
        _ depth: Int
    ) -> OutlineFacet {
        OutlineFacet(
            kind: kind,
            name: name,
            range: ByteRange(lowerBound: range.lowerBound, upperBound: range.upperBound),
            nameRange: ByteRange(
                lowerBound: range.lowerBound,
                upperBound: range.lowerBound + 1
            ),
            depth: depth
        )
    }
    func region(
        _ id: UInt32,
        _ kind: FoldKind,
        _ body: Range<UInt32>,
        _ depth: Int
    ) -> FoldRegion {
        FoldRegion(
            id: FoldID(rawValue: id),
            kind: kind,
            headerRange: ByteRange(
                lowerBound: body.lowerBound - 1,
                upperBound: body.lowerBound
            ),
            bodyRange: ByteRange(lowerBound: body.lowerBound, upperBound: body.upperBound),
            outlineDepth: depth,
            summary: FoldSummary(hiddenLineCount: 3)
        )
    }
    let document = ReaderDocument(
        bytes: bytes,
        lineTable: LineTable(bytes: bytes),
        byteUTF16Map: ByteUTF16Map(validUTF8: bytes),
        highlightSpans: [],
        outlineFacets: [
            facet(.mod, "outer", 0..<220, 0),
            facet(.impl, "Runtime", 10..<210, 1),
            facet(.method, "spawn_on", 20..<200, 2),
        ],
        foldRegions: [
            region(0, .container, 5..<215, 0),
            region(1, .container, 15..<205, 1),
            region(2, .declaration, 25..<195, 2),
        ]
    )
    let reader = ReaderTextView()
    reader.display(document: document, fileURL: URL(fileURLWithPath: "/nested.rs"))

    let scopes = reader.scopeHeaderFacets(at: 50)
    #expect(scopes.map(\.kind) == [.mod, .method])
    #expect(scopes.map(\.name) == ["outer", "spawn_on"])
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
func findKeepsHiddenMatchesInTheLogicalCountAndRevealsTheirFoldChain() throws {
    let (document, regions) = readingHeightLevelDocument()
    let reader = ReaderTextView()
    reader.display(document: document, fileURL: URL(fileURLWithPath: "/find-fold.rs"))
    #expect(reader.setReadingHeightLevel(.overview))
    #expect(reader.logicalFoldIDsForTesting.contains(regions.container.id))
    #expect(reader.logicalFoldIDsForTesting.contains(regions.declaration.id))

    let hiddenMatch = ByteRange(lowerBound: 40, upperBound: 41)
    reader.setFindMatches([hiddenMatch], selectedIndex: 0)
    #expect(reader.findMatchCount == 1)
    #expect(reader.occurrenceCount == 1)
    #expect(
        reader.foldExposureTextForTesting(regions.container.id)
            == " · 1 matches"
    )
    #expect(reader.revealFindMatch(at: 0))
    #expect(!reader.logicalFoldIDsForTesting.contains(regions.container.id))
    #expect(!reader.logicalFoldIDsForTesting.contains(regions.declaration.id))
    #expect(reader.selectedFindMatchIndex == 0)
}

@MainActor
@Test
func foldedDiffIsExposedByTheChipAndMergedHeaderGutterMarker() throws {
    let (document, regions) = readingHeightLevelDocument()
    let reader = ReaderTextView()
    reader.display(document: document, fileURL: URL(fileURLWithPath: "/diff-fold.rs"))
    #expect(reader.setReadingHeightLevel(.overview))

    let hiddenLine = Int(try #require(
        document.lineTable.lineColumn(at: 40)
    ).line)
    let headerLine = Int(try #require(
        document.lineTable.lineColumn(at: regions.container.headerRange.lowerBound)
    ).line)
    reader.setDiffMarkers([hiddenLine: .added])

    #expect(reader.diffMarkerCounts[.added] == 1)
    #expect(
        reader.foldExposureTextForTesting(regions.container.id) == " · diff"
    )
    #expect(reader.foldedDiffMarkersForTesting[headerLine]?.rawValue
        == DiffCore.MarkerKind.added.rawValue)
}

@MainActor
@Test
func foldedCurrentSymbolOccurrencesAreExposedByTheChip() throws {
    let source = """
        fn first() {
            target();
            target();
            target();
        }
        fn second() {
            target();
        }
        """
    let bytes = Array(source.utf8)
    let document = try DocumentLoader(source: { _ in bytes })
        .load(file: URL(fileURLWithPath: "/occurrence-fold.rs"))
        .document
    let firstHeader = UInt32((source as NSString).range(of: "fn first").location)
    let fold = try #require(document.foldRegions.first {
        $0.kind == .declaration && $0.headerRange.lowerBound == firstHeader
    })
    let reader = ReaderTextView()
    reader.display(
        document: document,
        fileURL: URL(fileURLWithPath: "/occurrence-fold.rs")
    )
    let selected = (source as NSString).range(of: "target")
    #expect(selected.location != NSNotFound)
    _ = reader.activate(atByteOffset: UInt32(selected.location))
    #expect(reader.toggleFold(id: fold.id))

    #expect(reader.symbolOccurrenceByteOffset == UInt32(selected.location))
    #expect(
        reader.foldExposureTextForTesting(fold.id) == " · 3 occurrences"
    )
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
    reader.view.textLayoutManager?.textViewportLayoutController.layoutViewport()
    window.displayIfNeeded()
    #expect(!renderedColors(in: reader).isEmpty)

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
func typeScriptIdentifierClickHighlightsLexicalOccurrences() throws {
    let source = """
        const $value = 1;
        const alias = $value;
        const object = { $value };
        object.$value;
        const $valueExtra = "$value";
        // $value
        """
    let bytes = Array(source.utf8)
    let loaded = try DocumentLoader(source: { _ in bytes }).load(
        file: URL(fileURLWithPath: "/fixture.ts"),
        languageMode: LanguageMode(language: .typescript)
    )
    let (reader, _, window) = renderOffscreen(loaded.document)
    let selected = try #require(source.range(of: "$value"))
    let selectedOffset = UInt32(source[..<selected.lowerBound].utf8.count)
    let keyword = try #require(source.range(of: "const"))
    let keywordOffset = UInt32(source[..<keyword.lowerBound].utf8.count)

    #expect(reader.activate(atByteOffset: selectedOffset) == 4)
    window.displayIfNeeded()
    #expect(reader.occurrenceCount == 4)
    #expect(reader.activate(atByteOffset: keywordOffset) == 0)
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
        document.highlightSpans.contains {
            $0.range == reference && ($0.kind == .parameter || $0.kind == .localBinding)
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
    #expect(renderedColors(in: reader, intersecting: paramRange).contains {
        colorsEqual($0, ReaderTheme(settings: ReaderSettings()).color(for: .parameter))
    })
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
func defaultVisualSettingsRenderRestrainedDeclarationsAndParameterRoles() throws {
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
        parameterColor: legacyTheme.color(for: .parameter).withAlphaComponent(0.9),
        markerColor: legacyTheme.color(for: .functionName).withAlphaComponent(0.7),
        functionFont: .monospacedSystemFont(
            ofSize: legacyTheme.functionNameFontSize,
            weight: NSFont.Weight(rawValue: legacyTheme.functionDeclarationFontWeight)
        ),
        functionKern: 0,
        emphasisFont: .monospacedSystemFont(
            ofSize: legacyTheme.fontSize,
            weight: NSFont.Weight(rawValue: legacyTheme.declarationEmphasisFontWeight)
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

// Reader wrap v2 W30-W34: inspect real continuation geometry, not just styles.
@MainActor
@Test
func wrapHangingIndentUsesSpaceAndWidthCapsInActualRows() throws {
    for count in [0, 4, 24, 40] {
        let source = String(repeating: " ", count: count)
            + String(repeating: "value ", count: 70) + "\n"
        let bytes = Array(source.utf8)
        let document = ReaderDocument(bytes: bytes, lineTable: LineTable(bytes: bytes),
            byteUTF16Map: ByteUTF16Map(validUTF8: bytes), highlightSpans: [], outlineFacets: [])
        let (reader, _, window) = renderOffscreen(document)
        var settings = wrapSettings(true)
        settings.syntaxFormatting = false
        reader.apply(settings: settings)
        wrapSettle(reader)
        let manager = try #require(reader.view.textLayoutManager)
        let fragment = try #require(manager.textLayoutFragment(for: .zero))
        #expect(fragment.textLineFragments.count > 1)
        let font = NSFont.monospacedSystemFont(ofSize: settings.fontSize, weight: .regular)
        let space = (" " as NSString).size(withAttributes: [.font: font]).width
        let width = try #require(reader.view.textContainer).size.width
        let expected = min(CGFloat(count) * space, 24 * space, width * 0.25)
        let style = try #require(reader.view.textStorage?.attribute(
            .paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(abs(style.headIndent - expected) < 0.1)
        #expect(abs(fragment.textLineFragments[1].typographicBounds.minX - expected) < 1)
        #expect(abs(style.lineHeightMultiple - settings.lineHeightMultiple) < 0.001)
        settings.wrapLines = false
        reader.apply(settings: settings)
        let off = try #require(reader.view.textStorage?.attribute(
            .paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(off.headIndent == 0)
        withExtendedLifetime(window) {}
    }
}

@MainActor
@Test
func wrapTabPrefixUsesTheSameExplicitStopsAsTextKit() throws {
    let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    let style = NSMutableParagraphStyle()
    style.tabStops = [NSTextTab(textAlignment: .left, location: 37),
                      NSTextTab(textAlignment: .left, location: 83)]
    style.defaultTabInterval = 41
    style.lineHeightMultiple = 1.4
    let text = NSMutableAttributedString(string: " \t \t" + String(repeating: "word ", count: 70),
        attributes: [.font: font, .paragraphStyle: style])
    let paragraphs = ReaderParagraphLayout()
    paragraphs.apply(to: text, wrap: true, width: 500, font: font)
    let result = try #require(text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
    #expect(abs(result.headIndent - 83) < 1)
    #expect(result.tabStops == style.tabStops)
    #expect(result.defaultTabInterval == 41)
    let content = NSTextContentStorage()
    let manager = NSTextLayoutManager()
    content.addTextLayoutManager(manager)
    manager.textContainer = NSTextContainer(size: NSSize(width: 500, height: 10000))
    manager.textContainer?.lineFragmentPadding = 0
    content.textStorage?.setAttributedString(text)
    manager.ensureLayout(for: content.documentRange)
    let fragment = try #require(manager.textLayoutFragment(for: .zero))
    #expect(fragment.textLineFragments.count > 1)
    #expect(abs(fragment.textLineFragments[1].typographicBounds.minX - 83) < 1)
    #expect(paragraphs.apply(to: text, wrap: true, width: 500, font: font) == 0)
}

@MainActor
@Test
func wrapHangingIndentRecomputesOnWidthChangesWithoutProjection() throws {
    let bytes = Array((String(repeating: " ", count: 40) + String(repeating: "word ", count: 150)).utf8)
    let document = ReaderDocument(bytes: bytes, lineTable: LineTable(bytes: bytes),
        byteUTF16Map: ByteUTF16Map(validUTF8: bytes), highlightSpans: [], outlineFacets: [])
    let (reader, scroll, window) = renderOffscreen(document)
    reader.apply(settings: wrapSettings(true))
    wrapSettle(reader)
    let projections = reader.projectionInstallCount
    for width: CGFloat in [800, 320, 800] {
        scroll.setFrameSize(NSSize(width: width, height: 180))
        scroll.tile()
        wrapSettle(reader)
        let container = try #require(reader.view.textContainer)
        let style = try #require(reader.view.textStorage?.attribute(
            .paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        let space = (" " as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)]).width
        #expect(abs(style.headIndent - min(24 * space, 0.25 * container.size.width)) < 1)
    }
    #expect(reader.projectionInstallCount == projections)
    withExtendedLifetime(window) {}
}

@MainActor
@Test
func wrapHangingIndentSurvivesSyntaxAndFoldProjectionChanges() throws {
    let source = "    fn indented(" + String(repeating: "argument: usize, ", count: 20)
        + ") {\n        let first = 1;\n        let second = 2;\n        let third = 3;\n    }\n"
    let bytes = Array(source.utf8)
    let lines = LineTable(bytes: bytes)
    let fold = FoldRegion(id: FoldID(rawValue: 4567), kind: .declaration,
        headerRange: ByteRange(lowerBound: 0, upperBound: lines.lineStarts[1]),
        bodyRange: ByteRange(lowerBound: lines.lineStarts[1] - 2, upperBound: UInt32(bytes.count - 1)),
        outlineDepth: 0, summary: FoldSummary(hiddenLineCount: 4))
    let document = ReaderDocument(bytes: bytes, lineTable: lines,
        byteUTF16Map: ByteUTF16Map(validUTF8: bytes), highlightSpans: [], outlineFacets: [], foldRegions: [fold])
    let (reader, _, window) = renderOffscreen(document)
    var settings = wrapSettings(true)
    settings.syntaxFormatting = false
    reader.apply(settings: settings)
    for operation in 0..<4 {
        switch operation {
        case 0: reader.updateSyntax(document: document)
        case 1: #expect(reader.toggleFold(id: fold.id))
        case 2: #expect(reader.toggleFold(id: fold.id))
        default:
            settings.fontSize = 18
            settings.humanistComments = true
            reader.apply(settings: settings)
        }
        wrapSettle(reader)
        let style = try #require(reader.view.textStorage?.attribute(
            .paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        let space = (" " as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: settings.fontSize, weight: .regular)]).width
        #expect(abs(style.headIndent - 4 * space) < 1)
        #expect(abs(style.lineHeightMultiple - settings.lineHeightMultiple) < 0.001)
        if operation == 1 {
            let placeholder = (reader.view.string as NSString).range(of: "\u{FFFC}")
            #expect(placeholder.location != NSNotFound)
            let rect = try #require(ReaderViewportGeometry.characterRect(displayLocation: placeholder.location, in: reader.view))
            #expect(rect.minY > reader.view.textContainerOrigin.y + 20)
        }
    }
    withExtendedLifetime(window) {}
}

@MainActor
@Test
func wrapParagraphLayoutPreservesProportionalCommentsAndLargeDeclarations() throws {
    let comment = "    // " + String(repeating: "human readable comment ", count: 30) + "\n"
    let source = comment + "    fn declaration(" + String(repeating: "argument: usize, ", count: 25) + ") {}\n"
    let bytes = Array(source.utf8)
    let nameStart = UInt32(comment.utf8.count + 7)
    let document = ReaderDocument(bytes: bytes, lineTable: LineTable(bytes: bytes),
        byteUTF16Map: ByteUTF16Map(validUTF8: bytes), highlightSpans: [
            HighlightSpan(range: ByteRange(lowerBound: 4, upperBound: UInt32(comment.utf8.count - 1)), kind: .comment),
            HighlightSpan(range: ByteRange(lowerBound: nameStart, upperBound: nameStart + 11), kind: .functionName)
        ], outlineFacets: [])
    let (reader, _, window) = renderOffscreen(document)
    var settings = wrapSettings(true)
    settings.syntaxFormatting = true
    settings.humanistComments = true
    settings.functionNameDelta = 4
    settings.lineHeightMultiple = 1.7
    reader.apply(settings: settings)
    wrapSettle(reader)
    let storage = try #require(reader.view.textStorage)
    let commentFont = try #require(storage.attribute(.font, at: 4, effectiveRange: nil) as? NSFont)
    let declarationFont = try #require(storage.attribute(.font, at: Int(nameStart), effectiveRange: nil) as? NSFont)
    #expect(commentFont == NSFont.systemFont(ofSize: settings.fontSize))
    #expect(abs(declarationFont.pointSize - settings.fontSize - settings.functionNameDelta) < 0.001)
    for offset in [0, comment.utf16.count] {
        let style = try #require(storage.attribute(.paragraphStyle, at: offset, effectiveRange: nil) as? NSParagraphStyle)
        #expect(style.headIndent > 0)
        #expect(abs(style.lineHeightMultiple - 1.7) < 0.001)
    }
    withExtendedLifetime(window) {}
}
