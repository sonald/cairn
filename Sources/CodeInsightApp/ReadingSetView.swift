@preconcurrency import AppKit
import CodeInsightAppModel
import CodeInsightReaderCore
import CodeInsightReaderUI

@MainActor
private final class ReadingSetDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class ReadingSetView: NSView {
    var onOpen: ((Int) -> Void)?
    var onExpand: ((Int) -> Void)?
    var onViewEvidence: ((Int) -> Void)?
    var onScroll: ((Double) -> Void)?

    private let scrollView = NSScrollView()
    private let documentView = ReadingSetDocumentView()
    private let content = NSStackView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(
        wrappingLabelWithString:
            "No excerpts could be frozen. Review the skipped reasons above."
    )
    private var cards: [ReadingSetExcerptView] = []
    private var theme = ReaderTheme(settings: ReaderSettings())
    private var settings = ReaderSettings()
    private var layoutPending = false
    private var updatingLayout = false
    private var lastWidth: CGFloat = -1
    private var anchor: (card: Int, location: Int?, offset: CGFloat, bottom: Bool)?
    nonisolated(unsafe) private var scrollEventMonitor: Any?
    nonisolated(unsafe) private var scrollObserver: NSObjectProtocol?

    override var isFlipped: Bool { true }
    private(set) var selfTestDrawCount = 0

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        selfTestDrawCount += 1
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        documentView.translatesAutoresizingMaskIntoConstraints = false
        content.orientation = .vertical
        content.alignment = .width
        content.spacing = 14
        content.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        subtitleLabel.font = .systemFont(ofSize: 11)
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        [titleLabel, subtitleLabel, emptyLabel].forEach(content.addArrangedSubview)
        addSubview(scrollView)
        documentView.addSubview(content)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            content.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 18),
            content.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 18),
            content.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -18),
            content.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -18),
            emptyLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
        setAccessibilityElement(false)
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.onScroll?(Double(self.scrollView.contentView.bounds.minY))
            }
        }
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if event.window === self?.window { self?.anchor = nil }
            }
            return event
        }
        apply(settings: ReaderSettings())
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let scrollEventMonitor { NSEvent.removeMonitor(scrollEventMonitor) }
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
        }
    }

    func display(
        title: String,
        excerpts: [ReadingSetExcerpt],
        canOpen: Bool = true,
        canExpand: Bool = true,
        canViewEvidence: Bool = true,
        openAvailability: [Bool]? = nil,
        expandAvailability: [Bool]? = nil,
        skippedReasons: [String] = []
    ) {
        anchor = nil
        titleLabel.stringValue = "Reading Set · \(title)"
        var subtitle = "\(excerpts.count) excerpts · frozen at capture · tab lifetime"
        if !skippedReasons.isEmpty {
            var order: [String] = []
            var counts: [String: Int] = [:]
            for reason in skippedReasons {
                if counts[reason] == nil { order.append(reason) }
                counts[reason, default: 0] += 1
            }
            let reasons = order.map { reason in
                let count = counts[reason, default: 0]
                return count == 1 ? reason : "\(reason) ×\(count)"
            }.joined(separator: "; ")
            subtitle += " · skipped \(skippedReasons.count) · \(reasons)"
        }
        subtitleLabel.stringValue = subtitle
        cards.forEach {
            content.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        cards = excerpts.enumerated().map { index, excerpt in
            let card = ReadingSetExcerptView(index: index)
            let openAvailable = openAvailability.map {
                $0.indices.contains(index) && $0[index]
            } ?? true
            let expandAvailable = expandAvailability.map {
                $0.indices.contains(index) && $0[index]
            } ?? true
            if canOpen && openAvailable {
                card.onOpen = { [weak self] in self?.onOpen?(index) }
            }
            if canExpand && expandAvailable {
                card.onExpand = { [weak self] in self?.onExpand?(index) }
            }
            if canViewEvidence {
                card.onViewEvidence = { [weak self] in
                    self?.onViewEvidence?(index)
                }
            }
            card.display(excerpt, settings: settings)
            content.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
            return card
        }
        requestLayout()
        emptyLabel.isHidden = !excerpts.isEmpty
        setAccessibilityLabel("Reading Set \(title)")
        let skippedValue = skippedReasons.isEmpty
            ? ""
            : ", skipped \(skippedReasons.count)"
        setAccessibilityValue(
            "\(excerpts.count) frozen excerpts\(skippedValue)"
        )
    }

    func apply(settings: ReaderSettings) {
        captureAnchor()
        self.settings = settings
        theme = ReaderTheme(settings: settings)
        layer?.backgroundColor = theme.backgroundColor.cgColor
        titleLabel.textColor = theme.foregroundColor
        subtitleLabel.textColor = theme.chromeSecondaryColor
        emptyLabel.textColor = theme.chromeSecondaryColor
        cards.forEach { $0.apply(settings: settings) }
        requestLayout()
    }

    func restoreScrollOffset(_ offset: Double?) {
        guard let offset else { return }
        anchor = nil
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, offset)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    override var isHidden: Bool {
        didSet {
            if isHidden { anchor = nil }
            else { requestLayout() }
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        if newSize.width != frame.width { captureAnchor() }
        super.setFrameSize(newSize)
    }

    override func layout() {
        super.layout()
        let width = scrollView.contentView.bounds.width
        if width != lastWidth && !updatingLayout {
            captureAnchor()
            requestLayout()
        }
    }

    private func captureAnchor() {
        guard anchor == nil, !updatingLayout, !isHidden, cards.contains(where: { $0.measurements > 0 }) else { return }
        anchor = viewportAnchor()
    }

    private func viewportAnchor() -> (card: Int, location: Int?, offset: CGFloat, bottom: Bool)? {
        let top = scrollView.contentView.bounds.minY
        guard let index = cards.firstIndex(where: { $0.convert($0.bounds, to: documentView).maxY > top }) else { return nil }
        let card = cards[index]
        let point = card.convert(NSPoint(x: 0, y: top), from: documentView)
        if let row = card.row(at: point.y) {
            let y = card.convert(NSPoint(x: 0, y: row.y), to: documentView).y
            return (index, row.location, y - top, false)
        }
        let bottom = point.y > card.codeView.convert(card.codeView.bounds, to: card).maxY
        let reference = NSPoint(x: 0, y: bottom ? card.bounds.height : 0)
        return (index, nil, card.convert(reference, to: documentView).y - top, bottom)
    }

    private func requestLayout() {
        guard !layoutPending else { return }
        layoutPending = true
        DispatchQueue.main.async { [weak self] in self?.selfTestFlushLayout() }
    }

    func selfTestFlushLayout() {
        guard layoutPending, !updatingLayout else { return }
        layoutPending = false
        guard bounds.width > 0 else { return }
        updatingLayout = true
        layoutSubtreeIfNeeded()
        scrollView.tile()
        lastWidth = scrollView.contentView.bounds.width
        for card in cards { card.measure() }
        layoutSubtreeIfNeeded()
        if let saved = anchor, cards.indices.contains(saved.card), !isHidden {
            let card = cards[saved.card]
            let localY = saved.location.flatMap { card.y(for: $0) } ?? (saved.bottom ? card.bounds.height : 0)
            let y = card.convert(NSPoint(x: 0, y: localY), to: documentView).y - saved.offset
            let maxY = max(0, documentView.bounds.height - scrollView.contentView.bounds.height)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, y), maxY)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        updatingLayout = false
        if scrollView.contentView.bounds.width != lastWidth { requestLayout() }
        needsDisplay = true
    }

    var selfTestGutterLabels: [[String]] { cards.map { $0.gutterLabels } }
    var selfTestCodeViews: [NSTextView] { cards.map(\.codeView) }
    var selfTestTextViews: [NSTextView] { selfTestCodeViews }
    var selfTestCodeScrollViews: [NSScrollView] { cards.map(\.codeScroll) }
    var selfTestScrollView: NSScrollView { scrollView }
    var selfTestMeasurementCount: Int { cards.reduce(0) { $0 + $1.measurements } }
    var selfTestLayoutPending: Bool { layoutPending }
    var selfTestViewportAnchor: (card: Int, location: Int?, offset: CGFloat)? {
        guard let saved = anchor ?? viewportAnchor(), cards.indices.contains(saved.card) else { return nil }
        let card = cards[saved.card]
        let localY = saved.location.flatMap { card.y(for: $0) } ?? (saved.bottom ? card.bounds.height : 0)
        let y = card.convert(NSPoint(x: 0, y: localY), to: documentView).y
        return (saved.card, saved.location, y - scrollView.contentView.bounds.minY)
    }
    var selfTestLayoutState: [(measurements: Int, heightConstraints: Int, contentBottom: CGFloat, documentHeight: CGFloat)] {
        // The scroll view also owns constraints for its scroller/clip children.
        cards.map { card in
            (card.measurements, card.codeScroll.constraints.filter {
                $0.firstItem === card.codeScroll && $0.firstAttribute == .height
                    && $0.relation == .equal && $0.secondItem == nil && $0.isActive
            }.count, card.textBottom + 10, card.codeDocument.bounds.height)
        }
    }

    var scrollOffset: Double {
        Double(scrollView.contentView.bounds.minY)
    }

    var selfTestTitle: String { titleLabel.stringValue }
    var selfTestSubtitle: String { subtitleLabel.stringValue }
    var selfTestEmptyVisible: Bool { !emptyLabel.isHidden }
    var selfTestCardCount: Int { cards.count }
    var selfTestCardFrames: [NSRect] {
        layoutSubtreeIfNeeded()
        return cards.map { $0.convert($0.bounds, to: documentView) }
    }
    var selfTestCardAccessibility: [(String, String)] {
        cards.map {
            ($0.accessibilityLabel() ?? "", $0.accessibilityValue() as? String ?? "")
        }
    }
    var selfTestCodeState: [(String, Bool, Bool)] {
        cards.map(\.selfTestCodeState)
    }
    var selfTestCodeGeometry: [(String, Bool, Bool)] {
        cards.map(\.selfTestCodeGeometry)
    }
    var selfTestActionState: [[(String, Bool, Bool)]] {
        cards.map(\.selfTestActionState)
    }
}

@MainActor
private final class ReadingSetExcerptView: NSView {
    var onOpen: (() -> Void)?
    var onExpand: (() -> Void)?
    var onViewEvidence: (() -> Void)?

    override var isFlipped: Bool { true }

    private let index: Int
    private let header = NSStackView()
    private let roleLabel = NSTextField(labelWithString: "")
    private let symbolLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let badge = ReadingSetChipView()
    private let caveat = ReadingSetChipView()
    private let provenance = ReadingSetChipView()
    let codeScroll = NSScrollView()
    let codeDocument = ReadingSetDocumentView()
    private let lineNumbers = ReadingSetGutterView()
    let codeView = NSTextView(usingTextLayoutManager: true)
    private let openButton = NSButton()
    private let expandButton = NSButton()
    private let evidenceButton = NSButton()
    private let actions = NSStackView()
    private var excerpt: ReadingSetExcerpt?
    private var theme = ReaderTheme(settings: ReaderSettings())
    private var codeHeight: CGFloat = 40
    private var settings = ReaderSettings()
    private var signature: [CGFloat] = []
    private var rows: [(range: NSRange, rect: NSRect)] = []
    private var sourceLabels: [(offset: Int, label: String)] = []
    private var unwrappedX: CGFloat = 0
    private var codeScrollHeightConstraint: NSLayoutConstraint!
    private let paragraphLayout = ReaderParagraphLayout()
    private(set) var measurements = 0
    private(set) var textBottom: CGFloat = 0

    init(index: Int) {
        self.index = index
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        roleLabel.font = .systemFont(ofSize: 9.5, weight: .bold)
        symbolLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        pathLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        [roleLabel, symbolLabel, pathLabel, spacer, badge, caveat, provenance]
            .forEach(header.addArrangedSubview)
        codeScroll.documentView = codeDocument
        codeScroll.hasVerticalScroller = false
        codeScroll.hasHorizontalScroller = true
        codeScroll.autohidesScrollers = true
        codeScroll.drawsBackground = false
        codeScroll.borderType = .noBorder
        codeView.isEditable = false
        codeView.isSelectable = true
        codeView.isRichText = false
        codeView.drawsBackground = false
        codeView.textContainerInset = .zero
        codeView.isVerticallyResizable = false
        codeView.isHorizontallyResizable = true
        codeView.textContainer?.widthTracksTextView = false
        codeView.textContainer?.heightTracksTextView = false
        codeView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        codeView.setAccessibilityLabel("Frozen source excerpt")
        codeDocument.addSubview(lineNumbers)
        codeDocument.addSubview(codeView)
        configure(openButton, title: "Open File", action: #selector(open(_:)))
        configure(expandButton, title: "Expand Context", action: #selector(expand(_:)))
        configure(evidenceButton, title: "View Evidence", action: #selector(evidence(_:)))
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 12
        [openButton, expandButton, evidenceButton].forEach(actions.addArrangedSubview)
        let stack = NSStackView(views: [header, codeScroll, actions])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.heightAnchor.constraint(equalToConstant: 34),
            actions.heightAnchor.constraint(equalToConstant: 32),
        ])
        codeScrollHeightConstraint = codeScroll.heightAnchor.constraint(equalToConstant: 40)
        codeScrollHeightConstraint.isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func display(_ excerpt: ReadingSetExcerpt, settings: ReaderSettings) {
        paragraphLayout.reset()
        self.excerpt = excerpt
        roleLabel.stringValue = excerpt.role.uppercased()
        symbolLabel.stringValue = excerpt.symbol
        pathLabel.stringValue = "\(excerpt.path):\(excerpt.line)"
        codeView.string = excerpt.sourceText
        var nextLine = excerpt.firstLine
        var offset = 0
        sourceLabels = excerpt.sourceText.components(separatedBy: "\n").map { line in
            defer { offset += line.utf16.count + 1 }
            guard line != "…" && line != "…\r" else { return (offset, "") }
            defer { nextLine &+= 1 }
            return (offset, String(nextLine))
        }
        signature = []
        openButton.isHidden = excerpt.sourceKind == .dependencyCaptured
        openButton.isEnabled = onOpen != nil
        expandButton.isEnabled = onExpand != nil
        evidenceButton.isEnabled = onViewEvidence != nil
        setAccessibilityLabel(
            "\(excerpt.role), \(excerpt.symbol), \(excerpt.path) line \(excerpt.line)"
        )
        setAccessibilityValue(
            "\(excerpt.inspector.badge.rawValue), \(provenanceText(excerpt))"
        )
        apply(settings: settings)
    }

    func apply(settings: ReaderSettings) {
        self.settings = settings
        let theme = ReaderTheme(settings: settings)
        self.theme = theme
        layer?.backgroundColor = theme.chromeColor.cgColor
        layer?.borderColor = theme.chromeDividerColor.cgColor
        roleLabel.textColor = theme.accentColor
        symbolLabel.textColor = theme.foregroundColor
        pathLabel.textColor = theme.chromeSecondaryColor
        codeView.textColor = theme.foregroundColor
        let font = NSFont.monospacedSystemFont(ofSize: theme.fontSize, weight: .regular)
        if codeView.font != font { codeView.font = font }
        lineNumbers.font = .monospacedDigitSystemFont(
            ofSize: theme.fontSize,
            weight: .regular
        )
        lineNumbers.textColor = theme.chromeTertiaryColor
        lineNumbers.needsDisplay = true
        guard let excerpt else { return }
        switch excerpt.inspector.badge {
        case .verified:
            badge.display(
                "VERIFIED",
                foreground: theme.verifiedColor,
                background: theme.verifiedBackgroundColor,
                border: theme.verifiedBackgroundColor
            )
        case .inferred:
            badge.display(
                "INFERRED",
                foreground: theme.inferredColor,
                background: theme.inferredBackgroundColor,
                border: theme.inferredBackgroundColor
            )
        case .unresolved:
            badge.display(
                "UNRESOLVED",
                foreground: theme.unresolvedColor,
                background: .clear,
                border: theme.unresolvedBorderColor
            )
        }
        caveat.display(
            excerpt.caveat,
            foreground: theme.warningColor,
            background: .clear,
            border: theme.warningColor
        )
        let dependency = excerpt.sourceKind == .dependencyCaptured
        provenance.display(
            provenanceText(excerpt),
            foreground: dependency ? theme.chromeSecondaryColor : theme.accentColor,
            background: .clear,
            border: dependency ? theme.chromeTertiaryColor : theme.accentColor,
            dashed: dependency
        )
        for button in [openButton, expandButton, evidenceButton] {
            button.contentTintColor = theme.accentColor
        }
    }

    private func provenanceText(_ excerpt: ReadingSetExcerpt) -> String {
        switch excerpt.sourceKind {
        case .projectCommit:
            "project · \(excerpt.revision.map { String($0.prefix(7)) } ?? "captured")"
        case .worktreeCaptured: "worktree · captured"
        case .dependencyCaptured: "dependency · captured"
        }
    }

    private func configure(_ button: NSButton, title: String, action: Selector) {
        button.title = title
        button.bezelStyle = .inline
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.target = self
        button.action = action
    }

    @objc private func open(_ sender: Any?) { onOpen?() }
    @objc private func expand(_ sender: Any?) { onExpand?() }
    @objc private func evidence(_ sender: Any?) { onViewEvidence?() }

    func measure() {
        guard bounds.width > 0, let manager = codeView.textLayoutManager,
              let content = manager.textContentManager else { return }
        let font = NSFont.monospacedSystemFont(ofSize: theme.fontSize, weight: .regular)
        let gutterWidth = ceil(sourceLabels.map { ($0.label as NSString).size(withAttributes: [.font: lineNumbers.font]).width }.max() ?? 0) + 8
        let nextSignature: [CGFloat] = [bounds.width, settings.wrapLines ? 1 : 0, CGFloat(theme.fontSize),
                                         CGFloat(settings.lineHeightMultiple), gutterWidth,
                                         CGFloat(codeScroll.scrollerStyle.rawValue)]
        guard nextSignature != signature else { return }
        signature = nextSignature
        measurements += 1
        let selected = codeView.selectedRanges
        let affinity = codeView.selectionAffinity
        if codeScroll.hasHorizontalScroller {
            unwrappedX = codeScroll.contentView.bounds.minX
        }
        codeScroll.hasHorizontalScroller = !settings.wrapLines
        codeScroll.tile()
        let available = max(1, codeScroll.contentSize.width - gutterWidth - 12)
        codeView.isHorizontallyResizable = !settings.wrapLines
        codeView.autoresizingMask = settings.wrapLines ? [.width] : []
        codeView.textContainer?.widthTracksTextView = settings.wrapLines
        codeView.frame.size.width = available
        codeView.textContainer?.containerSize = NSSize(width: settings.wrapLines ? available : CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = CGFloat(settings.lineHeightMultiple)
        paragraph.lineBreakMode = .byWordWrapping
        codeView.textStorage?.addAttributes([.font: font, .paragraphStyle: paragraph], range: NSRange(location: 0, length: codeView.string.utf16.count))
        if let storage = codeView.textStorage {
            paragraphLayout.apply(to: storage, wrap: settings.wrapLines,
                width: available - 2 * (codeView.textContainer?.lineFragmentPadding ?? 0), font: font)
        }
        manager.invalidateLayout(for: content.documentRange)
        manager.ensureLayout(for: content.documentRange)
        rows = []
        var usedWidth: CGFloat = 0
        textBottom = 0
        manager.enumerateTextLayoutFragments(from: content.documentRange.location, options: [.ensuresLayout, .ensuresExtraLineFragment]) { fragment in
            let start = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            for line in fragment.textLineFragments {
                let rect = line.typographicBounds.offsetBy(dx: fragment.layoutFragmentFrame.minX, dy: fragment.layoutFragmentFrame.minY)
                self.rows.append((NSRange(location: start + line.characterRange.location, length: line.characterRange.length), rect))
                usedWidth = max(usedWidth, rect.maxX)
                self.textBottom = max(self.textBottom, rect.maxY)
            }
            return true
        }
        let textHeight = max(ceil(textBottom), ceil(font.ascender - font.descender))
        let textWidth = settings.wrapLines ? available : max(available, ceil(usedWidth) + 2 * (codeView.textContainer?.lineFragmentPadding ?? 5))
        codeView.frame = NSRect(x: gutterWidth + 12, y: 10, width: textWidth, height: textHeight)
        codeDocument.frame = NSRect(x: 0, y: 0, width: max(codeScroll.contentSize.width, gutterWidth + 12 + textWidth), height: textHeight + 20)
        lineNumbers.frame = NSRect(x: 0, y: 10, width: gutterWidth, height: textHeight)
        lineNumbers.labels = sourceLabels.compactMap { source in
            guard !source.label.isEmpty, let row = rows.first(where: { $0.range.location == source.offset }) else { return nil }
            return (source.label, row.rect)
        }
        lineNumbers.needsDisplay = true
        codeScroll.tile()
        let scrollerHeight = max(0, codeScroll.bounds.height - codeScroll.contentSize.height)
        codeHeight = textHeight + 20 + scrollerHeight
        codeScrollHeightConstraint.constant = codeHeight
        codeView.setSelectedRanges(selected, affinity: affinity, stillSelecting: false)
        let x = settings.wrapLines ? 0 : min(unwrappedX, max(0, codeDocument.bounds.width - codeScroll.contentSize.width))
        codeScroll.contentView.scroll(to: NSPoint(x: x, y: 0))
        codeScroll.reflectScrolledClipView(codeScroll.contentView)
    }

    func row(at y: CGFloat) -> (location: Int, y: CGFloat)? {
        let local = codeView.convert(NSPoint(x: 0, y: y), from: self).y
        guard local >= 0, local <= codeView.bounds.height,
              let row = rows.first(where: { $0.rect.maxY > local }) else { return nil }
        return (row.range.location, codeView.convert(NSPoint(x: 0, y: row.rect.minY), to: self).y)
    }

    func y(for location: Int) -> CGFloat? {
        guard let row = rows.first(where: { NSLocationInRange(location, $0.range) || ($0.range.length == 0 && $0.range.location == location) }) else { return nil }
        return codeView.convert(NSPoint(x: 0, y: row.rect.minY), to: self).y
    }

    var gutterLabels: [String] { lineNumbers.labels.map(\.0) }

    var selfTestCodeState: (String, Bool, Bool) {
        (codeView.string, codeView.isSelectable, codeView.isEditable)
    }

    var selfTestCodeGeometry: (String, Bool, Bool) {
        (
            sourceLabels.map(\.label).joined(separator: "\n"),
            codeView.textContainer?.widthTracksTextView == false,
            codeScroll.hasHorizontalScroller
        )
    }

    var selfTestActionState: [(String, Bool, Bool)] {
        [openButton, expandButton, evidenceButton].map {
            ($0.title, $0.isHidden, $0.isEnabled)
        }
    }
}

@MainActor
private final class ReadingSetGutterView: NSView {
    var labels: [(String, NSRect)] = []
    var font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    var textColor = NSColor.secondaryLabelColor
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for (label, row) in labels where row.intersects(dirtyRect) {
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
            let size = (label as NSString).size(withAttributes: attributes)
            (label as NSString).draw(at: NSPoint(x: bounds.width - size.width - 4, y: row.minY + (row.height - size.height) / 2), withAttributes: attributes)
        }
    }
}

@MainActor
private final class ReadingSetChipView: NSStackView {
    private let label = NSTextField(labelWithString: "")
    private let dashedBorder = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        orientation = .horizontal
        alignment = .centerY
        edgeInsets = NSEdgeInsets(top: 1, left: 5, bottom: 1, right: 5)
        wantsLayer = true
        layer?.cornerRadius = 4
        label.font = .systemFont(ofSize: 9.5, weight: .medium)
        addArrangedSubview(label)
        dashedBorder.fillColor = NSColor.clear.cgColor
        dashedBorder.lineWidth = 1
        dashedBorder.lineDashPattern = [3, 2]
        layer?.addSublayer(dashedBorder)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func display(
        _ text: String?,
        foreground: NSColor,
        background: NSColor,
        border: NSColor,
        dashed: Bool = false
    ) {
        label.stringValue = text ?? ""
        label.textColor = foreground
        layer?.backgroundColor = background.cgColor
        layer?.borderColor = border.cgColor
        layer?.borderWidth = dashed ? 0 : 1
        dashedBorder.strokeColor = border.cgColor
        dashedBorder.isHidden = !dashed
        isHidden = text == nil
    }

    override func layout() {
        super.layout()
        dashedBorder.frame = bounds
        dashedBorder.path = CGPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            cornerWidth: 4,
            cornerHeight: 4,
            transform: nil
        )
    }
}
