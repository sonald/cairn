import AppKit
import CodeInsightAppModel
import CodeInsightReaderCore
import Observation

@MainActor
final class SearchPanel: NSWindowController,
    NSTextFieldDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSWindowDelegate
{
    private static let reloadInterval = Duration.milliseconds(34)

    private let appModel: AppModel
    private let panelModel = SearchPanelModel()
    private let input = NSTextField()
    private let caseButton = NSButton()
    private let regexButton = NSButton()
    private let outlineView = NSOutlineView()
    private let placeholderLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "0 matches in 0 files")
    private let truncatedLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let onOpen: (URL, UInt32) -> Void
    private var reloadTask: Task<Void, Never>?
    private weak var ownerWindow: NSWindow?

    init(appModel: AppModel, onOpen: @escaping (URL, UInt32) -> Void) {
        self.appModel = appModel
        self.onOpen = onOpen
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        super.init(window: panel)
        panel.delegate = self
        configureView()
        observe()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(relativeTo owner: NSWindow?) {
        ownerWindow = owner
        input.stringValue = ""
        panelModel.setQuery("")
        applyProjectState()
        render()

        guard let panel = window else { return }
        if let owner {
            panel.setFrameOrigin(NSPoint(
                x: owner.frame.midX - panel.frame.width / 2,
                y: owner.frame.midY - panel.frame.height / 2
            ))
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(input)
    }

    func refreshProjectState() {
        guard window?.isVisible == true else { return }
        applyProjectState()
    }

    private func applyProjectState() {
        let sessions = appModel.querySessions
        if sessions.isEmpty {
            panelModel.updateProjectState(appModel.projectState)
        } else {
            panelModel.updateWorkspaceSessions(sessions)
        }
    }

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
                truncationVisible = window?.isVisible == true
                    && !intersection.isNull
                    && intersection.width > 0
                    && intersection.height > 0
                diagnosticRow = [
                    "truncationRow": String(row),
                    "windowVisible": String(window?.isVisible == true),
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

    func outlineView(
        _ outlineView: NSOutlineView,
        numberOfChildrenOfItem item: Any?
    ) -> Int {
        if let group = item as? SearchPanelModel.Group {
            return group.matches.count
        }
        guard item == nil else { return 0 }
        return panelModel.groups.count
            + (panelModel.displayTruncationMessage == nil ? 0 : 1)
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        child index: Int,
        ofItem item: Any?
    ) -> Any {
        if let group = item as? SearchPanelModel.Group {
            return group.matches[index]
        }
        if panelModel.groups.indices.contains(index) {
            return panelModel.groups[index]
        }
        return panelModel.displayTruncationMessage!
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is SearchPanelModel.Group
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        item is SearchPanelModel.Group
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        shouldSelectItem item: Any
    ) -> Bool {
        item is SearchPanelModel.Match
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        heightOfRowByItem item: Any
    ) -> CGFloat {
        item is SearchPanelModel.Group ? 28 : 24
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        if let group = item as? SearchPanelModel.Group {
            let cell = reusableCell(identifier: "SearchGroup", in: outlineView)
            let text = NSMutableAttributedString(
                string: group.path,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: NSColor.labelColor,
                ]
            )
            text.append(NSAttributedString(
                string: "  \(group.matches.count)",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            ))
            cell.textField?.attributedStringValue = text
            return cell
        }
        if let message = item as? String {
            let cell = reusableCell(identifier: "SearchTruncation", in: outlineView)
            cell.textField?.stringValue = message
            cell.textField?.font = .systemFont(ofSize: 11, weight: .semibold)
            cell.textField?.textColor = .systemOrange
            return cell
        }
        guard let match = item as? SearchPanelModel.Match else { return nil }
        let cell = reusableCell(identifier: "SearchMatch", in: outlineView)
        cell.textField?.attributedStringValue = styledMatch(match)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard outlineView.selectedRow >= 0,
              let match = outlineView.item(atRow: outlineView.selectedRow)
                as? SearchPanelModel.Match,
              let index = flatIndex(of: match)
        else { return }
        panelModel.select(index)
    }

    func windowDidResignKey(_ notification: Notification) {
        dismiss(restoreFocus: false)
    }

    func controlTextDidChange(_ notification: Notification) {
        panelModel.setQuery(input.stringValue)
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            panelModel.selectPrevious()
        case #selector(NSResponder.moveDown(_:)):
            panelModel.selectNext()
        case #selector(NSResponder.insertNewline(_:)):
            openSelection()
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
        default:
            return false
        }
        return true
    }

    @objc private func caseSensitivityChanged(_ sender: NSButton) {
        panelModel.setCaseSensitive(sender.state == .on)
        window?.makeFirstResponder(input)
    }

    @objc private func regexChanged(_ sender: NSButton) {
        panelModel.setRegex(sender.state == .on)
        window?.makeFirstResponder(input)
    }

    @objc private func openClickedRow(_ sender: Any?) {
        guard outlineView.clickedRow >= 0,
              let match = outlineView.item(atRow: outlineView.clickedRow)
                as? SearchPanelModel.Match,
              let index = flatIndex(of: match)
        else { return }
        panelModel.select(index)
        openSelection()
    }

    private func configureView() {
        input.placeholderString = "Find in project"
        input.delegate = self
        input.font = .systemFont(ofSize: 15)
        input.setContentHuggingPriority(.defaultLow, for: .horizontal)

        configureToggle(
            caseButton,
            title: "Aa",
            accessibilityLabel: "Case sensitive",
            action: #selector(caseSensitivityChanged(_:))
        )
        configureToggle(
            regexButton,
            title: ".*",
            accessibilityLabel: "Regular expression",
            action: #selector(regexChanged(_:))
        )
        let header = NSStackView(views: [input, caseButton, regexButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("SearchResult"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(openClickedRow(_:))
        outlineView.refusesFirstResponder = true
        outlineView.rowSizeStyle = .custom
        outlineView.intercellSpacing = .zero

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.alignment = .center
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        truncatedLabel.stringValue = "results truncated"
        truncatedLabel.textColor = .systemOrange
        truncatedLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        truncatedLabel.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(header)
        content.addSubview(scrollView)
        content.addSubview(placeholderLabel)
        content.addSubview(statusLabel)
        content.addSubview(truncatedLabel)
        content.addSubview(spinner)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 30),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            input.heightAnchor.constraint(equalToConstant: 32),
            caseButton.widthAnchor.constraint(equalToConstant: 42),
            regexButton.widthAnchor.constraint(equalToConstant: 42),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -8),
            placeholderLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            statusLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            statusLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: truncatedLabel.leadingAnchor,
                constant: -8
            ),
            truncatedLabel.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            truncatedLabel.trailingAnchor.constraint(equalTo: spinner.leadingAnchor, constant: -8),
            spinner.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            spinner.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14),
        ])
        window?.contentView = content
    }

    private func configureToggle(
        _ button: NSButton,
        title: String,
        accessibilityLabel: String,
        action: Selector
    ) {
        button.title = title
        button.setButtonType(.toggle)
        button.bezelStyle = .texturedRounded
        button.font = .systemFont(ofSize: 12, weight: .semibold)
        button.target = self
        button.action = action
        button.toolTip = accessibilityLabel
        button.setAccessibilityLabel(accessibilityLabel)
    }

    private func reusableCell(
        identifier: String,
        in outlineView: NSOutlineView
    ) -> NSTableCellView {
        let viewIdentifier = NSUserInterfaceItemIdentifier(identifier)
        if let cell = outlineView.makeView(
            withIdentifier: viewIdentifier,
            owner: self
        ) as? NSTableCellView {
            return cell
        }

        let cell = NSTableCellView()
        cell.identifier = viewIdentifier
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func observe() {
        withObservationTracking {
            _ = panelModel.groups
            _ = panelModel.placeholder
            _ = panelModel.isSearching
            _ = panelModel.totalMatches
            _ = panelModel.fileCount
            _ = panelModel.isTruncated
            _ = panelModel.displayTruncationMessage
            _ = panelModel.selectedIndex
            _ = panelModel.isCaseSensitive
            _ = panelModel.isRegex
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observe()
                self.scheduleReload()
            }
        }
    }

    private func scheduleReload() {
        guard window?.isVisible == true, reloadTask == nil else { return }
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: Self.reloadInterval)
            guard !Task.isCancelled, let self else { return }
            reloadTask = nil
            render()
        }
    }

    private func render() {
        caseButton.state = panelModel.isCaseSensitive ? .on : .off
        regexButton.state = panelModel.isRegex ? .on : .off
        statusLabel.stringValue = "\(panelModel.totalMatches) matches in "
            + "\(panelModel.fileCount) files"
        truncatedLabel.isHidden = !panelModel.isTruncated
        placeholderLabel.stringValue = panelModel.placeholder
        placeholderLabel.isHidden = panelModel.placeholder.isEmpty
        if panelModel.isSearching {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }

        outlineView.reloadData()
        for group in panelModel.groups {
            outlineView.expandItem(group)
        }
        renderSelection()
    }

    private func renderSelection() {
        guard let index = panelModel.selectedIndex,
              let (group, match) = item(atFlatIndex: index)
        else {
            outlineView.deselectAll(nil)
            return
        }
        outlineView.expandItem(group)
        let row = outlineView.row(forItem: match)
        guard row >= 0 else { return }
        outlineView.selectRowIndexes([row], byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
    }

    private func item(
        atFlatIndex index: Int
    ) -> (SearchPanelModel.Group, SearchPanelModel.Match)? {
        var remaining = index
        for group in panelModel.groups {
            if remaining < group.matches.count {
                return (group, group.matches[remaining])
            }
            remaining -= group.matches.count
        }
        return nil
    }

    private func flatIndex(of match: SearchPanelModel.Match) -> Int? {
        var offset = 0
        for group in panelModel.groups {
            if let index = group.matches.firstIndex(where: { $0 === match }) {
                return offset + index
            }
            offset += group.matches.count
        }
        return nil
    }

    private func styledMatch(_ item: SearchPanelModel.Match) -> NSAttributedString {
        let match = item.value
        let prefix = String(format: "%5u  ", match.line)
        let value = NSMutableAttributedString(
            string: prefix + match.lineText,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ]
        )
        value.addAttribute(
            .foregroundColor,
            value: NSColor.secondaryLabelColor,
            range: NSRange(location: 0, length: prefix.utf16.count)
        )

        let bytes = Array(match.lineText.utf8)
        guard bytes.count == Int(match.lineTextRange.length) else { return value }
        let lower = max(match.byteRange.lowerBound, match.lineTextRange.lowerBound)
        let upper = min(match.byteRange.upperBound, match.lineTextRange.upperBound)
        guard lower < upper else { return value }
        let map = ByteUTF16Map(validUTF8: bytes)
        guard let range = map.nsRange(
            byteLowerBound: Int(lower - match.lineTextRange.lowerBound),
            byteUpperBound: Int(upper - match.lineTextRange.lowerBound)
        ) else { return value }
        value.addAttribute(
            .font,
            value: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold),
            range: NSRange(
                location: prefix.utf16.count + range.location,
                length: range.length
            )
        )
        return value
    }

    private func openSelection() {
        guard let request = panelModel.openSelection(),
              let root = appModel.fileTree?.root
        else { return }
        let file = root.appendingPathComponent(request.path)
        dismiss()
        onOpen(file, request.byteOffset)
    }

    private func dismiss(restoreFocus: Bool = true) {
        reloadTask?.cancel()
        reloadTask = nil
        panelModel.setQuery("")
        window?.orderOut(nil)
        if restoreFocus {
            ownerWindow?.makeKey()
        }
    }
}
