import AppKit
import CodeInsightAppModel
import CodeInsightCore
import CodeInsightExact
import CodeInsightReaderCore
import Observation

@MainActor
final class RelationWindowController: NSViewController,
    NSOutlineViewDataSource, NSOutlineViewDelegate, NSSplitViewDelegate
{
    private enum InspectorMode {
        case live(RelationTreeModel.Node)
        case frozen(
            ReadingSetExcerpt.FrozenInspectorDisplay,
            onOpenFormerCandidate: (() -> Void)?
        )
    }
    var onOpen: ((RelationTreeModel.Node) -> Void)?
    var onTreeChange: (() -> Void)?
    var onOpenReadingSet: ((String, [ReadingSetExcerpt], [String]) -> Void)?

    private let model: RelationTreeModel
    private let directionControl = NSSegmentedControl(
        labels: [localized("relation.callers"), localized("relation.calls"), localized("relation.implements"), localized("relation.references")],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let outlineView = RelationOutlineView()
    private let scrollView = NSScrollView()
    private let container = NSView()
    private let headerSurface = NSView()
    private let contentSplit = NSSplitView()
    private let listPane = NSView()
    private let inspectorView = ResolutionInspectorView()
    private let inspectButton = NSButton()
    private let readingSetButton = NSButton()
    private let placeholderLabel = NSTextField(
        labelWithString:
            localized("relation.hint")
    )
    private var currentTarget: ReferenceTarget?
    private var currentDocument: ReaderDocument?
    private var layoutPassCount = 0
    private var selfTestOpenSelectionCount = 0
    private var wholeTreeReloadCount = 0
    private var nodeReloadCount = 0
    private var theme = ReaderTheme(settings: ReaderSettings())
    private var inspectorMode: InspectorMode?
    private var frozenInspectorGeneration: UInt64?
    private var inspectorSplitFraction: CGFloat = 0.5
    private var adjustingInspectorSplit = false
    private let verificationReadiness: () -> ExactCoordinator.Readiness
    private let capturedSource: (
        String
    ) -> (
        contentID: ContentID,
        bytes: [UInt8],
        sourceKind: ReadingSetExcerpt.SourceKind,
        revision: String?
    )?
    private let languageMode: (String) -> LanguageMode?

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
    var selfTestReadingSetButtonState: (String, Bool, String) {
        loadViewIfNeeded()
        return (
            readingSetButton.title,
            readingSetButton.isEnabled,
            readingSetButton.accessibilityLabel() ?? ""
        )
    }
    func selfTestOpenAsReadingSet() { openAsReadingSet(nil) }
    var selfTestInspectorIsFrozen: Bool {
        if case .frozen = inspectorMode { return true }
        return false
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
        if let row = selfTestGroupRow(titlePrefix: localized("relation.references")),
           let node = outlineView.item(atRow: row) as? RelationTreeModel.Node
        {
            return node.title
        }
        return selfTestPossibleDisclosureItem?.title
    }

    var selfTestReferenceGroupFrame: NSRect {
        let group = selfTestGroupFrame(titlePrefix: localized("relation.references"))
        if group != .zero { return group }
        let disclosure = selfTestPossibleDisclosureFrame
        if disclosure != .zero { return disclosure }
        return selfTestVisibleEdgeFrames(inGroup: localized("relation.references")).first ?? .zero
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
            && directionControl.label(forSegment: 3) == localized("relation.references")
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
            $0.certainty == .unresolved
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
                && $0.candidateGroup == .corrected
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

    var selfTestListPaneHidden: Bool { listPane.isHidden }
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
                && $0.candidateGroup == .corrected
        }) else { return false }
        outlineView.expandItem(group)
        return outlineView.isItemExpanded(group)
    }

    func selfTestSelectCorrectedCandidate(titled title: String) -> Bool {
        guard let group = model.root?.children?.first(where: {
            $0.kind == .group
                && $0.candidateGroup == .corrected
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
                && $0.candidateGroup == .possible
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
            case "Exact": node.certainty == .exact ? node : nil
            case "Strong":
                node.certainty != .exact && node.certainty != .unresolved
                    && directRows.contains(ObjectIdentifier(node)) ? node : nil
            case "References", localized("relation.references"):
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
        },
        capturedSource: @escaping (
            String
        ) -> (
            contentID: ContentID,
            bytes: [UInt8],
            sourceKind: ReadingSetExcerpt.SourceKind,
            revision: String?
        )? = { _ in nil },
        languageMode: @escaping (String) -> LanguageMode?
    ) {
        self.model = model
        self.verificationReadiness = verificationReadiness
        self.capturedSource = capturedSource
        self.languageMode = languageMode
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
        directionControl.font = .systemFont(ofSize: 12)
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
        outlineView.style = .plain
        outlineView.intercellSpacing = .zero
        outlineView.indentationPerLevel = 12
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

        placeholderLabel.font = .systemFont(ofSize: 12)
        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.alignment = .center
        placeholderLabel.lineBreakMode = .byWordWrapping
        placeholderLabel.maximumNumberOfLines = 0
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false

        inspectButton.image = NSImage(
            systemSymbolName: "info.circle",
            accessibilityDescription: localized("relation.inspector.show")
        )
        inspectButton.title = localized("relation.inspector")
        inspectButton.imagePosition = .imageLeading
        inspectButton.font = .systemFont(ofSize: 12, weight: .semibold)
        inspectButton.bezelStyle = .accessoryBarAction
        inspectButton.isBordered = true
        inspectButton.toolTip = localized("relation.inspector.shortcut")
        inspectButton.setAccessibilityLabel(localized("relation.inspector.show"))
        inspectButton.target = self
        inspectButton.action = #selector(inspectSelection(_:))
        inspectButton.isEnabled = false
        inspectButton.translatesAutoresizingMaskIntoConstraints = false

        readingSetButton.title = localized("relation.freeze")
        readingSetButton.image = NSImage(
            systemSymbolName: "text.badge.plus",
            accessibilityDescription: localized("relation.freeze.title")
        )
        readingSetButton.imagePosition = .imageLeading
        readingSetButton.font = .systemFont(ofSize: 12, weight: .semibold)
        readingSetButton.bezelStyle = .accessoryBarAction
        readingSetButton.toolTip =
            localized("relation.freeze.hint")
        readingSetButton.setAccessibilityLabel(localized("relation.freeze.title"))
        readingSetButton.toolTip =
            localized("relation.freeze.help")
        readingSetButton.target = self
        readingSetButton.action = #selector(openAsReadingSet(_:))
        readingSetButton.isEnabled = false
        readingSetButton.translatesAutoresizingMaskIntoConstraints = false

        contentSplit.isVertical = true
        contentSplit.dividerStyle = .thin
        contentSplit.delegate = self
        contentSplit.arrangesAllSubviews = false
        contentSplit.setAccessibilityLabel(localized("relation.split"))
        contentSplit.toolTip = localized("relation.split.hint")
        contentSplit.wantsLayer = true
        contentSplit.layer?.backgroundColor = theme.chromeDividerColor.cgColor
        contentSplit.translatesAutoresizingMaskIntoConstraints = false
        contentSplit.addArrangedSubview(listPane)
        contentSplit.addSubview(inspectorView)
        inspectorView.isHidden = true
        listPane.wantsLayer = true
        listPane.layer?.backgroundColor = theme.chromeColor.cgColor
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
        headerSurface.addSubview(readingSetButton)
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
                equalTo: headerSurface.trailingAnchor,
                constant: -8
            ),
            readingSetButton.trailingAnchor.constraint(
                equalTo: inspectButton.leadingAnchor,
                constant: -6
            ),
            readingSetButton.topAnchor.constraint(
                equalTo: directionControl.bottomAnchor, constant: 6
            ),
            readingSetButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 104),
            readingSetButton.heightAnchor.constraint(equalToConstant: 22),
            inspectButton.trailingAnchor.constraint(
                equalTo: headerSurface.trailingAnchor,
                constant: -8
            ),
            inspectButton.topAnchor.constraint(
                equalTo: directionControl.bottomAnchor, constant: 6
            ),
            inspectButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 82),
            inspectButton.heightAnchor.constraint(equalToConstant: 22),
            headerSurface.bottomAnchor.constraint(equalTo: inspectButton.bottomAnchor, constant: 8),
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
        updateInspectorLayoutMode()
    }

    @ObservationIgnored private var inspectorReplacesList = false

    /// §3.1: the list and the inspector sit side by side only when the
    /// right area fits list ≥280pt, inspector ≥300pt, and the divider;
    /// otherwise the inspector replaces the list and Close brings the list
    /// back with its selection and scroll position. Hysteresis keeps width
    /// crossings from oscillating.
    private func updateInspectorLayoutMode() {
        if inspectorView.isHidden {
            inspectorReplacesList = false
        } else {
            let minimum: CGFloat = inspectorReplacesList ? 628 : 604
            inspectorReplacesList = contentSplit.bounds.width < minimum
        }
        listPane.isHidden = inspectorReplacesList
        let visiblePanes: [NSView] = [listPane, inspectorView].filter { !$0.isHidden }
        guard contentSplit.arrangedSubviews != visiblePanes else { return }
        adjustingInspectorSplit = true
        for pane in contentSplit.arrangedSubviews {
            contentSplit.removeArrangedSubview(pane)
        }
        visiblePanes.forEach(contentSplit.addArrangedSubview)
        layoutInspectorPanes()
        adjustingInspectorSplit = false
    }

    private func layoutInspectorPanes() {
        let wasAdjusting = adjustingInspectorSplit
        adjustingInspectorSplit = true
        contentSplit.adjustSubviews()
        if contentSplit.arrangedSubviews.count == 2 {
            let available = contentSplit.bounds.width - contentSplit.dividerThickness
            contentSplit.setPosition(
                min(max(available * inspectorSplitFraction, 280), available - 300),
                ofDividerAt: 0
            )
        }
        adjustingInspectorSplit = wasAdjusting
        fitOutlineWidthToVisibleRect()
    }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        guard !adjustingInspectorSplit else { return }
        updateInspectorLayoutMode()
        layoutInspectorPanes()
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        fitOutlineWidthToVisibleRect()
    }

    func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        let available = splitView.bounds.width - splitView.dividerThickness
        let position = min(max(proposedPosition, 280), available - 300)
        if !adjustingInspectorSplit, available > 0 {
            inspectorSplitFraction = position / available
        }
        return position
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimum: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimum, 280)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximum: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximum, splitView.bounds.width - splitView.dividerThickness - 300)
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
        guard let node = item as? RelationTreeModel.Node else { return 22 }
        return switch node.kind {
        case .edge, .root: 44
        case .group, .truncated, .loading, .error, .evidenceLine: 22
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
        if node.isCorrectedCandidate { return }
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
              node.candidateGroup != nil
        else { return }
        validateVisiblePossibleRows()
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"]
                as? RelationTreeModel.Node,
              node.kind == .group,
              node.candidateGroup != nil
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
        if node.isCorrectedCandidate {
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
              let context = model.relationQueryContexts[explanation.contextID],
              let source = node.target.flatMap({ capturedSource($0.path) }),
              let display = makeInspectorDisplay(
                  node: node,
                  context: context,
                  correctedTitles: correctedTitles(for: node),
                  readiness: verificationReadiness(),
                  sourceKind: source.sourceKind,
                  revision: source.revision,
                  contentID: source.contentID,
                  capturedAt: Date(),
                  atCapture: false
              )
        else { return }
        inspectorMode = .live(node)
        inspectorView.isHidden = false
        view.layoutSubtreeIfNeeded()
        updateInspectorLayoutMode()
        inspectorView.displayLive(display, theme: theme)
        updateInspectorLayoutMode()
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
        switch inspectorMode {
        case .live(let node): showInspector(for: node)
        case .frozen(let display, let action):
            inspectorView.displayFrozen(
                display,
                canOpenFormerCandidate: action != nil,
                theme: theme
            )
        case nil: break
        }
    }

    func showFrozenInspector(
        _ display: ReadingSetExcerpt.FrozenInspectorDisplay,
        onOpenFormerCandidate: (() -> Void)? = nil
    ) {
        loadViewIfNeeded()
        frozenInspectorGeneration = model.generation
        inspectorMode = .frozen(
            display,
            onOpenFormerCandidate: onOpenFormerCandidate
        )
        inspectorView.isHidden = false
        view.layoutSubtreeIfNeeded()
        updateInspectorLayoutMode()
        inspectorView.displayFrozen(
            display,
            canOpenFormerCandidate: onOpenFormerCandidate != nil,
            theme: theme
        )
    }

    func frozenInspectorDisplay(
        for node: RelationTreeModel.Node
    ) -> ReadingSetExcerpt.FrozenInspectorDisplay? {
        guard let explanation = node.explanation,
              let context = model.relationQueryContexts[explanation.contextID],
              let source = node.target.flatMap({ capturedSource($0.path) })
        else { return nil }
        return makeInspectorDisplay(
            node: node,
            context: context,
            correctedTitles: correctedTitles(for: node),
            readiness: verificationReadiness(),
            sourceKind: source.sourceKind,
            revision: source.revision,
            contentID: source.contentID,
            capturedAt: Date()
        )
    }

    private func hideInspector() {
        frozenInspectorGeneration = nil
        inspectorMode = nil
        guard !inspectorView.isHidden else { return }
        inspectorView.isHidden = true
        updateInspectorLayoutMode()
        view.layoutSubtreeIfNeeded()
    }

    private func openInspectedFormerCandidate() {
        switch inspectorMode {
        case .live(let node) where node.isCorrectedCandidate:
            onOpen?(node)
        case .frozen(_, let action): action?()
        default: break
        }
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
                && $0.candidateGroup == .corrected
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
                self.render()
                self.observe()
            }
        }
    }

    private func render() {
        if case .frozen = inspectorMode, frozenInspectorGeneration != model.generation {
            hideInspector()
        }
        directionControl.selectedSegment = segment(for: model.direction)
        readingSetButton.isEnabled = !readingSetNodes().isEmpty
        if model.root == nil {
            currentTarget = nil
            currentDocument = nil
            if case .live = inspectorMode { hideInspector() }
        }
        reloadWholeTree()
    }

    @objc private func openAsReadingSet(_ sender: Any?) {
        let nodes = readingSetNodes()
        guard !nodes.isEmpty else { return }
        var excerpts: [ReadingSetExcerpt] = []
        var skippedReasons: [String] = []
        for (index, node) in nodes.enumerated() {
            guard index < 50 else {
                skippedReasons.append("display cap (50 excerpts)")
                continue
            }
            guard let explanation = node.explanation,
                  let context = model.relationQueryContexts[explanation.contextID]
            else {
                skippedReasons.append("relation evidence is unavailable")
                continue
            }
            guard let source = node.target.flatMap({ capturedSource($0.path) })
            else {
                skippedReasons.append("recorded source is unreadable")
                continue
            }
            guard let target = node.target,
                  let languageMode = languageMode(target.path)
            else {
                skippedReasons.append("recorded source language is unsupported")
                continue
            }
            guard let excerpt = makeReadingSetExcerpt(
                role: readingSetRole(for: node),
                node: node,
                context: context,
                correctedTitles: correctedTitles(for: node),
                readiness: verificationReadiness(),
                languageMode: languageMode,
                bytes: source.bytes,
                contentID: source.contentID,
                revision: source.revision,
                sourceKind: source.sourceKind
            ) else {
                skippedReasons.append("recorded excerpt could not be frozen")
                continue
            }
            excerpts.append(excerpt)
        }
        onOpenReadingSet?(
            model.root?.title ?? localized("relation.title"),
            excerpts,
            skippedReasons
        )
    }

    private func readingSetNodes() -> [RelationTreeModel.Node] {
        guard let root = model.root else { return [] }
        var result: [RelationTreeModel.Node] = []
        func visit(_ node: RelationTreeModel.Node) {
            if (node.kind == .edge || node.kind == .root),
               node.target != nil,
               node.explanation != nil
            {
                result.append(node)
            }
            (node.children ?? []).forEach(visit)
        }
        visit(root)
        return result
    }

    func readingSetRole(for node: RelationTreeModel.Node) -> String {
        if node.kind == .root { return "DEFINITION" }
        return switch model.direction {
        case .callers:
            node.certainty == .exact ? "VERIFIED CALLER" : "INFERRED CALLER"
        case .calls: "CALL"
        case .implementations: "IMPLEMENTATION"
        case .references: "REFERENCE"
        }
    }

    private func reloadWholeTree() {
        guard isViewLoaded else { return }
        wholeTreeReloadCount += 1
        outlineView.reloadData()
        fitOutlineWidthToVisibleRect()
        if let root = model.root {
            outlineView.expandItem(root)
            placeholderLabel.stringValue = switch model.direction {
            case .callers: localized("relation.empty.callers")
            case .calls: localized("relation.empty.calls")
            case .implementations: localized("relation.empty.implementations")
            case .references: localized("relation.empty.references")
            }
            let showsPlaceholder = root.kind == .root
                && (root.children?.isEmpty == true
                    || (!root.isExpandable && root.children == nil))
            placeholderLabel.isHidden = !showsPlaceholder
            scrollView.isHidden = showsPlaceholder
        } else {
            placeholderLabel.stringValue = localized("relation.hint")
            placeholderLabel.isHidden = false
            scrollView.isHidden = true
        }
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
        readingSetButton.isEnabled = !readingSetNodes().isEmpty
        scrollView.contentView.scroll(to: visibleOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private var inspectedNode: RelationTreeModel.Node? {
        guard case .live(let node) = inspectorMode else { return nil }
        return node
    }

    private func expandLoadedGroups(under node: RelationTreeModel.Node) {
        outlineView.expandItem(node)
        for child in node.children ?? []
            where child.kind == .group && child.candidateGroup == nil
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
    private let headerTitle = NSTextField(labelWithString: localized("relation.inspector.title"))
    private let captureChip = RelationChipView()
    private let closeButton = NSButton()
    private let scrollView = NSScrollView()
    private let documentView = InspectorDocumentView()
    private let content = NSStackView()
    private let nodeTitle = NSTextField(labelWithString: "")
    private let badge = RelationChipView()
    private let why = NSTextField(wrappingLabelWithString: "")
    private let sourceTitle = NSTextField(labelWithString: localized("relation.inspector.source"))
    private let sourceBody = NSTextField(wrappingLabelWithString: "")
    private let sourceSection = NSStackView()
    private let verificationTitle = NSTextField(labelWithString: localized("relation.inspector.verification"))
    private let verificationBody = NSTextField(wrappingLabelWithString: "")
    private let verificationSection = NSStackView()
    private let correctionTitle = NSTextField(labelWithString: localized("relation.inspector.corrected"))
    private let correctionBody = NSTextField(wrappingLabelWithString: "")
    private let correctionSection = NSStackView()
    private let availabilityTitle = NSTextField(
        labelWithString: localized("relation.inspector.availability")
    )
    private let availabilityBody = NSTextField(wrappingLabelWithString: "")
    private let availabilitySection = NSStackView()
    private let environmentTitle = NSTextField(
        labelWithString: localized("relation.inspector.environment")
    )
    private let environmentBody = NSTextField(wrappingLabelWithString: "")
    private let environmentSection = NSStackView()
    private let auditButton = NSButton(title: localized("relation.audit.show"), target: nil, action: nil)
    private let auditStack = NSStackView()
    private let formerCandidateButton = NSButton(
        title: localized("relation.former.open"),
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
            accessibilityDescription: localized("relation.inspector.close")
        )
        closeButton.isBordered = false
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.toolTip = localized("relation.inspector.close")
        closeButton.setAccessibilityLabel(localized("relation.inspector.close"))
        closeButton.target = self
        closeButton.action = #selector(closeInspector(_:))
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerTitle)
        header.addSubview(captureChip)
        header.addSubview(closeButton)

        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
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
        nodeTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
        auditButton.font = .systemFont(ofSize: 12, weight: .medium)
        auditButton.target = self
        auditButton.action = #selector(toggleAudit(_:))
        auditButton.setAccessibilityLabel(localized("relation.audit.accessibility"))
        formerCandidateButton.bezelStyle = .inline
        formerCandidateButton.font = .systemFont(ofSize: 12, weight: .medium)
        formerCandidateButton.target = self
        formerCandidateButton.action = #selector(openFormerCandidate(_:))
        formerCandidateButton.setAccessibilityLabel(localized("relation.former.open"))
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
            captureChip.leadingAnchor.constraint(equalTo: headerTitle.trailingAnchor, constant: 8),
            captureChip.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            captureChip.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -8),
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
        setAccessibilityLabel(localized("relation.inspector.title"))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var selfTestVisibleText: [String] {
        var values: [String] = [
            captureChip.isHidden ? nil : captureChip.text,
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
        if !auditStack.isHidden {
            values.append(contentsOf: auditStack.arrangedSubviews.flatMap { row in
                (row as? NSStackView)?.arrangedSubviews.compactMap {
                    ($0 as? NSTextField)?.stringValue
                } ?? []
            })
        }
        return values
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

    func displayLive(
        _ display: ReadingSetExcerpt.FrozenInspectorDisplay,
        theme: ReaderTheme
    ) {
        displayNormalized(
            display,
            atCapture: false,
            canOpenFormerCandidate: display.formerCandidateAvailable,
            theme: theme
        )
    }

    func displayFrozen(
        _ display: ReadingSetExcerpt.FrozenInspectorDisplay,
        canOpenFormerCandidate: Bool,
        theme: ReaderTheme
    ) {
        displayNormalized(
            display,
            atCapture: true,
            canOpenFormerCandidate: canOpenFormerCandidate,
            theme: theme
        )
    }

    private func displayNormalized(
        _ display: ReadingSetExcerpt.FrozenInspectorDisplay,
        atCapture: Bool,
        canOpenFormerCandidate: Bool,
        theme: ReaderTheme
    ) {
        if atCapture {
            captureChip.display(
                localized("relation.capture"),
                foreground: theme.chromeSecondaryColor,
                background: .clear,
                border: theme.chromeTertiaryColor,
                dashed: true
            )
        } else {
            captureChip.isHidden = true
        }
        nodeTitle.stringValue = display.nodeTitle
        nodeTitle.toolTip = display.nodeTitle
        switch display.badge {
        case .verified:
            badge.display(
                display.badge.displayText,
                foreground: theme.verifiedColor,
                background: theme.verifiedBackgroundColor,
                border: theme.verifiedBackgroundColor
            )
        case .inferred:
            badge.display(
                display.badge.displayText,
                foreground: theme.inferredColor,
                background: theme.inferredBackgroundColor,
                border: theme.inferredBackgroundColor
            )
        case .unresolved:
            badge.display(
                display.badge.displayText,
                foreground: theme.unresolvedColor,
                background: .clear,
                border: theme.unresolvedBorderColor
            )
        }
        why.stringValue = display.why
        sourceBody.stringValue = display.sourceBody
        sourceSection.isHidden = display.sourceBody.isEmpty
        verificationTitle.stringValue = display.verificationTitle
        verificationBody.stringValue = display.verificationBody
        verificationSection.isHidden = display.verificationBody.isEmpty
        correctionBody.stringValue = display.correctionBody
        correctionSection.isHidden = display.correctionBody.isEmpty
        availabilityBody.stringValue = display.availabilityBody
        environmentBody.stringValue = display.environmentBody
        environmentSection.isHidden = display.environmentBody.isEmpty
        formerCandidateButton.isHidden = !display.formerCandidateAvailable
        formerCandidateButton.isEnabled = display.formerCandidateAvailable
            && canOpenFormerCandidate
        auditStack.isHidden = true
        auditButton.title = localized("relation.audit.show")
        rebuildAudit(
            display.auditRows.map { ($0.label, $0.value) },
            theme: theme
        )
        setAccessibilityLabel(
            atCapture
                ? localizedFormat("relation.inspector.node.capture", display.nodeTitle)
                : localizedFormat("relation.inspector.node", display.nodeTitle)
        )
        setAccessibilityValue(display.accessibilityValue)
        apply(theme: theme)
    }

    @objc private func closeInspector(_ sender: Any?) { onClose?() }

    @objc private func openFormerCandidate(_ sender: Any?) {
        onOpenFormerCandidate?()
    }

    @objc private func toggleAudit(_ sender: Any?) {
        auditStack.isHidden.toggle()
        auditButton.title = auditStack.isHidden
            ? localized("relation.audit.show") : localized("relation.audit.hide")
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
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        body.font = .systemFont(ofSize: 12)
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
            keyLabel.font = .systemFont(ofSize: 11)
            keyLabel.textColor = theme.chromeTertiaryColor
            keyLabel.setContentHuggingPriority(.required, for: .horizontal)
            let valueLabel = NSTextField(wrappingLabelWithString: value)
            valueLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            valueLabel.textColor = theme.chromeSecondaryColor
            valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let row = NSStackView(views: [keyLabel, valueLabel])
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 8
            auditStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: auditStack.widthAnchor).isActive = true
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
        titleLabel.toolTip = node.title
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
        badgeLabel.toolTip = switch node.certainty {
        case .exact: localized("relation.badge.verified.hint")
        case .strong, .probable, .possible: localized("relation.badge.inferred.hint")
        case .unresolved: localized("relation.badge.unresolved.hint")
        default: nil
        }
        switch node.certainty {
        case .exact:
            badgeLabel.textColor = theme.verifiedColor
            badgePill.layer?.backgroundColor = theme.verifiedBackgroundColor.cgColor
            badgePill.layer?.borderWidth = 0
        case .unresolved:
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
            if node.candidateGroup == .corrected {
                titleLabel.stringValue = localized("relation.corrected.show")
                titleLabel.font = .systemFont(ofSize: 11.5, weight: .semibold)
                titleLabel.textColor = theme.warningColor
                countLabel.stringValue = "\(node.children?.count ?? 0)"
                countLabel.font = .systemFont(ofSize: 10, weight: .semibold)
                countPill.isHidden = false
            } else if node.candidateGroup != nil {
                titleLabel.stringValue = localized("relation.possible.show")
                titleLabel.font = .systemFont(ofSize: 11.5, weight: .semibold)
                titleLabel.textColor = theme.accentColor
                countLabel.stringValue = (node.children?.count ?? 0).formatted()
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
            let scope = node.dependencyModifier
            let caveat = node.nameOnlyModifier
            let corrected = node.correctedModifier
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
            modifiersLabel.font = .systemFont(ofSize: 11)
            modifiersLabel.isHidden = modifiersLabel.stringValue.isEmpty
        case .evidenceLine:
            titleLabel.stringValue = "  \(node.title)"
            titleLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
            titleLabel.textColor = theme.chromeTertiaryColor
        case .loading:
            titleLabel.stringValue = node.title
            titleLabel.font = .systemFont(ofSize: 12)
            titleLabel.textColor = theme.chromeSecondaryColor
            spinner.isHidden = false
            spinner.startAnimation(nil)
        case .truncated:
            titleLabel.stringValue = node.title
            titleLabel.font = .systemFont(ofSize: 12)
            titleLabel.textColor = .systemOrange
        case .error:
            titleLabel.stringValue = node.title
            titleLabel.font = .systemFont(ofSize: 12)
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
