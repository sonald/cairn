import AppKit
import CodeInsightAppModel
import CodeInsightCore
import CodeInsightReaderCore
import Observation

@MainActor
final class RelationWindowController: NSViewController,
    NSOutlineViewDataSource, NSOutlineViewDelegate
{
    var onOpen: ((String, UInt32) -> Void)?
    var onTreeChange: (() -> Void)?

    private let model: RelationTreeModel
    private let directionControl = NSSegmentedControl(
        labels: ["Callers", "Calls", "Implements", "References"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let outlineView = RelationOutlineView()
    private let scrollView = NSScrollView()
    private let placeholderLabel = NSTextField(
        labelWithString:
            "Right-click a symbol → Show Callers / Calls / Implements / References"
    )
    private var currentTarget: ReferenceTarget?
    private var currentDocument: ReaderDocument?

    var selfTestPlaceholderText: String? {
        loadViewIfNeeded()
        return placeholderLabel.stringValue
    }
    var selfTestPlaceholderVisible: Bool {
        loadViewIfNeeded()
        return placeholderLabel.selfTestIsVisibleInWindow
    }
    var selfTestTreeVisible: Bool {
        loadViewIfNeeded()
        return scrollView.selfTestIsVisibleInWindow
    }

    var selfTestExactGroupTitle: String? {
        selfTestExactGroupItem?.title
    }

    var selfTestExactGroupRowCount: Int {
        guard let group = selfTestExactGroupItem else { return 0 }
        return group.children?.filter { outlineView.row(forItem: $0) >= 0 }.count ?? 0
    }

    var selfTestExactGroupFrame: NSRect {
        selfTestGroupFrame(titlePrefix: "Exact")
    }

    var selfTestHeuristicGroupFrame: NSRect {
        selfTestGroupFrame(titlePrefix: "Strong")
    }

    var selfTestReferenceGroupTitle: String? {
        guard let row = selfTestGroupRow(titlePrefix: "References"),
              let item = outlineView.item(atRow: row) as? RelationTreeModel.Node
        else { return nil }
        return item.title
    }

    var selfTestReferenceGroupFrame: NSRect {
        selfTestGroupFrame(titlePrefix: "References")
    }

    var selfTestDirectionSegmentFrames: [NSRect] {
        selfTestSegmentFrames
    }

    var selfTestRelationsVisibleRect: NSRect {
        guard isViewLoaded else { return .zero }
        return scrollView.contentView.documentVisibleRect
    }

    var selfTestExactGroupVisibleWithGeometry: Bool {
        let frame = selfTestExactGroupFrame
        return !scrollView.isHidden
            && frame.width > 0
            && frame.height > 0
            && selfTestRelationsVisibleRect.contains(frame)
    }

    var selfTestExactAndHeuristicGroupsDoNotOverlap: Bool {
        let exact = selfTestExactGroupFrame
        let heuristic = selfTestHeuristicGroupFrame
        return exact.width > 0
            && heuristic.width > 0
            && exact.intersection(heuristic).isEmpty
    }

    var selfTestReferenceGroupVisibleWithGeometry: Bool {
        let frame = selfTestReferenceGroupFrame
        return !scrollView.isHidden
            && frame.width > 0
            && frame.height > 0
            && selfTestRelationsVisibleRect.contains(frame)
    }

    var selfTestReferenceSegmentVisibleWithGeometry: Bool {
        let frames = selfTestSegmentFrames
        guard frames.count == 4 else { return false }
        let frame = frames[3]
        return directionControl.segmentCount == 4
            && directionControl.label(forSegment: 3) == "References"
            && directionControl.selfTestIsVisibleInWindow
            && frame.width > 0
            && frame.height > 0
            && selfTestDirectionControlScreenFrame.contains(frame)
    }

    var selfTestReferenceSegmentDoesNotOverlapOtherDirections: Bool {
        let frames = selfTestSegmentFrames
        guard frames.count == 4 else { return false }
        let reference = frames[3]
        return reference.width > 0
            && (0..<3).allSatisfy {
                let other = frames[$0]
                return other.width > 0 && reference.intersection(other).isEmpty
            }
    }

    var selfTestExternalGroupTitle: String? {
        guard let row = selfTestGroupRow(titlePrefix: "External / Unresolved"),
              let cell = outlineView.view(
                  atColumn: 0,
                  row: row,
                  makeIfNecessary: true
              ) as? NSTableCellView
        else { return nil }
        return cell.textField?.stringValue
    }

    func selfTestVisibleEdgeTitles(inGroup titlePrefix: String) -> [String] {
        guard let row = selfTestGroupRow(titlePrefix: titlePrefix),
              let group = outlineView.item(atRow: row) as? RelationTreeModel.Node
        else { return [] }
        return group.children?.compactMap { child in
            guard child.kind == .edge, outlineView.row(forItem: child) >= 0
            else { return nil }
            return child.title
        } ?? []
    }

    func selfTestVisibleEdgeSubtitle(
        titled title: String,
        inGroup titlePrefix: String
    ) -> String? {
        guard let row = selfTestGroupRow(titlePrefix: titlePrefix),
              let group = outlineView.item(atRow: row) as? RelationTreeModel.Node
        else { return nil }
        return group.children?.first {
            $0.kind == .edge
                && $0.title == title
                && outlineView.row(forItem: $0) >= 0
        }?.subtitle
    }

    func selfTestSelectEdge(titled title: String) -> Bool {
        guard isViewLoaded else { return false }
        for row in 0..<outlineView.numberOfRows {
            guard let node = outlineView.item(atRow: row) as? RelationTreeModel.Node,
                  node.kind == .edge,
                  node.title == title
            else { continue }
            outlineView.selectRowIndexes(
                IndexSet(integer: row),
                byExtendingSelection: false
            )
            selectSelection(outlineView)
            return true
        }
        return false
    }

    func selfTestExpandEdge(titled title: String) -> Bool {
        guard isViewLoaded else { return false }
        for row in 0..<outlineView.numberOfRows {
            guard let node = outlineView.item(atRow: row) as? RelationTreeModel.Node,
                  node.kind == .edge,
                  node.title == title,
                  node.isExpandable
            else { continue }
            outlineView.expandItem(node)
            return true
        }
        return false
    }

    func selfTestVisibleChildEdgeTitles(ofEdge title: String) -> [String] {
        guard isViewLoaded else { return [] }
        for row in 0..<outlineView.numberOfRows {
            guard let node = outlineView.item(atRow: row) as? RelationTreeModel.Node,
                  node.kind == .edge,
                  node.title == title
            else { continue }
            var result: [String] = []
            for group in node.children ?? [] where group.kind == .group {
                for child in group.children ?? []
                    where child.kind == .edge
                        && outlineView.row(forItem: child) >= 0
                {
                    result.append(child.title)
                }
            }
            return result
        }
        return []
    }

    func selfTestDeselect() {
        guard isViewLoaded else { return }
        outlineView.selectRowIndexes([], byExtendingSelection: false)
        selectSelection(outlineView)
    }

    func selfTestChangeDirection(_ direction: RelationTreeModel.Direction) {
        directionControl.selectedSegment = segment(for: direction)
        directionChanged(directionControl)
    }

    func selfTestOpenSelection() {
        openSelection(outlineView)
    }

    private var selfTestExactGroupItem: RelationTreeModel.Node? {
        guard let row = selfTestGroupRow(titlePrefix: "Exact") else { return nil }
        return outlineView.item(atRow: row) as? RelationTreeModel.Node
    }

    private func selfTestGroupRow(titlePrefix: String) -> Int? {
        guard isViewLoaded else { return nil }
        return (0..<outlineView.numberOfRows).first { row in
            guard let node = outlineView.item(atRow: row) as? RelationTreeModel.Node
            else { return false }
            return node.kind == .group && node.title.hasPrefix(titlePrefix)
        }
    }

    private func selfTestGroupFrame(titlePrefix: String) -> NSRect {
        guard let row = selfTestGroupRow(titlePrefix: titlePrefix) else {
            return .zero
        }
        return outlineView.rect(ofRow: row)
    }

    private var selfTestSegmentFrames: [NSRect] {
        guard isViewLoaded else { return [] }
        return (directionControl.cell?.accessibilityChildren() ?? []).compactMap {
            guard let object = $0 as? NSObject else { return nil }
            let selector = NSSelectorFromString("accessibilityFrame")
            guard object.responds(to: selector) else { return nil }
            typealias FrameGetter =
                @convention(c) (AnyObject, Selector) -> NSRect
            let getter = unsafeBitCast(
                object.method(for: selector),
                to: FrameGetter.self
            )
            return getter(object, selector)
        }
    }

    private var selfTestDirectionControlScreenFrame: NSRect {
        guard isViewLoaded, let window = directionControl.window else {
            return .zero
        }
        return window.convertToScreen(
            directionControl.convert(directionControl.bounds, to: nil)
        )
    }

    init(model: RelationTreeModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        directionControl.selectedSegment = segment(for: model.direction)
        directionControl.target = self
        directionControl.action = #selector(directionChanged(_:))
        directionControl.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("Relation"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(selectSelection(_:))
        outlineView.doubleAction = #selector(openSelection(_:))
        outlineView.openSelection = { [weak self] in self?.openSelection(nil) }
        outlineView.rowSizeStyle = .default
        outlineView.selectionHighlightStyle = .regular
        outlineView.backgroundColor = .clear
        outlineView.usesAlternatingRowBackgroundColors = false

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        placeholderLabel.font = .systemFont(ofSize: 11)
        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.alignment = .center
        placeholderLabel.lineBreakMode = .byWordWrapping
        placeholderLabel.maximumNumberOfLines = 2
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false

        let container = NSVisualEffectView()
        container.material = .windowBackground
        container.blendingMode = .withinWindow
        container.state = .followsWindowActiveState
        container.addSubview(directionControl)
        container.addSubview(scrollView)
        container.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            directionControl.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            directionControl.leadingAnchor.constraint(
                equalTo: container.leadingAnchor,
                constant: 8
            ),
            directionControl.trailingAnchor.constraint(
                equalTo: container.trailingAnchor,
                constant: -8
            ),
            scrollView.topAnchor.constraint(
                equalTo: directionControl.bottomAnchor,
                constant: 6
            ),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
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
        view = container
        render()
        observe()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        fitOutlineWidthToVisibleRect()
    }

    func setRoot(
        target: ReferenceTarget,
        direction: RelationTreeModel.Direction,
        document: ReaderDocument? = nil
    ) {
        loadViewIfNeeded()
        currentTarget = target
        currentDocument = document
        directionControl.selectedSegment = segment(for: direction)
        let loadTask = model.setRoot(
            target: target,
            direction: direction,
            document: document
        )
        if model.root == nil {
            currentTarget = nil
            currentDocument = nil
        }
        reloadWholeTree()
        onTreeChange?()

        guard let root = model.root else { return }
        outlineView.expandItem(root)
        let generation = model.generation
        Task { [weak self, weak root] in
            if let loadTask { await loadTask.value }
            guard let self, let root,
                  model.generation == generation,
                  model.root === root
            else { return }
            reloadWholeTree()
            expandLoadedGroups(under: root)
            onTreeChange?()
        }
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        numberOfChildrenOfItem item: Any?
    ) -> Int {
        guard let node = item as? RelationTreeModel.Node else {
            return model.root == nil ? 0 : 1
        }
        return node.children?.count ?? 0
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        child index: Int,
        ofItem item: Any?
    ) -> Any {
        guard let node = item as? RelationTreeModel.Node else {
            return model.root!
        }
        return node.children![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? RelationTreeModel.Node else { return false }
        return node.isExpandable || node.children?.isEmpty == false
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let node = item as? RelationTreeModel.Node else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("RelationCell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self)
            as? RelationCellView ?? RelationCellView()
        cell.identifier = identifier
        cell.display(node)
        return cell
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        heightOfRowByItem item: Any
    ) -> CGFloat {
        guard let node = item as? RelationTreeModel.Node else { return 24 }
        return switch node.kind {
        case .edge: 38
        case .root: 32
        case .group, .evidenceLine, .truncated, .loading, .error: 24
        }
    }

    @objc private func selectSelection(_ sender: Any?) {
        guard outlineView.selectedRow >= 0,
              let node = outlineView.item(atRow: outlineView.selectedRow)
                as? RelationTreeModel.Node,
              node.kind == .edge
        else {
            model.clearSelection()
            return
        }
        model.select(node)
        guard node.representsLocation, let target = node.target else { return }
        onOpen?(target.path, target.byteOffset)
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"]
                as? RelationTreeModel.Node,
              node.isExpandable,
              node.children == nil
        else { return }

        let generation = model.generation
        Task { [weak self, weak node] in
            guard let self, let node else { return }
            let expansion = Task { await model.expand(node) }
            await Task.yield()
            guard model.generation == generation else { return }
            outlineView.reloadItem(node, reloadChildren: true)
            outlineView.expandItem(node)
            onTreeChange?()
            await expansion.value
            guard model.generation == generation else { return }
            outlineView.reloadItem(node, reloadChildren: true)
            expandLoadedGroups(under: node)
            onTreeChange?()
        }
    }

    @objc private func directionChanged(_ sender: NSSegmentedControl) {
        let target = model.selectedRelationSymbol.map(ReferenceTarget.engine)
            ?? currentTarget
        guard let target else { return }
        setRoot(
            target: target,
            direction: direction(for: sender.selectedSegment),
            document: currentDocument
        )
    }

    @objc private func openSelection(_ sender: Any?) {
        guard outlineView.selectedRow >= 0,
              let node = outlineView.item(atRow: outlineView.selectedRow)
                as? RelationTreeModel.Node,
              node.kind == .edge,
              let target = node.target
        else { return }
        if !node.representsLocation || sender == nil {
            onOpen?(target.path, target.byteOffset)
        }
        guard let symbol = node.symbol,
              symbol.localKind == .declarationFacet
        else { return }
        setRoot(target: .engine(symbol), direction: model.direction)
    }

    private func observe() {
        withObservationTracking {
            _ = model.generation
            _ = model.root
            _ = model.direction
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                render()
                observe()
            }
        }
    }

    private func render() {
        directionControl.selectedSegment = segment(for: model.direction)
        if model.root == nil {
            currentTarget = nil
            currentDocument = nil
        }
        reloadWholeTree()
    }

    private func reloadWholeTree() {
        guard isViewLoaded else { return }
        outlineView.reloadData()
        fitOutlineWidthToVisibleRect()
        if let root = model.root { outlineView.expandItem(root) }
        let isEmpty = model.root == nil
        placeholderLabel.isHidden = !isEmpty
        scrollView.isHidden = isEmpty
    }

    private func expandLoadedGroups(under node: RelationTreeModel.Node) {
        outlineView.expandItem(node)
        for child in node.children ?? [] where child.kind == .group {
            outlineView.expandItem(child)
        }
        fitOutlineWidthToVisibleRect()
    }

    private func fitOutlineWidthToVisibleRect() {
        let width = scrollView.contentView.documentVisibleRect.width
        guard width > 0, outlineView.frame.width != width else { return }
        outlineView.setFrameSize(NSSize(
            width: width,
            height: outlineView.frame.height
        ))
    }

    private func segment(for direction: RelationTreeModel.Direction) -> Int {
        switch direction {
        case .callers: 0
        case .calls: 1
        case .implementations: 2
        case .references: 3
        }
    }

    private func direction(for segment: Int) -> RelationTreeModel.Direction {
        switch segment {
        case 1: .calls
        case 2: .implementations
        case 3: .references
        default: .callers
        }
    }
}

private extension NSView {
    var selfTestIsVisibleInWindow: Bool {
        guard let window, let contentView = window.contentView,
              !isHiddenOrHasHiddenAncestor,
              bounds.width > 0, bounds.height > 0
        else { return false }
        let frameInWindow = convert(bounds, to: nil)
        let contentFrameInWindow = contentView.convert(contentView.bounds, to: nil)
        let visibleFrame = frameInWindow.intersection(contentFrameInWindow)
        return visibleFrame.width > 0 && visibleFrame.height > 0
    }
}

@MainActor
private final class RelationOutlineView: NSOutlineView {
    var openSelection: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            openSelection?()
        } else {
            super.keyDown(with: event)
        }
    }
}

@MainActor
private final class RelationCellView: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    init() {
        super.init(frame: .zero)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badgeLabel.setContentHuggingPriority(.required, for: .horizontal)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let labels = NSStackView(views: [titleLabel, subtitleLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        let row = NSStackView(views: [spinner, labels, badgeLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = titleLabel
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func display(_ node: RelationTreeModel.Node) {
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        subtitleLabel.isHidden = true
        badgeLabel.stringValue = node.badge ?? ""
        badgeLabel.textColor = .systemOrange
        badgeLabel.font = .systemFont(ofSize: 12, weight: .semibold)

        switch node.kind {
        case .root:
            titleLabel.attributedStringValue = title(
                node.title,
                location: location(of: node),
                weight: .semibold
            )
        case .group:
            titleLabel.stringValue = node.title.uppercased()
            titleLabel.font = .systemFont(ofSize: 10, weight: .semibold)
            titleLabel.textColor = .secondaryLabelColor
        case .edge:
            titleLabel.attributedStringValue = title(
                node.title,
                location: location(of: node),
                weight: .medium
            )
            subtitleLabel.stringValue = node.subtitle ?? ""
            subtitleLabel.font = .systemFont(ofSize: 10)
            subtitleLabel.textColor = .secondaryLabelColor
            subtitleLabel.isHidden = false
        case .evidenceLine:
            titleLabel.stringValue = "  \(node.title)"
            titleLabel.font = .systemFont(ofSize: 10)
            titleLabel.textColor = .tertiaryLabelColor
        case .loading:
            titleLabel.stringValue = node.title
            titleLabel.font = .systemFont(ofSize: 11)
            titleLabel.textColor = .secondaryLabelColor
            spinner.isHidden = false
            spinner.startAnimation(nil)
        case .truncated:
            titleLabel.stringValue = node.title
            titleLabel.font = .systemFont(ofSize: 11)
            titleLabel.textColor = .systemOrange
        case .error:
            titleLabel.stringValue = node.title
            titleLabel.font = .systemFont(ofSize: 11)
            titleLabel.textColor = .systemRed
        }
    }

    private func location(of node: RelationTreeModel.Node) -> String? {
        guard let target = node.target else { return nil }
        return node.line.map { "\(target.path):\($0)" } ?? target.path
    }

    private func title(
        _ title: String,
        location: String?,
        weight: NSFont.Weight
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: weight),
                .foregroundColor: NSColor.labelColor,
            ]
        )
        if let location {
            result.append(NSAttributedString(
                string: "  \(location)",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 10),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            ))
        }
        return result
    }
}
