import AppKit
import CodeInsightAppModel
import CodeInsightCore
import CodeInsightReaderCore
import CodeInsightReaderUI
import Observation
import PDFKit
import WebKit

@MainActor
final class ContextWindowViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var selfTestReaderDrawCount: Int { miniReader.backgroundDrawCount }
    var onOpen: ((ContextWindowModel.Candidate) -> Void)?
    /// R5.2: open the enclosing scope at its signature line.
    var onOpenEnclosing: ((String, UInt32) -> Void)?
    /// Fired after the tracking control changes, so the window can feed the
    /// current caret to the enclosing mode right away.
    var onTrackingChange: (() -> Void)?

    private let model: ContextWindowModel
    private let modeControl = NSSegmentedControl(
        labels: [localized("lens.trackSymbol"), localized("lens.trackEnclosing")],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    /// R6.1: the pin is an independent button next to the two-segment
    /// tracking control.
    private let pinButton = NSButton(title: "", target: nil, action: nil)
    /// R5: the enclosing mode's header — kind badge, serif name, path.
    private let enclosingKindLabel = NSTextField(labelWithString: "")
    private let enclosingNameLabel = NSTextField(labelWithString: "")
    /// R4.3: the "caret on no symbol" corner note.
    private let previousTokenNoteLabel = NSTextField(labelWithString: "")
    /// R5.2: the fade + body-size line under the mini reader.
    private let enclosingBodyNoteLabel = NSTextField(labelWithString: "")
    private let previousButton = NSButton(title: "‹", target: nil, action: nil)
    private let countLabel = NSTextField(labelWithString: "")
    private let nextButton = NSButton(title: "›", target: nil, action: nil)
    private let pathLabel = NSTextField(labelWithString: "")
    private let symbolLabel = NSTextField(labelWithString: "")
    private let typeHopViaButton = NSButton(title: "", target: nil, action: nil)
    private let typeHopArrowLabel = NSTextField(labelWithString: "→")
    private let typeHopTargetButton = NSButton(title: "", target: nil, action: nil)
    private let typeHopBoundLabel = NSTextField(labelWithString: "")
    private lazy var typeHopLabel: NSStackView = NSStackView(views: [
        typeHopViaButton, typeHopArrowLabel, typeHopTargetButton, typeHopBoundLabel,
    ])
    private let stones = CertaintyStonesView(
        certainty: .possible, theme: ReaderTheme(settings: ReaderSettings()), size: 14
    )
    private let candidateLabel = NSTextField(labelWithString: "")
    private let candidateBadge = NSView()
    private let placeholderLabel = NSTextField(
        labelWithString:
            localized("main.click.a.symbol.to.see.its.definition.here.click.jumps.to.it")
    )
    private let scrollView = NSScrollView()
    private let miniReader: ReaderTextView
    private var isClosing = false
    private let container = NSView()
    private let headerSurface = NSView()
    private var theme = ReaderTheme(settings: ReaderSettings())
    /// The left column: every candidate, so choosing is a click rather than
    /// stepping with ‹ ›. Shown only when there is more than one.
    private let candidateTable = NSTableView()
    private let candidateScroll = NSScrollView()
    private var listedCandidates: [ContextWindowModel.Candidate] = []
    private var excerptBesideList: NSLayoutConstraint?
    private var excerptFullWidth: NSLayoutConstraint?
    private var isSyncingListSelection = false
    private static let candidateListWidth: CGFloat = 240

    func setHighlightedNames(_ names: [String: UInt8]) {
        miniReader.setHighlightedNames(names)
    }

    init(model: ContextWindowModel, derivedDataStore: ReaderDerivedDataStore = ReaderDerivedDataStore()) {
        miniReader = ReaderTextView(derivedDataStore: derivedDataStore)
        self.model = model
        super.init(nibName: nil, bundle: nil)
        miniReader.onIdentifierPreparationChanged = { [weak miniReader] state in
            let notice = readerIdentifierPreparationNotice(state)
            miniReader?.view.setAccessibilityHelp(notice)
            miniReader?.view.toolTip = notice
        }
    }

    /// Terminal window teardown: later model observations must not redisplay the excerpt.
    func cancelDerivedDataSubscription() {
        isClosing = true
        miniReader.stopPendingReaderWork()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(settings: ReaderSettings) {
        theme = ReaderTheme(settings: settings)
        miniReader.apply(settings: settings)
        if isViewLoaded {
            container.layer?.backgroundColor = theme.chromeColor.cgColor
            applyHeaderStyle()
            view.needsDisplay = true
        }
        applyBadgeStyle()
    }

    /// Pinned is a state the reader must not forget: the header turns amber.
    private func applyHeaderStyle() {
        let pinned = model.isPinned
        headerSurface.layer?.backgroundColor = (pinned
            ? theme.amberSoftColor : theme.chromeHeaderColor).cgColor
        modeControl.selectedSegmentBezelColor = theme.accentColor
        pinButton.image = NSImage(
            systemSymbolName: pinned ? "pin.fill" : "pin",
            accessibilityDescription: localized("lens.togglePin")
        )
        pinButton.contentTintColor = pinned
            ? theme.amberMarkColor : theme.chromeSecondaryColor
        symbolLabel.textColor = theme.foregroundColor
        pathLabel.textColor = theme.chromeSecondaryColor
        countLabel.textColor = theme.chromeSecondaryColor
        placeholderLabel.textColor = theme.chromeSecondaryColor
    }

    var selfTestLensStyle: (headerFill: CGColor?, stones: Certainty?, stonesVisible: Bool,
                            symbol: String, symbolFont: NSFont?, badgeFill: CGColor?) {
        loadViewIfNeeded()
        return (
            headerSurface.layer?.backgroundColor,
            stones.isHidden ? nil : stones.certainty,
            stones.window != nil && !stones.isHiddenOrHasHiddenAncestor && stones.frame.width > 0,
            symbolLabel.stringValue,
            symbolLabel.font,
            candidateBadge.layer?.backgroundColor
        )
    }

    func selfTestSetPinned(_ pinned: Bool) {
        loadViewIfNeeded()
        pinButton.state = pinned ? .on : .off
        togglePin(pinButton)
    }

    var selfTestSummary: String? {
        loadViewIfNeeded()
        return pathLabel.stringValue.isEmpty ? nil : pathLabel.stringValue
    }

    var selfTestProvenance: String? {
        loadViewIfNeeded()
        return candidateLabel.stringValue.isEmpty
            ? nil : candidateLabel.stringValue
    }

    var selfTestProvenanceTooltip: String? {
        loadViewIfNeeded()
        return candidateLabel.toolTip
    }

    var selfTestCandidateCount: Int {
        loadViewIfNeeded()
        return Int(countLabel.stringValue.split(separator: "/").last ?? "") ?? 0
    }

    var selfTestPinned: Bool {
        loadViewIfNeeded()
        return pinButton.state == .on
    }

    /// P3.3 self-test readouts.
    var selfTestTracking: String {
        loadViewIfNeeded()
        return modeControl.selectedSegment == 1 ? "enclosing" : "symbol"
    }

    var selfTestEnclosingTitle: String? {
        loadViewIfNeeded()
        return enclosingNameLabel.stringValue.isEmpty ? nil : enclosingNameLabel.stringValue
    }

    var selfTestShowsPreviousTokenNote: Bool {
        loadViewIfNeeded()
        return !previousTokenNoteLabel.isHidden
    }

    var selfTestPlaceholderText: String? {
        loadViewIfNeeded()
        return placeholderLabel.stringValue
    }
    var selfTestPlaceholderVisible: Bool {
        loadViewIfNeeded()
        return placeholderLabel.selfTestIsVisibleInWindow
    }
    var selfTestReaderVisible: Bool {
        loadViewIfNeeded()
        return scrollView.selfTestIsVisibleInWindow
    }
    var selfTestCandidateVisibleWithGeometry: Bool {
        guard candidateBadge.window != nil,
              view.window != nil,
              !candidateBadge.isHiddenOrHasHiddenAncestor,
              candidateBadge.bounds.width > 0,
              candidateBadge.bounds.height > 0
        else { return false }
        let frame = candidateBadge.convert(candidateBadge.bounds, to: view)
        return view.bounds.contains(frame)
            && scrollView.selfTestIsVisibleInWindow
    }
    var selfTestHasDoubleClickOpen: Bool {
        miniReader.view.gestureRecognizers.contains {
            ($0 as? NSClickGestureRecognizer)?.numberOfClicksRequired == 2
        }
    }

    override func loadView() {
        modeControl.selectedSegment = 0
        modeControl.target = self
        modeControl.action = #selector(trackingChanged(_:))
        pinButton.bezelStyle = .texturedRounded
        pinButton.imagePosition = .imageOnly
        pinButton.image = NSImage(
            systemSymbolName: "pin",
            accessibilityDescription: localized("lens.togglePin")
        )
        pinButton.contentTintColor = nil
        pinButton.target = self
        pinButton.action = #selector(togglePin(_:))
        pinButton.setButtonType(.toggle)
        pinButton.setAccessibilityLabel(localized("lens.togglePin"))
        previousButton.target = self
        previousButton.action = #selector(selectPrevious(_:))
        nextButton.target = self
        nextButton.action = #selector(selectNext(_:))
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        symbolLabel.font = cairnSerifFont(ofSize: 15, weight: .medium)
        symbolLabel.lineBreakMode = .byTruncatingTail
        symbolLabel.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)
        // One-hop label (P1.5): `viaText → TypeName (T: Read)`, both ends
        // clickable to switch the displayed side.
        typeHopViaButton.isBordered = false
        typeHopViaButton.imagePosition = .noImage
        typeHopViaButton.setButtonType(.momentaryChange)
        typeHopViaButton.contentTintColor = nil
        typeHopViaButton.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        typeHopViaButton.lineBreakMode = .byTruncatingTail
        typeHopViaButton.target = self
        typeHopViaButton.action = #selector(showTypeHopDeclaration(_:))
        typeHopTargetButton.isBordered = false
        typeHopTargetButton.imagePosition = .noImage
        typeHopTargetButton.setButtonType(.momentaryChange)
        typeHopTargetButton.font = cairnSerifFont(ofSize: 15, weight: .medium)
        typeHopTargetButton.lineBreakMode = .byTruncatingTail
        typeHopTargetButton.target = self
        typeHopTargetButton.action = #selector(showTypeHopType(_:))
        typeHopArrowLabel.font = .systemFont(ofSize: 12, weight: .regular)
        typeHopArrowLabel.textColor = theme.chromeTertiaryColor
        typeHopBoundLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        typeHopBoundLabel.textColor = theme.chromeTertiaryColor
        enclosingKindLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        enclosingKindLabel.textColor = theme.chromeSecondaryColor
        enclosingNameLabel.font = cairnSerifFont(ofSize: 15, weight: .medium)
        enclosingNameLabel.lineBreakMode = .byTruncatingTail
        enclosingNameLabel.textColor = theme.foregroundColor
        previousTokenNoteLabel.font = .systemFont(ofSize: 10)
        previousTokenNoteLabel.textColor = theme.chromeTertiaryColor
        previousTokenNoteLabel.alignment = .right
        previousTokenNoteLabel.stringValue = localized("lens.previousTokenNote")
        previousTokenNoteLabel.isHidden = true
        enclosingBodyNoteLabel.font = .systemFont(ofSize: 11)
        enclosingBodyNoteLabel.textColor = theme.chromeSecondaryColor
        enclosingBodyNoteLabel.alignment = .left
        enclosingBodyNoteLabel.isHidden = true
        typeHopLabel.orientation = .horizontal
        typeHopLabel.alignment = .firstBaseline
        typeHopLabel.spacing = 4
        typeHopLabel.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)
        stones.isHidden = true
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)

        candidateBadge.wantsLayer = true
        candidateBadge.layer?.cornerRadius = 4
        candidateLabel.font = .systemFont(ofSize: 12, weight: .medium)
        candidateLabel.lineBreakMode = .byTruncatingTail
        candidateLabel.cell?.truncatesLastVisibleLine = true
        candidateLabel.cell?.wraps = false
        // Long provenance must truncate, not demand pane width.
        candidateLabel.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        candidateLabel.setContentHuggingPriority(
            .defaultLow,
            for: .horizontal
        )
        candidateLabel.translatesAutoresizingMaskIntoConstraints = false
        candidateBadge.addSubview(candidateLabel)
        NSLayoutConstraint.activate([
            candidateLabel.leadingAnchor.constraint(
                equalTo: candidateBadge.leadingAnchor,
                constant: 6
            ),
            candidateLabel.trailingAnchor.constraint(
                equalTo: candidateBadge.trailingAnchor,
                constant: -6
            ),
            candidateLabel.topAnchor.constraint(
                equalTo: candidateBadge.topAnchor,
                constant: 2
            ),
            candidateLabel.bottomAnchor.constraint(
                equalTo: candidateBadge.bottomAnchor,
                constant: -2
            ),
        ])

        let header = NSStackView(views: [
            modeControl,
            pinButton,
            previousButton,
            countLabel,
            nextButton,
            symbolLabel,
            typeHopLabel,
            enclosingKindLabel,
            enclosingNameLabel,
            pathLabel,
            stones,
            candidateBadge,
        ])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false
        headerSurface.wantsLayer = true
        headerSurface.layer?.backgroundColor = theme.chromeHeaderColor.cgColor
        headerSurface.translatesAutoresizingMaskIntoConstraints = false
        headerSurface.addSubview(header)

        scrollView.documentView = miniReader.view
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("candidate"))
        column.resizingMask = .autoresizingMask
        candidateTable.addTableColumn(column)
        candidateTable.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        candidateTable.headerView = nil
        candidateTable.style = .plain
        candidateTable.rowSizeStyle = .custom
        candidateTable.intercellSpacing = .zero
        candidateTable.backgroundColor = .clear
        candidateTable.dataSource = self
        candidateTable.delegate = self
        candidateTable.setAccessibilityLabel(localized("main.lens.candidates"))
        candidateScroll.documentView = candidateTable
        candidateScroll.hasVerticalScroller = true
        candidateScroll.drawsBackground = false
        candidateScroll.borderType = .noBorder
        candidateScroll.isHidden = true
        candidateScroll.translatesAutoresizingMaskIntoConstraints = false

        placeholderLabel.font = .systemFont(ofSize: 12)
        placeholderLabel.textColor = theme.chromeSecondaryColor
        placeholderLabel.alignment = .center
        placeholderLabel.lineBreakMode = .byWordWrapping
        placeholderLabel.maximumNumberOfLines = 2
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false

        container.wantsLayer = true
        container.layer?.backgroundColor = theme.chromeColor.cgColor
        container.addSubview(headerSurface)
        container.addSubview(candidateScroll)
        container.addSubview(scrollView)
        container.addSubview(placeholderLabel)
        container.addSubview(previousTokenNoteLabel)
        container.addSubview(enclosingBodyNoteLabel)
        excerptBesideList = scrollView.leadingAnchor.constraint(equalTo: candidateScroll.trailingAnchor, constant: 1)
        excerptFullWidth = scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor)
        excerptFullWidth?.isActive = true
        NSLayoutConstraint.activate([
            candidateScroll.topAnchor.constraint(equalTo: headerSurface.bottomAnchor),
            candidateScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            candidateScroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            candidateScroll.widthAnchor.constraint(equalToConstant: Self.candidateListWidth),
            headerSurface.topAnchor.constraint(equalTo: container.topAnchor),
            headerSurface.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            headerSurface.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            headerSurface.heightAnchor.constraint(equalToConstant: 34),
            header.leadingAnchor.constraint(equalTo: headerSurface.leadingAnchor, constant: 8),
            header.trailingAnchor.constraint(equalTo: headerSurface.trailingAnchor, constant: -8),
            header.centerYAnchor.constraint(equalTo: headerSurface.centerYAnchor),
            scrollView.topAnchor.constraint(equalTo: headerSurface.bottomAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            placeholderLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            placeholderLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: container.leadingAnchor,
                constant: 16
            ),
            placeholderLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: container.trailingAnchor,
                constant: -16
            ),
        ])
        previousTokenNoteLabel.translatesAutoresizingMaskIntoConstraints = false
        enclosingBodyNoteLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            previousTokenNoteLabel.trailingAnchor.constraint(
                equalTo: container.trailingAnchor, constant: -8
            ),
            previousTokenNoteLabel.bottomAnchor.constraint(
                equalTo: headerSurface.bottomAnchor, constant: 14
            ),
            enclosingBodyNoteLabel.leadingAnchor.constraint(
                equalTo: container.leadingAnchor, constant: 8
            ),
            enclosingBodyNoteLabel.bottomAnchor.constraint(
                equalTo: container.bottomAnchor, constant: -6
            ),
        ])
        view = container
        miniReader.onClick = { [weak self] _, modifiers in
            guard let self else { return }
            // ⌘+click opens (K0a: resolved through reader.gesture.definition,
            // not a hardcoded modifier check).
            let meaningful = modifiers.intersection([.command, .option, .control, .shift])
            guard meaningful == appKeyBindingTable().definitionClickFlags else { return }
            self.openSelection()
        }
        let doubleClick = NSClickGestureRecognizer(
            target: self,
            action: #selector(openSelectedCandidate(_:))
        )
        doubleClick.numberOfClicksRequired = 2
        miniReader.view.addGestureRecognizer(doubleClick)
        render()
        observe()
    }

    func selfTestOpenSelection() {
        openSelection()
    }

    @objc private func openSelectedCandidate(_ sender: Any?) {
        openSelection()
    }

    private func openSelection() {
        if let candidate = model.displayedCandidate {
            onOpen?(candidate)
            return
        }
        if let scope = model.activeEnclosingScope {
            onOpenEnclosing?(scope.path, scope.displayRange.lowerBound)
        }
    }

    func selfTestChooseTracking(_ tracking: ContextWindowModel.Tracking) {
        loadViewIfNeeded()
        modeControl.selectedSegment = tracking == .enclosing ? 1 : 0
        trackingChanged(modeControl)
    }

    @objc private func trackingChanged(_ sender: NSSegmentedControl) {
        model.setTracking(sender.selectedSegment == 1 ? .enclosing : .symbol)
        onTrackingChange?()
        render()
    }

    @objc private func togglePin(_ sender: NSButton) {
        model.setPinned(sender.state == .on)
        render()
    }

    @objc private func selectPrevious(_ sender: Any?) {
        model.selectPrevious()
    }

    @objc private func selectNext(_ sender: Any?) {
        model.selectNext()
    }

    private func observe() {
        guard !isClosing else { return }
        withObservationTracking {
            _ = model.mode
            _ = model.stage
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isClosing else { return }
                self.render()
                self.observe()
            }
        }
    }

    private func render() {
        guard !isClosing else { return }
        modeControl.selectedSegment = model.tracking == .enclosing ? 1 : 0
        pinButton.state = model.isPinned ? .on : .off
        applyHeaderStyle()
        let text: String
        let highlightsSyntax: Bool
        renderTypeHopLabel()
        // "Keeping the previous" only makes sense with something on screen.
        previousTokenNoteLabel.isHidden = !model.isShowingPreviousToken
            || (model.displayedCandidate == nil && model.activeTypeHop == nil
                && model.activeEnclosingScope == nil)
        if let scope = model.activeEnclosingScope {
            renderEnclosing(scope)
            text = ""
            highlightsSyntax = false
        } else if let candidate = model.displayedCandidate {
            pathLabel.stringValue = "\(candidate.path):\(candidate.line):\(candidate.column)"
            let name = Self.declaredName(in: candidate.excerpt) ?? ""
            symbolLabel.stringValue = name
            symbolLabel.isHidden = name.isEmpty || model.activeTypeHop != nil
            stones.update(certainty: candidate.certainty, theme: theme)
            stones.isHidden = false
            let fullProvenance = [
                candidate.provenanceBadge,
                candidate.bindingKind,
            ]
                .compactMap { $0 }
                .joined(separator: " · ")
            // §3.2: the header keeps a short status; the full provider, tool
            // version, trust, limitations, commit, and features move to the
            // tooltip and accessibility value instead of widening the pane.
            candidateLabel.stringValue = Self.shortProvenanceLabel(
                candidate.provenanceBadge, bindingKind: candidate.bindingKind
            )
            candidateLabel.toolTip = fullProvenance
            candidateLabel.setAccessibilityLabel(fullProvenance)
            // No count while a type hop waits for its targets ("1/0").
            countLabel.stringValue = model.candidateCount > 0
                ? "\((model.selectedIndex ?? 0) + 1)/\(model.candidateCount)"
                : ""
            text = candidate.excerpt
            highlightsSyntax = true
            candidateBadge.isHidden = false
            enclosingKindLabel.isHidden = true
            enclosingNameLabel.isHidden = true
            enclosingBodyNoteLabel.isHidden = true
            placeholderLabel.isHidden = true
            scrollView.isHidden = false
            applyBadgeStyle()
        } else {
            placeholderLabel.stringValue = model.tracking == .enclosing
                ? localized("lens.enclosing.placeholder")
                : localized("main.click.a.symbol.to.see.its.definition.here.click.jumps.to.it")
            pathLabel.stringValue = ""
            symbolLabel.stringValue = ""
            symbolLabel.isHidden = true
            typeHopLabel.isHidden = true
            enclosingKindLabel.isHidden = true
            enclosingNameLabel.isHidden = true
            enclosingBodyNoteLabel.isHidden = true
            stones.isHidden = true
            candidateLabel.stringValue = ""
            candidateLabel.toolTip = nil
            candidateLabel.setAccessibilityLabel(nil)
            countLabel.stringValue = ""
            text = ""
            highlightsSyntax = false
            candidateBadge.isHidden = true
            scrollView.isHidden = true
            placeholderLabel.isHidden = false
        }
        previousButton.isEnabled = model.candidateCount > 1
        nextButton.isEnabled = model.candidateCount > 1
        renderCandidateList()
        if model.activeEnclosingScope != nil {
            // R5: the slice comes from the owner's displayed document.
            if let slice = enclosingDocument(model.activeEnclosingScope!) {
                miniReader.display(document: slice)
            } else {
                miniReader.clear()
            }
            return
        }
        guard let document = readerDocument(
            text,
            languageMode: model.selectedLanguageMode,
            highlightsSyntax: highlightsSyntax
        ) else {
            miniReader.clear()
            return
        }
        miniReader.display(document: document)
    }

    /// P1.5: the inline one-hop label — `ps: &S → S (T: Read)`. The side the
    /// window displays is bold; the other side dims and stays clickable.
    /// R5: the enclosing-mode presentation — kind badge, serif name, path,
    /// no stones; the body shows the doc comment through the signature plus
    /// the first body line, fading into the "⋯ N lines" note.
    private func renderEnclosing(_ scope: ContextWindowModel.EnclosingScope) {
        enclosingKindLabel.stringValue = Self.enclosingKindText(for: scope.kind)
        enclosingKindLabel.sizeToFit()
        enclosingKindLabel.isHidden = false
        enclosingNameLabel.stringValue = scope.name
        enclosingNameLabel.isHidden = false
        pathLabel.stringValue = scope.path
        symbolLabel.isHidden = true
        typeHopLabel.isHidden = true
        stones.isHidden = true // R5.4: no certainty stones
        candidateBadge.isHidden = true
        previousButton.isEnabled = false
        nextButton.isEnabled = false
        countLabel.stringValue = ""
        enclosingBodyNoteLabel.isHidden = false
        if let methods = scope.methodCount {
            enclosingBodyNoteLabel.stringValue = localizedFormat(
                "lens.enclosing.implNote",
                Int64(methods), Int64(scope.bodyLineCount)
            )
        } else {
            enclosingBodyNoteLabel.stringValue = localizedFormat(
                "lens.enclosing.bodyNote", Int64(scope.bodyLineCount)
            )
        }
        placeholderLabel.isHidden = true
        scrollView.isHidden = false
    }

    /// Slices the displayed document to the scope's display lines (doc
    /// comment start through the first body line). The owner supplies the
    /// bytes because only it knows the active reader's document.
    var onEnclosingSlice: ((ContextWindowModel.EnclosingScope) -> ReaderDocument?)?

    private func enclosingDocument(
        _ scope: ContextWindowModel.EnclosingScope
    ) -> ReaderDocument? {
        onEnclosingSlice?(scope)
    }

    static func enclosingKindText(for kind: OutlineKind) -> String {
        switch kind {
        case .fn: localized("lens.enclosing.fn")
        case .method: localized("lens.enclosing.method")
        case .impl: "impl"
        case .struct: localized("lens.enclosing.struct")
        case .enum: localized("lens.enclosing.enum")
        case .trait: localized("lens.enclosing.trait")
        case .class: localized("lens.enclosing.class")
        case .mod: "mod"
        default: kind.rawValue
        }
    }

    /// P1.5 self-test readout: the one-hop label's via text, the displayed
    /// type name, and the current showing side.
    /// What the one-hop label actually renders: the button titles and their
    /// laid-out widths (zero means the text never reached the screen).
    var selfTestRenderedTypeHop: (via: String, target: String, viaWidth: CGFloat, targetWidth: CGFloat)? {
        guard model.activeTypeHop != nil, !typeHopLabel.isHiddenOrHasHiddenAncestor else { return nil }
        view.layoutSubtreeIfNeeded()
        return (
            typeHopViaButton.attributedTitle.string,
            typeHopTargetButton.attributedTitle.string,
            typeHopViaButton.frame.width,
            typeHopTargetButton.frame.width
        )
    }

    var selfTestTypeHop: (via: String, target: String?, showing: String)? {
        guard let hop = model.activeTypeHop else { return nil }
        let target: String?
        if hop.showing == .type, let displayed = model.displayedCandidate,
           displayed.targetByteOffset != hop.via.targetByteOffset
        {
            target = Self.declaredName(in: displayed.excerpt)
        } else {
            target = hop.targets.first.flatMap { Self.declaredName(in: $0.excerpt) }
        }
        return (
            via: hop.viaText,
            target: target,
            showing: hop.showing == .type ? "type" : "declaration"
        )
    }

    private func renderTypeHopLabel() {
        guard let hop = model.activeTypeHop else {
            typeHopLabel.isHidden = true
            return
        }
        typeHopLabel.isHidden = false
        let showingType = hop.showing == .type
        let targetShownName: String
        if hop.targets.isEmpty {
            // P2: the syntax spelled no type and the Exact layer is pending
            // (resolving) or unable to answer (not ready).
            targetShownName = modelText(
                hop.pendingExact
                    ? "model.typehop.resolving"
                    : "model.typehop.pendingExact"
            )
        } else if showingType {
            targetShownName = Self.declaredName(
                in: model.displayedCandidate?.excerpt ?? ""
            ) ?? ""
        } else {
            targetShownName = hop.targets.first.flatMap {
                Self.declaredName(in: $0.excerpt)
            } ?? ""
        }

        typeHopViaButton.attributedTitle = NSAttributedString(
            string: hop.viaText,
            attributes: [
                .font: showingType
                    ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
                    : NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: showingType
                    ? theme.chromeSecondaryColor
                    : theme.foregroundColor,
            ]
        )
        typeHopViaButton.toolTip = hop.viaKind + " · "
            + modelText("model.typehop.showDeclarationHint")
        typeHopTargetButton.attributedTitle = NSAttributedString(
            string: targetShownName.isEmpty ? "…" : targetShownName,
            attributes: [
                .font: showingType
                    ? cairnSerifFont(ofSize: 15, weight: .semibold)
                    : cairnSerifFont(ofSize: 15, weight: .medium),
                .foregroundColor: showingType
                    ? theme.foregroundColor
                    : theme.chromeTertiaryColor,
            ]
        )
        typeHopTargetButton.toolTip = modelText("model.typehop.showTypeHint")
        typeHopBoundLabel.stringValue = hop.boundNote.map { "(\($0))" } ?? ""
        typeHopBoundLabel.isHidden = hop.boundNote == nil
        typeHopLabel.setAccessibilityLabel(modelTextFormat(
            "model.typehop.accessibility",
            hop.viaText,
            hop.viaKind,
            targetShownName
        ))
    }

    @objc private func showTypeHopDeclaration(_ sender: Any?) {
        model.showTypeHop(.declaration)
        render()
    }

    @objc private func showTypeHopType(_ sender: Any?) {
        model.showTypeHop(.type)
        render()
    }

    private func renderCandidateList() {
        if case let .candidates(candidates, _) = model.stage, candidates.count > 1 {
            listedCandidates = candidates
        } else if case let .typeHop(hop, _) = model.stage, hop.targets.count > 1 {
            listedCandidates = hop.targets
        } else {
            listedCandidates = []
        }
        let showsList = !listedCandidates.isEmpty
        candidateScroll.isHidden = !showsList
        excerptFullWidth?.isActive = !showsList
        excerptBesideList?.isActive = showsList
        candidateTable.reloadData()
        isSyncingListSelection = true
        if let selected = model.selectedIndex, showsList {
            candidateTable.selectRowIndexes([selected], byExtendingSelection: false)
            candidateTable.scrollRowToVisible(selected)
        } else {
            candidateTable.deselectAll(nil)
        }
        isSyncingListSelection = false
    }

    func numberOfRows(in tableView: NSTableView) -> Int { listedCandidates.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 38 }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ThemedTableRowView(selectionColor: theme.chromeSelectionColor)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard listedCandidates.indices.contains(row) else { return nil }
        let candidate = listedCandidates[row]
        let stones = CertaintyStonesView(certainty: candidate.certainty, theme: theme, size: 12)
        let name = NSTextField(labelWithString: Self.declaredName(in: candidate.excerpt) ?? candidate.label)
        name.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        name.textColor = theme.foregroundColor
        name.lineBreakMode = .byTruncatingTail
        let location = NSTextField(
            labelWithString: "\(URL(fileURLWithPath: candidate.path).lastPathComponent):\(candidate.line)"
        )
        location.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        location.textColor = theme.chromeSecondaryColor
        location.lineBreakMode = .byTruncatingMiddle
        location.toolTip = "\(candidate.path):\(candidate.line)"
        let labels = NSStackView(views: [name, location])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        let row = NSStackView(views: [stones, labels])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 8)
        for label in [name, location] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let cell = NSTableCellView()
        row.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            row.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        cell.setAccessibilityLabel("\(name.stringValue), \(location.toolTip ?? "")")
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingListSelection, candidateTable.selectedRow >= 0 else { return }
        model.select(at: candidateTable.selectedRow)
    }

    var selfTestCandidateList: (visible: Bool, rows: [String], selected: Int?, excerptLeading: CGFloat) {
        loadViewIfNeeded()
        view.layoutSubtreeIfNeeded()
        let rows = (0..<candidateTable.numberOfRows).compactMap {
            candidateTable.view(atColumn: 0, row: $0, makeIfNecessary: true)?.accessibilityLabel()
        }
        return (
            candidateScroll.window != nil && !candidateScroll.isHiddenOrHasHiddenAncestor
                && candidateScroll.frame.width > 0,
            rows,
            candidateTable.selectedRow >= 0 ? candidateTable.selectedRow : nil,
            scrollView.frame.minX
        )
    }

    var selfTestCandidateSelectionColor: NSColor? {
        guard candidateTable.selectedRow >= 0 else { return nil }
        return (candidateTable.rowView(atRow: candidateTable.selectedRow, makeIfNecessary: true)
            as? ThemedTableRowView)?.selectionColor
    }

    func selfTestClickCandidate(_ row: Int) {
        candidateTable.selectRowIndexes([row], byExtendingSelection: false)
    }

    /// The name a definition excerpt declares on its first code line, or nil
    /// when it is not a recognizable declaration (the Lens then shows no title
    /// rather than guessing).
    static func declaredName(in excerpt: String) -> String? {
        let keywords: Set<String> = [
            "fn", "struct", "enum", "trait", "type", "union", "mod", "const", "static",
            "def", "class", "function", "interface", "let", "var",
        ]
        for line in excerpt.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("#") || trimmed.hasPrefix("@") { continue }
            let words = trimmed.split { !($0.isLetter || $0.isNumber || $0 == "_") }
            guard let keyword = words.firstIndex(where: { keywords.contains(String($0)) }),
                  words.index(after: keyword) < words.endIndex
            else { return nil }
            let name = String(words[words.index(after: keyword)])
            return name.first.map { $0.isLetter || $0 == "_" } == true ? name : nil
        }
        return nil
    }

    /// Short header label for a full provenance badge: keeps the certainty
    /// status (Exact/Strong/Possible/…) and the binding kind; provider, tool
    /// version, trust, limitations, commit, and features move to the
    /// tooltip. Unresolved and other states keep their distinguishing word.
    static func shortProvenanceLabel(_ full: String, bindingKind: String?) -> String {
        let parts = full.components(separatedBy: " · ")
        guard let status = parts.first, !status.isEmpty else {
            return String(full.prefix(40))
        }
        if let bindingKind {
            return "\(status) · \(bindingKind)"
        }
        return status
    }

    private func applyBadgeStyle() {
        let colors: (background: NSColor, foreground: NSColor) =
            switch provenanceBadgeStyle(for: model.displayedCandidate?.certainty) {
            case .exact:
                (theme.mossSoftColor, theme.verifiedColor)
            case .strong:
                (theme.slateSoftColor, theme.inferredColor)
            case .possible:
                (theme.amberSoftColor, theme.warningColor)
            case .fallback:
                (theme.chipBackgroundColor, theme.chipForegroundColor)
            }
        candidateBadge.layer?.backgroundColor = colors.background.cgColor
        candidateLabel.textColor = colors.foreground
    }

    private func readerDocument(
        _ source: String,
        languageMode: LanguageMode?,
        highlightsSyntax: Bool
    ) -> ReaderDocument? {
        let bytes = Array(source.utf8)
        guard let languageMode else { return nil }
        let plain = ReaderDocument(
            bytes: bytes,
            languageMode: languageMode
        )
        guard highlightsSyntax else { return plain }
        return try? DocumentLoader().loadSyntax(for: plain)
    }
}

/// Keep identifier preparation separate from focus and syntax-load notices.
func readerIdentifierPreparationNotice(_ state: ReaderIdentifierState) -> String? {
    switch state {
    case .notRequested, .ready: nil
    case .building: localized("reader.identifiers.preparing")
    case .unavailable: localized("reader.identifiers.unavailable")
    }
}
