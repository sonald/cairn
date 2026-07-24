import AppKit
import CodeInsightReaderCore

@MainActor
public extension ReaderTheme {
    func color(for kind: HighlightKind) -> NSColor {
        dynamicColor { isDark in rgb(for: kind, isDark: isDark) }
    }

    func color(for kind: DiffCore.MarkerKind) -> NSColor {
        dynamicColor { isDark in diffRGB(for: kind, isDark: isDark) }
    }

    var backgroundColor: NSColor {
        dynamicColor(backgroundRGB(isDark:))
    }

    var foregroundColor: NSColor {
        dynamicColor(foregroundRGB(isDark:))
    }

    private func dynamicColor(
        _ value: @escaping @Sendable (Bool) -> UInt32
    ) -> NSColor {
        NSColor(name: nil) { appearance in
            let rgb = value(
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            )
            return NSColor(
                red: CGFloat((rgb >> 16) & 0xff) / 255,
                green: CGFloat((rgb >> 8) & 0xff) / 255,
                blue: CGFloat(rgb & 0xff) / 255,
                alpha: 1
            )
        }
    }
}

@MainActor
public final class RenderingAttributesCoordinator {
    public private(set) var styledFragmentCount = 0

    private var spans: [HighlightSpan] = []
    private var map: ByteUTF16Map?
    private var theme = ReaderTheme(settings: ReaderSettings())

    public init() {}

    public func update(document: ReaderDocument, theme: ReaderTheme) {
        spans = document.highlightSpans
        map = document.byteUTF16Map
        self.theme = theme
        styledFragmentCount = 0
    }

    func clear() {
        spans = []
        map = nil
        styledFragmentCount = 0
    }

    public func style(
        fragment: NSTextLayoutFragment,
        in manager: NSTextLayoutManager
    ) {
        let bounds = manager.textViewportLayoutController.viewportBounds
        let bufferedViewport = bounds.insetBy(dx: 0, dy: -bounds.height * 2)
        guard fragment.layoutFragmentFrame.intersects(bufferedViewport) else { return }
        guard let map, let content = manager.textContentManager else { return }

        let fragmentRange = fragment.rangeInElement
        let start = content.offset(
            from: content.documentRange.location,
            to: fragmentRange.location
        )
        let end = content.offset(
            from: content.documentRange.location,
            to: fragmentRange.endLocation
        )
        guard
            start != NSNotFound,
            end != NSNotFound,
            let lowerByte = map.byteOffset(forUTF16: start),
            let upperByte = map.byteOffset(forUTF16: end),
            let lower = UInt32(exactly: lowerByte),
            let upper = UInt32(exactly: upperByte)
        else { return }

        let visibleSpans = ViewportGating.spans(
            spans,
            intersectingBytes: lower..<upper,
            buffer: 0
        )
        let fragmentNSRange = NSRange(location: start, length: end - start)
        var wroteAttributes = false
        for span in visibleSpans {
            guard let globalRange = map.nsRange(
                byteLowerBound: Int(span.range.lowerBound),
                byteUpperBound: Int(span.range.upperBound)
            ) else { continue }
            let intersection = NSIntersectionRange(globalRange, fragmentNSRange)
            guard
                intersection.length > 0,
                let textRange = textRange(
                    intersection,
                    in: content
                )
            else { continue }
            manager.setRenderingAttributes(
                [.foregroundColor: theme.color(for: span.kind)],
                for: textRange
            )
            wroteAttributes = true
        }
        if wroteAttributes { styledFragmentCount += 1 }
    }

    private func textRange(
        _ range: NSRange,
        in content: NSTextContentManager
    ) -> NSTextRange? {
        guard
            let lower = content.location(
                content.documentRange.location,
                offsetBy: range.location
            ),
            let upper = content.location(lower, offsetBy: range.length)
        else { return nil }
        return NSTextRange(location: lower, end: upper)
    }
}

@MainActor
public final class ReaderTextView {
    public let view: NSTextView
    public let renderingCoordinator = RenderingAttributesCoordinator()
    public var onClick: ((Int, NSEvent.ModifierFlags) -> Void)?
    public var onViewportChange: (() -> Void)?
    private let backingTextStorage: NSTextStorage
    private var byteUTF16Map: ByteUTF16Map?
    private var displayedDocument: ReaderDocument?
    private var theme: ReaderTheme
    private var diffMarkers: [Int: DiffCore.MarkerKind] = [:]
    private weak var diffRuler: NSRulerView?

    public init(settings: ReaderSettings = ReaderSettings()) {
        theme = ReaderTheme(settings: settings)
        let textView = ClickTextView(usingTextLayoutManager: true)
        view = textView
        backingTextStorage = NSTextStorage()
        view.textContentStorage?.textStorage = backingTextStorage
        configure()
        applyThemeColors()
        textView.clickHandler = { [weak self] index, modifiers in
            self?.onClick?(index, modifiers)
        }
        textView.viewportChanged = { [weak self] in
            guard let self,
                  let layoutManager = self.view.textLayoutManager
            else { return }
            self.validateVisibleRenderingAttributes(in: layoutManager)
            self.diffRuler?.needsDisplay = true
            self.onViewportChange?()
        }
    }

    public func display(document: ReaderDocument) {
        guard
            let source = String(bytes: document.bytes, encoding: .utf8),
            let layoutManager = view.textLayoutManager
        else { return }

        byteUTF16Map = document.byteUTF16Map
        displayedDocument = document
        diffMarkers = [:]
        diffRuler?.needsDisplay = true
        renderingCoordinator.update(document: document, theme: theme)
        let attributed = NSMutableAttributedString(
            string: source,
            attributes: baseAttributes
        )
        applyTypography(
            document.highlightSpans,
            map: document.byteUTF16Map,
            to: attributed
        )
        if document.highlightSpans.isEmpty {
            layoutManager.renderingAttributesValidator = nil
        } else {
            layoutManager.renderingAttributesValidator = { [weak renderingCoordinator] manager, fragment in
                renderingCoordinator?.style(fragment: fragment, in: manager)
            }
        }
        backingTextStorage.setAttributedString(attributed)
        if !document.highlightSpans.isEmpty {
            validateVisibleRenderingAttributes(in: layoutManager)
        }
    }

    public func clear() {
        view.textLayoutManager?.renderingAttributesValidator = nil
        displayedDocument = nil
        byteUTF16Map = nil
        diffMarkers = [:]
        renderingCoordinator.clear()
        backingTextStorage.setAttributedString(NSAttributedString(string: ""))
        diffRuler?.needsDisplay = true
        view.needsDisplay = true
    }

    public func updateSyntax(document: ReaderDocument) {
        guard
            let layoutManager = view.textLayoutManager
        else { return }
        guard documentMatchesStorage(document) else {
            layoutManager.renderingAttributesValidator = nil
            return
        }

        byteUTF16Map = document.byteUTF16Map
        displayedDocument = document
        renderingCoordinator.update(document: document, theme: theme)
        let viewportRange = layoutManager.textViewportLayoutController.viewportRange
        layoutManager.renderingAttributesValidator = nil
        backingTextStorage.beginEditing()
        applyTypography(
            document.highlightSpans,
            map: document.byteUTF16Map,
            to: backingTextStorage
        )
        backingTextStorage.endEditing()
        layoutManager.renderingAttributesValidator = { [weak renderingCoordinator] manager, fragment in
            renderingCoordinator?.style(fragment: fragment, in: manager)
        }
        if let viewportRange {
            layoutManager.invalidateRenderingAttributes(for: viewportRange)
        }
        view.needsDisplay = true
        DispatchQueue.main.async { [weak self, weak layoutManager] in
            guard let self, let layoutManager else { return }
            self.validateVisibleRenderingAttributes(in: layoutManager)
        }
    }

    public func apply(settings: ReaderSettings) {
        theme = ReaderTheme(settings: settings)
        applyThemeColors()
        diffRuler?.needsDisplay = true
        guard let document = displayedDocument,
              let layoutManager = view.textLayoutManager
        else { return }
        guard documentMatchesStorage(document) else {
            layoutManager.renderingAttributesValidator = nil
            return
        }

        renderingCoordinator.update(document: document, theme: theme)
        let viewportRange = layoutManager.textViewportLayoutController.viewportRange
        layoutManager.renderingAttributesValidator = nil
        backingTextStorage.beginEditing()
        backingTextStorage.setAttributes(
            baseAttributes,
            range: NSRange(location: 0, length: backingTextStorage.length)
        )
        applyTypography(
            document.highlightSpans,
            map: document.byteUTF16Map,
            to: backingTextStorage
        )
        backingTextStorage.endEditing()
        if !document.highlightSpans.isEmpty {
            layoutManager.renderingAttributesValidator = {
                [weak renderingCoordinator] manager, fragment in
                renderingCoordinator?.style(fragment: fragment, in: manager)
            }
        }
        if let viewportRange {
            layoutManager.invalidateRenderingAttributes(for: viewportRange)
            validateVisibleRenderingAttributes(in: layoutManager)
        }
        view.needsDisplay = true
    }

    public func reveal(byteOffset: UInt32) {
        guard let location = byteUTF16Map?.utf16Offset(forByte: Int(byteOffset)),
              location <= backingTextStorage.length
        else { return }
        let lineRange = (backingTextStorage.string as NSString).lineRange(
            for: NSRange(location: location, length: 0)
        )
        view.scrollRangeToVisible(lineRange)
        view.showFindIndicator(for: lineRange)
    }

    public func restore(
        scrollByteOffset: UInt32?,
        selectionByteOffset: UInt32?
    ) {
        if let selectionByteOffset,
           let location = byteUTF16Map?.utf16Offset(
               forByte: Int(selectionByteOffset)
           ),
           location <= backingTextStorage.length
        {
            view.setSelectedRange(NSRange(location: location, length: 0))
        }
        guard let scrollByteOffset,
              let document = displayedDocument,
              let desired = document.lineTable.lineColumn(
                  at: scrollByteOffset
              ),
              let scrollView = view.enclosingScrollView,
              let window = view.window
        else { return }
        var candidateLine = Int(desired.line)
        for _ in 0..<3 {
            guard candidateLine > 0,
                  document.lineTable.lineStarts.indices.contains(candidateLine - 1),
                  let location = byteUTF16Map?.utf16Offset(
                      forByte: Int(
                          document.lineTable.lineStarts[candidateLine - 1]
                      )
                  )
            else { return }
            let range = NSRange(location: location, length: 0)
            view.scrollRangeToVisible(range)
            view.textLayoutManager?.textViewportLayoutController.layoutViewport()
            let screenRect = view.firstRect(
                forCharacterRange: range,
                actualRange: nil
            )
            let lineRect = view.convert(
                window.convertFromScreen(screenRect),
                from: nil
            )
            let clipView = scrollView.contentView
            clipView.scroll(to: NSPoint(
                x: clipView.bounds.origin.x,
                y: lineRect.minY
            ))
            scrollView.reflectScrolledClipView(clipView)
            guard let actualOffset = firstVisibleByteOffset(),
                  let actual = document.lineTable.lineColumn(at: actualOffset)
            else { return }
            let lineDelta = Int(actual.line) - Int(desired.line)
            if lineDelta == 0 { return }
            candidateLine = max(
                1,
                min(
                    document.lineTable.lineStarts.count,
                    candidateLine - lineDelta
                )
            )
        }
    }

    public func installDiffGutter(in scrollView: NSScrollView) {
        let ruler = DiffGutterRulerView(scrollView: scrollView, reader: self)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        diffRuler = ruler
    }

    public func setDiffMarkers(_ markers: [Int: DiffCore.MarkerKind]) {
        diffMarkers = markers
        diffRuler?.needsDisplay = true
    }

    public var diffMarkerCounts: [DiffCore.MarkerKind: Int] {
        Dictionary(grouping: diffMarkers.values, by: { $0 }).mapValues(\.count)
    }

    @discardableResult
    public func revealDiffLine(_ line: Int) -> Bool {
        guard line > 0,
              let document = displayedDocument,
              document.lineTable.lineStarts.indices.contains(line - 1),
              let location = byteUTF16Map?.utf16Offset(
                  forByte: Int(document.lineTable.lineStarts[line - 1])
              )
        else { return false }
        let range = (backingTextStorage.string as NSString).lineRange(
            for: NSRange(location: location, length: 0)
        )
        view.setSelectedRange(range)
        view.scrollRangeToVisible(range)
        view.showFindIndicator(for: range)
        return true
    }

    public var selectedLineNumber: Int? {
        guard let document = displayedDocument,
              let byteOffset = byteUTF16Map?.byteOffset(
                  forUTF16: view.selectedRange().location
              ),
              let byteOffset = UInt32(exactly: byteOffset),
              let position = document.lineTable.lineColumn(at: byteOffset)
        else { return nil }
        return Int(position.line)
    }

    public var displayedBytes: [UInt8]? { displayedDocument?.bytes }

    public func byteOffset(forCharacterIndex index: Int) -> UInt32? {
        byteUTF16Map?.byteOffset(forUTF16: index).flatMap(UInt32.init(exactly:))
    }

    public func firstVisibleByteOffset() -> UInt32? {
        guard let layoutManager = view.textLayoutManager,
              let content = layoutManager.textContentManager
        else { return nil }
        layoutManager.textViewportLayoutController.layoutViewport()
        guard let viewport = layoutManager.textViewportLayoutController.viewportRange else {
            return nil
        }
        let location = content.offset(
            from: content.documentRange.location,
            to: viewport.location
        )
        guard location != NSNotFound else { return nil }
        let lineStart = (backingTextStorage.string as NSString).lineRange(
            for: NSRange(location: location, length: 0)
        ).location
        return byteUTF16Map?.byteOffset(forUTF16: lineStart)
            .flatMap(UInt32.init(exactly:))
    }

    private var baseAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = theme.lineHeightMultiple
        return [
            .font: NSFont.monospacedSystemFont(
                ofSize: theme.fontSize,
                weight: .regular
            ),
            .foregroundColor: theme.foregroundColor,
            .paragraphStyle: paragraph,
        ]
    }

    private func configure() {
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.drawsBackground = true
        view.textContainerInset = NSSize(width: 12, height: 12)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = true
        view.minSize = .zero
        view.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
    }

    private func applyThemeColors() {
        view.backgroundColor = theme.backgroundColor
    }

    // Defense-in-depth fuse only; clear() is the root fix for document/storage splits.
    private func documentMatchesStorage(_ document: ReaderDocument) -> Bool {
        let matches = document.byteUTF16Map.utf16Count == backingTextStorage.length
#if DEBUG
        // Unit tests have no app delegate so they can exercise the release fallback.
        if !matches, NSApp?.delegate != nil {
            assertionFailure("Reader document and text storage lengths diverged")
        }
#endif
        return matches
    }

    private func applyTypography(
        _ spans: [HighlightSpan],
        map: ByteUTF16Map,
        to attributed: NSMutableAttributedString
    ) {
        for span in spans {
            guard let range = map.nsRange(
                byteLowerBound: Int(span.range.lowerBound),
                byteUpperBound: Int(span.range.upperBound)
            ) else { continue }
            guard range.location >= 0, range.location < attributed.length else {
                continue
            }
            let safeRange = NSRange(
                location: range.location,
                length: min(range.length, attributed.length - range.location)
            )
            guard safeRange.length > 0 else { continue }
            switch span.kind {
            case .functionName:
                attributed.addAttributes([
                    .font: NSFont.monospacedSystemFont(
                        ofSize: theme.functionNameFontSize,
                        weight: .semibold
                    ),
                    .kern: 0.15,
                ], range: safeRange)
            case .comment where theme.humanistComments:
                attributed.addAttribute(
                    .font,
                    value: NSFont.systemFont(ofSize: theme.fontSize),
                    range: safeRange
                )
            default:
                break
            }
        }
    }

    private func validateVisibleRenderingAttributes(in layoutManager: NSTextLayoutManager) {
        let controller = layoutManager.textViewportLayoutController
        controller.layoutViewport()
        guard let viewportRange = controller.viewportRange else { return }
        layoutManager.invalidateRenderingAttributes(for: viewportRange)
        let viewport = controller.viewportBounds.insetBy(
            dx: 0,
            dy: -controller.viewportBounds.height * 2
        )
        layoutManager.enumerateTextLayoutFragments(
            from: viewportRange.location,
            options: []
        ) { fragment in
            guard fragment.layoutFragmentFrame.minY <= viewport.maxY else {
                return false
            }
            layoutManager.renderingAttributesValidator?(layoutManager, fragment)
            return true
        }
        view.needsDisplay = true
    }

    fileprivate func drawDiffMarkers(in ruler: NSRulerView) {
        guard let document = displayedDocument, let window = view.window else { return }
        for (line, kind) in diffMarkers {
            guard line > 0,
                  document.lineTable.lineStarts.indices.contains(line - 1),
                  let location = byteUTF16Map?.utf16Offset(
                      forByte: Int(document.lineTable.lineStarts[line - 1])
                  )
            else { continue }
            let screenRect = view.firstRect(
                forCharacterRange: NSRange(location: location, length: 0),
                actualRange: nil
            )
            let markerRect = ruler.convert(window.convertFromScreen(screenRect), from: nil)
            let bar = NSRect(
                x: 1,
                y: markerRect.minY,
                width: max(2, ruler.ruleThickness - 2),
                height: max(2, markerRect.height)
            )
            guard bar.intersects(ruler.bounds) else { continue }
            theme.color(for: kind).setFill()
            bar.fill()
        }
    }
}

@MainActor
private final class DiffGutterRulerView: NSRulerView {
    private weak var reader: ReaderTextView?

    init(scrollView: NSScrollView, reader: ReaderTextView) {
        self.reader = reader
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        ruleThickness = 7
        clientView = reader.view
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        reader?.drawDiffMarkers(in: self)
    }
}

@MainActor
private final class ClickTextView: NSTextView {
    var clickHandler: ((Int, NSEvent.ModifierFlags) -> Void)?
    var viewportChanged: (() -> Void)?
    private var viewportOrigin: NSPoint?

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        NotificationCenter.default.removeObserver(
            self,
            name: NSView.boundsDidChangeNotification,
            object: nil
        )
        guard let clipView = enclosingScrollView?.contentView else { return }
        viewportOrigin = clipView.bounds.origin
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(viewportDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )
    }

    override func mouseDown(with event: NSEvent) {
        let index = characterIndex(for: event)
        super.mouseDown(with: event)
        clickHandler?(index, event.modifierFlags.intersection(.deviceIndependentFlagsMask))
    }

    @objc private func viewportDidChange(_ notification: Notification) {
        guard let clipView = notification.object as? NSClipView,
              clipView.bounds.origin != viewportOrigin
        else { return }
        viewportOrigin = clipView.bounds.origin
        viewportChanged?()
    }
}

@MainActor
private extension NSTextView {
    func characterIndex(for event: NSEvent) -> Int {
        characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
    }
}
