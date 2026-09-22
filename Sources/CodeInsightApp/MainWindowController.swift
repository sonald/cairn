import AppKit
import CodeInsightAppModel
import CodeInsightCore
import CodeInsightReaderCore
import CodeInsightReaderUI
import Observation
import PDFKit
import WebKit

enum ProvenanceBadgeStyle: Equatable {
    case exact
    case strong
    case possible
    case fallback
}

func provenanceBadgeStyle(for certainty: Certainty?) -> ProvenanceBadgeStyle {
    switch certainty {
    case .exact: .exact
    case .strong: .strong
    case .possible: .possible
    default: .fallback
    }
}

@MainActor
final class MainWindowController: NSWindowController, NSToolbarDelegate,
    NSToolbarItemValidation, NSWindowDelegate
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
    private let refreshIndexButton = NSButton()
    private let exactLabel = NSTextField(labelWithString: localized("main.exact.off.safe"))
    private let exactInfoButton = NSButton()
    private let exactStatusPopover = NSPopover()
    private let contextButton = NSButton(title: localized("main.context"), target: nil, action: nil)
    private let trailView = ReadingTrailView()
    private let statusBar = NSView()
    private let truncatedLabel = NSTextField(labelWithString: localized("main.results.truncated"))
    private var focusNotice: String?
    // A unique identifier per controller keeps AppKit's toolbar-family
    // synchronization from mutating sibling toolbars (closed windows from
    // earlier tests/self-tests) during profile-item add/remove, which
    // crashed with an out-of-range _currentItems assertion.
    private let toolbar = NSToolbar(
        identifier: NSToolbar.Identifier("MainToolbar-\(UUID().uuidString)")
    )
    private let recentProjectsStore: RecentProjectsStore
    private let recordsRecentProjects: Bool
    /// True for offscreen windows built by self-tests; their teardown skips
    /// scheduling asynchronous cleanup into the shared test run loop.
    private let isOffscreenTestWindow: Bool
    private let onChooseProject: () -> Void
    private let onChooseProjectLanguage: (URL, MainWindowController) -> Void
    private let onShowSettings: () -> Void
    /// Reports the controller to the application as soon as AppKit starts
    /// closing its window so routing excludes it immediately; the retained
    /// controller keeps finishing its asynchronous teardown afterwards.
    var onProjectWindowClosing: ((MainWindowController) -> Void)?
    /// Reports the controller once its asynchronous teardown finished and
    /// its project claim was released; the application drops it from the
    /// window collection here, not when the window disappears (§7.1).
    var onProjectWindowClosed: ((MainWindowController) -> Void)?
    /// Notifies the application that this window became the active project
    /// window (restore-target ordering, blank-window preference).
    var onProjectWindowBecameActive: ((MainWindowController) -> Void)?
    /// Claimed project identity (standardized, symlink-resolved). Set before
    /// any asynchronous load starts and kept through the whole closing
    /// sequence; `nil` while the window shows the welcome surface.
    private(set) var projectURL: URL?
    /// True once window closing was approved; rejects new project work.
    private(set) var isClosing = false
    /// Waiters for the completion of an approved close (a repeated open of
    /// the same project must wait for the previous session writer to end).
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    /// The running asynchronous teardown, if one started.
    private(set) var teardownTask: Task<Void, Never>?
    /// Session anchors restored/kept even when the load later failed, used
    /// by Retry; cleared only by teardown.
    private var displayedGeneration: UInt64?
    private var displayedSnapshotID: SnapshotID?
    private var displayedNavigationGeneration: UInt64?
    nonisolated(unsafe) private var escapeMonitor: Any?
    private var palettePanel: PalettePanel?
    private var searchPanel: SearchPanel?
    private var bookmarkPanel: BookmarkPanel?
    private var commitPickerPopover: CommitPickerPopover?
    private var compareCommitPickerPopover: CommitPickerPopover?
    private var panelPreset = PanelPresetModel.reading
    private var readingSetLayoutActive = false
    private var lastOpenedProjectRoot: URL?
    private var lastOpenedProjectLanguages: [LanguageID]?
    var lastOpenedProjectLanguage: LanguageID? {
        lastOpenedProjectLanguages?.first
    }
    private var pendingRecentProjectRoot: URL?
    private var pendingRecentProjectLanguages: [LanguageID]?
    var pendingRecentProjectLanguage: LanguageID? {
        pendingRecentProjectLanguages?.first
    }
    private var pendingTabRestore: TabStripModel.Tab?
    private var sessionRestoreTask: Task<Void, Never>?
    private var outlineFollowArbitration = OutlineFollowArbitration()
    private var currentReaderSettings = ReaderSettings()
    private let layoutDefaults: UserDefaults?
    private var contextVisibilityOverride: Bool?
    /// Per-window frame autosave: project windows derive it from the project
    /// identity so siblings never fight over `CodeInsightMainWindow`; blank
    /// windows keep the legacy name only when nothing better applies.
    private let frameAutosaveName: NSWindow.FrameAutosaveName?

    init(
        model: AppModel,
        settings: ReaderSettings,
        offscreen: Bool,
        measuresIdleFootprint: Bool = false,
        recentProjectsStore: RecentProjectsStore = RecentProjectsStore(),
        recordsRecentProjects: Bool = false,
        layoutDefaults: UserDefaults? = nil,
        frameAutosaveName: NSWindow.FrameAutosaveName? = nil,
        onChooseProject: @escaping () -> Void = {},
        onChooseProjectLanguage: @escaping (URL, MainWindowController) -> Void = {
            _, _ in
        },
        onShowSettings: @escaping () -> Void = {}
    ) {
        self.model = model
        currentReaderSettings = settings
        self.recentProjectsStore = recentProjectsStore
        self.recordsRecentProjects = recordsRecentProjects
        self.isOffscreenTestWindow = offscreen
        self.layoutDefaults = layoutDefaults ?? (offscreen ? nil : .standard)
        contextVisibilityOverride = self.layoutDefaults?.object(forKey: "Cairn.contextVisible") as? Bool
        self.onChooseProject = onChooseProject
        self.onChooseProjectLanguage = onChooseProjectLanguage
        self.onShowSettings = onShowSettings
        self.frameAutosaveName = frameAutosaveName
        sidebarController.setSplitAutosaveName(
            offscreen ? "CodeInsightSidebarSplit.SelfTest" : "CodeInsightSidebarSplit"
        )
        contextController = ContextWindowViewController(model: model.contextWindow)
        relationController = RelationWindowController(
            model: model.relationTree,
            verificationReadiness: { [weak model] in
                model?.exactCoordinator.readiness ?? .off("no project")
            },
            capturedSource: { [weak model] path in
                guard let model else { return nil }
                if exactLocationIsInDependency(path) {
                    guard let data = try? Data(
                        contentsOf: URL(fileURLWithPath: path),
                        options: .mappedIfSafe
                    ) else { return nil }
                    let bytes = Array(data)
                    return (
                        ContentID.sha256(of: bytes),
                        bytes,
                        ReadingSetExcerpt.SourceKind.dependencyCaptured,
                        nil
                    )
                }
                guard let source = model.capturedProjectSource(at: path)
                else { return nil }
                return (
                    source.contentID,
                    source.bytes,
                    model.currentRevision == nil
                        ? ReadingSetExcerpt.SourceKind.worktreeCaptured
                        : .projectCommit,
                    model.currentRevision
                )
            },
            languageMode: { [weak model] path in
                guard let model, let root = model.projectRoot else { return nil }
                let file = exactLocationIsInDependency(path)
                    ? URL(fileURLWithPath: path)
                    : root.appendingPathComponent(path)
                return model.languageMode(for: file)
            }
        )
        relationController.view.frame.size.width = 360
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

        // §3.1: compare columns keep at least 320pt each.
        primaryReaderItem.minimumThickness = 320
        primaryReaderItem.canCollapse = false
        secondaryReaderItem.minimumThickness = 320
        secondaryReaderItem.canCollapse = true
        secondaryReaderItem.isCollapsed = true
        readerSplitController.addSplitViewItem(primaryReaderItem)
        readerSplitController.addSplitViewItem(secondaryReaderItem)

        sidebarItem.minimumThickness = 180
        sidebarItem.canCollapse = true
        // §3.1: the independent right area keeps at least 300pt. The
        // Reader's 480pt floor is enforced by the sidebar adaptation, not a
        // hard constraint — a required minimum alongside the other panes
        // would grow the window instead of folding the sidebar.
        readerGroupItem.minimumThickness = 300
        readerGroupItem.canCollapse = false
        relationItem.minimumThickness = 300
        relationItem.automaticMaximumThickness = 380
        relationItem.canCollapse = true
        upperSplitController.addSplitViewItem(sidebarItem)
        upperSplitController.addSplitViewItem(readerGroupItem)
        upperSplitController.addSplitViewItem(relationItem)
        relationItem.isCollapsed = true

        let upperItem = NSSplitViewItem(viewController: upperSplitController)
        upperItem.minimumThickness = 300
        contextItem.minimumThickness = 120
        contextItem.automaticMaximumThickness = 280
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

        indexLabel.font = .systemFont(ofSize: 12)
        indexLabel.textColor = .secondaryLabelColor
        indexLabel.setAccessibilityLabel(localized("main.index.status"))
        indexLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        refreshIndexButton.bezelStyle = .rounded
        refreshIndexButton.font = .systemFont(ofSize: 12)
        refreshIndexButton.controlSize = .small
        refreshIndexButton.title = localized("main.refresh.index")
        refreshIndexButton.toolTip = localized("main.recapture.the.working.tree.as.a.new.index.generation")
        refreshIndexButton.isHidden = true
        refreshIndexButton.setAccessibilityLabel(localized("main.refresh.index"))
        truncatedLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        truncatedLabel.textColor = .systemOrange
        truncatedLabel.translatesAutoresizingMaskIntoConstraints = false
        truncatedLabel.drawsBackground = true
        truncatedLabel.backgroundColor = .systemOrange.withAlphaComponent(0.12)
        truncatedLabel.alignment = .center
        truncatedLabel.wantsLayer = true
        truncatedLabel.layer?.cornerRadius = 4
        truncatedLabel.setAccessibilityLabel(localized("main.query.completeness"))
        NSLayoutConstraint.activate([
            truncatedLabel.widthAnchor.constraint(
                equalToConstant: truncatedLabel.intrinsicContentSize.width + 12
            ),
            truncatedLabel.heightAnchor.constraint(equalToConstant: 18),
        ])
        exactLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        exactLabel.lineBreakMode = .byTruncatingMiddle
        exactLabel.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        exactLabel.setAccessibilityLabel(localized("main.exact.provider.status"))
        exactInfoButton.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: localized("main.analysis.status.details"))
        exactInfoButton.isBordered = false
        exactInfoButton.action = #selector(showExactStatusDetails(_:))
        exactInfoButton.toolTip = localized("main.analysis.status.and.available.features")
        exactInfoButton.setAccessibilityLabel(localized("main.analysis.status.details"))
        contextButton.isBordered = false
        contextButton.font = .systemFont(ofSize: 11)
        contextButton.image = NSImage(systemSymbolName: "rectangle.bottomthird.inset.filled", accessibilityDescription: nil)
        contextButton.imagePosition = .imageLeading
        contextButton.action = #selector(toggleContext(_:))
        contextButton.toolTip = localized("main.show.or.hide.the.definition.context")
        contextButton.setAccessibilityLabel(localized("main.show.definition.context"))

        let statusStack = NSStackView()
        statusStack.setViews([contextButton, indexLabel, refreshIndexButton], in: .leading)
        statusStack.setViews([truncatedLabel], in: .center)
        statusStack.setViews([exactLabel, exactInfoButton], in: .trailing)
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        statusStack.orientation = .horizontal
        statusStack.alignment = .centerY
        statusStack.spacing = 12
        let contentStack = NSStackView(
            views: [trailView, contentSplitController.view, statusBar]
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
            trailView.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            trailView.heightAnchor.constraint(equalToConstant: 26),
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
        window.setContentSize(frame.size)
        super.init(window: window)
        exactInfoButton.target = self
        contextButton.target = self
        window.delegate = self
        refreshIndexButton.target = self
        refreshIndexButton.action = #selector(refreshProjectIndex(_:))
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self, weak window] event in
            guard event.keyCode == 53,
                  event.window === window,
                  let self
            else { return event }
            if self.isFindBarVisible {
                _ = self.closeFindBar()
                return nil
            }
            if self.isFocusMode {
                _ = self.toggleFocusCurrentScope()
                return nil
            }
            return event
        }
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        if !measuresIdleFootprint {
            window.toolbarStyle = .unifiedCompact
            window.titleVisibility = .hidden
            window.toolbar = toolbar
        }
        if !offscreen {
            if let frameAutosaveName {
                window.setFrameAutosaveName(frameAutosaveName)
            } else {
                window.center()
                window.setFrameAutosaveName("CodeInsightMainWindow")
            }
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
            navigate(to: file, byteOffset: offset, cause: .outline)
        }
        readerController.onOpenScope = sidebarController.onOpenOutline
        readerController.onRevealPath = { [weak self] url in
            guard let self else { return }
            sidebarItem.isCollapsed = false
            sidebarController.revealPath(url)
        }
        readerController.onTokenClick = { [weak self] offset, commandClick in
            self?.handleReaderClick(offset: offset, commandClick: commandClick)
        }
        readerController.onOutlineChange = { [weak self] facets in
            guard let self else { return }
            sidebarController.setOutline(facets, file: model.selectedFile)
            if let offset = readerController.currentReadingPosition()?.byteOffset {
                sidebarController.highlightOutline(at: offset)
            }
        }
        readerController.onReadingPositionChange = { [weak self] offset in
            guard let self else { return }
            model.tabStrip.updateActiveScroll(offset)
            captureActiveTabState()
            model.scheduleSessionCheckpoint(panelPreset: panelPreset)
        }
        readerController.onOutlineFollowPositionChange = { [weak self] offset in
            guard let self, outlineFollowArbitration.suppressedBy == nil else {
                return
            }
            sidebarController.highlightOutline(at: offset)
        }
        readerController.onLiveScroll = { [weak self] in
            self?.outlineFollowArbitration.didLiveScroll()
        }
        readerController.onFocusNotice = { [weak self] message in
            self?.focusNotice = message
            self?.renderStatusBar()
        }
        readerController.onSelectionChange = { [weak self] offset in
            guard let self else { return }
            sidebarController.highlightOutline(at: offset)
            model.tabStrip.updateActiveSelection(offset)
            captureActiveTabState()
            model.scheduleSessionCheckpoint(panelPreset: panelPreset)
        }
        readerController.onDocumentChange = { [weak self] file, document in
            guard let self else { return }
            model.tabStrip.setActiveDocument(document, for: file)
            captureActiveTabState()
            model.scheduleSessionCheckpoint(panelPreset: panelPreset)
        }
        readerController.onOpenPreviewLink = { [weak self] url in
            self?.openPreviewLink(url)
        }
        readerController.onReadingSetScrollChange = { [weak self] offset in
            guard let self else { return }
            model.tabStrip.updateActiveReadingSetScroll(offset)
            model.scheduleSessionCheckpoint(panelPreset: panelPreset)
        }
        readerController.onShowRelation = { [weak self] offset, direction in
            self?.handleReaderRelation(offset: offset, direction: direction)
        }
        readerController.onCopyPathLine = { [weak model] file, line in
            guard let model else { return }
            let value = Self.pathLineText(
                for: file,
                under: model.fileTree?.root,
                line: line
            )
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([value as NSString])
        }
        readerController.onRevealInFinder = { file in
            NSWorkspace.shared.activateFileViewerSelecting([file])
        }
        secondaryReaderController.onChooseCompareVersion = { [weak self] in
            self?.showCompareCommitPicker()
        }
        secondaryReaderController.onCloseComparison = { [weak self] in
            self?.closeComparison()
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
        relationController.onOpen = { [weak self] node in
            self?.open(node)
        }
        relationController.onOpenReadingSet = {
            [weak self] title, excerpts, skippedReasons in
            guard let self else { return }
            captureActiveTabState()
            let evictsTab = model.tabStrip.tabs.count == model.tabStrip.maximumCount
            if evictsTab { model.cancelPendingSessionCheckpoint() }
            model.openReadingSet(
                title: title,
                excerpts: excerpts,
                skippedReasons: skippedReasons
            )
            pendingTabRestore = model.tabStrip.activeTab
            render()
            if evictsTab {
                checkpointSessionSynchronously(allowsPendingTopology: true)
            }
        }
        readerController.onViewReadingSetEvidence = { [weak self, weak model] index in
            guard let self,
                  case .readingSet(_, let excerpts) = model?.tabStrip.activeTab?.content,
                  excerpts.indices.contains(index)
            else { return }
            relationItem.isCollapsed = false
            relationController.showFrozenInspector(excerpts[index].inspector)
        }
        readerController.onOpenReadingSetExcerpt = { [weak self, weak model] index in
            guard let self, let model,
                  case .readingSet(_, let excerpts) = model.tabStrip.activeTab?.content,
                  excerpts.indices.contains(index)
            else { return }
            captureActiveTabState()
            let mayEvictTab = model.tabStrip.tabs.count == model.tabStrip.maximumCount
            if mayEvictTab { model.cancelPendingSessionCheckpoint() }
            model.openReadingSetExcerpt(excerpts[index])
            pendingTabRestore = model.tabStrip.activeTab
            render()
            if mayEvictTab {
                checkpointSessionSynchronously(allowsPendingTopology: true)
            }
        }
        readerController.onExpandReadingSetExcerpt = { [weak self, weak model] index in
            guard let self, let model,
                  case .readingSet(_, let excerpts) = model.tabStrip.activeTab?.content,
                  excerpts.indices.contains(index),
                  let bytes = model.readingSetSources(for: [excerpts[index]]).first ?? nil,
                  let expanded = expandedReadingSetExcerpt(
                      excerpts[index],
                      bytes: bytes
                  )
            else { return }
            captureActiveTabState()
            model.tabStrip.updateActiveReadingSetExcerpt(at: index, to: expanded)
            render()
        }
        relationController.onTreeChange = { [weak self] in
            self?.renderStatusBar()
            self?.renderTrail()
        }
        trailView.onRestore = { [weak model] id in
            model?.restoreTrailNode(id)
        }
        trailView.onOpenReadingSet = { [weak self, weak model] id in
            guard let self, let model else { return }
            let frozen = model.trailReadingSet(to: id)
            captureActiveTabState()
            let evictsTab = model.tabStrip.tabs.count == model.tabStrip.maximumCount
            if evictsTab { model.cancelPendingSessionCheckpoint() }
            model.openReadingSet(
                title: frozen.title,
                excerpts: frozen.excerpts,
                skippedReasons: frozen.skippedReasons
            )
            pendingTabRestore = model.tabStrip.activeTab
            render()
            if evictsTab {
                checkpointSessionSynchronously(allowsPendingTopology: true)
            }
        }
        profileButton.translatesAutoresizingMaskIntoConstraints = false
        // Bounded instead of fixed so a long analysis-profile title cannot
        // demand pane width; the title truncates and the full text lives in
        // the menu representation.
        profileButton.cell?.truncatesLastVisibleLine = true
        profileButton.cell?.wraps = false
        NSLayoutConstraint.activate([
            profileButton.widthAnchor.constraint(
                lessThanOrEqualToConstant: 180
            ),
            profileButton.heightAnchor.constraint(equalToConstant: 28),
        ])
        applyReaderSettings(settings)
        readerController.configureTabs(
            model.tabStrip,
            onActivate: { [weak self] in self?.activateTab($0) },
            onClose: { [weak self] in self?.closeTab($0) }
        )
        render()
        applyPanelPreset(.reading, restoring: true)
        observe()
    }

    deinit {
        sessionRestoreTask?.cancel()
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func openProject(root: URL) {
        openProject(root: root, language: .rust)
    }

    func openProject(root: URL, language: LanguageID) {
        openProjectWithSavedSession(
            root: root,
            languages: [language],
            overridesSavedLanguages: true
        )
    }

    func openProject(root: URL, languages: [LanguageID]) {
        guard let normalized = try? LanguageMode.normalize(languages: languages)
        else { return }
        openProjectWithSavedSession(
            root: root,
            languages: normalized,
            overridesSavedLanguages: true
        )
    }

    func openRecentProject(_ root: URL, forcingReopen: Bool = false) {
        openProjectWithSavedSession(
            root: root,
            languages: recentProjectsStore.languages(
                for: root.standardizedFileURL.path
            ),
            overridesSavedLanguages: false,
            forcingReopen: forcingReopen
        )
    }

    /// Unified "user opened a project" boundary covering Open, Recent,
    /// dropped directories, and Retry: a project that is already being
    /// read just focuses its window; a project with a saved reading
    /// session restores it (an explicit language choice overrides the
    /// saved combination); otherwise it opens fresh. The outgoing project
    /// is always flushed first. The project identity is claimed before any
    /// asynchronous load starts so duplicate requests resolve to this
    /// window.
    private func openProjectWithSavedSession(
        root: URL,
        languages: [LanguageID],
        overridesSavedLanguages: Bool,
        forcingReopen: Bool = false
    ) {
        let root = root.standardizedFileURL
        claimProject(root)
        if !forcingReopen,
           model.projectRoot?.standardizedFileURL == root,
           case .ready = model.projectState,
           model.sessionLoadNotice == nil,
           !overridesSavedLanguages || model.projectLanguages == languages
        {
            window?.makeKeyAndOrderFront(nil)
            render()
            return
        }
        // Every actual reopen, including a language change on the same root,
        // captures the latest reader state before consulting the saved snapshot.
        checkpointSessionSynchronously()
        if let snapshot = model.loadSessionSnapshot(forProject: root).snapshot {
            cancelSessionRestore()
            restoreSession(
                snapshot,
                overridingLanguages: overridesSavedLanguages ? languages : nil
            )
            return
        }
        openProjectFresh(root: root, languages: languages)
    }

    private func openProjectFresh(root: URL, languages: [LanguageID]) {
        cancelSessionRestore()
        lastOpenedProjectRoot = root
        lastOpenedProjectLanguages = languages
        pendingRecentProjectRoot = root
        pendingRecentProjectLanguages = languages
        guard languages.count > 1 else {
            try? model.openProject(root: root, language: languages[0])
            render()
            return
        }
        Task {
            try? await model.openProject(root: root, languages: languages)
        }
        render()
    }

    func retryLastOpenedProject() {
        if let root = lastOpenedProjectRoot {
            openProject(
                root: root,
                languages: lastOpenedProjectLanguages ?? [.rust]
            )
        } else {
            onChooseProject()
        }
    }

    func restoreSession(
        _ snapshot: SessionCodec.Snapshot,
        overridingLanguages: [LanguageID]? = nil
    ) {
        cancelSessionRestore()
        let root = URL(
            fileURLWithPath: snapshot.projectRoot,
            isDirectory: true
        ).standardizedFileURL
        claimProject(root)
        lastOpenedProjectRoot = root
        lastOpenedProjectLanguages = overridingLanguages ?? snapshot.languages
        pendingRecentProjectRoot = root
        pendingRecentProjectLanguages = overridingLanguages ?? snapshot.languages
        if let preset = PanelPresetModel(rawValue: snapshot.panelPreset) {
            applyPanelPreset(preset, restoring: true)
        }
        sessionRestoreTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let restored = await model.restoreSession(
                snapshot,
                overridingLanguages: overridingLanguages
            )
            guard restored, !Task.isCancelled else { return }
            pendingTabRestore = model.tabStrip.activeTab
            render()
            sessionRestoreTask = nil
        }
    }

    private func cancelSessionRestore() {
        sessionRestoreTask?.cancel()
        sessionRestoreTask = nil
    }

    /// Registers the project identity this window is now responsible for.
    /// Called before any asynchronous load so a duplicate request can find
    /// this window while it is still indexing/restoring.
    func claimProject(_ root: URL) {
        let identity = root.resolvingSymlinksInPath().standardizedFileURL
        projectURL = identity
    }

    /// A blank window that claims a project adopts the project-scoped frame
    /// autosave so sibling windows stop sharing one name (§6.4). Switching
    /// away from the shared blank default is expected; a window that
    /// already carries a project-specific name keeps it.
    func adoptProjectFrameAutosave(for root: URL) {
        guard projectURL == root.resolvingSymlinksInPath().standardizedFileURL,
              let window,
              window.frameAutosaveName.isEmpty
                || window.frameAutosaveName
                    == NSWindow.FrameAutosaveName("CodeInsightMainWindow")
        else { return }
        window.setFrameAutosaveName(NSWindow.FrameAutosaveName(
            "CodeInsightMainWindow-"
                + AppModel.sessionProjectKey(for: root)
        ))
    }

    /// Releases a claim whose open never completed (cancelled language
    /// pick, terminated request) so the window returns to the blank pool
    /// and a repeat request starts over (§3.3).
    func releaseProjectClaim() {
        guard !isClosing else { return }
        projectURL = nil
        window?.setFrameAutosaveName("")
    }

    /// A window that can transparently take over an open request: it has
    /// not claimed a project and is neither opening/restoring nor closing.
    /// Showing the welcome surface alone does not make a window reusable.
    var isUnclaimedForReuse: Bool {
        projectURL == nil && !isClosing && sessionRestoreTask == nil
    }

    /// True when this controller owns `window` as its project main window
    /// or one of its tool panels/sheets; used for menu routing.
    func controls(window candidate: NSWindow?) -> Bool {
        guard let candidate else { return false }
        if candidate === window { return true }
        if let searchPanel, searchPanel.window === candidate { return true }
        if let bookmarkPanel, bookmarkPanel.window === candidate { return true }
        if let palettePanel, palettePanel.window === candidate { return true }
        if candidate.sheetParent === window { return true }
        return false
    }

    /// Resolves another window's panels the same way menu routing does;
    /// exposed for tests.
    func panelKind(of candidate: NSWindow?) -> String? {
        guard let candidate, candidate !== window else { return nil }
        if let searchPanel, searchPanel.window === candidate { return "search" }
        if let bookmarkPanel, bookmarkPanel.window === candidate {
            return "bookmarks"
        }
        if let palettePanel, palettePanel.window === candidate { return "palette" }
        if candidate.sheetParent === window { return "sheet" }
        return nil
    }

    /// Clears this project's saved reading session after an explicit
    /// confirmation: all tabs close (discarding their Reading Sets) and
    /// the navigation state is dropped; the source tree, bookmarks, and
    /// global settings are untouched.
    func confirmClearReadingSession() {
        guard model.projectRoot != nil else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = localized("main.clear.this.project.s.reading.session")
        alert.informativeText = localized("main.clear.session.detail")
        alert.addButton(withTitle: localized("main.clear.reading.session"))
        alert.addButton(withTitle: localized("main.cancel"))
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn,
                  let self, !self.isClosing else { return }
            self.clearReadingSession()
        }
    }

    func clearReadingSessionForSelfTest() {
        clearReadingSession()
    }

    private func clearReadingSession() {
        cancelSessionRestore()
        // A write failure here already surfaces through the model's
        // session save notice; the cleared in-memory state stands.
        try? model.clearSessionForCurrentProject(panelPreset: panelPreset)
        pendingTabRestore = nil
        render()
    }

    func refreshRecentProjects() {
        renderEmptyState()
    }

    func selectFileInSidebar(_ file: URL) -> Bool {
        sidebarController.selectFile(file)
    }

    func renderForSelfTest() {
        render()
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
                    self?.cancelSessionRestore()
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
    var selfTestPanelPreset: PanelPresetModel { panelPreset }
    var selfTestPanelCollapses: (Bool, Bool, Bool, Bool) {
        (
            sidebarItem.isCollapsed,
            contextItem.isCollapsed,
            relationItem.isCollapsed,
            secondaryReaderItem.isCollapsed
        )
    }
    var selfTestTabCount: Int { model.tabStrip.tabs.count }
    var selfTestActiveTabIndex: Int? { model.tabStrip.activeIndex }
    var selfTestActiveTabFile: URL? { model.tabStrip.activeTab?.fileURL }
    var selfTestActiveTabSelectionByteOffset: UInt32? {
        model.tabStrip.activeTab?.selectionByteOffset
    }
    var selfTestReaderPlaceholderText: String? {
        readerController.selfTestPlaceholderText
    }
    var selfTestReaderPreviewKind: String? {
        readerController.selfTestPreviewState.kind
    }
    var selfTestReaderPreviewText: String? {
        readerController.selfTestPreviewState.renderedText
    }
    var selfTestReaderHTMLFinished: Bool {
        readerController.selfTestReaderHTMLFinished
    }
    var selfTestReaderHTMLLoadError: String? {
        readerController.selfTestReaderHTMLLoadError
    }
    var selfTestReaderPlaceholderVisible: Bool {
        readerController.selfTestPlaceholderVisible
    }
    var selfTestReaderSourceVisible: Bool {
        readerController.selfTestPreviewState.sourceVisible
    }
    var selfTestReadingByteOffset: UInt32? {
        readerController.currentReadingPosition()?.byteOffset
    }
    var selfTestReaderCaretByteOffset: UInt32? {
        readerController.selfTestReaderCaretByteOffset
    }
    var selfTestReadingGeometry: (
        scrollFrame: NSRect,
        clipFrame: NSRect,
        contentFrame: NSRect,
        rulerFrame: NSRect,
        windowContentFrame: NSRect,
        hasRuler: Bool,
        rulerThickness: CGFloat,
        firstGlyphGap: CGFloat?
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
            geometry.rulerThickness,
            geometry.firstGlyphGap
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
    var selfTestPrimarySelectionRange: NSRange? {
        readerController.selfTestPrimarySelectionRange
    }
    var selfTestSelectedOutlineRow: Int {
        sidebarController.selfTestSelectedOutlineRow
    }
    func selfTestNavigate(to file: URL, byteOffset: UInt32) {
        navigate(to: file, byteOffset: byteOffset)
    }
    @discardableResult
    func selfTestOpenPreviewLink(_ url: URL) -> Bool {
        openPreviewLink(url)
    }
    @discardableResult
    func selfTestActivatePreviewLink(at index: Int) -> Bool {
        readerController.selfTestActivatePreviewLink(at: index)
    }
    func selfTestEmitOutlineFollow(at byteOffset: UInt32) {
        readerController.selfTestEmitOutlineFollow(at: byteOffset)
    }
    func selfTestPostLiveScroll() {
        readerController.selfTestPostLiveScroll()
    }

    var selfTestReferenceScannedCount: Int {
        readerController.selfTestReferenceScannedCount
    }
    var selfTestTabGeometry: (
        stripFrame: NSRect,
        headerFrame: NSRect,
        controlFrame: NSRect,
        scopeFrame: NSRect,
        readerFrame: NSRect,
        containerFrame: NSRect,
        contentFrame: NSRect,
        stripHidden: Bool,
        scopeHidden: Bool,
        stripHiddenOrHasHiddenAncestor: Bool
    ) {
        let geometry = readerController.selfTestTabGeometry
        let contentFrame = window?.contentView.map {
            $0.convert($0.bounds, to: nil)
        } ?? .zero
        return (
            geometry.stripFrame,
            geometry.headerFrame,
            geometry.controlFrame,
            geometry.scopeFrame,
            geometry.readerFrame,
            geometry.containerFrame,
            contentFrame,
            geometry.stripHidden,
            geometry.scopeHidden,
            geometry.stripHiddenOrHasHiddenAncestor
        )
    }
    var selectedSidebarFile: URL? { sidebarController.selectedFile }
    var readerHasReadingPosition: Bool {
        readerController.currentReadingPosition() != nil
    }
    var selfTestContextSummary: String? { contextController.selfTestSummary }
    var selfTestContextProvenance: String? {
        // S6 moved full provider/environment detail to the tooltip; checks
        // about provenance content read the complete source.
        contextController.selfTestProvenanceTooltip
            ?? contextController.selfTestProvenance
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
    func selfTestSetDefaultSidebarDivider() {
        sidebarController.selfTestSetDefaultSidebarDivider()
    }
    var selfTestSidebarDividerPersistsAcrossRebuild: Bool {
        sidebarController.selfTestDividerPersistsAcrossRebuild()
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
    var selfTestListPaneHidden: Bool {
        relationController.selfTestListPaneHidden
    }
    var selfTestResolutionInspectorVisible: Bool {
        relationController.selfTestInspectorVisible
    }
    func selfTestCloseResolutionInspector() {
        relationController.selfTestCloseInspector()
    }
    var selfTestExactStatusText: String { exactLabel.stringValue }
    var selfTestSidebarPaneCollapsed: Bool { sidebarItem.isCollapsed }
    var selfTestReaderGroupWidth: CGFloat {
        readerGroupItem.viewController.view.frame.width
    }
    var selfTestRelationsPaneWidth: CGFloat {
        relationItem.viewController.view.frame.width
    }
    var selfTestContextPaneCollapsed: Bool { contextItem.isCollapsed }
    var selfTestRelationsPaneCollapsed: Bool { relationItem.isCollapsed }
    var selfTestOutlineHidden: Bool {
        sidebarController.selfTestOutlineHidden
    }
    var selfTestTrailBarVisible: Bool {
        selfTestViewIsVisibleInWindow(trailView)
    }
    var selfTestTrailBreadcrumbTitles: [String] {
        trailView.breadcrumbTitles
    }
    var selfTestTrailBreadcrumbText: String {
        trailView.breadcrumbText
    }
    var selfTestTrailBranchCount: Int { trailView.branchCount }
    var selfTestTrailBarAccessibility: (
        label: String,
        value: String,
        role: String,
        valueSettable: Bool
    ) {
        (
            trailView.accessibilityLabel() ?? "",
            trailView.accessibilityValue() as? String ?? "",
            trailView.accessibilityRole()?.rawValue ?? "",
            trailView.isAccessibilitySelectorAllowed(
                NSSelectorFromString("setAccessibilityValue:")
            )
        )
    }
    var selfTestTrailBarFrameInContentView: NSRect {
        guard let contentView = window?.contentView else { return .zero }
        return trailView.convert(trailView.bounds, to: contentView)
    }
    var selfTestTrailPopoverVisible: Bool { trailView.isPopoverShown }
    var selfTestTrailPopoverPaths: [String] { trailView.popoverPaths }
    var selfTestTrailDetailText: String { trailView.detailValue }
    var selfTestTrailSnapshotBoundaryCount: Int {
        trailView.snapshotBoundaryCount
    }
    var selfTestTrailPopoverContentView: NSView? {
        trailView.popoverContentView
    }
    var selfTestSelectedTrailNodeID: TrailNodeID? {
        trailView.selectedTrailNodeID
    }
    func selfTestShowTrailPopover() { trailView.showPopover() }
    func selfTestCloseTrailPopover() { trailView.closePopover() }
    func selfTestSelectTrailNode(path: String) -> Bool {
        trailView.selectNode(path: path)
    }
    func selfTestRestoreSelectedTrailNode() {
        trailView.restoreSelectedNode()
    }
    var selfTestTrailReadingSetButtonState: (
        title: String,
        enabled: Bool,
        label: String
    ) {
        trailView.readingSetButtonState
    }
    func selfTestOpenSelectedTrailAsReadingSet() {
        trailView.openSelectedNodeAsReadingSet()
    }
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
    var selfTestStatusBarBackgroundColor: NSColor? {
        statusBar.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))
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
    var selfTestExactStatusAllowsHorizontalCompression: Bool {
        exactLabel.contentCompressionResistancePriority(for: .horizontal)
            < .defaultHigh
            && exactLabel.lineBreakMode != .byClipping
    }
    var selfTestSidebarRowGeometry: (height: CGFloat, spacing: NSSize) {
        sidebarController.selfTestRowGeometry
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
    var selfTestPossibleRelationDisclosureTitle: String? {
        relationController.selfTestPossibleDisclosureTitle
    }
    var selfTestPossibleRelationDisclosureFrame: NSRect {
        relationController.selfTestPossibleDisclosureFrame
    }
    func selfTestExpandPossibleRelations() -> Bool {
        relationController.selfTestExpandPossibleMatches()
    }
    var selfTestVisibleRelationText: [String] {
        relationController.selfTestVisibleText()
    }
    func selfTestRelationBadgeFrame(titled title: String) -> NSRect {
        relationController.selfTestBadgeFrame(titled: title)
    }
    func selfTestRelationBadgeToolTip(titled title: String) -> String? {
        relationController.selfTestBadgeToolTip(titled: title)
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
    var selfTestRelationWholeTreeReloads: Int {
        relationController.selfTestWholeTreeReloads
    }
    var selfTestRelationNodeReloads: Int {
        relationController.selfTestNodeReloads
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
    var selfTestBookmarkMarkerLines: [Int] { readerController.bookmarkMarkerLines }
    var selfTestBookmarkMarkerAccessibilityLabel: String? {
        readerController.bookmarkMarkerAccessibilityLabel
    }
    func selfTestLeftReaderFontName(at byteOffset: UInt32) -> String? {
        readerController.selfTestFontName(at: byteOffset)
    }
    func selfTestLeftReaderFontSize(at byteOffset: UInt32) -> CGFloat? {
        readerController.selfTestFontSize(at: byteOffset)
    }
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
    var selfTestEmptyStateFailureReason: String? {
        readerController.selfTestEmptyStateFailureReason
    }
    var selfTestEmptyStateReasonIsSelectable: Bool {
        readerController.selfTestEmptyStateReasonIsSelectable
    }
    var selfTestEmptyStateChooseFolderActionAvailable: Bool {
        readerController.selfTestEmptyStateChooseFolderActionAvailable
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
        return !container.visibleRect.intersection(profileButton.frame).isEmpty
    }
    var selfTestProfileButtonFrame: NSRect { profileButton.frame }
    var selfTestProfileContainerBounds: NSRect {
        profileButton.superview?.bounds ?? .zero
    }
    var selfTestProfileMenuTitles: [String] {
        makeProfileMenu().items.compactMap(\.title)
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
        showPalette(prefill: "#", lockMode: true)
    }

    func showPalette(prefill: String = "", lockMode: Bool = false) {
        if palettePanel == nil {
            palettePanel = PalettePanel(
                appModel: model,
                settings: currentReaderSettings
            ) { [weak self] file, offset, expectedContentID in
                self?.navigate(
                    to: file,
                    byteOffset: offset,
                    cause: .search,
                    expectedContentID: expectedContentID
                )
            }
        }
        palettePanel?.show(
            prefill: prefill,
            lockMode: lockMode,
            relativeTo: window
        )
    }

    func showProjectSearch() {
        if searchPanel == nil {
            searchPanel = SearchPanel(
                appModel: model
            ) { [weak self] file, offset, expectedContentID in
                self?.navigate(
                    to: file,
                    byteOffset: offset,
                    cause: .search,
                    expectedContentID: expectedContentID
                )
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
        truncationDiagnostic: [String: String]?,
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

    var canCloseComparison: Bool {
        model.compare.rightRevision != nil || !secondaryReaderItem.isCollapsed
    }

    func closeComparison() {
        guard canCloseComparison else { return }
        savePanelLayout()
        model.clearCompare()
        applyPanelPreset(.reading, restoring: true)
        render()
    }

    func toggleRelations() {
        savePanelLayout()
        if relationItem.isCollapsed {
            openRelationsPane()
        } else {
            relationItem.isCollapsed = true
            updateRelationsWidthAdaptation()
        }
        savePanelLayout()
    }

    @objc func toggleContext(_ sender: Any?) {
        guard contentSurfaceMode == .source, !readingSetLayoutActive else { return }
        savePanelLayout()
        contextVisibilityOverride = contextItem.isCollapsed
        layoutDefaults?.set(contextVisibilityOverride, forKey: "Cairn.contextVisible")
        updateContextVisibility()
        savePanelLayout()
    }

    private func updateContextVisibility() {
        guard contentSurfaceMode == .source, !readingSetLayoutActive else { return }
        let hasContext = model.contextWindow.candidateCount > 0
            || model.contextWindow.mode == .pinned
        let visible = contextVisibilityOverride ?? (panelPreset != .focus && hasContext)
        contextItem.isCollapsed = !visible
        contextButton.setAccessibilityLabel(visible ? localized("main.hide.definition.context") : localized("main.show.definition.context"))
        contextButton.contentTintColor = visible ? .controlAccentColor : .secondaryLabelColor
    }

    @objc private func showExactStatusDetails(_ sender: NSButton) {
        model.exactCoordinator.refreshReadiness()
        renderExactStatus()
        let popover = exactStatusPopover
        let controller = NSViewController()
        let detail = NSTextView(frame: NSRect(x: 0, y: 0, width: 328, height: 300))
        detail.string = exactLabel.stringValue + "\n\n"
            + (exactLabel.toolTip ?? localized("main.provider.information.is.not.available.yet"))
            + "\n\n" + localized("main.limited.analysis.detail")
        detail.isEditable = false
        detail.isSelectable = true
        detail.font = .systemFont(ofSize: 12)
        detail.drawsBackground = false
        detail.textContainer?.widthTracksTextView = true
        detail.autoresizingMask = [.width]
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = detail
        controller.view = NSView()
        let restart = NSButton(title: localized("main.restart.analysis"), target: self, action: #selector(restartExactAnalysis(_:)))
        restart.bezelStyle = .rounded
        restart.isEnabled = model.snapshotPhase == .fullReady
            && model.exactCoordinator.readiness != .preparing
        let stack = NSStackView(views: [scroll, restart])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: controller.view.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor, constant: -16),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 300),
            controller.view.widthAnchor.constraint(equalToConstant: 360),
        ])
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    @objc private func restartExactAnalysis(_ sender: NSButton) {
        exactStatusPopover.close()
        model.restartExactAnalysis()
    }

    var canShowResolutionInspector: Bool {
        relationController.canInspectSelection
    }

    func showResolutionInspector() {
        openRelationsPane()
        _ = relationController.showSelectedInspector()
    }

    var canShowReadingTrail: Bool {
        !model.readingTrail.nodes.isEmpty
    }

    func showReadingTrail() {
        trailView.showPopover()
    }

    func applyPanelPreset(_ preset: PanelPresetModel, restoring: Bool = false) {
        panelPreset = preset
        if !restoring {
            layoutDefaults?.removeObject(forKey: panelLayoutKey)
            contextVisibilityOverride = nil
            layoutDefaults?.removeObject(forKey: "Cairn.contextVisible")
        }
        // An explicit preset choice replaces any layout captured for a
        // round-trip through a non-source surface.
        savedSourceSurfaceLayout = nil
        sidebarTemporarilyCollapsedForRelations = false
        applyPanelLayout(
            readingSetLayoutActive ? PanelPresetModel.focus.layout : (restoredPanelLayout() ?? preset.layout)
        )
        contentSurfaceMode = nil
        updateContentSurfaceIfNeeded()
        updateContextVisibility()
        model.scheduleSessionCheckpoint(panelPreset: panelPreset)
    }

    /// Which surface the window currently presents. Derived from project
    /// state and the selected file's kind; drives temporary panel exit per
    /// §3.1 without writing back into the user's preset.
    private enum ContentSurfaceMode: Equatable {
        case noProject
        case nonSource
        case source
    }

    private var contentSurfaceMode: ContentSurfaceMode?
    @ObservationIgnored private var savedSourceSurfaceLayout: PanelLayoutDescription?

    private func currentContentSurfaceMode() -> ContentSurfaceMode {
        switch model.projectState {
        case .empty, .failed:
            return .noProject
        case .indexing, .ready:
            if model.tabStrip.activeTab?.fileURL == nil {
                return .source
            }
            guard let file = model.selectedFile else { return .source }
            return model.languageMode(for: file) == nil ? .nonSource : .source
        }
    }

    @ObservationIgnored
    private var sidebarTemporarilyCollapsedForRelations = false

    /// Opens the Relations pane without ever growing the window: the
    /// sidebar folds first when the reader would fall below its readable
    /// floor, and the pane's restored thickness is clamped to the width
    /// that fits beside the reader (§3.1).
    private func openRelationsPane() {
        let upperSplit = upperSplitController.splitView
        upperSplit.layoutSubtreeIfNeeded()
        let available = min(
            upperSplit.bounds.width,
            window?.contentLayoutRect.width ?? upperSplit.bounds.width
        )
        let sidebarWidth = sidebarItem.isCollapsed
            ? 0
            : (upperSplit.arrangedSubviews.first?.frame.width ?? 0)
        if !sidebarItem.isCollapsed,
           available - sidebarWidth - relationItem.minimumThickness < 480
        {
            sidebarItem.isCollapsed = true
            sidebarTemporarilyCollapsedForRelations = true
        }
        let fittedSidebar = sidebarItem.isCollapsed
            ? 0
            : (upperSplit.arrangedSubviews.first?.frame.width ?? 0)
        let target = max(
            relationItem.minimumThickness,
            available - fittedSidebar - 480 - upperSplit.dividerThickness
        )
        let frameBefore = window?.frame
        // Restoring a collapsed pane re-applies its previous thickness in
        // the same layout pass. Cap the pane at the width that fits beside
        // the reader before it opens, and keep the cap while the window is
        // narrow; the frame guard enforces the §3.1 rule that the window
        // never grows to satisfy pane layout.
        capRelationsPane(width: target)
        relationItem.isCollapsed = false
        upperSplit.layoutSubtreeIfNeeded()
        let preferredWidth = (restoredPanelLayout()?.relationsFraction ?? 0) * available
        upperSplit.setPosition(available - min(target, max(300, preferredWidth > 0 ? preferredWidth : 360)), ofDividerAt: 1)
        if let frameBefore,
           window?.frame.width ?? 0 > frameBefore.width + 0.5
        {
            window?.setFrame(frameBefore, display: false)
            upperSplit.layoutSubtreeIfNeeded()
        }
    }

    /// Caps the Relations pane's maximum thickness while the window cannot
    /// fit its natural width beside a readable Reader; a nil width releases
    /// the cap. maximumThickness is enforced by the split view itself, so
    /// the cap survives arbitrary layout passes.
    private func capRelationsPane(width: CGFloat?) {
        guard let width, width > 0 else {
            relationItem.maximumThickness = NSSplitViewItem.unspecifiedDimension
            return
        }
        relationItem.maximumThickness = max(
            relationItem.minimumThickness,
            width
        )
    }

    /// §3.1 relations exploration: when the Relations pane is open and the
    /// window cannot keep the Reader at its readable floor with the sidebar
    /// up, the sidebar folds temporarily and returns when Relations closes.
    /// Bound to the pane's open state, not a width band, so crossings
    /// cannot oscillate; the user's preset is never overwritten.
    private func updateRelationsWidthAdaptation() {
        guard contentSurfaceMode == .source else { return }
        if case .some(.readingSet) = model.tabStrip.activeTab?.content { return }
        let relationsOpen = !relationItem.isCollapsed
        let upperSplit = upperSplitController.splitView
        if relationsOpen {
            upperSplit.layoutSubtreeIfNeeded()
            let available = min(
                upperSplit.bounds.width,
                window?.contentLayoutRect.width ?? upperSplit.bounds.width
            )
            let sidebarWidth = sidebarItem.isCollapsed
                ? 0
                : (upperSplit.arrangedSubviews.first?.frame.width ?? 0)
            let preferredWidth = upperSplit.arrangedSubviews.last?.frame.width ?? 360
            if !sidebarItem.isCollapsed,
               available - sidebarWidth - preferredWidth
                    - upperSplit.dividerThickness < 480
            {
                sidebarItem.isCollapsed = true
                sidebarTemporarilyCollapsedForRelations = true
            }
            let sidebarWidthNow = sidebarItem.isCollapsed
                ? 0
                : (upperSplit.arrangedSubviews.first?.frame.width ?? 0)
            capRelationsPane(width: available - sidebarWidthNow - 480 - upperSplit.dividerThickness)
        } else {
            capRelationsPane(width: nil)
            if sidebarTemporarilyCollapsedForRelations {
                sidebarTemporarilyCollapsedForRelations = false
                sidebarItem.isCollapsed = false
            }
        }
    }

    func windowDidResize(_ notification: Notification) {
        window?.contentView?.layoutSubtreeIfNeeded()
        updateRelationsWidthAdaptation()
    }

    func windowDidBecomeMain(_ notification: Notification) {
        onProjectWindowBecameActive?(self)
    }

    /// Approval stage: capture the reading state and run the final
    /// checkpoint before anything is torn down. A failed save offers
    /// retry / cancel close / continue here — `windowWillClose` is too
    /// late to ask. Nothing irreversible happens yet.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isClosing { return true }
        while true {
            do {
                try checkpointSessionSynchronouslyReportingFailure()
                return true
            } catch {
                guard let window else { return true }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = localized("main.reading.session.not.saved")
                alert.informativeText =
                    localizedFormat("main.session.save.failure", projectURL?.lastPathComponent ?? localized("main.this.project"), Self.sessionSaveFailureSummary(error))
                alert.addButton(withTitle: localized("main.retry.save"))
                alert.addButton(withTitle: localized("main.close.without.saving"))
                alert.addButton(withTitle: localized("main.cancel"))
                switch alert.runModal() {
                case .alertFirstButtonReturn:
                    continue
                case .alertSecondButtonReturn:
                    return true
                default:
                    return false
                }
            }
        }
    }

    nonisolated private static func sessionSaveFailureSummary(
        _ error: any Error
    ) -> String {
        let text = String(describing: error)
        return String(text.prefix(200))
    }

    /// Approved-close stage: mark closing (routing stops here), flush what
    /// can still be flushed synchronously, then finish the asynchronous
    /// teardown (task cancellation, Exact provider exit) while the
    /// application keeps this controller alive. Idempotent.
    func windowWillClose(_ notification: Notification) {
        // Final synchronous capture happens before anything tears down;
        // failures already surfaced (and were approved) in windowShouldClose.
        beginTeardown(runFinalCheckpoint: true)
    }

    /// Shared teardown entry for window close and application termination
    /// (§7.1). The controller keeps claiming its project (and stays in the
    /// application's collection) until the asynchronous finish released it,
    /// so a repeat open of the same project waits instead of racing a
    /// second session writer. Idempotent.
    func beginTeardown(runFinalCheckpoint: Bool) {
        guard !isClosing else { return }
        isClosing = true
        if runFinalCheckpoint {
            checkpointSessionSynchronously()
        }
        savePanelLayout()
        onProjectWindowClosing?(self)
        closeAuxiliaryPanels()
        cancelSessionRestore()
        escapeMonitor.map(NSEvent.removeMonitor)
        escapeMonitor = nil
        teardownTask = Task { [weak self] in
            guard let self else { return }
            await self.model.closeProject()
            self.projectURL = nil
            self.onProjectWindowClosed?(self)
            self.resumeCloseWaiters()
        }
    }

    /// Closes every tool surface this window owns so no orphan panel
    /// outlives its project window. Panels are dismissed with orderOut:
    /// their controllers own the windows, so window.close()'s
    /// released-when-closed semantics would over-release them once the
    /// controller reference drops.
    private func closeAuxiliaryPanels() {
        palettePanel?.window?.orderOut(nil)
        palettePanel = nil
        searchPanel?.window?.orderOut(nil)
        searchPanel = nil
        bookmarkPanel?.closePanel()
        bookmarkPanel = nil
        commitPickerPopover?.dismiss()
        commitPickerPopover = nil
        compareCommitPickerPopover?.dismiss()
        compareCommitPickerPopover = nil
    }

    /// Suspends until an approved close finished its asynchronous teardown.
    func waitForCloseCompletion() async {
        guard isClosing else { return }
        await withCheckedContinuation { continuation in
            closeWaiters.append(continuation)
        }
    }

    /// Teardown entry for application termination: identical to a window
    /// close except that the terminator already ran (or explicitly skipped)
    /// the final saves, so no second checkpoint runs here. The terminator
    /// then awaits `teardownCompletion()` for every window, including ones
    /// whose close is still finishing (§7.2).
    func beginTerminateTeardown() {
        beginTeardown(runFinalCheckpoint: false)
    }

    /// Waits for this window's asynchronous teardown to finish (provider
    /// exit, cache reference release, claim release). Returns immediately
    /// when teardown never started.
    func teardownCompletion() async {
        await teardownTask?.value
    }

    private func resumeCloseWaiters() {
        let waiters = closeWaiters
        closeWaiters = []
        waiters.forEach { $0.resume() }
    }

    /// Applies the §3.1 panel exit rules when the content surface actually
    /// changes; splitter positions are only touched on transitions.
    private func updateContentSurfaceIfNeeded() {
        let mode = currentContentSurfaceMode()
        guard mode != contentSurfaceMode else { return }
        let previous = contentSurfaceMode
        if previous == .source, mode != .source, !readingSetLayoutActive {
            savePanelLayout()
            savedSourceSurfaceLayout = currentPanelLayout()
        }
        contentSurfaceMode = mode
        switch mode {
        case .noProject:
            // Brand, Open Project, and recents carry the window; panels
            // without an object of operation leave. Menus stay.
            sidebarItem.isCollapsed = true
            contextItem.isCollapsed = true
            relationItem.isCollapsed = true
            trailView.isHidden = true
        case .nonSource:
            // File tree + content preview; the symbol outline, Context,
            // Relations, and Inspector leave without touching the pinned
            // preview or the user's source layout.
            sidebarItem.isCollapsed = false
            sidebarController.setOutlineHidden(true)
            contextItem.isCollapsed = true
            relationItem.isCollapsed = true
        case .source:
            sidebarController.setOutlineHidden(false)
            trailView.isHidden = false
            if let saved = savedSourceSurfaceLayout {
                savedSourceSurfaceLayout = nil
                applyPanelLayout(saved)
            } else {
                applyPanelLayout(
                    readingSetLayoutActive
                        ? PanelPresetModel.focus.layout
                        : (restoredPanelLayout() ?? panelPreset.layout)
                )
            }
        }
    }

    /// Reads the current splitter state so a round-trip through a
    /// non-source surface restores the user's arrangement, not just the
    /// preset defaults.
    private func currentPanelLayout() -> PanelLayoutDescription {
        let base = restoredPanelLayout() ?? panelPreset.layout
        let upperSplit = upperSplitController.splitView
        let contentSplit = contentSplitController.splitView
        let readerSplit = readerSplitController.splitView
        let sidebarFraction: Double
        if !sidebarItem.isCollapsed,
           upperSplit.bounds.width > 0,
           let sidebar = upperSplit.arrangedSubviews.first
        {
            sidebarFraction = sidebar.frame.width / upperSplit.bounds.width
        } else {
            sidebarFraction = base.sidebarFraction
        }
        let relationsFraction: Double
        if !relationItem.isCollapsed,
           upperSplit.bounds.width > 0,
           let relations = upperSplit.arrangedSubviews.last
        {
            relationsFraction = relations.frame.width / upperSplit.bounds.width
        } else {
            relationsFraction = base.relationsFraction
        }
        let contextFraction: Double
        if !contextItem.isCollapsed,
           contentSplit.bounds.height > 0,
           let context = contentSplit.arrangedSubviews.last
        {
            contextFraction = context.frame.height / contentSplit.bounds.height
        } else {
            contextFraction = base.contextFraction
        }
        let secondaryFraction: Double
        if !secondaryReaderItem.isCollapsed,
           readerSplit.bounds.width > 0,
           let secondary = readerSplit.arrangedSubviews.last
        {
            secondaryFraction = secondary.frame.width / readerSplit.bounds.width
        } else {
            secondaryFraction = base.secondaryReaderFraction
        }
        return PanelLayoutDescription(
            sidebarCollapsed: sidebarItem.isCollapsed && !sidebarTemporarilyCollapsedForRelations,
            readerCollapsed: readerGroupItem.isCollapsed,
            contextCollapsed: contextItem.isCollapsed,
            relationsCollapsed: relationItem.isCollapsed,
            readerSplit: !secondaryReaderItem.isCollapsed,
            sidebarFraction: sidebarFraction,
            contextFraction: contextFraction,
            relationsFraction: relationsFraction,
            secondaryReaderFraction: secondaryFraction
        )
    }

    private func applyPanelLayout(_ layout: PanelLayoutDescription) {
        sidebarItem.isCollapsed = layout.sidebarCollapsed
        readerGroupItem.isCollapsed = layout.readerCollapsed
        contextItem.isCollapsed = layout.contextCollapsed
        relationItem.isCollapsed = layout.relationsCollapsed
        secondaryReaderItem.isCollapsed = !layout.readerSplit

        // Keep auxiliary widths steady while the Reader takes available space.
        // The narrow-window adaptation above preserves its readable floor.
        sidebarItem.holdingPriority = .init(rawValue: 253)
        readerGroupItem.holdingPriority = .init(rawValue: 250)
        relationItem.holdingPriority = .init(rawValue: 252)
        contextItem.holdingPriority = .init(rawValue: 250)
        secondaryReaderItem.holdingPriority = .init(rawValue: 250)
        applyPanelSizes(layout)
        DispatchQueue.main.async { [weak self] in
            self?.applyPanelSizes(layout)
            self?.updateContextVisibility()
        }
    }

    private var panelLayoutKey: String { "Cairn.panelLayout.\(panelPreset.rawValue)" }

    private func restoredPanelLayout() -> PanelLayoutDescription? {
        guard let data = layoutDefaults?.data(forKey: panelLayoutKey),
              let layout = try? JSONDecoder().decode(PanelLayoutDescription.self, from: data),
              [layout.sidebarFraction, layout.contextFraction, layout.relationsFraction,
               layout.secondaryReaderFraction].allSatisfy({ $0.isFinite && (0...1).contains($0) })
        else { return nil }
        return layout
    }

    private func savePanelLayout() {
        guard contentSurfaceMode == .source, !readingSetLayoutActive,
              let layoutDefaults,
              let data = try? JSONEncoder().encode(currentPanelLayout())
        else { return }
        layoutDefaults.set(data, forKey: panelLayoutKey)
    }

    func applyReaderSettings(_ settings: ReaderSettings) {
        currentReaderSettings = settings
        window?.appearance = switch settings.theme {
        case .dark: NSAppearance(named: .darkAqua)
        case .light, .siClassic: NSAppearance(named: .aqua)
        case .auto: nil
        }
        let theme = ReaderTheme(settings: settings)
        window?.backgroundColor = theme.chromeColor
        window?.titlebarAppearsTransparent = true
        statusBar.wantsLayer = true
        statusBar.layer?.backgroundColor = theme.chromeColor.cgColor
        readerController.apply(settings: settings)
        secondaryReaderController.apply(settings: settings)
        sidebarController.apply(settings: settings)
        relationController.apply(settings: settings)
        contextController.apply(settings: settings)
        trailView.apply(settings: settings)
        palettePanel?.apply(settings: settings)
    }

    var readingHeightLevel: ReadingHeightLevel {
        readerController.readingHeightLevel
    }

    @discardableResult
    func setReadingHeightLevel(_ level: ReadingHeightLevel) -> Bool {
        readerController.setReadingHeightLevel(level)
    }

    var isFocusMode: Bool { readerController.isFocusMode }
    var isFindBarVisible: Bool { readerController.isFindBarVisible }

    @discardableResult
    func showFindBar() -> Bool { readerController.showFindBar() }

    @discardableResult
    func closeFindBar() -> Bool { readerController.closeFindBar() }

    func findNextMatch() { readerController.findNextMatch() }
    func findPreviousMatch() { readerController.findPreviousMatch() }

    var canFindInFile: Bool { readerController.canFindInFile }

    var canToggleBookmark: Bool { model.bookmarkEligibility() == .eligible }

    var bookmarkCommandAccessibilityHelp: String? {
        model.bookmarkEligibility().accessibilityHelp
    }

    var bookmarksPanelIsVisible: Bool { bookmarkPanel?.window?.isVisible == true }
    var selfTestBookmarkPanel: BookmarkPanel? { bookmarkPanel }

    func showBookmarks() {
        if bookmarkPanel == nil {
            bookmarkPanel = BookmarkPanel(
                appModel: model,
                onOpen: { [weak self] record in self?.openBookmark(record) },
                onLineOpen: { [weak self] record, line in
                    self?.openDriftedBookmarkLine(record, line: line)
                }
            )
        }
        bookmarkPanel?.show(relativeTo: window)
    }

    func closeBookmarks() { bookmarkPanel?.closePanel() }

    func toggleBookmark() {
        guard let record = model.captureCurrentBookmark() else { return }
        switch model.bookmarkModel.toggle(record) {
        case .added, .deleted, .rejected:
            render()
        case let .confirmationRequired(id):
            confirmBookmarkDeletion(id: id)
        }
    }

    @discardableResult
    func toggleFocusCurrentScope() -> Bool {
        readerController.toggleFocusCurrentScope()
    }

    var canFocusCurrentScope: Bool {
        readerController.canFocusCurrentScope
    }

    @discardableResult
    func toggleFoldAtSelection() -> Bool {
        readerController.toggleFoldAtSelection()
    }

    var canToggleFoldAtSelection: Bool {
        readerController.canToggleFoldAtSelection
    }

    var selfTestReadingHeightHeader:
        (
            fileName: String,
            level: ReadingHeightLevel,
            labels: [String],
            frame: NSRect,
            controlFrame: NSRect,
            shortcut: String,
            accessibilityLabel: String,
            hidden: Bool,
            enabled: Bool
        )
    {
        readerController.selfTestReadingHeightHeader
    }

    var selfTestUpperPaneWidths: (sidebar: CGFloat, reader: CGFloat) {
        window?.contentView?.layoutSubtreeIfNeeded()
        let panes = upperSplitController.splitView.arrangedSubviews
        guard panes.count >= 2 else { return (0, 0) }
        return (panes[0].frame.width, panes[1].frame.width)
    }

    var selfTestContentView: NSView? { window?.contentView }

    private func applyPanelSizes(_ layout: PanelLayoutDescription) {
        window?.contentView?.layoutSubtreeIfNeeded()
        let upperSplit = upperSplitController.splitView
        // The deferred application must not re-open panes the surface
        // adaptation folded after the preset was applied.
        if !layout.sidebarCollapsed, !sidebarItem.isCollapsed,
           upperSplit.bounds.width > 0 {
            upperSplit.setPosition(
                upperSplit.bounds.width * layout.sidebarFraction,
                ofDividerAt: 0
            )
        }
        if !layout.relationsCollapsed, !relationItem.isCollapsed, upperSplit.bounds.width > 0 {
            upperSplit.setPosition(
                upperSplit.bounds.width * (1 - layout.relationsFraction) - upperSplit.dividerThickness,
                ofDividerAt: 1
            )
        }
        let contentSplit = contentSplitController.splitView
        if !layout.contextCollapsed, !contextItem.isCollapsed,
           contentSplit.bounds.height > 0 {
            contentSplit.setPosition(
                contentSplit.bounds.height * (1 - layout.contextFraction) - contentSplit.dividerThickness,
                ofDividerAt: 0
            )
        }
        let readerSplit = readerSplitController.splitView
        if layout.readerSplit, readerSplit.bounds.width > 0 {
            readerSplit.setPosition(
                readerSplit.bounds.width * (1 - layout.secondaryReaderFraction) - readerSplit.dividerThickness,
                ofDividerAt: 0
            )
        }
    }

    private func openInSecondaryReader(_ file: URL) {
        navigate(to: file)
        applyPanelPreset(.compare)
    }

    /// Cheap validity check for the global relation commands: the primary
    /// Reader shows a project source file with a selection or caret. No
    /// I/O, no Exact, safe during menu tracking.
    var canShowRelationsFromReaderSurface: Bool {
        guard let file = model.selectedFile,
              projectPath(for: file) != nil,
              readerController.currentSelectionByteOffset != nil
        else { return false }
        return true
    }

    func showRelations(direction: RelationTreeModel.Direction) {
        // D3: the Reader's current selection or caret drives the global
        // relation commands through the same file + offset → resolve →
        // relation root path as the context menu. The pinned Context
        // preview is not a silent fallback target.
        guard let offset = readerController.currentSelectionByteOffset else {
            return
        }
        handleReaderRelation(offset: offset, direction: direction)
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
            item.label = localized("main.back")
            item.image = NSImage(
                systemSymbolName: "chevron.backward",
                accessibilityDescription: localized("main.back")
            )
            item.target = self
            item.action = #selector(goBack(_:))
            item.isNavigational = true
            item.visibilityPriority = .high
        case Self.forwardItemIdentifier:
            item.label = localized("main.forward")
            item.image = NSImage(
                systemSymbolName: "chevron.forward",
                accessibilityDescription: localized("main.forward")
            )
            item.target = self
            item.action = #selector(goForward(_:))
            item.isNavigational = true
            item.visibilityPriority = .high
        case Self.projectItemIdentifier:
            item.label = localized("main.project")
            item.view = projectLabel
            item.visibilityPriority = .low
            projectLabel.font = .systemFont(ofSize: 13, weight: .semibold)
            projectLabel.cell?.lineBreakMode = .byTruncatingTail
            projectLabel.frame.size = NSSize(width: 120, height: 22)
            item.menuFormRepresentation = NSMenuItem(
                title: projectLabel.stringValue,
                action: nil,
                keyEquivalent: ""
            )
        case Self.commitItemIdentifier:
            item.label = localized("main.version")
            item.view = commitButton
            item.visibilityPriority = .low
            commitButton.target = self
            commitButton.action = #selector(showCommitPicker(_:))
            commitButton.bezelStyle = .rounded
            commitButton.font = .systemFont(ofSize: 12, weight: .semibold)
            commitButton.cell?.lineBreakMode = .byTruncatingTail
            commitButton.frame.size = NSSize(width: 260, height: 28)
            commitButton.setAccessibilityLabel(localized("main.current.version"))
            let menuItem = NSMenuItem(
                title: commitButton.title,
                action: #selector(showCommitPickerFromMenu(_:)),
                keyEquivalent: ""
            )
            menuItem.target = self
            item.menuFormRepresentation = menuItem
        case Self.symbolsItemIdentifier:
            item.label = localized("main.symbols")
            item.view = symbolsButton
            // §3.2: Symbols stays visible at 900pt with long project names;
            // project/version/profile chrome overflows first.
            item.visibilityPriority = .high
            symbolsButton.title = localized("main.symbols.t")
            symbolsButton.image = NSImage(
                systemSymbolName: "magnifyingglass",
                accessibilityDescription: localized("main.symbols")
            )
            symbolsButton.imagePosition = .imageLeading
            symbolsButton.bezelStyle = .rounded
            symbolsButton.font = .systemFont(ofSize: 12)
            symbolsButton.target = self
            symbolsButton.action = #selector(showSymbolSearchFromToolbar(_:))
            symbolsButton.frame.size = NSSize(width: 120, height: 28)
            symbolsButton.setAccessibilityLabel(localized("main.open.symbol.search"))
            let menuItem = NSMenuItem(
                title: localized("main.symbols"),
                action: #selector(showSymbolSearchFromToolbar(_:)),
                keyEquivalent: "t"
            )
            menuItem.keyEquivalentModifierMask = .command
            menuItem.target = self
            item.menuFormRepresentation = menuItem
        case Self.settingsItemIdentifier:
            item.label = localized("main.settings")
            item.view = settingsButton
            item.visibilityPriority = .low
            settingsButton.title = ""
            settingsButton.image = NSImage(
                systemSymbolName: "gearshape",
                accessibilityDescription: localized("main.settings")
            )
            settingsButton.bezelStyle = .texturedRounded
            settingsButton.target = self
            settingsButton.action = #selector(showSettingsFromToolbar(_:))
            settingsButton.frame.size = NSSize(width: 32, height: 28)
            settingsButton.setAccessibilityLabel(localized("main.settings"))
            let menuItem = NSMenuItem(
                title: localized("main.settings.menu"),
                action: #selector(showSettingsFromToolbar(_:)),
                keyEquivalent: ","
            )
            menuItem.keyEquivalentModifierMask = .command
            menuItem.target = self
            item.menuFormRepresentation = menuItem
        case Self.profileItemIdentifier:
            item.label = localized("main.profile")
            item.view = profileButton
            item.visibilityPriority = .standard
            profileButton.bezelStyle = .rounded
            profileButton.font = .systemFont(ofSize: 12, weight: .semibold)
            profileButton.cell?.lineBreakMode = .byTruncatingTail
            // Bounded so a long analysis-profile title cannot demand pane
            // width; the full title lives in the menu representation.
            profileButton.cell?.truncatesLastVisibleLine = true
            profileButton.cell?.wraps = false
            profileButton.target = self
            profileButton.action = #selector(showProfileMenu(_:))
            profileButton.setAccessibilityLabel(localized("main.analysis.profile"))
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
            _ = model.replayNotice
            _ = model.staleIndexNotice
            _ = model.sessionSaveNotice
            _ = model.sessionLoadNotice
            _ = model.isRestoringSession
            _ = model.isRefreshingIndex
            _ = model.indexRefreshNotice
            _ = model.projectFailureReason
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
            _ = model.exactCoordinator.analysisEnvironment
            _ = model.exactCoordinator.trustMode
            _ = model.contextWindow.stage
            _ = model.contextWindow.mode
            _ = model.readingTrail
            _ = model.bookmarkModel.records
            _ = model.bookmarkModel.storageError
            _ = model.bookmarkModel.lastAttemptMessage
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.render()
                self?.observe()
            }
        }
    }

    private func render() {
        updateContentSurfaceIfNeeded()
        updateRelationsWidthAdaptation()
        updateContextVisibility()
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
        let readerContent = model.tabStrip.activeTab?.content
            ?? model.selectedFile.map(TabContent.file)
        let nextReadingSetLayout = if case .some(.readingSet) = readerContent {
            true
        } else {
            false
        }
        if nextReadingSetLayout != readingSetLayoutActive {
            if nextReadingSetLayout {
                savePanelLayout()
                savedSourceSurfaceLayout = currentPanelLayout()
                readingSetLayoutActive = true
                applyPanelLayout(PanelPresetModel.focus.layout)
            } else {
                readingSetLayoutActive = false
                if contentSurfaceMode == .source {
                    applyPanelLayout(savedSourceSurfaceLayout ?? restoredPanelLayout() ?? panelPreset.layout)
                    savedSourceSurfaceLayout = nil
                    updateContextVisibility()
                }
            }
        }
        let readingSetAvailability: [(open: Bool, expand: Bool)]? = if case .readingSet(
            _, let excerpts
        ) = readerContent {
            zip(excerpts, model.readingSetSources(for: excerpts)).map { excerpt, source in
                let expanded = source.flatMap {
                    expandedReadingSetExcerpt(excerpt, bytes: $0)
                }
                return (
                    source != nil && excerpt.sourceKind != .dependencyCaptured,
                    expanded.map {
                        $0.byteRange != excerpt.byteRange
                            || $0.sourceText != excerpt.sourceText
                    } ?? false
                )
            }
        } else {
            nil
        }
        let readerFile = readerContent?.fileURL
        readerController.projectRoot = model.projectRoot
        let selectedSource = readerSource(for: readerFile)
        let selectedLanguageMode = readerFile.flatMap(model.languageMode(for:))
        readerController.display(
            readerContent,
            snapshotID: model.currentSnapshotID,
            source: selectedSource,
            languageMode: selectedLanguageMode,
            readingSetAvailability: readingSetAvailability,
            readingSetSkippedReasons:
                model.tabStrip.activeTab?.readingSetSkippedReasons ?? []
        )
        if let readerFile,
           let document = model.tabStrip.activeDocument
        {
            readerController.setBookmarkMarkers(
                model.bookmarkMarkers(for: readerFile, document: document)
            )
        } else {
            readerController.setBookmarkMarkers([:])
        }
        if readerFile == nil, model.tabStrip.activeTab != nil {
            readerController.restoreReadingSetScrollOffset(
                model.tabStrip.activeTab?.readingSetScrollOffset
            )
        }
        readerController.refreshTabs()
        let compareFile = model.selectedFile.flatMap {
            projectPath(for: $0) == nil ? nil : $0
        }
        secondaryReaderController.display(
            model.compare.rightSnapshotID == nil ? nil : compareFile,
            snapshotID: model.compare.rightSnapshotID,
            source: model.compare.rightSource,
            languageMode: compareFile.flatMap(model.languageMode(for:))
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
               let restoreFile = restore.fileURL,
               restoreFile.standardizedFileURL
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
                    if let request = model.activeNavigationRequest {
                        outlineFollowArbitration.apply(request)
                    }
                    readerController.navigate(
                        to: file,
                        byteOffset: offset,
                        snapshotID: model.currentSnapshotID,
                        source: selectedSource,
                        languageMode: selectedLanguageMode
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
        updateWindowTitle()
        window?.toolbar?.items.first {
            $0.itemIdentifier == Self.projectItemIdentifier
        }?.menuFormRepresentation?.title = projectLabel.stringValue
        renderEmptyState()
        renderCommitButton()
        renderExactStatus()
        renderStatusBar()
        renderTrail()
        relationController.refreshInspector()
        captureActiveTabState()
        model.scheduleSessionCheckpoint(panelPreset: panelPreset)

        guard let toolbar = window?.toolbar else { return }
        renderProfileItem(in: toolbar)
        toolbar.validateVisibleItems()
        palettePanel?.refreshProjectState()
        searchPanel?.refreshProjectState()
        bookmarkPanel?.refresh()
    }

    private var profileTitle: String? {
        guard let profile = model.activeAnalysisProfileDisplay,
              let trustMode = model.exactCoordinator.trustMode
        else { return nil }
        let trust = switch trustMode {
        case .safe: localized("main.safe")
        case .trusted: localized("main.trusted")
        }
        let base = "\(Self.displayName(for: profile.language))"
            + " · \(profile.projectUnitName)"
        guard profile.language == .rust else {
            return base + " · \(trust)"
        }
        return base
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
        case .defaultFeatures: localized("main.features.default.short")
        case .allFeatures: localized("main.features.all.short")
        case .noDefaultFeatures: localized("main.features.no.default.short")
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
        let menu = NSMenu(title: localized("main.profile"))
        guard let profile = model.activeAnalysisProfileDisplay,
              let trustMode = model.exactCoordinator.trustMode
        else { return menu }
        let trust = switch trustMode {
        case .safe: localized("main.safe")
        case .trusted: localized("main.trusted")
        }
        let edition = profile.edition.map { localizedFormat("main.edition", String(describing: $0)) }
            ?? localized("main.edition.unknown")
        let currentTitle: String
        if profile.language == .rust {
            currentTitle = localizedFormat("main.current.rust.unit", profile.projectUnitName, Self.displayName(for: profile.featureSelection), edition, trust)
        } else {
            currentTitle = localizedFormat("main.current.unit", profile.projectUnitName, trust)
        }
        let current = NSMenuItem(
            title: currentTitle,
            action: nil,
            keyEquivalent: ""
        )
        current.isEnabled = false
        menu.addItem(current)
        if profile.language == .rust {
            menu.addItem(.separator())
            for featureSelection in model.availableFeatureSelections {
                let title = switch featureSelection {
                case .defaultFeatures: localized("main.default.features")
                case .allFeatures: localized("main.all.features")
                case .noDefaultFeatures: localized("main.no.default.features")
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
        }
        menu.addItem(.separator())
        let trustItem = NSMenuItem(
            title: localized("main.trust.this.repository"),
            action: NSSelectorFromString("trustThisRepository:"),
            keyEquivalent: ""
        )
        trustItem.target = NSApplication.shared.delegate
        menu.addItem(trustItem)
        if profile.language == .rust {
            menu.addItem(.separator())
            let explanation = NSMenuItem(
                title: localized("main.switch.features.here.the.current.unit.is.detected"),
                action: nil,
                keyEquivalent: ""
            )
            explanation.isEnabled = false
            menu.addItem(explanation)
        }
        return menu
    }

    /// "project-name — Cairn"; sibling projects sharing a name are told
    /// apart by their parent directory (§6.3). The title bar itself stays
    /// hidden (toolbar style) — the title serves the Window menu, Mission
    /// Control, and AppKit switcher surfaces.
    func updateWindowTitle(among siblings: [URL] = []) {
        guard let window else { return }
        guard let identity = projectURL ?? model.fileTree?.root else {
            window.title = "Cairn"
            return
        }
        let name = identity.lastPathComponent
        let disambiguation = siblings.first { other in
            other != identity && other.lastPathComponent == name
        }
        if let disambiguation {
            let parent = disambiguation.deletingLastPathComponent()
                .lastPathComponent
            window.title = "\(name) (\(parent)) — Cairn"
        } else {
            window.title = "\(name) — Cairn"
        }
    }

    private func renderEmptyState() {
        if case .ready = model.projectState, let root = pendingRecentProjectRoot {
            if recordsRecentProjects {
                recentProjectsStore.record(
                    root,
                    languages: pendingRecentProjectLanguages ?? [.rust]
                )
            }
            pendingRecentProjectRoot = nil
            pendingRecentProjectLanguages = nil
        }

        let retry = { [weak self] in
            _ = self?.retryLastOpenedProject()
        }
        let openDropped = { [weak self] (root: URL) in
            guard let self else { return }
            self.onChooseProjectLanguage(root, self)
        }
        switch model.projectState {
        case .empty:
            readerController.showEmptyState(
                recentPaths: recentProjectsStore.paths,
                failed: false,
                onChooseProject: onChooseProject,
                onOpenRecent: { [weak self] in self?.openRecentProject($0) },
                onOpenDropped: openDropped,
                onRetry: retry
            )
        case .failed:
            readerController.showEmptyState(
                recentPaths: recentProjectsStore.paths,
                failed: true,
                failureReason: model.projectFailureReason,
                onChooseProject: onChooseProject,
                onOpenRecent: { [weak self] in self?.openRecentProject($0) },
                onOpenDropped: openDropped,
                onRetry: retry
            )
        case .indexing:
            readerController.removeEmptyState(placeholder: localized("main.indexing.project"))
        case .ready:
            readerController.removeEmptyState(placeholder: localized("main.select.a.file.to.read.p.to.open"))
        }
    }

    private var compareVersionTitle: String {
        guard let revision = model.compare.rightRevision else {
            return localized("main.choose.comparison.version")
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
        let environment = coordinator.analysisEnvironment
        let activeTrust = environment?.trustMode ?? coordinator.trustMode
        let trust: String? = switch activeTrust {
        case .safe: localized("main.safe")
        case .trusted: localized("main.trusted")
        case nil: nil
        }
        let trustSuffix = trust.map { " · \($0)" } ?? ""
        let status: String
        let color: NSColor
        let statusDetail: String?
        switch coordinator.readiness {
        case .ready:
            if environment?.limitations.contains(.dependenciesUnavailableOffline) == true {
                status = localizedFormat("main.exact.deps.unavailable.offline", trustSuffix)
                color = .systemOrange
            } else if environment?.limitations.isEmpty == false {
                status = localizedFormat("main.exact.ready.limited", trustSuffix)
                color = .systemBlue
            } else if environment != nil {
                status = localizedFormat("main.exact.ready", trustSuffix)
                color = .systemGreen
            } else {
                status = localizedFormat("main.exact.ready.environment.unknown", trustSuffix)
                color = .systemBlue
            }
            statusDetail = nil
        case .preparing:
            status = localizedFormat("main.exact.preparing", trustSuffix)
            color = .secondaryLabelColor
            statusDetail = nil
        case .unavailable(let reason):
            status = reason.localizedCaseInsensitiveContains("sandbox")
                ? localized("main.exact.unavailable.sandbox")
                : localized("main.exact.unavailable")
            color = .systemRed
            statusDetail = reason
        case .off(let reason):
            status = reason.localizedCaseInsensitiveContains("sandbox")
                ? localized("main.exact.unavailable.sandbox")
                : localized("main.exact.off.safe")
            color = .systemOrange
            statusDetail = reason
        }
        let limitations = environment?.limitations
            .sorted { $0.rawValue < $1.rawValue }
            .map(localizedLimitation)
            .joined(separator: "; ")
        let limitationMeaning = limitations.map {
            $0.isEmpty ? localized("main.none.known") : $0
        } ?? localized("main.not.available.yet")
        let detail: String?
        if let attribution = coordinator.attribution {
            var lines = [
                localizedFormat("main.provider", attribution.provider),
                localizedFormat("main.tool.version", attribution.toolVersion),
                localizedFormat("main.trust", trust ?? localized("main.unknown")),
                localizedFormat("main.limitations", limitationMeaning),
            ]
            if model.activeAnalysisProfileDisplay?.language != .python {
                lines.append(
                    localizedFormat("main.features", Self.displayName(for: attribution.featureSelection))
                )
            }
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
        return localizedFormat("main.indexing.files", Int64(model.fileTree?.fileCount ?? 0))
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
        let indexStatus = [
            focusNotice,
            model.isRestoringSession ? localized("main.restoring.reading.session") : nil,
            initialIndexStatus,
            model.isRefreshingIndex ? localized("main.refreshing.index") : nil,
            model.indexRefreshNotice,
            coverageStatus,
            model.replayNotice,
            model.staleIndexNotice,
            model.sessionSaveNotice,
            model.sessionLoadNotice,
        ]
            .compactMap { $0 }
            .joined(separator: " · ")
        focusNotice = nil
        indexLabel.stringValue = indexStatus
        indexLabel.isHidden = indexStatus.isEmpty
        refreshIndexButton.isHidden = model.isRefreshingIndex
            || (model.staleIndexNotice == nil && model.indexRefreshNotice == nil)
        refreshIndexButton.isEnabled = !model.isRefreshingIndex
        truncatedLabel.isHidden = !model.relationTree.hasTruncatedResults
    }

    var canRefreshIndex: Bool {
        guard case .ready = model.projectState, model.projectRoot != nil else {
            return false
        }
        return !model.isRefreshingIndex
    }

    @objc func refreshProjectIndex(_ sender: Any?) {
        guard canRefreshIndex else { return }
        refreshIndex()
    }

    func refreshIndex() {
        captureActiveTabState()
        model.refreshIndex(leaving: currentJumpRecord())
        render()
    }

    private func renderTrail() {
        trailView.display(
            trail: model.readingTrail,
            store: model.resolutionExplanations
        )
        trailView.isHidden = model.readingTrail.nodes.isEmpty || contentSurfaceMode != .source
    }

    private func renderCommitButton() {
        guard let revision = model.currentRevision else {
            commitButton.title = switch model.commitPicker.currentBranchName {
            case "detached": localized("main.detached")
            case let branch?: localizedFormat("main.branch.working.tree", branch)
            case nil: localized("main.working.tree")
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
        // Symbols remains visible when Version moves into the overflow menu.
        let anchor = (sender as? NSView) ?? symbolsButton
        guard anchor.window != nil else { return }
        if commitPickerPopover == nil {
            commitPickerPopover = CommitPickerPopover(
                appModel: model,
                selectedRevision: { [weak model] in model?.currentRevision },
                onChoose: { [weak self] commit in
                    self?.cancelSessionRestore()
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
        // Let the overflow menu finish tracking before showing a transient popover.
        DispatchQueue.main.async { [weak self] in self?.showCommitPicker(nil) }
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

    private func openBookmark(_ record: BookmarkRecord) {
        guard let leaving = currentJumpRecord() else { return }
        model.openStrictBookmark(record, leaving: leaving)
    }

    private func openDriftedBookmarkLine(_ record: BookmarkRecord, line: UInt32) {
        guard let target = model.explicitBookmarkLineOpen(record, line: line) else { return }
        navigate(to: target.file, byteOffset: target.byteOffset)
    }

    private func confirmBookmarkDeletion(id: UUID) {
        let alert = NSAlert()
        alert.messageText = localized("main.delete.bookmark")
        alert.informativeText = localized("main.its.note.will.be.removed")
        alert.addButton(withTitle: localized("main.delete"))
        alert.addButton(withTitle: localized("main.cancel"))
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn,
                  let self, !self.isClosing else { return }
            _ = self.model.bookmarkModel.delete(id: id)
            self.render()
        }
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
        guard let file = model.selectedFile,
              let languageMode = model.languageMode(for: file)
        else { return }
        if let range = change.rightRange {
            secondaryReaderController.navigate(
                to: file,
                byteOffset: range.lowerBound,
                snapshotID: model.compare.rightSnapshotID,
                source: model.compare.rightSource,
                languageMode: languageMode
            )
        } else if let range = change.leftRange {
            readerController.navigate(
                to: file,
                byteOffset: range.lowerBound,
                snapshotID: model.currentSnapshotID,
                source: model.documentSource,
                languageMode: languageMode
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
        openRelationsPane()
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

    private func open(_ node: RelationTreeModel.Node) {
        guard let target = node.target else { return }
        let frozenInspectorDisplay = relationController
            .frozenInspectorDisplay(for: node)
        open(
            path: target.path,
            byteOffset: target.byteOffset,
            explanation: model.navigationExplanation(
                for: node,
                frozenInspectorDisplay: frozenInspectorDisplay,
                readingSetRole: relationController.readingSetRole(for: node)
            ),
            symbolAnchor: node.title
        )
    }

    private func open(
        path: String,
        byteOffset: UInt32,
        explanation: NavigationExplanation? = nil,
        symbolAnchor: String? = nil
    ) {
        guard let root = model.fileTree?.root else { return }
        let file = exactLocationIsInDependency(path)
            ? URL(fileURLWithPath: path)
            : root.appendingPathComponent(path)
        navigate(
            to: file,
            byteOffset: byteOffset,
            cause: .relation,
            explanation: explanation,
            symbolAnchor: symbolAnchor,
            expectedContentID: exactLocationIsInDependency(path)
                ? nil
                : model.indexedContentID(forPath: path)
        )
    }

    private func showRelations(
        target: ReferenceTarget,
        direction: RelationTreeModel.Direction,
        document: ReaderDocument? = nil
    ) {
        openRelationsPane()
        relationController.setRoot(
            target: target,
            direction: direction,
            document: document
        )
        render()
    }

    private func navigate(
        to file: URL,
        byteOffset: UInt32? = nil,
        cause: NavigationCause = .fileSelection,
        explanation: NavigationExplanation? = nil,
        symbolAnchor: String? = nil,
        expectedContentID: ContentID? = nil
    ) {
        let current = currentJumpRecord()
        captureActiveTabState()
        let existingTab = model.tabStrip.tabs.firstIndex(where: {
            $0.fileURL?.standardizedFileURL == file.standardizedFileURL
        })
        let focusesExistingTab = byteOffset == nil
            && existingTab != nil
            && existingTab != model.tabStrip.activeIndex
        let request = NavigationRequest(
            destination: SourceDestination(
                file: file,
                byteOffset: byteOffset,
                symbolAnchor: symbolAnchor,
                expectedContentID: expectedContentID
            ),
            cause: cause,
            policy: byteOffset == nil ? .passive : .explicitSemantic,
            explanation: explanation
        )
        model.navigate(
            request,
            leaving: current
        )
        if focusesExistingTab { pendingTabRestore = model.tabStrip.activeTab }
        render()
    }

    private func openInNewTab(_ file: URL) {
        captureActiveTabState()
        let opensNewTab = !model.tabStrip.tabs.contains {
            $0.fileURL?.standardizedFileURL == file.standardizedFileURL
        }
        let evictsTab = opensNewTab
            && model.tabStrip.tabs.count == model.tabStrip.maximumCount
        if evictsTab { model.cancelPendingSessionCheckpoint() }
        model.openInNewTab(file)
        pendingTabRestore = model.tabStrip.activeTab
        render()
        if evictsTab {
            checkpointSessionSynchronously(allowsPendingTopology: true)
        }
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
        model.cancelPendingSessionCheckpoint()
        model.closeTab(index)
        pendingTabRestore = closesActive ? model.tabStrip.activeTab : nil
        render()
        checkpointSessionSynchronously(allowsPendingTopology: true)
    }

    private func selectRelativeTab(_ delta: Int) {
        guard model.tabStrip.tabs.count > 1 else { return }
        captureActiveTabState()
        model.selectRelativeTab(delta)
        pendingTabRestore = model.tabStrip.activeTab
        render()
    }

    private func captureActiveTabState() {
        if model.tabStrip.activeTab?.fileURL == nil {
            model.tabStrip.updateActiveReadingSetScroll(
                readerController.currentReadingSetScrollOffset
            )
            return
        }
        let scrollPosition = readerController.currentReadingPosition(
            fallbackByteOffset: model.selectedByteOffset
        )
        let selectionPosition = readerController.readingPosition(
            at: model.tabStrip.activeTab?.selectionByteOffset
                ?? model.selectedByteOffset
        )
        guard scrollPosition != nil || selectionPosition != nil else { return }
        let scrollAnchor = scrollPosition.map {
            SessionCodec.Anchor(
                byteOffset: $0.byteOffset,
                line: $0.line,
                column: $0.column,
                symbolAnchor: $0.symbolAnchor
            )
        }
        let selectionAnchor = selectionPosition.map {
            SessionCodec.Anchor(
                byteOffset: $0.byteOffset,
                line: $0.line,
                column: $0.column,
                symbolAnchor: $0.symbolAnchor
            )
        }
        model.tabStrip.updateActiveSessionAnchors(
            contentID: scrollPosition?.contentID ?? selectionPosition?.contentID,
            scrollAnchor: scrollAnchor,
            selectionAnchor: selectionAnchor
        )
    }

    func checkpointSessionSynchronously(
        allowsPendingTopology: Bool = false
    ) {
        captureActiveTabState()
        savePanelLayout()
        try? model.writeSessionCheckpoint(
            panelPreset: panelPreset,
            allowsPendingTopology: allowsPendingTopology
        )
    }

    /// Same checkpoint, but reports the save failure so the close approval
    /// stage can offer retry/cancel/continue (§7.1).
    func checkpointSessionSynchronouslyReportingFailure(
        allowsPendingTopology: Bool = false
    ) throws {
        captureActiveTabState()
        savePanelLayout()
        try model.writeSessionCheckpoint(
            panelPreset: panelPreset,
            allowsPendingTopology: allowsPendingTopology
        )
    }

    func scheduleSessionCheckpointForApplicationLifecycle() {
        captureActiveTabState()
        savePanelLayout()
        model.scheduleSessionCheckpoint(panelPreset: panelPreset)
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
                snapshotID: model.currentSnapshotID,
                revision: model.currentRevision
            )
        }
        return JumpRecord(
            path: path,
            contentID: position.contentID,
            byteOffset: position.byteOffset,
            line: position.line,
            column: position.column,
            symbolAnchor: position.symbolAnchor,
            snapshotID: model.currentSnapshotID,
            revision: model.currentRevision
        )
    }

    nonisolated static func pathLineText(
        for file: URL,
        under projectRoot: URL?,
        line: UInt32
    ) -> String {
        let path = projectRoot.flatMap {
            projectRelativePath(for: file, under: $0)
        } ?? file.path
        return "\(path):\(line)"
    }

    nonisolated private static func projectRelativePath(
        for file: URL,
        under root: URL
    ) -> String? {
        guard file.pathComponents.starts(with: root.pathComponents)
        else { return nil }
        return file.pathComponents.dropFirst(root.pathComponents.count)
            .joined(separator: "/")
    }

    private func projectPath(for file: URL) -> String? {
        guard let root = model.fileTree?.root else { return nil }
        return Self.projectRelativePath(for: file, under: root)
    }

    @discardableResult
    private func openPreviewLink(_ url: URL) -> Bool {
        let file = url.standardizedFileURL
        guard let path = model.fileTree?.selectionPath(for: file),
              let node = path.last,
              !node.isDirectory
        else { return false }
        navigate(to: file)
        return true
    }

    private func readerSource(
        for file: URL?
    ) -> DocumentLoader.ContentSource? {
        guard let file, projectPath(for: file) != nil else { return nil }
        return model.documentSource
    }
}

@MainActor
final class ThemeSelectionRowView: NSTableRowView {
    var selectionColor: NSColor = .selectedContentBackgroundColor {
        didSet { needsDisplay = true }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        selectionColor.setFill()
        bounds.fill()
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

@MainActor
private final class TabStripView: NSView {
    private weak var model: TabStripModel?
    private var onActivate: ((Int) -> Void)?
    private var onClose: ((Int) -> Void)?
    private let scrollView = NSScrollView()
    private let tabs = NSStackView()
    private var displayedKeys: [String] = []
    private var displayedActiveIndex: Int?
    private var previousClipSize = NSSize.zero
    private var theme = ReaderTheme(settings: ReaderSettings())

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel(localized("main.open.files"))
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        tabs.orientation = .horizontal
        tabs.alignment = .centerY
        tabs.spacing = 1
        tabs.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tabs
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            tabs.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            tabs.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            tabs.heightAnchor.constraint(equalTo: heightAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ model: TabStripModel, onActivate: @escaping (Int) -> Void,
                   onClose: @escaping (Int) -> Void) {
        self.model = model
        self.onActivate = onActivate
        self.onClose = onClose
        refresh()
    }

    func apply(settings: ReaderSettings) {
        theme = ReaderTheme(settings: settings)
        displayedKeys = []
        refresh()
    }

    var activeTitle: String { model?.activeTab?.title ?? "" }

    override func layout() {
        super.layout()
        let size = scrollView.contentView.bounds.size
        guard size != previousClipSize else { return }
        previousClipSize = size
        revealActiveTab()
    }

    func refresh() {
        guard let model else { return }
        isHidden = model.tabs.isEmpty
        setAccessibilityValue(activeTitle)
        let keys = model.tabs.map {
            ($0.fileURL?.path ?? "") + "\n" + $0.title + "\n" + String($0.isPreview)
        }
        guard keys != displayedKeys || model.activeIndex != displayedActiveIndex else { return }
        displayedKeys = keys
        displayedActiveIndex = model.activeIndex
        for tab in tabs.arrangedSubviews {
            tabs.removeArrangedSubview(tab)
            tab.removeFromSuperview()
        }
        for (index, tab) in model.tabs.enumerated() {
            let active = index == model.activeIndex
            var title = tab.title
            if model.tabs.filter({ $0.title == title }).count > 1, let file = tab.fileURL {
                let peers = model.tabs.compactMap { $0.title == tab.title ? $0.fileURL : nil }
                let components = file.pathComponents
                for length in 2...components.count {
                    let suffix = components.suffix(length).joined(separator: "/")
                    if peers.filter({ $0.pathComponents.suffix(length).joined(separator: "/") == suffix }).count == 1 {
                        title = suffix
                        break
                    }
                }
            }
            let button = NSButton(title: title, target: self, action: #selector(activate(_:)))
            button.tag = index
            button.isBordered = false
            button.font = .systemFont(ofSize: 12, weight: active ? .semibold : .regular)
            if tab.isPreview, let font = button.font {
                button.font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            button.alignment = .left
            button.lineBreakMode = .byTruncatingMiddle
            button.contentTintColor = active ? theme.foregroundColor : theme.chromeSecondaryColor
            button.toolTip = tab.fileURL?.path ?? tab.title
            button.setAccessibilityRole(.radioButton)
            button.setAccessibilityValue(active ? 1 : 0)
            button.setAccessibilityLabel(localizedFormat("main.tab.title", title, tab.isPreview ? localized("main.preview.suffix") : ""))
            let help = (tab.fileURL?.path ?? tab.title)
                + (tab.isPreview ? localized("main.preview.tip") : "")
            button.setAccessibilityHelp(help)
            let menu = NSMenu(title: title)
            menu.autoenablesItems = false
            let keepOpen = NSMenuItem(title: localized("main.keep.open"), action: #selector(keepTabOpen(_:)), keyEquivalent: "")
            keepOpen.target = self
            keepOpen.tag = index
            keepOpen.isEnabled = tab.isPreview
            menu.addItem(keepOpen)
            button.menu = menu
            let close = NSButton(title: "", target: self, action: #selector(closeTab(_:)))
            close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
            close.tag = index
            close.isBordered = false
            close.controlSize = .small
            close.contentTintColor = theme.chromeSecondaryColor
            close.setAccessibilityLabel(localizedFormat("main.close.tab", title))
            close.toolTip = localizedFormat("main.close.tab", tab.title)
            let row = NSStackView(views: [button, close])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 6
            row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 4)
            row.wantsLayer = true
            row.layer?.backgroundColor = (active ? theme.backgroundColor : theme.chromeHeaderColor).cgColor
            row.menu = menu
            let width = min(220, max(110, button.intrinsicContentSize.width + 42))
            tabs.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                row.widthAnchor.constraint(equalToConstant: width),
                row.heightAnchor.constraint(equalTo: heightAnchor),
                close.widthAnchor.constraint(equalToConstant: 22),
                close.heightAnchor.constraint(equalToConstant: 22),
            ])
        }
        layoutSubtreeIfNeeded()
        revealActiveTab()
    }

    private func revealActiveTab() {
        if let active = model?.activeIndex, tabs.arrangedSubviews.indices.contains(active) {
            tabs.scrollToVisible(tabs.arrangedSubviews[active].frame)
        }
    }

    @objc private func activate(_ sender: NSButton) { onActivate?(sender.tag) }
    @objc private func closeTab(_ sender: NSButton) { onClose?(sender.tag) }
    @objc private func keepTabOpen(_ sender: NSMenuItem) {
        model?.keepOpen(sender.tag)
        refresh()
    }
}

@MainActor
private final class ReadingHeightControl: NSSegmentedControl {
    private let segmentWidths: [CGFloat] = [48, 76, 72]

    init() {
        super.init(frame: .zero)
        segmentCount = ReadingHeightLevel.allCases.count
        trackingMode = .selectOne
        segmentStyle = .texturedRounded
        controlSize = .small
        font = .systemFont(ofSize: 11)
        for level in ReadingHeightLevel.allCases {
            setLabel(level.title, forSegment: level.rawValue)
        }
        selectedSegment = ReadingHeightLevel.full.rawValue
        for (index, width) in segmentWidths.enumerated() {
            setWidth(width, forSegment: index)
        }
        setAccessibilityLabel(localized("main.reading.height"))
        toolTip = localized("main.reading.height.0.1.2")
        setToolTip(
            localized("main.height.full.help"),
            forSegment: ReadingHeightLevel.full.rawValue
        )
        setToolTip(
            localized("main.structure.folds.function.bodies.and.keeps.signatures.visible"),
            forSegment: ReadingHeightLevel.structure.rawValue
        )
        setToolTip(
            localized("main.height.overview.help"),
            forSegment: ReadingHeightLevel.overview.rawValue
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var level: ReadingHeightLevel {
        ReadingHeightLevel(rawValue: selectedSegment) ?? .full
    }

    func set(level: ReadingHeightLevel) {
        selectedSegment = level.rawValue
        needsDisplay = true
    }

    func apply(settings: ReaderSettings) {
        needsDisplay = true
    }

}

/// Intercepts the native autoresize before TextKit discards the old line geometry.
@MainActor
private final class PlainTextPreviewView: NSTextView {
    var onWidthChange: ((CGFloat) -> Void)?
    var isReflowing = false

    override func setFrameSize(_ newSize: NSSize) {
        if !isReflowing, newSize.width != frame.width, let onWidthChange {
            onWidthChange(newSize.width)
        } else {
            super.setFrameSize(newSize)
        }
    }
}

@MainActor
final class ReaderViewController: NSViewController, NSSearchFieldDelegate,
    NSTextViewDelegate, WKNavigationDelegate
{
    var onTokenClick: ((UInt32, Bool) -> Void)?
    var onShowRelation: ((UInt32, RelationTreeModel.Direction) -> Void)?
    var onOutlineChange: (([OutlineFacet]) -> Void)?
    var onReadingPositionChange: ((UInt32) -> Void)?
    var onOutlineFollowPositionChange: ((UInt32) -> Void)?
    var onLiveScroll: (() -> Void)?
    var onFocusNotice: ((String) -> Void)?
    var onSelectionChange: ((UInt32) -> Void)?
    var onOpenScope: ((UInt32) -> Void)?
    var onRevealPath: ((URL) -> Void)?
    var projectRoot: URL?
    var onDocumentChange: ((URL, ReaderDocument?) -> Void)?
    var onOpenPreviewLink: ((URL) -> Void)?
    var onReadingSetScrollChange: ((Double) -> Void)?
    var onCopyPathLine: ((URL, UInt32) -> Void)?
    var onRevealInFinder: ((URL) -> Void)?
    var onOpenReadingSetExcerpt: ((Int) -> Void)?
    var onExpandReadingSetExcerpt: ((Int) -> Void)?
    var onViewReadingSetEvidence: ((Int) -> Void)?
    var onChooseCompareVersion: (() -> Void)?
    var onCloseComparison: (() -> Void)?
    var onPreviousDiffHunk: (() -> Void)?
    var onNextDiffHunk: (() -> Void)?
    var onFunctionChange: ((DiffCore.FunctionChange) -> Void)?
    private let label = NSTextField(labelWithString: "")
    private let textView = ReaderTextView()
    private let readingSetView = ReadingSetView()
    private let previewArea = NSView()
    private let loader = DocumentLoader()
    private let showsCompareControls: Bool
    private let compareVersionButton = NSButton()
    private let previousHunkButton = NSButton()
    private let nextHunkButton = NSButton()
    private let functionSummaryStack = NSStackView()
    private var displayedFunctionChanges: [DiffCore.FunctionChange] = []
    private let readerArea = NSView()
    private let tabStripView = TabStripView()
    private let readerHeader = NSView()
    private let readerHeaderDivider = NSView()
    private let pathControl = NSPathControl()
    private let scopeHeader = NSView()
    private let scopeHeaderContent = NSStackView()
    private let scopeHeaderDivider = NSView()
    private let fileNameLabel = NSTextField(labelWithString: "")
    private let readingHeightControl = ReadingHeightControl()
    private let readingHeightShortcutLabel = NSTextField(
        labelWithString: "⌥⌘0/1/2"
    )
    private let findBar = NSView()
    private let findBarDivider = NSView()
    private let findField = NSSearchField()
    private let findCaseButton = NSButton()
    private let findPreviousButton = NSButton()
    private let findNextButton = NSButton()
    private let findStatusLabel = NSTextField(labelWithString: "")
    private let findCloseButton = NSButton()
    private weak var scrollView: NSScrollView?
    private(set) var displayedFile: URL?
    private var displayedSnapshotID: SnapshotID?
    private var displayedLanguageMode: LanguageMode?
    private var displayedDocument: ReaderDocument?
    private var displayedReadingSetKey: String?
    private var previewView: NSView?
    private var previewKind: String?
    private enum TextPreviewKind { case plainText, markdown }
    private var textPreviewKind: TextPreviewKind?
    private var previewWrapLines = ReaderSettings().wrapLines
    private var previewUnwrappedX: CGFloat = 0
    private var previewRenderedText: String?
    private var previewLinkCount = 0
    private var previewAccessibilityLabel: String?
    private var previewHTMLJavaScriptEnabled: Bool?
    private var previewHTMLDataStorePersistent: Bool?
    private var previewHTMLContentSecurityPolicy: String?
    private var previewPDFPageCount: Int?
    private var previewImageSize: NSSize?
    private var previewHTMLSource: String?
    private var previewHTMLBaseURL: URL?
    private var previewHTMLFinished = false
    private var previewHTMLLoadError: String?
    private var htmlInitialNavigationAllowed = false
    private var loadGeneration: UInt64 = 0
    private var syntaxLoadPending = false
    private var pendingFocusNavigationOffset: UInt32?
    private var findTask: Task<Void, Never>?
    private var findWorker: Task<[ByteRange], Error>?
    private var findRequestID: UInt64 = 0
    private var savedSymbolOccurrenceByteOffset: UInt32?
    private var findWrapped = false
    private var findScanDelayForTesting = Duration.zero
    private(set) var findCancelledWorkerCountForTesting = 0
    private var contextMenuOffset: UInt32?
    private var readingPositionTask: Task<Void, Never>?
    private var emptyStateView: EmptyStateView?
    private var readerTheme = ReaderTheme(settings: ReaderSettings())
    private var scopeHeaderByteOffset: UInt32?
    nonisolated(unsafe) private var liveScrollObserver: NSObjectProtocol?

    init(showsCompareControls: Bool = false) {
        self.showsCompareControls = showsCompareControls
        super.init(nibName: nil, bundle: nil)
        findBar.isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        findTask?.cancel()
        findWorker?.cancel()
        if let liveScrollObserver {
            NotificationCenter.default.removeObserver(liveScrollObserver)
        }
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
        liveScrollObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.didLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.textView.didLiveScrollWhileFocused()
                self?.onLiveScroll?()
            }
        }

        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        readerArea.addSubview(scrollView)
        readerArea.addSubview(readingSetView)
        readerArea.addSubview(previewArea)
        readerArea.addSubview(label)
        previewArea.translatesAutoresizingMaskIntoConstraints = false
        previewArea.wantsLayer = true
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: readerArea.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: readerArea.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: readerArea.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: readerArea.bottomAnchor),
            readingSetView.leadingAnchor.constraint(equalTo: readerArea.leadingAnchor),
            readingSetView.trailingAnchor.constraint(equalTo: readerArea.trailingAnchor),
            readingSetView.topAnchor.constraint(equalTo: readerArea.topAnchor),
            readingSetView.bottomAnchor.constraint(equalTo: readerArea.bottomAnchor),
            previewArea.leadingAnchor.constraint(equalTo: readerArea.leadingAnchor),
            previewArea.trailingAnchor.constraint(equalTo: readerArea.trailingAnchor),
            previewArea.topAnchor.constraint(equalTo: readerArea.topAnchor),
            previewArea.bottomAnchor.constraint(equalTo: readerArea.bottomAnchor),
            label.centerXAnchor.constraint(equalTo: readerArea.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: readerArea.centerYAnchor),
        ])
        readingSetView.isHidden = true
        previewArea.isHidden = true
        readingSetView.onOpen = { [weak self] in
            self?.onOpenReadingSetExcerpt?($0)
        }
        readingSetView.onExpand = { [weak self] in
            self?.onExpandReadingSetExcerpt?($0)
        }
        readingSetView.onViewEvidence = { [weak self] in
            self?.onViewReadingSetEvidence?($0)
        }
        readingSetView.onScroll = { [weak self] offset in
            self?.onReadingSetScrollChange?(offset)
        }
        if showsCompareControls {
            view = compareContainer(readerView: readerArea)
        } else {
            tabStripView.isHidden = true
            configureReaderHeader()
            pathControl.pathStyle = .standard
            pathControl.controlSize = .small
            pathControl.isEditable = false
            pathControl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            pathControl.target = self
            pathControl.action = #selector(revealBreadcrumb(_:))
            pathControl.setAccessibilityLabel(localized("main.file.path"))
            pathControl.isHidden = true
            configureScopeHeader()
            configureFindBar()
            let stack = NSStackView(views: [
                readerHeader,
                findBar,
                pathControl,
                readerArea,
            ])
            stack.orientation = .vertical
            stack.alignment = .width
            stack.distribution = .fill
            stack.spacing = 0
            NSLayoutConstraint.activate([
                readerArea.widthAnchor.constraint(equalTo: stack.widthAnchor),
                readerHeader.heightAnchor.constraint(equalToConstant: 32),
                findBar.heightAnchor.constraint(equalToConstant: 31),
                pathControl.heightAnchor.constraint(equalToConstant: 24),
                pathControl.widthAnchor.constraint(equalTo: stack.widthAnchor),
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
        textView.onCaretChange = { [weak self] byteOffset in
            self?.renderScopeHeader(at: byteOffset)
            self?.onSelectionChange?(byteOffset)
        }

        let relationMenu = NSMenu(title: localized("main.relations"))
        relationMenu.autoenablesItems = false
        relationMenu.addItem(NSMenuItem(
            title: localized("main.show.callers"),
            action: #selector(showCallers(_:)),
            keyEquivalent: ""
        ))
        relationMenu.addItem(NSMenuItem(
            title: localized("main.show.calls"),
            action: #selector(showCalls(_:)),
            keyEquivalent: ""
        ))
        relationMenu.addItem(NSMenuItem(
            title: localized("main.show.implementations"),
            action: #selector(showImplementations(_:)),
            keyEquivalent: ""
        ))
        relationMenu.addItem(NSMenuItem(
            title: localized("main.show.references"),
            action: #selector(showReferences(_:)),
            keyEquivalent: ""
        ))
        relationMenu.addItem(.separator())
        relationMenu.addItem(NSMenuItem(
            title: localized("main.copy.path.line"),
            action: #selector(copyPathLine(_:)),
            keyEquivalent: ""
        ))
        relationMenu.addItem(NSMenuItem(
            title: localized("main.reveal.in.finder"),
            action: #selector(revealInFinder(_:)),
            keyEquivalent: ""
        ))
        for item in relationMenu.items { item.target = self }
        textView.view.menu = relationMenu
        textView.onContextMenu = { [weak self] characterIndex in
            guard let self else { return }
            contextMenuOffset = displayedDocument == nil
                ? nil
                : textView.byteOffset(forCharacterIndex: characterIndex)
            let location = contextMenuLocation()
            for item in textView.view.menu?.items ?? [] where !item.isSeparatorItem {
                item.isEnabled = if item.action == #selector(revealInFinder(_:)) {
                    location.map {
                        FileManager.default.fileExists(atPath: $0.file.path)
                    } ?? false
                } else {
                    location != nil
                }
            }
        }
    }

    private func configureReaderHeader() {
        readerHeader.wantsLayer = true
        readerHeader.translatesAutoresizingMaskIntoConstraints = false
        fileNameLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        fileNameLabel.cell?.lineBreakMode = .byTruncatingMiddle
        fileNameLabel.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal)
        fileNameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tabStripView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tabStripView.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        readingHeightShortcutLabel.font = .systemFont(ofSize: 10)
        readingHeightShortcutLabel.isHidden = true
        readingHeightControl.target = self
        readingHeightControl.action = #selector(changeReadingHeight(_:))

        let row = NSStackView(views: [
            fileNameLabel,
            tabStripView,
            readingHeightShortcutLabel,
            readingHeightControl,
        ])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        readerHeaderDivider.wantsLayer = true
        readerHeaderDivider.translatesAutoresizingMaskIntoConstraints = false
        readerHeader.addSubview(row)
        readerHeader.addSubview(readerHeaderDivider)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(
                equalTo: readerHeader.leadingAnchor,
                constant: 13),
            row.trailingAnchor.constraint(
                equalTo: readerHeader.trailingAnchor,
                constant: -13),
            row.centerYAnchor.constraint(
                equalTo: readerHeader.centerYAnchor,
                constant: -0.5),
            readingHeightControl.widthAnchor.constraint(equalToConstant: 196),
            readingHeightControl.heightAnchor.constraint(equalToConstant: 24),
            tabStripView.heightAnchor.constraint(equalToConstant: 30),
            readerHeaderDivider.leadingAnchor.constraint(
                equalTo: readerHeader.leadingAnchor
            ),
            readerHeaderDivider.trailingAnchor.constraint(
                equalTo: readerHeader.trailingAnchor
            ),
            readerHeaderDivider.bottomAnchor.constraint(
                equalTo: readerHeader.bottomAnchor
            ),
            readerHeaderDivider.heightAnchor.constraint(equalToConstant: 1),
        ])
        readerHeader.setAccessibilityElement(false)
        fileNameLabel.setAccessibilityLabel(localized("main.current.file"))
        applyReaderHeaderTheme(ReaderSettings())
    }

    private func configureScopeHeader() {
        scopeHeader.wantsLayer = true
        scopeHeader.translatesAutoresizingMaskIntoConstraints = false
        scopeHeader.isHidden = true
        scopeHeaderContent.orientation = .horizontal
        scopeHeaderContent.alignment = .centerY
        scopeHeaderContent.spacing = 8
        scopeHeaderContent.translatesAutoresizingMaskIntoConstraints = false
        scopeHeaderDivider.wantsLayer = true
        scopeHeaderDivider.translatesAutoresizingMaskIntoConstraints = false
        readerArea.addSubview(scopeHeader)
        scopeHeader.addSubview(scopeHeaderContent)
        scopeHeader.addSubview(scopeHeaderDivider)
        NSLayoutConstraint.activate([
            scopeHeader.leadingAnchor.constraint(equalTo: readerArea.leadingAnchor),
            scopeHeader.trailingAnchor.constraint(equalTo: readerArea.trailingAnchor),
            scopeHeader.topAnchor.constraint(equalTo: readerArea.topAnchor),
            scopeHeader.heightAnchor.constraint(equalToConstant: 26),
            scopeHeaderContent.leadingAnchor.constraint(
                equalTo: scopeHeader.leadingAnchor,
                constant: 13
            ),
            scopeHeaderContent.trailingAnchor.constraint(
                lessThanOrEqualTo: scopeHeader.trailingAnchor,
                constant: -13
            ),
            scopeHeaderContent.centerYAnchor.constraint(
                equalTo: scopeHeader.centerYAnchor,
                constant: -0.5
            ),
            scopeHeaderDivider.leadingAnchor.constraint(
                equalTo: scopeHeader.leadingAnchor
            ),
            scopeHeaderDivider.trailingAnchor.constraint(
                equalTo: scopeHeader.trailingAnchor
            ),
            scopeHeaderDivider.bottomAnchor.constraint(
                equalTo: scopeHeader.bottomAnchor
            ),
            scopeHeaderDivider.heightAnchor.constraint(equalToConstant: 1),
        ])
        scopeHeader.setAccessibilityElement(true)
        scopeHeader.setAccessibilityLabel(localized("main.current.scope"))
        applyScopeHeaderTheme()
    }

    private func renderScopeHeader(at byteOffset: UInt32?) {
        scopeHeaderByteOffset = byteOffset
        guard !showsCompareControls,
              let byteOffset,
              let file = displayedFile,
              let document = displayedDocument
        else {
            hideScopeHeader()
            return
        }
        let facets = textView.scopeHeaderFacets(at: byteOffset)
        guard !facets.isEmpty,
              let line = document.lineTable.lineColumn(at: byteOffset)?.line
        else {
            hideScopeHeader()
            return
        }

        for arranged in scopeHeaderContent.arrangedSubviews {
            scopeHeaderContent.removeArrangedSubview(arranged)
            arranged.removeFromSuperview()
        }
        for (index, facet) in facets.enumerated() {
            if index > 0 {
                scopeHeaderContent.addArrangedSubview(scopeLabel(
                    "▸",
                    color: readerTheme.chromeTertiaryColor
                ))
            }
            scopeHeaderContent.addArrangedSubview(scopeLabel(
                Self.scopeKindTitle(facet.kind),
                color: readerTheme.color(for: .keyword)
            ))
            let button = NSButton(title: facet.name, target: self, action: #selector(openScope(_:)))
            button.isBordered = false
            button.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            button.contentTintColor = readerTheme.foregroundColor
            button.tag = Int(facet.nameRange.lowerBound)
            button.toolTip = localizedFormat("main.go.to", facet.name)
            button.setAccessibilityLabel(localizedFormat("main.go.to", facet.name))
            scopeHeaderContent.addArrangedSubview(button)
        }
        let location = "\(file.lastPathComponent):\(line)"
        scopeHeaderContent.addArrangedSubview(scopeLabel(
            location,
            color: readerTheme.chromeSecondaryColor
        ))
        scopeHeader.isHidden = false
        let scopes = facets.map {
            "\(Self.scopeKindTitle($0.kind)) \($0.name)"
        }.joined(separator: ", ")
        scopeHeader.setAccessibilityElement(false)
        scopeHeader.setAccessibilityLabel(
            localizedFormat("main.scope.description", scopes, file.lastPathComponent, Int64(line))
        )
    }

    private func hideScopeHeader() {
        scopeHeader.isHidden = true
        scopeHeader.setAccessibilityLabel(localized("main.current.scope"))
    }

    @objc private func openScope(_ sender: NSButton) {
        guard let offset = UInt32(exactly: sender.tag) else { return }
        if let onOpenScope { onOpenScope(offset) }
        else { _ = textView.activate(atByteOffset: offset) }
    }

    @objc private func revealBreadcrumb(_ sender: NSPathControl) {
        guard let url = sender.clickedPathItem?.url else { return }
        onRevealPath?(url)
    }

    private func updatePathControl() {
        guard !showsCompareControls else { return }
        pathControl.isHidden = displayedFile == nil
        guard let file = displayedFile else { pathControl.pathItems = []; return }
        pathControl.url = file
        pathControl.toolTip = file.path
        if let root = projectRoot,
           let index = pathControl.pathItems.firstIndex(where: { $0.url?.standardizedFileURL == root.standardizedFileURL }) {
            pathControl.pathItems = Array(pathControl.pathItems.dropFirst(index))
        }
    }

    private func scopeLabel(_ title: String, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = color
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setAccessibilityElement(false)
        return label
    }

    private static func scopeKindTitle(_ kind: OutlineKind) -> String {
        switch kind {
        case .fn: localized("main.scope.kind.fn")
        case .method: localized("main.scope.kind.method")
        case .struct: localized("main.scope.kind.struct")
        case .class: localized("main.scope.kind.class")
        case .enum: localized("main.scope.kind.enum")
        case .trait: localized("main.scope.kind.trait")
        case .impl: localized("main.scope.kind.impl")
        case .mod: localized("main.scope.kind.mod")
        case .const: localized("main.scope.kind.const")
        case .static: localized("main.scope.kind.static")
        case .typeAlias: localized("main.scope.kind.typeAlias")
        case .field: localized("main.scope.kind.field")
        case .enumMember: localized("main.scope.kind.enumMember")
        }
    }

    private func applyScopeHeaderTheme() {
        scopeHeader.layer?.backgroundColor = readerTheme.chromeColor.cgColor
        scopeHeaderDivider.layer?.backgroundColor =
            readerTheme.chromeDividerColor.cgColor
        renderScopeHeader(at: scopeHeaderByteOffset)
    }

    private func configureFindBar() {
        findBar.wantsLayer = true
        findBar.translatesAutoresizingMaskIntoConstraints = false
        findBar.isHidden = true
        findField.placeholderString = localized("main.find.in.file")
        findField.sendsSearchStringImmediately = true
        findField.sendsWholeSearchString = false
        findField.delegate = self
        findField.setAccessibilityLabel(localized("main.find.in.file"))

        findCaseButton.title = "Aa"
        findCaseButton.setButtonType(.toggle)
        findCaseButton.bezelStyle = .texturedRounded
        findCaseButton.target = self
        findCaseButton.action = #selector(toggleFindCase(_:))
        findCaseButton.toolTip = localized("main.match.case")
        findCaseButton.setAccessibilityLabel(localized("main.match.case"))

        findPreviousButton.title = "↑"
        findPreviousButton.bezelStyle = .inline
        findPreviousButton.target = self
        findPreviousButton.action = #selector(findPrevious(_:))
        findPreviousButton.setAccessibilityLabel(localized("main.previous.match"))

        findNextButton.title = "↓"
        findNextButton.bezelStyle = .inline
        findNextButton.target = self
        findNextButton.action = #selector(findNext(_:))
        findNextButton.setAccessibilityLabel(localized("main.next.match"))

        findStatusLabel.font = .systemFont(ofSize: 11)
        findStatusLabel.alignment = .right
        findStatusLabel.setContentCompressionResistancePriority(
            .defaultHigh,
            for: .horizontal
        )
        findStatusLabel.setAccessibilityLabel(localized("main.find.result"))

        findCloseButton.title = "×"
        findCloseButton.bezelStyle = .inline
        findCloseButton.target = self
        findCloseButton.action = #selector(closeFind(_:))
        findCloseButton.setAccessibilityLabel(localized("main.close.find.bar"))

        findField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        findField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [
            findField,
            findCaseButton,
            findPreviousButton,
            findNextButton,
            findStatusLabel,
            findCloseButton,
        ])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        findBarDivider.wantsLayer = true
        findBarDivider.translatesAutoresizingMaskIntoConstraints = false
        findBar.addSubview(row)
        findBar.addSubview(findBarDivider)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: findBar.leadingAnchor, constant: 13),
            row.trailingAnchor.constraint(equalTo: findBar.trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: findBar.centerYAnchor, constant: -0.5),
            findField.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
            findField.heightAnchor.constraint(equalToConstant: 22),
            findCaseButton.widthAnchor.constraint(equalToConstant: 34),
            findPreviousButton.widthAnchor.constraint(equalToConstant: 24),
            findNextButton.widthAnchor.constraint(equalToConstant: 24),
            findCloseButton.widthAnchor.constraint(equalToConstant: 24),
            findBarDivider.leadingAnchor.constraint(equalTo: findBar.leadingAnchor),
            findBarDivider.trailingAnchor.constraint(equalTo: findBar.trailingAnchor),
            findBarDivider.bottomAnchor.constraint(equalTo: findBar.bottomAnchor),
            findBarDivider.heightAnchor.constraint(equalToConstant: 1),
        ])
        findBar.setAccessibilityElement(false)
        applyFindBarTheme(ReaderSettings())
    }

    @objc private func changeReadingHeight(_ sender: ReadingHeightControl) {
        _ = setReadingHeightLevel(sender.level)
    }

    @objc private func toggleFindCase(_ sender: NSButton) {
        scheduleFind()
    }

    @objc private func findPrevious(_ sender: Any?) {
        navigateFind(by: -1)
    }

    @objc private func findNext(_ sender: Any?) {
        navigateFind(by: 1)
    }

    @objc private func closeFind(_ sender: Any?) {
        closeFindBar()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSSearchField === findField else { return }
        scheduleFind()
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard control === findField else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            navigateFind(by: NSEvent.modifierFlags.contains(.shift) ? -1 : 1)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            closeFindBar()
            return true
        default:
            return false
        }
    }

    func textView(
        _ textView: NSTextView,
        clickedOnLink link: Any,
        at charIndex: Int
    ) -> Bool {
        guard let file = displayedFile,
              let resolved = resolvedPreviewLink(link, relativeTo: file)
        else { return true }
        onOpenPreviewLink?(resolved)
        return true
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        let result = htmlNavigationDecision(
            for: navigationAction.request.url,
            navigationAction.navigationType,
            isMainFrame: navigationAction.targetFrame?.isMainFrame != false
        )
        decisionHandler(result.policy)
        if let callback = result.callback {
            onOpenPreviewLink?(callback)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard (previewView as? WKWebView) === webView else { return }
        previewHTMLFinished = true
        previewHTMLLoadError = nil
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        guard (previewView as? WKWebView) === webView else { return }
        previewHTMLFinished = false
        previewHTMLLoadError = error.localizedDescription
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        guard (previewView as? WKWebView) === webView else { return }
        previewHTMLFinished = false
        previewHTMLLoadError = error.localizedDescription
    }

    private func htmlNavigationDecision(
        for url: URL?,
        _ navigationType: WKNavigationType,
        isMainFrame: Bool
    ) -> (policy: WKNavigationActionPolicy, callback: URL?) {
        guard isMainFrame else { return (.cancel, nil) }
        if navigationType == .other,
           htmlInitialNavigationAllowed
        {
            htmlInitialNavigationAllowed = false
            return (.allow, nil)
        }
        guard navigationType == .linkActivated,
              let file = displayedFile,
              let url,
              let resolved = resolvedPreviewLink(url, relativeTo: file)
        else { return (.cancel, nil) }
        let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: true
        )
        let hasFragment = components?.fragment != nil
        let hasQuery = components?.query != nil
        if hasFragment,
           !hasQuery,
           resolved.standardizedFileURL == file.standardizedFileURL
        {
            return (.allow, nil)
        }
        return (.cancel, resolved)
    }

    private func htmlNavigationPolicy(
        for navigationType: WKNavigationType,
        isMainFrame: Bool
    ) -> WKNavigationActionPolicy {
        htmlNavigationDecision(
            for: nil,
            navigationType,
            isMainFrame: isMainFrame
        ).policy
    }

    func selfTestHTMLNavigationPolicy(
        for navigationType: WKNavigationType,
        initialLoad: Bool = false
    ) -> WKNavigationActionPolicy {
        if initialLoad { htmlInitialNavigationAllowed = true }
        return htmlNavigationPolicy(for: navigationType, isMainFrame: true)
    }

    func selfTestHTMLNavigationPolicy(
        for url: URL,
        navigationType: WKNavigationType,
        initialLoad: Bool = false
    ) -> WKNavigationActionPolicy {
        if initialLoad { htmlInitialNavigationAllowed = true }
        let result = htmlNavigationDecision(
            for: url,
            navigationType,
            isMainFrame: true
        )
        if let callback = result.callback {
            onOpenPreviewLink?(callback)
        }
        return result.policy
    }

    var selfTestReaderHTMLFinished: Bool { previewHTMLFinished }
    var selfTestReaderHTMLLoadError: String? { previewHTMLLoadError }

    func selfTestActivatePreviewLink(at index: Int) -> Bool {
        guard index >= 0,
              let previewTextView = (previewView as? NSScrollView)?
                  .documentView as? NSTextView,
              let storage = previewTextView.textStorage
        else { return false }
        var ordinal = 0
        var value: Any?
        storage.enumerateAttribute(
            .link,
            in: NSRange(location: 0, length: storage.length)
        ) { attribute, _, stop in
            guard attribute != nil else { return }
            if ordinal == index {
                value = attribute
                stop.pointee = true
            }
            ordinal += 1
        }
        guard let value else { return false }
        return textView(
            previewTextView,
            clickedOnLink: value,
            at: 0
        )
    }

    private func resolvedPreviewLink(_ value: Any, relativeTo file: URL) -> URL? {
        let resolved: URL?
        if let url = value as? URL {
            resolved = URL(string: url.absoluteString, relativeTo: file)?.absoluteURL
        } else if let string = value as? String {
            resolved = URL(string: string, relativeTo: file)?.absoluteURL
        } else {
            resolved = nil
        }
        guard let resolved else { return nil }
        guard resolved.isFileURL,
              resolved.host == nil
                || resolved.host?.isEmpty == true
                || resolved.host?.caseInsensitiveCompare("localhost") == .orderedSame
        else { return nil }
        var components = URLComponents(
            url: resolved,
            resolvingAgainstBaseURL: true
        )
        components?.query = nil
        components?.fragment = nil
        return components?.url?.standardizedFileURL
    }

    private func applyReaderHeaderTheme(_ settings: ReaderSettings) {
        readerTheme = ReaderTheme(settings: settings)
        readerHeader.layer?.backgroundColor = readerTheme.chromeHeaderColor.cgColor
        readerHeaderDivider.layer?.backgroundColor =
            readerTheme.chromeDividerColor.cgColor
        fileNameLabel.textColor = readerTheme.foregroundColor
        readingHeightShortcutLabel.textColor = readerTheme.chromeTertiaryColor
        readingHeightControl.apply(settings: settings)
        applyScopeHeaderTheme()
        applyFindBarTheme(settings)
    }

    private func applyFindBarTheme(_ settings: ReaderSettings) {
        let theme = ReaderTheme(settings: settings)
        findBar.layer?.backgroundColor = theme.chromeHeaderColor.cgColor
        findBarDivider.layer?.backgroundColor = theme.chromeDividerColor.cgColor
        findStatusLabel.textColor = theme.chromeSecondaryColor
    }

    private func compareContainer(readerView: NSView) -> NSView {
        compareVersionButton.title = localized("main.choose.comparison.version")
        compareVersionButton.bezelStyle = .rounded
        compareVersionButton.target = self
        compareVersionButton.action = #selector(chooseCompareVersion(_:))
        compareVersionButton.setAccessibilityLabel(localized("main.comparison.version"))
        compareVersionButton.lineBreakMode = .byTruncatingMiddle
        compareVersionButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        previousHunkButton.title = "↑"
        previousHunkButton.bezelStyle = .inline
        previousHunkButton.target = self
        previousHunkButton.action = #selector(previousDiffHunk(_:))
        previousHunkButton.setAccessibilityLabel(localized("main.previous.diff.hunk"))
        nextHunkButton.title = "↓"
        nextHunkButton.bezelStyle = .inline
        nextHunkButton.target = self
        nextHunkButton.action = #selector(nextDiffHunk(_:))
        nextHunkButton.setAccessibilityLabel(localized("main.next.diff.hunk"))

        let closeButton = NSButton()
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closeComparison(_:))
        closeButton.toolTip = localized("main.close.comparison.w")
        closeButton.setAccessibilityLabel(localized("main.close.comparison"))
        let spacer = NSView()
        let controls = NSStackView(views: [
            compareVersionButton, spacer, previousHunkButton, nextHunkButton, closeButton,
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
            closeButton.widthAnchor.constraint(equalToConstant: 22),
            closeButton.heightAnchor.constraint(equalToConstant: 22),
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

    @objc private func closeComparison(_ sender: Any?) {
        onCloseComparison?()
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
        case .added: localized("main.added")
        case .removed: localized("main.removed")
        case .signatureChanged: localized("main.signature")
        case .bodyChanged: localized("main.body")
        }
    }

    func apply(settings: ReaderSettings) {
        loadViewIfNeeded()
        let previewWrapChanged = previewWrapLines != settings.wrapLines
        previewWrapLines = settings.wrapLines
        readerTheme = ReaderTheme(settings: settings)
        textView.apply(settings: settings)
        readingSetView.apply(settings: settings)
        previewArea.layer?.backgroundColor = readerTheme.backgroundColor.cgColor
        if let previewTextView = (previewView as? NSScrollView)?.documentView as? NSTextView {
            previewTextView.backgroundColor = readerTheme.backgroundColor
            previewTextView.textColor = readerTheme.foregroundColor
            if textPreviewKind == .plainText, previewWrapChanged,
               let previewScrollView = previewView as? NSScrollView {
                configurePlainTextPreview(previewTextView, in: previewScrollView)
            }
        }
        if let pdfView = previewView as? PDFView {
            pdfView.backgroundColor = readerTheme.backgroundColor
        }
        if let webView = previewView as? WKWebView,
           let html = previewHTMLSource,
           let baseURL = previewHTMLBaseURL
        {
            webView.underPageBackgroundColor = readerTheme.backgroundColor
            previewHTMLFinished = false
            previewHTMLLoadError = nil
            htmlInitialNavigationAllowed = true
            webView.loadHTMLString(htmlPreviewMarkup(html), baseURL: baseURL)
        }
        if !showsCompareControls {
            tabStripView.apply(settings: settings)
            applyReaderHeaderTheme(settings)
        }
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
        readingSetView.onScroll = { [weak model] offset in
            model?.updateActiveReadingSetScroll(offset)
        }
    }

    func refreshTabs() {
        guard !showsCompareControls else { return }
        loadViewIfNeeded()
        tabStripView.refresh()
        fileNameLabel.stringValue = tabStripView.activeTitle
        fileNameLabel.isHidden = !tabStripView.isHidden
    }

    func showEmptyState(
        recentPaths: [String],
        failed: Bool,
        failureReason: String? = nil,
        onChooseProject: @escaping () -> Void,
        onOpenRecent: @escaping (URL) -> Void,
        onOpenDropped: @escaping (URL) -> Void,
        onRetry: @escaping () -> Void
    ) {
        loadViewIfNeeded()
        pathControl.isHidden = true
        readingHeightControl.isEnabled = false
        label.isHidden = true
        scrollView?.isHidden = true
        if let emptyStateView {
            emptyStateView.update(
                recentPaths: recentPaths,
                failed: failed,
                reason: failureReason
            )
            return
        }
        let emptyStateView = EmptyStateView(
            recentPaths: recentPaths,
            failed: failed,
            onChooseProject: onChooseProject,
            onOpenRecent: onOpenRecent,
            onOpenDropped: onOpenDropped,
            onRetry: onRetry
        )
        emptyStateView.update(
            recentPaths: recentPaths,
            failed: failed,
            reason: failureReason
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
        guard displayedReadingSetKey == nil else { return }
        scrollView?.isHidden = false
        readingHeightControl.isEnabled = displayedDocument != nil
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
    var selfTestEmptyStateFailureReason: String? {
        emptyStateView?.selfTestFailureReason
    }
    var selfTestEmptyStateReasonIsSelectable: Bool {
        emptyStateView?.selfTestReasonIsSelectable == true
    }
    var selfTestEmptyStateChooseFolderActionAvailable: Bool {
        emptyStateView?.selfTestChooseFolderActionAvailable == true
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
    var selfTestPreviewState: (
        kind: String?,
        renderedText: String?,
        linkCount: Int,
        editable: Bool,
        selectable: Bool,
        visible: Bool,
        sourceVisible: Bool,
        previewVisible: Bool,
        accessibilityLabel: String?,
        htmlJavaScriptEnabled: Bool?,
        htmlDataStorePersistent: Bool?,
        htmlContentSecurityPolicy: String?,
        pdfPageCount: Int?,
        imageSize: NSSize?
    ) {
        let previewTextView = (previewView as? NSScrollView)?.documentView as? NSTextView
        return (
            previewKind,
            previewRenderedText,
            previewLinkCount,
            previewTextView?.isEditable ?? false,
            previewTextView?.isSelectable ?? false,
            previewView != nil && !previewArea.isHidden,
            scrollView?.isHidden == false,
            !previewArea.isHidden,
            previewAccessibilityLabel,
            previewHTMLJavaScriptEnabled,
            previewHTMLDataStorePersistent,
            previewHTMLContentSecurityPolicy,
            previewPDFPageCount,
            previewImageSize
        )
    }
    func selfTestPreviewFont(at substring: String) -> NSFont? {
        guard !substring.isEmpty,
              let previewTextView = (previewView as? NSScrollView)?
                  .documentView as? NSTextView,
              let storage = previewTextView.textStorage
        else { return nil }
        let range = (storage.string as NSString).range(of: substring)
        guard range.location != NSNotFound else { return nil }
        return storage.attribute(.font, at: range.location, effectiveRange: nil)
            as? NSFont
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
        headerFrame: NSRect,
        controlFrame: NSRect,
        scopeFrame: NSRect,
        readerFrame: NSRect,
        containerFrame: NSRect,
        stripHidden: Bool,
        scopeHidden: Bool,
        stripHiddenOrHasHiddenAncestor: Bool
    ) {
        (
            tabStripView.convert(tabStripView.bounds, to: nil),
            readerHeader.convert(readerHeader.bounds, to: nil),
            readingHeightControl.superview?.convert(
                readingHeightControl.alignmentRect(
                    forFrame: readingHeightControl.frame
                ),
                to: nil
            ) ?? .zero,
            scopeHeader.convert(scopeHeader.bounds, to: nil),
            readerArea.convert(readerArea.bounds, to: nil),
            readerArea.convert(readerArea.bounds, to: nil),
            tabStripView.isHidden,
            scopeHeader.isHidden,
            tabStripView.isHiddenOrHasHiddenAncestor
        )
    }

    var readingHeightLevel: ReadingHeightLevel { textView.readingHeightLevel }
    var isFindBarVisible: Bool { !findBar.isHidden }
    var canFindInFile: Bool { displayedDocument != nil && !showsCompareControls }

    @discardableResult
    func showFindBar() -> Bool {
        loadViewIfNeeded()
        guard canFindInFile else { return false }
        if findBar.isHidden {
            savedSymbolOccurrenceByteOffset = textView.symbolOccurrenceByteOffset
            findBar.isHidden = false
            scheduleFind(immediate: true)
        }
        view.window?.makeFirstResponder(findField)
        findField.currentEditor()?.selectAll(nil)
        return true
    }

    @discardableResult
    func closeFindBar() -> Bool {
        guard !findBar.isHidden else { return false }
        invalidateFind()
        findBar.isHidden = true
        textView.clearFindMatches(
            restoringSymbolAt: savedSymbolOccurrenceByteOffset
        )
        savedSymbolOccurrenceByteOffset = nil
        findWrapped = false
        findStatusLabel.stringValue = ""
        view.window?.makeFirstResponder(textView.view)
        return true
    }

    func findNextMatch() {
        if findBar.isHidden { _ = showFindBar() }
        navigateFind(by: 1)
    }

    func findPreviousMatch() {
        if findBar.isHidden { _ = showFindBar() }
        navigateFind(by: -1)
    }

    private func scheduleFind(immediate: Bool = false) {
        invalidateFind()
        findWrapped = false
        let query = findField.stringValue
        guard !findBar.isHidden,
              let file = displayedFile?.standardizedFileURL,
              let document = displayedDocument
        else { return }
        guard !query.isEmpty else {
            textView.setFindMatches([], selectedIndex: nil)
            renderFindStatus()
            return
        }
        guard !query.contains("\n"), !query.contains("\r") else {
            textView.setFindMatches([], selectedIndex: nil)
            findStatusLabel.stringValue = localized("main.line.breaks.are.not.supported")
            findPreviousButton.isEnabled = false
            findNextButton.isEnabled = false
            return
        }

        let requestID = findRequestID
        let contentID = document.contentID
        let bytes = document.bytes
        let pattern = Array(query.utf8)
        let caseSensitive = findCaseButton.state == .on
        let selectedRange = textView.selectedFindMatchRange
        let scanDelay = findScanDelayForTesting
        findStatusLabel.stringValue = localized("main.searching")
        findPreviousButton.isEnabled = false
        findNextButton.isEnabled = false
        findTask = Task { [weak self] in
            if !immediate {
                do {
                    try await Task.sleep(for: .milliseconds(150))
                } catch {
                    return
                }
            }
            guard let self, requestID == self.findRequestID else { return }
            let worker = Task.detached(priority: .userInitiated) {
                if scanDelay != .zero {
                    try await Task.sleep(for: scanDelay)
                }
                return try literalRanges(
                    pattern,
                    in: bytes,
                    caseSensitive: caseSensitive
                )
            }
            self.findWorker = worker
            do {
                let ranges = try await worker.value
                guard requestID == self.findRequestID,
                      !self.findBar.isHidden,
                      self.displayedFile?.standardizedFileURL == file,
                      self.displayedDocument?.contentID == contentID,
                      self.findField.stringValue == query,
                      (self.findCaseButton.state == .on) == caseSensitive
                else { return }
                self.findWorker = nil
                let selectedIndex = selectedRange.flatMap { ranges.firstIndex(of: $0) }
                    ?? (ranges.isEmpty ? nil : 0)
                self.textView.setFindMatches(
                    ranges,
                    selectedIndex: selectedIndex
                )
                if let selectedIndex {
                    _ = self.textView.revealFindMatch(at: selectedIndex)
                }
                self.renderFindStatus()
            } catch is CancellationError {
                self.findCancelledWorkerCountForTesting += 1
                return
            } catch {
                guard requestID == self.findRequestID else { return }
                self.findStatusLabel.stringValue = localized("main.search.failed")
            }
        }
    }

    private func invalidateFind() {
        findRequestID &+= 1
        findTask?.cancel()
        findTask = nil
        findWorker?.cancel()
        findWorker = nil
    }

    private func navigateFind(by delta: Int) {
        let count = textView.findMatchCount
        guard count > 0 else { return }
        let previous = textView.selectedFindMatchIndex ?? (delta > 0 ? -1 : 0)
        let unwrapped = previous + delta
        let next = (unwrapped % count + count) % count
        findWrapped = unwrapped < 0 || unwrapped >= count
        _ = textView.revealFindMatch(at: next)
        renderFindStatus()
    }

    private func renderFindStatus() {
        let count = textView.findMatchCount
        findPreviousButton.isEnabled = count > 0
        findNextButton.isEnabled = count > 0
        guard count > 0, let selected = textView.selectedFindMatchIndex else {
            findStatusLabel.stringValue = localized("main.0.matches")
            return
        }
        findStatusLabel.stringValue = "\(selected + 1) / \(count)"
            + (findWrapped ? localized("main.wrapped") : "")
    }
    var isFocusMode: Bool { textView.isFocusMode }
    var canFocusCurrentScope: Bool { displayedDocument != nil }
    /// Byte offset of the Reader's current selection or caret, when a
    /// source document is displayed. Drives surface-scoped relation
    /// commands alongside the context menu.
    var currentSelectionByteOffset: UInt32? {
        guard displayedDocument != nil, displayedFile != nil else { return nil }
        let range = textView.view.selectedRange()
        guard range.location != NSNotFound,
              let byteOffset = textView.byteOffset(
                  forCharacterIndex: range.location
              ),
              let offset = UInt32(exactly: byteOffset)
        else { return nil }
        return offset
    }
    @discardableResult
    func setReadingHeightLevel(_ level: ReadingHeightLevel) -> Bool {
        loadViewIfNeeded()
        let changed = textView.setReadingHeightLevel(level)
        readingHeightControl.set(level: textView.readingHeightLevel)
        return changed
    }
    @discardableResult
    func toggleFocusCurrentScope() -> Bool {
        if textView.isFocusMode { return textView.exitFocusMode() }
        guard let byteOffset = textView.byteOffset(
            forCharacterIndex: textView.view.selectedRange().location
        ), textView.focusCurrentScope(at: byteOffset)
        else {
            onFocusNotice?(localized("main.no.enclosing.scope.to.focus"))
            return false
        }
        return true
    }
    @discardableResult
    func toggleFoldAtSelection() -> Bool {
        guard let document = displayedDocument,
            let byteOffset = textView.byteOffset(
                forCharacterIndex: textView.view.selectedRange().location
            ),
            let line = document.lineTable.lineColumn(at: byteOffset)?.line
        else { return false }
        return textView.toggleFold(atLine: Int(line))
    }
    var canToggleFoldAtSelection: Bool {
        guard let document = displayedDocument,
            let byteOffset = textView.byteOffset(
                forCharacterIndex: textView.view.selectedRange().location
            ),
            let line = document.lineTable.lineColumn(at: byteOffset)?.line
        else { return false }
        return textView.canToggleFold(atLine: Int(line))
    }
    var selfTestReadingHeightHeader:
        (
            fileName: String,
            level: ReadingHeightLevel,
            labels: [String],
            frame: NSRect,
            controlFrame: NSRect,
            shortcut: String,
            accessibilityLabel: String,
            hidden: Bool,
            enabled: Bool
        )
    {
        loadViewIfNeeded()
        view.layoutSubtreeIfNeeded()
        return (
            fileNameLabel.stringValue,
            readingHeightControl.level,
            (0..<readingHeightControl.segmentCount).compactMap {
                readingHeightControl.label(forSegment: $0)
            },
            readerHeader.convert(readerHeader.bounds, to: nil),
            readingHeightControl.superview?.convert(
                readingHeightControl.alignmentRect(
                    forFrame: readingHeightControl.frame
                ),
                to: nil
            ) ?? .zero,
            readingHeightShortcutLabel.stringValue,
            readingHeightControl.accessibilityLabel() ?? "",
            readingHeightControl.isHidden,
            readingHeightControl.isEnabled
        )
    }
    var selfTestScopeHeader: (
        hidden: Bool,
        frame: NSRect,
        readerFrame: NSRect,
        labels: [String],
        labelFrames: [NSRect],
        fontNames: [String],
        accessibilityLabel: String
    ) {
        loadViewIfNeeded()
        view.layoutSubtreeIfNeeded()
        let labels = scopeHeaderContent.arrangedSubviews.compactMap { $0 as? NSControl }
        return (
            scopeHeader.isHidden,
            scopeHeader.convert(scopeHeader.bounds, to: nil),
            readerArea.convert(readerArea.bounds, to: nil),
            labels.map { ($0 as? NSButton)?.title ?? $0.stringValue },
            labels.map { label in
                guard let parent = label.superview else { return .zero }
                return parent.convert(
                    label.alignmentRect(forFrame: label.frame),
                    to: nil
                )
            },
            labels.compactMap { $0.font?.fontName },
            scopeHeader.accessibilityLabel() ?? ""
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
        compareVersionButton.toolTip = versionTitle
        previousHunkButton.isEnabled = hunkCount > 0
        nextHunkButton.isEnabled = hunkCount > 0
        previousHunkButton.toolTip = hunkCount == 0
            ? localized("main.no.diff.hunks")
            : localized("main.previous.hunk")
        nextHunkButton.toolTip = hunkCount == 0
            ? localized("main.no.diff.hunks")
            : localized("main.next.hunk")
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
            ?? (truncated ? localized("main.large.diff.side.by.side.only") : nil)
        if let status {
            let label = NSTextField(labelWithString: status)
            label.textColor = .secondaryLabelColor
            functionSummaryStack.addArrangedSubview(label)
        } else if functionChanges.isEmpty {
            let label = NSTextField(labelWithString: localized("main.no.function.changes"))
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

    func setBookmarkMarkers(_ markers: [Int: [String]]) {
        loadViewIfNeeded()
        textView.setBookmarkMarkers(markers)
    }

    var displayedBytes: [UInt8]? { textView.displayedBytes }
    var bookmarkMarkerLines: [Int] { textView.bookmarkMarkerLines }
    var bookmarkMarkerAccessibilityLabel: String? {
        textView.bookmarkMarkerAccessibilityLabel
    }
    var isEditable: Bool { textView.view.isEditable }
    var diffMarkerCounts: [DiffCore.MarkerKind: Int] { textView.diffMarkerCounts }
    var gutterShowsLineNumbersAndDiff: Bool {
        textView.gutterShowsLineNumbersAndDiff
    }
    var selectedDiffLine: Int? { textView.selectedLineNumber }
    var selfTestOccurrenceCount: Int { textView.occurrenceCount }
    var selfTestFindState: (
        visible: Bool,
        query: String,
        status: String,
        count: Int,
        selectedIndex: Int?,
        previousEnabled: Bool,
        nextEnabled: Bool,
        barFrame: NSRect,
        fieldFrame: NSRect,
        caseFrame: NSRect,
        closeFrame: NSRect
    ) {
        loadViewIfNeeded()
        view.layoutSubtreeIfNeeded()
        return (
            !findBar.isHidden,
            findField.stringValue,
            findStatusLabel.stringValue,
            textView.findMatchCount,
            textView.selectedFindMatchIndex,
            findPreviousButton.isEnabled,
            findNextButton.isEnabled,
            findBar.frame,
            findField.frame,
            findCaseButton.frame,
            findCloseButton.frame
        )
    }
    func selfTestSetFind(
        _ query: String,
        caseSensitive: Bool = false,
        delay: Duration = .zero
    ) {
        findScanDelayForTesting = delay
        findCaseButton.state = caseSensitive ? .on : .off
        findField.stringValue = query
        scheduleFind(immediate: true)
        findScanDelayForTesting = .zero
    }
    func selfTestNavigateFind(by delta: Int) {
        navigateFind(by: delta)
    }
    var selfTestFindWorkerActive: Bool { findWorker != nil }
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
    func selfTestFontName(at byteOffset: UInt32) -> String? {
        textView.font(atByteOffset: byteOffset)?.fontName
    }
    func selfTestFontSize(at byteOffset: UInt32) -> CGFloat? {
        textView.font(atByteOffset: byteOffset)?.pointSize
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
    var selfTestPrimarySelectionRange: NSRange? {
        textView.primarySelectionRange
    }
    var selfTestReaderCaretByteOffset: UInt32? {
        textView.byteOffset(forCharacterIndex: textView.view.selectedRange().location)
    }
    func selfTestEmitOutlineFollow(at byteOffset: UInt32) {
        onOutlineFollowPositionChange?(byteOffset)
    }
    func selfTestPostLiveScroll() {
        guard let scrollView else { return }
        NotificationCenter.default.post(
            name: NSScrollView.didLiveScrollNotification,
            object: scrollView
        )
    }
    var selfTestReadingGeometry: (
        scrollFrame: NSRect,
        clipFrame: NSRect,
        contentFrame: NSRect,
        rulerFrame: NSRect,
        hasRuler: Bool,
        rulerThickness: CGFloat,
        firstGlyphGap: CGFloat?
    ) {
        loadViewIfNeeded()
        guard let scrollView else {
            return (.zero, .zero, .zero, .zero, false, 0, nil)
        }
        let ruler = scrollView.verticalRulerView
        let rulerFrame = ruler?.convert(ruler?.bounds ?? .zero, to: nil) ?? .zero
        let clipFrame = scrollView.contentView.convert(scrollView.contentView.bounds, to: nil)
        let visible = textView.view.convert(textView.view.visibleRect, to: nil)
            .intersection(clipFrame)
        let textMinX = rulerFrame.intersects(visible)
            ? max(visible.minX, rulerFrame.maxX) : visible.minX
        let contentFrame = NSRect(
            x: textMinX, y: visible.minY,
            width: max(0, visible.maxX - textMinX), height: visible.height
        )
        let firstGlyphGap: CGFloat?
        if let window = textView.view.window, !textView.view.string.isEmpty {
            let glyph = window.convertFromScreen(textView.view.firstRect(
                forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil
            ))
            firstGlyphGap = glyph.isEmpty ? nil : glyph.minX - contentFrame.minX
        } else {
            firstGlyphGap = nil
        }
        return (
            scrollView.convert(scrollView.bounds, to: nil),
            clipFrame,
            contentFrame,
            rulerFrame,
            scrollView.hasVerticalRuler,
            ruler?.ruleThickness ?? 0,
            firstGlyphGap
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
        _ content: TabContent?,
        snapshotID: SnapshotID? = nil,
        source: DocumentLoader.ContentSource? = nil,
        languageMode: LanguageMode? = LanguageMode(language: .rust),
        readingSetAvailability: [(open: Bool, expand: Bool)]? = nil,
        readingSetSkippedReasons: [String] = []
    ) {
        switch content {
        case .file(let file):
            display(
                file,
                snapshotID: snapshotID,
                source: source,
                languageMode: languageMode
            )
        case .readingSet(let title, let excerpts):
            displayReadingSet(
                title: title,
                excerpts: excerpts,
                actionAvailability: readingSetAvailability,
                skippedReasons: readingSetSkippedReasons
            )
        case nil:
            display(
                URL?.none,
                snapshotID: snapshotID,
                source: source,
                languageMode: languageMode
            )
        }
    }

    private func displayReadingSet(
        title: String,
        excerpts: [ReadingSetExcerpt],
        actionAvailability: [(open: Bool, expand: Bool)]?,
        skippedReasons: [String]
    ) {
        loadViewIfNeeded()
        let key = title + excerpts.map {
            "\($0.contentID.bytes)-\($0.byteRange.lowerBound)-\($0.byteRange.upperBound)"
        }.joined(separator: "|") + (actionAvailability?.map {
            "\($0.open)-\($0.expand)"
        }.joined(separator: "|") ?? "") + skippedReasons.joined(separator: "|")
        guard key != displayedReadingSetKey else { return }
        findTask?.cancel()
        findWorker?.cancel()
        readingPositionTask?.cancel()
        loadGeneration &+= 1
        displayedFile = nil
        updatePathControl()
        displayedSnapshotID = nil
        displayedLanguageMode = nil
        displayedDocument = nil
        displayedReadingSetKey = key
        contextMenuOffset = nil
        onOutlineChange?([])
        hideScopeHeader()
        findBar.isHidden = true
        label.isHidden = true
        clearPreview()
        textView.clear()
        scrollView?.isHidden = true
        readingSetView.isHidden = false
        readingHeightControl.isHidden = true
        readingHeightControl.isEnabled = false
        readingHeightShortcutLabel.isHidden = true
        fileNameLabel.stringValue = localizedFormat("main.reading.set", title)
        readingSetView.display(
            title: title,
            excerpts: excerpts,
            canOpen: onOpenReadingSetExcerpt != nil,
            canExpand: onExpandReadingSetExcerpt != nil,
            canViewEvidence: onViewReadingSetEvidence != nil,
            openAvailability: actionAvailability?.map(\.open),
            expandAvailability: actionAvailability?.map(\.expand),
            skippedReasons: skippedReasons
        )
    }

    private static let previewContentSecurityPolicy =
        "default-src 'none'; style-src 'unsafe-inline'; img-src data:; "
            + "object-src 'none'; frame-src 'none'; connect-src 'none'; "
            + "media-src 'none'; base-uri 'none'; form-action 'none'"

    private func clearPreview() {
        if let webView = previewView as? WKWebView {
            webView.stopLoading()
            webView.navigationDelegate = nil
        }
        previewView?.removeFromSuperview()
        previewView = nil
        previewKind = nil
        textPreviewKind = nil
        previewUnwrappedX = 0
        previewRenderedText = nil
        previewLinkCount = 0
        previewAccessibilityLabel = nil
        previewHTMLJavaScriptEnabled = nil
        previewHTMLDataStorePersistent = nil
        previewHTMLContentSecurityPolicy = nil
        previewPDFPageCount = nil
        previewImageSize = nil
        previewHTMLSource = nil
        previewHTMLBaseURL = nil
        previewHTMLFinished = false
        previewHTMLLoadError = nil
        htmlInitialNavigationAllowed = false
        previewArea.isHidden = true
    }

    private func installPreview(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        previewArea.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: previewArea.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: previewArea.trailingAnchor),
            view.topAnchor.constraint(equalTo: previewArea.topAnchor),
            view.bottomAnchor.constraint(equalTo: previewArea.bottomAnchor),
        ])
        previewView = view
        previewArea.layer?.backgroundColor = readerTheme.backgroundColor.cgColor
        previewArea.isHidden = false
        scrollView?.isHidden = true
        label.isHidden = true
        readingSetView.isHidden = true
    }

    private func displayPreview(
        _ file: URL,
        source: DocumentLoader.ContentSource?
    ) {
        findBar.isHidden = true
        invalidateFind()
        savedSymbolOccurrenceByteOffset = nil
        textView.clear()
        readingHeightControl.isHidden = true
        readingHeightControl.isEnabled = false
        readingHeightShortcutLabel.isHidden = true
        syntaxLoadPending = false
        pendingFocusNavigationOffset = nil
        displayedDocument = nil
        onDocumentChange?(file, nil)
        clearPreview()

        let bytes: [UInt8]
        do {
            if let source {
                bytes = try source(file)
            } else {
                bytes = Array(try Data(contentsOf: file, options: .mappedIfSafe))
            }
        } catch {
            displayPreviewError(localizedFormat("main.open.failure", file.lastPathComponent))
            return
        }

        let extensionName = file.pathExtension.lowercased()
        if extensionName == "pdf" {
            guard let document = PDFDocument(data: Data(bytes)) else {
                displayPreviewError(localized("main.could.not.open.pdf"))
                return
            }
            let pdfView = PDFView()
            pdfView.document = document
            pdfView.autoScales = true
            pdfView.displayMode = .singlePageContinuous
            pdfView.displaysPageBreaks = true
            pdfView.backgroundColor = readerTheme.backgroundColor
            pdfView.setAccessibilityLabel(localized("main.pdf.preview"))
            previewKind = "PDF"
            previewAccessibilityLabel = localized("main.pdf.preview")
            previewPDFPageCount = document.pageCount
            installPreview(pdfView)
            return
        }

        if let image = NSImage(data: Data(bytes)) {
            let imageView = NSImageView()
            imageView.image = image
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.imageAlignment = .alignCenter
            imageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
            imageView.setContentHuggingPriority(.defaultLow, for: .vertical)
            imageView.setContentCompressionResistancePriority(
                .defaultLow,
                for: .horizontal
            )
            imageView.setContentCompressionResistancePriority(
                .defaultLow,
                for: .vertical
            )
            imageView.setAccessibilityLabel(localized("main.image.preview"))
            previewKind = "Image"
            previewAccessibilityLabel = localized("main.image.preview")
            previewImageSize = image.size
            installPreview(imageView)
            return
        }

        guard let string = String(bytes: bytes, encoding: .utf8) else {
            displayPreviewError(localized("main.unsupported.binary"))
            return
        }
        if extensionName == "md" || extensionName == "markdown" {
            guard let markdown = try? AttributedString(
                markdown: string,
                options: .init(),
                baseURL: file
            ) else {
                displayPreviewError(localized("main.unsupported.binary"))
                return
            }
            let attributed = markdownPreviewAttributedString(markdown)
            displayPreviewText(
                attributed,
                kind: .markdown,
                accessibilityLabel: localized("main.markdown.preview")
            )
            return
        }
        if extensionName == "html" || extensionName == "htm" {
            displayPreviewHTML(string, file: file)
            return
        }
        displayPreviewText(
            NSAttributedString(string: string),
            kind: .plainText,
            accessibilityLabel: localized("main.plain.text.preview")
        )
    }

    private func markdownPreviewAttributedString(
        _ markdown: AttributedString
    ) -> NSAttributedString {
        let rendered = NSMutableAttributedString()
        var previousComponents: [PresentationIntent.IntentType]?
        var previousListItemIdentity: Int?
        // Ordinal for the item currently open in each ordered list.
        var orderedCounters: [Int: Int] = [:]
        for run in markdown.runs {
            let components = run.presentationIntent?.components ?? []
            let leaf = components.first
            let listItem = components.first {
                if case .listItem = $0.kind { return true }
                return false
            }
            let orderedList = components.first {
                if case .orderedList = $0.kind { return true }
                return false
            }
            let listContainer = orderedList ?? components.first {
                if case .unorderedList = $0.kind { return true }
                return false
            }
            if let previousComponents,
               let previousLeaf = previousComponents.first,
               let leaf,
               previousLeaf.identity != leaf.identity,
               rendered.length > 0,
               !rendered.string.hasSuffix("\n")
            {
                let previousIsListItem = previousComponents.contains {
                    if case .listItem = $0.kind { return true }
                    return false
                }
                let isListItem = previousIsListItem && components.contains {
                    if case .listItem = $0.kind { return true }
                    return false
                }
                rendered.append(NSAttributedString(
                    string: isListItem ? "\n" : "\n\n"
                ))
            }
            // A new list item begins: emit its marker with nesting indent.
            // Unordered items get a bullet; ordered items number within
            // their list, restarting when the list changes (§S10a).
            if let listItem,
               listItem.identity != previousListItemIdentity
            {
                let nesting = components.reduce(0) { count, component in
                    switch component.kind {
                    case .orderedList, .unorderedList:
                        count + 1
                    default:
                        count
                    }
                }
                let indent = String(
                    repeating: "  ",
                    count: max(0, nesting - 1)
                )
                if let orderedList {
                    let counter = (orderedCounters[orderedList.identity] ?? 0) + 1
                    orderedCounters[orderedList.identity] = counter
                    rendered.append(NSAttributedString(
                        string: "\(indent)\(counter). "
                    ))
                } else {
                    rendered.append(NSAttributedString(
                        string: "\(indent)• "
                    ))
                }
                previousListItemIdentity = listItem.identity
            }
            _ = listContainer
            let attributed = NSMutableAttributedString(
                attributedString: NSAttributedString(
                    AttributedString(markdown[run.range])
                )
            )
            if attributed.length > 0 {
                let range = NSRange(location: 0, length: attributed.length)
                let baseFont: NSFont = switch leaf?.kind {
                case .header(let level):
                    NSFont.systemFont(
                        ofSize: max(16, 24 - CGFloat(min(level, 6)) * 1.5),
                        weight: .semibold
                    )
                case .codeBlock:
                    NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
                default:
                    NSFont.systemFont(ofSize: 14)
                }
                var font = baseFont
                if run.inlinePresentationIntent?.contains(.code) == true {
                    font = NSFont.monospacedSystemFont(
                        ofSize: baseFont.pointSize,
                        weight: .regular
                    )
                }
                if run.inlinePresentationIntent?.contains(
                    .stronglyEmphasized
                ) == true {
                    font = NSFontManager.shared.convert(
                        font,
                        toHaveTrait: .boldFontMask
                    )
                }
                if run.inlinePresentationIntent?.contains(.emphasized) == true {
                    font = NSFontManager.shared.convert(
                        font,
                        toHaveTrait: .italicFontMask
                    )
                }
                attributed.addAttribute(
                    NSAttributedString.Key.font,
                    value: font,
                    range: range
                )
                if run.inlinePresentationIntent?.contains(
                    .strikethrough
                ) == true {
                    attributed.addAttribute(
                        NSAttributedString.Key.strikethroughStyle,
                        value: NSUnderlineStyle.single.rawValue,
                        range: range
                    )
                }
                if run.link != nil {
                    attributed.addAttributes([
                        NSAttributedString.Key.foregroundColor:
                            readerTheme.accentColor,
                        NSAttributedString.Key.underlineStyle:
                            NSUnderlineStyle.single.rawValue,
                    ], range: range)
                }
            }
            rendered.append(attributed)
            previousComponents = components
        }
        return rendered
    }

    private func displayPreviewText(
        _ attributed: NSAttributedString,
        kind: TextPreviewKind,
        accessibilityLabel: String
    ) {
        let styled = NSMutableAttributedString(attributedString: attributed)
        if styled.length > 0 {
            let fullRange = NSRange(location: 0, length: styled.length)
            styled.enumerateAttribute(.font, in: fullRange) { value, range, _ in
                guard value == nil else { return }
                styled.addAttribute(
                    .font,
                    value: NSFont.systemFont(ofSize: 14),
                    range: range
                )
            }
            styled.enumerateAttribute(.foregroundColor, in: fullRange) {
                value, range, _ in
                guard value == nil else { return }
                styled.addAttribute(
                    .foregroundColor,
                    value: readerTheme.foregroundColor,
                    range: range
                )
            }
        }
        let textView = kind == .plainText ? PlainTextPreviewView() : NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = readerTheme.backgroundColor
        textView.textContainerInset = NSSize(width: 24, height: 24)
        textView.textStorage?.setAttributedString(styled)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        textView.setAccessibilityLabel(accessibilityLabel)
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        var linkCount = 0
        if styled.length > 0 {
            styled.enumerateAttribute(
                .link,
                in: NSRange(location: 0, length: styled.length)
            ) { value, _, _ in
                if value != nil { linkCount += 1 }
            }
        }
        textPreviewKind = kind
        previewKind = kind == .plainText ? "Plain text" : "Markdown"
        previewRenderedText = textView.string
        previewLinkCount = linkCount
        previewAccessibilityLabel = accessibilityLabel
        installPreview(scrollView)
        view.layoutSubtreeIfNeeded()
        if kind == .plainText {
            configurePlainTextPreview(textView, in: scrollView)
            (textView as? PlainTextPreviewView)?.onWidthChange = { [weak self, weak textView, weak scrollView] width in
                guard let self, let textView, let scrollView else { return }
                self.configurePlainTextPreview(textView, in: scrollView, width: width)
            }
        }
    }

    private func configurePlainTextPreview(
        _ textView: NSTextView, in scrollView: NSScrollView, width: CGFloat? = nil
    ) {
        guard let container = textView.textContainer,
              let layout = textView.layoutManager else { return }
        let plainTextView = textView as? PlainTextPreviewView
        plainTextView?.isReflowing = true
        defer { plainTextView?.isReflowing = false }
        let selection = textView.selectedRanges
        let affinity = textView.selectionAffinity
        let oldOrigin = scrollView.contentView.bounds.origin
        let wasUnwrapped = textView.isHorizontallyResizable
        if wasUnwrapped { previewUnwrappedX = oldOrigin.x }

        // Keep a local UTF-16 character at the same vertical viewport offset.
        // This preview uses TextKit 1; source/fold projection state does not apply.
        layout.ensureLayout(for: container)
        let point = NSPoint(
            x: max(0, oldOrigin.x - textView.textContainerOrigin.x),
            y: max(0, oldOrigin.y - textView.textContainerOrigin.y)
        )
        let glyph = layout.glyphIndex(for: point, in: container)
        let character = glyph < layout.numberOfGlyphs
            ? layout.characterIndexForGlyph(at: glyph) : nil
        let anchorY = character.map { _ in
            layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
                + textView.textContainerOrigin.y
        }

        scrollView.hasHorizontalScroller = !previewWrapLines
        scrollView.tile()
        var viewport = scrollView.contentSize
        if let width { viewport.width = width }
        textView.isHorizontallyResizable = !previewWrapLines
        textView.autoresizingMask = previewWrapLines ? [.width] : []
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        container.widthTracksTextView = previewWrapLines
        textView.setFrameSize(NSSize(width: viewport.width, height: textView.frame.height))
        container.containerSize = NSSize(
            width: previewWrapLines
                ? max(1, viewport.width - 2 * textView.textContainerInset.width)
                : .greatestFiniteMagnitude,
            height: .greatestFiniteMagnitude
        )
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        textView.setFrameSize(NSSize(
            width: previewWrapLines ? viewport.width
                : max(viewport.width, ceil(used.maxX) + 2 * textView.textContainerInset.width),
            height: max(viewport.height, ceil(used.maxY) + 2 * textView.textContainerInset.height)
        ))
        textView.setSelectedRanges(selection, affinity: affinity, stillSelecting: false)
        var y = oldOrigin.y
        if let character, let anchorY {
            let newGlyph = layout.glyphIndexForCharacter(at: character)
            y += layout.lineFragmentRect(forGlyphAt: newGlyph, effectiveRange: nil).minY
                + textView.textContainerOrigin.y - anchorY
        }
        let restored = NSPoint(
            x: previewWrapLines ? 0 : min(previewUnwrappedX, max(0, textView.frame.width - viewport.width)),
            y: min(max(0, y), max(0, textView.frame.height - viewport.height))
        )
        scrollView.contentView.scroll(to: restored)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func displayPreviewHTML(_ html: String, file: URL) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.underPageBackgroundColor = readerTheme.backgroundColor
        webView.setAccessibilityLabel(localized("main.html.preview"))
        previewKind = "HTML"
        previewAccessibilityLabel = localized("main.html.preview")
        previewHTMLJavaScriptEnabled = configuration
            .defaultWebpagePreferences.allowsContentJavaScript
        previewHTMLDataStorePersistent = false
        previewHTMLContentSecurityPolicy = Self.previewContentSecurityPolicy
        previewHTMLSource = html
        previewHTMLBaseURL = file
        previewHTMLFinished = false
        previewHTMLLoadError = nil
        installPreview(webView)
        htmlInitialNavigationAllowed = true
        webView.loadHTMLString(
            htmlPreviewMarkup(html),
            baseURL: file
        )
    }

    private func htmlPreviewMarkup(_ html: String) -> String {
        let style = "<style>body { color: \(cssColor(readerTheme.foregroundColor)); "
            + "background-color: \(cssColor(readerTheme.backgroundColor)); "
            + "font-family: -apple-system, BlinkMacSystemFont, sans-serif; }</style>"
        let meta = "<meta http-equiv=\"Content-Security-Policy\" content=\""
            + Self.previewContentSecurityPolicy + "\">"
        guard let headStart = html.range(
            of: "<head",
            options: [.caseInsensitive]
        ), let headEnd = html[headStart.upperBound...].firstIndex(of: ">") else {
            return "<head>\(meta)\(style)</head>\(html)"
        }
        let insertion = html.index(after: headEnd)
        return String(html[..<insertion]) + meta + style + String(html[insertion...])
    }

    private func cssColor(_ color: NSColor) -> String {
        let resolved = color.usingColorSpace(.deviceRGB) ?? .black
        return String(
            format: "#%02x%02x%02x",
            Int(resolved.redComponent * 255),
            Int(resolved.greenComponent * 255),
            Int(resolved.blueComponent * 255)
        )
    }

    private func displayPreviewError(_ message: String) {
        let errorLabel = NSTextField(labelWithString: message)
        errorLabel.alignment = .center
        errorLabel.textColor = readerTheme.chromeSecondaryColor
        errorLabel.setAccessibilityLabel(localizedFormat("main.preview.failure", message))
        previewKind = "Error"
        previewRenderedText = message
        previewAccessibilityLabel = localizedFormat("main.preview.failure", message)
        installPreview(errorLabel)
    }

    var currentReadingSetScrollOffset: Double? {
        displayedReadingSetKey == nil ? nil : readingSetView.scrollOffset
    }

    func setReadingSetScrollOffsetForSelfTest(_ offset: Double) {
        readingSetView.restoreScrollOffset(offset)
    }

    var selfTestReadingSetState: (
        visible: Bool,
        title: String,
        subtitle: String,
        emptyVisible: Bool,
        cardCount: Int,
        cardFrames: [NSRect],
        cardAccessibility: [(String, String)],
        code: [(String, Bool, Bool)],
        codeGeometry: [(String, Bool, Bool)],
        actions: [[(String, Bool, Bool)]]
    ) {
        (
            !readingSetView.isHidden,
            readingSetView.selfTestTitle,
            readingSetView.selfTestSubtitle,
            readingSetView.selfTestEmptyVisible,
            readingSetView.selfTestCardCount,
            readingSetView.selfTestCardFrames,
            readingSetView.selfTestCardAccessibility,
            readingSetView.selfTestCodeState,
            readingSetView.selfTestCodeGeometry,
            readingSetView.selfTestActionState
        )
    }

    func restoreReadingSetScrollOffset(_ offset: Double?) {
        guard displayedReadingSetKey != nil else { return }
        readingSetView.restoreScrollOffset(offset)
    }

    func display(
        _ file: URL?,
        snapshotID: SnapshotID? = nil,
        source: DocumentLoader.ContentSource? = nil,
        languageMode: LanguageMode? = LanguageMode(language: .rust)
    ) {
        loadViewIfNeeded()
        guard file != displayedFile
                || snapshotID != displayedSnapshotID
                || languageMode != displayedLanguageMode
        else { return }
        displayedReadingSetKey = nil
        readingSetView.isHidden = true
        scrollView?.isHidden = false
        readingHeightControl.isHidden = false
        readingHeightControl.isEnabled = false
        readingHeightShortcutLabel.isHidden = true
        let rerunFind = !findBar.isHidden
        if rerunFind {
            invalidateFind()
            savedSymbolOccurrenceByteOffset = nil
            textView.setFindMatches([], selectedIndex: nil)
        }
        displayedFile = file
        updatePathControl()
        if !showsCompareControls {
            fileNameLabel.stringValue = file?.lastPathComponent ?? ""
        }
        displayedSnapshotID = snapshotID
        displayedLanguageMode = languageMode
        contextMenuOffset = nil
        readingPositionTask?.cancel()
        readingPositionTask = nil
        syntaxLoadPending = false
        pendingFocusNavigationOffset = nil
        loadGeneration &+= 1
        let generation = loadGeneration
        onOutlineChange?([])
        scopeHeaderByteOffset = nil
        hideScopeHeader()

        guard let file else {
            findBar.isHidden = true
            findStatusLabel.stringValue = ""
            displayedDocument = nil
            clearPreview()
            label.stringValue = localized("main.select.a.file.to.read.p.to.open")
            label.isHidden = false
            textView.clear()
            hideScopeHeader()
            // No file displayed: the source-only reading height controls
            // leave with it (§3.1 no-project surface).
            readingHeightControl.isHidden = true
            readingHeightShortcutLabel.isHidden = true
            return
        }

        guard let languageMode else {
            displayPreview(file, source: source)
            return
        }

        clearPreview()
        do {
            let activeLoader = source.map { DocumentLoader(source: $0) } ?? loader
            let loaded = try activeLoader.load(
                file: file,
                languageMode: languageMode
            )
            displayedDocument = loaded.document
            readingHeightControl.isEnabled = true
            onDocumentChange?(file, loaded.document)
            label.isHidden = true
            layoutTextViewFrame()
            textView.display(document: loaded.document, fileURL: file)
            renderScopeHeader(at: textView.byteOffset(
                forCharacterIndex: textView.view.selectedRange().location
            ))
            if rerunFind { scheduleFind(immediate: true) }
            onOutlineChange?(loaded.document.outlineFacets)
            textView.view.textLayoutManager?
                .textViewportLayoutController.layoutViewport()
            if loaded.tier != .regular {
                syntaxLoadPending = true
                activeLoader.loadSyntax(for: loaded.document) { [weak self] result in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.loadGeneration == generation,
                              self.displayedLanguageMode == languageMode
                        else { return }
                        self.syntaxLoadPending = false
                        switch result {
                        case let .success(document):
                            self.displayedDocument = document
                            self.onDocumentChange?(file, document)
                            let wasFocused = self.textView.isFocusMode
                            let focusOffset = self.pendingFocusNavigationOffset
                            self.pendingFocusNavigationOffset = nil
                            self.textView.updateSyntax(
                                document: document,
                                focusByteOffset: focusOffset
                            )
                            self.renderScopeHeader(at: self.textView.byteOffset(
                                forCharacterIndex:
                                    self.textView.view.selectedRange().location
                            ))
                            if wasFocused,
                               let focusOffset,
                               self.textView.isFocusMode
                            {
                                _ = self.textView.followFocusForExplicitNavigation(
                                    to: focusOffset
                                )
                            }
                            if wasFocused && !self.textView.isFocusMode {
                                self.onFocusNotice?(localized("main.focus.ended.no.enclosing.scope"))
                            }
                            self.onOutlineChange?(document.outlineFacets)
                        case .failure:
                            self.pendingFocusNavigationOffset = nil
                            if self.textView.isFocusMode {
                                _ = self.textView.exitFocusMode()
                                self.onFocusNotice?(localized("main.focus.ended.syntax.unavailable"))
                            }
                            self.label.stringValue = localized("main.syntax.highlighting.failed")
                            self.label.isHidden = false
                            self.hideScopeHeader()
                        }
                    }
                }
            }
        } catch {
            if rerunFind {
                textView.setFindMatches([], selectedIndex: nil)
                renderFindStatus()
            }
            displayedDocument = nil
            onDocumentChange?(file, nil)
            label.stringValue = localizedFormat("main.open.failure", file.lastPathComponent)
            label.isHidden = false
            textView.clear()
            hideScopeHeader()
        }
    }

    func navigate(
        to file: URL,
        byteOffset: UInt32,
        snapshotID: SnapshotID? = nil,
        source: DocumentLoader.ContentSource? = nil,
        languageMode: LanguageMode? = LanguageMode(language: .rust)
    ) {
        display(
            file,
            snapshotID: snapshotID,
            source: source,
            languageMode: languageMode
        )
        if textView.isFocusMode {
            if syntaxLoadPending {
                pendingFocusNavigationOffset = byteOffset
            } else if !textView.followFocusForExplicitNavigation(to: byteOffset) {
                onFocusNotice?(localized("main.focus.ended.no.enclosing.scope"))
            }
        }
        textView.reveal(byteOffset: byteOffset)
        _ = textView.activate(atByteOffset: byteOffset)
        onSelectionChange?(byteOffset)
        onReadingPositionChange?(byteOffset)
    }

    func restoreReadingPosition(
        scrollByteOffset: UInt32?,
        selectionByteOffset: UInt32?
    ) {
        let generation = loadGeneration
        let languageMode = displayedLanguageMode
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  loadGeneration == generation,
                  displayedLanguageMode == languageMode
            else { return }
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
        guard displayedFile != nil,
              let document = displayedDocument
        else { return nil }
        let byteOffset = min(
            textView.firstVisibleByteOffset() ?? fallbackByteOffset ?? 0,
            UInt32(clamping: document.bytes.count)
        )
        return readingPosition(at: byteOffset)
    }

    func readingPosition(at byteOffset: UInt32?) -> (
        file: URL,
        contentID: ContentID,
        byteOffset: UInt32,
        line: UInt32,
        column: UInt32,
        symbolAnchor: String?
    )? {
        guard let byteOffset,
              let file = displayedFile,
              let document = displayedDocument,
              document.byteUTF16Map.utf16Offset(forByte: Int(byteOffset)) != nil
        else { return nil }
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
            if let anchor = textView.followAnchorByteOffset() {
                onOutlineFollowPositionChange?(anchor)
            }
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

    @objc private func copyPathLine(_ sender: Any?) {
        guard let location = contextMenuLocation() else { return }
        onCopyPathLine?(location.file, location.line)
    }

    @objc private func revealInFinder(_ sender: Any?) {
        guard let location = contextMenuLocation(),
              FileManager.default.fileExists(atPath: location.file.path)
        else { return }
        onRevealInFinder?(location.file)
    }

    private func contextMenuLocation() -> (file: URL, line: UInt32)? {
        guard let contextMenuOffset,
              let file = displayedFile,
              let document = displayedDocument,
              let line = document.lineTable.lineColumn(
                  at: contextMenuOffset
              )?.line
        else { return nil }
        return (file, line)
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
        labels: [localized("main.follow"), localized("main.pin")],
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
            localized("main.click.a.symbol.to.see.its.definition.here.click.jumps.to.it")
    )
    private let scrollView = NSScrollView()
    private let miniReader = ReaderTextView()
    private let container = NSView()
    private let headerSurface = NSView()
    private var theme = ReaderTheme(settings: ReaderSettings())

    init(model: ContextWindowModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(settings: ReaderSettings) {
        theme = ReaderTheme(settings: settings)
        miniReader.apply(settings: settings)
        if isViewLoaded {
            container.layer?.backgroundColor = theme.chromeColor.cgColor
            headerSurface.layer?.backgroundColor = theme.chromeHeaderColor.cgColor
            view.needsDisplay = true
        }
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

    var selfTestProvenanceTooltip: String? {
        loadViewIfNeeded()
        return candidateLabel.toolTip
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
        candidateLabel.font = .systemFont(ofSize: 12, weight: .medium)
        candidateLabel.lineBreakMode = .byTruncatingTail
        candidateLabel.cell?.truncatesLastVisibleLine = true
        candidateLabel.cell?.wraps = false
        // Long provenance must truncate, not demand pane width.
        candidateLabel.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        candidateLabel.setContentHuggingPriority(
            .defaultLow,
            for: .horizontal
        )
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
        headerSurface.wantsLayer = true
        headerSurface.layer?.backgroundColor = theme.chromeHeaderColor.cgColor
        headerSurface.translatesAutoresizingMaskIntoConstraints = false
        headerSurface.addSubview(header)

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

        container.wantsLayer = true
        container.layer?.backgroundColor = theme.chromeColor.cgColor
        container.addSubview(headerSurface)
        container.addSubview(scrollView)
        container.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            headerSurface.topAnchor.constraint(equalTo: container.topAnchor),
            headerSurface.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            headerSurface.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            headerSurface.heightAnchor.constraint(equalToConstant: 30),
            header.leadingAnchor.constraint(equalTo: headerSurface.leadingAnchor, constant: 8),
            header.trailingAnchor.constraint(equalTo: headerSurface.trailingAnchor, constant: -8),
            header.centerYAnchor.constraint(equalTo: headerSurface.centerYAnchor),
            scrollView.topAnchor.constraint(equalTo: headerSurface.bottomAnchor),
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
            let fullProvenance = [
                candidate.provenanceBadge,
                candidate.bindingKind,
            ]
                .compactMap { $0 }
                .joined(separator: " · ")
            // §3.2: the header keeps a short status; the full provider, tool
            // version, trust, limitations, commit, and features move to the
            // tooltip and accessibility value instead of widening the pane.
            candidateLabel.stringValue = Self.shortProvenanceLabel(
                candidate.provenanceBadge, bindingKind: candidate.bindingKind
            )
            candidateLabel.toolTip = fullProvenance
            candidateLabel.setAccessibilityLabel(fullProvenance)
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
            candidateLabel.toolTip = nil
            candidateLabel.setAccessibilityLabel(nil)
            countLabel.stringValue = ""
            text = ""
            highlightsSyntax = false
            candidateBadge.isHidden = true
            scrollView.isHidden = true
            placeholderLabel.isHidden = false
        }
        previousButton.isEnabled = model.candidateCount > 1
        nextButton.isEnabled = model.candidateCount > 1
        guard let document = readerDocument(
            text,
            languageMode: model.selectedLanguageMode,
            highlightsSyntax: highlightsSyntax
        ) else {
            miniReader.clear()
            return
        }
        miniReader.display(document: document)
    }

    /// Short header label for a full provenance badge: keeps the certainty
    /// status (Exact/Strong/Possible/…) and the binding kind; provider, tool
    /// version, trust, limitations, commit, and features move to the
    /// tooltip. Unresolved and other states keep their distinguishing word.
    static func shortProvenanceLabel(_ full: String, bindingKind: String?) -> String {
        let parts = full.components(separatedBy: " · ")
        guard let status = parts.first, !status.isEmpty else {
            return String(full.prefix(40))
        }
        if let bindingKind {
            return "\(status) · \(bindingKind)"
        }
        return status
    }

    private func applyBadgeStyle() {
        let colors: (background: NSColor, foreground: NSColor) =
            switch provenanceBadgeStyle(for: model.selectedCandidate?.certainty) {
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
        languageMode: LanguageMode?,
        highlightsSyntax: Bool
    ) -> ReaderDocument? {
        let bytes = Array(source.utf8)
        guard let languageMode else { return nil }
        let plain = ReaderDocument(
            bytes: bytes,
            languageMode: languageMode
        )
        guard highlightsSyntax else { return plain }
        return try? DocumentLoader().loadSyntax(for: plain)
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
