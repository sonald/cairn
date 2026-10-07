import AppKit
import CodeInsightAppModel
import CodeInsightCore
import CodeInsightEngine
import CodeInsightExact
import CodeInsightGit
import CodeInsightReaderCore
import CodeInsightReaderUI
import CoreText
import Darwin
import os
import PDFKit
import SwiftUI
import WebKit

@main
private struct CodeInsightApplication {
    @MainActor
    static func main() {
        let startedAt = ContinuousClock.now
        let arguments = Array(CommandLine.arguments.dropFirst())
        if launchSelfTestIfRequested(startedAt: startedAt, arguments: arguments) {
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        // One store shared by the model and the delegate: the model
        // advances the last-session pointer when a project's
        // snapshot is written, and launch reads the same pointer.
        let launchRecentStore = RecentProjectsStore()
        let delegate = AppDelegate.production(
            startedAt: startedAt,
            recentProjectsStore: launchRecentStore
        )
        app.delegate = delegate
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation,
    NSMenuDelegate
{
    let startedAt: ContinuousClock.Instant
    /// Model injected by self-test entry points; production launches pass
    /// none and every window gets its own model assembled from the shared
    /// trust registry / materializer / bookmark store (§4).
    private let injectedModel: AppModel?
    let exactSelfTestProviderState: ExactSelfTestProviderState?
    let relationTimingTemporaryRoot: URL?
    let recentProjectsStore: RecentProjectsStore
    /// Session store anchor for windows the application assembles itself;
    /// self-tests inject an isolated URL so multi-window acceptance never
    /// touches real user data (§11).
    let windowSessionURL: URL?
    private(set) var readerSettings = ReaderSettings(defaults: .standard)
    private let readerDerivedDataStore = ReaderDerivedDataStore()
    nonisolated(unsafe) private var wrapKeyMonitor: Any?
    // Window collection and routing state (all MainActor, §4.1).
    private(set) var projectWindows: [MainWindowController] = []
    /// Most-recently-active project window, recency-ordered (last = most
    /// recent). Drives the launch restore target and blank-window choice.
    private(set) var activeWindowOrder: [MainWindowController] = []
    private weak var lastActiveProjectWindow: MainWindowController?
    private(set) var settingsWindowController: ReaderSettingsWindowController?
    /// Shared single-instance services owned by the application, injected
    /// into every window's model (§8.2/§8.3).
    private let sharedTrustRegistry: TrustRegistry
    private let sharedMaterializer: Materializer
    // Launch Services open requests (§5.2): queued until launch finished;
    // processed strictly serially afterwards.
    private(set) var pendingOpenURLs: [URL] = []
    private var receivedExplicitOpenRequest = false
    private var launchFinished = false
    private(set) var isDrainingOpenRequests = false
    /// Set while quitting so no new project work starts (§7.2).
    private var isTerminating = false
    /// Projects whose session checkpoint was successfully written at least
    /// once this run; only those may become the restore target (§7.3).
    private var persistedProjects: Set<String> = []

    init(
        startedAt: ContinuousClock.Instant,
        model: AppModel? = nil,
        exactSelfTestProviderState: ExactSelfTestProviderState? = nil,
        relationTimingTemporaryRoot: URL? = nil,
        recentProjectsStore: RecentProjectsStore = RecentProjectsStore(),
        windowSessionURL: URL? = nil,
        sharedTrustRegistry: TrustRegistry = TrustRegistry(),
        sharedMaterializer: Materializer = Materializer()
    ) {
        self.startedAt = startedAt
        self.injectedModel = model
        self.exactSelfTestProviderState = exactSelfTestProviderState
        self.relationTimingTemporaryRoot = relationTimingTemporaryRoot
        self.recentProjectsStore = recentProjectsStore
        self.windowSessionURL = windowSessionURL
        self.sharedTrustRegistry = sharedTrustRegistry
        self.sharedMaterializer = sharedMaterializer
        super.init()
        loadKeyBindingOverrides()
        NotificationCenter.default.addObserver(self,
            selector: #selector(readerFontEnvironmentChanged),
            name: .readerFontEnvironmentDidChange, object: ReaderFontResolver.shared)
        NotificationCenter.default.addObserver(self,
            selector: #selector(installedFontsChanged),
            name: Notification.Name(kCTFontManagerRegisteredFontsChangedNotification as String), object: nil)
        // Core Text uses the distributed center for session/persistent registrations.
        DistributedNotificationCenter.default().addObserver(self,
            selector: #selector(installedFontsChanged),
            name: Notification.Name(kCTFontManagerRegisteredFontsChangedNotification as String), object: nil)
    }

    @objc nonisolated private func installedFontsChanged(_ notification: Notification) {
        // Core Text can post on its registration thread; UI work stays on main.
        Task { @MainActor in ReaderFontResolver.shared.refresh() }
    }

    @objc private func readerFontEnvironmentChanged(_ notification: Notification) {
        for controller in projectWindows { controller.applyReaderSettings(readerSettings) }
        settingsWindowController?.update(settings: readerSettings)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        ReaderFontResolver.shared.refreshIfNeeded()
    }

    /// Normal application entry point; tests override storage locations only.
    static func production(
        startedAt: ContinuousClock.Instant,
        sessionURL: URL = AppModel.defaultSessionURL,
        recentProjectsStore: RecentProjectsStore = RecentProjectsStore(),
        sharedTrustRegistry: TrustRegistry = TrustRegistry(),
        sharedMaterializer: Materializer = Materializer()
    ) -> AppDelegate {
        AppDelegate(
            startedAt: startedAt,
            recentProjectsStore: recentProjectsStore,
            windowSessionURL: sessionURL,
            sharedTrustRegistry: sharedTrustRegistry,
            sharedMaterializer: sharedMaterializer
        )
    }

    /// Model behind the self-test accessors (`model`) and the first window.
    /// Injected models keep their own singletons; production windows share
    /// the application's instances.
    private lazy var bootstrapModel: AppModel = makeWindowModel()

    /// The one process-wide bookmark authority (§8.1).
    private lazy var sharedBookmarkStore = SharedBookmarkStore(
        fileURL: (windowSessionURL ?? AppModel.defaultSessionURL)
            .deletingLastPathComponent()
            .appendingPathComponent("bookmarks.json")
    )

    var model: AppModel {
        if let injectedModel {
            return injectedModel
        }
        return bootstrapModel
    }

    private func makeWindowModel() -> AppModel {
        AppModel(
            sessionURL: windowSessionURL ?? AppModel.defaultSessionURL,
            recentProjectsStore: recentProjectsStore,
            sharedBookmarkStore: sharedBookmarkStore,
            exactCoordinator: ExactCoordinator(
                trustRegistry: sharedTrustRegistry,
                materializer: sharedMaterializer
            )
        )
    }

    /// The window self-test helpers inspect; multi-window routing never
    /// relies on this alias.
    var windowController: MainWindowController? {
        projectWindows.first
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        if wrapKeyMonitor == nil {
            wrapKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated {
                    self?.handleMonitoredKeyEquivalent(event) == true
                }
                return handled ? nil : event
            }
        }
        // Menus and shared storage exist before the first open request can
        // arrive; no project is opened here (§5.2).
        if NSApplication.shared.mainMenu == nil {
            NSApplication.shared.mainMenu = makeMainMenu()
        }
        applyApplicationAppearance()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        if let wrapKeyMonitor { NSEvent.removeMonitor(wrapKeyMonitor) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        receivedExplicitOpenRequest = true
        pendingOpenURLs.append(contentsOf: urls)
        guard launchFinished else { return }
        drainOpenRequests()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !receivedExplicitOpenRequest {
            launch(offscreen: false)
        } else {
            NSApplication.shared.mainMenu = makeMainMenu()
            applyApplicationAppearance()
            drainOpenRequests()
            // All explicit requests failed or were cancelled: keep exactly
            // one welcome window instead of restoring an unrelated project
            // (§5.2 step 4).
            if projectWindows.isEmpty {
                makeWindowWithModel(model, offscreen: false)?.showWindow(nil)
            }
        }
        launchFinished = true
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Idempotent final fallback: checkpoints already ran during the
        // terminate reply; this only catches paths that bypassed approval.
        for controller in projectWindows {
            controller.checkpointSessionSynchronously()
        }
        for controller in projectWindows {
            controller.model.exactCoordinator.shutdown()
        }
        if ProcessInfo.processInfo.arguments.contains("--self-test-session") {
            Self.writeJSON(["channel": "session-termination", "willTerminate": true])
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        for controller in projectWindows {
            controller.scheduleSessionCheckpointForApplicationLifecycle()
        }
    }

    // MARK: - Self-test accessors (multi-window lifecycle coverage)

    var selfTestProjectWindowCount: Int { projectWindows.count }

    func selfTestProjectWindow(_ index: Int) -> MainWindowController? {
        projectWindows.indices.contains(index) ? projectWindows[index] : nil
    }

    var selfTestIsDrainingOpenRequests: Bool { isDrainingOpenRequests }

    func selfTestLaunchOffscreen() {
        launch(offscreen: true)
    }

    func selfTestEnqueueOpenRequest(
        root: URL,
        languages: [LanguageID]?,
        sourceWindow: MainWindowController? = nil
    ) {
        enqueueOpenRequest(
            root: root,
            languages: languages,
            sourceWindow: sourceWindow
        )
    }

    /// Decision offered for a failed final save during quit.
    enum QuitSaveFailureDecision: Equatable {
        case retry
        case skipWindow
        case cancelQuit
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        // Closing the last project window with Settings still open routes
        // through the same termination path (§7.2).
        guard !isTerminating else { return .terminateNow }
        isTerminating = true
        // Final capture/save per window. A failure is handled per window:
        // retry re-runs that window's save, skip proceeds without it while
        // the OTHER windows still get their final save, and cancelling
        // aborts the quit with every window intact (§7.2).
        let proceed = finalizeQuitSaves { controller, error in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = localized("app.save.failed")
            alert.informativeText =
                localizedFormat("app.save.failureDetail",
                    controller.projectURL?.lastPathComponent ?? localized("app.save.project"),
                    String(describing: error))
            alert.addButton(withTitle: localized("app.save.retry"))
            alert.addButton(withTitle: localized("app.save.quit"))
            alert.addButton(withTitle: localized("app.save.cancel"))
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                return .retry
            case .alertSecondButtonReturn:
                return .skipWindow
            default:
                return .cancelQuit
            }
        }
        guard proceed else {
            isTerminating = false
            return .terminateCancel
        }
        let closing = projectWindows
        Task { @MainActor in
            for controller in closing {
                controller.beginTerminateTeardown()
            }
            // Await every window's teardown, including windows whose close
            // was already running when the quit started: their providers
            // must exit before the process may end (§7.2).
            for controller in closing {
                await controller.teardownCompletion()
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Runs the final per-window save loop. `prompt` decides what a failed
    /// save means; tests inject scripted decisions. Windows that are
    /// already closing had their final save (or approved skip) in their
    /// own approval stage and are not asked again. Returns false when the
    /// quit was cancelled.
    func finalizeQuitSaves(
        prompt: (MainWindowController, any Error) -> QuitSaveFailureDecision
    ) -> Bool {
        var skipped = Set<ObjectIdentifier>()
        while true {
            var failure: (controller: MainWindowController, error: any Error)?
            for controller in projectWindows
            where !controller.isClosing
                && !skipped.contains(ObjectIdentifier(controller))
            {
                do {
                    controller.model.projectSearch.commitQuery()
                    try controller.checkpointSessionSynchronouslyReportingFailure()
                } catch {
                    failure = (controller, error)
                    break
                }
            }
            guard let failure else { return true }
            switch prompt(failure.controller, failure.error) {
            case .retry:
                continue
            case .skipWindow:
                skipped.insert(ObjectIdentifier(failure.controller))
                continue
            case .cancelQuit:
                return false
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        // Project windows alone decide termination; the global Settings
        // window must not keep the app (or block quit) on its own, and a
        // window whose teardown is still finishing no longer counts as
        // open (§7.2).
        projectWindows.allSatisfy(\.isClosing)
    }

    func launch(
        offscreen: Bool,
        measuresIdleFootprint: Bool = false
    ) {
        NSApplication.shared.mainMenu = makeMainMenu()
        applyApplicationAppearance()
        // The launch restore target is known before the window exists, so
        // its frame autosave can be project-scoped from the start (§6.4).
        let snapshot = offscreen ? nil : launchSessionSnapshot()
        let autosave = snapshot.map {
            NSWindow.FrameAutosaveName(
                "CodeInsightMainWindow-"
                    + AppModel.sessionProjectKey(
                        for: URL(
                            fileURLWithPath: $0.projectRoot,
                            isDirectory: true
                        )
                    )
            )
        }
        let windowController = makeWindowWithModel(
            model,
            offscreen: offscreen,
            measuresIdleFootprint: measuresIdleFootprint,
            frameAutosaveName: autosave
        )
        windowController?.showWindow(nil)
        guard !offscreen, let windowController else { return }
        if let snapshot {
            windowController.restoreSession(snapshot)
        }
    }

    /// Shared assembly for every main window: fresh model (or the injected
    /// self-test model for the first window), shared singletons, routing
    /// callbacks. Production and self-tests use the same path (§4).
    private func makeWindowWithModel(
        _ windowModel: AppModel,
        offscreen: Bool,
        measuresIdleFootprint: Bool = false,
        frameAutosaveName: NSWindow.FrameAutosaveName? = nil
    ) -> MainWindowController? {
        guard !isTerminating else { return nil }
        windowModel.onSessionCheckpointWritten = { [weak self] projectRoot in
            self?.handleSessionCheckpointWritten(projectRoot)
        }
        let windowController = MainWindowController(
            model: windowModel,
            settings: readerSettings,
            offscreen: offscreen,
            derivedDataStore: readerDerivedDataStore,
            measuresIdleFootprint: measuresIdleFootprint,
            recentProjectsStore: recentProjectsStore,
            recordsRecentProjects: !offscreen,
            frameAutosaveName: frameAutosaveName,
            onChooseProject: { [weak self] in
                self?.chooseLanguagesProject(nil)
            },
            onChooseProjectLanguage: { [weak self] root, source in
                self?.chooseLanguagesProject(root, from: source)
            },
            onShowSettings: { [weak self] in self?.showSettings(nil) }
        )
        registerProjectWindow(windowController)
        // Cascade fresh windows away from the previous one while staying
        // inside the visible screen area (§6.4).
        if !offscreen, let previous = activeWindowOrder.last?.window,
           previous !== windowController.window,
           let screen = NSScreen.main?.visibleFrame
        {
            let offset: CGFloat = 28
            let origin = previous.frame.origin
            let candidate = NSPoint(
                x: origin.x + offset,
                y: max(screen.minY, origin.y - offset)
            )
            if screen.contains(NSPoint(x: candidate.x, y: candidate.y)) {
                windowController.window?.setFrameOrigin(candidate)
            }
        }
        // Track creation order as initial activity order even offscreen:
        // it is application-internal bookkeeping and lets programmatic
        // dispatch find the window while no key window exists.
        handleProjectWindowBecameActive(windowController)
        return windowController
    }

    /// Routing registration shared by production assembly and tests that
    /// build their own windows (§4: one assembly path, isolated storage).
    func registerProjectWindow(_ windowController: MainWindowController) {
        windowController.onProjectWindowClosing = { [weak self] controller in
            self?.handleProjectWindowStartedClosing(controller)
        }
        windowController.onProjectWindowClosed = { [weak self] controller in
            self?.handleProjectWindowFinishedTeardown(controller)
        }
        windowController.onProjectWindowBecameActive = { [weak self] controller in
            self?.handleProjectWindowBecameActive(controller)
        }
        windowController.model.bookmarkModel.onSharedRecordsChanged = {
            [weak windowController] in
            windowController?.renderForSelfTest()
        }
        projectWindows.append(windowController)
    }

    /// Creates a blank welcome window (⌘N / fallback surface).
    @discardableResult
    private func createBlankWindow() -> MainWindowController? {
        guard let controller = makeWindowWithModel(
            makeWindowModel(),
            offscreen: false
        ) else { return nil }
        controller.showWindow(nil)
        return controller
    }

    private func handleProjectWindowBecameActive(
        _ controller: MainWindowController
    ) {
        activeWindowOrder.removeAll { $0 === controller }
        activeWindowOrder.append(controller)
        lastActiveProjectWindow = controller
    }

    /// A window started closing: it stays in the collection (still
    /// claiming its project, so a repeat open can find and wait for it)
    /// until its asynchronous teardown finishes; routing skips closing
    /// windows through `isClosing` (§7.1).
    private func handleProjectWindowStartedClosing(
        _ controller: MainWindowController
    ) {
        if let root = controller.projectURL?.path {
            // A successfully saved project stays a valid restore target
            // even after its window closed (§7.3).
            if persistedProjects.contains(root) {
                updateLaunchRestorePointer()
            }
        }
        refreshWindowTitles()
        // Closing the last project window quits (Settings stays out of
        // the decision); closing windows no longer count as open (§7.2).
        let openRemaining = projectWindows.contains { !$0.isClosing }
        if !openRemaining && launchFinished && !isTerminating {
            NSApplication.shared.terminate(nil)
        }
    }

    /// A window finished its teardown: its project claim was released and
    /// its provider exited, so the controller leaves the collection only
    /// now (§7.1).
    private func handleProjectWindowFinishedTeardown(
        _ controller: MainWindowController
    ) {
        projectWindows.removeAll { $0 === controller }
        activeWindowOrder.removeAll { $0 === controller }
        if lastActiveProjectWindow === controller {
            lastActiveProjectWindow = activeWindowOrder.last
        }
    }

    /// Window titles distinguish sibling projects sharing a name (§6.3).
    private func refreshWindowTitles() {
        let identities = projectWindows.compactMap(\.projectURL)
        for controller in projectWindows {
            controller.updateWindowTitle(among: identities)
        }
    }

    private func handleSessionCheckpointWritten(_ projectRoot: String) {
        persistedProjects.insert(projectRoot)
        if lastActiveProjectWindow?.model.projectRoot?.path == projectRoot {
            updateLaunchRestorePointer()
        }
    }

    /// The restore target follows the most recently active project that
    /// has persisted a session this run (§7.3).
    private func updateLaunchRestorePointer() {
        guard !persistedProjects.isEmpty else { return }
        for controller in activeWindowOrder.reversed() {
            if let root = controller.projectURL?.path,
               persistedProjects.contains(root)
            {
                recentProjectsStore.lastSessionProjectPath = root
                return
            }
        }
    }

    /// The snapshot to reopen at launch: the last project's per-project
    /// file, or — before that pointer ever exists — the legacy single-file
    /// session, migrated once. A missing or unreadable snapshot shows the
    /// welcome surface; recoverable problems surface through the window's
    /// status bar instead of a modal.
    private func launchSessionSnapshot() -> SessionCodec.Snapshot? {
        if let lastPath = recentProjectsStore.lastSessionProjectPath {
            return model.loadSessionSnapshot(
                forProject: URL(fileURLWithPath: lastPath, isDirectory: true)
            ).snapshot
        }
        return model.loadLegacySessionSnapshot().snapshot
    }

    func enlargedWindowLayout(
        controller: MainWindowController,
        statusBarOccupancyHeight: CGFloat
    ) -> (checks: [String: Bool], geometry: [String: Double]) {
        let contentSize = NSSize(width: 1_600, height: 1_000)
        controller.window?.setContentSize(contentSize)
        // Keep the offscreen self-test deterministic when AppKit clamps to the screen.
        controller.window?.contentView?.setFrameSize(contentSize)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.window?.displayIfNeeded()
        let contentFrame = controller.window?.contentView?.bounds ?? .zero
        controller.selfTestSetDefaultSidebarDivider()
        let splitFrame = controller.selfTestContentSplitFrameInContentView
        let trailFrame = controller.selfTestTrailBarFrameInContentView
        // The trail bar retires on the no-project surface (§3.1); only a
        // visible bar occupies content height.
        let trailOccupancyHeight =
            controller.selfTestTrailBarVisible ? trailFrame.height : 0
        let statusFrame = controller.selfTestStatusBarFrameInContentView
        let sidebar = controller.selfTestSidebarGeometry
        let sidebarAvailableHeight =
            sidebar.filesPaneHeight + sidebar.outlinePaneHeight
        let expectedFilesPaneHeight = sidebarAvailableHeight * 0.65
        let expectedOutlinePaneHeight = sidebarAvailableHeight * 0.35
        let tolerance: CGFloat = 1
        var checks = [
            "contentSplitWidthFillsContentView":
                abs(splitFrame.width - contentFrame.width) <= tolerance,
            "contentSplitHeightFillsAvailableContent":
                abs(
                    splitFrame.height
                        - (
                            contentFrame.height - statusBarOccupancyHeight
                                - trailOccupancyHeight
                        )
                ) <= tolerance,
            "sidebarFilesPaneIs65Percent":
                sidebarAvailableHeight > 0
                && abs(sidebar.filesPaneHeight - expectedFilesPaneHeight)
                    <= sidebarAvailableHeight * 0.05,
            "sidebarOutlinePaneIs35Percent":
                sidebarAvailableHeight > 0
                && abs(sidebar.outlinePaneHeight - expectedOutlinePaneHeight)
                    <= sidebarAvailableHeight * 0.05,
            "sidebarFilesPaneNotCollapsedByPlaceholder":
                sidebar.filesPaneHeight > sidebar.filePlaceholderHeight * 3,
            "sidebarFilesPlaceholderCentered":
                sidebar.filePlaceholderCenterOffset <= tolerance,
            "sidebarOutlinePlaceholderCentered":
                sidebar.outlinePlaceholderCenterOffset <= tolerance,
            "sidebarManualDividerSurvivesPlaceholderRefresh":
                controller.selfTestSidebarDividerSurvivesPlaceholderRefresh,
            "sidebarDividerPersistsAcrossRebuild":
                controller.selfTestSidebarDividerPersistsAcrossRebuild,
        ]
        if statusBarOccupancyHeight > 0 {
            checks["statusBarPinnedToContentBottom"] =
                abs(statusFrame.minY - contentFrame.minY) <= tolerance
            checks["statusBarWidthFillsContentView"] =
                abs(statusFrame.width - contentFrame.width) <= tolerance
            checks["statusBarHeightIs24"] =
                abs(statusFrame.height - statusBarOccupancyHeight) <= tolerance
        }
        return (
            checks,
            [
                "contentHeight": Double(contentFrame.height),
                "contentWidth": Double(contentFrame.width),
                "sidebarAvailablePaneHeight": Double(sidebarAvailableHeight),
                "sidebarExpectedFilesPaneHeight":
                    Double(expectedFilesPaneHeight),
                "sidebarExpectedOutlinePaneHeight":
                    Double(expectedOutlinePaneHeight),
                "sidebarFilePlaceholderHeight":
                    Double(sidebar.filePlaceholderHeight),
                "sidebarFilesPaneHeight": Double(sidebar.filesPaneHeight),
                "sidebarOutlinePaneHeight": Double(sidebar.outlinePaneHeight),
                "splitHeight": Double(splitFrame.height),
                "splitMinY": Double(splitFrame.minY),
                "trailBarHeight": Double(trailFrame.height),
                "splitWidth": Double(splitFrame.width),
                "statusBarHeight": Double(statusFrame.height),
                "statusBarMinY": Double(statusFrame.minY),
                "statusBarOccupancyHeight": Double(statusBarOccupancyHeight),
                "statusBarWidth": Double(statusFrame.width),
            ]
        )
    }

    @objc private func openProject(_ sender: Any?) {
        chooseLanguagesProject(nil)
    }

    @objc private func clearReadingSession(_ sender: Any?) {
        projectCommandTarget()?.confirmClearReadingSession()
    }

    @objc private func openPythonProject(_ sender: Any?) {
        chooseProject(language: .python)
    }

    @objc private func openTypeScriptProject(_ sender: Any?) {
        chooseProject(language: .typescript)
    }

    private func chooseProject(language: LanguageID) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = localized("app.open.action")
        if panel.runModal() == .OK, let root = panel.url {
            enqueueOpenRequest(
                root: root,
                languages: [language],
                sourceWindow: projectCommandTarget()
            )
        }
    }

    @objc private func openRecentProject(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        enqueueOpenRequest(
            root: URL(fileURLWithPath: path, isDirectory: true),
            languages: nil,
            sourceWindow: projectCommandTarget()
        )
    }

    private func chooseLanguagesProject(
        _ root: URL?,
        from sourceWindow: MainWindowController? = nil
    ) {
        let selectedRoot: URL
        if let root {
            selectedRoot = root
        } else {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.prompt = localized("app.open.action")
            guard panel.runModal() == .OK, let panelRoot = panel.url else {
                return
            }
            selectedRoot = panelRoot
        }
        enqueueOpenRequest(
            root: selectedRoot,
            languages: nil,
            sourceWindow: sourceWindow ?? projectCommandTarget()
        )
    }

    // MARK: - Project open routing (§3.1)

    private struct PendingOpenRequest {
        let root: URL
        /// Explicit language choice (Open Python / Open TypeScript); nil
        /// means saved session / Recents / picker decide.
        let languages: [LanguageID]?
        let sourceWindow: MainWindowController?
    }

    func enqueueOpenRequest(
        root: URL,
        languages: [LanguageID]?,
        sourceWindow: MainWindowController?
    ) {
        pendingOpenURLs.append(root)
        requestContexts.append(
            PendingOpenRequest(
                root: root,
                languages: languages,
                sourceWindow: sourceWindow
            )
        )
        drainOpenRequests()
    }

    /// Per-URL context for requests submitted directly (menu/recents);
    /// Launch Services entries only carry URLs and take the default
    /// context as the queue drains.
    private var requestContexts: [PendingOpenRequest] = []

    private func nextRequestContext(for root: URL) -> PendingOpenRequest {
        if let index = requestContexts.firstIndex(where: {
            $0.root.standardizedFileURL == root.standardizedFileURL
        }) {
            return requestContexts.remove(at: index)
        }
        return PendingOpenRequest(root: root, languages: nil, sourceWindow: nil)
    }

    /// Serial open pipeline: validates, dedupes, and routes one request at
    /// a time so language pickers queue instead of interleaving (§3.3).
    private func drainOpenRequests() {
        guard !isDrainingOpenRequests else { return }
        guard !pendingOpenURLs.isEmpty else {
            // Explicit requests that all failed or were cancelled leave a
            // welcome window rather than restoring an old project (§5.2).
            if launchFinished && receivedExplicitOpenRequest,
               projectWindows.isEmpty
            {
                createBlankWindow()
            }
            return
        }
        isDrainingOpenRequests = true
        Task { @MainActor [weak self] in
            while let self, !self.pendingOpenURLs.isEmpty {
                let url = self.pendingOpenURLs.removeFirst()
                await self.processOpenRequest(url)
            }
            guard let self else { return }
            self.isDrainingOpenRequests = false
            // Requests queued while the final item was still processing
            // restart the pipeline instead of waiting forever.
            if !self.pendingOpenURLs.isEmpty {
                self.drainOpenRequests()
            } else if self.launchFinished && self.receivedExplicitOpenRequest,
                self.projectWindows.isEmpty
            {
                self.createBlankWindow()
            }
        }
    }

    /// Canonical project identity (§3.2): file URL only, real directory,
    /// symlink-resolved standardized path. Returns an error message for
    /// anything the app cannot open as a project.
    static func projectIdentity(
        for url: URL
    ) -> Result<URL, OpenIdentityFailure> {
        guard url.isFileURL else {
            return .failure(OpenIdentityFailure(
                path: url.path.isEmpty ? url.absoluteString : url.path,
                reason: localized("app.open.notLocal")
            ))
        }
        // Resolve symlinks first so aliases point at the real directory.
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: resolved.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            return .failure(OpenIdentityFailure(
                path: url.path,
                reason: localized("app.open.notFolder")
            ))
        }
        return .success(resolved)
    }

    struct OpenIdentityFailure: Error {
        let path: String
        let reason: String

        var message: String { localizedFormat("app.open.failureDetail", path, reason) }
    }

    private func processOpenRequest(_ url: URL) async {
        guard !isTerminating else { return }
        let context = nextRequestContext(for: url)
        switch Self.projectIdentity(for: url) {
        case .failure(let failure):
            reportOpenFailure(failure.message, preferredWindow: context.sourceWindow)
            return
        case .success(let identity):
            await openProjectIdentity(identity, context: context)
        }
    }

    private func reportOpenFailure(
        _ message: String,
        preferredWindow: MainWindowController?
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = localized("app.open.failed")
        alert.informativeText = message
        // The error surfaces in the window that started the request; a
        // missing one falls back to the most recent project window rather
        // than a stranger's (§6.2).
        guard let window = preferredWindow?.window ?? activeWindowOrder.last?.window
        else {
            alert.runModal()
            return
        }
        Task { @MainActor in
            await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { _ in
                    continuation.resume()
                }
            }
        }
    }

    private func windowController(
        forProject identity: URL
    ) -> MainWindowController? {
        projectWindows.first {
            $0.projectURL?.standardizedFileURL == identity.standardizedFileURL
        }
    }

    private func openProjectIdentity(
        _ identity: URL,
        context: PendingOpenRequest
    ) async {
        if let existing = windowController(forProject: identity) {
            if existing.isClosing {
                // A closing window still claims the project; wait for its
                // session writer to finish before reopening (§4.1). The
                // controller stays in the collection while closing, so the
                // wait is found and the claim is released afterwards.
                await existing.waitForCloseCompletion()
            } else {
                activateWindow(existing)
                // An explicit language choice on an already-open project
                // runs the existing confirm-and-reload flow in its window.
                if let languages = context.languages,
                   existing.model.projectRoot != nil,
                   existing.model.projectLanguages != languages
                {
                    existing.openProject(root: identity, languages: languages)
                }
                return
            }
        }
        guard !isTerminating else { return }
        // Pick the destination window: source window when blank, then the
        // active blank window, then any blank window, then a new window.
        let destination: MainWindowController
        let autoCreated: Bool
        if let source = context.sourceWindow, source.isUnclaimedForReuse {
            destination = source
            autoCreated = false
        } else if let active = lastActiveProjectWindow,
                  active.isUnclaimedForReuse,
                  active !== context.sourceWindow
        {
            destination = active
            autoCreated = false
        } else if let blank = projectWindows.first(where: \.isUnclaimedForReuse) {
            destination = blank
            autoCreated = false
        } else if let created = createBlankWindow() {
            destination = created
            autoCreated = true
        } else {
            return
        }
        // Claim before any asynchronous load so duplicate requests resolve
        // to this window (§3.2 step 5).
        destination.claimProject(identity)
        destination.adoptProjectFrameAutosave(for: identity)
        refreshWindowTitles()

        // Language resolution order (§3.3): an explicit menu choice wins
        // over everything; then the saved session; then a Recents record;
        // the picker only runs for first opens.
        if let explicit = context.languages {
            destination.openProject(root: identity, languages: explicit)
            activateWindow(destination)
            return
        }
        let windowModel = destination.model
        let load = windowModel.loadSessionSnapshot(forProject: identity)
        if let snapshot = load.snapshot {
            destination.restoreSession(snapshot)
            activateWindow(destination)
            return
        }
        if recentProjectsStore.storedLanguagesIfRecorded(
            for: identity.path
        ) != nil {
            destination.openRecentProject(identity)
            activateWindow(destination)
            return
        }
        let picked = await presentLanguageSelection(for: identity)
        guard !isTerminating, let picked else {
            // Cancelled (or terminating): this request's claim is released
            // first so a repeat request starts over. Only the window this
            // request created goes away; a user-created blank window stays
            // (§3.3).
            destination.releaseProjectClaim()
            refreshWindowTitles()
            if autoCreated, destination.isUnclaimedForReuse {
                destination.window?.performClose(nil)
            }
            return
        }
        destination.openProject(root: identity, languages: picked)
        activateWindow(destination)
    }

    private func activateWindow(_ controller: MainWindowController) {
        guard let window = controller.window else { return }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        handleProjectWindowBecameActive(controller)
    }

    /// The one-at-a-time language picker for first opens. Dialog state is
    /// local to the alert, never shared across windows (§6.2). Tests and
    /// self-tests may substitute a scripted picker through the override.
    var languagePickerOverride: (@MainActor (URL) async -> [LanguageID]?)?

    private func presentLanguageSelection(
        for root: URL
    ) async -> [LanguageID]? {
        if let languagePickerOverride {
            return await languagePickerOverride(root)
        }
        let alert = makeLanguageSelectionAlert(for: root)
        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }
        return alert.languageSelection
    }

    /// Directories the file-name probe skips; mirrors the indexer's fixed
    /// skip rules so the preselection matches what will be indexed.
    static let languageProbeSkippedDirectories: Set<String> = [
        ".git", "target", "node_modules", ".build", "venv", ".venv",
        "__pycache__", "dist", "build",
    ]

    /// Entry cap for the read-only filename probe: it terminates on huge
    /// trees without reading file contents or launching providers.
    static let languageProbeEntryLimit = 5_000

    /// Languages to preselect when opening `root` for the first time. A
    /// stored Recents preference wins when present (never the Rust
    /// fallback); otherwise a bounded, cancellable-by-limit filename probe
    /// classifies only the extensions that actually appear. Plain .js/.jsx
    /// files do not select TypeScript.
    static func preselectedLanguages(
        for root: URL,
        storedLanguage: LanguageID?
    ) -> (languages: [LanguageID], probeCapped: Bool) {
        if let storedLanguage {
            return ([storedLanguage], false)
        }
        let allLanguages: [LanguageID] = [.rust, .python, .typescript]
        var found: Set<LanguageID> = []
        var scanned = 0
        var capped = false
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        while let item = enumerator?.nextObject() as? URL {
            scanned += 1
            if scanned > languageProbeEntryLimit {
                capped = true
                break
            }
            if item.pathExtension.isEmpty == false,
               item.lastPathComponent.hasPrefix(".")
            {
                continue
            }
            if item.pathComponents.contains(
                where: { languageProbeSkippedDirectories.contains($0) }
            ) {
                continue
            }
            let name = item.lastPathComponent
            if allLanguages.contains(where: { language in
                LanguageMode.classify(path: name, language: language) != nil
            }) {
                for language in allLanguages
                where LanguageMode.classify(path: name, language: language) != nil
                {
                    found.insert(language)
                }
            }
        }
        let ordered = allLanguages.filter { found.contains($0) }
        return (ordered, capped)
    }

    /// Language picker state lives entirely inside one alert presentation
    /// so a queued second open can never overwrite the visible choice
    /// (§6.2). The gate is the checkbox targets; nothing survives the
    /// modal session.
    @MainActor final class LanguageSelectionGate: NSObject {
        var checkboxes: [NSButton] = []
        weak var openButton: NSButton?

        @objc func checkboxChanged(_ sender: NSButton) {
            openButton?.isEnabled = checkboxes.contains { $0.state == .on }
        }

        var selection: [LanguageID]? {
            var selected: [LanguageID] = []
            if checkboxes.indices.contains(0), checkboxes[0].state == .on {
                selected.append(.rust)
            }
            if checkboxes.indices.contains(1), checkboxes[1].state == .on {
                selected.append(.python)
            }
            if checkboxes.indices.contains(2), checkboxes[2].state == .on {
                selected.append(.typescript)
            }
            guard !selected.isEmpty else { return nil }
            return try? LanguageMode.normalize(languages: selected)
        }
    }

    final class LanguageSelectionAlert: NSAlert {
        var gate = LanguageSelectionGate()

        var languageSelection: [LanguageID]? { gate.selection }
    }

    func makeLanguageSelectionAlert(for root: URL) -> LanguageSelectionAlert {
        let alert = LanguageSelectionAlert()
        alert.messageText = localized("app.open.languages")
        alert.informativeText =
            localizedFormat("app.open.languageDetail", root.lastPathComponent)
        alert.addButton(withTitle: localized("app.open.action"))
        alert.addButton(withTitle: localized("app.cancel"))
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        let options: [String] = [
            "Rust",
            "Python",
            "TypeScript",
        ]
        // §S9: preselect a stored Recents preference when valid, otherwise
        // the languages the bounded filename probe actually found; manual
        // choices stay possible and win once made.
        // A valid stored record wins; the Rust fallback never counts as a
        // user choice (§S9).
        let stored = recentProjectsStore
            .storedLanguagesIfRecorded(for: root.standardizedFileURL.path)?
            .first
        let preselected = Self.preselectedLanguages(
            for: root,
            storedLanguage: stored
        )
        let gate = alert.gate
        gate.checkboxes = options.map { title in
            let checkbox = NSButton(
                checkboxWithTitle: title,
                target: gate,
                action: #selector(
                    LanguageSelectionGate.checkboxChanged(_:)
                )
            )
            checkbox.setAccessibilityLabel(title)
            let language: LanguageID = switch title {
            case "Rust": .rust
            case "Python": .python
            default: .typescript
            }
            checkbox.state = preselected.languages.contains(language)
                ? .on
                : .off
            stack.addArrangedSubview(checkbox)
            return checkbox
        }
        stack.frame.size = stack.fittingSize
        stack.layoutSubtreeIfNeeded()
        alert.accessoryView = stack
        let openButton = alert.buttons[0]
        openButton.isEnabled = !preselected.languages.isEmpty
        gate.openButton = openButton
        return alert
    }

    @objc private func clearRecentProjects(_ sender: Any?) {
        recentProjectsStore.clear()
        windowController?.refreshRecentProjects()
    }

    @objc private func showAbout(_ sender: Any?) {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "dev"
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: "Cairn",
            .applicationVersion: version,
            .credits: NSAttributedString(
                string: localized("app.about.description")
            ),
        ])
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildOpenRecentMenu(menu)
    }

    private func rebuildOpenRecentMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        let paths = recentProjectsStore.paths
        if paths.isEmpty {
            let emptyItem = NSMenuItem(
                title: localized("app.recent.empty"),
                action: nil,
                keyEquivalent: ""
            )
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            for path in paths {
                let item = NSMenuItem(
                    title: URL(fileURLWithPath: path).lastPathComponent,
                    action: #selector(openRecentProject(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = path
                item.toolTip = path
                item.isEnabled = true
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let clearItem = NSMenuItem(
            title: localized("app.recent.clear"),
            action: #selector(clearRecentProjects(_:)),
            keyEquivalent: ""
        )
        clearItem.target = self
        clearItem.isEnabled = !paths.isEmpty
        menu.addItem(clearItem)
    }

    /// Shared trust list state for the Settings window; refreshed after
    /// every grant/revoke so it always reflects the shared registry.
    private(set) lazy var trustListModel = TrustListModel()

    @objc func showSettings(_ sender: Any?) {
        if settingsWindowController == nil {
            settingsWindowController = ReaderSettingsWindowController(
                settings: readerSettings,
                derivedDataStore: readerDerivedDataStore,
                trustModel: trustListModel,
                keyBindingsModel: keyBindingSettingsModel,
                onRevoke: { [weak self] repositoryURL in
                    await self?.revokeRepositoryTrustAppLevel(repositoryURL)
                },
                onClearCache: { [weak self] in
                    await self?.clearMaterializedCacheAppLevel() ?? .failed(localized("app.unavailable"))
                }
            ) { [weak self] settings in
                guard let self else { return }
                commitReaderSettings(settings)
            }
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.trustListModel.refresh(from: self.sharedTrustRegistry)
        }
        settingsWindowController?.update(settings: readerSettings)
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.center()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// Application-level trust revoke (§8.2): stops every window whose
    /// project matches, waits for the providers to exit, then writes the
    /// registry and refreshes all surfaces.
    private func revokeRepositoryTrustAppLevel(_ repositoryURL: URL) async {
        do {
            let canonical = repositoryURL.resolvingSymlinksInPath()
                .standardizedFileURL.path
            // Stop affected projects first; unaffected windows only need
            // their trust lists refreshed afterwards.
            for controller in projectWindows {
                guard let root = controller.projectURL,
                      root.path == canonical
                else { continue }
                try await controller.model.revokeRepositoryTrust(repositoryURL)
            }
            try await sharedTrustRegistry.revoke(repositoryURL)
            for controller in projectWindows {
                await controller.model.exactCoordinator.refreshTrust()
            }
            await trustListModel.refresh(from: sharedTrustRegistry)
        } catch {
            await trustListModel.refresh(from: sharedTrustRegistry)
            presentTrustError(error)
        }
    }

    /// Application-level cache clear (§8.4): stops all projects' Exact
    /// work, waits for their directories to be released, then deletes the
    /// shared cache. Reader/index/tabs/sessions stay untouched.
    func clearMaterializedCacheAppLevel() async -> MaterializedCacheClearOutcome {
        // Maintenance mode spans the whole operation: every coordinator
        // sharing this materializer refuses new prepares until the clear
        // finished (successfully or not), so nothing can claim a directory
        // mid-deletion — including windows created while we wait (§8.4).
        sharedMaterializer.beginMaintenance()
        defer {
            sharedMaterializer.endMaintenance()
            for controller in projectWindows {
                controller.model.restartExactAnalysis()
            }
        }
        do {
            let coordinators = projectWindows.map(\.model.exactCoordinator)
            for coordinator in coordinators {
                await coordinator.stopAllWorkForCacheClear()
            }
            try await sharedMaterializer.clear()
            return .cleared
        } catch {
            return .failed(
                localizedFormat("app.cache.failed", String(describing: error))
            )
        }
    }

    func grantCurrentRepositoryTrustAppLevel(_ targetModel: AppModel) async throws {
        try await targetModel.grantCurrentRepositoryTrust()
        for controller in projectWindows {
            await controller.model.exactCoordinator.refreshTrust()
        }
        await trustListModel.refresh(from: sharedTrustRegistry)
    }

    @objc private func trustThisRepository(_ sender: Any?) {
        // Capture the target window now: after the sheet returns, the
        // user may have switched windows — the confirmation must still
        // apply to (and only to) this project (§6.2).
        guard let controller = projectCommandTarget(),
              let window = controller.window,
              controller.model.canTrustCurrentRepository
        else { return }
        let targetModel = controller.model
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = localized("app.trust.title")
        alert.informativeText = localized("app.trust.detail")
        alert.addButton(withTitle: localized("app.trust.action"))
        alert.addButton(withTitle: localized("app.cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, !controller.isClosing else { return }
            Task { @MainActor in
                guard !controller.isClosing else { return }
                do {
                    try await self?.grantCurrentRepositoryTrustAppLevel(targetModel)
                } catch {
                    // Errors surface in the window that started the
                    // operation; if it is gone, they are dropped rather
                    // than pasted onto another project (§6.2).
                    guard !controller.isClosing else { return }
                    self?.presentTrustError(error, in: window)
                }
            }
        }
    }

    private func presentTrustError(
        _ error: any Error,
        in window: NSWindow? = nil
    ) {
        let alert = NSAlert(error: error)
        // The error belongs to the window that started the operation; if
        // that window is gone it is shown app-modal, never as a sheet on
        // some other project's window (§6.2).
        let targetWindow = window ?? projectCommandTarget()?.window
        if let targetWindow, targetWindow.isVisible {
            alert.beginSheetModal(for: targetWindow)
        } else {
            alert.runModal()
        }
    }

    // MARK: - Menu routing (§6.1)

    /// Resolves the project window a menu action/shortcut applies to:
    /// key window when it is (or belongs to) a project window, otherwise
    /// the main window; global app windows (Settings, About) disable
    /// project commands without falling back.
    func projectCommandTarget() -> MainWindowController? {
        projectCommandTarget(
            keyWindow: NSApplication.shared.keyWindow,
            mainWindow: NSApplication.shared.mainWindow
        )
    }

    /// Resolution core with explicit windows so tests can drive routing
    /// deterministically; production always funnels through the overload
    /// above.
    func projectCommandTarget(
        keyWindow: NSWindow?,
        mainWindow: NSWindow?
    ) -> MainWindowController? {
        if let keyWindow {
            for controller in projectWindows
            where !controller.isClosing && controller.controls(window: keyWindow) {
                return controller
            }
            // A key window owned by this app but not by any project window
            // is a global surface: no project target, no fallback (§6.1.3).
            if NSApplication.shared.windows.contains(keyWindow) {
                return nil
            }
        }
        if let mainWindow {
            for controller in projectWindows
            where !controller.isClosing && controller.controls(window: mainWindow) {
                return controller
            }
        }
        // An inactive application cannot receive user keyboard or menu
        // input, so no user command is being stolen here: programmatic
        // dispatch (self-tests, assistive scripting) targets the most
        // recently active project window instead of nothing (§6.1.5 keeps
        // its no-fallback rule for real key-window input).
        if !NSApplication.shared.isActive {
            if let lastActiveProjectWindow, !lastActiveProjectWindow.isClosing {
                return lastActiveProjectWindow
            }
            return activeWindowOrder.last { !$0.isClosing }
        }
        return nil
    }

    /// ⌘N: a fresh blank welcome window; never auto-restores (§6.3).
    @objc private func newWindow(_ sender: Any?) {
        createBlankWindow()
    }

    /// ⇧⌘W: close the routed project window itself.
    @objc private func closeProjectWindow(_ sender: Any?) {
        projectCommandTarget()?.window?.performClose(nil)
    }

    @objc private func openSymbol(_ sender: Any?) {
        projectCommandTarget()?.showSymbolSearch()
    }

    @objc private func quickOpen(_ sender: Any?) {
        projectCommandTarget()?.showPalette()
    }

    @objc private func openCommandPalette(_ sender: Any?) {
        projectCommandTarget()?.showPalette(prefill: ">")
    }

    @objc private func jumpToTypeDefinition(_ sender: Any?) {
        projectCommandTarget()?.jumpToTypeDefinitionAtCaret()
    }

    @objc private func openToSide(_ sender: Any?) {
        projectCommandTarget()?.openCurrentFileToSide()
    }

    @objc private func closeSplit(_ sender: Any?) {
        projectCommandTarget()?.closeReference()
    }

    @objc private func showExclusionRules(_ sender: Any?) {
        projectCommandTarget()?.showExclusionRules()
    }

    @objc private func toggleHighlight(_ sender: Any?) {
        projectCommandTarget()?.toggleHighlightAtCaret()
    }

    @objc private func clearHighlights(_ sender: Any?) {
        projectCommandTarget()?.clearHighlights()
    }

    @objc private func jumpToMatchingBracket(_ sender: Any?) {
        projectCommandTarget()?.jumpToMatchingBracket()
    }

    @objc private func selectInsideBrackets(_ sender: Any?) {
        projectCommandTarget()?.selectInsideBrackets()
    }

    @objc private func goToLine(_ sender: Any?) {
        projectCommandTarget()?.showPalette(prefill: ":")
    }

    @objc private func findInProject(_ sender: Any?) {
        projectCommandTarget()?.showProjectSearch()
    }

    @objc private func nextProjectSearchResult(_ sender: Any?) {
        projectCommandTarget()?.nextProjectSearchResult()
    }

    @objc private func previousProjectSearchResult(_ sender: Any?) {
        projectCommandTarget()?.previousProjectSearchResult()
    }

    @objc private func toggleProjectSearchResults(_ sender: Any?) {
        projectCommandTarget()?.toggleProjectSearchResults()
    }

    @objc private func findInFile(_ sender: Any?) {
        _ = projectCommandTarget()?.showFindBar()
    }

    @objc private func findNext(_ sender: Any?) {
        projectCommandTarget()?.findNextMatch()
    }

    @objc private func findPrevious(_ sender: Any?) {
        projectCommandTarget()?.findPreviousMatch()
    }

    @objc func openSelectedFileInNewTab(_ sender: Any?) {
        projectCommandTarget()?.openSelectedFileInNewTab()
    }

    @objc func closeActiveTab(_ sender: Any?) {
        guard let target = projectCommandTarget() else { return }
        if target.model.tabStrip.tabs.isEmpty {
            // ⌘W with nothing to close falls through to the window (§6.3).
            target.window?.performClose(nil)
        } else {
            target.closeActiveTab()
        }
    }

    @objc private func refreshProjectIndex(_ sender: Any?) {
        projectCommandTarget()?.refreshProjectIndex(sender)
    }

    @objc func selectPreviousTab(_ sender: Any?) {
        projectCommandTarget()?.selectPreviousTab()
    }

    @objc func selectNextTab(_ sender: Any?) {
        projectCommandTarget()?.selectNextTab()
    }

    @objc private func trackLensSymbol(_ sender: Any?) {
        projectCommandTarget()?.setLensTracking(.symbol)
    }

    @objc private func trackLensEnclosing(_ sender: Any?) {
        projectCommandTarget()?.setLensTracking(.enclosing)
    }

    @objc private func toggleLensPin(_ sender: Any?) {
        projectCommandTarget()?.toggleLensPin()
    }

    @objc private func previousContextCandidate(_ sender: Any?) {
        projectCommandTarget()?.selectPreviousContextCandidate(sender)
    }

    @objc private func nextContextCandidate(_ sender: Any?) {
        projectCommandTarget()?.selectNextContextCandidate(sender)
    }

    @objc private func goBack(_ sender: Any?) {
        projectCommandTarget()?.goBack(sender)
    }

    @objc private func goForward(_ sender: Any?) {
        projectCommandTarget()?.goForward(sender)
    }

    @objc private func previousDiffHunk(_ sender: Any?) {
        projectCommandTarget()?.previousDiffHunk(sender)
    }

    @objc private func nextDiffHunk(_ sender: Any?) {
        projectCommandTarget()?.nextDiffHunk(sender)
    }

    @objc private func closeComparison(_ sender: Any?) {
        projectCommandTarget()?.closeComparison()
    }

    @objc private func toggleRelations(_ sender: Any?) {
        projectCommandTarget()?.toggleRelations()
    }

    @objc private func applyPanelPreset(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let preset = PanelPresetModel(rawValue: rawValue)
        else { return }
        projectCommandTarget()?.applyPanelPreset(preset)
    }

    @objc private func showCallers(_ sender: Any?) {
        projectCommandTarget()?.showRelations(direction: .callers)
    }

    @objc private func showCalls(_ sender: Any?) {
        projectCommandTarget()?.showRelations(direction: .calls)
    }

    @objc private func showImplementations(_ sender: Any?) {
        projectCommandTarget()?.showRelations(direction: .implementations)
    }

    @objc func showResolutionInspector(_ sender: Any?) {
        projectCommandTarget()?.showResolutionInspector()
    }

    @objc private func showSymbolDocumentation(_ sender: Any?) {
        projectCommandTarget()?.showSymbolDocumentationAtSelection()
    }

    @objc func showReadingTrail(_ sender: Any?) {
        projectCommandTarget()?.showReadingTrail()
    }

    @objc private func toggleFold(_ sender: Any?) {
        _ = projectCommandTarget()?.toggleFoldAtSelection()
    }

    @objc func toggleBookmark(_ sender: Any?) {
        projectCommandTarget()?.toggleBookmark()
    }

    @objc func showBookmarks(_ sender: Any?) {
        projectCommandTarget()?.showBookmarks()
    }

    @objc func closeBookmarks(_ sender: Any?) {
        projectCommandTarget()?.closeBookmarks()
    }

    @objc func useFullReadingHeight(_ sender: Any?) {
        _ = projectCommandTarget()?.setReadingHeightLevel(.full)
    }

    @objc private func useStructureReadingHeight(_ sender: Any?) {
        _ = projectCommandTarget()?.setReadingHeightLevel(.structure)
    }

    @objc private func useOverviewReadingHeight(_ sender: Any?) {
        _ = projectCommandTarget()?.setReadingHeightLevel(.overview)
    }

    @objc private func focusCurrentScope(_ sender: Any?) {
        _ = projectCommandTarget()?.toggleFocusCurrentScope()
    }

    @objc func increaseReaderFontSize(_ sender: Any?) {
        changeReaderFontSize(by: 1)
    }

    @objc func decreaseReaderFontSize(_ sender: Any?) {
        changeReaderFontSize(by: -1)
    }

    private func changeReaderFontSize(by delta: Double) {
        var settings = readerSettings
        let previous = settings.fontSize
        settings.fontSize += delta
        guard settings.fontSize != previous else { return }
        commitReaderSettings(settings)
    }

    /// View → Wrap Lines, ⌥Z (reader-wrap design D1.1, decision C1). Wrap is
    /// an application-level reading preference: the action works regardless
    /// of which window is key and never routes through a project target.
    @objc private func toggleWrapLines(_ sender: Any?) {
        var settings = readerSettings
        settings.wrapLines.toggle()
        commitReaderSettings(settings)
    }

    // Option-only key equivalents are consumed by NSTextView's text input
    // before reaching the menu; `handleMonitoredKeyEquivalent` (key binding
    // table, K0a) handles every option-only chord, ⌥Z included.

    func commitReaderSettings(_ settings: ReaderSettings) {
        readerSettings = settings
        applyApplicationAppearance()
        settings.save(to: .standard)
        // Reader preferences are global: every project window follows (§6.4).
        for controller in projectWindows {
            controller.applyReaderSettings(settings)
        }
        settingsWindowController?.update(settings: settings)
    }

    private func applyApplicationAppearance() {
        NSApplication.shared.appearance = switch readerSettings.theme {
        case .dark: NSAppearance(named: .darkAqua)
        case .light, .siClassic: NSAppearance(named: .aqua)
        case .auto: nil
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // Same routed target the action itself uses (§6.1): a global key
        // window disables project commands entirely.
        let target = projectCommandTarget()
        let model = target?.model
        switch menuItem.action {
        case #selector(refreshProjectIndex(_:)), #selector(showExclusionRules(_:)):
            return target?.canRefreshIndex == true
        case #selector(findInFile(_:)), #selector(findNext(_:)),
            #selector(findPrevious(_:)):
            return target?.canFindInFile == true
        case #selector(toggleHighlight(_:)), #selector(jumpToMatchingBracket(_:)),
            #selector(selectInsideBrackets(_:)):
            return target?.canFindInFile == true
        case #selector(clearHighlights(_:)):
            return target?.hasHighlights == true
        case #selector(goBack(_:)):
            return target?.canGoBack == true
        case #selector(goForward(_:)):
            return target?.canGoForward == true
        case #selector(openToSide(_:)):
            return target?.canOpenCurrentFileToSide == true
        case #selector(closeSplit(_:)):
            return target?.hasReferencePane == true
        case #selector(previousDiffHunk(_:)), #selector(nextDiffHunk(_:)):
            return !(model?.compare.diff?.hunks.isEmpty ?? true)
        case #selector(closeComparison(_:)):
            return target?.canCloseComparison == true
        case #selector(showCallers(_:)),
            #selector(showCalls(_:)),
            #selector(showImplementations(_:)):
            return target?.canShowRelationsFromReaderSurface == true
        case #selector(showResolutionInspector(_:)):
            return target?.canShowResolutionInspector == true
        case #selector(showSymbolDocumentation(_:)):
            return target?.canShowSymbolDocumentation == true
        case #selector(showReadingTrail(_:)):
            return target?.canShowReadingTrail == true
        case #selector(toggleFold(_:)):
            return target?.canToggleFoldAtSelection == true
        case #selector(toggleBookmark(_:)):
            let help = target?.bookmarkCommandAccessibilityHelp
            menuItem.toolTip = help
            menuItem.setAccessibilityHelp(help)
            return target?.canToggleBookmark == true
        case #selector(showBookmarks(_:)), #selector(applyPanelPreset(_:)),
            #selector(toggleRelations(_:)), #selector(previousContextCandidate(_:)),
            #selector(nextContextCandidate(_:)):
            return target != nil
        case #selector(closeBookmarks(_:)):
            return target?.bookmarksPanelIsVisible == true
        case #selector(useFullReadingHeight(_:)):
            menuItem.state =
                target?.readingHeightLevel == .full
                ? .on : .off
            return target != nil
        case #selector(useStructureReadingHeight(_:)):
            menuItem.state =
                target?.readingHeightLevel == .structure
                ? .on : .off
            return target != nil
        case #selector(useOverviewReadingHeight(_:)):
            menuItem.state =
                target?.readingHeightLevel == .overview
                ? .on : .off
            return target != nil
        case #selector(focusCurrentScope(_:)):
            menuItem.state = target?.isFocusMode == true ? .on : .off
            return target?.canFocusCurrentScope == true
        case #selector(toggleWrapLines(_:)):
            // Application-level setting (D1.1/E1): stays available when the
            // Settings window or the welcome window is key, with no project
            // command target; the checkmark reads the same global value the
            // Settings form and the reader surfaces use.
            menuItem.state = readerSettings.wrapLines ? .on : .off
            return true
        case #selector(increaseReaderFontSize(_:)):
            return readerSettings.fontSize < ReaderSettings.fontSizeRange.upperBound
        case #selector(decreaseReaderFontSize(_:)):
            return readerSettings.fontSize > ReaderSettings.fontSizeRange.lowerBound
        case #selector(trustThisRepository(_:)):
            return model?.canTrustCurrentRepository == true
        case #selector(openSelectedFileInNewTab(_:)):
            return target?.selectedSidebarFile != nil
        case #selector(closeActiveTab(_:)):
            // Always available on a project window: no tabs left means it
            // closes the window (§6.3).
            return target != nil
        case #selector(closeProjectWindow(_:)):
            return target != nil
        case #selector(selectPreviousTab(_:)), #selector(selectNextTab(_:)):
            return (model?.tabStrip.tabs.count ?? 0) > 1
        case #selector(clearReadingSession(_:)):
            return model?.projectRoot != nil
        case #selector(quickOpen(_:)), #selector(openCommandPalette(_:)),
            #selector(goToLine(_:)), #selector(findInProject(_:)),
            #selector(nextProjectSearchResult(_:)), #selector(previousProjectSearchResult(_:)),
            #selector(toggleProjectSearchResults(_:)),
            #selector(openSymbol(_:)):
            return target != nil
        default:
            return true
        }
    }

    // MARK: Key binding table (K0a)

    /// Effective bindings: the default scheme plus the user override layer.
    /// Every menu item, hidden alternate, toolbar menu representation, reader
    /// gesture, and option-only key monitor resolves through this table.
    var keyBindingTable = KeyBindingTable(scheme: .default)
    /// K-R1.4/K-R3.7: overrides persist globally and every window shares the
    /// committed table.
    private let keyBindingStore = KeyBindingStore(defaults: .standard)

    /// Loads persisted overrides into the effective table at init.
    private func loadKeyBindingOverrides() {
        var table = keyBindingTable
        for (id, bindings) in keyBindingStore.load() {
            table.setBindings(bindings, for: id)
        }
        keyBindingTable = table
    }

    /// K-R3.6: applies a new table everywhere — persists the override layer,
    /// rebuilds the main menu (hidden alternates included), and refreshes
    /// every window's gesture/toolbar references and the settings page.
    func applyKeyBindings(_ table: KeyBindingTable) {
        keyBindingTable = table
        keyBindingStore.save(table.overrides)
        keyBindingSettingsModel.applyCommitted(table)
        NSApplication.shared.mainMenu = makeMainMenu()
        for controller in projectWindows {
            controller.applyKeyBindings()
        }
    }

    /// Settings-page state for the key bindings tab; commits flow back
    /// through `applyKeyBindings`.
    private(set) lazy var keyBindingSettingsModel = KeyBindingSettingsModel(
        table: keyBindingTable,
        onCommit: { [weak self] table in
            self?.applyKeyBindings(table)
        }
    )

    /// One command's dispatch: the selector plus where the action goes. The
    /// key monitor (`handleMonitoredKeyEquivalent`) uses the same mapping as
    /// the menu factory so a recorded ⌥-only chord dispatches identically.
    private struct CommandAction {
        enum Target {
            case delegate
            case responderChain
            case application
        }

        let selector: Selector?
        let target: Target
        let representedObject: String?

        init(
            _ selector: Selector?,
            _ target: Target = .delegate,
            representedObject: String? = nil
        ) {
            self.selector = selector
            self.target = target
            self.representedObject = representedObject
        }
    }

    private static let commandActions: [CommandID: CommandAction] = [
        .appAbout: CommandAction(#selector(AppDelegate.showAbout(_:))),
        .appSettings: CommandAction(#selector(AppDelegate.showSettings(_:))),
        .appQuit: CommandAction(#selector(NSApplication.terminate(_:)), .application),
        .fileOpenProject: CommandAction(#selector(AppDelegate.openProject(_:))),
        .fileNewWindow: CommandAction(#selector(AppDelegate.newWindow(_:))),
        .fileQuickOpen: CommandAction(#selector(AppDelegate.quickOpen(_:))),
        .fileOpenPythonProject: CommandAction(#selector(AppDelegate.openPythonProject(_:))),
        .fileOpenTypeScriptProject: CommandAction(#selector(AppDelegate.openTypeScriptProject(_:))),
        .fileOpenInNewTab: CommandAction(#selector(AppDelegate.openSelectedFileInNewTab(_:))),
        .fileCloseTab: CommandAction(#selector(AppDelegate.closeActiveTab(_:))),
        .fileCloseWindow: CommandAction(#selector(AppDelegate.closeProjectWindow(_:))),
        .fileClearReadingSession: CommandAction(#selector(AppDelegate.clearReadingSession(_:))),
        .fileRefreshIndex: CommandAction(#selector(AppDelegate.refreshProjectIndex(_:))),
        .fileTrustRepository: CommandAction(#selector(AppDelegate.trustThisRepository(_:))),
        .editCut: CommandAction(#selector(NSText.cut(_:)), .responderChain),
        .editCopy: CommandAction(#selector(NSText.copy(_:)), .responderChain),
        .editPaste: CommandAction(#selector(NSText.paste(_:)), .responderChain),
        .editSelectAll: CommandAction(#selector(NSText.selectAll(_:)), .responderChain),
        .findInFile: CommandAction(#selector(AppDelegate.findInFile(_:))),
        .findNext: CommandAction(#selector(AppDelegate.findNext(_:))),
        .findPrevious: CommandAction(#selector(AppDelegate.findPrevious(_:))),
        .findInProject: CommandAction(#selector(AppDelegate.findInProject(_:))),
        .nextProjectSearchResult: CommandAction(#selector(AppDelegate.nextProjectSearchResult(_:))),
        .previousProjectSearchResult: CommandAction(#selector(AppDelegate.previousProjectSearchResult(_:))),
        .toggleProjectSearchResults: CommandAction(#selector(AppDelegate.toggleProjectSearchResults(_:))),
        .goCommandPalette: CommandAction(#selector(AppDelegate.openCommandPalette(_:))),
        .goOpenSymbol: CommandAction(#selector(AppDelegate.openSymbol(_:))),
        .goToLine: CommandAction(#selector(AppDelegate.goToLine(_:))),
        .goBack: CommandAction(#selector(AppDelegate.goBack(_:))),
        .goForward: CommandAction(#selector(AppDelegate.goForward(_:))),
        .goPreviousTab: CommandAction(#selector(AppDelegate.selectPreviousTab(_:))),
        .goNextTab: CommandAction(#selector(AppDelegate.selectNextTab(_:))),
        .goPreviousDiffHunk: CommandAction(#selector(AppDelegate.previousDiffHunk(_:))),
        .goNextDiffHunk: CommandAction(#selector(AppDelegate.nextDiffHunk(_:))),
        .navigateTypeDefinition: CommandAction(#selector(AppDelegate.jumpToTypeDefinition(_:))),
        .fileExclusionRules: CommandAction(#selector(AppDelegate.showExclusionRules(_:))),
        .viewOpenToSide: CommandAction(#selector(AppDelegate.openToSide(_:))),
        .viewCloseSplit: CommandAction(#selector(AppDelegate.closeSplit(_:))),
        .findToggleHighlight: CommandAction(#selector(AppDelegate.toggleHighlight(_:))),
        .findClearHighlights: CommandAction(#selector(AppDelegate.clearHighlights(_:))),
        .goMatchingBracket: CommandAction(#selector(AppDelegate.jumpToMatchingBracket(_:))),
        .goSelectInsideBrackets: CommandAction(#selector(AppDelegate.selectInsideBrackets(_:))),
        .viewPresetReading: CommandAction(
            #selector(AppDelegate.applyPanelPreset(_:)),
            representedObject: PanelPresetModel.reading.rawValue
        ),
        .viewPresetRelations: CommandAction(
            #selector(AppDelegate.applyPanelPreset(_:)),
            representedObject: PanelPresetModel.relations.rawValue
        ),
        .viewPresetCompare: CommandAction(
            #selector(AppDelegate.applyPanelPreset(_:)),
            representedObject: PanelPresetModel.compare.rawValue
        ),
        .viewPresetFocus: CommandAction(
            #selector(AppDelegate.applyPanelPreset(_:)),
            representedObject: PanelPresetModel.focus.rawValue
        ),
        .viewCloseComparison: CommandAction(#selector(AppDelegate.closeComparison(_:))),
        .viewToggleFold: CommandAction(#selector(AppDelegate.toggleFold(_:))),
        .viewReadingHeightFull: CommandAction(#selector(AppDelegate.useFullReadingHeight(_:))),
        .viewReadingHeightStructure: CommandAction(
            #selector(AppDelegate.useStructureReadingHeight(_:))
        ),
        .viewReadingHeightOverview: CommandAction(
            #selector(AppDelegate.useOverviewReadingHeight(_:))
        ),
        .viewFocusCurrentScope: CommandAction(#selector(AppDelegate.focusCurrentScope(_:))),
        .viewToggleBookmark: CommandAction(#selector(AppDelegate.toggleBookmark(_:))),
        .viewShowBookmarks: CommandAction(#selector(AppDelegate.showBookmarks(_:))),
        .viewHideBookmarks: CommandAction(#selector(AppDelegate.closeBookmarks(_:))),
        .viewIncreaseFontSize: CommandAction(#selector(AppDelegate.increaseReaderFontSize(_:))),
        .viewDecreaseFontSize: CommandAction(#selector(AppDelegate.decreaseReaderFontSize(_:))),
        .viewWrapLines: CommandAction(#selector(AppDelegate.toggleWrapLines(_:))),
        .viewShowReadingTrail: CommandAction(#selector(AppDelegate.showReadingTrail(_:))),
        .relationsToggle: CommandAction(#selector(AppDelegate.toggleRelations(_:))),
        .relationsShowCallers: CommandAction(#selector(AppDelegate.showCallers(_:))),
        .relationsShowCalls: CommandAction(#selector(AppDelegate.showCalls(_:))),
        .relationsShowImplementations: CommandAction(
            #selector(AppDelegate.showImplementations(_:))
        ),
        .relationsShowSymbolDocumentation: CommandAction(
            #selector(AppDelegate.showSymbolDocumentation(_:))
        ),
        .relationsShowResolutionInspector: CommandAction(
            #selector(AppDelegate.showResolutionInspector(_:))
        ),
        .lensPreviousCandidate: CommandAction(
            #selector(AppDelegate.previousContextCandidate(_:))
        ),
        .lensTrackSymbol: CommandAction(#selector(AppDelegate.trackLensSymbol(_:))),
        .lensTrackEnclosing: CommandAction(#selector(AppDelegate.trackLensEnclosing(_:))),
        .lensTogglePin: CommandAction(#selector(AppDelegate.toggleLensPin(_:))),
        .lensNextCandidate: CommandAction(#selector(AppDelegate.nextContextCandidate(_:))),
    ]

    /// Menu item whose title and first keyboard binding come from the key
    /// binding table (K0a).
    private func menuItem(for id: CommandID) -> NSMenuItem? {
        guard let definition = keyBindingTable.definition(for: id),
              let action = Self.commandActions[id]
        else { return nil }
        let item = NSMenuItem(
            title: localized(definition.titleKey),
            action: action.selector,
            keyEquivalent: ""
        )
        if case let .keyboard(chord)? = keyBindingTable.bindings(for: id).first {
            item.applyKeyChord(chord)
        }
        switch action.target {
        case .delegate: item.target = self
        case .application: item.target = NSApplication.shared
        case .responderChain: break
        }
        item.representedObject = action.representedObject
        return item
    }

    /// Hidden carriers for a command's second and later keyboard bindings
    /// (⌘[ / ⌘] for Back/Forward): `isHidden` plus
    /// `allowsKeyEquivalentWhenHidden`, matching the pre-migration approach.
    private func hiddenAlternateMenuItems(for id: CommandID) -> [NSMenuItem] {
        guard let definition = keyBindingTable.definition(for: id),
              let action = Self.commandActions[id]
        else { return [] }
        return keyBindingTable.bindings(for: id).dropFirst().compactMap { binding in
            guard case let .keyboard(chord) = binding else { return nil }
            let item = NSMenuItem(
                title: localized(definition.titleKey),
                action: action.selector,
                keyEquivalent: ""
            )
            item.applyKeyChord(chord)
            switch action.target {
            case .delegate: item.target = self
            case .application: item.target = NSApplication.shared
            case .responderChain: break
            }
            item.representedObject = action.representedObject
            item.isHidden = true
            item.allowsKeyEquivalentWhenHidden = true
            return item
        }
    }

    private func appendMenuItem(for id: CommandID, to menu: NSMenu) {
        if let item = menuItem(for: id) { menu.addItem(item) }
        for alternate in hiddenAlternateMenuItems(for: id) { menu.addItem(alternate) }
    }

    /// Dispatches a command outside menu matching — the option-only key
    /// monitor path. Validation mirrors menu activation.
    func performCommand(_ id: CommandID) -> Bool {
        guard let action = Self.commandActions[id], let selector = action.selector else {
            return false
        }
        let sender = NSMenuItem()
        sender.action = selector
        sender.representedObject = action.representedObject
        switch action.target {
        case .delegate:
            sender.target = self
            guard validateMenuItem(sender) else { return false }
            perform(selector, with: sender)
        case .application:
            NSApplication.shared.perform(selector, with: sender)
        case .responderChain:
            NSApp.sendAction(selector, to: nil, from: sender)
        }
        return true
    }

    /// Option-only chords (⌥ or ⌥⇧, never ⌘/⌃) never match a menu item
    /// because Option changes the typed character (⌥Z → Ω). Handle them here,
    /// before responder dispatch, including while Settings owns the key
    /// window. Every option-only keyboard binding in the table dispatches,
    /// not just ⌥Z (K0a generalizes `handleWrapKeyEquivalent`).
    func handleMonitoredKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard flags.contains(.option), flags.isDisjoint(with: [.command, .control]) else {
            return false
        }
        for command in keyBindingTable.commands {
            for binding in keyBindingTable.bindings(for: command.id) {
                guard case let .keyboard(chord) = binding,
                      chord.modifiers.contains(.option),
                      chord.modifiers.isDisjoint(with: [.command, .control]),
                      chord.matches(event)
                else { continue }
                if !event.isARepeat { _ = performCommand(command.id) }
                return true
            }
        }
        return false
    }

    /// Internal for the menu wiring tests: the wrap command must stay
    /// reachable and checkable without any project window (D1.1).
    /// Item titles and keyboard bindings all come from the key binding table
    /// (K0a); second bindings become hidden alternate items.
    func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Cairn")
        appendMenuItem(for: .appAbout, to: appMenu)
        appMenu.addItem(.separator())
        appendMenuItem(for: .appSettings, to: appMenu)
        appMenu.addItem(.separator())
        appendMenuItem(for: .appQuit, to: appMenu)
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: localized("app.menu.file"))
        appendMenuItem(for: .fileOpenProject, to: fileMenu)
        appendMenuItem(for: .fileNewWindow, to: fileMenu)
        appendMenuItem(for: .fileOpenPythonProject, to: fileMenu)
        appendMenuItem(for: .fileOpenTypeScriptProject, to: fileMenu)
        appendMenuItem(for: .fileQuickOpen, to: fileMenu)
        let recentItem = NSMenuItem(
            title: localized("app.menu.open.recent"),
            action: nil,
            keyEquivalent: ""
        )
        let recentMenu = NSMenu(title: localized("app.menu.open.recent"))
        recentMenu.delegate = self
        rebuildOpenRecentMenu(recentMenu)
        recentItem.submenu = recentMenu
        fileMenu.addItem(recentItem)
        appendMenuItem(for: .fileOpenInNewTab, to: fileMenu)
        appendMenuItem(for: .fileCloseTab, to: fileMenu)
        appendMenuItem(for: .fileCloseWindow, to: fileMenu)
        appendMenuItem(for: .fileClearReadingSession, to: fileMenu)
        fileMenu.addItem(.separator())
        appendMenuItem(for: .fileRefreshIndex, to: fileMenu)
        appendMenuItem(for: .fileExclusionRules, to: fileMenu)
        fileMenu.addItem(.separator())
        appendMenuItem(for: .fileTrustRepository, to: fileMenu)
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        // Without an Edit menu, Cmd+C/Cmd+A have no key-equivalent route in a
        // programmatic menu bar (found by interactive walkthrough T3.4).
        // Actions target nil so the responder chain (reader text view, search
        // field) handles them.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: localized("app.menu.edit"))
        appendMenuItem(for: .editCut, to: editMenu)
        appendMenuItem(for: .editCopy, to: editMenu)
        appendMenuItem(for: .editPaste, to: editMenu)
        editMenu.addItem(.separator())
        appendMenuItem(for: .editSelectAll, to: editMenu)
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let findItem = NSMenuItem()
        let findMenu = NSMenu(title: localized("app.menu.find"))
        appendMenuItem(for: .findInFile, to: findMenu)
        appendMenuItem(for: .findNext, to: findMenu)
        appendMenuItem(for: .findPrevious, to: findMenu)
        findMenu.addItem(.separator())
        appendMenuItem(for: .findInProject, to: findMenu)
        appendMenuItem(for: .nextProjectSearchResult, to: findMenu)
        appendMenuItem(for: .previousProjectSearchResult, to: findMenu)
        appendMenuItem(for: .toggleProjectSearchResults, to: findMenu)
        findMenu.addItem(.separator())
        appendMenuItem(for: .findToggleHighlight, to: findMenu)
        appendMenuItem(for: .findClearHighlights, to: findMenu)
        findItem.submenu = findMenu
        mainMenu.addItem(findItem)

        let goItem = NSMenuItem()
        let goMenu = NSMenu(title: localized("app.menu.go"))
        appendMenuItem(for: .goCommandPalette, to: goMenu)
        appendMenuItem(for: .goOpenSymbol, to: goMenu)
        appendMenuItem(for: .goToLine, to: goMenu)
        appendMenuItem(for: .navigateTypeDefinition, to: goMenu)
        appendMenuItem(for: .goMatchingBracket, to: goMenu)
        appendMenuItem(for: .goSelectInsideBrackets, to: goMenu)
        goMenu.addItem(.separator())
        // Back/Forward keep the migrated menu order: both visible items
        // first, then both hidden alternate items (⌘[ / ⌘]).
        if let backItem = menuItem(for: .goBack) { goMenu.addItem(backItem) }
        if let forwardItem = menuItem(for: .goForward) { goMenu.addItem(forwardItem) }
        for alternate in hiddenAlternateMenuItems(for: .goBack) { goMenu.addItem(alternate) }
        for alternate in hiddenAlternateMenuItems(for: .goForward) { goMenu.addItem(alternate) }
        appendMenuItem(for: .goPreviousTab, to: goMenu)
        appendMenuItem(for: .goNextTab, to: goMenu)
        goMenu.addItem(.separator())
        appendMenuItem(for: .lensPreviousCandidate, to: goMenu)
        appendMenuItem(for: .lensNextCandidate, to: goMenu)
        appendMenuItem(for: .lensTrackSymbol, to: goMenu)
        appendMenuItem(for: .lensTrackEnclosing, to: goMenu)
        appendMenuItem(for: .lensTogglePin, to: goMenu)
        goMenu.addItem(.separator())
        appendMenuItem(for: .goPreviousDiffHunk, to: goMenu)
        appendMenuItem(for: .goNextDiffHunk, to: goMenu)
        goItem.submenu = goMenu
        mainMenu.addItem(goItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: localized("app.menu.view"))
        let presetItem = NSMenuItem(title: localized("app.menu.preset"), action: nil, keyEquivalent: "")
        let presetMenu = NSMenu(title: localized("app.menu.preset"))
        let presets: [(PanelPresetModel, CommandID)] = [
            (.reading, .viewPresetReading),
            (.relations, .viewPresetRelations),
            (.compare, .viewPresetCompare),
            (.focus, .viewPresetFocus),
        ]
        for (_, id) in presets {
            if let item = menuItem(for: id) { presetMenu.addItem(item) }
        }
        presetItem.submenu = presetMenu
        viewMenu.addItem(presetItem)
        appendMenuItem(for: .viewCloseComparison, to: viewMenu)
        appendMenuItem(for: .viewOpenToSide, to: viewMenu)
        appendMenuItem(for: .viewCloseSplit, to: viewMenu)
        viewMenu.addItem(.separator())
        let foldingItem = NSMenuItem(
            title: localized("app.menu.folding"),
            action: nil,
            keyEquivalent: ""
        )
        let foldingMenu = NSMenu(title: localized("app.menu.folding"))
        // ⌘⇧[ is already Previous Tab. P0 explicitly permits a non-conflicting
        // replacement, so keep the bracket mnemonic with ⌃⌘[.
        appendMenuItem(for: .viewToggleFold, to: foldingMenu)
        appendMenuItem(for: .viewReadingHeightFull, to: foldingMenu)
        appendMenuItem(for: .viewReadingHeightStructure, to: foldingMenu)
        appendMenuItem(for: .viewReadingHeightOverview, to: foldingMenu)
        foldingMenu.addItem(.separator())
        appendMenuItem(for: .viewFocusCurrentScope, to: foldingMenu)
        foldingItem.submenu = foldingMenu
        viewMenu.addItem(foldingItem)
        viewMenu.addItem(.separator())
        appendMenuItem(for: .viewToggleBookmark, to: viewMenu)
        appendMenuItem(for: .viewShowBookmarks, to: viewMenu)
        appendMenuItem(for: .viewHideBookmarks, to: viewMenu)
        viewMenu.addItem(.separator())
        appendMenuItem(for: .viewIncreaseFontSize, to: viewMenu)
        appendMenuItem(for: .viewDecreaseFontSize, to: viewMenu)
        appendMenuItem(for: .viewWrapLines, to: viewMenu)
        viewMenu.addItem(.separator())
        appendMenuItem(for: .viewShowReadingTrail, to: viewMenu)
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        let relationsItem = NSMenuItem()
        let relationsMenu = NSMenu(title: localized("app.menu.relations"))
        appendMenuItem(for: .relationsToggle, to: relationsMenu)
        relationsMenu.addItem(.separator())
        appendMenuItem(for: .relationsShowCallers, to: relationsMenu)
        appendMenuItem(for: .relationsShowCalls, to: relationsMenu)
        appendMenuItem(for: .relationsShowImplementations, to: relationsMenu)
        relationsMenu.addItem(.separator())
        appendMenuItem(for: .relationsShowSymbolDocumentation, to: relationsMenu)
        appendMenuItem(for: .relationsShowResolutionInspector, to: relationsMenu)
        relationsItem.submenu = relationsMenu
        mainMenu.addItem(relationsItem)

        // System window menu: switching, minimizing, Bring All to Front
        // (§6.3). The same instance must back the menu bar item and
        // NSApplication.windowsMenu so AppKit populates it once.
        let windowMenuItem = NSMenuItem()
        let windowMenu = makeWindowMenu()
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApplication.shared.windowsMenu = windowMenu

        return mainMenu
    }

    private func makeWindowMenu() -> NSMenu {
        let windowMenu = NSMenu(title: localized("app.menu.window"))
        windowMenu.autoenablesItems = true
        return windowMenu
    }

    static func menuItems(in menu: NSMenu?) -> [NSMenuItem] {
        guard let menu else { return [] }
        return menu.items.flatMap { item in
            [item] + menuItems(in: item.submenu)
        }
    }
}
