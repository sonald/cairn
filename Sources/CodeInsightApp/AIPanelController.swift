import AppKit
import CodeInsightAI
import CodeInsightAppModel
import CodeInsightReaderCore
import CodeInsightReaderUI
import Observation

/// The AI panel: a conversation about the snapshot, one question after
/// another. Under each question is one line for the reading (the current
/// step, then a summary; it unfolds into the steps, whose code opens) and
/// the answer, whose citations open the code.
@MainActor
final class AIPanelController: NSViewController, NSTextViewDelegate {
    let conversation: AIConversationModel
    private let appModel: AppModel
    /// Opens `path` (project-relative) at a byte offset in the reader.
    var onOpen: ((URL, UInt32?) -> Void)?
    var onShowSettings: (() -> Void)?

    private var theme = ReaderTheme(settings: ReaderSettings())
    private let header = NSStackView()
    private let snapshotLabel = NSTextField(labelWithString: "")
    private let newButton = NSButton()
    private let scrollView = NSScrollView()
    private let turnsStack = NSStackView()
    private let placeholder = NSTextField(wrappingLabelWithString: "")
    private let placeholderButton = NSButton()
    private let banner = NSStackView()
    private let bannerLabel = NSTextField(wrappingLabelWithString: "")
    private let bannerAllow = NSButton()
    private let bannerCancel = NSButton()
    private let inputScroll = NSScrollView()
    /// A scroll view's own layer border does not draw; this plain view carries it.
    private let inputBox = NSView()
    private let input = AIInputTextView()
    private let sendButton = NSButton()
    private var turnViews: [AITurnView] = []
    private var pendingQuestion: String?
    private var pendingSelection: AIConversationModel.Selection?
    private var updateScheduled = false

    init(conversation: AIConversationModel, appModel: AppModel) {
        self.conversation = conversation
        self.appModel = appModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true

        snapshotLabel.font = .systemFont(ofSize: 11)
        snapshotLabel.lineBreakMode = .byTruncatingTail
        snapshotLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        newButton.title = localized("ai.new")
        newButton.bezelStyle = .recessed
        newButton.controlSize = .small
        newButton.font = .systemFont(ofSize: 11)
        newButton.target = self
        newButton.action = #selector(newConversation(_:))
        newButton.setAccessibilityLabel(localized("ai.new"))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        header.setViews([snapshotLabel, spacer, newButton], in: .leading)
        header.orientation = .horizontal
        header.spacing = 6
        header.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 8)
        header.wantsLayer = true

        turnsStack.orientation = .vertical
        turnsStack.alignment = .leading
        turnsStack.spacing = 18
        turnsStack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 16, right: 12)
        placeholder.font = .systemFont(ofSize: 12)
        placeholder.alignment = .left
        placeholderButton.bezelStyle = .rounded
        placeholderButton.controlSize = .small
        placeholderButton.title = localized("ai.openSettings")
        placeholderButton.target = self
        placeholderButton.action = #selector(showSettings(_:))
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        turnsStack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(turnsStack)
        scrollView.documentView = document
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        NSLayoutConstraint.activate([
            turnsStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            turnsStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            turnsStack.topAnchor.constraint(equalTo: document.topAnchor),
            turnsStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])

        bannerLabel.font = .systemFont(ofSize: 12)
        bannerAllow.title = localized("ai.consent.allow")
        bannerAllow.bezelStyle = .rounded
        bannerAllow.controlSize = .small
        bannerAllow.target = self
        bannerAllow.action = #selector(allowSending(_:))
        bannerCancel.title = localized("settings.cancel")
        bannerCancel.bezelStyle = .rounded
        bannerCancel.controlSize = .small
        bannerCancel.target = self
        bannerCancel.action = #selector(cancelConsent(_:))
        let bannerButtons = NSStackView(views: [bannerAllow, bannerCancel])
        bannerButtons.spacing = 6
        banner.setViews([bannerLabel, bannerButtons], in: .leading)
        banner.orientation = .vertical
        banner.alignment = .leading
        banner.spacing = 6
        banner.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        banner.wantsLayer = true
        banner.isHidden = true

        input.delegate = self
        input.isRichText = false
        input.allowsUndo = true
        input.font = .systemFont(ofSize: 13)
        input.textContainerInset = NSSize(width: 4, height: 6)
        input.isVerticallyResizable = true
        input.autoresizingMask = [.width]
        input.textContainer?.widthTracksTextView = true
        input.onSubmit = { [weak self] in self?.send(nil) }
        input.setAccessibilityLabel(localized("ai.input"))
        input.placeholder = localized("ai.input.placeholder")
        inputScroll.documentView = input
        inputScroll.hasVerticalScroller = true
        inputScroll.autohidesScrollers = true
        inputScroll.borderType = .noBorder
        inputScroll.drawsBackground = false
        inputScroll.translatesAutoresizingMaskIntoConstraints = false
        inputBox.wantsLayer = true
        inputBox.layer?.cornerRadius = 7
        inputBox.layer?.borderWidth = 1
        inputBox.addSubview(inputScroll)
        NSLayoutConstraint.activate([
            inputScroll.leadingAnchor.constraint(equalTo: inputBox.leadingAnchor, constant: 1),
            inputScroll.trailingAnchor.constraint(equalTo: inputBox.trailingAnchor, constant: -1),
            inputScroll.topAnchor.constraint(equalTo: inputBox.topAnchor, constant: 1),
            inputScroll.bottomAnchor.constraint(equalTo: inputBox.bottomAnchor, constant: -1),
        ])
        sendButton.bezelStyle = .regularSquare
        sendButton.isBordered = false
        sendButton.imageScaling = .scaleProportionallyUpOrDown
        sendButton.target = self
        sendButton.action = #selector(send(_:))
        let inputRow = NSStackView(views: [inputBox, sendButton])
        inputRow.orientation = .horizontal
        inputRow.alignment = .bottom
        inputRow.spacing = 6
        inputRow.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 10, right: 10)

        let column = NSStackView(views: [header, scrollView, banner, inputRow])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(column)
        for view in [header, scrollView, banner, inputRow] {
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            column.topAnchor.constraint(equalTo: root.topAnchor),
            column.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            inputScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 34),
            inputScroll.heightAnchor.constraint(lessThanOrEqualToConstant: 110),
            sendButton.widthAnchor.constraint(equalToConstant: 26),
            sendButton.heightAnchor.constraint(equalToConstant: 26),
        ])
        scrollView.setContentHuggingPriority(.init(1), for: .vertical)
        let preferredInput = inputScroll.heightAnchor.constraint(equalToConstant: 34)
        preferredInput.priority = .defaultLow
        preferredInput.isActive = true
        input.onHeightChange = { [weak self] height in
            preferredInput.constant = min(max(height, 34), 110)
            self?.view.layoutSubtreeIfNeeded()
        }
        view = root
        applyTheme()
        observe()
        // Settings and the key live outside the model; coming back from the
        // Settings window is when they change.
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowBecameKey(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
        update()
    }

    @objc private func windowBecameKey(_ note: Notification) {
        guard (note.object as? NSWindow) === view.window else { return }
        update()
    }

    func apply(settings: ReaderSettings) {
        theme = ReaderTheme(settings: settings)
        guard isViewLoaded else { return }
        applyTheme()
        update()
    }

    private func applyTheme() {
        view.appearance = cairnAppearance(for: theme.variant)
        view.layer?.backgroundColor = theme.backgroundColor.cgColor
        header.layer?.backgroundColor = theme.chromeColor.cgColor
        banner.layer?.backgroundColor = theme.chromeColor.cgColor
        snapshotLabel.textColor = theme.chromeSecondaryColor
        placeholder.textColor = theme.chromeSecondaryColor
        bannerLabel.textColor = theme.foregroundColor
        input.textColor = theme.foregroundColor
        input.insertionPointColor = theme.foregroundColor
        input.backgroundColor = .clear
        input.drawsBackground = false
        inputBox.layer?.borderColor = theme.chromeTertiaryColor.cgColor
        for view in turnViews { view.theme = theme }
    }

    func focusInput() {
        view.window?.makeFirstResponder(input)
    }

    // MARK: Model

    private func observe() {
        withObservationTracking {
            _ = conversation.turns
            _ = appModel.projectRoot
            _ = appModel.fileTree
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.scheduleUpdate()
                self?.observe()
            }
        }
    }

    /// Streaming changes the answer many times a second; render at most ~12×/s.
    private func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.updateScheduled = false
            self?.update()
        }
    }

    private func update() {
        guard isViewLoaded else { return }
        // A conversation belongs to the project it was asked in.
        if let root = conversation.snapshot?.root,
           root.standardizedFileURL.path != appModel.projectRoot?.standardizedFileURL.path {
            conversation.reset()
        }
        let turns = conversation.turns
        let pinnedToBottom = isScrolledToBottom
        while turnViews.count > turns.count { turnViews.removeLast().removeFromSuperview() }
        for (index, turn) in turns.enumerated() {
            if index == turnViews.count {
                let view = AITurnView(theme: theme)
                view.onOpen = { [weak self] path, line in self?.open(path: path, line: line) }
                view.onOpenEvidence = { [weak self] evidence in self?.open(evidence) }
                view.onLink = { [weak self] url in self?.openLink(url) }
                turnsStack.addArrangedSubview(view)
                view.widthAnchor.constraint(equalTo: turnsStack.widthAnchor, constant: -24).isActive = true
                turnViews.append(view)
            }
            turnViews[index].show(turn, snapshot: conversation.snapshot)
        }
        // Only an empty panel explains what is missing; checking is not free.
        if turns.isEmpty || placeholder.superview != nil { updatePlaceholder(isEmpty: turns.isEmpty) }
        updateHeader()
        updateSendButton()
        // Follows the answer only while the reader stays at the end; asking scrolls there.
        if pinnedToBottom { scrollToBottom() }
    }

    private func updateHeader() {
        let settings = AIProviderSettings.load()
        var parts: [String] = []
        if let snapshot = conversation.snapshot {
            parts.append(snapshot.revision.map { String($0.prefix(7)) } ?? localized("ai.snapshot.worktree"))
        }
        if !settings.model.isEmpty { parts.append(settings.model) }
        snapshotLabel.stringValue = parts.joined(separator: " · ")
        newButton.isEnabled = !conversation.turns.isEmpty
    }

    private func updatePlaceholder(isEmpty: Bool) {
        let blocker = conversation.blocker(project: appModel.projectRoot)
        let text: String
        var showsSettings = false
        switch blocker {
        case .noProject: text = localized("ai.empty.noProject")
        case .needsSettings, .needsKey:
            text = localized("ai.empty.needsSettings")
            showsSettings = true
        case .helperMissing: text = localized("ai.helper.missing")
        case .needsConsent, nil: text = localized("ai.empty.ready")
        }
        if isEmpty {
            placeholder.stringValue = text
            if placeholder.superview == nil { turnsStack.insertArrangedSubview(placeholder, at: 0) }
            if showsSettings, placeholderButton.superview == nil {
                turnsStack.insertArrangedSubview(placeholderButton, at: 1)
            } else if !showsSettings {
                placeholderButton.removeFromSuperview()
            }
        } else {
            placeholder.removeFromSuperview()
            placeholderButton.removeFromSuperview()
        }
    }

    private func updateSendButton() {
        let running = conversation.isRunning
        let name = running ? "stop.circle.fill" : "arrow.up.circle.fill"
        let label = localized(running ? "ai.stop" : "ai.send")
        sendButton.image = NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 20, weight: .regular))
        sendButton.contentTintColor = theme.accentColor
        sendButton.toolTip = label
        sendButton.setAccessibilityLabel(label)
    }

    private var isScrolledToBottom: Bool {
        guard let document = scrollView.documentView else { return true }
        return scrollView.contentView.bounds.maxY >= document.frame.height - 24
    }

    private func scrollToBottom() {
        view.layoutSubtreeIfNeeded()
        guard let document = scrollView.documentView else { return }
        let y = max(0, document.frame.height - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: Asking

    /// Asks `question` (or what is typed), after the first-use consent. A
    /// question about a selection starts a new conversation.
    func ask(_ question: String? = nil, about selection: AIConversationModel.Selection? = nil) {
        let text = (question ?? input.string).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        switch conversation.blocker(project: appModel.projectRoot) {
        case .needsConsent(let host):
            pendingQuestion = text
            pendingSelection = selection
            bannerLabel.stringValue = localizedFormat("ai.consent.message", host)
            banner.isHidden = false
            view.window?.makeFirstResponder(bannerAllow)
            return
        case .noProject, .needsSettings, .needsKey, .helperMissing:
            update()
            return
        case nil:
            break
        }
        // After the checks, so a cancelled consent keeps the old conversation.
        if selection != nil { conversation.reset() }
        if question == nil { input.string = "" }
        input.didChangeText()
        conversation.ask(text, about: selection, snapshot: AISnapshot(model: appModel))
        update()
        scrollToBottom()
    }

    @objc private func send(_ sender: Any?) {
        if conversation.isRunning { conversation.cancel() } else { ask() }
    }

    @objc private func newConversation(_ sender: Any?) {
        conversation.reset()
        focusInput()
    }

    @objc private func allowSending(_ sender: Any?) {
        banner.isHidden = true
        guard let root = appModel.projectRoot, let question = pendingQuestion else { return }
        conversation.allowSending(project: root)
        pendingQuestion = nil
        ask(question, about: pendingSelection)
        pendingSelection = nil
        if input.string.trimmingCharacters(in: .whitespacesAndNewlines) == question { input.string = "" }
    }

    @objc private func cancelConsent(_ sender: Any?) {
        banner.isHidden = true
        pendingQuestion = nil
        pendingSelection = nil
        focusInput()
    }

    @objc private func showSettings(_ sender: Any?) { onShowSettings?() }

    // MARK: Opening code

    /// Offsets are from the conversation's snapshot; after a switch to
    /// another one the file opens without them.
    private var offsetsApply: Bool { conversation.snapshot?.id == appModel.currentSnapshotID }

    private func open(_ evidence: AIEvidence) {
        guard let snapshot = conversation.snapshot else { return }
        onOpen?(snapshot.url(of: evidence.path), offsetsApply ? evidence.byteOffset : nil)
    }

    /// Links in the answer are the model's text: only snapshot files open.
    private func open(path: String, line: Int) {
        guard let snapshot = conversation.snapshot, let path = snapshot.resolve(cited: path) else { return }
        onOpen?(snapshot.url(of: path), offsetsApply ? snapshot.byteOffset(of: path, line: line) : nil)
    }

    private func openLink(_ url: URL) {
        if url.scheme == "https" || url.scheme == "http" { NSWorkspace.shared.open(url) }
    }
}

// MARK: - One question

@MainActor
private final class AITurnView: NSStackView, NSTextViewDelegate {
    var theme: ReaderTheme { didSet { lastAnswer = nil } }
    var onOpen: ((String, Int) -> Void)?
    var onOpenEvidence: ((AIEvidence) -> Void)?
    var onLink: ((URL) -> Void)?
    private let question = NSTextField(wrappingLabelWithString: "")
    /// The selection a question was asked about; opens it.
    private let selection = NSButton()
    private var shownSelection: AIConversationModel.Selection?
    /// One line for the reading: the current step while it runs, then a
    /// summary; clicking it lists the steps, and the code read opens from there.
    private let activity = NSButton()
    private let spinner = NSProgressIndicator()
    private let activityRow = NSStackView()
    private let steps = NSStackView()
    private var expanded = false
    private let answer = AIAnswerTextView(usingTextLayoutManager: false)
    private let status = NSTextField(wrappingLabelWithString: "")
    private var lastAnswer: String?
    private var shownSteps: [AIToolStep] = []
    private var shownEvidence: [AIEvidence] = []

    init(theme: ReaderTheme) {
        self.theme = theme
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        question.font = .systemFont(ofSize: 13, weight: .semibold)
        question.isSelectable = true
        activity.isBordered = false
        activity.imagePosition = .imageLeading
        activity.imageHugsTitle = true
        activity.target = self
        activity.action = #selector(toggleSteps)
        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isDisplayedWhenStopped = false
        activityRow.orientation = .horizontal
        activityRow.spacing = 4
        activityRow.addArrangedSubview(activity)
        activityRow.addArrangedSubview(spinner)
        activity.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        steps.orientation = .vertical
        steps.alignment = .leading
        steps.spacing = 2
        steps.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 0)
        steps.isHidden = true
        status.font = .systemFont(ofSize: 11)
        answer.isEditable = false
        answer.isSelectable = true
        answer.drawsBackground = false
        answer.textContainerInset = .zero
        answer.textContainer?.lineFragmentPadding = 0
        answer.textContainer?.widthTracksTextView = true
        answer.isVerticallyResizable = false
        answer.delegate = self
        answer.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        answer.setAccessibilityLabel(localized("ai.answer"))
        selection.isBordered = false
        selection.alignment = .left
        selection.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        selection.target = self
        selection.action = #selector(openSelection)
        selection.toolTip = localized("ai.card.open")
        for view in [selection, question, activityRow, steps, answer, status] as [NSView] {
            addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        setCustomSpacing(4, after: activityRow)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func toggleSteps() {
        expanded.toggle()
        steps.isHidden = !expanded
        updateActivityImage()
    }

    private func updateActivityImage() {
        let name = expanded ? "chevron.down" : "chevron.right"
        activity.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        activity.contentTintColor = theme.chromeSecondaryColor
        activity.setAccessibilityValue(localized(expanded ? "ai.steps.expanded" : "ai.steps.collapsed"))
    }

    @objc private func openSelection() {
        guard let shownSelection else { return }
        onOpen?(shownSelection.path, shownSelection.startLine)
    }

    func show(_ turn: AIConversationModel.Turn, snapshot: AISnapshot?) {
        shownSelection = turn.selection
        if let picked = turn.selection {
            let lines = picked.startLine == picked.endLine ? "\(picked.startLine)" : "\(picked.startLine)–\(picked.endLine)"
            selection.attributedTitle = NSAttributedString(string: "\(picked.path):\(lines)", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: theme.accentColor,
            ])
        }
        selection.isHidden = turn.selection == nil
        question.stringValue = turn.question
        question.textColor = theme.foregroundColor
        showActivity(turn)
        if turn.answer != lastAnswer {
            lastAnswer = turn.answer
            let rendered = MarkdownPreviewRenderer(
                theme: theme, baseURL: nil, bodyPointSize: 13, compactHeadings: true, loadsImages: false
            ).render(turn.answer) ?? NSAttributedString(string: turn.answer)
            let linked = NSMutableAttributedString(attributedString: rendered)
            if let snapshot { Self.linkCitations(in: linked, snapshot: snapshot, color: theme.accentColor) }
            answer.textStorage?.setAttributedString(linked)
            answer.invalidateIntrinsicContentSize()
        }
        answer.isHidden = turn.answer.isEmpty
        status.stringValue = Self.statusText(turn)
        // With steps, the reading line carries the progress and the summary.
        status.isHidden = !turn.steps.isEmpty && {
            switch turn.state {
            case .working, .done: return true
            default: return false
            }
        }()
        if case .failed = turn.state {
            status.textColor = .systemOrange
        } else {
            status.textColor = theme.chromeTertiaryColor
        }
    }

    private func showActivity(_ turn: AIConversationModel.Turn) {
        activityRow.isHidden = turn.steps.isEmpty && turn.runningStep == nil
        guard !activityRow.isHidden else { return }
        let working = { if case .working = turn.state { return true } else { return false } }()
        let title: String
        if working, let running = turn.runningStep {
            title = localizedFormat("ai.steps.current", turn.steps.count + 1, Self.describe(running, running: true))
        } else if working, let last = turn.steps.last {
            title = localizedFormat("ai.steps.current", turn.steps.count, Self.describe(last))
        } else {
            title = Self.summary(turn)
        }
        activity.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: theme.chromeSecondaryColor,
        ])
        activity.setAccessibilityLabel(title)
        activity.toolTip = localized(expanded ? "ai.steps.hide" : "ai.steps.show")
        updateActivityImage()
        if working { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        guard turn.steps != shownSteps || turn.evidence != shownEvidence else { return }
        shownSteps = turn.steps
        shownEvidence = turn.evidence
        steps.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, step) in turn.steps.enumerated() {
            let row = AIStepRow(step: step, number: index + 1,
                                evidence: turn.evidence.first { $0.step == index + 1 }, theme: theme)
            row.onOpen = { [weak self] evidence in self?.onOpenEvidence?(evidence) }
            steps.addArrangedSubview(row)
        }
    }

    static func describe(_ step: AIToolStep, running: Bool = false) -> String {
        let subject = step.kind == .list && step.subject.isEmpty ? "/" : step.subject
        let text = localizedFormat("ai.step." + step.kind.rawValue, subject)
        if running { return text }
        guard let count = step.count else { return text + " ⚠︎" }
        return step.kind == .read ? text : text + " · \(count)"
    }

    static func statusText(_ turn: AIConversationModel.Turn) -> String {
        switch turn.state {
        case .working:
            return turn.steps.isEmpty ? localized("ai.status.thinking") : localized("ai.status.reading")
        case .answering:
            return localized("ai.status.answering")
        case .cancelled:
            return localized("ai.status.stopped")
        case .failed(let message):
            let reason = switch message {
            case "roundLimit": localizedFormat("ai.error.roundLimit", AIConversationModel.maxRounds)
            case "contextLimit": localized("ai.error.contextLimit")
            case "helperMissing": localized("ai.helper.missing")
            case AIHelper.exitedMessage: localized("ai.error.helperExited")
            default: message
            }
            return localized("ai.status.failed") + " " + reason
        case .done:
            return summary(turn)
        }
    }

    static func summary(_ turn: AIConversationModel.Turn) -> String {
        let reads = turn.steps.filter { $0.kind == .read }.count
        let searches = turn.steps.count - reads
        var parts: [String] = []
        if searches > 0 { parts.append(localizedFormat("ai.summary.searches", searches)) }
        if reads > 0 { parts.append(localizedFormat("ai.summary.reads", reads)) }
        if let elapsed = turn.elapsed { parts.append(String(format: "%.1f s", elapsed)) }
        return parts.joined(separator: " · ")
    }

    /// `path:line` and `path:start-end` naming a snapshot file become links
    /// that open the reader there.
    static func linkCitations(in text: NSMutableAttributedString, snapshot: AISnapshot, color: NSColor) {
        let pattern = #"(?<![\w/.-])([\w.\-/]+\.[A-Za-z0-9]+|[\w.\-]+/[\w.\-/]+):(\d+)(?:\s*[-–]\s*(\d+))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let string = text.string as NSString
        for match in regex.matches(in: text.string, range: NSRange(location: 0, length: string.length)).reversed() {
            let cited = string.substring(with: match.range(at: 1))
            guard text.attribute(.link, at: match.range.location, effectiveRange: nil) == nil,
                  let path = snapshot.resolve(cited: cited),
                  let line = Int(string.substring(with: match.range(at: 2)))
            else { continue }
            var components = URLComponents()
            components.scheme = "cairn-ai"
            components.host = "open"
            components.queryItems = [URLQueryItem(name: "path", value: path), URLQueryItem(name: "line", value: String(line))]
            guard let url = components.url else { continue }
            text.addAttributes([.link: url, .foregroundColor: color], range: match.range)
        }
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) else { return true }
        if url.scheme == "cairn-ai",
           let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           let path = items.first(where: { $0.name == "path" })?.value,
           let line = items.first(where: { $0.name == "line" })?.value.flatMap(Int.init) {
            onOpen?(path, line)
        } else {
            onLink?(url)
        }
        return true
    }
}

/// One step of the reading. A step that read code names the lines and opens
/// them; its first lines show on hover.
@MainActor
private final class AIStepRow: NSButton {
    var onOpen: ((AIEvidence) -> Void)?
    private let evidence: AIEvidence?

    init(step: AIToolStep, number: Int, evidence: AIEvidence?, theme: ReaderTheme) {
        self.evidence = evidence
        super.init(frame: .zero)
        isBordered = false
        alignment = .left
        lineBreakMode = .byTruncatingMiddle
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let text: String
        if let evidence {
            let range = evidence.startLine == evidence.endLine
                ? "\(evidence.startLine)" : "\(evidence.startLine)–\(evidence.endLine)"
            // A read names its lines; a lookup or history says what it was.
            text = step.kind == .read
                ? "\(number)  \(evidence.path):\(range)"
                : "\(number)  \(AITurnView.describe(step)) → \(evidence.path):\(range)"
            toolTip = evidence.excerpt
            target = self
            action = #selector(clicked(_:))
        } else {
            text = "\(number)  " + AITurnView.describe(step)
            isEnabled = false
        }
        attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: evidence == nil ? theme.chromeTertiaryColor : theme.accentColor,
        ])
        setAccessibilityLabel(text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        if evidence != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }

    @objc private func clicked(_ sender: Any?) {
        if let evidence { onOpen?(evidence) }
    }
}

/// The answer's height follows its text.
private final class AIAnswerTextView: NSTextView {
    override var intrinsicContentSize: NSSize {
        guard let container = textContainer, let layout = layoutManager else { return super.intrinsicContentSize }
        layout.ensureLayout(for: container)
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(layout.usedRect(for: container).height) + 2)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { invalidateIntrinsicContentSize() }
    }
}

/// ↩ sends, ⇧↩ or ⌥↩ breaks the line; the height follows the text.
final class AIInputTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onHeightChange: ((CGFloat) -> Void)?
    var placeholder = "" { didSet { needsDisplay = true } }

    override func doCommand(by selector: Selector) {
        let modifiers = NSApp.currentEvent?.modifierFlags ?? []
        if selector == #selector(insertNewline(_:)), !modifiers.contains(.shift), !modifiers.contains(.option) {
            onSubmit?()
        } else if selector == #selector(insertNewline(_:)) {
            insertNewlineIgnoringFieldEditor(nil)
        } else if selector == #selector(cancelOperation(_:)), let onCancel {
            onCancel()
        } else {
            super.doCommand(by: selector)
        }
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
        guard let container = textContainer, let layout = layoutManager else { return }
        layout.ensureLayout(for: container)
        onHeightChange?(ceil(layout.usedRect(for: container).height) + textContainerInset.height * 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0),
                             y: textContainerInset.height)
        (placeholder as NSString).draw(at: origin, withAttributes: [
            .font: font ?? .systemFont(ofSize: 13),
            .foregroundColor: NSColor.placeholderTextColor,
        ])
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The inline box for asking about a selection: quick questions, a field
/// (an empty question asks for an explanation), sent with ↩.
final class AIAskPopover: NSViewController {
    private static var shown: NSPopover?
    private let onAsk: (String) -> Void
    private let input = AIInputTextView(usingTextLayoutManager: false)

    /// Shows the box under `rect` of `view`; `onAsk` gets the question.
    static func show(relativeTo rect: NSRect, of view: NSView, onAsk: @escaping (String) -> Void) {
        shown?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        let controller = AIAskPopover(onAsk: { question in
            shown?.close()
            onAsk(question)
        })
        popover.contentViewController = controller
        shown = popover
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        // Typing goes to the box even when a click in the window opened it.
        controller.view.window?.makeKey()
        controller.view.window?.makeFirstResponder(controller.input)
    }

    private init(onAsk: @escaping (String) -> Void) {
        self.onAsk = onAsk
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let chips = NSStackView(views: ["ai.chip.explain", "ai.chip.callers", "ai.chip.why"].map { key in
            let chip = NSButton(title: localized(key), target: self, action: #selector(askChip(_:)))
            chip.bezelStyle = .push
            chip.controlSize = .small
            return chip
        })
        chips.spacing = 6
        input.font = .systemFont(ofSize: 13)
        input.placeholder = localized("ai.selection.placeholder")
        input.drawsBackground = false
        input.isRichText = false
        input.textContainerInset = NSSize(width: 2, height: 4)
        input.setAccessibilityLabel(localized("ai.input"))
        input.onSubmit = { [weak self] in self?.submit() }
        input.onCancel = { [weak self] in self?.view.window?.performClose(nil) }
        let scroll = NSScrollView()
        scroll.documentView = input
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        input.autoresizingMask = [.width]
        input.isVerticallyResizable = true
        input.textContainer?.widthTracksTextView = true
        let hint = NSTextField(labelWithString: localized("ai.selection.hint"))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        let column = NSStackView(views: [chips, scroll, hint])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        NSLayoutConstraint.activate([
            column.widthAnchor.constraint(equalToConstant: 380),
            scroll.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -24),
            scroll.heightAnchor.constraint(equalToConstant: 54),
        ])
        view = column
    }

    @objc private func askChip(_ sender: NSButton) { onAsk(sender.title) }

    private func submit() {
        let text = input.string.trimmingCharacters(in: .whitespacesAndNewlines)
        onAsk(text.isEmpty ? localized("ai.chip.explain") : text)
    }
}
