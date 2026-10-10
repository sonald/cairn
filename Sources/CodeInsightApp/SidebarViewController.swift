import AppKit
import CodeInsightAppModel
import CodeInsightCore
import CodeInsightReaderCore
import CodeInsightReaderUI

@MainActor
/// Owns the file tree and symbol outline: data, selection sync and project
/// placeholders. Their views are two independent panels (`filesController`,
/// `outlineController`); this controller's own view is never shown.
final class SidebarViewController: NSViewController,
    NSOutlineViewDataSource, NSOutlineViewDelegate
{
    var onOpenFile: ((URL) -> Void)?
    var onOpenFileInSecondary: ((URL) -> Void)?
    /// “Open to the Side”: the split reference pane.
    var onOpenFileToSide: ((URL) -> Void)?
    var onOpenFileInNewTab: ((URL) -> Void)?
    var onOpenOutline: ((UInt32) -> Void)?
    /// Opens the project's exclusion rules editor.
    var onEditExclusionRules: (() -> Void)?
    /// Files header: how many paths the project's rules removed.
    private let exclusionButton = NSButton()
    var onChooseProject: (() -> Void)?
    private let fileOutlineView = NSOutlineView()
    private let symbolOutlineView = NSOutlineView()
    let filesController = NSViewController()
    let outlineController = NSViewController()
    /// Title-bar buttons of each panel (exclusion count, collapse all).
    private(set) var filesAccessories: [NSButton] = []
    private(set) var outlineAccessories: [NSButton] = []
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
    private var collapsedOutlineKeys: [URL: Set<UInt32>] = [:]
    private var isSynchronizingOutlineSelection = false
    private var isSynchronizingFileSelection = false
    private var synchronizedFile: URL?
    private var hasSelectedFile = false
    private var theme = ReaderTheme(settings: ReaderSettings())

    func apply(settings: ReaderSettings) {
        theme = ReaderTheme(settings: settings)
        guard isViewLoaded else { return }
        isSynchronizingFileSelection = true
        isSynchronizingOutlineSelection = true
        defer {
            isSynchronizingFileSelection = false
            isSynchronizingOutlineSelection = false
        }
        fileOutlineView.backgroundColor = theme.chromeColor
        symbolOutlineView.backgroundColor = theme.chromeColor
        for body in [filesController.view, outlineController.view] {
            body.layer?.backgroundColor = theme.chromeColor.cgColor
        }
        fileOutlineView.reloadData()
        symbolOutlineView.reloadData()
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
    /// Panel heights (title bar included) and placeholder centering.
    var selfTestGeometry: (
        filesPaneHeight: CGFloat,
        outlinePaneHeight: CGFloat,
        filePlaceholderHeight: CGFloat,
        filePlaceholderCenterOffset: CGFloat,
        outlinePlaceholderCenterOffset: CGFloat
    ) {
        loadViewIfNeeded()
        filesController.view.superview?.layoutSubtreeIfNeeded()
        outlineController.view.superview?.layoutSubtreeIfNeeded()
        return (
            filesController.view.superview?.frame.height ?? 0,
            outlineController.view.superview?.frame.height ?? 0,
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

    override func loadView() {
        configure(fileOutlineView, column: "File")
        configure(symbolOutlineView, column: "Symbol")
        fileOutlineView.target = self
        fileOutlineView.doubleAction = #selector(openFileInNewTab(_:))
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
        let toSide = NSMenuItem(
            title: localized("main.open.to.side"),
            action: #selector(openFileToSide(_:)),
            keyEquivalent: ""
        )
        toSide.target = self
        fileMenu.addItem(toSide)
        fileOutlineView.menu = fileMenu

        configurePlaceholders()
        (filesController.view, filesAccessories) = pane(
            title: localized("main.files"),
            outlineView: fileOutlineView,
            scrollView: fileScrollView,
            placeholder: filePlaceholder
        )
        (outlineController.view, outlineAccessories) = pane(
            title: localized("main.outline"),
            outlineView: symbolOutlineView,
            scrollView: symbolScrollView,
            placeholder: outlinePlaceholder
        )
        addChild(filesController)
        addChild(outlineController)
        view = NSView()
        updateFilePlaceholder(isIndexing: false)
        updateOutlinePlaceholder()
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
        // Rule-excluded and unreadable paths share the one count button.
        let excluded = tree?.ruleExcludedPaths.count ?? 0
        let unreadable = tree?.unreadablePaths.count ?? 0
        exclusionButton.isHidden = excluded == 0 && unreadable == 0
        exclusionButton.title = [excluded, unreadable].filter { $0 > 0 }.map(String.init)
            .joined(separator: " · ")
        let help = [
            excluded > 0 ? localizedFormat("main.rules.excluded", Int64(excluded)) : nil,
            unreadable > 0 ? localizedFormat("main.unreadable.files", Int64(unreadable)) : nil,
        ].compactMap { $0 }.joined(separator: "\n")
        exclusionButton.toolTip = help
        exclusionButton.setAccessibilityLabel(help)
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

    /// Lists what the rules removed and what could not be read; editing
    /// happens in the rules sheet.
    @objc private func showExcludedPaths(_ sender: NSButton) {
        var views: [NSView] = []
        func section(_ titleText: String, _ paths: [String]) {
            guard !paths.isEmpty else { return }
            let title = NSTextField(labelWithString: titleText)
            title.font = .systemFont(ofSize: 12, weight: .semibold)
            let list = NSTextField(wrappingLabelWithString: paths.prefix(50).joined(separator: "\n")
                + (paths.count > 50 ? "\n" + localizedFormat("main.rules.more", Int64(paths.count - 50)) : ""))
            list.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            list.textColor = theme.chromeSecondaryColor
            list.isSelectable = true
            views += [title, list]
        }
        let excluded = tree?.ruleExcludedPaths ?? []
        let unreadable = tree?.unreadablePaths ?? []
        section(localizedFormat("main.rules.excluded", Int64(excluded.count)), excluded)
        section(localizedFormat("main.unreadable.files", Int64(unreadable.count)), unreadable)
        let edit = NSButton(title: localized("main.rules.edit"), target: self, action: #selector(editRulesFromPopover(_:)))
        edit.bezelStyle = .rounded
        let stack = NSStackView(views: views + [edit])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        let controller = NSViewController()
        controller.view = stack
        stack.widthAnchor.constraint(lessThanOrEqualToConstant: 420).isActive = true
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        exclusionPopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    private var exclusionPopover: NSPopover?

    @objc private func editRulesFromPopover(_ sender: Any?) {
        exclusionPopover?.close()
        onEditExclusionRules?()
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
        if url.standardizedFileURL == tree?.root.standardizedFileURL {
            fileOutlineView.deselectAll(nil)
            fileOutlineView.scroll(.zero)
        } else {
            _ = synchronizeFileSelection(to: url, reveal: true)
            if let node = tree?.selectionPath(for: url)?.last, node.isDirectory {
                fileOutlineView.expandItem(node)
            }
        }
        fileOutlineView.window?.makeFirstResponder(fileOutlineView)
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

    func setOutline(_ nodes: [OutlineNode], file: URL? = nil) {
        loadViewIfNeeded()
        if let previous = outlineFile, !outlineModel.nodes.isEmpty {
            collapsedOutlineKeys[previous] = Set(outlineModel.nodes.indices.compactMap { index in
                !outlineModel.childIndices[index].isEmpty
                    && !symbolOutlineView.isItemExpanded(facetRows[index])
                    ? outlineModel.nodes[index].key : nil
            })
        }
        outlineFile = file
        outlineModel.setDocument(nodes)
        facetRows = outlineModel.nodes.indices.map { NSNumber(value: $0) }
        isSynchronizingOutlineSelection = true
        symbolOutlineView.reloadData()
        symbolOutlineView.expandItem(nil, expandChildren: true)
        if let file, let collapsed = collapsedOutlineKeys[file] {
            for index in outlineModel.nodes.indices
            where collapsed.contains(outlineModel.nodes[index].key) {
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
                  outlineModel.nodes.indices.contains(number.intValue)
            else { return nil }
            return outlineCell(for: outlineModel.nodes[number.intValue])
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

    @objc private func openFileToSide(_ sender: Any?) {
        guard let file = contextMenuFile() else { return }
        onOpenFileToSide?(file)
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

    /// The panel body (scroll view plus placeholder) and the buttons its
    /// title bar carries.
    private func pane(
        title: String,
        outlineView: NSOutlineView,
        scrollView: NSScrollView,
        placeholder: NSView
    ) -> (NSView, [NSButton]) {
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

        let collapse = NSButton(title: "", target: self, action: #selector(collapseSidebarTree(_:)))
        collapse.image = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)
        collapse.tag = outlineView === fileOutlineView ? 0 : 1
        collapse.isBordered = false
        collapse.controlSize = .small
        collapse.toolTip = localizedFormat("main.collapse.all", title.lowercased())
        collapse.setAccessibilityLabel(localizedFormat("main.collapse.all", title.lowercased()))
        var accessories = [collapse]
        if outlineView === fileOutlineView {
            exclusionButton.isBordered = false
            exclusionButton.controlSize = .small
            exclusionButton.font = .systemFont(ofSize: 10.5)
            exclusionButton.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: nil)
            exclusionButton.imagePosition = .imageLeading
            exclusionButton.target = self
            exclusionButton.action = #selector(showExcludedPaths(_:))
            exclusionButton.isHidden = true
            accessories.insert(exclusionButton, at: 0)
        }
        let body = NSView()
        body.wantsLayer = true
        body.layer?.backgroundColor = theme.chromeColor.cgColor
        body.addSubview(scrollView)
        body.addSubview(placeholder)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: body.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            placeholder.leadingAnchor.constraint(greaterThanOrEqualTo: body.leadingAnchor, constant: 8),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: body.trailingAnchor, constant: -8),
        ])
        return (body, accessories)
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

    @objc private func collapseSidebarTree(_ sender: NSButton) {
        let outline = sender.tag == 0 ? fileOutlineView : symbolOutlineView
        outline.collapseItem(nil, collapseChildren: true)
        outline.window?.makeFirstResponder(outline)
    }

    private func outlineCell(for node: OutlineNode) -> NSView {
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
        image.contentTintColor = symbolColor(for: node.kind)
        label.textColor = theme.foregroundColor
        image.image = NSImage(
            systemSymbolName: symbolName(for: node.kind),
            accessibilityDescription: nil
        )
        label.stringValue = node.title
        detail.stringValue = node.detail
        detail.textColor = theme.chromeSecondaryColor
        detail.isHidden = node.detail.isEmpty
        let kind = switch node.kind {
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
        cell.toolTip = [kind, node.title, node.detail].filter { !$0.isEmpty }.joined(separator: " ")
        image.setAccessibilityElement(false)
        label.setAccessibilityElement(false)
        detail.setAccessibilityElement(false)
        cell.setAccessibilityElement(true)
        cell.setAccessibilityChildren([])
        cell.setAccessibilityLabel("\(kind) \(node.title)")
        cell.setAccessibilityValue(node.detail)
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
