import AppKit
import CodeInsightAppModel
import CodeInsightCore
import CodeInsightEngine
import CodeInsightReaderCore
import CodeInsightReaderUI
import Observation
import QuartzCore

/// The persistent project-search surface in the main window's bottom area.
@MainActor
final class SearchPanel: NSViewController, NSTextFieldDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let appModel: AppModel
    private var panelModel: SearchPanelModel { appModel.projectSearch }
    private let input = QueryInputField()
    private let caseButton = NSButton()
    private let wordButton = NSButton()
    private let regexButton = NSButton()
    private let chips = QueryChipRow()
    private let errorLabel = NSTextField(labelWithString: "")
    private let outlineView = QueryOutlineView()
    private let scrollView = NSScrollView()
    private let placeholderLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let coverageLabel = NSTextField(wrappingLabelWithString: "")
    private let header = NSStackView()
    private let summary = NSStackView()
    private var theme = ReaderTheme(settings: ReaderSettings())
    nonisolated(unsafe) private var clickMonitor: Any?
    private var reloadTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var ghostTask: Task<Void, Never>?
    private var bubble: NSPanel?
    private var hintDismissedQuery: String?
    private var fullGhost = ""
    private var hintsEnabled = true
    private var syncingSelection = false
    private var chipTexts: [String] = []
    private var chipRemovals: [(inout ProjectSearchQuery) -> Void] = []
    private weak var chipEditor: NSTextField?
    private var previouslySearching = false
    private var lastChipQuery: ProjectSearchQuery?
    private let onOpen: (URL, ByteRange, ContentID?, Bool) -> Void
    private let onReturnToReader: () -> Void

    init(appModel: AppModel, onOpen: @escaping (URL, ByteRange, ContentID?, Bool) -> Void,
         onReturnToReader: @escaping () -> Void) {
        self.appModel = appModel
        self.onOpen = onOpen
        self.onReturnToReader = onReturnToReader
        super.init(nibName: nil, bundle: nil)
        configureView()
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.bubble != nil, event.window === self.view.window else { return event }
            let point = self.input.convert(event.locationInWindow, from: nil)
            if !self.input.bounds.contains(point) { self.hideHints() }
            return event
        }
        observe()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let clickMonitor { NSEvent.removeMonitor(clickMonitor) } }

    func apply(settings: ReaderSettings) {
        theme = ReaderTheme(settings: settings)
        hintsEnabled = settings.showQuerySuggestions
        panelModel.setSuggestionsEnabled(hintsEnabled)
        view.appearance = cairnAppearance(for: settings.theme)
        view.layer?.backgroundColor = theme.backgroundColor.cgColor
        header.layer?.backgroundColor = theme.chromeColor.cgColor
        summary.layer?.backgroundColor = theme.backgroundColor.cgColor
        input.textColor = theme.foregroundColor
        input.backgroundColor = theme.backgroundColor
        // The layer fills the whole rounded field; the cell fills only its text rect.
        input.layer?.backgroundColor = theme.backgroundColor.cgColor
        input.ghostColor = theme.chromeTertiaryColor
        input.errorColor = theme.unresolvedColor
        input.borderColor = theme.chromeDividerColor
        input.focusColor = theme.accentColor
        input.updateFocusBorder()
        outlineView.backgroundColor = theme.backgroundColor
        errorLabel.textColor = theme.unresolvedColor
        placeholderLabel.textColor = theme.chromeTertiaryColor
        coverageLabel.textColor = theme.chromeTertiaryColor
        statusLabel.textColor = theme.chromeSecondaryColor
        lastChipQuery = nil
        if !hintsEnabled { hideHints() }
        render()
    }

    func focusInput(selection: String? = nil) {
        refreshProjectState()
        if let selection, !selection.isEmpty { panelModel.setQueryFromSelection(selection) }
        input.stringValue = panelModel.query
        view.window?.makeFirstResponder(input)
        scheduleHints()
    }
    func refreshProjectState() {
        let sessions = appModel.querySessions
        if sessions.isEmpty { panelModel.updateProjectState(appModel.projectState) }
        else { panelModel.updateWorkspaceSessions(sessions) }
    }
    func moveResult(by delta: Int) {
        if delta < 0 { panelModel.selectPrevious() } else { panelModel.selectNext() }
        renderSelection()
        openSelection(focusReader: false)
    }
    func dismissHints() { hideHints() }
    /// Called after results render, so the reader can refresh its hit underlines.
    var onResultsChanged: (() -> Void)?
    /// Current hits inside one file's content, with their condition indices.
    /// Stale results are omitted: their offsets may belong to older bytes.
    func queryHits(forContent contentID: ContentID?) -> [(range: ByteRange, condition: Int)] {
        guard let contentID, !panelModel.isStale else { return [] }
        return panelModel.groups.filter { $0.contentID == contentID }.flatMap { group in
            group.matches.flatMap { match -> [(range: ByteRange, condition: Int)] in
                let value = match.value
                let ranges = value.conditionRanges.isEmpty
                    ? [value.conditionIndices.first ?? 0: [value.byteRange]] : value.conditionRanges
                return ranges.flatMap { condition, hits in hits.map { (range: $0, condition: condition) } }
            }
        }
    }
    var hasSearchFocus: Bool { inputHasFocus || view.window?.firstResponder === outlineView }
    var outlineViewForTesting: NSOutlineView { outlineView }
    var selfTestTheme: ReaderTheme { theme }
    func selfTestStyledMatch(_ match: SearchMatch) -> NSAttributedString { styledMatch(match) }
    func selfTestStyledGroup(path: String, count: Int) -> NSAttributedString { styledGroup(path: path, count: count) }

    func selfTestSetQuery(_ query: String) {
        input.stringValue = query
        controlTextDidChange(Notification(
            name: NSControl.textDidChangeNotification,
            object: input
        ))
    }

    func selfTestRevealTruncationRow() {
        reloadTask?.cancel()
        reloadTask = nil
        render()
        for group in panelModel.groups {
            outlineView.expandItem(group)
        }
        outlineView.layoutSubtreeIfNeeded()
        outlineView.window?.displayIfNeeded()
        guard let message = panelModel.displayTruncationMessage else { return }
        for row in 0..<outlineView.numberOfRows
        where outlineView.item(atRow: row) as? String == message {
            outlineView.scrollRowToVisible(row)
            outlineView.layoutSubtreeIfNeeded()
            outlineView.window?.displayIfNeeded()
            return
        }
    }

    var selfTestOutlineState: (
        totalRows: Int,
        groupRows: Int,
        matchRows: Int,
        truncationRows: Int,
        truncationVisible: Bool,
        truncationDiagnostic: [String: String]?,
        status: String,
        searching: Bool
    ) {
        let totalRows = outlineView.numberOfRows
        var groupRows = 0
        var matchRows = 0
        var truncationRows = 0
        var truncationVisible = false
        var diagnosticRow: [String: String]?
        for row in 0..<totalRows {
            switch outlineView.item(atRow: row) {
            case is SearchPanelModel.Group:
                groupRows += 1
            case is SearchPanelModel.Match:
                matchRows += 1
            case let message as String
                where message == panelModel.displayTruncationMessage:
                truncationRows += 1
                let frame = outlineView.rect(ofRow: row)
                let visibleRect = outlineView.visibleRect
                let intersection = frame.intersection(visibleRect)
                truncationVisible = view.window?.isVisible == true
                    && !intersection.isNull
                    && intersection.width > 0
                    && intersection.height > 0
                diagnosticRow = [
                    "truncationRow": String(row),
                    "windowVisible": String(view.window?.isVisible == true),
                    "rowRect": NSStringFromRect(frame),
                    "visibleRect": NSStringFromRect(visibleRect),
                    "intersection": NSStringFromRect(intersection),
                ]
            default:
                break
            }
        }
        return (
            totalRows,
            groupRows,
            matchRows,
            truncationRows,
            truncationVisible,
            diagnosticRow,
            statusLabel.stringValue,
            panelModel.isSearching
        )
    }


    private func configureView() {
        view = NSView()
        view.wantsLayer = true
        input.delegate = self
        input.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        // The overlay draws the placeholder without resetting the active field editor.
        input.placeholderString = nil
        input.setAccessibilityLabel(localized("panel.search.input"))
        input.focusRingType = .none
        input.isEditable = true
        input.isSelectable = true
        input.isBezeled = false
        input.drawsBackground = false
        input.wantsLayer = true
        input.layer?.cornerRadius = 7
        input.layer?.borderWidth = 1
        input.heightAnchor.constraint(equalToConstant: 28).isActive = true
        input.setContentHuggingPriority(.defaultLow, for: .horizontal)
        input.onAcceptGhost = { [weak self] in
            guard let self, !self.fullGhost.isEmpty else { return false }
            self.setQuery(self.panelModel.query + self.fullGhost)
            return true
        }
        input.onPaste = { [weak self] text in
            guard let self, self.input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.contains(where: \.isWhitespace) else { return false }
            self.panelModel.setQueryFromSelection(text)
            self.input.stringValue = self.panelModel.query
            return true
        }
        for (button, title, key, action) in [
            (caseButton, "Aa", "panel.search.case", #selector(caseChanged)),
            (wordButton, "ab", "panel.search.word", #selector(wordChanged)),
            (regexButton, ".*", "panel.search.regex", #selector(regexChanged)),
        ] {
            configureButton(button, title: title, action: action)
            button.setButtonType(.toggle)
            button.toolTip = localized(key)
            button.setAccessibilityLabel(localized(key))
        }
        let history = button("⌄", #selector(showHistory))
        history.toolTip = localized("panel.query.history")
        history.setAccessibilityLabel(localized("panel.query.history"))
        let help = button("?", #selector(showHelp))
        help.toolTip = localized("panel.query.help")
        help.setAccessibilityLabel(localized("panel.query.help"))
        let row = NSStackView(views: [input, caseButton, wordButton, regexButton, history, help])
        row.spacing = 6
        row.alignment = .centerY
        chips.identifier = .init("QueryChips")
        errorLabel.font = .systemFont(ofSize: 11.5)
        errorLabel.isHidden = true
        header.setViews([row, chips, errorLabel], in: .leading)
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 6
        header.edgeInsets = .init(top: 8, left: 10, bottom: 6, right: 10)
        header.wantsLayer = true
        row.widthAnchor.constraint(equalTo: header.widthAnchor, constant: -20).isActive = true
        chips.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
        statusLabel.font = .systemFont(ofSize: 11.5)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        summary.setViews([statusLabel, spacer, button("↑", #selector(previous)), button("↓", #selector(next))], in: .leading)
        summary.spacing = 8
        summary.edgeInsets = .init(top: 2, left: 10, bottom: 2, right: 10)
        summary.heightAnchor.constraint(equalToConstant: 26).isActive = true
        summary.wantsLayer = true
        let column = NSTableColumn(identifier: .init("SearchResult"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(clicked)
        outlineView.doubleAction = #selector(doubleClicked)
        outlineView.style = .plain
        outlineView.floatsGroupRows = true
        outlineView.indentationPerLevel = 0
        outlineView.rowSizeStyle = .custom
        outlineView.intercellSpacing = .zero
        outlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outlineView.setAccessibilityLabel(localized("panel.search.results"))
        outlineView.onReturn = { [weak self] in self?.openSelection(focusReader: true) }
        outlineView.onEscape = { [weak self] in self?.onReturnToReader() }
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        placeholderLabel.maximumNumberOfLines = 3
        placeholderLabel.font = .systemFont(ofSize: 12)
        placeholderLabel.lineBreakMode = .byWordWrapping
        coverageLabel.font = .systemFont(ofSize: 11)
        coverageLabel.maximumNumberOfLines = 2
        coverageLabel.lineBreakMode = .byWordWrapping
        let footer = NSStackView(views: [coverageLabel])
        footer.edgeInsets = .init(top: 5, left: 10, bottom: 5, right: 10)
        let stack = NSStackView(views: [header, summary, scrollView, footer])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        view.addSubview(placeholderLabel)
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor), stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor), summary.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor), footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
            placeholderLabel.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 14),
            placeholderLabel.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -14),
            placeholderLabel.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 16),
        ])
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let result = NSButton()
        configureButton(result, title: title, action: action)
        return result
    }
    private func configureButton(_ button: NSButton, title: String, action: Selector) {
        button.title = title
        button.target = self
        button.action = action
        button.isBordered = false
        button.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
    }
    private func conditionColor(_ index: Int) -> NSColor {
        let theme = theme
        return NSColor(name: nil) { appearance in
            let rgb = theme.queryConditionRGB(index: index, isDark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
            return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                           blue: CGFloat(rgb & 255) / 255, alpha: 1)
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSTextField === input else { return }
        hintDismissedQuery = nil
        hideHints()
        // A query is one line; pasted or dropped line breaks become spaces.
        if input.stringValue.contains(where: \.isNewline) {
            input.stringValue = String(input.stringValue.map { $0.isNewline ? " " : $0 })
        }
        panelModel.setQuery(input.stringValue)
        scheduleHints()
    }
    func controlTextDidBeginEditing(_ obj: Notification) {
        if obj.object as? NSTextField === input { scheduleHints() }
    }
    func controlTextDidEndEditing(_ obj: Notification) {
        if let field = obj.object as? NSTextField, field !== input {
            if field === chipEditor { commitChip(field) }
            return
        }
        idleTask?.cancel(); clearGhost()
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if control !== input {
            guard let field = control as? NSTextField, field === chipEditor else { return false }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                // Commit before AppKit tears down the editor; the end notification is then inert.
                commitChip(field)
                view.window?.makeFirstResponder(input)
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                chipEditor = nil
                field.delegate = nil
                lastChipQuery = nil
                renderChips()
                view.window?.makeFirstResponder(input)
                return true
            }
            return false
        }
        switch commandSelector {
        case #selector(NSResponder.insertTab(_:)) where !fullGhost.isEmpty:
            setQuery(panelModel.query + fullGhost)
        case #selector(NSResponder.cancelOperation(_:)):
            if bubble != nil || !fullGhost.isEmpty {
                hintDismissedQuery = panelModel.query
                panelModel.dismissSuggestions()
                hideHints()
            } else { onReturnToReader() }
        case #selector(NSResponder.moveUp(_:)) where textView.selectedRange() == NSRange(location: 0, length: 0): showHistory()
        case #selector(NSResponder.moveDown(_:)):
            view.window?.makeFirstResponder(outlineView)
            if panelModel.selectedIndex == nil { panelModel.selectNext() }
            renderSelection()
            openSelection(focusReader: false)
        case #selector(NSResponder.insertNewline(_:)):
            panelModel.commitQuery()
            openSelection(focusReader: true)
        default: return false
        }
        return true
    }
    @objc private func caseChanged() { panelModel.setCaseSensitive(caseButton.state == .on); view.window?.makeFirstResponder(input); scheduleHints() }
    @objc private func wordChanged() { panelModel.setWholeWord(wordButton.state == .on); view.window?.makeFirstResponder(input); scheduleHints() }
    @objc private func regexChanged() { panelModel.setRegex(regexButton.state == .on); view.window?.makeFirstResponder(input); scheduleHints() }
    @objc private func previous() { moveResult(by: -1) }
    @objc private func next() { moveResult(by: 1) }
    @objc private func clicked() { openSelection(focusReader: false); view.window?.makeFirstResponder(outlineView) }
    @objc private func doubleClicked() { openSelection(focusReader: true) }

    private func setQuery(_ text: String) {
        hideHints()
        input.stringValue = text
        panelModel.setQuery(text)
        view.window?.makeFirstResponder(input)
        input.currentEditor()?.selectedRange = NSRange(location: text.utf16.count, length: 0)
        hintDismissedQuery = nil
        scheduleHints()
    }

    private func renderChips() {
        guard chipEditor == nil, let query = panelModel.parsedQuery, query != lastChipQuery else { return }
        lastChipQuery = query
        chips.arrangedSubviews.forEach { chips.removeArrangedSubview($0); $0.removeFromSuperview() }
        chipTexts = []; chipRemovals = []
        func append(_ text: String, label: String, value: String = "", color: Int? = nil, remove: @escaping (inout ProjectSearchQuery) -> Void) {
            let index = chipTexts.count
            chipTexts.append(text); chipRemovals.append(remove)
            let edit = button(label, #selector(editChip(_:)))
            edit.tag = index
            // Caption in words, value in code font, as in the design's chips.
            let title = NSMutableAttributedString(string: label, attributes: [
                .font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: theme.chromeTertiaryColor])
            if !value.isEmpty {
                title.append(NSAttributedString(string: " " + value, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular), .foregroundColor: theme.foregroundColor]))
            }
            edit.attributedTitle = title
            edit.setAccessibilityLabel(title.string)
            let close = button("×", #selector(removeChip(_:)))
            close.tag = index
            var items: [NSView] = []
            if let color {
                let swatch = NSView()
                swatch.wantsLayer = true
                swatch.layer?.backgroundColor = conditionColor(color).cgColor
                swatch.layer?.cornerRadius = 2
                swatch.widthAnchor.constraint(equalToConstant: 8).isActive = true
                swatch.heightAnchor.constraint(equalToConstant: 8).isActive = true
                items.append(swatch)
            }
            items += [edit, close]
            let chip = NSStackView(views: items)
            chip.spacing = 5
            chip.edgeInsets = .init(top: 0, left: 6, bottom: 0, right: 2)
            chip.wantsLayer = true
            chip.layer?.cornerRadius = 6
            chip.layer?.borderWidth = 1
            chip.layer?.borderColor = theme.chromeDividerColor.cgColor
            chip.layer?.backgroundColor = theme.backgroundColor.cgColor
            chips.addArrangedSubview(chip)
        }
        for (i, terms) in query.includes.enumerated() {
            let text = terms.map(\.serialized).joined(separator: " OR ")
            append(text, label: localized("panel.query.include"), value: text, color: i) { $0.includes.remove(at: i) }
        }
        for (i, term) in query.excludes.enumerated() {
            append("-" + term.serialized, label: localized("panel.query.exclude"), value: term.serialized) { $0.excludes.remove(at: i) }
        }
        // Labels describe each condition in words; the chip's text stays the syntax.
        for (i, glob) in query.includeGlobs.enumerated() {
            append("path:" + ProjectSearchQuery.quoted(glob), label: localized("panel.query.path"), value: glob) { $0.includeGlobs.remove(at: i) }
        }
        for (i, glob) in query.excludeGlobs.enumerated() {
            append("-path:" + ProjectSearchQuery.quoted(glob), label: localized("panel.query.notpath"), value: glob) { $0.excludeGlobs.remove(at: i) }
        }
        for area in ProjectSearchQuery.Area.allCases where query.includedAreas.contains(area) {
            append("in:" + area.rawValue, label: localized("panel.query.chip.in"), value: localized("panel.query.area." + area.rawValue)) { $0.includedAreas.remove(area) }
        }
        for area in ProjectSearchQuery.Area.allCases where query.excludedAreas.contains(area) {
            append("-in:" + area.rawValue, label: localized("panel.query.chip.notin"), value: localized("panel.query.area." + area.rawValue)) { $0.excludedAreas.remove(area) }
        }
        if let near = query.near { append("near:\(near)", label: localizedFormat("panel.query.chip.near", Int64(near))) { $0.near = nil } }
        if query.sameFunction { append("same:fn", label: localized("panel.query.same")) { $0.sameFunction = false } }
        chips.addArrangedSubview(button(localized("panel.query.add"), #selector(showAddMenu)))
        chips.layoutSubtreeIfNeeded()
        chips.invalidateIntrinsicContentSize()
        header.arrangedSubviews.first(where: { $0.identifier?.rawValue == "QueryChips" })?.isHidden = query.isEmpty || query.isSimpleWord
    }
    @objc private func removeChip(_ sender: NSButton) {
        guard var query = panelModel.parsedQuery, chipRemovals.indices.contains(sender.tag) else { return }
        chipRemovals[sender.tag](&query)
        setQuery(query.serialized)
    }
    @objc private func editChip(_ sender: NSButton) {
        guard chipEditor == nil, chipTexts.indices.contains(sender.tag) else { return }
        hideHints()
        let field = NSTextField(string: chipTexts[sender.tag])
        field.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        field.tag = sender.tag
        field.delegate = self
        field.widthAnchor.constraint(equalToConstant: max(100, CGFloat(field.stringValue.count * 8))).isActive = true
        // NSStackView can insert a private gravity-area view between itself and a button.
        var container = sender.superview
        while let current = container, !(current is NSStackView) { container = current.superview }
        guard let stack = container as? NSStackView else { return }
        stack.insertArrangedSubview(field, at: stack.arrangedSubviews.firstIndex { $0 === sender } ?? 0)
        sender.isHidden = true
        chipEditor = field
        chips.invalidateIntrinsicContentSize()
        // selectText starts the native field editor itself. Calling makeFirstResponder
        // first starts a second editing transition whose end notification commits the chip.
        // Wait until the button action and stack layout finish before starting that one transition.
        DispatchQueue.main.async { [weak self, weak field] in
            guard let self, let field, self.chipEditor === field, field.window != nil else { return }
            self.view.layoutSubtreeIfNeeded()
            field.selectText(nil)
        }
    }
    private func commitChip(_ field: NSTextField) {
        guard field === chipEditor, chipTexts.indices.contains(field.tag) else { return }
        var texts = chipTexts
        texts[field.tag] = field.stringValue
        let text = texts.joined(separator: " ")
        chipEditor = nil
        field.delegate = nil
        lastChipQuery = nil
        setQuery(text)
        renderChips()
    }
    @objc private func showAddMenu() {
        let menu = NSMenu()
        for (key, value) in [("include", "lock"), ("or", "lock OR acquire"), ("exclude", "-test"),
                             ("path", "path:src/"), ("notpath", "-path:tests/"), ("code", "in:code"),
                             ("notcomment", "-in:comment"), ("near", "near:5"), ("same", "same:fn")] {
            let item = NSMenuItem(title: localized("panel.query." + key) + "   " + value, action: #selector(addCondition(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = value; menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 10, y: header.frame.minY), in: view)
    }
    @objc private func addCondition(_ item: NSMenuItem) {
        guard let value = item.representedObject as? String else { return }
        setQuery(panelModel.query.trimmingCharacters(in: .whitespacesAndNewlines) + (panelModel.query.isEmpty ? "" : " ") + value)
    }
    @objc private func showHistory() {
        hideHints()
        let menu = NSMenu()
        for entry in panelModel.history {
            let item = NSMenuItem(title: entry.text, action: #selector(applyHistory(_:)), keyEquivalent: "")
            item.representedObject = entry; item.target = self; menu.addItem(item)
        }
        if menu.items.isEmpty { menu.addItem(withTitle: localized("panel.query.history.empty"), action: nil, keyEquivalent: "") }
        menu.popUp(positioning: nil, at: NSPoint(x: 10, y: header.frame.minY), in: view)
    }
    @objc private func applyHistory(_ item: NSMenuItem) {
        guard let state = item.representedObject as? QueryState else { return }
        panelModel.applyHistory(state)
        input.stringValue = panelModel.query
        focusInput()
    }

    private func observe() {
        withObservationTracking {
            _ = panelModel.groups; _ = panelModel.selectedIndex; _ = panelModel.isSearching
            _ = panelModel.query; _ = panelModel.parsedQuery; _ = panelModel.syntaxError
            _ = panelModel.isStale; _ = panelModel.placeholder; _ = panelModel.totalMatches
            _ = panelModel.isTruncated; _ = panelModel.suggestions
            _ = panelModel.isCaseSensitive; _ = panelModel.isWholeWord; _ = panelModel.isRegex
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observe()
                guard self.reloadTask == nil else { return }
                self.reloadTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(34))
                    guard let self, !Task.isCancelled else { return }
                    self.reloadTask = nil
                    self.render()
                }
            }
        }
    }
    private func render() {
        if previouslySearching && !panelModel.isSearching { scheduleHints() }
        previouslySearching = panelModel.isSearching
        if input.stringValue != panelModel.query { input.stringValue = panelModel.query }
        caseButton.state = panelModel.isCaseSensitive ? .on : .off
        wordButton.state = panelModel.isWholeWord ? .on : .off
        regexButton.state = panelModel.isRegex ? .on : .off
        for button in [caseButton, wordButton, regexButton] {
            button.contentTintColor = button.state == .on ? theme.accentColor : theme.chromeSecondaryColor
            button.wantsLayer = true
            button.layer?.cornerRadius = 5
            button.layer?.backgroundColor = (button.state == .on ? theme.accentColor.withAlphaComponent(0.16) : .clear).cgColor
        }
        renderChips()
        errorLabel.isHidden = panelModel.syntaxError == nil
        errorLabel.stringValue = panelModel.syntaxErrorMessage ?? ""
        input.errorRange = panelModel.syntaxError.map { NSRange(location: $0.range.lowerBound, length: $0.range.count) }
        // With nothing earlier to keep, an invalid query shows only its error.
        let errorWithoutResults = panelModel.syntaxError != nil && panelModel.groups.isEmpty
        if panelModel.syntaxError != nil {
            statusLabel.stringValue = errorWithoutResults ? "" : localized("panel.query.previous")
        } else if panelModel.isStale {
            statusLabel.stringValue = localized(panelModel.isSearching ? "panel.query.stale" : "panel.query.stale.pending")
        } else if panelModel.parsedQuery?.groupsMatchesByLine == true {
            statusLabel.stringValue = localizedFormat("panel.query.rows", Int64(panelModel.totalMatches), Int64(panelModel.fileCount))
        } else {
            statusLabel.stringValue = localizedFormat("panel.search.summary", localizedFormat("panel.search.matches", Int64(panelModel.totalMatches)), localizedFormat("panel.search.files", Int64(panelModel.fileCount)))
        }
        let languages = panelModel.searchedLanguages.map { language in
            switch language {
            case .rust: "Rust"
            case .python: "Python"
            case .typescript: "TypeScript"
            case .javascript: "JavaScript"
            }
        }.joined(separator: ", ")
        var scope = [panelModel.query.isEmpty ? localized("panel.search.placeholder") : languages.isEmpty
            ? localizedFormat("panel.search.scope", Int64(panelModel.searchedFileCount))
            : localizedFormat("panel.query.coverage", Int64(panelModel.searchedFileCount), languages)]
        if panelModel.excludedFileCount > 0 { scope.append(localizedFormat("panel.query.path.excluded", Int64(panelModel.excludedFileCount))) }
        let ruleExcluded = panelModel.projectExcludedPathCount ?? appModel.fileTree?.ruleExcludedPaths.count ?? 0
        if ruleExcluded > 0 { scope.append(localizedFormat("main.rules.excluded", Int64(ruleExcluded))) }
        if panelModel.nonSourcePathCount > 0 { scope.append(localizedFormat("panel.query.nonsource", Int64(panelModel.nonSourcePathCount))) }
        if panelModel.regexSkippedPathCount > 0 { scope.append(localizedFormat("panel.query.regex.skipped", Int64(panelModel.regexSkippedPathCount))) }
        if panelModel.isTruncated { scope.append(localizedFormat("panel.query.conditions.truncated", panelModel.truncatedConditionIndices.sorted().map { String($0 + 1) }.joined(separator: ", "))) }
        if let truncated = panelModel.displayTruncationMessage { scope.append(truncated) }
        coverageLabel.stringValue = errorWithoutResults ? "" : scope.joined(separator: " · ")
        placeholderLabel.stringValue = panelModel.placeholder
        placeholderLabel.isHidden = !panelModel.groups.isEmpty || panelModel.placeholder.isEmpty || errorWithoutResults
        let alpha: CGFloat = panelModel.isStale ? 0.45 : 1
        if outlineView.alphaValue != alpha {
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { outlineView.alphaValue = alpha }
            else { NSAnimationContext.runAnimationGroup { $0.duration = 0.2; outlineView.animator().alphaValue = alpha } }
        }
        syncingSelection = true
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
        renderSelection()
        syncingSelection = false
        onResultsChanged?()
    }
    private func renderSelection() {
        guard let selected = panelModel.selectedIndex, let item = item(atFlatIndex: selected) else { return }
        let wasSyncing = syncingSelection
        syncingSelection = true
        let row = outlineView.row(forItem: item.1)
        if row >= 0 { outlineView.selectRowIndexes([row], byExtendingSelection: false); outlineView.scrollRowToVisible(row) }
        syncingSelection = wasSyncing
    }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let group = item as? SearchPanelModel.Group { return group.matches.count }
        return panelModel.groups.count + (panelModel.displayTruncationMessage == nil ? 0 : 1)
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let group = item as? SearchPanelModel.Group { return group.matches[index] }
        return panelModel.groups.indices.contains(index) ? panelModel.groups[index] as Any : panelModel.displayTruncationMessage! as Any
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { item is SearchPanelModel.Group }
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { item is SearchPanelModel.Group }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { item is SearchPanelModel.Match && !panelModel.isStale }
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat { item is SearchPanelModel.Group ? 25 : 21 }
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        if item is SearchPanelModel.Group {
            return QueryGroupRowView(fill: theme.chromeColor, divider: theme.chromeDividerColor)
        }
        return ThemedTableRowView(selectionColor: theme.chromeSelectionColor)
    }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let group = item as? SearchPanelModel.Group {
            let label = NSTextField(labelWithAttributedString: styledGroup(path: group.path + (group.isTruncated ? " · " + localized("panel.search.truncated") : ""), count: group.matches.count))
            label.toolTip = group.path
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            // Which conditions hit inside this file, after the count.
            let conditions = Set(group.matches.flatMap { $0.value.conditionIndices }).sorted()
            let swatches = conditions.map { condition -> NSView in
                let swatch = NSView(); swatch.wantsLayer = true
                swatch.layer?.backgroundColor = conditionColor(condition).cgColor; swatch.layer?.cornerRadius = 2
                swatch.widthAnchor.constraint(equalToConstant: 8).isActive = true
                swatch.heightAnchor.constraint(equalToConstant: 8).isActive = true
                return swatch
            }
            let row = NSStackView(views: [label] + swatches)
            row.spacing = 4
            if !swatches.isEmpty { row.setCustomSpacing(6, after: label) }
            // Keep child result columns flush while reserving a gutter for the group's disclosure button.
            row.edgeInsets = .init(top: 0, left: 20, bottom: 0, right: 10)
            return row
        }
        if let message = item as? String {
            let label = NSTextField(labelWithString: message); label.textColor = theme.warningColor; return label
        }
        guard let match = item as? SearchPanelModel.Match else { return nil }
        let repeated: Bool = if let index = flatIndex(of: match), index > 0, let previous = self.item(atFlatIndex: index - 1) {
            match.value.symbolName != nil && previous.1.value.pathID == match.value.pathID && previous.1.value.symbolName == match.value.symbolName
        } else { false }
        let symbol = NSTextField(labelWithString: repeated ? "│" : (match.value.symbolName ?? ""))
        symbol.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        symbol.textColor = repeated ? theme.chromeDividerColor : theme.chromeSecondaryColor
        symbol.toolTip = match.value.symbolName
        symbol.lineBreakMode = .byTruncatingTail
        symbol.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let swatches = NSStackView()
        swatches.spacing = 2
        swatches.widthAnchor.constraint(equalToConstant: 22).isActive = true
        for condition in match.value.conditionIndices {
            let swatch = NSView(); swatch.wantsLayer = true
            swatch.layer?.backgroundColor = conditionColor(condition).cgColor; swatch.layer?.cornerRadius = 2
            swatch.widthAnchor.constraint(equalToConstant: match.value.conditionIndices.count > 2 ? 4 : 8).isActive = true
            swatch.heightAnchor.constraint(equalToConstant: 8).isActive = true
            swatches.addArrangedSubview(swatch)
        }
        let line = NSTextField(labelWithString: String(match.value.line))
        line.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        line.textColor = theme.lineNumberColor; line.alignment = .right
        line.widthAnchor.constraint(equalToConstant: 34).isActive = true
        let text = NSTextField(labelWithAttributedString: styledMatch(match.value))
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        text.lineBreakMode = .byTruncatingTail
        let row = NSStackView(views: [symbol, swatches, line, text])
        row.spacing = 0
        row.setCustomSpacing(8, after: line)
        row.edgeInsets = .init(top: 1, left: 10, bottom: 1, right: 10)
        row.toolTip = match.value.lineText
        return row
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !syncingSelection, let match = outlineView.item(atRow: outlineView.selectedRow) as? SearchPanelModel.Match,
              let index = flatIndex(of: match) else { return }
        panelModel.select(index)
        if view.window?.firstResponder === outlineView, NSApp.currentEvent?.type == .keyDown { openSelection(focusReader: false) }
    }
    private func flatIndex(of match: SearchPanelModel.Match) -> Int? {
        var offset = 0
        for group in panelModel.groups {
            if let index = group.matches.firstIndex(where: { $0 === match }) { return offset + index }
            offset += group.matches.count
        }
        return nil
    }
    private func item(atFlatIndex index: Int) -> (SearchPanelModel.Group, SearchPanelModel.Match)? {
        var index = index
        for group in panelModel.groups { if index < group.matches.count { return (group, group.matches[index]) }; index -= group.matches.count }
        return nil
    }
    private func styledGroup(path: String, count: Int) -> NSAttributedString {
        NSAttributedString(string: path + "  \(count)", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .medium), .foregroundColor: theme.foregroundColor, .paragraphStyle: Self.singleLine(.byTruncatingMiddle)])
    }
    private func styledMatch(_ match: SearchMatch) -> NSAttributedString {
        let value = NSMutableAttributedString(string: match.lineText, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular), .foregroundColor: theme.foregroundColor])
        let bytes = Array(match.lineText.utf8)
        var firstHit = value.length
        if bytes.count == Int(match.lineTextRange.length) {
            let map = ByteUTF16Map(validUTF8: bytes)
            let conditions = match.conditionRanges.isEmpty ? [match.conditionIndices.first ?? 0: [match.byteRange]] : match.conditionRanges
            for (condition, ranges) in conditions.sorted(by: { $0.key < $1.key }) {
                for hit in ranges {
                    let lower = max(hit.lowerBound, match.lineTextRange.lowerBound)
                    let upper = min(hit.upperBound, match.lineTextRange.upperBound)
                    guard lower < upper, let range = map.nsRange(byteLowerBound: Int(lower - match.lineTextRange.lowerBound), byteUpperBound: Int(upper - match.lineTextRange.lowerBound)) else { continue }
                    firstHit = min(firstHit, range.location)
                    value.addAttributes([.underlineStyle: NSUnderlineStyle.thick.rawValue, .underlineColor: conditionColor(condition)], range: range)
                }
            }
        }
        return Self.singleLineMatch(value, prefixLength: 0, hitLocation: firstHit)
    }
    /// Attributed strings replace the label's line break mode, so every result
    /// carries its own single-line paragraph style.
    static func singleLine(_ mode: NSLineBreakMode) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = mode
        return style
    }

    /// Drops the source indentation after the line number (never past the hit)
    /// and truncates the tail so a long line stays on one row.
    static func singleLineMatch(
        _ value: NSMutableAttributedString,
        prefixLength: Int,
        hitLocation: Int
    ) -> NSAttributedString {
        let text = value.string as NSString
        var end = prefixLength
        while end < min(hitLocation, text.length),
              let scalar = UnicodeScalar(text.character(at: end)),
              scalar == " " || scalar == "\t"
        {
            end += 1
        }
        value.deleteCharacters(in: NSRange(location: prefixLength, length: end - prefixLength))
        value.addAttribute(.paragraphStyle, value: singleLine(.byTruncatingTail),
                           range: NSRange(location: 0, length: value.length))
        return value
    }


    private func openSelection(focusReader: Bool) {
        guard let request = panelModel.openSelection(), let match = panelModel.selectedMatch,
              let root = appModel.fileTree?.root else { return }
        hideHints()
        onOpen(root.appendingPathComponent(request.path), match.byteRange, request.contentID, focusReader)
    }

    private var inputHasFocus: Bool { input.currentEditor() != nil && view.window?.firstResponder === input.currentEditor() }
    private func scheduleHints() {
        idleTask?.cancel()
        guard hintsEnabled else { return }
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled, self.inputHasFocus,
                  self.hintDismissedQuery != self.panelModel.query, !self.panelModel.suggestions.isEmpty else { return }
            self.showSuggestions()
        }
    }
    private func showSuggestions() {
        let suggestions = Array(panelModel.suggestions.prefix(3))
        guard !suggestions.isEmpty else { return }
        let rows = suggestions.enumerated().map { index, suggestion -> NSView in
            let button = NSButton(title: suggestion.title, target: self, action: #selector(chooseSuggestion(_:)))
            let title = NSMutableAttributedString(string: suggestion.title, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular), .foregroundColor: theme.foregroundColor])
            title.append(NSAttributedString(string: "   " + suggestion.explanation, attributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: theme.chromeTertiaryColor]))
            button.attributedTitle = title
            button.tag = index; button.isBordered = false; button.alignment = .left
            button.font = .systemFont(ofSize: 11.5)
            button.toolTip = suggestion.query
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return button
        }
        // Topic on the left, how to act on the right edge of the bubble.
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: bubbleWidth - 22)]
        let heading = NSTextField(labelWithAttributedString: NSAttributedString(
            string: localized(panelModel.query.isEmpty ? "panel.query.hints.empty" : panelModel.totalMatches == 0 ? "panel.query.hints.relax" : "panel.query.hints.narrow")
                + "\t" + localized("panel.query.hints.actions"),
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: theme.chromeTertiaryColor, .paragraphStyle: paragraph]
        ))
        showBubble(rows: [heading] + rows)
        if let suggestion = suggestions.first(where: { $0.query.hasPrefix(panelModel.query) }) {
            startGhost(String(suggestion.query.dropFirst(panelModel.query.count)))
        }
    }
    @objc private func chooseSuggestion(_ button: NSButton) {
        guard panelModel.suggestions.indices.contains(button.tag) else { return }
        let suggestion = panelModel.suggestions[button.tag]
        hideHints()
        panelModel.applySuggestion(suggestion)
        input.stringValue = panelModel.query
        focusInput()
    }
    private func startGhost(_ text: String) {
        clearGhost()
        guard inputHasFocus, let editor = input.currentEditor() else { return }
        if input.stringValue.isEmpty {
            // An untouched empty field can still carry AppKit's initial selection sentinel.
            editor.selectedRange = NSRange(location: 0, length: 0)
        } else {
            guard editor.selectedRange.location == input.stringValue.utf16.count,
                  editor.selectedRange.length == 0 else { return }
        }
        fullGhost = text
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { input.ghost = text; return }
        ghostTask = Task { [weak self] in
            var shown = ""
            for character in text {
                try? await Task.sleep(for: .milliseconds(28))
                guard let self, !Task.isCancelled, self.inputHasFocus else { return }
                shown.append(character); self.input.ghost = shown
            }
        }
    }
    private func clearGhost() {
        ghostTask?.cancel(); ghostTask = nil; fullGhost = ""; input.ghost = ""
    }
    private func hideHints() {
        idleTask?.cancel(); clearGhost()
        if let bubble { bubble.parent?.removeChildWindow(bubble); bubble.orderOut(nil) }
        bubble = nil
    }
    private var bubbleWidth: CGFloat { min(440, max(220, input.bounds.width)) }
    private func showBubble(rows: [NSView]) {
        if let bubble { bubble.parent?.removeChildWindow(bubble); bubble.orderOut(nil) }
        guard let owner = view.window else { return }
        let width = bubbleWidth
        let content = NSStackView(views: rows)
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 4
        content.edgeInsets = .init(top: 8, left: 8, bottom: 8, right: 8)
        let background = QueryBubbleBackground()
        background.fillColor = theme.backgroundColor
        background.borderColor = theme.chromeDividerColor
        content.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: background.leadingAnchor), content.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            content.topAnchor.constraint(equalTo: background.topAnchor, constant: 6), content.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: CGFloat(rows.count * 28 + 22)), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.contentView = background
        let rect = owner.convertToScreen(input.convert(input.bounds, to: nil))
        let final = NSRect(x: rect.minX, y: rect.minY - panel.frame.height - 4, width: width, height: panel.frame.height)
        panel.setFrame(final, display: true)
        owner.addChildWindow(panel, ordered: .above)
        bubble = panel
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 0
            panel.setFrameOrigin(NSPoint(x: final.minX, y: final.minY - 6))
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                panel.animator().setFrame(final, display: true)
            }
        }
    }
    @objc private func showHelp() {
        hideHints()
        let rows = [("lock await", "and"), ("lock OR mutex", "or"), ("-test", "exclude"),
                    ("\"fn spawn(\"", "phrase"), ("/sp[a-z]+n/", "regex"), ("path:src/ -path:tests/", "path"),
                    ("in:code -in:comment", "area"), ("near:5", "near"), ("same:fn", "same")].map { syntax, key -> NSView in
            let label = NSTextField(labelWithString: syntax + "   " + localized("panel.query.help." + key))
            label.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
            label.textColor = theme.foregroundColor
            return label
        }
        showBubble(rows: rows)
    }
}

/// Opaque file header: its floating copy must cover the rows scrolling under it.
@MainActor
private final class QueryGroupRowView: NSTableRowView {
    private let fill: NSColor
    private let divider: NSColor
    init(fill: NSColor, divider: NSColor) {
        self.fill = fill
        self.divider = divider
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func drawBackground(in dirtyRect: NSRect) {
        fill.setFill()
        bounds.fill()
        divider.withAlphaComponent(0.6).setFill()
        NSRect(x: 0, y: isFlipped ? bounds.maxY - 1 : bounds.minY, width: bounds.width, height: 1).fill()
    }
}

@MainActor
private final class QueryOutlineView: NSOutlineView {
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 { onReturn?() }
        else if event.keyCode == 53 { onEscape?() }
        else { super.keyDown(with: event) }
    }
}

/// Paints completion separately from editable text, including the active field editor.
@MainActor
private final class QueryInputField: NSTextField {
    private let glyph = NSImageView()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = QueryInputCell(textCell: "")
        glyph.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        glyph.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: leadingAnchor, constant: QueryInputCell.leadingInset / 2 + 1),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    var onPaste: ((String) -> Bool)?
    var onAcceptGhost: (() -> Bool)?
    var ghost = "" {
        didSet {
            if let editor = currentEditor() as? NSTextView { attachOverlay(to: editor) }
            needsDisplay = true
            overlay.needsDisplay = true
        }
    }
    var errorRange: NSRange? { didSet { overlay.needsDisplay = true } }
    var ghostColor = NSColor.secondaryLabelColor { didSet { glyph.contentTintColor = ghostColor } }
    var errorColor = NSColor.systemRed
    var borderColor = NSColor.separatorColor
    var focusColor = NSColor.controlAccentColor
    private var editing = false
    func updateFocusBorder() {
        layer?.borderColor = (editing ? focusColor : borderColor).cgColor
        layer?.borderWidth = editing ? 1.5 : 1
    }
    private lazy var overlay = QueryInputOverlay(field: self)
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if overlay.superview == nil { addSubview(overlay); overlay.frame = bounds; overlay.autoresizingMask = [.width, .height] }
    }
    fileprivate func attachOverlay(to editor: NSTextView?) {
        editing = editor != nil
        updateFocusBorder()
        let host: NSView = editor.map { $0 as NSView } ?? self
        if overlay.superview !== host { host.addSubview(overlay) }
        overlay.frame = host.bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.needsDisplay = true
    }
    override func textDidBeginEditing(_ notification: Notification) {
        super.textDidBeginEditing(notification)
        if let editor = currentEditor() as? NSTextView { attachOverlay(to: editor) }
    }
    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        attachOverlay(to: nil)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "v", let text = NSPasteboard.general.string(forType: .string), onPaste?(text) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
    /// Top-left of the text at a UTF-16 offset, in the overlay's flipped space.
    private func textPoint(at offset: Int, in overlay: NSView, attributes: [NSAttributedString.Key: Any]) -> NSPoint {
        if let editor = currentEditor() as? NSTextView, let window {
            let screen = editor.firstRect(forCharacterRange: NSRange(location: offset, length: 0), actualRange: nil)
            let rect = overlay.convert(window.convertFromScreen(screen), from: nil)
            return NSPoint(x: rect.minX, y: rect.minY)
        }
        let textRect = cell?.drawingRect(forBounds: bounds) ?? bounds
        let text = stringValue as NSString
        let prefix = text.substring(to: min(offset, text.length)) as NSString
        // The cell lays text out with the field editor's 2pt line-fragment padding.
        return NSPoint(x: textRect.minX + 2 + prefix.size(withAttributes: attributes).width, y: textRect.minY)
    }
    fileprivate func paintOverlay(in overlay: NSView) {
        let font = font ?? .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let lineHeight = QueryInputCell.lineHeight(for: font)
        let origin = textPoint(at: stringValue.utf16.count, in: overlay, attributes: attrs)
        if ghost.isEmpty && stringValue.isEmpty {
            (localized("panel.query.placeholder") as NSString).draw(at: origin, withAttributes: [.font: font, .foregroundColor: ghostColor])
        }
        if !ghost.isEmpty {
            (ghost as NSString).draw(at: origin, withAttributes: [.font: font, .foregroundColor: ghostColor.withAlphaComponent(0.85)])
            let end = origin.x + (ghost as NSString).size(withAttributes: attrs).width + 6
            ghostColor.withAlphaComponent(0.5).setStroke()
            let keycap = NSBezierPath(roundedRect: NSRect(x: end, y: origin.y + (lineHeight - 14) / 2, width: 24, height: 14), xRadius: 3, yRadius: 3)
            keycap.lineWidth = 0.5; keycap.stroke()
            ("Tab" as NSString).draw(at: NSPoint(x: end + 3, y: origin.y + (lineHeight - 14) / 2 + 1), withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: ghostColor])
        }
        if let range = errorRange, NSMaxRange(range) <= stringValue.utf16.count {
            // A wavy underline under the offending span, like a spelling mark.
            let start = textPoint(at: range.location, in: overlay, attributes: attrs)
            let finish = textPoint(at: NSMaxRange(range), in: overlay, attributes: attrs)
            let y = start.y + lineHeight
            let path = NSBezierPath()
            var x = start.x
            path.move(to: NSPoint(x: x, y: y))
            var up = true
            while x < max(finish.x, start.x + 6) {
                x += 2
                path.line(to: NSPoint(x: x, y: y + (up ? -1.5 : 0)))
                up.toggle()
            }
            errorColor.setStroke(); path.lineWidth = 1; path.stroke()
        }
    }
}
@MainActor
private final class QueryInputOverlay: NSView {
    weak var field: QueryInputField?
    init(field: QueryInputField) { self.field = field; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { field?.paintOverlay(in: self) }
}

/// One line of text, vertically centered after the leading search glyph.
@MainActor
private final class QueryInputCell: NSTextFieldCell {
    static let leadingInset: CGFloat = 24
    static let trailingInset: CGFloat = 6
    static func lineHeight(for font: NSFont) -> CGFloat { ceil(font.ascender - font.descender + font.leading) }
    private let queryEditor = QueryFieldEditor()
    private var adjustingEditFrame = false
    override init(textCell string: String) {
        super.init(textCell: string)
        // A query is one line: no wrapping, horizontal scrolling, no typed newlines.
        usesSingleLineMode = true
        wraps = false
        isScrollable = true
        lineBreakMode = .byClipping
    }
    required init(coder: NSCoder) { super.init(coder: coder) }
    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        queryEditor.isFieldEditor = true
        queryEditor.focusRingType = .none
        queryEditor.queryField = controlView as? QueryInputField
        return queryEditor
    }
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        // The edit frame passed below is already centered; AppKit asks again for it,
        // and the editor must sit exactly where the idle text was drawn.
        guard !adjustingEditFrame else { return rect }
        let height = Self.lineHeight(for: font ?? .systemFont(ofSize: 12.5))
        return NSRect(x: rect.minX + Self.leadingInset, y: rect.minY + floor((rect.height - height) / 2),
                      width: max(0, rect.width - Self.leadingInset - Self.trailingInset), height: height)
    }
    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        let frame = drawingRect(forBounds: rect)
        adjustingEditFrame = true
        defer { adjustingEditFrame = false }
        super.edit(withFrame: frame, in: controlView, editor: textObj, delegate: delegate, event: event)
    }
    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        let frame = drawingRect(forBounds: rect)
        adjustingEditFrame = true
        defer { adjustingEditFrame = false }
        super.select(withFrame: frame, in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }
}
@MainActor
private final class QueryFieldEditor: NSTextView {
    weak var queryField: QueryInputField?
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { queryField?.attachOverlay(to: self) }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { queryField?.attachOverlay(to: nil) }
        return accepted
    }
    override func insertTab(_ sender: Any?) {
        if queryField?.onAcceptGhost?() == true { return }
        super.insertTab(sender)
    }
    override func paste(_ sender: Any?) {
        if let text = NSPasteboard.general.string(forType: .string), queryField?.onPaste?(text) == true { return }
        super.paste(sender)
    }
}

@MainActor
private final class QueryChipRow: NSView {
    var arrangedSubviews: [NSView] { subviews }
    func addArrangedSubview(_ view: NSView) { addSubview(view); invalidateIntrinsicContentSize() }
    func removeArrangedSubview(_ view: NSView) { view.removeFromSuperview(); invalidateIntrinsicContentSize() }
    override var isFlipped: Bool { true }
    private var lastWidth: CGFloat = 0
    private func positionChips(apply: Bool) -> CGFloat {
        let available = max(100, bounds.width)
        var x: CGFloat = 0
        var y: CGFloat = 0
        for chip in subviews {
            let width = min(available, chip.fittingSize.width)
            if x > 0 && x + width > available { x = 0; y += 28 }
            if apply { chip.frame = NSRect(x: x, y: y, width: width, height: 22) }
            x += width + 6
        }
        return subviews.isEmpty ? 0 : y + 22
    }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: positionChips(apply: false)) }
    override func layout() {
        super.layout()
        _ = positionChips(apply: true)
        if lastWidth != bounds.width { lastWidth = bounds.width; invalidateIntrinsicContentSize() }
    }
}

@MainActor
private final class QueryBubbleBackground: NSView {
    var fillColor = NSColor.windowBackgroundColor
    var borderColor = NSColor.separatorColor
    override func draw(_ dirtyRect: NSRect) {
        let body = NSBezierPath(roundedRect: NSRect(x: 0.5, y: 0.5, width: bounds.width - 1, height: bounds.height - 7), xRadius: 10, yRadius: 10)
        fillColor.setFill(); body.fill()
        borderColor.setStroke(); body.lineWidth = 1; body.stroke()
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: 22, y: bounds.height - 7))
        arrow.line(to: NSPoint(x: 27, y: bounds.height - 1))
        arrow.line(to: NSPoint(x: 32, y: bounds.height - 7))
        fillColor.setFill(); arrow.fill()
        borderColor.setStroke(); arrow.stroke()
    }
}
