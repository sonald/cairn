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
        wrappingLabelWithString: "No excerpts could be frozen."
    )
    private var cards: [ReadingSetExcerptView] = []
    private var theme = ReaderTheme(settings: ReaderSettings())
    nonisolated(unsafe) private var scrollObserver: NSObjectProtocol?

    override var isFlipped: Bool { true }

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
                onScroll?(Double(scrollView.contentView.bounds.minY))
            }
        }
        scrollView.contentView.postsBoundsChangedNotifications = true
        apply(settings: ReaderSettings())
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
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
        titleLabel.stringValue = "Reading Set · \(title)"
        var subtitle = "\(excerpts.count) 段 · frozen at capture"
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
            card.display(excerpt, theme: theme)
            content.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
            return card
        }
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
        theme = ReaderTheme(settings: settings)
        layer?.backgroundColor = theme.backgroundColor.cgColor
        titleLabel.textColor = theme.foregroundColor
        subtitleLabel.textColor = theme.chromeSecondaryColor
        emptyLabel.textColor = theme.chromeSecondaryColor
        cards.forEach { $0.apply(theme: theme) }
    }

    func restoreScrollOffset(_ offset: Double?) {
        guard let offset else { return }
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, offset)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
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

    private let index: Int
    private let header = NSStackView()
    private let roleLabel = NSTextField(labelWithString: "")
    private let symbolLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let badge = ReadingSetChipView()
    private let caveat = ReadingSetChipView()
    private let provenance = ReadingSetChipView()
    private let codeScroll = NSScrollView()
    private let codeDocument = ReadingSetDocumentView()
    private let lineNumbers = NSTextField(labelWithString: "")
    private let codeView = NSTextView()
    private let openButton = NSButton()
    private let expandButton = NSButton()
    private let evidenceButton = NSButton()
    private let actions = NSStackView()
    private var excerpt: ReadingSetExcerpt?
    private var theme = ReaderTheme(settings: ReaderSettings())
    private var codeHeight: CGFloat = 40
    private var codeWidth: CGFloat = 1

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
        lineNumbers.alignment = .right
        lineNumbers.maximumNumberOfLines = 0
        lineNumbers.lineBreakMode = .byClipping
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
        configure(openButton, title: "打开完整文件", action: #selector(open(_:)))
        configure(expandButton, title: "扩大上下文", action: #selector(expand(_:)))
        configure(evidenceButton, title: "查看证据", action: #selector(evidence(_:)))
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
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func display(_ excerpt: ReadingSetExcerpt, theme: ReaderTheme) {
        self.excerpt = excerpt
        roleLabel.stringValue = excerpt.role.uppercased()
        symbolLabel.stringValue = excerpt.symbol
        pathLabel.stringValue = "\(excerpt.path):\(excerpt.line)"
        codeView.string = excerpt.sourceText
        let font = NSFont.monospacedSystemFont(
            ofSize: theme.fontSize,
            weight: .regular
        )
        let sourceLines = excerpt.sourceText.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        var nextLine = excerpt.firstLine
        lineNumbers.stringValue = sourceLines.map { sourceLine in
            guard sourceLine != "…" else { return "" }
            defer { nextLine &+= 1 }
            return String(nextLine)
        }.joined(separator: "\n")
        let lineHeight = font.boundingRectForFont.height
        codeHeight = ceil(lineHeight * CGFloat(max(1, sourceLines.count))) + 20
        codeWidth = ceil(sourceLines.map {
            ($0 as NSString).size(withAttributes: [.font: font]).width
        }.max() ?? 1) + 24
        codeScroll.heightAnchor.constraint(equalToConstant: codeHeight).isActive = true
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
        apply(theme: theme)
    }

    func apply(theme: ReaderTheme) {
        self.theme = theme
        layer?.backgroundColor = theme.chromeColor.cgColor
        layer?.borderColor = theme.chromeDividerColor.cgColor
        roleLabel.textColor = theme.accentColor
        symbolLabel.textColor = theme.foregroundColor
        pathLabel.textColor = theme.chromeSecondaryColor
        codeView.textColor = theme.foregroundColor
        codeView.font = .monospacedSystemFont(
            ofSize: theme.fontSize,
            weight: .regular
        )
        lineNumbers.font = .monospacedDigitSystemFont(
            ofSize: theme.fontSize,
            weight: .regular
        )
        lineNumbers.textColor = theme.chromeTertiaryColor
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

    override func layout() {
        super.layout()
        let gutterWidth: CGFloat = 42
        let innerHeight = max(1, codeHeight - 20)
        let documentWidth = max(
            codeScroll.contentSize.width,
            gutterWidth + 12 + codeWidth
        )
        codeDocument.frame = NSRect(
            x: 0,
            y: 0,
            width: documentWidth,
            height: codeHeight
        )
        lineNumbers.frame = NSRect(
            x: 0,
            y: 10,
            width: gutterWidth,
            height: innerHeight
        )
        codeView.frame = NSRect(
            x: gutterWidth + 12,
            y: 10,
            width: codeWidth,
            height: innerHeight
        )
    }

    var selfTestCodeState: (String, Bool, Bool) {
        (codeView.string, codeView.isSelectable, codeView.isEditable)
    }

    var selfTestCodeGeometry: (String, Bool, Bool) {
        (
            lineNumbers.stringValue,
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
