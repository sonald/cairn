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
    private static let indexItemIdentifier = NSToolbarItem.Identifier("IndexStatus")

    let model: AppModel
    private let sidebarController = SidebarViewController()
    private let readerController = ReaderViewController()
    private let contextController: ContextWindowViewController
    private let projectLabel = NSTextField(labelWithString: "CodeInsight")
    private let indexLabel = NSTextField(labelWithString: "")
    private var displayedGeneration: UInt64?
    private var displayedNavigationGeneration: UInt64?
    private var symbolSearchPanel: SymbolSearchPanel?

    init(model: AppModel, offscreen: Bool) {
        self.model = model
        contextController = ContextWindowViewController(model: model.contextWindow)
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
        readerController.onTokenClick = { [weak self] offset, commandClick in
            self?.handleReaderClick(offset: offset, commandClick: commandClick)
        }
        contextController.onOpen = { [weak self] candidate in
            self?.open(candidate)
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

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            Self.backItemIdentifier,
            Self.forwardItemIdentifier,
            Self.projectItemIdentifier,
            .flexibleSpace,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            Self.backItemIdentifier,
            Self.forwardItemIdentifier,
            Self.projectItemIdentifier,
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
            _ = model.fileTree
            _ = model.selectedFile
            _ = model.navigationGeneration
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.render()
                self?.observe()
            }
        }
    }

    private func render() {
        if displayedGeneration != model.generation {
            sidebarController.display(model.fileTree)
            displayedGeneration = model.generation
        }
        readerController.display(model.selectedFile)
        if displayedNavigationGeneration != model.navigationGeneration {
            if let file = model.selectedFile, let offset = model.selectedByteOffset {
                readerController.navigate(to: file, byteOffset: offset)
            }
            displayedNavigationGeneration = model.navigationGeneration
        }
        projectLabel.stringValue = model.fileTree?.root.lastPathComponent ?? "CodeInsight"

        guard let toolbar = window?.toolbar else { return }
        switch model.projectState {
        case .indexing:
            indexLabel.stringValue = "Indexing \(model.fileTree?.fileCount ?? 0) files…"
            if toolbar.items.allSatisfy({ $0.itemIdentifier != Self.indexItemIdentifier }) {
                toolbar.insertItem(
                    withItemIdentifier: Self.indexItemIdentifier,
                    at: toolbar.items.count
                )
            }
        default:
            if let index = toolbar.items.firstIndex(where: {
                $0.itemIdentifier == Self.indexItemIdentifier
            }) {
                toolbar.removeItem(at: index)
            }
        }
        toolbar.validateVisibleItems()
        symbolSearchPanel?.refreshProjectState()
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

    private func open(_ candidate: ContextWindowModel.Candidate) {
        guard let root = model.fileTree?.root else { return }
        navigate(
            to: root.appendingPathComponent(candidate.path),
            byteOffset: candidate.targetByteOffset
        )
    }

    private func navigate(to file: URL, byteOffset: UInt32? = nil) {
        model.navigate(
            to: file,
            byteOffset: byteOffset,
            leaving: currentJumpRecord()
        )
    }

    private func currentJumpRecord() -> JumpRecord? {
        guard case let .ready(session, _) = model.projectState,
              let position = readerController.currentReadingPosition(),
              let path = projectPath(for: position.file)
        else { return nil }
        return JumpRecord(
            path: path,
            contentID: position.contentID,
            byteOffset: position.byteOffset,
            line: position.line,
            column: position.column,
            symbolAnchor: position.symbolAnchor,
            snapshotID: session.snapshotID
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
    NSOutlineViewDataSource, NSOutlineViewDelegate
{
    var onOpenFile: ((URL) -> Void)?
    private let outlineView = NSOutlineView()
    private var tree: FileTreeModel?

    override func loadView() {
        let column = NSTableColumn(identifier: .init("File"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.dataSource = self
        outlineView.delegate = self

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        view = scrollView
    }

    func display(_ tree: FileTreeModel?) {
        self.tree = tree
        loadViewIfNeeded()
        outlineView.reloadData()
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        numberOfChildrenOfItem item: Any?
    ) -> Int {
        (item as? FileTreeNode)?.children.count ?? tree?.children.count ?? 0
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        child index: Int,
        ofItem item: Any?
    ) -> Any {
        (item as? FileTreeNode)?.children[index] ?? tree!.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileTreeNode)?.isDirectory == true
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
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
        guard outlineView.selectedRow >= 0,
              let node = outlineView.item(atRow: outlineView.selectedRow) as? FileTreeNode,
              !node.isDirectory
        else { return }
        onOpenFile?(node.url)
    }
}

@MainActor
final class ReaderViewController: NSViewController {
    var onTokenClick: ((UInt32, Bool) -> Void)?
    private let label = NSTextField(labelWithString: "Open a project to begin")
    private let textView = ReaderTextView()
    private let loader = DocumentLoader()
    private var displayedFile: URL?
    private var displayedDocument: ReaderDocument?
    private var loadGeneration: UInt64 = 0

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
            let meaningful = modifiers.intersection([.command, .option, .control, .shift])
            if meaningful.isEmpty {
                self.onTokenClick?(offset, false)
            } else if meaningful == .command {
                self.onTokenClick?(offset, true)
            }
        }
    }

    func display(_ file: URL?) {
        loadViewIfNeeded()
        guard file != displayedFile else { return }
        displayedFile = file
        loadGeneration &+= 1
        let generation = loadGeneration

        guard let file else {
            displayedDocument = nil
            label.stringValue = "Open a project to begin"
            label.isHidden = false
            textView.view.string = ""
            return
        }

        do {
            let loaded = try loader.load(file: file)
            displayedDocument = loaded.document
            label.isHidden = true
            layoutTextViewFrame()
            textView.display(document: loaded.document)
            textView.view.textLayoutManager?
                .textViewportLayoutController.layoutViewport()
            if loaded.tier != .regular {
                loader.loadSyntax(for: loaded.document) { [weak self] result in
                    Task { @MainActor [weak self] in
                        guard let self, self.loadGeneration == generation else { return }
                        switch result {
                        case let .success(document):
                            self.displayedDocument = document
                            self.textView.updateSyntax(document: document)
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

    func navigate(to file: URL, byteOffset: UInt32) {
        display(file)
        textView.reveal(byteOffset: byteOffset)
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
            contentID: ContentID.sha256(of: document.bytes),
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
