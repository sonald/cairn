import AppKit
import CodeInsightAppModel
import CodeInsightCore
import CodeInsightReaderCore
import CodeInsightReaderUI
import Observation

/// What the panel asks of its window: navigation and the reader's commands.
@MainActor
protocol ProjectSymbolsPanelHost: AnyObject {
    /// Preview (`focusReader == false`) or keep open and focus the reader.
    func openProjectSymbol(path: String, nameRange: ByteRange, contentID: ContentID, focusReader: Bool)
    func openProjectSymbolToSide(path: String, offset: UInt32)
    func showProjectSymbolRelations(path: String, offset: UInt32, direction: RelationTreeModel.Direction)
    func toggleProjectSymbolHighlight(name: String)
    func revealProjectSymbolFile(path: String)
    /// Context's target, else the caret: (path, byte offset).
    func currentSymbolLocation() -> (path: String, offset: UInt32)?
    func returnFocusToReader()
}

/// The project symbols panel (B2–B6): every indexed declaration by kind or
/// by module, filtered by text, kind, visibility and directory.
@MainActor
final class ProjectSymbolsPanel: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate,
    NSSearchFieldDelegate, NSMenuDelegate
{
    let model: ProjectSymbolsPanelModel
    weak var host: ProjectSymbolsPanelHost?

    private let filterField = NSSearchField()
    private let organization = NSSegmentedControl()
    private let filterButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let locateButton = NSButton()
    private let helpButton = NSButton()
    private let banner = NSTextField(wrappingLabelWithString: "")
    private let message = NSTextField(wrappingLabelWithString: "")
    private let outlineView = SymbolsOutlineView()
    private let scrollView = NSScrollView()
    private let placeholder = NSTextField(wrappingLabelWithString: "")
    private let footer = NSTextField(labelWithString: "")
    private var theme = ReaderTheme(settings: ReaderSettings())
    private var items: [Int: NodeItem] = [:]
    private var renderedRevision: UInt64 = .max
    /// B6.2: rows drop owner and path only near the 180pt minimum width.
    private var isNarrow: Bool { view.bounds.width < 200 }
    private var renderedNarrow: Bool?
    private var isSyncing = false
    private var filterTask: Task<Void, Never>?
    private var messageTask: Task<Void, Never>?

    private final class NodeItem: NSObject {
        let node: Int
        init(_ node: Int) { self.node = node }
    }

    init(model: ProjectSymbolsPanelModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard renderedNarrow != isNarrow else { return }
        let firstLayout = renderedNarrow == nil
        renderedNarrow = isNarrow
        guard !firstLayout else { return }
        let visible = outlineView.rows(in: outlineView.visibleRect)
        guard visible.length > 0 else { return }
        outlineView.reloadData(
            forRowIndexes: IndexSet(integersIn: visible.location..<NSMaxRange(visible)),
            columnIndexes: [0]
        )
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        filterField.placeholderString = localized("panel.symbols.filter")
        filterField.delegate = self
        filterField.controlSize = .small
        filterField.font = .systemFont(ofSize: 12)
        filterField.setAccessibilityLabel(localized("panel.symbols.filter"))
        // The field's × clears the text; Return applies it at once.
        filterField.target = self
        filterField.action = #selector(filterAction(_:))

        organization.segmentCount = 2
        organization.setLabel(localized("panel.symbols.byKind"), forSegment: 0)
        organization.setLabel(localized("panel.symbols.byModule"), forSegment: 1)
        organization.controlSize = .small
        organization.target = self
        organization.action = #selector(changeOrganization(_:))
        organization.setAccessibilityLabel(localized("panel.symbols.organization"))

        filterButton.controlSize = .small
        filterButton.isBordered = false
        filterButton.font = .systemFont(ofSize: 11)
        filterButton.menu = NSMenu()
        filterButton.menu?.addItem(withTitle: localized("panel.symbols.filters"), action: nil, keyEquivalent: "")
        filterButton.menu?.delegate = self
        filterButton.setAccessibilityLabel(localized("panel.symbols.filters"))
        filterButton.toolTip = localized("panel.symbols.filters")

        for (button, symbol, help, action) in [
            (locateButton, "scope", localized("panel.symbols.locate"), #selector(locateCurrentSymbol(_:))),
            (helpButton, "questionmark.circle", localized("panel.symbols.help.title"), #selector(showHelp(_:))),
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
            button.isBordered = false
            button.controlSize = .small
            button.target = self
            button.action = action
            button.toolTip = help
            button.setAccessibilityLabel(help)
        }

        let controls = NSStackView(views: [organization, filterButton, NSView(), locateButton, helpButton])
        controls.orientation = .horizontal
        controls.spacing = 6
        controls.setHuggingPriority(.defaultLow, for: .horizontal)
        filterButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for label in [banner, message, placeholder, footer] {
            label.font = .systemFont(ofSize: 11)
            label.isHidden = true
        }
        footer.lineBreakMode = .byTruncatingTail
        footer.isHidden = false
        placeholder.alignment = .center

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("symbol"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.rowSizeStyle = .custom
        outlineView.rowHeight = 22
        outlineView.intercellSpacing = .zero
        outlineView.style = .plain
        outlineView.indentationPerLevel = 13
        outlineView.backgroundColor = .clear
        outlineView.target = self
        outlineView.doubleAction = #selector(openClickedRow(_:))
        outlineView.setAccessibilityLabel(localized("panel.symbols"))
        outlineView.onReturn = { [weak self] in self?.openSelected(focusReader: true) }
        outlineView.onEscape = { [weak self] in self?.escape() }
        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let stack = NSStackView(views: [filterField, controls, banner, message, scrollView, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        root.addSubview(placeholder)
        for view in [filterField, controls, banner, message, scrollView, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
        }
        stack.setCustomSpacing(2, after: scrollView)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            placeholder.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            placeholder.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            placeholder.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
        ])
        scrollView.setContentHuggingPriority(.init(1), for: .vertical)
        view = root
        observe()
        render()
    }

    func apply(settings: ReaderSettings) {
        theme = ReaderTheme(settings: settings)
        guard isViewLoaded else { return }
        view.appearance = cairnAppearance(for: theme.variant)
        view.layer?.backgroundColor = theme.chromeColor.cgColor
        for label in [banner, message, placeholder, footer] { label.textColor = theme.chromeSecondaryColor }
        for button in [locateButton, helpButton] { button.contentTintColor = theme.chromeSecondaryColor }
        renderedRevision = .max
        render()
    }

    // MARK: Focus and commands

    var filterHasFocus: Bool {
        guard let editor = view.window?.firstResponder as? NSTextView else { return false }
        return editor.delegate as? NSSearchField === filterField
    }

    func focusFilter() {
        view.window?.makeFirstResponder(filterField)
    }

    func locate() { locateCurrentSymbol(nil) }

    @objc private func locateCurrentSymbol(_ sender: Any?) {
        guard let location = host?.currentSymbolLocation() else {
            show(message: localized("panel.symbols.locate.none"))
            return
        }
        switch model.locate(path: location.path, offset: location.offset) {
        case let .found(node):
            reveal(node)
        case .hiddenByFilter:
            show(message: localized("panel.symbols.locate.filtered"))
        case .notFound:
            show(message: localized("panel.symbols.locate.none"))
        }
    }

    private func show(message text: String) {
        message.stringValue = text
        message.isHidden = false
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.message.isHidden = true
        }
    }

    @objc private func showHelp(_ sender: NSButton) {
        let popover = NSPopover()
        popover.behavior = .transient
        let label = NSTextField(wrappingLabelWithString: localized("panel.symbols.help"))
        label.font = .systemFont(ofSize: 11.5)
        label.preferredMaxLayoutWidth = 300
        let controller = NSViewController()
        let container = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            label.widthAnchor.constraint(equalToConstant: 300),
        ])
        controller.view = container
        popover.contentViewController = controller
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    private func escape() {
        if !filterField.stringValue.isEmpty {
            filterField.stringValue = ""
            applyFilterText()
        } else {
            host?.returnFocusToReader()
        }
    }

    // MARK: Filter controls

    func controlTextDidChange(_ notification: Notification) {
        filterTask?.cancel()
        filterTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.applyFilterText()
        }
    }

    @objc private func filterAction(_ sender: NSSearchField) { applyFilterText() }

    private func applyFilterText() {
        filterTask?.cancel()
        model.setFilterText(filterField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            applyFilterText()
            render()
            view.window?.makeFirstResponder(outlineView)
            if outlineView.selectedRow < 0, outlineView.numberOfRows > 0 {
                outlineView.selectRowIndexes([firstSymbolRow() ?? 0], byExtendingSelection: false)
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            escape()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            applyFilterText()
            return true
        default:
            return false
        }
    }

    private func firstSymbolRow() -> Int? {
        (0..<outlineView.numberOfRows).first { row in
            guard let item = outlineView.item(atRow: row) as? NodeItem,
                  case .symbol = model.node(item.node)?.content else { return false }
            return true
        }
    }

    @objc private func changeOrganization(_ sender: NSSegmentedControl) {
        model.setOrganization(sender.selectedSegment == 1 ? .module : .kind)
    }

    @objc private func toggleGroup(_ sender: NSMenuItem) {
        guard let group = (sender.representedObject as? String).flatMap(ProjectSymbolGroup.init(rawValue:)) else { return }
        model.setGroup(group, enabled: !model.enabledGroups.contains(group))
    }

    @objc private func togglePublicOnly(_ sender: NSMenuItem) {
        model.setPublicOnly(!model.publicOnly)
    }

    @objc private func chooseScope(_ sender: NSMenuItem) {
        guard let scope = (sender.representedObject as? String).flatMap(ProjectSymbolScope.init(rawValue:)) else { return }
        model.setScope(scope)
    }

    // MARK: Menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu === filterButton.menu {
            fillFilterMenu(menu)
        } else {
            fillContextMenu(menu)
        }
    }

    private func fillFilterMenu(_ menu: NSMenu) {
        menu.addItem(withTitle: filterTitle, action: nil, keyEquivalent: "")  // pull-down title
        menu.addItem(.sectionHeader(title: localized("panel.symbols.kinds")))
        for group in ProjectSymbolGroup.allCases {
            let item = NSMenuItem(title: Self.title(of: group), action: #selector(toggleGroup(_:)), keyEquivalent: "")
            item.representedObject = group.rawValue
            item.state = model.enabledGroups.contains(group) ? .on : .off
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let publicItem = NSMenuItem(title: localized("panel.symbols.publicOnly"), action: #selector(togglePublicOnly(_:)), keyEquivalent: "")
        publicItem.state = model.publicOnly ? .on : .off
        publicItem.target = self
        publicItem.toolTip = localized("panel.symbols.publicOnly.help")
        menu.addItem(publicItem)
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: localized("panel.symbols.scope")))
        for scope in ProjectSymbolScope.allCases {
            let item = NSMenuItem(
                title: scope == .project ? localized("panel.symbols.scope.project") : localized("panel.symbols.scope.directory"),
                action: #selector(chooseScope(_:)), keyEquivalent: ""
            )
            item.representedObject = scope.rawValue
            item.state = model.scope == scope ? .on : .off
            item.target = self
            item.isEnabled = scope == .project || model.currentDirectory != nil
            menu.addItem(item)
        }
        menu.autoenablesItems = false
    }

    private var filterTitle: String {
        var parts: [String] = []
        if model.enabledGroups.count < ProjectSymbolGroup.allCases.count { parts.append(localized("panel.symbols.kinds.short")) }
        if model.publicOnly { parts.append(localized("panel.symbols.publicOnly.short")) }
        if model.scope == .currentDirectory { parts.append(localized("panel.symbols.scope.directory.short")) }
        return parts.isEmpty ? localized("panel.symbols.filters") : parts.joined(separator: " · ")
    }

    private enum ContextAction: Int {
        case open, openToSide, callers, callees, references, implementations, highlight, reveal, copyName
    }

    private func fillContextMenu(_ menu: NSMenu) {
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        guard !model.isStale, row >= 0, let item = outlineView.item(atRow: row) as? NodeItem,
              case let .symbol(rowIndex, _) = model.node(item.node)?.content,
              let symbol = model.row(rowIndex)
        else { return }
        let shape = symbol.kind.shape
        let entries: [(ContextAction, String, Bool)] = [
            (.open, localized("panel.symbols.menu.open"), true),
            (.openToSide, localized("app.menu.open.to.side"), true),
            (.callers, localized("panel.symbols.menu.callers"), shape == .function),
            (.callees, localized("panel.symbols.menu.callees"), shape == .function),
            (.references, localized("panel.symbols.menu.references"), true),
            (.implementations, localized("panel.symbols.menu.implementations"), shape == .trait || shape.family == .type),
            (.highlight, localized("main.highlight.toggle"), true),
            (.reveal, localized("panel.symbols.menu.reveal"), true),
            (.copyName, localized("panel.symbols.menu.copyName"), true),
        ]
        for (index, entry) in entries.enumerated() {
            if [2, 6].contains(index) { menu.addItem(.separator()) }
            let menuItem = NSMenuItem(title: entry.1, action: #selector(runContextAction(_:)), keyEquivalent: "")
            menuItem.tag = entry.0.rawValue
            menuItem.representedObject = rowIndex
            menuItem.isEnabled = entry.2
            menuItem.target = self
            menu.addItem(menuItem)
        }
        menu.autoenablesItems = false
    }

    @objc private func runContextAction(_ sender: NSMenuItem) {
        guard let action = ContextAction(rawValue: sender.tag), !model.isStale,
              let rowIndex = sender.representedObject as? Int, let row = model.row(rowIndex)
        else { return }
        let offset = row.symbol.nameRange.lowerBound
        switch action {
        case .open:
            host?.openProjectSymbol(path: row.path, nameRange: row.symbol.nameRange, contentID: row.contentID, focusReader: true)
        case .openToSide: host?.openProjectSymbolToSide(path: row.path, offset: offset)
        case .callers: host?.showProjectSymbolRelations(path: row.path, offset: offset, direction: .callers)
        case .callees: host?.showProjectSymbolRelations(path: row.path, offset: offset, direction: .calls)
        case .references: host?.showProjectSymbolRelations(path: row.path, offset: offset, direction: .references)
        case .implementations: host?.showProjectSymbolRelations(path: row.path, offset: offset, direction: .implementations)
        case .highlight: host?.toggleProjectSymbolHighlight(name: row.name)
        case .reveal: host?.revealProjectSymbolFile(path: row.path)
        case .copyName:
            guard let name = model.qualifiedName(ofRow: rowIndex) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(name, forType: .string)
        }
    }

    // MARK: Opening

    @objc private func openClickedRow(_ sender: Any?) {
        guard outlineView.clickedRow >= 0 else { return }
        openSelected(focusReader: true)
    }

    private func openSelected(focusReader: Bool) {
        guard let target = model.selectedTarget else { return }
        host?.openProjectSymbol(path: target.path, nameRange: target.nameRange, contentID: target.contentID, focusReader: focusReader)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncing else { return }
        let item = outlineView.item(atRow: outlineView.selectedRow) as? NodeItem
        model.select(node: item?.node)
        openSelected(focusReader: false)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !isSyncing, model.filterText.isEmpty,
              let item = notification.userInfo?["NSObject"] as? NodeItem else { return }
        model.expandedKeys.insert(model.key(of: item.node))
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !isSyncing, model.filterText.isEmpty,
              let item = notification.userInfo?["NSObject"] as? NodeItem else { return }
        model.expandedKeys.remove(model.key(of: item.node))
    }

    // MARK: Data source (children materialize only when asked)

    private func item(_ node: Int) -> NodeItem {
        if let item = items[node] { return item }
        let item = NodeItem(node)
        items[node] = item
        return item
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        model.visibleChildren(of: (item as? NodeItem)?.node ?? model.rootNode).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        self.item(model.visibleChildren(of: (item as? NodeItem)?.node ?? model.rootNode)[index])
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let item = item as? NodeItem else { return false }
        return !model.visibleChildren(of: item.node).isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let item = item as? NodeItem, case .symbol = model.node(item.node)?.content else { return false }
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? NodeItem, let node = model.node(item.node) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("ProjectSymbolCell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? SymbolCell ?? SymbolCell(identifier: identifier)
        let narrow = isNarrow
        cell.detail.isHidden = narrow
        cell.mark.isHidden = true
        cell.icon.isHidden = false
        cell.title.alphaValue = model.isDimmed(item.node) ? 0.5 : 1
        cell.icon.alphaValue = cell.title.alphaValue
        cell.detail.textColor = theme.chromeTertiaryColor
        switch node.content {
        case let .symbol(rowIndex, merged):
            guard let row = model.row(rowIndex) else { return cell }
            configureSymbol(cell, row: row, node: node, merged: merged, narrow: narrow)
        default:
            cell.icon.image = NSImage(systemSymbolName: Self.containerIcon(node.content), accessibilityDescription: nil)
            cell.icon.contentTintColor = theme.chromeSecondaryColor
            let title = containerTitle(node.content)
            let count = model.count(of: item.node)
            let text = NSMutableAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: theme.foregroundColor,
            ])
            text.append(NSAttributedString(string: "  \(count.formatted())", attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: theme.chromeTertiaryColor,
            ]))
            cell.title.attributedStringValue = text
            cell.detail.stringValue = ""
            cell.setAccessibilityLabel("\(title) \(count)")
        }
        return cell
    }

    private func configureSymbol(_ cell: SymbolCell, row: ProjectSymbolRow, node: ProjectSymbolNode, merged: Bool, narrow: Bool) {
        let kind = OutlineKind(row.kind, isMethod: row.group == .method)
        cell.icon.image = NSImage(systemSymbolName: SidebarViewController.symbolName(for: kind), accessibilityDescription: nil)
        cell.icon.contentTintColor = SidebarViewController.symbolColor(for: kind, theme: theme)
        if let visibility = row.visibility {
            cell.mark.isHidden = false
            cell.mark.image = NSImage(systemSymbolName: Self.visibilityIcon(visibility), accessibilityDescription: nil)
            cell.mark.contentTintColor = theme.chromeSecondaryColor
        }
        let secondary: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: theme.chromeTertiaryColor]
        let text = NSMutableAttributedString()
        if model.isMultiLanguage {
            text.append(NSAttributedString(string: Self.languageTag(row.kind.language) + " ", attributes: secondary))
        }
        // The owner shows only where the row stands alone in its group.
        let parentIsGroup = node.parent.flatMap(model.node).map { if case .group = $0.content { true } else { false } } ?? false
        if !narrow, parentIsGroup, let parent = row.parentRow.flatMap(model.row), row.group == .method || row.group == .field {
            text.append(NSAttributedString(string: parent.name + row.kind.qualifiedNameSeparator, attributes: secondary))
        }
        let name: String
        if row.kind == .rustImpl {
            name = row.symbol.implTraitName.map { "impl \($0) for \(row.name)" } ?? "impl \(row.name)"
        } else {
            name = row.name
        }
        let nameText = NSMutableAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: theme.foregroundColor,
        ])
        let offset = row.kind == .rustImpl ? (name as NSString).range(of: row.name, options: .backwards).location : 0
        for range in model.matchRanges(for: row.name) where offset != NSNotFound {
            let nsRange = NSRange(location: range.lowerBound + offset, length: range.count)
            if NSMaxRange(nsRange) <= nameText.length {
                nameText.addAttribute(.font, value: NSFont.systemFont(ofSize: 12, weight: .bold), range: nsRange)
            }
        }
        text.append(nameText)
        if merged {
            text.append(NSAttributedString(string: "  " + localized("panel.symbols.mergedByName"), attributes: secondary))
        }
        cell.title.attributedStringValue = text
        cell.detail.stringValue = "\(displayPath(row)):\(row.symbol.line)"
        let visibility = row.visibility.map(Self.visibilityTitle) ?? ""
        cell.setAccessibilityLabel([visibility, Self.title(of: row.group), name].filter { !$0.isEmpty }.joined(separator: " "))
        cell.setAccessibilityValue(cell.detail.stringValue)
        cell.toolTip = merged ? localized("panel.symbols.mergedByName.help") : nil
    }

    private func displayPath(_ row: ProjectSymbolRow) -> String {
        guard let listing = model.listing(row.unit), listing.unitRoot != ".",
              row.path.hasPrefix(listing.unitRoot + "/") else { return row.path }
        return String(row.path.dropFirst(listing.unitRoot.count + 1))
    }

    private func containerTitle(_ content: ProjectSymbolNode.Content) -> String {
        switch content {
        case let .group(group): Self.title(of: group)
        case let .unit(unit):
            model.listing(unit).map { "\(Self.languageName($0.language)) · \($0.unitRoot)" } ?? ""
        case let .crate(path): path
        case let .module(name): name
        case .unmounted: localized("panel.symbols.unmounted")
        case let .file(path): path
        case .root, .symbol: ""
        }
    }

    static func title(of group: ProjectSymbolGroup) -> String {
        localized("panel.symbols.kind.\(group.rawValue)")
    }

    private static func containerIcon(_ content: ProjectSymbolNode.Content) -> String {
        switch content {
        case .group: "square.stack.3d.up"
        case .unit: "shippingbox"
        case .crate: "cube"
        case .module: "folder"
        case .unmounted: "questionmark.folder"
        case .file: "doc"
        case .root, .symbol: "circle"
        }
    }

    private static func visibilityIcon(_ visibility: DeclarationVisibility) -> String {
        switch visibility {
        case .public: "circle.fill"
        case .restricted: "circle.lefthalf.filled"
        case .private: "circle"
        }
    }

    private static func visibilityTitle(_ visibility: DeclarationVisibility) -> String {
        switch visibility {
        case .public: localized("panel.symbols.visibility.public")
        case .restricted: localized("panel.symbols.visibility.restricted")
        case .private: localized("panel.symbols.visibility.private")
        }
    }

    private static func languageTag(_ language: LanguageID) -> String {
        switch language {
        case .rust: "rs"
        case .python: "py"
        case .typescript: "ts"
        case .javascript: "js"
        }
    }

    private static func languageName(_ language: LanguageID) -> String {
        switch language {
        case .rust: "Rust"
        case .python: "Python"
        case .typescript: "TypeScript"
        case .javascript: "JavaScript"
        }
    }

    // MARK: Rendering

    private func observe() {
        withObservationTracking {
            _ = model.revision; _ = model.isStale; _ = model.status; _ = model.selectedRow
            _ = model.unavailableReason
            _ = model.organization; _ = model.publicOnly; _ = model.scope; _ = model.enabledGroups
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observe()
                self?.render()
            }
        }
    }

    func render() {
        guard isViewLoaded else { return }
        organization.selectedSegment = model.organization == .module ? 1 : 0
        filterButton.item(at: 0)?.title = filterTitle
        banner.stringValue = localized("panel.symbols.stale")
        banner.isHidden = !model.isStale
        outlineView.alphaValue = model.isStale ? 0.55 : 1
        switch model.status {
        case .indexing:
            placeholder.stringValue = localized("panel.symbols.indexing")
        case .empty:
            placeholder.stringValue = model.unavailableReason ?? localized("panel.symbols.empty")
        case .ready:
            placeholder.stringValue = localized("panel.symbols.noMatch")
        }
        let summary = model.summary
        placeholder.isHidden = model.status == .ready && model.visibleChildren(of: model.rootNode).count > 0
        let languages = summary.languages.map(Self.languageName).joined(separator: localized("panel.symbols.listSeparator"))
        footer.stringValue = model.status == .ready
            ? (summary.filtered
                ? localizedFormat("panel.symbols.footer.filtered", Int64(summary.shown), Int64(summary.total), Int64(summary.files), languages)
                : localizedFormat("panel.symbols.footer", Int64(summary.total), Int64(summary.files), languages))
            : ""
        if renderedRevision != model.revision {
            renderedRevision = model.revision
            reloadTree()
        }
        syncSelection()
    }

    private func reloadTree() {
        isSyncing = true
        defer { isSyncing = false }
        items = [:]
        outlineView.reloadData()
        let roots = model.visibleChildren(of: model.rootNode)
        if !model.filterText.isEmpty {
            // Containers kept for their matches open themselves (B3.1).
            func expandKept(_ node: Int) {
                for child in model.visibleChildren(of: node) {
                    let content = model.node(child)?.content
                    let isSymbol: Bool = if case .symbol = content { true } else { false }
                    guard !model.visibleChildren(of: child).isEmpty, !isSymbol || model.isDimmed(child) else { continue }
                    outlineView.expandItem(item(child))
                    expandKept(child)
                }
            }
            expandKept(model.rootNode)
        } else {
            func restore(_ node: Int) {
                for child in model.visibleChildren(of: node) where model.expandedKeys.contains(model.key(of: child)) {
                    outlineView.expandItem(item(child))
                    restore(child)
                }
            }
            restore(model.rootNode)
            if roots.count == 1 { outlineView.expandItem(item(roots[0])) }
        }
    }

    private func syncSelection() {
        isSyncing = true
        defer { isSyncing = false }
        guard let row = model.selectedRow, let node = model.node(forRow: row), model.isVisible(node) else {
            outlineView.deselectAll(nil)
            return
        }
        let index = outlineView.row(forItem: items[node])
        if index >= 0, outlineView.selectedRow != index {
            outlineView.selectRowIndexes([index], byExtendingSelection: false)
        }
    }

    /// Expands the ancestors of `node`, selects and scrolls to it.
    private func reveal(_ node: Int) {
        isSyncing = true
        defer { isSyncing = false }
        var chain: [Int] = []
        var current = model.node(node)?.parent
        while let index = current, index != model.rootNode {
            chain.append(index)
            current = model.node(index)?.parent
        }
        for ancestor in chain.reversed() {
            outlineView.expandItem(item(ancestor))
            if model.filterText.isEmpty { model.expandedKeys.insert(model.key(of: ancestor)) }
        }
        let row = outlineView.row(forItem: item(node))
        guard row >= 0 else { return }
        outlineView.selectRowIndexes([row], byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
        view.window?.makeFirstResponder(outlineView)
    }
}

/// Icon, name and a right-aligned `path:line`; a 9pt visibility mark leads.
private final class SymbolCell: NSTableCellView {
    let mark = NSImageView()
    let icon = NSImageView()
    let title = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        mark.symbolConfiguration = .init(pointSize: 7, weight: .regular)
        title.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 11)
        detail.lineBreakMode = .byTruncatingHead
        detail.alignment = .right
        title.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [mark, icon, title, detail])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            mark.widthAnchor.constraint(equalToConstant: 9),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = title
        imageView = icon
        for view in [mark, icon, title, detail] { view.setAccessibilityElement(false) }
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// Return opens, Escape clears the filter and then leaves the panel.
private final class SymbolsOutlineView: NSOutlineView {
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onReturn?()
        case 53: onEscape?()
        default: super.keyDown(with: event)
        }
    }
}
