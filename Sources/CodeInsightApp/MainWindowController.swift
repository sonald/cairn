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

/// The app-wide key binding table (K-R3.7). Every surface — menus, toolbar
/// menu representations, reader gestures, the key monitor — reads this one
/// table; the default scheme stands in when no delegate is installed (tests).
/// Main-actor only, like the UI that consumes it.
@MainActor
func appKeyBindingTable() -> KeyBindingTable {
    (NSApp.delegate as? AppDelegate)?.keyBindingTable ?? KeyBindingTable(scheme: .default)
}

extension KeyBindingTable {
    /// Flags of the `reader.gesture.symbolDoc` click gesture (⌥ by default).
    var symbolDocClickFlags: NSEvent.ModifierFlags {
        if case let .click(modifiers)? = bindings(for: .readerGestureSymbolDoc).first {
            return modifiers.eventFlags
        }
        return [.option]
    }

    /// Flags of the `reader.gesture.definition` click gesture (⌘ by default).
    var definitionClickFlags: NSEvent.ModifierFlags {
        if case let .click(modifiers)? = bindings(for: .readerGestureDefinition).first {
            return modifiers.eventFlags
        }
        return [.command]
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
    private let readerController: ReaderViewController
    private let secondaryReaderController: ReaderViewController
    private let contextController: ContextWindowViewController
    private let relationController: RelationWindowController
    /// D5: sidebar | work area; the Lens spans only the reader and Relations.
    private let outerSplitController = NSSplitViewController()
    private let contentSplitController = NSSplitViewController()
    private let upperSplitController = NSSplitViewController()
    private let readerSplitController = NSSplitViewController()
    private let sidebarItem: NSSplitViewItem
    private let readerGroupItem: NSSplitViewItem
    private let secondaryReaderItem: NSSplitViewItem
    private let queryDockController = NSViewController()
    private let queryDockTabs = NSStackView()
    private let queryDockBody = NSView()
    private var selectedBottomTab = "context"
    private let contextItem: NSSplitViewItem
    private let relationItem: NSSplitViewItem
    private let projectLabel = NSTextField(labelWithString: "Cairn")
    private let commitButton = NSButton()
    private let symbolsButton = NSButton()
    private let settingsButton = NSButton()
    private let profileButton = NSButton()
    private let indexLabel = NSTextField(labelWithString: "")
    private let identifierStatusLabel = NSTextField(labelWithString: "")
    private let refreshIndexButton = NSButton()
    private let exactLabel = NSTextField(labelWithString: localized("main.exact.off.safe"))
    private let exactInfoButton = NSButton()
    private let exactStatusPopover = NSPopover()
    private let contextButton = NSButton(title: localized("main.context"), target: nil, action: nil)
    private let trailView = ReadingTrailView()
    private let statusBar = NSView()
    private let statusSeparator = NSView()
    /// The highest certainty Exact can currently deliver, as stones.
    private let exactStones = CertaintyStonesView(
        certainty: .possible, theme: ReaderTheme(settings: ReaderSettings()), size: 13
    )
    private let truncatedLabel = NSTextField(labelWithString: localized("main.results.truncated"))
    private let highlightChips = HighlightChipsView()
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
    private var pendingRefreshContentID: ContentID?
    private var searchDockHasBeenShown = false
    private var sessionRestoreTask: Task<Void, Never>?
    private var outlineFollowArbitration = OutlineFollowArbitration()
    private var currentReaderSettings = ReaderSettings()
    private let symbolDocCard = SymbolDocCard()
    /// Screen rects of recently hovered tokens, so the card anchors to the
    /// token it shows even after the pointer moved on.
    private var symbolHoverAnchors: [SymbolHoverModel.Token: NSRect] = [:]
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
        derivedDataStore: ReaderDerivedDataStore = ReaderDerivedDataStore(),
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
        readerController = ReaderViewController(derivedDataStore: derivedDataStore)
        secondaryReaderController = ReaderViewController(showsCompareControls: true, derivedDataStore: derivedDataStore)
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
        contextController = ContextWindowViewController(model: model.contextWindow, derivedDataStore: derivedDataStore)
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
        queryDockController.view = NSView()
        contextItem = NSSplitViewItem(viewController: queryDockController)

        outerSplitController.splitView.isVertical = true
        outerSplitController.splitView.dividerStyle = .thin
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
        upperSplitController.addSplitViewItem(readerGroupItem)
        upperSplitController.addSplitViewItem(relationItem)
        relationItem.isCollapsed = true

        let upperItem = NSSplitViewItem(viewController: upperSplitController)
        upperItem.minimumThickness = 300
        contextItem.minimumThickness = 120
        contextItem.canCollapse = true
        contentSplitController.addSplitViewItem(upperItem)
        contentSplitController.addSplitViewItem(contextItem)
        let workItem = NSSplitViewItem(viewController: contentSplitController)
        workItem.minimumThickness = 300
        workItem.canCollapse = false
        outerSplitController.addSplitViewItem(sidebarItem)
        outerSplitController.addSplitViewItem(workItem)

        let contentView = NSView()
        let contentViewController = NSViewController()
        contentViewController.view = contentView
        contentViewController.addChild(outerSplitController)
        outerSplitController.view.translatesAutoresizingMaskIntoConstraints = false

        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.isHidden = true
        let separator = statusSeparator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.separatorColor.cgColor

        identifierStatusLabel.font = .systemFont(ofSize: 12)
        identifierStatusLabel.textColor = .secondaryLabelColor
        identifierStatusLabel.isHidden = true
        identifierStatusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
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
        statusStack.setViews(
            [contextButton, highlightChips, indexLabel, identifierStatusLabel, refreshIndexButton],
            in: .leading
        )
        statusStack.setViews([truncatedLabel], in: .center)
        statusStack.setViews([exactStones, exactLabel, exactInfoButton], in: .trailing)
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        statusStack.orientation = .horizontal
        statusStack.alignment = .centerY
        statusStack.spacing = 12
        let contentStack = NSStackView(
            views: [trailView, outerSplitController.view, statusBar]
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
            outerSplitController.view.widthAnchor.constraint(
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
        configureQueryDock()
        exactInfoButton.target = self
        contextButton.target = self
        window.delegate = self
        refreshIndexButton.target = self
        refreshIndexButton.action = #selector(refreshProjectIndex(_:))
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self, weak window] event in
            guard event.keyCode == 53, let self else { return event }
            // The card closes first, whichever view holds focus, including
            // the card itself after a click inside it.
            if event.window === window || self.symbolDocCard.contains(event.window),
               self.escapeSymbolDocumentation()
            {
                return nil
            }
            guard event.window === window else { return event }
            if self.searchPanel?.hasSearchFocus == true { return event }
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
            guard let self else { return }
            if focusedPane == .reference, let pane = model.referencePane, isReferenceActive {
                revealInReference(pane.file, byteOffset: offset)
                return
            }
            guard let file = model.selectedFile else { return }
            navigate(to: file, byteOffset: offset, cause: .outline)
        }
        sidebarController.onOpenFileToSide = { [weak self] url in self?.openReference(url) }
        readerController.onOpenToSide = { [weak self] url in self?.openReference(url) }
        readerController.onOpenScope = sidebarController.onOpenOutline
        sidebarController.onEditExclusionRules = { [weak self] in self?.showExclusionRules() }
        readerController.onRevealPath = { [weak self] url in
            guard let self else { return }
            sidebarItem.isCollapsed = false
            sidebarController.revealPath(url)
        }
        for reader in [readerController, secondaryReaderController] {
            reader.onTokenClick = { [weak self, weak reader] offset, commandClick in
                guard let self, let reader else { return }
                handleReaderClick(offset: offset, commandClick: commandClick, from: reader)
            }
            reader.onTypeDefinitionClick = { [weak self, weak reader] offset in
                guard let self, let reader else { return }
                handleReaderTypeDefinition(offset: offset, from: reader)
            }
            reader.onShowRelation = { [weak self, weak reader] offset, direction in
                guard let self, let reader else { return }
                handleReaderRelation(offset: offset, direction: direction, from: reader)
            }
        }
        secondaryReaderController.onOutlineChange = { [weak self] facets in
            guard let self else { return }
            referenceOutline = facets
            if focusedPane == .reference { renderOutlineForFocus() }
        }
        secondaryReaderController.onSelectionChange = { [weak self] offset in
            guard let self, isReferenceActive, model.referencePane != nil else { return }
            // Programmatic reveals report selections too; focus follows only
            // user clicks and caret moves (onTokenClick, onCaretFollow).
            model.referencePane?.byteOffset = offset
            sidebarController.highlightOutline(at: offset)
            model.scheduleSessionCheckpoint(panelPreset: panelPreset)
        }
        for reader in [readerController, secondaryReaderController] {
            reader.onCaretFollow = { [weak self, weak reader] offset in
                guard let self, let reader else { return }
                noteFocus(reader === secondaryReaderController && isReferenceActive ? .reference : .primary)
                handleReaderCaret(offset: offset, from: reader)
            }
        }
        for reader in [readerController, secondaryReaderController] {
            reader.onHover = { [weak self] request in self?.handleHover(request) }
            reader.onHoverRequest = { [weak self] request in
                self?.showSymbolDocumentation(for: request)
            }
            reader.onHoverDismiss = { [weak self] in self?.model.symbolHover.dismiss() }
            reader.onHoverEscape = { [weak self] in self?.escapeSymbolDocumentation() ?? false }
            reader.onOpenInDash = { [weak self] identifier, offset, document in
                guard let self else { return }
                DashIntegration.open(query: dashQuery(identifier: identifier, in: document, byteOffset: offset))
            }
        }
        symbolDocCard.onPointerEntered = { [weak self] in
            self?.model.symbolHover.pointerEnteredCard()
        }
        symbolDocCard.onPointerExited = { [weak self] in
            self?.model.symbolHover.pointerExitedCard()
        }
        symbolDocCard.onEscape = { [weak self] in self?.model.symbolHover.dismiss() }
        secondaryReaderController.onDocumentChange = { [weak self] _, _ in
            self?.model.symbolHover.dismiss()
        }
        symbolDocCard.onOpenLink = { [weak self] url in self?.openSymbolDocLink(url) }
        readerController.onOutlineChange = { [weak self] facets in
            guard let self else { return }
            primaryOutline = facets
            guard focusedPane == .primary else { return }
            sidebarController.setOutline(facets.map(OutlineNode.init(facet:)), file: model.selectedFile)
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
        readerController.onIdentifierPreparationChanged = { [weak self] in
            self?.renderIdentifierStatus()
            self?.renderHighlightChips()
        }
        secondaryReaderController.onIdentifierPreparationChanged = { [weak self] in
            self?.renderIdentifierStatus()
            self?.renderHighlightChips()
        }
        for reader in [readerController, secondaryReaderController] {
            reader.onToggleHighlightName = { [weak self] name in self?.toggleHighlight(name: name) }
            reader.onAssignHighlightColor = { [weak self] name, slot in
                self?.model.highlightedNames.assign(name, slot: slot)
                self?.highlightsDidChange()
            }
        }
        highlightChips.onReveal = { [weak self] name, backwards in
            guard let self, !focusedReader.revealOccurrence(ofName: name, backwards: backwards) else { return }
            showTransientStatus(localizedFormat("main.highlight.notInFile", name))
        }
        highlightChips.onRemove = { [weak self] name in
            self?.model.highlightedNames.remove(name)
            self?.highlightsDidChange()
        }
        highlightChips.onClearAll = { [weak self] in self?.clearHighlights() }
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
            model.symbolHover.dismiss()
            model.tabStrip.setActiveDocument(document, for: file)
            captureActiveTabState()
            model.scheduleSessionCheckpoint(panelPreset: panelPreset)
            refreshProjectSearchHits()
        }
        readerController.onOpenPreviewLink = { [weak self] url in
            self?.openPreviewLink(url)
        }
        readerController.onReadingSetScrollChange = { [weak self] offset in
            guard let self else { return }
            model.tabStrip.updateActiveReadingSetScroll(offset)
            model.scheduleSessionCheckpoint(panelPreset: panelPreset)
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
            guard let self else { return }
            if secondaryReaderController.isReferenceMode { closeReference() } else { closeComparison() }
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
        contextController.onTrackingChange = { [weak self] in
            self?.replayCaretForLensTracking()
        }
        contextController.onOpenEnclosing = { [weak self] path, byteOffset in
            self?.open(path: path, byteOffset: byteOffset)
        }
        contextController.onEnclosingSlice = { [weak self] scope in
            self?.enclosingSlice(for: scope)
        }
        contextController.onOpen = { [weak self] candidate in
            guard let self else { return }
            // Q5.4: with the reference pane focused, Context opens there.
            if focusedPane == .reference, isReferenceActive, let root = model.fileTree?.root,
               !exactLocationIsInDependency(candidate.path) {
                openReference(root.appendingPathComponent(candidate.path), byteOffset: candidate.targetByteOffset)
                return
            }
            open(candidate)
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
        observeSymbolHover()
    }

    deinit {
        sessionRestoreTask?.cancel()
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Project opening and session restore

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
        // R6.3: restore the lens tracking; the pin always starts released.
        if let tracking = ContextWindowModel.Tracking(rawValue: snapshot.contextTracking ?? "") {
            model.contextWindow.setTracking(tracking)
        }
        model.highlightedNames = HighlightedNames(restoring: snapshot.highlights)
        renderHighlights()
        model.referencePane = snapshot.referencePane.map {
            ReferencePaneState(file: root.appendingPathComponent($0.path), byteOffset: $0.byteOffset)
        }
        referenceBack = []
        referenceForward = []
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
        if let bookmarkPanel, bookmarkPanel.window === candidate { return true }
        if let palettePanel, palettePanel.window === candidate { return true }
        if candidate.sheetParent === window { return true }
        return false
    }

    /// Resolves another window's panels the same way menu routing does;
    /// exposed for tests.
    func panelKind(of candidate: NSWindow?) -> String? {
        guard let candidate, candidate !== window else { return nil }
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
        renderHighlights()
        render()
    }

    func refreshRecentProjects() {
        renderEmptyState()
    }

    // MARK: - Commit selection and self-test hooks

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
            commitPickerPopover?.apply(settings: currentReaderSettings)
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
    func selfTestScrollReader(toByteOffset offset: UInt32) {
        readerController.restoreReadingPosition(scrollByteOffset: offset, selectionByteOffset: nil)
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
    func selfTestWaitForIdentifierPreparation() async {
        await readerController.selfTestWaitForIdentifierPreparation()
    }
    var selfTestIdentifierPreparationState: ReaderIdentifierState {
        readerController.selfTestIdentifierPreparationState
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
    var selfTestContextEnclosingTitle: String? { contextController.selfTestEnclosingTitle }
    var selfTestRenderedTypeHop: (via: String, target: String, viaWidth: CGFloat, targetWidth: CGFloat)? {
        contextController.selfTestRenderedTypeHop
    }
    var selfTestTypeHop: (via: String, target: String?, showing: String)? {
        contextController.selfTestTypeHop
    }
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
        return outerSplitController.view.convert(
            outerSplitController.view.bounds,
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
        let contentFrame = outerSplitController.view.convert(
            outerSplitController.view.bounds,
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
    var selfTestCommitButtonBezel: NSColor? { commitButton.bezelColor }
    var selfTestReaderHistorical: (flag: Bool, background: NSColor?) {
        readerController.selfTestHistoricalSnapshot
    }
    var selfTestSnapshotBadge: (text: String, style: CairnBadgeView.Style, visible: Bool) {
        readerController.selfTestSnapshotBadge
    }
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

    /// Feeds a user caret move from the primary reader, as `onCaretFollow` does.
    func selfTestFollowCaret(offset: UInt32) {
        handleReaderCaret(offset: offset, from: readerController)
    }

    /// Switches the lens tracking through its segmented control.
    func selfTestChooseLensTracking(_ tracking: ContextWindowModel.Tracking) {
        contextController.selfTestChooseTracking(tracking)
    }

    func selfTestReaderClick(offset: UInt32, commandClick: Bool) {
        handleReaderClick(offset: offset, commandClick: commandClick, from: readerController)
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

    // MARK: - Seek palette, query dock and project search

    /// D1: ⌘T and ⌘P share one Seek palette; ⌘T only starts in project symbols.
    func showSymbolSearch() {
        showPalette(prefill: "#")
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

    private func configureQueryDock() {
        queryDockController.addChild(contextController)
        let panel = SearchPanel(appModel: model, onOpen: { [weak self] file, range, contentID, focusReader in
            guard let self else { return }
            if self.model.selectedFile?.standardizedFileURL != file.standardizedFileURL || self.model.selectedByteOffset != range.lowerBound {
                self.navigate(to: file, byteOffset: range.lowerBound, cause: .search, expectedContentID: contentID)
            }
            self.readerController.revealProjectSearchMatch(range, expectedContentID: contentID)
            self.refreshProjectSearchHits()
            if focusReader { self.readerController.focusText() }
        }, onReturnToReader: { [weak self] in self?.readerController.focusText() })
        panel.onResultsChanged = { [weak self] in self?.refreshProjectSearchHits() }
        searchPanel = panel
        queryDockController.addChild(panel)
        for (title, tag) in [(localized("main.context"), 0), (localized("panel.query.results"), 1), ("×", 2)] {
            let button = NSButton(title: title, target: self, action: #selector(selectBottomTab(_:)))
            button.tag = tag
            button.isBordered = false
            button.font = .systemFont(ofSize: 11.5)
            let titleWidth = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .semibold)]).width
            button.widthAnchor.constraint(equalToConstant: tag == 2 ? 32 : ceil(titleWidth) + 24).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
            if tag == 2 {
                let spacer = NSView()
                spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
                queryDockTabs.addArrangedSubview(spacer)
                button.setAccessibilityLabel(localized("panel.query.close"))
            }
            queryDockTabs.addArrangedSubview(button)
        }
        queryDockTabs.spacing = 0
        queryDockTabs.heightAnchor.constraint(equalToConstant: 28).isActive = true
        queryDockTabs.wantsLayer = true
        let stack = NSStackView(views: [queryDockTabs, queryDockBody])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        queryDockController.view.addSubview(stack)
        for controller in [contextController as NSViewController, panel] {
            let child = controller.view
            child.translatesAutoresizingMaskIntoConstraints = false
            queryDockBody.addSubview(child)
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: queryDockBody.leadingAnchor), child.trailingAnchor.constraint(equalTo: queryDockBody.trailingAnchor),
                child.topAnchor.constraint(equalTo: queryDockBody.topAnchor), child.bottomAnchor.constraint(equalTo: queryDockBody.bottomAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: queryDockController.view.leadingAnchor), stack.trailingAnchor.constraint(equalTo: queryDockController.view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: queryDockController.view.topAnchor), stack.bottomAnchor.constraint(equalTo: queryDockController.view.bottomAnchor),
            queryDockTabs.widthAnchor.constraint(equalTo: stack.widthAnchor), queryDockBody.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        model.projectSearch.onStateChanged = { [weak self] in
            guard let self else { return }
            self.model.scheduleSessionCheckpoint(panelPreset: self.panelPreset)
        }
        renderBottomTab()
    }

    @objc private func selectBottomTab(_ sender: NSButton) {
        if sender.tag == 2 {
            if selectedBottomTab == "search" { model.projectSearch.commitQuery() }
            contextVisibilityOverride = false
            contextItem.isCollapsed = true
            searchPanel?.dismissHints()
            refreshProjectSearchHits()
            readerController.focusText()
        } else {
            selectedBottomTab = sender.tag == 1 ? "search" : "context"
            renderBottomTab()
        }
        savePanelLayout()
    }
    private func renderBottomTab() {
        let firstSearchPresentation = selectedBottomTab == "search" && !searchDockHasBeenShown
        if selectedBottomTab == "search" { searchDockHasBeenShown = true }
        contextItem.minimumThickness = selectedBottomTab == "search" ? 240 : 120
        contextController.view.isHidden = selectedBottomTab == "search"
        searchPanel?.view.isHidden = selectedBottomTab != "search"
        let theme = ReaderTheme(settings: currentReaderSettings)
        queryDockTabs.layer?.backgroundColor = theme.chromeHeaderColor.cgColor
        for case let button as NSButton in queryDockTabs.arrangedSubviews {
            let selected = button.tag == (selectedBottomTab == "search" ? 1 : 0)
            button.font = .systemFont(ofSize: 11.5, weight: selected ? .semibold : .regular)
            button.contentTintColor = selected ? theme.foregroundColor : theme.chromeSecondaryColor
            button.wantsLayer = true
            button.layer?.backgroundColor = (selected ? theme.backgroundColor : theme.chromeHeaderColor).cgColor
        }
        if selectedBottomTab != "search" { searchPanel?.dismissHints() }
        if firstSearchPresentation, !contextItem.isCollapsed {
            window?.contentView?.layoutSubtreeIfNeeded()
            let split = contentSplitController.splitView
            let height = min(360, split.bounds.height * 0.45)
            split.setPosition(split.bounds.height - height - split.dividerThickness, ofDividerAt: 0)
        }
        refreshProjectSearchHits()
    }
    /// Underlines the visible search results in the main reader while the
    /// results tab is showing; hiding results clears the underlines.
    private func refreshProjectSearchHits() {
        let showing = selectedBottomTab == "search" && !contextItem.isCollapsed
        let contentID = readerController.displayedContentID
        readerController.setQueryHits(
            showing ? searchPanel?.queryHits(forContent: contentID) ?? [] : [],
            contentID: contentID
        )
    }
    func showProjectSearch() {
        let selection = focusedReader.hasFocusedText ? focusedReader.selectedSourceText : nil
        selectedBottomTab = "search"
        contextVisibilityOverride = true
        contextItem.isCollapsed = false
        renderBottomTab()
        searchPanel?.focusInput(selection: selection)
        savePanelLayout()
    }
    func nextProjectSearchResult() { searchPanel?.moveResult(by: 1) }
    func previousProjectSearchResult() { searchPanel?.moveResult(by: -1) }
    func toggleProjectSearchResults() {
        if selectedBottomTab == "search", !contextItem.isCollapsed {
            model.projectSearch.commitQuery()
            contextVisibilityOverride = false
            contextItem.isCollapsed = true
            searchPanel?.dismissHints()
            refreshProjectSearchHits()
        } else { showProjectSearch() }
        savePanelLayout()
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

    // MARK: - Tab commands

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

    // MARK: - Panels

    var canCloseComparison: Bool {
        model.compare.rightRevision != nil || (!secondaryReaderItem.isCollapsed && !isReferenceActive)
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
        // Anything the lens can show counts: a candidate, a type hop still
        // waiting for Exact (no targets yet), the enclosing scope — and the
        // enclosing mode itself, which the user chose from the pane.
        let lens = model.contextWindow
        let hasContext = lens.candidateCount > 0
            || lens.displayedCandidate != nil
            || lens.activeTypeHop != nil
            || lens.activeEnclosingScope != nil
            || lens.tracking == .enclosing
            || lens.isPinned
        let visible = contextVisibilityOverride ?? (panelPreset != .focus && (selectedBottomTab == "search" || hasContext))
        contextItem.isCollapsed = !visible
        contextButton.setAccessibilityLabel(visible ? localized("main.hide.definition.context") : localized("main.show.definition.context"))
        let theme = ReaderTheme(settings: currentReaderSettings)
        contextButton.contentTintColor = visible ? theme.accentColor : theme.chromeSecondaryColor
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
        if model.referencePane != nil { renderSecondaryReader() }
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
        let outerSplit = outerSplitController.splitView
        let upperSplit = upperSplitController.splitView
        outerSplit.layoutSubtreeIfNeeded()
        let available = min(
            outerSplit.bounds.width,
            window?.contentLayoutRect.width ?? outerSplit.bounds.width
        )
        let sidebarWidth = sidebarItem.isCollapsed
            ? 0
            : (outerSplit.arrangedSubviews.first?.frame.width ?? 0)
        if !sidebarItem.isCollapsed,
           available - sidebarWidth - relationItem.minimumThickness < 480
        {
            sidebarItem.isCollapsed = true
            sidebarTemporarilyCollapsedForRelations = true
        }
        outerSplit.layoutSubtreeIfNeeded()
        let fittedSidebar = sidebarItem.isCollapsed
            ? 0
            : (outerSplit.arrangedSubviews.first?.frame.width ?? 0)
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
        outerSplit.layoutSubtreeIfNeeded()
        upperSplit.layoutSubtreeIfNeeded()
        let preferredWidth = (restoredPanelLayout()?.relationsFraction ?? 0) * available
        upperSplit.setPosition(
            upperSplit.bounds.width - min(target, max(300, preferredWidth > 0 ? preferredWidth : 360)),
            ofDividerAt: 0
        )
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
        let outerSplit = outerSplitController.splitView
        let upperSplit = upperSplitController.splitView
        if relationsOpen {
            outerSplit.layoutSubtreeIfNeeded()
            let available = min(
                outerSplit.bounds.width,
                window?.contentLayoutRect.width ?? outerSplit.bounds.width
            )
            let sidebarWidth = sidebarItem.isCollapsed
                ? 0
                : (outerSplit.arrangedSubviews.first?.frame.width ?? 0)
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
                : (outerSplit.arrangedSubviews.first?.frame.width ?? 0)
            capRelationsPane(width: available - sidebarWidthNow - 480 - upperSplit.dividerThickness)
        } else {
            capRelationsPane(width: nil)
            if sidebarTemporarilyCollapsedForRelations {
                sidebarTemporarilyCollapsedForRelations = false
                sidebarItem.isCollapsed = false
            }
        }
    }

    // MARK: - Window lifecycle and close

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
        model.projectSearch.commitQuery()
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
        model.symbolHover.dismiss()
        symbolDocCard.hide()
        readerController.cancelDerivedDataSubscription()
        secondaryReaderController.cancelDerivedDataSubscription()
        contextController.cancelDerivedDataSubscription()
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
        searchPanel?.dismissHints()
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

    // MARK: - Panel layout

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
        let outerSplit = outerSplitController.splitView
        let upperSplit = upperSplitController.splitView
        let contentSplit = contentSplitController.splitView
        let readerSplit = readerSplitController.splitView
        // Fractions stay relative to the whole width, as before D5.
        let sidebarFraction: Double
        if !sidebarItem.isCollapsed,
           outerSplit.bounds.width > 0,
           let sidebar = outerSplit.arrangedSubviews.first
        {
            sidebarFraction = sidebar.frame.width / outerSplit.bounds.width
        } else {
            sidebarFraction = base.sidebarFraction
        }
        let relationsFraction: Double
        if !relationItem.isCollapsed,
           outerSplit.bounds.width > 0,
           let relations = upperSplit.arrangedSubviews.last
        {
            relationsFraction = relations.frame.width / outerSplit.bounds.width
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
            readerSplit: !secondaryReaderItem.isCollapsed && !isReferenceActive,
            sidebarFraction: sidebarFraction,
            contextFraction: contextFraction,
            relationsFraction: relationsFraction,
            secondaryReaderFraction: secondaryFraction,
            bottomTab: selectedBottomTab
        )
    }

    private func applyPanelLayout(_ layout: PanelLayoutDescription) {
        selectedBottomTab = layout.bottomTab == "search" ? "search" : "context"
        if selectedBottomTab == "search" { contextVisibilityOverride = !layout.contextCollapsed }
        renderBottomTab()
        sidebarItem.isCollapsed = layout.sidebarCollapsed
        readerGroupItem.isCollapsed = layout.readerCollapsed
        contextItem.isCollapsed = layout.contextCollapsed
        relationItem.isCollapsed = layout.relationsCollapsed
        secondaryReaderItem.isCollapsed = !layout.readerSplit && !isReferenceActive

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

    // MARK: - Reader commands

    func applyReaderSettings(_ settings: ReaderSettings) {
        currentReaderSettings = settings
        model.symbolHover.isHoverEnabled = settings.hoverDocs
        if symbolDocCard.isShown { renderSymbolHover() }
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
        applyStatusTheme(theme)
        renderHighlightChips(theme: theme)
        renderCommitButton()
        renderTrustSeal()
        readerController.apply(settings: settings)
        secondaryReaderController.apply(settings: settings)
        sidebarController.apply(settings: settings)
        relationController.apply(settings: settings)
        contextController.apply(settings: settings)
        trailView.apply(settings: settings)
        palettePanel?.apply(settings: settings)
        searchPanel?.apply(settings: settings)
        renderBottomTab()
        bookmarkPanel?.apply(settings: settings)
        commitPickerPopover?.apply(settings: settings)
        compareCommitPickerPopover?.apply(settings: settings)
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
            bookmarkPanel?.apply(settings: currentReaderSettings)
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
        let sidebar = outerSplitController.splitView.arrangedSubviews.first
        let reader = upperSplitController.splitView.arrangedSubviews.first
        guard let sidebar, let reader else { return (0, 0) }
        return (sidebar.frame.width, reader.frame.width)
    }

    var selfTestContentView: NSView? { window?.contentView }

    private func applyPanelSizes(_ layout: PanelLayoutDescription) {
        window?.contentView?.layoutSubtreeIfNeeded()
        let outerSplit = outerSplitController.splitView
        let upperSplit = upperSplitController.splitView
        // The deferred application must not re-open panes the surface
        // adaptation folded after the preset was applied.
        if !layout.sidebarCollapsed, !sidebarItem.isCollapsed,
           outerSplit.bounds.width > 0 {
            outerSplit.setPosition(
                outerSplit.bounds.width * layout.sidebarFraction,
                ofDividerAt: 0
            )
            outerSplit.layoutSubtreeIfNeeded()
        }
        if !layout.relationsCollapsed, !relationItem.isCollapsed, upperSplit.bounds.width > 0 {
            upperSplit.setPosition(
                upperSplit.bounds.width - outerSplit.bounds.width * layout.relationsFraction
                    - upperSplit.dividerThickness,
                ofDividerAt: 0
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

    // MARK: - Toolbar

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
            item.label = localized("main.seek")
            item.view = symbolsButton
            // §3.2: Seek stays visible at 900pt with long project names;
            // project/version/profile chrome overflows first.
            item.visibilityPriority = .high
            symbolsButton.title = localized("main.seek.p")
            symbolsButton.image = NSImage(
                systemSymbolName: "magnifyingglass",
                accessibilityDescription: localized("main.seek")
            )
            symbolsButton.imagePosition = .imageLeading
            symbolsButton.bezelStyle = .rounded
            symbolsButton.font = .systemFont(ofSize: 12)
            symbolsButton.target = self
            symbolsButton.action = #selector(showSeekFromToolbar(_:))
            symbolsButton.frame.size = NSSize(width: 120, height: 28)
            symbolsButton.setAccessibilityLabel(localized("main.open.seek"))
            let menuItem = NSMenuItem(
                title: localized("main.seek"),
                action: #selector(showSeekFromToolbar(_:)),
                keyEquivalent: ""
            )
            // ⌘P comes from the shared key binding table (K0a); it is the
            // same command as Quick Open, not a second definition.
            if case let .keyboard(chord)? = keyBindings.bindings(for: .fileQuickOpen).first {
                menuItem.applyKeyChord(chord)
            }
            menuItem.target = self
            seekMenuFormItem = menuItem
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
                keyEquivalent: ""
            )
            // ⌘, comes from the shared key binding table (K0a); same command
            // as the Settings menu item.
            if case let .keyboard(chord)? = keyBindings.bindings(for: .appSettings).first {
                menuItem.applyKeyChord(chord)
            }
            menuItem.target = self
            settingsMenuFormItem = menuItem
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

    // MARK: - Toolbar item validation

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.action {
        case #selector(goBack(_:)):
            canGoBack
        case #selector(goForward(_:)):
            canGoForward
        default:
            true
        }
    }

    // MARK: - Observation and rendering

    private func observe() {
        guard !isClosing else { return }
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
            _ = model.contextWindow.tracking
            _ = model.contextWindow.isPinned
            _ = model.readingTrail
            _ = model.bookmarkModel.records
            _ = model.bookmarkModel.storageError
            _ = model.bookmarkModel.lastAttemptMessage
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isClosing else { return }
                self.render()
                self.observe()
            }
        }
    }

    private func render() {
        guard !isClosing else { return }
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
        renderSecondaryReader()
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
        renderTrail()
        if pendingRefreshContentID != nil, model.indexRefreshNotice != nil {
            pendingTabRestore = nil
            pendingRefreshContentID = nil
        }
        if displayedNavigationGeneration != model.navigationGeneration {
            // Trail and file headers can resize the viewport on first navigation.
            // Settle them before the reader computes its centered destination.
            window?.contentView?.layoutSubtreeIfNeeded()
            defer { pendingRefreshContentID = nil }
            let canRestoreRefresh = pendingRefreshContentID == nil
                || (model.activeNavigationRequest?.cause == .historyReplay
                    && pendingRefreshContentID == model.tabStrip.activeDocument?.contentID)
            if canRestoreRefresh, let restore = pendingTabRestore,
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
        renderTrustSeal()
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

    /// The trust seal: a shield before the profile title, moss when Safe and
    /// amber when Trusted, so trust stays visible when the title truncates.
    private func renderTrustSeal() {
        guard let trustMode = model.exactCoordinator.trustMode else {
            profileButton.image = nil
            return
        }
        let theme = ReaderTheme(settings: currentReaderSettings)
        let trusted = trustMode == .trusted
        let description = trusted ? localized("main.trusted") : localized("main.safe")
        let symbol = NSImage(
            systemSymbolName: trusted ? "exclamationmark.shield.fill" : "checkmark.shield.fill",
            accessibilityDescription: description
        )
        profileButton.image = symbol?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(paletteColors: [trusted ? theme.warningColor : theme.verifiedColor])
        )
        profileButton.imagePosition = .imageLeading
        trustSealColor = trusted ? theme.warningColor : theme.verifiedColor
    }

    private var trustSealColor: NSColor?
    var selfTestTrustSeal: (description: String?, color: NSColor?) {
        (profileButton.image?.accessibilityDescription, profileButton.image == nil ? nil : trustSealColor)
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
                recentLanguages: recentLanguageLabels(),
                recentStatus: recentProjectStatus(),
                failed: false,
                onChooseProject: onChooseProject,
                onOpenRecent: { [weak self] in self?.openRecentProject($0) },
                onOpenDropped: openDropped,
                onRetry: retry
            )
        case .failed:
            readerController.showEmptyState(
                recentPaths: recentProjectsStore.paths,
                recentLanguages: recentLanguageLabels(),
                recentStatus: recentProjectStatus(),
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
        let theme = ReaderTheme(settings: currentReaderSettings)
        let status: String
        let color: NSColor
        // Exact ready (even limited) reaches Exact; otherwise fuzzy still reaches Strong.
        let reach: Certainty
        let statusDetail: String?
        switch coordinator.readiness {
        case .ready:
            if environment?.limitations.contains(.dependenciesUnavailableOffline) == true {
                status = localizedFormat("main.exact.deps.unavailable.offline", trustSuffix)
                color = theme.warningColor
                reach = .exact
            } else if environment?.limitations.isEmpty == false {
                status = localizedFormat("main.exact.ready.limited", trustSuffix)
                color = theme.inferredColor
                reach = .exact
            } else if environment != nil {
                status = localizedFormat("main.exact.ready", trustSuffix)
                color = theme.verifiedColor
                reach = .exact
            } else {
                status = localizedFormat("main.exact.ready.environment.unknown", trustSuffix)
                color = theme.inferredColor
                reach = .exact
            }
            statusDetail = nil
        case .preparing:
            status = localizedFormat("main.exact.preparing", trustSuffix)
            color = theme.chromeSecondaryColor
            reach = .strong
            statusDetail = nil
        case .unavailable(let reason):
            status = reason.localizedCaseInsensitiveContains("sandbox")
                ? localized("main.exact.unavailable.sandbox")
                : localized("main.exact.unavailable")
            color = theme.unresolvedColor
            reach = .strong
            statusDetail = reason
        case .off(let reason):
            status = reason.localizedCaseInsensitiveContains("sandbox")
                ? localized("main.exact.unavailable.sandbox")
                : localized("main.exact.off.safe")
            color = theme.warningColor
            reach = .strong
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
        exactStones.update(certainty: reach, theme: theme)
        exactStones.toolTip = detail
    }

    private func applyStatusTheme(_ theme: ReaderTheme) {
        statusSeparator.layer?.backgroundColor = theme.chromeDividerColor.cgColor
        indexLabel.textColor = theme.chromeSecondaryColor
        identifierStatusLabel.textColor = theme.chromeSecondaryColor
        truncatedLabel.textColor = theme.warningColor
        truncatedLabel.backgroundColor = theme.amberSoftColor
        contextButton.contentTintColor = contextItem.isCollapsed
            ? theme.chromeSecondaryColor : theme.accentColor
        renderExactStatus()
    }

    var selfTestStatusStyle: (exactColor: NSColor?, reach: Certainty, stonesVisible: Bool,
                              truncatedFill: NSColor?, separator: CGColor?) {
        (exactLabel.textColor, exactStones.certainty,
         exactStones.window != nil && !exactStones.isHiddenOrHasHiddenAncestor
            && exactStones.frame.width > 0,
         truncatedLabel.backgroundColor, statusSeparator.layer?.backgroundColor)
    }

    private var initialIndexStatus: String? {
        guard model.snapshotPhase == nil,
              case .indexing = model.projectState
        else { return nil }
        return localizedFormat("main.indexing.files", Int64(model.fileTree?.fileCount ?? 0))
    }

    private func renderIdentifierStatus() {
        let primary = readerController.identifierPreparationNotice
        let secondary = secondaryReaderController.identifierPreparationNotice
        let messages = primary == secondary ? [primary] : [primary, secondary]
        identifierStatusLabel.stringValue = messages.compactMap { $0 }.joined(separator: " · ")
        identifierStatusLabel.isHidden = identifierStatusLabel.stringValue.isEmpty
        identifierStatusLabel.setAccessibilityLabel(identifierStatusLabel.stringValue)
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
            transientStatusNotice,
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
        pendingTabRestore = model.tabStrip.activeTab
        pendingRefreshContentID = pendingTabRestore?.anchorContentID
        if pendingRefreshContentID == nil { pendingTabRestore = nil }
        model.refreshIndex(leaving: currentJumpRecord(preferSelection: true))
        render()
    }

    private var exclusionRulesSheet: ExclusionRulesSheet?

    func showExclusionRules() {
        guard canRefreshIndex, let window, exclusionRulesSheet == nil else { return }
        let sheet = ExclusionRulesSheet(rules: model.pathRules) { [weak self] lines in
            self?.applyExclusionRules(lines)
        }
        exclusionRulesSheet = sheet
        guard let sheetWindow = sheet.window else { return }
        window.beginSheet(sheetWindow) { [weak self] _ in
            self?.exclusionRulesSheet = nil
        }
    }

    private func applyExclusionRules(_ lines: [String]) {
        captureActiveTabState()
        do {
            pendingTabRestore = model.tabStrip.activeTab
            pendingRefreshContentID = pendingTabRestore?.anchorContentID
            if pendingRefreshContentID == nil { pendingTabRestore = nil }
            try model.updatePathRules(lines: lines, leaving: currentJumpRecord(preferSelection: true))
        } catch {
            pendingTabRestore = nil
            pendingRefreshContentID = nil
            showTransientStatus(localizedFormat("rules.saveFailed", error.localizedDescription))
        }
        render()
    }

    private func renderTrail() {
        trailView.display(
            trail: model.readingTrail,
            store: model.resolutionExplanations
        )
        trailView.isHidden = model.readingTrail.nodes.isEmpty || contentSurfaceMode != .source
    }

    /// Canonical paths of trusted repositories, fetched from the registry actor.
    private var trustedRepositoryPaths: Set<String> = []
    private var trustedRepositoryTask: Task<Void, Never>?

    /// Trusted repositories and last reading times for the welcome screen.
    private func recentProjectStatus() -> (trusted: Set<String>, lastRead: [String: Date]) {
        refreshTrustedRepositoryPaths()
        let paths = recentProjectsStore.paths
        let trusted = paths.filter {
            trustedRepositoryPaths.contains(
                URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path
            )
        }
        let lastRead = paths.compactMap { path in
            model.lastSessionDate(forProjectRoot: path).map { (path, $0) }
        }
        return (Set(trusted), Dictionary(lastRead, uniquingKeysWith: { first, _ in first }))
    }

    /// The registry is an actor: read it asynchronously and re-render the
    /// welcome screen only when the trusted set actually changed.
    private func refreshTrustedRepositoryPaths() {
        guard trustedRepositoryTask == nil else { return }
        let registry = model.exactCoordinator.trustRegistry
        trustedRepositoryTask = Task { [weak self] in
            let paths = Set(await registry.trustedRepositories().map(\.path))
            guard let self else { return }
            trustedRepositoryTask = nil
            guard paths != trustedRepositoryPaths else { return }
            trustedRepositoryPaths = paths
            switch model.projectState {
            case .empty, .failed: renderEmptyState()
            case .indexing, .ready: break
            }
        }
    }

    /// Short language labels for the welcome screen's recent projects.
    private func recentLanguageLabels() -> [String: String] {
        // Only recorded languages: an unrecorded project shows its folder icon
        // rather than the Rust fallback presented as fact.
        Dictionary(uniqueKeysWithValues: recentProjectsStore.paths.compactMap { path in
            guard let languages = recentProjectsStore.storedLanguagesIfRecorded(for: path)
            else { return nil }
            let label = languages.map { language in
                switch language {
                case .rust: "RS"
                case .python: "PY"
                case .typescript: "TS"
                case .javascript: "JS"
                }
            }.joined(separator: "·")
            return (path, label)
        })
    }

    private func renderCommitButton() {
        let theme = ReaderTheme(settings: currentReaderSettings)
        readerController.setHistoricalSnapshot(model.currentRevision != nil)
        let excludedByRules = model.selectedFile.flatMap { projectPath(for: $0) }.map { path in
            if case .excludedByRule = model.pathRules.verdict(
                for: path, isDirectory: false, appliesDefaults: model.currentRevision == nil
            ) { true } else { false }
        } ?? false
        readerController.setExcludedByRules(excludedByRules)
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
        commitButton.bezelColor = theme.histColor
        commitButton.contentTintColor = theme.backgroundColor
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

    // MARK: - Toolbar, menu and navigation actions

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
            commitPickerPopover?.apply(settings: currentReaderSettings)
        }
        commitPickerPopover?.show(relativeTo: anchor)
    }

    @objc private func showCommitPickerFromMenu(_ sender: Any?) {
        // Let the overflow menu finish tracking before showing a transient popover.
        DispatchQueue.main.async { [weak self] in self?.showCommitPicker(nil) }
    }

    @objc private func showSeekFromToolbar(_ sender: Any?) {
        showPalette()
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
        compareCommitPickerPopover?.apply(settings: currentReaderSettings)
    }

    @objc func selectPreviousContextCandidate(_ sender: Any?) {
        model.contextWindow.selectPrevious()
    }

    @objc func selectNextContextCandidate(_ sender: Any?) {
        model.contextWindow.selectNext()
    }

    @objc func goBack(_ sender: Any?) {
        if historyTargetsReference {
            stepReferenceHistory(backwards: true)
            return
        }
        guard let current = currentJumpRecord() else { return }
        model.goBack(from: current)
    }

    @objc func goForward(_ sender: Any?) {
        if historyTargetsReference {
            stepReferenceHistory(backwards: false)
            return
        }
        model.goForward()
    }

    /// Q5.5: Back and Forward act on the focused side.
    private var historyTargetsReference: Bool { focusedPane == .reference && isReferenceActive }

    var canGoBack: Bool {
        historyTargetsReference ? !referenceBack.isEmpty : model.navigationHistory.canGoBack
    }

    var canGoForward: Bool {
        historyTargetsReference ? !referenceForward.isEmpty : model.navigationHistory.canGoForward
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

    // MARK: - Symbol documentation card

    private func observeSymbolHover() {
        guard !isClosing else { return }
        withObservationTracking {
            _ = model.symbolHover.phase
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isClosing else { return }
                self.renderSymbolHover()
                self.observeSymbolHover()
            }
        }
    }

    private func renderSymbolHover() {
        guard case let .showing(token, doc) = model.symbolHover.phase,
              let window, window.isVisible,
              let anchor = symbolHoverAnchors[token]
        else {
            symbolDocCard.hide()
            if model.symbolHover.phase == .idle { symbolHoverAnchors.removeAll() }
            return
        }
        symbolDocCard.show(
            doc,
            notes: doc.notes.map(symbolDocNoteText),
            anchor: anchor,
            in: window,
            theme: ReaderTheme(settings: currentReaderSettings),
            externalLink: dashLink(for: token, doc: doc)
        )
    }

    /// The card's "Open in Dash" link; nil without Dash or an identifier.
    private func dashLink(for token: SymbolHoverModel.Token, doc: SymbolDoc) -> (title: String, url: URL)? {
        guard DashIntegration.isInstalled, let document = token.document,
              let identifier = String(bytes: document.bytes[Int(token.lowerBound)..<Int(token.upperBound)], encoding: .utf8),
              let url = DashIntegration.url(query: DashIntegration.query(
                  identifier: identifier, doc: doc, language: document.languageMode.language))
        else { return nil }
        return (localized("main.open.in.dash"), url)
    }

    /// Context-menu query: the hover card's exact result is reused when it is
    /// showing the clicked identifier, otherwise the identifier alone is sent.
    private func dashQuery(identifier: String, in document: ReaderDocument, byteOffset: UInt32) -> String {
        var doc: SymbolDoc?
        if case let .showing(token, shown) = model.symbolHover.phase,
           token.contentID == document.contentID,
           token.lowerBound <= byteOffset, byteOffset < token.upperBound {
            doc = shown
        }
        return DashIntegration.query(identifier: identifier, doc: doc, language: document.languageMode.language)
    }

    /// Languages with a hover docs layer (hover docs plans Q16, P1);
    /// JavaScript and others open no card.
    private func hoverToken(for request: ReaderHoverRequest) -> SymbolHoverModel.Token? {
        switch request.document.languageMode.language {
        case .rust, .python, .typescript:
            break
        case .javascript:
            return nil
        }
        guard let path = projectPath(for: request.file)
        else { return nil }
        let token = SymbolHoverModel.Token(
            file: path,
            contentID: request.document.contentID,
            range: request.target.byteRange,
            document: request.document
        )
        if symbolHoverAnchors.count > 16, model.symbolHover.phase == .idle {
            symbolHoverAnchors.removeAll()
        }
        symbolHoverAnchors[token] = request.target.screenRect
        return token
    }

    private func handleHover(_ request: ReaderHoverRequest?) {
        model.symbolHover.pointerMoved(over: request.flatMap(hoverToken(for:)))
    }

    private func showSymbolDocumentation(for request: ReaderHoverRequest) {
        guard let token = hoverToken(for: request) else { return }
        model.symbolHover.showNow(token)
    }

    var canShowSymbolDocumentation: Bool {
        focusedReader.hoverRequestAtSelection().flatMap(hoverToken(for:)) != nil
    }

    func showSymbolDocumentationAtSelection() {
        guard let request = focusedReader.hoverRequestAtSelection() else { return }
        showSymbolDocumentation(for: request)
    }

    private var focusedReader: ReaderViewController {
        secondaryReaderController.hasFocusedText ? secondaryReaderController : readerController
    }

    private func escapeSymbolDocumentation() -> Bool {
        guard model.symbolHover.phase != .idle else { return false }
        model.symbolHover.dismiss()
        return true
    }

    /// Intra-doc and rustdoc links jump to a project definition when one
    /// matches; anything else opens in the default browser, because the user
    /// clicked it.
    private func openSymbolDocLink(_ url: URL) {
        let name = symbolName(fromDocLink: url)
        if let name, let target = model.contextWindow.definition(named: name) {
            model.symbolHover.dismiss()
            open(path: target.path, byteOffset: target.byteOffset)
            return
        }
        if url.scheme == symbolLinkScheme {
            focusNotice = localizedFormat("main.hover.symbolNotFound", name ?? url.absoluteString)
            renderStatusBar()
            return
        }
        guard url.scheme == "http" || url.scheme == "https" || url.scheme == "dash-plugin" else { return }
        model.symbolHover.dismiss()
        NSWorkspace.shared.open(url)
    }

    private func symbolName(fromDocLink url: URL) -> String? {
        if url.scheme == symbolLinkScheme {
            let path = String(url.absoluteString.dropFirst(symbolLinkScheme.count + 1))
            // Rust paths use `::`, JSDoc links also `.` and `#`.
            return path.components(separatedBy: "::").last?
                .components(separatedBy: ".").last?
                .components(separatedBy: "#").last
        }
        // rustdoc pages: …/struct.Oid.html, …/fn.open.html#method.walk
        if let fragment = url.fragment, let dot = fragment.lastIndex(of: ".") {
            return String(fragment[fragment.index(after: dot)...])
        }
        let page = url.lastPathComponent
        let parts = page.split(separator: ".")
        guard parts.count == 3, parts[2] == "html" else { return nil }
        return String(parts[1])
    }

    /// Shared key binding table (K-R3.7): every window reads the app-wide
    /// table; the default scheme stands in when no delegate is installed.
    var keyBindings: KeyBindingTable { appKeyBindingTable() }

    /// Toolbar menu-form items whose keycaps mirror the shared table.
    private var seekMenuFormItem: NSMenuItem?
    private var settingsMenuFormItem: NSMenuItem?

    /// K-R3.6: after an override commit, re-apply the toolbar menu-form
    /// keycaps. (The main menu is rebuilt by the application delegate.)
    func applyKeyBindings() {
        if let item = seekMenuFormItem,
           case let .keyboard(chord)? = keyBindings.bindings(for: .fileQuickOpen).first
        {
            item.applyKeyChord(chord)
        }
        if let item = settingsMenuFormItem,
           case let .keyboard(chord)? = keyBindings.bindings(for: .appSettings).first
        {
            item.applyKeyChord(chord)
        }
    }

    /// Self-test access to a toolbar item's menu-form representation: returns
    /// the stored live item when available so override tests can observe the
    /// in-place update instead of a freshly built one.
    func selfTestToolbarMenuFormItem(identifier: String) -> NSMenuItem? {
        if identifier == "Symbols", let item = seekMenuFormItem { return item }
        if identifier == "Settings", let item = settingsMenuFormItem { return item }
        let toolbar = NSToolbar(identifier: "self-test")
        toolbar.delegate = self
        return self.toolbar(
            toolbar,
            itemForItemIdentifier: NSToolbarItem.Identifier(identifier),
            willBeInsertedIntoToolbar: false
        )?.menuFormRepresentation
    }

    /// R5.2: slices the reader's displayed document to the scope's display
    /// lines (doc comment start through the first body line).
    private func enclosingSlice(
        for scope: ContextWindowModel.EnclosingScope
    ) -> ReaderDocument? {
        guard let document = readerController.caretDocument else { return nil }
        let table = document.lineTable
        guard let firstLine = table.lineColumn(
            at: scope.displayRange.lowerBound
        )?.line,
            let lastLine = table.lineColumn(
                at: min(scope.displayRange.upperBound, UInt32(document.bytes.count))
            )?.line,
            let lower = table.byteOffset(line: firstLine, column: 1),
            let upper = table.byteOffset(
                line: min(lastLine + 1, UInt32(table.lineStarts.count)),
                column: 1
            )
        else { return nil }
        let slice = Array(document.bytes[Int(lower)..<Int(upper)])
        let plain = ReaderDocument(bytes: slice)
        return (try? DocumentLoader().loadSyntax(for: plain)) ?? plain
    }

    /// R6.4: the tracking-mode commands.
    func setLensTracking(_ tracking: ContextWindowModel.Tracking) {
        model.contextWindow.setTracking(tracking)
        replayCaretForLensTracking()
    }

    /// The caret the lens last followed; switching to the enclosing mode
    /// shows its scope at once instead of waiting for the next caret move.
    private var lastLensCaret: (offset: UInt32, reader: ReaderViewController)?

    private func replayCaretForLensTracking() {
        guard model.contextWindow.tracking == .enclosing,
              let caret = lastLensCaret,
              let file = model.selectedFile,
              let path = projectPath(for: file),
              let document = caret.reader.caretDocument
        else { return }
        caretFollowTask?.cancel()
        model.contextWindow.caretMoved(file: path, offset: caret.offset, document: document)
    }

    func toggleLensPin() {
        model.contextWindow.setPinned(!model.contextWindow.isPinned)
    }

    /// P3.2: caret follow. Symbol mode debounces 150 ms (R4.1); the
    /// enclosing mode needs only a light 32 ms debounce so held arrow keys
    /// stay smooth. Only the focused reader drives the lens (R4.5).
    private var caretFollowTask: Task<Void, Never>?
    private func handleReaderCaret(offset: UInt32, from reader: ReaderViewController) {
        // The focused reader wins; the split peer only observes.
        if reader !== readerController, !reader.hasFocusedText, readerController.hasFocusedText {
            return
        }
        lastLensCaret = (offset, reader)
        guard let file = paneFile(for: reader),
              let path = projectPath(for: file),
              let document = reader.caretDocument
        else { return }
        caretFollowTask?.cancel()
        let tracking = model.contextWindow.tracking
        let delay: Duration = tracking == .enclosing
            ? .milliseconds(32) : .milliseconds(150)
        caretFollowTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            guard self.model.contextWindow.tracking == tracking else { return }
            if tracking == .enclosing {
                self.model.contextWindow.caretMoved(
                    file: path, offset: offset, document: document
                )
            } else {
                self.model.contextWindow.tokenClicked(
                    file: path, offset: offset, trigger: .caret
                )
            }
        }
    }

    /// P1.6: ⌘⇧+click / ⌃⌘J / context menu — jump to the type definition of
    /// the binding under the position; failures surface as a brief status.
    private func handleReaderTypeDefinition(offset: UInt32, from reader: ReaderViewController? = nil) {
        let reader = reader ?? focusedReader
        let inReference = reader === secondaryReaderController && isReferenceActive
        guard let file = paneFile(for: reader),
              let path = projectPath(for: file)
        else { return }
        Task { [weak self] in
            guard let self else { return }
            let result = await self.model.contextWindow.typeDefinitionTarget(
                file: path,
                offset: offset
            )
            await MainActor.run {
                switch result {
                case let .target(candidate):
                    if inReference, let root = self.model.fileTree?.root,
                       !exactLocationIsInDependency(candidate.path) {
                        self.openReference(
                            root.appendingPathComponent(candidate.path),
                            byteOffset: candidate.targetByteOffset
                        )
                    } else {
                        self.open(
                            path: candidate.path,
                            byteOffset: candidate.targetByteOffset,
                            cause: .typeDefinition
                        )
                    }
                case let .failed(reason):
                    self.showTransientStatus(reason)
                }
            }
        }
    }

    // MARK: Highlighted names and brackets

    func toggleHighlightAtCaret() {
        guard let name = focusedReader.identifierAtCaret else {
            showTransientStatus(localized("main.highlight.noIdentifier"))
            return
        }
        toggleHighlight(name: name)
    }

    private func toggleHighlight(name: String) {
        if model.highlightedNames.toggle(name) == .full {
            showTransientStatus(localizedFormat("main.highlight.full", Int64(ReaderTheme.highlightSlotCount)))
            return
        }
        highlightsDidChange()
    }

    func clearHighlights() {
        guard !model.highlightedNames.isEmpty else { return }
        model.highlightedNames.removeAll()
        highlightsDidChange()
    }

    var hasHighlights: Bool { !model.highlightedNames.isEmpty }

    func jumpToMatchingBracket() {
        guard !focusedReader.jumpToMatchingBracket() else { return }
        showTransientStatus(localized("main.bracket.none"))
    }

    func selectInsideBrackets() {
        guard !focusedReader.selectInsideBrackets() else { return }
        showTransientStatus(localized("main.bracket.notInside"))
    }

    private func highlightsDidChange() {
        renderHighlights()
        model.scheduleSessionCheckpoint(panelPreset: panelPreset)
    }

    /// Every reader of the window paints the same names in the same colors.
    private func renderHighlights() {
        let names = model.highlightedNames.slotsByName
        readerController.setHighlightedNames(names)
        secondaryReaderController.setHighlightedNames(names)
        contextController.setHighlightedNames(names)
        renderHighlightChips()
    }

    private func renderHighlightChips(theme: ReaderTheme? = nil) {
        let reader = focusedReader
        highlightChips.display(
            model.highlightedNames.entries.map {
                .init(name: $0.name, slot: $0.slot, count: reader.occurrenceCount(ofName: $0.name))
            },
            theme: theme ?? ReaderTheme(settings: currentReaderSettings)
        )
    }

    // MARK: Split reference pane (Q5)

    private enum Pane { case primary, reference }
    private var focusedPane = Pane.primary
    private var primaryOutline: [OutlineFacet] = []
    private var referenceOutline: [OutlineFacet] = []
    private var referenceBack: [ReferencePaneState] = []
    private var referenceForward: [ReferencePaneState] = []
    private static let minimumPaneWidth: CGFloat = 320

    /// The reference pane shows while one is set, unless Compare or Focus owns the right side.
    var isReferenceActive: Bool {
        model.referencePane != nil && model.compare.rightRevision == nil
            && panelPreset != .compare && panelPreset != .focus
            && contentSurfaceMode == .source
    }

    var hasReferencePane: Bool { model.referencePane != nil }

    /// The file a reader shows: the reference pane's own file on the right.
    private func paneFile(for reader: ReaderViewController) -> URL? {
        reader === secondaryReaderController && isReferenceActive ? model.referencePane?.file : model.selectedFile
    }

    /// Opens `file` in the reference pane, replacing what it shows (Q5.2).
    func openReference(_ file: URL, byteOffset: UInt32? = nil) {
        guard projectPath(for: file) != nil else {
            showTransientStatus(localized("main.split.projectOnly"))
            return
        }
        guard ensureRoomForSplit() else {
            showTransientStatus(localized("main.split.tooNarrow"))
            return
        }
        if model.compare.rightRevision != nil || panelPreset == .compare || panelPreset == .focus {
            if model.compare.rightRevision != nil || panelPreset == .compare { model.clearCompare() }
            applyPanelPreset(.reading, restoring: true)
        }
        let target = ReferencePaneState(file: file, byteOffset: byteOffset ?? 0)
        if let current = model.referencePane, current != target {
            referenceBack.append(current)
            referenceForward.removeAll()
        }
        showReference(target)
    }

    /// `⌘\`: the current file at the current position, beside itself.
    func openCurrentFileToSide() {
        guard let file = model.selectedFile else { return }
        openReference(file, byteOffset: readerController.currentSelectionByteOffset ?? 0)
    }

    var canOpenCurrentFileToSide: Bool {
        model.selectedFile.flatMap { projectPath(for: $0) } != nil
    }

    func closeReference() {
        guard model.referencePane != nil else { return }
        model.referencePane = nil
        referenceBack.removeAll()
        referenceForward.removeAll()
        noteFocus(.primary)
        secondaryReaderController.setReferenceMode(false)
        secondaryReaderController.display(nil)
        if panelPreset != .compare { secondaryReaderItem.isCollapsed = true }
        model.scheduleSessionCheckpoint(panelPreset: panelPreset)
        render()
    }

    private func showReference(_ state: ReferencePaneState) {
        model.referencePane = state
        noteFocus(.reference)
        render()
        revealInReference(state.file, byteOffset: state.byteOffset)
        model.scheduleSessionCheckpoint(panelPreset: panelPreset)
    }

    private func stepReferenceHistory(backwards: Bool) {
        guard let current = model.referencePane,
              let target = backwards ? referenceBack.popLast() : referenceForward.popLast()
        else { return }
        if backwards { referenceForward.append(current) } else { referenceBack.append(current) }
        showReference(target)
    }

    private func revealInReference(_ file: URL, byteOffset: UInt32) {
        secondaryReaderController.navigate(
            to: file,
            byteOffset: byteOffset,
            snapshotID: model.currentSnapshotID,
            source: readerSource(for: file),
            languageMode: model.languageMode(for: file)
        )
    }

    /// The right-hand reader is either Compare's other version or the split
    /// reference pane; presets and compare changes re-run this.
    private func renderSecondaryReader() {
        if isReferenceActive, let pane = model.referencePane {
            renderReference(pane)
        } else {
            let compareFile = model.selectedFile.flatMap {
                projectPath(for: $0) == nil ? nil : $0
            }
            secondaryReaderController.setReferenceMode(false)
            secondaryReaderController.display(
                model.compare.rightSnapshotID == nil ? nil : compareFile,
                snapshotID: model.compare.rightSnapshotID,
                source: model.compare.rightSource,
                languageMode: compareFile.flatMap(model.languageMode(for:))
            )
            if focusedPane == .reference { noteFocus(.primary) }
        }
        renderFocusIndicators()
    }

    private func renderReference(_ pane: ReferencePaneState) {
        if secondaryReaderItem.isCollapsed { secondaryReaderItem.isCollapsed = false }
        let needsReveal = secondaryReaderController.displayedFile?.standardizedFileURL
            != pane.file.standardizedFileURL
        secondaryReaderController.setReferenceMode(
            true,
            title: projectPath(for: pane.file) ?? pane.file.lastPathComponent
        )
        secondaryReaderController.setDiffMarkers([:])
        if needsReveal {
            window?.contentView?.layoutSubtreeIfNeeded()
            revealInReference(pane.file, byteOffset: pane.byteOffset)
        }
        if let document = secondaryReaderController.caretDocument {
            secondaryReaderController.setBookmarkMarkers(model.bookmarkMarkers(for: pane.file, document: document))
        }
    }

    /// Q5.8: both readers need their minimum width; the sidebar yields first.
    private func ensureRoomForSplit() -> Bool {
        if isReferenceActive || !secondaryReaderItem.isCollapsed { return true }
        let needed = Self.minimumPaneWidth * 2 + readerSplitController.splitView.dividerThickness
        if readerSplitController.view.bounds.width >= needed { return true }
        if !sidebarItem.isCollapsed {
            sidebarItem.isCollapsed = true
            window?.contentView?.layoutSubtreeIfNeeded()
        }
        return readerSplitController.view.bounds.width >= needed
    }

    /// Q5.3: the side the user last clicked, typed or moved the caret in.
    private func noteFocus(_ pane: Pane) {
        let pane = isReferenceActive ? pane : .primary
        guard pane != focusedPane else { return }
        focusedPane = pane
        renderFocusIndicators()
        renderOutlineForFocus()
        renderHighlightChips()
    }

    private func renderFocusIndicators() {
        let split = isReferenceActive
        readerController.setFocusIndicator(split && focusedPane == .primary)
        secondaryReaderController.setFocusIndicator(split && focusedPane == .reference)
    }

    private func renderOutlineForFocus() {
        if focusedPane == .reference, let pane = model.referencePane {
            sidebarController.setOutline(referenceOutline.map(OutlineNode.init(facet:)), file: pane.file)
            sidebarController.highlightOutline(at: pane.byteOffset)
        } else {
            sidebarController.setOutline(primaryOutline.map(OutlineNode.init(facet:)), file: model.selectedFile)
            if let offset = readerController.currentReadingPosition()?.byteOffset {
                sidebarController.highlightOutline(at: offset)
            }
        }
    }

    func jumpToTypeDefinitionAtCaret() {
        guard let offset = model.tabStrip.activeTab?.selectionByteOffset else {
            showTransientStatus(modelText("model.typehop.noType"))
            return
        }
        handleReaderTypeDefinition(offset: offset)
    }

    /// Brief status-line notice for navigation failures (R3.4).
    private var transientStatusNotice: String?
    private var transientStatusTask: Task<Void, Never>?
    func showTransientStatus(_ message: String) {
        transientStatusNotice = message
        renderStatusBar()
        transientStatusTask?.cancel()
        transientStatusTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.transientStatusNotice = nil
                self?.renderStatusBar()
            }
        }
    }

    private func handleReaderClick(offset: UInt32, commandClick: Bool, from reader: ReaderViewController) {
        let inReference = reader === secondaryReaderController && isReferenceActive
        guard reader === readerController || inReference else { return }
        noteFocus(inReference ? .reference : .primary)
        guard let file = paneFile(for: reader),
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
                if inReference, let root = model.fileTree?.root,
                   !exactLocationIsInDependency(candidate.path) {
                    openReference(root.appendingPathComponent(candidate.path), byteOffset: candidate.targetByteOffset)
                } else {
                    self.open(candidate)
                }
            }
        } else {
            model.contextWindow.tokenClicked(file: path, offset: offset)
        }
    }

    private func handleReaderRelation(
        offset: UInt32,
        direction: RelationTreeModel.Direction,
        from reader: ReaderViewController? = nil
    ) {
        let reader = reader ?? readerController
        guard reader === readerController || isReferenceActive,
              let file = paneFile(for: reader),
              let path = projectPath(for: file)
        else { return }
        openRelationsPane()
        if direction == .references,
           case let .ready(session, _) = model.projectState,
           let document = reader === readerController ? model.tabStrip.activeDocument : reader.caretDocument,
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
        symbolAnchor: String? = nil,
        cause: NavigationCause = .relation
    ) {
        guard let root = model.fileTree?.root else { return }
        let file = exactLocationIsInDependency(path)
            ? URL(fileURLWithPath: path)
            : root.appendingPathComponent(path)
        navigate(
            to: file,
            byteOffset: byteOffset,
            cause: cause,
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

    // MARK: - Tab strip state

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

    // MARK: - Session checkpoints

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

    // MARK: - Jump records and path helpers

    private func currentJumpRecord(preferSelection: Bool = false) -> JumpRecord? {
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
        let position = preferSelection
            ? readerController.readingPosition(at: readerController.currentSelectionByteOffset ?? model.selectedByteOffset)
            : readerController.currentReadingPosition(fallbackByteOffset: model.selectedByteOffset)
        guard let position, position.file.standardizedFileURL == selectedFile.standardizedFileURL
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
