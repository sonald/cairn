import AppKit
import CodeInsightAppModel
import CodeInsightCore
import CodeInsightReaderCore
import CodeInsightReaderUI

@MainActor
final class ReadingTrailView: NSView, NSTableViewDataSource,
    NSTableViewDelegate
{
    var onRestore: ((TrailNodeID) -> Void)?

    private struct Row {
        let id: TrailNodeID
        let depth: Int
        let isLastSibling: Bool
        let crossesSnapshot: Bool
    }

    private let titleLabel = NSTextField(labelWithString: "Reading Trail")
    private let breadcrumb = NSStackView()
    private let branchButton = NSButton(title: "⑂", target: nil, action: nil)
    private let divider = NSView()
    private let popover = NSPopover()
    private let tableView = NSTableView()
    private let detailDocument = ReadingTrailDocumentView()
    private let detailStack = NSStackView()
    private let detailText = NSTextField(wrappingLabelWithString: "")
    private let restoreButton = NSButton(
        title: "Restore this node",
        target: nil,
        action: nil
    )
    private var trail: ReadingTrail?
    private var store: ResolutionExplanationStore?
    private var rows: [Row] = []
    private var activePath: [TrailNodeID] = []
    private var selectedID: TrailNodeID?
    private var theme = ReaderTheme(settings: ReaderSettings())

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Reading Trail")

        titleLabel.font = .systemFont(ofSize: 10, weight: .bold)
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        breadcrumb.orientation = .horizontal
        breadcrumb.alignment = .centerY
        breadcrumb.spacing = 5
        breadcrumb.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        branchButton.bezelStyle = .accessoryBarAction
        branchButton.font = .systemFont(ofSize: 11, weight: .semibold)
        branchButton.toolTip = "Show the semantic trail and its branches (⌥⌘T)"
        branchButton.setAccessibilityLabel("Show Reading Trail branches")
        branchButton.target = self
        branchButton.action = #selector(showTrail(_:))
        branchButton.setContentHuggingPriority(.required, for: .horizontal)
        divider.wantsLayer = true

        let bar = NSStackView(views: [titleLabel, breadcrumb, branchButton])
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = 10
        addSubview(bar)
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            bar.centerYAnchor.constraint(equalTo: centerYAnchor),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
        ])
        configurePopover()
        apply(settings: ReaderSettings())
        render()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(settings: ReaderSettings) {
        theme = ReaderTheme(settings: settings)
        layer?.backgroundColor = theme.chromeHeaderColor.cgColor
        divider.layer?.backgroundColor = theme.chromeDividerColor.cgColor
        titleLabel.textColor = theme.accentColor
        branchButton.contentTintColor = theme.accentColor
        tableView.backgroundColor = theme.chromeColor
        popover.contentViewController?.view.layer?.backgroundColor =
            theme.chromeColor.cgColor
        detailDocument.layer?.backgroundColor = theme.chromeColor.cgColor
        detailText.textColor = theme.foregroundColor
        restoreButton.contentTintColor = theme.accentColor
        tableView.reloadData()
        renderDetail()
    }

    func display(
        trail: ReadingTrail,
        store: ResolutionExplanationStore
    ) {
        self.trail = trail
        self.store = store
        rows = flattenedRows(trail)
        activePath = path(to: trail.activeNodeID, in: trail)
        if selectedID.flatMap({ trail.nodes[$0] }) == nil {
            selectedID = trail.activeNodeID
        }
        render()
        tableView.reloadData()
        selectCurrentRow()
        renderDetail()
    }

    var branchCount: Int {
        guard let trail else { return 0 }
        return trail.nodes.keys.filter { id in
            trail.edges.filter { $0.from == id }.count > 1
        }.count
    }

    var breadcrumbTitles: [String] {
        guard let trail else { return [] }
        return activePath.compactMap { trail.nodes[$0] }.map(displayName)
    }

    var breadcrumbText: String {
        guard let trail else { return "" }
        return activePath.enumerated().map { index, id in
            guard let node = trail.nodes[id] else { return "" }
            if index == 0 { return displayName(node) }
            let cause = incomingEdge(to: id, in: trail).map {
                causeText($0.cause)
            } ?? "navigate"
            return "\(cause) → \(displayName(node))"
        }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var popoverPaths: [String] {
        guard let trail else { return [] }
        return rows.compactMap { trail.nodes[$0.id]?.jump.path }
    }

    var detailValue: String { detailText.stringValue }
    var selectedTrailNodeID: TrailNodeID? { selectedID }
    var isPopoverShown: Bool { popover.isShown }
    var snapshotBoundaryCount: Int { rows.count(where: \.crossesSnapshot) }
    var popoverContentView: NSView? { popover.contentViewController?.view }

    func showPopover() {
        guard branchButton.isEnabled else { return }
        popover.show(
            relativeTo: branchButton.bounds,
            of: branchButton,
            preferredEdge: .maxY
        )
        selectCurrentRow()
    }

    func closePopover() { popover.close() }

    func selectNode(path: String) -> Bool {
        guard let row = rows.firstIndex(where: {
            trail?.nodes[$0.id]?.jump.path == path
        }) else { return false }
        selectedID = rows[row].id
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        renderDetail()
        return true
    }

    func restoreSelectedNode() {
        restore(nil)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard rows.indices.contains(row),
              let trail,
              let node = trail.nodes[rows[row].id]
        else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("ReadingTrailNode")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self)
            as? ReadingTrailCellView ?? ReadingTrailCellView()
        cell.identifier = identifier
        let incoming = incomingEdge(to: node.id, in: trail)
        cell.display(
            title: displayName(node),
            gutter: gutter(for: rows[row]),
            cause: incoming.map { causeText($0.cause) } ?? "root",
            snapshot: snapshotText(node.jump),
            badge: incoming.flatMap(badgeText),
            isCurrent: node.id == trail.activeNodeID,
            crossesSnapshot: rows[row].crossesSnapshot,
            theme: theme
        )
        return cell
    }

    func tableView(
        _ tableView: NSTableView,
        rowViewForRow row: Int
    ) -> NSTableRowView? {
        let view = ThemeSelectionRowView()
        view.selectionColor = theme.chromeSelectionColor
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard rows.indices.contains(tableView.selectedRow) else { return }
        selectedID = rows[tableView.selectedRow].id
        renderDetail()
    }

    @objc private func showTrail(_ sender: Any?) { showPopover() }

    @objc private func restore(_ sender: Any?) {
        guard let selectedID else { return }
        popover.close()
        onRestore?(selectedID)
    }

    private func configurePopover() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 820, height: 520))
        content.wantsLayer = true
        let controller = NSViewController()
        controller.view = content
        controller.preferredContentSize = content.frame.size
        popover.contentViewController = controller
        popover.contentSize = content.frame.size
        popover.behavior = .transient

        let tableColumn = NSTableColumn(identifier: .init("Trail"))
        tableColumn.resizingMask = .autoresizingMask
        tableView.addTableColumn(tableColumn)
        tableView.headerView = nil
        tableView.rowHeight = 56
        tableView.intercellSpacing = .zero
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityLabel("Reading Trail graph")
        let tableScroll = NSScrollView()
        tableScroll.documentView = tableView
        tableScroll.hasVerticalScroller = true
        tableScroll.autohidesScrollers = true
        tableScroll.drawsBackground = false
        tableScroll.translatesAutoresizingMaskIntoConstraints = false

        let leftHeader = trailHeader(title: "READING TRAIL", detail: "THIS SESSION")
        let left = NSView()
        left.translatesAutoresizingMaskIntoConstraints = false
        left.addSubview(leftHeader)
        left.addSubview(tableScroll)

        detailDocument.wantsLayer = true
        detailDocument.translatesAutoresizingMaskIntoConstraints = false
        detailStack.orientation = .vertical
        detailStack.alignment = .leading
        detailStack.spacing = 14
        detailStack.translatesAutoresizingMaskIntoConstraints = false
        detailText.font = .systemFont(ofSize: 12)
        detailText.maximumNumberOfLines = 0
        detailText.isSelectable = true
        detailText.setAccessibilityLabel("Trail node details")
        restoreButton.bezelStyle = .rounded
        restoreButton.target = self
        restoreButton.action = #selector(restore(_:))
        restoreButton.setAccessibilityLabel("Restore this trail node")
        detailStack.addArrangedSubview(detailText)
        detailStack.addArrangedSubview(restoreButton)
        detailDocument.addSubview(detailStack)
        let detailScroll = NSScrollView()
        detailScroll.documentView = detailDocument
        detailScroll.hasVerticalScroller = true
        detailScroll.autohidesScrollers = true
        detailScroll.drawsBackground = false
        detailScroll.translatesAutoresizingMaskIntoConstraints = false
        let rightHeader = trailHeader(title: "TRAIL NODE", detail: "AUDIT")
        let right = NSView()
        right.translatesAutoresizingMaskIntoConstraints = false
        right.addSubview(rightHeader)
        right.addSubview(detailScroll)

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(left)
        split.addArrangedSubview(right)
        content.addSubview(split)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            split.topAnchor.constraint(equalTo: content.topAnchor),
            split.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            left.widthAnchor.constraint(equalToConstant: 455),
            right.widthAnchor.constraint(greaterThanOrEqualToConstant: 340),
            leftHeader.leadingAnchor.constraint(equalTo: left.leadingAnchor),
            leftHeader.trailingAnchor.constraint(equalTo: left.trailingAnchor),
            leftHeader.topAnchor.constraint(equalTo: left.topAnchor),
            tableScroll.leadingAnchor.constraint(equalTo: left.leadingAnchor),
            tableScroll.trailingAnchor.constraint(equalTo: left.trailingAnchor),
            tableScroll.topAnchor.constraint(equalTo: leftHeader.bottomAnchor),
            tableScroll.bottomAnchor.constraint(equalTo: left.bottomAnchor),
            rightHeader.leadingAnchor.constraint(equalTo: right.leadingAnchor),
            rightHeader.trailingAnchor.constraint(equalTo: right.trailingAnchor),
            rightHeader.topAnchor.constraint(equalTo: right.topAnchor),
            detailScroll.leadingAnchor.constraint(equalTo: right.leadingAnchor),
            detailScroll.trailingAnchor.constraint(equalTo: right.trailingAnchor),
            detailScroll.topAnchor.constraint(equalTo: rightHeader.bottomAnchor),
            detailScroll.bottomAnchor.constraint(equalTo: right.bottomAnchor),
            detailStack.leadingAnchor.constraint(equalTo: detailDocument.leadingAnchor, constant: 16),
            detailStack.trailingAnchor.constraint(equalTo: detailDocument.trailingAnchor, constant: -16),
            detailStack.topAnchor.constraint(equalTo: detailDocument.topAnchor, constant: 16),
            detailStack.bottomAnchor.constraint(lessThanOrEqualTo: detailDocument.bottomAnchor, constant: -16),
            detailDocument.widthAnchor.constraint(equalTo: detailScroll.contentView.widthAnchor),
            detailDocument.heightAnchor.constraint(greaterThanOrEqualToConstant: 486),
            detailText.widthAnchor.constraint(equalTo: detailStack.widthAnchor),
        ])
    }

    private func trailHeader(title: String, detail: String) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 10, weight: .bold)
        titleLabel.textColor = .secondaryLabelColor
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        detailLabel.textColor = .tertiaryLabelColor
        let stack = NSStackView(views: [titleLabel, detailLabel])
        stack.orientation = .horizontal
        stack.distribution = .equalSpacing
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(stack)
        NSLayoutConstraint.activate([
            header.heightAnchor.constraint(equalToConstant: 34),
            stack.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])
        return header
    }

    private func render() {
        breadcrumb.arrangedSubviews.forEach {
            breadcrumb.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let titles = breadcrumbTitles
        if titles.isEmpty {
            let empty = NSTextField(
                labelWithString: "Explicit semantic navigation will appear here"
            )
            empty.font = .systemFont(ofSize: 11)
            empty.textColor = theme.chromeTertiaryColor
            empty.lineBreakMode = .byTruncatingTail
            breadcrumb.addArrangedSubview(empty)
        } else {
            if titles.count > 4 {
                breadcrumb.addArrangedSubview(crumbLabel("…", active: false))
            }
            let visibleIDs = Array(activePath.suffix(4))
            for (index, id) in visibleIDs.enumerated() {
                if index > 0, let trail,
                   let edge = incomingEdge(to: id, in: trail)
                {
                    let arrow = NSTextField(
                        labelWithString: "─\(causeText(edge.cause))→"
                    )
                    arrow.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
                    arrow.textColor = theme.chromeSecondaryColor
                    breadcrumb.addArrangedSubview(arrow)
                }
                guard let node = trail?.nodes[id] else { continue }
                breadcrumb.addArrangedSubview(crumbLabel(
                    displayName(node),
                    active: id == trail?.activeNodeID
                ))
            }
        }
        branchButton.title = branchCount > 0 ? "⑂ \(branchCount)" : "⑂"
        branchButton.isEnabled = !(trail?.nodes.isEmpty ?? true)
        setAccessibilityValue(
            breadcrumbText.isEmpty ? "No semantic navigation yet" : breadcrumbText
        )
    }

    private func crumbLabel(_ text: String, active: Bool) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedSystemFont(
            ofSize: 10.5,
            weight: active ? .semibold : .medium
        )
        label.textColor = active ? theme.accentColor : theme.foregroundColor
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private func renderDetail() {
        guard let trail, let selectedID, let node = trail.nodes[selectedID]
        else {
            detailText.stringValue = "Select a trail node to inspect its route and evidence."
            restoreButton.isEnabled = false
            return
        }
        let incoming = incomingEdge(to: selectedID, in: trail)
        let observed = incoming?.observedAtNavigation?.explanation
        let current = incoming?.currentExplanationID.flatMap { store?.value(for: $0) }
        var sections = [
            displayName(node),
            locationText(node.jump),
            "",
            "SNAPSHOT",
            snapshotText(node.jump),
            "",
            "NAVIGATED VIA",
            incoming.map { causeText($0.cause) } ?? "session root",
            "",
            "EXPLANATION",
            "AT NAVIGATION · frozen snapshot",
            observed.map(explanationText) ?? "No relation explanation was attached.",
            "",
            "CURRENT · explanation store",
            current.map(explanationText) ?? "No newer explanation is available.",
        ]
        if let observed, let current,
           explanationText(observed) != explanationText(current)
        {
            sections += ["", "Evidence changed after navigation; the frozen snapshot remains unchanged."]
        }
        detailText.stringValue = sections.joined(separator: "\n")
        restoreButton.isEnabled = true
    }

    private func flattenedRows(_ trail: ReadingTrail) -> [Row] {
        let destinationIDs = Set(trail.edges.map(\.to))
        var roots = trail.nodes.keys.filter { !destinationIDs.contains($0) }
        if let first = trail.edges.first?.from,
           let index = roots.firstIndex(of: first)
        {
            roots.swapAt(0, index)
        }
        roots.sort { lhs, rhs in
            if lhs == trail.edges.first?.from { return true }
            if rhs == trail.edges.first?.from { return false }
            return trail.nodes[lhs]?.jump.path ?? ""
                < trail.nodes[rhs]?.jump.path ?? ""
        }
        var result: [Row] = []
        var visited: Set<TrailNodeID> = []
        func append(_ id: TrailNodeID, depth: Int, isLast: Bool) {
            guard visited.insert(id).inserted, let node = trail.nodes[id] else { return }
            let parent = incomingEdge(to: id, in: trail).flatMap {
                trail.nodes[$0.from]
            }
            result.append(Row(
                id: id,
                depth: depth,
                isLastSibling: isLast,
                crossesSnapshot: parent?.jump.snapshotID != nil
                    && parent?.jump.snapshotID != node.jump.snapshotID
            ))
            let children = trail.edges.filter { $0.from == id }.map(\.to)
            for (index, child) in children.enumerated() {
                append(child, depth: depth + 1, isLast: index == children.count - 1)
            }
        }
        for (index, root) in roots.enumerated() {
            append(root, depth: 0, isLast: index == roots.count - 1)
        }
        return result
    }

    private func path(
        to active: TrailNodeID?,
        in trail: ReadingTrail
    ) -> [TrailNodeID] {
        guard var cursor = active else { return [] }
        var result = [cursor]
        var visited: Set<TrailNodeID> = [cursor]
        while let edge = incomingEdge(to: cursor, in: trail),
              visited.insert(edge.from).inserted
        {
            cursor = edge.from
            result.append(cursor)
        }
        return result.reversed()
    }

    private func incomingEdge(
        to id: TrailNodeID,
        in trail: ReadingTrail
    ) -> TrailEdge? {
        trail.edges.last { $0.to == id }
    }

    private func selectCurrentRow() {
        guard let selectedID,
              let row = rows.firstIndex(where: { $0.id == selectedID })
        else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    private func displayName(_ node: TrailNode) -> String {
        if let anchor = node.jump.symbolAnchor, !anchor.isEmpty { return anchor }
        let file = URL(fileURLWithPath: node.jump.path).lastPathComponent
        return node.jump.line > 1 ? "\(file):\(node.jump.line)" : file
    }

    private func locationText(_ jump: JumpRecord) -> String {
        jump.line > 0 ? "\(jump.path):\(jump.line):\(jump.column)" : jump.path
    }

    private func snapshotText(_ jump: JumpRecord) -> String {
        if let revision = jump.revision { return "commit \(revision.prefix(7))" }
        if let snapshot = jump.snapshotID {
            return "worktree \(snapshot.rawValue.uuidString.prefix(7).lowercased())"
        }
        return "worktree"
    }

    private func causeText(_ cause: NavigationCause) -> String {
        switch cause {
        case .fileSelection: "open"
        case .outline: "outline"
        case .relation: "relation"
        case .search: "search"
        case .historyReplay: "history"
        case .tabActivation: "tab"
        }
    }

    private func badgeText(_ edge: TrailEdge) -> String? {
        let explanation = edge.currentExplanationID.flatMap {
            store?.value(for: $0)
        } ?? edge.observedAtNavigation?.explanation
        guard let explanation else { return nil }
        return switch explanation.trace {
        case .verificationOnly, .corroborated: "Verified"
        case .candidateOnly(let candidate):
            candidate.certainty == .unresolved ? "Unresolved" : "Inferred"
        case .conflict: "Inferred"
        }
    }

    private func explanationText(
        _ explanation: MaterializedResolutionExplanation
    ) -> String {
        switch explanation.trace {
        case .verificationOnly(let verification):
            return "Verified · \(verification.attribution.provider) returned this target."
        case .corroborated(let candidate, let verification):
            return "Verified · source \(evidenceText(candidate)) · \(verification.attribution.provider) corroborated it."
        case .candidateOnly(let candidate):
            return "Inferred · source \(evidenceText(candidate)) · \(completenessText(candidate.completeness))."
        case .conflict(let candidate, _):
            return "Inferred · source \(evidenceText(candidate)) · provider returned a different target."
        }
    }

    private func evidenceText(_ candidate: CandidateObservation) -> String {
        let values = candidate.evidence.map {
            switch $0 {
            case .lexicalBinding: "lexical binding"
            case .uniqueImport: "unique import"
            case .sameFile: "same file"
            case .nameOnly: "name only"
            case .methodNameOnly: "method name only"
            case .receiverType: "receiver type"
            }
        }
        return values.isEmpty ? "candidate" : values.joined(separator: ", ")
    }

    private func completenessText(_ completeness: Completeness) -> String {
        switch completeness {
        case .complete: "candidate generation complete"
        case .partial: "candidate generation partial"
        case .truncated: "candidate generation truncated"
        case .unknown: "candidate completeness unknown"
        }
    }

    private func gutter(for row: Row) -> String {
        if row.depth == 0 { return "●" }
        let prefix = String(repeating: "│  ", count: max(0, row.depth - 1))
        return prefix + (row.isLastSibling ? "└─●" : "├─●")
    }
}

@MainActor
private final class ReadingTrailDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class ReadingTrailCellView: NSTableCellView {
    private let snapshotBoundary = NSTextField(labelWithString: "")
    private let gutter = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let currentLabel = NSTextField(labelWithString: "")
    private let causeChip = RelationChipView()
    private let snapshotChip = RelationChipView()
    private let badge = RelationChipView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        snapshotBoundary.font = .systemFont(ofSize: 9)
        snapshotBoundary.isHidden = true
        gutter.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        gutter.alignment = .right
        titleLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        currentLabel.font = .monospacedSystemFont(ofSize: 9, weight: .semibold)
        currentLabel.setContentHuggingPriority(.required, for: .horizontal)
        let metadata = NSStackView(views: [causeChip, snapshotChip])
        metadata.orientation = .horizontal
        metadata.alignment = .centerY
        metadata.spacing = 5
        let labels = NSStackView(views: [titleLabel, metadata])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let titleRow = NSStackView(views: [labels, badge, currentLabel])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 7
        let row = NSStackView(views: [gutter, titleRow])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        addSubview(snapshotBoundary)
        addSubview(row)
        snapshotBoundary.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            snapshotBoundary.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            snapshotBoundary.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            snapshotBoundary.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            gutter.widthAnchor.constraint(equalToConstant: 48),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 3),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func display(
        title: String,
        gutter gutterText: String,
        cause: String,
        snapshot: String,
        badge badgeText: String?,
        isCurrent: Bool,
        crossesSnapshot: Bool,
        theme: ReaderTheme
    ) {
        snapshotBoundary.stringValue = crossesSnapshot ? "┄ snapshot boundary ┄" : ""
        snapshotBoundary.isHidden = !crossesSnapshot
        snapshotBoundary.textColor = theme.chromeTertiaryColor
        gutter.stringValue = gutterText
        gutter.textColor = isCurrent ? theme.accentColor : theme.chromeTertiaryColor
        titleLabel.stringValue = title
        titleLabel.textColor = theme.foregroundColor
        currentLabel.stringValue = isCurrent ? "● CURRENT" : ""
        currentLabel.textColor = theme.accentColor
        causeChip.display(
            cause,
            foreground: theme.accentColor,
            background: theme.inferredBackgroundColor,
            border: theme.inferredBackgroundColor
        )
        snapshotChip.display(
            snapshot,
            foreground: theme.chromeSecondaryColor,
            background: .clear,
            border: theme.chromeDividerColor
        )
        let badgeColors: (NSColor, NSColor, NSColor, Bool) = switch badgeText {
        case "Verified": (
            theme.verifiedColor,
            theme.verifiedBackgroundColor,
            theme.verifiedBackgroundColor,
            false
        )
        case "Unresolved": (
            theme.unresolvedColor,
            .clear,
            theme.unresolvedBorderColor,
            true
        )
        default: (
            theme.inferredColor,
            theme.inferredBackgroundColor,
            theme.inferredBackgroundColor,
            false
        )
        }
        badge.display(
            badgeText,
            foreground: badgeColors.0,
            background: badgeColors.1,
            border: badgeColors.2,
            dashed: badgeColors.3
        )
        setAccessibilityLabel(title)
        setAccessibilityValue(
            [cause, snapshot, badgeText, isCurrent ? "Current" : nil]
                .compactMap { $0 }.joined(separator: ", ")
        )
    }
}
