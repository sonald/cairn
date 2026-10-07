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

/// Runs the requested self-test or performance mode. Returns false when the
/// arguments ask for a normal launch.
@MainActor
func launchSelfTestIfRequested(
    startedAt: ContinuousClock.Instant,
    arguments: [String]
) -> Bool {
    let runsSelfTest = arguments.contains {
        $0.hasPrefix("--self-test") || $0.hasPrefix("--fold-perf")
    }
    guard runsSelfTest else { return false }
    if arguments.contains("--self-test-readonly") {
        _ = NSApplication.shared
        runReadonlyWorkloadSelfTest(arguments: arguments)
    }
    if arguments.contains("--self-test-ligatures") {
        _ = NSApplication.shared
        runLigatureSelfTest(arguments: arguments)
    }
    let foldPerformanceRequested = arguments.contains("--fold-perf-mode")
    let foldPerformance = foldPerformanceArguments(arguments)
    if foldPerformanceRequested, foldPerformance == nil {
        FileHandle.standardError.write(Data(
            (
                "usage: codeinsight-app --fold-perf-mode <control|fold> "
                    + "--fold-perf-fixture <path> --fold-perf-out <json>\n"
            ).utf8
        ))
        Darwin.exit(2)
    }
    let wrapPerformanceRequested = arguments.contains("--self-test-wrap")
    let wrapPerformance = wrapPerformanceRequested
        ? wrapPerformanceArguments(arguments)
        : nil
    if wrapPerformanceRequested, wrapPerformance == nil {
        let usage = "usage: codeinsight-app --self-test-wrap --fixture <path> --wrap <on|off> --scenario <initial|toggle|resize|reading-set> --output <json> [--code-sha <sha>] [--warmup N] [--samples N] [--font-postscript NAME] [--ligature-mode fontDefault|enabled|disabled]\n"
        FileHandle.standardError.write(Data(usage.utf8))
        Darwin.exit(2)
    }
    let relationTimingRequested =
        arguments.contains("--self-test-relation-timing")
    let relationTimingTarget = relationTimingArguments(arguments)
    if relationTimingRequested, relationTimingTarget == nil {
        FileHandle.standardError.write(Data(
            (
                "usage: codeinsight-app --self-test-relation-timing "
                    + "<project-root> <relative-file> <utf8-byte-offset> "
                    + "<fake|real>\n"
            ).utf8
        ))
        Darwin.exit(2)
    }
    if let index = arguments.firstIndex(of: "--self-test-switch"),
       arguments.indices.contains(index + 1)
    {
        AppDelegate(startedAt: startedAt).runSwitchSelfTest(root: URL(
            fileURLWithPath: arguments[index + 1],
            isDirectory: true
        ))
    }
    let pythonSelfTestRoot = arguments.firstIndex(of: "--self-test-python")
        .flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    if arguments.contains("--self-test-python"), pythonSelfTestRoot == nil {
        FileHandle.standardError.write(Data(
            "usage: codeinsight-app --self-test-python <python-git-repo>\n".utf8
        ))
        Darwin.exit(2)
    }
    let typescriptSelfTestRoot = arguments.firstIndex(of: "--self-test-typescript")
        .flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    if arguments.contains("--self-test-typescript"), typescriptSelfTestRoot == nil {
        FileHandle.standardError.write(Data(
            "usage: codeinsight-app --self-test-typescript <typescript-git-repo>\n".utf8
        ))
        Darwin.exit(2)
    }
    let mixedSelfTestRoot = arguments.firstIndex(of: "--self-test-mixed")
        .flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    if arguments.contains("--self-test-mixed"), mixedSelfTestRoot == nil {
        FileHandle.standardError.write(Data(
            "usage: codeinsight-app --self-test-mixed <mixed-git-repo>\n".utf8
        ))
        Darwin.exit(2)
    }
    let nonSourceSelfTestRoot = arguments.firstIndex(of: "--self-test-non-source")
        .flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
    if arguments.contains("--self-test-non-source") {
        guard let nonSourceSelfTestRoot,
              let values = try? nonSourceSelfTestRoot.resourceValues(
                  forKeys: [.isDirectoryKey]
              ),
              values.isDirectory == true
        else {
            FileHandle.standardError.write(Data(
                "usage: codeinsight-app --self-test-non-source <fixture-root>\n".utf8
            ))
            Darwin.exit(2)
        }
    }
    let app = NSApplication.shared
    if let foldPerformance {
        app.setActivationPolicy(.prohibited)
        runFoldPerformance(
            mode: foldPerformance.mode,
            fixture: foldPerformance.fixture,
            output: foldPerformance.output
        )
    }
    if let wrapPerformance {
        app.setActivationPolicy(.prohibited)
        runWrapPerformance(wrapPerformance)
    }
    app.setActivationPolicy(.regular)
    let exactRoot = arguments.firstIndex(of: "--self-test-exact")
        .flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        .map { URL(fileURLWithPath: $0, isDirectory: true) }
    let bookmarkSelfTestRoot = arguments.firstIndex(of: "--self-test-bookmarks")
        .flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        .map { URL(fileURLWithPath: $0, isDirectory: true) }
    if arguments.contains("--self-test-bookmarks"), bookmarkSelfTestRoot == nil {
        FileHandle.standardError.write(Data(
            "usage: codeinsight-app --self-test-bookmarks <rust-project-root>\n".utf8
        ))
        Darwin.exit(2)
    }
    let bookmarkRestartSessionURL = arguments.firstIndex(of: "--self-test-bookmarks-restart")
        .flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        .map(URL.init(fileURLWithPath:))
    if arguments.contains("--self-test-bookmarks-restart"), bookmarkRestartSessionURL == nil {
        FileHandle.standardError.write(Data(
            "usage: codeinsight-app --self-test-bookmarks-restart <session-url>\n".utf8
        ))
        Darwin.exit(2)
    }
    if let bookmarkRestartSessionURL {
        runBookmarkSelfTestRestart(sessionURL: bookmarkRestartSessionURL)
    }
    // Two-process reading-session acceptance: the first process builds
    // a real reading state and checkpoints it; the restart process
    // relaunches the same build and verifies the restored scene.
    // Both need CAIRN_SESSION_SELFTEST_URL and an isolated defaults
    // suite so no user data is touched.
    let sessionSelfTestRoot = arguments.firstIndex(of: "--self-test-session")
        .flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        .map { URL(fileURLWithPath: $0, isDirectory: true) }
    if arguments.contains("--self-test-session"), sessionSelfTestRoot == nil {
        FileHandle.standardError.write(Data(
            "usage: codeinsight-app --self-test-session <rust-project-root>\n".utf8
        ))
        Darwin.exit(2)
    }
    let sessionSelfTestRestart = arguments.contains("--self-test-session-restart")
    let sessionSelfTestActive = sessionSelfTestRoot != nil || sessionSelfTestRestart
    if sessionSelfTestActive,
       ProcessInfo.processInfo.environment["CAIRN_SESSION_SELFTEST_URL"] == nil
        || ProcessInfo.processInfo.environment["CAIRN_SESSION_SELFTEST_DEFAULTS"] == nil
    {
        FileHandle.standardError.write(Data((
            "usage: CAIRN_SESSION_SELFTEST_URL=<session.json> "
                + "CAIRN_SESSION_SELFTEST_DEFAULTS=<suite> "
                + "codeinsight-app --self-test-session[-restart]\n"
        ).utf8))
        Darwin.exit(2)
    }
    let delegate: AppDelegate
    if let relationTimingTarget {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CodeInsightRelationTiming-\(UUID().uuidString)",
                isDirectory: true
            )
        let trustRegistry = TrustRegistry(
            fileURL: temporaryRoot.appendingPathComponent("trust.json")
        )
        let providerState: ExactSelfTestProviderState?
        let coordinator: ExactCoordinator
        if relationTimingTarget.provider == "fake" {
            let state = ExactSelfTestProviderState()
            let location = ExactLocation(
                file: relationTimingTarget.relativeFile,
                byteOffset: Int(relationTimingTarget.offset),
                line: 1,
                column: 1
            )
            let item = exactSelfTestCallItem(
                name: "relation-timing-target",
                uri: relationTimingTarget.file,
                location: location
            )
            let provider = InProcessExactProvider(
                location: nil,
                capabilities: [.callHierarchy],
                callHierarchyItems: [item],
                incomingRelations: [],
                state: state
            )
            providerState = state
            coordinator = ExactCoordinator(
                providerFactory: { _ in provider },
                sandboxAvailable: { true },
                trustRegistry: trustRegistry
            )
        } else {
            providerState = nil
            coordinator = ExactCoordinator(
                providerFactory: { projectURL in
                    guard let executable = RustAnalyzerProvider.findExecutable()
                    else {
                        throw ExactError.unavailable(
                            "rust-analyzer is not installed"
                        )
                    }
                    return try RustAnalyzerProvider(
                        projectURL: projectURL,
                        executableURL: executable,
                        requestTimeout: 30,
                        closeGrace: 2
                    )
                },
                trustRegistry: trustRegistry
            )
        }
        delegate = AppDelegate(
            startedAt: startedAt,
            model: AppModel(exactCoordinator: coordinator),
            exactSelfTestProviderState: providerState,
            relationTimingTemporaryRoot: temporaryRoot
        )
    } else if let exactRoot {
        let fixtureRoot = exactSelfTestFixtureRoot(root: exactRoot)
        let target = exactSelfTestTarget(root: fixtureRoot)
        let providerState = ExactSelfTestProviderState()
        let rootItem = target.map {
            exactSelfTestCallItem(
                name: "answer",
                uri: $0.relationFile,
                location: $0.definition
            )
        }
        let callerItem = target.map {
            exactSelfTestCallItem(
                name: "exact_dependency_caller",
                uri: $0.dependencyFile,
                location: $0.dependencyDefinition
            )
        }
        let provider = InProcessExactProvider(
            location: target?.definition,
            capabilities: [
                .definition, .implementations, .callHierarchy, .references,
            ],
            implementationLocations: target.map { [$0.dependencyDefinition] },
            referenceLocations: target?.referenceLocations,
            callHierarchyItems: rootItem.map { [$0] },
            incomingRelations: callerItem.map {
                [ExactCallRelation(
                    item: $0,
                    callSites: [
                        ExactLocation(
                            file: "src/lib.rs",
                            byteOffset: Int(target?.relationCallOffset ?? 0),
                            line: 1,
                            column: 1
                        ),
                        ExactLocation(
                            file: "src/lib.rs",
                            byteOffset: Int(target?.relationCallOffset ?? 0) + 1,
                            line: 1,
                            column: 2
                        ),
                    ]
                )]
            },
            outgoingRelations: callerItem.map {
                [ExactCallRelation(item: $0, callSites: [])]
            },
            externalFile: "src/lib.rs",
            externalOffset: target.flatMap(\.externalCallOffset).map(Int.init),
            externalLocation: target?.dependencyDefinition,
            state: providerState
        )
        let coordinator = ExactCoordinator(
            providerFactory: { _ in provider },
            snapshotFactory: { root, _ in
                try ExactSelfTestDirectorySnapshot(root: root)
            },
            sandboxAvailable: { true },
            trustRegistry: TrustRegistry(fileURL: FileManager.default
                .temporaryDirectory
                .appendingPathComponent("CodeInsightExactSelfTest-trust.json"))
        )
        delegate = AppDelegate(
            startedAt: startedAt,
            model: AppModel(
                indexService: ExactSelfTestIndexService(),
                exactCoordinator: coordinator
            ),
            exactSelfTestProviderState: providerState
        )
    } else {
        if pythonSelfTestRoot != nil
            || typescriptSelfTestRoot != nil
            || mixedSelfTestRoot != nil
        {
            let pythonSelfTestID = UUID().uuidString
            let pythonRecentStore = RecentProjectsStore(defaults: UserDefaults(
                suiteName: "CodeInsightLanguageSelfTest-\(pythonSelfTestID)"
            )!)
            delegate = AppDelegate(
                startedAt: startedAt,
                model: AppModel(
                    sessionURL: FileManager.default.temporaryDirectory
                        .appendingPathComponent(
                            "CodeInsightLanguageSelfTest-\(pythonSelfTestID).json"
                        )
                ),
                recentProjectsStore: pythonRecentStore
            )
        } else if arguments.contains("--self-test-multiwindow") {
            // Multi-window acceptance: one process, isolated session
            // store, isolated defaults, temp trust and cache (§11).
            let storageRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "CodeInsightMultiWindowStorage-\(UUID().uuidString)",
                    isDirectory: true
                )
            let multiWindowDefaults = UserDefaults(
                suiteName: "CodeInsightMultiWindow-\(UUID().uuidString)"
            )!
            let multiWindowStore = RecentProjectsStore(
                defaults: multiWindowDefaults
            )
            let multiWindowSessionURL = storageRoot
                .appendingPathComponent("session.json")
            delegate = AppDelegate.production(
                startedAt: startedAt,
                sessionURL: multiWindowSessionURL,
                recentProjectsStore: multiWindowStore,
                sharedTrustRegistry: TrustRegistry(
                    fileURL: storageRoot.appendingPathComponent("trust.json")
                ),
                sharedMaterializer: Materializer(
                    rootURL: storageRoot.appendingPathComponent("materialized")
                )
            )
        } else {
            let bookmarkSessionURL = bookmarkSelfTestRoot.map { _ in
                ProcessInfo.processInfo.environment[
                    "CAIRN_BOOKMARK_SESSION_URL"
                ].map(URL.init(fileURLWithPath:)) ?? AppModel.defaultSessionURL
            }
            // One store shared by the model and the delegate: the model
            // advances the last-session pointer when a project's
            // snapshot is written, and launch reads the same pointer.
            let launchRecentStore = RecentProjectsStore()
            let appModel: AppModel
            if let sessionSelfTestURL = sessionSelfTestActive
                ? ProcessInfo.processInfo.environment[
                    "CAIRN_SESSION_SELFTEST_URL"
                ].map(URL.init(fileURLWithPath:))
                : nil,
               let suiteName = ProcessInfo.processInfo.environment[
                   "CAIRN_SESSION_SELFTEST_DEFAULTS"
               ],
               let isolatedDefaults = UserDefaults(suiteName: suiteName)
            {
                let isolatedStore = RecentProjectsStore(
                    defaults: isolatedDefaults
                )
                appModel = AppModel(
                    sessionURL: sessionSelfTestURL,
                    recentProjectsStore: isolatedStore
                )
                delegate = AppDelegate(
                    startedAt: startedAt,
                    model: appModel,
                    recentProjectsStore: isolatedStore
                )
            } else if let bookmarkSessionURL {
                appModel = AppModel(
                    sessionURL: bookmarkSessionURL,
                    recentProjectsStore: launchRecentStore
                )
                delegate = AppDelegate(
                    startedAt: startedAt,
                    model: appModel,
                    recentProjectsStore: launchRecentStore
                )
            } else {
                delegate = AppDelegate(
                    startedAt: startedAt,
                    model: AppModel(),
                    recentProjectsStore: launchRecentStore
                )
            }
        }
    }
    if let pythonRoot = pythonSelfTestRoot {
        withExtendedLifetime(delegate) {
            Task { @MainActor in
                await delegate.runPythonSelfTest(root: URL(
                    fileURLWithPath: pythonRoot,
                    isDirectory: true
                ))
            }
            app.run()
        }
        return true
    }
    if let mixedRoot = mixedSelfTestRoot {
        withExtendedLifetime(delegate) {
            Task { @MainActor in
                await delegate.runMixedSelfTest(root: URL(
                    fileURLWithPath: mixedRoot,
                    isDirectory: true
                ))
            }
            app.run()
        }
        return true
    }
    if let typescriptRoot = typescriptSelfTestRoot {
        withExtendedLifetime(delegate) {
            Task { @MainActor in
                await delegate.runTypeScriptSelfTest(root: URL(
                    fileURLWithPath: typescriptRoot,
                    isDirectory: true
                ))
            }
            app.run()
        }
        return true
    }
    app.delegate = delegate
    withExtendedLifetime(delegate) {
        if let relationTimingTarget {
            delegate.runRelationTimingSelfTest(
                root: relationTimingTarget.root,
                file: relationTimingTarget.file,
                relativeFile: relationTimingTarget.relativeFile,
                offset: relationTimingTarget.offset,
                provider: relationTimingTarget.provider
            )
        } else if let exactRoot {
            delegate.runExactSelfTest(root: exactRoot)
        } else if arguments.contains("--self-test-search") {
            delegate.runSearchSelfTest()
        } else if arguments.contains("--self-test-reading") {
            delegate.runReadingSelfTest()
        } else if arguments.contains("--self-test-projector") {
            delegate.runProjectorSelfTest()
        } else if arguments.contains("--self-test-fold") {
            delegate.runFoldSelfTest()
        } else if arguments.contains("--self-test-tabs") {
            delegate.runTabsSelfTest()
        } else if let index = arguments.firstIndex(of: "--self-test-diff"),
                  arguments.indices.contains(index + 1)
        {
            delegate.runDiffSelfTest(root: URL(
                fileURLWithPath: arguments[index + 1],
                isDirectory: true
            ))
        } else if let index = arguments.firstIndex(of: "--self-test-pin"),
           arguments.indices.contains(index + 1)
        {
            delegate.runPinSelfTest(root: URL(
                fileURLWithPath: arguments[index + 1],
                isDirectory: true
            ))
        } else if let index = arguments.firstIndex(of: "--self-test-history"),
           arguments.indices.contains(index + 1)
        {
            delegate.runHistorySelfTest(root: URL(
                fileURLWithPath: arguments[index + 1],
                isDirectory: true
            ))
        } else if let index = arguments.firstIndex(of: "--self-test-open"),
           arguments.indices.contains(index + 1)
        {
            delegate.runOpenSelfTest(file: URL(
                fileURLWithPath: arguments[index + 1]
            ))
        } else if let index = arguments.firstIndex(of: "--self-test-project"),
           arguments.indices.contains(index + 1)
        {
            delegate.runProjectSelfTest(root: URL(
                fileURLWithPath: arguments[index + 1],
                isDirectory: true
            ))
        } else if let index = arguments.firstIndex(
            of: "--self-test-gutter-line"
        ), arguments.indices.contains(index + 1) {
            delegate.runGutterLineSelfTest(root: URL(
                fileURLWithPath: arguments[index + 1],
                isDirectory: true
            ))
        } else if let bookmarkSelfTestRoot {
            delegate.runBookmarkSelfTest(root: bookmarkSelfTestRoot)
        } else if let sessionSelfTestRoot {
            delegate.runSessionSelfTest(root: sessionSelfTestRoot)
        } else if sessionSelfTestRestart {
            delegate.runSessionSelfTestRestart()
        } else if arguments.contains("--self-test-multiwindow") {
            delegate.runMultiWindowSelfTest()
        } else if arguments.contains("--self-test") {
            delegate.runSelfTest()
        } else if let nonSourceSelfTestRoot {
            delegate.runNonSourceSelfTest(root: nonSourceSelfTestRoot)
        } else {
            app.run()
        }
    }
    return true
}

extension AppDelegate {
    func runSelfTest() {
        launch(offscreen: true, measuresIdleFootprint: true)
        let coldStartMS = milliseconds(since: startedAt)
        guard let windowController, windowController.window?.isVisible == true else {
            Self.exitSelfTest(channel: "base", status: 1)
        }
        windowController.window?.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.35))
        guard let footprint = physicalFootprintBytes() else {
            Self.exitSelfTest(channel: "base", status: 1)
        }
        let idleFootprintMB = Double(footprint) / 1_048_576
        windowController.prepareTitledWindowForSelfTest()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        let layout = enlargedWindowLayout(
            controller: windowController,
            statusBarOccupancyHeight: 0
        )
        var themeSettings = readerSettings
        themeSettings.theme = .dark
        windowController.applyReaderSettings(themeSettings)
        let darkChromeMatchesTheme = windowController.window?
            .effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        themeSettings.theme = .light
        windowController.applyReaderSettings(themeSettings)
        let lightChromeMatchesTheme = windowController.window?
            .effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
        themeSettings.theme = .siClassic
        windowController.applyReaderSettings(themeSettings)
        let siClassicChromeStaysLight = windowController.window?
            .effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
        themeSettings.theme = .auto
        windowController.applyReaderSettings(themeSettings)
        let autoChromeFollowsSystem = windowController.window?.appearance == nil

        let languageAlert = makeLanguageSelectionAlert(for: URL(
            fileURLWithPath: "/tmp/codeinsight-language-picker-self-test",
            isDirectory: true
        ))
        languageAlert.window.contentView?.layoutSubtreeIfNeeded()
        languageAlert.window.displayIfNeeded()
        let languageStack = languageAlert.accessoryView as? NSStackView
        let languageCheckboxes = languageStack?.arrangedSubviews
            .compactMap { $0 as? NSButton } ?? []
        let languageFrames = languageCheckboxes.map(\.frame)
        let languageLabelsFit = languageCheckboxes.count == 3
            && languageCheckboxes.allSatisfy {
                $0.frame.width >= $0.fittingSize.width - 1
                    && $0.frame.height >= $0.fittingSize.height - 1
            }
        let languageFramesDoNotOverlap = languageFrames.count == 3
            && languageFrames.allSatisfy { !$0.isEmpty }
            && zip(languageFrames, languageFrames.dropFirst()).allSatisfy {
                left, right in !left.intersects(right)
            }
        let languageOrderMatches = languageCheckboxes.map(\.title)
            == ["Rust", "Python", "TypeScript"]
        let languageOpenButton = languageAlert.buttons.first
        let languageOpenDisabledAtZero = languageOpenButton?.isEnabled == false
        languageCheckboxes.first?.performClick(nil)
        let languageOpenEnabledAtOne = languageOpenButton?.isEnabled == true
        languageCheckboxes.dropFirst().forEach { $0.performClick(nil) }
        let languageOpenEnabledAtThree = languageOpenButton?.isEnabled == true
        languageCheckboxes.forEach { $0.performClick(nil) }
        let languageOpenDisabledAfterClearing = languageOpenButton?.isEnabled == false

        windowController.applyPanelPreset(.reading)
        pumpRunLoop()
        let appMenu = NSApplication.shared.mainMenu?.items.first?.submenu
        let fileMenu = NSApplication.shared.mainMenu?.items
            .compactMap(\.submenu).first { $0.title == "File" }
        let goMenu = NSApplication.shared.mainMenu?.items
            .compactMap(\.submenu).first { $0.title == "Go" }
        let relationsMenu = NSApplication.shared.mainMenu?.items
            .compactMap(\.submenu).first { $0.title == "Relations" }
        let viewMenu = NSApplication.shared.mainMenu?.items
            .compactMap(\.submenu).first { $0.title == "View" }
        let foldingMenu = viewMenu?.item(withTitle: "Folding")?.submenu
        let inspectorMenuItem = relationsMenu?.item(
            withTitle: "Show Resolution Inspector"
        )
        let trailMenuItem = viewMenu?.item(withTitle: "Show Reading Trail")
        let toggleBookmarkMenuItem = viewMenu?.item(withTitle: "Toggle Bookmark")
        let showBookmarksMenuItem = viewMenu?.item(withTitle: "Show Bookmarks")
        let hideBookmarksMenuItem = viewMenu?.item(withTitle: "Hide Bookmarks")
        let bookmarkPanelShortcutCount = Self.menuItems(
            in: NSApplication.shared.mainMenu
        ).filter {
            $0.keyEquivalent == "b"
                && $0.keyEquivalentModifierMask == [.command, .option]
        }.count
        let fullHeightItem = foldingMenu?.item(withTitle: "Full")
        let structureHeightItem = foldingMenu?.item(withTitle: "Structure")
        let overviewHeightItem = foldingMenu?.item(withTitle: "Overview")
        let paletteCommands = PalettePanel.commandRows(
            in: NSApplication.shared.mainMenu
        )
        let structureActionSent =
            structureHeightItem.flatMap { item in
                item.action.map {
                    NSApplication.shared.sendAction($0, to: item.target, from: item)
                }
            } ?? false
        for item in [fullHeightItem, structureHeightItem, overviewHeightItem]
            .compactMap({ $0 })
        {
            _ = validateMenuItem(item)
        }
        let heightHeader = windowController.selfTestReadingHeightHeader
        let readingHeightInputsStaySynchronized =
            structureActionSent
            && windowController.readingHeightLevel == .structure
            && heightHeader.level == .structure
            && structureHeightItem?.state == .on
            && fullHeightItem?.state == .off
            && overviewHeightItem?.state == .off
        useFullReadingHeight(nil)
        var checks = [
            "darkChromeMatchesTheme": darkChromeMatchesTheme,
            "lightChromeMatchesTheme": lightChromeMatchesTheme,
            "siClassicChromeStaysLight": siClassicChromeStaysLight,
            "autoChromeFollowsSystem": autoChromeFollowsSystem,
            "languagePickerLabelsFit": languageLabelsFit,
            "languagePickerFramesDoNotOverlap": languageFramesDoNotOverlap,
            "languagePickerOrderMatches": languageOrderMatches,
            "languagePickerOpenGate": languageOpenDisabledAtZero
                && languageOpenEnabledAtOne
                && languageOpenEnabledAtThree
                && languageOpenDisabledAfterClearing,
            "quickOpenUsesCommandP":
                fileMenu?.item(withTitle: "Quick Open…")?.keyEquivalent == "p"
                && fileMenu?.item(withTitle: "Quick Open…")?
                    .keyEquivalentModifierMask == .command,
            "fileMenuHasRustPythonAndTypeScriptOpen":
                fileMenu?.item(withTitle: "Open Project…") != nil
                && fileMenu?.item(withTitle: "Open Python Project…") != nil
                && fileMenu?.item(withTitle: "Open TypeScript Project…") != nil,
            "fileMenuKeepsOpenFirstAndMixedAfterTypeScript":
                fileMenu?.item(withTitle: "Open Project…") == fileMenu?.items.first
                && fileMenu?.items.compactMap(\.title).firstIndex(
                    of: "Open TypeScript Project…"
                ) == fileMenu?.items.compactMap(\.title).firstIndex(
                    of: "Open Python Project…"
                ).map { $0 + 1 },
            "paletteCollectsRustPythonAndTypeScriptOpen":
                paletteCommands.contains {
                    $0.title == "File ▸ Open Project…"
                }
                && paletteCommands.contains {
                    $0.title == "File ▸ Open Python Project…"
                }
                && paletteCommands.contains {
                    $0.title == "File ▸ Open TypeScript Project…"
                },
            "commandPaletteUsesShiftCommandP":
                goMenu?.item(withTitle: "Command Palette…")?
                    .keyEquivalent == "p"
                && goMenu?.item(withTitle: "Command Palette…")?
                    .keyEquivalentModifierMask == [.command, .shift],
            "symbolPaletteUsesCommandT":
                goMenu?.item(withTitle: "Open Symbol…")?.keyEquivalent == "t"
                && goMenu?.item(withTitle: "Open Symbol…")?
                    .keyEquivalentModifierMask == .command,
            "linePaletteUsesCommandL":
                goMenu?.item(withTitle: "Go to Line…")?.keyEquivalent == "l"
                && goMenu?.item(withTitle: "Go to Line…")?
                    .keyEquivalentModifierMask == .command,
            "paletteCollectsRuntimeFoldingCommand":
                paletteCommands.contains {
                    $0.title == "View ▸ Folding ▸ Overview"
                        && $0.shortcut == "⌥⌘2"
                },
            "paletteExcludesEditingCommands":
                !paletteCommands.contains {
                    ["Cut", "Copy", "Paste", "Select All"].contains(
                        $0.title.components(separatedBy: " ▸ ").last ?? ""
                    )
                },
            "foldingMenuHasExactFiveCommands":
                foldingMenu?.items.filter { !$0.isSeparatorItem }.map(\.title)
                == [
                    "Toggle Fold",
                    "Full",
                    "Structure",
                    "Overview",
                    "Focus Current Scope",
                ],
            "toggleFoldUsesResolvedKey":
                foldingMenu?.item(withTitle: "Toggle Fold")?.keyEquivalent == "[",
            "toggleFoldAvoidsPreviousTabShortcut":
                foldingMenu?.item(withTitle: "Toggle Fold")?
                .keyEquivalentModifierMask == [.command, .control],
            "fullHeightUsesPrototypeShortcut":
                fullHeightItem?.keyEquivalent == "0"
                && fullHeightItem?.keyEquivalentModifierMask == [.command, .option],
            "structureHeightUsesPrototypeShortcut":
                structureHeightItem?.keyEquivalent == "1"
                && structureHeightItem?.keyEquivalentModifierMask
                    == [.command, .option],
            "overviewHeightUsesPrototypeShortcut":
                overviewHeightItem?.keyEquivalent == "2"
                && overviewHeightItem?.keyEquivalentModifierMask
                    == [.command, .option],
            "focusUsesPrototypeShortcut":
                foldingMenu?.item(withTitle: "Focus Current Scope")?
                .keyEquivalent == "f"
                && foldingMenu?.item(withTitle: "Focus Current Scope")?
                    .keyEquivalentModifierMask == [.command, .option],
            "readingHeightInputsStaySynchronized":
                readingHeightInputsStaySynchronized,
            "readingHeightHeaderMatchesPrototypeGeometry":
                heightHeader.labels == ["Full", "Structure", "Overview"]
                && heightHeader.shortcut == "⌥⌘0/1/2"
                && heightHeader.accessibilityLabel == "Reading height"
                && abs(heightHeader.frame.height - 32) <= 1
                && abs(heightHeader.controlFrame.width - 196) <= 1
                && abs(heightHeader.controlFrame.height - 24) <= 1
                && heightHeader.frame.contains(heightHeader.controlFrame),
            // §3.1: without a project the sidebar retires around the brand
            // empty state instead of showing its placeholders.
            "sidebarRetiredWithoutProject":
                windowController.selfTestSidebarPaneCollapsed,
            "emptyStateCarriesOpenProjectWithoutProject":
                windowController.selfTestEmptyStateExists
                && windowController.selfTestEmptyStateOpenButtonIsVisibleDefaultAction,
            "contextRetiredWithoutProject":
                windowController.selfTestContextPaneCollapsed
                && !windowController.selfTestContextPlaceholderVisible,
            "contextPlaceholderTextWithoutCandidate":
                windowController.selfTestContextPlaceholderText
                == "Click a symbol to see its definition here. ⌘-click jumps to it.",
            "contextReaderHiddenWithoutCandidate":
                !windowController.selfTestContextReaderVisible,
            "emptyStateExists": windowController.selfTestEmptyStateExists,
            "emptyStateHasCairn": windowController.selfTestEmptyStateTexts
                .contains("Cairn"),
            "emptyStateHasOpenProjectButton": windowController
                .selfTestEmptyStateButtonTitles.contains {
                    $0.contains("Open Project…")
                },
            "emptyStateOpenProjectButtonShowsCommandO": windowController
                .selfTestEmptyStateButtonVisibleInWindow
                && windowController.selfTestEmptyStateButtonTitles.contains {
                    $0.contains("⌘O")
                },
            "emptyStateOpenProjectButtonIsVisibleDefaultAction": windowController
                .selfTestEmptyStateOpenButtonIsVisibleDefaultAction,
            "emptyStateAttachedToWindow": windowController
                .selfTestEmptyStateAttachedToWindow,
            "emptyStateUnhidden": windowController.selfTestEmptyStateUnhidden,
            "emptyStateFrameVisibleInWindow": windowController
                .selfTestEmptyStateFrameVisibleInWindow,
            "emptyStateMarkVisibleInWindow": windowController
                .selfTestEmptyStateMarkVisibleInWindow,
            "emptyStateMarkIs48Square": windowController
                .selfTestEmptyStateMarkIs48Square,
            "emptyStateMarkUsesCairnDrawing": windowController
                .selfTestEmptyStateMarkUsesCairnDrawing,
            "emptyStateNotCoveredByReader": windowController
                .selfTestEmptyStateNotCoveredByReader,
            "emptyStateTitleVisibleInWindow": windowController
                .selfTestEmptyStateTitleVisibleInWindow,
            "emptyStateOpenProjectButtonVisibleInWindow": windowController
                .selfTestEmptyStateButtonVisibleInWindow,
            "symbolsToolbarItemExistsAndVisible": windowController
                .selfTestSymbolsToolbarItemExistsAndVisible,
            "settingsToolbarItemExistsAndVisible": windowController
                .selfTestSettingsToolbarItemExistsAndVisible,
            "profileToolbarItemRegisteredAndHiddenWithoutProject":
                windowController.selfTestProfileToolbarItemRegisteredAndHidden,
            "statusBarHiddenWithoutProject":
                !windowController.selfTestStatusBarVisible,
            "menuHasAboutCairn": appMenu?.item(withTitle: "About Cairn") != nil,
            "menuHasQuitCairn": appMenu?.item(withTitle: "Quit Cairn") != nil,
            "relationsMenuExposesResolutionInspector":
                inspectorMenuItem?.keyEquivalent == "i"
                && inspectorMenuItem?.keyEquivalentModifierMask == .command
                && inspectorMenuItem?.action
                    == #selector(showResolutionInspector(_:))
                && inspectorMenuItem?.target === self,
            "viewMenuExposesReadingTrail":
                trailMenuItem?.keyEquivalent == "t"
                && trailMenuItem?.keyEquivalentModifierMask
                    == [.command, .option]
                && trailMenuItem?.action == #selector(showReadingTrail(_:))
                && trailMenuItem?.target === self,
            "bookmarksMenuHasNonConflictingToggleAndPanelCommands":
                toggleBookmarkMenuItem?.keyEquivalent == "m"
                && toggleBookmarkMenuItem?.keyEquivalentModifierMask == [.command, .shift]
                && toggleBookmarkMenuItem?.action == #selector(toggleBookmark(_:))
                && showBookmarksMenuItem?.keyEquivalent == "b"
                && showBookmarksMenuItem?.keyEquivalentModifierMask == [.command, .option]
                && showBookmarksMenuItem?.action == #selector(showBookmarks(_:))
                && hideBookmarksMenuItem?.action == #selector(closeBookmarks(_:))
                && bookmarkPanelShortcutCount == 1,
            "bookmarksToggleIsDisabledWithNamedAccessibilityHelpOutsideReader":
                toggleBookmarkMenuItem.map {
                    !validateMenuItem($0)
                        && $0.toolTip
                            == "Bookmarks require a current project file in the primary reader."
                        && $0.accessibilityHelp()
                            == "Bookmarks require a current project file in the primary reader."
                } ?? false,
            "readingTrailBarHiddenWithoutProject":
                !windowController.selfTestTrailBarVisible,
            "windowTitleIsCairn": windowController.window?.title == "Cairn",
        ]
        windowController.applyPanelPreset(.relations)
        pumpRunLoop()
        // §3.1: the relations pane retires without a project.
        checks["relationsRetiredWithoutRoot"] =
            windowController.selfTestRelationsPaneCollapsed
        checks.merge(layout.checks) { _, new in new }
        Self.finishSelfTest(
            coldStartMS: coldStartMS,
            idleFootprintMB: idleFootprintMB,
            checks: checks,
            enlargedWindowGeometry: layout.geometry
        )
    }

    private static func finishSelfTest(
        coldStartMS: Double,
        idleFootprintMB: Double,
        checks: [String: Bool],
        enlargedWindowGeometry: [String: Double]
    ) {
        do {
            let passed = checks.values.allSatisfy { $0 }
            var object: [String: Any] = checks
            object["coldStartMS"] = coldStartMS
            object["idleFootprintMB"] = idleFootprintMB
            object["idleFootprintUnderBudget"] =
                idleFootprintMB < SelfTestBudgets.idleFootprintMB
            object["idleFootprintWindowStyle"] = "borderless"
            object["toolbarAssertionsWindowStyle"] = "titled"
            object["enlargedWindowGeometry"] = enlargedWindowGeometry
            object["passed"] = passed
            let data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
            exitSelfTest(channel: "base", status: passed ? 0 : 1)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exitSelfTest(channel: "base", status: 1)
        }
    }
}

private func foldPerformanceArguments(
    _ arguments: [String]
) -> (mode: String, fixture: URL, output: URL)? {
    guard let modeIndex = arguments.firstIndex(of: "--fold-perf-mode"),
          arguments.indices.contains(modeIndex + 1),
          let fixtureIndex = arguments.firstIndex(of: "--fold-perf-fixture"),
          arguments.indices.contains(fixtureIndex + 1),
          let outputIndex = arguments.firstIndex(of: "--fold-perf-out"),
          arguments.indices.contains(outputIndex + 1)
    else { return nil }
    let mode = arguments[modeIndex + 1]
    guard ["control", "fold"].contains(mode) else { return nil }
    return (
        mode,
        URL(fileURLWithPath: arguments[fixtureIndex + 1]).standardizedFileURL,
        URL(fileURLWithPath: arguments[outputIndex + 1]).standardizedFileURL
    )
}

/// Argument surface for the soft-wrap performance mode (§7.4.1):
/// `--self-test-wrap --fixture <path> --wrap <on|off>
///  --scenario <initial|toggle|resize|reading-set> --output <path>`
/// plus optional `--code-sha`, `--warmup`, and `--samples`.
private func wrapPerformanceArguments(
    _ arguments: [String]
) -> WrapPerformanceRequest? {
    guard arguments.contains("--self-test-wrap"),
          let fixtureIndex = arguments.firstIndex(of: "--fixture"),
          arguments.indices.contains(fixtureIndex + 1),
          let wrapIndex = arguments.firstIndex(of: "--wrap"),
          arguments.indices.contains(wrapIndex + 1),
          ["on", "off"].contains(arguments[wrapIndex + 1]),
          let scenarioIndex = arguments.firstIndex(of: "--scenario"),
          arguments.indices.contains(scenarioIndex + 1),
          ["initial", "toggle", "resize", "reading-set"]
              .contains(arguments[scenarioIndex + 1]),
          let outputIndex = arguments.firstIndex(of: "--output"),
          arguments.indices.contains(outputIndex + 1)
    else { return nil }
    func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1)
        else { return nil }
        return arguments[index + 1]
    }
    let warmup = value(after: "--warmup").flatMap(Int.init) ?? 5
    let samples = value(after: "--samples").flatMap(Int.init) ?? 30
    guard warmup >= 0, samples >= 1, samples <= 200,
          let ligatureMode = CodeLigatureMode(rawValue: value(after: "--ligature-mode") ?? "fontDefault")
    else { return nil }
    return WrapPerformanceRequest(
        fixture: URL(
            fileURLWithPath: arguments[fixtureIndex + 1]
        ).standardizedFileURL,
        wrapOn: arguments[wrapIndex + 1] == "on",
        scenario: arguments[scenarioIndex + 1],
        output: URL(
            fileURLWithPath: arguments[outputIndex + 1]
        ).standardizedFileURL,
        codeSHA: value(after: "--code-sha") ?? "unknown",
        warmupCount: warmup,
        sampleCount: samples,
        fontPostScriptName: value(after: "--font-postscript"),
        ligatureMode: ligatureMode
    )
}

private func relationTimingArguments(
    _ arguments: [String]
) -> (
    root: URL,
    file: URL,
    relativeFile: String,
    offset: UInt32,
    provider: String
)? {
    guard let index = arguments.firstIndex(of: "--self-test-relation-timing"),
          arguments.indices.contains(index + 4),
          let offset = UInt32(arguments[index + 3]),
          ["fake", "real"].contains(arguments[index + 4])
    else { return nil }
    let root = URL(
        fileURLWithPath: arguments[index + 1],
        isDirectory: true
    ).resolvingSymlinksInPath().standardizedFileURL
    let relativeFile = arguments[index + 2]
    guard !relativeFile.hasPrefix("/") else { return nil }
    let file = root.appendingPathComponent(relativeFile)
        .resolvingSymlinksInPath().standardizedFileURL
    var isDirectory: ObjCBool = false
    guard file.path.hasPrefix(root.path + "/"),
          FileManager.default.fileExists(
              atPath: root.path,
              isDirectory: &isDirectory
          ),
          isDirectory.boolValue,
          let bytes = try? Data(contentsOf: file),
          Int(offset) < bytes.count
    else { return nil }
    return (root, file, relativeFile, offset, arguments[index + 4])
}
private func exactSelfTestCallItem(
    name: String,
    uri: URL,
    location: ExactLocation
) -> ExactCallHierarchyItem {
    ExactCallHierarchyItem(
        name: name,
        kind: 12,
        uri: uri.absoluteString,
        range: location,
        selectionRange: location,
        data: nil
    )
}
