import AppKit
import CodeInsightAppModel
import CodeInsightCore
import CodeInsightReaderCore
import CodeInsightReaderUI

@MainActor
final class SidebarViewController: NSViewController,
    NSOutlineViewDataSource, NSOutlineViewDelegate, NSSplitViewDelegate
{
    var onOpenFile: ((URL) -> Void)?
    var onOpenFileInSecondary: ((URL) -> Void)?
    var onOpenFileInNewTab: ((URL) -> Void)?
    var onOpenOutline: ((UInt32) -> Void)?
    var onChooseProject: (() -> Void)?
    private let fileOutlineView = NSOutlineView()
    private let symbolOutlineView = NSOutlineView()
    private let splitView = NSSplitView()
    private let backgroundView = NSView()
    private let fileScrollView = NSScrollView()
    private let symbolScrollView = NSScrollView()
    private let filePlaceholder = NSStackView()
    private let filePlaceholderLabel = NSTextField(labelWithString: localized("main.no.project.open"))
    private let filePlaceholderButton = NSButton()
    private let fileLoadingIndicator = NSProgressIndicator()
    private let outlinePlaceholder = NSTextField(labelWithString: localized("main.no.file.open"))
    private let outlineModel = OutlinePanelModel()
    private var tree: FileTreeModel?
    private var facetRows: [NSNumber] = []
    private var outlineFile: URL?
    private var collapsedOutlineOffsets: [URL: Set<UInt32>] = [:]
    private var isSynchronizingOutlineSelection = false
    private var setInitialDivider = false
    private var isSynchronizingFileSelection = false
    private var synchronizedFile: URL?
    private var hasSelectedFile = false
    private var outlineSurfaceHidden = false
    private var filesCollapsed = false
    private var outlineCollapsed = false
    private var isAdjustingSections = false
    private var expandedDividerFraction: CGFloat = 0.55
    private var compactSplitHeight: NSLayoutConstraint?
    private var splitBottomConstraint: NSLayoutConstraint?
    private var splitAutosaveName = "CodeInsightSidebarSplit"
    private var theme = ReaderTheme(settings: ReaderSettings())
    private var paneSurfaces: [(pane: NSView, header: NSView, label: NSTextField, divider: NSView, body: NSView, toggle: NSButton)] = []

    func setSplitAutosaveName(_ name: String) {
        splitAutosaveName = name
        filesCollapsed = UserDefaults.standard.bool(forKey: "\(name).filesCollapsed")
        outlineCollapsed = UserDefaults.standard.bool(forKey: "\(name).outlineCollapsed")
        expandedDividerFraction = 0.55
        setInitialDivider = false
    }

    /// Hides the symbol outline half of the sidebar for non-source
    /// surfaces; the file tree stays (§3.1).
    func setOutlineHidden(_ hidden: Bool) {
        loadViewIfNeeded()
        guard outlineSurfaceHidden != hidden else { return }
        outlineSurfaceHidden = hidden
        splitView.arrangedSubviews.last?.isHidden = hidden
        isAdjustingSections = true
        splitView.adjustSubviews()
        isAdjustingSections = false
        restoreSidebarDividerIfNeeded()
    }

    func apply(settings: ReaderSettings) {
        theme = ReaderTheme(settings: settings)
        guard isViewLoaded else { return }
        isSynchronizingFileSelection = true
        isSynchronizingOutlineSelection = true
        defer {
            isSynchronizingFileSelection = false
            isSynchronizingOutlineSelection = false
        }
        backgroundView.layer?.backgroundColor = theme.chromeColor.cgColor
        fileOutlineView.backgroundColor = theme.chromeColor
        symbolOutlineView.backgroundColor = theme.chromeColor
        for surface in paneSurfaces {
            surface.pane.layer?.backgroundColor = theme.chromeColor.cgColor
            surface.header.layer?.backgroundColor = theme.chromeColor.cgColor
            surface.label.textColor = theme.chromeSecondaryColor
            surface.divider.layer?.backgroundColor = theme.chromeDividerColor.cgColor
            surface.toggle.contentTintColor = theme.chromeSecondaryColor
        }
        fileOutlineView.reloadData()
        symbolOutlineView.reloadData()
        view.needsDisplay = true
    }

    var selfTestOutlineHidden: Bool {
        loadViewIfNeeded()
        return outlineSurfaceHidden
    }
    var selfTestFilesPlaceholderText: String? {
        loadViewIfNeeded()
        return filePlaceholderLabel.stringValue
    }
    var selfTestFilesPlaceholderVisible: Bool {
        loadViewIfNeeded()
        return filePlaceholder.selfTestIsVisibleInWindow
    }
    var selfTestFilesLoadingIndicatorVisible: Bool {
        loadViewIfNeeded()
        return fileLoadingIndicator.selfTestIsVisibleInWindow
    }
    var selfTestFilesOpenProjectButtonTitle: String {
        loadViewIfNeeded()
        return filePlaceholderButton.title
    }
    var selfTestFilesOpenProjectButtonVisible: Bool {
        loadViewIfNeeded()
        return filePlaceholderButton.selfTestIsVisibleInWindow
    }
    var selfTestFilesContentVisible: Bool {
        loadViewIfNeeded()
        return fileScrollView.selfTestIsVisibleInWindow
    }
    var selfTestFileContextMenuHasOpenInNewTab: Bool {
        loadViewIfNeeded()
        return fileOutlineView.menu?.items.contains {
            $0.action == #selector(openFileInNewTab(_:))
        } == true
    }
    var selfTestOutlinePlaceholderText: String? {
        loadViewIfNeeded()
        return outlinePlaceholder.stringValue
    }
    var selfTestOutlinePlaceholderVisible: Bool {
        loadViewIfNeeded()
        return outlinePlaceholder.selfTestIsVisibleInWindow
    }
    var selfTestOutlineContentVisible: Bool {
        loadViewIfNeeded()
        return symbolScrollView.selfTestIsVisibleInWindow
    }
    var selfTestFilesCollapsed: Bool { filesCollapsed }
    var selfTestOutlineCollapsed: Bool { outlineCollapsed }
    var selfTestGeometry: (
        filesPaneHeight: CGFloat,
        outlinePaneHeight: CGFloat,
        filePlaceholderHeight: CGFloat,
        filePlaceholderCenterOffset: CGFloat,
        outlinePlaceholderCenterOffset: CGFloat
    ) {
        loadViewIfNeeded()
        view.layoutSubtreeIfNeeded()
        guard splitView.arrangedSubviews.count == 2 else {
            return (0, 0, 0, .infinity, .infinity)
        }
        return (
            splitView.arrangedSubviews[0].frame.height,
            splitView.arrangedSubviews[1].frame.height,
            filePlaceholder.frame.height,
            abs(filePlaceholder.frame.midY - fileScrollView.frame.midY),
            abs(outlinePlaceholder.frame.midY - symbolScrollView.frame.midY)
        )
    }

    var selfTestRowGeometry: (height: CGFloat, spacing: NSSize) {
        loadViewIfNeeded()
        return (
            outlineView(fileOutlineView, heightOfRowByItem: NSObject()),
            fileOutlineView.intercellSpacing
        )
    }

    func selfTestSetDefaultSidebarDivider() {
        loadViewIfNeeded()
        view.layoutSubtreeIfNeeded()
        guard splitView.arrangedSubviews.count == 2,
              splitView.bounds.height > 0
        else { return }
        splitView.setPosition(splitView.bounds.height * 0.65, ofDividerAt: 0)
        view.layoutSubtreeIfNeeded()
    }

    func selfTestDividerSurvivesPlaceholderRefresh() -> Bool {
        loadViewIfNeeded()
        guard splitView.arrangedSubviews.count == 2 else { return false }
        let originalPosition = splitView.arrangedSubviews[0].frame.height
        splitView.setPosition(splitView.bounds.height * 0.55, ofDividerAt: 0)
        updateFilePlaceholder(isIndexing: false)
        updateOutlinePlaceholder()
        splitView.layoutSubtreeIfNeeded()
        let panes = splitView.arrangedSubviews
        let availableHeight = panes[0].frame.height + panes[1].frame.height
        let survived = availableHeight > 0
            && abs(panes[0].frame.height / availableHeight - 0.55) <= 0.02
        splitView.setPosition(originalPosition, ofDividerAt: 0)
        return survived
    }

    func selfTestDividerPersistsAcrossRebuild() -> Bool {
        let name = "\(splitAutosaveName).Persistence.\(UUID().uuidString)"
        let defaults = UserDefaults.standard
        func removeProbeDefaults() {
            defaults.dictionaryRepresentation().keys
                .filter { $0.contains(name) }
                .forEach { defaults.removeObject(forKey: $0) }
        }
        removeProbeDefaults()
        defer { removeProbeDefaults() }

        func makeController() -> (SidebarViewController, NSWindow) {
            let controller = SidebarViewController()
            controller.setSplitAutosaveName(name)
            controller.loadViewIfNeeded()
            let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: 300, height: 500),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentViewController = controller
            window.setContentSize(NSSize(width: 300, height: 500))
            window.orderFront(nil)
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            return (controller, window)
        }
        let (writer, writerWindow) = makeController()
        writer.splitView.setPosition(310, ofDividerAt: 0)
        writerWindow.displayIfNeeded()
        let (reader, readerWindow) = makeController()
        defer { writerWindow.orderOut(nil); readerWindow.orderOut(nil) }

        let restored = reader.splitView.arrangedSubviews.first?.frame.height ?? 0
        let didStore = defaults.dictionaryRepresentation().keys.contains {
            $0.contains(name)
        }
        return didStore && abs(restored - 310) <= 1
    }

    override func loadView() {
        configure(fileOutlineView, column: "File")
        configure(symbolOutlineView, column: "Symbol")
        fileOutlineView.target = self
        fileOutlineView.doubleAction = #selector(openFileInNewTab(_:))
        filesCollapsed = UserDefaults.standard.bool(forKey: "\(splitAutosaveName).filesCollapsed")
        outlineCollapsed = UserDefaults.standard.bool(forKey: "\(splitAutosaveName).outlineCollapsed")
        symbolOutlineView.indentationPerLevel = 13
        symbolOutlineView.target = self
        symbolOutlineView.action = #selector(openOutlineRow(_:))

        let fileMenu = NSMenu(title: localized("main.open.file"))
        let openLeft = NSMenuItem(
            title: localized("main.open.in.left.reader"),
            action: #selector(openFileInLeftReader(_:)),
            keyEquivalent: ""
        )
        openLeft.target = self
        fileMenu.addItem(openLeft)
        let openInNewTab = NSMenuItem(
            title: localized("main.open.in.new.tab"),
            action: #selector(openFileInNewTab(_:)),
            keyEquivalent: ""
        )
        openInNewTab.target = self
        fileMenu.addItem(openInNewTab)
        let openRight = NSMenuItem(
            title: localized("main.open.in.right.reader.compare"),
            action: #selector(openFileInRightReader(_:)),
            keyEquivalent: ""
        )
        openRight.target = self
        fileMenu.addItem(openRight)
        fileOutlineView.menu = fileMenu

        configurePlaceholders()
        splitView.isVertical = false
        splitView.dividerStyle = .thin
        // Native autosave also records loading layouts; only persist the
        // explicit divider fraction and section buttons below.
        splitView.delegate = self
        splitView.addArrangedSubview(pane(
            title: localized("main.files"),
            outlineView: fileOutlineView,
            scrollView: fileScrollView,
            placeholder: filePlaceholder
        ))
        splitView.addArrangedSubview(pane(
            title: localized("main.outline"),
            outlineView: symbolOutlineView,
            scrollView: symbolScrollView,
            placeholder: outlinePlaceholder
        ))
        splitView.translatesAutoresizingMaskIntoConstraints = false

        backgroundView.wantsLayer = true
        backgroundView.layer?.backgroundColor = theme.chromeColor.cgColor
        backgroundView.addSubview(splitView)
        let bottom = splitView.bottomAnchor.constraint(equalTo: backgroundView.bottomAnchor)
        splitBottomConstraint = bottom
        compactSplitHeight = splitView.heightAnchor.constraint(equalToConstant: 51)
        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: backgroundView.topAnchor),
            bottom,
        ])
        view = backgroundView
        updateFilePlaceholder(isIndexing: false)
        updateOutlinePlaceholder()
        restoreSidebarDividerIfNeeded()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        restoreSidebarDividerIfNeeded()
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        restoreSidebarDividerIfNeeded()
    }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        let wasAdjusting = isAdjustingSections
        isAdjustingSections = true
        splitView.adjustSubviews()
        isAdjustingSections = wasAdjusting
        restoreSidebarDividerIfNeeded()
    }

    private func restoreSidebarDividerIfNeeded() {
        guard !isAdjustingSections, paneSurfaces.count == 2 else { return }
        isAdjustingSections = true
        defer { isAdjustingSections = false }
        if !setInitialDivider, !outlineSurfaceHidden,
           splitView.bounds.height >= 120,
           splitView.arrangedSubviews.allSatisfy({ $0.frame.height > 0 }) {
            setInitialDivider = true
            let defaults = UserDefaults.standard
            if let fraction = defaults.object(forKey: "\(splitAutosaveName).fraction") as? Double,
               fraction.isFinite, (0.05...0.95).contains(fraction) {
                expandedDividerFraction = fraction
            }
        }
        let compact = filesCollapsed && (outlineCollapsed || outlineSurfaceHidden)
        compactSplitHeight?.constant = outlineSurfaceHidden ? 25 : 50 + splitView.dividerThickness
        if compact {
            splitBottomConstraint?.isActive = false
            compactSplitHeight?.isActive = true
        } else {
            compactSplitHeight?.isActive = false
            splitBottomConstraint?.isActive = true
        }
        for (index, surface) in paneSurfaces.enumerated() {
            let collapsed = index == 0 ? filesCollapsed : outlineCollapsed
            surface.body.isHidden = collapsed
            surface.toggle.image = NSImage(systemSymbolName: collapsed ? "chevron.right" : "chevron.down",
                                           accessibilityDescription: nil)
            let action = localizedFormat(collapsed ? "main.expand.section" : "main.collapse.section", surface.label.stringValue)
            surface.toggle.toolTip = action
            surface.toggle.setAccessibilityLabel(action)
            surface.toggle.setAccessibilityValue(collapsed ? localized("main.collapsed") : localized("main.expanded"))
        }
        guard !outlineSurfaceHidden, setInitialDivider else { return }
        let available = splitView.bounds.height - splitView.dividerThickness
        let requestedPosition = filesCollapsed ? 25
            : outlineCollapsed ? available - 25
            : available * expandedDividerFraction
        let position = self.splitView(splitView, constrainSplitPosition: requestedPosition, ofSubviewAt: 0)
        if abs(paneSurfaces[0].pane.frame.height - position) > 0.5 {
            splitView.setPosition(position, ofDividerAt: 0)
        }
    }

    func display(_ tree: FileTreeModel?) {
        loadViewIfNeeded()
        var expanded: Set<URL> = []
        func remember(_ nodes: [FileTreeNode]) {
            for node in nodes where node.isDirectory {
                if fileOutlineView.isItemExpanded(node) { expanded.insert(node.url) }
                remember(node.children)
            }
        }
        remember(self.tree?.children ?? [])
        let selected = (fileOutlineView.item(atRow: fileOutlineView.selectedRow) as? FileTreeNode)?.url
        if self.tree?.root != tree?.root { synchronizedFile = nil }
        isSynchronizingFileSelection = true
        defer { isSynchronizingFileSelection = false }
        self.tree = tree
        fileOutlineView.reloadData()
        func restore(_ nodes: [FileTreeNode]) {
            for node in nodes where node.isDirectory {
                if expanded.contains(node.url) { fileOutlineView.expandItem(node) }
                restore(node.children)
            }
        }
        restore(tree?.children ?? [])
        if let selected, let node = tree?.selectionPath(for: selected)?.last {
            let row = fileOutlineView.row(forItem: node)
            if row >= 0 { fileOutlineView.selectRowIndexes([row], byExtendingSelection: false) }
        }
    }

    func setProjectState(_ state: ProjectState) {
        loadViewIfNeeded()
        if case .indexing = state {
            updateFilePlaceholder(isIndexing: true)
        } else {
            updateFilePlaceholder(isIndexing: false)
        }
    }

    func setSelectedFile(_ file: URL?) {
        loadViewIfNeeded()
        hasSelectedFile = file != nil
        if file == nil, !facetRows.isEmpty {
            outlineModel.setDocument([])
            facetRows = []
            symbolOutlineView.reloadData()
        }
        updateOutlinePlaceholder()
    }

    @discardableResult
    func synchronizeFileSelection(to file: URL?, reveal: Bool = false) -> Bool {
        loadViewIfNeeded()
        let file = file?.standardizedFileURL
        guard reveal || file != synchronizedFile else { return true }
        isSynchronizingFileSelection = true
        defer { isSynchronizingFileSelection = false }
        guard let path = tree?.selectionPath(for: file), let node = path.last else {
            fileOutlineView.deselectAll(nil)
            if !reveal { synchronizedFile = file }
            return true
        }
        for parent in path.dropLast() {
            fileOutlineView.expandItem(parent)
        }
        let row = fileOutlineView.row(forItem: node)
        guard row >= 0 else {
            fileOutlineView.deselectAll(nil)
            return false
        }
        if fileOutlineView.selectedRow != row {
            fileOutlineView.selectRowIndexes([row], byExtendingSelection: false)
        }
        fileOutlineView.scrollRowToVisible(row)
        if !reveal { synchronizedFile = file }
        return true
    }

    func selectFile(_ file: URL) -> Bool {
        loadViewIfNeeded()
        guard let path = tree?.selectionPath(for: file), let node = path.last else {
            return false
        }
        for parent in path.dropLast() {
            fileOutlineView.expandItem(parent)
        }
        let row = fileOutlineView.row(forItem: node)
        guard row >= 0 else { return false }
        fileOutlineView.selectRowIndexes([row], byExtendingSelection: false)
        return true
    }

    func revealPath(_ url: URL) {
        loadViewIfNeeded()
        if filesCollapsed { toggleSidebarSection(paneSurfaces[0].toggle) }
        if url.standardizedFileURL == tree?.root.standardizedFileURL {
            fileOutlineView.deselectAll(nil)
            fileOutlineView.scroll(.zero)
        } else {
            _ = synchronizeFileSelection(to: url, reveal: true)
            if let node = tree?.selectionPath(for: url)?.last, node.isDirectory {
                fileOutlineView.expandItem(node)
            }
        }
        view.window?.makeFirstResponder(fileOutlineView)
    }

    var selectedFile: URL? {
        loadViewIfNeeded()
        guard fileOutlineView.selectedRow >= 0,
              let node = fileOutlineView.item(atRow: fileOutlineView.selectedRow)
                as? FileTreeNode,
              !node.isDirectory
        else { return nil }
        return node.url
    }

    func setOutline(_ facets: [OutlineFacet], file: URL? = nil) {
        loadViewIfNeeded()
        if let previous = outlineFile, !outlineModel.facets.isEmpty {
            collapsedOutlineOffsets[previous] = Set(outlineModel.facets.indices.compactMap { index in
                !outlineModel.childIndices[index].isEmpty
                    && !symbolOutlineView.isItemExpanded(facetRows[index])
                    ? outlineModel.facets[index].range.lowerBound : nil
            })
        }
        outlineFile = file
        outlineModel.setDocument(facets)
        facetRows = outlineModel.facets.indices.map { NSNumber(value: $0) }
        isSynchronizingOutlineSelection = true
        symbolOutlineView.reloadData()
        symbolOutlineView.expandItem(nil, expandChildren: true)
        if let file, let collapsed = collapsedOutlineOffsets[file] {
            for index in outlineModel.facets.indices
            where collapsed.contains(outlineModel.facets[index].range.lowerBound) {
                symbolOutlineView.collapseItem(facetRows[index])
            }
        }
        symbolOutlineView.deselectAll(nil)
        isSynchronizingOutlineSelection = false
        updateOutlinePlaceholder()
    }

    func highlightOutline(at byteOffset: UInt32) {
        isSynchronizingOutlineSelection = true
        defer { isSynchronizingOutlineSelection = false }
        let index = outlineModel.highlight(at: byteOffset)
        guard let index else {
            symbolOutlineView.deselectAll(nil)
            return
        }
        var visibleIndex = index
        while symbolOutlineView.row(forItem: facetRows[visibleIndex]) < 0,
              let parent = outlineModel.parentIndices[visibleIndex] {
            visibleIndex = parent
        }
        let row = symbolOutlineView.row(forItem: facetRows[visibleIndex])
        guard row >= 0, symbolOutlineView.selectedRow != row else { return }
        symbolOutlineView.selectRowIndexes([row], byExtendingSelection: false)
        let rowRect = symbolOutlineView.rect(ofRow: row)
        if !symbolScrollView.contentView.documentVisibleRect.contains(rowRect) {
            symbolOutlineView.scrollRowToVisible(row)
        }
    }

    var selfTestSelectedOutlineRow: Int {
        loadViewIfNeeded()
        return symbolOutlineView.selectedRow
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        numberOfChildrenOfItem item: Any?
    ) -> Int {
        if outlineView === symbolOutlineView {
            return (item as? NSNumber).map { outlineModel.childIndices[$0.intValue].count }
                ?? outlineModel.rootIndices.count
        }
        return (item as? FileTreeNode)?.children.count ?? tree?.children.count ?? 0
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        child index: Int,
        ofItem item: Any?
    ) -> Any {
        if outlineView === symbolOutlineView {
            let indices = (item as? NSNumber).map { outlineModel.childIndices[$0.intValue] }
                ?? outlineModel.rootIndices
            return facetRows[indices[index]]
        }
        return (item as? FileTreeNode)?.children[index] ?? tree!.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if outlineView === symbolOutlineView {
            return (item as? NSNumber).map { !outlineModel.childIndices[$0.intValue].isEmpty } ?? false
        }
        return (item as? FileTreeNode)?.isDirectory == true
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        heightOfRowByItem item: Any
    ) -> CGFloat {
        22
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
            cell.textField?.textColor = theme.foregroundColor
            cell.imageView?.image = fileIcon(for: node)
            cell.imageView?.contentTintColor = fileIconColor(for: node)
            cell.toolTip = node.url.path
            return cell
        }
        let cell = NSTableCellView()
        cell.identifier = identifier
        let image = NSImageView()
        image.image = fileIcon(for: node)
        image.contentTintColor = fileIconColor(for: node)
        image.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: node.name)
        label.font = .systemFont(ofSize: 12)
        label.textColor = theme.foregroundColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.imageView = image
        cell.textField = label
        cell.toolTip = node.url.path
        cell.addSubview(image)
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            image.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
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

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let outlineView = notification.object as? NSOutlineView else { return }
        if outlineView === symbolOutlineView {
            if let event = NSApp.currentEvent,
               event.type == .leftMouseDown || event.type == .leftMouseUp { return }
            guard !isSynchronizingOutlineSelection,
                  outlineView.selectedRow >= 0,
                  let row = outlineView.item(atRow: outlineView.selectedRow) as? NSNumber,
                  let offset = outlineModel.open(row.intValue)
            else { return }
            onOpenOutline?(offset)
        } else {
            guard !isSynchronizingFileSelection else { return }
            guard outlineView.selectedRow >= 0,
                  let node = outlineView.item(atRow: outlineView.selectedRow)
                    as? FileTreeNode,
                  !node.isDirectory
            else { return }
            onOpenFile?(node.url)
        }
    }

    @objc private func openOutlineRow(_ sender: NSOutlineView) {
        let index = sender.clickedRow >= 0 ? sender.clickedRow : sender.selectedRow
        guard index >= 0,
              let row = sender.item(atRow: index) as? NSNumber,
              let offset = outlineModel.open(row.intValue)
        else { return }
        onOpenOutline?(offset)
    }

    @objc private func openFileInLeftReader(_ sender: Any?) {
        guard let file = contextMenuFile() else { return }
        onOpenFile?(file)
    }

    @objc private func openFileInRightReader(_ sender: Any?) {
        guard let file = contextMenuFile() else { return }
        onOpenFileInSecondary?(file)
    }

    @objc private func openFileInNewTab(_ sender: Any?) {
        guard let file = contextMenuFile() else { return }
        onOpenFileInNewTab?(file)
    }

    private func contextMenuFile() -> URL? {
        let row = fileOutlineView.clickedRow >= 0
            ? fileOutlineView.clickedRow
            : fileOutlineView.selectedRow
        guard row >= 0,
              let node = fileOutlineView.item(atRow: row) as? FileTreeNode,
              !node.isDirectory
        else { return nil }
        return node.url
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        false
    }

    func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        let available = splitView.bounds.height - splitView.dividerThickness
        if filesCollapsed { return 25 }
        if outlineCollapsed { return max(25, available - 25) }
        let minimum = min(100, available / 2)
        let position = min(max(minimum, proposedPosition), available - minimum)
        // Record intentional divider moves, not automatic frame changes during
        // window resizing or a temporary non-source surface.
        if setInitialDivider, !isAdjustingSections, !outlineSurfaceHidden, available >= 120 {
            let fraction = min(0.95, max(0.05, position / available))
            expandedDividerFraction = fraction
            UserDefaults.standard.set(fraction, forKey: "\(splitAutosaveName).fraction")
        }
        return position
    }

    private func configure(_ outlineView: NSOutlineView, column title: String) {
        let column = NSTableColumn(identifier: .init(title))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.selectionHighlightStyle = .regular
        outlineView.backgroundColor = .clear
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.style = .plain
        outlineView.indentationPerLevel = 13
        outlineView.setAccessibilityLabel(outlineView === fileOutlineView ? localized("main.files") : localized("main.outline"))
    }

    private func pane(
        title: String,
        outlineView: NSOutlineView,
        scrollView: NSScrollView,
        placeholder: NSView
    ) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = theme.chromeSecondaryColor
        label.translatesAutoresizingMaskIntoConstraints = false
        let header = NSView()
        header.wantsLayer = true
        header.layer?.backgroundColor = theme.chromeColor.cgColor
        header.translatesAutoresizingMaskIntoConstraints = false
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = theme.chromeDividerColor.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = outlineView
        outlineView.rowSizeStyle = .custom
        outlineView.rowHeight = 22
        outlineView.intercellSpacing = .zero
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false

        let pane = NSView()
        pane.wantsLayer = true
        pane.layer?.backgroundColor = theme.chromeColor.cgColor
        pane.addSubview(header)
        header.addSubview(label)
        let toggle = NSButton(title: "", target: self, action: #selector(toggleSidebarSection(_:)))
        toggle.tag = outlineView === fileOutlineView ? 0 : 1
        toggle.isBordered = false
        toggle.controlSize = .small
        toggle.contentTintColor = theme.chromeSecondaryColor
        toggle.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(toggle)
        let collapse = NSButton(title: "", target: self, action: #selector(collapseSidebarTree(_:)))
        collapse.image = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)
        collapse.tag = outlineView === fileOutlineView ? 0 : 1
        collapse.isBordered = false
        collapse.controlSize = .small
        collapse.contentTintColor = theme.chromeSecondaryColor
        collapse.toolTip = localizedFormat("main.collapse.all", title.lowercased())
        collapse.setAccessibilityLabel(localizedFormat("main.collapse.all", title.lowercased()))
        collapse.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(collapse)
        pane.addSubview(divider)
        let body = NSView()
        body.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(body)
        body.addSubview(scrollView)
        body.addSubview(placeholder)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: pane.topAnchor),
            header.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 24),
            toggle.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 4),
            toggle.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            toggle.widthAnchor.constraint(equalToConstant: 18),
            toggle.heightAnchor.constraint(equalToConstant: 22),
            label.leadingAnchor.constraint(equalTo: toggle.trailingAnchor, constant: 3),
            label.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            collapse.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -6),
            collapse.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            collapse.widthAnchor.constraint(equalToConstant: 22),
            collapse.heightAnchor.constraint(equalToConstant: 22),
            divider.topAnchor.constraint(equalTo: header.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
            body.topAnchor.constraint(equalTo: divider.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
            scrollView.topAnchor.constraint(equalTo: body.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            placeholder.leadingAnchor.constraint(
                greaterThanOrEqualTo: pane.leadingAnchor,
                constant: 8
            ),
            placeholder.trailingAnchor.constraint(
                lessThanOrEqualTo: pane.trailingAnchor,
                constant: -8
            ),
        ])
        paneSurfaces.append((pane, header, label, divider, body, toggle))
        return pane
    }

    private func configurePlaceholders() {
        filePlaceholderLabel.font = .systemFont(ofSize: 11)
        filePlaceholderLabel.textColor = .secondaryLabelColor
        filePlaceholderLabel.alignment = .center
        filePlaceholderButton.title = localized("main.open.project")
        filePlaceholderButton.font = .systemFont(ofSize: 11)
        filePlaceholderButton.isBordered = false
        filePlaceholderButton.contentTintColor = .linkColor
        filePlaceholderButton.target = self
        filePlaceholderButton.action = #selector(chooseProject(_:))
        fileLoadingIndicator.style = .spinning
        fileLoadingIndicator.controlSize = .small
        fileLoadingIndicator.isDisplayedWhenStopped = false
        filePlaceholder.orientation = .vertical
        filePlaceholder.alignment = .centerX
        filePlaceholder.spacing = 4
        filePlaceholder.addArrangedSubview(fileLoadingIndicator)
        filePlaceholder.addArrangedSubview(filePlaceholderLabel)
        filePlaceholder.addArrangedSubview(filePlaceholderButton)

        outlinePlaceholder.font = .systemFont(ofSize: 11)
        outlinePlaceholder.textColor = .secondaryLabelColor
        outlinePlaceholder.alignment = .center
    }

    private func updateFilePlaceholder(isIndexing: Bool) {
        let showsPlaceholder = isIndexing || tree == nil
        filePlaceholder.isHidden = !showsPlaceholder
        fileScrollView.isHidden = showsPlaceholder
        if isIndexing {
            filePlaceholderLabel.stringValue = localized("main.loading.files")
            filePlaceholderButton.isHidden = true
            fileLoadingIndicator.isHidden = false
            fileLoadingIndicator.startAnimation(nil)
        } else {
            filePlaceholderLabel.stringValue = localized("main.no.project.open")
            filePlaceholderButton.isHidden = false
            fileLoadingIndicator.stopAnimation(nil)
            fileLoadingIndicator.isHidden = true
        }
    }

    private func updateOutlinePlaceholder() {
        outlinePlaceholder.stringValue = hasSelectedFile
            ? localized("main.no.symbols.in.this.file")
            : localized("main.no.file.open")
        let showsPlaceholder = !hasSelectedFile || facetRows.isEmpty
        outlinePlaceholder.isHidden = !showsPlaceholder
        symbolScrollView.isHidden = showsPlaceholder
    }

    @objc private func chooseProject(_ sender: Any?) {
        onChooseProject?()
    }

    @objc private func toggleSidebarSection(_ sender: NSButton) {
        let defaults = UserDefaults.standard
        let available = splitView.bounds.height - splitView.dividerThickness
        if !filesCollapsed, !outlineCollapsed, !outlineSurfaceHidden, available >= 120 {
            expandedDividerFraction = paneSurfaces[0].pane.frame.height / available
            defaults.set(expandedDividerFraction,
                         forKey: "\(splitAutosaveName).fraction")
        }
        if sender.tag == 0 {
            filesCollapsed.toggle()
            defaults.set(filesCollapsed, forKey: "\(splitAutosaveName).filesCollapsed")
        } else {
            outlineCollapsed.toggle()
            defaults.set(outlineCollapsed, forKey: "\(splitAutosaveName).outlineCollapsed")
        }
        restoreSidebarDividerIfNeeded()
        view.needsLayout = true
        view.window?.makeFirstResponder(sender)
    }

    @objc private func collapseSidebarTree(_ sender: NSButton) {
        let outline = sender.tag == 0 ? fileOutlineView : symbolOutlineView
        outline.collapseItem(nil, collapseChildren: true)
        view.window?.makeFirstResponder(outline)
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
            label.font = .systemFont(ofSize: 12)
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            let detail = NSTextField(labelWithString: "")
            detail.font = .systemFont(ofSize: 11)
            detail.lineBreakMode = .byTruncatingTail
            detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            detail.setContentHuggingPriority(.defaultLow, for: .horizontal)
            cell = NSStackView(views: [image, label, detail])
            cell.identifier = identifier
            cell.orientation = .horizontal
            cell.alignment = .centerY
            cell.spacing = 4
        }
        let image = cell.arrangedSubviews[0] as! NSImageView
        let label = cell.arrangedSubviews[1] as! NSTextField
        let detail = cell.arrangedSubviews[2] as! NSTextField
        image.contentTintColor = symbolColor(for: facet.kind)
        label.textColor = theme.foregroundColor
        image.image = NSImage(
            systemSymbolName: symbolName(for: facet.kind),
            accessibilityDescription: nil
        )
        label.stringValue = facet.name
        detail.stringValue = facet.detail
        detail.textColor = theme.chromeSecondaryColor
        detail.isHidden = facet.detail.isEmpty
        let kind = switch facet.kind {
        case .fn: localized("main.function")
        case .method: localized("main.method")
        case .struct: localized("main.struct")
        case .class: localized("main.class")
        case .enum: localized("main.enum")
        case .trait: localized("main.trait")
        case .impl: localized("main.implementation")
        case .mod: localized("main.module")
        case .const: localized("main.constant")
        case .static: localized("main.static")
        case .typeAlias: localized("main.type.alias")
        case .field: localized("main.field")
        case .enumMember: localized("main.enum.case")
        }
        cell.toolTip = [kind, facet.name, facet.detail].filter { !$0.isEmpty }.joined(separator: " ")
        image.setAccessibilityElement(false)
        label.setAccessibilityElement(false)
        detail.setAccessibilityElement(false)
        cell.setAccessibilityElement(true)
        cell.setAccessibilityChildren([])
        cell.setAccessibilityLabel("\(kind) \(facet.name)")
        cell.setAccessibilityValue(facet.detail)
        cell.edgeInsets = NSEdgeInsets(
            top: 0,
            left: 2,
            bottom: 0,
            right: 4
        )
        return cell
    }

    private func symbolName(for kind: OutlineKind) -> String {
        switch kind {
        case .fn: "function"
        case .method: "m.square"
        case .struct, .class: "shippingbox"
        case .enum: "list.bullet"
        case .trait: "point.3.connected.trianglepath.dotted"
        case .impl: "hammer"
        case .mod: "folder"
        case .const: "c.square"
        case .static: "s.square"
        case .typeAlias: "t.square"
        case .field: "shippingbox"
        case .enumMember: "list.bullet.indent"
        }
    }

    private func symbolColor(for kind: OutlineKind) -> NSColor {
        switch kind {
        case .struct, .class, .trait, .typeAlias: theme.color(for: .typeName)
        case .enum, .enumMember, .const, .static: theme.color(for: .number)
        case .fn, .method: theme.color(for: .functionName)
        case .field: theme.chromeSecondaryColor
        case .impl, .mod: theme.chromeSecondaryColor
        }
    }

    private func fileIcon(for node: FileTreeNode) -> NSImage? {
        let symbol: String
        if node.isDirectory {
            symbol = "folder"
        } else if LanguageMode.classify(path: node.url.path, languages: [.rust, .python, .typescript]) != nil {
            symbol = "curlybraces"
        } else {
            symbol = switch node.url.pathExtension.lowercased() {
            case "json", "toml", "yaml", "yml", "lock": "slider.horizontal.3"
            case "md", "txt", "rst": "doc.text"
            case "png", "jpg", "jpeg", "svg": "photo"
            case "swift": "swift"
            default: "doc"
            }
        }
        return NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: node.isDirectory ? localized("main.folder") : localized("main.file")
        )
    }

    private func fileIconColor(for node: FileTreeNode) -> NSColor {
        guard !node.isDirectory else { return theme.chromeSecondaryColor }
        return switch LanguageMode.classify(path: node.url.path, languages: [.rust, .python, .typescript])?.language {
        case .rust: theme.color(for: .string)
        case .python: theme.color(for: .number)
        case .typescript: theme.color(for: .functionName)
        default: theme.chromeSecondaryColor
        }
    }
}
