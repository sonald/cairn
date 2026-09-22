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
        /// `expectedContentID` carries the indexed identity for project-symbol
        /// locations; rows produced from the displayed document pass nil.
        case location(URL, UInt32, expectedContentID: ContentID?)
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
    private static let rowHeight: CGFloat = 30
    private static let resultsChromeHeight: CGFloat = 85
    private let appModel: AppModel
    private let symbolModel = SymbolSearchPanelModel()
    private var lockedMode: (mode: Mode, prefix: String)?
    private let onOpen: (URL, UInt32?, ContentID?) -> Void
    private let input = NSTextField()
    private let modeLabel = NSTextField(labelWithString: "⌘P")
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private let footerLabel = NSTextField(labelWithString: "")
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
        onOpen: @escaping (URL, UInt32?, ContentID?) -> Void
    ) {
        self.appModel = appModel
        self.onOpen = onOpen
        theme = ReaderTheme(settings: settings)
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 325),
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

    func show(
        prefill: String,
        lockMode: Bool = false,
        relativeTo owner: NSWindow?
    ) {
        prepare(
            prefill: prefill,
            lockMode: lockMode,
            owner: owner,
            commands: Self.commandRows(in: NSApp.mainMenu)
        )
        guard let panel = window else { return }
        positionPanel()
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
        hintLabel.textColor = theme.chromeTertiaryColor
        emptyLabel.textColor = theme.chromeTertiaryColor
        modeLabel.textColor = theme.chromeTertiaryColor
        tableView.backgroundColor = theme.backgroundColor
        tableView.reloadData()
    }

    func refreshProjectState() {
        guard window?.isVisible == true else { return }
        refreshRows()
    }

    var rowsForTesting: [Row] { rows }
    var tableViewForTesting: NSTableView { tableView }
    var emptyMessageForTesting: String { emptyLabel.stringValue }
    var inputFrameForTesting: NSRect { input.convert(input.bounds, to: nil) }
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
        commands: [Row],
        lockMode: Bool = false
    ) {
        prepare(
            prefill: prefill,
            lockMode: lockMode,
            owner: owner,
            commands: commands
        )
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

        title.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        cell.textField = title
        cell.toolTip = switch value.payload {
        case .file(let file): file.path
        case .location(let file, _, _): file.path + " · " + value.detail
        default: value.title
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
            title.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])

        var trailingAnchor = cell.trailingAnchor
        if !value.shortcut.isEmpty {
            let shortcut = NSTextField(labelWithString: value.shortcut)
            shortcut.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            shortcut.textColor = theme.chromeTertiaryColor
            shortcut.alignment = .right
            shortcut.setContentCompressionResistancePriority(.required, for: .horizontal)
            shortcut.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(shortcut)
            NSLayoutConstraint.activate([
                shortcut.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                shortcut.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            ])
            trailingAnchor = shortcut.leadingAnchor
        }
        if !value.detail.isEmpty {
            let detail = NSTextField(labelWithString: value.detail)
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = theme.chromeTertiaryColor
            detail.alignment = .right
            detail.lineBreakMode = .byTruncatingHead
            detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            detail.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(detail)
            NSLayoutConstraint.activate([
                detail.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 12),
                detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                detail.centerYAnchor.constraint(equalTo: title.centerYAnchor),
                detail.widthAnchor.constraint(lessThanOrEqualTo: cell.widthAnchor, multiplier: 0.5),
            ])
        } else {
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12).isActive = true
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        Self.rowHeight
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
        modeLabel.setAccessibilityLabel(localized("panel.palette.shortcut"))
        modeLabel.translatesAutoresizingMaskIntoConstraints = false

        input.placeholderString = localized("panel.palette.open")
        input.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        input.isBordered = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.delegate = self
        input.setAccessibilityLabel(localized("panel.palette.quickOpen"))
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
        tableView.style = .plain
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = Self.rowHeight
        tableView.usesAutomaticRowHeights = false
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.intercellSpacing = .zero
        tableView.setAccessibilityLabel(localized("panel.palette.results"))

        scrollView.documentView = tableView
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = .init()
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.setAccessibilityLabel(localized("panel.palette.status"))

        hintLabel.font = .systemFont(ofSize: 10.5)
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        footerLabel.font = .systemFont(ofSize: 10.5)
        footerLabel.alignment = .right
        footerLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        footerLabel.setAccessibilityLabel(localized("panel.palette.limit"))
        footerLabel.translatesAutoresizingMaskIntoConstraints = false

        for view in [modeLabel, input, separator, scrollView, emptyLabel, hintLabel, footerLabel] {
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            input.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            input.topAnchor.constraint(equalTo: content.topAnchor, constant: 11),
            input.heightAnchor.constraint(equalToConstant: 22),
            input.trailingAnchor.constraint(equalTo: modeLabel.leadingAnchor, constant: -12),
            modeLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            modeLabel.centerYAnchor.constraint(equalTo: input.centerYAnchor),
            modeLabel.widthAnchor.constraint(equalToConstant: 44),
            separator.topAnchor.constraint(equalTo: content.topAnchor, constant: 44),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: hintLabel.topAnchor, constant: -8),
            emptyLabel.leadingAnchor.constraint(equalTo: input.leadingAnchor),
            emptyLabel.trailingAnchor.constraint(equalTo: input.trailingAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            hintLabel.leadingAnchor.constraint(equalTo: input.leadingAnchor),
            hintLabel.trailingAnchor.constraint(lessThanOrEqualTo: footerLabel.leadingAnchor, constant: -8),
            hintLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
            hintLabel.heightAnchor.constraint(equalToConstant: 16),
            footerLabel.trailingAnchor.constraint(equalTo: modeLabel.trailingAnchor),
            footerLabel.centerYAnchor.constraint(equalTo: hintLabel.centerYAnchor),
        ])
    }

    private func prepare(
        prefill: String,
        lockMode: Bool,
        owner: NSWindow?,
        commands: [Row]
    ) {
        if let ownerWindow {
            NotificationCenter.default.removeObserver(self, name: nil, object: ownerWindow)
        }
        ownerWindow = owner
        if let owner {
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                         NSWindow.didChangeScreenNotification] {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(ownerGeometryChanged(_:)), name: name, object: owner
                )
            }
        }
        originalResponder = owner?.firstResponder
        capturedCommands = commands
        lockedMode = lockMode
            ? (Mode.parse(prefill).mode, String(prefill.prefix(1)))
            : nil
        input.stringValue = prefill
        refreshRows()
    }

    private func refreshRows() {
        let raw = input.stringValue.trimmingCharacters(in: .whitespaces)
        let parsed: (mode: Mode, query: String) = if let lockedMode {
            (
                lockedMode.mode,
                raw.hasPrefix(lockedMode.prefix)
                    ? String(raw.dropFirst())
                    : raw
            )
        } else {
            Mode.parse(input.stringValue)
        }
        modeLabel.stringValue = switch parsed.mode {
        case .file: "⌘P"
        case .command: "⇧⌘P"
        case .currentSymbol: "@"
        case .projectSymbol: "⌘T"
        case .line: "⌘L"
        }
        input.placeholderString = switch parsed.mode {
        case .file: localized("panel.palette.open")
        case .command: localized("panel.palette.command")
        case .currentSymbol: localized("panel.palette.fileSymbol")
        case .projectSymbol: localized("panel.palette.projectSymbol")
        case .line: localized("panel.palette.line")
        }
        hintLabel.stringValue = lockedMode == nil
            ? localized("panel.palette.hint")
            : localized("panel.palette.navigation")
        switch parsed.mode {
        case .file:
            symbolModel.reset()
            install(Self.fileRows(
                query: parsed.query,
                tree: appModel.fileTree,
                tabs: appModel.tabStrip.tabs.compactMap(\.fileURL)
            ), emptyMessage: appModel.fileTree == nil ? localized("panel.palette.noProject") : localized("panel.palette.noFiles"))
        case .command:
            symbolModel.reset()
            install(Self.filterCommandRows(capturedCommands, query: parsed.query),
                    emptyMessage: localized("panel.palette.noCommands"))
        case .currentSymbol:
            symbolModel.reset()
            guard let document = appModel.tabStrip.activeDocument,
                  let file = appModel.selectedFile
            else {
                install([], emptyMessage: fileModeUnavailableMessage)
                return
            }
            install(Self.currentSymbolRows(
                query: parsed.query,
                document: document,
                file: file
            ), emptyMessage: parsed.query.isEmpty
                ? localized("panel.palette.enterSymbol")
                : localized("panel.palette.noSymbols"))
        case .projectSymbol:
            guard !parsed.query.isEmpty else {
                symbolModel.reset()
                install([], emptyMessage: localized("panel.palette.enterProjectSymbol"))
                return
            }
            let sessions = appModel.querySessions
            if sessions.isEmpty {
                symbolModel.updateQuery(
                    parsed.query,
                    projectState: appModel.projectState,
                    currentPath: selectedProjectPath
                )
            } else {
                symbolModel.updateQuery(
                    parsed.query,
                    sessions: sessions,
                    currentPath: selectedProjectPath
                )
            }
            installProjectSymbolRows()
        case .line:
            symbolModel.reset()
            guard let document = appModel.tabStrip.activeDocument,
                  let file = appModel.selectedFile
            else {
                install([], emptyMessage: fileModeUnavailableMessage)
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

    private var fileModeUnavailableMessage: String {
        guard let tab = appModel.tabStrip.activeTab,
              tab.fileURL == nil
        else { return localized("panel.palette.noFile") }
        return localized("panel.palette.readingSetNoFile")
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
                    hit.facet.nameRange.lowerBound,
                    expectedContentID: appModel.indexedContentID(forPath: hit.path)
                )
            )
        }
        let placeholder = symbolModel.rows.compactMap { row -> String? in
            if case let .placeholder(message) = row { return message }
            return nil
        }.first
        install(candidates, emptyMessage: placeholder ?? localized("panel.palette.noProjectSymbols"))
    }

    private func install(_ candidates: [Row], emptyMessage: String) {
        let previousIdentity = selectedIndex.flatMap {
            rows.indices.contains($0) ? rows[$0].identity : nil
        }
        let total = candidates.count
        rows = Array(candidates.prefix(Self.resultLimit))
        emptyLabel.stringValue = rows.isEmpty ? emptyMessage : ""
        emptyLabel.isHidden = !rows.isEmpty
        scrollView.isHidden = rows.isEmpty
        footerLabel.stringValue = total > Self.resultLimit
            ? localizedFormat("panel.palette.more", Int64(total - Self.resultLimit))
            : ""
        footerLabel.isHidden = footerLabel.stringValue.isEmpty
        selectedIndex = previousIdentity.flatMap { identity in
            rows.firstIndex { $0.identity == identity && $0.isSelectable }
        } ?? rows.firstIndex(where: \.isSelectable)
        tableView.reloadData()
        positionPanel()
        if let selectedIndex {
            tableView.selectRowIndexes([selectedIndex], byExtendingSelection: false)
            tableView.scrollRowToVisible(selectedIndex)
        } else {
            tableView.deselectAll(nil)
        }
    }

    /// Screen coordinates; resizing results keeps the input's top edge fixed.
    static func frame(relativeTo ownerContent: NSRect, visibleFrame: NSRect, height: CGFloat) -> NSRect {
        let safe = visibleFrame.insetBy(dx: 8, dy: 8)
        let intersection = ownerContent.intersection(visibleFrame)
        let area = intersection.isEmpty ? visibleFrame : intersection
        let width = min(max(1, area.width - 48), min(760, max(560, area.width * 0.5)))
        let minimumTop = safe.minY + min(safe.height, Self.resultsChromeHeight + Self.rowHeight)
        let top = min(safe.maxY, max(minimumTop, area.maxY - area.height * 0.15))
        let height = min(height, max(1, top - safe.minY))
        return NSRect(
            x: min(max(area.midX - width / 2, safe.minX), safe.maxX - width),
            y: top - height,
            width: width,
            height: height
        )
    }

    @objc private func ownerGeometryChanged(_ notification: Notification) {
        guard window?.isVisible == true else { return }
        positionPanel()
    }

    private func positionPanel() {
        guard let panel = window else { return }
        let visibleFrame = (ownerWindow?.screen ?? panel.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let ownerContent = ownerWindow.map { $0.convertToScreen($0.contentLayoutRect) }
            ?? visibleFrame
        let resultHeight = rows.isEmpty ? 48 : CGFloat(min(rows.count, 8)) * Self.rowHeight
        var frame = Self.frame(
            relativeTo: ownerContent,
            visibleFrame: visibleFrame,
            height: Self.resultsChromeHeight + resultHeight
        )
        if !rows.isEmpty {
            let fittingRows = max(1, floor((frame.height - Self.resultsChromeHeight) / Self.rowHeight))
            let height = Self.resultsChromeHeight + fittingRows * Self.rowHeight
            frame.origin.y += frame.height - height
            frame.size.height = height
        }
        scrollView.hasVerticalScroller = CGFloat(rows.count) * Self.rowHeight
            > frame.height - Self.resultsChromeHeight
        scrollView.verticalScrollElasticity = scrollView.hasVerticalScroller ? .automatic : .none
        panel.setFrame(frame, display: true)
        panel.contentView?.layoutSubtreeIfNeeded()
        tableView.sizeLastColumnToFit()
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
            onOpen(file, nil, nil)
        case let .location(file, offset, expectedContentID):
            dismiss()
            onOpen(file, offset, expectedContentID)
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
        NSApp.activate(ignoringOtherApps: true)
        ownerWindow.makeKeyAndOrderFront(nil)
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
                if Mode.parse(self.input.stringValue).mode == .projectSymbol {
                    self.installProjectSymbolRows()
                }
                self.observeSymbolModel()
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
                contains(relative[$0.standardizedFileURL]!, query: query)
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
            OutlineKind.mod, .trait, .impl, .struct, .class, .enum, .typeAlias,
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
                detail: localizedFormat("panel.palette.symbolLine", localized("panel.symbol.kind." + facet.kind.rawValue), Int64(line ?? 1)),
                shortcut: "",
                identity: "current:\(facet.kind.rawValue):\(facet.nameRange.lowerBound)",
                payload: .location(file, facet.nameRange.lowerBound, expectedContentID: nil)
            )
        }
    }

    static func lineRows(
        query: String,
        document: ReaderDocument,
        file: URL
    ) -> (rows: [Row], message: String) {
        guard !query.isEmpty else { return ([], localized("panel.palette.enterLine")) }
        guard let requested = Int(query), requested > 0 else {
            return ([], localized("panel.palette.positiveLine"))
        }
        let last = document.lineTable.lineStarts.count
        let line = min(requested, last)
        let detail = requested > last
            ? localizedFormat("panel.palette.pastEnd", Int64(requested), Int64(last))
            : localizedFormat("panel.palette.lineNumber", Int64(line))
        return ([Row(
            title: localizedFormat("panel.palette.goToLine", Int64(line)),
            detail: detail,
            shortcut: "↩",
            identity: "line:\(line)",
            payload: .location(
                file,
                document.lineTable.lineStarts[line - 1],
                expectedContentID: nil
            )
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
