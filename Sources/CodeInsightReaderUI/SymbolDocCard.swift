@preconcurrency import AppKit
import CodeInsightCore
import CodeInsightReaderCore

/// The hover documentation card: a translucent borderless child window with
/// a location line, a signature band and the Markdown body, plus a footer for
/// notes. Selection, copy, scrolling and links work inside it.
@MainActor
public final class SymbolDocCard: NSObject, NSTextViewDelegate {
    public static let maximumSize = NSSize(width: 560, height: 400)
    static let minimumWidth: CGFloat = 260
    static let gap: CGFloat = 4
    static let horizontalPadding: CGFloat = 14
    static let bodyPointSize: CGFloat = 12.5

    public var onPointerEntered: (() -> Void)?
    public var onPointerExited: (() -> Void)?
    public var onOpenLink: ((URL) -> Void)?
    public var onEscape: (() -> Void)?

    public private(set) var shownDoc: SymbolDoc?
    public var isShown: Bool { panel.isVisible }
    /// The card's frame in screen coordinates while shown.
    public var frame: NSRect { panel.frame }

    /// Whether `window` is the card, e.g. for key events routed to it after
    /// a click inside.
    public func contains(_ window: NSWindow?) -> Bool { window === panel }

    private let panel = CardPanel(
        contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: true
    )
    private let effect = NSVisualEffectView()
    private let tint = NSView()
    private let scrollView = NSScrollView()
    private let textView = CardTextView(usingTextLayoutManager: false)
    private let footerDivider = NSView()
    private let footer = NSTextField(wrappingLabelWithString: "")
    private var theme: ReaderTheme?
    private var notes: [String] = []
    private weak var parent: NSWindow?

    override public init() {
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.escape = { [weak self] in self?.onEscape?() }
        panel.setAccessibilityRole(.popover)
        panel.setAccessibilityLabel(localized("reader.hover.card"))

        let root = TrackingView()
        root.wantsLayer = true
        root.layer?.cornerRadius = 9
        root.layer?.masksToBounds = true
        root.layer?.borderWidth = 1
        root.entered = { [weak self] in self?.onPointerEntered?() }
        root.exited = { [weak self] in self?.onPointerExited?() }
        panel.contentView = root

        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        tint.wantsLayer = true
        for view in [effect, tint] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                view.topAnchor.constraint(equalTo: root.topAnchor),
                view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ])
        }

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.delegate = self
        textView.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        textView.escape = { [weak self] in self?.onEscape?() }
        textView.hoveredLink = { [weak self] url in self?.showLinkInFooter(url) }
        textView.setAccessibilityLabel(localized("reader.hover.card"))

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        footer.isSelectable = true
        footer.drawsBackground = false
        footer.font = .systemFont(ofSize: 11)
        footerDivider.wantsLayer = true
        for view in [scrollView, footerDivider, footer] as [NSView] {
            root.addSubview(view)
        }
    }

    // MARK: - Showing

    /// Shows `doc` next to `anchor` (screen coordinates): above the symbol
    /// when it fits inside the parent window, otherwise below.
    public func show(
        _ doc: SymbolDoc,
        notes: [String],
        anchor: NSRect,
        in parent: NSWindow,
        theme: ReaderTheme
    ) {
        let unchangedContent = shownDoc == doc && self.notes == notes && self.theme == theme
        shownDoc = doc
        self.notes = notes
        self.theme = theme
        panel.appearance = parent.effectiveAppearance
        if !unchangedContent { applyContent() }
        let size = layoutSize()
        panel.setFrame(placement(for: size, anchor: anchor, within: parent.frame), display: true)
        layoutSubviews(size: size)
        if self.parent !== parent {
            self.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
            self.parent = parent
        }
        panel.orderFront(nil)
    }

    public func hide() {
        guard panel.isVisible || parent != nil else { return }
        // A click inside the card made it key; give keys (Escape, ⌘C, find)
        // back to the reader window.
        if panel.isKeyWindow { parent?.makeKey() }
        parent?.removeChildWindow(panel)
        parent = nil
        panel.orderOut(nil)
        shownDoc = nil
        textView.setSelectedRange(NSRange(location: 0, length: 0))
    }

    static func placement(
        for size: NSSize,
        anchor: NSRect,
        within bounds: NSRect
    ) -> NSRect {
        var x = anchor.minX - 4
        x = max(bounds.minX + 8, min(x, bounds.maxX - size.width - 8))
        let above = anchor.maxY + gap
        let below = anchor.minY - gap - size.height
        let fitsAbove = above + size.height <= bounds.maxY - 8
        let fitsBelow = below >= bounds.minY + 8
        let y = fitsAbove || !fitsBelow ? above : below
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func placement(for size: NSSize, anchor: NSRect, within bounds: NSRect) -> NSRect {
        Self.placement(for: size, anchor: anchor, within: bounds)
    }

    // MARK: - Content

    private func applyContent() {
        guard let doc = shownDoc, let theme else { return }
        let root = panel.contentView
        let appearance = panel.appearance ?? NSApp.effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            tint.layer?.backgroundColor = theme.backgroundColor.withAlphaComponent(0.55).cgColor
            root?.layer?.borderColor = theme.chromeDividerColor.withAlphaComponent(0.8).cgColor
            footerDivider.layer?.backgroundColor = theme.chromeDividerColor.cgColor
        }
        textView.textStorage?.setAttributedString(Self.content(for: doc, theme: theme))
        textView.selectedTextAttributes = [.backgroundColor: theme.chromeSelectionColor]
        applyFooter(notes)
    }

    static func content(for doc: SymbolDoc, theme: ReaderTheme) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let pad = paddingBlock(top: 9, bottom: 0)
        if let location = doc.location {
            let style = NSMutableParagraphStyle()
            style.textBlocks = [pad]
            style.lineBreakMode = .byCharWrapping
            output.append(NSAttributedString(string: location + "\n", attributes: [
                .font: ReaderFontResolver.shared.resolve(theme: theme, size: 11).font,
                .foregroundColor: theme.chromeTertiaryColor,
                .paragraphStyle: style,
            ]))
        }
        if let signature = doc.signature {
            let band = NSTextBlock()
            band.setValue(100, type: .percentageValueType, for: .width)
            band.backgroundColor = theme.chromeColor.withAlphaComponent(0.72)
            band.setWidth(1, type: .absoluteValueType, for: .border, edge: .minY)
            band.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
            band.setBorderColor(theme.chromeDividerColor)
            band.setWidth(horizontalPadding, type: .absoluteValueType, for: .padding, edge: .minX)
            band.setWidth(horizontalPadding, type: .absoluteValueType, for: .padding, edge: .maxX)
            band.setWidth(8, type: .absoluteValueType, for: .padding, edge: .minY)
            band.setWidth(9, type: .absoluteValueType, for: .padding, edge: .maxY)
            band.setWidth(doc.location == nil ? 0 : 7, type: .absoluteValueType, for: .margin, edge: .minY)
            let style = NSMutableParagraphStyle()
            style.textBlocks = [band]
            style.lineBreakMode = .byCharWrapping
            style.lineHeightMultiple = 1.12
            let resolved = ReaderFontResolver.shared.resolve(theme: theme, size: 12.5)
            var attributes = resolved.attributes
            attributes[.foregroundColor] = theme.foregroundColor
            attributes[.paragraphStyle] = style
            let start = output.length
            output.append(NSAttributedString(string: signature + "\n", attributes: attributes))
            let spans = CodeSnippetHighlighter.spans(
                for: signature,
                languageHint: doc.signatureLanguage ?? ""
            )
            let emphasis = ReaderFontResolver.shared.resolve(theme: theme, size: 12.5, weight: .semibold).font
            CodeTextPreviewStyler.apply(spans, to: output, offset: start, theme: theme, emphasisFont: emphasis)
        }
        let body: NSAttributedString?
        if !doc.markdown.isEmpty {
            body = MarkdownPreviewRenderer(
                theme: theme,
                baseURL: nil,
                bodyPointSize: bodyPointSize,
                compactHeadings: true
            ).render(doc.markdown)
        } else if doc.signature != nil {
            body = NSAttributedString(string: localized("reader.hover.noDocs"), attributes: [
                .font: NSFontManager.shared.convert(
                    .systemFont(ofSize: bodyPointSize),
                    toHaveTrait: .italicFontMask
                ),
                .foregroundColor: theme.chromeTertiaryColor,
            ])
        } else {
            body = nil
        }
        if let body, body.length > 0 {
            let wrapped = NSMutableAttributedString(attributedString: body)
            let outer = paddingBlock(top: 10, bottom: 12)
            wrapped.enumerateAttribute(
                .paragraphStyle,
                in: NSRange(location: 0, length: wrapped.length)
            ) { value, range, _ in
                let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
                    ?? NSMutableParagraphStyle()
                style.textBlocks = [outer] + style.textBlocks
                wrapped.addAttribute(.paragraphStyle, value: style, range: range)
            }
            output.append(wrapped)
        }
        while output.string.hasSuffix("\n") {
            output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1))
        }
        // TextKit 1 leaves the last block's bottom padding and border out of
        // the used rect; a tiny block-free paragraph closes it.
        if output.length > 0 {
            output.append(NSAttributedString(string: "\n\u{00A0}", attributes: [
                .font: NSFont.systemFont(ofSize: 2),
            ]))
        }
        return output
    }

    /// One shared block per section so consecutive paragraphs pad as one.
    private static func paddingBlock(top: CGFloat, bottom: CGFloat) -> NSTextBlock {
        let block = NSTextBlock()
        block.setValue(100, type: .percentageValueType, for: .width)
        block.setWidth(horizontalPadding, type: .absoluteValueType, for: .padding, edge: .minX)
        block.setWidth(horizontalPadding, type: .absoluteValueType, for: .padding, edge: .maxX)
        block.setWidth(top, type: .absoluteValueType, for: .padding, edge: .minY)
        block.setWidth(bottom, type: .absoluteValueType, for: .padding, edge: .maxY)
        return block
    }

    private func applyFooter(_ notes: [String]) {
        guard let theme else { return }
        let text = NSMutableAttributedString()
        for (index, note) in notes.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: "\n")) }
            text.append(NSAttributedString(string: "● ", attributes: [
                .font: NSFont.systemFont(ofSize: 7),
                .foregroundColor: theme.color(for: .number),
                .baselineOffset: 1.5,
            ]))
            text.append(NSAttributedString(string: note, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: theme.chromeSecondaryColor,
            ]))
        }
        footer.attributedStringValue = text
        footer.isHidden = notes.isEmpty
        footerDivider.isHidden = notes.isEmpty
    }

    private func showLinkInFooter(_ url: URL?) {
        guard let theme else { return }
        guard let url, url.scheme != symbolLinkScheme else {
            applyFooter(notes)
            relayout()
            return
        }
        let text = NSMutableAttributedString(string: "↗ ", attributes: [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: theme.accentColor,
        ])
        text.append(NSAttributedString(string: url.absoluteString, attributes: [
            .font: ReaderFontResolver.shared.resolve(theme: theme, size: 10.5).font,
            .foregroundColor: theme.chromeTertiaryColor,
        ]))
        footer.attributedStringValue = text
        footer.isHidden = false
        footerDivider.isHidden = false
        relayout()
    }

    private func relayout() {
        guard panel.isVisible else { return }
        var frame = panel.frame
        let size = layoutSize()
        // Grow downward from the top edge so the card never jumps away from
        // the pointer while it reads a link.
        frame.origin.y += frame.height - size.height
        frame.size = size
        panel.setFrame(frame, display: true)
        layoutSubviews(size: size)
    }

    // MARK: - Layout

    private var footerHeight: CGFloat {
        guard !footer.isHidden else { return 0 }
        return footer.sizeThatFits(NSSize(
            width: panel.frame.width - 2 * Self.horizontalPadding,
            height: .greatestFiniteMagnitude
        )).height + 12
    }

    private func layoutSize() -> NSSize {
        let width = preferredWidth()
        footer.preferredMaxLayoutWidth = width - 2 * Self.horizontalPadding
        let footerSize = footer.isHidden ? 0 : footer.sizeThatFits(NSSize(
            width: width - 2 * Self.horizontalPadding,
            height: .greatestFiniteMagnitude
        )).height + 12
        textView.frame.size.width = width
        textView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        var contentHeight: CGFloat = 0
        if let manager = textView.layoutManager, let container = textView.textContainer {
            manager.ensureLayout(for: container)
            contentHeight = ceil(manager.usedRect(for: container).height)
        }
        // A notes-only card is just its footer.
        if textView.textStorage?.length == 0 {
            return NSSize(width: width, height: max(footerSize, 24))
        }
        return NSSize(
            width: width,
            height: min(Self.maximumSize.height, contentHeight + footerSize)
        )
    }

    private func layoutSubviews(size: NSSize) {
        let footerSize = footer.isHidden ? 0 : footerHeight
        let hasContent = textView.textStorage?.length ?? 0 > 0
        scrollView.isHidden = !hasContent
        footerDivider.isHidden = footer.isHidden || !hasContent
        scrollView.frame = NSRect(x: 0, y: footerSize, width: size.width, height: size.height - footerSize)
        footerDivider.frame = NSRect(x: 0, y: footerSize - 1, width: size.width, height: 1)
        footer.frame = NSRect(
            x: Self.horizontalPadding,
            y: 6,
            width: size.width - 2 * Self.horizontalPadding,
            height: max(0, footerSize - 12)
        )
        textView.frame = NSRect(
            x: 0, y: 0,
            width: size.width,
            height: max(textView.frame.height, scrollView.contentSize.height)
        )
        textView.sizeToFit()
        textView.scroll(.zero)
    }

    /// Short content shrinks the card; long lines wrap at the maximum width.
    private func preferredWidth() -> CGFloat {
        guard let storage = textView.textStorage else { return Self.minimumWidth }
        var widest: CGFloat = 0
        let text = storage.string as NSString
        text.enumerateSubstrings(
            in: NSRange(location: 0, length: text.length),
            options: .byLines
        ) { _, range, _, _ in
            guard range.length > 0 else { return }
            let line = storage.attributedSubstring(from: range)
            widest = max(widest, ceil(line.size().width))
        }
        for note in notes {
            widest = max(widest, ceil((note as NSString).size(withAttributes: [
                .font: NSFont.systemFont(ofSize: 11),
            ]).width) + 14)
        }
        let padded = widest + 2 * Self.horizontalPadding + 12
        return min(Self.maximumSize.width, max(Self.minimumWidth, padded))
    }

    // MARK: - NSTextViewDelegate

    public func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        guard let url else { return false }
        onOpenLink?(url)
        return true
    }
}

/// Localized footer text for the card's notes.
public func symbolDocNoteText(_ note: SymbolDoc.Note) -> String {
    switch note {
    case .exactPending:
        localized("reader.hover.note.pending")
    case .exactUnavailable(let reason):
        localizedFormat("reader.hover.note.unavailable", reason)
    case .limitation("procMacrosDisabled"):
        localized("reader.hover.note.procMacros")
    case .limitation("buildScriptsDisabled"):
        localized("reader.hover.note.buildScripts")
    case .limitation("dependenciesUnavailableOffline"), .dependencySourceMissing:
        localized("reader.hover.note.dependencySource")
    case .limitation(let other):
        other
    }
}

private final class CardPanel: NSPanel {
    var escape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { escape?() }
}

private final class TrackingView: NSView {
    var entered: (() -> Void)?
    var exited: (() -> Void)?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        self.area = area
    }

    override func mouseEntered(with event: NSEvent) { entered?() }
    override func mouseExited(with event: NSEvent) { exited?() }
}

private final class CardTextView: NSTextView {
    var escape: (() -> Void)?
    var hoveredLink: ((URL?) -> Void)?
    private var lastLink: URL?
    private var linkArea: NSTrackingArea?

    override func cancelOperation(_ sender: Any?) {
        escape?()
    }

    /// One click follows a link even while the card is not key yet.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let linkArea { removeTrackingArea(linkArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        linkArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        var link: URL?
        if let storage = textStorage, index < storage.length,
           let manager = layoutManager, let container = textContainer
        {
            let glyph = manager.glyphIndexForCharacter(at: index)
            let rect = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            if rect.insetBy(dx: -1, dy: -1).contains(point) {
                let value = storage.attribute(.link, at: index, effectiveRange: nil)
                link = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
            }
        }
        if link != lastLink {
            lastLink = link
            hoveredLink?(link)
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if lastLink != nil {
            lastLink = nil
            hoveredLink?(nil)
        }
    }
}
