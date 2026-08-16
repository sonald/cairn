import AppKit
import CodeInsightAppModel
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

    override func loadView() {
        input.placeholderString = "Search commits"
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
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 480))
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
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            statusLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            statusLabel.heightAnchor.constraint(equalToConstant: 16),
        ])
        view = content
    }

    func show(relativeTo anchor: NSView) {
        loadViewIfNeeded()
        input.stringValue = ""
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

    func numberOfRows(in tableView: NSTableView) -> Int {
        (allowsWorktree ? 1 : 0) + appModel.commitPicker.filteredCommits.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        if allowsWorktree, row == 0 { return worktreeCell() }
        let commits = appModel.commitPicker.filteredCommits
        let index = row - (allowsWorktree ? 1 : 0)
        guard commits.indices.contains(index) else { return nil }
        return commitCell(commits[index])
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        allowsWorktree && row == 0 ? 48 : 58
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
        let count = numberOfRows(in: tableView)
        guard count > 0 else { return }
        let current = tableView.selectedRow >= 0 ? tableView.selectedRow : 0
        let next = (current + delta + count) % count
        tableView.selectRowIndexes([next], byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    private func chooseSelection() {
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        if allowsWorktree, row == 0 {
            choose(nil)
        } else {
            let commits = appModel.commitPicker.filteredCommits
            let index = row - (allowsWorktree ? 1 : 0)
            guard commits.indices.contains(index) else { return }
            choose(commits[index])
        }
        popover.performClose(nil)
    }

    func chooseCommit(_ revision: String) -> Bool {
        guard let commit = appModel.commitPicker.commits.first(where: {
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
        let rows = (firstCommitRow..<(firstCommitRow + commitRowCount))
        let viewport = tableView.visibleRect
        let frames = rows.map(tableView.rect(ofRow:))
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

    private func choose(_ commit: CommitInfo?) {
        onChoose(commit)
    }

    private func render() {
        guard isViewLoaded else { return }
        tableView.reloadData()
        let picker = appModel.commitPicker
        let row: Int
        if !picker.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            row = picker.filteredCommits.isEmpty
                ? (allowsWorktree ? 0 : -1)
                : (allowsWorktree ? 1 : 0)
        } else if let revision = selectedRevision(),
                  let index = picker.filteredCommits.firstIndex(where: {
                      $0.fullSHA == revision || $0.shortSHA == revision
                  })
        {
            row = index + (allowsWorktree ? 1 : 0)
        } else {
            row = allowsWorktree ? 0 : (picker.filteredCommits.isEmpty ? -1 : 0)
        }
        if row >= 0 {
            tableView.selectRowIndexes([row], byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        } else {
            tableView.deselectAll(nil)
        }

        if picker.isLoading {
            statusLabel.stringValue = "Loading history…"
        } else if picker.errorMessage != nil {
            statusLabel.stringValue = "Commit history unavailable."
        } else if !picker.query.isEmpty && picker.filteredCommits.isEmpty {
            statusLabel.stringValue = "No matching commits."
        } else {
            statusLabel.stringValue = "\(picker.filteredCommits.count) commits"
        }
    }

    private func observe() {
        withObservationTracking {
            _ = appModel.commitPicker.filteredCommits
            _ = appModel.commitPicker.currentCommit
            _ = appModel.commitPicker.isLoading
            _ = appModel.commitPicker.errorMessage
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.render()
                self.observe()
            }
        }
    }

    private func worktreeCell() -> NSView {
        let title = NSTextField(labelWithString: "Working Tree")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let detail = NSTextField(labelWithString: "Current files on disk")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [title, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        return rowCell(
            checkmarked: selectedRevision() == nil,
            content: labels
        )
    }

    private func commitCell(_ commit: CommitInfo) -> NSView {
        let sha = NSTextField(labelWithString: commit.shortSHA)
        sha.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        sha.textColor = .secondaryLabelColor
        sha.setContentHuggingPriority(.required, for: .horizontal)

        let summary = NSTextField(labelWithString: commit.summary)
        summary.font = .systemFont(ofSize: 13)
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
        metadata.textColor = .secondaryLabelColor
        metadata.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let badges = commit.branchNames.map {
            badge("⎇ \($0)", color: .systemBlue)
        } + commit.tagNames.map {
            badge("tag \($0)", color: .systemPurple)
        }
        let bottom = NSStackView(views: [metadata] + badges)
        bottom.orientation = .horizontal
        bottom.alignment = .centerY
        bottom.spacing = 5

        let labels = NSStackView(views: [top, bottom])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        return rowCell(
            checkmarked: selectedRevision().map {
                $0 == commit.fullSHA || $0 == commit.shortSHA
            } ?? false,
            content: labels
        )
    }

    private func rowCell(checkmarked: Bool, content: NSView) -> NSView {
        let check = NSImageView(image: NSImage(
            systemSymbolName: checkmarked ? "checkmark" : "circle",
            accessibilityDescription: checkmarked ? "Current version" : nil
        ) ?? NSImage())
        check.contentTintColor = checkmarked ? .controlAccentColor : .clear
        check.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false

        let cell = NSTableCellView()
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

    private func badge(_ value: String, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: " \(value) ")
        label.font = .systemFont(ofSize: 9, weight: .semibold)
        label.textColor = color
        label.drawsBackground = true
        label.backgroundColor = color.withAlphaComponent(0.12)
        label.wantsLayer = true
        label.layer?.cornerRadius = 4
        label.layer?.masksToBounds = true
        label.setContentHuggingPriority(.required, for: .horizontal)
        return label
    }
}
