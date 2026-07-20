import AppKit
import CodeInsightReaderCore

@MainActor
public enum ReaderTheme {
    public static let lineHeightMultiple: CGFloat = 1.25
    public static let baseFontSize: CGFloat = 13
    public static let functionNameDelta: CGFloat = 1
    public static let functionNameKern: CGFloat = 0.15

    public static let baseFont = NSFont.monospacedSystemFont(
        ofSize: baseFontSize,
        weight: .regular
    )
    public static let functionNameFont = NSFont.monospacedSystemFont(
        ofSize: baseFontSize + functionNameDelta,
        weight: .semibold
    )

    public static func color(for kind: HighlightKind) -> NSColor {
        switch kind {
        case .keyword:
            dynamic(light: 0x9C36B5, dark: 0xE879F9)
        case .comment:
            dynamic(light: 0x4D7C0F, dark: 0xA3E635)
        case .string:
            dynamic(light: 0xB42318, dark: 0xFDA29B)
        case .number:
            dynamic(light: 0x7F56D9, dark: 0xC4B5FD)
        case .functionName:
            dynamic(light: 0x175CD3, dark: 0x84ADFF)
        case .typeName:
            dynamic(light: 0x087E8B, dark: 0x67E8F9)
        }
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? dark
                : light
            return NSColor(
                red: CGFloat((value >> 16) & 0xff) / 255,
                green: CGFloat((value >> 8) & 0xff) / 255,
                blue: CGFloat(value & 0xff) / 255,
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

    public init() {}

    public func update(document: ReaderDocument) {
        spans = document.highlightSpans
        map = document.byteUTF16Map
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
                [.foregroundColor: ReaderTheme.color(for: span.kind)],
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
    private let backingTextStorage: NSTextStorage
    private var byteUTF16Map: ByteUTF16Map?

    public init() {
        let textView = ClickTextView(usingTextLayoutManager: true)
        view = textView
        backingTextStorage = NSTextStorage()
        view.textContentStorage?.textStorage = backingTextStorage
        configure()
        textView.clickHandler = { [weak self] index, modifiers in
            self?.onClick?(index, modifiers)
        }
        textView.viewportChanged = { [weak self] in
            guard let self,
                  let layoutManager = self.view.textLayoutManager
            else { return }
            self.validateVisibleRenderingAttributes(in: layoutManager)
        }
    }

    public func display(document: ReaderDocument) {
        guard
            let source = String(bytes: document.bytes, encoding: .utf8),
            let layoutManager = view.textLayoutManager
        else { return }

        byteUTF16Map = document.byteUTF16Map
        renderingCoordinator.update(document: document)
        let attributed = NSMutableAttributedString(
            string: source,
            attributes: baseAttributes
        )
        applyFunctionNameLayout(
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

    public func updateSyntax(document: ReaderDocument) {
        guard
            let layoutManager = view.textLayoutManager
        else { return }

        byteUTF16Map = document.byteUTF16Map
        renderingCoordinator.update(document: document)
        let viewportRange = layoutManager.textViewportLayoutController.viewportRange
        layoutManager.renderingAttributesValidator = nil
        backingTextStorage.beginEditing()
        applyFunctionNameLayout(
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
        paragraph.lineHeightMultiple = ReaderTheme.lineHeightMultiple
        return [
            .font: ReaderTheme.baseFont,
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: paragraph,
        ]
    }

    private func configure() {
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.drawsBackground = true
        view.backgroundColor = .textBackgroundColor
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

    private func applyFunctionNameLayout(
        _ spans: [HighlightSpan],
        map: ByteUTF16Map,
        to attributed: NSMutableAttributedString
    ) {
        for span in spans where span.kind == .functionName {
            guard let range = map.nsRange(
                byteLowerBound: Int(span.range.lowerBound),
                byteUpperBound: Int(span.range.upperBound)
            ) else { continue }
            attributed.addAttributes([
                .font: ReaderTheme.functionNameFont,
                .kern: ReaderTheme.functionNameKern,
            ], range: range)
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
