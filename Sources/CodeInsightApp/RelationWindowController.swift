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
    private let container = NSView()
    private let headerSurface = NSView()
    private let placeholderLabel = NSTextField(
        labelWithString:
            "Right-click a symbol → Show Callers / Calls / Implements / References"
    )
    private var currentTarget: ReferenceTarget?
    private var currentDocument: ReaderDocument?
    private var layoutPassCount = 0
    private var selfTestOpenSelectionCount = 0
    private var wholeTreeReloadCount = 0
    private var nodeReloadCount = 0
    private var theme = ReaderTheme(settings: ReaderSettings())

    func apply(settings: ReaderSettings) {
        theme = ReaderTheme(settings: settings)
        guard isViewLoaded else { return }
        container.layer?.backgroundColor = theme.chromeColor.cgColor
        headerSurface.layer?.backgroundColor = theme.chromeHeaderColor.cgColor
        directionControl.selectedSegmentBezelColor = theme.accentColor
        outlineView.backgroundColor = theme.chromeColor
        for row in 0..<outlineView.numberOfRows {
            (outlineView.rowView(atRow: row, makeIfNecessary: false)
                as? ThemeSelectionRowView)?.selectionColor = theme.chromeSelectionColor
            guard let node = outlineView.item(atRow: row) as? RelationTreeModel.Node,
                  let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false)
                    as? RelationCellView
            else { continue }
            cell.display(node, theme: theme)
        }
        view.needsDisplay = true
    }

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
        nil
    }

    var selfTestExactGroupRowCount: Int {
        selfTestVisibleEdgeNodes(inGroup: "Exact").count
    }

    var selfTestExactGroupFrame: NSRect {
        selfTestVisibleEdgeFrames(inGroup: "Exact").first ?? .zero
    }

    var selfTestHeuristicGroupFrame: NSRect {
        selfTestVisibleEdgeFrames(inGroup: "Strong").first ?? .zero
    }

    var selfTestReferenceGroupTitle: String? {
        if let row = selfTestGroupRow(titlePrefix: "References"),
           let node = outlineView.item(atRow: row) as? RelationTreeModel.Node
        {
            return node.title
        }
        return selfTestPossibleDisclosureItem?.title
    }

    var selfTestReferenceGroupFrame: NSRect {
        let group = selfTestGroupFrame(titlePrefix: "References")
        if group != .zero { return group }
        let disclosure = selfTestPossibleDisclosureFrame
        if disclosure != .zero { return disclosure }
        return selfTestVisibleEdgeFrames(inGroup: "References").first ?? .zero
    }

    var selfTestDirectionSegmentFrames: [NSRect] {
        selfTestSegmentFrames
    }

    var selfTestRelationsVisibleRect: NSRect {
        guard isViewLoaded else { return .zero }
        return scrollView.contentView.documentVisibleRect
    }

    var selfTestExactGroupVisibleWithGeometry: Bool {
        selfTestFrameIsVisible(selfTestExactGroupFrame)
    }

    var selfTestExactAndHeuristicGroupsDoNotOverlap: Bool {
        let exact = selfTestExactGroupFrame
        let heuristic = selfTestHeuristicGroupFrame
        return exact.width > 0
            && heuristic.width > 0
            && exact.intersection(heuristic).isEmpty
    }

    var selfTestReferenceGroupVisibleWithGeometry: Bool {
        selfTestFrameIsVisible(selfTestReferenceGroupFrame)
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
        selfTestVisibleEdgeNodes(inGroup: "").first {
            $0.subtitle?.hasPrefix("Unresolved") == true
                || $0.subtitle?.hasPrefix("External · in dependency") == true
        }?.subtitle
    }

    func selfTestVisibleEdgeTitles(inGroup titlePrefix: String) -> [String] {
        selfTestVisibleEdgeNodes(inGroup: titlePrefix).map(\.title)
    }

    func selfTestVisibleEdgeSubtitle(
        titled title: String,
        inGroup titlePrefix: String
    ) -> String? {
        selfTestVisibleEdgeNodes(inGroup: titlePrefix).first {
            $0.title == title
        }?.subtitle
    }

    func selfTestAccessibility(
        titled title: String,
        inGroup titlePrefix: String
    ) -> (
        label: String,
        value: String,
        role: String,
        valueSettable: Bool
    )? {
        guard let cell = selfTestCell(titled: title, inGroup: titlePrefix)
        else { return nil }
        return (
            cell.accessibilityLabel() ?? "",
            cell.accessibilityValue() as? String ?? "",
            cell.accessibilityRole()?.rawValue ?? "",
            cell.isAccessibilitySelectorAllowed(
                NSSelectorFromString("setAccessibilityValue:")
            )
        )
    }

    func selfTestVisibleEdgeFrames(inGroup titlePrefix: String) -> [NSRect] {
        selfTestVisibleEdgeNodes(inGroup: titlePrefix).compactMap {
            let row = outlineView.row(forItem: $0)
            return row >= 0 ? outlineView.rect(ofRow: row) : nil
        }
    }

    var selfTestExactAndReferenceGroupsDoNotOverlap: Bool {
        let exact = selfTestExactGroupFrame
        let references = selfTestReferenceGroupFrame
        return exact.width > 0
            && references.width > 0
            && exact.intersection(references).isEmpty
    }

    var selfTestResultsAndDirectionControlDoNotOverlap: Bool {
        guard isViewLoaded else { return false }
        return scrollView.frame.width > 0
            && directionControl.frame.width > 0
            && scrollView.frame.intersection(
                directionControl.convert(directionControl.bounds, to: view)
            ).isEmpty
    }

    var selfTestLayoutPasses: Int { layoutPassCount }
    var selfTestWholeTreeReloads: Int { wholeTreeReloadCount }
    var selfTestNodeReloads: Int { nodeReloadCount }

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

    var selfTestPossibleDisclosureTitle: String? {
        selfTestPossibleDisclosureItem?.title
    }

    var selfTestPossibleDisclosureDisplayText: [String] {
        guard let item = selfTestPossibleDisclosureItem else { return [] }
        let row = outlineView.row(forItem: item)
        return (outlineView.view(atColumn: 0, row: row, makeIfNecessary: true)
            as? RelationCellView)?.selfTestTitleAndCount ?? []
    }

    var selfTestPossibleDisclosureFrame: NSRect {
        guard let item = selfTestPossibleDisclosureItem else { return .zero }
        let row = outlineView.row(forItem: item)
        return row >= 0 ? outlineView.rect(ofRow: row) : .zero
    }

    func selfTestExpandPossibleMatches() -> Bool {
        guard let item = selfTestPossibleDisclosureItem else { return false }
        outlineView.expandItem(item)
        return outlineView.isItemExpanded(item)
    }

    func selfTestScrollPossibleMatchToVisible(at index: Int) -> Bool {
        guard let item = selfTestPossibleDisclosureItem,
              let children = item.children,
              children.indices.contains(index)
        else { return false }
        let row = outlineView.row(forItem: children[index])
        guard row >= 0 else { return false }
        outlineView.scrollRowToVisible(row)
        validateVisiblePossibleRows()
        return outlineView.rect(ofRow: row)
            .intersects(scrollView.contentView.documentVisibleRect)
    }

    func selfTestVisibleText() -> [String] {
        guard isViewLoaded else { return [] }
        return (0..<outlineView.numberOfRows).compactMap { row in
            guard let node = outlineView.item(atRow: row) as? RelationTreeModel.Node
            else { return nil }
            return [node.title, node.subtitle, node.badge]
                .compactMap { $0 }
                .joined(separator: " ")
        }
    }

    func selfTestBadgeFrame(titled title: String) -> NSRect {
        guard let cell = selfTestCell(titled: title, inGroup: "")
            as? RelationCellView
        else { return .zero }
        return cell.selfTestBadgeFrame(in: outlineView)
    }

    func selfTestBadgeLabelFrame(titled title: String) -> NSRect {
        guard let cell = selfTestCell(titled: title, inGroup: "")
            as? RelationCellView
        else { return .zero }
        return cell.selfTestBadgeLabelFrame(in: outlineView)
    }

    func selfTestBadgeCornerRadius(titled title: String) -> CGFloat {
        (selfTestCell(titled: title, inGroup: "") as? RelationCellView)?
            .selfTestBadgeCornerRadius ?? 0
    }

    func selfTestBadgeToolTip(titled title: String) -> String? {
        (selfTestCell(titled: title, inGroup: "") as? RelationCellView)?
            .selfTestBadgeToolTip
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

    var selfTestSelectedEdgeTitle: String? {
        guard isViewLoaded,
              let node = outlineView.item(atRow: outlineView.selectedRow)
                as? RelationTreeModel.Node,
              node.kind == .edge
        else { return nil }
        return node.title
    }

    var selfTestLastAccessibilityNotification: String? {
        outlineView.lastAccessibilityNotification?.rawValue
    }

    var selfTestAccessibilityNotificationCount: Int {
        outlineView.accessibilityNotificationCount
    }

    var selfTestOpenCount: Int {
        selfTestOpenSelectionCount
    }

    func selfTestPressKey(_ keyCode: UInt16) -> Bool {
        let characters = switch keyCode {
        case 125: String(UnicodeScalar(NSDownArrowFunctionKey)!)
        case 126: String(UnicodeScalar(NSUpArrowFunctionKey)!)
        case 36, 76: "\r"
        default: ""
        }
        guard isViewLoaded,
              let event = NSEvent.keyEvent(
                  with: .keyDown,
                  location: .zero,
                  modifierFlags: [],
                  timestamp: 0,
                  windowNumber: view.window?.windowNumber ?? 0,
                  context: nil,
                  characters: characters,
                  charactersIgnoringModifiers: characters,
                  isARepeat: false,
                  keyCode: keyCode
              )
        else { return false }
        view.window?.makeFirstResponder(outlineView)
        outlineView.keyDown(with: event)
        return true
    }

    func selfTestChangeDirection(_ direction: RelationTreeModel.Direction) {
        directionControl.selectedSegment = segment(for: direction)
        directionChanged(directionControl)
    }

    func selfTestOpenSelection() {
        openSelection(outlineView)
    }

    private var selfTestPossibleDisclosureItem: RelationTreeModel.Node? {
        possibleDisclosureItem
    }

    private var possibleDisclosureItem: RelationTreeModel.Node? {
        guard isViewLoaded else { return nil }
        return model.root?.children?.first {
            $0.kind == .group && $0.title.hasPrefix("Show ")
        }
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

    private func selfTestCell(
        titled title: String,
        inGroup titlePrefix: String
    ) -> NSTableCellView? {
        guard let child = selfTestVisibleEdgeNodes(inGroup: titlePrefix).first(
            where: { $0.title == title }
        )
        else { return nil }
        let childRow = outlineView.row(forItem: child)
        return outlineView.view(
            atColumn: 0,
            row: childRow,
            makeIfNecessary: true
        ) as? NSTableCellView
    }

    private func selfTestVisibleEdgeNodes(
        inGroup titlePrefix: String
    ) -> [RelationTreeModel.Node] {
        guard isViewLoaded else { return [] }
        if !titlePrefix.isEmpty,
           let row = selfTestGroupRow(titlePrefix: titlePrefix),
           let group = outlineView.item(atRow: row) as? RelationTreeModel.Node
        {
            return group.children?.filter {
                $0.kind == .edge && outlineView.row(forItem: $0) >= 0
            } ?? []
        }
        let possibleRows = Set(
            (selfTestPossibleDisclosureItem?.children ?? []).map(ObjectIdentifier.init)
        )
        let directRows = Set(
            (model.root?.children ?? [])
                .filter { $0.kind == .edge }
                .map(ObjectIdentifier.init)
        )
        return (0..<outlineView.numberOfRows).compactMap { row in
            guard let node = outlineView.item(atRow: row)
                    as? RelationTreeModel.Node,
                  node.kind == .edge
            else { return nil }
            return switch titlePrefix {
            case "Exact": node.badge == "Verified" ? node : nil
            case "Strong":
                node.badge == "Inferred"
                    && directRows.contains(ObjectIdentifier(node)) ? node : nil
            case "References":
                model.direction == .references ? node : nil
            case "Possible", "Probable":
                possibleRows.contains(ObjectIdentifier(node)) ? node : nil
            default: node
            }
        }
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

    private func selfTestFrameIsVisible(_ frame: NSRect) -> Bool {
        guard !scrollView.isHidden, frame.width > 0, frame.height > 0 else {
            return false
        }
        let intersection = selfTestRelationsVisibleRect.intersection(frame)
        return intersection.width > 0
            && intersection.height >= frame.height - 0.5
    }

    init(model: RelationTreeModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        model.onNodeChange = { [weak self] node in
            guard let self else { return }
            reloadNode(node)
            onTreeChange?()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        directionControl.selectedSegment = segment(for: model.direction)
        directionControl.target = self
        directionControl.action = #selector(directionChanged(_:))
        directionControl.selectedSegmentBezelColor = theme.accentColor
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
        outlineView.selectionChanged = { [weak self] in
            self?.selectSelection(nil)
        }
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
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(visibleBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        placeholderLabel.font = .systemFont(ofSize: 11)
        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.alignment = .center
        placeholderLabel.lineBreakMode = .byWordWrapping
        placeholderLabel.maximumNumberOfLines = 2
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false

        container.wantsLayer = true
        container.layer?.backgroundColor = theme.chromeColor.cgColor
        headerSurface.wantsLayer = true
        headerSurface.layer?.backgroundColor = theme.chromeHeaderColor.cgColor
        headerSurface.translatesAutoresizingMaskIntoConstraints = false
        headerSurface.addSubview(directionControl)
        container.addSubview(headerSurface)
        container.addSubview(scrollView)
        container.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            headerSurface.topAnchor.constraint(equalTo: container.topAnchor),
            headerSurface.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            headerSurface.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            directionControl.topAnchor.constraint(equalTo: headerSurface.topAnchor, constant: 8),
            directionControl.leadingAnchor.constraint(
                equalTo: headerSurface.leadingAnchor,
                constant: 8
            ),
            directionControl.trailingAnchor.constraint(
                equalTo: headerSurface.trailingAnchor,
                constant: -8
            ),
            headerSurface.bottomAnchor.constraint(equalTo: directionControl.bottomAnchor, constant: 8),
            scrollView.topAnchor.constraint(
                equalTo: headerSurface.bottomAnchor,
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
        layoutPassCount += 1
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
            reloadNode(root)
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
        cell.display(node, theme: theme)
        return cell
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        rowViewForItem item: Any
    ) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("ThemeSelectionRow")
        let row = outlineView.makeView(withIdentifier: identifier, owner: self)
            as? ThemeSelectionRowView ?? ThemeSelectionRowView()
        row.identifier = identifier
        row.selectionColor = theme.chromeSelectionColor
        return row
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        heightOfRowByItem item: Any
    ) -> CGFloat {
        guard let node = item as? RelationTreeModel.Node else { return 24 }
        return switch node.kind {
        case .edge, .root: 44
        case .group, .truncated, .loading, .error: 26
        case .evidenceLine: 24
        }
    }

    @objc private func selectSelection(_ sender: Any?) {
        outlineView.postSelectedRowsChanged()
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
            reloadNode(node)
            onTreeChange?()
            await expansion.value
            guard model.generation == generation else { return }
            reloadNode(node)
            onTreeChange?()
        }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"]
                as? RelationTreeModel.Node,
              node.kind == .group,
              node.title.hasPrefix("Show ")
        else { return }
        validateVisiblePossibleRows()
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"]
                as? RelationTreeModel.Node,
              node.kind == .group,
              node.title.hasPrefix("Show ")
        else { return }
        model.cancelPossibleValidation()
    }

    @objc private func visibleBoundsChanged(_ notification: Notification) {
        validateVisiblePossibleRows()
    }

    private func validateVisiblePossibleRows() {
        guard let disclosure = possibleDisclosureItem,
              outlineView.isItemExpanded(disclosure)
        else { return }
        let rows = disclosure.children ?? []
        let visibleRect = scrollView.contentView.documentVisibleRect
        let visibleIndexes = rows.indices.filter { index in
            let row = outlineView.row(forItem: rows[index])
            guard row >= 0 else { return false }
            let intersection = outlineView.rect(ofRow: row)
                .intersection(visibleRect)
            return intersection.width > 0 && intersection.height > 0
        }
        guard let firstVisible = visibleIndexes.first,
              let lastVisible = visibleIndexes.last
        else { return }
        var prioritized = visibleIndexes.map { rows[$0] }
        if prioritized.count < RelationTreeModel.possibleValidationBatchSize {
            let nearby = rows.indices.filter { $0 > lastVisible }
                + rows.indices.reversed().filter { $0 < firstVisible }
            prioritized += nearby.map { rows[$0] }
        }
        model.validatePossible(
            Array(prioritized.prefix(
                RelationTreeModel.possibleValidationBatchSize
            ))
        )
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
            selfTestOpenSelectionCount += 1
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
        wholeTreeReloadCount += 1
        outlineView.reloadData()
        fitOutlineWidthToVisibleRect()
        if let root = model.root { outlineView.expandItem(root) }
        let isEmpty = model.root == nil
        placeholderLabel.isHidden = !isEmpty
        scrollView.isHidden = isEmpty
    }

    private func reloadNode(_ node: RelationTreeModel.Node) {
        guard isViewLoaded else { return }
        let selectedItem = outlineView.item(atRow: outlineView.selectedRow)
            as? RelationTreeModel.Node
        let visibleOrigin = scrollView.contentView.bounds.origin
        nodeReloadCount += 1
        outlineView.reloadItem(node, reloadChildren: true)
        expandLoadedGroups(under: node)
        if let selectedItem {
            let row = outlineView.row(forItem: selectedItem)
            if row >= 0 {
                outlineView.selectRowIndexes(
                    IndexSet(integer: row),
                    byExtendingSelection: false
                )
            }
        }
        scrollView.contentView.scroll(to: visibleOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func expandLoadedGroups(under node: RelationTreeModel.Node) {
        outlineView.expandItem(node)
        for child in node.children ?? []
            where child.kind == .group && !child.title.hasPrefix("Show ")
        {
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
    var selectionChanged: (() -> Void)?
    private(set) var lastAccessibilityNotification:
        NSAccessibility.Notification?
    private(set) var accessibilityNotificationCount = 0

    func postSelectedRowsChanged() {
        lastAccessibilityNotification = .selectedRowsChanged
        accessibilityNotificationCount += 1
        NSAccessibility.post(
            element: self,
            notification: .selectedRowsChanged
        )
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            openSelection?()
        } else {
            let selectedRowBeforeKey = selectedRow
            super.keyDown(with: event)
            if selectedRow != selectedRowBeforeKey {
                selectionChanged?()
            }
        }
    }
}

@MainActor
private final class RelationCellView: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let countPill = NSStackView()
    private let locationLabel = NSTextField(labelWithString: "")
    private let dispatchLabel = NSTextField(labelWithString: "")
    private let dispatchChip = NSStackView()
    private let modifiersLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private let badgePill = NSStackView()
    private let spinner = NSProgressIndicator()

    init() {
        super.init(frame: .zero)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        locationLabel.lineBreakMode = .byTruncatingMiddle
        locationLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        dispatchLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        modifiersLabel.lineBreakMode = .byTruncatingTail
        modifiersLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badgeLabel.setContentHuggingPriority(.required, for: .horizontal)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        dispatchChip.orientation = .horizontal
        dispatchChip.alignment = .centerY
        dispatchChip.edgeInsets = NSEdgeInsets(top: 1, left: 5, bottom: 1, right: 5)
        dispatchChip.setContentHuggingPriority(.required, for: .horizontal)
        dispatchChip.setContentCompressionResistancePriority(.required, for: .horizontal)
        dispatchChip.wantsLayer = true
        dispatchChip.layer?.cornerRadius = 4
        dispatchChip.addArrangedSubview(dispatchLabel)
        badgePill.orientation = .horizontal
        badgePill.alignment = .centerY
        badgePill.edgeInsets = NSEdgeInsets(top: 1, left: 5, bottom: 1, right: 5)
        badgePill.setContentHuggingPriority(.required, for: .horizontal)
        badgePill.setContentCompressionResistancePriority(.required, for: .horizontal)
        badgePill.wantsLayer = true
        badgePill.layer?.cornerRadius = 4
        badgePill.addArrangedSubview(badgeLabel)
        NSLayoutConstraint.activate([
            badgePill.widthAnchor.constraint(
                equalTo: badgeLabel.widthAnchor,
                constant: 10
            ),
            badgePill.heightAnchor.constraint(
                equalTo: badgeLabel.heightAnchor,
                constant: 2
            ),
        ])
        countPill.orientation = .horizontal
        countPill.alignment = .centerY
        countPill.edgeInsets = NSEdgeInsets(top: 1, left: 7, bottom: 1, right: 7)
        countPill.setContentHuggingPriority(.required, for: .horizontal)
        countPill.setContentCompressionResistancePriority(.required, for: .horizontal)
        countPill.wantsLayer = true
        countPill.layer?.cornerRadius = 20
        countPill.addArrangedSubview(countLabel)
        let detail = NSStackView(views: [locationLabel, dispatchChip, modifiersLabel])
        detail.orientation = .horizontal
        detail.alignment = .centerY
        detail.spacing = 5
        let titleRow = NSStackView(views: [titleLabel, countPill])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 7
        let labels = NSStackView(views: [titleRow, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        let row = NSStackView(views: [spinner, labels, badgePill])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = titleLabel
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func display(_ node: RelationTreeModel.Node, theme: ReaderTheme) {
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        locationLabel.isHidden = true
        dispatchChip.isHidden = true
        modifiersLabel.isHidden = true
        countPill.isHidden = true
        titleLabel.textColor = theme.foregroundColor
        locationLabel.textColor = theme.chromeSecondaryColor
        dispatchLabel.textColor = theme.chipForegroundColor
        dispatchChip.layer?.backgroundColor = theme.chipBackgroundColor.cgColor
        modifiersLabel.textColor = theme.chromeTertiaryColor
        countLabel.textColor = theme.chromeSecondaryColor
        countPill.layer?.backgroundColor = theme.chipBackgroundColor.cgColor
        badgeLabel.stringValue = node.badge ?? ""
        badgePill.isHidden = node.badge == nil
        badgeLabel.toolTip = switch node.badge {
        case "Verified": "Verified by rust-analyzer"
        case "Inferred": "Inferred from source structure"
        case "Unresolved": "Unresolved source target"
        default: nil
        }
        switch node.badge {
        case "Verified":
            badgeLabel.textColor = theme.verifiedColor
            badgePill.layer?.backgroundColor = theme.verifiedBackgroundColor.cgColor
            badgePill.layer?.borderWidth = 0
        case "Unresolved":
            badgeLabel.textColor = theme.unresolvedColor
            badgePill.layer?.backgroundColor = NSColor.clear.cgColor
            badgePill.layer?.borderColor = theme.unresolvedBorderColor.cgColor
            badgePill.layer?.borderWidth = 1
        default:
            badgeLabel.textColor = theme.inferredColor
            badgePill.layer?.backgroundColor = theme.inferredBackgroundColor.cgColor
            badgePill.layer?.borderWidth = 0
        }
        badgeLabel.font = .systemFont(ofSize: 10, weight: .semibold)

        switch node.kind {
        case .root:
            titleLabel.stringValue = node.title
            titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
            locationLabel.stringValue = location(of: node) ?? ""
            locationLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            locationLabel.toolTip = location(of: node)
            locationLabel.isHidden = locationLabel.stringValue.isEmpty
        case .group:
            if node.title.hasPrefix("Show ") {
                titleLabel.stringValue = "Show possible matches"
                titleLabel.font = .systemFont(ofSize: 11.5, weight: .semibold)
                titleLabel.textColor = theme.accentColor
                countLabel.stringValue = node.title.split(separator: " ")
                    .dropFirst().first.map(String.init) ?? ""
                countLabel.font = .systemFont(ofSize: 10, weight: .semibold)
                countPill.isHidden = countLabel.stringValue.isEmpty
            } else {
                titleLabel.stringValue = node.title.uppercased()
                titleLabel.font = .systemFont(ofSize: 10, weight: .semibold)
                titleLabel.textColor = theme.chromeSecondaryColor
            }
        case .edge:
            titleLabel.stringValue = node.title
            titleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
            locationLabel.stringValue = location(of: node) ?? ""
            locationLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            locationLabel.toolTip = location(of: node)
            locationLabel.isHidden = locationLabel.stringValue.isEmpty
            dispatchLabel.stringValue = node.dispatchLabel ?? ""
            dispatchLabel.font = .monospacedSystemFont(ofSize: 9.5, weight: .medium)
            dispatchChip.isHidden = dispatchLabel.stringValue.isEmpty
            modifiersLabel.stringValue = node.modifiers.joined(separator: " · ")
            modifiersLabel.font = .systemFont(ofSize: 10)
            modifiersLabel.isHidden = modifiersLabel.stringValue.isEmpty
        case .evidenceLine:
            titleLabel.stringValue = "  \(node.title)"
            titleLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
            titleLabel.textColor = theme.chromeTertiaryColor
        case .loading:
            titleLabel.stringValue = node.title
            titleLabel.font = .systemFont(ofSize: 11)
            titleLabel.textColor = theme.chromeSecondaryColor
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
        setAccessibilityLabel(node.title)
        setAccessibilityValue(
            [node.subtitle, node.badge].compactMap { $0 }.joined(separator: ", ")
        )
    }

    func selfTestBadgeFrame(in view: NSView) -> NSRect {
        badgePill.convert(badgePill.bounds, to: view)
    }

    func selfTestBadgeLabelFrame(in view: NSView) -> NSRect {
        badgeLabel.convert(badgeLabel.bounds, to: view)
    }

    var selfTestBadgeToolTip: String? { badgeLabel.toolTip }
    var selfTestBadgeCornerRadius: CGFloat { badgePill.layer?.cornerRadius ?? 0 }
    var selfTestTitleAndCount: [String] {
        [titleLabel.stringValue, countLabel.stringValue]
    }

    private func location(of node: RelationTreeModel.Node) -> String? {
        guard let target = node.target else { return nil }
        return node.line.map { "\(target.path):\($0)" } ?? target.path
    }

}
