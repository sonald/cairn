import AppKit
import CodeInsightAppModel
import CodeInsightCore
import CodeInsightEngine
import CodeInsightExact
import CodeInsightGit
import CodeInsightReaderCore
import CodeInsightReaderUI
import Darwin
import os
import SwiftUI

private enum SelfTestBudgets {
    static let coldStartMS = 500.0
    static let idleFootprintMB = 100.0
    static let regularFirstVisibleMS = 100.0
    static let hugeFirstVisibleMS = 2_500.0
    static let hugeStyledFragments = 500
    static let projectTreeVisibleMS = 1_000.0
    static let projectIndexReadyMS = 2_000.0
    static let snapshotFirstPaintMS = 1_000.0
}

private struct DiffSelfTestTarget {
    let file: URL
    let path: String
    let worktreeBytes: [UInt8]
    let commitBytes: [UInt8]
    let expected: DiffCore.Result
}

@main
private struct CodeInsightApplication {
    @MainActor
    static func main() {
        let startedAt = ContinuousClock.now
        let arguments = Array(CommandLine.arguments.dropFirst())
        if let index = arguments.firstIndex(of: "--self-test-switch"),
           arguments.indices.contains(index + 1)
        {
            AppDelegate(startedAt: startedAt).runSwitchSelfTest(root: URL(
                fileURLWithPath: arguments[index + 1],
                isDirectory: true
            ))
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let exactRoot = arguments.firstIndex(of: "--self-test-exact")
            .flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        let delegate: AppDelegate
        if let exactRoot {
            let fixtureRoot = exactSelfTestFixtureRoot(root: exactRoot)
            let target = exactSelfTestTarget(root: fixtureRoot)
            let provider = InProcessExactProvider(
                location: target?.definition,
                externalFile: "src/lib.rs",
                externalOffset: target.flatMap(\.externalCallOffset).map(Int.init),
                externalLocation: ExactLocation(
                    file: "/dependency/src/slice.rs",
                    byteOffset: 40,
                    line: 4,
                    column: 5
                )
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
                )
            )
        } else {
            delegate = AppDelegate(startedAt: startedAt)
        }
        app.delegate = delegate
        withExtendedLifetime(delegate) {
            if let exactRoot {
                delegate.runExactSelfTest(root: exactRoot)
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
            } else if arguments.contains("--self-test") {
                delegate.runSelfTest()
            } else {
                app.run()
            }
        }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation,
    NSMenuDelegate
{
    private let startedAt: ContinuousClock.Instant
    private let model: AppModel
    private let recentProjectsStore = RecentProjectsStore()
    private var readerSettings = ReaderSettings(defaults: .standard)
    private var windowController: MainWindowController?
    private var settingsWindowController: ReaderSettingsWindowController?

    init(startedAt: ContinuousClock.Instant, model: AppModel = AppModel()) {
        self.startedAt = startedAt
        self.model = model
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        launch(offscreen: false)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.exactCoordinator.shutdown()
    }

    func runSelfTest() {
        launch(offscreen: true, measuresIdleFootprint: true)
        let coldStartMS = milliseconds(since: startedAt)
        guard let windowController, windowController.window?.isVisible == true else {
            Darwin.exit(1)
        }
        windowController.window?.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.35))
        guard let footprint = physicalFootprintBytes() else { Darwin.exit(1) }
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

        windowController.applyPanelPreset(.reading)
        pumpRunLoop()
        let appMenu = NSApplication.shared.mainMenu?.items.first?.submenu
        var checks = [
            "darkChromeMatchesTheme": darkChromeMatchesTheme,
            "lightChromeMatchesTheme": lightChromeMatchesTheme,
            "siClassicChromeStaysLight": siClassicChromeStaysLight,
            "autoChromeFollowsSystem": autoChromeFollowsSystem,
            "filesPlaceholderVisibleWithoutProject":
                windowController.selfTestFilesPlaceholderVisible,
            "filesPlaceholderTextWithoutProject":
                windowController.selfTestFilesPlaceholderText == "No project open",
            "filesOpenProjectButtonVisibleWithoutProject":
                windowController.selfTestFilesOpenProjectButtonVisible,
            "filesOpenProjectButtonTitle":
                windowController.selfTestFilesOpenProjectButtonTitle
                == "Open Project…",
            "outlinePlaceholderVisibleWithoutFile":
                windowController.selfTestOutlinePlaceholderVisible,
            "outlinePlaceholderTextWithoutFile":
                windowController.selfTestOutlinePlaceholderText == "No file open",
            "contextPlaceholderVisibleWithoutCandidate":
                windowController.selfTestContextPlaceholderVisible,
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
            "windowTitleIsCairn": windowController.window?.title == "Cairn",
        ]
        windowController.applyPanelPreset(.relations)
        pumpRunLoop()
        checks["relationsPlaceholderVisibleWithoutRoot"] =
            windowController.selfTestRelationsPlaceholderVisible
        checks["relationsPlaceholderTextWithoutRoot"] =
            windowController.selfTestRelationsPlaceholderText
            == "Right-click a symbol → Show Callers / Calls / Implements"
        checks.merge(layout.checks) { _, new in new }
        Self.finishSelfTest(
            coldStartMS: coldStartMS,
            idleFootprintMB: idleFootprintMB,
            checks: checks,
            enlargedWindowGeometry: layout.geometry
        )
    }

    func runProjectSelfTest(root: URL) {
        launch(offscreen: true)
        let projectStartedAt = ContinuousClock.now
        windowController?.openProject(root: root)
        let filesLoadingPlaceholderVisibleDuringIndexing =
            windowController?.selfTestFilesPlaceholderVisible == true
            && windowController?.selfTestFilesPlaceholderText == "Loading files…"
        let filesSpinnerVisibleDuringIndexing =
            windowController?.selfTestFilesLoadingIndicatorVisible == true
        var indexStatusVisibleDuringIndexing = false
        var indexStatusTextDuringIndexing = ""
        func recordIndexStatus() {
            guard let windowController,
                  windowController.selfTestIndexStatusVisible,
                  windowController.selfTestIndexStatusText.contains("Files")
            else { return }
            indexStatusVisibleDuringIndexing = true
            indexStatusTextDuringIndexing = windowController.selfTestIndexStatusText
        }
        recordIndexStatus()
        let deadline = Date(timeIntervalSinceNow: 30)
        while model.fileTree == nil, Date() < deadline {
            if case .failed = model.projectState { break }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
            recordIndexStatus()
        }
        let treeVisibleMS = milliseconds(since: projectStartedAt)
        let fileCount = model.fileTree?.fileCount ?? 0
        var ready = false
        var reused = 0
        var extracted = 0
        while Date() < deadline {
            switch model.projectState {
            case let .ready(session, _):
                ready = true
                reused = session.stats.reusedCount
                extracted = session.stats.extractedCount
            case .failed:
                Self.finishProjectSelfTest(
                    treeVisibleMS: treeVisibleMS,
                    indexReadyMS: milliseconds(since: projectStartedAt),
                    fileCount: fileCount,
                    reused: reused,
                    extracted: extracted,
                    ready: false,
                    emptyStateRemoved: false,
                    readerDocumentVisible: false
                )
            default:
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
                recordIndexStatus()
            }
            if ready { break }
        }
        let indexReadyMS = milliseconds(since: projectStartedAt)
        _ = waitUntil(timeout: 5) { !self.model.commitPicker.isLoading }
        windowController?.window?.contentView?.layoutSubtreeIfNeeded()
        let emptyStateRemoved = windowController?.selfTestEmptyStateExists == false
        let readerDocumentVisible = windowController?
            .selfTestReaderDocumentVisibleInWindow == true
        let statusBarVisibleAfterReady = waitUntil(timeout: 5) {
            self.windowController?.selfTestStatusBarVisible == true
        }
        let indexStatusHiddenAfterFullReady = waitUntil(timeout: 5) {
            self.windowController?.selfTestIndexStatusVisible == false
        }
        let filesPlaceholderHiddenAfterReady =
            windowController?.selfTestFilesPlaceholderVisible == false
            && windowController?.selfTestFilesContentVisible == true
        let outlinePlaceholderVisibleWithoutFile =
            windowController?.selfTestOutlinePlaceholderVisible == true
            && windowController?.selfTestOutlinePlaceholderText == "No file open"

        let loader = DocumentLoader()
        let outlineEmptyFile = rustFiles(in: model.fileTree?.children ?? []).first {
            guard let loaded = try? loader.load(file: $0) else { return false }
            return loaded.tier == .regular
                && loaded.document.outlineFacets.isEmpty
        }
        let outlineNoSymbolsPlaceholderVisible: Bool?
        if let outlineEmptyFile,
           windowController?.selectFileInSidebar(outlineEmptyFile) == true,
           waitUntil(timeout: 5, condition: {
               self.windowController?.displayedReaderFile?.standardizedFileURL
                   == outlineEmptyFile.standardizedFileURL
           })
        {
            outlineNoSymbolsPlaceholderVisible = waitUntil(timeout: 5) {
                self.windowController?.selfTestOutlinePlaceholderVisible == true
                    && self.windowController?.selfTestOutlinePlaceholderText
                        == "No symbols in this file"
            }
        } else {
            outlineNoSymbolsPlaceholderVisible = nil
        }
        let outlineFile = rustFiles(in: model.fileTree?.children ?? []).first {
            guard let loaded = try? loader.load(file: $0) else { return false }
            return !loaded.document.outlineFacets.isEmpty
        }
        let outlinePlaceholderHiddenWithContent: Bool
        if let outlineFile,
           windowController?.selectFileInSidebar(outlineFile) == true,
           waitUntil(timeout: 5, condition: {
               self.windowController?.displayedReaderFile?.standardizedFileURL
                   == outlineFile.standardizedFileURL
           })
        {
            outlinePlaceholderHiddenWithContent = waitUntil(timeout: 5) {
                self.windowController?.selfTestOutlinePlaceholderVisible == false
                    && self.windowController?.selfTestOutlineContentVisible == true
            }
        } else {
            outlinePlaceholderHiddenWithContent = false
        }
        let layout = windowController.map {
            enlargedWindowLayout(controller: $0, statusBarOccupancyHeight: 24)
        }
        let branchName = currentBranchName(repositoryURL: root)
        let commitTitle = windowController?.selfTestCommitButtonTitle ?? ""
        let commitTitleMatchesRepository: Bool
        if (try? GitRepository(url: root)) != nil {
            commitTitleMatchesRepository = branchName.map {
                commitTitle.hasPrefix("⎇ ") && commitTitle.contains($0)
            } == true
        } else {
            commitTitleMatchesRepository = commitTitle == "Working Tree"
                && !commitTitle.contains("⎇")
        }
        let commitPickerShowsCurrentBranch = commitTitleMatchesRepository
            && windowController?.selfTestCommitToolbarItemExistsAndVisible == true
        var projectChecks = layout?.checks ?? [:]
        projectChecks.merge([
            "filesLoadingPlaceholderVisibleDuringIndexing":
                filesLoadingPlaceholderVisibleDuringIndexing,
            "filesSpinnerVisibleDuringIndexing":
                filesSpinnerVisibleDuringIndexing,
            "filesPlaceholderHiddenAfterReady":
                filesPlaceholderHiddenAfterReady,
            "outlinePlaceholderVisibleWithoutFile":
                outlinePlaceholderVisibleWithoutFile,
            "outlinePlaceholderHiddenWithContent":
                outlinePlaceholderHiddenWithContent,
        ]) { _, new in new }
        if let outlineNoSymbolsPlaceholderVisible {
            projectChecks["outlineNoSymbolsPlaceholderVisible"] =
                outlineNoSymbolsPlaceholderVisible
        }
        model.flushPersistentIndexCache()
        Self.finishProjectSelfTest(
            treeVisibleMS: treeVisibleMS,
            indexReadyMS: indexReadyMS,
            fileCount: fileCount,
            reused: reused,
            extracted: extracted,
            ready: ready,
            emptyStateRemoved: emptyStateRemoved,
            readerDocumentVisible: readerDocumentVisible,
            branchName: branchName,
            commitTitle: commitTitle,
            commitPickerShowsCurrentBranch: commitPickerShowsCurrentBranch,
            indexStatusVisibleDuringIndexing: indexStatusVisibleDuringIndexing,
            indexStatusTextDuringIndexing: indexStatusTextDuringIndexing,
            statusBarVisibleAfterReady: statusBarVisibleAfterReady,
            indexStatusHiddenAfterFullReady: indexStatusHiddenAfterFullReady,
            layoutChecks: projectChecks,
            enlargedWindowGeometry: layout?.geometry ?? [:]
        )
    }

    func runDiffSelfTest(root: URL) -> Never {
        launch(offscreen: true)
        guard let controller = windowController else {
            finishDiffSelfTest(error: "window unavailable")
        }
        controller.openProject(root: root)
        guard waitUntil(timeout: 30, condition: {
            if case .failed = self.model.projectState { return true }
            if case .ready = self.model.projectState {
                return !self.model.commitPicker.isLoading
            }
            return false
        }),
        case .ready = model.projectState,
        model.commitPicker.errorMessage == nil,
        model.commitPicker.commits.indices.contains(1)
        else {
            finishDiffSelfTest(error: "project or HEAD~1 unavailable")
        }
        emitDiffStep("openProject", controller: controller)

        let revision = model.commitPicker.commits[1].fullSHA
        let snapshot: CommitSnapshot
        let target: DiffSelfTestTarget
        do {
            snapshot = try CommitSnapshot(repositoryURL: root, revision: revision)
            guard let found = diffSelfTestTarget(root: root, snapshot: snapshot) else {
                finishDiffSelfTest(error: "no multi-line file differs from HEAD~1")
            }
            target = found
        } catch {
            finishDiffSelfTest(error: error.localizedDescription)
        }

        controller.openFileForSelfTest(target.file)
        guard waitUntil(timeout: 5, condition: {
            self.model.selectedFile == target.file
                && controller.displayedReaderFile == target.file
        }) else {
            finishDiffSelfTest(error: "left reader did not open target file")
        }
        emitDiffStep("openFile", controller: controller, extra: [
            "file": target.path,
            "worktreeByteCount": target.worktreeBytes.count,
        ])

        controller.applyPanelPreset(.compare)
        guard controller.selectCompareCommit(revision),
              waitUntil(timeout: 30, condition: {
                  self.model.compare.rightRevision == revision
                      && self.model.compare.diff != nil
                      && controller.selfTestRightReaderBytes != nil
              })
        else {
            finishDiffSelfTest(error: "right CommitPicker selection did not finish")
        }
        pumpRunLoop()

        let rightReaderMatchesCommitBlob = controller.selfTestRightReaderBytes
            == target.commitBytes
        let rightReaderDiffersFromWorktree = controller.selfTestRightReaderBytes
            != target.worktreeBytes
        emitDiffStep("selectHEAD~1", controller: controller, extra: [
            "revision": revision,
            "rightReaderByteCount": controller.selfTestRightReaderBytes?.count ?? 0,
            "commitBlobByteCount": target.commitBytes.count,
            "rightReaderMatchesCommitBlob": rightReaderMatchesCommitBlob,
            "rightReaderDiffersFromWorktree": rightReaderDiffersFromWorktree,
        ])

        let actualGutterCounts = controller.selfTestGutterCounts
        let expectedGutterCounts = target.expected.gutterCounts
        let gutterCountsMatch = actualGutterCounts == expectedGutterCounts
        var diffComputeMS = Double.greatestFiniteMagnitude
        for _ in 0 ..< 5 {
            let diffClock = ContinuousClock.now
            _ = DiffCore().compare(left: target.worktreeBytes, right: target.commitBytes)
            diffComputeMS = min(diffComputeMS, milliseconds(since: diffClock))
        }
        emitDiffStep("gutter", controller: controller, extra: [
            "gutterCounts": Self.jsonGutterCounts(actualGutterCounts),
            "expectedGutterCounts": Self.jsonGutterCounts(expectedGutterCounts),
            "gutterCountsMatch": gutterCountsMatch,
            "diffComputeMS": diffComputeMS,
            "leftLineCount": target.expected.leftLineCount,
            "rightLineCount": target.expected.rightLineCount,
        ])

        let navigation = controller.selfTestNavigateNextDiffHunk()
        pumpRunLoop()
        let hunkNavMoved = navigation.before != nil
            && navigation.after != nil
            && navigation.before != navigation.after
            && model.compare.selectedHunkIndex == 0
        emitDiffStep("nextHunk", controller: controller, extra: [
            "beforeLine": (navigation.before as Any?) ?? NSNull(),
            "afterLine": (navigation.after as Any?) ?? NSNull(),
            "selectedHunkIndex": (model.compare.selectedHunkIndex as Any?) ?? NSNull(),
            "hunkNavMoved": hunkNavMoved,
        ])

        controller.applyPanelPreset(.reading)
        pumpRunLoop()
        let readingPresetCollapsedRight = controller.selfTestSecondaryReaderCollapsed
        emitDiffStep("readingPreset", controller: controller, extra: [
            "rightReaderCollapsed": readingPresetCollapsedRight,
        ])

        let leftReaderBytesBeforeClear = controller.selfTestLeftReaderBytes
        model.clearCompare()
        pumpRunLoop()
        var siClassicSettings = readerSettings
        siClassicSettings.theme = .siClassic
        controller.applyReaderSettings(siClassicSettings)
        pumpRunLoop()
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.window?.displayIfNeeded()
        let themeSwitchPreservedLeftReader = controller.selfTestLeftReaderBytes
            == leftReaderBytesBeforeClear
        let themeSwitchClearedRightReader = controller.selfTestRightReaderBytes == nil
        emitDiffStep("clearCompareAndApplySIClassic", controller: controller, extra: [
            "themeSwitchPreservedLeftReader": themeSwitchPreservedLeftReader,
            "themeSwitchClearedRightReader": themeSwitchClearedRightReader,
        ])

        finishDiffSelfTest(
            controller: controller,
            checks: [
                "rightReaderMatchesCommitBlob": rightReaderMatchesCommitBlob,
                "rightReaderDiffersFromWorktree": rightReaderDiffersFromWorktree,
                "gutterCountsMatch": gutterCountsMatch,
                "hunkNavMoved": hunkNavMoved,
                "readingPresetCollapsedRight": readingPresetCollapsedRight,
                "themeSwitchPreservedLeftReader": themeSwitchPreservedLeftReader,
                "themeSwitchClearedRightReader": themeSwitchClearedRightReader,
            ],
            gutterCounts: actualGutterCounts
        )
    }

    private func diffSelfTestTarget(
        root: URL,
        snapshot: CommitSnapshot
    ) -> DiffSelfTestTarget? {
        let candidates = snapshot.listFiles().map(\.path).filter {
            let ext = URL(fileURLWithPath: $0).pathExtension
            return ext == "rs" || ext == "swift"
        }.sorted {
            let leftRust = $0.hasSuffix(".rs")
            let rightRust = $1.hasSuffix(".rs")
            return leftRust == rightRust ? $0 < $1 : leftRust
        }
        for path in candidates {
            let file = root.appendingPathComponent(path).standardizedFileURL
            guard let worktree = try? Array(Data(contentsOf: file)),
                  let committed = try? snapshot.readBytes(path: path),
                  worktree != committed
            else { continue }
            let expected = DiffCore().compare(left: worktree, right: committed)
            guard !expected.truncated,
                  !expected.hunks.isEmpty,
                  max(expected.leftLineCount, expected.rightLineCount) > 1
            else { continue }
            return DiffSelfTestTarget(
                file: file,
                path: path,
                worktreeBytes: worktree,
                commitBytes: committed,
                expected: expected
            )
        }
        return nil
    }

    private func emitDiffStep(
        _ step: String,
        controller: MainWindowController?,
        extra: [String: Any] = [:]
    ) {
        var object: [String: Any] = [
            "step": step,
            "leftRevision": model.currentRevision ?? "worktree",
            "rightRevision": (model.compare.rightRevision as Any?) ?? NSNull(),
            "file": (model.selectedFile?.path as Any?) ?? NSNull(),
            "hunkCount": model.compare.diff?.hunks.count ?? 0,
            "rightReaderCollapsed": controller?.selfTestSecondaryReaderCollapsed ?? true,
        ]
        for (key, value) in extra { object[key] = value }
        Self.writeJSON(object)
    }

    private func finishDiffSelfTest(
        controller: MainWindowController? = nil,
        checks: [String: Bool] = [:],
        gutterCounts: [DiffCore.MarkerKind: Int] = [:],
        error: String? = nil
    ) -> Never {
        let passed = error == nil
            && !checks.isEmpty
            && checks.values.allSatisfy { $0 }
        var summary: [String: Any] = checks
        summary["step"] = "summary"
        summary["passed"] = passed
        summary["gutterCounts"] = Self.jsonGutterCounts(gutterCounts)
        summary["rightReaderCollapsed"] = controller?.selfTestSecondaryReaderCollapsed
            ?? true
        if let error { summary["error"] = error }
        Self.writeJSON(summary)
        Darwin.exit(passed ? 0 : 1)
    }

    private static func jsonGutterCounts(
        _ counts: [DiffCore.MarkerKind: Int]
    ) -> [String: Int] {
        [
            "added": counts[.added] ?? 0,
            "removed": counts[.removed] ?? 0,
            "changed": counts[.changed] ?? 0,
        ]
    }

    func runHistorySelfTest(root: URL) -> Never {
        launch(offscreen: true)
        guard let windowController else {
            Self.finishHistorySelfTest(
                selectionSynchronized: false,
                switchEnteredHistory: false,
                navigationSequence: false,
                error: "window unavailable"
            )
        }

        windowController.openProject(root: root)
        guard waitUntil(timeout: 30, condition: {
            if case .failed = self.model.projectState { return true }
            if case .ready = self.model.projectState {
                return !self.model.commitPicker.isLoading
            }
            return false
        }),
        case .ready = model.projectState,
        model.commitPicker.errorMessage == nil
        else {
            Self.finishHistorySelfTest(
                selectionSynchronized: false,
                switchEnteredHistory: false,
                navigationSequence: false,
                error: "project or commit history unavailable"
            )
        }

        var selectionSynchronized = emitHistoryStep(
            "openProject",
            controller: windowController
        )
        guard let fileA = rustFiles(in: model.fileTree?.children ?? []).first,
              waitUntil(timeout: 5, condition: {
                  windowController.selectFileInSidebar(fileA)
              }),
              waitUntil(timeout: 5, condition: {
                  self.model.selectedFile == fileA
                      && windowController.displayedReaderFile == fileA
              })
        else {
            Self.finishHistorySelfTest(
                selectionSynchronized: false,
                switchEnteredHistory: false,
                navigationSequence: false,
                error: "could not open file A through the sidebar"
            )
        }
        selectionSynchronized = emitHistoryStep(
            "openA",
            controller: windowController
        ) && selectionSynchronized

        guard model.commitPicker.commits.indices.contains(1) else {
            Self.finishHistorySelfTest(
                selectionSynchronized: selectionSynchronized,
                switchEnteredHistory: false,
                navigationSequence: false,
                error: "HEAD~1 unavailable"
            )
        }
        let previousRevision = model.commitPicker.commits[1].fullSHA
        guard windowController.selectCommit(previousRevision),
              waitUntil(timeout: 30, condition: {
                  self.model.currentRevision == previousRevision
                      && self.model.snapshotPhase == .fullReady
              })
        else {
            Self.finishHistorySelfTest(
                selectionSynchronized: selectionSynchronized,
                switchEnteredHistory: false,
                navigationSequence: false,
                error: "commit switch did not complete"
            )
        }
        pumpRunLoop()
        let switchEnteredHistory = model.navigationHistory.canGoBack
        selectionSynchronized = emitHistoryStep(
            "switchHEAD~1",
            controller: windowController
        ) && selectionSynchronized

        guard let fileB = rustFiles(in: model.fileTree?.children ?? []).first(where: {
            $0.standardizedFileURL != fileA.standardizedFileURL
        }),
        windowController.selectFileInSidebar(fileB),
        waitUntil(timeout: 5, condition: {
            self.model.selectedFile == fileB
                && windowController.displayedReaderFile == fileB
        })
        else {
            Self.finishHistorySelfTest(
                selectionSynchronized: false,
                switchEnteredHistory: switchEnteredHistory,
                navigationSequence: false,
                error: "could not open file B through the sidebar"
            )
        }
        selectionSynchronized = emitHistoryStep(
            "openB",
            controller: windowController
        ) && selectionSynchronized

        var navigationSequence = historyStateMatches(
            revision: previousRevision,
            file: fileB,
            controller: windowController
        )
        navigationSequence = performHistoryNavigation(
            { windowController.goBack(nil) },
            revision: previousRevision,
            file: fileA
        ) && navigationSequence
        selectionSynchronized = emitHistoryStep(
            "back1",
            controller: windowController
        ) && selectionSynchronized
        navigationSequence = performHistoryNavigation(
            { windowController.goBack(nil) },
            revision: nil,
            file: fileA
        ) && navigationSequence
        selectionSynchronized = emitHistoryStep(
            "back2",
            controller: windowController
        ) && selectionSynchronized
        navigationSequence = performHistoryNavigation(
            { windowController.goForward(nil) },
            revision: previousRevision,
            file: fileA
        ) && navigationSequence
        selectionSynchronized = emitHistoryStep(
            "forward1",
            controller: windowController
        ) && selectionSynchronized
        navigationSequence = performHistoryNavigation(
            { windowController.goForward(nil) },
            revision: previousRevision,
            file: fileB
        ) && navigationSequence
        selectionSynchronized = emitHistoryStep(
            "forward2",
            controller: windowController
        ) && selectionSynchronized

        Self.finishHistorySelfTest(
            selectionSynchronized: selectionSynchronized,
            switchEnteredHistory: switchEnteredHistory,
            navigationSequence: navigationSequence,
            error: nil
        )
    }

    func runPinSelfTest(root: URL) -> Never {
        launch(offscreen: true)
        guard let windowController else {
            finishPinSelfTest(controller: nil, error: "window unavailable")
        }

        windowController.openProject(root: root)
        guard waitUntil(timeout: 30, condition: {
            if case .failed = self.model.projectState { return true }
            if case .ready = self.model.projectState { return true }
            return false
        }), case .ready = model.projectState
        else {
            finishPinSelfTest(
                controller: windowController,
                error: "project unavailable"
            )
        }

        let files = rustFiles(in: model.fileTree?.children ?? [])
        let fixture = root.standardizedFileURL.appendingPathComponent(
            "Tests/RustExtractorTests/Fixtures/alias_cross_file_negative",
            isDirectory: true
        )
        let expectedFiles = ["a.rs", "b.rs", "main.rs"].map {
            fixture.appendingPathComponent($0).standardizedFileURL
        }
        let fileA = expectedFiles[0]
        let fileB = expectedFiles[1]
        let mainFile = expectedFiles[2]
        guard expectedFiles.allSatisfy(files.contains),
              let aBytes = try? Data(contentsOf: fileA),
              let bBytes = try? Data(contentsOf: fileB),
              let mainBytes = try? Data(contentsOf: mainFile),
              let realRange = aBytes.range(of: Data("real".utf8)),
              let localCallRange = bBytes.range(of: Data("y();".utf8)),
              let callerRange = bBytes.range(of: Data("call_local".utf8)),
              let mainCallRange = mainBytes.range(of: Data("y();".utf8)),
              let realOffset = UInt32(exactly: realRange.lowerBound),
              let localCallOffset = UInt32(exactly: localCallRange.lowerBound),
              let callerOffset = UInt32(exactly: callerRange.lowerBound),
              let mainCallOffset = UInt32(exactly: mainCallRange.lowerBound)
        else {
            finishPinSelfTest(
                controller: windowController,
                error: "expected a.rs, b.rs, and main.rs fixture symbols"
            )
        }

        guard waitUntil(timeout: 5, condition: {
                  windowController.selectFileInSidebar(fileB)
              }),
              waitUntil(timeout: 5, condition: {
                  windowController.displayedReaderFile?.standardizedFileURL
                      == fileB.standardizedFileURL
              })
        else {
            finishPinSelfTest(
                controller: windowController,
                error: "could not open b.rs"
            )
        }
        windowController.selfTestReaderClick(
            offset: localCallOffset,
            commandClick: false
        )
        guard waitUntil(timeout: 5, condition: { self.pinContextSummary != nil }),
              let initialContext = pinContextSummary
        else {
            finishPinSelfTest(
                controller: windowController,
                error: "initial context did not load"
            )
        }
        let contextPlaceholderHiddenWithContent =
            !windowController.selfTestContextPlaceholderVisible
            && windowController.selfTestContextReaderVisible
        emitPinStep(
            "contextLoaded",
            controller: windowController,
            extra: [
                "contextPlaceholderHiddenWithContent":
                    contextPlaceholderHiddenWithContent,
            ]
        )

        let relationBeforeFollow = pinRelationRootSummary
        windowController.selfTestReaderRelation(
            offset: callerOffset,
            direction: .callers
        )
        let followRelationSet = waitUntil(timeout: 5, condition: {
            self.pinRelationRootSummary != relationBeforeFollow
                && self.pinRelationRootSummary != nil
        })
        pumpRunLoop()
        windowController.applyPanelPreset(.relations)
        pumpRunLoop()
        let relationsPlaceholderHiddenWithRoot =
            !windowController.selfTestRelationsPlaceholderVisible
            && windowController.selfTestRelationsTreeVisible
        windowController.applyPanelPreset(.reading)
        pumpRunLoop()
        let followRelationPreservedContext = pinContextSummary == initialContext
        emitPinStep(
            "followShowCallers",
            controller: windowController,
            extra: [
                "relationRootSet": followRelationSet,
                "contextPreserved": followRelationPreservedContext,
                "relationsPlaceholderHiddenWithRoot":
                    relationsPlaceholderHiddenWithRoot,
            ]
        )

        guard windowController.selectFileInSidebar(mainFile),
              waitUntil(timeout: 5, condition: {
                  windowController.displayedReaderFile?.standardizedFileURL
                      == mainFile.standardizedFileURL
              })
        else {
            finishPinSelfTest(
                controller: windowController,
                error: "could not open main.rs"
            )
        }
        windowController.selfTestSetContextPinned(true)
        let pinnedContext = pinContextSummary
        let readerBeforeCommandClick = windowController.displayedReaderFile
        windowController.selfTestReaderClick(
            offset: mainCallOffset,
            commandClick: true
        )
        let commandClickNavigated = waitUntil(timeout: 5, condition: {
            windowController.displayedReaderFile?.standardizedFileURL
                == fileA.standardizedFileURL
        }) && readerBeforeCommandClick?.standardizedFileURL
            != windowController.displayedReaderFile?.standardizedFileURL
        pumpRunLoop()
        let commandClickPreservedContext = pinContextSummary == pinnedContext
        emitPinStep(
            "pinnedCommandClick",
            controller: windowController,
            extra: [
                "readerChanged": commandClickNavigated,
                "contextPreserved": commandClickPreservedContext,
            ]
        )

        let relationBeforePinned = pinRelationRootSummary
        windowController.selfTestReaderRelation(
            offset: realOffset,
            direction: .callers
        )
        let pinnedRelationChanged = waitUntil(timeout: 5, condition: {
            self.pinRelationRootSummary != relationBeforePinned
                && self.pinRelationRootSummary != nil
        })
        pumpRunLoop()
        let pinnedRelationPreservedContext = pinContextSummary == pinnedContext
        emitPinStep(
            "pinnedShowCallers",
            controller: windowController,
            extra: [
                "relationRootChanged": pinnedRelationChanged,
                "contextPreserved": pinnedRelationPreservedContext,
            ]
        )

        windowController.selfTestSetContextPinned(false)
        windowController.selfTestReaderClick(offset: realOffset, commandClick: false)
        let followUpdatedContext = waitUntil(timeout: 5, condition: {
            self.pinContextSummary != nil && self.pinContextSummary != pinnedContext
        })
        pumpRunLoop()
        emitPinStep(
            "followClick",
            controller: windowController,
            extra: ["contextChanged": followUpdatedContext]
        )

        finishPinSelfTest(
            controller: windowController,
            checks: [
                "initialContextLoaded": true,
                "contextPlaceholderHiddenWithContent":
                    contextPlaceholderHiddenWithContent,
                "relationsPlaceholderHiddenWithRoot":
                    relationsPlaceholderHiddenWithRoot,
                "followRelationSet": followRelationSet,
                "followRelationPreservedContext": followRelationPreservedContext,
                "commandClickNavigated": commandClickNavigated,
                "commandClickPreservedContext": commandClickPreservedContext,
                "pinnedRelationChanged": pinnedRelationChanged,
                "pinnedRelationPreservedContext": pinnedRelationPreservedContext,
                "followUpdatedContext": followUpdatedContext,
            ]
        )
    }

    func runExactSelfTest(root: URL) -> Never {
        launch(offscreen: true)
        let projectRoot = exactSelfTestFixtureRoot(root: root)
        guard let windowController,
              let target = exactSelfTestTarget(root: projectRoot)
        else {
            finishExactSelfTest(
                controller: windowController,
                checks: [:],
                realProvider: "not-run",
                error: "exact self-test target unavailable"
            )
        }

        windowController.openProject(root: projectRoot)
        guard waitUntil(timeout: 30, condition: {
            if case .failed = self.model.projectState { return true }
            if case .ready = self.model.projectState { return true }
            return false
        }), case .ready = model.projectState else {
            finishExactSelfTest(
                controller: windowController,
                checks: [:],
                realProvider: "not-run",
                error: "project unavailable"
            )
        }
        let initialStatusSafe = waitUntil(timeout: 5, condition: {
            model.exactCoordinator.readiness == .ready
                && windowController.selfTestExactStatusVisible
                && windowController.selfTestExactStatusText.contains("Safe")
        })
        let initialProfileTitle =
            "Rust · \(projectRoot.lastPathComponent) · Safe"
        let initialProfileVisible = waitUntil(timeout: 5, condition: {
            windowController.selfTestProfileToolbarItemExistsAndVisible
                && windowController.selfTestProfileTitle == initialProfileTitle
        })
        emitExactStep(
            "initial-status",
            variant: "fake",
            controller: windowController,
            extra: [
                "profileVisible": initialProfileVisible,
                "profileTitle": windowController.selfTestProfileTitle,
            ]
        )
        guard waitUntil(timeout: 5, condition: {
                  windowController.selectFileInSidebar(target.file)
              }),
              waitUntil(timeout: 5, condition: {
                  windowController.displayedReaderFile?.standardizedFileURL
                      == target.file.standardizedFileURL
              })
        else {
            finishExactSelfTest(
                controller: windowController,
                checks: [:],
                realProvider: "not-run",
                error: "could not open exact self-test file"
                    + " (treeContainsTarget="
                    + "\(model.fileTree?.selectionPath(for: target.file) != nil))"
            )
        }

        let clickedAt = ContinuousClock.now
        windowController.selfTestReaderClick(
            offset: target.clickOffset,
            commandClick: false
        )
        let fuzzyVisible = waitUntil(timeout: 5, condition: {
            windowController.selfTestContextCandidateCount >= 1
                && windowController.selfTestContextProvenance?.contains("Exact") == false
        })
        let fuzzyFirstAnswerMS = milliseconds(since: clickedAt)
        let fuzzyCount = windowController.selfTestContextCandidateCount
        emitExactStep(
            "fuzzy",
            variant: "fake",
            controller: windowController,
            extra: ["fuzzyFirstAnswerMS": fuzzyFirstAnswerMS]
        )

        let exactVisible = waitUntil(timeout: 5, condition: {
            windowController.selfTestContextProvenance?.contains("Exact") == true
        })
        let exactUpgradeMS = milliseconds(since: clickedAt)
        let fuzzyRetained = windowController.selfTestContextCandidateCount >= fuzzyCount
        emitExactStep(
            "exact",
            variant: "fake",
            controller: windowController,
            extra: ["exactUpgradeMS": exactUpgradeMS]
        )
        let exactSummary = windowController.selfTestContextSummary
        let exactCount = windowController.selfTestContextCandidateCount

        let relationFileVisible = waitUntil(timeout: 5, condition: {
            windowController.selectFileInSidebar(target.relationFile)
        }) && waitUntil(timeout: 5, condition: {
            windowController.displayedReaderFile?.standardizedFileURL
                == target.relationFile.standardizedFileURL
        })
        if relationFileVisible {
            windowController.selfTestReaderRelation(
                offset: target.relationCallOffset,
                direction: .callers
            )
        }
        let exactGroupVisible = waitUntil(timeout: 5, condition: {
            windowController.selfTestExactGroupRowCount > 0
        })
        let exactGroupHeaderHonest = windowController.selfTestExactGroupTitle == "Exact"
        let exactStatusVisible = windowController.selfTestExactStatusText
            .contains("Exact:")
            && windowController.selfTestExactStatusVisible
        emitExactStep(
            "relations",
            variant: "fake",
            controller: windowController
        )

        windowController.selfTestSetContextPinned(true)
        let pinnedStable = waitUntil(timeout: 5, condition: {
            windowController.selfTestContextPinned
                && windowController.selfTestContextSummary == exactSummary
                && windowController.selfTestContextCandidateCount == exactCount
        })
        emitExactStep(
            "pinnedExact",
            variant: "fake",
            controller: windowController
        )

        let selectedForDirection = windowController.selfTestSelectRelationEdge(
            titled: "relation_root"
        )
        let directionGeneration = model.relationTree.generation
        if selectedForDirection {
            windowController.selfTestChangeRelationDirection(.calls)
        }
        let selectedEdgeDrivesRoot = waitUntil(timeout: 5, condition: {
            model.relationTree.root?.title == "relation_root"
                && model.relationTree.direction == .calls
        })
        let directionGenerationIncremented =
            model.relationTree.generation > directionGeneration
        emitExactStep(
            "relation-direction-root",
            variant: "fake",
            controller: windowController,
            extra: [
                "selectedEdge": selectedForDirection,
                "rootTitle": model.relationTree.root?.title ?? "",
                "generationIncremented": directionGenerationIncremented,
            ]
        )

        windowController.selfTestReaderRelation(
            offset: target.relationCallOffset,
            direction: .callers
        )
        let deselectRootReady = waitUntil(timeout: 5, condition: {
            model.relationTree.root?.title == "answer"
                && model.relationTree.direction == .callers
                && windowController.selfTestExactGroupRowCount > 0
        })
        let selectedForDeselect = deselectRootReady
            && windowController.selfTestSelectRelationEdge(titled: "relation_root")
        let contextBeforeDeselect = (
            summary: windowController.selfTestContextSummary,
            provenance: windowController.selfTestContextProvenance,
            candidateCount: windowController.selfTestContextCandidateCount,
            pinned: windowController.selfTestContextPinned
        )
        windowController.selfTestDeselectRelation()
        let deselectPreservedContext =
            windowController.selfTestContextSummary == contextBeforeDeselect.summary
            && windowController.selfTestContextProvenance
                == contextBeforeDeselect.provenance
            && windowController.selfTestContextCandidateCount
                == contextBeforeDeselect.candidateCount
            && windowController.selfTestContextPinned == contextBeforeDeselect.pinned
        if selectedForDeselect {
            windowController.selfTestChangeRelationDirection(.calls)
        }
        let deselectedRootPreserved = waitUntil(timeout: 5, condition: {
            model.relationTree.root?.title == "answer"
                && model.relationTree.direction == .calls
        })
        emitExactStep(
            "relation-deselect-root",
            variant: "fake",
            controller: windowController,
            extra: [
                "selectedEdge": selectedForDeselect,
                "rootTitle": model.relationTree.root?.title ?? "",
                "contextPreserved": deselectPreservedContext,
            ]
        )

        windowController.selfTestReaderRelation(
            offset: target.relationCallOffset,
            direction: .callers
        )
        let answerCallersReady = waitUntil(timeout: 5, condition: {
            model.relationTree.root?.title == "answer"
                && model.relationTree.direction == .callers
                && windowController.selfTestExactGroupRowCount > 0
        })
        let selectedForOpen = answerCallersReady
            && windowController.selfTestSelectRelationEdge(titled: "main")
        let openGeneration = model.relationTree.generation
        if selectedForOpen {
            windowController.selfTestOpenRelationSelection()
        }
        let doubleClickNavigatesAndSetsRoot = waitUntil(timeout: 5, condition: {
            windowController.displayedReaderFile?.standardizedFileURL
                == target.file.standardizedFileURL
                && model.relationTree.root?.title == "main"
                && model.relationTree.generation > openGeneration
        })
        emitExactStep(
            "relation-double-click",
            variant: "fake",
            controller: windowController,
            extra: [
                "selectedEdge": selectedForOpen,
                "rootTitle": model.relationTree.root?.title ?? "",
                "navigated": windowController.displayedReaderFile?.standardizedFileURL
                    == target.file.standardizedFileURL,
            ]
        )

        let signatureTraitFileVisible = target.signatureTraitOffset != nil
            && waitUntil(timeout: 5, condition: {
                windowController.selectFileInSidebar(target.relationFile)
            }) && waitUntil(timeout: 5, condition: {
                windowController.displayedReaderFile?.standardizedFileURL
                    == target.relationFile.standardizedFileURL
            })
        if signatureTraitFileVisible, let signatureTraitOffset =
            target.signatureTraitOffset
        {
            windowController.selfTestReaderRelation(
                offset: signatureTraitOffset,
                direction: .calls
            )
        }
        let externalGroupVisible = waitUntil(timeout: 5, condition: {
            model.relationTree.root?.title == "Backend"
                && windowController.selfTestExternalGroupTitle != nil
        })
        let externalGroupHeaderHonest =
            windowController.selfTestExternalGroupTitle
                == "EXTERNAL / UNRESOLVED (0)"
        emitExactStep(
            "relation-empty-external",
            variant: "fake",
            controller: windowController,
            extra: [
                "externalGroupTitle":
                    windowController.selfTestExternalGroupTitle ?? "",
                "rootTitle": model.relationTree.root?.title ?? "",
            ]
        )

        let externalDemotionFileVisible = target.externalRootOffset != nil
            && waitUntil(timeout: 5, condition: {
                windowController.selectFileInSidebar(target.relationFile)
            }) && waitUntil(timeout: 5, condition: {
                windowController.displayedReaderFile?.standardizedFileURL
                    == target.relationFile.standardizedFileURL
            })
        if externalDemotionFileVisible,
           let externalRootOffset = target.externalRootOffset
        {
            windowController.selfTestReaderRelation(
                offset: externalRootOffset,
                direction: .calls
            )
        }
        let providerProvenExternalDemoted = waitUntil(timeout: 5, condition: {
            model.relationTree.root?.title == "dependency_call"
                && windowController.selfTestVisibleRelationEdgeTitles(
                    inGroup: "External / Unresolved"
                ).contains("len")
                && !windowController.selfTestVisibleRelationEdgeTitles(
                    inGroup: "Possible"
                ).contains("len")
        })
        let externalDemotionSubtitle =
            windowController.selfTestVisibleRelationEdgeSubtitle(
                titled: "len",
                inGroup: "External / Unresolved"
            )
        let externalDemotionSubtitleHonest =
            externalDemotionSubtitle
                == "External · in dependency (rust-analyzer)"
        emitExactStep(
            "relation-external-demotion",
            variant: "external-demotion-fake",
            controller: windowController,
            extra: [
                "externalTitles": windowController
                    .selfTestVisibleRelationEdgeTitles(
                        inGroup: "External / Unresolved"
                    ),
                "possibleTitles": windowController
                    .selfTestVisibleRelationEdgeTitles(inGroup: "Possible"),
                "subtitle": externalDemotionSubtitle ?? "",
            ]
        )

        let trustRevoke = runTrustRevokeExactVariant()
        let real = runRealExactVariant(root: root)
        let realOffline = runRealOfflineCoverageVariant(root: root)
        let historical = runHistoricalExactVariant()
        var checks = [
            "fuzzyVisible": fuzzyVisible,
            "exactVisible": exactVisible,
            "fuzzyRetained": fuzzyRetained,
            "pinnedTargetStable": pinnedStable,
            "exactGroupVisible": exactGroupVisible,
            "exactGroupHeaderHonest": exactGroupHeaderHonest,
            "exactStatusVisible": exactStatusVisible,
            "initialStatusSafeBeforeClick": initialStatusSafe,
            "initialProfileVisible": initialProfileVisible,
            "initialProfileTitleSafe":
                windowController.selfTestProfileTitle == initialProfileTitle,
            "relationFileVisible": relationFileVisible,
            "selectedForDirection": selectedForDirection,
            "selectedEdgeDrivesRoot": selectedEdgeDrivesRoot,
            "directionGenerationIncremented": directionGenerationIncremented,
            "deselectRootReady": deselectRootReady,
            "selectedForDeselect": selectedForDeselect,
            "deselectedRootPreserved": deselectedRootPreserved,
            "deselectPreservedContext": deselectPreservedContext,
            "answerCallersReady": answerCallersReady,
            "selectedForOpen": selectedForOpen,
            "doubleClickNavigatesAndSetsRoot": doubleClickNavigatesAndSetsRoot,
            "signatureTraitFileVisible": signatureTraitFileVisible,
            "externalGroupVisible": externalGroupVisible,
            "externalGroupHeaderHonest": externalGroupHeaderHonest,
            "externalDemotionFileVisible": externalDemotionFileVisible,
            "providerProvenExternalDemoted": providerProvenExternalDemoted,
            "externalDemotionSubtitleHonest": externalDemotionSubtitleHonest,
            "realProviderPassedOrSkipped": real.passed,
            "realOfflineCoveragePassedOrSkipped": realOffline.passed,
            "historicalExactVisible": historical.exactVisible,
            "historicalInitialStatusSafe": historical.initialStatusSafe,
            "providerRootIsMaterialized": historical.providerRootIsMaterialized,
            "uiPathIsRepoRelative": historical.uiPathIsRepoRelative,
            "historicalProvenanceAttributed": historical.provenanceAttributed,
        ]
        for (key, value) in trustRevoke { checks[key] = value }
        finishExactSelfTest(
            controller: windowController,
            checks: checks,
            realProvider: real.status,
            realOfflineCoverage: realOffline.status,
            error: nil
        )
    }

    private func runTrustRevokeExactVariant() -> [String: Bool] {
        guard let fixture = try? makeHistoricalExactSelfTestRepository() else {
            emitExactStep(
                "trust-revoke",
                variant: "fake",
                controller: nil,
                extra: ["reason": "fixture unavailable"]
            )
            return ["trustRevokeFixtureReady": false]
        }
        defer { try? FileManager.default.removeItem(at: fixture) }
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CodeInsightExactTrustRevokeSelfTest-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: cache) }
        let trustFile = cache.appendingPathComponent("trust.json")
        let providerState = ExactSelfTestProviderState()
        let coordinator = ExactCoordinator(
            providerFactory: { _ in
                InProcessExactProvider(location: nil, state: providerState)
            },
            snapshotFactory: { root, _ in
                try ExactSelfTestDirectorySnapshot(root: root)
            },
            sandboxAvailable: { true },
            trustRegistry: TrustRegistry(fileURL: trustFile)
        )
        let trustModel = AppModel(
            indexService: ExactSelfTestIndexService(),
            exactCoordinator: coordinator
        )
        let controller = MainWindowController(
            model: trustModel,
            settings: readerSettings,
            offscreen: true
        )
        controller.showWindow(nil)
        defer { controller.close() }
        controller.openProject(root: fixture)
        guard waitUntil(timeout: 30, condition: {
            if case .failed = trustModel.projectState { return true }
            return coordinator.readiness == .ready
                && providerState.trustModes == ["safe"]
        }), case .ready = trustModel.projectState else {
            emitExactStep(
                "trust-revoke",
                variant: "fake",
                controller: controller,
                extra: ["reason": "safe session unavailable"]
            )
            return ["trustRevokeSafeSessionReady": false]
        }
        let initialStatusSafe = waitUntil(timeout: 5, condition: {
            controller.selfTestExactStatusVisible
                && controller.selfTestExactStatusText.contains("Safe")
        })
        let safeProfileTitle = "Rust · \(fixture.lastPathComponent) · Safe"
        let initialProfileVisible = waitUntil(timeout: 5, condition: {
            controller.selfTestProfileToolbarItemExistsAndVisible
                && controller.selfTestProfileTitle == safeProfileTitle
        })
        let initialProfileTitleSafe =
            controller.selfTestProfileTitle == safeProfileTitle

        Task { try? await trustModel.grantCurrentRepositoryTrust() }
        let trustedReady = waitUntil(timeout: 5, condition: {
            coordinator.readiness == .ready
                && coordinator.trustedRepositories.count == 1
                && providerState.trustModes == ["safe", "trusted"]
        })
        let trustedStatusVisible = trustedReady && waitUntil(timeout: 5, condition: {
            controller.selfTestExactStatusVisible
                && controller.selfTestExactStatusText.contains("Trusted")
        })
        let trustedProfileTitle =
            "Rust · \(fixture.lastPathComponent) · Trusted"
        let trustedProfileVisible = trustedReady && waitUntil(timeout: 5, condition: {
            controller.selfTestProfileToolbarItemExistsAndVisible
                && controller.selfTestProfileTitle == trustedProfileTitle
        })
        emitExactStep(
            "trusted-status",
            variant: "fake",
            controller: controller,
            extra: ["profileTitle": controller.selfTestProfileTitle]
        )

        let settingsController = ReaderSettingsWindowController(
            settings: readerSettings,
            exactCoordinator: coordinator,
            onRevoke: { repositoryURL in
                try? await trustModel.revokeRepositoryTrust(repositoryURL)
            },
            onChange: { _ in }
        )
        settingsController.window?.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        settingsController.showWindow(nil)
        defer { settingsController.close() }

        let trustView = NSHostingView(rootView: TrustSettingsView(
            coordinator: coordinator,
            onRevoke: { repositoryURL in
                try? await trustModel.revokeRepositoryTrust(repositoryURL)
            }
        ))
        let layoutWindow = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 560, height: 360),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        layoutWindow.contentView = trustView
        layoutWindow.orderFront(nil)
        defer { layoutWindow.close() }
        trustView.layoutSubtreeIfNeeded()
        settingsController.window?.displayIfNeeded()
        layoutWindow.displayIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        let listRowCount = selfTestListRowCount(in: trustView)

        Task { try? await trustModel.revokeRepositoryTrust(fixture) }
        let rebuiltSafe = waitUntil(timeout: 5, condition: {
            coordinator.readiness == .ready
                && providerState.trustModes == ["safe", "trusted", "safe"]
        })
        trustView.layoutSubtreeIfNeeded()
        settingsController.window?.displayIfNeeded()
        layoutWindow.displayIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))

        let trustedRepositoriesEmpty = coordinator.trustedRepositories.isEmpty
        let trustJSONEmpty = (
            (try? JSONSerialization.jsonObject(with: Data(contentsOf: trustFile)))
                as? [String: Any]
        )?.isEmpty == true
        let trustedSessionClosed = providerState.closedSessions.contains(2)
        let statusIsSafe = rebuiltSafe && waitUntil(timeout: 5, condition: {
            controller.selfTestExactStatusVisible
                && controller.selfTestExactStatusText.contains("Safe")
        })
        let safeProfileRestored = rebuiltSafe && waitUntil(timeout: 5, condition: {
            controller.selfTestProfileToolbarItemExistsAndVisible
                && controller.selfTestProfileTitle == safeProfileTitle
        })
        let checks = [
            "trustInitialStatusSafe": initialStatusSafe,
            "trustInitialProfileVisible": initialProfileVisible,
            "trustInitialProfileTitleSafe": initialProfileTitleSafe,
            "trustRevokeTrustedReady": trustedReady,
            "trustStatusTrusted": trustedStatusVisible,
            "trustProfileTitleTrusted": trustedProfileVisible,
            "trustRevokeListRowLaidOut": listRowCount == 1,
            "trustRevokeRepositoriesEmpty": trustedRepositoriesEmpty,
            "trustRevokeJSONEmpty": trustJSONEmpty,
            "trustRevokePreparedSafe": rebuiltSafe,
            "trustRevokeClosedTrustedSession": trustedSessionClosed,
            "trustRevokeStatusIsSafe": statusIsSafe,
            "trustRevokeProfileTitleIsSafe": safeProfileRestored,
        ]
        emitExactStep(
            "trust-revoke",
            variant: "fake",
            controller: controller,
            extra: checks
        )
        return checks
    }

    private func runHistoricalExactVariant() -> (
        providerRootIsMaterialized: Bool,
        uiPathIsRepoRelative: Bool,
        exactVisible: Bool,
        initialStatusSafe: Bool,
        provenanceAttributed: Bool
    ) {
        let fixture: URL
        do {
            fixture = try makeHistoricalExactSelfTestRepository()
        } catch {
            emitExactStep(
                "failed",
                variant: "historical-fake",
                controller: nil,
                extra: ["reason": error.localizedDescription]
            )
            return (false, false, false, false, false)
        }
        defer { try? FileManager.default.removeItem(at: fixture) }

        let snapshot: CommitSnapshot
        let target: ExactSelfTestTarget
        do {
            snapshot = try CommitSnapshot(
                repositoryURL: fixture,
                revision: "HEAD~1"
            )
            guard let found = exactSelfTestTarget(root: fixture) else {
                throw ExactSelfTestError.fixture("target unavailable")
            }
            target = found
        } catch {
            emitExactStep(
                "failed",
                variant: "historical-fake",
                controller: nil,
                extra: ["reason": error.localizedDescription]
            )
            return (false, false, false, false, false)
        }

        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CodeInsightExactHistorySelfTest-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: cache) }
        let materializer = Materializer(
            rootURL: cache.appendingPathComponent("materialized")
        )
        let providerState = ExactSelfTestProviderState()
        let coordinator = ExactCoordinator(
            providerFactory: { root in
                providerState.root = root
                return InProcessExactProvider(location: ExactLocation(
                    file: root.appendingPathComponent("src/lib.rs").path,
                    byteOffset: 7,
                    line: 1,
                    column: 8
                ))
            },
            trustRegistry: TrustRegistry(
                fileURL: cache.appendingPathComponent("trust.json")
            ),
            materializer: materializer
        )
        let historyModel = AppModel(
            indexService: ProjectIndexService(),
            exactCoordinator: coordinator
        )
        let controller = MainWindowController(
            model: historyModel,
            settings: readerSettings,
            offscreen: true
        )
        controller.showWindow(nil)
        defer { controller.close() }
        controller.openProject(root: fixture)
        guard waitUntil(timeout: 30, condition: {
            if case .failed = historyModel.projectState { return true }
            if case .ready = historyModel.projectState {
                return !historyModel.commitPicker.isLoading
            }
            return false
        }), case .ready = historyModel.projectState,
        controller.selectCommit(snapshot.commitOID.hex),
        waitUntil(timeout: 30, condition: {
            historyModel.currentRevision == snapshot.commitOID.hex
                && historyModel.snapshotPhase == .fullReady
                && coordinator.readiness == .ready
        }),
        controller.selectFileInSidebar(target.file),
        waitUntil(timeout: 5, condition: {
            controller.displayedReaderFile?.standardizedFileURL
                == target.file.standardizedFileURL
        }) else {
            emitExactStep(
                "failed",
                variant: "historical-fake",
                controller: controller,
                extra: ["reason": "HEAD~1 switch or file open failed"]
            )
            return (false, false, false, false, false)
        }

        let initialStatusSafe = waitUntil(timeout: 5, condition: {
            controller.selfTestExactStatusText.contains("Safe")
        })
        controller.selfTestReaderClick(
            offset: target.clickOffset,
            commandClick: false
        )
        let exactVisible = waitUntil(timeout: 5, condition: {
            controller.selfTestContextProvenance?.contains("Exact") == true
        })
        let providerRoot = providerState.root
        let providerRootIsMaterialized = providerRoot?.path.contains(
            "/materialized/\(snapshot.commitOID.hex)/"
        ) == true
        let uiPath = historyModel.contextWindow.selectedCandidate?.path
        let uiPathIsRepoRelative = uiPath == "src/lib.rs"
            && uiPath?.hasPrefix("/") == false
        let provenance = controller.selfTestContextProvenance
        let provenanceAttributed = provenance?.contains(
            String(snapshot.commitOID.hex.prefix(7))
        ) == true && provenance?.contains("materialized") == true
        emitExactStep(
            "historicalExact",
            variant: "historical-fake",
            controller: controller,
            extra: [
                "revision": snapshot.commitOID.hex,
                "providerRoot": (providerRoot?.path as Any?) ?? NSNull(),
                "providerRootIsMaterialized": providerRootIsMaterialized,
                "uiPath": (uiPath as Any?) ?? NSNull(),
                "uiPathIsRepoRelative": uiPathIsRepoRelative,
                "provenanceAttributed": provenanceAttributed,
            ]
        )
        return (
            providerRootIsMaterialized,
            uiPathIsRepoRelative,
            exactVisible,
            initialStatusSafe,
            provenanceAttributed
        )
    }

    private func runRealExactVariant(
        root: URL
    ) -> (status: String, passed: Bool) {
        guard let executable = RustAnalyzerProvider.findExecutable() else {
            emitExactStep(
                "skipped",
                variant: "rust-analyzer",
                controller: nil,
                extra: ["reason": "rust-analyzer not installed"]
            )
            return ("skipped:not-installed", true)
        }

        let fixtureRoot = exactSelfTestFixtureRoot(root: root)
        guard let target = exactSelfTestTarget(root: fixtureRoot) else {
            emitExactStep(
                "skipped",
                variant: "rust-analyzer",
                controller: nil,
                extra: ["reason": "real-provider fixture unavailable"]
            )
            return ("skipped:fixture-unavailable", true)
        }
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CodeInsightExactRealSelfTest-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: cache) }

        let coordinator = ExactCoordinator(
            providerFactory: { projectURL in
                try RustAnalyzerProvider(
                    projectURL: projectURL,
                    executableURL: executable,
                    cacheURL: cache,
                    requestTimeout: 30,
                    closeGrace: 0.5
                )
            },
            snapshotFactory: { root, _ in
                try ExactSelfTestDirectorySnapshot(root: root)
            },
            trustRegistry: TrustRegistry(fileURL: FileManager.default
                .temporaryDirectory
                .appendingPathComponent("CodeInsightExactRealSelfTest-trust.json"))
        )
        let realModel = AppModel(
            indexService: ExactSelfTestIndexService(),
            exactCoordinator: coordinator
        )
        let controller = MainWindowController(
            model: realModel,
            settings: readerSettings,
            offscreen: true
        )
        controller.showWindow(nil)
        defer { controller.close() }
        controller.openProject(root: fixtureRoot)
        guard waitUntil(timeout: 30, condition: {
            if case .failed = realModel.projectState { return true }
            if case .ready = realModel.projectState { return true }
            return false
        }), case .ready = realModel.projectState,
        waitUntil(timeout: 5, condition: {
            controller.selectFileInSidebar(target.file)
        }),
        waitUntil(timeout: 5, condition: {
            controller.displayedReaderFile?.standardizedFileURL
                == target.file.standardizedFileURL
        }) else {
            emitExactStep(
                "failed",
                variant: "rust-analyzer",
                controller: controller,
                extra: ["reason": "project or file unavailable"]
            )
            return ("failed:project", false)
        }

        if case .off(let reason) = coordinator.readiness {
            emitExactStep(
                "skipped",
                variant: "rust-analyzer",
                controller: controller,
                extra: ["reason": reason]
            )
            return ("skipped:sandbox-unavailable", true)
        }
        let initialStatusSafe = waitUntil(timeout: 5, condition: {
            coordinator.readiness == .ready
                && controller.selfTestExactStatusText.contains("Safe")
        })
        emitExactStep(
            "initial-status",
            variant: "rust-analyzer",
            controller: controller
        )
        if !initialStatusSafe, case .off(let reason) = coordinator.readiness {
            emitExactStep(
                "skipped",
                variant: "rust-analyzer",
                controller: controller,
                extra: ["reason": reason]
            )
            return ("skipped:sandbox-unavailable", true)
        }
        guard initialStatusSafe else {
            return ("failed:initial-status", false)
        }

        controller.selfTestReaderClick(offset: target.clickOffset, commandClick: false)
        let fuzzyVisible = waitUntil(timeout: 5, condition: {
            controller.selfTestContextCandidateCount >= 1
                && controller.selfTestContextProvenance?.contains("Exact") == false
        })
        let fuzzyCount = controller.selfTestContextCandidateCount
        emitExactStep(
            "fuzzy",
            variant: "rust-analyzer",
            controller: controller
        )
        guard fuzzyVisible else { return ("failed:fuzzy", false) }

        let finished = waitUntil(timeout: 45, condition: {
            if controller.selfTestContextProvenance?.contains("Exact") == true {
                return true
            }
            switch coordinator.readiness {
            case .off, .unavailable:
                return true
            case .preparing, .ready:
                return false
            }
        })
        if case .off(let reason) = coordinator.readiness {
            emitExactStep(
                "skipped",
                variant: "rust-analyzer",
                controller: controller,
                extra: ["reason": reason]
            )
            return ("skipped:sandbox-unavailable", true)
        }
        if case .unavailable(let reason) = coordinator.readiness {
            emitExactStep(
                "failed",
                variant: "rust-analyzer",
                controller: controller,
                extra: ["reason": reason]
            )
            return ("failed:unavailable", false)
        }
        let exactVisible = finished
            && controller.selfTestContextProvenance?.contains("Exact") == true
        let fuzzyRetained = controller.selfTestContextCandidateCount >= fuzzyCount
        emitExactStep(
            "exact",
            variant: "rust-analyzer",
            controller: controller
        )
        return (
            exactVisible && fuzzyRetained ? "passed" : "failed:exact",
            exactVisible && fuzzyRetained
        )
    }

    private func runRealOfflineCoverageVariant(
        root: URL
    ) -> (status: String, passed: Bool) {
        guard let executable = RustAnalyzerProvider.findExecutable() else {
            emitExactStep(
                "skipped",
                variant: "rust-analyzer-offline",
                controller: nil,
                extra: ["reason": "rust-analyzer not installed"]
            )
            return ("skipped:not-installed", true)
        }
        let fixture: URL
        do {
            fixture = try makeOfflineExactSelfTestFixture(
                source: exactSelfTestFixtureRoot(root: root)
            )
        } catch {
            emitExactStep(
                "failed",
                variant: "rust-analyzer-offline",
                controller: nil,
                extra: ["reason": error.localizedDescription]
            )
            return ("failed:fixture", false)
        }
        defer { try? FileManager.default.removeItem(at: fixture) }
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CodeInsightExactOfflineSelfTest-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: cache) }
        let observedDiagnostic = OSAllocatedUnfairLock(initialState: "")
        let coordinator = ExactCoordinator(
            providerFactory: { projectURL in
                try RustAnalyzerProvider(
                    projectURL: projectURL,
                    executableURL: executable,
                    cacheURL: cache,
                    requestTimeout: 30,
                    closeGrace: 0.5,
                    diagnosticObserver: { diagnostic in
                        observedDiagnostic.withLock { $0 = diagnostic }
                    }
                )
            },
            snapshotFactory: { root, _ in
                try ExactSelfTestDirectorySnapshot(root: root)
            },
            trustRegistry: TrustRegistry(
                fileURL: cache.appendingPathComponent("trust.json")
            )
        )
        let model = AppModel(
            indexService: ExactSelfTestIndexService(),
            exactCoordinator: coordinator
        )
        let controller = MainWindowController(
            model: model,
            settings: readerSettings,
            offscreen: true
        )
        controller.showWindow(nil)
        defer { controller.close() }
        controller.openProject(root: fixture)
        let prepared = waitUntil(timeout: 45, condition: {
            switch coordinator.readiness {
            case .ready, .off, .unavailable:
                return true
            case .preparing:
                return false
            }
        })
        if case .off(let reason) = coordinator.readiness {
            emitExactStep(
                "skipped",
                variant: "rust-analyzer-offline",
                controller: controller,
                extra: ["reason": reason]
            )
            return ("skipped:sandbox-unavailable", true)
        }
        if case .unavailable(let reason) = coordinator.readiness {
            emitExactStep(
                "failed",
                variant: "rust-analyzer-offline",
                controller: controller,
                extra: ["reason": reason]
            )
            return ("failed:unavailable", false)
        }
        guard prepared else {
            emitExactStep(
                "failed",
                variant: "rust-analyzer-offline",
                controller: controller,
                extra: ["reason": "provider-readiness-timeout"]
            )
            return ("failed:readiness-timeout", false)
        }
        let coverageObserved = waitUntil(timeout: 15, condition: {
            coordinator.coverage == .dependenciesUnavailableOffline
        })
        guard coverageObserved else {
            let diagnostic = observedDiagnostic.withLock { $0.lowercased() }
            let offlineDiagnosticArrived =
                (diagnostic.contains("--offline")
                    || diagnostic.contains("offline mode")
                    || diagnostic.contains("cargo_net_offline"))
                && (diagnostic.contains("failed")
                    || diagnostic.contains("no matching package")
                    || diagnostic.contains("not found"))
            emitExactStep(
                offlineDiagnosticArrived ? "failed" : "skipped",
                variant: "rust-analyzer-offline",
                controller: controller,
                extra: [
                    "diagnosticsObserved": offlineDiagnosticArrived,
                    "noDefinitionRequest": true,
                    "reason": offlineDiagnosticArrived
                        ? "offline-diagnostics-without-coverage"
                        : "diagnostics-timeout",
                ]
            )
            return offlineDiagnosticArrived
                ? ("failed:coverage", false)
                : ("skipped:diagnostics-timeout", true)
        }
        let passed = waitUntil(timeout: 5, condition: {
            let status = controller.selfTestExactStatusText
            return status.contains("deps unavailable (offline)")
                && status.contains("Safe")
        })
        emitExactStep(
            passed ? "offline-coverage" : "failed",
            variant: "rust-analyzer-offline",
            controller: controller,
            extra: ["noDefinitionRequest": true]
        )
        return (passed ? "passed" : "failed:coverage", passed)
    }

    private func emitExactStep(
        _ step: String,
        variant: String,
        controller: MainWindowController?,
        extra: [String: Any] = [:]
    ) {
        var object: [String: Any] = [
            "step": step,
            "variant": variant,
            "readerFile": (controller?.displayedReaderFile?.lastPathComponent as Any?)
                ?? NSNull(),
            "contextSummary": (controller?.selfTestContextSummary as Any?)
                ?? NSNull(),
            "contextProvenance": (controller?.selfTestContextProvenance as Any?)
                ?? NSNull(),
            "candidateCount": controller?.selfTestContextCandidateCount ?? 0,
            "pinned": controller?.selfTestContextPinned ?? false,
            "exactGroupRowCount": controller?.selfTestExactGroupRowCount ?? 0,
            "exactGroupTitle": (controller?.selfTestExactGroupTitle as Any?)
                ?? NSNull(),
            "exactStatusText": controller?.selfTestExactStatusText
                ?? "Exact: unavailable",
        ]
        for (key, value) in extra { object[key] = value }
        Self.writeJSON(object)
    }

    private func finishExactSelfTest(
        controller: MainWindowController?,
        checks: [String: Bool],
        realProvider: String,
        realOfflineCoverage: String = "not-run",
        error: String?
    ) -> Never {
        let passed = error == nil
            && !checks.isEmpty
            && checks.values.allSatisfy { $0 }
        var summary: [String: Any] = checks
        summary["passed"] = passed
        summary["realProvider"] = realProvider
        summary["realOfflineCoverage"] = realOfflineCoverage
        if let error { summary["error"] = error }
        emitExactStep(
            "summary",
            variant: "all",
            controller: controller,
            extra: summary
        )
        Darwin.exit(passed ? 0 : 1)
    }

    private func performHistoryNavigation(
        _ action: () -> Void,
        revision: String?,
        file: URL
    ) -> Bool {
        guard let windowController else { return false }
        let cursor = model.navigationHistory.cursor
        action()
        pumpRunLoop()
        guard model.navigationHistory.cursor != cursor else { return false }
        guard waitUntil(timeout: 30, condition: {
            self.model.currentRevision == revision
                && self.model.selectedFile == file
                && self.model.snapshotPhase == .fullReady
        }) else { return false }
        pumpRunLoop()
        return historyStateMatches(
            revision: revision,
            file: file,
            controller: windowController
        )
    }

    private func historyStateMatches(
        revision: String?,
        file: URL,
        controller: MainWindowController
    ) -> Bool {
        model.currentRevision == revision
            && controller.displayedReaderFile?.standardizedFileURL
                == file.standardizedFileURL
    }

    @discardableResult
    private func emitHistoryStep(
        _ step: String,
        controller: MainWindowController
    ) -> Bool {
        let readerFile = controller.displayedReaderFile
        let treeFile = controller.selectedSidebarFile
        Self.writeJSON([
            "step": step,
            "snapshotShort": model.currentRevision.map { String($0.prefix(7)) }
                ?? "worktree",
            "readerFile": (readerFile?.lastPathComponent as Any?) ?? NSNull(),
            "treeSelectedFile": (treeFile?.lastPathComponent as Any?) ?? NSNull(),
            "canGoBack": model.navigationHistory.canGoBack,
            "canGoForward": model.navigationHistory.canGoForward,
            "historyCount": model.navigationHistory.records.count,
            "readerHasReadingPosition": controller.readerHasReadingPosition,
        ])
        return readerFile?.standardizedFileURL == treeFile?.standardizedFileURL
    }

    private var pinContextSummary: String? {
        model.contextWindow.selectedCandidate.map { "\($0.path):\($0.line)" }
    }

    private var pinRelationRootSummary: String? {
        guard let root = model.relationTree.root else { return nil }
        if let target = root.target {
            return "\(root.title) \(target.path):\(root.line ?? 0)"
        }
        return root.title
    }

    private func emitPinStep(
        _ step: String,
        controller: MainWindowController?,
        extra: [String: Any] = [:]
    ) {
        var object: [String: Any] = [
            "step": step,
            "readerFile": (controller?.displayedReaderFile?.lastPathComponent as Any?)
                ?? NSNull(),
            "contextSummary": (pinContextSummary as Any?) ?? NSNull(),
            "relationRootSummary": (pinRelationRootSummary as Any?) ?? NSNull(),
            "pinned": model.contextWindow.mode == .pinned,
        ]
        for (key, value) in extra { object[key] = value }
        Self.writeJSON(object)
    }

    private func finishPinSelfTest(
        controller: MainWindowController?,
        checks: [String: Bool] = [:],
        error: String? = nil
    ) -> Never {
        let passed = error == nil
            && !checks.isEmpty
            && checks.values.allSatisfy { $0 }
        var summary: [String: Any] = checks
        summary["passed"] = passed
        if let error { summary["error"] = error }
        emitPinStep("summary", controller: controller, extra: summary)
        Darwin.exit(passed ? 0 : 1)
    }

    func runSwitchSelfTest(root: URL) -> Never {
        model.openProject(root: root)
        let openDeadline = Date(timeIntervalSinceNow: 30)
        while Date() < openDeadline {
            if case .ready = model.projectState { break }
            if case .failed = model.projectState {
                Self.finishSwitchSelfTest(state: nil, reused: 0, extracted: 0, ready: false)
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
        }
        guard case .ready = model.projectState else {
            Self.finishSwitchSelfTest(state: nil, reused: 0, extracted: 0, ready: false)
        }

        let state = SwitchSelfTestState(startedAt: .now)
        model.switchToCommit("HEAD~1")
        let deadline = Date(timeIntervalSinceNow: 30)
        while Date() < deadline {
            state.record(model.snapshotPhase)
            if model.snapshotPhase == .fullReady,
               case let .ready(session, _) = model.projectState
            {
                Self.finishSwitchSelfTest(
                    state: state,
                    reused: session.stats.reusedCount,
                    extracted: session.stats.extractedCount,
                    ready: true
                )
            }
            if case .failed = model.projectState {
                Self.finishSwitchSelfTest(
                    state: state,
                    reused: 0,
                    extracted: 0,
                    ready: false
                )
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
        }
        Self.finishSwitchSelfTest(
            state: state,
            reused: 0,
            extracted: 0,
            ready: false
        )
    }

    func runOpenSelfTest(file: URL) {
        let textView = ReaderTextView()
        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: 1024, height: 768)
        )
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.documentView = textView.view
        textView.view.frame = scrollView.contentView.bounds
        let window = NSWindow(
            contentRect: scrollView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        let openedAt = ContinuousClock.now
        let state = OpenSelfTestState(
            openedAt: openedAt,
            textView: textView,
            window: window
        )

        do {
            let loader = DocumentLoader()
            let loaded = try loader.load(file: file)
            state.tier = loaded.tier
            state.textView.display(document: loaded.document)
            state.textView.view.textLayoutManager?
                .textViewportLayoutController.layoutViewport()
            guard
                let fragment = state.textView.view.textLayoutManager?
                    .textLayoutFragment(for: .zero),
                !fragment.textLineFragments.isEmpty
            else { Darwin.exit(1) }
            state.firstVisibleMS = milliseconds(since: openedAt)
            state.firstVisibleOutlineFacets = loaded.document.outlineFacets.count
            if loaded.tier == .regular {
                state.syntaxVisibleMS = state.firstVisibleMS
                state.outlineFacets = loaded.document.outlineFacets.count
            } else {
                loader.loadSyntax(for: loaded.document) { result in
                    Task { @MainActor in
                        switch result {
                        case let .success(document):
                            state.textView.updateSyntax(document: document)
                            try? await Task.sleep(for: .milliseconds(10))
                            state.textView.view.textLayoutManager?
                                .textViewportLayoutController.layoutViewport()
                            state.window.displayIfNeeded()
                            state.syntaxVisibleMS = milliseconds(since: state.openedAt)
                            state.outlineFacets = document.outlineFacets.count
                        case .failure:
                            state.failed = true
                        }
                    }
                }
            }
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            Darwin.exit(1)
        }

        let deadline = Date(timeIntervalSinceNow: 30)
        while state.syntaxVisibleMS == nil, !state.failed, Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        guard
            let tier = state.tier,
            let firstVisibleMS = state.firstVisibleMS,
            let syntaxVisibleMS = state.syntaxVisibleMS,
            let firstVisibleOutlineFacets = state.firstVisibleOutlineFacets,
            let outlineFacets = state.outlineFacets,
            !state.failed
        else { Darwin.exit(1) }
        Self.finishOpenSelfTest(
            tier: tier,
            firstVisibleMS: firstVisibleMS,
            syntaxVisibleMS: syntaxVisibleMS,
            styledFragments: state.textView.renderingCoordinator.styledFragmentCount,
            firstVisibleOutlineFacets: firstVisibleOutlineFacets,
            outlineFacets: outlineFacets
        )
    }

    private func launch(
        offscreen: Bool,
        measuresIdleFootprint: Bool = false
    ) {
        NSApplication.shared.mainMenu = makeMainMenu()
        let windowController = MainWindowController(
            model: model,
            settings: readerSettings,
            offscreen: offscreen,
            measuresIdleFootprint: measuresIdleFootprint,
            recentProjectsStore: recentProjectsStore,
            recordsRecentProjects: !offscreen,
            onChooseProject: { [weak self] in self?.openProject(nil) },
            onShowSettings: { [weak self] in self?.showSettings(nil) }
        )
        self.windowController = windowController
        windowController.showWindow(nil)
    }

    private func enlargedWindowLayout(
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
        let splitFrame = controller.selfTestContentSplitFrameInContentView
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
                        - (contentFrame.height - statusBarOccupancyHeight)
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
                "splitWidth": Double(splitFrame.width),
                "statusBarHeight": Double(statusFrame.height),
                "statusBarMinY": Double(statusFrame.minY),
                "statusBarOccupancyHeight": Double(statusBarOccupancyHeight),
                "statusBarWidth": Double(statusFrame.width),
            ]
        )
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        true
    }

    @objc private func openProject(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        if panel.runModal() == .OK, let root = panel.url {
            windowController?.openProject(root: root)
        }
    }

    @objc private func openRecentProject(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        windowController?.openProject(root: URL(
            fileURLWithPath: path,
            isDirectory: true
        ))
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
                string: "A read-only code reader for macOS."
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
                title: "No Recent Projects",
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
            title: "Clear Menu",
            action: #selector(clearRecentProjects(_:)),
            keyEquivalent: ""
        )
        clearItem.target = self
        clearItem.isEnabled = !paths.isEmpty
        menu.addItem(clearItem)
    }

    @objc private func showSettings(_ sender: Any?) {
        if settingsWindowController == nil {
            settingsWindowController = ReaderSettingsWindowController(
                settings: readerSettings,
                exactCoordinator: model.exactCoordinator,
                onRevoke: { [weak self] repositoryURL in
                    guard let self else { return }
                    do {
                        try await model.revokeRepositoryTrust(repositoryURL)
                    } catch {
                        presentTrustError(error)
                    }
                }
            ) { [weak self] settings in
                guard let self else { return }
                readerSettings = settings
                settings.save(to: .standard)
                windowController?.applyReaderSettings(settings)
            }
        }
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.center()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc private func trustThisRepository(_ sender: Any?) {
        guard let window = windowController?.window,
              model.canTrustCurrentRepository
        else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Trust This Repository?"
        alert.informativeText = "This will allow this repository's build scripts "
            + "and proc macros to execute. Network access remains disabled."
        alert.addButton(withTitle: "Trust")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            Task { @MainActor in
                do {
                    try await model.grantCurrentRepositoryTrust()
                } catch {
                    presentTrustError(error)
                }
            }
        }
    }

    private func presentTrustError(_ error: any Error) {
        let alert = NSAlert(error: error)
        if let window = windowController?.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    @objc private func openSymbol(_ sender: Any?) {
        windowController?.showSymbolSearch()
    }

    @objc private func findInProject(_ sender: Any?) {
        windowController?.showProjectSearch()
    }

    @objc private func previousContextCandidate(_ sender: Any?) {
        windowController?.selectPreviousContextCandidate(sender)
    }

    @objc private func nextContextCandidate(_ sender: Any?) {
        windowController?.selectNextContextCandidate(sender)
    }

    @objc private func goBack(_ sender: Any?) {
        windowController?.goBack(sender)
    }

    @objc private func goForward(_ sender: Any?) {
        windowController?.goForward(sender)
    }

    @objc private func previousDiffHunk(_ sender: Any?) {
        windowController?.previousDiffHunk(sender)
    }

    @objc private func nextDiffHunk(_ sender: Any?) {
        windowController?.nextDiffHunk(sender)
    }

    @objc private func toggleRelations(_ sender: Any?) {
        windowController?.toggleRelations()
    }

    @objc private func applyPanelPreset(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let preset = PanelPresetModel(rawValue: rawValue)
        else { return }
        windowController?.applyPanelPreset(preset)
    }

    @objc private func showCallers(_ sender: Any?) {
        windowController?.showRelations(direction: .callers)
    }

    @objc private func showCalls(_ sender: Any?) {
        windowController?.showRelations(direction: .calls)
    }

    @objc private func showImplementations(_ sender: Any?) {
        windowController?.showRelations(direction: .implementations)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(goBack(_:)):
            model.navigationHistory.canGoBack
        case #selector(goForward(_:)):
            model.navigationHistory.canGoForward
        case #selector(previousDiffHunk(_:)), #selector(nextDiffHunk(_:)):
            !(model.compare.diff?.hunks.isEmpty ?? true)
        case #selector(showCallers(_:)),
             #selector(showCalls(_:)),
             #selector(showImplementations(_:)):
            model.contextWindow.selectedCandidate != nil
        case #selector(trustThisRepository(_:)):
            model.canTrustCurrentRepository
        default:
            true
        }
    }

    private func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Cairn")
        let aboutItem = NSMenuItem(
            title: "About Cairn",
            action: #selector(showAbout(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = self
        appMenu.addItem(aboutItem)
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(showSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "Quit Cairn",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApplication.shared
        appMenu.addItem(quitItem)
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let openItem = NSMenuItem(
            title: "Open Project…",
            action: #selector(openProject(_:)),
            keyEquivalent: "o"
        )
        openItem.target = self
        fileMenu.addItem(openItem)
        let recentItem = NSMenuItem(
            title: "Open Recent",
            action: nil,
            keyEquivalent: ""
        )
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.delegate = self
        rebuildOpenRecentMenu(recentMenu)
        recentItem.submenu = recentMenu
        fileMenu.addItem(recentItem)
        fileMenu.addItem(.separator())
        let trustItem = NSMenuItem(
            title: "Trust This Repository…",
            action: #selector(trustThisRepository(_:)),
            keyEquivalent: ""
        )
        trustItem.target = self
        fileMenu.addItem(trustItem)
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        // Without an Edit menu, Cmd+C/Cmd+A have no key-equivalent route in a
        // programmatic menu bar (found by interactive walkthrough T3.4).
        // Actions target nil so the responder chain (reader text view, search
        // field) handles them.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(
            title: "Cut",
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        ))
        editMenu.addItem(NSMenuItem(
            title: "Copy",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        ))
        editMenu.addItem(NSMenuItem(
            title: "Paste",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        ))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(
            title: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        ))
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let findItem = NSMenuItem()
        let findMenu = NSMenu(title: "Find")
        let findInProjectItem = NSMenuItem(
            title: "Find in Project…",
            action: #selector(findInProject(_:)),
            keyEquivalent: "f"
        )
        findInProjectItem.keyEquivalentModifierMask = [.command, .shift]
        findInProjectItem.target = self
        findMenu.addItem(findInProjectItem)
        findItem.submenu = findMenu
        mainMenu.addItem(findItem)

        let goItem = NSMenuItem()
        let goMenu = NSMenu(title: "Go")
        let symbolItem = NSMenuItem(
            title: "Open Symbol…",
            action: #selector(openSymbol(_:)),
            keyEquivalent: "t"
        )
        symbolItem.target = self
        goMenu.addItem(symbolItem)
        goMenu.addItem(.separator())
        let backItem = NSMenuItem(
            title: "Back",
            action: #selector(goBack(_:)),
            keyEquivalent: "\u{F702}"
        )
        backItem.keyEquivalentModifierMask = [.command, .control]
        backItem.target = self
        goMenu.addItem(backItem)
        let forwardItem = NSMenuItem(
            title: "Forward",
            action: #selector(goForward(_:)),
            keyEquivalent: "\u{F703}"
        )
        forwardItem.keyEquivalentModifierMask = [.command, .control]
        forwardItem.target = self
        goMenu.addItem(forwardItem)
        let alternateBackItem = NSMenuItem(
            title: "Back",
            action: #selector(goBack(_:)),
            keyEquivalent: "["
        )
        alternateBackItem.keyEquivalentModifierMask = .command
        alternateBackItem.target = self
        alternateBackItem.isHidden = true
        alternateBackItem.allowsKeyEquivalentWhenHidden = true
        goMenu.addItem(alternateBackItem)
        let alternateForwardItem = NSMenuItem(
            title: "Forward",
            action: #selector(goForward(_:)),
            keyEquivalent: "]"
        )
        alternateForwardItem.keyEquivalentModifierMask = .command
        alternateForwardItem.target = self
        alternateForwardItem.isHidden = true
        alternateForwardItem.allowsKeyEquivalentWhenHidden = true
        goMenu.addItem(alternateForwardItem)
        goMenu.addItem(.separator())
        let previousCandidate = NSMenuItem(
            title: "Previous Context Candidate",
            action: #selector(previousContextCandidate(_:)),
            keyEquivalent: "\u{F702}"
        )
        previousCandidate.keyEquivalentModifierMask = [.command, .option]
        previousCandidate.target = self
        goMenu.addItem(previousCandidate)
        let nextCandidate = NSMenuItem(
            title: "Next Context Candidate",
            action: #selector(nextContextCandidate(_:)),
            keyEquivalent: "\u{F703}"
        )
        nextCandidate.keyEquivalentModifierMask = [.command, .option]
        nextCandidate.target = self
        goMenu.addItem(nextCandidate)
        goMenu.addItem(.separator())
        let previousHunk = NSMenuItem(
            title: "Previous Diff Hunk",
            action: #selector(previousDiffHunk(_:)),
            keyEquivalent: "\u{F700}"
        )
        previousHunk.keyEquivalentModifierMask = [.command, .option]
        previousHunk.target = self
        goMenu.addItem(previousHunk)
        let nextHunk = NSMenuItem(
            title: "Next Diff Hunk",
            action: #selector(nextDiffHunk(_:)),
            keyEquivalent: "\u{F701}"
        )
        nextHunk.keyEquivalentModifierMask = [.command, .option]
        nextHunk.target = self
        goMenu.addItem(nextHunk)
        goItem.submenu = goMenu
        mainMenu.addItem(goItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let presetItem = NSMenuItem(title: "Preset", action: nil, keyEquivalent: "")
        let presetMenu = NSMenu(title: "Preset")
        let presets: [(PanelPresetModel, String, String)] = [
            (.reading, "Reading", "1"),
            (.relations, "Relations", "2"),
            (.compare, "Compare", "3"),
            (.focus, "Focus", "4"),
        ]
        for (preset, title, key) in presets {
            let item = NSMenuItem(
                title: title,
                action: #selector(applyPanelPreset(_:)),
                keyEquivalent: key
            )
            item.keyEquivalentModifierMask = .command
            item.target = self
            item.representedObject = preset.rawValue
            presetMenu.addItem(item)
        }
        presetItem.submenu = presetMenu
        viewMenu.addItem(presetItem)
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        let relationsItem = NSMenuItem()
        let relationsMenu = NSMenu(title: "Relations")
        let toggleItem = NSMenuItem(
            title: "Show/Hide Relations",
            action: #selector(toggleRelations(_:)),
            keyEquivalent: "r"
        )
        toggleItem.keyEquivalentModifierMask = [.command, .control]
        toggleItem.target = self
        relationsMenu.addItem(toggleItem)
        relationsMenu.addItem(.separator())
        let callersItem = NSMenuItem(
            title: "Show Callers",
            action: #selector(showCallers(_:)),
            keyEquivalent: "h"
        )
        callersItem.keyEquivalentModifierMask = [.command, .shift]
        callersItem.target = self
        relationsMenu.addItem(callersItem)
        let callsItem = NSMenuItem(
            title: "Show Calls",
            action: #selector(showCalls(_:)),
            keyEquivalent: ""
        )
        callsItem.target = self
        relationsMenu.addItem(callsItem)
        let implementationsItem = NSMenuItem(
            title: "Show Implementations",
            action: #selector(showImplementations(_:)),
            keyEquivalent: ""
        )
        implementationsItem.target = self
        relationsMenu.addItem(implementationsItem)
        relationsItem.submenu = relationsMenu
        mainMenu.addItem(relationsItem)

        return mainMenu
    }

    private static func finishSelfTest(
        coldStartMS: Double,
        idleFootprintMB: Double,
        checks: [String: Bool],
        enlargedWindowGeometry: [String: Double]
    ) {
        do {
            let passed = coldStartMS < SelfTestBudgets.coldStartMS
                && idleFootprintMB < SelfTestBudgets.idleFootprintMB
                && checks.values.allSatisfy { $0 }
            var object: [String: Any] = checks
            object["coldStartMS"] = coldStartMS
            object["idleFootprintMB"] = idleFootprintMB
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
            Darwin.exit(passed ? 0 : 1)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            Darwin.exit(1)
        }
    }

    private static func finishProjectSelfTest(
        treeVisibleMS: Double,
        indexReadyMS: Double,
        fileCount: Int,
        reused: Int,
        extracted: Int,
        ready: Bool,
        emptyStateRemoved: Bool,
        readerDocumentVisible: Bool,
        branchName: String? = nil,
        commitTitle: String = "",
        commitPickerShowsCurrentBranch: Bool = false,
        indexStatusVisibleDuringIndexing: Bool = false,
        indexStatusTextDuringIndexing: String = "",
        statusBarVisibleAfterReady: Bool = false,
        indexStatusHiddenAfterFullReady: Bool = false,
        layoutChecks: [String: Bool] = [:],
        enlargedWindowGeometry: [String: Double] = [:]
    ) -> Never {
        do {
            var object: [String: Any] = [
                "treeVisibleMS": treeVisibleMS,
                "indexReadyMS": indexReadyMS,
                "fileCount": fileCount,
                "reused": reused,
                "extracted": extracted,
                "emptyStateRemoved": emptyStateRemoved,
                "readerDocumentVisible": readerDocumentVisible,
                "branchName": branchName ?? "",
                "commitTitle": commitTitle,
                "commitPickerShowsCurrentBranch": commitPickerShowsCurrentBranch,
                "indexStatusVisibleDuringIndexing":
                    indexStatusVisibleDuringIndexing,
                "indexStatusTextDuringIndexing":
                    indexStatusTextDuringIndexing,
                "statusBarVisibleAfterReady": statusBarVisibleAfterReady,
                "indexStatusHiddenAfterFullReady":
                    indexStatusHiddenAfterFullReady,
                "enlargedWindowGeometry": enlargedWindowGeometry,
            ]
            object.merge(layoutChecks) { _, new in new }
            let data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
            Darwin.exit(
                ready
                    && emptyStateRemoved
                    && readerDocumentVisible
                    && commitPickerShowsCurrentBranch
                    && indexStatusVisibleDuringIndexing
                    && statusBarVisibleAfterReady
                    && indexStatusHiddenAfterFullReady
                    && layoutChecks.values.allSatisfy { $0 }
                    && treeVisibleMS < SelfTestBudgets.projectTreeVisibleMS
                    && indexReadyMS < SelfTestBudgets.projectIndexReadyMS
                    ? 0 : 1
            )
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            Darwin.exit(1)
        }
    }

    private static func finishSwitchSelfTest(
        state: SwitchSelfTestState?,
        reused: Int,
        extracted: Int,
        ready: Bool
    ) -> Never {
        do {
            let firstPaintMS = state?.firstPaintMS ?? -1
            let cachedReadyMS = state?.cachedReadyMS ?? -1
            let fullReadyMS = state?.fullReadyMS ?? -1
            let data = try JSONSerialization.data(
                withJSONObject: [
                    "firstPaintMS": firstPaintMS,
                    "cachedReadyMS": cachedReadyMS,
                    "fullReadyMS": fullReadyMS,
                    "reused": reused,
                    "extracted": extracted,
                ],
                options: [.sortedKeys]
            )
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
            Darwin.exit(
                firstPaintMS >= 0
                    && firstPaintMS < SelfTestBudgets.snapshotFirstPaintMS
                    && cachedReadyMS >= firstPaintMS
                    && fullReadyMS >= cachedReadyMS
                    && ready
                    ? 0 : 1
            )
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            Darwin.exit(1)
        }
    }

    private static func finishHistorySelfTest(
        selectionSynchronized: Bool,
        switchEnteredHistory: Bool,
        navigationSequence: Bool,
        error: String?
    ) -> Never {
        let passed = selectionSynchronized
            && switchEnteredHistory
            && navigationSequence
            && error == nil
        var summary: [String: Any] = [
            "step": "summary",
            "selectionSynchronized": selectionSynchronized,
            "switchEnteredHistory": switchEnteredHistory,
            "navigationSequence": navigationSequence,
            "passed": passed,
        ]
        if let error { summary["error"] = error }
        writeJSON(summary)
        Darwin.exit(passed ? 0 : 1)
    }

    private static func writeJSON(_ object: [String: Any]) {
        do {
            let data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
        }
    }

    private static func finishOpenSelfTest(
        tier: FileTier,
        firstVisibleMS: Double,
        syntaxVisibleMS: Double,
        styledFragments: Int,
        firstVisibleOutlineFacets: Int,
        outlineFacets: Int
    ) -> Never {
        do {
            let data = try JSONSerialization.data(
                withJSONObject: [
                    "tier": tier.rawValue,
                    "firstVisibleMS": firstVisibleMS,
                    "syntaxVisibleMS": syntaxVisibleMS,
                    "styledFragments": styledFragments,
                    "firstVisibleOutlineFacets": firstVisibleOutlineFacets,
                    "outlineFacets": outlineFacets,
                ],
                options: [.sortedKeys]
            )
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
            let withinBudget = tier == .regular
                ? firstVisibleMS < SelfTestBudgets.regularFirstVisibleMS
                    && styledFragments > 0
                : tier != .huge
                    || (
                        firstVisibleMS < SelfTestBudgets.hugeFirstVisibleMS
                            && firstVisibleOutlineFacets == 0
                            && styledFragments < SelfTestBudgets.hugeStyledFragments
                    )
            Darwin.exit(withinBudget ? 0 : 1)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            Darwin.exit(1)
        }
    }
}

@MainActor
private final class OpenSelfTestState {
    let openedAt: ContinuousClock.Instant
    let textView: ReaderTextView
    let window: NSWindow
    var tier: FileTier?
    var firstVisibleMS: Double?
    var syntaxVisibleMS: Double?
    var firstVisibleOutlineFacets: Int?
    var outlineFacets: Int?
    var failed = false

    init(
        openedAt: ContinuousClock.Instant,
        textView: ReaderTextView,
        window: NSWindow
    ) {
        self.openedAt = openedAt
        self.textView = textView
        self.window = window
    }
}

@MainActor
private final class SwitchSelfTestState {
    let startedAt: ContinuousClock.Instant
    var firstPaintMS: Double?
    var cachedReadyMS: Double?
    var fullReadyMS: Double?

    init(startedAt: ContinuousClock.Instant) {
        self.startedAt = startedAt
    }

    func record(_ phase: SnapshotPhase?) {
        guard let phase else { return }
        let elapsed = milliseconds(since: startedAt)
        // Equal timestamps mark monotonic phases coalesced into one poll.
        if firstPaintMS == nil { firstPaintMS = elapsed }
        guard phase != .firstPaint else { return }
        if cachedReadyMS == nil { cachedReadyMS = elapsed }
        guard phase == .fullReady else { return }
        if fullReadyMS == nil { fullReadyMS = elapsed }
    }
}

private struct ExactSelfTestTarget {
    let file: URL
    let clickOffset: UInt32
    let definition: ExactLocation
    let relationFile: URL
    let relationCallOffset: UInt32
    let signatureTraitOffset: UInt32?
    let externalRootOffset: UInt32?
    let externalCallOffset: UInt32?
}

private struct ExactSelfTestIndexService: IndexService {
    func index(root: URL) async throws -> EngineSession {
        try await Task.detached(priority: .userInitiated) {
            try ProjectIndexer().index(root: root)
        }.value
    }
}

private struct ExactSelfTestDirectorySnapshot: Snapshot {
    let snapshotID = SnapshotID(rawValue: UUID())
    let objectFormat = GitObjectFormat.sha1
    let sourceKind = SourceKind.untracked
    private let root: URL
    private let files = ["src/lib.rs", "src/main.rs"]

    init(root: URL) throws {
        self.root = root.standardizedFileURL
        for file in files {
            _ = try Data(contentsOf: self.root.appendingPathComponent(file))
        }
    }

    func listFiles() -> [(path: String, contentID: ContentID, fileMode: FileMode)] {
        files.compactMap { path in
            guard let bytes = try? readBytes(path: path) else { return nil }
            return (path, ContentID.sha256(of: bytes), .regular)
        }
    }

    func readBytes(path: String) throws -> [UInt8] {
        guard files.contains(path) else { throw GitError.missingPath(path) }
        return [UInt8](try Data(
            contentsOf: root.appendingPathComponent(path),
            options: .mappedIfSafe
        ))
    }

}

private final class InProcessExactProvider: ExactProvider, @unchecked Sendable {
    let capabilities: ExactCapabilities = [.definition]
    let toolVersion = "in-process-fake-1"
    private let location: ExactLocation?
    private let externalFile: String?
    private let externalOffset: Int?
    private let externalLocation: ExactLocation?
    private let state: ExactSelfTestProviderState?

    init(
        location: ExactLocation?,
        externalFile: String? = nil,
        externalOffset: Int? = nil,
        externalLocation: ExactLocation? = nil,
        state: ExactSelfTestProviderState? = nil
    ) {
        self.location = location
        self.externalFile = externalFile
        self.externalOffset = externalOffset
        self.externalLocation = externalLocation
        self.state = state
    }

    func prepare(
        snapshot: any Snapshot,
        profile: ExactProfileKey,
        trustMode: TrustMode
    ) throws -> any ExactSession {
        let ordinal = state?.recordPrepare(trustMode: trustMode)
        return InProcessExactSession(
            location: location,
            externalFile: externalFile,
            externalOffset: externalOffset,
            externalLocation: externalLocation,
            attribution: ExactAttribution(
                provider: "fake-exact",
                toolVersion: toolVersion,
                configFingerprint: profile.configFingerprint,
                environmentFingerprint: profile.environmentFingerprint,
                trustMode: trustMode,
                generatedAt: Date(timeIntervalSince1970: 0),
                coverage: trustMode == .safe ? .partial : .full
            ),
            ordinal: ordinal,
            state: state
        )
    }
}

private final class InProcessExactSession: ExactSession, @unchecked Sendable {
    let readiness: ExactReadiness = .ready
    let attribution: ExactAttribution
    private let location: ExactLocation?
    private let externalFile: String?
    private let externalOffset: Int?
    private let externalLocation: ExactLocation?
    private let ordinal: Int?
    private let state: ExactSelfTestProviderState?

    init(
        location: ExactLocation?,
        externalFile: String?,
        externalOffset: Int?,
        externalLocation: ExactLocation?,
        attribution: ExactAttribution,
        ordinal: Int?,
        state: ExactSelfTestProviderState?
    ) {
        self.location = location
        self.externalFile = externalFile
        self.externalOffset = externalOffset
        self.externalLocation = externalLocation
        self.attribution = attribution
        self.ordinal = ordinal
        self.state = state
    }

    func definition(file: String, byteOffset: Int) throws -> ExactLocation? {
        Thread.sleep(forTimeInterval: 0.25)
        if file == externalFile, byteOffset == externalOffset {
            return externalLocation
        }
        return location
    }

    func cancel() {}
    func close() {
        if let ordinal { state?.recordClose(ordinal: ordinal) }
    }
}

private final class ExactSelfTestProviderState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRoot: URL?
    private var storedTrustModes: [String] = []
    private var storedClosedSessions: Set<Int> = []

    var root: URL? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedRoot
        }
        set {
            lock.lock()
            storedRoot = newValue
            lock.unlock()
        }
    }

    var trustModes: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedTrustModes
    }

    var closedSessions: Set<Int> {
        lock.lock()
        defer { lock.unlock() }
        return storedClosedSessions
    }

    func recordPrepare(trustMode: TrustMode) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let mode = switch trustMode {
        case .safe: "safe"
        case .trusted: "trusted"
        }
        storedTrustModes.append(mode)
        return storedTrustModes.count
    }

    func recordClose(ordinal: Int) {
        lock.lock()
        storedClosedSessions.insert(ordinal)
        lock.unlock()
    }
}

private func exactSelfTestTarget(root: URL) -> ExactSelfTestTarget? {
    let root = root.standardizedFileURL
    let path = "src/main.rs"
    let definitionPath = "src/lib.rs"
    let file = root.appendingPathComponent(path)
    let relationFile = root.appendingPathComponent(definitionPath)
    guard let source = try? String(contentsOf: file, encoding: .utf8),
          let click = source.range(of: "answer();", options: .backwards),
          let definitionSource = try? String(
              contentsOf: relationFile,
              encoding: .utf8
          ),
          let definition = definitionSource.range(of: "answer"),
          let relationCall = definitionSource.range(
              of: "answer()",
              options: .backwards
          ),
          let clickOffset = UInt32(exactly: source[..<click.lowerBound].utf8.count),
          let definitionOffset = UInt32(exactly: definitionSource[
              ..<definition.lowerBound
          ].utf8.count),
          let relationCallOffset = UInt32(exactly: definitionSource[
              ..<relationCall.lowerBound
          ].utf8.count),
          let coordinate = LineTable(bytes: Array(definitionSource.utf8))
              .lineColumn(at: definitionOffset)
    else { return nil }
    let signatureTraitOffset = definitionSource.range(of: "Backend").flatMap {
        UInt32(exactly: definitionSource[..<$0.lowerBound].utf8.count)
    }
    let externalRootOffset = definitionSource.range(of: "dependency_call").flatMap {
        UInt32(exactly: definitionSource[..<$0.lowerBound].utf8.count)
    }
    let externalCallOffset = definitionSource.range(
        of: "values.len()",
        options: .backwards
    ).flatMap {
        UInt32(exactly: definitionSource[..<$0.lowerBound].utf8.count)
    }
    return ExactSelfTestTarget(
        file: file,
        clickOffset: clickOffset,
        definition: ExactLocation(
            file: definitionPath,
            byteOffset: Int(definitionOffset),
            line: Int(coordinate.line),
            column: Int(coordinate.column)
        ),
        relationFile: relationFile,
        relationCallOffset: relationCallOffset,
        signatureTraitOffset: signatureTraitOffset,
        externalRootOffset: externalRootOffset,
        externalCallOffset: externalCallOffset
    )
}

private func exactSelfTestFixtureRoot(root: URL) -> URL {
    root.standardizedFileURL.appendingPathComponent(
        "Tests/CodeInsightExactTests/Fixtures/exact_fixture",
        isDirectory: true
    )
}

private func makeOfflineExactSelfTestFixture(source: URL) throws -> URL {
    let destination = FileManager.default.temporaryDirectory.appendingPathComponent(
        "CodeInsightExactOfflineFixture-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.copyItem(at: source, to: destination)
    let manifestURL = destination.appendingPathComponent("Cargo.toml")
    var manifest = try String(contentsOf: manifestURL, encoding: .utf8)
    manifest += """

        [dependencies]
        codeinsight-definitely-missing-offline-dependency = "99.99.99"
        """
    try manifest.write(to: manifestURL, atomically: true, encoding: .utf8)
    return destination
}

private func makeHistoricalExactSelfTestRepository() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "CodeInsightExactHistoryFixture-\(UUID().uuidString)",
        isDirectory: true
    )
    do {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("src"),
            withIntermediateDirectories: true
        )
        try Data(
            "[package]\nname='history'\nversion='0.1.0'\nedition='2021'\n".utf8
        ).write(to: root.appendingPathComponent("Cargo.toml"))
        try Data(
            "use history::answer;\nfn main() { let _ = answer(); }\n".utf8
        ).write(to: root.appendingPathComponent("src/main.rs"))
        try Data("pub fn answer() -> u8 { 1 }\n".utf8)
            .write(to: root.appendingPathComponent("src/lib.rs"))
        try exactSelfTestGit(root, "init", "-q")
        try exactSelfTestGit(root, "config", "user.name", "CodeInsight Tests")
        try exactSelfTestGit(
            root,
            "config",
            "user.email",
            "tests@codeinsight.invalid"
        )
        try exactSelfTestGit(root, "add", "-A")
        try exactSelfTestGit(root, "commit", "-q", "-m", "definition line 1")
        try Data("// moved\n// again\npub fn answer() -> u8 { 2 }\n".utf8)
            .write(to: root.appendingPathComponent("src/lib.rs"))
        try exactSelfTestGit(root, "add", "-A")
        try exactSelfTestGit(root, "commit", "-q", "-m", "definition line 3")
        return root
    } catch {
        try? FileManager.default.removeItem(at: root)
        throw error
    }
}

private func exactSelfTestGit(_ root: URL, _ arguments: String...) throws {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = root
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw ExactSelfTestError.git(
            String(
                data: output.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "git failed"
        )
    }
}

private enum ExactSelfTestError: Error, LocalizedError {
    case fixture(String)
    case git(String)

    var errorDescription: String? {
        switch self {
        case .fixture(let detail): detail
        case .git(let detail): detail
        }
    }
}

private func physicalFootprintBytes() -> UInt64? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
    )
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : nil
}

private func milliseconds(since start: ContinuousClock.Instant) -> Double {
    let duration = start.duration(to: .now)
    return Double(duration.components.seconds) * 1_000
        + Double(duration.components.attoseconds) / 1_000_000_000_000_000
}

@MainActor
private func waitUntil(
    timeout: TimeInterval,
    condition: () -> Bool
) -> Bool {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while Date() < deadline {
        if condition() { return true }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    return condition()
}

@MainActor
private func pumpRunLoop() {
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
}

@MainActor
private func selfTestListRowCount(in view: NSView) -> Int {
    max(
        (view as? NSTableView)?.numberOfRows ?? 0,
        view.subviews.map(selfTestListRowCount(in:)).max() ?? 0
    )
}

private func rustFiles(in nodes: [FileTreeNode]) -> [URL] {
    nodes.flatMap { node in
        node.isDirectory ? rustFiles(in: node.children) : [node.url]
    }
}
