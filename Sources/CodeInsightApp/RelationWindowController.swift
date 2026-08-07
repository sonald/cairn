import AppKit
import CodeInsightAppModel
import CodeInsightCore
import CodeInsightExact
import CodeInsightReaderCore
import Observation

@MainActor
final class RelationWindowController: NSViewController,
    NSOutlineViewDataSource, NSOutlineViewDelegate
{
    var onOpen: ((RelationTreeModel.Node) -> Void)?
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
    private let contentSplit = NSStackView()
    private let listPane = NSView()
    private let inspectorView = ResolutionInspectorView()
    private let inspectButton = NSButton()
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
    private var inspectedNode: RelationTreeModel.Node?
    private let verificationReadiness: () -> ExactCoordinator.Readiness

    func apply(settings: ReaderSettings) {
        theme = ReaderTheme(settings: settings)
        guard isViewLoaded else { return }
        container.layer?.backgroundColor = theme.chromeColor.cgColor
        headerSurface.layer?.backgroundColor = theme.chromeHeaderColor.cgColor
        listPane.layer?.backgroundColor = theme.chromeColor.cgColor
        contentSplit.layer?.backgroundColor = theme.chromeDividerColor.cgColor
        directionControl.selectedSegmentBezelColor = theme.accentColor
        outlineView.backgroundColor = theme.chromeColor
        inspectorView.apply(theme: theme)
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
    var selfTestInspectorButtonTitle: String {
        loadViewIfNeeded()
        return inspectButton.title
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

    var selfTestCorrectedDisclosureDisplayText: [String] {
        guard let item = model.root?.children?.first(where: {
            $0.kind == .group
                && $0.title.hasPrefix("Show corrected candidates")
        }) else { return [] }
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

    var selfTestInspectorVisible: Bool {
        let frame = selfTestInspectorFrame
        return frame.width > 0 && frame.height > 0
    }

    var selfTestInspectorFrame: NSRect {
        inspectorView.isHidden
            ? .zero : inspectorView.convert(inspectorView.bounds, to: view)
    }

    var selfTestRelationListFrame: NSRect {
        listPane.convert(listPane.bounds, to: view)
    }

    var selfTestInspectorText: [String] {
        inspectorView.selfTestVisibleText
    }

    var selfTestInspectorAuditVisible: Bool {
        inspectorView.selfTestAuditVisible
    }

    var selfTestInspectorAccessibility: (String, String, String, Bool) {
        inspectorView.selfTestAccessibility
    }

    func selfTestClickBadge(titled title: String) -> Bool {
        guard let cell = selfTestCell(titled: title, inGroup: "")
            as? RelationCellView
        else { return false }
        cell.selfTestInspect()
        return true
    }

    func selfTestToggleInspectorAudit() {
        inspectorView.selfTestToggleAudit()
    }

    func selfTestExpandCorrectedCandidates() -> Bool {
        guard let group = model.root?.children?.first(where: {
            $0.kind == .group
                && $0.title.hasPrefix("Show corrected candidates")
        }) else { return false }
        outlineView.expandItem(group)
        return outlineView.isItemExpanded(group)
    }

    func selfTestSelectCorrectedCandidate(titled title: String) -> Bool {
        guard let group = model.root?.children?.first(where: {
            $0.kind == .group
                && $0.title.hasPrefix("Show corrected candidates")
        }), let node = group.children?.first(where: { $0.title == title })
        else { return false }
        outlineView.expandItem(group)
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return false }
        outlineView.selectRowIndexes(
            IndexSet(integer: row),
            byExtendingSelection: false
        )
        selectSelection(nil)
        return true
    }

    func selfTestOpenFormerCandidate() {
        inspectorView.selfTestOpenFormerCandidate()
    }

    func selfTestCloseInspector() { hideInspector() }

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

    func selfTestPressInspectorShortcut() -> Bool {
        guard isViewLoaded,
              let event = NSEvent.keyEvent(
                  with: .keyDown,
                  location: .zero,
                  modifierFlags: .command,
                  timestamp: 0,
                  windowNumber: view.window?.windowNumber ?? 0,
                  context: nil,
                  characters: "i",
                  charactersIgnoringModifiers: "i",
                  isARepeat: false,
                  keyCode: 34
              )
        else { return false }
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
            $0.kind == .group
                && $0.title.hasPrefix("Show ")
                && !$0.title.hasPrefix("Show corrected candidates")
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

    init(
        model: RelationTreeModel,
        verificationReadiness: @escaping () -> ExactCoordinator.Readiness = {
            .off("no project")
        }
    ) {
        self.model = model
        self.verificationReadiness = verificationReadiness
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
        outlineView.inspectSelection = { [weak self] in
            self?.inspectSelection(nil)
        }
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

        inspectButton.image = NSImage(
            systemSymbolName: "info.circle",
            accessibilityDescription: "Show Resolution Inspector"
        )
        inspectButton.title = "Inspector"
        inspectButton.imagePosition = .imageLeading
        inspectButton.font = .systemFont(ofSize: 11, weight: .semibold)
        inspectButton.bezelStyle = .accessoryBarAction
        inspectButton.isBordered = true
        inspectButton.toolTip = "Show Resolution Inspector (⌘I)"
        inspectButton.setAccessibilityLabel("Show Resolution Inspector")
        inspectButton.target = self
        inspectButton.action = #selector(inspectSelection(_:))
        inspectButton.isEnabled = false
        inspectButton.translatesAutoresizingMaskIntoConstraints = false

        contentSplit.orientation = .horizontal
        contentSplit.distribution = .fillEqually
        contentSplit.spacing = 1
        contentSplit.wantsLayer = true
        contentSplit.layer?.backgroundColor = theme.chromeDividerColor.cgColor
        contentSplit.translatesAutoresizingMaskIntoConstraints = false
        contentSplit.addArrangedSubview(listPane)
        contentSplit.addArrangedSubview(inspectorView)
        inspectorView.isHidden = true
        listPane.wantsLayer = true
        listPane.layer?.backgroundColor = theme.chromeColor.cgColor
        inspectorView.widthAnchor.constraint(
            greaterThanOrEqualToConstant: 220
        ).isActive = true
        listPane.addSubview(scrollView)
        listPane.addSubview(placeholderLabel)
        inspectorView.onClose = { [weak self] in self?.hideInspector() }
        inspectorView.onOpenFormerCandidate = { [weak self] in
            self?.openInspectedFormerCandidate()
        }

        container.wantsLayer = true
        container.layer?.backgroundColor = theme.chromeColor.cgColor
        headerSurface.wantsLayer = true
        headerSurface.layer?.backgroundColor = theme.chromeHeaderColor.cgColor
        headerSurface.translatesAutoresizingMaskIntoConstraints = false
        headerSurface.addSubview(directionControl)
        headerSurface.addSubview(inspectButton)
        container.addSubview(headerSurface)
        container.addSubview(contentSplit)
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
                equalTo: inspectButton.leadingAnchor,
                constant: -6
            ),
            inspectButton.trailingAnchor.constraint(
                equalTo: headerSurface.trailingAnchor,
                constant: -8
            ),
            inspectButton.centerYAnchor.constraint(
                equalTo: directionControl.centerYAnchor
            ),
            inspectButton.widthAnchor.constraint(equalToConstant: 82),
            inspectButton.heightAnchor.constraint(equalToConstant: 22),
            headerSurface.bottomAnchor.constraint(equalTo: directionControl.bottomAnchor, constant: 8),
            contentSplit.topAnchor.constraint(
                equalTo: headerSurface.bottomAnchor,
                constant: 6
            ),
            contentSplit.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            contentSplit.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            contentSplit.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scrollView.topAnchor.constraint(equalTo: listPane.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: listPane.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: listPane.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: listPane.bottomAnchor),
            placeholderLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            placeholderLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: listPane.leadingAnchor,
                constant: 16
            ),
            placeholderLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: listPane.trailingAnchor,
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
        cell.onInspect = { [weak self, weak node] in
            guard let node else { return }
            self?.inspectBadge(for: node)
        }
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
            inspectButton.isEnabled = false
            model.clearSelection()
            return
        }
        inspectButton.isEnabled = node.explanation != nil
        showInspector(for: node)
        if node.modifiers.contains("Conflict/Corrected") { return }
        model.select(node)
        guard node.representsLocation, node.target != nil else { return }
        onOpen?(node)
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
              node.target != nil
        else { return }
        if node.modifiers.contains("Conflict/Corrected") {
            showInspector(for: node)
            return
        }
        if !node.representsLocation || sender == nil {
            selfTestOpenSelectionCount += 1
            onOpen?(node)
        }
        guard let symbol = node.symbol,
              symbol.localKind == .declarationFacet
        else { return }
        setRoot(target: .engine(symbol), direction: model.direction)
    }

    @objc private func inspectSelection(_ sender: Any?) {
        guard outlineView.selectedRow >= 0,
              let node = outlineView.item(atRow: outlineView.selectedRow)
                as? RelationTreeModel.Node,
              node.kind == .edge
        else { return }
        showInspector(for: node)
    }

    var canInspectSelection: Bool {
        guard outlineView.selectedRow >= 0,
              let node = outlineView.item(atRow: outlineView.selectedRow)
                as? RelationTreeModel.Node
        else { return false }
        return node.kind == .edge && node.explanation != nil
    }

    @discardableResult
    func showSelectedInspector() -> Bool {
        guard canInspectSelection,
              let node = outlineView.item(atRow: outlineView.selectedRow)
                as? RelationTreeModel.Node
        else { return false }
        showInspector(for: node)
        return !inspectorView.isHidden
    }

    private func showInspector(for node: RelationTreeModel.Node) {
        guard let explanation = node.explanation,
              let context = model.relationQueryContexts[explanation.contextID]
        else { return }
        inspectedNode = node
        inspectorView.isHidden = false
        view.layoutSubtreeIfNeeded()
        inspectorView.display(
            node: node,
            clauses: narrativeClauses(for: explanation, context: context),
            context: context,
            correctedTitles: correctedTitles(for: node),
            readiness: verificationReadiness(),
            theme: theme
        )
    }

    private func inspectBadge(for node: RelationTreeModel.Node) {
        let row = outlineView.row(forItem: node)
        if row >= 0 {
            outlineView.selectRowIndexes(
                IndexSet(integer: row),
                byExtendingSelection: false
            )
            outlineView.postSelectedRowsChanged()
        }
        inspectButton.isEnabled = node.explanation != nil
        showInspector(for: node)
    }

    func refreshInspector() {
        guard let inspectedNode else { return }
        showInspector(for: inspectedNode)
    }

    private func hideInspector() {
        inspectedNode = nil
        guard !inspectorView.isHidden else { return }
        inspectorView.isHidden = true
        view.layoutSubtreeIfNeeded()
    }

    private func openInspectedFormerCandidate() {
        guard let inspectedNode,
              inspectedNode.modifiers.contains("Conflict/Corrected")
        else { return }
        onOpen?(inspectedNode)
    }

    private func correctedTitles(
        for node: RelationTreeModel.Node
    ) -> [String] {
        guard let refs = node.explanation?.reconciliationRefs else { return [] }
        let reconciliationIDs = Set(refs.compactMap { reference in
            if case .correctedCandidate = reference.role {
                return reference.reconciliationID
            }
            return nil
        })
        guard !reconciliationIDs.isEmpty else { return [] }
        return (model.root?.children ?? []).filter {
            $0.kind == .group
                && $0.title.hasPrefix("Show corrected candidates")
        }.flatMap { $0.children ?? [] }.filter { candidate in
            guard case .conflict(_, let reference) =
                    candidate.explanation?.primaryTrace
            else { return false }
            return reconciliationIDs.contains(reference.reconciliationID)
        }.map(\.title)
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
            hideInspector()
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
        if inspectedNode === node || inspectedNode === selectedItem {
            refreshInspector()
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
    var inspectSelection: (() -> Void)?
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
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "i"
        {
            inspectSelection?()
        } else if event.keyCode == 36 || event.keyCode == 76 {
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
private final class InspectableBadgeView: NSStackView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

@MainActor
final class RelationChipView: NSStackView {
    private let label = NSTextField(labelWithString: "")
    private let dashedBorder = CAShapeLayer()

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        edgeInsets = NSEdgeInsets(top: 1, left: 5, bottom: 1, right: 5)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        wantsLayer = true
        layer?.cornerRadius = 4
        label.font = .systemFont(ofSize: 9.5, weight: .medium)
        addArrangedSubview(label)
        dashedBorder.fillColor = NSColor.clear.cgColor
        dashedBorder.lineWidth = 1
        dashedBorder.lineDashPattern = [3, 2]
        layer?.addSublayer(dashedBorder)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var text: String { label.stringValue }

    override var intrinsicContentSize: NSSize {
        let size = label.intrinsicContentSize
        return NSSize(
            width: size.width + edgeInsets.left + edgeInsets.right,
            height: size.height + edgeInsets.top + edgeInsets.bottom
        )
    }

    func display(
        _ text: String?,
        foreground: NSColor,
        background: NSColor,
        border: NSColor,
        dashed: Bool = false
    ) {
        label.stringValue = text ?? ""
        label.textColor = foreground
        layer?.backgroundColor = background.cgColor
        layer?.borderColor = border.cgColor
        layer?.borderWidth = dashed ? 0 : 1
        dashedBorder.strokeColor = border.cgColor
        dashedBorder.isHidden = !dashed
        isHidden = text == nil
        invalidateIntrinsicContentSize()
    }

    override func layout() {
        super.layout()
        dashedBorder.frame = bounds
        dashedBorder.path = CGPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            cornerWidth: 4,
            cornerHeight: 4,
            transform: nil
        )
    }
}

@MainActor
private final class InspectorDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class ResolutionInspectorView: NSView {
    var onClose: (() -> Void)?
    var onOpenFormerCandidate: (() -> Void)?

    private let header = NSView()
    private let headerTitle = NSTextField(labelWithString: "Resolution Inspector")
    private let closeButton = NSButton()
    private let scrollView = NSScrollView()
    private let documentView = InspectorDocumentView()
    private let content = NSStackView()
    private let nodeTitle = NSTextField(labelWithString: "")
    private let badge = RelationChipView()
    private let why = NSTextField(wrappingLabelWithString: "")
    private let sourceTitle = NSTextField(labelWithString: "SOURCE")
    private let sourceBody = NSTextField(wrappingLabelWithString: "")
    private let sourceSection = NSStackView()
    private let verificationTitle = NSTextField(labelWithString: "VERIFICATION")
    private let verificationBody = NSTextField(wrappingLabelWithString: "")
    private let verificationSection = NSStackView()
    private let correctionTitle = NSTextField(labelWithString: "CORRECTED CANDIDATES")
    private let correctionBody = NSTextField(wrappingLabelWithString: "")
    private let correctionSection = NSStackView()
    private let availabilityTitle = NSTextField(
        labelWithString: "VERIFICATION AVAILABILITY"
    )
    private let availabilityBody = NSTextField(wrappingLabelWithString: "")
    private let availabilitySection = NSStackView()
    private let environmentTitle = NSTextField(
        labelWithString: "ANALYSIS ENVIRONMENT"
    )
    private let environmentBody = NSTextField(wrappingLabelWithString: "")
    private let environmentSection = NSStackView()
    private let auditButton = NSButton(title: "Show full audit", target: nil, action: nil)
    private let auditStack = NSStackView()
    private let formerCandidateButton = NSButton(
        title: "Open former candidate",
        target: nil,
        action: nil
    )
    private var theme = ReaderTheme(settings: ReaderSettings())

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        header.wantsLayer = true
        header.translatesAutoresizingMaskIntoConstraints = false
        headerTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        headerTitle.translatesAutoresizingMaskIntoConstraints = false
        closeButton.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: "Close Resolution Inspector"
        )
        closeButton.isBordered = false
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.toolTip = "Close Resolution Inspector"
        closeButton.setAccessibilityLabel("Close Resolution Inspector")
        closeButton.target = self
        closeButton.action = #selector(closeInspector(_:))
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerTitle)
        header.addSubview(closeButton)

        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        documentView.translatesAutoresizingMaskIntoConstraints = false
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(content)

        nodeTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        nodeTitle.lineBreakMode = .byTruncatingMiddle
        badge.setContentHuggingPriority(.required, for: .horizontal)
        nodeTitle.setContentHuggingPriority(.required, for: .horizontal)
        let identitySpacer = NSView()
        identitySpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let identity = NSStackView(views: [nodeTitle, badge, identitySpacer])
        identity.orientation = .horizontal
        identity.alignment = .centerY
        identity.spacing = 8
        why.font = .systemFont(ofSize: 12, weight: .medium)
        configure(section: sourceSection, title: sourceTitle, body: sourceBody)
        configure(
            section: verificationSection,
            title: verificationTitle,
            body: verificationBody
        )
        configure(
            section: correctionSection,
            title: correctionTitle,
            body: correctionBody
        )
        configure(
            section: availabilitySection,
            title: availabilityTitle,
            body: availabilityBody
        )
        configure(
            section: environmentSection,
            title: environmentTitle,
            body: environmentBody
        )
        auditButton.bezelStyle = .inline
        auditButton.font = .systemFont(ofSize: 11, weight: .medium)
        auditButton.target = self
        auditButton.action = #selector(toggleAudit(_:))
        auditButton.setAccessibilityLabel("Show full resolution audit")
        formerCandidateButton.bezelStyle = .inline
        formerCandidateButton.font = .systemFont(ofSize: 11, weight: .medium)
        formerCandidateButton.target = self
        formerCandidateButton.action = #selector(openFormerCandidate(_:))
        formerCandidateButton.setAccessibilityLabel("Open former candidate")
        auditStack.orientation = .vertical
        auditStack.alignment = .leading
        auditStack.spacing = 5
        auditStack.isHidden = true
        [
            identity,
            why,
            sourceSection,
            verificationSection,
            correctionSection,
            availabilitySection,
            environmentSection,
            formerCandidateButton,
            auditButton,
            auditStack,
        ].forEach(content.addArrangedSubview)

        addSubview(header)
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 34),
            headerTitle.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 10),
            headerTitle.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            closeButton.heightAnchor.constraint(equalToConstant: 20),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            content.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 12),
            content.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -12),
            content.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -12),
            identity.widthAnchor.constraint(equalTo: content.widthAnchor),
            why.widthAnchor.constraint(equalTo: content.widthAnchor),
            sourceSection.widthAnchor.constraint(equalTo: content.widthAnchor),
            verificationSection.widthAnchor.constraint(equalTo: content.widthAnchor),
            correctionSection.widthAnchor.constraint(equalTo: content.widthAnchor),
            availabilitySection.widthAnchor.constraint(equalTo: content.widthAnchor),
            environmentSection.widthAnchor.constraint(equalTo: content.widthAnchor),
            auditStack.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
        setAccessibilityRole(.group)
        setAccessibilityLabel("Resolution Inspector")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var selfTestVisibleText: [String] {
        [
            nodeTitle.stringValue,
            badge.text,
            why.stringValue,
            sourceSection.isHidden ? nil : sourceTitle.stringValue,
            sourceSection.isHidden ? nil : sourceBody.stringValue,
            verificationSection.isHidden ? nil : verificationTitle.stringValue,
            verificationSection.isHidden ? nil : verificationBody.stringValue,
            correctionSection.isHidden ? nil : correctionTitle.stringValue,
            correctionSection.isHidden ? nil : correctionBody.stringValue,
            availabilityTitle.stringValue,
            availabilityBody.stringValue,
            environmentSection.isHidden ? nil : environmentTitle.stringValue,
            environmentSection.isHidden ? nil : environmentBody.stringValue,
            formerCandidateButton.isHidden ? nil : formerCandidateButton.title,
            auditButton.title,
        ].compactMap { $0 }
    }

    var selfTestAuditVisible: Bool { !auditStack.isHidden }

    var selfTestAccessibility: (String, String, String, Bool) {
        (
            accessibilityLabel() ?? "",
            accessibilityValue() as? String ?? "",
            accessibilityRole()?.rawValue ?? "",
            isAccessibilitySelectorAllowed(
                NSSelectorFromString("setAccessibilityValue:")
            )
        )
    }

    func selfTestToggleAudit() { toggleAudit(nil) }
    func selfTestOpenFormerCandidate() { openFormerCandidate(nil) }

    func apply(theme: ReaderTheme) {
        self.theme = theme
        layer?.backgroundColor = theme.chromeColor.cgColor
        header.layer?.backgroundColor = theme.chromeHeaderColor.cgColor
        headerTitle.textColor = theme.foregroundColor
        nodeTitle.textColor = theme.foregroundColor
        why.textColor = theme.foregroundColor
        for label in [
            sourceTitle,
            verificationTitle,
            correctionTitle,
            availabilityTitle,
            environmentTitle,
        ] {
            label.textColor = label === correctionTitle
                ? theme.warningColor : theme.chromeSecondaryColor
        }
        [sourceBody, verificationBody, correctionBody, availabilityBody,
         environmentBody].forEach { $0.textColor = theme.chromeSecondaryColor }
        styleButton(auditButton, color: theme.accentColor)
        styleButton(formerCandidateButton, color: theme.warningColor)
        for row in auditStack.arrangedSubviews.compactMap({ $0 as? NSStackView }) {
            (row.arrangedSubviews.first as? NSTextField)?.textColor =
                theme.chromeTertiaryColor
            (row.arrangedSubviews.last as? NSTextField)?.textColor =
                theme.chromeSecondaryColor
        }
    }

    func display(
        node: RelationTreeModel.Node,
        clauses: [NarrativeClause],
        context: RelationQueryContext,
        correctedTitles: [String],
        readiness: ExactCoordinator.Readiness,
        theme: ReaderTheme
    ) {
        nodeTitle.stringValue = node.title
        switch node.badge {
        case "Verified":
            badge.display(
                "VERIFIED",
                foreground: theme.verifiedColor,
                background: theme.verifiedBackgroundColor,
                border: theme.verifiedBackgroundColor
            )
        case "Unresolved":
            badge.display(
                "UNRESOLVED",
                foreground: theme.unresolvedColor,
                background: .clear,
                border: theme.unresolvedBorderColor
            )
        default:
            badge.display(
                "INFERRED",
                foreground: theme.inferredColor,
                background: theme.inferredBackgroundColor,
                border: theme.inferredBackgroundColor
            )
        }
        let sourceClauses = clauses.filter(isSourceClause)
        let verificationClauses = clauses.filter { !isSourceClause($0) }
        why.stringValue = (sourceClauses.first ?? verificationClauses.first)
            .map(renderEnglish) ?? "No resolution explanation is available."
        sourceBody.stringValue = sourceClauses.map(renderEnglish)
            .joined(separator: " ")
        sourceSection.isHidden = sourceClauses.isEmpty
        verificationBody.stringValue = verificationClauses.map(renderEnglish)
            .joined(separator: " ")
        verificationSection.isHidden = verificationClauses.isEmpty
        verificationTitle.stringValue = verificationClauses.contains {
            if case .conflict = $0 { return true }
            return false
        } ? "VERIFICATION CONFLICT" : "VERIFICATION"
        correctionBody.stringValue = correctedTitles.isEmpty ? "" :
            "This target replaced earlier source candidates: "
                + correctedTitles.joined(separator: ", ") + "."
        correctionSection.isHidden = correctedTitles.isEmpty
        availabilityBody.stringValue = readinessText(readiness)
        let environment = analysisEnvironment(
            for: node.explanation,
            context: context
        )
        environmentBody.stringValue = environmentText(environment)
        environmentSection.isHidden = environment == nil
        formerCandidateButton.isHidden =
            !node.modifiers.contains("Conflict/Corrected")
        auditStack.isHidden = true
        auditButton.title = "Show full audit"
        rebuildAudit(
            auditRows(for: node.explanation, context: context),
            theme: theme
        )
        setAccessibilityLabel("Resolution Inspector for \(node.title)")
        setAccessibilityValue(
            ([node.badge, why.stringValue].compactMap { $0 }
                + clauses.map(renderEnglish))
                .joined(separator: ", ")
        )
        apply(theme: theme)
    }

    @objc private func closeInspector(_ sender: Any?) { onClose?() }

    @objc private func openFormerCandidate(_ sender: Any?) {
        onOpenFormerCandidate?()
    }

    @objc private func toggleAudit(_ sender: Any?) {
        auditStack.isHidden.toggle()
        auditButton.title = auditStack.isHidden
            ? "Show full audit" : "Hide full audit"
        auditButton.setAccessibilityLabel(auditButton.title)
        styleButton(auditButton, color: theme.accentColor)
    }

    private func configure(
        section: NSStackView,
        title: NSTextField,
        body: NSTextField
    ) {
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 4
        title.font = .systemFont(ofSize: 10, weight: .semibold)
        body.font = .systemFont(ofSize: 11)
        section.addArrangedSubview(title)
        section.addArrangedSubview(body)
        body.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
    }

    private func styleButton(_ button: NSButton, color: NSColor) {
        button.attributedTitle = NSAttributedString(
            string: button.title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: color,
            ]
        )
    }

    private func rebuildAudit(
        _ rows: [(String, String)],
        theme: ReaderTheme
    ) {
        auditStack.arrangedSubviews.forEach {
            auditStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for (key, value) in rows {
            let keyLabel = NSTextField(labelWithString: key)
            keyLabel.font = .systemFont(ofSize: 10)
            keyLabel.textColor = theme.chromeTertiaryColor
            keyLabel.setContentHuggingPriority(.required, for: .horizontal)
            let valueLabel = NSTextField(wrappingLabelWithString: value)
            valueLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            valueLabel.textColor = theme.chromeSecondaryColor
            let row = NSStackView(views: [keyLabel, valueLabel])
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 8
            auditStack.addArrangedSubview(row)
            valueLabel.widthAnchor.constraint(
                lessThanOrEqualTo: auditStack.widthAnchor,
                constant: -78
            ).isActive = true
        }
    }

    private func auditRows(
        for explanation: RelationRowExplanation?,
        context: RelationQueryContext
    ) -> [(String, String)] {
        guard let explanation else { return [] }
        let candidate = candidateObservation(explanation.primaryTrace)
        let attribution = exactAttribution(
            explanation.primaryTrace,
            context: context
        )
        var rows: [(String, String)] = [
            ("Resolver", resolverText(candidate: candidate, attribution: attribution)),
            ("Certainty", certaintyText(candidate?.certainty, verified: attribution != nil)),
            ("Dispatch", dispatchText(candidate?.dispatch)),
            ("Evidence", candidate.map { evidenceText($0.evidence) } ?? "—"),
            ("Candidate coverage", candidate.map {
                completenessText($0.completeness)
            } ?? "n/a"),
        ]
        if case .completed(let observation) = context.candidateQuery {
            rows.append((
                "Relation set",
                "\(completenessText(observation.completeness)) · returned \(observation.returnedCount)"
            ))
        }
        if case .completed(.completed(_, let origin, let exhaustiveness)) =
            context.exactQuery
        {
            rows.append(("Query exhaustiveness", exhaustivenessText(exhaustiveness)))
            rows.append(("Exact origin", originText(origin)))
        }
        if let snapshot = candidateSnapshot(candidate) {
            rows.append(("Snapshot", String(snapshot.uuidString.prefix(8))))
        }
        if let attribution {
            rows.append((
                "Profile",
                "\(attribution.featureSelection.rawValue) · \(trustText(attribution.environment.trustMode))"
            ))
            rows.append(("Provider", "\(attribution.provider) \(attribution.toolVersion)"))
        }
        return rows
    }

    private func isSourceClause(_ clause: NarrativeClause) -> Bool {
        switch clause {
        case .sourceEvidence, .candidateCompleteness, .candidateRelationSet: true
        default: false
        }
    }

    private func candidateObservation(
        _ trace: ResolutionTrace
    ) -> CandidateObservation? {
        switch trace {
        case .candidateOnly(let candidate), .conflict(let candidate, _),
             .corroborated(let candidate, _): candidate
        case .verificationOnly: nil
        }
    }

    private func exactAttribution(
        _ trace: ResolutionTrace,
        context: RelationQueryContext
    ) -> ExactAttribution? {
        switch trace {
        case .verificationOnly(let observation),
             .corroborated(_, let observation): return observation.attribution
        case .candidateOnly, .conflict:
            if case .completed(.completed(let attribution, _, _)) =
                context.exactQuery
            {
                return attribution
            }
            return nil
        }
    }

    private func analysisEnvironment(
        for explanation: RelationRowExplanation?,
        context: RelationQueryContext
    ) -> ExactAnalysisEnvironment? {
        explanation.flatMap {
            exactAttribution($0.primaryTrace, context: context)?.environment
        }
    }

    private func readinessText(
        _ readiness: ExactCoordinator.Readiness
    ) -> String {
        switch readiness {
        case .preparing: "Preparing exact provider…"
        case .ready: "Exact provider is ready."
        case .unavailable(let reason): "Exact provider unavailable: \(reason)"
        case .off(let reason): "Exact provider is off: \(reason)"
        }
    }

    private func environmentText(
        _ environment: ExactAnalysisEnvironment?
    ) -> String {
        guard let environment else { return "" }
        let limitations = environment.limitations
            .sorted { $0.rawValue < $1.rawValue }
            .map(\.displayName)
        return ([trustText(environment.trustMode)] + limitations)
            .joined(separator: " · ")
    }

    private func resolverText(
        candidate: CandidateObservation?,
        attribution: ExactAttribution?
    ) -> String {
        switch (candidate, attribution) {
        case (_?, _?): "Source resolver + rust-analyzer"
        case (_?, nil): "Source resolver"
        case (nil, _?): "rust-analyzer"
        case (nil, nil): "—"
        }
    }

    private func certaintyText(
        _ certainty: Certainty?,
        verified: Bool
    ) -> String {
        if verified { return "Exact" }
        guard let certainty else { return "—" }
        return switch certainty {
        case .unresolved: "Unresolved"
        case .possible: "Possible"
        case .probable: "Probable"
        case .strong: "Strong"
        case .exact: "Exact"
        }
    }

    private func dispatchText(_ dispatch: DispatchKind?) -> String {
        guard let dispatch else { return "—" }
        return switch dispatch {
        case .direct: "Direct"
        case .virtualDispatch: "Virtual"
        case .traitDispatch: "Trait"
        case .interfaceDispatch: "Interface"
        case .callback: "Callback"
        case .dynamicDispatch: "Dynamic"
        case .macroGenerated: "Macro generated"
        }
    }

    private func evidenceText(_ evidence: [ResolutionEvidence]) -> String {
        evidence.map {
            switch $0 {
            case .lexicalBinding: "lexicalBinding"
            case .uniqueImport: "uniqueImport"
            case .sameFile: "sameFile"
            case .nameOnly: "nameOnly"
            case .methodNameOnly: "methodNameOnly"
            case .receiverType: "receiverType"
            }
        }.joined(separator: ", ")
    }

    private func completenessText(_ completeness: Completeness) -> String {
        switch completeness {
        case .complete: "complete"
        case .partial: "partial"
        case .truncated: "truncated"
        case .unknown: "unknown"
        }
    }

    private func exhaustivenessText(
        _ exhaustiveness: QueryExhaustiveness
    ) -> String {
        switch exhaustiveness {
        case .guaranteed: "guaranteed"
        case .bestEffort: "best-effort"
        case .unknown: "unknown"
        }
    }

    private func originText(_ origin: ExactOrigin) -> String {
        switch origin {
        case .worktree: "worktree"
        case .materialized(let commitOID): "materialized \(commitOID)"
        }
    }

    private func candidateSnapshot(
        _ candidate: CandidateObservation?
    ) -> UUID? {
        guard let candidate else { return nil }
        if case .occurrence(let occurrence) = candidate.target {
            return occurrence.snapshotID.rawValue
        }
        return nil
    }

    private func trustText(_ trustMode: TrustMode) -> String {
        switch trustMode {
        case .safe: "Safe"
        case .trusted: "Trusted"
        }
    }
}

@MainActor
private final class RelationCellView: NSTableCellView {
    var onInspect: (() -> Void)?
    private let titleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let countPill = NSStackView()
    private let locationLabel = NSTextField(labelWithString: "")
    private let dispatchLabel = NSTextField(labelWithString: "")
    private let dispatchChip = NSStackView()
    private let scopeChip = RelationChipView()
    private let caveatChip = RelationChipView()
    private let correctedChip = RelationChipView()
    private let modifiersLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private let badgePill = InspectableBadgeView()
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
        badgePill.onClick = { [weak self] in self?.onInspect?() }
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
        let detail = NSStackView(views: [
            locationLabel,
            dispatchChip,
            scopeChip,
            caveatChip,
            correctedChip,
            modifiersLabel,
        ])
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
        scopeChip.isHidden = true
        caveatChip.isHidden = true
        correctedChip.isHidden = true
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
            if node.title.hasPrefix("Show corrected candidates") {
                titleLabel.stringValue = "Show corrected candidates"
                titleLabel.font = .systemFont(ofSize: 11.5, weight: .semibold)
                titleLabel.textColor = theme.warningColor
                countLabel.stringValue = "\(node.children?.count ?? 0)"
                countLabel.font = .systemFont(ofSize: 10, weight: .semibold)
                countPill.isHidden = false
            } else if node.title.hasPrefix("Show ") {
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
            let scope = node.modifiers.first { $0 == "dependency" }
            let caveat = node.modifiers.first { $0 == "name match only" }
            let corrected = node.modifiers.first {
                $0 == "Conflict/Corrected" || $0.hasPrefix("corrected ")
            }
            scopeChip.display(
                scope,
                foreground: theme.chromeSecondaryColor,
                background: .clear,
                border: theme.unresolvedBorderColor,
                dashed: true
            )
            caveatChip.display(
                caveat,
                foreground: theme.warningColor,
                background: theme.warningBackgroundColor,
                border: theme.warningBorderColor
            )
            correctedChip.display(
                corrected,
                foreground: theme.warningColor,
                background: theme.warningBackgroundColor,
                border: theme.warningBorderColor
            )
            modifiersLabel.stringValue = node.modifiers.filter {
                $0 != scope && $0 != caveat && $0 != corrected
            }.joined(separator: " · ")
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
    func selfTestInspect() { onInspect?() }
    var selfTestTitleAndCount: [String] {
        [titleLabel.stringValue, countLabel.stringValue]
    }

    private func location(of node: RelationTreeModel.Node) -> String? {
        guard let target = node.target else { return nil }
        return node.line.map { "\(target.path):\($0)" } ?? target.path
    }

}
