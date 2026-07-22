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
    private static let exactItemIdentifier = NSToolbarItem.Identifier("ExactStatus")

    let model: AppModel
    private let sidebarController = SidebarViewController()
    private let readerController = ReaderViewController()
    private let secondaryReaderController = ReaderViewController(showsCompareControls: true)
    private let contextController: ContextWindowViewController
    private let relationController: RelationWindowController
    private let contentSplitController = NSSplitViewController()
    private let upperSplitController = NSSplitViewController()
    private let readerSplitController = NSSplitViewController()
    private let sidebarItem: NSSplitViewItem
    private let readerGroupItem: NSSplitViewItem
    private let secondaryReaderItem: NSSplitViewItem
    private let contextItem: NSSplitViewItem
    private let relationItem: NSSplitViewItem
    private let projectLabel = NSTextField(labelWithString: "CodeInsight")
    private let commitButton = NSButton()
    private let indexLabel = NSTextField(labelWithString: "")
    private let exactLabel = NSTextField(labelWithString: "Exact: off (Safe)")
    private var displayedGeneration: UInt64?
    private var displayedSnapshotID: SnapshotID?
    private var displayedNavigationGeneration: UInt64?
    private var symbolSearchPanel: SymbolSearchPanel?
    private var searchPanel: SearchPanel?
    private var commitPickerPopover: CommitPickerPopover?
    private var compareCommitPickerPopover: CommitPickerPopover?
    private var panelPreset = PanelPresetModel.reading

    init(model: AppModel, settings: ReaderSettings, offscreen: Bool) {
        self.model = model
        contextController = ContextWindowViewController(model: model.contextWindow)
        relationController = RelationWindowController(model: model.relationTree)
        relationController.view.frame.size.width = 300
        relationItem = NSSplitViewItem(viewController: relationController)
        sidebarItem = NSSplitViewItem(
            sidebarWithViewController: sidebarController
        )
        let primaryReaderItem = NSSplitViewItem(viewController: readerController)
        secondaryReaderItem = NSSplitViewItem(
            viewController: secondaryReaderController
        )
        readerGroupItem = NSSplitViewItem(viewController: readerSplitController)
        contextItem = NSSplitViewItem(viewController: contextController)

        contentSplitController.splitView.isVertical = false
        upperSplitController.splitView.isVertical = true
        readerSplitController.splitView.isVertical = true

        primaryReaderItem.minimumThickness = 300
        primaryReaderItem.canCollapse = false
        secondaryReaderItem.minimumThickness = 300
        secondaryReaderItem.canCollapse = true
        secondaryReaderItem.isCollapsed = true
        readerSplitController.addSplitViewItem(primaryReaderItem)
        readerSplitController.addSplitViewItem(secondaryReaderItem)

        sidebarItem.minimumThickness = 180
        sidebarItem.canCollapse = true
        readerGroupItem.minimumThickness = 300
        readerGroupItem.canCollapse = false
        relationItem.minimumThickness = 220
        relationItem.maximumThickness = 500
        relationItem.canCollapse = true
        upperSplitController.addSplitViewItem(sidebarItem)
        upperSplitController.addSplitViewItem(readerGroupItem)
        upperSplitController.addSplitViewItem(relationItem)
        relationItem.isCollapsed = true

        let upperItem = NSSplitViewItem(viewController: upperSplitController)
        upperItem.minimumThickness = 300
        contextItem.minimumThickness = 120
        contextItem.maximumThickness = 280
        contextItem.canCollapse = true
        contentSplitController.addSplitViewItem(upperItem)
        contentSplitController.addSplitViewItem(contextItem)

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
        window.contentViewController = contentSplitController
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
        sidebarController.onOpenFileInSecondary = { [weak self] url in
            self?.openInSecondaryReader(url)
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
        secondaryReaderController.onChooseCompareVersion = { [weak self] in
            self?.showCompareCommitPicker()
        }
        secondaryReaderController.onPreviousDiffHunk = { [weak self] in
            self?.previousDiffHunk(nil)
        }
        secondaryReaderController.onNextDiffHunk = { [weak self] in
            self?.nextDiffHunk(nil)
        }
        secondaryReaderController.onFunctionChange = { [weak self] change in
            self?.openFunctionChange(change)
        }
        contextController.onOpen = { [weak self] candidate in
            self?.open(candidate)
        }
        relationController.onOpen = { [weak self] path, offset in
            self?.open(path: path, byteOffset: offset)
        }
        applyReaderSettings(settings)
        render()
        applyPanelPreset(.reading)
        observe()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func openProject(root: URL) {
        model.openProject(root: root)
        render()
    }

    func selectFileInSidebar(_ file: URL) -> Bool {
        sidebarController.selectFile(file)
    }

    func openFileForSelfTest(_ file: URL) {
        navigate(to: file)
    }

    func selectCommit(_ revision: String) -> Bool {
        if commitPickerPopover == nil {
            commitPickerPopover = CommitPickerPopover(
                appModel: model,
                selectedRevision: { [weak model] in model?.currentRevision },
                onChoose: { [weak self] commit in
                    if let commit {
                        self?.model.switchToCommit(
                            commit.fullSHA,
                            leaving: self?.currentJumpRecord()
                        )
                    } else {
                        self?.model.switchToWorktree(leaving: self?.currentJumpRecord())
                    }
                }
            )
        }
        return commitPickerPopover?.chooseCommit(revision) == true
    }

    func selectCompareCommit(_ revision: String) -> Bool {
        prepareCompareCommitPicker()
        return compareCommitPickerPopover?.chooseCommit(revision) == true
    }

    var displayedReaderFile: URL? { readerController.displayedFile }
    var selectedSidebarFile: URL? { sidebarController.selectedFile }
    var readerHasReadingPosition: Bool {
        readerController.currentReadingPosition() != nil
    }
    var selfTestContextSummary: String? { contextController.selfTestSummary }
    var selfTestContextProvenance: String? {
        contextController.selfTestProvenance
    }
    var selfTestContextCandidateCount: Int {
        contextController.selfTestCandidateCount
    }
    var selfTestContextPinned: Bool { contextController.selfTestPinned }
    var selfTestExactStatusText: String { exactLabel.stringValue }
    var selfTestExactGroupTitle: String? {
        relationController.selfTestExactGroupTitle
    }
    var selfTestExactGroupRowCount: Int {
        relationController.selfTestExactGroupRowCount
    }
    var selfTestRightReaderBytes: [UInt8]? { secondaryReaderController.displayedBytes }
    var selfTestGutterCounts: [DiffCore.MarkerKind: Int] {
        let left = readerController.diffMarkerCounts
        let right = secondaryReaderController.diffMarkerCounts
        var counts = left
        for (kind, count) in right { counts[kind, default: 0] += count }
        return counts
    }
    var selfTestSelectedDiffLine: Int? {
        secondaryReaderController.selectedDiffLine ?? readerController.selectedDiffLine
    }
    var selfTestSecondaryReaderCollapsed: Bool { secondaryReaderItem.isCollapsed }

    func selfTestNavigateNextDiffHunk() -> (before: Int?, after: Int?) {
        guard let hunk = model.compare.diff?.hunks.first else { return (nil, nil) }
        if let target = hunk.lines.first(where: {
            $0.kind != .context && $0.rightLine != nil
        })?.rightLine {
            let lineCount = model.compare.diff?.rightLineCount ?? 0
            let prime = target == 1 ? lineCount : 1
            if prime > 0, prime != target {
                _ = secondaryReaderController.revealDiffLine(prime)
            }
            let before = secondaryReaderController.selectedDiffLine
            nextDiffHunk(nil)
            return (before, secondaryReaderController.selectedDiffLine)
        }
        if let target = hunk.lines.first(where: {
            $0.kind != .context && $0.leftLine != nil
        })?.leftLine {
            let lineCount = model.compare.diff?.leftLineCount ?? 0
            let prime = target == 1 ? lineCount : 1
            if prime > 0, prime != target {
                _ = readerController.revealDiffLine(prime)
            }
            let before = readerController.selectedDiffLine
            nextDiffHunk(nil)
            return (before, readerController.selectedDiffLine)
        }
        return (nil, nil)
    }

    func selfTestSetContextPinned(_ pinned: Bool) {
        contextController.selfTestSetPinned(pinned)
    }

    func selfTestReaderClick(offset: UInt32, commandClick: Bool) {
        handleReaderClick(offset: offset, commandClick: commandClick)
    }

    func selfTestReaderRelation(
        offset: UInt32,
        direction: RelationTreeModel.Direction
    ) {
        handleReaderRelation(offset: offset, direction: direction)
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

    func applyPanelPreset(_ preset: PanelPresetModel) {
        panelPreset = preset
        let layout = preset.layout
        sidebarItem.isCollapsed = layout.sidebarCollapsed
        readerGroupItem.isCollapsed = layout.readerCollapsed
        contextItem.isCollapsed = layout.contextCollapsed
        relationItem.isCollapsed = layout.relationsCollapsed
        secondaryReaderItem.isCollapsed = !layout.readerSplit

        sidebarItem.holdingPriority = .init(rawValue: 251)
        readerGroupItem.holdingPriority = .init(rawValue: 253)
        relationItem.holdingPriority = .init(rawValue: 250)
        contextItem.holdingPriority = .init(rawValue: 250)
        secondaryReaderItem.holdingPriority = .init(rawValue: 251)
        applyPanelSizes()
        DispatchQueue.main.async { [weak self] in self?.applyPanelSizes() }
    }

    func applyReaderSettings(_ settings: ReaderSettings) {
        readerController.apply(settings: settings)
        secondaryReaderController.apply(settings: settings)
        contextController.apply(settings: settings)
    }

    private func applyPanelSizes() {
        window?.contentView?.layoutSubtreeIfNeeded()
        let layout = panelPreset.layout
        let upperSplit = upperSplitController.splitView
        if !layout.sidebarCollapsed, upperSplit.bounds.width > 0 {
            upperSplit.setPosition(
                upperSplit.bounds.width * layout.sidebarFraction,
                ofDividerAt: 0
            )
        }
        if !layout.relationsCollapsed, upperSplit.bounds.width > 0 {
            upperSplit.setPosition(
                upperSplit.bounds.width * (1 - layout.relationsFraction),
                ofDividerAt: 1
            )
        }
        let contentSplit = contentSplitController.splitView
        if !layout.contextCollapsed, contentSplit.bounds.height > 0 {
            contentSplit.setPosition(
                contentSplit.bounds.height * (1 - layout.contextFraction),
                ofDividerAt: 0
            )
        }
        let readerSplit = readerSplitController.splitView
        if layout.readerSplit, readerSplit.bounds.width > 0 {
            readerSplit.setPosition(
                readerSplit.bounds.width * (1 - layout.secondaryReaderFraction),
                ofDividerAt: 0
            )
        }
    }

    private func openInSecondaryReader(_ file: URL) {
        navigate(to: file)
        applyPanelPreset(.compare)
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
            Self.exactItemIdentifier,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            Self.backItemIdentifier,
            Self.forwardItemIdentifier,
            Self.projectItemIdentifier,
            Self.commitItemIdentifier,
            Self.indexItemIdentifier,
            Self.exactItemIdentifier,
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
        case Self.exactItemIdentifier:
            item.label = "Exact Status"
            item.view = exactLabel
            exactLabel.font = .systemFont(ofSize: 11, weight: .semibold)
            exactLabel.setAccessibilityLabel("Exact provider status")
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
            _ = model.compare.rightRevision
            _ = model.compare.rightSnapshotID
            _ = model.compare.diff
            _ = model.compare.functionChanges
            _ = model.compare.selectedHunkIndex
            _ = model.compare.isLoading
            _ = model.compare.errorMessage
            _ = model.exactCoordinator.readiness
            _ = model.exactCoordinator.coverage
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
        if !sidebarController.synchronizeFileSelection(to: model.selectedFile) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                _ = sidebarController.synchronizeFileSelection(to: model.selectedFile)
            }
        }
        readerController.display(
            model.selectedFile,
            snapshotID: model.currentSnapshotID,
            source: model.documentSource
        )
        secondaryReaderController.display(
            model.compare.rightSnapshotID == nil ? nil : model.selectedFile,
            snapshotID: model.compare.rightSnapshotID,
            source: model.compare.rightSource
        )
        readerController.setDiffMarkers(model.compare.diff?.leftMarkers ?? [:])
        secondaryReaderController.setDiffMarkers(
            model.compare.diff?.rightMarkers ?? [:]
        )
        secondaryReaderController.configureCompareControls(
            versionTitle: compareVersionTitle,
            functionChanges: model.compare.functionChanges,
            selectedHunkIndex: model.compare.selectedHunkIndex,
            hunkCount: model.compare.diff?.hunks.count ?? 0,
            truncated: model.compare.diff?.truncated ?? false,
            errorMessage: model.compare.errorMessage
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
        renderExactStatus()

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

    private var compareVersionTitle: String {
        guard let revision = model.compare.rightRevision else {
            return "Choose comparison version…"
        }
        let commit = model.commitPicker.commits.first {
            $0.fullSHA == revision || $0.shortSHA == revision
        }
        let sha = commit?.shortSHA ?? String(revision.prefix(7))
        return commit.map { "⎇ \(sha) \(Self.truncated($0.summary, limit: 28))" }
            ?? "⎇ \(sha)"
    }

    private func renderExactStatus() {
        let status: String
        let color: NSColor
        let detail: String?
        switch model.exactCoordinator.readiness {
        case .ready:
            if model.exactCoordinator.coverage == .dependenciesUnavailableOffline {
                status = "Exact: deps unavailable (offline)"
                color = .systemOrange
                detail = "Dependency coverage is unavailable because network access is disabled."
            } else {
                status = "Exact: ready"
                color = .systemGreen
                detail = nil
            }
        case .preparing:
            status = "Exact: preparing"
            color = .secondaryLabelColor
            detail = nil
        case .unavailable(let reason):
            status = reason.localizedCaseInsensitiveContains("sandbox")
                ? "Exact: unavailable (sandbox)"
                : "Exact: unavailable"
            color = .systemRed
            detail = reason
        case .off(let reason):
            status = reason.localizedCaseInsensitiveContains("sandbox")
                ? "Exact: unavailable (sandbox)"
                : "Exact: off (Safe)"
            color = .systemOrange
            detail = reason
        }
        exactLabel.stringValue = status
        exactLabel.textColor = color
        exactLabel.toolTip = detail
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
            commitPickerPopover = CommitPickerPopover(
                appModel: model,
                selectedRevision: { [weak model] in model?.currentRevision },
                onChoose: { [weak self] commit in
                    if let commit {
                        self?.model.switchToCommit(
                            commit.fullSHA,
                            leaving: self?.currentJumpRecord()
                        )
                    } else {
                        self?.model.switchToWorktree(leaving: self?.currentJumpRecord())
                    }
                }
            )
        }
        commitPickerPopover?.show(relativeTo: sender)
    }

    private func showCompareCommitPicker() {
        prepareCompareCommitPicker()
        compareCommitPickerPopover?.show(
            relativeTo: secondaryReaderController.compareVersionAnchor
        )
    }

    private func prepareCompareCommitPicker() {
        guard compareCommitPickerPopover == nil else { return }
        compareCommitPickerPopover = CommitPickerPopover(
            appModel: model,
            allowsWorktree: false,
            selectedRevision: { [weak model] in model?.compare.rightRevision },
            onChoose: { [weak model] commit in
                guard let commit else { return }
                model?.selectCompareCommit(commit.fullSHA)
            }
        )
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

    @objc func previousDiffHunk(_ sender: Any?) {
        guard let hunk = model.compare.selectPreviousHunk() else { return }
        reveal(hunk)
    }

    @objc func nextDiffHunk(_ sender: Any?) {
        guard let hunk = model.compare.selectNextHunk() else { return }
        reveal(hunk)
    }

    private func reveal(_ hunk: DiffCore.Hunk) {
        if let line = hunk.lines.first(where: {
            $0.kind != .context && $0.rightLine != nil
        })?.rightLine {
            _ = secondaryReaderController.revealDiffLine(line)
        } else if let line = hunk.lines.first(where: {
            $0.kind != .context && $0.leftLine != nil
        })?.leftLine {
            _ = readerController.revealDiffLine(line)
        }
    }

    private func openFunctionChange(_ change: DiffCore.FunctionChange) {
        guard let file = model.selectedFile else { return }
        if let range = change.rightRange {
            secondaryReaderController.navigate(
                to: file,
                byteOffset: range.lowerBound,
                snapshotID: model.compare.rightSnapshotID,
                source: model.compare.rightSource
            )
        } else if let range = change.leftRange {
            readerController.navigate(
                to: file,
                byteOffset: range.lowerBound,
                snapshotID: model.currentSnapshotID,
                source: model.documentSource
            )
        }
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
                  let candidate = await model.contextWindow.resolvedCandidate(
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
        switch model.projectState {
        case .empty, .failed:
            return nil
        case .indexing, .ready:
            break
        }
        guard let selectedFile = model.selectedFile,
              let path = projectPath(for: selectedFile)
        else { return nil }
        guard let position = readerController.currentReadingPosition(
            fallbackByteOffset: model.selectedByteOffset
        ), position.file.standardizedFileURL == selectedFile.standardizedFileURL
        else {
            return JumpRecord(
                path: path,
                contentID: nil,
                byteOffset: model.selectedByteOffset ?? 0,
                line: 0,
                column: 0,
                symbolAnchor: nil,
                snapshotID: model.currentSnapshotID
            )
        }
        return JumpRecord(
            path: path,
            contentID: position.contentID,
            byteOffset: position.byteOffset,
            line: position.line,
            column: position.column,
            symbolAnchor: position.symbolAnchor,
            snapshotID: model.currentSnapshotID
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
    var onOpenFileInSecondary: ((URL) -> Void)?
    var onOpenOutline: ((UInt32) -> Void)?
    private let fileOutlineView = NSOutlineView()
    private let symbolOutlineView = NSOutlineView()
    private let splitView = NSSplitView()
    private let outlineModel = OutlinePanelModel()
    private var tree: FileTreeModel?
    private var facetRows: [NSNumber] = []
    private var setInitialDivider = false
    private var isSynchronizingFileSelection = false

    override func loadView() {
        configure(fileOutlineView, column: "File")
        configure(symbolOutlineView, column: "Symbol")
        symbolOutlineView.indentationPerLevel = 0
        symbolOutlineView.target = self
        symbolOutlineView.action = #selector(openOutlineRow(_:))

        let fileMenu = NSMenu(title: "Open File")
        let openLeft = NSMenuItem(
            title: "Open in Left Reader",
            action: #selector(openFileInLeftReader(_:)),
            keyEquivalent: ""
        )
        openLeft.target = self
        fileMenu.addItem(openLeft)
        let openRight = NSMenuItem(
            title: "Open in Right Reader (Compare)",
            action: #selector(openFileInRightReader(_:)),
            keyEquivalent: ""
        )
        openRight.target = self
        fileMenu.addItem(openRight)
        fileOutlineView.menu = fileMenu

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

    @discardableResult
    func synchronizeFileSelection(to file: URL?) -> Bool {
        loadViewIfNeeded()
        isSynchronizingFileSelection = true
        defer { isSynchronizingFileSelection = false }
        guard let path = tree?.selectionPath(for: file), let node = path.last else {
            fileOutlineView.deselectAll(nil)
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

    var selectedFile: URL? {
        loadViewIfNeeded()
        guard fileOutlineView.selectedRow >= 0,
              let node = fileOutlineView.item(atRow: fileOutlineView.selectedRow)
                as? FileTreeNode,
              !node.isDirectory
        else { return nil }
        return node.url
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
        guard sender.clickedRow >= 0,
              let row = sender.item(atRow: sender.clickedRow) as? NSNumber,
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
    var onChooseCompareVersion: (() -> Void)?
    var onPreviousDiffHunk: (() -> Void)?
    var onNextDiffHunk: (() -> Void)?
    var onFunctionChange: ((DiffCore.FunctionChange) -> Void)?
    private let label = NSTextField(labelWithString: "Open a project to begin")
    private let textView = ReaderTextView()
    private let loader = DocumentLoader()
    private let showsCompareControls: Bool
    private let compareVersionButton = NSButton()
    private let previousHunkButton = NSButton()
    private let nextHunkButton = NSButton()
    private let functionSummaryStack = NSStackView()
    private var displayedFunctionChanges: [DiffCore.FunctionChange] = []
    private weak var scrollView: NSScrollView?
    private(set) var displayedFile: URL?
    private var displayedSnapshotID: SnapshotID?
    private var displayedDocument: ReaderDocument?
    private var loadGeneration: UInt64 = 0
    private var contextMenuOffset: UInt32?
    private var readingPositionTask: Task<Void, Never>?

    init(showsCompareControls: Bool = false) {
        self.showsCompareControls = showsCompareControls
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let scrollView = NSScrollView()
        self.scrollView = scrollView
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
        if showsCompareControls {
            view = compareContainer(scrollView: scrollView)
        } else {
            view = scrollView
        }
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

    private func compareContainer(scrollView: NSScrollView) -> NSView {
        compareVersionButton.title = "Choose comparison version…"
        compareVersionButton.bezelStyle = .rounded
        compareVersionButton.target = self
        compareVersionButton.action = #selector(chooseCompareVersion(_:))
        compareVersionButton.setAccessibilityLabel("Comparison version")

        previousHunkButton.title = "↑"
        previousHunkButton.bezelStyle = .inline
        previousHunkButton.target = self
        previousHunkButton.action = #selector(previousDiffHunk(_:))
        previousHunkButton.setAccessibilityLabel("Previous diff hunk")
        nextHunkButton.title = "↓"
        nextHunkButton.bezelStyle = .inline
        nextHunkButton.target = self
        nextHunkButton.action = #selector(nextDiffHunk(_:))
        nextHunkButton.setAccessibilityLabel("Next diff hunk")

        let spacer = NSView()
        let controls = NSStackView(views: [
            compareVersionButton, spacer, previousHunkButton, nextHunkButton,
        ])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 6
        controls.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        functionSummaryStack.orientation = .horizontal
        functionSummaryStack.alignment = .centerY
        functionSummaryStack.spacing = 8
        functionSummaryStack.translatesAutoresizingMaskIntoConstraints = false
        let summaryScroll = NSScrollView()
        summaryScroll.documentView = functionSummaryStack
        summaryScroll.hasHorizontalScroller = true
        summaryScroll.drawsBackground = false
        summaryScroll.borderType = .noBorder
        summaryScroll.translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(controls)
        container.addSubview(summaryScroll)
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            controls.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            controls.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            controls.heightAnchor.constraint(equalToConstant: 28),
            summaryScroll.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 2),
            summaryScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            summaryScroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            summaryScroll.heightAnchor.constraint(equalToConstant: 30),
            functionSummaryStack.leadingAnchor.constraint(
                equalTo: summaryScroll.contentView.leadingAnchor
            ),
            functionSummaryStack.topAnchor.constraint(
                equalTo: summaryScroll.contentView.topAnchor
            ),
            functionSummaryStack.bottomAnchor.constraint(
                equalTo: summaryScroll.contentView.bottomAnchor
            ),
            scrollView.topAnchor.constraint(equalTo: summaryScroll.bottomAnchor, constant: 2),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    @objc private func chooseCompareVersion(_ sender: Any?) {
        onChooseCompareVersion?()
    }

    @objc private func previousDiffHunk(_ sender: Any?) {
        onPreviousDiffHunk?()
    }

    @objc private func nextDiffHunk(_ sender: Any?) {
        onNextDiffHunk?()
    }

    @objc private func openFunctionChange(_ sender: NSButton) {
        guard displayedFunctionChanges.indices.contains(sender.tag) else { return }
        onFunctionChange?(displayedFunctionChanges[sender.tag])
    }

    private static func title(_ kind: DiffCore.FunctionChange.Kind) -> String {
        switch kind {
        case .added: "Added"
        case .removed: "Removed"
        case .signatureChanged: "Signature"
        case .bodyChanged: "Body"
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        contextMenuOffset = contextMenuByteOffset()
        for item in menu.items { item.isEnabled = contextMenuOffset != nil }
    }

    func apply(settings: ReaderSettings) {
        textView.apply(settings: settings)
    }

    func configureCompareControls(
        versionTitle: String,
        functionChanges: [DiffCore.FunctionChange],
        selectedHunkIndex: Int?,
        hunkCount: Int,
        truncated: Bool,
        errorMessage: String?
    ) {
        guard showsCompareControls else { return }
        loadViewIfNeeded()
        compareVersionButton.title = versionTitle
        previousHunkButton.isEnabled = hunkCount > 0
        nextHunkButton.isEnabled = hunkCount > 0
        previousHunkButton.toolTip = hunkCount == 0
            ? "No diff hunks"
            : "Previous hunk"
        nextHunkButton.toolTip = hunkCount == 0
            ? "No diff hunks"
            : "Next hunk"
        if let selectedHunkIndex {
            nextHunkButton.title = "↓ \(selectedHunkIndex + 1)/\(hunkCount)"
        } else {
            nextHunkButton.title = "↓"
        }
        displayedFunctionChanges = functionChanges
        functionSummaryStack.arrangedSubviews.forEach {
            functionSummaryStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let status = errorMessage
            ?? (truncated ? "Large diff — side-by-side only" : nil)
        if let status {
            let label = NSTextField(labelWithString: status)
            label.textColor = .secondaryLabelColor
            functionSummaryStack.addArrangedSubview(label)
        } else if functionChanges.isEmpty {
            let label = NSTextField(labelWithString: "No function changes")
            label.textColor = .secondaryLabelColor
            functionSummaryStack.addArrangedSubview(label)
        } else {
            for (index, change) in functionChanges.enumerated() {
                let button = NSButton(
                    title: "\(Self.title(change.kind)) · \(change.displayName)",
                    target: self,
                    action: #selector(openFunctionChange(_:))
                )
                button.bezelStyle = .inline
                button.tag = index
                functionSummaryStack.addArrangedSubview(button)
            }
        }
    }

    func setDiffMarkers(_ markers: [Int: DiffCore.MarkerKind]) {
        loadViewIfNeeded()
        if !markers.isEmpty,
           scrollView?.verticalRulerView == nil,
           let scrollView
        {
            textView.installDiffGutter(in: scrollView)
        }
        textView.setDiffMarkers(markers)
    }

    var displayedBytes: [UInt8]? { textView.displayedBytes }
    var diffMarkerCounts: [DiffCore.MarkerKind: Int] { textView.diffMarkerCounts }
    var selectedDiffLine: Int? { textView.selectedLineNumber }
    var compareVersionAnchor: NSView {
        loadViewIfNeeded()
        return compareVersionButton
    }

    @discardableResult
    func revealDiffLine(_ line: Int) -> Bool {
        textView.revealDiffLine(line)
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
            textView.setDiffMarkers([:])
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

    func currentReadingPosition(fallbackByteOffset: UInt32? = nil) -> (
        file: URL,
        contentID: ContentID,
        byteOffset: UInt32,
        line: UInt32,
        column: UInt32,
        symbolAnchor: String?
    )? {
        guard let file = displayedFile,
              let document = displayedDocument
        else { return nil }
        let byteOffset = min(
            textView.firstVisibleByteOffset() ?? fallbackByteOffset ?? 0,
            UInt32(clamping: document.bytes.count)
        )
        guard let coordinate = document.lineTable.lineColumn(at: byteOffset) else {
            return nil
        }
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
        if let scrollView {
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

    func apply(settings: ReaderSettings) {
        miniReader.apply(settings: settings)
    }

    func selfTestSetPinned(_ pinned: Bool) {
        loadViewIfNeeded()
        modeControl.selectedSegment = pinned ? 1 : 0
        modeChanged(modeControl)
    }

    var selfTestSummary: String? {
        loadViewIfNeeded()
        return pathLabel.stringValue.isEmpty ? nil : pathLabel.stringValue
    }

    var selfTestProvenance: String? {
        loadViewIfNeeded()
        return candidateLabel.stringValue.isEmpty
            ? nil : candidateLabel.stringValue
    }

    var selfTestCandidateCount: Int {
        loadViewIfNeeded()
        return Int(countLabel.stringValue.split(separator: "/").last ?? "") ?? 0
    }

    var selfTestPinned: Bool {
        loadViewIfNeeded()
        return modeControl.selectedSegment == 1
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
            candidateLabel.stringValue = [
                candidate.provenanceBadge,
                candidate.bindingKind,
            ]
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
