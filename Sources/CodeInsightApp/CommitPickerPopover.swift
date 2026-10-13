import AppKit
import CodeInsightAppModel
import CodeInsightReaderCore
import CodeInsightReaderUI
import CodeInsightGit
import Observation

@MainActor
final class CommitPickerPopover: NSViewController,
    NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate
{
    private let appModel: AppModel
    private let allowsWorktree: Bool
    private let selectedRevision: () -> String?
    private let onChoose: (CommitInfo?) -> Void
    private let popover = NSPopover()
    private let input = NSTextField()
    private let tableView = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    init(
        appModel: AppModel,
        allowsWorktree: Bool = true,
        selectedRevision: @escaping () -> String?,
        onChoose: @escaping (CommitInfo?) -> Void
    ) {
        self.appModel = appModel
        self.allowsWorktree = allowsWorktree
        self.selectedRevision = selectedRevision
        self.onChoose = onChoose
        super.init(nibName: nil, bundle: nil)
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 560, height: 480)
        popover.contentViewController = self
        observe()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var theme = ReaderTheme(settings: ReaderSettings())

    func apply(settings: ReaderSettings) {
        theme = ReaderTheme(settings: settings)
        guard isViewLoaded else { return }
        view.appearance = cairnAppearance(for: theme.variant)
        view.layer?.backgroundColor = theme.chromeColor.cgColor
        statusLabel.textColor = theme.chromeSecondaryColor
        tableView.reloadData()
    }

    var selfTestTheme: ReaderTheme { theme }

    override func loadView() {
        input.placeholderString = localized("panel.commit.search")
        input.delegate = self
        input.font = .systemFont(ofSize: 14)
        input.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("Commit"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(chooseClickedRow(_:))
        tableView.refusesFirstResponder = true
        tableView.rowSizeStyle = .custom
        tableView.intercellSpacing = .zero

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = theme.chromeSecondaryColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 480))
        content.wantsLayer = true
        content.layer?.backgroundColor = theme.chromeColor.cgColor
        content.addSubview(input)
        content.addSubview(scrollView)
        content.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            input.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            input.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            input.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            input.heightAnchor.constraint(equalToConstant: 30),
            scrollView.topAnchor.constraint(equalTo: input.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -6),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -14),
            statusLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            statusLabel.heightAnchor.constraint(equalToConstant: 16),
        ])
        view = content
    }

    func show(relativeTo anchor: NSView) {
        loadViewIfNeeded()
        input.stringValue = ""
        keepSelectionOnRender = false
        appModel.commitPicker.setQuery("")
        render()
        popover.show(
            relativeTo: anchor.bounds,
            of: anchor,
            preferredEdge: .minY
        )
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            view.window?.makeFirstResponder(input)
        }
    }

    private enum Row {
        case worktree
        case resolved(CommitInfo)
        case commit(CommitInfo)
        case loadMore
    }

    /// Rebuilt on every render; the data source reads only this.
    private var rows: [Row] = []

    private func makeRows() -> [Row] {
        let picker = appModel.commitPicker
        return (allowsWorktree ? [.worktree] : [])
            + (picker.resolvedCommit.map { [Row.resolved($0)] } ?? [])
            + picker.filteredCommits.map(Row.commit)
            + (picker.hasMore ? [.loadMore] : [])
    }

    private func rowIndex(ofRevision revision: String) -> Int? {
        rows.firstIndex {
            switch $0 {
            case .commit(let commit), .resolved(let commit):
                commit.fullSHA == revision || commit.shortSHA == revision
            default: false
            }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        switch rows[row] {
        case .worktree: return worktreeCell()
        case .resolved(let commit): return commitCell(commit, resolved: true)
        case .commit(let commit): return commitCell(commit)
        case .loadMore: return loadMoreCell()
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row) else { return 58 }
        return switch rows[row] {
        case .worktree: 48
        case .loadMore: appModel.commitPicker.loadMoreError == nil ? 44 : 58
        case .resolved, .commit: 58
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        appModel.commitPicker.setQuery(input.stringValue)
        render()
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
        case #selector(NSResponder.insertNewline(_:)):
            chooseSelection()
        case #selector(NSResponder.cancelOperation(_:)):
            popover.performClose(nil)
        default:
            return false
        }
        return true
    }

    @objc private func chooseClickedRow(_ sender: NSTableView) {
        guard sender.clickedRow >= 0 else { return }
        sender.selectRowIndexes([sender.clickedRow], byExtendingSelection: false)
        chooseSelection()
    }

    private func moveSelection(by delta: Int) {
        let count = rows.count
        guard count > 0 else { return }
        let current = tableView.selectedRow >= 0 ? tableView.selectedRow : 0
        let next = (current + delta + count) % count
        tableView.selectRowIndexes([next], byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    private func chooseSelection() {
        let row = tableView.selectedRow
        guard rows.indices.contains(row) else { return }
        switch rows[row] {
        case .worktree: choose(nil)
        case .resolved(let commit), .commit(let commit): choose(commit)
        case .loadMore:
            loadMore()
            return
        }
        popover.performClose(nil)
    }

    @objc private func loadMore() {
        keepSelectionOnRender = true
        appModel.commitPicker.loadMore()
    }

    /// Closes the popover when its owning window goes away (§7.1).
    func dismiss() {
        popover.performClose(nil)
    }

    func chooseCommit(_ revision: String) -> Bool {        guard let commit = appModel.commitPicker.commits.first(where: {
            $0.fullSHA == revision || $0.shortSHA == revision
        }) else { return false }
        choose(commit)
        return true
    }

    func selfTestClose() {
        popover.performClose(nil)
    }

    var selfTestGeometry: (
        contentHeight: CGFloat,
        viewportHeight: CGFloat,
        commitRowFrames: [NSRect],
        visibleCommitRows: Int,
        shown: Bool
    ) {
        let firstCommitRow = allowsWorktree ? 1 : 0
        let commitRowCount = min(2, appModel.commitPicker.filteredCommits.count)
        let commitRows = (firstCommitRow..<(firstCommitRow + commitRowCount))
        let viewport = tableView.visibleRect
        let frames = commitRows.map(tableView.rect(ofRow:))
        let visibleRows = frames.filter {
            let intersection = $0.intersection(viewport)
            return !$0.isEmpty
                && intersection.width > 0
                && intersection.height > 0
        }.count
        return (
            view.bounds.height,
            tableView.enclosingScrollView?.contentView.bounds.height ?? 0,
            frames,
            visibleRows,
            popover.isShown
        )
    }

    /// Badge texts on one commit's row, only when the row is actually shown.
    func selfTestVisibleBadges(forCommit fullSHA: String) -> [String] {
        guard let row = rowIndex(ofRevision: fullSHA),
              let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: true),
              cell.window != nil
        else { return [] }
        cell.layoutSubtreeIfNeeded()
        func labels(_ view: NSView) -> [NSTextField] {
            ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap(labels)
        }
        return labels(cell)
            .filter { $0.drawsBackground && !$0.isHiddenOrHasHiddenAncestor && $0.frame.width > 0 }
            .map { $0.stringValue.trimmingCharacters(in: .whitespaces) }
    }

    private func choose(_ commit: CommitInfo?) {
        onChoose(commit)
    }

    private func render() {
        guard isViewLoaded else { return }
        let previousRow = tableView.selectedRow
        rows = makeRows()
        tableView.reloadData()
        let picker = appModel.commitPicker
        let firstCommitRow = rows.firstIndex {
            if case .worktree = $0 { false } else { true }
        }
        let row: Int
        if keepSelectionOnRender, rows.indices.contains(previousRow) {
            // A page is being appended: stay where the user was (the former
            // load-more row becomes the first new commit).
            row = previousRow
            if !picker.isLoadingMore { keepSelectionOnRender = false }
        } else if !picker.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            row = firstCommitRow ?? (allowsWorktree ? 0 : -1)
        } else if let revision = selectedRevision(),
                  let index = rowIndex(ofRevision: revision)
        {
            row = index
        } else {
            row = allowsWorktree ? 0 : (firstCommitRow ?? -1)
        }
        if row >= 0 {
            tableView.selectRowIndexes([row], byExtendingSelection: false)
            if row != previousRow { tableView.scrollRowToVisible(row) }
        } else {
            tableView.deselectAll(nil)
        }

        let listed = picker.filteredCommits.count + (picker.resolvedCommit == nil ? 0 : 1)
        if picker.isLoading {
            statusLabel.stringValue = localized("panel.commit.loading")
        } else if picker.errorMessage != nil {
            statusLabel.stringValue = localized("panel.commit.unavailable")
        } else if !picker.query.isEmpty && listed == 0 {
            statusLabel.stringValue = localized("panel.commit.empty")
        } else {
            statusLabel.stringValue = localizedFormat("panel.commit.count", Int64(listed))
        }
    }

    /// Set while a page is being appended so render() keeps the user's row.
    private var keepSelectionOnRender = false

    private func observe() {
        withObservationTracking {
            _ = appModel.commitPicker.filteredCommits
            _ = appModel.commitPicker.resolvedCommit
            _ = appModel.commitPicker.currentCommit
            _ = appModel.commitPicker.isLoading
            _ = appModel.commitPicker.errorMessage
            _ = appModel.commitPicker.hasMore
            _ = appModel.commitPicker.isLoadingMore
            _ = appModel.commitPicker.loadMoreError
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.render()
                self.observe()
            }
        }
    }

    private func worktreeCell() -> NSView {
        let title = NSTextField(labelWithString: localized("panel.commit.worktree"))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = theme.foregroundColor
        let detail = NSTextField(labelWithString: localized("panel.commit.onDisk"))
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = theme.chromeSecondaryColor
        let labels = NSStackView(views: [title, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        return rowCell(
            checkmarked: selectedRevision() == nil,
            content: labels,
            historical: false
        )
    }

    private func loadMoreCell() -> NSView {
        let picker = appModel.commitPicker
        let button = NSButton(
            title: localized(picker.isLoadingMore ? "panel.commit.loadingMore" : "panel.commit.loadMore"),
            target: self,
            action: #selector(loadMore)
        )
        button.bezelStyle = .inline
        button.controlSize = .small
        button.isEnabled = !picker.isLoadingMore
        var views: [NSView] = [button]
        if let reason = picker.loadMoreError {
            let error = NSTextField(labelWithString: localizedFormat("panel.commit.loadMore.failed", reason))
            error.font = .systemFont(ofSize: 10)
            error.textColor = theme.chromeSecondaryColor
            error.lineBreakMode = .byTruncatingTail
            views.append(error)
        }
        let labels = NSStackView(views: views)
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        return rowCell(checkmarked: false, content: labels, historical: false)
    }

    private func commitCell(_ commit: CommitInfo, resolved: Bool = false) -> NSView {
        let sha = NSTextField(labelWithString: commit.shortSHA)
        let selected = selectedRevision().map {
            $0 == commit.fullSHA || $0 == commit.shortSHA
        } ?? false
        sha.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        sha.textColor = selected ? theme.histColor : theme.chromeSecondaryColor
        sha.setContentHuggingPriority(.required, for: .horizontal)

        let summary = NSTextField(labelWithString: commit.summary)
        summary.font = .systemFont(ofSize: 13)
        summary.textColor = theme.foregroundColor
        summary.lineBreakMode = .byTruncatingTail
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let top = NSStackView(views: [sha, summary])
        top.orientation = .horizontal
        top.alignment = .centerY
        top.spacing = 10

        let metadata = NSTextField(
            labelWithString: "\(dateFormatter.string(from: commit.date)) · \(commit.authorName)"
        )
        metadata.font = .systemFont(ofSize: 10)
        metadata.textColor = theme.chromeSecondaryColor
        metadata.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let resolvedBadge = resolved
            ? [badge(localized("panel.commit.resolved"), color: theme.accentColor, fill: theme.histSoftColor)]
            : []
        let badges = resolvedBadge + commit.branchNames.map {
            badge("⎇ \($0)", color: theme.verifiedColor, fill: theme.mossSoftColor)
        } + commit.tagNames.map {
            badge(localizedFormat("panel.commit.tag", $0), color: theme.histColor, fill: theme.histSoftColor)
        }
        let bottom = NSStackView(views: [metadata] + badges)
        bottom.orientation = .horizontal
        bottom.alignment = .centerY
        bottom.spacing = 5

        let labels = NSStackView(views: [top, bottom])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        return rowCell(checkmarked: selected, content: labels, historical: true)
    }

    private func rowCell(checkmarked: Bool, content: NSView, historical: Bool) -> NSView {
        let check = NSImageView(image: NSImage(
            systemSymbolName: checkmarked ? "checkmark" : "circle",
            accessibilityDescription: checkmarked ? localized("panel.commit.current") : nil
        ) ?? NSImage())
        check.contentTintColor = checkmarked
            ? (historical ? theme.histColor : theme.accentColor) : .clear
        check.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false

        let cell = NSTableCellView()
        if checkmarked && historical {
            cell.wantsLayer = true
            cell.layer?.cornerRadius = 6
            cell.layer?.backgroundColor = theme.histSoftColor.cgColor
        }
        cell.addSubview(check)
        cell.addSubview(content)
        NSLayoutConstraint.activate([
            check.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            check.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            check.widthAnchor.constraint(equalToConstant: 14),
            check.heightAnchor.constraint(equalToConstant: 14),
            content.leadingAnchor.constraint(equalTo: check.trailingAnchor, constant: 8),
            content.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
            content.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func badge(_ value: String, color: NSColor, fill: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: " \(value) ")
        label.font = .systemFont(ofSize: 9.5, weight: .semibold)
        label.textColor = color
        label.drawsBackground = true
        label.backgroundColor = fill
        label.wantsLayer = true
        label.layer?.cornerRadius = 4
        label.layer?.masksToBounds = true
        label.setContentHuggingPriority(.required, for: .horizontal)
        return label
    }
}
