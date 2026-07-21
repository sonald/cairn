import AppKit
import CodeInsightAppModel
import CodeInsightCore
import CodeInsightReaderCore
import CodeInsightReaderUI
import Observation

@MainActor
final class MainWindowController: NSWindowController, NSToolbarDelegate,
    NSToolbarItemValidation
{
    private static let backItemIdentifier = NSToolbarItem.Identifier("Back")
    private static let forwardItemIdentifier = NSToolbarItem.Identifier("Forward")
    private static let projectItemIdentifier = NSToolbarItem.Identifier("Project")
    private static let commitItemIdentifier = NSToolbarItem.Identifier("Commit")
    private static let indexItemIdentifier = NSToolbarItem.Identifier("IndexStatus")

    let model: AppModel
    private let sidebarController = SidebarViewController()
    private let readerController = ReaderViewController()
    private let contextController: ContextWindowViewController
    private let relationController: RelationWindowController
    private let relationItem: NSSplitViewItem
    private let projectLabel = NSTextField(labelWithString: "CodeInsight")
    private let commitButton = NSButton()
    private let indexLabel = NSTextField(labelWithString: "")
    private var displayedGeneration: UInt64?
    private var displayedSnapshotID: SnapshotID?
    private var displayedNavigationGeneration: UInt64?
    private var symbolSearchPanel: SymbolSearchPanel?
    private var searchPanel: SearchPanel?
    private var commitPickerPopover: CommitPickerPopover?

    init(model: AppModel, offscreen: Bool) {
        self.model = model
        contextController = ContextWindowViewController(model: model.contextWindow)
        relationController = RelationWindowController(model: model.relationTree)
        relationController.view.frame.size.width = 300
        relationItem = NSSplitViewItem(viewController: relationController)
        let content = NSSplitViewController()
        content.splitView.isVertical = false

        let readerSplit = NSSplitViewController()
        readerSplit.splitView.isVertical = true
        let sidebarItem = NSSplitViewItem(
            sidebarWithViewController: sidebarController
        )
        sidebarItem.minimumThickness = 180
        readerSplit.addSplitViewItem(sidebarItem)
        readerSplit.addSplitViewItem(
            NSSplitViewItem(viewController: readerController)
        )
        relationItem.minimumThickness = 220
        relationItem.maximumThickness = 500
        relationItem.canCollapse = true
        readerSplit.addSplitViewItem(relationItem)
        relationItem.isCollapsed = true

        content.addSplitViewItem(NSSplitViewItem(viewController: readerSplit))
        let contextItem = NSSplitViewItem(
            viewController: contextController
        )
        contextItem.minimumThickness = 120
        contextItem.maximumThickness = 280
        content.addSplitViewItem(contextItem)

        let frame = NSRect(x: offscreen ? -10_000 : 0, y: 0, width: 1280, height: 820)
        let window = NSWindow(
            contentRect: frame,
            styleMask: offscreen
                ? [.borderless]
                : [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "CodeInsight"
        window.minSize = NSSize(width: 900, height: 600)
        window.contentViewController = content
        let toolbar = NSToolbar(identifier: "MainToolbar")
        super.init(window: window)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        window.toolbar = toolbar
        if !offscreen {
            window.center()
            window.setFrameAutosaveName("CodeInsightMainWindow")
        }
        sidebarController.onOpenFile = { [weak self] url in
            self?.navigate(to: url)
        }
        sidebarController.onOpenOutline = { [weak self] offset in
            guard let self, let file = model.selectedFile else { return }
            navigate(to: file, byteOffset: offset)
        }
        readerController.onTokenClick = { [weak self] offset, commandClick in
            self?.handleReaderClick(offset: offset, commandClick: commandClick)
        }
        readerController.onOutlineChange = { [weak self] facets in
            guard let self else { return }
            sidebarController.setOutline(facets)
            if let offset = readerController.currentReadingPosition()?.byteOffset {
                sidebarController.highlightOutline(at: offset)
            }
        }
        readerController.onReadingPositionChange = { [weak self] offset in
            self?.sidebarController.highlightOutline(at: offset)
        }
        readerController.onShowRelation = { [weak self] offset, direction in
            self?.handleReaderRelation(offset: offset, direction: direction)
        }
        contextController.onOpen = { [weak self] candidate in
            self?.open(candidate)
        }
        relationController.onOpen = { [weak self] path, offset in
            self?.open(path: path, byteOffset: offset)
        }
        render()
        observe()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func openProject(root: URL) {
        model.openProject(root: root)
        render()
    }

    func showSymbolSearch() {
        if symbolSearchPanel == nil {
            symbolSearchPanel = SymbolSearchPanel(appModel: model) { [weak self] file, offset in
                self?.navigate(to: file, byteOffset: offset)
            }
        }
        symbolSearchPanel?.show(relativeTo: window)
    }

    func showProjectSearch() {
        if searchPanel == nil {
            searchPanel = SearchPanel(appModel: model) { [weak self] file, offset in
                self?.navigate(to: file, byteOffset: offset)
            }
        }
        searchPanel?.show(relativeTo: window)
    }

    func toggleRelations() {
        relationItem.isCollapsed.toggle()
    }

    func showRelations(direction: RelationTreeModel.Direction) {
        guard let symbol = model.contextWindow.selectedCandidate?.symbol else { return }
        showRelations(symbol: symbol, direction: direction)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            Self.backItemIdentifier,
            Self.forwardItemIdentifier,
            Self.projectItemIdentifier,
            Self.commitItemIdentifier,
            .flexibleSpace,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            Self.backItemIdentifier,
            Self.forwardItemIdentifier,
            Self.projectItemIdentifier,
            Self.commitItemIdentifier,
            Self.indexItemIdentifier,
            .flexibleSpace,
        ]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        switch itemIdentifier {
        case Self.backItemIdentifier:
            item.label = "Back"
            item.image = NSImage(
                systemSymbolName: "chevron.backward",
                accessibilityDescription: "Back"
            )
            item.target = self
            item.action = #selector(goBack(_:))
        case Self.forwardItemIdentifier:
            item.label = "Forward"
            item.image = NSImage(
                systemSymbolName: "chevron.forward",
                accessibilityDescription: "Forward"
            )
            item.target = self
            item.action = #selector(goForward(_:))
        case Self.projectItemIdentifier:
            item.label = "Project"
            item.view = projectLabel
        case Self.commitItemIdentifier:
            item.label = "Version"
            item.view = commitButton
            item.visibilityPriority = .high
            commitButton.target = self
            commitButton.action = #selector(showCommitPicker(_:))
            commitButton.bezelStyle = .rounded
            commitButton.font = .systemFont(ofSize: 12, weight: .semibold)
            commitButton.cell?.lineBreakMode = .byTruncatingTail
            commitButton.frame.size = NSSize(width: 260, height: 28)
            commitButton.setAccessibilityLabel("Current version")
        case Self.indexItemIdentifier:
            item.label = "Index Status"
            item.view = indexLabel
        default:
            return nil
        }
        return item
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.action {
        case #selector(goBack(_:)):
            model.navigationHistory.canGoBack
        case #selector(goForward(_:)):
            model.navigationHistory.canGoForward
        default:
            true
        }
    }

    private func observe() {
        withObservationTracking {
            _ = model.projectState
            _ = model.generation
            _ = model.snapshotPhase
            _ = model.coverage
            _ = model.currentRevision
            _ = model.currentSnapshotID
            _ = model.fileTree
            _ = model.selectedFile
            _ = model.navigationGeneration
            _ = model.commitPicker.currentCommit
            _ = model.commitPicker.isLoading
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.render()
                self?.observe()
            }
        }
    }

    private func render() {
        if displayedGeneration != model.generation
            || displayedSnapshotID != model.currentSnapshotID
        {
            sidebarController.display(model.fileTree)
            displayedGeneration = model.generation
            displayedSnapshotID = model.currentSnapshotID
        }
        readerController.display(
            model.selectedFile,
            snapshotID: model.currentSnapshotID,
            source: model.documentSource
        )
        if displayedNavigationGeneration != model.navigationGeneration {
            if let file = model.selectedFile, let offset = model.selectedByteOffset {
                readerController.navigate(
                    to: file,
                    byteOffset: offset,
                    snapshotID: model.currentSnapshotID,
                    source: model.documentSource
                )
            }
            displayedNavigationGeneration = model.navigationGeneration
        }
        projectLabel.stringValue = model.fileTree?.root.lastPathComponent ?? "CodeInsight"
        renderCommitButton()

        guard let toolbar = window?.toolbar else { return }
        let statusText = model.coverage.statusText(for: model.snapshotPhase)
            ?? initialIndexStatus
        if let statusText {
            indexLabel.stringValue = statusText
            if toolbar.items.allSatisfy({ $0.itemIdentifier != Self.indexItemIdentifier }) {
                toolbar.insertItem(
                    withItemIdentifier: Self.indexItemIdentifier,
                    at: toolbar.items.count
                )
            }
        } else {
            if let index = toolbar.items.firstIndex(where: {
                $0.itemIdentifier == Self.indexItemIdentifier
            }) {
                toolbar.removeItem(at: index)
            }
        }
        toolbar.validateVisibleItems()
        symbolSearchPanel?.refreshProjectState()
        searchPanel?.refreshProjectState()
    }

    private var initialIndexStatus: String? {
        guard model.snapshotPhase == nil,
              case .indexing = model.projectState
        else { return nil }
        return "Indexing \(model.fileTree?.fileCount ?? 0) files…"
    }

    private func renderCommitButton() {
        guard let revision = model.currentRevision else {
            commitButton.title = "Working Tree"
            commitButton.bezelColor = nil
            commitButton.contentTintColor = .controlTextColor
            commitButton.toolTip = "Working Tree"
            commitButton.isEnabled = model.fileTree != nil
            return
        }

        let commit = model.commitPicker.currentCommit
        let sha = commit?.shortSHA ?? String(revision.prefix(7))
        let summary = commit.map { Self.truncated($0.summary, limit: 34) } ?? ""
        commitButton.title = summary.isEmpty
            ? "⎇ \(sha)"
            : "⎇ \(sha) \(summary)"
        commitButton.bezelColor = .controlAccentColor
        commitButton.contentTintColor = .white
        commitButton.toolTip = commit.map { "\($0.fullSHA) — \($0.summary)" }
            ?? revision
        commitButton.isEnabled = model.fileTree != nil
    }

    private static func truncated(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit - 1)) + "…"
    }

    @objc private func showCommitPicker(_ sender: NSButton) {
        if commitPickerPopover == nil {
            commitPickerPopover = CommitPickerPopover(appModel: model)
        }
        commitPickerPopover?.show(relativeTo: sender)
    }

    @objc func selectPreviousContextCandidate(_ sender: Any?) {
        model.contextWindow.selectPrevious()
    }

    @objc func selectNextContextCandidate(_ sender: Any?) {
        model.contextWindow.selectNext()
    }

    @objc func goBack(_ sender: Any?) {
        guard let current = currentJumpRecord() else { return }
        model.goBack(from: current)
    }

    @objc func goForward(_ sender: Any?) {
        model.goForward()
    }

    private func handleReaderClick(offset: UInt32, commandClick: Bool) {
        guard let file = model.selectedFile,
              let path = projectPath(for: file)
        else { return }
        if commandClick {
            Task { [weak self] in
                guard let self,
                      let candidate = await self.model.contextWindow.explicitJump(
                        file: path,
                        offset: offset
                      )
                else { return }
                self.open(candidate)
            }
        } else {
            model.contextWindow.tokenClicked(file: path, offset: offset)
        }
    }

    private func handleReaderRelation(
        offset: UInt32,
        direction: RelationTreeModel.Direction
    ) {
        guard let file = model.selectedFile,
              let path = projectPath(for: file)
        else { return }
        relationItem.isCollapsed = false
        Task { [weak self] in
            guard let self,
                  let candidate = await model.contextWindow.explicitJump(
                    file: path,
                    offset: offset
                  )
            else { return }
            showRelations(symbol: candidate.symbol, direction: direction)
        }
    }

    private func open(_ candidate: ContextWindowModel.Candidate) {
        open(path: candidate.path, byteOffset: candidate.targetByteOffset)
    }

    private func open(path: String, byteOffset: UInt32) {
        guard let root = model.fileTree?.root else { return }
        navigate(
            to: root.appendingPathComponent(path),
            byteOffset: byteOffset
        )
    }

    private func showRelations(
        symbol: SymbolOccurrenceID,
        direction: RelationTreeModel.Direction
    ) {
        relationItem.isCollapsed = false
        relationController.setRoot(symbol: symbol, direction: direction)
    }

    private func navigate(to file: URL, byteOffset: UInt32? = nil) {
        model.navigate(
            to: file,
            byteOffset: byteOffset,
            leaving: currentJumpRecord()
        )
    }

    private func currentJumpRecord() -> JumpRecord? {
        let snapshotID: SnapshotID?
        switch model.projectState {
        case let .ready(session, _):
            snapshotID = session.snapshotID
        case .indexing:
            snapshotID = nil
        case .empty, .failed:
            return nil
        }
        guard let position = readerController.currentReadingPosition(),
              let path = projectPath(for: position.file)
        else { return nil }
        return JumpRecord(
            path: path,
            contentID: position.contentID,
            byteOffset: position.byteOffset,
            line: position.line,
            column: position.column,
            symbolAnchor: position.symbolAnchor,
            snapshotID: snapshotID
        )
    }

    private func projectPath(for file: URL) -> String? {
        guard let root = model.fileTree?.root,
              file.pathComponents.starts(with: root.pathComponents)
        else { return nil }
        return file.pathComponents.dropFirst(root.pathComponents.count)
            .joined(separator: "/")
    }
}

@MainActor
final class SidebarViewController: NSViewController,
    NSOutlineViewDataSource, NSOutlineViewDelegate, NSSplitViewDelegate
{
    var onOpenFile: ((URL) -> Void)?
    var onOpenOutline: ((UInt32) -> Void)?
    private let fileOutlineView = NSOutlineView()
    private let symbolOutlineView = NSOutlineView()
    private let splitView = NSSplitView()
    private let outlineModel = OutlinePanelModel()
    private var tree: FileTreeModel?
    private var facetRows: [NSNumber] = []
    private var setInitialDivider = false

    override func loadView() {
        configure(fileOutlineView, column: "File")
        configure(symbolOutlineView, column: "Symbol")
        symbolOutlineView.indentationPerLevel = 0
        symbolOutlineView.target = self
        symbolOutlineView.action = #selector(openOutlineRow(_:))

        splitView.isVertical = false
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.addArrangedSubview(pane(title: "Files", outlineView: fileOutlineView))
        splitView.addArrangedSubview(pane(title: "Outline", outlineView: symbolOutlineView))
        view = splitView
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !setInitialDivider, splitView.bounds.height > 0 else { return }
        splitView.setPosition(splitView.bounds.height * 0.65, ofDividerAt: 0)
        setInitialDivider = true
    }

    func display(_ tree: FileTreeModel?) {
        self.tree = tree
        loadViewIfNeeded()
        fileOutlineView.reloadData()
    }

    func setOutline(_ facets: [OutlineFacet]) {
        loadViewIfNeeded()
        outlineModel.setDocument(facets)
        facetRows = outlineModel.facets.indices.map { NSNumber(value: $0) }
        symbolOutlineView.reloadData()
        symbolOutlineView.deselectAll(nil)
    }

    func highlightOutline(at byteOffset: UInt32) {
        let index = outlineModel.highlight(at: byteOffset)
        guard let index else {
            symbolOutlineView.deselectAll(nil)
            return
        }
        let row = symbolOutlineView.row(forItem: facetRows[index])
        guard row >= 0, symbolOutlineView.selectedRow != row else { return }
        symbolOutlineView.selectRowIndexes([row], byExtendingSelection: false)
        symbolOutlineView.scrollRowToVisible(row)
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        numberOfChildrenOfItem item: Any?
    ) -> Int {
        if outlineView === symbolOutlineView {
            return item == nil ? facetRows.count : 0
        }
        return (item as? FileTreeNode)?.children.count ?? tree?.children.count ?? 0
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        child index: Int,
        ofItem item: Any?
    ) -> Any {
        if outlineView === symbolOutlineView { return facetRows[index] }
        return (item as? FileTreeNode)?.children[index] ?? tree!.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if outlineView === symbolOutlineView { return false }
        return (item as? FileTreeNode)?.isDirectory == true
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        if outlineView === symbolOutlineView {
            guard let number = item as? NSNumber,
                  outlineModel.facets.indices.contains(number.intValue)
            else { return nil }
            return outlineCell(for: outlineModel.facets[number.intValue])
        }
        guard let node = item as? FileTreeNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("FileTreeCell")
        if let cell = outlineView.makeView(withIdentifier: identifier, owner: self)
            as? NSTableCellView
        {
            cell.textField?.stringValue = node.name
            return cell
        }
        let cell = NSTableCellView()
        cell.identifier = identifier
        let label = NSTextField(labelWithString: node.name)
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.textField = label
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let outlineView = notification.object as? NSOutlineView else { return }
        if outlineView === symbolOutlineView {
            return
        } else {
            guard outlineView.selectedRow >= 0,
                  let node = outlineView.item(atRow: outlineView.selectedRow)
                    as? FileTreeNode,
                  !node.isDirectory
            else { return }
            onOpenFile?(node.url)
        }
    }

    @objc private func openOutlineRow(_ sender: NSOutlineView) {
        guard sender.clickedRow >= 0,
              let row = sender.item(atRow: sender.clickedRow) as? NSNumber,
              let offset = outlineModel.open(row.intValue)
        else { return }
        onOpenOutline?(offset)
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        false
    }

    private func configure(_ outlineView: NSOutlineView, column title: String) {
        let column = NSTableColumn(identifier: .init(title))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.dataSource = self
        outlineView.delegate = self
    }

    private func pane(title: String, outlineView: NSOutlineView) -> NSView {
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let pane = NSView()
        pane.addSubview(label)
        pane.addSubview(scrollView)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: pane.topAnchor, constant: 6),
            label.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -8),
            scrollView.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
        ])
        return pane
    }

    private func outlineCell(for facet: OutlineFacet) -> NSView {
        let identifier = NSUserInterfaceItemIdentifier("OutlineFacetCell")
        let cell: NSStackView
        if let reused = symbolOutlineView.makeView(withIdentifier: identifier, owner: self)
            as? NSStackView
        {
            cell = reused
        } else {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                image.widthAnchor.constraint(equalToConstant: 14),
                image.heightAnchor.constraint(equalToConstant: 14),
            ])
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingTail
            cell = NSStackView(views: [image, label])
            cell.identifier = identifier
            cell.orientation = .horizontal
            cell.alignment = .centerY
            cell.spacing = 4
        }
        let image = cell.arrangedSubviews[0] as! NSImageView
        let label = cell.arrangedSubviews[1] as! NSTextField
        image.image = NSImage(
            systemSymbolName: symbolName(for: facet.kind),
            accessibilityDescription: facet.kind.rawValue
        )
        label.stringValue = facet.name
        cell.edgeInsets = NSEdgeInsets(
            top: 0,
            left: 4 + CGFloat(facet.depth) * 12,
            bottom: 0,
            right: 4
        )
        return cell
    }

    private func symbolName(for kind: OutlineKind) -> String {
        switch kind {
        case .fn: "function"
        case .method: "m.square"
        case .struct: "shippingbox"
        case .enum: "list.bullet"
        case .trait: "point.3.connected.trianglepath.dotted"
        case .impl: "hammer"
        case .mod: "folder"
        case .const: "c.square"
        case .static: "s.square"
        case .typeAlias: "t.square"
        }
    }
}

@MainActor
final class ReaderViewController: NSViewController, NSMenuDelegate {
    var onTokenClick: ((UInt32, Bool) -> Void)?
    var onShowRelation: ((UInt32, RelationTreeModel.Direction) -> Void)?
    var onOutlineChange: (([OutlineFacet]) -> Void)?
    var onReadingPositionChange: ((UInt32) -> Void)?
    private let label = NSTextField(labelWithString: "Open a project to begin")
    private let textView = ReaderTextView()
    private let loader = DocumentLoader()
    private var displayedFile: URL?
    private var displayedSnapshotID: SnapshotID?
    private var displayedDocument: ReaderDocument?
    private var loadGeneration: UInt64 = 0
    private var contextMenuOffset: UInt32?
    private var readingPositionTask: Task<Void, Never>?

    override func loadView() {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.documentView = textView.view
        textView.view.frame = scrollView.contentView.bounds

        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])
        view = scrollView
        textView.onClick = { [weak self] characterIndex, modifiers in
            guard let self,
                  let offset = self.textView.byteOffset(
                    forCharacterIndex: characterIndex
                  )
            else { return }
            self.onReadingPositionChange?(offset)
            let meaningful = modifiers.intersection([.command, .option, .control, .shift])
            if meaningful.isEmpty {
                self.onTokenClick?(offset, false)
            } else if meaningful == .command {
                self.onTokenClick?(offset, true)
            }
        }
        textView.onViewportChange = { [weak self] in
            self?.scheduleReadingPositionChange()
        }

        let relationMenu = NSMenu(title: "Relations")
        relationMenu.autoenablesItems = false
        relationMenu.delegate = self
        relationMenu.addItem(NSMenuItem(
            title: "Show Callers",
            action: #selector(showCallers(_:)),
            keyEquivalent: ""
        ))
        relationMenu.addItem(NSMenuItem(
            title: "Show Calls",
            action: #selector(showCalls(_:)),
            keyEquivalent: ""
        ))
        relationMenu.addItem(NSMenuItem(
            title: "Show Implementations",
            action: #selector(showImplementations(_:)),
            keyEquivalent: ""
        ))
        for item in relationMenu.items { item.target = self }
        textView.view.menu = relationMenu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        contextMenuOffset = contextMenuByteOffset()
        for item in menu.items { item.isEnabled = contextMenuOffset != nil }
    }

    func display(
        _ file: URL?,
        snapshotID: SnapshotID? = nil,
        source: DocumentLoader.ContentSource? = nil
    ) {
        loadViewIfNeeded()
        guard file != displayedFile || snapshotID != displayedSnapshotID else { return }
        displayedFile = file
        displayedSnapshotID = snapshotID
        contextMenuOffset = nil
        readingPositionTask?.cancel()
        readingPositionTask = nil
        loadGeneration &+= 1
        let generation = loadGeneration
        onOutlineChange?([])

        guard let file else {
            displayedDocument = nil
            label.stringValue = "Open a project to begin"
            label.isHidden = false
            textView.view.string = ""
            return
        }

        do {
            let activeLoader = source.map { DocumentLoader(source: $0) } ?? loader
            let loaded = try activeLoader.load(file: file)
            displayedDocument = loaded.document
            label.isHidden = true
            layoutTextViewFrame()
            textView.display(document: loaded.document)
            onOutlineChange?(loaded.document.outlineFacets)
            textView.view.textLayoutManager?
                .textViewportLayoutController.layoutViewport()
            if loaded.tier != .regular {
                activeLoader.loadSyntax(for: loaded.document) { [weak self] result in
                    Task { @MainActor [weak self] in
                        guard let self, self.loadGeneration == generation else { return }
                        switch result {
                        case let .success(document):
                            self.displayedDocument = document
                            self.textView.updateSyntax(document: document)
                            self.onOutlineChange?(document.outlineFacets)
                        case .failure:
                            self.label.stringValue = "Syntax highlighting failed"
                            self.label.isHidden = false
                        }
                    }
                }
            }
        } catch {
            displayedDocument = nil
            label.stringValue = "Could not open \(file.lastPathComponent)"
            label.isHidden = false
        }
    }

    func navigate(
        to file: URL,
        byteOffset: UInt32,
        snapshotID: SnapshotID? = nil,
        source: DocumentLoader.ContentSource? = nil
    ) {
        display(file, snapshotID: snapshotID, source: source)
        textView.reveal(byteOffset: byteOffset)
        onReadingPositionChange?(byteOffset)
    }

    func currentReadingPosition() -> (
        file: URL,
        contentID: ContentID,
        byteOffset: UInt32,
        line: UInt32,
        column: UInt32,
        symbolAnchor: String?
    )? {
        guard let file = displayedFile,
              let document = displayedDocument,
              let byteOffset = textView.firstVisibleByteOffset(),
              let coordinate = document.lineTable.lineColumn(at: byteOffset)
        else { return nil }
        return (
            file: file,
            contentID: document.contentID,
            byteOffset: byteOffset,
            line: coordinate.line,
            column: coordinate.column,
            symbolAnchor: document.symbolAnchor(at: byteOffset)
        )
    }

    private func layoutTextViewFrame() {
        view.layoutSubtreeIfNeeded()
        if let scrollView = view as? NSScrollView {
            textView.view.frame = scrollView.contentView.bounds
        }
    }

    private func scheduleReadingPositionChange() {
        guard readingPositionTask == nil else { return }
        readingPositionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, let self else { return }
            readingPositionTask = nil
            guard let offset = currentReadingPosition()?.byteOffset else { return }
            onReadingPositionChange?(offset)
        }
    }

    @objc private func showCallers(_ sender: Any?) {
        showRelation(.callers)
    }

    @objc private func showCalls(_ sender: Any?) {
        showRelation(.calls)
    }

    @objc private func showImplementations(_ sender: Any?) {
        showRelation(.implementations)
    }

    private func showRelation(_ direction: RelationTreeModel.Direction) {
        guard let contextMenuOffset else { return }
        onShowRelation?(contextMenuOffset, direction)
    }

    private func contextMenuByteOffset() -> UInt32? {
        guard displayedDocument != nil else { return nil }
        let characterIndex: Int
        if let event = NSApplication.shared.currentEvent,
           event.window === textView.view.window
        {
            characterIndex = textView.view.characterIndexForInsertion(
                at: textView.view.convert(event.locationInWindow, from: nil)
            )
        } else {
            characterIndex = textView.view.selectedRange().location
        }
        return textView.byteOffset(forCharacterIndex: characterIndex)
    }

}

@MainActor
final class ContextWindowViewController: NSViewController {
    var onOpen: ((ContextWindowModel.Candidate) -> Void)?

    private let model: ContextWindowModel
    private let modeControl = NSSegmentedControl(
        labels: ["Follow", "Pin"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let previousButton = NSButton(title: "‹", target: nil, action: nil)
    private let countLabel = NSTextField(labelWithString: "")
    private let nextButton = NSButton(title: "›", target: nil, action: nil)
    private let pathLabel = NSTextField(labelWithString: "")
    private let candidateLabel = NSTextField(labelWithString: "")
    private let miniReader = ReaderTextView()

    init(model: ContextWindowModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        modeControl.selectedSegment = 0
        modeControl.target = self
        modeControl.action = #selector(modeChanged(_:))
        previousButton.target = self
        previousButton.action = #selector(selectPrevious(_:))
        nextButton.target = self
        nextButton.action = #selector(selectNext(_:))
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        candidateLabel.textColor = .secondaryLabelColor
        candidateLabel.font = .systemFont(ofSize: 11)

        let header = NSStackView(views: [
            modeControl,
            previousButton,
            countLabel,
            nextButton,
            pathLabel,
            candidateLabel,
        ])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.documentView = miniReader.view
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(header)
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
        miniReader.onClick = { [weak self] _, modifiers in
            guard modifiers.intersection([.command, .option, .control, .shift]) == .command,
                  let self,
                  let candidate = self.model.selectedCandidate
            else { return }
            self.onOpen?(candidate)
        }
        render()
        observe()
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        model.setMode(sender.selectedSegment == 1 ? .pinned : .follow)
    }

    @objc private func selectPrevious(_ sender: Any?) {
        model.selectPrevious()
    }

    @objc private func selectNext(_ sender: Any?) {
        model.selectNext()
    }

    private func observe() {
        withObservationTracking {
            _ = model.mode
            _ = model.stage
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.render()
                self?.observe()
            }
        }
    }

    private func render() {
        modeControl.selectedSegment = model.mode == .pinned ? 1 : 0
        let text: String
        let highlightsSyntax: Bool
        if let candidate = model.selectedCandidate {
            pathLabel.stringValue = "\(candidate.path):\(candidate.line):\(candidate.column)"
            candidateLabel.stringValue = [candidate.label, candidate.bindingKind]
                .compactMap { $0 }
                .joined(separator: " · ")
            countLabel.stringValue = "\((model.selectedIndex ?? 0) + 1)/\(model.candidateCount)"
            text = candidate.excerpt
            highlightsSyntax = true
        } else {
            pathLabel.stringValue = ""
            candidateLabel.stringValue = ""
            countLabel.stringValue = ""
            text = model.isIndexBuilding
                ? "Indexing…"
                : "Select a symbol to see context"
            highlightsSyntax = false
        }
        previousButton.isEnabled = model.candidateCount > 1
        nextButton.isEnabled = model.candidateCount > 1
        miniReader.display(document: readerDocument(text, highlightsSyntax: highlightsSyntax))
    }

    private func readerDocument(
        _ source: String,
        highlightsSyntax: Bool
    ) -> ReaderDocument {
        let bytes = Array(source.utf8)
        let highlighted = highlightsSyntax
            ? try? RustHighlighter().highlight(bytes: bytes)
            : nil
        return ReaderDocument(
            bytes: bytes,
            highlightSpans: highlighted?.spans ?? [],
            outlineFacets: highlighted?.outlineFacets ?? []
        )
    }
}
