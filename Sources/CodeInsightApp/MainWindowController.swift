import AppKit
import CodeInsightAppModel
import CodeInsightCore
import CodeInsightReaderCore
import CodeInsightReaderUI
import Observation

enum ProvenanceBadgeStyle: Equatable {
    case exact
    case strong
    case possible
    case fallback
}

func provenanceBadgeStyle(for text: String) -> ProvenanceBadgeStyle {
    if text.contains("Exact") { return .exact }
    if text.contains("Strong") { return .strong }
    if text.contains("Possible") { return .possible }
    return .fallback
}

@MainActor
final class MainWindowController: NSWindowController, NSToolbarDelegate,
    NSToolbarItemValidation
{
    private static let backItemIdentifier = NSToolbarItem.Identifier("Back")
    private static let forwardItemIdentifier = NSToolbarItem.Identifier("Forward")
    private static let projectItemIdentifier = NSToolbarItem.Identifier("Project")
    private static let commitItemIdentifier = NSToolbarItem.Identifier("Commit")
    private static let symbolsItemIdentifier = NSToolbarItem.Identifier("Symbols")
    private static let settingsItemIdentifier = NSToolbarItem.Identifier("Settings")
    private static let profileItemIdentifier = NSToolbarItem.Identifier("Profile")

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
    private let projectLabel = NSTextField(labelWithString: "Cairn")
    private let commitButton = NSButton()
    private let symbolsButton = NSButton()
    private let settingsButton = NSButton()
    private let profileButton = NSButton()
    private let indexLabel = NSTextField(labelWithString: "")
    private let exactLabel = NSTextField(labelWithString: "Exact: off (Safe)")
    private let statusBar = NSView()
    private let truncatedLabel = NSTextField(labelWithString: "Results truncated")
    private let toolbar = NSToolbar(identifier: "MainToolbar")
    private let recentProjectsStore: RecentProjectsStore
    private let recordsRecentProjects: Bool
    private let onChooseProject: () -> Void
    private let onShowSettings: () -> Void
    private var displayedGeneration: UInt64?
    private var displayedSnapshotID: SnapshotID?
    private var displayedNavigationGeneration: UInt64?
    private var symbolSearchPanel: SymbolSearchPanel?
    private var searchPanel: SearchPanel?
    private var commitPickerPopover: CommitPickerPopover?
    private var compareCommitPickerPopover: CommitPickerPopover?
    private var panelPreset = PanelPresetModel.reading
    private var lastOpenedProjectRoot: URL?
    private var pendingRecentProjectRoot: URL?
    private var pendingTabRestore: TabStripModel.Tab?

    init(
        model: AppModel,
        settings: ReaderSettings,
        offscreen: Bool,
        measuresIdleFootprint: Bool = false,
        recentProjectsStore: RecentProjectsStore = RecentProjectsStore(),
        recordsRecentProjects: Bool = false,
        onChooseProject: @escaping () -> Void = {},
        onShowSettings: @escaping () -> Void = {}
    ) {
        self.model = model
        self.recentProjectsStore = recentProjectsStore
        self.recordsRecentProjects = recordsRecentProjects
        self.onChooseProject = onChooseProject
        self.onShowSettings = onShowSettings
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
        contentSplitController.splitView.dividerStyle = .thin
        upperSplitController.splitView.dividerStyle = .thin
        readerSplitController.splitView.dividerStyle = .thin

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

        let contentView = NSView()
        let contentViewController = NSViewController()
        contentViewController.view = contentView
        contentViewController.addChild(contentSplitController)
        contentSplitController.view.translatesAutoresizingMaskIntoConstraints = false

        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.isHidden = true
        let separator = NSView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.separatorColor.cgColor

        indexLabel.font = .systemFont(ofSize: 11)
        indexLabel.textColor = .secondaryLabelColor
        indexLabel.setAccessibilityLabel("Index status")
        indexLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        truncatedLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        truncatedLabel.textColor = .systemOrange
        truncatedLabel.translatesAutoresizingMaskIntoConstraints = false
        truncatedLabel.drawsBackground = true
        truncatedLabel.backgroundColor = .systemOrange.withAlphaComponent(0.12)
        truncatedLabel.alignment = .center
        truncatedLabel.wantsLayer = true
        truncatedLabel.layer?.cornerRadius = 4
        truncatedLabel.setAccessibilityLabel("Query completeness")
        NSLayoutConstraint.activate([
            truncatedLabel.widthAnchor.constraint(
                equalToConstant: truncatedLabel.intrinsicContentSize.width + 12
            ),
            truncatedLabel.heightAnchor.constraint(equalToConstant: 18),
        ])
        exactLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        exactLabel.setAccessibilityLabel("Exact provider status")

        let statusStack = NSStackView()
        statusStack.setViews([indexLabel], in: .leading)
        statusStack.setViews([truncatedLabel], in: .center)
        statusStack.setViews([exactLabel], in: .trailing)
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        statusStack.orientation = .horizontal
        statusStack.alignment = .centerY
        statusStack.spacing = 12
        let contentStack = NSStackView(
            views: [contentSplitController.view, statusBar]
        )
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.alignment = .width
        contentStack.distribution = .fill
        contentStack.spacing = 0
        contentView.addSubview(contentStack)
        statusBar.addSubview(separator)
        statusBar.addSubview(statusStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor
            ),
            contentStack.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor
            ),
            contentStack.topAnchor.constraint(
                equalTo: contentView.topAnchor
            ),
            contentStack.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor
            ),
            contentSplitController.view.widthAnchor.constraint(
                equalTo: contentStack.widthAnchor
            ),
            statusBar.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 24),
            separator.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor),
            separator.topAnchor.constraint(equalTo: statusBar.topAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
            statusStack.leadingAnchor.constraint(
                equalTo: statusBar.leadingAnchor,
                constant: 12
            ),
            statusStack.trailingAnchor.constraint(
                equalTo: statusBar.trailingAnchor,
                constant: -12
            ),
            statusStack.centerYAnchor.constraint(
                equalTo: statusBar.centerYAnchor,
                constant: 0.5
            ),
        ])

        let frame = NSRect(x: offscreen ? -10_000 : 0, y: 0, width: 1280, height: 820)
        let window = NSWindow(
            contentRect: frame,
            styleMask: measuresIdleFootprint
                ? [.borderless]
                : [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Cairn"
        window.minSize = NSSize(width: 900, height: 600)
        window.contentViewController = contentViewController
        super.init(window: window)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        if !measuresIdleFootprint {
            window.toolbarStyle = .unified
            window.titleVisibility = .hidden
            window.toolbar = toolbar
        }
        if !offscreen {
            window.center()
            window.setFrameAutosaveName("CodeInsightMainWindow")
        }
        sidebarController.onOpenFile = { [weak self] url in
            self?.navigate(to: url)
        }
        sidebarController.onChooseProject = onChooseProject
        sidebarController.onOpenFileInSecondary = { [weak self] url in
            self?.openInSecondaryReader(url)
        }
        sidebarController.onOpenFileInNewTab = { [weak self] url in
            self?.openInNewTab(url)
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
            guard let self else { return }
            sidebarController.highlightOutline(at: offset)
            model.tabStrip.updateActiveScroll(offset)
        }
        readerController.onSelectionChange = { [weak self] offset in
            guard let self else { return }
            sidebarController.highlightOutline(at: offset)
            model.tabStrip.updateActiveSelection(offset)
        }
        readerController.onDocumentChange = { [weak model] file, document in
            model?.tabStrip.setActiveDocument(document, for: file)
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
        relationController.onTreeChange = { [weak self] in
            self?.renderStatusBar()
        }
        profileButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            profileButton.widthAnchor.constraint(equalToConstant: 240),
            profileButton.heightAnchor.constraint(equalToConstant: 28),
        ])
        applyReaderSettings(settings)
        readerController.configureTabs(
            model.tabStrip,
            onActivate: { [weak self] in self?.activateTab($0) },
            onClose: { [weak self] in self?.closeTab($0) }
        )
        render()
        applyPanelPreset(.reading)
        observe()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func openProject(root: URL) {
        let root = root.standardizedFileURL
        lastOpenedProjectRoot = root
        pendingRecentProjectRoot = root
        model.openProject(root: root)
        render()
    }

    func refreshRecentProjects() {
        renderEmptyState()
    }

    func selectFileInSidebar(_ file: URL) -> Bool {
        sidebarController.selectFile(file)
    }

    func openFileForSelfTest(_ file: URL) {
        navigate(to: file)
    }

    func openFileInNewTabForSelfTest(_ file: URL) {
        openInNewTab(file)
    }

    func setReadingPositionForSelfTest(
        scrollByteOffset: UInt32,
        selectionByteOffset: UInt32
    ) {
        readerController.restoreReadingPosition(
            scrollByteOffset: scrollByteOffset,
            selectionByteOffset: selectionByteOffset
        )
        model.tabStrip.updateActiveAnchors(
            scrollByteOffset: scrollByteOffset,
            selectionByteOffset: selectionByteOffset
        )
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
    var selfTestTabCount: Int { model.tabStrip.tabs.count }
    var selfTestActiveTabIndex: Int? { model.tabStrip.activeIndex }
    var selfTestActiveTabFile: URL? { model.tabStrip.activeTab?.fileURL }
    var selfTestActiveTabSelectionByteOffset: UInt32? {
        model.tabStrip.activeTab?.selectionByteOffset
    }
    var selfTestReaderPlaceholderText: String? {
        readerController.selfTestPlaceholderText
    }
    var selfTestReaderPlaceholderVisible: Bool {
        readerController.selfTestPlaceholderVisible
    }
    var selfTestReadingByteOffset: UInt32? {
        readerController.currentReadingPosition()?.byteOffset
    }
    var selfTestReadingGeometry: (
        scrollFrame: NSRect,
        clipFrame: NSRect,
        contentFrame: NSRect,
        rulerFrame: NSRect,
        windowContentFrame: NSRect,
        hasRuler: Bool,
        rulerThickness: CGFloat
    ) {
        let geometry = readerController.selfTestReadingGeometry
        let contentFrame = window?.contentView.map {
            $0.convert($0.bounds, to: nil)
        } ?? .zero
        return (
            geometry.scrollFrame,
            geometry.clipFrame,
            geometry.contentFrame,
            geometry.rulerFrame,
            contentFrame,
            geometry.hasRuler,
            geometry.rulerThickness
        )
    }
    var selfTestOccurrenceCount: Int { readerController.selfTestOccurrenceCount }
    var selfTestCurrentLineNumber: Int? {
        readerController.selfTestCurrentLineNumber
    }
    var selfTestVisibleLineNumbers: [Int] {
        readerController.selfTestVisibleLineNumbers
    }
    var selfTestVisibleCurrentLineNumbers: [Int] {
        readerController.selfTestVisibleCurrentLineNumbers
    }
    var selfTestStyledFragmentCount: Int {
        readerController.selfTestStyledFragmentCount
    }
    var selfTestReferenceStyledFragmentCount: Int {
        readerController.selfTestReferenceStyledFragmentCount
    }
    var selfTestReferenceAttributeRunCount: Int {
        readerController.selfTestReferenceAttributeRunCount
    }
    func selfTestActivateReading(at byteOffset: UInt32) -> Int {
        readerController.selfTestActivate(at: byteOffset)
    }

    var selfTestReferenceScannedCount: Int {
        readerController.selfTestReferenceScannedCount
    }
    var selfTestTabGeometry: (
        stripFrame: NSRect,
        readerFrame: NSRect,
        containerFrame: NSRect,
        contentFrame: NSRect,
        stripHidden: Bool,
        stripHiddenOrHasHiddenAncestor: Bool
    ) {
        let geometry = readerController.selfTestTabGeometry
        let contentFrame = window?.contentView.map {
            $0.convert($0.bounds, to: nil)
        } ?? .zero
        return (
            geometry.stripFrame,
            geometry.readerFrame,
            geometry.containerFrame,
            contentFrame,
            geometry.stripHidden,
            geometry.stripHiddenOrHasHiddenAncestor
        )
    }
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
    var selfTestFilesPlaceholderText: String? {
        sidebarController.selfTestFilesPlaceholderText
    }
    var selfTestFilesPlaceholderVisible: Bool {
        sidebarController.selfTestFilesPlaceholderVisible
    }
    var selfTestFilesLoadingIndicatorVisible: Bool {
        sidebarController.selfTestFilesLoadingIndicatorVisible
    }
    var selfTestFilesOpenProjectButtonTitle: String {
        sidebarController.selfTestFilesOpenProjectButtonTitle
    }
    var selfTestFilesOpenProjectButtonVisible: Bool {
        sidebarController.selfTestFilesOpenProjectButtonVisible
    }
    var selfTestFilesContentVisible: Bool {
        sidebarController.selfTestFilesContentVisible
    }
    var selfTestFileContextMenuHasOpenInNewTab: Bool {
        sidebarController.selfTestFileContextMenuHasOpenInNewTab
    }
    var selfTestOutlinePlaceholderText: String? {
        sidebarController.selfTestOutlinePlaceholderText
    }
    var selfTestOutlinePlaceholderVisible: Bool {
        sidebarController.selfTestOutlinePlaceholderVisible
    }
    var selfTestOutlineContentVisible: Bool {
        sidebarController.selfTestOutlineContentVisible
    }
    var selfTestSidebarGeometry: (
        filesPaneHeight: CGFloat,
        outlinePaneHeight: CGFloat,
        filePlaceholderHeight: CGFloat,
        filePlaceholderCenterOffset: CGFloat,
        outlinePlaceholderCenterOffset: CGFloat
    ) {
        sidebarController.selfTestGeometry
    }
    var selfTestSidebarDividerSurvivesPlaceholderRefresh: Bool {
        sidebarController.selfTestDividerSurvivesPlaceholderRefresh()
    }
    var selfTestContextPlaceholderText: String? {
        contextController.selfTestPlaceholderText
    }
    var selfTestContextPlaceholderVisible: Bool {
        contextController.selfTestPlaceholderVisible
    }
    var selfTestContextReaderVisible: Bool {
        contextController.selfTestReaderVisible
    }
    var selfTestContextCandidateVisibleWithGeometry: Bool {
        contextController.selfTestCandidateVisibleWithGeometry
    }
    var selfTestContextHasDoubleClickOpen: Bool {
        contextController.selfTestHasDoubleClickOpen
    }
    var selfTestRelationsPlaceholderText: String? {
        relationController.selfTestPlaceholderText
    }
    var selfTestRelationsPlaceholderVisible: Bool {
        relationController.selfTestPlaceholderVisible
    }
    var selfTestRelationsTreeVisible: Bool {
        relationController.selfTestTreeVisible
    }
    var selfTestExactStatusText: String { exactLabel.stringValue }
    var selfTestContentSplitFrameInContentView: NSRect {
        guard let contentView = window?.contentView else { return .zero }
        return contentSplitController.view.convert(
            contentSplitController.view.bounds,
            to: contentView
        )
    }
    var selfTestStatusBarFrameInContentView: NSRect {
        guard let contentView = window?.contentView else { return .zero }
        return statusBar.convert(statusBar.bounds, to: contentView)
    }
    var selfTestStatusBarVisible: Bool {
        guard selfTestViewIsVisibleInWindow(statusBar) else { return false }
        let statusFrame = statusBar.convert(statusBar.bounds, to: nil)
        let contentFrame = contentSplitController.view.convert(
            contentSplitController.view.bounds,
            to: nil
        )
        return abs(statusFrame.height - 24) < 0.5
            && statusFrame.maxY <= contentFrame.minY + 0.5
    }
    var selfTestIndexStatusText: String { indexLabel.stringValue }
    var selfTestIndexStatusVisible: Bool {
        selfTestStatusBarVisible
            && indexLabel.isDescendant(of: statusBar)
            && selfTestViewIsVisibleInWindow(indexLabel)
    }
    var selfTestExactStatusVisible: Bool {
        selfTestStatusBarVisible
            && exactLabel.isDescendant(of: statusBar)
            && selfTestViewIsVisibleInWindow(exactLabel)
    }
    var selfTestExactGroupTitle: String? {
        relationController.selfTestExactGroupTitle
    }
    var selfTestExactGroupRowCount: Int {
        relationController.selfTestExactGroupRowCount
    }
    var selfTestExactGroupFrame: NSRect {
        relationController.selfTestExactGroupFrame
    }
    var selfTestHeuristicGroupFrame: NSRect {
        relationController.selfTestHeuristicGroupFrame
    }
    var selfTestReferenceGroupTitle: String? {
        relationController.selfTestReferenceGroupTitle
    }
    var selfTestReferenceGroupFrame: NSRect {
        relationController.selfTestReferenceGroupFrame
    }
    var selfTestDirectionSegmentFrames: [NSRect] {
        relationController.selfTestDirectionSegmentFrames
    }
    var selfTestReferenceGroupVisibleWithGeometry: Bool {
        relationController.selfTestReferenceGroupVisibleWithGeometry
    }
    var selfTestReferenceSegmentVisibleWithGeometry: Bool {
        relationController.selfTestReferenceSegmentVisibleWithGeometry
    }
    var selfTestReferenceSegmentDoesNotOverlapOtherDirections: Bool {
        relationController.selfTestReferenceSegmentDoesNotOverlapOtherDirections
    }
    var selfTestRelationsVisibleRect: NSRect {
        relationController.selfTestRelationsVisibleRect
    }
    var selfTestExactGroupVisibleWithGeometry: Bool {
        relationController.selfTestExactGroupVisibleWithGeometry
    }
    var selfTestExactAndHeuristicGroupsDoNotOverlap: Bool {
        relationController.selfTestExactAndHeuristicGroupsDoNotOverlap
    }
    var selfTestExternalGroupTitle: String? {
        relationController.selfTestExternalGroupTitle
    }
    func selfTestVisibleRelationEdgeTitles(inGroup titlePrefix: String) -> [String] {
        relationController.selfTestVisibleEdgeTitles(inGroup: titlePrefix)
    }
    func selfTestVisibleRelationEdgeSubtitle(
        titled title: String,
        inGroup titlePrefix: String
    ) -> String? {
        relationController.selfTestVisibleEdgeSubtitle(
            titled: title,
            inGroup: titlePrefix
        )
    }
    func selfTestRelationAccessibility(
        titled title: String,
        inGroup titlePrefix: String
    ) -> (
        label: String,
        value: String,
        role: String,
        valueSettable: Bool
    )? {
        relationController.selfTestAccessibility(
            titled: title,
            inGroup: titlePrefix
        )
    }
    func selfTestVisibleRelationEdgeFrames(
        inGroup titlePrefix: String
    ) -> [NSRect] {
        relationController.selfTestVisibleEdgeFrames(inGroup: titlePrefix)
    }
    var selfTestExactAndReferenceGroupsDoNotOverlap: Bool {
        relationController.selfTestExactAndReferenceGroupsDoNotOverlap
    }
    var selfTestRelationResultsAndDirectionControlDoNotOverlap: Bool {
        relationController.selfTestResultsAndDirectionControlDoNotOverlap
    }
    var selfTestRelationLayoutPasses: Int {
        relationController.selfTestLayoutPasses
    }
    var selfTestSelectedRelationEdgeTitle: String? {
        relationController.selfTestSelectedEdgeTitle
    }
    var selfTestLastRelationAccessibilityNotification: String? {
        relationController.selfTestLastAccessibilityNotification
    }
    var selfTestRelationAccessibilityNotificationCount: Int {
        relationController.selfTestAccessibilityNotificationCount
    }
    var selfTestRelationOpenCount: Int {
        relationController.selfTestOpenCount
    }
    func selfTestPressRelationKey(_ keyCode: UInt16) -> Bool {
        relationController.selfTestPressKey(keyCode)
    }
    func selfTestExpandRelationEdge(titled title: String) -> Bool {
        relationController.selfTestExpandEdge(titled: title)
    }
    func selfTestVisibleRelationChildEdgeTitles(ofEdge title: String) -> [String] {
        relationController.selfTestVisibleChildEdgeTitles(ofEdge: title)
    }
    var selfTestLeftReaderBytes: [UInt8]? { readerController.displayedBytes }
    var selfTestRightReaderBytes: [UInt8]? { secondaryReaderController.displayedBytes }
    var selfTestLeftReaderIsEditable: Bool { readerController.isEditable }
    var selfTestGutterCounts: [DiffCore.MarkerKind: Int] {
        let left = readerController.diffMarkerCounts
        let right = secondaryReaderController.diffMarkerCounts
        var counts = left
        for (kind, count) in right { counts[kind, default: 0] += count }
        return counts
    }
    var selfTestGutterCoexistsWithLineNumbers: Bool {
        let leftHasDiff = !readerController.diffMarkerCounts.isEmpty
        let rightHasDiff = !secondaryReaderController.diffMarkerCounts.isEmpty
        return (leftHasDiff || rightHasDiff)
            && (!leftHasDiff || readerController.gutterShowsLineNumbersAndDiff)
            && (!rightHasDiff
                || secondaryReaderController.gutterShowsLineNumbersAndDiff)
    }
    var selfTestSelectedDiffLine: Int? {
        secondaryReaderController.selectedDiffLine ?? readerController.selectedDiffLine
    }
    var selfTestSecondaryReaderCollapsed: Bool { secondaryReaderItem.isCollapsed }
    var selfTestEmptyStateExists: Bool { readerController.selfTestEmptyStateExists }
    var selfTestEmptyStateTexts: [String] { readerController.selfTestEmptyStateTexts }
    var selfTestEmptyStateButtonTitles: [String] {
        readerController.selfTestEmptyStateButtonTitles
    }
    var selfTestEmptyStateAttachedToWindow: Bool {
        readerController.selfTestEmptyStateAttachedToWindow
    }
    var selfTestEmptyStateUnhidden: Bool {
        readerController.selfTestEmptyStateUnhidden
    }
    var selfTestEmptyStateFrameVisibleInWindow: Bool {
        readerController.selfTestEmptyStateFrameVisibleInWindow
    }
    var selfTestEmptyStateMarkVisibleInWindow: Bool {
        readerController.selfTestEmptyStateMarkVisibleInWindow
    }
    var selfTestEmptyStateMarkIs48Square: Bool {
        readerController.selfTestEmptyStateMarkIs48Square
    }
    var selfTestEmptyStateMarkUsesCairnDrawing: Bool {
        readerController.selfTestEmptyStateMarkUsesCairnDrawing
    }
    var selfTestEmptyStateNotCoveredByReader: Bool {
        readerController.selfTestEmptyStateNotCoveredByReader
    }
    var selfTestEmptyStateTitleVisibleInWindow: Bool {
        readerController.selfTestEmptyStateTitleVisibleInWindow
    }
    var selfTestEmptyStateButtonVisibleInWindow: Bool {
        readerController.selfTestEmptyStateButtonVisibleInWindow
    }
    var selfTestEmptyStateOpenButtonIsVisibleDefaultAction: Bool {
        readerController.selfTestEmptyStateOpenButtonIsVisibleDefaultAction
    }
    var selfTestCommitButtonTitle: String { commitButton.title }
    var selfTestCommitToolbarItemExistsAndVisible: Bool {
        selfTestToolbarItemExistsAndVisible(identifier: Self.commitItemIdentifier)
    }
    func selfTestShowCommitPicker(compare: Bool) {
        if compare {
            showCompareCommitPicker()
        } else {
            showCommitPicker(commitButton)
        }
    }
    func selfTestCloseCommitPicker(compare: Bool) {
        (compare ? compareCommitPickerPopover : commitPickerPopover)?.selfTestClose()
    }
    func selfTestCommitPickerGeometry(compare: Bool) -> (
        contentHeight: CGFloat,
        viewportHeight: CGFloat,
        commitRowFrames: [NSRect],
        visibleCommitRows: Int,
        shown: Bool
    )? {
        (compare ? compareCommitPickerPopover : commitPickerPopover)?
            .selfTestGeometry
    }
    var selfTestSymbolsToolbarItemExistsAndVisible: Bool {
        selfTestToolbarItemExistsAndVisible(identifier: Self.symbolsItemIdentifier)
    }
    var selfTestSettingsToolbarItemExistsAndVisible: Bool {
        selfTestToolbarItemExistsAndVisible(identifier: Self.settingsItemIdentifier)
    }
    var selfTestProfileToolbarItemExistsAndVisible: Bool {
        selfTestToolbarItemExistsAndVisible(identifier: Self.profileItemIdentifier)
    }
    var selfTestProfileToolbarItemRegisteredAndHidden: Bool {
        guard let toolbar = window?.toolbar else { return false }
        return toolbarAllowedItemIdentifiers(toolbar)
            .contains(Self.profileItemIdentifier)
            && !selfTestProfileToolbarItemExistsAndVisible
    }
    var selfTestProfileTitle: String { profileButton.title }
    var selfTestProfileButtonVisibleWithGeometry: Bool {
        guard window != nil,
              selfTestProfileToolbarItemExistsAndVisible,
              !profileButton.isHiddenOrHasHiddenAncestor,
              profileButton.frame.width > 0,
              profileButton.frame.height > 0,
              let container = profileButton.superview
        else { return false }
        return container.bounds.contains(profileButton.frame)
    }
    var selfTestProfileButtonFrame: NSRect { profileButton.frame }
    var selfTestProfileContainerBounds: NSRect {
        profileButton.superview?.bounds ?? .zero
    }
    func selfTestSwitchFeatureSelection(
        _ featureSelection: FeatureSelection
    ) -> Bool {
        guard let item = makeProfileMenu().items.first(where: {
            $0.representedObject as? String == featureSelection.rawValue
        }), let action = item.action
        else { return false }
        return NSApplication.shared.sendAction(
            action,
            to: item.target,
            from: item
        )
    }
    func prepareTitledWindowForSelfTest() {
        guard let window else { return }
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        window.toolbar = toolbar
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        toolbar.validateVisibleItems()
    }
    var selfTestReaderDocumentVisibleInWindow: Bool {
        readerController.selfTestReaderDocumentVisibleInWindow
    }
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

    func selfTestOpenContextSelection() {
        contextController.selfTestOpenSelection()
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

    func selfTestSelectRelationEdge(titled title: String) -> Bool {
        relationController.selfTestSelectEdge(titled: title)
    }

    func selfTestDeselectRelation() {
        relationController.selfTestDeselect()
    }

    func selfTestChangeRelationDirection(_ direction: RelationTreeModel.Direction) {
        relationController.selfTestChangeDirection(direction)
    }

    func selfTestOpenRelationSelection() {
        relationController.selfTestOpenSelection()
    }

    private func selfTestToolbarItemExistsAndVisible(
        identifier: NSToolbarItem.Identifier
    ) -> Bool {
        return window?.toolbar?.visibleItems?.contains {
            $0.itemIdentifier == identifier
        } == true
    }

    private func selfTestViewIsVisibleInWindow(_ view: NSView) -> Bool {
        guard let window = view.window,
              let contentView = window.contentView,
              !view.isHiddenOrHasHiddenAncestor,
              view.bounds.width > 0,
              view.bounds.height > 0
        else { return false }
        let frameInWindow = view.convert(view.bounds, to: nil)
        let contentFrameInWindow = contentView.convert(contentView.bounds, to: nil)
        let visibleFrame = frameInWindow.intersection(contentFrameInWindow)
        return visibleFrame.width > 0 && visibleFrame.height > 0
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

    func selfTestSetProjectSearchQuery(_ query: String) {
        searchPanel?.selfTestSetQuery(query)
    }

    func selfTestRevealProjectSearchTruncationRow() {
        searchPanel?.selfTestRevealTruncationRow()
    }

    var selfTestProjectSearchOutlineState: (
        totalRows: Int,
        groupRows: Int,
        matchRows: Int,
        truncationRows: Int,
        truncationVisible: Bool,
        status: String,
        searching: Bool
    )? {
        searchPanel?.selfTestOutlineState
    }

    func openSelectedFileInNewTab() {
        guard let file = sidebarController.selectedFile else { return }
        openInNewTab(file)
    }

    func closeActiveTab() {
        guard let index = model.tabStrip.activeIndex else { return }
        closeTab(index)
    }

    func selectPreviousTab() {
        selectRelativeTab(-1)
    }

    func selectNextTab() {
        selectRelativeTab(1)
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
        window?.appearance = switch settings.theme {
        case .dark: NSAppearance(named: .darkAqua)
        case .light, .siClassic: NSAppearance(named: .aqua)
        case .auto: nil
        }
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
        showRelations(target: .engine(symbol), direction: direction)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            Self.backItemIdentifier,
            Self.forwardItemIdentifier,
            Self.projectItemIdentifier,
            Self.commitItemIdentifier,
            .flexibleSpace,
            Self.symbolsItemIdentifier,
            .flexibleSpace,
            Self.settingsItemIdentifier,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            Self.backItemIdentifier,
            Self.forwardItemIdentifier,
            Self.projectItemIdentifier,
            Self.commitItemIdentifier,
            Self.symbolsItemIdentifier,
            Self.settingsItemIdentifier,
            Self.profileItemIdentifier,
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
            item.isNavigational = true
            item.visibilityPriority = .high
        case Self.forwardItemIdentifier:
            item.label = "Forward"
            item.image = NSImage(
                systemSymbolName: "chevron.forward",
                accessibilityDescription: "Forward"
            )
            item.target = self
            item.action = #selector(goForward(_:))
            item.isNavigational = true
            item.visibilityPriority = .high
        case Self.projectItemIdentifier:
            item.label = "Project"
            item.view = projectLabel
            projectLabel.font = .systemFont(ofSize: 13, weight: .semibold)
            projectLabel.cell?.lineBreakMode = .byTruncatingTail
            projectLabel.frame.size = NSSize(width: 120, height: 22)
            item.menuFormRepresentation = NSMenuItem(
                title: projectLabel.stringValue,
                action: nil,
                keyEquivalent: ""
            )
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
            let menuItem = NSMenuItem(
                title: commitButton.title,
                action: #selector(showCommitPickerFromMenu(_:)),
                keyEquivalent: ""
            )
            menuItem.target = self
            item.menuFormRepresentation = menuItem
        case Self.symbolsItemIdentifier:
            item.label = "Symbols"
            item.view = symbolsButton
            item.visibilityPriority = .standard
            symbolsButton.title = "Symbols  ⌘T"
            symbolsButton.image = NSImage(
                systemSymbolName: "magnifyingglass",
                accessibilityDescription: "Symbols"
            )
            symbolsButton.imagePosition = .imageLeading
            symbolsButton.bezelStyle = .rounded
            symbolsButton.font = .systemFont(ofSize: 12)
            symbolsButton.target = self
            symbolsButton.action = #selector(showSymbolSearchFromToolbar(_:))
            symbolsButton.frame.size = NSSize(width: 150, height: 28)
            symbolsButton.setAccessibilityLabel("Open Symbol Search")
            let menuItem = NSMenuItem(
                title: "Symbols",
                action: #selector(showSymbolSearchFromToolbar(_:)),
                keyEquivalent: "t"
            )
            menuItem.keyEquivalentModifierMask = .command
            menuItem.target = self
            item.menuFormRepresentation = menuItem
        case Self.settingsItemIdentifier:
            item.label = "Settings"
            item.view = settingsButton
            item.visibilityPriority = .low
            settingsButton.title = ""
            settingsButton.image = NSImage(
                systemSymbolName: "gearshape",
                accessibilityDescription: "Settings"
            )
            settingsButton.bezelStyle = .texturedRounded
            settingsButton.target = self
            settingsButton.action = #selector(showSettingsFromToolbar(_:))
            settingsButton.frame.size = NSSize(width: 32, height: 28)
            settingsButton.setAccessibilityLabel("Settings")
            let menuItem = NSMenuItem(
                title: "Settings…",
                action: #selector(showSettingsFromToolbar(_:)),
                keyEquivalent: ","
            )
            menuItem.keyEquivalentModifierMask = .command
            menuItem.target = self
            item.menuFormRepresentation = menuItem
        case Self.profileItemIdentifier:
            item.label = "Profile"
            item.view = profileButton
            item.visibilityPriority = .high
            profileButton.bezelStyle = .rounded
            profileButton.font = .systemFont(ofSize: 11, weight: .semibold)
            profileButton.cell?.lineBreakMode = .byTruncatingTail
            profileButton.target = self
            profileButton.action = #selector(showProfileMenu(_:))
            profileButton.setAccessibilityLabel("Analysis profile")
            item.menuFormRepresentation = profileMenuItem()
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
            _ = model.commitPicker.currentBranchName
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
            _ = model.exactCoordinator.trustMode
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
        sidebarController.setProjectState(model.projectState)
        sidebarController.setSelectedFile(model.selectedFile)
        if !sidebarController.synchronizeFileSelection(to: model.selectedFile) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                _ = sidebarController.synchronizeFileSelection(to: model.selectedFile)
            }
        }
        let readerFile = model.tabStrip.activeTab?.fileURL ?? model.selectedFile
        let selectedSource = readerSource(for: readerFile)
        readerController.display(
            readerFile,
            snapshotID: model.currentSnapshotID,
            source: selectedSource
        )
        readerController.refreshTabs()
        let compareFile = model.selectedFile.flatMap {
            projectPath(for: $0) == nil ? nil : $0
        }
        secondaryReaderController.display(
            model.compare.rightSnapshotID == nil ? nil : compareFile,
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
            if let restore = pendingTabRestore,
               restore.fileURL.standardizedFileURL
                    == readerFile?.standardizedFileURL
            {
                readerController.restoreReadingPosition(
                    scrollByteOffset: restore.scrollByteOffset,
                    selectionByteOffset: restore.selectionByteOffset
                )
                pendingTabRestore = nil
            } else {
                pendingTabRestore = nil
                if let file = model.selectedFile,
                   let offset = model.selectedByteOffset
                {
                    readerController.navigate(
                        to: file,
                        byteOffset: offset,
                        snapshotID: model.currentSnapshotID,
                        source: selectedSource
                    )
                }
            }
            displayedNavigationGeneration = model.navigationGeneration
        }
        if let root = model.fileTree?.root {
            projectLabel.stringValue = root.lastPathComponent
            projectLabel.textColor = .labelColor
        } else {
            projectLabel.stringValue = "Cairn"
            projectLabel.textColor = .secondaryLabelColor
        }
        window?.toolbar?.items.first {
            $0.itemIdentifier == Self.projectItemIdentifier
        }?.menuFormRepresentation?.title = projectLabel.stringValue
        renderEmptyState()
        renderCommitButton()
        renderExactStatus()
        renderStatusBar()

        guard let toolbar = window?.toolbar else { return }
        renderProfileItem(in: toolbar)
        toolbar.validateVisibleItems()
        symbolSearchPanel?.refreshProjectState()
        searchPanel?.refreshProjectState()
    }

    private var profileTitle: String? {
        guard let profile = model.activeAnalysisProfileDisplay,
              let trustMode = model.exactCoordinator.trustMode
        else { return nil }
        let trust = switch trustMode {
        case .safe: "Safe"
        case .trusted: "Trusted"
        }
        return "\(Self.displayName(for: profile.language))"
            + " · \(profile.projectUnitName)"
            + " · \(Self.displayName(for: profile.featureSelection))"
            + " · \(trust)"
    }

    private static func displayName(for language: LanguageID) -> String {
        switch language {
        case .rust: "Rust"
        case .python: "Python"
        case .typescript: "TypeScript"
        case .javascript: "JavaScript"
        }
    }

    private static func displayName(
        for featureSelection: FeatureSelection
    ) -> String {
        switch featureSelection {
        case .defaultFeatures: "default"
        case .allFeatures: "all"
        case .noDefaultFeatures: "no-default"
        }
    }

    private func renderProfileItem(in toolbar: NSToolbar) {
        guard let profileTitle else {
            if let index = toolbar.items.firstIndex(where: {
                $0.itemIdentifier == Self.profileItemIdentifier
            }) {
                toolbar.removeItem(at: index)
            }
            return
        }
        profileButton.title = profileTitle
        if toolbar.items.allSatisfy({
            $0.itemIdentifier != Self.profileItemIdentifier
        }) {
            let settingsIndex = toolbar.items.firstIndex {
                $0.itemIdentifier == Self.settingsItemIdentifier
            } ?? toolbar.items.count
            toolbar.insertItem(
                withItemIdentifier: Self.profileItemIdentifier,
                at: settingsIndex
            )
        }
        guard let item = toolbar.items.first(where: {
            $0.itemIdentifier == Self.profileItemIdentifier
        }) else { return }
        item.menuFormRepresentation = profileMenuItem()
    }

    private func profileMenuItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: profileButton.title,
            action: nil,
            keyEquivalent: ""
        )
        item.submenu = makeProfileMenu()
        return item
    }

    private func makeProfileMenu() -> NSMenu {
        let menu = NSMenu(title: "Profile")
        guard let profile = model.activeAnalysisProfileDisplay,
              let trustMode = model.exactCoordinator.trustMode
        else { return menu }
        let trust = switch trustMode {
        case .safe: "Safe"
        case .trusted: "Trusted"
        }
        let edition = profile.edition.map { "edition \($0)" }
            ?? "edition unknown"
        let current = NSMenuItem(
            title: "Current unit: \(profile.projectUnitName)"
                + " · features: \(Self.displayName(for: profile.featureSelection))"
                + " · \(edition) · \(trust)",
            action: nil,
            keyEquivalent: ""
        )
        current.isEnabled = false
        menu.addItem(current)
        menu.addItem(.separator())
        for featureSelection in model.availableFeatureSelections {
            let title = switch featureSelection {
            case .defaultFeatures: "Default features"
            case .allFeatures: "All features"
            case .noDefaultFeatures: "No default features"
            }
            let feature = NSMenuItem(
                title: title,
                action: #selector(switchFeatureSelectionFromMenu(_:)),
                keyEquivalent: ""
            )
            feature.target = self
            feature.representedObject = featureSelection.rawValue
            feature.state = featureSelection == profile.featureSelection
                ? .on
                : .off
            feature.isEnabled = model.snapshotPhase == .fullReady
            menu.addItem(feature)
        }
        menu.addItem(.separator())
        let trustItem = NSMenuItem(
            title: "Trust This Repository…",
            action: NSSelectorFromString("trustThisRepository:"),
            keyEquivalent: ""
        )
        trustItem.target = NSApplication.shared.delegate
        menu.addItem(trustItem)
        menu.addItem(.separator())
        let explanation = NSMenuItem(
            title: "Switch features here; the current unit is detected",
            action: nil,
            keyEquivalent: ""
        )
        explanation.isEnabled = false
        menu.addItem(explanation)
        return menu
    }

    private func renderEmptyState() {
        if case .ready = model.projectState, let root = pendingRecentProjectRoot {
            if recordsRecentProjects {
                recentProjectsStore.record(root)
            }
            pendingRecentProjectRoot = nil
        }

        let retry = { [weak self] in
            guard let self else { return }
            if let root = lastOpenedProjectRoot {
                openProject(root: root)
            } else {
                onChooseProject()
            }
        }
        switch model.projectState {
        case .empty:
            readerController.showEmptyState(
                recentPaths: recentProjectsStore.paths,
                failed: false,
                onChooseProject: onChooseProject,
                onOpenProject: { [weak self] in self?.openProject(root: $0) },
                onRetry: retry
            )
        case .failed:
            readerController.showEmptyState(
                recentPaths: recentProjectsStore.paths,
                failed: true,
                onChooseProject: onChooseProject,
                onOpenProject: { [weak self] in self?.openProject(root: $0) },
                onRetry: retry
            )
        case .indexing:
            readerController.removeEmptyState(placeholder: "Indexing project…")
        case .ready:
            readerController.removeEmptyState(placeholder: "Select a file to read")
        }
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
        let coordinator = model.exactCoordinator
        let trust: String? = switch coordinator.trustMode {
        case .safe: "Safe"
        case .trusted: "Trusted"
        case nil: nil
        }
        let trustSuffix = trust.map { " · \($0)" } ?? ""
        let status: String
        let color: NSColor
        let statusDetail: String?
        switch coordinator.readiness {
        case .ready:
            switch coordinator.coverage {
            case .dependenciesUnavailableOffline:
                status = "Exact: deps unavailable (offline)\(trustSuffix)"
                color = .systemOrange
            case .partial:
                status = "Exact: ready\(trustSuffix) (partial)"
                color = .systemOrange
            case .full:
                status = "Exact: ready\(trustSuffix)"
                color = .systemGreen
            case nil:
                status = "Exact: ready\(trustSuffix) (coverage unknown)"
                color = .systemOrange
            }
            statusDetail = nil
        case .preparing:
            status = "Exact: preparing\(trustSuffix)"
            color = .secondaryLabelColor
            statusDetail = nil
        case .unavailable(let reason):
            status = reason.localizedCaseInsensitiveContains("sandbox")
                ? "Exact: unavailable (sandbox)"
                : "Exact: unavailable"
            color = .systemRed
            statusDetail = reason
        case .off(let reason):
            status = reason.localizedCaseInsensitiveContains("sandbox")
                ? "Exact: unavailable (sandbox)"
                : "Exact: off (Safe)"
            color = .systemOrange
            statusDetail = reason
        }
        let coverageMeaning = switch coordinator.coverage {
        case .full:
            "full — dependency, build-script, and proc-macro coverage is enabled."
        case .partial:
            "partial — Safe mode disables build scripts and proc macros."
        case .dependenciesUnavailableOffline:
            "deps unavailable (offline) — dependency analysis is incomplete because network access is disabled."
        case nil:
            "not available yet."
        }
        let detail: String?
        if let attribution = coordinator.attribution {
            var lines = [
                "Provider: \(attribution.provider)",
                "Tool version: \(attribution.toolVersion)",
                "Trust: \(trust ?? "Unknown")",
                "Coverage: \(coverageMeaning)",
                "Features: \(Self.displayName(for: attribution.featureSelection))",
            ]
            if let statusDetail { lines.append(statusDetail) }
            detail = lines.joined(separator: "\n")
        } else {
            detail = statusDetail
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

    private func renderStatusBar() {
        let hasProject = switch model.projectState {
        case .indexing, .ready: true
        case .empty, .failed: false
        }
        statusBar.isHidden = !hasProject
        let coverageStatus = model.coverage.statusText(
            for: model.snapshotPhase ?? .firstPaint
        )
        let indexStatus = [initialIndexStatus, coverageStatus]
            .compactMap { $0 }
            .joined(separator: " · ")
        indexLabel.stringValue = indexStatus
        indexLabel.isHidden = indexStatus.isEmpty
        truncatedLabel.isHidden = !model.relationTree.hasTruncatedResults
    }

    private func renderCommitButton() {
        guard let revision = model.currentRevision else {
            commitButton.title = switch model.commitPicker.currentBranchName {
            case "detached": "⎇ detached"
            case let branch?: "⎇ \(branch) · Working Tree"
            case nil: "Working Tree"
            }
            commitButton.bezelColor = nil
            commitButton.contentTintColor = .controlTextColor
            commitButton.toolTip = commitButton.title
            commitButton.isEnabled = model.fileTree != nil
            updateCommitMenuTitle()
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
        updateCommitMenuTitle()
    }

    private func updateCommitMenuTitle() {
        let menuItem = window?.toolbar?.items.first {
            $0.itemIdentifier == Self.commitItemIdentifier
        }?.menuFormRepresentation
        menuItem?.title = commitButton.title
        menuItem?.isEnabled = commitButton.isEnabled
    }

    private static func truncated(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit - 1)) + "…"
    }

    @objc private func showCommitPicker(_ sender: Any?) {
        guard let anchor = (sender as? NSView) ?? window?.contentView else { return }
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
        commitPickerPopover?.show(relativeTo: anchor)
    }

    @objc private func showCommitPickerFromMenu(_ sender: Any?) {
        showCommitPicker(nil)
    }

    @objc private func showSymbolSearchFromToolbar(_ sender: Any?) {
        showSymbolSearch()
    }

    @objc private func showSettingsFromToolbar(_ sender: Any?) {
        onShowSettings()
    }

    @objc private func showProfileMenu(_ sender: Any?) {
        guard profileTitle != nil else { return }
        makeProfileMenu().popUp(
            positioning: nil,
            at: .zero,
            in: profileButton
        )
    }

    @objc private func switchFeatureSelectionFromMenu(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let featureSelection = FeatureSelection(rawValue: rawValue)
        else { return }
        model.switchFeatureSelection(featureSelection)
        render()
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
        if direction == .references,
           case let .ready(session, _) = model.projectState,
           let document = model.tabStrip.activeDocument,
           let binding = document.localBinding(at: offset),
           let file = session.manifest.files.first(where: {
               session.paths.resolve($0.pathID) == path
                   && $0.contentID == document.contentID
           }),
           let bindingIndex = UInt32(exactly: binding.bindingIndex)
        {
            showRelations(
                target: .localBinding(
                    pathID: file.pathID,
                    bindingIndex: bindingIndex
                ),
                direction: direction,
                document: document
            )
            return
        }
        Task { [weak self] in
            guard let self,
                  let candidate = await model.contextWindow.resolvedCandidate(
                      file: path,
                      offset: offset
                  ),
                  let symbol = candidate.symbol
            else { return }
            showRelations(target: .engine(symbol), direction: direction)
        }
    }

    private func open(_ candidate: ContextWindowModel.Candidate) {
        open(path: candidate.path, byteOffset: candidate.targetByteOffset)
    }

    private func open(path: String, byteOffset: UInt32) {
        guard let root = model.fileTree?.root else { return }
        let file = exactLocationIsInDependency(path)
            ? URL(fileURLWithPath: path)
            : root.appendingPathComponent(path)
        navigate(
            to: file,
            byteOffset: byteOffset
        )
    }

    private func showRelations(
        target: ReferenceTarget,
        direction: RelationTreeModel.Direction,
        document: ReaderDocument? = nil
    ) {
        relationItem.isCollapsed = false
        relationController.setRoot(
            target: target,
            direction: direction,
            document: document
        )
    }

    private func navigate(to file: URL, byteOffset: UInt32? = nil) {
        let current = currentJumpRecord()
        captureActiveTabState()
        let existingTab = model.tabStrip.tabs.firstIndex(where: {
            $0.fileURL.standardizedFileURL == file.standardizedFileURL
        })
        let focusesExistingTab = byteOffset == nil
            && existingTab != nil
            && existingTab != model.tabStrip.activeIndex
        model.navigate(
            to: file,
            byteOffset: byteOffset,
            leaving: current
        )
        if focusesExistingTab { pendingTabRestore = model.tabStrip.activeTab }
        render()
    }

    private func openInNewTab(_ file: URL) {
        captureActiveTabState()
        model.openInNewTab(file)
        pendingTabRestore = model.tabStrip.activeTab
        render()
    }

    private func activateTab(_ index: Int) {
        guard model.tabStrip.activeIndex != index,
              model.tabStrip.tabs.indices.contains(index)
        else { return }
        captureActiveTabState()
        model.activateTab(index)
        pendingTabRestore = model.tabStrip.activeTab
        render()
    }

    private func closeTab(_ index: Int) {
        let closesActive = model.tabStrip.activeIndex == index
        if closesActive { captureActiveTabState() }
        model.closeTab(index)
        pendingTabRestore = closesActive ? model.tabStrip.activeTab : nil
        render()
    }

    private func selectRelativeTab(_ delta: Int) {
        guard model.tabStrip.tabs.count > 1 else { return }
        captureActiveTabState()
        model.selectRelativeTab(delta)
        pendingTabRestore = model.tabStrip.activeTab
        render()
    }

    private func captureActiveTabState() {
        if let position = readerController.currentReadingPosition(
            fallbackByteOffset: model.selectedByteOffset
        ) {
            model.tabStrip.updateActiveScroll(position.byteOffset)
        }
    }

    private func currentJumpRecord() -> JumpRecord? {
        switch model.projectState {
        case .empty, .failed:
            return nil
        case .indexing, .ready:
            break
        }
        guard let selectedFile = model.selectedFile else { return nil }
        let path = projectPath(for: selectedFile)
            ?? (exactLocationIsInDependency(selectedFile.path)
                ? selectedFile.path
                : nil)
        guard let path else { return nil }
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

    private func readerSource(
        for file: URL?
    ) -> DocumentLoader.ContentSource? {
        guard let file, projectPath(for: file) != nil else { return nil }
        return model.documentSource
    }
}

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
    private let fileScrollView = NSScrollView()
    private let symbolScrollView = NSScrollView()
    private let filePlaceholder = NSStackView()
    private let filePlaceholderLabel = NSTextField(labelWithString: "No project open")
    private let filePlaceholderButton = NSButton()
    private let fileLoadingIndicator = NSProgressIndicator()
    private let outlinePlaceholder = NSTextField(labelWithString: "No file open")
    private let outlineModel = OutlinePanelModel()
    private var tree: FileTreeModel?
    private var facetRows: [NSNumber] = []
    private var setInitialDivider = false
    private var isSynchronizingFileSelection = false
    private var hasSelectedFile = false

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
            $0.title == "Open in New Tab"
                && $0.action == #selector(openFileInNewTab(_:))
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
        let openInNewTab = NSMenuItem(
            title: "Open in New Tab",
            action: #selector(openFileInNewTab(_:)),
            keyEquivalent: ""
        )
        openInNewTab.target = self
        fileMenu.addItem(openInNewTab)
        let openRight = NSMenuItem(
            title: "Open in Right Reader (Compare)",
            action: #selector(openFileInRightReader(_:)),
            keyEquivalent: ""
        )
        openRight.target = self
        fileMenu.addItem(openRight)
        fileOutlineView.menu = fileMenu

        configurePlaceholders()
        splitView.isVertical = false
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.addArrangedSubview(pane(
            title: "Files",
            outlineView: fileOutlineView,
            scrollView: fileScrollView,
            placeholder: filePlaceholder
        ))
        splitView.addArrangedSubview(pane(
            title: "Outline",
            outlineView: symbolOutlineView,
            scrollView: symbolScrollView,
            placeholder: outlinePlaceholder
        ))
        splitView.translatesAutoresizingMaskIntoConstraints = false

        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.state = .followsWindowActiveState
        sidebar.addSubview(splitView)
        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: sidebar.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
        ])
        view = sidebar
        updateFilePlaceholder(isIndexing: false)
        updateOutlinePlaceholder()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !setInitialDivider,
              splitView.bounds.height > 0,
              splitView.arrangedSubviews.allSatisfy({ $0.frame.height > 0 })
        else { return }
        splitView.setPosition(splitView.bounds.height * 0.65, ofDividerAt: 0)
        setInitialDivider = true
    }

    func display(_ tree: FileTreeModel?) {
        self.tree = tree
        loadViewIfNeeded()
        fileOutlineView.reloadData()
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
        updateOutlinePlaceholder()
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
            cell.imageView?.image = fileIcon(isDirectory: node.isDirectory)
            return cell
        }
        let cell = NSTableCellView()
        cell.identifier = identifier
        let image = NSImageView()
        image.image = fileIcon(isDirectory: node.isDirectory)
        image.contentTintColor = .secondaryLabelColor
        image.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: node.name)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.imageView = image
        cell.textField = label
        cell.addSubview(image)
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            image.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
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

    private func configure(_ outlineView: NSOutlineView, column title: String) {
        let column = NSTableColumn(identifier: .init(title))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.rowSizeStyle = .default
        outlineView.rowHeight = 24
        outlineView.selectionHighlightStyle = .regular
        outlineView.backgroundColor = .clear
        outlineView.usesAlternatingRowBackgroundColors = false
    }

    private func pane(
        title: String,
        outlineView: NSOutlineView,
        scrollView: NSScrollView,
        placeholder: NSView
    ) -> NSView {
        let label = NSTextField(labelWithString: title.uppercased())
        label.attributedStringValue = NSAttributedString(
            string: title.uppercased(),
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
                .kern: 0.6,
            ]
        )
        label.translatesAutoresizingMaskIntoConstraints = false
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false

        let pane = NSView()
        pane.addSubview(label)
        pane.addSubview(separator)
        pane.addSubview(scrollView)
        pane.addSubview(placeholder)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: pane.topAnchor, constant: 10),
            label.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -8),
            separator.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 6),
            separator.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
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
        return pane
    }

    private func configurePlaceholders() {
        filePlaceholderLabel.font = .systemFont(ofSize: 11)
        filePlaceholderLabel.textColor = .secondaryLabelColor
        filePlaceholderLabel.alignment = .center
        filePlaceholderButton.title = "Open Project…"
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
            filePlaceholderLabel.stringValue = "Loading files…"
            filePlaceholderButton.isHidden = true
            fileLoadingIndicator.isHidden = false
            fileLoadingIndicator.startAnimation(nil)
        } else {
            filePlaceholderLabel.stringValue = "No project open"
            filePlaceholderButton.isHidden = false
            fileLoadingIndicator.stopAnimation(nil)
            fileLoadingIndicator.isHidden = true
        }
    }

    private func updateOutlinePlaceholder() {
        outlinePlaceholder.stringValue = hasSelectedFile
            ? "No symbols in this file"
            : "No file open"
        let showsPlaceholder = !hasSelectedFile || facetRows.isEmpty
        outlinePlaceholder.isHidden = !showsPlaceholder
        symbolScrollView.isHidden = showsPlaceholder
    }

    @objc private func chooseProject(_ sender: Any?) {
        onChooseProject?()
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

    private func fileIcon(isDirectory: Bool) -> NSImage? {
        NSImage(
            systemSymbolName: isDirectory ? "folder" : "doc",
            accessibilityDescription: isDirectory ? "Folder" : "File"
        )?.withSymbolConfiguration(.init(hierarchicalColor: .secondaryLabelColor))
    }
}

@MainActor
private final class TabStripView: NSView {
    private weak var model: TabStripModel?
    private var onActivate: ((Int) -> Void)?
    private var onClose: ((Int) -> Void)?
    private var theme = ReaderTheme(settings: ReaderSettings())

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Open files")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        _ model: TabStripModel,
        onActivate: @escaping (Int) -> Void,
        onClose: @escaping (Int) -> Void
    ) {
        self.model = model
        self.onActivate = onActivate
        self.onClose = onClose
        refresh()
    }

    func apply(settings: ReaderSettings) {
        theme = ReaderTheme(settings: settings)
        needsDisplay = true
    }

    func refresh() {
        isHidden = (model?.tabs.count ?? 0) <= 1
        setAccessibilityValue(model?.activeTab?.fileURL.lastPathComponent ?? "")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        theme.backgroundColor.setFill()
        bounds.fill()
        guard let model else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        for index in model.tabs.indices {
            let rect = tabRect(index: index, count: model.tabs.count)
            if index == model.activeIndex {
                NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
                rect.fill()
                NSColor.controlAccentColor.setFill()
                NSRect(x: rect.minX, y: rect.maxY - 2, width: rect.width, height: 2)
                    .fill()
            }
            let titleRect = rect.insetBy(dx: 10, dy: 7)
            let closeWidth: CGFloat = 18
            let textRect = NSRect(
                x: titleRect.minX,
                y: titleRect.minY,
                width: max(0, titleRect.width - closeWidth),
                height: titleRect.height
            )
            (model.tabs[index].fileURL.lastPathComponent as NSString).draw(
                in: textRect,
                withAttributes: [
                    .font: NSFont.systemFont(
                        ofSize: 11,
                        weight: index == model.activeIndex ? .semibold : .regular
                    ),
                    .foregroundColor: theme.foregroundColor,
                    .paragraphStyle: paragraph,
                ]
            )
            ("×" as NSString).draw(
                in: closeRect(for: rect),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: theme.foregroundColor.withAlphaComponent(0.65),
                ]
            )
            NSColor.separatorColor.setFill()
            NSRect(x: rect.maxX - 1, y: 5, width: 1, height: rect.height - 10)
                .fill()
        }
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.minX, y: bounds.maxY - 1, width: bounds.width, height: 1)
            .fill()
    }

    override func mouseDown(with event: NSEvent) {
        guard let model else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let index = model.tabs.indices.first(where: {
            tabRect(index: $0, count: model.tabs.count).contains(point)
        }) else { return }
        if closeRect(
            for: tabRect(index: index, count: model.tabs.count)
        ).contains(point) {
            onClose?(index)
        } else {
            onActivate?(index)
        }
    }

    private func tabRect(index: Int, count: Int) -> NSRect {
        guard count > 0 else { return .zero }
        let width = min(180, bounds.width / CGFloat(count))
        return NSRect(
            x: CGFloat(index) * width,
            y: 0,
            width: width,
            height: bounds.height
        )
    }

    private func closeRect(for tabRect: NSRect) -> NSRect {
        NSRect(
            x: tabRect.maxX - 24,
            y: tabRect.minY + 6,
            width: 18,
            height: tabRect.height - 12
        )
    }
}

@MainActor
final class ReaderViewController: NSViewController {
    var onTokenClick: ((UInt32, Bool) -> Void)?
    var onShowRelation: ((UInt32, RelationTreeModel.Direction) -> Void)?
    var onOutlineChange: (([OutlineFacet]) -> Void)?
    var onReadingPositionChange: ((UInt32) -> Void)?
    var onSelectionChange: ((UInt32) -> Void)?
    var onDocumentChange: ((URL, ReaderDocument?) -> Void)?
    var onChooseCompareVersion: (() -> Void)?
    var onPreviousDiffHunk: (() -> Void)?
    var onNextDiffHunk: (() -> Void)?
    var onFunctionChange: ((DiffCore.FunctionChange) -> Void)?
    private let label = NSTextField(labelWithString: "")
    private let textView = ReaderTextView()
    private let loader = DocumentLoader()
    private let showsCompareControls: Bool
    private let compareVersionButton = NSButton()
    private let previousHunkButton = NSButton()
    private let nextHunkButton = NSButton()
    private let functionSummaryStack = NSStackView()
    private var displayedFunctionChanges: [DiffCore.FunctionChange] = []
    private let readerArea = NSView()
    private let tabStripView = TabStripView()
    private weak var scrollView: NSScrollView?
    private(set) var displayedFile: URL?
    private var displayedSnapshotID: SnapshotID?
    private var displayedDocument: ReaderDocument?
    private var loadGeneration: UInt64 = 0
    private var contextMenuOffset: UInt32?
    private var readingPositionTask: Task<Void, Never>?
    private var emptyStateView: EmptyStateView?

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
        textView.configureGutter(in: scrollView, lineNumbers: true)
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        readerArea.addSubview(scrollView)
        readerArea.addSubview(label)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: readerArea.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: readerArea.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: readerArea.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: readerArea.bottomAnchor),
            label.centerXAnchor.constraint(equalTo: readerArea.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: readerArea.centerYAnchor),
        ])
        if showsCompareControls {
            view = compareContainer(readerView: readerArea)
        } else {
            tabStripView.isHidden = true
            let stack = NSStackView(views: [tabStripView, readerArea])
            stack.orientation = .vertical
            stack.alignment = .width
            stack.distribution = .fill
            stack.spacing = 0
            NSLayoutConstraint.activate([
                tabStripView.heightAnchor.constraint(equalToConstant: 30),
            ])
            view = stack
        }
        textView.onClick = { [weak self] characterIndex, modifiers in
            guard let self,
                  let offset = self.textView.byteOffset(
                    forCharacterIndex: characterIndex
                  )
            else { return }
            self.onSelectionChange?(offset)
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
        relationMenu.addItem(NSMenuItem(
            title: "Show References",
            action: #selector(showReferences(_:)),
            keyEquivalent: ""
        ))
        for item in relationMenu.items { item.target = self }
        textView.view.menu = relationMenu
        textView.onContextMenu = { [weak self] characterIndex in
            guard let self else { return }
            contextMenuOffset = displayedDocument == nil
                ? nil
                : textView.byteOffset(forCharacterIndex: characterIndex)
            for item in textView.view.menu?.items ?? [] {
                item.isEnabled = contextMenuOffset != nil
            }
        }
    }

    private func compareContainer(readerView: NSView) -> NSView {
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

        readerView.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(controls)
        container.addSubview(summaryScroll)
        container.addSubview(readerView)
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
            readerView.topAnchor.constraint(equalTo: summaryScroll.bottomAnchor, constant: 2),
            readerView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            readerView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            readerView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
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

    func apply(settings: ReaderSettings) {
        loadViewIfNeeded()
        textView.apply(settings: settings)
        if !showsCompareControls { tabStripView.apply(settings: settings) }
    }

    func configureTabs(
        _ model: TabStripModel,
        onActivate: @escaping (Int) -> Void,
        onClose: @escaping (Int) -> Void
    ) {
        guard !showsCompareControls else { return }
        loadViewIfNeeded()
        tabStripView.configure(
            model,
            onActivate: onActivate,
            onClose: onClose
        )
    }

    func refreshTabs() {
        guard !showsCompareControls else { return }
        loadViewIfNeeded()
        tabStripView.refresh()
    }

    func showEmptyState(
        recentPaths: [String],
        failed: Bool,
        onChooseProject: @escaping () -> Void,
        onOpenProject: @escaping (URL) -> Void,
        onRetry: @escaping () -> Void
    ) {
        loadViewIfNeeded()
        label.isHidden = true
        scrollView?.isHidden = true
        if let emptyStateView {
            emptyStateView.update(recentPaths: recentPaths, failed: failed)
            return
        }
        let emptyStateView = EmptyStateView(
            recentPaths: recentPaths,
            failed: failed,
            onChooseProject: onChooseProject,
            onOpenProject: onOpenProject,
            onRetry: onRetry
        )
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        readerArea.addSubview(emptyStateView)
        NSLayoutConstraint.activate([
            emptyStateView.leadingAnchor.constraint(equalTo: readerArea.leadingAnchor),
            emptyStateView.trailingAnchor.constraint(equalTo: readerArea.trailingAnchor),
            emptyStateView.topAnchor.constraint(equalTo: readerArea.topAnchor),
            emptyStateView.bottomAnchor.constraint(equalTo: readerArea.bottomAnchor),
        ])
        self.emptyStateView = emptyStateView
    }

    func removeEmptyState(placeholder: String) {
        emptyStateView?.removeFromSuperview()
        emptyStateView = nil
        scrollView?.isHidden = false
        if displayedFile == nil {
            label.stringValue = placeholder
            label.isHidden = false
        }
    }

    var selfTestEmptyStateExists: Bool { emptyStateView != nil }
    var selfTestEmptyStateTexts: [String] {
        emptyStateView?.selfTestTextValues ?? []
    }
    var selfTestEmptyStateButtonTitles: [String] {
        emptyStateView?.selfTestButtonTitles ?? []
    }
    var selfTestEmptyStateAttachedToWindow: Bool {
        emptyStateView?.selfTestAttachedToWindow == true
    }
    var selfTestEmptyStateUnhidden: Bool {
        emptyStateView?.selfTestUnhidden == true
    }
    var selfTestEmptyStateFrameVisibleInWindow: Bool {
        emptyStateView?.selfTestFrameVisibleInWindow == true
    }
    var selfTestEmptyStateMarkVisibleInWindow: Bool {
        emptyStateView?.selfTestMarkVisibleInWindow == true
    }
    var selfTestEmptyStateMarkIs48Square: Bool {
        emptyStateView?.selfTestMarkIs48Square == true
    }
    var selfTestEmptyStateMarkUsesCairnDrawing: Bool {
        emptyStateView?.selfTestMarkUsesCairnDrawing == true
    }
    var selfTestEmptyStateNotCoveredByReader: Bool {
        emptyStateView?.superview === readerArea && scrollView?.isHidden == true
    }
    var selfTestEmptyStateTitleVisibleInWindow: Bool {
        emptyStateView?.selfTestTitleVisibleInWindow == true
    }
    var selfTestEmptyStateButtonVisibleInWindow: Bool {
        emptyStateView?.selfTestButtonVisibleInWindow == true
    }
    var selfTestEmptyStateOpenButtonIsVisibleDefaultAction: Bool {
        emptyStateView?.selfTestOpenButtonIsVisibleDefaultAction == true
    }
    var selfTestReaderDocumentVisibleInWindow: Bool {
        guard let scrollView else { return false }
        return !scrollView.isHiddenOrHasHiddenAncestor
            && scrollView.window != nil
            && scrollView.bounds.width > 0
            && scrollView.bounds.height > 0
            && !textView.view.isHiddenOrHasHiddenAncestor
            && textView.view.window != nil
            && textView.view.bounds.width > 0
            && textView.view.bounds.height > 0
            && textView.view.visibleRect.width > 0
            && textView.view.visibleRect.height > 0
    }
    var selfTestPlaceholderText: String? {
        label.isHidden ? nil : label.stringValue
    }
    var selfTestPlaceholderVisible: Bool {
        !label.isHiddenOrHasHiddenAncestor
            && label.window != nil
            && label.frame.width > 0
            && label.frame.height > 0
    }
    var selfTestTabGeometry: (
        stripFrame: NSRect,
        readerFrame: NSRect,
        containerFrame: NSRect,
        stripHidden: Bool,
        stripHiddenOrHasHiddenAncestor: Bool
    ) {
        (
            tabStripView.convert(tabStripView.bounds, to: nil),
            readerArea.convert(readerArea.bounds, to: nil),
            view.convert(view.bounds, to: nil),
            tabStripView.isHidden,
            tabStripView.isHiddenOrHasHiddenAncestor
        )
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
    var isEditable: Bool { textView.view.isEditable }
    var diffMarkerCounts: [DiffCore.MarkerKind: Int] { textView.diffMarkerCounts }
    var gutterShowsLineNumbersAndDiff: Bool {
        textView.gutterShowsLineNumbersAndDiff
    }
    var selectedDiffLine: Int? { textView.selectedLineNumber }
    var selfTestOccurrenceCount: Int { textView.occurrenceCount }
    var selfTestCurrentLineNumber: Int? { textView.currentLineNumber }
    var selfTestStyledFragmentCount: Int {
        textView.renderingCoordinator.styledFragmentCount
    }
    var selfTestReferenceStyledFragmentCount: Int {
        textView.renderingCoordinator.referenceStyledFragmentCount
    }
    var selfTestReferenceAttributeRunCount: Int {
        textView.renderingCoordinator.referenceAttributeRunCount
    }
    var selfTestReferenceScannedCount: Int {
        textView.renderingCoordinator.referenceScannedCount
    }
    var selfTestVisibleLineNumbers: [Int] {
        textView.captureVisibleDecorationState()
        return textView.visibleLineNumbers
    }
    var selfTestVisibleCurrentLineNumbers: [Int] {
        textView.captureVisibleDecorationState()
        return textView.visibleCurrentLineNumbers
    }
    func selfTestActivate(at byteOffset: UInt32) -> Int {
        textView.activate(atByteOffset: byteOffset)
    }
    var selfTestReadingGeometry: (
        scrollFrame: NSRect,
        clipFrame: NSRect,
        contentFrame: NSRect,
        rulerFrame: NSRect,
        hasRuler: Bool,
        rulerThickness: CGFloat
    ) {
        loadViewIfNeeded()
        guard let scrollView else {
            return (.zero, .zero, .zero, .zero, false, 0)
        }
        let ruler = scrollView.verticalRulerView
        let visible = textView.view.convert(textView.view.visibleRect, to: nil)
        let gutterWidth = max(0, textView.view.textContainerInset.width - 12)
        return (
            scrollView.convert(scrollView.bounds, to: nil),
            scrollView.contentView.convert(scrollView.contentView.bounds, to: nil),
            NSRect(
                x: visible.minX + gutterWidth,
                y: visible.minY,
                width: max(0, visible.width - gutterWidth),
                height: visible.height
            ),
            ruler?.convert(ruler?.bounds ?? .zero, to: nil) ?? .zero,
            scrollView.hasVerticalRuler,
            ruler?.ruleThickness ?? 0
        )
    }
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
            label.stringValue = "Select a file to read"
            label.isHidden = false
            textView.clear()
            return
        }

        do {
            let activeLoader = source.map { DocumentLoader(source: $0) } ?? loader
            let loaded = try activeLoader.load(file: file)
            displayedDocument = loaded.document
            onDocumentChange?(file, loaded.document)
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
                            self.onDocumentChange?(file, document)
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
            onDocumentChange?(file, nil)
            label.stringValue = "Could not open \(file.lastPathComponent)"
            label.isHidden = false
            textView.clear()
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

    func restoreReadingPosition(
        scrollByteOffset: UInt32?,
        selectionByteOffset: UInt32?
    ) {
        let generation = loadGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, loadGeneration == generation else { return }
            textView.restore(
                scrollByteOffset: scrollByteOffset,
                selectionByteOffset: selectionByteOffset
            )
        }
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
            textView.view.frame = NSRect(
                origin: .zero,
                size: scrollView.contentView.bounds.size
            )
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

    @objc private func showReferences(_ sender: Any?) {
        showRelation(.references)
    }

    private func showRelation(_ direction: RelationTreeModel.Direction) {
        guard let contextMenuOffset else { return }
        onShowRelation?(contextMenuOffset, direction)
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
    private let candidateBadge = NSView()
    private let placeholderLabel = NSTextField(
        labelWithString:
            "Click a symbol to see its definition here. ⌘-click jumps to it."
    )
    private let scrollView = NSScrollView()
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
        applyBadgeStyle()
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

    var selfTestPlaceholderText: String? {
        loadViewIfNeeded()
        return placeholderLabel.stringValue
    }
    var selfTestPlaceholderVisible: Bool {
        loadViewIfNeeded()
        return placeholderLabel.selfTestIsVisibleInWindow
    }
    var selfTestReaderVisible: Bool {
        loadViewIfNeeded()
        return scrollView.selfTestIsVisibleInWindow
    }
    var selfTestCandidateVisibleWithGeometry: Bool {
        guard candidateBadge.window != nil,
              view.window != nil,
              !candidateBadge.isHiddenOrHasHiddenAncestor,
              candidateBadge.bounds.width > 0,
              candidateBadge.bounds.height > 0
        else { return false }
        let frame = candidateBadge.convert(candidateBadge.bounds, to: view)
        return view.bounds.contains(frame)
            && scrollView.selfTestIsVisibleInWindow
    }
    var selfTestHasDoubleClickOpen: Bool {
        miniReader.view.gestureRecognizers.contains {
            ($0 as? NSClickGestureRecognizer)?.numberOfClicksRequired == 2
        }
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
        pathLabel.font = .systemFont(ofSize: 12)
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)

        candidateBadge.wantsLayer = true
        candidateBadge.layer?.cornerRadius = 4
        candidateLabel.font = .systemFont(ofSize: 11, weight: .medium)
        candidateLabel.lineBreakMode = .byTruncatingTail
        candidateLabel.translatesAutoresizingMaskIntoConstraints = false
        candidateBadge.addSubview(candidateLabel)
        NSLayoutConstraint.activate([
            candidateLabel.leadingAnchor.constraint(
                equalTo: candidateBadge.leadingAnchor,
                constant: 6
            ),
            candidateLabel.trailingAnchor.constraint(
                equalTo: candidateBadge.trailingAnchor,
                constant: -6
            ),
            candidateLabel.topAnchor.constraint(
                equalTo: candidateBadge.topAnchor,
                constant: 2
            ),
            candidateLabel.bottomAnchor.constraint(
                equalTo: candidateBadge.bottomAnchor,
                constant: -2
            ),
        ])

        let header = NSStackView(views: [
            modeControl,
            previousButton,
            countLabel,
            nextButton,
            pathLabel,
            candidateBadge,
        ])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = miniReader.view
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        placeholderLabel.font = .systemFont(ofSize: 12)
        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.alignment = .center
        placeholderLabel.lineBreakMode = .byWordWrapping
        placeholderLabel.maximumNumberOfLines = 2
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false

        let container = NSVisualEffectView()
        container.material = .windowBackground
        container.blendingMode = .withinWindow
        container.state = .followsWindowActiveState
        container.addSubview(header)
        container.addSubview(scrollView)
        container.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            header.heightAnchor.constraint(equalToConstant: 30),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            placeholderLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            placeholderLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: container.leadingAnchor,
                constant: 16
            ),
            placeholderLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: container.trailingAnchor,
                constant: -16
            ),
        ])
        view = container
        miniReader.onClick = { [weak self] _, modifiers in
            guard modifiers.intersection([.command, .option, .control, .shift]) == .command,
                  let self
            else { return }
            self.openSelection()
        }
        let doubleClick = NSClickGestureRecognizer(
            target: self,
            action: #selector(openSelectedCandidate(_:))
        )
        doubleClick.numberOfClicksRequired = 2
        miniReader.view.addGestureRecognizer(doubleClick)
        render()
        observe()
    }

    func selfTestOpenSelection() {
        openSelection()
    }

    @objc private func openSelectedCandidate(_ sender: Any?) {
        openSelection()
    }

    private func openSelection() {
        guard let candidate = model.selectedCandidate else { return }
        onOpen?(candidate)
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
            candidateBadge.isHidden = false
            placeholderLabel.isHidden = true
            scrollView.isHidden = false
            applyBadgeStyle()
        } else {
            pathLabel.stringValue = ""
            candidateLabel.stringValue = ""
            countLabel.stringValue = ""
            text = ""
            highlightsSyntax = false
            candidateBadge.isHidden = true
            scrollView.isHidden = true
            placeholderLabel.isHidden = false
        }
        previousButton.isEnabled = model.candidateCount > 1
        nextButton.isEnabled = model.candidateCount > 1
        miniReader.display(document: readerDocument(text, highlightsSyntax: highlightsSyntax))
    }

    private func applyBadgeStyle() {
        let colors: (background: NSColor, foreground: NSColor) =
            switch provenanceBadgeStyle(for: candidateLabel.stringValue) {
            case .exact:
                (.systemGreen.withAlphaComponent(0.12), .systemGreen)
            case .strong:
                (.systemBlue.withAlphaComponent(0.12), .systemBlue)
            case .possible:
                (.systemOrange.withAlphaComponent(0.12), .systemOrange)
            case .fallback:
                (.quaternaryLabelColor, .secondaryLabelColor)
            }
        candidateBadge.layer?.backgroundColor = colors.background.cgColor
        candidateLabel.textColor = colors.foreground
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
