import AppKit
import CodeInsightAppModel

@MainActor
final class BookmarkPanel: NSWindowController, NSSearchFieldDelegate,
    NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate, NSWindowDelegate
{
    private let appModel: AppModel
    private let onOpen: (BookmarkRecord) -> Void
    private let onLineOpen: (BookmarkRecord, UInt32) -> Void
    private let searchField = NSSearchField()
    private let statsLabel = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let exportButton = NSButton(title: "Export Raw Copy…", target: nil, action: nil)
    private let tableView = NSTableView()
    private let noteView = NSTextView()
    private let copyButton = NSButton(title: "Copy as Markdown", target: nil, action: nil)
    private let markdownExportButton = NSButton(title: "Export Markdown…", target: nil, action: nil)
    private var rows: [BookmarkRecord] = []
    private var selectedID: UUID?
    private var lastCopiedMarkdown = ""

    init(
        appModel: AppModel,
        onOpen: @escaping (BookmarkRecord) -> Void,
        onLineOpen: @escaping (BookmarkRecord, UInt32) -> Void
    ) {
        self.appModel = appModel
        self.onOpen = onOpen
        self.onLineOpen = onLineOpen
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Bookmarks"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.contentMinSize = NSSize(width: 560, height: 460)
        panel.setContentSize(NSSize(width: 560, height: 460))
        super.init(window: panel)
        panel.delegate = self
        configureView()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(relativeTo owner: NSWindow?) {
        refresh()
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
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.makeFirstResponder(searchField)
    }

    func closePanel() {
        finalizeNote()
        window?.orderOut(nil)
    }

    func refresh() {
        let root = appModel.projectRoot?.standardizedFileURL.path
        rows = root.map { appModel.bookmarkModel.filteredRecords(
            projectPath: $0,
            query: searchField.stringValue
        ) } ?? []
        let counts = root.map { appModel.bookmarkModel.statusCounts(
            projectPath: $0,
            status: appModel.bookmarkStatus(for:)
        ) } ?? [:]
        statsLabel.stringValue = "\(rows.count) bookmarks" + counts.keys.sorted {
            $0.displayText < $1.displayText
        }.map { " · \($0.displayText): \(counts[$0] ?? 0)" }.joined()
        let hasError = appModel.bookmarkModel.storageError != nil
        errorLabel.stringValue = hasError
            ? "Bookmarks could not be read. The original file is unchanged."
            : ""
        errorLabel.isHidden = !hasError
        exportButton.isHidden = !hasError
        exportButton.isEnabled = appModel.bookmarkModel.rescueBytes != nil
        tableView.reloadData()
        if let id = selectedID, let row = rows.firstIndex(where: { $0.id == id }) {
            tableView.selectRowIndexes([row], byExtendingSelection: false)
        } else {
            clearSelectedNote()
        }
    }

    var selfTestState: (
        visible: Bool,
        rows: Int,
        rowIDs: [String],
        accessibilityLabel: String,
        exportVisible: Bool,
        exportEnabled: Bool,
        exportAccessibilityLabel: String
    ) {
        (
            window?.isVisible == true,
            rows.count,
            rows.map { $0.id.uuidString },
            tableView.accessibilityLabel() ?? "",
            !exportButton.isHidden,
            exportButton.isEnabled,
            exportButton.accessibilityLabel() ?? ""
        )
    }

    var selfTestGeometry: (
        content: NSRect,
        table: NSRect,
        row: NSRect,
        copy: NSRect,
        markdownExport: NSRect,
        copyVisible: Bool,
        markdownExportVisible: Bool
    ) {
        window?.contentView?.layoutSubtreeIfNeeded()
        return (
            window?.contentView?.bounds ?? .zero,
            tableView.visibleRect,
            tableView.numberOfRows > 0 ? tableView.rect(ofRow: 0) : .zero,
            copyButton.alignmentRect(forFrame: copyButton.frame),
            markdownExportButton.alignmentRect(forFrame: markdownExportButton.frame),
            !copyButton.isHidden && copyButton.alphaValue > 0,
            !markdownExportButton.isHidden && markdownExportButton.alphaValue > 0
        )
    }

    func selfTestSetFilter(_ query: String) {
        searchField.stringValue = query
        controlTextDidChange(Notification(
            name: NSControl.textDidChangeNotification,
            object: searchField
        ))
    }

    @discardableResult
    func selfTestSelectFirstRow() -> Bool {
        guard !rows.isEmpty else { return false }
        tableView.selectRowIndexes([0], byExtendingSelection: false)
        tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification, object: tableView))
        return selectedID != nil
    }

    func selfTestTypeNote(_ text: String) {
        noteView.string = text
        textDidChange(Notification(name: NSText.didChangeNotification, object: noteView))
    }

    func selfTestClearSelection() {
        tableView.deselectAll(nil)
        tableViewSelectionDidChange(Notification(
            name: NSTableView.selectionDidChangeNotification,
            object: tableView
        ))
    }

    func selfTestFinalizeNote() { finalizeNote() }

    func selfTestPressCopyMarkdown() { copyButton.performClick(nil) }

    var selfTestLastCopiedMarkdown: String { lastCopiedMarkdown }

    func selfTestPressExportMarkdown() { markdownExportButton.performClick(nil) }

    @discardableResult
    func selfTestPressFirstOpen() -> Bool {
        guard !rows.isEmpty else { return false }
        return selfTestPressOpen(id: rows[0].id)
    }

    @discardableResult
    func selfTestPressOpen(id: UUID) -> Bool {
        selfTestPress(title: "Open", id: id)
    }

    @discardableResult
    func selfTestPressOpenLine(id: UUID) -> Bool {
        selfTestPress(title: "Open line", id: id)
    }

    @discardableResult
    func selfTestPressReanchor(id: UUID) -> Bool {
        selfTestPress(title: "Re-anchor", id: id)
    }

    func selfTestRowToolTip(id: UUID) -> String? {
        guard let row = rows.firstIndex(where: { $0.id == id }) else { return nil }
        let cell = tableView(tableView, viewFor: tableView.tableColumns.first, row: row)
        return cell?.subviews.compactMap { $0 as? NSTextField }
            .first(where: { $0.toolTip != nil })?.toolTip ?? cell?.toolTip
    }

    private func selfTestPress(title: String, id: UUID) -> Bool {
        guard let row = rows.firstIndex(where: { $0.id == id }) else { return false }
        tableView.reloadData()
        guard let cell = tableView.view(
            atColumn: 0,
            row: row,
            makeIfNecessary: true
        ), let button = buttons(in: cell).first(where: { $0.title == title })
        else { return false }
        button.performClick(nil)
        return true
    }

    @discardableResult
    func selfTestPressExport() -> Bool {
        guard !exportButton.isHidden, exportButton.isEnabled else { return false }
        exportButton.performClick(nil)
        return true
    }

    var selfTestFirstRowToolTip: String? {
        rows.first.flatMap { selfTestRowToolTip(id: $0.id) }
    }

    func selfTestAXTree() -> [[String: String]] {
        var result: [[String: String]] = []
        func visit(_ view: NSView) {
            guard result.count < 64 else { return }
            let role = view.accessibilityRole().map(String.init(describing:)) ?? ""
            let label = view.accessibilityLabel() ?? ""
            let help = view.accessibilityHelp() ?? ""
            let value = view.accessibilityValue().map(String.init(describing:)) ?? ""
            if !role.isEmpty || !label.isEmpty || !help.isEmpty || !value.isEmpty {
                result.append(["role": role, "label": label, "help": help, "value": value])
            }
            view.subviews.forEach(visit)
        }
        if let content = window?.contentView { visit(content) }
        if !rows.isEmpty,
           let cell = tableView(
            tableView,
            viewFor: tableView.tableColumns.first,
            row: 0
           ) {
            visit(cell)
        }
        return result
    }

    @discardableResult
    func exportRawCopy(to url: URL) -> Bool {
        guard let bytes = appModel.bookmarkModel.rescueBytes else { return false }
        do {
            try bytes.write(to: url)
            return true
        } catch {
            return false
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let record = rows[row]
        let status = appModel.bookmarkModel.attemptMessage(for: record.id)
            ?? appModel.bookmarkStatus(for: record).displayText
        let cell = NSTableCellView()
        let title = NSTextField(labelWithString: appModel.bookmarkModel.title(for: record))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingMiddle
        let detail = NSTextField(wrappingLabelWithString:
            "\(record.path) · \(snapshotText(record)) · \(status)"
            + (record.note.isEmpty ? "" : "\n\(record.note)")
        )
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.toolTip = status
        let open = button("Open", action: #selector(openBookmark(_:)), record: record)
        let delete = button("Delete", action: #selector(deleteBookmark(_:)), record: record)
        let actions = NSStackView(views: [open, delete])
        actions.orientation = .horizontal
        actions.spacing = 4
        if appModel.bookmarkStatus(for: record) == .drifted {
            actions.addArrangedSubview(button(
                "Open line", action: #selector(openDriftedLine(_:)), record: record
            ))
            actions.addArrangedSubview(button(
                "Re-anchor", action: #selector(reanchorBookmark(_:)), record: record
            ))
        }
        let stack = NSStackView(views: [title, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        actions.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        cell.addSubview(actions)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -8),
            actions.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            actions.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        cell.setAccessibilityLabel("\(title.stringValue), \(detail.stringValue)")
        cell.toolTip = status
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 58 }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard rows.indices.contains(tableView.selectedRow) else {
            clearSelectedNote()
            return
        }
        let record = rows[tableView.selectedRow]
        selectedID = record.id
        noteView.string = record.note
    }

    @objc private func openBookmark(_ sender: NSButton) {
        guard let record = record(for: sender) else { return }
        onOpen(record)
    }

    @objc private func openDriftedLine(_ sender: NSButton) {
        guard let record = record(for: sender) else { return }
        onLineOpen(record, record.line)
    }

    @objc private func reanchorBookmark(_ sender: NSButton) {
        guard let record = record(for: sender) else { return }
        _ = appModel.reanchorBookmark(id: record.id, line: record.line)
        refresh()
    }

    @objc private func deleteBookmark(_ sender: NSButton) {
        guard let record = record(for: sender) else { return }
        let delete = { [weak self] in
            guard self?.appModel.bookmarkModel.delete(id: record.id) == true else { return }
            if self?.selectedID == record.id { self?.clearSelectedNote() }
            self?.refresh()
        }
        guard !record.note.isEmpty else { delete(); return }
        let alert = NSAlert()
        alert.messageText = "Delete bookmark?"
        alert.informativeText = "Its note will be removed."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if let window {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { delete() }
            }
        }
    }

    @objc private func exportRawCopy(_ sender: Any?) {
        if let path = ProcessInfo.processInfo.environment[
            "CAIRN_BOOKMARK_RAW_EXPORT_PATH"
        ] {
            _ = exportRawCopy(to: URL(fileURLWithPath: path))
            return
        }
        let save = NSSavePanel()
        save.nameFieldStringValue = "bookmarks.raw.json"
        guard let window else { return }
        save.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = save.url else { return }
            _ = self?.exportRawCopy(to: url)
        }
    }

    @objc private func copyMarkdown(_ sender: Any?) {
        lastCopiedMarkdown = markdownText()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(lastCopiedMarkdown, forType: .string)
    }

    @objc private func exportMarkdown(_ sender: Any?) {
        let text = markdownText()
        if let path = ProcessInfo.processInfo.environment["CAIRN_BOOKMARK_MARKDOWN_EXPORT_PATH"] {
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
            return
        }
        let save = NSSavePanel()
        save.nameFieldStringValue = "bookmarks.md"
        guard let window else { return }
        save.beginSheetModal(for: window) { response in
            guard response == .OK, let url = save.url else { return }
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func textDidChange(_ notification: Notification) {
        guard notification.object as? NSTextView === noteView, let selectedID,
              rows.contains(where: { $0.id == selectedID }),
              appModel.bookmarkModel.records.contains(where: { $0.id == selectedID })
        else {
            clearSelectedNote()
            return
        }
        _ = appModel.bookmarkModel.updateNote(id: selectedID, text: noteView.string)
        refresh()
    }

    func textDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextView === noteView else { return }
        finalizeNote()
    }

    func windowWillClose(_ notification: Notification) { finalizeNote() }

    func controlTextDidChange(_ notification: Notification) { refresh() }

    private func configureView() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        searchField.placeholderString = "Filter bookmarks"
        searchField.delegate = self
        searchField.setAccessibilityLabel("Filter bookmarks")
        statsLabel.font = .systemFont(ofSize: 11)
        statsLabel.textColor = .secondaryLabelColor
        errorLabel.textColor = .systemRed
        errorLabel.setAccessibilityLabel("Bookmark storage error")
        exportButton.target = self
        exportButton.action = #selector(exportRawCopy(_:))
        exportButton.setAccessibilityLabel("Export Raw Copy…")
        noteView.delegate = self
        noteView.isRichText = false
        noteView.setAccessibilityLabel("Bookmark note")
        copyButton.target = self
        copyButton.action = #selector(copyMarkdown(_:))
        copyButton.setAccessibilityLabel("Copy as Markdown")
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        markdownExportButton.target = self
        markdownExportButton.action = #selector(exportMarkdown(_:))
        markdownExportButton.setAccessibilityLabel("Export Markdown…")
        markdownExportButton.translatesAutoresizingMaskIntoConstraints = false
        let column = NSTableColumn(identifier: .init("bookmark"))
        column.width = 540
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityLabel("Bookmarks")
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let noteScroll = NSScrollView()
        noteScroll.documentView = noteView
        noteScroll.hasVerticalScroller = true
        noteScroll.translatesAutoresizingMaskIntoConstraints = false
        let header = NSStackView(views: [searchField, statsLabel])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        header.translatesAutoresizingMaskIntoConstraints = false
        searchField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        exportButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(header)
        content.addSubview(errorLabel)
        content.addSubview(exportButton)
        content.addSubview(scroll)
        content.addSubview(noteScroll)
        content.addSubview(copyButton)
        content.addSubview(markdownExportButton)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            errorLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            errorLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            errorLabel.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            exportButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            exportButton.topAnchor.constraint(equalTo: errorLabel.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: exportButton.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: noteScroll.topAnchor, constant: -8),
            noteScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            noteScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            noteScroll.heightAnchor.constraint(equalToConstant: 88),
            noteScroll.bottomAnchor.constraint(equalTo: copyButton.topAnchor, constant: -6),
            copyButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            copyButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            markdownExportButton.leadingAnchor.constraint(equalTo: copyButton.trailingAnchor, constant: 8),
            markdownExportButton.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),
            markdownExportButton.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -12),
        ])
    }

    private func button(_ title: String, action: Selector, record: BookmarkRecord) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .inline
        button.identifier = .init(record.id.uuidString)
        button.setAccessibilityLabel("\(title) bookmark")
        return button
    }

    private func record(for sender: NSButton) -> BookmarkRecord? {
        guard let id = sender.identifier?.rawValue else { return nil }
        return rows.first { $0.id.uuidString == id }
    }

    private func buttons(in view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons(in:))
    }

    private func snapshotText(_ record: BookmarkRecord) -> String {
        switch record.snapshot {
        case .worktree: "Worktree"
        case let .commit(fullOID): "Saved at \(fullOID.prefix(8))"
        }
    }

    private func markdownText() -> String {
        guard let root = appModel.projectRoot?.standardizedFileURL.path else { return "" }
        return appModel.bookmarkModel.markdown(
            projectPath: root,
            status: appModel.bookmarkStatus(for:)
        )
    }

    private func finalizeNote() {
        guard let selectedID,
              rows.contains(where: { $0.id == selectedID }),
              appModel.bookmarkModel.records.contains(where: { $0.id == selectedID })
        else {
            clearSelectedNote()
            return
        }
        _ = appModel.bookmarkModel.finalizeNote(id: selectedID)
        refresh()
    }

    private func clearSelectedNote() {
        selectedID = nil
        noteView.string = ""
    }
}
