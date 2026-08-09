import AppKit
import CodeInsightAppModel
import CodeInsightCore
import CodeInsightReaderCore
import CodeInsightReaderUI
import Observation

@MainActor
final class PalettePanel: NSWindowController, NSTextFieldDelegate,
    NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate
{
    enum Mode: Equatable {
        case file
        case command
        case currentSymbol
        case projectSymbol
        case line

        static func parse(_ input: String) -> (mode: Self, query: String) {
            guard let first = input.first else { return (.file, "") }
            let query = String(input.dropFirst())
                .trimmingCharacters(in: .whitespaces)
            return switch first {
            case ">": (.command, query)
            case "@": (.currentSymbol, query)
            case "#": (.projectSymbol, query)
            case ":": (.line, query)
            default: (.file, input.trimmingCharacters(in: .whitespaces))
            }
        }
    }

    enum Payload {
        case file(URL)
        case location(URL, UInt32)
        case command(NSMenuItem)
    }

    struct Row {
        let title: String
        let detail: String
        let shortcut: String
        let identity: String
        let payload: Payload?

        var isSelectable: Bool { payload != nil }
    }

    private static let resultLimit = 20
    private let appModel: AppModel
    private let symbolModel = SymbolSearchPanelModel()
    private let onOpen: (URL, UInt32?) -> Void
    private let input = NSTextField()
    private let modeLabel = NSTextField(labelWithString: "⌘P")
    private let tableView = NSTableView()
    private let footerLabel = NSTextField(labelWithString: "")
    private var footerHeightConstraint: NSLayoutConstraint?
    private var footerBottomConstraint: NSLayoutConstraint?
    private var scrollFooterSpacingConstraint: NSLayoutConstraint?
    private var theme: ReaderTheme
    private var rows: [Row] = []
    private var selectedIndex: Int?
    private var capturedCommands: [Row] = []
    private weak var ownerWindow: NSWindow?
    private weak var originalResponder: NSResponder?
    var restoreFocusForTesting: (() -> Void)?
    var revalidateForTesting: ((NSMenuItem) -> Void)?
    var sendActionForTesting: ((Selector, AnyObject?, NSMenuItem) -> Void)?

    init(
        appModel: AppModel,
        settings: ReaderSettings,
        onOpen: @escaping (URL, UInt32?) -> Void
    ) {
        self.appModel = appModel
        self.onOpen = onOpen
        theme = ReaderTheme(settings: settings)
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 270),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        super.init(window: panel)
        panel.delegate = self
        configureView()
        apply(settings: settings)
        observeSymbolModel()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(prefill: String, relativeTo owner: NSWindow?) {
        prepare(
            prefill: prefill,
            owner: owner,
            commands: Self.commandRows(in: NSApp.mainMenu)
        )
        guard let panel = window else { return }
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(input)
        if let editor = input.currentEditor() as? NSTextView {
            editor.setSelectedRange(NSRange(
                location: input.stringValue.utf16.count,
                length: 0
            ))
        }
    }

    func apply(settings: ReaderSettings) {
        theme = ReaderTheme(settings: settings)
        window?.appearance = switch settings.theme {
        case .dark: NSAppearance(named: .darkAqua)
        case .light, .siClassic: NSAppearance(named: .aqua)
        case .auto: nil
        }
        guard let content = window?.contentView else { return }
        content.layer?.backgroundColor = theme.backgroundColor.cgColor
        content.layer?.borderColor = theme.chromeDividerColor.cgColor
        footerLabel.textColor = theme.chromeTertiaryColor
        modeLabel.textColor = theme.chromeTertiaryColor
        tableView.backgroundColor = theme.backgroundColor
        tableView.reloadData()
    }

    func refreshProjectState() {
        guard window?.isVisible == true else { return }
        refreshRows()
    }

    var rowsForTesting: [Row] { rows }
    var footerForTesting: String { footerLabel.stringValue }
    var selectedIndexForTesting: Int? { selectedIndex }
    var originalResponderForTesting: NSResponder? { originalResponder }
    var inputSelectionForTesting: NSRange? {
        (input.currentEditor() as? NSTextView)?.selectedRange()
    }

    func setQueryForTesting(_ query: String) {
        input.stringValue = query
        refreshRows()
    }

    func selectForTesting(_ index: Int) {
        guard rows.indices.contains(index), rows[index].isSelectable else { return }
        selectedIndex = index
        tableView.selectRowIndexes([index], byExtendingSelection: false)
    }

    func openSelectionForTesting() {
        openSelection()
    }

    func prepareForTesting(
        prefill: String,
        owner: NSWindow?,
        commands: [Row]
    ) {
        prepare(prefill: prefill, owner: owner, commands: commands)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let value = rows[row]
        let cell = NSTableCellView()
        let title = NSTextField(labelWithString: value.title)
        title.font = .systemFont(ofSize: 12.5, weight: .medium)
        title.textColor = value.isSelectable
            ? theme.foregroundColor
            : theme.chromeTertiaryColor
        title.lineBreakMode = .byTruncatingMiddle
        title.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(title)

        let detail = NSTextField(labelWithString: value.detail)
        detail.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        detail.textColor = theme.chromeTertiaryColor
        detail.alignment = .right
        detail.lineBreakMode = .byTruncatingHead
        detail.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(detail)

        let shortcut = NSTextField(labelWithString: value.shortcut)
        shortcut.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        shortcut.textColor = theme.chromeTertiaryColor
        shortcut.alignment = .center
        shortcut.wantsLayer = true
        shortcut.layer?.cornerRadius = 3
        shortcut.layer?.borderWidth = value.shortcut.isEmpty ? 0 : 1
        shortcut.layer?.borderColor = theme.chromeDividerColor.cgColor
        shortcut.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(shortcut)

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
            title.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8),
            detail.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            detail.widthAnchor.constraint(lessThanOrEqualToConstant: 180),
            shortcut.leadingAnchor.constraint(equalTo: detail.trailingAnchor, constant: 8),
            shortcut.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
            shortcut.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            shortcut.widthAnchor.constraint(greaterThanOrEqualToConstant:
                value.shortcut.isEmpty ? 0 : 28),
        ])
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        26
    }

    func tableView(
        _ tableView: NSTableView,
        rowViewForRow row: Int
    ) -> NSTableRowView? {
        PaletteTableRowView(selectionColor: theme.chromeSelectionColor)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard tableView.selectedRow >= 0,
              rows.indices.contains(tableView.selectedRow),
              rows[tableView.selectedRow].isSelectable
        else { return }
        selectedIndex = tableView.selectedRow
    }

    func controlTextDidChange(_ notification: Notification) {
        refreshRows()
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
        case #selector(NSResponder.insertNewline(_:)):
            openSelection()
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
        default:
            return false
        }
        return true
    }

    func windowDidResignKey(_ notification: Notification) {
        dismiss(restoreFocus: false)
    }

    @objc private func openClickedRow(_ sender: Any?) {
        guard tableView.clickedRow >= 0,
              rows.indices.contains(tableView.clickedRow),
              rows[tableView.clickedRow].isSelectable
        else { return }
        selectedIndex = tableView.clickedRow
        openSelection()
    }

    private func configureView() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.cornerRadius = 10
        content.layer?.borderWidth = 1
        content.layer?.masksToBounds = true

        modeLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        modeLabel.alignment = .center
        modeLabel.setAccessibilityLabel("Palette shortcut")
        modeLabel.translatesAutoresizingMaskIntoConstraints = false

        input.placeholderString = "Open file, > command, @ symbol, # project, : line"
        input.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        input.isBordered = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.delegate = self
        input.setAccessibilityLabel("Quick Open")
        input.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("PaletteResult"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openClickedRow(_:))
        tableView.refusesFirstResponder = true
        tableView.rowSizeStyle = .custom
        tableView.intercellSpacing = .zero
        tableView.setAccessibilityLabel("Palette results")

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        footerLabel.font = .systemFont(ofSize: 10.5)
        footerLabel.setAccessibilityLabel("Palette status")
        footerLabel.translatesAutoresizingMaskIntoConstraints = false

        for view in [modeLabel, input, separator, scrollView, footerLabel] {
            content.addSubview(view)
        }
        footerHeightConstraint = footerLabel.heightAnchor.constraint(equalToConstant: 0)
        footerBottomConstraint = footerLabel.bottomAnchor.constraint(
            equalTo: content.bottomAnchor
        )
        scrollFooterSpacingConstraint = scrollView.bottomAnchor.constraint(
            equalTo: footerLabel.topAnchor
        )
        NSLayoutConstraint.activate([
            modeLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            modeLabel.centerYAnchor.constraint(equalTo: input.centerYAnchor),
            modeLabel.widthAnchor.constraint(equalToConstant: 44),
            input.topAnchor.constraint(equalTo: content.topAnchor, constant: 4),
            input.leadingAnchor.constraint(equalTo: modeLabel.trailingAnchor, constant: 6),
            input.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            input.heightAnchor.constraint(equalToConstant: 26),
            separator.topAnchor.constraint(equalTo: input.bottomAnchor, constant: 4),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollFooterSpacingConstraint!,
            footerLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            footerLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            footerBottomConstraint!,
            footerHeightConstraint!,
        ])
    }

    private func prepare(
        prefill: String,
        owner: NSWindow?,
        commands: [Row]
    ) {
        ownerWindow = owner
        originalResponder = owner?.firstResponder
        capturedCommands = commands
        input.stringValue = prefill
        refreshRows()
    }

    private func refreshRows() {
        let parsed = Mode.parse(input.stringValue)
        modeLabel.stringValue = switch parsed.mode {
        case .file: "⌘P"
        case .command: "⇧⌘P"
        case .currentSymbol: "@"
        case .projectSymbol: "⌘T"
        case .line: "⌘L"
        }
        switch parsed.mode {
        case .file:
            symbolModel.reset()
            install(Self.fileRows(
                query: parsed.query,
                tree: appModel.fileTree,
                tabs: appModel.tabStrip.tabs.map(\.fileURL)
            ), emptyMessage: appModel.fileTree == nil ? "No project open" : "No files found")
        case .command:
            symbolModel.reset()
            install(Self.filterCommandRows(capturedCommands, query: parsed.query),
                    emptyMessage: "No commands found")
        case .currentSymbol:
            symbolModel.reset()
            guard let document = appModel.tabStrip.activeDocument,
                  let file = appModel.selectedFile
            else {
                install([], emptyMessage: "No active file")
                return
            }
            install(Self.currentSymbolRows(
                query: parsed.query,
                document: document,
                file: file
            ), emptyMessage: parsed.query.isEmpty
                ? "Type a symbol name"
                : "No symbols found")
        case .projectSymbol:
            guard !parsed.query.isEmpty else {
                symbolModel.reset()
                install([], emptyMessage: "Type a project symbol")
                return
            }
            symbolModel.updateQuery(
                parsed.query,
                projectState: appModel.projectState,
                currentPath: selectedProjectPath
            )
            installProjectSymbolRows()
        case .line:
            symbolModel.reset()
            guard let document = appModel.tabStrip.activeDocument,
                  let file = appModel.selectedFile
            else {
                install([], emptyMessage: "No active file")
                return
            }
            let result = Self.lineRows(
                query: parsed.query,
                document: document,
                file: file
            )
            install(result.rows, emptyMessage: result.message)
        }
    }

    private func installProjectSymbolRows() {
        let candidates: [Row] = symbolModel.rows.compactMap { row in
            guard case let .result(name, hit) = row,
                  let root = appModel.fileTree?.root
            else { return nil }
            return Row(
                title: name,
                detail: "\(hit.path):\(hit.line):\(hit.column)",
                shortcut: "",
                identity: "project:\(hit.path):\(hit.facet.nameRange.lowerBound)",
                payload: .location(
                    root.appendingPathComponent(hit.path),
                    hit.facet.nameRange.lowerBound
                )
            )
        }
        let placeholder = symbolModel.rows.compactMap { row -> String? in
            if case let .placeholder(message) = row { return message }
            return nil
        }.first
        install(candidates, emptyMessage: placeholder ?? "No project symbols found")
    }

    private func install(_ candidates: [Row], emptyMessage: String) {
        let previousIdentity = selectedIndex.flatMap {
            rows.indices.contains($0) ? rows[$0].identity : nil
        }
        let total = candidates.count
        rows = Array(candidates.prefix(Self.resultLimit))
        if rows.isEmpty {
            rows = [Row(
                title: emptyMessage,
                detail: "",
                shortcut: "",
                identity: "message:\(emptyMessage)",
                payload: nil
            )]
            footerLabel.stringValue = ""
            selectedIndex = nil
        } else {
            footerLabel.stringValue = total > Self.resultLimit
                ? "… 还有 \(total - Self.resultLimit) 条"
                : ""
            selectedIndex = previousIdentity.flatMap { identity in
                rows.firstIndex { $0.identity == identity && $0.isSelectable }
            } ?? rows.firstIndex(where: \.isSelectable)
        }
        let showsFooter = !footerLabel.stringValue.isEmpty
        footerLabel.isHidden = !showsFooter
        footerHeightConstraint?.constant = showsFooter ? 14 : 0
        footerBottomConstraint?.constant = showsFooter ? -5 : 0
        scrollFooterSpacingConstraint?.constant = showsFooter ? -4 : 0
        tableView.reloadData()
        let listHeight = min(CGFloat(rows.count) * 26 + 4, 200)
        window?.setContentSize(NSSize(
            width: 380,
            height: 35 + listHeight + (showsFooter ? 23 : 0)
        ))
        window?.contentView?.layoutSubtreeIfNeeded()
        if window?.isVisible == true { window?.center() }
        if let selectedIndex {
            tableView.selectRowIndexes([selectedIndex], byExtendingSelection: false)
            tableView.scrollRowToVisible(selectedIndex)
        } else {
            tableView.deselectAll(nil)
        }
    }

    private func moveSelection(by delta: Int) {
        let selectable = rows.indices.filter { rows[$0].isSelectable }
        guard !selectable.isEmpty else { return }
        guard let selectedIndex,
              let position = selectable.firstIndex(of: selectedIndex)
        else {
            self.selectedIndex = delta < 0 ? selectable.last : selectable.first
            return
        }
        self.selectedIndex = selectable[
            (position + delta + selectable.count) % selectable.count
        ]
        tableView.selectRowIndexes([self.selectedIndex!], byExtendingSelection: false)
        tableView.scrollRowToVisible(self.selectedIndex!)
    }

    private func openSelection() {
        guard let selectedIndex,
              rows.indices.contains(selectedIndex),
              let payload = rows[selectedIndex].payload
        else { return }
        switch payload {
        case .file(let file):
            dismiss()
            onOpen(file, nil)
        case let .location(file, offset):
            dismiss()
            onOpen(file, offset)
        case .command(let item):
            execute(item)
        }
    }

    private func execute(_ item: NSMenuItem) {
        dismiss()
        if let revalidateForTesting {
            revalidateForTesting(item)
        } else {
            item.menu?.update()
        }
        guard !item.isHidden,
              item.action != nil,
              item.isEnabled
        else { return }
        if let sendActionForTesting {
            sendActionForTesting(item.action!, item.target, item)
        } else {
            NSApp.sendAction(item.action!, to: item.target, from: item)
        }
    }

    private func dismiss(restoreFocus: Bool = true) {
        symbolModel.reset()
        window?.orderOut(nil)
        if restoreFocus, let restoreFocusForTesting {
            restoreFocusForTesting()
            return
        }
        guard restoreFocus, let ownerWindow else { return }
        ownerWindow.makeKey()
        ownerWindow.makeFirstResponder(originalResponder)
    }

    private var selectedProjectPath: String? {
        guard let rawRoot = appModel.fileTree?.root,
              let rawFile = appModel.selectedFile
        else { return nil }
        let root = rawRoot.resolvingSymlinksInPath()
        let file = rawFile.resolvingSymlinksInPath()
        guard file.pathComponents.starts(with: root.pathComponents) else { return nil }
        return file.pathComponents.dropFirst(root.pathComponents.count)
            .joined(separator: "/")
    }

    private func observeSymbolModel() {
        withObservationTracking {
            _ = symbolModel.rows
            _ = symbolModel.selectedIndex
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if Mode.parse(input.stringValue).mode == .projectSymbol {
                    installProjectSymbolRows()
                }
                observeSymbolModel()
            }
        }
    }

    static func fileRows(
        query: String,
        tree: FileTreeModel?,
        tabs: [URL]
    ) -> [Row] {
        guard let tree else { return [] }
        let files = flatten(tree.children)
        let relative = Dictionary(uniqueKeysWithValues: files.map {
            ($0.standardizedFileURL, relativePath($0, root: tree.root))
        })
        let ordered: [URL]
        if query.isEmpty {
            var seen: Set<URL> = []
            let open = tabs.map(\.standardizedFileURL).filter {
                relative[$0] != nil && seen.insert($0).inserted
            }
            let remaining = files.map(\.standardizedFileURL).filter {
                seen.insert($0).inserted
            }.sorted { fileSortKey(relative[$0]!) < fileSortKey(relative[$1]!) }
            ordered = open + remaining
        } else {
            ordered = files.filter {
                contains($0.lastPathComponent, query: query)
            }.sorted {
                let lhs = relative[$0.standardizedFileURL]!
                let rhs = relative[$1.standardizedFileURL]!
                let lhsPrefix = hasPrefix($0.lastPathComponent, query: query)
                let rhsPrefix = hasPrefix($1.lastPathComponent, query: query)
                if lhsPrefix != rhsPrefix { return lhsPrefix }
                return fileSortKey(lhs) < fileSortKey(rhs)
            }
        }
        let disambiguation = parentDisambiguation(
            ordered,
            relativePaths: relative
        )
        return ordered.map { file in
            let path = relative[file.standardizedFileURL]!
            return Row(
                title: file.lastPathComponent,
                detail: disambiguation[file.standardizedFileURL]
                    ?? parentPath(path),
                shortcut: "",
                identity: "file:\(file.standardizedFileURL.path)",
                payload: .file(file)
            )
        }
    }

    static func currentSymbolRows(
        query: String,
        document: ReaderDocument,
        file: URL
    ) -> [Row] {
        guard !query.isEmpty else { return [] }
        let kindOrder: [OutlineKind: Int] = Dictionary(uniqueKeysWithValues: [
            OutlineKind.mod, .trait, .impl, .struct, .enum, .typeAlias,
            .const, .static, .fn, .method,
        ].enumerated().map { ($0.element, $0.offset) })
        return document.outlineFacets.filter {
            contains($0.name, query: query)
        }.sorted { lhs, rhs in
            let lhsPrefix = hasPrefix(lhs.name, query: query)
            let rhsPrefix = hasPrefix(rhs.name, query: query)
            if lhsPrefix != rhsPrefix { return lhsPrefix }
            let lhsKind = kindOrder[lhs.kind] ?? .max
            let rhsKind = kindOrder[rhs.kind] ?? .max
            if lhsKind != rhsKind { return lhsKind < rhsKind }
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return lhs.range.lowerBound < rhs.range.lowerBound
        }.map { facet in
            let line = document.lineTable.lineColumn(at: facet.nameRange.lowerBound)?.line
            return Row(
                title: facet.name,
                detail: "\(facet.kind.rawValue) · line \(line ?? 1)",
                shortcut: "",
                identity: "current:\(facet.kind.rawValue):\(facet.nameRange.lowerBound)",
                payload: .location(file, facet.nameRange.lowerBound)
            )
        }
    }

    static func lineRows(
        query: String,
        document: ReaderDocument,
        file: URL
    ) -> (rows: [Row], message: String) {
        guard !query.isEmpty else { return ([], "Type a line number") }
        guard let requested = Int(query), requested > 0 else {
            return ([], "Enter a positive line number")
        }
        let last = document.lineTable.lineStarts.count
        let line = min(requested, last)
        let detail = requested > last
            ? "Line \(requested) is past the end · using \(last)"
            : "Line \(line)"
        return ([Row(
            title: "Go to line \(line)",
            detail: detail,
            shortcut: "↩",
            identity: "line:\(line)",
            payload: .location(file, document.lineTable.lineStarts[line - 1])
        )], "")
    }

    static func commandRows(in menu: NSMenu?) -> [Row] {
        guard let menu else { return [] }
        var result: [Row] = []
        collectCommands(in: menu, path: [], into: &result)
        return result.sorted {
            let lhsDepth = $0.title.components(separatedBy: " ▸ ").count
            let rhsDepth = $1.title.components(separatedBy: " ▸ ").count
            if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
            return $0.title < $1.title
        }
    }

    static func filterCommandRows(_ rows: [Row], query: String) -> [Row] {
        guard !query.isEmpty else { return rows }
        return rows.filter {
            contains($0.title, query: query)
        }.sorted {
            let lhsLeaf = $0.title.components(separatedBy: " ▸ ").last ?? $0.title
            let rhsLeaf = $1.title.components(separatedBy: " ▸ ").last ?? $1.title
            let lhsPrefix = hasPrefix(lhsLeaf, query: query)
            let rhsPrefix = hasPrefix(rhsLeaf, query: query)
            if lhsPrefix != rhsPrefix { return lhsPrefix }
            let lhsDepth = $0.title.components(separatedBy: " ▸ ").count
            let rhsDepth = $1.title.components(separatedBy: " ▸ ").count
            if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
            return $0.title < $1.title
        }
    }

    private static func collectCommands(
        in menu: NSMenu,
        path: [String],
        into result: inout [Row]
    ) {
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
        for item in menu.items where !item.isSeparatorItem && !item.isHidden {
            let component = if path.isEmpty, let submenu = item.submenu {
                submenu.title
            } else if item.title.isEmpty {
                item.submenu?.title ?? ""
            } else {
                item.title
            }
            let nextPath = component.isEmpty ? path : path + [component]
            if let submenu = item.submenu {
                collectCommands(in: submenu, path: nextPath, into: &result)
                continue
            }
            guard item.action != nil,
                  item.isEnabled,
                  !isEditingCommand(item)
            else { continue }
            let title = nextPath.joined(separator: " ▸ ")
            result.append(Row(
                title: title,
                detail: "",
                shortcut: shortcutText(for: item),
                identity: "command:\(title)",
                payload: .command(item)
            ))
        }
    }

    private static func isEditingCommand(_ item: NSMenuItem) -> Bool {
        let actions = [
            "cut:", "copy:", "paste:", "selectAll:",
            "deleteBackward:", "undo:", "redo:",
        ]
        return item.action.map { actions.contains(NSStringFromSelector($0)) } == true
    }

    private static func shortcutText(for item: NSMenuItem) -> String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        let mask = item.keyEquivalentModifierMask
        var result = ""
        if mask.contains(.control) { result += "⌃" }
        if mask.contains(.option) { result += "⌥" }
        if mask.contains(.shift) { result += "⇧" }
        if mask.contains(.command) { result += "⌘" }
        let key = item.keyEquivalent
        result += key.count == 1 ? key.uppercased() : key
        return result
    }

    private static func flatten(_ nodes: [FileTreeNode]) -> [URL] {
        nodes.flatMap { $0.isDirectory ? flatten($0.children) : [$0.url] }
    }

    private static func relativePath(_ file: URL, root: URL) -> String {
        let file = file.resolvingSymlinksInPath()
        let root = root.resolvingSymlinksInPath()
        return file.pathComponents.dropFirst(root.pathComponents.count)
            .joined(separator: "/")
    }

    private static func fileSortKey(_ path: String) -> (Int, String) {
        (path.split(separator: "/").count, path)
    }

    private static func parentPath(_ relativePath: String) -> String {
        let parent = relativePath.split(separator: "/").dropLast()
        return parent.isEmpty ? "./" : parent.joined(separator: "/") + "/"
    }

    private static func parentDisambiguation(
        _ files: [URL],
        relativePaths: [URL: String]
    ) -> [URL: String] {
        var result: [URL: String] = [:]
        for group in Dictionary(grouping: files, by: \.lastPathComponent).values {
            guard group.count > 1 else { continue }
            let parents = group.map { file in
                relativePaths[file.standardizedFileURL]!
                    .split(separator: "/").dropLast().map(String.init)
            }
            for (index, file) in group.enumerated() {
                if parents[index].isEmpty {
                    result[file.standardizedFileURL] = "./"
                    continue
                }
                for depth in 1...parents[index].count {
                    let suffix = parents[index].suffix(depth).joined(separator: "/")
                    let unique = parents.indices.filter { other in
                        parents[other].suffix(depth).joined(separator: "/") == suffix
                    }.count == 1
                    if unique || depth == parents[index].count {
                        result[file.standardizedFileURL] = suffix + "/"
                        break
                    }
                }
            }
        }
        return result
    }

    private static func contains(_ value: String, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return ((try? literalRanges(
            Array(query.utf8),
            in: Array(value.utf8),
            caseSensitive: false,
            maximumMatches: 1
        )) ?? []).isEmpty == false
    }

    private static func hasPrefix(_ value: String, query: String) -> Bool {
        let value = Array(value.utf8)
        let query = Array(query.utf8)
        guard query.count <= value.count else { return false }
        return query.indices.allSatisfy {
            asciiFold(value[$0]) == asciiFold(query[$0])
        }
    }
}

private final class PaletteTableRowView: NSTableRowView {
    private let selectionColor: NSColor

    init(selectionColor: NSColor) {
        self.selectionColor = selectionColor
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        selectionColor.setFill()
        bounds.fill()
    }
}
