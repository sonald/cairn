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
    var onOpenReadingSet: ((TrailNodeID) -> Void)?

    private struct Row {
        let id: TrailNodeID
        let depth: Int
        let isLastSibling: Bool
        let crossesSnapshot: Bool
        /// First node of a side branch: drawn with a connector from its parent's lane.
        var isBranchStart = false
        var parentIndex: Int?
        /// Lanes whose line continues below this row (own lane included when it does).
        var lanesBelow: Set<Int> = []
        /// Lanes whose line enters this row from above.
        var lanesAbove: Set<Int> = []
    }

    private let titleLabel = NSTextField(labelWithString: localized("trail.title"))
    private let breadcrumb = NSStackView()
    private let branchButton = NSButton(title: "⑂", target: nil, action: nil)
    private let divider = NSView()
    private let popover = NSPopover()
    private let tableView = NSTableView()
    private let detailDocument = ReadingTrailDocumentView()
    private let detailStack = NSStackView()
    private let detailText = NSTextField(wrappingLabelWithString: "")
    private let restoreButton = NSButton(
        title: localized("trail.restore"),
        target: nil,
        action: nil
    )
    private let readingSetButton = NSButton(
        title: localized("trail.freeze"),
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
        setAccessibilityLabel(localized("trail.title"))

        titleLabel.font = .systemFont(ofSize: 10, weight: .bold)
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        breadcrumb.orientation = .horizontal
        breadcrumb.alignment = .centerY
        breadcrumb.spacing = 5
        breadcrumb.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Above the bar's own edge preferences (just under 250) and the crumb
        // labels' hugging (251), so the breadcrumb's size never ties either.
        breadcrumb.setHuggingPriority(.defaultLow + 10, for: .horizontal)
        breadcrumb.setHuggingPriority(.defaultLow + 10, for: .vertical)
        branchButton.bezelStyle = .accessoryBarAction
        branchButton.font = .systemFont(ofSize: 11, weight: .semibold)
        branchButton.toolTip = localized("trail.branchesHelp")
        branchButton.setAccessibilityLabel(localized("trail.branchesAX"))
        branchButton.target = self
        branchButton.action = #selector(showTrail(_:))
        branchButton.setContentHuggingPriority(.required, for: .horizontal)
        divider.wantsLayer = true

        // The badge gets its own trailing gravity area. In one shared area the
        // breadcrumb's hugging ties with the button's trailing-edge preference,
        // leaving the slack to the solver.
        let bar = NSStackView()
        bar.setViews([titleLabel, breadcrumb], in: .leading)
        bar.setViews([branchButton], in: .trailing)
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
        readingSetButton.contentTintColor = theme.accentColor
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
            } ?? localized("trail.navigate")
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
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            tableView.window?.makeFirstResponder(tableView)
        }
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

    func openSelectedNodeAsReadingSet() {
        openReadingSet(nil)
    }

    var readingSetButtonState: (title: String, enabled: Bool, label: String) {
        (
            readingSetButton.title,
            readingSetButton.isEnabled,
            readingSetButton.accessibilityLabel() ?? ""
        )
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
            lanes: TrailGutterView.Lanes(
                depth: rows[row].depth,
                count: laneCount,
                above: rows[row].lanesAbove,
                below: rows[row].lanesBelow,
                isBranchStart: rows[row].isBranchStart
            ),
            cause: incoming.map { causeText($0.cause) } ?? localized("trail.root"),
            snapshot: snapshotText(node.jump),
            historical: node.jump.revision != nil,
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

    @objc private func openReadingSet(_ sender: Any?) {
        guard let selectedID, readingSetButton.isEnabled else { return }
        popover.close()
        onOpenReadingSet?(selectedID)
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
        tableView.setAccessibilityLabel(localized("trail.graph"))
        let tableScroll = NSScrollView()
        tableScroll.documentView = tableView
        tableScroll.hasVerticalScroller = true
        tableScroll.autohidesScrollers = true
        tableScroll.drawsBackground = false
        tableScroll.translatesAutoresizingMaskIntoConstraints = false

        let leftHeader = trailHeader(title: localized("trail.heading"), detail: localized("trail.historyHeading"))
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
        detailText.setAccessibilityLabel(localized("trail.detailAX"))
        restoreButton.bezelStyle = .rounded
        restoreButton.target = self
        restoreButton.action = #selector(restore(_:))
        restoreButton.setAccessibilityLabel(localized("trail.restoreAX"))
        readingSetButton.bezelStyle = .rounded
        readingSetButton.target = self
        readingSetButton.action = #selector(openReadingSet(_:))
        readingSetButton.setAccessibilityLabel(localized("trail.freeze"))
        detailStack.addArrangedSubview(detailText)
        detailStack.addArrangedSubview(readingSetButton)
        detailStack.addArrangedSubview(restoreButton)
        detailDocument.addSubview(detailStack)
        let detailScroll = NSScrollView()
        detailScroll.documentView = detailDocument
        detailScroll.hasVerticalScroller = true
        detailScroll.autohidesScrollers = true
        detailScroll.drawsBackground = false
        detailScroll.translatesAutoresizingMaskIntoConstraints = false
        let rightHeader = trailHeader(title: localized("trail.nodeHeading"), detail: localized("trail.auditHeading"))
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
                labelWithString:
                    localized("trail.hint")
            )
            empty.font = .systemFont(ofSize: 11)
            empty.textColor = theme.chromeTertiaryColor
            empty.lineBreakMode = .byTruncatingTail
            empty.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            breadcrumb.addArrangedSubview(empty)
        } else {
            // When space runs out, older crumbs truncate first (down to a
            // stub), then the cause arrows, then the active crumb. Every label
            // gets its own priority so the solver never picks which to squeeze:
            // "…" 240, crumbs 241-243, arrows 246-248, active crumb 249.
            if titles.count > 4 {
                breadcrumb.addArrangedSubview(crumbLabel(
                    "…", active: false, compressionResistance: .defaultLow - 10
                ))
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
                    arrow.setContentCompressionResistancePriority(
                        .defaultLow - 5 + Float(index), for: .horizontal
                    )
                    breadcrumb.addArrangedSubview(arrow)
                }
                guard let node = trail?.nodes[id] else { continue }
                let active = id == trail?.activeNodeID
                breadcrumb.addArrangedSubview(crumbLabel(
                    displayName(node),
                    active: active,
                    compressionResistance: active
                        ? .defaultLow - 1
                        : .defaultLow - 9 + Float(index)
                ))
            }
        }
        branchButton.title = branchCount > 0
            ? localizedFormat("trail.branches", Int64(branchCount))
            : localized("trail.details")
        branchButton.isEnabled = !(trail?.nodes.isEmpty ?? true)
        setAccessibilityValue(
            breadcrumbText.isEmpty
                ? localized("trail.hint")
                : breadcrumbText
        )
    }

    private func crumbLabel(
        _ text: String,
        active: Bool,
        compressionResistance: NSLayoutConstraint.Priority
    ) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedSystemFont(
            ofSize: 10.5,
            weight: active ? .semibold : .medium
        )
        label.textColor = active ? theme.accentColor : theme.foregroundColor
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(compressionResistance, for: .horizontal)
        // A squeezed crumb keeps a short "a_…2" stub instead of vanishing
        // between its arrows; it outranks the active crumb's resistance.
        let stub = label.widthAnchor.constraint(
            greaterThanOrEqualToConstant: min(label.intrinsicContentSize.width, 32)
        )
        stub.priority = .defaultLow - 0.5
        stub.isActive = true
        return label
    }

    private func renderDetail() {
        guard let trail, let selectedID, let node = trail.nodes[selectedID]
        else {
            detailText.stringValue = localized("trail.select")
            restoreButton.isEnabled = false
            readingSetButton.isEnabled = false
            return
        }
        let incoming = incomingEdge(to: selectedID, in: trail)
        let observed = incoming?.observedAtNavigation?.explanation
        let current = incoming?.currentExplanationID.flatMap { store?.value(for: $0) }
        // A frozen display with no live explanation reference is an edge
        // restored from an earlier session: only the display snapshot
        // survived, so it is labeled as historical rather than current.
        let isRestoredEvidence = incoming?.frozenInspectorDisplay != nil
            && incoming?.currentExplanationID == nil
        var sections: [(DetailStyle, String)] = [
            (.title, displayName(node)),
            (.location, locationText(node.jump)),
            (.gap, ""),
            (.heading, localized("trail.snapshot")),
            (node.jump.revision == nil ? .body : .history, snapshotText(node.jump)),
            (.gap, ""),
            (.heading, localized("trail.via")),
            (.body, incoming.map { causeText($0.cause) } ?? localized("trail.sessionRoot")),
            (.gap, ""),
            (.heading, localized("trail.explanation")),
            (.caption, isRestoredEvidence
                ? localized("trail.previousEvidence")
                : localized("trail.frozenEvidence")),
            (.body, observed.map(explanationText) ?? localized("trail.noExplanation")),
            (.gap, ""),
            (.heading, localized("trail.currentEvidence")),
            (.body, current.map(explanationText) ?? localized("trail.noNewEvidence")),
        ]
        if isRestoredEvidence {
            sections += [(.gap, ""), (.warning, localized("trail.snapshotOnly"))]
        }
        if let observed, let current,
           explanationText(observed) != explanationText(current)
        {
            sections += [(.gap, ""), (.warning, localized("trail.changed"))]
        }
        detailText.attributedStringValue = styledDetail(sections)
        restoreButton.isEnabled = true
        readingSetButton.isEnabled = path(
            to: selectedID,
            in: trail
        ).dropFirst().contains { id in
            incomingEdge(to: id, in: trail)?.frozenInspectorDisplay != nil
        }
    }

    private enum DetailStyle {
        case title, location, heading, caption, body, history, warning, gap
    }

    /// One line per section, so the plain string stays the joined section text.
    private func styledDetail(_ sections: [(DetailStyle, String)]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, (style, text)) in sections.enumerated() {
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacingBefore = style == .heading ? 2 : 0
            var attributes: [NSAttributedString.Key: Any] = [.paragraphStyle: paragraph]
            switch style {
            case .title:
                attributes[.font] = cairnSerifFont(ofSize: 20, weight: .medium)
                attributes[.foregroundColor] = theme.foregroundColor
            case .location:
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
                attributes[.foregroundColor] = theme.chromeSecondaryColor
            case .heading:
                attributes[.font] = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
                attributes[.foregroundColor] = theme.chromeSecondaryColor
                attributes[.kern] = 0.8
            case .caption:
                attributes[.font] = NSFont.systemFont(ofSize: 11)
                attributes[.foregroundColor] = theme.chromeSecondaryColor
            case .body:
                attributes[.font] = NSFont.systemFont(ofSize: 12.5)
                attributes[.foregroundColor] = theme.foregroundColor
            case .history:
                attributes[.font] = NSFont.systemFont(ofSize: 12.5, weight: .medium)
                attributes[.foregroundColor] = theme.histColor
            case .warning:
                attributes[.font] = NSFont.systemFont(ofSize: 12, weight: .medium)
                attributes[.foregroundColor] = theme.warningColor
            case .gap:
                attributes[.font] = NSFont.systemFont(ofSize: 6)
            }
            let line = index == sections.count - 1 ? text : text + "\n"
            result.append(NSAttributedString(string: line, attributes: attributes))
        }
        return result
    }

    var selfTestDetailTitleFont: NSFont? {
        guard detailText.attributedStringValue.length > 0 else { return nil }
        return detailText.attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    }

    func selfTestDetailColor(of text: String) -> NSColor? {
        let value = detailText.attributedStringValue
        let range = (value.string as NSString).range(of: text)
        guard range.location != NSNotFound else { return nil }
        return value.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
    }

    /// Bar frames in this view's coordinates, plus whether any bar item's
    /// horizontal position is left to the solver.
    var selfTestBarLayout: (breadcrumb: NSRect, badge: NSRect, ambiguous: Bool) {
        let items: [NSView] = [titleLabel, breadcrumb, branchButton]
        return (
            convert(breadcrumb.bounds, from: breadcrumb),
            convert(branchButton.bounds, from: branchButton),
            items.contains(where: \.hasAmbiguousLayout)
        )
    }

    /// Each breadcrumb label's text, laid-out width, natural width and
    /// whether its position is left to the solver.
    var selfTestCrumbs: [(text: String, width: CGFloat, natural: CGFloat, ambiguous: Bool)] {
        breadcrumb.arrangedSubviews.compactMap { $0 as? NSTextField }.map {
            ($0.stringValue, $0.frame.width, $0.intrinsicContentSize.width, $0.hasAmbiguousLayout)
        }
    }

    /// Row order with each row's lane and branch flag, as drawn.
    var selfTestRowLanes: [(path: String, depth: Int, branchStart: Bool, above: Set<Int>, below: Set<Int>)] {
        rows.compactMap { row in
            trail?.nodes[row.id].map {
                ($0.jump.path, row.depth, row.isBranchStart, row.lanesAbove, row.lanesBelow)
            }
        }
    }

    func selfTestRowStyle(path: String) -> (gutter: NSColor?, snapshotFill: CGColor?, current: Bool)? {
        guard let row = rows.firstIndex(where: { trail?.nodes[$0.id]?.jump.path == path }),
              let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: true)
                as? ReadingTrailCellView
        else { return nil }
        return cell.selfTestStyle
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
        func append(_ id: TrailNodeID, depth: Int, isLast: Bool, parentIndex: Int? = nil) {
            guard visited.insert(id).inserted, let node = trail.nodes[id] else { return }
            let parent = incomingEdge(to: id, in: trail).flatMap {
                trail.nodes[$0.from]
            }
            result.append(Row(
                id: id,
                depth: depth,
                isLastSibling: isLast,
                crossesSnapshot: parent?.jump.snapshotID != nil
                    && parent?.jump.snapshotID != node.jump.snapshotID,
                parentIndex: parentIndex
            ))
            let index = result.count - 1
            let children = trail.edges.filter { $0.from == id }.map(\.to)
            guard !children.isEmpty else { return }
            // Reading on is not branching: the first route taken from a node keeps
            // its lane, so later detours never reshuffle what was already drawn.
            // Rows stay in visiting order; later routes indent one lane.
            append(children[0], depth: depth, isLast: children.count == 1, parentIndex: index)
            for (offset, child) in children.dropFirst().enumerated() {
                let start = result.count
                append(child, depth: depth + 1, isLast: offset == children.count - 2, parentIndex: index)
                if result.indices.contains(start), result[start].id == child {
                    result[start].isBranchStart = true
                }
            }
        }
        for (index, root) in roots.enumerated() {
            append(root, depth: 0, isLast: index == roots.count - 1)
        }
        // A lane continues below row i when the next row at or left of that
        // lane sits on it and is not the start of a new branch.
        for i in result.indices {
            for lane in 0...result[i].depth {
                guard let next = result[(i + 1)...].first(where: { $0.depth <= lane })
                else { continue }
                if next.depth == lane && !next.isBranchStart {
                    result[i].lanesBelow.insert(lane)
                }
            }
        }
        // A branch hangs off its parent's lane: keep that lane open from the
        // parent down to the branch's first row.
        for (j, row) in result.enumerated() where row.isBranchStart {
            guard let parent = row.parentIndex else { continue }
            for i in parent..<j { result[i].lanesBelow.insert(row.depth - 1) }
        }
        for i in result.indices.dropFirst() {
            result[i].lanesAbove = result[i - 1].lanesBelow
        }
        return result
    }

    private var laneCount: Int { (rows.map(\.depth).max() ?? 0) + 1 }

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
        if let revision = jump.revision { return localizedFormat("trail.commit", String(revision.prefix(7))) }
        if let snapshot = jump.snapshotID {
            return localizedFormat("trail.worktreeID", snapshot.rawValue.uuidString.prefix(7).lowercased())
        }
        return localized("trail.worktree")
    }

    private func causeText(_ cause: NavigationCause) -> String {
        switch cause {
        case .fileSelection: localized("trail.open")
        case .outline: localized("trail.outline")
        case .relation: localized("trail.relation")
        case .search: localized("trail.search")
        case .historyReplay: localized("trail.history")
        case .tabActivation: localized("trail.tab")
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
            return localizedFormat("trail.verifiedExplanation", verification.attribution.provider)
        case .corroborated(let candidate, let verification):
            return localizedFormat("trail.corroboratedExplanation", evidenceText(candidate), verification.attribution.provider)
        case .candidateOnly(let candidate):
            return localizedFormat("trail.inferredExplanation", evidenceText(candidate), completenessText(candidate.completeness))
        case .conflict(let candidate, _):
            return localizedFormat("trail.conflictExplanation", evidenceText(candidate))
        }
    }

    private func evidenceText(_ candidate: CandidateObservation) -> String {
        let values = candidate.evidence.map {
            switch $0 {
            case .lexicalBinding: localized("trail.lexical")
            case .uniqueImport: localized("trail.uniqueImport")
            case .sameFile: localized("trail.sameFile")
            case .nameOnly: localized("trail.nameOnly")
            case .methodNameOnly: localized("trail.methodNameOnly")
            case .receiverType: localized("trail.receiver")
            }
        }
        return values.isEmpty ? localized("trail.candidate") : values.joined(separator: ", ")
    }

    private func completenessText(_ completeness: Completeness) -> String {
        switch completeness {
        case .complete: localized("trail.complete")
        case .partial: localized("trail.partial")
        case .truncated: localized("trail.truncated")
        case .unknown: localized("trail.unknown")
        }
    }

}

@MainActor
private final class ReadingTrailDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class ReadingTrailCellView: NSTableCellView {
    private let snapshotBoundary = NSTextField(labelWithString: "")
    private let gutter = TrailGutterView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let currentLabel = NSTextField(labelWithString: "")
    private let causeChip = RelationChipView()
    private let snapshotChip = RelationChipView()
    private let badge = RelationChipView()
    private var isCurrentRow = false

    var selfTestStyle: (gutter: NSColor?, snapshotFill: CGColor?, current: Bool) {
        (gutter.nodeColor, snapshotChip.layer?.backgroundColor, isCurrentRow)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        snapshotBoundary.font = .systemFont(ofSize: 9)
        snapshotBoundary.isHidden = true
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
        let row = titleRow
        row.translatesAutoresizingMaskIntoConstraints = false
        gutter.translatesAutoresizingMaskIntoConstraints = false
        addSubview(gutter)
        addSubview(snapshotBoundary)
        addSubview(row)
        snapshotBoundary.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            snapshotBoundary.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            snapshotBoundary.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            snapshotBoundary.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            gutter.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            gutter.topAnchor.constraint(equalTo: topAnchor),
            gutter.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: gutter.trailingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 3),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func display(
        title: String,
        lanes: TrailGutterView.Lanes,
        cause: String,
        snapshot: String,
        historical: Bool,
        badge badgeText: String?,
        isCurrent: Bool,
        crossesSnapshot: Bool,
        theme: ReaderTheme
    ) {
        snapshotBoundary.stringValue = crossesSnapshot ? localized("trail.boundary") : ""
        snapshotBoundary.isHidden = !crossesSnapshot
        snapshotBoundary.textColor = theme.histColor
        gutter.update(
            lanes: lanes,
            nodeColor: isCurrent ? theme.amberMarkColor
                : historical ? theme.histColor : theme.accentColor,
            haloColor: isCurrent ? theme.amberSoftColor : nil,
            lineColor: theme.accentColor.withAlphaComponent(0.45),
            boundaryColor: crossesSnapshot ? theme.histColor : nil,
            fillColor: theme.chromeColor
        )
        titleLabel.stringValue = title
        titleLabel.textColor = theme.foregroundColor
        currentLabel.stringValue = isCurrent ? localized("trail.current") : ""
        currentLabel.textColor = theme.warningColor
        causeChip.display(
            cause,
            foreground: theme.chipForegroundColor,
            background: theme.chipBackgroundColor,
            border: theme.chipBackgroundColor
        )
        snapshotChip.display(
            snapshot,
            foreground: historical ? theme.histColor : theme.chromeSecondaryColor,
            background: historical ? theme.histSoftColor : .clear,
            border: historical ? theme.histSoftColor : theme.chromeDividerColor
        )
        isCurrentRow = isCurrent
        let badgeColors: (NSColor, NSColor, NSColor, Bool) = switch badgeText {
        case "Verified": (
            theme.verifiedColor,
            theme.mossSoftColor,
            theme.mossSoftColor,
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
            theme.slateSoftColor,
            theme.slateSoftColor,
            false
        )
        }
        let displayBadge = badgeText.map { value in
            switch value {
            case "Verified": localized("trail.verified")
            case "Unresolved": localized("trail.unresolved")
            default: localized("trail.inferred")
            }
        }
        badge.display(
            displayBadge,
            foreground: badgeColors.0,
            background: badgeColors.1,
            border: badgeColors.2,
            dashed: badgeColors.3
        )
        setAccessibilityLabel(title)
        setAccessibilityValue(
            [cause, snapshot, displayBadge, isCurrent ? localized("trail.currentAX") : nil]
                .compactMap { $0 }.joined(separator: ", ")
        )
    }
}

/// Draws the trail as a path: one lane per branch level, a node on the row's
/// lane, straight lines where a lane continues and a curve where a branch starts.
@MainActor
final class TrailGutterView: NSView {
    struct Lanes: Equatable {
        var depth = 0
        var count = 1
        var above: Set<Int> = []
        var below: Set<Int> = []
        var isBranchStart = false
    }

    static let laneWidth: CGFloat = 14
    static let inset: CGFloat = 10

    private(set) var lanes = Lanes()
    private(set) var nodeColor: NSColor = .clear
    private var haloColor: NSColor?
    private var lineColor: NSColor = .clear
    private var boundaryColor: NSColor?
    private var fillColor: NSColor = .clear
    private var widthConstraint: NSLayoutConstraint?

    override var isFlipped: Bool { true }

    static func x(forLane lane: Int) -> CGFloat {
        inset + CGFloat(lane) * laneWidth
    }

    var nodeCenterX: CGFloat { Self.x(forLane: lanes.depth) }

    func update(
        lanes: Lanes,
        nodeColor: NSColor,
        haloColor: NSColor?,
        lineColor: NSColor,
        boundaryColor: NSColor?,
        fillColor: NSColor
    ) {
        self.lanes = lanes
        self.nodeColor = nodeColor
        self.haloColor = haloColor
        self.lineColor = lineColor
        self.boundaryColor = boundaryColor
        self.fillColor = fillColor
        let width = Self.x(forLane: lanes.count - 1) + Self.inset
        if let widthConstraint {
            widthConstraint.constant = width
        } else {
            translatesAutoresizingMaskIntoConstraints = false
            widthConstraint = widthAnchor.constraint(equalToConstant: width)
            widthConstraint?.isActive = true
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let midY = bounds.midY
        let x = nodeCenterX
        for lane in lanes.above.union(lanes.below) where lane != lanes.depth {
            let lx = Self.x(forLane: lane)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: lx, y: lanes.above.contains(lane) ? 0 : midY))
            path.line(to: NSPoint(x: lx, y: lanes.below.contains(lane) ? bounds.maxY : midY))
            stroke(path)
        }
        if lanes.above.contains(lanes.depth) && !lanes.isBranchStart {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x, y: 0))
            path.line(to: NSPoint(x: x, y: midY))
            stroke(path, dashed: boundaryColor != nil, color: boundaryColor)
        }
        if lanes.isBranchStart, lanes.depth > 0 {
            let from = Self.x(forLane: lanes.depth - 1)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: from, y: 0))
            path.curve(
                to: NSPoint(x: x, y: midY),
                controlPoint1: NSPoint(x: from, y: midY * 0.8),
                controlPoint2: NSPoint(x: x, y: midY * 0.4)
            )
            stroke(path, dashed: boundaryColor != nil, color: boundaryColor)
        }
        if lanes.below.contains(lanes.depth) {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x, y: midY))
            path.line(to: NSPoint(x: x, y: bounds.maxY))
            stroke(path)
        }
        if let haloColor {
            haloColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: x - 8, y: midY - 8, width: 16, height: 16)).fill()
        }
        let radius: CGFloat = haloColor == nil ? 4 : 5
        let node = NSBezierPath(ovalIn: NSRect(x: x - radius, y: midY - radius, width: radius * 2, height: radius * 2))
        if haloColor == nil {
            fillColor.setFill()
            node.fill()
            nodeColor.setStroke()
            node.lineWidth = 2
            node.stroke()
        } else {
            nodeColor.setFill()
            node.fill()
        }
    }

    private func stroke(_ path: NSBezierPath, dashed: Bool = false, color: NSColor? = nil) {
        (color ?? lineColor).setStroke()
        path.lineWidth = 1.5
        if dashed { path.setLineDash([3, 3], count: 2, phase: 0) }
        path.stroke()
    }
}
