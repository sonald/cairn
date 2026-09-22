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
import PDFKit
import SwiftUI
import WebKit

private enum SelfTestBudgets {
    static let coldStartMS = 500.0
    static let idleFootprintMB = 100.0
    // Current F0 control measured 48.7 MiB process-wide delta. 56 keeps
    // the old ~13% headroom and the historical 64 MiB injection is rejected.
    static let largeReferenceDeltaFootprintMB = 56.0
    static let regularFirstVisibleMS = 100.0
    static let hugeFirstVisibleMS = 2_500.0
    static let hugeStyledFragments = 500
    static let projectTreeVisibleMS = 1_000.0
    static let projectIndexReadyMS = 2_500.0
    static let snapshotFirstPaintMS = 1_000.0
}

private final class PerfResolutionCollector: @unchecked Sendable {
    struct Sample: Sendable {
        let milliseconds: Double
        let candidates: Int
        let accepted: Int
    }

    private let samples = OSAllocatedUnfairLock(initialState: [Sample]())

    func record(milliseconds: Double, candidates: Int, accepted: Int) {
        let sample = Sample(
            milliseconds: milliseconds,
            candidates: candidates,
            accepted: accepted
        )
        samples.withLock { $0.append(sample) }
    }

    func snapshot() -> [Sample] {
        samples.withLock { $0 }
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

private struct WrapPerformanceRequest {
    let fixture: URL
    let wrapOn: Bool
    let scenario: String
    let output: URL
    let codeSHA: String
    let warmupCount: Int
    let sampleCount: Int
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
    guard warmup >= 0, samples >= 1, samples <= 200 else { return nil }
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
        sampleCount: samples
    )
}

private struct DiffSelfTestTarget {
    let file: URL
    let path: String
    let worktreeBytes: [UInt8]
    let commitBytes: [UInt8]
    let expected: DiffCore.Result
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

@main
private struct CodeInsightApplication {
    @MainActor
    static func main() {
        let startedAt = ContinuousClock.now
        let arguments = Array(CommandLine.arguments.dropFirst())
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
            FileHandle.standardError.write(Data(
                (
                    "usage: codeinsight-app --self-test-wrap --fixture <path> "
                        + "--wrap <on|off> "
                        + "--scenario <initial|toggle|resize|reading-set> "
                        + "--output <json> [--code-sha <sha>] "
                        + "[--warmup N] [--samples N]\n"
                ).utf8
            ))
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
            let runsSelfTest = arguments.contains {
                $0.hasPrefix("--self-test") || $0.hasPrefix("--fold-perf")
            }
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
                } else if runsSelfTest {
                    delegate = AppDelegate(
                        startedAt: startedAt,
                        model: AppModel(),
                        recentProjectsStore: launchRecentStore
                    )
                } else {
                    delegate = AppDelegate.production(
                        startedAt: startedAt,
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
            return
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
            return
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
            return
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
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation,
    NSMenuDelegate
{
    private let startedAt: ContinuousClock.Instant
    /// Model injected by self-test entry points; production launches pass
    /// none and every window gets its own model assembled from the shared
    /// trust registry / materializer / bookmark store (§4).
    private let injectedModel: AppModel?
    private let exactSelfTestProviderState: ExactSelfTestProviderState?
    private let relationTimingTemporaryRoot: URL?
    private let recentProjectsStore: RecentProjectsStore
    /// Session store anchor for windows the application assembles itself;
    /// self-tests inject an isolated URL so multi-window acceptance never
    /// touches real user data (§11).
    private let windowSessionURL: URL?
    private var readerSettings = ReaderSettings(defaults: .standard)
    nonisolated(unsafe) private var wrapKeyMonitor: Any?
    // Window collection and routing state (all MainActor, §4.1).
    private var projectWindows: [MainWindowController] = []
    /// Most-recently-active project window, recency-ordered (last = most
    /// recent). Drives the launch restore target and blank-window choice.
    private var activeWindowOrder: [MainWindowController] = []
    private weak var lastActiveProjectWindow: MainWindowController?
    private(set) var settingsWindowController: ReaderSettingsWindowController?
    /// Shared single-instance services owned by the application, injected
    /// into every window's model (§8.2/§8.3).
    private let sharedTrustRegistry: TrustRegistry
    private let sharedMaterializer: Materializer
    // Launch Services open requests (§5.2): queued until launch finished;
    // processed strictly serially afterwards.
    private var pendingOpenURLs: [URL] = []
    private var receivedExplicitOpenRequest = false
    private var launchFinished = false
    private var isDrainingOpenRequests = false
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

    private var model: AppModel {
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
    private var windowController: MainWindowController? {
        projectWindows.first
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        if wrapKeyMonitor == nil {
            wrapKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated {
                    self?.handleWrapKeyEquivalent(event) == true
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

    func runProjectorSelfTest() -> Never {
        let checks = ReaderTextView.projectorSelfTestChecks()
        let passed = !checks.isEmpty && checks.values.allSatisfy { $0 }
        do {
            var object: [String: Any] = checks
            object["channel"] = "projector"
            object["passed"] = passed
            let data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            Self.exitSelfTest(channel: "projector", status: 1)
        }
        Self.exitSelfTest(channel: "projector", status: passed ? 0 : 1)
    }

    func runFoldSelfTest() -> Never {
        let checks = ReaderTextView.foldSelfTestChecks()
        let passed = !checks.isEmpty && checks.values.allSatisfy { $0 }
        do {
            var object: [String: Any] = checks
            object["channel"] = "fold"
            object["passed"] = passed
            let data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            Self.exitSelfTest(channel: "fold", status: 1)
        }
        Self.exitSelfTest(channel: "fold", status: passed ? 0 : 1)
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

    func runNonSourceSelfTest(root: URL) -> Never {
        launch(offscreen: true)

        func finish(
            passed: Bool,
            checks: [String: Bool],
            projectReadyMS: Double,
            treePaths: [String],
            files: [[String: Any]],
            captures: [[String: Any]],
            contentSizes: [String: Any],
            history: [String: Any],
            error: String? = nil
        ) -> Never {
            var object: [String: Any] = [
                "channel": "non-source",
                "passed": passed,
                "checks": checks,
                "projectReadyMS": projectReadyMS,
                "physicalFootprintBytes": Int(physicalFootprintBytes() ?? 0),
                "treeCount": treePaths.count,
                "treePaths": treePaths,
                "files": files,
                "captures": captures,
                "contentSizes": contentSizes,
                "history": history,
            ]
            if let error { object["error"] = error }
            Self.writeJSON(object)
            Self.exitSelfTest(channel: "non-source", status: passed ? 0 : 1)
        }

        guard let controller = windowController,
              let window = controller.window
        else {
            finish(
                passed: false,
                checks: ["windowCreated": false],
                projectReadyMS: 0,
                treePaths: [],
                files: [],
                captures: [],
                contentSizes: [:],
                history: [:],
                error: "window was not created"
            )
        }
        controller.prepareTitledWindowForSelfTest()
        window.setFrameOrigin(NSPoint(x: 80, y: 80))
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let openedContentSize = window.contentView?.bounds.size ?? .zero
        var contentSizes: [String: Any] = [
            "beforePreview": [
                "width": openedContentSize.width,
                "height": openedContentSize.height,
            ],
        ]

        func allViews(in view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap { allViews(in: $0) }
        }
        func visible(_ view: NSView?) -> Bool {
            guard let view else { return false }
            view.layoutSubtreeIfNeeded()
            guard let contentView = window.contentView else { return false }
            let frame = view.convert(view.bounds, to: contentView)
            return view.window === window
                && !view.isHiddenOrHasHiddenAncestor
                && frame.width > 0
                && frame.height > 0
                && !frame.intersection(contentView.bounds).isEmpty
        }
        func labeled(_ label: String) -> NSView? {
            guard let contentView = window.contentView else { return nil }
            return allViews(in: contentView).first {
                $0.accessibilityLabel() == label
            }
        }
        func relativePath(_ file: URL) -> String? {
            let file = file.standardizedFileURL
            let root = root.standardizedFileURL
            guard file.pathComponents.starts(with: root.pathComponents),
                  file.pathComponents.count > root.pathComponents.count
            else { return nil }
            return file.pathComponents.dropFirst(root.pathComponents.count)
                .joined(separator: "/")
        }
        func select(_ file: URL) -> Bool {
            guard controller.selectFileInSidebar(file) else { return false }
            return waitUntil(timeout: 5) {
                controller.displayedReaderFile?.standardizedFileURL
                    == file.standardizedFileURL
            }
        }
        func sourceControlsAreLocked() -> Bool {
            let height = controller.selfTestReadingHeightHeader
            return !controller.canFindInFile
                && !controller.canFocusCurrentScope
                && !controller.canToggleFoldAtSelection
                && !controller.readerHasReadingPosition
                && height.hidden
                && !height.enabled
        }
        func capture(_ name: String) -> [String: Any] {
            let directory = ProcessInfo.processInfo.environment[
                "CAIRN_NON_SOURCE_CAPTURE_DIR"
            ] ?? "/tmp/cairn-non-source-captures"
            try? FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true
            )
            let path = URL(fileURLWithPath: directory)
                .appendingPathComponent("\(name).png").path
            guard let result = cachedPNG(of: window.contentView, path: path)
            else {
                return [
                    "name": name,
                    "path": path,
                    "width": 0,
                    "height": 0,
                    "visiblePixels": false,
                ]
            }
            return [
                "name": name,
                "path": result.path,
                "width": result.width,
                "height": result.height,
                "visiblePixels": result.visiblePixels,
            ]
        }
        func writeSnapshotImage(
            _ image: NSImage,
            name: String,
            captureMethod: String
        ) -> [String: Any] {
            let directory = ProcessInfo.processInfo.environment[
                "CAIRN_NON_SOURCE_CAPTURE_DIR"
            ] ?? "/tmp/cairn-non-source-captures"
            try? FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true
            )
            let path = URL(fileURLWithPath: directory)
                .appendingPathComponent("\(name).png").path
            try? FileManager.default.removeItem(atPath: path)
            guard let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let data = bitmap.representation(using: .png, properties: [:]),
                  (try? data.write(to: URL(fileURLWithPath: path))) != nil
            else {
                return [
                    "name": name,
                    "path": path,
                    "width": 0,
                    "height": 0,
                    "visiblePixels": false,
                    "captureMethod": captureMethod,
                ]
            }
            return [
                "name": name,
                "path": path,
                "width": bitmap.pixelsWide,
                "height": bitmap.pixelsHigh,
                "visiblePixels": bookmarkBitmapHasVisiblePixels(bitmap),
                "captureMethod": captureMethod,
            ]
        }
        func captureWebView(_ webView: WKWebView) -> [String: Any] {
            let directory = ProcessInfo.processInfo.environment[
                "CAIRN_NON_SOURCE_CAPTURE_DIR"
            ] ?? "/tmp/cairn-non-source-captures"
            try? FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true
            )
            let path = URL(fileURLWithPath: directory)
                .appendingPathComponent("dark-html.png").path
            try? FileManager.default.removeItem(atPath: path)
            var snapshot: NSImage?
            var snapshotError: String?
            var snapshotErrorDomain: String?
            var snapshotErrorCode: Int?
            var completed = false
            webView.layoutSubtreeIfNeeded()
            webView.displayIfNeeded()
            for _ in 0..<4 { pumpRunLoop() }
            let configuration = WKSnapshotConfiguration()
            configuration.rect = webView.bounds
            configuration.afterScreenUpdates = true
            webView.takeSnapshot(with: configuration) { image, error in
                snapshot = image
                snapshotError = error?.localizedDescription
                if let error {
                    let error = error as NSError
                    snapshotErrorDomain = error.domain
                    snapshotErrorCode = error.code
                }
                completed = true
            }
            let deadline = Date(timeIntervalSinceNow: 5)
            while !completed, Date() < deadline {
                pumpRunLoop()
            }
            guard let snapshot else {
                return [
                    "name": "dark-html",
                    "path": path,
                    "width": 0,
                    "height": 0,
                    "visiblePixels": false,
                    "error": snapshotError ?? "snapshot timed out",
                    "errorDomain": snapshotErrorDomain ?? "",
                    "errorCode": snapshotErrorCode ?? 0,
                    "captureMethod": "none",
                    "webViewInWindow": webView.window != nil,
                    "webViewHidden": webView.isHiddenOrHasHiddenAncestor,
                    "webViewFrameWidth": webView.frame.width,
                    "webViewFrameHeight": webView.frame.height,
                    "webViewURL": webView.url?.absoluteString ?? "",
                    "webViewLoading": webView.isLoading,
                    "webViewProgress": webView.estimatedProgress,
                ]
            }
            return writeSnapshotImage(
                snapshot,
                name: "dark-html",
                captureMethod: "WKWebView.takeSnapshot"
            )
        }
        func previewContentSizeIsStable() -> Bool {
            guard let contentView = window.contentView else { return false }
            let size = contentView.bounds.size
            return abs(size.width - openedContentSize.width) <= 1
                && abs(size.height - openedContentSize.height) <= 1
        }
        func recordContentSize(_ name: String) {
            let size = window.contentView?.bounds.size ?? .zero
            contentSizes[name] = [
                "width": size.width,
                "height": size.height,
                "stable": previewContentSizeIsStable(),
            ]
        }

        let projectStartedAt = ContinuousClock.now
        controller.openProject(root: root, language: .rust)
        let projectIsReady: () -> Bool = {
            if case .ready = self.model.projectState { return true }
            return false
        }
        let ready = waitUntil(timeout: 30) {
            model.snapshotPhase == .fullReady
                && model.fileTree != nil
                && projectIsReady()
        }
        let projectReadyMS = milliseconds(since: projectStartedAt)
        guard ready, let tree = model.fileTree else {
            finish(
                passed: false,
                checks: ["projectReady": false],
                projectReadyMS: projectReadyMS,
                treePaths: [],
                files: [],
                captures: [],
                contentSizes: [:],
                history: [:],
                error: "project did not reach fullReady"
            )
        }
        var treePaths: [String] = []
        func collect(_ nodes: [FileTreeNode]) {
            for node in nodes {
                if node.isDirectory {
                    collect(node.children)
                } else if let path = relativePath(node.url) {
                    treePaths.append(path)
                }
            }
        }
        collect(tree.children)
        treePaths.sort()
        let requiredPaths = [
            "main.rs", "README.md", "page.html", "image.png",
            "paper.pdf", "notes.txt",
        ]
        var checks: [String: Bool] = [
            "projectReady": true,
            "treeContainsRequiredFiles": requiredPaths.allSatisfy {
                treePaths.contains($0)
            },
        ]
        var files: [[String: Any]] = []
        var captures: [[String: Any]] = []
        var history: [String: Any] = [:]

        let readme = root.appendingPathComponent("README.md")
        let guide = root.appendingPathComponent("docs/guide.md")

        let markdownSelected = select(readme)
        let markdownState = controller.selfTestReaderPreviewKind == "Markdown"
        let markdownView = labeled("Markdown preview")
        recordContentSize("markdown")
        checks["markdownPreview"] = markdownSelected
            && markdownState
            && visible(markdownView)
            && controller.selfTestReaderPreviewText?.contains("guide") == true
            && sourceControlsAreLocked()
            && previewContentSizeIsStable()
        files.append([
            "path": "README.md",
            "kind": controller.selfTestReaderPreviewKind ?? "",
            "accessibilityLabel": markdownView?.accessibilityLabel() ?? "",
            "frameWidth": markdownView?.frame.width ?? 0,
            "frameHeight": markdownView?.frame.height ?? 0,
            "visible": visible(markdownView),
        ])
        var light = ReaderSettings()
        light.theme = .light
        controller.applyReaderSettings(light)
        pumpRunLoop()
        let lightCapture = capture("light-markdown")
        captures.append(lightCapture)
        checks["captureLightMarkdown"] = lightCapture["visiblePixels"] as? Bool == true

        let historyBeforeLink = model.navigationHistory.records.count
        let linkActivated = controller.selfTestActivatePreviewLink(at: 0)
        let guideSelected = waitUntil(timeout: 5) {
            controller.displayedReaderFile?.standardizedFileURL
                == guide.standardizedFileURL
        }
        history["beforeMarkdownLink"] = historyBeforeLink
        history["afterMarkdownLink"] = model.navigationHistory.records.count
        history["markdownLinkActivated"] = linkActivated
        let historyAfterLink = model.navigationHistory.records.count
        controller.goBack(nil)
        let back = waitUntil(timeout: 5) {
            controller.displayedReaderFile?.standardizedFileURL
                == readme.standardizedFileURL
        }
        controller.goForward(nil)
        let forward = waitUntil(timeout: 5) {
            controller.displayedReaderFile?.standardizedFileURL
                == guide.standardizedFileURL
        }
        history["afterBack"] = model.navigationHistory.records.count
        history["afterForward"] = model.navigationHistory.records.count
        history["trailEdges"] = model.readingTrail.edges.count
        checks["markdownLinkHistory"] = linkActivated
            && guideSelected
            && back
            && forward
            && historyAfterLink == historyBeforeLink + 1
            && model.readingTrail.edges.isEmpty

        let page = root.appendingPathComponent("page.html")
        let htmlSelected = select(page)
        pumpRunLoop()
        let htmlWebView = labeled("HTML preview") as? WKWebView
            ?? window.contentView.flatMap { content in
                allViews(in: content).compactMap { $0 as? WKWebView }.first
            }
        let htmlLoaded = waitUntil(timeout: 5) {
            controller.selfTestReaderHTMLFinished
                && htmlWebView != nil
                && htmlWebView?.isLoading == false
        }
        let htmlKind = controller.selfTestReaderPreviewKind
        recordContentSize("html")
        let htmlWebViewHasNonPersistentDataStore =
            htmlWebView?.configuration.websiteDataStore.isPersistent == false
        let htmlWebViewHasJavaScriptDisabled =
            htmlWebView?.configuration.defaultWebpagePreferences
                .allowsContentJavaScript == false
        checks["htmlPreview"] = htmlSelected
            && htmlKind == "HTML"
            && htmlLoaded
            && visible(htmlWebView)
            && htmlWebViewHasNonPersistentDataStore
            && htmlWebViewHasJavaScriptDisabled
            && htmlWebView?.accessibilityLabel() == "HTML preview"
            && sourceControlsAreLocked()
            && previewContentSizeIsStable()
        let htmlWidth = htmlWebView?.frame.width ?? 0
        let htmlHeight = htmlWebView?.frame.height ?? 0
        files.append([
            "path": "page.html",
            "kind": htmlKind ?? "",
            "accessibilityLabel": htmlWebView?.accessibilityLabel() ?? "",
            "frameWidth": htmlWidth,
            "frameHeight": htmlHeight,
            "visible": visible(htmlWebView),
            "loaded": htmlLoaded,
            "didFinish": controller.selfTestReaderHTMLFinished,
            "loadError": controller.selfTestReaderHTMLLoadError ?? "",
            "javaScriptEnabled": !htmlWebViewHasJavaScriptDisabled,
            "dataStorePersistent": !htmlWebViewHasNonPersistentDataStore,
        ])
        var dark = ReaderSettings()
        dark.theme = .dark
        controller.applyReaderSettings(dark)
        let htmlReloaded = waitUntil(timeout: 5) {
            controller.selfTestReaderHTMLFinished
                && htmlWebView != nil
                && htmlWebView?.isLoading == false
        }
        pumpRunLoop()
        let darkCapture: [String: Any] = if htmlReloaded,
                                            let htmlWebView
        {
            captureWebView(htmlWebView)
        } else {
            [
                "name": "dark-html",
                "path": "",
                "width": 0,
                "height": 0,
                "visiblePixels": false,
                "error": controller.selfTestReaderHTMLLoadError
                    ?? "HTML did not finish loading",
            ]
        }
        captures.append(darkCapture)
        checks["captureDarkHTML"] = htmlReloaded
            && darkCapture["visiblePixels"] as? Bool == true

        let image = root.appendingPathComponent("image.png")
        let imageSelected = select(image)
        let imageView = labeled("Image preview") as? NSImageView
        let imageKind = controller.selfTestReaderPreviewKind
        recordContentSize("image")
        checks["imagePreview"] = imageSelected
            && imageKind == "Image"
            && imageView?.image != nil
            && visible(imageView)
            && sourceControlsAreLocked()
            && previewContentSizeIsStable()
        files.append([
            "path": "image.png",
            "kind": imageKind ?? "",
            "accessibilityLabel": imageView?.accessibilityLabel() ?? "",
            "frameWidth": imageView?.frame.width ?? 0,
            "frameHeight": imageView?.frame.height ?? 0,
            "visible": visible(imageView),
            "hasImage": imageView?.image != nil,
        ])
        var siClassic = ReaderSettings()
        siClassic.theme = .siClassic
        controller.applyReaderSettings(siClassic)
        pumpRunLoop()
        let imageCapture = capture("si-image")
        captures.append(imageCapture)
        checks["captureSIImage"] = imageCapture["visiblePixels"] as? Bool == true

        let pdf = root.appendingPathComponent("paper.pdf")
        let pdfSelected = select(pdf)
        let pdfView = labeled("PDF preview") as? PDFView
        let pdfKind = controller.selfTestReaderPreviewKind
        recordContentSize("pdf")
        checks["pdfPreview"] = pdfSelected
            && pdfKind == "PDF"
            && (pdfView?.document?.pageCount ?? 0) > 0
            && visible(pdfView)
            && sourceControlsAreLocked()
            && previewContentSizeIsStable()
        files.append([
            "path": "paper.pdf",
            "kind": pdfKind ?? "",
            "accessibilityLabel": pdfView?.accessibilityLabel() ?? "",
            "frameWidth": pdfView?.frame.width ?? 0,
            "frameHeight": pdfView?.frame.height ?? 0,
            "visible": visible(pdfView),
            "pageCount": pdfView?.document?.pageCount ?? 0,
        ])
        let pdfCapture: [String: Any]
        if let pdfView,
           let page = pdfView.currentPage ?? pdfView.document?.page(at: 0)
        {
            let targetSize = NSSize(
                width: max(1, pdfView.bounds.width),
                height: max(1, pdfView.bounds.height)
            )
            pdfCapture = writeSnapshotImage(
                page.thumbnail(of: targetSize, for: .mediaBox),
                name: "si-pdf",
                captureMethod: "PDFPage.thumbnail"
            )
        } else {
            pdfCapture = [
                "name": "si-pdf",
                "path": "",
                "width": 0,
                "height": 0,
                "visiblePixels": false,
                "captureMethod": "PDFPage.thumbnail",
            ]
        }
        captures.append(pdfCapture)
        checks["captureSIPDF"] = pdfCapture["visiblePixels"] as? Bool == true

        let notes = root.appendingPathComponent("notes.txt")
        let notesSelected = select(notes)
        let notesKind = controller.selfTestReaderPreviewKind
        let notesPreviewText = controller.selfTestReaderPreviewText
        recordContentSize("plainText")
        let notesText = (try? Data(contentsOf: notes))
            .flatMap { String(data: $0, encoding: .utf8) }
        checks["plainTextPreview"] = notesSelected
            && notesKind == "Plain text"
            && notesPreviewText == notesText
            && sourceControlsAreLocked()
            && previewContentSizeIsStable()
        files.append([
            "path": "notes.txt",
            "kind": notesKind ?? "",
            "accessibilityLabel": "Plain text preview",
            "frameWidth": 0,
            "frameHeight": 0,
            "visible": visible(labeled("Plain text preview")),
        ])

        let main = root.appendingPathComponent("main.rs")
        let sourceSelected = select(main)
        let sourceHeight = controller.selfTestReadingHeightHeader
        checks["sourceSurfaceRestored"] = sourceSelected
            && controller.selfTestReaderPreviewKind == nil
            && controller.selfTestLeftReaderBytes != nil
            && controller.canFindInFile
            && sourceHeight.enabled
            && !sourceHeight.hidden
        history["sourceRestored"] = checks["sourceSurfaceRestored"] == true
        history["treeCount"] = treePaths.count
        let passed = checks.values.allSatisfy { $0 }
        finish(
            passed: passed,
            checks: checks,
            projectReadyMS: projectReadyMS,
            treePaths: treePaths,
            files: files,
            captures: captures,
            contentSizes: contentSizes,
            history: history
        )
    }

    func runTabsSelfTest() -> Never {
        let root: URL
        do {
            root = try makeTabsSelfTestRepository()
        } catch {
            Self.finishTabsSelfTest(
                checks: [:],
                geometry: [:],
                error: error.localizedDescription
            )
        }

        func finish(
            checks: [String: Bool],
            geometry: [String: Double],
            error: String? = nil
        ) -> Never {
            try? FileManager.default.removeItem(at: root)
            Self.finishTabsSelfTest(
                checks: checks,
                geometry: geometry,
                error: error
            )
        }

        // Exclude the titled-window WindowServer cache from the tab footprint measurement.
        launch(offscreen: true, measuresIdleFootprint: true)
        guard let controller = windowController else {
            finish(checks: [:], geometry: [:], error: "window unavailable")
        }
        let contentSize = NSSize(width: 1_600, height: 1_000)
        controller.window?.setContentSize(contentSize)
        controller.window?.contentView?.setFrameSize(contentSize)
        pumpRunLoop()

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
            finish(
                checks: [:],
                geometry: [:],
                error: "project or HEAD~1 unavailable"
            )
        }

        let fileA = root.appendingPathComponent("src/a.rs").standardizedFileURL
        let fileB = root.appendingPathComponent("src/b.rs").standardizedFileURL
        let menus = NSApplication.shared.mainMenu?.items.compactMap(\.submenu)
        let fileMenu = menus?.first { $0.title == "File" }
        let goMenu = menus?.first { $0.title == "Go" }
        let openInNewTabItem = fileMenu?.item(withTitle: "Open in New Tab")
        let closeTabItem = fileMenu?.item(withTitle: "Close Tab")
        let previousTabItem = goMenu?.item(withTitle: "Previous Tab")
        let nextTabItem = goMenu?.item(withTitle: "Next Tab")
        let menuChecks = [
            "sidebarHasOpenInNewTab":
                controller.selfTestFileContextMenuHasOpenInNewTab,
            "commandShiftReturnOpensNewTab":
                openInNewTabItem?.keyEquivalent == "\r"
                && openInNewTabItem?.keyEquivalentModifierMask
                    == [.command, .shift]
                && openInNewTabItem?.action
                    == #selector(openSelectedFileInNewTab(_:))
                && openInNewTabItem?.target === self,
            "commandWClosesTab":
                closeTabItem?.keyEquivalent == "w"
                && closeTabItem?.keyEquivalentModifierMask == .command
                && closeTabItem?.action == #selector(closeActiveTab(_:))
                && closeTabItem?.target === self,
            "commandShiftBracketSwitchesTabs":
                previousTabItem?.keyEquivalent == "["
                && previousTabItem?.keyEquivalentModifierMask
                    == [.command, .shift]
                && previousTabItem?.action == #selector(selectPreviousTab(_:))
                && previousTabItem?.target === self
                && nextTabItem?.keyEquivalent == "]"
                && nextTabItem?.keyEquivalentModifierMask
                    == [.command, .shift]
                && nextTabItem?.action == #selector(selectNextTab(_:))
                && nextTabItem?.target === self,
        ]
        guard let bytesA = try? [UInt8](Data(contentsOf: fileA)),
              let bytesB = try? [UInt8](Data(contentsOf: fileB)),
              let scrollTarget = Data(bytesA).range(
                  of: Data("let anchor_180".utf8)
              )?.lowerBound,
              let scrollByteOffset = UInt32(exactly: scrollTarget),
              let selectionByteOffset = UInt32(exactly: scrollTarget + 4),
              waitUntil(timeout: 5, condition: {
                  controller.selectFileInSidebar(fileA)
              }),
              waitUntil(timeout: 5, condition: {
                  controller.displayedReaderFile?.standardizedFileURL == fileA
                      && controller.selfTestLeftReaderBytes == bytesA
              })
        else {
            finish(
                checks: [:],
                geometry: [:],
                error: "could not open tab fixture A"
            )
        }

        controller.setReadingPositionForSelfTest(
            scrollByteOffset: scrollByteOffset,
            selectionByteOffset: selectionByteOffset
        )
        pumpRunLoop()
        guard let recordedScroll = controller.selfTestReadingByteOffset else {
            finish(
                checks: [:],
                geometry: [:],
                error: "could not record A reading position"
            )
        }
        let oneTabGeometry = Self.tabGeometryChecks(
            controller.selfTestTabGeometry,
            prefix: "oneTab",
            expectsVisibleStrip: true
        )
        let openedA = controller.selfTestTabCount == 1
            && controller.selfTestActiveTabIndex == 0
            && controller.selfTestLeftReaderBytes == bytesA
        Self.writeJSON([
            "step": "openA",
            "tabs": controller.selfTestTabCount,
            "active": controller.selfTestActiveTabIndex ?? -1,
            "stripHidden": controller.selfTestTabGeometry.stripHidden,
            "recordedScroll": recordedScroll,
        ])

        controller.openFileInNewTabForSelfTest(fileB)
        guard waitUntil(timeout: 5, condition: {
            controller.displayedReaderFile?.standardizedFileURL == fileB
                && controller.selfTestLeftReaderBytes == bytesB
        }) else {
            finish(
                checks: oneTabGeometry,
                geometry: [:],
                error: "could not open tab fixture B"
            )
        }
        pumpRunLoop()
        let twoTabGeometry = Self.tabGeometryChecks(
            controller.selfTestTabGeometry,
            prefix: "twoTabs",
            expectsVisibleStrip: true
        )
        let openedB = controller.selfTestTabCount == 2
            && controller.selfTestActiveTabIndex == 1
            && controller.selfTestActiveTabFile?.standardizedFileURL == fileB
            && controller.selfTestLeftReaderBytes == bytesB
        let dualTabFootprintMB = physicalFootprintBytes().map {
            Double($0) / 1_048_576
        } ?? -1
        let dualTabFootprintUnderBudget = dualTabFootprintMB >= 0
            && dualTabFootprintMB < SelfTestBudgets.idleFootprintMB
        Self.writeJSON([
            "step": "openB",
            "tabs": controller.selfTestTabCount,
            "active": controller.selfTestActiveTabIndex ?? -1,
            "bytesEqual": controller.selfTestLeftReaderBytes == bytesB,
            "footprintMB": dualTabFootprintMB,
            "geometry": Self.tabGeometryJSON(controller.selfTestTabGeometry),
        ])

        let previousTabActionSent = previousTabItem.flatMap { item in
            item.action.map {
                NSApplication.shared.sendAction(
                    $0,
                    to: item.target,
                    from: item
                )
            }
        } ?? false
        let restoredA = previousTabActionSent
            && waitUntil(timeout: 5, condition: {
                controller.displayedReaderFile?.standardizedFileURL == fileA
                    && controller.selfTestLeftReaderBytes == bytesA
            })
        pumpRunLoop()
        let restoredScroll = controller.selfTestReadingByteOffset
        let scrollRestored = restoredScroll.map {
            abs(Int64($0) - Int64(recordedScroll)) <= 4
        } == true
        let selectionRestored =
            controller.selfTestActiveTabSelectionByteOffset == selectionByteOffset
        Self.writeJSON([
            "step": "switchA",
            "bytesEqual": controller.selfTestLeftReaderBytes == bytesA,
            "recordedScroll": recordedScroll,
            "restoredScroll": restoredScroll.map(Int.init) ?? -1,
            "scrollRestored": scrollRestored,
            "selectionRestored": selectionRestored,
        ])

        let nextTabActionSent = nextTabItem.flatMap { item in
            item.action.map {
                NSApplication.shared.sendAction(
                    $0,
                    to: item.target,
                    from: item
                )
            }
        } ?? false
        let selectedBByCommand = nextTabActionSent
            && waitUntil(timeout: 5, condition: {
                controller.displayedReaderFile?.standardizedFileURL == fileB
                    && controller.selfTestLeftReaderBytes == bytesB
            })
        let closeTabActionSent = closeTabItem.flatMap { item in
            item.action.map {
                NSApplication.shared.sendAction(
                    $0,
                    to: item.target,
                    from: item
                )
            }
        } ?? false
        let closedBByCommand = closeTabActionSent
            && waitUntil(timeout: 5, condition: {
                controller.selfTestTabCount == 1
                    && controller.displayedReaderFile?
                        .standardizedFileURL == fileA
                    && controller.selfTestLeftReaderBytes == bytesA
            })
        pumpRunLoop()
        let closedB = selectedBByCommand
            && closedBByCommand
            && controller.selfTestTabCount == 1
            && controller.selfTestActiveTabIndex == 0
            && controller.displayedReaderFile?.standardizedFileURL == fileA
            && controller.selfTestLeftReaderBytes == bytesA
        let hiddenAfterCloseGeometry = Self.tabGeometryChecks(
            controller.selfTestTabGeometry,
            prefix: "oneTabAfterClose",
            expectsVisibleStrip: true
        )
        Self.writeJSON([
            "step": "closeB",
            "tabs": controller.selfTestTabCount,
            "active": controller.selfTestActiveTabIndex ?? -1,
            "readerStillA": controller.displayedReaderFile?
                .standardizedFileURL == fileA,
            "stripHidden": controller.selfTestTabGeometry.stripHidden,
            "geometry": Self.tabGeometryJSON(controller.selfTestTabGeometry),
        ])

        controller.openFileInNewTabForSelfTest(fileB)
        controller.selectPreviousTab()
        let previousRevision = model.commitPicker.commits[1].fullSHA
        guard controller.selectCommit(previousRevision),
              waitUntil(timeout: 30, condition: {
                  self.model.currentRevision == previousRevision
                      && self.model.snapshotPhase == .fullReady
              })
        else {
            var checks = oneTabGeometry
            checks.merge(twoTabGeometry) { _, new in new }
            checks.merge(hiddenAfterCloseGeometry) { _, new in new }
            finish(
                checks: checks,
                geometry: Self.tabGeometryJSON(controller.selfTestTabGeometry),
                error: "snapshot switch did not complete"
            )
        }
        controller.selectNextTab()
        let missingFilePlaceholder = waitUntil(timeout: 5, condition: {
            controller.displayedReaderFile?.standardizedFileURL == fileB
                && controller.selfTestLeftReaderBytes == nil
                && controller.selfTestReaderPlaceholderVisible
                && controller.selfTestReaderPlaceholderText
                    == "Could not open b.rs"
        })
        Self.writeJSON([
            "step": "missingSnapshotFile",
            "revision": previousRevision,
            "file": controller.displayedReaderFile?.path ?? "",
            "placeholder": controller.selfTestReaderPlaceholderText ?? "",
            "bytesAreNil": controller.selfTestLeftReaderBytes == nil,
            "honestPlaceholder": missingFilePlaceholder,
        ])

        var checks = oneTabGeometry
        checks.merge(twoTabGeometry) { _, new in new }
        checks.merge(hiddenAfterCloseGeometry) { _, new in new }
        checks.merge(menuChecks) { _, new in new }
        checks.merge([
            "oneTabOpened": openedA,
            "openedBInNewTab": openedB,
            "dualTabFootprintUnderBudget": dualTabFootprintUnderBudget,
            "switchedBackToA": restoredA,
            "aBytesRestored": restoredA,
            "scrollRestored": scrollRestored,
            "selectionAnchorRestored": selectionRestored,
            "closedBWhileReaderStayedOnA": closedB,
            "missingSnapshotFileShowsHonestPlaceholder":
                missingFilePlaceholder,
        ]) { _, new in new }
        finish(
            checks: checks,
            geometry: Self.tabGeometryJSON(controller.selfTestTabGeometry)
        )
    }

    func runSearchSelfTest() -> Never {
        let root: URL
        do {
            root = try makeSearchSelfTestDirectory()
        } catch {
            Self.writeJSON([
                "error": error.localizedDescription,
                "selfTest": "search",
            ])
            Self.exitSelfTest(channel: "search", status: 1)
        }

        func finish(
            state: (
                totalRows: Int,
                groupRows: Int,
                matchRows: Int,
                truncationRows: Int,
                truncationVisible: Bool,
                truncationDiagnostic: [String: String]?,
                status: String,
                searching: Bool
            )?,
            error: String? = nil
        ) -> Never {
            try? FileManager.default.removeItem(at: root)
            let checks = [
                "matchRowsCappedAt2000": state?.matchRows == 2_000,
                "statusContainsTrueTotal": state?.status.contains("2001") == true,
                "truncationRowExists": state?.truncationRows == 1,
                "truncationRowVisible": state?.truncationVisible == true,
            ]
            Self.writeJSON([
                "checks": checks,
                "error": error as Any,
                "groupRows": state?.groupRows as Any,
                "matchRows": state?.matchRows as Any,
                "searching": state?.searching as Any,
                "selfTest": "search",
                "status": state?.status as Any,
                "totalRows": state?.totalRows as Any,
                "truncationRows": state?.truncationRows as Any,
                "truncationDiagnostic": state?.truncationDiagnostic as Any,
            ])
            Self.exitSelfTest(
                channel: "search",
                status: error == nil && checks.values.allSatisfy { $0 } ? 0 : 1
            )
        }

        launch(offscreen: true)
        guard let controller = windowController else {
            finish(state: nil, error: "window unavailable")
        }
        let contentSize = NSSize(width: 1_600, height: 1_000)
        controller.window?.setContentSize(contentSize)
        controller.window?.contentView?.setFrameSize(contentSize)
        pumpRunLoop()

        controller.openProject(root: root)
        guard waitUntil(timeout: 30, condition: {
            if case .failed = self.model.projectState { return true }
            if case .ready = self.model.projectState { return true }
            return false
        }), case .ready = model.projectState else {
            finish(state: nil, error: "fixture indexing failed")
        }

        controller.showProjectSearch()
        controller.selfTestSetProjectSearchQuery("zzqqmarker")
        guard waitUntil(timeout: 30, condition: {
            guard let state = controller.selfTestProjectSearchOutlineState else {
                return false
            }
            return !state.searching && state.status.contains("2001")
        }) else {
            finish(
                state: controller.selfTestProjectSearchOutlineState,
                error: "search did not finish"
            )
        }

        controller.selfTestRevealProjectSearchTruncationRow()
        pumpRunLoop()
        finish(state: controller.selfTestProjectSearchOutlineState)
    }

    func runReadingSelfTest() -> Never {
        let root: URL
        do {
            root = try makeReadingSelfTestDirectory()
        } catch {
            Self.finishReadingSelfTest(
                checks: [:],
                metrics: [:],
                error: error.localizedDescription
            )
        }

        func finish(
            checks: [String: Bool],
            metrics: [String: Double],
            error: String? = nil
        ) -> Never {
            try? FileManager.default.removeItem(at: root)
            Self.finishReadingSelfTest(
                checks: checks,
                metrics: metrics,
                error: error
            )
        }

        launch(offscreen: true, measuresIdleFootprint: true)
        guard let controller = windowController else {
            finish(checks: [:], metrics: [:], error: "window unavailable")
        }
        // The design's 100 MB budget is for an idle app, before a project
        // or the enlarged reading viewport is loaded. Report loaded memory
        // separately instead of comparing it with the idle budget.
        let readingIdleFootprintMB = physicalFootprintBytes().map {
            Double($0) / 1_048_576
        } ?? -1
        let contentSize = NSSize(width: 1_600, height: 1_000)
        controller.window?.setContentSize(contentSize)
        controller.window?.contentView?.setFrameSize(contentSize)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.window?.displayIfNeeded()
        controller.openProject(root: root)
        guard waitUntil(timeout: 10, condition: {
            if case .failed = self.model.projectState { return true }
            if case .ready = self.model.projectState { return true }
            return false
        }), case .ready = model.projectState
        else {
            finish(checks: [:], metrics: [:], error: "fixture project unavailable")
        }

        let regular = root.appendingPathComponent("regular.rs")
        guard let regularBytes = try? [UInt8](Data(contentsOf: regular)),
              let alphaOffset = Data(regularBytes).range(
                  of: Data("alpha".utf8)
              )?.lowerBound,
              let betaOffset = Data(regularBytes).range(
                  of: Data("beta".utf8)
              )?.lowerBound
        else {
            finish(checks: [:], metrics: [:], error: "regular fixture unavailable")
        }
        controller.openFileForSelfTest(regular)
        guard waitUntil(timeout: 5, condition: {
            controller.selfTestLeftReaderBytes == regularBytes
        }) else {
            finish(checks: [:], metrics: [:], error: "regular reader did not open")
        }
        pumpRunLoop()

        let geometryOn = controller.selfTestReadingGeometry
        let alphaCount = controller.selfTestActivateReading(
            at: UInt32(alphaOffset)
        )
        let betaCount = controller.selfTestActivateReading(
            at: UInt32(betaOffset)
        )
        let currentLine = controller.selfTestCurrentLineNumber
        let currentLineState = controller.selfTestVisibleCurrentLineNumbers
        let visibleLineNumbers = controller.selfTestVisibleLineNumbers
        let regularFootprintMB = physicalFootprintBytes().map {
            Double($0) / 1_048_576
        } ?? -1
        let blankCount = controller.selfTestActivateReading(at: 2)

        var disabledSettings = readerSettings
        disabledSettings.lineNumbers = false
        controller.applyReaderSettings(disabledSettings)
        pumpRunLoop()
        let geometryOff = controller.selfTestReadingGeometry

        let tolerance: CGFloat = 1
        let rulerInsideWindow = geometryOn.windowContentFrame
            .insetBy(dx: -tolerance, dy: -tolerance)
            .contains(geometryOn.rulerFrame)
        let rulerInClip = geometryOn.clipFrame.intersection(geometryOn.rulerFrame)
        let occupiedRulerWidth = rulerInClip.isNull ? 0 : rulerInClip.width
        let rulerWidthEquation = abs(
            geometryOn.contentFrame.width
                - (
                    geometryOn.clipFrame.width
                        - occupiedRulerWidth
                )
        ) <= tolerance
        let disabledWidthEquation = abs(
            geometryOff.contentFrame.width
                - geometryOff.clipFrame.width
        ) <= tolerance
        let disabledWidthGainEquation =
            abs(geometryOff.clipFrame.width - geometryOn.clipFrame.width) <= tolerance
            && abs(geometryOff.contentFrame.width
                - geometryOn.contentFrame.width
                - occupiedRulerWidth) <= tolerance
        let legacySettings = ReaderSettings()
        controller.applyReaderSettings(legacySettings)
        let legacyFunctionFontName = controller.selfTestLeftReaderFontName(
            at: UInt32(alphaOffset)
        )
        var changedVisualSettings = legacySettings
        changedVisualSettings.functionDeclarationFontWeight =
            Double(NSFont.Weight.regular.rawValue)
        controller.applyReaderSettings(changedVisualSettings)
        pumpRunLoop()
        let changedFunctionFontName = controller.selfTestLeftReaderFontName(
            at: UInt32(alphaOffset)
        )
        let visualSettingAppliedImmediately =
            legacyFunctionFontName
                == NSFont.monospacedSystemFont(
                    ofSize: legacySettings.fontSize
                        + legacySettings.functionNameDelta,
                    weight: NSFont.Weight(rawValue: legacySettings.functionDeclarationFontWeight)
                ).fontName
            && changedFunctionFontName
                == NSFont.monospacedSystemFont(
                    ofSize: legacySettings.fontSize
                        + legacySettings.functionNameDelta,
                    weight: .regular
                ).fontName
            && changedFunctionFontName != legacyFunctionFontName

        let originalReaderSettings = readerSettings
        var commandSettings = legacySettings
        commandSettings.fontSize = 12
        commitReaderSettings(commandSettings)
        showSettings(nil)
        settingsWindowController?.window?.setFrameOrigin(
            NSPoint(x: -20_000, y: -20_000)
        )
        pumpRunLoop()
        let viewMenu = NSApplication.shared.mainMenu?.items
            .compactMap(\.submenu).first { $0.title == "View" }
        let increaseFontItem = viewMenu?.item(withTitle: "Increase Font Size")
        let decreaseFontItem = viewMenu?.item(withTitle: "Decrease Font Size")
        let fontMenuUsesExactKeyEquivalents =
            increaseFontItem?.keyEquivalent == "+"
            && increaseFontItem?.keyEquivalentModifierMask == .command
            && decreaseFontItem?.keyEquivalent == "-"
            && decreaseFontItem?.keyEquivalentModifierMask == .command
        increaseReaderFontSize(nil)
        let firstIncrease = readerSettings.fontSize
        increaseReaderFontSize(nil)
        pumpRunLoop()
        let secondIncrease = readerSettings.fontSize
        let fontChangesByOnePoint = firstIncrease == 13 && secondIncrease == 14
        let fileReaderFontUpdatesImmediately =
            controller.selfTestLeftReaderFontSize(at: 0) == 14
        let openSettingsWindowUpdatesImmediately =
            settingsWindowController?.currentSettings.fontSize == 14
        let defaultsRoundTripAfterMenuChange =
            ReaderSettings(defaults: .standard) == readerSettings
        while readerSettings.fontSize < ReaderSettings.fontSizeRange.upperBound {
            increaseReaderFontSize(nil)
        }
        let upperBoundDisablesIncrease = increaseFontItem.map {
            readerSettings.fontSize == 24 && !validateMenuItem($0)
        } ?? false
        increaseReaderFontSize(nil)
        let upperBoundClamps = readerSettings.fontSize == 24
        while readerSettings.fontSize > ReaderSettings.fontSizeRange.lowerBound {
            decreaseReaderFontSize(nil)
        }
        let lowerBoundDisablesDecrease = decreaseFontItem.map {
            readerSettings.fontSize == 10 && !validateMenuItem($0)
        } ?? false
        decreaseReaderFontSize(nil)
        let lowerBoundClamps = readerSettings.fontSize == 10
        settingsWindowController?.close()
        commitReaderSettings(originalReaderSettings)

        ReaderSettingsWindowController.selfTestEnableAccessibility()
        let settingsController = ReaderSettingsWindowController(
            settings: legacySettings,
            exactCoordinator: model.exactCoordinator,
            onRevoke: { _ in },
            onChange: { _ in }
        )
        settingsController.window?.setFrameOrigin(
            NSPoint(x: -20_000, y: -20_000)
        )
        settingsController.showWindow(nil)
        pumpRunLoop()
        _ = settingsController.selfTestPressReaderControl("Advanced typography")
        pumpRunLoop()
        let settingsGeometry = settingsController.selfTestVisualControlGeometry
        settingsController.close()
        let visualControlsVisible = settingsGeometry.frames.count == 4
            && settingsGeometry.frames.allSatisfy {
                $0.width > 0 && $0.height > 0
                    && settingsGeometry.visibleFrame.contains($0)
            }
        let visualControlsDoNotOverlap = settingsGeometry.frames.indices.allSatisfy {
            index in
            settingsGeometry.frames.indices.allSatisfy {
                $0 == index
                    || !settingsGeometry.frames[index]
                        .intersects(settingsGeometry.frames[$0])
            }
                && settingsGeometry.existingFrames.allSatisfy {
                    !settingsGeometry.frames[index].intersects($0)
                }
        }
        var checks: [String: Bool] = [
            "rulerExistsByDefault":
                geometryOn.hasRuler && geometryOn.rulerThickness > 0,
            "rulerInsideWindowContent": rulerInsideWindow,
            "readerWidthEqualsContainerMinusRuler": rulerWidthEquation,
            "firstGlyphGapIsReadableWithRuler":
                geometryOn.firstGlyphGap.map { (8...12).contains($0) } ?? false,
            "firstGlyphGapIsReadableWithoutRuler":
                geometryOff.firstGlyphGap.map { (8...12).contains($0) } ?? false,
            "disabledRulerRestoresFullWidth":
                !geometryOff.hasRuler
                && geometryOff.rulerThickness == 0
                && disabledWidthEquation,
            "disabledRulerExpandsReaderByRulerWidth":
                disabledWidthGainEquation,
            "visibleLineNumbersMatchFixture":
                visibleLineNumbers.contains(1)
                && visibleLineNumbers.allSatisfy { (1...3).contains($0) },
            "alphaOccurrenceCountMatches": alphaCount == 3,
            "switchingToBetaReplacesOccurrences": betaCount == 2,
            "currentLineIsExclusive":
                currentLine == 2 && currentLineState == [2],
            "blankClickClearsOccurrences":
                blankCount == 0 && controller.selfTestOccurrenceCount == 0,
            "readerVisualSettingAppliedImmediately":
                visualSettingAppliedImmediately,
            "fontMenuUsesExactKeyEquivalents":
                fontMenuUsesExactKeyEquivalents,
            "fontMenuChangesByOnePoint": fontChangesByOnePoint,
            "fontMenuUpperBoundDisabledAndClamped":
                upperBoundDisablesIncrease && upperBoundClamps,
            "fontMenuLowerBoundDisabledAndClamped":
                lowerBoundDisablesDecrease && lowerBoundClamps,
            "fontMenuPersistsUserDefaults": defaultsRoundTripAfterMenuChange,
            "fontMenuUpdatesFileReaderImmediately":
                fileReaderFontUpdatesImmediately,
            "fontMenuUpdatesOpenSettingsImmediately":
                openSettingsWindowUpdatesImmediately,
            "readerVisualControlsVisibleWithGeometry":
                visualControlsVisible,
            "readerVisualControlsDoNotOverlap":
                visualControlsDoNotOverlap,
            "idleFootprintUnderBudget":
                readingIdleFootprintMB >= 0
                && readingIdleFootprintMB < SelfTestBudgets.idleFootprintMB,
        ]
        Self.writeJSON([
            "step": "regular",
            "alphaOccurrences": alphaCount,
            "betaOccurrences": betaCount,
            "currentLine": currentLine ?? -1,
            "visibleLineNumbers": visibleLineNumbers,
            "footprintMB": regularFootprintMB,
            "rulerWidth": Double(geometryOn.rulerFrame.width),
            "rulerMinX": Double(geometryOn.rulerFrame.minX),
            "rulerMaxX": Double(geometryOn.rulerFrame.maxX),
            "readerWidth": Double(geometryOn.contentFrame.width),
            "readerMinX": Double(geometryOn.contentFrame.minX),
            "readerMaxX": Double(geometryOn.contentFrame.maxX),
            "firstGlyphGapWithRuler": Double(geometryOn.firstGlyphGap ?? -1),
            "firstGlyphGapWithoutRuler": Double(geometryOff.firstGlyphGap ?? -1),
            "readerWidthWithoutRuler": Double(geometryOff.contentFrame.width),
            "containerWidth": Double(geometryOn.scrollFrame.width),
            "containerMinX": Double(geometryOn.scrollFrame.minX),
            "containerMaxX": Double(geometryOn.scrollFrame.maxX),
            "availableContentWidth":
                Double(
                    geometryOn.clipFrame.width
                        - occupiedRulerWidth
                ),
            "availableContentMinX":
                Double(geometryOn.contentFrame.minX),
            "availableContentMaxX":
                Double(geometryOn.clipFrame.maxX),
        ])

        let referenceFixture = root.appendingPathComponent(
            "target/m6_reference_density.rs"
        )
        let referenceProjectFixture = root.appendingPathComponent(
            "m6_reference_density.rs"
        )
        do {
            try FileManager.default.copyItem(
                at: referenceFixture,
                to: referenceProjectFixture
            )
        } catch {
            finish(
                checks: checks,
                metrics: [:],
                error: "M6 reference scale copy failed: \(error)"
            )
        }
        // Opening the same project now focuses its existing reading session.
        // The fixture added above needs an explicit index refresh instead.
        let beforeReferenceRefresh = model.generation
        controller.refreshProjectIndex(nil)
        guard waitUntil(timeout: 30, condition: {
            if case .failed = self.model.projectState { return true }
            if !self.model.isRefreshingIndex
                && self.model.generation > beforeReferenceRefresh
                && self.model.fileTree != nil
                && self.model.snapshotPhase == .fullReady
            {
                return true
            }
            return false
        }) && model.fileTree != nil
            && model.snapshotPhase == .fullReady
        else {
            finish(
                checks: checks,
                metrics: [:],
                error: "reference fixture project unavailable"
            )
        }
        controller.openFileForSelfTest(regular)
        guard waitUntil(timeout: 5, condition: {
            controller.selfTestLeftReaderBytes == regularBytes
        }) else {
            finish(
                checks: checks,
                metrics: [:],
                error: "reference reader did not reopen"
            )
        }
        let referenceUsesFixture = root.appendingPathComponent(
            "a_reference_use.rs"
        )
        guard let referenceBytes = try? [UInt8](Data(contentsOf: referenceFixture)),
              let referenceProjectBytes = try? [UInt8](
                  Data(contentsOf: referenceProjectFixture)
              ),
              let referenceUsesBytes = try? [UInt8](
                  Data(contentsOf: referenceUsesFixture)
              )
        else {
            finish(
                checks: checks,
                metrics: [:],
                error: "M6 reference scale bytes unavailable"
            )
        }
        guard case let .ready(referenceSession, referenceContext) =
                model.projectState
        else {
            finish(
                checks: checks,
                metrics: [:],
                error: "M6 reference scale session unavailable"
            )
        }
        let regularPathID = referenceSession.manifest.files.first {
            URL(
                fileURLWithPath: referenceSession.paths.resolve($0.pathID)
            ).lastPathComponent == regular.lastPathComponent
        }?.pathID
        guard let referenceSymbol = (try? referenceSession.definitions(
            of: "p0",
            context: referenceContext
        ))?.first(where: { $0.0.pathID == regularPathID })?.0
        else {
            finish(
                checks: checks,
                metrics: [:],
                error: "regular p0 definition unavailable; files="
                    + referenceSession.manifest.files.map {
                        referenceSession.paths.resolve($0.pathID)
                    }.joined(separator: ",")
            )
        }
        guard let referenceFile = referenceSession.manifest.files.first(where: {
                  $0.pathID == referenceSymbol.pathID
              }),
              let referenceIndex = referenceSession.contentIndexes.first(where: {
                  $0.key.contentID == referenceFile.contentID
              })?.value,
              referenceIndex.symbols.indices.contains(
                  Int(referenceSymbol.localIndex)
              )
        else {
            finish(
                checks: checks,
                metrics: [:],
                error: "regular p0 content index unavailable"
            )
        }
        let referenceCandidateNeedle = Data("p0".utf8)
        var referenceCandidateCount = 0
        for candidateBytes in [referenceProjectBytes, referenceUsesBytes] {
            let bytes = Data(candidateBytes)
            var offset = 0
            while offset < bytes.count,
                  let range = bytes.range(
                      of: referenceCandidateNeedle,
                      in: offset..<bytes.count
                  )
            {
                referenceCandidateCount += 1
                offset = range.upperBound
            }
        }
        let referenceDeclarationRange =
            referenceIndex.symbols[Int(referenceSymbol.localIndex)].nameRange
        let referenceScaleBaselineFootprintMB = physicalFootprintBytes().map {
            Double($0) / 1_048_576
        } ?? -1
        var referenceProbe: (
            verifiedCount: Int,
            firstBatchMS: Double,
            totalMS: Double,
            isTruncated: Bool,
            error: String?
        )?
        let referenceProbeStartedAt = ContinuousClock.now
        Task { @MainActor in
            do {
                let stream = try referenceSession.searchReferences(
                    ContentSearchQuery(
                        pattern: "p0",
                        caseSensitive: true
                    ),
                    excludingPathID: referenceSymbol.pathID,
                    excludingRange: referenceDeclarationRange,
                    context: referenceContext
                )
                var verifiedCount = 0
                var firstBatchMS: Double?
                var isTruncated = false
                for try await batch in stream {
                    let count = batch.matchesByPath.values.reduce(0) {
                        $0 + $1.count
                    }
                    if firstBatchMS == nil, count > 0 {
                        firstBatchMS = milliseconds(
                            since: referenceProbeStartedAt
                        )
                    }
                    verifiedCount += count
                    isTruncated =
                        isTruncated || batch.completeness == .truncated
                }
                referenceProbe = (
                    verifiedCount,
                    firstBatchMS ?? -1,
                    milliseconds(since: referenceProbeStartedAt),
                    isTruncated,
                    nil
                )
            } catch {
                referenceProbe = (
                    0,
                    -1,
                    milliseconds(since: referenceProbeStartedAt),
                    false,
                    error.localizedDescription
                )
            }
        }
        guard waitUntil(timeout: 10, condition: { referenceProbe != nil }),
              let referenceProbe,
              referenceProbe.error == nil
        else {
            finish(
                checks: checks,
                metrics: [:],
                error: referenceProbe?.error ?? "reference scale probe timed out"
            )
        }
        let referenceResultStartedAt = ContinuousClock.now
        controller.selfTestReaderRelation(
            offset: referenceDeclarationRange.lowerBound,
            direction: .references
        )
        let referenceDisclosureReady = waitUntil(timeout: 10, condition: {
            controller.selfTestPossibleRelationDisclosureTitle
                == "Show \(referenceProbe.verifiedCount) possible matches"
        })
        let referencePossibleDefaultCollapsed =
            referenceDisclosureReady
            && controller.selfTestVisibleRelationEdgeTitles(
                inGroup: "References"
            ).isEmpty
        let referenceResultVisible =
            referencePossibleDefaultCollapsed
            && controller.selfTestExpandPossibleRelations()
            && waitUntil(timeout: 10, condition: {
                controller.selfTestVisibleRelationEdgeTitles(
                    inGroup: "References"
                ).count == referenceProbe.verifiedCount
            })
        let referenceResultTotalMS = milliseconds(
            since: referenceResultStartedAt
        )
        let referenceVisibleRowCount = controller
            .selfTestVisibleRelationEdgeTitles(inGroup: "References").count
        let referenceFooter = model.relationTree.root?.children?.first {
            $0.kind == .truncated
                && $0.title.hasSuffix("verified references · partial")
        }?.title
        let referenceResultVisibleWithGeometry =
            controller.selfTestReferenceGroupVisibleWithGeometry
        let referenceScaleAfterFootprintMB = physicalFootprintBytes().map {
            Double($0) / 1_048_576
        } ?? -1
        let referenceScaleDeltaFootprintMB =
            referenceScaleAfterFootprintMB
                - referenceScaleBaselineFootprintMB
        let referenceOriginOffset = controller.selfTestReadingByteOffset
        let historyCountBeforeReferenceOpen =
            model.navigationHistory.records.count
        let referenceFirstTitle = controller.selfTestVisibleRelationEdgeTitles(
            inGroup: "References"
        ).first
        let referenceSelected = referenceFirstTitle.map {
            controller.selfTestSelectRelationEdge(titled: $0)
        } == true
        let referenceOpenedCrossFile = referenceSelected
            && waitUntil(timeout: 5, condition: {
                controller.displayedReaderFile?.standardizedFileURL
                    == referenceUsesFixture.standardizedFileURL
            })
        let referenceHistoryRecorded =
            model.navigationHistory.records.count
                > historyCountBeforeReferenceOpen
        if referenceOpenedCrossFile {
            controller.goBack(nil)
        }
        let referenceHistoryBack = referenceOriginOffset.map { origin in
            waitUntil(timeout: 5, condition: {
                controller.displayedReaderFile?.standardizedFileURL
                    == regular.standardizedFileURL
                    && model.selectedByteOffset == origin
            })
        } ?? false
        checks.merge([
            "largeReferenceCandidateCountMeasured":
                referenceCandidateCount == 18_001,
            "largeReferenceVerifiedCountMeasured":
                referenceProbe.verifiedCount == 201,
            "largeReferenceFirstBatchMeasured":
                referenceProbe.firstBatchMS >= 0
                    && referenceProbe.firstBatchMS <= referenceProbe.totalMS,
            "largeReferenceTotalMeasured":
                referenceProbe.totalMS >= 0,
            "largeReferenceRowsVisible":
                referenceResultVisible
                    && referenceVisibleRowCount == referenceProbe.verifiedCount,
            "largeReferencePossibleDefaultCollapsed":
                referencePossibleDefaultCollapsed,
            "largeReferenceServicePartialHonest":
                referenceProbe.isTruncated
                    && referenceFooter
                        == "\(referenceProbe.verifiedCount) "
                            + "verified references · partial"
                    && referenceFooter?.contains("18001") == false,
            "largeReferenceResultVisibleWithGeometry":
                referenceResultVisibleWithGeometry,
            "largeReferenceHistoryRecorded":
                referenceHistoryRecorded,
            "largeReferenceHistoryBack":
                referenceHistoryBack,
            "largeReferenceFootprintUnderBudget":
                referenceScaleBaselineFootprintMB >= 0
                    && referenceScaleAfterFootprintMB >= 0
                    && referenceScaleDeltaFootprintMB
                        < SelfTestBudgets.largeReferenceDeltaFootprintMB,
        ]) { _, new in new }
        Self.writeJSON([
            "step": "reference-scale",
            "candidateCount": referenceCandidateCount,
            "verifiedCount": referenceProbe.verifiedCount,
            "firstBatchMS": referenceProbe.firstBatchMS,
            "serviceTotalMS": referenceProbe.totalMS,
            "resultTotalMS": referenceResultTotalMS,
            "visibleRowCount": referenceVisibleRowCount,
            "possibleDefaultCollapsed": referencePossibleDefaultCollapsed,
            "serviceTruncated": referenceProbe.isTruncated,
            "footer": referenceFooter ?? "",
            "historyRecorded": referenceHistoryRecorded,
            "historyBack": referenceHistoryBack,
            "baselineFootprintMB": referenceScaleBaselineFootprintMB,
            "afterFootprintMB": referenceScaleAfterFootprintMB,
            "deltaFootprintMB": referenceScaleDeltaFootprintMB,
        ])

        controller.applyReaderSettings(readerSettings)
        let huge = root.appendingPathComponent("target/huge.rs")
        guard let hugeBytes = try? [UInt8](Data(contentsOf: huge)),
              let needleOffset = Data(hugeBytes).range(
                  of: Data("needle".utf8)
              )?.lowerBound
        else {
            finish(checks: checks, metrics: [:], error: "huge fixture unavailable")
        }
        let hugeOpenedAt = ContinuousClock.now
        controller.openFileForSelfTest(huge)
        guard waitUntil(timeout: 10, condition: {
            controller.selfTestLeftReaderBytes?.count == hugeBytes.count
        }) else {
            finish(checks: checks, metrics: [:], error: "huge reader did not open")
        }
        pumpRunLoop()
        let hugeFirstVisibleMS = milliseconds(since: hugeOpenedAt)
        let hugeBaselineFootprintMB = physicalFootprintBytes().map {
            Double($0) / 1_048_576
        } ?? -1
        let hugeOccurrenceCount = controller.selfTestActivateReading(
            at: UInt32(needleOffset)
        )
        let styledFragments = controller.selfTestStyledFragmentCount
        let hugeVisibleLines = controller.selfTestVisibleLineNumbers.count
        let hugeFootprintMB = physicalFootprintBytes().map {
            Double($0) / 1_048_576
        } ?? -1
        let hugeIncrementalFootprintMB =
            hugeFootprintMB - hugeBaselineFootprintMB
        let hugeLineCount = 100_000
        let expectedHugeOccurrences = 200
        checks.merge([
            "hugeOccurrenceCountMatches":
                hugeOccurrenceCount == expectedHugeOccurrences,
            "styledFragmentsTrackViewport":
                styledFragments > 0
                && styledFragments < SelfTestBudgets.hugeStyledFragments,
            "rulerLinesTrackViewport":
                hugeVisibleLines > 0
                && hugeVisibleLines < SelfTestBudgets.hugeStyledFragments,
            "styledFragmentsDoNotTrackFile":
                styledFragments * 100 < hugeLineCount,
        ]) { _, new in new }
        // phys_footprint is a process-wide net metric. TextKit rendering-cache
        // reclamation can dominate this interval, so it cannot gate S7 cost.
        // The >100 MB absolute baseline predates S7 and is an M7 candidate.
        var metrics = [
            "idleFootprintMB": readingIdleFootprintMB,
            "regularFootprintMB": regularFootprintMB,
            "referenceCandidateCount": Double(referenceCandidateCount),
            "referenceVerifiedCount": Double(referenceProbe.verifiedCount),
            "referenceFirstBatchMS": referenceProbe.firstBatchMS,
            "referenceServiceTotalMS": referenceProbe.totalMS,
            "referenceResultTotalMS": referenceResultTotalMS,
            "referenceVisibleRowCount": Double(referenceVisibleRowCount),
            "referenceScaleBaselineFootprintMB":
                referenceScaleBaselineFootprintMB,
            "referenceScaleAfterFootprintMB":
                referenceScaleAfterFootprintMB,
            "referenceScaleDeltaFootprintMB":
                referenceScaleDeltaFootprintMB,
            "hugeBaselineFootprintMB": hugeBaselineFootprintMB,
            "hugeAfterFootprintMB": hugeFootprintMB,
            "hugeDeltaFootprintMB": hugeIncrementalFootprintMB,
            "hugeLineCount": Double(hugeLineCount),
            "hugeOccurrenceCount": Double(hugeOccurrenceCount),
            "styledFragmentCount": Double(styledFragments),
            "visibleLineCount": Double(hugeVisibleLines),
            "firstVisibleMS": hugeFirstVisibleMS,
        ]
        Self.writeJSON([
            "step": "huge",
            "totalLines": hugeLineCount,
            "occurrences": hugeOccurrenceCount,
            "styledFragments": styledFragments,
            "visibleLines": hugeVisibleLines,
            "firstVisibleMS": hugeFirstVisibleMS,
            "baselineFootprintMB": hugeBaselineFootprintMB,
            "afterFootprintMB": hugeFootprintMB,
            "deltaFootprintMB": hugeIncrementalFootprintMB,
            // Keep the established keys for downstream readers.
            "incrementalFootprintMB": hugeIncrementalFootprintMB,
            "footprintMB": hugeFootprintMB,
            "memoryAssessment":
                "metric-only: TextKit cache reclamation makes the S7 delta "
                + "non-attributable; >100 MB absolute baseline predates S7 "
                + "and is an M7 candidate after attributable measurement",
        ])

        controller.openFileForSelfTest(referenceFixture)
        guard waitUntil(timeout: 30, condition: {
            controller.selfTestLeftReaderBytes?.count == referenceBytes.count
                && controller.selfTestReferenceAttributeRunCount > 0
        }) else {
            finish(
                checks: checks,
                metrics: metrics,
                error: "M6 reference styling did not render"
            )
        }
        pumpRunLoop()
        let referenceRuns = controller.selfTestReferenceAttributeRunCount
        let referenceFragments =
            controller.selfTestReferenceStyledFragmentCount
        let referenceScanned = controller.selfTestReferenceScannedCount

        var syntaxOffSettings = readerSettings
        syntaxOffSettings.syntaxFormatting = false
        controller.applyReaderSettings(syntaxOffSettings)
        pumpRunLoop()
        let referenceRunsWhenOff =
            controller.selfTestReferenceAttributeRunCount
        let referenceFragmentsWhenOff =
            controller.selfTestReferenceStyledFragmentCount
        checks.merge([
            "referenceRunsTrackViewport":
                referenceRuns > 0 && referenceRuns < 350,
            "referenceFragmentsTrackViewport":
                referenceFragments > 0 && referenceFragments < 350,
            "referenceRunsDoNotTrackFile":
                referenceRuns * 100 < 35_000,
            // 工作量门：输出计数会被 fragment 交集过滤，即使 viewport 门控失效
            // 也仍是 51。必须另测"实际扫描到多少候选"才能抓住门控回退。
            "referenceLookupIsViewportGated":
                referenceScanned > 0 && referenceScanned * 50 < 35_000,
            "syntaxFormattingOffSuppressesReferenceRuns":
                referenceRunsWhenOff == 0
                    && referenceFragmentsWhenOff == 0,
        ]) { _, new in new }
        metrics["referenceAttributeRunCount"] = Double(referenceRuns)
        metrics["referenceStyledFragmentCount"] = Double(referenceFragments)
        metrics["referenceScannedCount"] = Double(referenceScanned)
        Self.writeJSON([
            "step": "references",
            "totalReferences": 35_000,
            "referenceAttributeRuns": referenceRuns,
            "referenceStyledFragments": referenceFragments,
            "referenceScannedCount": referenceScanned,
            "referenceAttributeRunsWhenOff": referenceRunsWhenOff,
            "referenceStyledFragmentsWhenOff": referenceFragmentsWhenOff,
        ])
        controller.selfTestNavigate(to: regular, byteOffset: UInt32(alphaOffset))
        pumpRunLoop()
        let primarySelectionRange = controller.selfTestPrimarySelectionRange
        let explicitOutlineRow = controller.selfTestSelectedOutlineRow
        controller.selfTestEmitOutlineFollow(at: UInt32(betaOffset))
        pumpRunLoop()
        let programmaticFollowIsBlocked = explicitOutlineRow >= 0
            && controller.selfTestSelectedOutlineRow == explicitOutlineRow
        controller.selfTestPostLiveScroll()
        pumpRunLoop()
        controller.selfTestEmitOutlineFollow(at: UInt32(betaOffset))
        pumpRunLoop()
        checks.merge([
            "navigationSetsNativePrimarySelection":
                primarySelectionRange?.length == "alpha".utf16.count,
            "programmaticNavigationBlocksViewportFollow":
                programmaticFollowIsBlocked,
            "didLiveScrollResumesViewportFollow":
                controller.selfTestSelectedOutlineRow >= 0
                && controller.selfTestSelectedOutlineRow != explicitOutlineRow,
        ]) { _, new in new }
        finish(checks: checks, metrics: metrics)
    }

    func runDiffSelfTest(root: URL) -> Never {
        launch(offscreen: true)
        guard let controller = windowController else {
            finishDiffSelfTest(error: "window unavailable")
        }
        let contentSize = NSSize(width: 1_600, height: 1_000)
        controller.window?.setContentSize(contentSize)
        controller.window?.contentView?.setFrameSize(contentSize)
        controller.window?.appearance = NSAppearance(named: .darkAqua)
        pumpRunLoop()
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

        controller.selfTestShowCommitPicker(compare: false)
        pumpRunLoop()
        let versionPickerGeometry = controller.selfTestCommitPickerGeometry(
            compare: false
        )
        controller.selfTestCloseCommitPicker(compare: false)
        let versionPickerGeometryValid =
            versionPickerGeometry?.shown == true
            && (versionPickerGeometry?.contentHeight ?? 0) >= 202
            && (versionPickerGeometry?.viewportHeight ?? 0) >= 116
            && versionPickerGeometry?.visibleCommitRows == 2
            && versionPickerGeometry?.commitRowFrames.allSatisfy {
                $0.width > 0 && $0.height > 0
            } == true
        emitDiffStep("darkVersionPickerGeometry", controller: controller, extra: [
            "contentHeight": versionPickerGeometry?.contentHeight ?? 0,
            "viewportHeight": versionPickerGeometry?.viewportHeight ?? 0,
            "commitRowFrames": versionPickerGeometry?.commitRowFrames.map(
                NSStringFromRect
            ) ?? [],
            "visibleCommitRows": versionPickerGeometry?.visibleCommitRows ?? 0,
            "valid": versionPickerGeometryValid,
        ])

        var selectedRevision: String?
        var selectedTarget: DiffSelfTestTarget?
        for commit in model.commitPicker.commits.dropFirst() {
            guard let snapshot = try? CommitSnapshot(
                repositoryURL: root,
                revision: commit.fullSHA
            ), let target = diffSelfTestTarget(root: root, snapshot: snapshot) else {
                continue
            }
            selectedRevision = commit.fullSHA
            selectedTarget = target
            break
        }
        guard let revision = selectedRevision, let target = selectedTarget else {
            finishDiffSelfTest(error: "no earlier commit has a multi-line source diff")
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
        pumpRunLoop()
        controller.selfTestShowCommitPicker(compare: true)
        pumpRunLoop()
        let comparePickerGeometry = controller.selfTestCommitPickerGeometry(
            compare: true
        )
        controller.selfTestCloseCommitPicker(compare: true)
        let comparePickerGeometryValid =
            comparePickerGeometry?.shown == true
            && (comparePickerGeometry?.contentHeight ?? 0) >= 202
            && (comparePickerGeometry?.viewportHeight ?? 0) >= 116
            && comparePickerGeometry?.visibleCommitRows == 2
            && comparePickerGeometry?.commitRowFrames.allSatisfy {
                $0.width > 0 && $0.height > 0
            } == true
        emitDiffStep("darkComparePickerGeometry", controller: controller, extra: [
            "contentHeight": comparePickerGeometry?.contentHeight ?? 0,
            "viewportHeight": comparePickerGeometry?.viewportHeight ?? 0,
            "commitRowFrames": comparePickerGeometry?.commitRowFrames.map(
                NSStringFromRect
            ) ?? [],
            "visibleCommitRows": comparePickerGeometry?.visibleCommitRows ?? 0,
            "valid": comparePickerGeometryValid,
        ])
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
        let gutterCoexistsWithLineNumbers =
            controller.selfTestGutterCoexistsWithLineNumbers
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
            "gutterCoexistsWithLineNumbers": gutterCoexistsWithLineNumbers,
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

        func comparisonCloseButton(in view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.accessibilityLabel() == "Close Comparison" {
                return button
            }
            return view.subviews.lazy.compactMap(comparisonCloseButton).first
        }
        let closeHeaderButton = controller.window?.contentView.flatMap(comparisonCloseButton)
        let closeHeaderAvailable = closeHeaderButton?.isEnabled == true
            && closeHeaderButton?.action != nil
            && closeHeaderButton?.target != nil
        controller.applyPanelPreset(.reading)
        pumpRunLoop()
        let readingPresetCollapsedRight = controller.selfTestSecondaryReaderCollapsed
        let readingPresetPreservedComparison = model.compare.rightRevision == revision
            && model.compare.diff != nil
        emitDiffStep("readingPreset", controller: controller, extra: [
            "rightReaderCollapsed": readingPresetCollapsedRight,
            "comparisonPreserved": readingPresetPreservedComparison,
        ])

        let leftReaderBytesBeforeClear = controller.selfTestLeftReaderBytes
        let closeItem = NSApp.mainMenu?.items.compactMap(\.submenu)
            .first { $0.title == "View" }?.item(withTitle: "Close Comparison")
        let closeActionDispatched: Bool
        if let closeItem, let action = closeItem.action, validateMenuItem(closeItem) {
            closeActionDispatched = NSApp.sendAction(action, to: closeItem.target, from: closeItem)
        } else {
            closeActionDispatched = false
        }
        pumpRunLoop()
        let closeClearedState = model.compare.rightRevision == nil
            && model.compare.rightSnapshotID == nil && model.compare.diff == nil
        let closeCollapsedRight = controller.selfTestSecondaryReaderCollapsed
        let closeClearedMarkers = controller.selfTestGutterCounts.isEmpty
        let closeDisabledAfterClosing = closeItem.map { !validateMenuItem($0) } ?? false
        emitDiffStep("closeComparison", controller: controller, extra: [
            "actionDispatched": closeActionDispatched,
            "stateCleared": closeClearedState,
            "markersCleared": closeClearedMarkers,
        ])
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
                "darkVersionPickerGeometryValid": versionPickerGeometryValid,
                "darkComparePickerGeometryValid": comparePickerGeometryValid,
                "rightReaderMatchesCommitBlob": rightReaderMatchesCommitBlob,
                "rightReaderDiffersFromWorktree": rightReaderDiffersFromWorktree,
                "gutterCountsMatch": gutterCountsMatch,
                "gutterCoexistsWithLineNumbers":
                    gutterCoexistsWithLineNumbers,
                "hunkNavMoved": hunkNavMoved,
                "readingPresetCollapsedRight": readingPresetCollapsedRight,
                "readingPresetPreservedComparison": readingPresetPreservedComparison,
                "closeComparisonHeaderAvailable": closeHeaderAvailable,
                "closeComparisonMenuActionDispatched": closeActionDispatched,
                "closeComparisonClearedState": closeClearedState,
                "closeComparisonCollapsedRight": closeCollapsedRight,
                "closeComparisonClearedMarkers": closeClearedMarkers,
                "closeComparisonDisabledAfterClosing": closeDisabledAfterClosing,
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
            URL(fileURLWithPath: $0).pathExtension == "rs"
        }.sorted()
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
        Self.exitSelfTest(channel: "diff", status: passed ? 0 : 1)
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
        guard waitUntil(timeout: 5, condition: {
                  self.pinContextSummary != nil
                      && !windowController.selfTestContextPlaceholderVisible
                      && windowController.selfTestContextReaderVisible
              }),
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
        let relationsPlaceholderHiddenWithRoot = waitUntil(timeout: 5, condition: {
            !windowController.selfTestRelationsPlaceholderVisible
                && windowController.selfTestRelationsTreeVisible
        })
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

    func runRelationTimingSelfTest(
        root: URL,
        file: URL,
        relativeFile: String,
        offset: UInt32,
        provider: String
    ) -> Never {
        launch(offscreen: true)
        guard let controller = windowController else {
            Self.writeJSON([
                "step": "summary",
                "passed": false,
                "error": "window unavailable",
            ])
            Self.exitSelfTest(channel: "relation-timing", status: 1)
        }

        func finish(_ result: [String: Any], status: Int32) -> Never {
            controller.close()
            model.exactCoordinator.shutdown()
            if let relationTimingTemporaryRoot {
                try? FileManager.default.removeItem(at: relationTimingTemporaryRoot)
            }
            Self.writeJSON(result)
            Self.exitSelfTest(channel: "relation-timing", status: status)
        }

        controller.window?.setContentSize(
            NSSize(width: 1_600, height: 1_000)
        )
        pumpRunLoop()
        controller.openProject(root: root)
        guard waitUntil(timeout: 120, condition: {
                  if case .failed = self.model.projectState { return true }
                  if case .ready = self.model.projectState {
                      return self.model.snapshotPhase == .fullReady
                  }
                  return false
              }),
              case .ready = model.projectState,
              model.snapshotPhase == .fullReady
        else {
            finish([
                "step": "summary",
                "passed": false,
                "error": "project index did not reach fullReady",
            ], status: 1)
        }

        if provider == "real" {
            Task { try? await model.grantCurrentRepositoryTrust() }
            guard waitUntil(timeout: 120, condition: {
                      self.model.exactCoordinator.readiness == .ready
                          && self.model.exactCoordinator.trustMode == .trusted
                  })
            else {
                finish([
                    "step": "summary",
                    "passed": false,
                    "error": "rust-analyzer did not become ready in Trusted mode",
                ], status: 1)
            }
        }

        guard waitUntil(timeout: 30, condition: {
                  controller.selectFileInSidebar(file)
              }),
              waitUntil(timeout: 30, condition: {
                  controller.displayedReaderFile?.standardizedFileURL
                      == file.standardizedFileURL
              })
        else {
            finish([
                "step": "summary",
                "passed": false,
                "error": "target file unavailable",
            ], status: 1)
        }

        let contextStartedAt = ContinuousClock.now
        controller.selfTestReaderClick(offset: offset, commandClick: false)
        let contextVisible = waitUntil(timeout: 120, condition: {
            controller.selfTestContextCandidateCount >= 1
        })
        let contextFirstActionableMS = contextVisible
            ? milliseconds(since: contextStartedAt)
            : 0
        let contextExactVisible = contextVisible && waitUntil(timeout: 120, condition: {
            controller.selfTestContextProvenance?.contains("Exact") == true
        })
        let contextExactMS = contextExactVisible
            ? milliseconds(since: contextStartedAt)
            : 0

        exactSelfTestProviderState?.delayNextRelation(by: 0.25)
        let cold = measureRelationTiming(
            model: model,
            controller: controller,
            offset: offset,
            direction: .callers,
            timeout: 120
        )
        let coldSelectable =
            !cold.relationFirstActionableTitle.isEmpty
            && controller.selfTestSelectRelationEdge(
                titled: cold.relationFirstActionableTitle
            )
            && controller.selfTestSelectedRelationEdgeTitle
                == cold.relationFirstActionableTitle
        controller.selfTestDeselectRelation()

        exactSelfTestProviderState?.delayNextRelation(by: 0.25)
        let warm = measureRelationTiming(
            model: model,
            controller: controller,
            offset: offset,
            direction: .callers,
            timeout: 120
        )
        let warmSelectable =
            !warm.relationFirstActionableTitle.isEmpty
            && controller.selfTestSelectRelationEdge(
                titled: warm.relationFirstActionableTitle
            )
            && controller.selfTestSelectedRelationEdgeTitle
                == warm.relationFirstActionableTitle
        let fieldsValid = [cold, warm].allSatisfy {
            $0.relationFirstActionableMS > 0
                && $0.relationAllResultsMS >= $0.relationFirstActionableMS
                && ["heuristic", "exact"].contains(
                    $0.relationFirstActionableKind
                )
                && $0.relationCandidateEdgeCount > 0
        }
        let passed = fieldsValid && coldSelectable && warmSelectable
        finish([
            "step": "summary",
            "variant": provider == "real" ? "rust-analyzer" : "fake",
            "measurementScope": provider == "real"
                ? "real rust-analyzer"
                : "instrumentation-only; not real rust-analyzer",
            "projectRoot": root.path,
            "file": relativeFile,
            "utf8ByteOffset": Int(offset),
            "indexHot": true,
            "cold": [
                "relationFirstActionableMS":
                    cold.relationFirstActionableMS,
                "relationAllResultsMS":
                    cold.relationAllResultsMS,
                "relationFirstActionableKind":
                    cold.relationFirstActionableKind,
                "relationFirstActionableTitle":
                    cold.relationFirstActionableTitle,
                "relationCandidateEdgeCount":
                    cold.relationCandidateEdgeCount,
            ],
            "warm": [
                "relationFirstActionableMS":
                    warm.relationFirstActionableMS,
                "relationAllResultsMS":
                    warm.relationAllResultsMS,
                "relationFirstActionableKind":
                    warm.relationFirstActionableKind,
                "relationFirstActionableTitle":
                    warm.relationFirstActionableTitle,
                "relationCandidateEdgeCount":
                    warm.relationCandidateEdgeCount,
            ],
            "coldFirstActionableSelectable": coldSelectable,
            "warmFirstActionableSelectable": warmSelectable,
            "contextFirstActionableMS": contextFirstActionableMS,
            "contextExactMS": contextExactMS,
            "contextExactVisible": contextExactVisible,
            "passed": passed,
        ], status: passed ? 0 : 1)
    }

    func runExactSelfTest(root: URL) -> Never {
        launch(offscreen: true)
        let projectRoot = exactSelfTestFixtureRoot(root: root)
        guard let windowController,
              let target = exactSelfTestTarget(root: projectRoot),
              let localReferenceDeclarationOffset =
                  target.localReferenceDeclarationOffset,
              let localReferenceUseOffset = target.localReferenceUseOffset
        else {
            finishExactSelfTest(
                controller: windowController,
                checks: [:],
                realProvider: "not-run",
                error: "exact self-test target unavailable"
            )
        }
        windowController.window?.setContentSize(
            NSSize(width: 1_600, height: 1_000)
        )
        pumpRunLoop()

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
            "Rust · \(projectRoot.lastPathComponent) · default · Safe"
        let initialProfileVisible = waitUntil(timeout: 5, condition: {
            windowController.selfTestProfileToolbarItemExistsAndVisible
                && windowController.selfTestProfileTitle == initialProfileTitle
        })
        let initialProfileTitleSafe =
            windowController.selfTestProfileTitle == initialProfileTitle
        emitExactStep(
            "initial-status",
            variant: "fake",
            controller: windowController,
            extra: [
                "profileVisible": initialProfileVisible,
                "profileTitle": windowController.selfTestProfileTitle,
            ]
        )
        let relationTimingFileVisible = waitUntil(timeout: 5, condition: {
            windowController.selectFileInSidebar(target.relationFile)
        }) && waitUntil(timeout: 5, condition: {
            windowController.displayedReaderFile?.standardizedFileURL
                == target.relationFile.standardizedFileURL
        })
        let relationSessionCountBefore =
            exactSelfTestProviderState?.trustModes.count ?? 0
        var relationColdTiming = (
            relationFirstActionableMS: 0.0,
            relationAllResultsMS: 0.0,
            relationFirstActionableKind: "",
            relationFirstActionableTitle: "",
            relationCandidateEdgeCount: 0
        )
        var relationWarmTiming = relationColdTiming
        if relationTimingFileVisible {
            exactSelfTestProviderState?.delayNextRelation(by: 0.25)
            relationColdTiming = measureRelationTiming(
                model: model,
                controller: windowController,
                offset: target.relationCallOffset,
                direction: .callers,
                timeout: 5
            )
            exactSelfTestProviderState?.delayNextRelation(by: 0.25)
            relationWarmTiming = measureRelationTiming(
                model: model,
                controller: windowController,
                offset: target.relationCallOffset,
                direction: .callers,
                timeout: 5
            )
        }
        let relationSessionCountAfter =
            exactSelfTestProviderState?.trustModes.count ?? 0
        let relationColdFirstActionableSelectable =
            !relationColdTiming.relationFirstActionableTitle.isEmpty
            && windowController.selfTestSelectRelationEdge(
                titled: relationColdTiming.relationFirstActionableTitle
            )
            && windowController.selfTestSelectedRelationEdgeTitle
                == relationColdTiming.relationFirstActionableTitle
        let relationWarmFirstActionableSelectable =
            !relationWarmTiming.relationFirstActionableTitle.isEmpty
            && windowController.selfTestSelectRelationEdge(
                titled: relationWarmTiming.relationFirstActionableTitle
            )
            && windowController.selfTestSelectedRelationEdgeTitle
                == relationWarmTiming.relationFirstActionableTitle
        windowController.selfTestDeselectRelation()
        let relationColdTimingFieldsValid =
            relationColdTiming.relationFirstActionableMS > 0
            && relationColdTiming.relationAllResultsMS
                >= relationColdTiming.relationFirstActionableMS
            && ["heuristic", "exact"].contains(
                relationColdTiming.relationFirstActionableKind
            )
        let relationWarmTimingFieldsValid =
            relationWarmTiming.relationFirstActionableMS > 0
            && relationWarmTiming.relationAllResultsMS
                >= relationWarmTiming.relationFirstActionableMS
            && ["heuristic", "exact"].contains(
                relationWarmTiming.relationFirstActionableKind
            )
        let relationTimingSameSession =
            relationSessionCountBefore > 0
            && relationSessionCountAfter == relationSessionCountBefore
        emitExactStep(
            "relation-timing",
            variant: "delayed-exact-fake",
            controller: windowController,
            extra: [
                "measurementScope": "instrumentation-only; not real rust-analyzer",
                "thresholdBasis":
                    "structural-only; real threshold pending host measurement",
                "cold": [
                    "relationFirstActionableMS":
                        relationColdTiming.relationFirstActionableMS,
                    "relationAllResultsMS":
                        relationColdTiming.relationAllResultsMS,
                    "relationFirstActionableKind":
                        relationColdTiming.relationFirstActionableKind,
                    "relationFirstActionableTitle":
                        relationColdTiming.relationFirstActionableTitle,
                    "relationCandidateEdgeCount":
                        relationColdTiming.relationCandidateEdgeCount,
                ],
                "warm": [
                    "relationFirstActionableMS":
                        relationWarmTiming.relationFirstActionableMS,
                    "relationAllResultsMS":
                        relationWarmTiming.relationAllResultsMS,
                    "relationFirstActionableKind":
                        relationWarmTiming.relationFirstActionableKind,
                    "relationFirstActionableTitle":
                        relationWarmTiming.relationFirstActionableTitle,
                    "relationCandidateEdgeCount":
                        relationWarmTiming.relationCandidateEdgeCount,
                ],
                "sameSession": relationTimingSameSession,
                "coldFirstActionableSelectable":
                    relationColdFirstActionableSelectable,
                "warmFirstActionableSelectable":
                    relationWarmFirstActionableSelectable,
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
        var exactSummary = windowController.selfTestContextSummary
        var exactCount = windowController.selfTestContextCandidateCount

        let featureProbeFileVisible = waitUntil(timeout: 5, condition: {
            windowController.selectFileInSidebar(target.relationFile)
        }) && waitUntil(timeout: 5, condition: {
            windowController.displayedReaderFile?.standardizedFileURL
                == target.relationFile.standardizedFileURL
        })
        if featureProbeFileVisible,
           let signatureTraitOffset = target.signatureTraitOffset
        {
            windowController.selfTestReaderRelation(
                offset: signatureTraitOffset,
                direction: .calls
            )
        }
        let featureRelationActiveBeforeSwitch = waitUntil(timeout: 5, condition: {
            model.relationTree.root?.title == "Backend"
                && model.relationTree.root?.children?.contains {
                    $0.kind == .loading
                } == false
        })
        exactSelfTestProviderState?.blockNextDefinition()
        exactSelfTestProviderState?.blockNextRelation()
        let oldGeneration = model.generation
        if featureProbeFileVisible,
           let signatureTraitOffset = target.signatureTraitOffset
        {
            windowController.selfTestReaderRelation(
                offset: signatureTraitOffset,
                direction: .calls
            )
        }
        if featureProbeFileVisible {
            windowController.selfTestReaderClick(
                offset: target.relationCallOffset,
                commandClick: false
            )
        }
        let oldGenerationRequestInFlight = waitUntil(timeout: 5, condition: {
            exactSelfTestProviderState?.definitionIsBlocked == true
                && exactSelfTestProviderState?.relationIsBlocked == true
                && windowController.selfTestContextCandidateCount >= 1
                && windowController.selfTestContextProvenance?
                    .contains("Exact") == false
        })
        let menuActionTriggered =
            windowController.selfTestSwitchFeatureSelection(.allFeatures)
        let reprofiledAt = ContinuousClock.now
        let featurePrepared = menuActionTriggered
            && waitUntil(timeout: 5, condition: {
                model.currentFeatureSelection == .allFeatures
                    && model.generation == oldGeneration + 1
                    && model.exactCoordinator.readiness == .ready
                    && exactSelfTestProviderState?.featureSelections.last
                        == .allFeatures
            })
        let contextVisibleDuringSwitch =
            windowController.selfTestContextCandidateCount >= 1
        exactSelfTestProviderState?.releaseBlockedDefinition()
        exactSelfTestProviderState?.releaseBlockedRelation()
        let oldGenerationResultReturned = waitUntil(timeout: 5, condition: {
            exactSelfTestProviderState?.blockedDefinitionReturned == true
        })
        let oldGenerationRelationResultReturned = waitUntil(
            timeout: 5,
            condition: {
                exactSelfTestProviderState?.blockedRelationReturned == true
            }
        )
        let featureRelationRestoredAfterSwitch = waitUntil(timeout: 5, condition: {
            model.relationTree.root?.title == "Backend"
                && model.relationTree.root?.children?.isEmpty == false
                && model.relationTree.root?.children?.contains {
                    $0.kind == .loading
                } == false
        })
        if featureProbeFileVisible {
            windowController.selfTestReaderClick(
                offset: target.relationCallOffset,
                commandClick: false
            )
        }
        let fuzzyAfterSwitch = waitUntil(timeout: 5, condition: {
            windowController.selfTestContextCandidateCount >= 1
                && windowController.selfTestContextProvenance?
                    .contains("Exact") == false
        })
        let switchedExactVisible = waitUntil(timeout: 5, condition: {
            windowController.selfTestContextProvenance?
                .contains("features: all") == true
        })
        let oldGenerationResultDiscarded = oldGenerationResultReturned
            && oldGenerationRelationResultReturned
            && model.generation == oldGeneration + 1
            && switchedExactVisible
        let contextReadyMS = milliseconds(since: reprofiledAt)
        let reprofileExtracted = if case let .ready(session, _) = model.projectState {
            session.stats.extractedCount
        } else {
            -1
        }
        if switchedExactVisible {
            exactSummary = windowController.selfTestContextSummary
            exactCount = windowController.selfTestContextCandidateCount
        }
        let switchedProfileTitle =
            "Rust · \(projectRoot.lastPathComponent) · all · Safe"
        let profileButtonVisibleWithGeometry = waitUntil(timeout: 5, condition: {
            windowController.selfTestProfileButtonVisibleWithGeometry
                && windowController.selfTestProfileTitle == switchedProfileTitle
        })
        emitExactStep(
            "feature-switch",
            variant: "fake",
            controller: windowController,
            extra: [
                "menuActionTriggered": menuActionTriggered,
                "featurePrepared": featurePrepared,
                "fakePrepareFeatures": exactSelfTestProviderState?
                    .featureSelections.map(\.rawValue) ?? [],
                "contextVisibleDuringSwitch": contextVisibleDuringSwitch,
                "fuzzyAfterSwitch": fuzzyAfterSwitch,
                "oldGenerationRequestInFlight": oldGenerationRequestInFlight,
                "oldGenerationResultReturned": oldGenerationResultReturned,
                "oldGenerationRelationResultReturned":
                    oldGenerationRelationResultReturned,
                "oldGenerationResultDiscarded": oldGenerationResultDiscarded,
                "relationActiveBeforeSwitch": featureRelationActiveBeforeSwitch,
                "relationRestoredAfterSwitch":
                    featureRelationRestoredAfterSwitch,
                "switchedExactVisible": switchedExactVisible,
                "contextReadyMS": contextReadyMS,
                "extracted": reprofileExtracted,
                "profileButtonVisibleWithGeometry":
                    profileButtonVisibleWithGeometry,
                "profileButtonFrame": NSStringFromRect(
                    windowController.selfTestProfileButtonFrame
                ),
                "profileContainerBounds": NSStringFromRect(
                    windowController.selfTestProfileContainerBounds
                ),
                "profileTitle": windowController.selfTestProfileTitle,
            ]
        )

        let relationFileVisible = waitUntil(timeout: 5, condition: {
            windowController.selectFileInSidebar(target.relationFile)
        }) && waitUntil(timeout: 5, condition: {
            windowController.displayedReaderFile?.standardizedFileURL
                == target.relationFile.standardizedFileURL
        })
        if relationFileVisible {
            _ = windowController.selfTestActivateReading(
                at: localReferenceDeclarationOffset
            )
            pumpRunLoop()
            windowController.selfTestReaderRelation(
                offset: localReferenceDeclarationOffset,
                direction: .references
            )
        }
        let localReferencesVisible = waitUntil(timeout: 5, condition: {
            model.relationTree.direction == .references
                && windowController.selfTestReferenceGroupTitle == nil
                && windowController.selfTestVisibleRelationEdgeTitles(
                    inGroup: "References"
                ).count == 1
        })
        let localReferenceCountHonest =
            windowController.selfTestVisibleRelationEdgeTitles(
                inGroup: "References"
            ).count == 1
        let localReferenceGroupVisibleWithGeometry =
            windowController.selfTestReferenceGroupVisibleWithGeometry
        let localReferenceGroupFrame =
            windowController.selfTestReferenceGroupFrame
        let localReferenceVisibleRect =
            windowController.selfTestRelationsVisibleRect
        let localReferenceIntersection =
            localReferenceVisibleRect.intersection(localReferenceGroupFrame)
        let referenceSegmentVisibleWithGeometry =
            windowController.selfTestReferenceSegmentVisibleWithGeometry
        let referenceSegmentDoesNotOverlapOtherDirections =
            windowController.selfTestReferenceSegmentDoesNotOverlapOtherDirections
        let localReferenceOriginOffset = windowController.selfTestReadingByteOffset
        let historyCountBeforeLocalReferenceOpen =
            model.navigationHistory.records.count
        let localReferenceTitle = windowController.selfTestVisibleRelationEdgeTitles(
            inGroup: "References"
        ).first
        let localReferenceSelected = localReferenceTitle.map {
            windowController.selfTestSelectRelationEdge(titled: $0)
        } == true
        let localReferenceOpenedAtCorrectOffset = waitUntil(timeout: 5, condition: {
            model.selectedByteOffset == localReferenceUseOffset
        })
        let localReferenceOpenedOffset = model.selectedByteOffset
        let localReferenceHistoryRecorded =
            model.navigationHistory.records.count
                > historyCountBeforeLocalReferenceOpen
        if localReferenceOpenedAtCorrectOffset {
            windowController.goBack(nil)
        }
        let localReferenceHistoryBack = localReferenceOriginOffset.map { origin in
            waitUntil(timeout: 5, condition: {
                model.selectedByteOffset == origin
                    && windowController.displayedReaderFile?.standardizedFileURL
                        == target.relationFile.standardizedFileURL
            })
        } ?? false
        if relationFileVisible {
            windowController.selfTestReaderClick(
                offset: target.relationCallOffset,
                commandClick: false
            )
        }
        let localReferenceContextRestored = waitUntil(timeout: 5, condition: {
            windowController.selfTestContextProvenance?.contains("Exact") == true
        })
        if localReferenceContextRestored {
            exactSummary = windowController.selfTestContextSummary
            exactCount = windowController.selfTestContextCandidateCount
        }
        emitExactStep(
            "local-references",
            variant: "reader-index",
            controller: windowController,
            extra: [
                "direction": "\(model.relationTree.direction)",
                "groupTitle": windowController.selfTestReferenceGroupTitle ?? "",
                "groupFrame": NSStringFromRect(
                    localReferenceGroupFrame
                ),
                "visibleRect": NSStringFromRect(
                    localReferenceVisibleRect
                ),
                "intersection": NSStringFromRect(localReferenceIntersection),
                "treeVisible": windowController.selfTestRelationsTreeVisible,
                "segmentFrames":
                    windowController.selfTestDirectionSegmentFrames.map(
                        NSStringFromRect
                    ),
                "groupVisibleWithGeometry":
                    localReferenceGroupVisibleWithGeometry,
                "referenceSegmentVisibleWithGeometry":
                    referenceSegmentVisibleWithGeometry,
                "referenceSegmentDoesNotOverlapOtherDirections":
                    referenceSegmentDoesNotOverlapOtherDirections,
                "selected": localReferenceSelected,
                "openedOffset": localReferenceOpenedOffset.map { $0 as Any }
                    ?? NSNull(),
                "returnedOffset": model.selectedByteOffset.map { $0 as Any }
                    ?? NSNull(),
                "expectedUseOffset": localReferenceUseOffset,
                "historyRecorded": localReferenceHistoryRecorded,
                "historyBack": localReferenceHistoryBack,
                "contextRestored": localReferenceContextRestored,
                "originOffset": localReferenceOriginOffset.map { $0 as Any }
                    ?? NSNull(),
            ]
        )
        if relationFileVisible,
           let definitionOffset = UInt32(exactly: target.definition.byteOffset)
        {
            windowController.selfTestReaderRelation(
                offset: definitionOffset,
                direction: .references
            )
        }
        func projectReferenceRows() -> [RelationTreeModel.Node] {
            model.relationTree.root?.children?
                .flatMap { node in
                    node.kind == .edge ? [node] : node.children ?? []
                }
                .filter { $0.kind == .edge } ?? []
        }
        let exactReferencesVisible = waitUntil(timeout: 5, condition: {
            model.relationTree.direction == .references
                && model.relationTree.root?.children?.contains {
                    $0.kind == .loading
                } == false
                && exactRelationEdges(in: model).contains {
                    $0.title.hasPrefix("main.rs:")
                }
        })
        _ = windowController.selfTestExpandPossibleRelations()
        let projectReferenceNodes = projectReferenceRows()
        let exactReferenceNodes = exactRelationEdges(in: model)
        let fuzzyReferenceNodes = projectReferenceNodes.filter {
            $0.badge != "Verified"
        }
        let exactReferenceTitles = exactReferenceNodes.map(\.title)
        let fuzzyReferenceTitles = fuzzyReferenceNodes.map(\.title)
        let exactReferenceRowCount = exactReferenceNodes.count
        let fuzzyReferenceRowCount = fuzzyReferenceNodes.count
        let possibleReferenceDisclosure = model.relationTree.root?.children?
            .first {
                $0.kind == .group && $0.candidateGroup == .possible
            }
        let possibleReferenceCountHonest = possibleReferenceDisclosure.map {
            let count = $0.children?.count ?? 0
            return $0.title == "Show \(count) possible \(count == 1 ? "match" : "matches")"
        } ?? true
        let noCertaintyNamedReferenceGroups =
            model.relationTree.root?.children?.allSatisfy {
                $0.kind != .group
                    || !["Exact", "Strong", "Probable", "Possible"]
                        .contains($0.title)
            } == true
        let mixedReferencePresentationHonest =
            exactReferenceRowCount > 0
            && fuzzyReferenceRowCount > 0
            && exactReferenceRowCount + fuzzyReferenceRowCount
                == projectReferenceNodes.count
            && exactReferenceNodes.allSatisfy { $0.badge == "Verified" }
            && fuzzyReferenceNodes.allSatisfy { $0.badge != "Verified" }
            && possibleReferenceCountHonest
            && noCertaintyNamedReferenceGroups
        let projectReferenceTitles = projectReferenceNodes.map(\.title)
        let projectReferencesVisible = exactReferencesVisible
            && !projectReferenceTitles.isEmpty
        let projectReferencesCrossFile = projectReferenceTitles.contains {
            $0.hasPrefix("main.rs:")
        }
        let exactReferencesHeuristicProvenanceRetained =
            exactReferenceNodes.contains {
                $0.subtitle?.contains("heuristic also matched") == true
            }
        let exactReferencesDeclarationExcluded =
            !projectReferenceNodes.contains {
                    $0.target?.path == target.definition.file
                        && $0.target?.byteOffset
                            == UInt32(target.definition.byteOffset)
                }
        let projectReferenceNode = projectReferenceNodes.first {
            $0.kind == .edge
                && $0.title.hasPrefix("main.rs:")
                && $0.symbol == nil
                && $0.target != nil
        }
        let exactReferenceAXNode = exactReferenceNodes.first {
            $0.subtitle?.contains("heuristic also matched") == true
        }
        let projectReferenceAccessibility = exactReferenceAXNode.flatMap {
            windowController.selfTestRelationAccessibility(
                titled: $0.title,
                inGroup: ""
            )
        }
        let projectReferenceAXProvenanceReachable =
            projectReferenceAccessibility.map {
                [$0.label, $0.value].joined(separator: " ")
                    .contains("Verified")
                    && [$0.label, $0.value].joined(separator: " ")
                        .contains("heuristic also matched")
            } == true
        let projectReferenceAXReadOnly =
            projectReferenceAccessibility.map {
                $0.role != NSAccessibility.Role.textField.rawValue
                    && !$0.valueSettable
            } == true
        let relationLayoutPassesBeforeGeometryRead =
            windowController.selfTestRelationLayoutPasses
        let projectReferenceEdgeFrames =
            windowController.selfTestVisibleRelationEdgeFrames(
                inGroup: ""
            )
        let projectReferenceVisibleRect =
            windowController.selfTestRelationsVisibleRect
        let projectReferenceRowsVisibleWithGeometry =
            !projectReferenceEdgeFrames.isEmpty
            && projectReferenceEdgeFrames.allSatisfy {
                guard $0.width > 0, $0.height > 0 else { return false }
                let intersection = projectReferenceVisibleRect.intersection($0)
                return intersection.width > 0
                    && intersection.height >= $0.height - 0.5
            }
        let projectReferenceGroupsDoNotOverlap =
            possibleReferenceDisclosure == nil
                || windowController.selfTestExactAndReferenceGroupsDoNotOverlap
        let projectReferenceResultsAndControlsDoNotOverlap =
            windowController
                .selfTestRelationResultsAndDirectionControlDoNotOverlap
        let relationGeometryReadDidNotForceLayout =
            relationLayoutPassesBeforeGeometryRead
                == windowController.selfTestRelationLayoutPasses
        emitExactStep(
            "project-references",
            variant: "exact+fuzzy",
            controller: windowController,
            extra: [
                "direction": "\(model.relationTree.direction)",
                "groupTitle": windowController.selfTestReferenceGroupTitle ?? "",
                "edgeCount": projectReferenceTitles.count,
                "edgeTitles": projectReferenceTitles,
                "exactEdgeTitles": exactReferenceTitles,
                "fuzzyEdgeTitles": fuzzyReferenceTitles,
                "exactRowCount": exactReferenceRowCount,
                "fuzzyRowCount": fuzzyReferenceRowCount,
                "possibleDisclosure":
                    possibleReferenceDisclosure?.title ?? "",
                "mixedPresentationHonest":
                    mixedReferencePresentationHonest,
                "exactVisible": exactReferencesVisible,
                "heuristicProvenanceRetained":
                    exactReferencesHeuristicProvenanceRetained,
                "declarationExcluded": exactReferencesDeclarationExcluded,
                "crossFile": projectReferencesCrossFile,
                "axLabel": projectReferenceAccessibility?.label ?? "",
                "axValue": projectReferenceAccessibility?.value ?? "",
                "axRole": projectReferenceAccessibility?.role ?? "",
                "axValueSettable":
                    projectReferenceAccessibility?.valueSettable ?? true,
                "axProvenanceReachable":
                    projectReferenceAXProvenanceReachable,
                "axReadOnly": projectReferenceAXReadOnly,
                "rowsVisibleWithGeometry":
                    projectReferenceRowsVisibleWithGeometry,
                "edgeFrames": projectReferenceEdgeFrames.map(
                    NSStringFromRect
                ),
                "visibleRect": NSStringFromRect(
                    projectReferenceVisibleRect
                ),
                "groupsDoNotOverlap":
                    projectReferenceGroupsDoNotOverlap,
                "resultsAndControlsDoNotOverlap":
                    projectReferenceResultsAndControlsDoNotOverlap,
                "geometryReadDidNotForceLayout":
                    relationGeometryReadDidNotForceLayout,
            ]
        )
        let referenceNavigationRoot = model.relationTree.root
        let referenceNavigationTreeGeneration = model.relationTree.generation
        let referenceNavigationGeneration = model.navigationGeneration
        let originalRelationOnSelect = model.relationTree.onSelect
        var referenceSelectionCount = 0
        model.relationTree.onSelect = { node in
            referenceSelectionCount += 1
            originalRelationOnSelect(node)
        }
        let referenceSingleClickSelected = projectReferenceNode.map {
            windowController.selfTestSelectRelationEdge(titled: $0.title)
        } == true
        let referenceSingleClickNavigated = projectReferenceNode?.target.map { target in
            waitUntil(timeout: 5, condition: {
                windowController.displayedReaderFile?.standardizedFileURL
                    == projectRoot.appendingPathComponent(target.path)
                        .standardizedFileURL
                    && model.selectedByteOffset == target.byteOffset
            })
        } ?? false
        pumpRunLoop()
        let referenceSingleClickExactlyOnce =
            model.navigationGeneration == referenceNavigationGeneration + 1
        let referenceSingleClickNoFeedback = referenceSelectionCount == 1
        let referenceSingleClickNoReroot =
            model.relationTree.root === referenceNavigationRoot
            && model.relationTree.generation == referenceNavigationTreeGeneration
            && projectReferenceNode?.symbol == nil
        let navigationAfterReferenceSingleClick = model.navigationGeneration
        if referenceSingleClickSelected {
            windowController.selfTestOpenRelationSelection()
        }
        pumpRunLoop()
        let referenceDoubleClickDidNotNavigateTwice =
            model.navigationGeneration == navigationAfterReferenceSingleClick
        model.relationTree.onSelect = originalRelationOnSelect
        if referenceSingleClickNavigated {
            windowController.goBack(nil)
        }
        let referenceSingleClickHistoryBack = referenceSingleClickNavigated
            && waitUntil(timeout: 5, condition: {
                windowController.displayedReaderFile?.standardizedFileURL
                    == target.relationFile.standardizedFileURL
            })
        var referenceKeyboardDownMovedSelection = false
        var referenceKeyboardUpMovedSelection = false
        var referenceKeyboardSelectionNavigated = false
        var referenceKeyboardAXNotificationCorrect = false
        var referenceKeyboardEnterOpened = false
        var referenceKeyboardKeypadEnterOpened = false
        var referenceKeyboardRestoredRelationFile = false
        if projectReferenceTitles.count >= 2 {
            let firstTitle = projectReferenceTitles[0]
            let secondTitle = projectReferenceTitles[1]
            let selectedFirst =
                windowController.selfTestSelectRelationEdge(titled: firstTitle)
            let navigationBeforeDown = model.navigationGeneration
            let notificationsBeforeDown =
                windowController.selfTestRelationAccessibilityNotificationCount
            referenceKeyboardDownMovedSelection =
                selectedFirst
                && windowController.selfTestPressRelationKey(125)
                && windowController.selfTestSelectedRelationEdgeTitle
                    == secondTitle
            referenceKeyboardSelectionNavigated =
                referenceKeyboardDownMovedSelection
                && waitUntil(timeout: 5, condition: {
                    model.navigationGeneration > navigationBeforeDown
                })
            referenceKeyboardAXNotificationCorrect =
                windowController.selfTestLastRelationAccessibilityNotification
                    == NSAccessibility.Notification.selectedRowsChanged.rawValue
                && windowController
                    .selfTestRelationAccessibilityNotificationCount
                    == notificationsBeforeDown + 1
            referenceKeyboardUpMovedSelection =
                windowController.selfTestPressRelationKey(126)
                && windowController.selfTestSelectedRelationEdgeTitle
                    == firstTitle
            let openCountBeforeEnter =
                windowController.selfTestRelationOpenCount
            referenceKeyboardEnterOpened =
                windowController.selfTestPressRelationKey(36)
                && windowController.selfTestRelationOpenCount
                    == openCountBeforeEnter + 1
            let openCountBeforeKeypadEnter =
                windowController.selfTestRelationOpenCount
            referenceKeyboardKeypadEnterOpened =
                windowController.selfTestPressRelationKey(76)
                && windowController.selfTestRelationOpenCount
                    == openCountBeforeKeypadEnter + 1
            referenceKeyboardRestoredRelationFile =
                windowController.selectFileInSidebar(target.relationFile)
                && waitUntil(timeout: 5, condition: {
                    windowController.displayedReaderFile?.standardizedFileURL
                        == target.relationFile.standardizedFileURL
                })
        }
        emitExactStep(
            "reference-single-click-navigation",
            variant: "fuzzy-two-stage",
            controller: windowController,
            extra: [
                "selected": referenceSingleClickSelected,
                "navigated": referenceSingleClickNavigated,
                "navigationExactlyOnce": referenceSingleClickExactlyOnce,
                "selectionCount": referenceSelectionCount,
                "noFeedback": referenceSingleClickNoFeedback,
                "noReroot": referenceSingleClickNoReroot,
                "doubleClickDidNotNavigateTwice":
                    referenceDoubleClickDidNotNavigateTwice,
                "historyBack": referenceSingleClickHistoryBack,
                "keyboardDownMovedSelection":
                    referenceKeyboardDownMovedSelection,
                "keyboardUpMovedSelection":
                    referenceKeyboardUpMovedSelection,
                "keyboardSelectionNavigated":
                    referenceKeyboardSelectionNavigated,
                "keyboardAXNotificationCorrect":
                    referenceKeyboardAXNotificationCorrect,
                "keyboardEnterOpened": referenceKeyboardEnterOpened,
                "keyboardKeypadEnterOpened":
                    referenceKeyboardKeypadEnterOpened,
                "keyboardRestoredRelationFile":
                    referenceKeyboardRestoredRelationFile,
            ]
        )
        if relationFileVisible {
            windowController.selfTestReaderRelation(
                offset: target.relationCallOffset,
                direction: .callers
            )
        }
        let verifiedRowsVisible = waitUntil(timeout: 5, condition: {
            model.relationTree.direction == .callers
                && model.relationTree.root?.title == "answer"
                && exactRelationEdges(in: model).contains {
                    $0.title == "exact_dependency_caller"
                }
        })
        let contextAndRelationsReadyMS = milliseconds(since: reprofiledAt)
        let verifiedRowCount = windowController.selfTestExactGroupRowCount
        let verifiedBadgesHonest =
            verifiedRowCount > 0
            && exactRelationEdges(in: model).allSatisfy {
                $0.badge == "Verified"
            }
        let exactStatusVisible = windowController.selfTestExactStatusText
            .contains("Exact:")
            && windowController.selfTestExactStatusVisible
        let exactCaller = exactRelationEdges(in: model).first {
            $0.title == "exact_dependency_caller"
        }
        let exactCallerVisible = exactCaller != nil
        let exactCallerCallSitesHonest =
            exactCaller?.subtitle?.contains("2 call sites") == true
        let exactCallerIsOneLevel = exactCallerVisible
            && exactCaller?.isExpandable == false
            && exactCaller?.children?.isEmpty == true
            && !windowController.selfTestExpandRelationEdge(
                titled: "exact_dependency_caller"
            )
        let verifiedBadgeVisibleWithGeometry =
            windowController.selfTestExactGroupVisibleWithGeometry
        let verifiedAndInferredRowsDoNotOverlap =
            windowController.selfTestExactAndHeuristicGroupsDoNotOverlap
        // metric-only：physicalFootprint 是进程级净指标，而本通道在同一进程里可能
        // 已经跑过真实 rust-analyzer 变体（RA 子进程 + 真实索引会把 footprint 抬到
        // ~150MB）。用 100MB 空载预算去守这个场景不可归因——沿用 M5 对巨档
        // footprint 的同一裁决：只报数，不设布尔门。
        // 空载内存预算由 --self-test / --self-test-reading 的独立进程守。
        let exactRelationsFootprintMB = physicalFootprintBytes().map {
            Double($0) / 1_048_576
        }
        emitExactStep(
            "relations",
            variant: "fake",
            controller: windowController,
            extra: [
                "contextAndRelationsReadyMS": contextAndRelationsReadyMS,
                "extracted": reprofileExtracted,
                "exactCallerVisible": exactCallerVisible,
                "exactCallerCallSitesHonest": exactCallerCallSitesHonest,
                "exactCallerIsOneLevel": exactCallerIsOneLevel,
                "verifiedRowFrame": NSStringFromRect(
                    windowController.selfTestExactGroupFrame
                ),
                "inferredRowFrame": NSStringFromRect(
                    windowController.selfTestHeuristicGroupFrame
                ),
                "relationsVisibleRect": NSStringFromRect(
                    windowController.selfTestRelationsVisibleRect
                ),
                "footprintMB": exactRelationsFootprintMB.map { $0 as Any }
                    ?? NSNull(),
            ]
        )

        if relationFileVisible, let signatureTraitOffset = target.signatureTraitOffset {
            // S2a's async offset commits can leave the reader on the last
            // edge target; this step resolves from the relation file.
            _ = windowController.selectFileInSidebar(target.relationFile)
            _ = waitUntil(timeout: 5, condition: {
                windowController.displayedReaderFile?.standardizedFileURL
                    == target.relationFile.standardizedFileURL
            })
            windowController.selfTestReaderRelation(
                offset: signatureTraitOffset,
                direction: .implementations
            )
        }
        let exactImplementationsVisible = waitUntil(timeout: 5, condition: {
            model.relationTree.direction == .implementations
                && windowController.selfTestExactGroupRowCount > 0
        })
        emitExactStep(
            "relation-exact-implementations",
            variant: "fake",
            controller: windowController
        )
        windowController.selfTestReaderRelation(
            offset: target.relationCallOffset,
            direction: .callers
        )
        let exactCallersRestored = waitUntil(timeout: 5, condition: {
            model.relationTree.root?.title == "answer"
                && model.relationTree.direction == .callers
                && windowController.selfTestExactGroupRowCount > 0
                && windowController.selfTestVisibleRelationEdgeTitles(inGroup: "")
                    .contains("relation_root")
        })

        let selectedFirstFollowCaller =
            windowController.selfTestSelectRelationEdge(titled: "relation_root")
        let firstFollowSummary = selectedFirstFollowCaller
            && waitUntil(timeout: 5, condition: {
                windowController.selfTestContextSummary != exactSummary
            })
            ? windowController.selfTestContextSummary
            : nil
        _ = windowController.selfTestExpandPossibleRelations()
        let secondFollowCallerReady = waitUntil(timeout: 5, condition: {
            windowController.selfTestVisibleRelationEdgeTitles(inGroup: "")
                .contains("main")
        })
        let selectedSecondFollowCaller =
            secondFollowCallerReady
            && windowController.selfTestSelectRelationEdge(titled: "main")
        let relationRowsUpdateFollowContext = firstFollowSummary != nil
            && selectedSecondFollowCaller
            && waitUntil(timeout: 5, condition: {
                let summary = windowController.selfTestContextSummary
                return summary != nil && summary != firstFollowSummary
            })
        let secondFollowSummary = relationRowsUpdateFollowContext
            ? windowController.selfTestContextSummary
            : nil
        // S2a made offset navigations commit after their content-identity
        // validation task, so the reader can legitimately sit on the last
        // opened edge target here. This step's intent is clicking the call
        // in the relation file — re-establish it first.
        _ = windowController.selectFileInSidebar(target.relationFile)
        _ = waitUntil(timeout: 5, condition: {
            windowController.displayedReaderFile?.standardizedFileURL
                == target.relationFile.standardizedFileURL
        })
        windowController.selfTestReaderClick(
            offset: target.relationCallOffset,
            commandClick: false
        )
        let relationFollowContextRestored = waitUntil(timeout: 5, condition: {
            windowController.selfTestContextSummary == exactSummary
        })
        emitExactStep(
            "relation-follow-context",
            variant: "fake",
            controller: windowController,
            extra: [
                "selectedFirst": selectedFirstFollowCaller,
                "firstSummary": firstFollowSummary ?? "",
                "selectedSecond": selectedSecondFollowCaller,
                "secondSummary": secondFollowSummary ?? "",
                "updatedTwice": relationRowsUpdateFollowContext,
                "restored": relationFollowContextRestored,
            ]
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
        _ = windowController.selfTestExpandPossibleRelations()
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
                && windowController.selfTestExternalGroupTitle == nil
        })
        let externalGroupHeaderHonest =
            windowController.selfTestExternalGroupTitle == nil
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
        var checksAfterFirstBatch: [String: Bool]
        if externalDemotionFileVisible,
           let externalRootOffset = target.externalRootOffset
        {
            exactSelfTestProviderState?.blockNextRelation()
            let definitionRequestsBefore =
                exactSelfTestProviderState?.definitionRequestCount ?? -1
            let nodeReloadsBefore =
                windowController.selfTestRelationNodeReloads
            windowController.selfTestReaderRelation(
                offset: externalRootOffset,
                direction: .calls
            )
            let heuristicPublishedWhileExactBlocked = waitUntil(
                timeout: 5,
                condition: {
                    exactSelfTestProviderState?.relationIsBlocked == true
                        && model.relationTree.root?.title == "dependency_call"
                        && windowController
                            .selfTestPossibleRelationDisclosureTitle
                            == "Show 1 possible match"
                }
            )
            let firstBatchUsedNodeReload =
                windowController.selfTestRelationNodeReloads > nodeReloadsBefore
            exactSelfTestProviderState?.releaseBlockedRelation()
            let bothRelationQueriesFinished = waitUntil(
                timeout: 5,
                condition: {
                    model.relationTree.root?.children?.contains {
                        $0.kind == .loading
                    } == false
                }
            )
            let defaultDefinitionPromotionRequests =
                (exactSelfTestProviderState?.definitionRequestCount ?? -1)
                    - definitionRequestsBefore
            let defaultDefinitionPromotionSkipped =
                defaultDefinitionPromotionRequests == 0
            let possibleRowRetained =
                windowController.selfTestPossibleRelationDisclosureTitle
                    == "Show 1 possible match"
            let possibleExpanded =
                windowController.selfTestExpandPossibleRelations()
            let onDemandDefinitionValidation = waitUntil(
                timeout: 5,
                condition: {
                    (exactSelfTestProviderState?.definitionRequestCount ?? -1)
                        - definitionRequestsBefore == 1
                }
            )
            let expandedDefinitionValidationRequests =
                (exactSelfTestProviderState?.definitionRequestCount ?? -1)
                    - definitionRequestsBefore
            emitExactStep(
                "relation-first-batch",
                variant: "blocked-root-exact-fake",
                controller: windowController,
                extra: [
                    "heuristicPublishedWhileExactBlocked":
                        heuristicPublishedWhileExactBlocked,
                    "firstBatchUsedNodeReload": firstBatchUsedNodeReload,
                    "bothQueriesFinished": bothRelationQueriesFinished,
                    "defaultDefinitionPromotionRequests":
                        defaultDefinitionPromotionRequests,
                    "possibleRowRetained": possibleRowRetained,
                    "possibleExpanded": possibleExpanded,
                    "expandedDefinitionValidationRequests":
                        expandedDefinitionValidationRequests,
                ]
            )
            checksAfterFirstBatch = [
                "heuristicPublishedWhileExactBlocked":
                    heuristicPublishedWhileExactBlocked,
                "firstBatchUsedNodeReload": firstBatchUsedNodeReload,
                "bothRelationQueriesFinished": bothRelationQueriesFinished,
                "defaultDefinitionPromotionSkipped":
                    defaultDefinitionPromotionSkipped,
                "possibleRowRetainedWithoutPromotion": possibleRowRetained,
                "possibleExpandedForValidation": possibleExpanded,
                "expandedDefinitionValidationOnDemand":
                    onDemandDefinitionValidation,
            ]
        } else {
            checksAfterFirstBatch = [
                "heuristicPublishedWhileExactBlocked": false,
                "firstBatchUsedNodeReload": false,
                "bothRelationQueriesFinished": false,
                "defaultDefinitionPromotionSkipped": false,
                "possibleRowRetainedWithoutPromotion": false,
                "possibleExpandedForValidation": false,
                "expandedDefinitionValidationOnDemand": false,
            ]
        }
        let relationFileRestoredAfterDependency =
            windowController.selectFileInSidebar(target.relationFile)
            && waitUntil(
                timeout: 5,
                condition: {
                    windowController.displayedReaderFile?.standardizedFileURL
                        == target.relationFile.standardizedFileURL
                }
            )

        func receiverRelationCheck(
            offset: UInt32?,
            rootTitle: String,
            edgeTitle: String,
            expectedGroup: String,
            expectedSubtitle: String,
            absentGroups: [String]
        ) -> (present: Bool, absent: Bool, subtitleHonest: Bool, subtitle: String) {
            guard relationFileVisible, let offset else {
                return (false, false, false, "")
            }
            windowController.selfTestReaderRelation(
                offset: offset,
                direction: .calls
            )
            if expectedGroup == "Possible" {
                _ = waitUntil(timeout: 5, condition: {
                    windowController.selfTestPossibleRelationDisclosureTitle != nil
                })
                _ = windowController.selfTestExpandPossibleRelations()
            }
            let present = waitUntil(timeout: 5, condition: {
                if expectedGroup == "Possible" {
                    _ = windowController.selfTestExpandPossibleRelations()
                }
                return model.relationTree.root?.title == rootTitle
                    && windowController.selfTestVisibleRelationEdgeTitles(
                        inGroup: expectedGroup
                    ).contains(edgeTitle)
            })
            let absent = absentGroups.allSatisfy {
                !windowController.selfTestVisibleRelationEdgeTitles(
                    inGroup: $0
                ).contains(edgeTitle)
            }
            let subtitle =
                windowController.selfTestVisibleRelationEdgeSubtitle(
                    titled: edgeTitle,
                    inGroup: expectedGroup
                ) ?? ""
            return (present, absent, subtitle == expectedSubtitle, subtitle)
        }

        let typedReceiver = receiverRelationCheck(
            offset: target.typedReceiverRootOffset,
            rootTitle: "typed_receiver_call",
            edgeTitle: "typed_edge",
            expectedGroup: "Strong",
            expectedSubtitle: "direct",
            absentGroups: ["Possible"]
        )
        let inferredReceiver = receiverRelationCheck(
            offset: target.inferredReceiverRootOffset,
            rootTitle: "inferred_receiver_call",
            edgeTitle: "inferred_edge",
            expectedGroup: "Possible",
            expectedSubtitle: "direct",
            absentGroups: ["Strong"]
        )
        let traitObjectReceiver = receiverRelationCheck(
            offset: target.traitObjectReceiverRootOffset,
            rootTitle: "trait_object_receiver_call",
            edgeTitle: "trait_object_edge",
            expectedGroup: "Possible",
            expectedSubtitle: "dynamic · name match only",
            absentGroups: ["Strong"]
        )
        emitExactStep(
            "relation-receiver-types",
            variant: "fake",
            controller: windowController,
            extra: [
                "typedStrong": typedReceiver.present,
                "typedPossible": !typedReceiver.absent,
                "typedSubtitle": typedReceiver.subtitle,
                "inferredProbable": inferredReceiver.present,
                "inferredPossible": !inferredReceiver.absent,
                "inferredSubtitle": inferredReceiver.subtitle,
                "traitObjectPossible": traitObjectReceiver.present,
                "traitObjectSubtitle": traitObjectReceiver.subtitle,
            ]
        )

        let fullZeroTitle = runExactZeroCoverageVariant(
            root: projectRoot,
            limitations: []
        )
        let partialZeroTitle = runExactZeroCoverageVariant(
            root: projectRoot,
            limitations: [.buildScriptsDisabled, .procMacrosDisabled]
        )
        let offlineZeroTitle = runExactZeroCoverageVariant(
            root: projectRoot,
            limitations: [.dependenciesUnavailableOffline]
        )
        let exactZeroFullCopyHonest =
            fullZeroTitle == "No verified references"
        let exactZeroPartialCopyHonest =
            partialZeroTitle
                == "Analysis limited: build scripts disabled; proc macros disabled"
        let exactZeroOfflineCopyHonest =
            offlineZeroTitle == "Analysis limited: dependencies unavailable offline"
        let exactZeroCoverageCopyDistinct =
            Set([fullZeroTitle, partialZeroTitle, offlineZeroTitle]).count == 3
        emitExactStep(
            "relation-zero-coverage",
            variant: "fake",
            controller: windowController,
            extra: [
                "full": fullZeroTitle ?? "",
                "partial": partialZeroTitle ?? "",
                "offline": offlineZeroTitle ?? "",
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
            "verifiedRowsVisible": verifiedRowsVisible,
            "verifiedBadgesHonest": verifiedBadgesHonest,
            "exactCallerVisible": exactCallerVisible,
            "exactCallerCallSitesHonest": exactCallerCallSitesHonest,
            "exactCallerIsOneLevel": exactCallerIsOneLevel,
            "exactImplementationsVisible": exactImplementationsVisible,
            "exactCallersRestored": exactCallersRestored,
            "verifiedBadgeVisibleWithGeometry":
                verifiedBadgeVisibleWithGeometry,
            "verifiedAndInferredRowsDoNotOverlap":
                verifiedAndInferredRowsDoNotOverlap,
            "localReferencesVisible": localReferencesVisible,
            "localReferenceCountHonest": localReferenceCountHonest,
            "localReferenceGroupVisibleWithGeometry":
                localReferenceGroupVisibleWithGeometry,
            "referenceSegmentVisibleWithGeometry":
                referenceSegmentVisibleWithGeometry,
            "referenceSegmentDoesNotOverlapOtherDirections":
                referenceSegmentDoesNotOverlapOtherDirections,
            "localReferenceSelected": localReferenceSelected,
            "localReferenceOpenedAtCorrectOffset":
                localReferenceOpenedAtCorrectOffset,
            "localReferenceHistoryRecorded": localReferenceHistoryRecorded,
            "localReferenceHistoryBack": localReferenceHistoryBack,
            "localReferenceContextRestored": localReferenceContextRestored,
            "projectReferencesVisible": projectReferencesVisible,
            "projectReferencesCrossFile": projectReferencesCrossFile,
            "exactReferencesVisible": exactReferencesVisible,
            "exactReferencesHeuristicProvenanceRetained":
                exactReferencesHeuristicProvenanceRetained,
            "projectReferenceAXProvenanceReachable":
                projectReferenceAXProvenanceReachable,
            "projectReferenceAXReadOnly": projectReferenceAXReadOnly,
            "projectReferenceRowsVisibleWithGeometry":
                projectReferenceRowsVisibleWithGeometry,
            "projectReferenceGroupsDoNotOverlap":
                projectReferenceGroupsDoNotOverlap,
            "projectReferenceResultsAndControlsDoNotOverlap":
                projectReferenceResultsAndControlsDoNotOverlap,
            "relationGeometryReadDidNotForceLayout":
                relationGeometryReadDidNotForceLayout,
            "exactReferencesDeclarationExcluded":
                exactReferencesDeclarationExcluded,
            "mixedReferencePresentationHonest":
                mixedReferencePresentationHonest,
            "exactZeroFullCopyHonest": exactZeroFullCopyHonest,
            "exactZeroPartialCopyHonest": exactZeroPartialCopyHonest,
            "exactZeroOfflineCopyHonest": exactZeroOfflineCopyHonest,
            "exactZeroCoverageCopyDistinct": exactZeroCoverageCopyDistinct,
            "referenceSingleClickSelected": referenceSingleClickSelected,
            "referenceSingleClickNavigated": referenceSingleClickNavigated,
            "referenceSingleClickExactlyOnce": referenceSingleClickExactlyOnce,
            "referenceSingleClickNoFeedback": referenceSingleClickNoFeedback,
            "referenceSingleClickNoReroot": referenceSingleClickNoReroot,
            "referenceDoubleClickDidNotNavigateTwice":
                referenceDoubleClickDidNotNavigateTwice,
            "referenceSingleClickHistoryBack": referenceSingleClickHistoryBack,
            "referenceKeyboardDownMovedSelection":
                referenceKeyboardDownMovedSelection,
            "referenceKeyboardUpMovedSelection":
                referenceKeyboardUpMovedSelection,
            "referenceKeyboardSelectionNavigated":
                referenceKeyboardSelectionNavigated,
            "referenceKeyboardAXNotificationCorrect":
                referenceKeyboardAXNotificationCorrect,
            "referenceKeyboardEnterOpened": referenceKeyboardEnterOpened,
            "referenceKeyboardKeypadEnterOpened":
                referenceKeyboardKeypadEnterOpened,
            "referenceKeyboardRestoredRelationFile":
                referenceKeyboardRestoredRelationFile,

            "exactStatusVisible": exactStatusVisible,
            "initialStatusSafeBeforeClick": initialStatusSafe,
            "initialProfileVisible": initialProfileVisible,
            "initialProfileTitleSafe": initialProfileTitleSafe,
            "relationTimingFileVisible": relationTimingFileVisible,
            "relationColdTimingFieldsValid": relationColdTimingFieldsValid,
            "relationWarmTimingFieldsValid": relationWarmTimingFieldsValid,
            "relationTimingSameSession": relationTimingSameSession,
            "relationColdFirstActionableSelectable":
                relationColdFirstActionableSelectable,
            "relationWarmFirstActionableSelectable":
                relationWarmFirstActionableSelectable,
            "relationColdHeuristicFirst":
                relationColdTiming.relationFirstActionableKind == "heuristic",
            "relationWarmHeuristicFirst":
                relationWarmTiming.relationFirstActionableKind == "heuristic",
            "featureProbeFileVisible": featureProbeFileVisible,
            "featureMenuActionTriggered": menuActionTriggered,
            "featurePrepared": featurePrepared,
            "featureContextClearedDuringSwitch": !contextVisibleDuringSwitch,
            "featureFuzzyAfterSwitch": fuzzyAfterSwitch,
            "featureOldGenerationRequestInFlight":
                oldGenerationRequestInFlight,
            "featureOldGenerationResultReturned":
                oldGenerationResultReturned,
            "featureOldGenerationRelationResultReturned":
                oldGenerationRelationResultReturned,
            "featureOldGenerationResultDiscarded":
                oldGenerationResultDiscarded,
            "featureRelationActiveBeforeSwitch":
                featureRelationActiveBeforeSwitch,
            "featureRelationRestoredAfterSwitch":
                featureRelationRestoredAfterSwitch,
            "featureSwitchedExactVisible": switchedExactVisible,
            "featureProfileButtonVisibleWithGeometry":
                profileButtonVisibleWithGeometry,
            "relationFileVisible": relationFileVisible,
            "selectedFirstFollowCaller": selectedFirstFollowCaller,
            "selectedSecondFollowCaller": selectedSecondFollowCaller,
            "relationRowsUpdateFollowContext": relationRowsUpdateFollowContext,
            "relationFollowContextRestored": relationFollowContextRestored,
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
            "relationFileRestoredAfterDependency":
                relationFileRestoredAfterDependency,
            "typedReceiverStrong": typedReceiver.present,
            "typedReceiverAbsentFromPossible": typedReceiver.absent,
            "typedReceiverNameMatchNoteAbsent": typedReceiver.subtitleHonest,
            "inferredReceiverProbable": inferredReceiver.present,
            "inferredReceiverAbsentFromPossible": inferredReceiver.absent,
            "inferredReceiverNameMatchNoteAbsent":
                inferredReceiver.subtitleHonest,
            "traitObjectStaysPossible": traitObjectReceiver.present,
            "traitObjectAbsentFromStrongAndProbable":
                traitObjectReceiver.absent,
            "traitObjectSubtitleHonest": traitObjectReceiver.subtitleHonest,
            "realProviderPassedOrSkipped": real.passed,
            "realOfflineCoveragePassedOrSkipped": realOffline.passed,
            "historicalExactVisible": historical.exactVisible,
            "historicalInitialStatusSafe": historical.initialStatusSafe,
            "providerRootIsMaterialized": historical.providerRootIsMaterialized,
            "uiPathIsRepoRelative": historical.uiPathIsRepoRelative,
            "historicalProvenanceAttributed": historical.provenanceAttributed,
        ]
        for (key, value) in checksAfterFirstBatch { checks[key] = value }
        for (key, value) in trustRevoke { checks[key] = value }
        for (key, value) in real.reachedChecks { checks[key] = value }
        finishExactSelfTest(
            controller: windowController,
            checks: checks,
            realProvider: real.status,
            realOfflineCoverage: realOffline.status,
            error: nil
        )
    }

    private func runExactZeroCoverageVariant(
        root: URL,
        limitations: Set<ExactAnalysisLimitation>
    ) -> String? {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CodeInsightExactZeroCoverageSelfTest-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: cache) }
        let coordinator = ExactCoordinator(
            providerFactory: { _ in
                InProcessExactProvider(
                    location: nil,
                    capabilities: [.references],
                    referenceLocations: [],
                    limitations: limitations
                )
            },
            snapshotFactory: { root, _ in
                try ExactSelfTestDirectorySnapshot(root: root)
            },
            sandboxAvailable: { true },
            trustRegistry: TrustRegistry(
                fileURL: cache.appendingPathComponent("trust.json")
            )
        )
        defer { coordinator.shutdown() }
        let variant = AppModel(
            indexService: ExactSelfTestIndexService(),
            exactCoordinator: coordinator
        )
        variant.openProject(root: root)
        guard waitUntil(timeout: 5, condition: {
            guard case .ready = variant.projectState else { return false }
            return coordinator.readiness == .ready
                && coordinator.analysisEnvironment?.limitations == limitations
        }), case let .ready(session, context) = variant.projectState,
        let symbol = try? session.definitions(
            of: "answer",
            context: context
        ).first?.0
        else { return nil }

        variant.relationTree.setRoot(
            target: .engine(symbol),
            direction: .references
        )
        guard waitUntil(timeout: 5, condition: {
            variant.relationTree.root?.children?.contains {
                $0.kind == .loading
            } == false
        }) else { return nil }
        return variant.relationTree.root?.children?.first {
            $0.kind == .truncated
                && ($0.title.hasPrefix("Verified ")
                    || $0.title.hasPrefix("No verified ")
                    || $0.title.hasPrefix("Analysis limited:"))
        }?.title
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
        let unit = trustModel.activeAnalysisProfileDisplay?
            .projectUnitName ?? fixture.lastPathComponent
        let safeProfileTitle = "Rust · \(unit) · default · Safe"
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
            "Rust · \(unit) · default · Trusted"
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

        let settingsTrustModel = TrustListModel()
        settingsTrustModel.replace(coordinator.trustedRepositories)
        let settingsController = ReaderSettingsWindowController(
            settings: readerSettings,
            trustModel: settingsTrustModel,
            onRevoke: { repositoryURL in
                try? await trustModel.revokeRepositoryTrust(repositoryURL)
                await settingsTrustModel.refresh(from: coordinator.trustRegistry)
            },
            onClearCache: {
                do {
                    try await coordinator.clearMaterializedCache()
                    return .cleared
                } catch {
                    return .failed(error.localizedDescription)
                }
            },
            onChange: { _ in }
        )
        settingsController.window?.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        settingsController.showWindow(nil)
        defer { settingsController.close() }

        let trustView = NSHostingView(rootView: TrustSettingsView(
            trustModel: settingsTrustModel,
            onRevoke: { repositoryURL in
                try? await trustModel.revokeRepositoryTrust(repositoryURL)
                await settingsTrustModel.refresh(from: coordinator.trustRegistry)
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
    ) -> (status: String, passed: Bool, reachedChecks: [String: Bool]) {
        let unreached: [String: Any] = [
            "textDocumentImplementationReached": false,
            "callHierarchyIncomingCallsReached": false,
            "callHierarchyOutgoingCallsReached": false,
        ]
        guard let executable = RustAnalyzerProvider.findExecutable() else {
            emitExactStep(
                "skipped",
                variant: "rust-analyzer",
                controller: nil,
                extra: unreached.merging(
                    ["reason": "rust-analyzer not installed"]
                ) { _, new in new }
            )
            return ("skipped:not-installed", true, [:])
        }

        let fixtureRoot = exactSelfTestFixtureRoot(root: root)
        guard let target = exactSelfTestTarget(root: fixtureRoot) else {
            emitExactStep(
                "skipped",
                variant: "rust-analyzer",
                controller: nil,
                extra: unreached.merging(
                    ["reason": "real-provider fixture unavailable"]
                ) { _, new in new }
            )
            return ("skipped:fixture-unavailable", true, [:])
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
            return ("failed:project", false, [:])
        }

        if case .off(let reason) = coordinator.readiness {
            emitExactStep(
                "skipped",
                variant: "rust-analyzer",
                controller: controller,
                extra: unreached.merging(["reason": reason]) { _, new in new }
            )
            return ("skipped:sandbox-unavailable", true, [:])
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
                extra: unreached.merging(["reason": reason]) { _, new in new }
            )
            return ("skipped:sandbox-unavailable", true, [:])
        }
        guard initialStatusSafe else {
            return ("failed:initial-status", false, [:])
        }

        guard let definitionOffset = UInt32(exactly: target.definition.byteOffset)
        else {
            return ("failed:fixture", false, [:])
        }
        let realRelationTimingFileVisible =
            controller.selectFileInSidebar(target.relationFile)
            && waitUntil(timeout: 5, condition: {
                controller.displayedReaderFile?.standardizedFileURL
                    == target.relationFile.standardizedFileURL
            })
        var realRelationColdTiming = (
            relationFirstActionableMS: 0.0,
            relationAllResultsMS: 0.0,
            relationFirstActionableKind: "",
            relationFirstActionableTitle: "",
            relationCandidateEdgeCount: 0
        )
        var realRelationWarmTiming = realRelationColdTiming
        if realRelationTimingFileVisible {
            realRelationColdTiming = measureRelationTiming(
                model: realModel,
                controller: controller,
                offset: definitionOffset,
                direction: .callers,
                timeout: 45
            )
            realRelationWarmTiming = measureRelationTiming(
                model: realModel,
                controller: controller,
                offset: definitionOffset,
                direction: .callers,
                timeout: 45
            )
        }
        let realRelationColdSelectable =
            !realRelationColdTiming.relationFirstActionableTitle.isEmpty
            && controller.selfTestSelectRelationEdge(
                titled: realRelationColdTiming.relationFirstActionableTitle
            )
            && controller.selfTestSelectedRelationEdgeTitle
                == realRelationColdTiming.relationFirstActionableTitle
        let realRelationWarmSelectable =
            !realRelationWarmTiming.relationFirstActionableTitle.isEmpty
            && controller.selfTestSelectRelationEdge(
                titled: realRelationWarmTiming.relationFirstActionableTitle
            )
            && controller.selfTestSelectedRelationEdgeTitle
                == realRelationWarmTiming.relationFirstActionableTitle
        controller.selfTestDeselectRelation()
        let realRelationColdTimingFieldsValid =
            realRelationColdTiming.relationFirstActionableMS > 0
            && realRelationColdTiming.relationAllResultsMS
                >= realRelationColdTiming.relationFirstActionableMS
            && ["heuristic", "exact"].contains(
                realRelationColdTiming.relationFirstActionableKind
            )
        let realRelationWarmTimingFieldsValid =
            realRelationWarmTiming.relationFirstActionableMS > 0
            && realRelationWarmTiming.relationAllResultsMS
                >= realRelationWarmTiming.relationFirstActionableMS
            && ["heuristic", "exact"].contains(
                realRelationWarmTiming.relationFirstActionableKind
            )
        var reachedChecks = [
            "realRelationTimingFileVisible": realRelationTimingFileVisible,
            "realRelationColdTimingFieldsValid":
                realRelationColdTimingFieldsValid,
            "realRelationWarmTimingFieldsValid":
                realRelationWarmTimingFieldsValid,
            "realRelationColdFirstActionableSelectable":
                realRelationColdSelectable,
            "realRelationWarmFirstActionableSelectable":
                realRelationWarmSelectable,
        ]
        emitExactStep(
            "relation-timing",
            variant: "rust-analyzer",
            controller: controller,
            extra: [
                "measurementScope": "real rust-analyzer",
                "thresholdBasis":
                    "structural-only; threshold pending host measurement",
                "cold": [
                    "relationFirstActionableMS":
                        realRelationColdTiming.relationFirstActionableMS,
                    "relationAllResultsMS":
                        realRelationColdTiming.relationAllResultsMS,
                    "relationFirstActionableKind":
                        realRelationColdTiming.relationFirstActionableKind,
                    "relationFirstActionableTitle":
                        realRelationColdTiming.relationFirstActionableTitle,
                    "relationCandidateEdgeCount":
                        realRelationColdTiming.relationCandidateEdgeCount,
                ],
                "warm": [
                    "relationFirstActionableMS":
                        realRelationWarmTiming.relationFirstActionableMS,
                    "relationAllResultsMS":
                        realRelationWarmTiming.relationAllResultsMS,
                    "relationFirstActionableKind":
                        realRelationWarmTiming.relationFirstActionableKind,
                    "relationFirstActionableTitle":
                        realRelationWarmTiming.relationFirstActionableTitle,
                    "relationCandidateEdgeCount":
                        realRelationWarmTiming.relationCandidateEdgeCount,
                ],
                "coldHeuristicFirstObserved":
                    realRelationColdTiming.relationFirstActionableKind
                        == "heuristic",
                "warmHeuristicFirstObserved":
                    realRelationWarmTiming.relationFirstActionableKind
                        == "heuristic",
            ]
        )
        guard reachedChecks.values.allSatisfy({ $0 }),
              controller.selectFileInSidebar(target.file),
              waitUntil(timeout: 5, condition: {
                  controller.displayedReaderFile?.standardizedFileURL
                      == target.file.standardizedFileURL
              })
        else {
            return ("failed:relation-timing", false, reachedChecks)
        }

        let contextStartedAt = ContinuousClock.now
        controller.selfTestReaderClick(offset: target.clickOffset, commandClick: false)
        let contextVisible = waitUntil(timeout: 5, condition: {
            controller.selfTestContextCandidateCount >= 1
        })
        let contextFirstActionableMS = contextVisible
            ? milliseconds(since: contextStartedAt)
            : 0
        let fuzzyVisible = contextVisible
            && controller.selfTestContextProvenance?.contains("Exact") == false
        let fuzzyCount = controller.selfTestContextCandidateCount
        emitExactStep(
            "fuzzy",
            variant: "rust-analyzer",
            controller: controller,
            extra: ["fuzzyVisibleBeforeExact": fuzzyVisible]
        )
        guard contextVisible else { return ("failed:context", false, [:]) }

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
                extra: unreached.merging(["reason": reason]) { _, new in new }
            )
            return ("skipped:sandbox-unavailable", true, [:])
        }
        if case .unavailable(let reason) = coordinator.readiness {
            emitExactStep(
                "failed",
                variant: "rust-analyzer",
                controller: controller,
                extra: ["reason": reason]
            )
            return ("failed:unavailable", false, [:])
        }
        let exactVisible = finished
            && controller.selfTestContextProvenance?.contains("Exact") == true
        let contextExactMS = exactVisible
            ? milliseconds(since: contextStartedAt)
            : 0
        let fuzzyRetained = controller.selfTestContextCandidateCount >= fuzzyCount
        emitExactStep(
            "exact",
            variant: "rust-analyzer",
            controller: controller,
            extra: [
                "contextFirstActionableMS": contextFirstActionableMS,
                "contextExactMS": contextExactMS,
            ]
        )
        guard exactVisible && fuzzyRetained,
              let signatureTraitOffset = target.signatureTraitOffset,
              let relationRootOffset = target.relationRootOffset,
              controller.selectFileInSidebar(target.relationFile),
              waitUntil(timeout: 5, condition: {
                  controller.displayedReaderFile?.standardizedFileURL
                      == target.relationFile.standardizedFileURL
              })
        else {
            return ("failed:exact", false, [:])
        }

        func exactEdges() -> [(symbol: String, file: String)] {
            exactRelationEdges(in: realModel).compactMap {
                guard let file = $0.target?.path
                else { return nil }
                return ($0.title, file)
            }
        }

        controller.selfTestReaderRelation(
            offset: signatureTraitOffset,
            direction: .implementations
        )
        let implementationReached = waitUntil(timeout: 45, condition: {
            realModel.relationTree.direction == .implementations
                && realModel.relationTree.root?.title == "Backend"
                && exactEdges().contains {
                    $0 == ("ExactFixtureBackend", "src/lib.rs")
                }
        })
        emitExactStep(
            implementationReached ? "real-implementations" : "failed",
            variant: "rust-analyzer",
            controller: controller,
            extra: [
                "textDocumentImplementationReached": implementationReached,
                "exactEdges": exactEdges().map {
                    ["symbol": $0.symbol, "file": $0.file]
                },
            ]
        )
        reachedChecks["textDocumentImplementationReached"] =
            implementationReached
        guard implementationReached else {
            return ("failed:implementations", false, reachedChecks)
        }

        controller.selfTestReaderRelation(
            offset: definitionOffset,
            direction: .callers
        )
        let incomingCallsReached = waitUntil(timeout: 45, condition: {
            realModel.relationTree.direction == .callers
                && realModel.relationTree.root?.title == "answer"
                && exactEdges().contains {
                    $0 == ("relation_root", "src/lib.rs")
                }
                && exactEdges().contains {
                    $0 == ("main", "src/main.rs")
                }
        })
        emitExactStep(
            incomingCallsReached ? "real-incoming-calls" : "failed",
            variant: "rust-analyzer",
            controller: controller,
            extra: [
                "callHierarchyIncomingCallsReached": incomingCallsReached,
                "exactEdges": exactEdges().map {
                    ["symbol": $0.symbol, "file": $0.file]
                },
            ]
        )
        reachedChecks["callHierarchyIncomingCallsReached"] =
            incomingCallsReached
        guard incomingCallsReached else {
            return ("failed:incoming-calls", false, reachedChecks)
        }

        controller.selfTestReaderRelation(
            offset: relationRootOffset,
            direction: .calls
        )
        let outgoingCallsReached = waitUntil(timeout: 45, condition: {
            realModel.relationTree.direction == .calls
                && realModel.relationTree.root?.title == "relation_root"
                && exactEdges().contains {
                    $0 == ("answer", "src/lib.rs")
                }
        })
        emitExactStep(
            outgoingCallsReached ? "real-outgoing-calls" : "failed",
            variant: "rust-analyzer",
            controller: controller,
            extra: [
                "callHierarchyOutgoingCallsReached": outgoingCallsReached,
                "exactEdges": exactEdges().map {
                    ["symbol": $0.symbol, "file": $0.file]
                },
            ]
        )
        reachedChecks["callHierarchyOutgoingCallsReached"] =
            outgoingCallsReached
        guard outgoingCallsReached else {
            return ("failed:outgoing-calls", false, reachedChecks)
        }

        controller.selfTestReaderRelation(
            offset: definitionOffset,
            direction: .references
        )
        let exactReferencesVisible = waitUntil(timeout: 45, condition: {
            realModel.relationTree.direction == .references
                && exactEdges().contains { $0.symbol.hasPrefix("main.rs:") }
        })
        emitExactStep(
            exactReferencesVisible ? "real-references" : "failed",
            variant: "rust-analyzer",
            controller: controller,
            extra: [
                "textDocumentReferencesReached": exactReferencesVisible,
            ]
        )
        return exactReferencesVisible
            ? ("passed", true, reachedChecks)
            : ("failed:references", false, reachedChecks)
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
            coordinator.analysisEnvironment?.limitations.contains(
                .dependenciesUnavailableOffline
            ) == true
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

    private func measureRelationTiming(
        model: AppModel,
        controller: MainWindowController,
        offset: UInt32,
        direction: RelationTreeModel.Direction,
        timeout: TimeInterval
    ) -> (
        relationFirstActionableMS: Double,
        relationAllResultsMS: Double,
        relationFirstActionableKind: String,
        relationFirstActionableTitle: String,
        relationCandidateEdgeCount: Int
    ) {
        let previousGeneration = model.relationTree.generation
        let startedAt = ContinuousClock.now
        controller.selfTestReaderRelation(offset: offset, direction: direction)
        let deadline = ContinuousClock.now + .seconds(timeout)
        var firstMS = 0.0
        var firstKind = ""
        var firstTitle = ""
        var allResultsMS = 0.0
        while ContinuousClock.now < deadline {
            if model.relationTree.generation > previousGeneration {
                if firstMS == 0,
                   let first = firstActionableRelation(
                       model: model,
                       controller: controller
                   )
                {
                    firstMS = milliseconds(since: startedAt)
                    firstKind = first.kind
                    firstTitle = first.title
                }
                if firstMS > 0,
                   let children = model.relationTree.root?.children,
                   !children.contains(where: { $0.kind == .loading })
                {
                    allResultsMS = milliseconds(since: startedAt)
                    break
                }
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        return (
            firstMS,
            allResultsMS,
            firstKind,
            firstTitle,
            model.relationTree.heuristicCandidateCount
        )
    }

    private func exactRelationEdges(
        in model: AppModel
    ) -> [RelationTreeModel.Node] {
        guard let root = model.relationTree.root else { return [] }
        return relationEdgeNodes(in: root).filter { $0.badge == "Verified" }
    }

    private func relationEdgeNodes(
        in root: RelationTreeModel.Node
    ) -> [RelationTreeModel.Node] {
        let children = root.children ?? []
        var rows: [RelationTreeModel.Node] = []
        for child in children {
            if child.kind == .edge {
                rows.append(child)
            } else {
                rows += (child.children ?? []).filter { $0.kind == .edge }
            }
        }
        return rows
    }

    private var exactRelationEdgeCount: Int {
        exactRelationEdges(in: model).count
    }

    private func exactRelationEdgeCount(in model: AppModel) -> Int {
        exactRelationEdges(in: model).count
    }

    private func finishPythonSelfTest(
        coldFileCount: Int,
        coldReused: Int,
        coldExtracted: Int,
        hotFileCount: Int,
        hotReused: Int,
        hotExtracted: Int,
        checks: [String: Bool],
        startedAt: ContinuousClock.Instant
    ) -> Never {
        let passed = checks.values.allSatisfy { $0 }
        Self.writeJSON([
            "step": "summary",
            "channel": "python",
            "passed": passed,
            "cold": [
                "fileCount": coldFileCount,
                "reused": coldReused,
                "extracted": coldExtracted,
            ],
            "hot": [
                "fileCount": hotFileCount,
                "reused": hotReused,
                "extracted": hotExtracted,
            ],
            "checks": checks,
            "elapsedMS": milliseconds(since: startedAt),
        ])
        Self.exitSelfTest(channel: "python", status: passed ? 0 : 1)
    }

    private func finishPythonSelfTest(
        error: String,
        startedAt: ContinuousClock.Instant
    ) -> Never {
        Self.writeJSON([
            "step": "summary",
            "channel": "python",
            "passed": false,
            "error": error,
            "elapsedMS": milliseconds(since: startedAt),
        ])
        Self.exitSelfTest(channel: "python", status: 1)
    }

    private func firstActionableRelation(
        model: AppModel,
        controller: MainWindowController
    ) -> (kind: String, title: String)? {
        guard controller.selfTestRelationsTreeVisible,
              let root = model.relationTree.root
        else { return nil }
        let visibleRect = controller.selfTestRelationsVisibleRect
        let titles = controller.selfTestVisibleRelationEdgeTitles(inGroup: "")
        let frames = controller.selfTestVisibleRelationEdgeFrames(inGroup: "")
        let rows = root.children?.flatMap { child in
            child.kind == .edge
                ? [child]
                : (child.children ?? []).filter { $0.kind == .edge }
        } ?? []
        for (title, frame) in zip(titles, frames) {
            let visibleFrame = visibleRect.intersection(frame)
            guard frame.width > 0,
                  frame.height > 0,
                  visibleFrame.width > 0,
                  visibleFrame.height > 0,
                  let row = rows.first(where: {
                      $0.title == title && $0.target != nil
                  })
            else { continue }
            return (
                row.badge == "Verified" ? "exact" : "heuristic",
                title
            )
        }
        return nil
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
        Self.exitSelfTest(channel: "exact", status: passed ? 0 : 1)
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
        Self.exitSelfTest(channel: "pin", status: passed ? 0 : 1)
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

    func runPythonSelfTest(root inputRoot: URL) async -> Never {
        launch(offscreen: true, measuresIdleFootprint: false)
        let startedAt = ContinuousClock.now
        let root = inputRoot.standardizedFileURL
        let relativeMemoryFile = "src/mcp/shared/memory.py"
        let memoryFile = root.appendingPathComponent(relativeMemoryFile)
            .standardizedFileURL
        let compareRelativeFile = "src/mcp/server/fastmcp/server.py"
        let compareFile = root.appendingPathComponent(compareRelativeFile)
            .standardizedFileURL
        let hierarchyRelativeFile = "src/mcp/cli/cli.py"
        let hierarchyFile = root.appendingPathComponent(hierarchyRelativeFile)
            .standardizedFileURL
        let pythonModel = self.model
        let pythonRecentStore = self.recentProjectsStore

        func pythonReady() -> Bool {
            if case let .ready(session, _) = pythonModel.projectState {
                return session.analysisProfile.language == .python
            }
            return false
        }
        func finish(_ error: String) -> Never {
            finishPythonSelfTest(error: error, startedAt: startedAt)
        }
        func pythonWait(
            timeout: TimeInterval,
            _ condition: @escaping () -> Bool
        ) async -> Bool {
            let deadline = Date(timeIntervalSinceNow: timeout)
            while Date() < deadline {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return condition()
        }

        guard let controller = windowController else {
            finish("window unavailable")
        }
        guard previousCommitRevision(root: root) != nil else {
            finish("HEAD~1 unavailable")
        }

        controller.openProject(root: root, language: .python)
        guard await pythonWait(timeout: 120, {
            if case .failed = pythonModel.projectState { return true }
            if case .ready = pythonModel.projectState {
                return pythonModel.fileTree != nil
                    && !pythonModel.commitPicker.isLoading
                    && pythonModel.snapshotPhase == .fullReady
                    && pythonReady()
            }
            return false
        }), case let .ready(session, context) = pythonModel.projectState,
              pythonModel.snapshotPhase == .fullReady,
              pythonModel.fileTree != nil,
              session.analysisProfile.language == .python,
              let previousRevision = pythonModel.commitPicker.commits
                .dropFirst().first?.fullSHA
        else {
            finish("python project or HEAD~1 commit unavailable")
        }
        let coldSession = session
        let coldContext = context
        let fileCount = pythonModel.fileTree?.fileCount ?? 0
        let coldStats = coldSession.stats
        let sourceFiles = coldSession.manifest.files.filter { $0.detectedLanguage == .python }
        let semanticIndexOnlyPython = coldSession.manifest.files.allSatisfy { file in
            let mode = LanguageMode.classify(
                path: coldSession.paths.resolve(file.pathID), language: .python
            )
            return file.detectedLanguage == mode?.language
                && coldSession.content(at: file.pathID)?.0.languageMode == mode
        } && coldSession.contentIndexes.keys.allSatisfy { $0.languageMode.language == .python }
        let treeFiles = pythonFiles(in: pythonModel.fileTree?.children ?? [])
        let snapshotFiles = coldSession.manifest.files.filter {
            $0.fileMode == .regular || $0.fileMode == .lfsPointer
        }.map { root.appendingPathComponent(coldSession.paths.resolve($0.pathID)).standardizedFileURL }
        let treeMatchesSnapshot = Set(treeFiles) == Set(snapshotFiles)
        guard treeMatchesSnapshot, sourceFiles.count == 204, semanticIndexOnlyPython else {
            finish("Python workspace/index mismatch: tree=\(treeFiles.count) snapshot=\(snapshotFiles.count) sources=\(sourceFiles.count) semanticIndexOnlyPython=\(semanticIndexOnlyPython)")
        }
        let configPath = "pyproject.toml"
        let configFile = root.appendingPathComponent(configPath).standardizedFileURL
        guard let config = coldSession.manifest.files.first(where: {
                  coldSession.paths.resolve($0.pathID) == configPath
              }), config.detectedLanguage == nil,
              let configBytes = try? Array(Data(contentsOf: configFile)),
              ContentID.sha256(of: configBytes) == config.contentID,
              controller.selectFileInSidebar(configFile),
              await pythonWait(timeout: 30, {
                  controller.displayedReaderFile?.standardizedFileURL == configFile
                      && controller.selfTestReaderPreviewKind == "Plain text"
                      && controller.selfTestReaderPreviewText == String(decoding: configBytes, as: UTF8.self)
                      && pythonModel.tabStrip.activeDocument == nil
              })
        else { finish("Python configuration preview did not match the worktree snapshot") }
        Self.writeJSON([
            "step": "cold-open",
            "language": "python",
            "projectUnit": coldSession.analysisProfile.projectUnitName,
            "fileCount": fileCount,
            "sourceFileCount": sourceFiles.count,
            "treeMatchesSnapshot": treeMatchesSnapshot,
            "configurationPreview": configPath,
            "reused": coldStats.reusedCount,
            "extracted": coldStats.extractedCount,
            "snapshotPhase": pythonModel.snapshotPhase?.rawValue as Any,
            "elapsedMS": milliseconds(since: startedAt),
        ])

        guard await pythonWait(timeout: 90, {
            pythonModel.exactCoordinator.readiness == .ready
        }), let attribution = pythonModel.exactCoordinator.attribution
        else {
            finish("Pyright missing/unready: \(pythonModel.exactCoordinator.readiness)")
        }

        do {
            let contentHits = try await contentSearchHits(
                session: coldSession,
                context: coldContext,
                query: ContentSearchQuery(
                    pattern: "create_client_server_memory_streams",
                    caseSensitive: true
                )
            )
            let symbolHits = try coldSession.searchSymbols(
                query: "create_client_server_memory_streams",
                limit: 20,
                boost: SearchBoost(),
                context: coldContext
            )
            guard contentHits.contains(where: { $0.hasSuffix(relativeMemoryFile) }),
                  symbolHits.contains(where: { $0.path.hasSuffix(relativeMemoryFile) })
            else {
                finish("search did not hit memory.py")
            }
            Self.writeJSON([
                "step": "search",
                "contentHit": relativeMemoryFile,
                "symbolHit": relativeMemoryFile,
                "elapsedMS": milliseconds(since: startedAt),
            ])
        } catch {
            finish("search failed: \(error)")
        }

        guard controller.selectFileInSidebar(memoryFile),
              await pythonWait(timeout: 30, {
                  controller.displayedReaderFile?.standardizedFileURL
                      == memoryFile.standardizedFileURL
                      && pythonModel.tabStrip.activeDocument != nil
                      && controller.selfTestStyledFragmentCount > 0
              })
        else {
            finish("could not open memory.py in reader")
        }
        let readerBytes = controller.selfTestLeftReaderBytes ?? []
        let activeDocument = pythonModel.tabStrip.activeDocument
        let outlineCount = activeDocument?.outlineFacets.count ?? 0
        let bindingCount = activeDocument?.localBindings.count ?? 0
        let localReferenceCount = activeDocument?.referencesByBinding
            .compactMap(\.count).reduce(0, +) ?? 0
        let styledFragments = controller.selfTestStyledFragmentCount
        let foldRegions = activeDocument?.foldRegions.count ?? 0
        guard !readerBytes.isEmpty,
              outlineCount > 0,
              bindingCount > 0,
              localReferenceCount > 0,
              styledFragments > 0,
              foldRegions > 0
        else {
            finish("Reader/outline/local reference unavailable")
        }
        let needleOffsets = utf8Offsets(
            of: "create_client_server_memory_streams",
            in: readerBytes
        )
        guard let callOffset = needleOffsets.dropFirst().first
            .flatMap(UInt32.init)
        else {
            finish("call-site offset unavailable")
        }
        let fuzzy = await pythonModel.contextWindow.resolvedCandidate(
            file: relativeMemoryFile,
            offset: callOffset
        )
        guard let fuzzySymbol = fuzzy?.symbol else {
            finish("fuzzy context had no Python symbol")
        }
        controller.selfTestReaderRelation(
            offset: callOffset,
            direction: .references
        )
        let localRelationLoaded = await pythonWait(timeout: 30) {
            guard let root = pythonModel.relationTree.root,
                  !(root.children?.contains { $0.kind == .loading } ?? true)
            else { return false }
            return !self.relationEdgeNodes(in: root).isEmpty
        }
        guard localRelationLoaded else {
            finish("local relation tree did not load")
        }
        Self.writeJSON([
            "step": "reader-context",
            "outlineFacets": outlineCount,
            "localBindings": bindingCount,
            "localReferences": localReferenceCount,
            "styledFragments": styledFragments,
            "foldRegions": foldRegions,
            "fuzzySymbol": fuzzySymbol.localIndex,
            "localRelationLoaded": localRelationLoaded,
            "elapsedMS": milliseconds(since: startedAt),
        ])

        guard case let .completed(definitions) =
            await pythonModel.exactCoordinator.definition(
                file: relativeMemoryFile,
                byteOffset: callOffset,
                generation: coldContext.generation
            ),
            !definitions.isEmpty
        else {
            finish("Pyright definition unavailable")
        }

        await pythonModel.relationTree.setRoot(
            target: .engine(fuzzySymbol),
            direction: .references
        )?.value
        let referenceCount = exactRelationEdgeCount(in: pythonModel)

        guard let hierarchyBytes = try? Array(Data(contentsOf: hierarchyFile)),
              let hierarchyDeclOffset = utf8Offsets(
                  of: "def _parse_file_path",
                  in: hierarchyBytes
              ).first,
              let hierarchyOffset = utf8Offsets(
                  of: "_parse_file_path",
                  in: Array(hierarchyBytes.dropFirst(hierarchyDeclOffset))
              ).first.map({ hierarchyDeclOffset + $0 }).flatMap(UInt32.init),
              let hierarchyCandidate = await pythonModel.contextWindow
                .resolvedCandidate(
                    file: hierarchyRelativeFile,
                    offset: hierarchyOffset
                ),
              let hierarchySymbol = hierarchyCandidate.symbol
        else {
            finish("hierarchy symbol unavailable")
        }
        await pythonModel.relationTree.setRoot(
            target: .engine(hierarchySymbol),
            direction: .callers
        )?.value
        let callerCount = exactRelationEdgeCount(in: pythonModel)
        await pythonModel.relationTree.setRoot(
            target: .engine(hierarchySymbol),
            direction: .calls
        )?.value
        let callCount = exactRelationEdgeCount(in: pythonModel)
        let exactReferences = referenceCount > 0
        let callHierarchyExact = callerCount > 0 || callCount > 0
        Self.writeJSON([
            "step": "real-python-hierarchy-counts",
            "hierarchyFile": hierarchyRelativeFile,
            "hierarchyOffset": hierarchyOffset,
            "referenceCount": referenceCount,
            "callerCount": callerCount,
            "callCount": callCount,
            "elapsedMS": milliseconds(since: startedAt),
        ])
        guard callHierarchyExact else {
            finish("Pyright call hierarchy unavailable")
        }
        pythonModel.contextWindow.tokenClicked(
            file: hierarchyRelativeFile,
            offset: hierarchyOffset
        )
        let contextSymbolReady = await pythonWait(timeout: 5) {
            if pythonModel.contextWindow.selectedCandidate?.symbol
                == hierarchySymbol
            {
                return true
            }
            return false
        }
        guard contextSymbolReady else {
            finish("implementations context symbol unavailable")
        }
        // S5/D3: the global relation commands resolve from the Reader's
        // selection, so place it on the hierarchy symbol first.
        controller.selfTestNavigate(to: hierarchyFile, byteOffset: hierarchyOffset)
        controller.showRelations(direction: .implementations)
        let implementationsUnsupported = await pythonWait(timeout: 5) {
            if controller.selfTestVisibleRelationText.contains(where: {
                $0.contains("Verified unavailable: server does not support implementations")
            }) {
                return true
            }
            return false
        }
        guard implementationsUnsupported else {
            finish("implementations must be unsupported")
        }
        guard let hierarchyDocument = pythonModel.tabStrip.activeDocument,
              let hierarchyBinding = hierarchyDocument.localBinding(at: hierarchyOffset),
              hierarchyBinding.binding.kind == .letBinding,
              !hierarchyBinding.references.isEmpty,
              let hierarchyManifestFile = coldSession.manifest.files.first(where: {
                  coldSession.paths.resolve($0.pathID) == hierarchyRelativeFile
                      && $0.contentID == hierarchyDocument.contentID
              })
        else { finish("hierarchy Reader binding or snapshot identity unavailable") }
        controller.showRelations(direction: .references)
        let localReferencesAfterUnsupported = await pythonWait(timeout: 5) {
            guard pythonModel.exactCoordinator.readiness == .ready,
                  pythonModel.relationTree.direction == .references,
                  let root = pythonModel.relationTree.root,
                  root.kind == .root, root.symbol == nil, root.subtitle == "Local",
                  let target = root.target,
                  target.path == coldSession.paths.resolve(hierarchyManifestFile.pathID),
                  target.byteOffset == hierarchyBinding.binding.declarationRange.lowerBound,
                  hierarchyDocument.localBinding(at: target.byteOffset)?.bindingIndex
                    == hierarchyBinding.bindingIndex,
                  let edges = root.children,
                  edges.count == hierarchyBinding.references.count,
                  edges.allSatisfy({ $0.kind == .edge })
            else { return false }
            return zip(edges, hierarchyBinding.references).allSatisfy { edge, range in
                edge.target?.path == target.path
                    && edge.target?.byteOffset == range.lowerBound
                    && edge.line == hierarchyDocument.lineTable.lineColumn(at: range.lowerBound)?.line
            } && !controller.selfTestVisibleRelationText.contains {
                $0.contains("server does not support implementations")
            }
        }
        let referencesVisibleAfterUnsupported =
            controller.selfTestVisibleRelationText
        let coordinatorReadinessAfterUnsupported =
            pythonModel.exactCoordinator.readiness
        guard localReferencesAfterUnsupported else {
            Self.writeJSON([
                "step": "references-after-unsupported-diagnostic",
                "visible": referencesVisibleAfterUnsupported,
                "readiness": String(describing: coordinatorReadinessAfterUnsupported),
                "expectedBindingIndex": hierarchyBinding.bindingIndex,
                "expectedPath": hierarchyRelativeFile,
                "expectedReferenceOffsets": hierarchyBinding.references.map(\.lowerBound),
                "elapsedMS": milliseconds(since: startedAt),
            ])
            finish("local references after unsupported implementations did not match Reader binding")
        }
        await pythonModel.relationTree.setRoot(
            target: .engine(hierarchySymbol),
            direction: .references
        )?.value
        let exactReferencesAfterUnsupportedCount = exactRelationEdgeCount(in: pythonModel)
        let exactReferencesAfterUnsupported = pythonModel.exactCoordinator.readiness == .ready
            && pythonModel.relationTree.direction == .references
            && pythonModel.relationTree.root?.symbol == hierarchySymbol
            && exactReferencesAfterUnsupportedCount > 0
        guard exactReferencesAfterUnsupported else {
            finish("Pyright references after unsupported implementations unavailable")
        }
        Self.writeJSON([
            "step": "real-python-exact",
            "provider": attribution.provider,
            "toolVersion": attribution.toolVersion,
            "definitionTargets": definitions.count,
            "references": referenceCount,
            "localReferencesAfterUnsupported": hierarchyBinding.references.count,
            "exactReferencesAfterUnsupported": exactReferencesAfterUnsupportedCount,
            "callers": callerCount,
            "calls": callCount,
            "implementations": "unsupported",
            "elapsedMS": milliseconds(since: startedAt),
        ])

        guard let worktreeBytes = try? Array(Data(contentsOf: compareFile)),
              let commitSnapshot = try? CommitSnapshot(
                  repositoryURL: root,
                  revision: previousRevision
              ),
              let commitBytes = try? commitSnapshot.readBytes(
                  path: compareRelativeFile
              ),
              worktreeBytes != commitBytes
        else {
            finish("compare fixture or HEAD~1 diff unavailable")
        }
        controller.openFileForSelfTest(compareFile)
        guard await pythonWait(timeout: 30, {
            pythonModel.selectedFile?.standardizedFileURL
                == compareFile.standardizedFileURL
                && controller.displayedReaderFile?.standardizedFileURL
                    == compareFile.standardizedFileURL
        }) else {
            finish("compare main reader did not open")
        }
        controller.applyPanelPreset(.compare)
        guard controller.selectCompareCommit(previousRevision) else {
            finish("compare commit picker did not select")
        }
        guard await pythonWait(timeout: 60, {
            pythonModel.compare.diff != nil
                && pythonModel.compare.diff?.hunks.isEmpty == false
                && pythonModel.compare.diff?.truncated == false
                && pythonModel.compare.rightRevision == previousRevision
                && controller.selfTestRightReaderBytes != nil
        }) else {
            finish("compare HEAD~1 did not finish")
        }
        let rightBytes = controller.selfTestRightReaderBytes ?? []
        let rightReaderMatchesCommit = rightBytes == commitBytes
        let rightReaderDiffersFromWorktree = rightBytes != worktreeBytes
        guard rightReaderMatchesCommit, rightReaderDiffersFromWorktree else {
            finish("compare right reader mismatch")
        }
        Self.writeJSON([
            "step": "compare",
            "diffHunks": pythonModel.compare.diff?.hunks.count ?? 0,
            "truncated": pythonModel.compare.diff?.truncated ?? true,
            "rightReaderMatchesCommit": rightReaderMatchesCommit,
            "rightReaderDiffersFromWorktree": rightReaderDiffersFromWorktree,
            "elapsedMS": milliseconds(since: startedAt),
        ])

        pythonModel.switchToCommit(previousRevision)
        guard await pythonWait(timeout: 120, {
            pythonModel.snapshotPhase == .fullReady
                && pythonModel.currentRevision != nil
                && pythonModel.exactCoordinator.readiness == .ready
                && pythonReady()
        }) else {
            finish("switchToCommit did not finish Python")
        }
        let commitStats = if case let .ready(s, _) = pythonModel.projectState {
            s.stats
        } else {
            coldStats
        }
        guard let source = pythonModel.documentSource,
              let expectedConfigBytes = try? commitSnapshot.readBytes(path: configPath),
              let actualConfigBytes = try? source(configFile),
              actualConfigBytes == expectedConfigBytes,
              pythonModel.fileTree?.selectionPath(for: configFile) != nil,
              controller.selectFileInSidebar(configFile),
              await pythonWait(timeout: 30, {
                  controller.displayedReaderFile?.standardizedFileURL == configFile
                      && controller.selfTestReaderPreviewKind == "Plain text"
                      && controller.selfTestReaderPreviewText == String(decoding: expectedConfigBytes, as: UTF8.self)
                      && pythonModel.tabStrip.activeDocument == nil
              })
        else { finish("Python configuration preview did not match HEAD~1") }
        pythonModel.switchToWorktree()
        guard await pythonWait(timeout: 120, {
            pythonModel.currentRevision == nil
                && pythonModel.snapshotPhase == .fullReady
                && pythonModel.exactCoordinator.readiness == .ready
                && pythonReady()
        }) else {
            finish("switchToWorktree did not finish Python")
        }
        let worktreeStats = if case let .ready(s, _) = pythonModel.projectState {
            s.stats
        } else {
            coldStats
        }
        Self.writeJSON([
            "step": "switch",
            "commitReused": commitStats.reusedCount,
            "commitExtracted": commitStats.extractedCount,
            "worktreeReused": worktreeStats.reusedCount,
            "worktreeExtracted": worktreeStats.extractedCount,
            "elapsedMS": milliseconds(since: startedAt),
        ])

        controller.checkpointSessionSynchronously()
        guard let session = pythonModel.loadSessionSnapshot(
            forProject: root
        ).snapshot,
              session.language == .python
        else {
            finish("session checkpoint language not Python")
        }
        pythonRecentStore.record(root, language: .python)
        controller.openRecentProject(root, forcingReopen: true)
        guard await pythonWait(timeout: 120, {
            pythonModel.snapshotPhase == .fullReady
                && pythonReady()
        }) else {
            finish("recent reopen did not finish Python")
        }
        let hotStats = if case let .ready(s, _) = pythonModel.projectState {
            s.stats
        } else {
            coldStats
        }
        guard hotStats.reusedCount > 0 else {
            finish("recent reopen did not reuse cache")
        }
        Self.writeJSON([
            "step": "hot-recent",
            "fileCount": pythonModel.fileTree?.fileCount ?? 0,
            "reused": hotStats.reusedCount,
            "extracted": hotStats.extractedCount,
            "elapsedMS": milliseconds(since: startedAt),
        ])

        let generationBeforeRestore = pythonModel.generation
        controller.restoreSession(session)
        guard await pythonWait(timeout: 120, {
            pythonModel.generation != generationBeforeRestore
                && pythonModel.snapshotPhase == .fullReady
                && pythonModel.exactCoordinator.readiness == .ready
                && pythonReady()
        }) else {
            finish("session restore did not finish Python")
        }
        pythonRecentStore.clear()

        let checks = [
            "treeMatchesSnapshot": treeMatchesSnapshot,
            "sourceFileCountMatchesCorpus": sourceFiles.count == 204,
            "semanticIndexOnlyPython": semanticIndexOnlyPython,
            "configurationPreviewMatchesWorktree": true,
            "configurationPreviewMatchesCommit": true,
            "contentSearchMemory": true,
            "symbolSearchMemory": true,
            "readerOutlineReady": outlineCount > 0,
            "localReferencesReady": localReferenceCount > 0,
            "styledFragmentsReady": styledFragments > 0,
            "foldRegionsReady": foldRegions > 0,
            "fuzzyContextSymbol": true,
            "localRelationLoaded": localRelationLoaded,
            "exactDefinition": true,
            "exactReferences": exactReferences,
            "exactCallHierarchy": callHierarchyExact,
            "implementationsUnsupported": implementationsUnsupported,
            "localReferencesAfterUnsupported": localReferencesAfterUnsupported,
            "exactReferencesAfterUnsupported": exactReferencesAfterUnsupported,
            "compareHunksNonempty": true,
            "compareRightDiffers": rightReaderDiffersFromWorktree,
            "switchToCommitPython": true,
            "switchToWorktreePython": true,
            "recentReopenPython": true,
            "sessionRestorePython": true,
        ]
        finishPythonSelfTest(
            coldFileCount: fileCount,
            coldReused: coldStats.reusedCount,
            coldExtracted: coldStats.extractedCount,
            hotFileCount: pythonModel.fileTree?.fileCount ?? 0,
            hotReused: hotStats.reusedCount,
            hotExtracted: hotStats.extractedCount,
            checks: checks,
            startedAt: startedAt
        )
    }

    func runTypeScriptSelfTest(root inputRoot: URL) async -> Never {
        launch(offscreen: true, measuresIdleFootprint: false)
        let startedAt = ContinuousClock.now
        let root = inputRoot.standardizedFileURL
        let tsxFile = root.appendingPathComponent(
            "components/search-results-image.tsx"
        ).standardizedFileURL
        let tsFile = root.appendingPathComponent("lib/utils/index.ts")
            .standardizedFileURL
        let tsRelative = "lib/utils/index.ts"
        let tsxRelative = "components/search-results-image.tsx"
        let tsModel = self.model
        let tsRecentStore = self.recentProjectsStore

        func tsReady() -> Bool {
            if case let .ready(session, _) = tsModel.projectState {
                return session.analysisProfile.language == .typescript
            }
            return false
        }
        func finish(_ error: String) -> Never {
            finishTypeScriptSelfTest(
                error: error,
                startedAt: startedAt
            )
        }
        func tsWait(
            timeout: TimeInterval,
            _ condition: @escaping () -> Bool
        ) async -> Bool {
            let deadline = Date(timeIntervalSinceNow: timeout)
            while Date() < deadline {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return condition()
        }

        guard let controller = windowController else {
            finish("window unavailable")
        }
        guard previousCommitRevision(root: root) != nil else {
            finish("HEAD~1 unavailable")
        }

        controller.openProject(root: root, language: .typescript)
        guard await tsWait(timeout: 180, {
            if case .failed = tsModel.projectState { return true }
            if case .ready = tsModel.projectState {
                return tsModel.fileTree != nil
                    && !tsModel.commitPicker.isLoading
                    && tsModel.snapshotPhase == .fullReady
                    && tsReady()
            }
            return false
        }), case let .ready(session, context) = tsModel.projectState,
              tsModel.snapshotPhase == .fullReady,
              tsModel.fileTree != nil,
              session.analysisProfile.language == .typescript,
              let previousRevision = tsModel.commitPicker.commits
                .dropFirst().first?.fullSHA
        else {
            finish("typescript project or HEAD~1 commit unavailable")
        }
        let coldSession = session
        let coldContext = context
        let coldStats = coldSession.stats
        let sourceFiles = coldSession.manifest.files.filter { $0.detectedLanguage == .typescript }
        let manifestFiles = sourceFiles.map {
            coldSession.paths.resolve($0.pathID)
        }.sorted()
        let semanticIndexOnlyTypeScript = coldSession.manifest.files.allSatisfy { file in
            let mode = LanguageMode.classify(
                path: coldSession.paths.resolve(file.pathID), language: .typescript
            )
            return file.detectedLanguage == mode?.language
                && coldSession.content(at: file.pathID)?.0.languageMode == mode
        } && coldSession.contentIndexes.keys.allSatisfy { $0.languageMode.language == .typescript }
        let treeFiles = pythonFiles(in: tsModel.fileTree?.children ?? [])
        let snapshotFiles = coldSession.manifest.files.filter {
            $0.fileMode == .regular || $0.fileMode == .lfsPointer
        }.map { root.appendingPathComponent(coldSession.paths.resolve($0.pathID)).standardizedFileURL }
        let treeMatchesSnapshot = Set(treeFiles) == Set(snapshotFiles)
        let tsCount = manifestFiles.filter { $0.hasSuffix(".ts") }.count
        let tsxCount = manifestFiles.filter { $0.hasSuffix(".tsx") }.count
        let manifestHasTsAndTsx = manifestFiles.contains(tsRelative)
            && manifestFiles.contains(tsxRelative)
        guard treeMatchesSnapshot, tsCount == 2, tsxCount == 51,
              manifestHasTsAndTsx, semanticIndexOnlyTypeScript
        else {
            finish("TypeScript workspace/index mismatch: tree=\(treeFiles.count) snapshot=\(snapshotFiles.count) ts=\(tsCount) tsx=\(tsxCount) semanticIndexOnlyTypeScript=\(semanticIndexOnlyTypeScript)")
        }
        let configPath = "package.json"
        let configFile = root.appendingPathComponent(configPath).standardizedFileURL
        guard let config = coldSession.manifest.files.first(where: {
                  coldSession.paths.resolve($0.pathID) == configPath
              }), config.detectedLanguage == nil,
              let configBytes = try? Array(Data(contentsOf: configFile)),
              ContentID.sha256(of: configBytes) == config.contentID,
              controller.selectFileInSidebar(configFile),
              await tsWait(timeout: 30, {
                  controller.displayedReaderFile?.standardizedFileURL == configFile
                      && controller.selfTestReaderPreviewKind == "Plain text"
                      && controller.selfTestReaderPreviewText == String(decoding: configBytes, as: UTF8.self)
                      && tsModel.tabStrip.activeDocument == nil
              })
        else { finish("TypeScript configuration preview did not match the worktree snapshot") }
        let profileUnit = coldSession.analysisProfile.projectUnitName
        Self.writeJSON([
            "step": "cold-open",
            "language": "typescript",
            "projectUnit": profileUnit,
            "tsCount": tsCount,
            "tsxCount": tsxCount,
            "fileCount": treeFiles.count,
            "sourceFileCount": sourceFiles.count,
            "treeMatchesSnapshot": treeMatchesSnapshot,
            "configurationPreview": configPath,
            "reused": coldStats.reusedCount,
            "extracted": coldStats.extractedCount,
            "snapshotPhase": tsModel.snapshotPhase?.rawValue as Any,
            "elapsedMS": milliseconds(since: startedAt),
        ])

        guard await tsWait(timeout: 90, {
            tsModel.exactCoordinator.readiness == .ready
        }), let attribution = tsModel.exactCoordinator.attribution
        else {
            finish("TypeScript provider missing/unready: "
                + "\(tsModel.exactCoordinator.readiness)")
        }

        var searchHitTSX = false
        do {
            let contentHits = try await contentSearchHits(
                session: coldSession,
                context: coldContext,
                query: ContentSearchQuery(
                    pattern: "SearchResultsImageSection",
                    caseSensitive: true
                )
            )
            let symbolHits = try coldSession.searchSymbols(
                query: "SearchResultsImageSection",
                limit: 20,
                boost: SearchBoost(),
                context: coldContext
            )
            guard contentHits.contains(where: {
                $0.hasSuffix(tsxRelative)
            }), symbolHits.contains(where: {
                $0.path.hasSuffix(tsxRelative)
            })
            else {
                finish("search did not hit search-results-image.tsx")
            }
            searchHitTSX = true
            Self.writeJSON([
                "step": "search",
                "contentHit": tsxRelative,
                "symbolHit": tsxRelative,
                "elapsedMS": milliseconds(since: startedAt),
            ])
        } catch {
            finish("search failed: \(error)")
        }

        for (label, file, mode) in [
            ("ts", tsFile, LanguageMode(language: .typescript)),
            ("tsx", tsxFile, LanguageMode(language: .typescript, variant: "tsx")),
        ] {
            guard controller.selectFileInSidebar(file),
                  await tsWait(timeout: 30, {
                      controller.displayedReaderFile?.standardizedFileURL
                          == file.standardizedFileURL
                          && tsModel.tabStrip.activeDocument != nil
                          && controller.selfTestStyledFragmentCount > 0
                  }),
                  let activeDocument = tsModel.tabStrip.activeDocument,
                  !activeDocument.outlineFacets.isEmpty,
                  !activeDocument.foldRegions.isEmpty,
                  activeDocument.languageMode == mode
            else {
                finish("Reader/outline/fold/mode unavailable for " + label)
            }
        }

        let activeDocument = tsModel.tabStrip.activeDocument
        let tsxModeExplicit = activeDocument?.languageMode.variant == "tsx"
        let outlineCount = activeDocument?.outlineFacets.count ?? 0
        let bindingCount = activeDocument?.localBindings.count ?? 0
        let localReferenceCount = activeDocument?.referencesByBinding
            .compactMap(\.count).reduce(0, +) ?? 0
        let foldRegions = activeDocument?.foldRegions.count ?? 0
        let styledFragments = controller.selfTestStyledFragmentCount
        guard tsxModeExplicit, outlineCount > 0, bindingCount > 0,
              localReferenceCount > 0, foldRegions > 0,
              styledFragments > 0
        else {
            finish("TSX Reader/outline/local reference unavailable")
        }
        let profileTitle = controller.selfTestProfileTitle
        let profileMenu = controller.selfTestProfileMenuTitles
        let profileMenuText = profileMenu.joined(separator: " ")
        let profileHasNoCargo = profileTitle.localizedCaseInsensitiveContains(
            "TypeScript"
        )
            && profileTitle.localizedCaseInsensitiveContains("tsconfig")
            && !profileTitle.localizedCaseInsensitiveContains("features")
            && !profileMenuText.localizedCaseInsensitiveContains(
                "features"
            )
            && !profileMenuText.localizedCaseInsensitiveContains(
                "edition"
            )
            && profileMenuText.contains("Trust This Repository")
        let tsxSource = (try? String(
            contentsOf: tsxFile,
            encoding: .utf8
        )) ?? ""
        let relativeFile = "components/chat.tsx"
        let relativeSource = (try? String(
            contentsOf: root.appendingPathComponent(relativeFile),
            encoding: .utf8
        )) ?? ""
        let relativeImportOffset: UInt32
        if let range = relativeSource.range(of: "import { ChatPanel }"),
           let tokenStart = relativeSource.range(
               of: "ChatPanel",
               range: range.lowerBound..<relativeSource.endIndex
           )?.lowerBound,
           let offset = UInt32(exactly: relativeSource.utf8.distance(
               from: relativeSource.utf8.startIndex,
               to: tokenStart
        ))
        {
            relativeImportOffset = offset
        } else {
            finish("relative import ChatPanel token offset unavailable")
        }
        let relativeResolutions = (try? coldSession.resolve(
            file: coldSession.paths.intern(relativeFile),
            offset: relativeImportOffset,
            context: coldContext
        )) ?? []
        let relativeCandidate = relativeResolutions.first
        let relativeTarget = relativeCandidate.map {
            coldSession.paths.resolve($0.target.pathID)
        }
        let fuzzyRelativeResolved =
            relativeTarget == "components/chat-panel.tsx"
            && relativeCandidate?.certainty == .probable
            && relativeCandidate?.completeness == .partial
        guard fuzzyRelativeResolved else {
            finish(
                "fuzzy-relative did not match frozen import binding contract: "
                    + "target=\(relativeTarget as Any)"
                    + " certainty=\(String(describing: relativeCandidate?.certainty))"
                    + " completeness=\(String(describing: relativeCandidate?.completeness))"
            )
        }
        Self.writeJSON([
            "step": "fuzzy-relative",
            "file": relativeFile,
            "offset": Int(relativeImportOffset),
            "resolved": fuzzyRelativeResolved,
            "target": relativeTarget as Any,
            "certainty": relativeResolutions.map { $0.certainty.rawValue },
            "elapsedMS": milliseconds(since: startedAt),
        ])

        let aliasImportOffset: UInt32
        if let range = tsxSource.range(of: "Card"),
           let offset = UInt32(exactly: tsxSource.utf8.distance(
               from: tsxSource.utf8.startIndex,
               to: range.lowerBound
           ))
        {
            aliasImportOffset = offset
        } else {
            finish("alias import offset unavailable")
        }
        let aliasResolutions = (try? coldSession.resolve(
            file: coldSession.paths.intern(tsxRelative),
            offset: aliasImportOffset,
            context: coldContext
        )) ?? []
        let fuzzyAliasUnresolved = aliasResolutions.isEmpty
            || aliasResolutions.allSatisfy {
                $0.certainty == .unresolved
            }
        let exactCardDefinitions = await tsModel.exactCoordinator.definition(
            file: tsxRelative,
            byteOffset: aliasImportOffset,
            generation: coldContext.generation
        )
        let exactCardResolved = if case .completed(let entries) =
            exactCardDefinitions
        {
            !entries.isEmpty && entries.contains {
                $0.location.file.hasSuffix("components/ui/card.tsx")
            }
        } else {
            false
        }
        let attributionMatches = attribution.provider
            == "typescript-language-server"
        Self.writeJSON([
            "step": "alias",
            "file": tsxRelative,
            "offset": Int(aliasImportOffset),
            "fuzzyUnresolved": fuzzyAliasUnresolved,
            "exactCardResolved": exactCardResolved,
            "provider": attribution.provider,
            "elapsedMS": milliseconds(since: startedAt),
        ])
        guard fuzzyAliasUnresolved, exactCardResolved, attributionMatches else {
            finish("alias fuzzy should stay unresolved, exact Card must resolve, provider must be typescript-language-server")
        }

        guard let sectionSymbol = (
            try? coldSession.searchSymbols(
                query: "SearchResultsImageSection",
                limit: 20,
                boost: SearchBoost(),
                context: coldContext
            ).first(where: {
                $0.path.hasSuffix("components/search-results-image.tsx")
            })?.occurrence
        ) else {
            finish("SearchResultsImageSection symbol unavailable")
        }
        await tsModel.relationTree.setRoot(
            target: .engine(sectionSymbol),
            direction: .references
        )?.value
        var exactReferences = false
        let refsDeadline = Date(timeIntervalSinceNow: 60)
        while Date() < refsDeadline {
            if let root = tsModel.relationTree.root,
               !(root.children?.contains { $0.kind == .loading } ?? true)
            {
                exactReferences = !exactRelationEdges(in: tsModel).isEmpty
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        if exactReferences == false {
            exactReferences = !exactRelationEdges(in: tsModel).isEmpty
        }
        guard exactReferences else {
            finish("TypeScript references unavailable")
        }
        Self.writeJSON([
            "step": "real-typescript-exact",
            "provider": attribution.provider,
            "toolVersion": attribution.toolVersion,
            "definitionTargets": exactCardDefinitions.map {
                if case .completed(let entries) = $0 {
                    return entries.count
                }
                return 0
            } ?? 0,
            "exactReferences": exactReferences,
            "elapsedMS": milliseconds(since: startedAt),
        ])

        let compareFile = tsxFile
        guard let worktreeBytes = try? Array(Data(contentsOf: compareFile)),
              let commitSnapshot = try? CommitSnapshot(
                  repositoryURL: root,
                  revision: previousRevision
              ),
              let commitBytes = try? commitSnapshot.readBytes(
                  path: tsxRelative
              ),
              worktreeBytes != commitBytes
        else {
            finish("compare fixture or HEAD~1 diff unavailable")
        }
        controller.openFileForSelfTest(compareFile)
        guard await tsWait(timeout: 30, {
            tsModel.selectedFile?.standardizedFileURL
                == compareFile.standardizedFileURL
                && controller.displayedReaderFile?.standardizedFileURL
                    == compareFile.standardizedFileURL
        }) else {
            finish("compare main reader did not open")
        }
        controller.applyPanelPreset(.compare)
        guard controller.selectCompareCommit(previousRevision) else {
            finish("compare commit picker did not select")
        }
        guard await tsWait(timeout: 60, {
            tsModel.compare.diff != nil
                && tsModel.compare.diff?.hunks.isEmpty == false
                && tsModel.compare.diff?.truncated == false
                && tsModel.compare.rightRevision == previousRevision
                && controller.selfTestRightReaderBytes != nil
        }) else {
            finish("compare HEAD~1 did not finish")
        }
        let rightBytes = controller.selfTestRightReaderBytes ?? []
        let compareRightMatchesCommit = rightBytes == commitBytes
        let compareRightDiffersFromWorktree = rightBytes != worktreeBytes
        let compareHunksNonempty =
            (tsModel.compare.diff?.hunks.isEmpty == false)
        guard compareRightMatchesCommit, compareRightDiffersFromWorktree else {
            finish("compare right reader mismatch")
        }
        Self.writeJSON([
            "step": "compare",
            "diffHunks": tsModel.compare.diff?.hunks.count ?? 0,
            "truncated": tsModel.compare.diff?.truncated ?? true,
            "rightReaderMatchesCommit": compareRightMatchesCommit,
            "rightReaderDiffersFromWorktree": compareRightDiffersFromWorktree,
            "elapsedMS": milliseconds(since: startedAt),
        ])

        var switchToCommitTypeScript = false
        tsModel.switchToCommit(previousRevision)
        guard await tsWait(timeout: 180, {
            tsModel.snapshotPhase == .fullReady
                && tsModel.currentRevision != nil
                && tsModel.exactCoordinator.readiness == .ready
                && tsReady()
        }) else {
            finish("switchToCommit did not finish TypeScript")
        }
        switchToCommitTypeScript = true
        let commitStats = if case let .ready(s, _) = tsModel.projectState {
            s.stats
        } else {
            coldStats
        }
        guard let source = tsModel.documentSource,
              let expectedConfigBytes = try? commitSnapshot.readBytes(path: configPath),
              let actualConfigBytes = try? source(configFile),
              actualConfigBytes == expectedConfigBytes,
              tsModel.fileTree?.selectionPath(for: configFile) != nil,
              controller.selectFileInSidebar(configFile),
              await tsWait(timeout: 30, {
                  controller.displayedReaderFile?.standardizedFileURL == configFile
                      && controller.selfTestReaderPreviewKind == "Plain text"
                      && controller.selfTestReaderPreviewText == String(decoding: expectedConfigBytes, as: UTF8.self)
                      && tsModel.tabStrip.activeDocument == nil
              })
        else { finish("TypeScript configuration preview did not match HEAD~1") }
        var switchToWorktreeTypeScript = false
        tsModel.switchToWorktree()
        guard await tsWait(timeout: 180, {
            tsModel.currentRevision == nil
                && tsModel.snapshotPhase == .fullReady
                && tsModel.exactCoordinator.readiness == .ready
                && tsReady()
        }) else {
            finish("switchToWorktree did not finish TypeScript")
        }
        switchToWorktreeTypeScript = true
        let worktreeStats = if case let .ready(s, _) = tsModel.projectState {
            s.stats
        } else {
            coldStats
        }
        Self.writeJSON([
            "step": "switch",
            "commitReused": commitStats.reusedCount,
            "commitExtracted": commitStats.extractedCount,
            "worktreeReused": worktreeStats.reusedCount,
            "worktreeExtracted": worktreeStats.extractedCount,
            "elapsedMS": milliseconds(since: startedAt),
        ])

        var retryReopenTypeScript = false
        controller.retryLastOpenedProject()
        guard await tsWait(timeout: 180, {
            tsModel.snapshotPhase == .fullReady
                && tsModel.exactCoordinator.readiness == .ready
                && tsReady()
        }) else {
            finish("retry reopen did not finish TypeScript")
        }
        let retryStats = if case let .ready(s, _) = tsModel.projectState {
            s.stats
        } else {
            coldStats
        }
        retryReopenTypeScript = true
        Self.writeJSON([
            "step": "retry-reopen",
            "fileCount": tsModel.fileTree?.fileCount ?? 0,
            "reused": retryStats.reusedCount,
            "extracted": retryStats.extractedCount,
            "elapsedMS": milliseconds(since: startedAt),
        ])

        controller.checkpointSessionSynchronously()
        guard let persisted = tsModel.loadSessionSnapshot(
            forProject: root
        ).snapshot,
              persisted.language == .typescript
        else {
            finish("session checkpoint language not TypeScript")
        }
        tsRecentStore.record(root, language: .typescript)
        var recentReopenTypeScript = false
        controller.openRecentProject(root, forcingReopen: true)
        guard await tsWait(timeout: 180, {
            tsModel.snapshotPhase == .fullReady
                && tsModel.exactCoordinator.readiness == .ready
                && tsReady()
        }) else {
            finish("recent reopen did not finish TypeScript")
        }
        recentReopenTypeScript = true
        let hotStats = if case let .ready(s, _) = tsModel.projectState {
            s.stats
        } else {
            coldStats
        }
        guard hotStats.reusedCount > 0 else {
            finish("recent reopen did not reuse cache")
        }
        Self.writeJSON([
            "step": "hot-recent",
            "fileCount": tsModel.fileTree?.fileCount ?? 0,
            "reused": hotStats.reusedCount,
            "extracted": hotStats.extractedCount,
            "elapsedMS": milliseconds(since: startedAt),
        ])

        let generationBeforeRestore = tsModel.generation
        var sessionRestoreTypeScript = false
        controller.restoreSession(persisted)
        guard await tsWait(timeout: 180, {
            tsModel.generation != generationBeforeRestore
                && tsModel.snapshotPhase == .fullReady
                && tsModel.exactCoordinator.readiness == .ready
                && tsReady()
        }) else {
            finish("session restore did not finish TypeScript")
        }
        sessionRestoreTypeScript = true
        tsRecentStore.clear()

        let checks = [
            "treeMatchesSnapshot": treeMatchesSnapshot,
            "treeHasTsAndTsx": tsCount == 2 && tsxCount == 51,
            "manifestHasTsAndTsx": manifestHasTsAndTsx,
            "semanticIndexOnlyTypeScript": semanticIndexOnlyTypeScript,
            "configurationPreviewMatchesWorktree": true,
            "configurationPreviewMatchesCommit": true,
            "searchHitTSX": searchHitTSX,
            "profileUnitTSConfig": profileUnit == "tsconfig.json",
            "profileHasNoCargo": profileHasNoCargo,
            "coldReusedZero": coldStats.reusedCount == 0,
            "coldExtractedPositive": coldStats.extractedCount > 0,
            "tsxReaderExplicitMode": tsxModeExplicit,
            "readerOutlineReady": outlineCount > 0,
            "localReferencesReady": localReferenceCount > 0,
            "styledFragmentsReady": styledFragments > 0,
            "foldRegionsReady": foldRegions > 0,
            "fuzzyRelativeResolved": fuzzyRelativeResolved,
            "fuzzyAliasUnresolved": fuzzyAliasUnresolved,
            "exactCardDefinition": exactCardResolved,
            "exactReferences": exactReferences,
            "providerMatchesTypeScriptLanguageServer": attributionMatches,
            "compareHunksNonempty": compareHunksNonempty,
            "compareRightMatchesCommit": compareRightMatchesCommit,
            "compareRightDiffers": compareRightDiffersFromWorktree,
            "switchToCommitTypeScript": switchToCommitTypeScript,
            "switchToWorktreeTypeScript": switchToWorktreeTypeScript,
            "retryReopenTypeScript": retryReopenTypeScript,
            "recentReopenTypeScript": recentReopenTypeScript,
            "hotReusedPositive": hotStats.reusedCount > 0,
            "sessionRestoreTypeScript": sessionRestoreTypeScript,
        ]
        finishTypeScriptSelfTest(
            coldFileCount: treeFiles.count,
            coldReused: coldStats.reusedCount,
            coldExtracted: coldStats.extractedCount,
            hotFileCount: tsModel.fileTree?.fileCount ?? 0,
            hotReused: hotStats.reusedCount,
            hotExtracted: hotStats.extractedCount,
            checks: checks,
            startedAt: startedAt
        )
    }

    func runMixedSelfTest(root inputRoot: URL) async -> Never {
        let startedAt = ContinuousClock.now
        let root = inputRoot.standardizedFileURL
        func finish(_ error: String) -> Never {
            Self.writeJSON([
                "step": "summary",
                "channel": "mixed",
                "passed": false,
                "error": error,
                "elapsedMS": milliseconds(since: startedAt),
            ])
            Self.exitSelfTest(channel: "mixed", status: 1)
        }
        func git(_ arguments: [String]) throws -> String {
            let process = Process()
            let standardOutput = Pipe()
            let standardError = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root.path] + arguments
            process.standardOutput = standardOutput
            process.standardError = standardError
            try process.run()
            process.waitUntilExit()
            let data = standardOutput.fileHandleForReading.readDataToEndOfFile()
            let errorData = standardError.fileHandleForReading
                .readDataToEndOfFile()
            guard process.terminationStatus == 0
            else {
                throw CocoaError(.fileReadUnknown, userInfo: [
                    NSLocalizedFailureReasonErrorKey:
                        "git \(arguments.joined(separator: " ")) failed ("
                        + "\(process.terminationStatus)): "
                        + String(decoding: errorData, as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        + " "
                        + String(decoding: data, as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                ])
            }
            return String(decoding: data, as: UTF8.self)
        }

        let fixedCommit = "457b66e72da1967c2432131a7ff8adc4341eb337"
        let expectedConfigHashes: [String: String] = [
            "pyproject.toml":
                "0c48694c3cc9668d7e062a03e98ab41d53a5b68a7500bd977da826e5f01273e6",
            "uv.lock":
                "562ebad06578ceca1bbcd1888942fcb8bf001340dbd63ce6c4d5737c144dbe4c",
            "crates/qrcode2txt/Cargo.toml":
                "e0079b229039a8a02b440878c4235f6ac05a0c5e6db71b6cf61fcf28eee947a2",
            "tools/model-files-web/tsconfig.json":
                "770b4140bbb581e2dfd9ea9946ffc9c75a1d86ba7d2db5f77c83e37cbdf9d808",
            "tools/model-files-web/package.json":
                "798565f0dc3bcb30375457bd8e003d7c30b14679f0e79bc6a1c50ddd0d63eb6c",
            "tools/model-files-web/package-lock.json":
                "8373619bda0840fb24893976201504404cd0fde71f61621057b529dfc1719d31",
        ]
        do {
            let head = try git(["rev-parse", "HEAD"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard head == fixedCommit else {
                finish("mixed HEAD \(head) != fixed \(fixedCommit)")
            }
            let status = try git([
                "status",
                "--porcelain=v1",
                "--untracked-files=all",
                "--ignored=matching",
            ])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard status.isEmpty else {
                finish("mixed git worktree is not clean")
            }
            let listed = try git(["ls-files"])
                .split(separator: "\n").map(String.init)
            let rustFiles = listed.filter { $0.hasSuffix(".rs") }
            let pythonFiles = listed.filter {
                $0.hasSuffix(".py") && !$0.hasSuffix(".pyi")
            }
            let dtsFiles = listed.filter { $0.hasSuffix(".d.ts") }
            let tsFiles = listed.filter {
                $0.hasSuffix(".ts")
                    && !$0.hasSuffix(".d.ts")
                    && !$0.hasSuffix(".mts")
                    && !$0.hasSuffix(".cts")
            }
            let tsxFiles = listed.filter { $0.hasSuffix(".tsx") }
            let jsFiles = listed.filter {
                $0.hasSuffix(".js") || $0.hasSuffix(".jsx")
            }
            guard rustFiles.count == 11,
                  pythonFiles.count == 8,
                  tsFiles.count == 22,
                  tsxFiles.count == 4,
                  dtsFiles.count == 1,
                  jsFiles.isEmpty
            else {
                finish("preflight counts rust=\(rustFiles.count) "
                    + "python=\(pythonFiles.count) ts=\(tsFiles.count) "
                    + "tsx=\(tsxFiles.count) dts=\(dtsFiles.count) "
                    + "js=\(jsFiles.count) mismatch")
            }
            for (path, hash) in expectedConfigHashes {
                guard listed.contains(path),
                      let data = try? Data(contentsOf: root.appendingPathComponent(path)),
                      ContentID.sha256(of: data).bytes
                        .map({ String(format: "%02x", $0) }).joined() == hash
                else {
                    finish("preflight config hash mismatch \(path)")
                }
            }
        } catch {
            finish("mixed git preflight failed: \(error)")
        }

        launch(offscreen: true, measuresIdleFootprint: false)
        guard let controller = windowController else {
            finish("window unavailable")
        }
        controller.openProject(
            root: root,
            languages: [.rust, .python, .typescript]
        )

        var sawFirstPaint = false
        let deadline = Date(timeIntervalSinceNow: 30)
        while Date() < deadline {
            if model.snapshotPhase == .firstPaint {
                sawFirstPaint = true
            }
            if model.snapshotPhase == .fullReady,
               model.querySessions.count == 3
            {
                break
            }
            if case .failed = model.projectState {
                finish("mixed project failed during cold open")
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard sawFirstPaint,
              model.snapshotPhase == .fullReady,
              model.projectLanguages == [.rust, .python, .typescript],
              model.querySessions.count == 3,
              model.fileTree?.root.standardizedFileURL == root
        else {
            finish("mixed cold open did not reach firstPaint/fullReady")
        }

        let sessions = model.querySessions
        var sessionOutputs: [[String: Any]] = []
        var rustCount = 0
        var pythonCount = 0
        var tsCount = 0
        var tsxCount = 0
        var dtsCount = 0
        var snapshotIDs = Set<SnapshotID>()

        for (session, _) in sessions {
            let paths = session.manifest.files.map {
                session.paths.resolve($0.pathID)
            }
            let language = session.analysisProfile.language
            let languagePaths = paths.filter {
                LanguageMode.classify(
                    path: $0,
                    language: language
                ) != nil
            }
            snapshotIDs.insert(session.snapshotID)
            for path in languagePaths {
                if path.hasSuffix(".rs") {
                    rustCount += 1
                } else if path.hasSuffix(".py"), !path.hasSuffix(".pyi") {
                    pythonCount += 1
                } else if path.hasSuffix(".d.ts") {
                    dtsCount += 1
                } else if path.hasSuffix(".tsx") {
                    tsxCount += 1
                } else if path.hasSuffix(".ts") {
                    tsCount += 1
                }
            }
            sessionOutputs.append([
                "language": session.analysisProfile.language.rawValue,
                "files": languagePaths.count,
                "extracted": session.stats.extractedCount,
                "reused": session.stats.reusedCount,
                "profileRoot": session.paths.resolve(
                    session.analysisProfile.projectRoot
                ),
            ])
        }
        guard sessions.contains(where: {
            $0.0.analysisProfile.language == .rust
                && $0.0.paths.resolve($0.0.analysisProfile.projectRoot)
                    == "crates/qrcode2txt"
        }), sessions.contains(where: {
            $0.0.analysisProfile.language == .python
                && $0.0.paths.resolve($0.0.analysisProfile.projectRoot) == "."
        }), sessions.contains(where: {
            $0.0.analysisProfile.language == .typescript
                && $0.0.paths.resolve($0.0.analysisProfile.projectRoot)
                    == "tools/model-files-web"
        }) else {
            finish("mixed profile roots do not match fixed corpus")
        }
        guard snapshotIDs.count == 1 else {
            finish("mixed sessions do not share one snapshot")
        }
        guard rustCount == 11,
              pythonCount == 8,
              tsCount == 22,
              tsxCount == 4,
              dtsCount == 0
        else {
            finish("mixed counts rust=\(rustCount) python=\(pythonCount) "
                + "ts=\(tsCount) tsx=\(tsxCount) d.ts=\(dtsCount) mismatch")
        }

        Self.writeJSON([
            "step": "MIXED_SELF_TEST_COLD",
            "channel": "mixed",
            "passed": true,
            "commit": fixedCommit,
            "languages": [0, 1, 2],
            "root": root.path,
            "sessionSnapshot": snapshotIDs.first!.rawValue.uuidString,
            "treeFileCount": model.fileTree?.fileCount as Any,
            "counts": [
                "rust": rustCount,
                "python": pythonCount,
                "ts": tsCount,
                "tsx": tsxCount,
                "dts": dtsCount,
            ],
            "sessions": sessionOutputs,
            "elapsedMS": milliseconds(since: startedAt),
        ])

        var searchContentPaths: [String: [String]] = [:]
        var searchSymbolPaths: [String: [String]] = [:]
        var contentLanguageCounts: [String: Int] = [:]
        var symbolLanguageCounts: [String: Int] = [:]
        for (session, context) in sessions {
            let language = session.analysisProfile.language
            let languageKey = String(describing: language)
            do {
                let contentHits = try await contentSearchHits(
                    session: session,
                    context: context,
                    query: ContentSearchQuery(
                        pattern: "main",
                        caseSensitive: false
                    )
                )
                let contentLanguagePaths = contentHits.filter {
                    LanguageMode.classify(path: $0, language: language) != nil
                }
                contentLanguageCounts[languageKey, default: 0] +=
                    contentLanguagePaths.count
                searchContentPaths[languageKey] =
                    (searchContentPaths[languageKey] ?? [])
                        + contentLanguagePaths
            } catch {
                finish("mixed content search failed for \(languageKey): \(error)")
            }
            do {
                let symbolHits = try session.searchSymbols(
                    query: "main",
                    limit: 50,
                    boost: SearchBoost(),
                    context: context
                )
                let languageSymbols = symbolHits.map(\.path)
                symbolLanguageCounts[languageKey, default: 0] +=
                    languageSymbols.count
                searchSymbolPaths[languageKey] =
                    (searchSymbolPaths[languageKey] ?? [])
                    + languageSymbols
            } catch {
                finish("mixed symbol search failed for \(languageKey): \(error)")
            }
        }
        guard contentLanguageCounts.values.filter({ $0 > 0 }).count >= 2,
              symbolLanguageCounts.values.filter({ $0 > 0 }).count >= 2
        else {
            finish("mixed search did not cover at least two languages")
        }
        Self.writeJSON([
            "step": "MIXED_SELF_TEST_SEARCH",
            "channel": "mixed",
            "passed": true,
            "languageContentMatches": contentLanguageCounts,
            "languageSymbolMatches": symbolLanguageCounts,
            "contentPaths": searchContentPaths.mapValues {
                Array(Set($0)).sorted()
            },
            "symbolPaths": searchSymbolPaths.mapValues {
                Array(Set($0)).sorted()
            },
            "elapsedMS": milliseconds(since: startedAt),
        ])

        let readerCases: [
            (LanguageID, String, LanguageMode, String?, Bool, Int)
        ] = [
            (.rust,
                "crates/qrcode2txt/src/lib.rs",
                LanguageMode(language: .rust),
                "from_results",
                false,
                1),
            (.python,
                "src/tools/analysis/analysis.py",
                LanguageMode(language: .python),
                "get_top_tokens",
                false,
                1),
            (.typescript,
                "tools/model-files-web/src/core/tokenizer.ts",
                LanguageMode(language: .typescript),
                "isRecord",
                false,
                1),
            (.typescript,
                "tools/model-files-web/src/App.tsx",
                LanguageMode(language: .typescript, variant: "tsx"),
                "loadRepository",
                true,
                0),
        ]
        var readerOutputs: [[String: Any]] = []
        for item in readerCases {
            let language = item.0
            let path = item.1
            let mode = item.2
            let needle = item.3
            let allowNoRelation = item.4
            let needleIndex = item.5
            let file = root.appendingPathComponent(path)
                .standardizedFileURL
            controller.openFileForSelfTest(file)
            let readerDeadline = Date(timeIntervalSinceNow: 60)
            var readerReady = false
            while Date() < readerDeadline {
                if case let .ready(session, _) = model.projectState,
                   session.analysisProfile.language == language,
                   controller.displayedReaderFile?.standardizedFileURL
                    == file.standardizedFileURL,
                   let document = model.tabStrip.activeDocument,
                   document.languageMode == mode,
                   controller.selfTestStyledFragmentCount > 0,
                   !document.outlineFacets.isEmpty,
                   !document.foldRegions.isEmpty
                {
                    readerReady = true
                    break
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
            guard readerReady else {
                finish("mixed reader did not ready \(path)")
            }
            guard let document = model.tabStrip.activeDocument else {
                finish("mixed reader document unavailable \(path)")
            }
            var output: [String: Any] = [
                "path": path,
                "mode": mode.variant ?? "base",
                "styled": controller.selfTestStyledFragmentCount,
                "outline": document.outlineFacets.count,
                "folds": document.foldRegions.count,
                "activeLanguage": String(describing: language),
            ]
            var relationCount = 0
            var contextResolved = false
            let previousRelationRoot = model.relationTree.root
            if let needle,
               let bytes = controller.selfTestLeftReaderBytes
            {
                let offsets = utf8Offsets(of: needle, in: bytes)
                    .dropFirst(needleIndex)
                if let offset = offsets.first.map(UInt32.init) {
                    let candidate = await model.contextWindow.resolvedCandidate(
                        file: path,
                        offset: offset
                    )
                    contextResolved = candidate != nil
                    if candidate != nil {
                        controller.selfTestReaderRelation(
                            offset: offset,
                            direction: .references
                        )
                        let relationDeadline = Date(timeIntervalSinceNow: 60)
                        var capturedRoot: RelationTreeModel.Node?
                        while Date() < relationDeadline {
                            if let root = model.relationTree.root,
                               root !== previousRelationRoot,
                               !(root.children?.contains {
                                   $0.kind == .loading
                               } ?? true)
                            {
                                capturedRoot = root
                                break
                            }
                            try? await Task.sleep(for: .milliseconds(10))
                        }
                        let edges = capturedRoot.map {
                            relationEdgeNodes(in: $0)
                        } ?? []
                        let foreign = edges.filter { edge in
                            guard let target = edge.target else { return true }
                            let mode = LanguageMode.classify(
                                path: target.path,
                                languages: [language]
                            )
                            return mode?.language != language
                        }
                        guard foreign.isEmpty && !edges.isEmpty else {
                            finish("mixed relation foreign for \(path)")
                        }
                        relationCount = edges.count
                    }
                }
            }
            if !contextResolved && !allowNoRelation {
                finish("mixed context did not resolve \(path)")
            }
            output["context"] = contextResolved
            output["relationEdges"] = relationCount
            readerOutputs.append(output)
        }
        Self.writeJSON([
            "step": "MIXED_SELF_TEST_READER",
            "channel": "mixed",
            "passed": true,
            "readers": readerOutputs,
            "elapsedMS": milliseconds(since: startedAt),
        ])

        let exactCases: [
            (LanguageID, String, String, Int, String)
        ] = [
            (
                .rust,
                "crates/qrcode2txt/src/lib.rs",
                "from_results",
                1,
                "rust-analyzer"
            ),
            (
                .python,
                "src/tools/analysis/analysis.py",
                "get_top_tokens",
                1,
                "pyright"
            ),
            (
                .typescript,
                "tools/model-files-web/src/core/tokenizer.ts",
                "inspectTokenizerStructure",
                0,
                "typescript-language-server"
            ),
        ]
        var exactOutputs: [[String: Any]] = []
        for item in exactCases {
            let language = item.0
            let path = item.1
            let needle = item.2
            let needleIndex = item.3
            let provider = item.4
            let file = root.appendingPathComponent(path).standardizedFileURL
            controller.openFileForSelfTest(file)
            let exactReadyStarted = ContinuousClock.now
            let exactReadyDeadline = Date(timeIntervalSinceNow: 30)
            while Date() < exactReadyDeadline {
                if model.exactCoordinator.readiness == .ready,
                   model.exactCoordinator.attribution?.provider == provider,
                   case let .ready(session, _) = model.projectState,
                   session.analysisProfile.language == language,
                   controller.displayedReaderFile?.standardizedFileURL == file
                {
                    break
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard model.exactCoordinator.readiness == .ready,
                  let attribution = model.exactCoordinator.attribution,
                  attribution.provider == provider,
                  case let .ready(session, context) = model.projectState,
                  session.analysisProfile.language == language,
                  controller.displayedReaderFile?.standardizedFileURL == file,
                  controller.selfTestLeftReaderBytes != nil
            else {
                finish("mixed exact \(provider) not ready for \(path): "
                    + "\(String(describing: model.exactCoordinator.readiness))"
                    + " attribution=\(String(describing: model.exactCoordinator.attribution?.provider))"
                )
            }
            let readyMS = milliseconds(since: exactReadyStarted)
            guard let bytes = try? Data(contentsOf: file) else {
                finish("mixed exact file missing \(path)")
            }
            let offsets = utf8Offsets(of: needle, in: Array(bytes))
                .dropFirst(needleIndex)
            guard let offset = offsets.first.map(UInt32.init) else {
                finish("mixed exact needle unavailable \(path)")
            }
            guard case let .completed(definitions) =
                await model.exactCoordinator.definition(
                    file: path,
                    byteOffset: offset,
                    generation: context.generation
                ),
                  !definitions.isEmpty
            else {
                finish("mixed exact definition failed for \(path)")
            }
            let previousExactRelationRoot = model.relationTree.root
            controller.selfTestReaderRelation(
                offset: offset,
                direction: .references
            )
            let exactRelationDeadline = Date(timeIntervalSinceNow: 30)
            var exactEdges: [RelationTreeModel.Node] = []
            while Date() < exactRelationDeadline {
                if let root = model.relationTree.root,
                   root !== previousExactRelationRoot,
                   !(root.children?.contains { $0.kind == .loading } ?? true)
                {
                    exactEdges = exactRelationEdges(in: model)
                    if !exactEdges.isEmpty { break }
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard !exactEdges.isEmpty else {
                finish("mixed exact references empty for \(path)")
            }
            exactOutputs.append([
                "provider": attribution.provider,
                "toolVersion": attribution.toolVersion,
                "definitionCount": definitions.count,
                "verifiedReferenceCount": exactEdges.count,
                "readyMS": readyMS,
                "profileRoot": session.paths.resolve(
                    session.analysisProfile.projectRoot
                ),
            ])
        }
        Self.writeJSON([
            "step": "MIXED_SELF_TEST_EXACT",
            "channel": "mixed",
            "passed": true,
            "exact": exactOutputs,
            "elapsedMS": milliseconds(since: startedAt),
        ])

        let fixedHistoricalCommit = "6cc5b52f9f1bef28b27133155bbb858b2891c829"
        let fixedCompareFile = "crates/qrcode2txt/tests/qrcode_monkey_fixtures.rs"
        let coldSnapshotID = snapshotIDs.first!.rawValue.uuidString
        let coldProfileRoots = sessions.map {
            $0.0.paths.resolve($0.0.analysisProfile.projectRoot)
        }.sorted()
        var coldByLanguage: [String: [String: Any]] = [:]
        for (session, _) in sessions {
            let activeFiles = session.manifest.files.map {
                session.paths.resolve($0.pathID)
            }.filter {
                LanguageMode.classify(
                    path: $0,
                    language: session.analysisProfile.language
                ) != nil
            }
            coldByLanguage[String(describing: session.analysisProfile.language)] = [
                "files": activeFiles.count,
                "extracted": session.stats.extractedCount,
                "reused": session.stats.reusedCount,
            ]
        }

        let commitSwitchStarted = ContinuousClock.now
        model.switchToCommit(fixedHistoricalCommit)
        let overrideDeadline = Date(timeIntervalSinceNow: 30)
        while Date() < overrideDeadline {
            if model.currentRevision == fixedHistoricalCommit,
               model.snapshotPhase == .fullReady,
               model.querySessions.count == 3
            {
                break
            }
            if case .failed = model.projectState {
                finish("mixed snapshot commit failed")
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard model.currentRevision == fixedHistoricalCommit,
              model.snapshotPhase == .fullReady,
              model.querySessions.count == 3,
              model.projectLanguages == [.rust, .python, .typescript]
        else {
            finish("mixed snapshot commit did not reach fullReady")
        }
        let commitSwitchMS = milliseconds(since: commitSwitchStarted)
        let historicalSessions = model.querySessions
        var historicalRust = 0, historicalPython = 0, historicalTS = 0
        for (session, _) in historicalSessions {
            let paths = session.manifest.files.map {
                session.paths.resolve($0.pathID)
            }
            if session.analysisProfile.language == .rust {
                historicalRust = paths.filter { $0.hasSuffix(".rs") }.count
            } else if session.analysisProfile.language == .python {
                historicalPython = paths.filter {
                    $0.hasSuffix(".py") && !$0.hasSuffix(".pyi")
                }.count
            } else if session.analysisProfile.language == .typescript {
                historicalTS = paths.filter { $0.hasSuffix(".ts") || $0.hasSuffix(".tsx") }.count
            }
        }
        let historicalSnapshotID = model.currentSnapshotID!.rawValue.uuidString
        let historicalProfileRoots = historicalSessions.map {
            $0.0.paths.resolve($0.0.analysisProfile.projectRoot)
        }.sorted()
        var historicalRootByLanguage: [LanguageID: String] = [:]
        for (session, _) in historicalSessions {
            historicalRootByLanguage[session.analysisProfile.language] =
                session.paths.resolve(session.analysisProfile.projectRoot)
        }
        guard Set(historicalSessions.map { $0.0.analysisProfile.language })
                == Set([.rust, .python, .typescript]),
              historicalRootByLanguage[.rust] == "crates/qrcode2txt",
              historicalRootByLanguage[.python] == ".",
              historicalRootByLanguage[.typescript] == ".",
              historicalRust == 11,
              historicalPython == 9,
              historicalTS == 0,
              historicalSessions.contains(where: {
                  $0.0.analysisProfile.language == .typescript
              })
        else {
            finish("historical snapshot language/profile/counts mismatch "
                + "rust=\(historicalRust) python=\(historicalPython) "
                + "ts=\(historicalTS) roots=\(historicalProfileRoots)")
        }
        Self.writeJSON([
            "step": "MIXED_SELF_TEST_SNAPSHOT",
            "channel": "mixed",
            "coldSnapshot": coldSnapshotID,
            "commitSnapshot": historicalSnapshotID,
            "commit": fixedHistoricalCommit,
            "switchMS": commitSwitchMS,
            "languages": historicalSessions.map { String(describing: $0.0.analysisProfile.language) },
            "counts": [
                "rust": historicalRust,
                "python": historicalPython,
                "ts": historicalTS,
            ],
            "elapsedMS": milliseconds(since: startedAt),
        ])

        let worktreeSwitchStarted = ContinuousClock.now
        model.switchToWorktree()
        let worktreeDeadline = Date(timeIntervalSinceNow: 30)
        while Date() < worktreeDeadline {
            if model.currentRevision == nil,
               model.snapshotPhase == .fullReady,
               model.querySessions.count == 3,
               model.exactCoordinator.readiness == .ready
            {
                break
            }
            if case .failed = model.projectState {
                finish("worktree switch failed")
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard model.currentRevision == nil,
              model.snapshotPhase == .fullReady,
              model.querySessions.count == 3,
              model.exactCoordinator.readiness == .ready
        else {
            finish("worktree switch did not reach ready")
        }
        let worktreeSwitchMS = milliseconds(since: worktreeSwitchStarted)
        let worktreeSnapshotID = model.currentSnapshotID!.rawValue.uuidString
        let worktreeProfileRoots = model.querySessions.map {
            $0.0.paths.resolve($0.0.analysisProfile.projectRoot)
        }.sorted()
        guard Set(worktreeProfileRoots) == Set(coldProfileRoots) else {
            finish("worktree profile roots did not restore to cold")
        }
        Self.writeJSON([
            "step": "MIXED_SELF_TEST_WORKTREE",
            "channel": "mixed",
            "worktreeSnapshot": worktreeSnapshotID,
            "ready": String(describing: model.exactCoordinator.readiness),
            "switchMS": worktreeSwitchMS,
            "elapsedMS": milliseconds(since: startedAt),
        ])

        let compareFile = root.appendingPathComponent(fixedCompareFile)
        controller.openFileForSelfTest(compareFile)
        let compareDeadline = Date(timeIntervalSinceNow: 30)
        while Date() < compareDeadline {
            if controller.displayedReaderFile?.standardizedFileURL
                == compareFile.standardizedFileURL,
               model.tabStrip.activeDocument != nil
            {
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard controller.displayedReaderFile?.standardizedFileURL
            == compareFile.standardizedFileURL
        else {
            finish("compare file did not open")
        }
        controller.applyPanelPreset(.compare)
        let comparePicked = controller.selectCompareCommit(fixedHistoricalCommit)
        let compareWaitDeadline = Date(timeIntervalSinceNow: 30)
        while Date() < compareWaitDeadline {
            if model.compare.diff != nil,
               controller.selfTestRightReaderBytes != nil
            {
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard comparePicked,
              model.compare.diff != nil,
              controller.selfTestRightReaderBytes != nil
        else {
            finish("compare picker/diff did not complete")
        }
        guard let diff = model.compare.diff,
              diff.hunks.isEmpty == false,
              diff.truncated == false,
              diff.leftLineCount == 62,
              diff.rightLineCount == 45,
              diff.changeCount == 17,
              let commitSnapshot = try? CommitSnapshot(
                  repositoryURL: root,
                  revision: fixedHistoricalCommit
              ),
              let commitBytes = try? commitSnapshot.readBytes(path: fixedCompareFile),
              controller.selfTestRightReaderBytes == commitBytes,
              controller.selfTestRightReaderBytes
                != (try? Data(contentsOf: compareFile)).map(Array.init)
        else {
            finish("compare fixed Rust hunk mismatch")
        }
        Self.writeJSON([
            "step": "MIXED_SELF_TEST_COMPARE",
            "channel": "mixed",
            "revision": fixedHistoricalCommit,
            "leftLineCount": diff.leftLineCount,
            "rightLineCount": diff.rightLineCount,
            "changeCount": diff.changeCount,
            "truncated": diff.truncated,
            "hunkCount": diff.hunks.count,
            "elapsedMS": milliseconds(since: startedAt),
        ])

        let checkpointTsxFile = root.appendingPathComponent(
            "tools/model-files-web/src/App.tsx"
        ).standardizedFileURL
        controller.openFileForSelfTest(checkpointTsxFile)
        let tsxReadyDeadline = Date(timeIntervalSinceNow: 30)
        while Date() < tsxReadyDeadline {
            if model.tabStrip.activeDocument?.languageMode
                == LanguageMode(language: .typescript, variant: "tsx"),
               controller.displayedReaderFile?.standardizedFileURL
                == checkpointTsxFile
            {
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard model.tabStrip.activeDocument?.languageMode
            == LanguageMode(language: .typescript, variant: "tsx"),
              controller.displayedReaderFile?.standardizedFileURL == checkpointTsxFile
        else {
            finish("checkpoint TSX reader was not active")
        }
        controller.checkpointSessionSynchronously()
        guard let savedSnapshot = model.loadSessionSnapshot(
            forProject: root
        ).snapshot else {
            finish("checkpoint did not persist session")
        }
        guard savedSnapshot.languages == [.rust, .python, .typescript],
              savedSnapshot.revision == nil
        else {
            finish("checkpoint languages/revision mismatch")
        }
        let savedLangs = savedSnapshot.languages
        let recentStore = recentProjectsStore
        recentStore.record(root, languages: savedLangs)
        model.exactCoordinator.shutdown()
        controller.openRecentProject(root, forcingReopen: true)
        let reopenDeadline = Date(timeIntervalSinceNow: 30)
        var reopenOK = false
        while Date() < reopenDeadline {
            if model.snapshotPhase == .fullReady,
               model.querySessions.count == 3,
               model.exactCoordinator.readiness == .ready
            {
                reopenOK = true
                break
            }
            if case .failed = model.projectState { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard reopenOK else {
            finish("hot recent reopen did not reach fullReady")
        }
        let hotSessions = model.querySessions
        var hotByLanguage: [String: [String: Any]] = [:]
        var hotReused = 0
        for (session, _) in hotSessions {
            let key = String(describing: session.analysisProfile.language)
            let activePaths = session.manifest.files.map {
                session.paths.resolve($0.pathID)
            }.filter {
                LanguageMode.classify(
                    path: $0,
                    language: session.analysisProfile.language
                ) != nil
            }
            hotByLanguage[key] = [
                "files": activePaths.count,
                "extracted": session.stats.extractedCount,
                "reused": session.stats.reusedCount,
            ]
            hotReused += session.stats.reusedCount
        }
        guard hotReused > 0 else {
            finish("hot reopen did not reuse cache")
        }
        let generationBeforeRestore = model.generation
        controller.restoreSession(savedSnapshot)
        let restoreDeadline = Date(timeIntervalSinceNow: 30)
        while Date() < restoreDeadline {
            if model.generation != generationBeforeRestore,
               model.snapshotPhase == .fullReady,
               model.querySessions.count == 3,
               model.exactCoordinator.readiness == .ready,
               controller.displayedReaderFile?.standardizedFileURL == checkpointTsxFile,
               model.tabStrip.activeDocument?.languageMode
                == LanguageMode(language: .typescript, variant: "tsx"),
               model.exactCoordinator.attribution?.provider
                == "typescript-language-server"
            {
                break
            }
            if case .failed = model.projectState { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard model.generation != generationBeforeRestore,
              model.snapshotPhase == .fullReady,
              model.querySessions.count == 3,
              model.projectLanguages == [.rust, .python, .typescript],
              model.exactCoordinator.readiness == .ready,
              controller.displayedReaderFile?.standardizedFileURL
                == checkpointTsxFile,
              model.tabStrip.activeDocument?.languageMode
                == LanguageMode(language: .typescript, variant: "tsx"),
              model.exactCoordinator.attribution?.provider
                == "typescript-language-server"
        else {
            finish("checkpoint restore did not reach mixed fullReady")
        }
        recentStore.clear()
        Self.writeJSON([
            "step": "MIXED_SELF_TEST_HOT",
            "channel": "mixed",
            "savedLanguages": savedSnapshot.languages.map { String(describing: $0) },
            "hotReused": hotReused,
            "restoreGeneration": model.generation,
            "restoreTSX": true,
            "elapsedMS": milliseconds(since: startedAt),
        ])

        do {
            let head = try git(["rev-parse", "HEAD"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let status = try git([
                "status",
                "--porcelain=v1",
                "--untracked-files=all",
                "--ignored=matching",
            ])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard head == fixedCommit, status.isEmpty else {
                finish("post journey repo HEAD/status changed")
            }
        } catch {
            finish("post journey git check failed")
        }
        let checks: [String: Bool] = [
            "cold": true,
            "search": true,
            "reader": true,
            "exact": true,
            "snapshot": true,
            "compare": true,
            "hot": true,
            "restore": true,
            "cleanHead": true,
        ]
        Self.writeJSON([
            "step": "MIXED_SELF_TEST_SUMMARY",
            "channel": "mixed",
            "passed": true,
            "checks": checks,
            "coldSnapshot": coldSnapshotID,
            "commitSnapshot": historicalSnapshotID,
            "worktreeSnapshot": worktreeSnapshotID,
            "profileRoots": coldProfileRoots,
            "coldStats": coldByLanguage,
            "hotStats": hotByLanguage,
            "providerVersions": exactOutputs.map {
                [
                    "provider": $0["provider"]!,
                    "toolVersion": $0["toolVersion"]!,
                    "readyMS": $0["readyMS"]!,
                ]
            },
            "commitSwitchMS": commitSwitchMS,
            "worktreeSwitchMS": worktreeSwitchMS,
            "elapsedMS": milliseconds(since: startedAt),
        ])
        model.exactCoordinator.shutdown()
        Self.exitSelfTest(channel: "mixed", status: 0)
    }

    private func finishTypeScriptSelfTest(
        coldFileCount: Int,
        coldReused: Int,
        coldExtracted: Int,
        hotFileCount: Int,
        hotReused: Int,
        hotExtracted: Int,
        checks: [String: Bool],
        startedAt: ContinuousClock.Instant
    ) -> Never {
        let passed = checks.values.allSatisfy { $0 }
        Self.writeJSON([
            "step": "summary",
            "channel": "typescript",
            "passed": passed,
            "cold": [
                "fileCount": coldFileCount,
                "reused": coldReused,
                "extracted": coldExtracted,
            ],
            "hot": [
                "fileCount": hotFileCount,
                "reused": hotReused,
                "extracted": hotExtracted,
            ],
            "checks": checks,
            "elapsedMS": milliseconds(since: startedAt),
        ])
        Self.exitSelfTest(channel: "typescript", status: passed ? 0 : 1)
    }

    private func finishTypeScriptSelfTest(
        error: String,
        startedAt: ContinuousClock.Instant
    ) -> Never {
        Self.writeJSON([
            "step": "summary",
            "channel": "typescript",
            "passed": false,
            "error": error,
            "elapsedMS": milliseconds(since: startedAt),
        ])
        Self.exitSelfTest(channel: "typescript", status: 1)
    }

    // Pixel-level acceptance for the gutter-aligned vertical line that used to
    // bleed from the reader ruler into the tab strip (macOS 14+ clipsToBounds
    // default change). Opens a real on-screen window, opens one and two tabs,
    // captures the window at native (Retina) resolution, and scans the header
    // band around x == ruler.maxX for a stray vertical line.
    func runGutterLineSelfTest(root: URL) -> Never {
        let channel = "gutterLine"
        launch(offscreen: true)
        guard let controller = windowController,
              let window = controller.window
        else {
            Self.writeJSON(["channel": channel, "error": "window unavailable"])
            Self.exitSelfTest(channel: channel, status: 1)
        }
        controller.applyReaderSettings(ReaderSettings(theme: .light))
        window.setContentSize(NSSize(width: 1_200, height: 800))
        window.setFrameOrigin(NSPoint(x: 80, y: 80))
        window.orderFrontRegardless()
        pumpRunLoop()

        controller.openProject(root: root)
        guard waitUntil(timeout: 60, condition: {
            if case .ready = self.model.projectState { return true }
            return false
        }) else {
            Self.writeJSON(["channel": channel, "error": "project not ready"])
            Self.exitSelfTest(channel: channel, status: 1)
        }

        let fileA = root.appendingPathComponent("tokio/src/lib.rs")
            .standardizedFileURL
        let fileB = root.appendingPathComponent("tokio/src/blocking.rs")
            .standardizedFileURL

        controller.openFileForSelfTest(fileA)
        guard waitUntil(timeout: 15, condition: {
            controller.displayedReaderFile?.standardizedFileURL == fileA
        }) else {
            Self.writeJSON(["channel": channel, "error": "could not open lib.rs"])
            Self.exitSelfTest(channel: channel, status: 1)
        }
        let oneTab = gutterLineScan(
            controller: controller,
            window: window,
            label: "oneTab"
        )

        controller.openFileInNewTabForSelfTest(fileB)
        guard waitUntil(timeout: 15, condition: {
            controller.displayedReaderFile?.standardizedFileURL == fileB
        }) else {
            Self.writeJSON(
                ["channel": channel, "error": "could not open blocking.rs"]
            )
            Self.exitSelfTest(channel: channel, status: 1)
        }
        let twoTabs = gutterLineScan(
            controller: controller,
            window: window,
            label: "twoTabs"
        )

        Self.writeJSON([
            "channel": channel,
            "oneTab": oneTab.json,
            "twoTabs": twoTabs.json,
        ])
        Self.exitSelfTest(
            channel: channel,
            status: oneTab.pass && twoTabs.pass ? 0 : 1
        )
    }

    /// Reading-session acceptance, first process: builds a real reading
    /// scene (tabs, preview-free strip, semantic trail with a sibling
    /// branch, back/forward state, reading position) against the real
    /// project-open entry, checkpoints it, and records expectations for
    /// the restart process. All state goes through the env-provided
    /// isolated session URL and defaults suite.
    func runSessionSelfTest(root: URL) -> Never {
        let channel = "session"
        launch(offscreen: false)
        guard let controller = windowController,
              let window = controller.window
        else {
            Self.writeJSON(["channel": channel, "passed": false, "error": "window unavailable"])
            Self.exitSelfTest(channel: channel, status: 1)
        }
        window.setContentSize(NSSize(width: 1_200, height: 800))
        window.orderFrontRegardless()
        controller.openProject(root: root)
        guard waitUntil(timeout: 90, condition: {
            if case .ready = self.model.projectState { return true }
            return false
        }), model.projectRoot?.standardizedFileURL == root.standardizedFileURL
        else {
            Self.writeJSON(["channel": channel, "passed": false, "error": "project not ready"])
            Self.exitSelfTest(channel: channel, status: 1)
        }
        let main = root.appendingPathComponent("main.rs")
        let other = root.appendingPathComponent("other.rs")
        let third = root.appendingPathComponent("third.rs")
        controller.openFileInNewTabForSelfTest(main)
        controller.openFileInNewTabForSelfTest(other)
        controller.openFileInNewTabForSelfTest(third)
        guard waitUntil(timeout: 15, condition: {
            self.model.tabStrip.tabs.count == 3
        }) else {
            Self.writeJSON(["channel": channel, "passed": false, "error": "tabs unavailable"])
            Self.exitSelfTest(channel: channel, status: 1)
        }
        // Trail with a sibling branch: main → other, back to main, main →
        // third. Explicit semantic requests so the shared pipeline records
        // both history and trail.
        func jump(_ file: URL, offset: UInt32) -> JumpRecord {
            JumpRecord(
                path: file.lastPathComponent,
                contentID: nil,
                byteOffset: offset,
                line: 1,
                column: offset + 1,
                symbolAnchor: nil,
                snapshotID: model.currentSnapshotID,
                revision: model.currentRevision
            )
        }
        func semantic(_ file: URL, offset: UInt32, leaving: JumpRecord?) {
            model.navigate(
                NavigationRequest(
                    destination: SourceDestination(file: file, byteOffset: offset),
                    cause: .relation,
                    policy: .explicitSemantic
                ),
                leaving: leaving
            )
        }
        semantic(other, offset: 0, leaving: jump(main, offset: 0))
        model.goBack(from: jump(other, offset: 0))
        guard waitUntil(timeout: 10, condition: {
            self.model.readingTrail.edges.count == 1
                && self.model.navigationHistory.canGoForward
                // Wait for the back's replay to publish before the next
                // navigation, so the two never race for the active tab.
                && self.model.activeNavigationRequest?.destination.file
                    .standardizedFileURL == main.standardizedFileURL
        }) else {
            Self.writeJSON([
                "channel": channel,
                "passed": false,
                "error": "back unavailable",
            ] as [String: Any])
            Self.exitSelfTest(channel: channel, status: 1)
        }
        semantic(third, offset: 0, leaving: jump(main, offset: 0))
        guard waitUntil(timeout: 15, condition: {
            controller.displayedReaderFile?.standardizedFileURL
                == third.standardizedFileURL
                && self.model.tabStrip.activeDocument != nil
        }) else {
            Self.writeJSON([
                "channel": channel,
                "passed": false,
                "error": "reader unavailable",
                "displayed": controller.displayedReaderFile?.path ?? "",
                "activeTab": controller.selfTestActiveTabFile?.path ?? "",
                "activeDocument": self.model.tabStrip.activeDocument == nil,
                "lastRequest": self.model.activeNavigationRequest?.destination.file
                    .lastPathComponent ?? "",
                "tabs": self.model.tabStrip.tabs.map {
                    $0.fileURL?.lastPathComponent ?? ""
                },
                "activeIndex": self.model.tabStrip.activeIndex ?? -1,
                "trailEdges": self.model.readingTrail.edges.count,
            ] as [String: Any])
            Self.exitSelfTest(channel: channel, status: 1)
        }
        // Choose a real line in the middle of the fixture, far from the
        // top of the viewport. Do not checkpoint here: normal termination
        // must capture the final Reader position before debounce fires.
        let bytes = (try? Data(contentsOf: third)).map(Array.init) ?? []
        let lineStart = bytes.indices.first { $0 > bytes.count / 2 && bytes[$0 - 1] == 10 } ?? 0
        let selection = UInt32(min(lineStart + 4, max(0, bytes.count - 1)))
        controller.setReadingPositionForSelfTest(
            scrollByteOffset: UInt32(lineStart), selectionByteOffset: selection
        )
        guard waitUntil(timeout: 10, condition: {
            controller.selfTestReaderCaretByteOffset == selection
                && controller.selfTestReadingByteOffset != nil
        }) else { Self.exitSelfTest(channel: channel, status: 1) }

        let tabs = model.tabStrip.tabs
        let expectations: [String: Any] = [
            "root": root.standardizedFileURL.path,
            "tabPaths": tabs.map { $0.fileURL?.lastPathComponent ?? "" },
            "activeIndex": model.tabStrip.activeIndex ?? -1,
            "scrollAnchor": controller.selfTestReadingByteOffset ?? UInt32.max,
            "selectionAnchor": controller.selfTestReaderCaretByteOffset ?? UInt32.max,
            "trailNodeIDs": model.readingTrail.orderedNodes().map { $0.id.rawValue.uuidString },
            "trailEdges": model.readingTrail.edges.map { [$0.from.rawValue.uuidString, $0.to.rawValue.uuidString] },
            "trailActiveID": model.readingTrail.activeNodeID?.rawValue.uuidString ?? "",
            "historyCursor": model.navigationHistory.cursor,
            "historyRecords": model.navigationHistory.records.count,
            "canGoBack": model.navigationHistory.canGoBack,
            "canGoForward": model.navigationHistory.canGoForward,
        ]
        writeSessionSelfTestExpectations(expectations)
        guard tabs.count == 3, model.readingTrail.edges.count == 2 else {
            Self.exitSelfTest(channel: channel, status: 1)
        }
        Self.writeJSON(["channel": channel, "passed": true, "expectations": expectations])
        NSApplication.shared.terminate(nil)
        fatalError("Session self-test termination was cancelled")
    }

    /// Multi-window acceptance (§3.1/§3.2/§7.1): two isolated projects in
    /// two windows with two models; duplicate and alias requests activate
    /// instead of duplicating; closing one window keeps the other working.
    /// Runs entirely offscreen against an isolated session store wired by
    /// the `--self-test-multiwindow` entry point.
    func runMultiWindowSelfTest() -> Never {
        let channel = "multiwindow"

        func fail(_ error: String) -> Never {
            Self.writeJSON([
                "channel": channel, "passed": false, "error": error,
            ] as [String: Any])
            Self.exitSelfTest(channel: channel, status: 1)
        }

        func makeProject(_ files: [String: String]) -> URL? {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "CodeInsightMultiWindow-\(UUID().uuidString)",
                    isDirectory: true
                )
            do {
                try FileManager.default.createDirectory(
                    at: root,
                    withIntermediateDirectories: true
                )
                for (path, contents) in files {
                    let file = root.appendingPathComponent(path)
                    try FileManager.default.createDirectory(
                        at: file.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try contents.write(
                        to: file,
                        atomically: true,
                        encoding: .utf8
                    )
                }
                for arguments in [
                    ["init", "-q"],
                    ["config", "user.name", "CodeInsight Tests"],
                    ["config", "user.email", "tests@codeinsight.invalid"],
                    ["add", "-A"],
                    ["commit", "-q", "-m", "fixture"],
                ] {
                    let process = Process()
                    process.currentDirectoryURL = root
                    process.executableURL = URL(
                        fileURLWithPath: "/usr/bin/git"
                    )
                    process.arguments = arguments
                    try process.run()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else { return nil }
                }
                return root
            } catch {
                try? FileManager.default.removeItem(at: root)
                return nil
            }
        }

        guard let projectA = makeProject([
            "src/lib.rs": "pub fn alpha() {}\n",
            "src/main.rs": "fn main() { crate::alpha(); }\n",
        ]) else { return fail("project A fixture unavailable") }
        guard let projectB = makeProject([
            "src/lib.rs": "pub fn beta() {}\n",
        ]) else { return fail("project B fixture unavailable") }

        launch(offscreen: true)
        // Pre-record language preferences so the open pipeline never shows
        // the modal language picker inside the self-test.
        recentProjectsStore.record(projectA, language: .rust)
        recentProjectsStore.record(projectB, language: .rust)

        enqueueOpenRequest(
            root: projectA,
            languages: nil,
            sourceWindow: nil
        )
        guard waitUntil(timeout: 60, condition: {
            self.projectWindows.first?.model.projectState
                .isReadyForMultiWindowSelfTest == true
        }) else { return fail("project A never became ready") }

        // A second request plus an alias of the first, submitted together:
        // the alias activates A's window; B gets a new one (§3.1).
        let alias = URL(
            fileURLWithPath: projectA.path + "/.",
            isDirectory: true
        )
        enqueueOpenRequest(root: alias, languages: nil, sourceWindow: nil)
        enqueueOpenRequest(
            root: projectB,
            languages: nil,
            sourceWindow: nil
        )
        guard waitUntil(timeout: 60, condition: {
            self.projectWindows.count == 2
                && self.projectWindows.last?.model.projectState
                    .isReadyForMultiWindowSelfTest == true
        }) else { return fail("project B never became ready in a new window") }

        guard projectWindows.count == 2 else {
            return fail("alias request duplicated a window")
        }
        let windowA = projectWindows[0]
        let windowB = projectWindows[1]
        guard windowA.model !== windowB.model,
              windowA.projectURL?.standardizedFileURL
                == projectA.standardizedFileURL,
              windowB.projectURL?.standardizedFileURL
                == projectB.standardizedFileURL
        else { return fail("window claiming or model isolation broken") }
        guard windowA.window?.title == "\(projectA.lastPathComponent) — Cairn",
              windowB.window?.title == "\(projectB.lastPathComponent) — Cairn"
        else { return fail("window titles not project-scoped") }

        // Reading state is per-window: tabs opened in A never appear in B.
        windowA.openFileInNewTabForSelfTest(
            projectA.appendingPathComponent("src/main.rs")
        )
        guard waitUntil(timeout: 15, condition: {
            windowA.model.tabStrip.tabs.count == 1
        }) else { return fail("tab never opened in A") }
        guard windowB.model.tabStrip.tabs.isEmpty else {
            return fail("A's tab leaked into B's model")
        }
        // A later alias-only request activates A's window without
        // resetting it and without creating a window (§3.1).
        guard windowA.model.projectRoot?.standardizedFileURL
            == projectA.standardizedFileURL
        else { return fail("alias activation reset A") }
        enqueueOpenRequest(root: alias, languages: nil, sourceWindow: nil)
        guard waitUntil(timeout: 15, condition: {
            self.activeWindowOrder.last === windowA
        }) else { return fail("alias request did not activate A's window") }
        guard projectWindows.count == 2 else {
            return fail("alias request duplicated a window")
        }

        // Closing B (approved close through AppKit) removes it from the
        // collection and leaves A working (§7.1).
        windowB.window?.performClose(nil)
        // Immediately re-request B while its teardown is still running:
        // the pipeline must wait for the old session writer to finish
        // instead of racing a second model for the same project (review
        // F2). Exactly one B window exists afterwards.
        enqueueOpenRequest(root: projectB, languages: nil, sourceWindow: nil)
        // The old B window keeps its ready state until its asynchronous
        // teardown runs, so the reopened B is identified by NOT closing.
        guard waitUntil(timeout: 30, condition: {
            self.projectWindows.count == 2
                && self.projectWindows.last?.isClosing == false
                && self.projectWindows.last?.model.projectState
                    .isReadyForMultiWindowSelfTest == true
                && self.projectWindows.last?.projectURL?.standardizedFileURL
                    == projectB.standardizedFileURL
                && self.projectWindows.first === windowA
        }) else { return fail("immediate reopen of B did not serialize with its close") }
        guard projectWindows.filter({
            $0.projectURL?.standardizedFileURL == projectB.standardizedFileURL
        }).count == 1
        else { return fail("reopened B produced duplicate windows") }
        guard waitUntil(timeout: 15, condition: {
            self.projectWindows.count == 2
        }) else { return fail("closing B did not retire its window") }
        guard projectWindows.first === windowA,
              windowA.model.projectState.isReadyForMultiWindowSelfTest,
              windowA.model.tabStrip.tabs.count == 1,
              projectWindows[1].isClosing == false
        else { return fail("A disturbed by B's close") }

        // Cancel a first open (review F1): the claim is released, the
        // auto-created blank window goes away, and the repeat request
        // loads the project.
        guard let projectC = makeProject([
            "src/lib.rs": "pub fn gamma() {}\n",
        ]) else { return fail("project C fixture unavailable") }
        languagePickerOverride = { _ in nil }
        enqueueOpenRequest(root: projectC, languages: nil, sourceWindow: nil)
        guard waitUntil(timeout: 15, condition: {
            !self.isDrainingOpenRequests && self.pendingOpenURLs.isEmpty
        }) else { return fail("cancelled open never finished draining") }
        // The auto-created window closes with an asynchronous teardown;
        // wait for the collection to settle back to A + B.
        guard waitUntil(timeout: 15, condition: {
            self.projectWindows.count == 2
                && self.projectWindows.allSatisfy({
                    $0.projectURL?.standardizedFileURL
                        != projectC.standardizedFileURL
                })
        }) else { return fail("cancelled request left a claimed window behind") }
        languagePickerOverride = { _ in [.rust] }
        enqueueOpenRequest(root: projectC, languages: nil, sourceWindow: nil)
        guard waitUntil(timeout: 60, condition: {
            self.projectWindows.count == 3
                && self.projectWindows.last?.model.projectState
                    .isReadyForMultiWindowSelfTest == true
        }) else { return fail("repeat request after cancel did not load C") }
        guard let windowC = projectWindows.last,
              windowC.projectURL?.standardizedFileURL
                == projectC.standardizedFileURL
        else { return fail("C loaded into the wrong window") }

        // Projects left per-project snapshots behind (§7.3).
        windowA.checkpointSessionSynchronously()
        let sessionsDirectory = (windowSessionURL ?? AppModel.defaultSessionURL)
            .deletingLastPathComponent()
            .appendingPathComponent("sessions", isDirectory: true)
        let persisted = (try? FileManager.default.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: nil
        ))?.count ?? 0
        guard persisted >= 2 else {
            return fail("per-project snapshots missing on disk")
        }

        try? FileManager.default.removeItem(at: projectA)
        try? FileManager.default.removeItem(at: projectB)
        try? FileManager.default.removeItem(at: projectC)
        Self.writeJSON([
            "channel": channel,
            "passed": true,
            "windows": projectWindows.count,
            "persistedSnapshots": persisted,
            "titleA": windowA.window?.title ?? "",
        ] as [String: Any])
        Self.exitSelfTest(channel: channel, status: 0)
    }


    /// Reading-session acceptance, second process: relaunches the same
    /// build against the isolated store; the normal launch path (pointer
    // → per-project snapshot → restoreSession) must rebuild the scene the
    /// first process recorded.
    func runSessionSelfTestRestart() -> Never {
        let channel = "session-restart"
        launch(offscreen: false)
        guard let controller = windowController else {
            Self.writeJSON(["channel": channel, "passed": false, "error": "window unavailable"])
            Self.exitSelfTest(channel: channel, status: 1)
        }
        guard let expected = readSessionSelfTestExpectations() else {
            Self.writeJSON([
                "channel": channel,
                "passed": false,
                "error": "expectations unavailable",
            ])
            Self.exitSelfTest(channel: channel, status: 1)
        }
        let rootPath = expected["root"] as? String ?? ""
        let restored = waitUntil(timeout: 120, condition: {
            self.model.projectRoot?.standardizedFileURL.path == rootPath
                && self.model.snapshotPhase == .fullReady
                && self.model.tabStrip.tabs.count == (expected["tabPaths"] as? [String])?.count
        })
        let expectedPaths = expected["tabPaths"] as? [String] ?? []
        let expectedActive = expected["activeIndex"] as? Int ?? -1
        let readerReady = restored && waitUntil(timeout: 15, condition: {
            expectedPaths.indices.contains(expectedActive)
                && controller.displayedReaderFile?.lastPathComponent == expectedPaths[expectedActive]
                && Int(controller.selfTestReadingByteOffset ?? .max) == (expected["scrollAnchor"] as? Int ?? -1)
                && Int(controller.selfTestReaderCaretByteOffset ?? .max) == (expected["selectionAnchor"] as? Int ?? -1)
        })
        guard readerReady else {
            Self.writeJSON([
                "channel": channel,
                "passed": false,
                "error": "Reader restoration did not complete",
                "tabs": self.model.tabStrip.tabs.count,
            ])
            Self.exitSelfTest(channel: channel, status: 1)
        }
        let tabPaths = model.tabStrip.tabs.map {
            $0.fileURL?.lastPathComponent ?? ""
        }
        let activeIndex = model.tabStrip.activeIndex ?? -1
        let trailNodes = model.readingTrail.orderedNodes().map { $0.id.rawValue.uuidString }
        let trailEdges = model.readingTrail.edges.map { [$0.from.rawValue.uuidString, $0.to.rawValue.uuidString] }
        let historyCursor = model.navigationHistory.cursor
        let historyRecords = model.navigationHistory.records.count
        var checks: [String: Bool] = [
            "tabOrder": tabPaths == (expected["tabPaths"] as? [String] ?? []),
            "activeTab": activeIndex == (expected["activeIndex"] as? Int ?? -1),
            "scrollAnchor": Int(controller.selfTestReadingByteOffset ?? .max)
                == (expected["scrollAnchor"] as? Int ?? -1),
            "selectionAnchor": Int(
                controller.selfTestReaderCaretByteOffset ?? .max
            ) == (expected["selectionAnchor"] as? Int ?? -1),
            "trailNodes": trailNodes == (expected["trailNodeIDs"] as? [String] ?? []),
            "trailEdges": trailEdges == (expected["trailEdges"] as? [[String]] ?? []),
            "trailActive": model.readingTrail.activeNodeID?.rawValue.uuidString == (expected["trailActiveID"] as? String),
            "historyCursor": historyCursor == (expected["historyCursor"] as? Int ?? -1),
            "historyRecords": historyRecords == (expected["historyRecords"] as? Int ?? -1),
            "canGoBack": model.navigationHistory.canGoBack
                == (expected["canGoBack"] as? Bool ?? false),
            "canGoForward": model.navigationHistory.canGoForward
                == (expected["canGoForward"] as? Bool ?? false),
            "readerDisplaysActiveTab": {
                guard tabPaths.indices.contains(activeIndex) else { return false }
                return controller.displayedReaderFile?.lastPathComponent
                    == tabPaths[activeIndex]
            }(),
        ]
        controller.goBack(nil)
        checks["backAfterRestart"] = waitUntil(timeout: 10) {
            controller.displayedReaderFile?.lastPathComponent == "main.rs"
        }
        controller.goForward(nil)
        checks["forwardAfterRestart"] = waitUntil(timeout: 10) {
            controller.displayedReaderFile?.lastPathComponent == "third.rs"
        }
        let passed = checks.values.allSatisfy { $0 }
        let output: [String: Any] = [
            "channel": channel,
            "passed": passed,
            "processRestart": true,
            "checks": checks,
            "tabPaths": tabPaths,
            "trailEdges": trailEdges,
            "historyCursor": historyCursor,
        ]
        if let data = try? JSONSerialization.data(
            withJSONObject: output,
            options: [.sortedKeys]
        ) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
        }
        Darwin.exit(passed ? 0 : 1)
    }

    private func writeSessionSelfTestExpectations(_ value: [String: Any]) {
        guard let path = ProcessInfo.processInfo.environment[
            "CAIRN_SESSION_SELFTEST_EXPECTATIONS"
        ] else { return }
        if let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys]
        ) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    private func readSessionSelfTestExpectations() -> [String: Any]? {
        guard let path = ProcessInfo.processInfo.environment[
            "CAIRN_SESSION_SELFTEST_EXPECTATIONS"
        ],
            let data = try? Data(contentsOf: URL(fileURLWithPath: path))
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    func runBookmarkSelfTest(root: URL) -> Never {
        let channel = "bookmarks"
        let languages = bookmarkSelfTestLanguages()
        let languageFiles = bookmarkSelfTestFiles(in: root, languages: languages)
        launch(offscreen: false)
        guard let controller = windowController,
              let window = controller.window,
              let file = languageFiles.first?.file
        else {
            Self.writeJSON(["channel": channel, "passed": false, "error": "fixture unavailable"])
            Self.exitSelfTest(channel: channel, status: 1)
        }
        window.setContentSize(NSSize(width: 1_200, height: 800))
        window.setFrameOrigin(NSPoint(x: 80, y: 80))
        window.orderFrontRegardless()
        NSApplication.shared.activate(ignoringOtherApps: true)
        controller.openProject(root: root, languages: languages)
        guard waitUntil(timeout: 60, condition: {
            if case .ready = self.model.projectState { return true }
            return false
        }) else {
            Self.writeJSON(["channel": channel, "passed": false, "error": "project not ready"])
            Self.exitSelfTest(channel: channel, status: 1)
        }
        controller.openFileForSelfTest(file)
        guard waitUntil(timeout: 15, condition: {
            controller.displayedReaderFile?.standardizedFileURL == file
                && self.model.tabStrip.activeDocument != nil
        }) else {
            Self.writeJSON(["channel": channel, "passed": false, "error": "reader unavailable"])
            Self.exitSelfTest(channel: channel, status: 1)
        }
        controller.setReadingPositionForSelfTest(scrollByteOffset: 0, selectionByteOffset: 0)
        pumpRunLoop()
        let viewMenu = NSApplication.shared.mainMenu?.items.compactMap(\.submenu)
            .first { $0.title == "View" }
        guard let toggle = viewMenu?.item(withTitle: "Toggle Bookmark"),
              let show = viewMenu?.item(withTitle: "Show Bookmarks")
        else {
            Self.writeJSON(["channel": channel, "passed": false, "error": "menu unavailable"])
            Self.exitSelfTest(channel: channel, status: 1)
        }
        let toggleEnabled = validateMenuItem(toggle)
        let toggled = toggleEnabled && performMenuShortcut(
            characters: "m", modifiers: [.command, .shift], window: window
        )
        guard waitUntil(timeout: 5, condition: {
            self.model.bookmarkModel.records.count == 1
        }), let record = self.model.bookmarkModel.records.first else {
            Self.writeJSON(["channel": channel, "passed": false, "error": "bookmark toggle failed"])
            Self.exitSelfTest(channel: channel, status: 1)
        }
        let gutterMarker = controller.selfTestBookmarkMarkerLines.contains(Int(record.line))
            && !(controller.selfTestBookmarkMarkerAccessibilityLabel ?? "").isEmpty
        let gutterLines = controller.selfTestBookmarkMarkerLines
        let gutterAccessibilityLabel = controller.selfTestBookmarkMarkerAccessibilityLabel ?? ""
        let openedPanel = performMenuShortcut(
            characters: "b", modifiers: [.command, .option], window: window
        )
        let panelShortcutIsUnique = show.keyEquivalent == "b"
            && show.keyEquivalentModifierMask == [.command, .option]
        guard waitUntil(timeout: 5, condition: {
            controller.selfTestBookmarkPanel?.selfTestState.visible == true
        }), let panel = controller.selfTestBookmarkPanel else {
            Self.writeJSON(["channel": channel, "passed": false, "error": "panel unavailable"])
            Self.exitSelfTest(channel: channel, status: 1)
        }
        let shown = panel.selfTestState
        panel.selfTestSetFilter("no-bookmark-match")
        let filteredOut = panel.selfTestState.rows == 0
        panel.selfTestSetFilter(record.path)
        let filteredIn = panel.selfTestState.rows == 1
            && panel.selfTestState.rowIDs == [record.id.uuidString]
        let statusToolTip = panel.selfTestFirstRowToolTip
        let noteText = "* _ [ ] # > | \\ ` { } ( ) + - . !\nnext"
        let noteSelected = panel.selfTestSelectFirstRow()
        let noteUpdatedAt = BookmarkModel(store: BookmarkStore(
            fileURL: bookmarkSelfTestSessionURL().deletingLastPathComponent()
                .appendingPathComponent("bookmarks.json")
        )).records.first(where: { $0.id == record.id })?.updatedAt ?? record.updatedAt
        panel.selfTestTypeNote(noteText)
        let reloadedNote = BookmarkModel(store: BookmarkStore(
            fileURL: bookmarkSelfTestSessionURL().deletingLastPathComponent()
                .appendingPathComponent("bookmarks.json")
        )).records.first(where: { $0.id == record.id })
        let noteWriteThrough = reloadedNote?.note == noteText
            && reloadedNote?.updatedAt == noteUpdatedAt
        panel.selfTestFinalizeNote()
        let finalizedNote = BookmarkModel(store: BookmarkStore(
            fileURL: bookmarkSelfTestSessionURL().deletingLastPathComponent()
                .appendingPathComponent("bookmarks.json")
        )).records.first(where: { $0.id == record.id })
        let noteFinalized = (finalizedNote?.updatedAt ?? noteUpdatedAt) > noteUpdatedAt
        let noteRestart = finalizedNote?.note == noteText
        let bookmarksURL = bookmarkSelfTestSessionURL().deletingLastPathComponent()
            .appendingPathComponent("bookmarks.json")
        let rawBookmarksBefore = try? Data(contentsOf: bookmarksURL)
        panel.selfTestPressCopyMarkdown()
        let copiedMarkdown = panel.selfTestLastCopiedMarkdown
        let pasteboardReadback = NSPasteboard.general.string(forType: .string) == copiedMarkdown
        panel.selfTestPressExportMarkdown()
        let markdownPath = ProcessInfo.processInfo.environment[
            "CAIRN_BOOKMARK_MARKDOWN_EXPORT_PATH"
        ] ?? ""
        let exportedMarkdown = try? String(contentsOfFile: markdownPath, encoding: .utf8)
        let rawBookmarksAfter = try? Data(contentsOf: bookmarksURL)
        let rawBookmarksUnchanged = rawBookmarksBefore == rawBookmarksAfter
        let normalAX = panel.selfTestAXTree()
        let panelGeometry = panel.selfTestGeometry
        let historyBefore = self.model.navigationHistory.records.count
        let rowOpen = panel.selfTestPressFirstOpen()
        let openedExact = waitUntil(timeout: 5, condition: {
            self.model.navigationHistory.records.count == historyBefore + 1
                && self.model.tabStrip.activeDocument?.contentID == record.contentID
        })
        let contentIDExactAtOpen = self.model.tabStrip.activeDocument?.contentID == record.contentID
        let returned = openedExact
            && performMenuShortcut(characters: "[", modifiers: [.command], window: window)
            && waitUntil(timeout: 5, condition: {
                self.model.navigationHistory.canGoForward
            })
        let gitHEAD = bookmarkSelfTestGitHEAD(in: root)
        var gitChecks: [String: Bool] = [:]
        let gitSkip = gitHEAD == nil ? "commit checks require a repository with HEAD" : ""
        if let gitHEAD {
            self.model.switchToCommit(gitHEAD)
            let commitReady = waitUntil(timeout: 60, condition: {
                self.model.snapshotPhase == .fullReady && self.model.currentRevision == gitHEAD
            })
            controller.openFileForSelfTest(file)
            let commitReader = waitUntil(timeout: 15, condition: {
                controller.displayedReaderFile?.standardizedFileURL == file
                    && self.model.tabStrip.activeDocument != nil
            })
            controller.setReadingPositionForSelfTest(scrollByteOffset: 0, selectionByteOffset: 0)
            let commitToggle = commitReady && commitReader && performMenuShortcut(
                characters: "m", modifiers: [.command, .shift], window: window
            )
            let commitRecord = self.model.bookmarkModel.records.last { candidate in
                if case let .commit(fullOID) = candidate.snapshot { return fullOID == gitHEAD }
                return false
            }
            let commitCaptured = commitRecord.map { candidate in
                if case let .commit(fullOID) = candidate.snapshot {
                    return fullOID.count == 40 || fullOID.count == 64
                }
                return false
            } ?? false
            self.model.switchToWorktree()
            let worktreeReady = waitUntil(timeout: 60, condition: {
                self.model.snapshotPhase == .fullReady && self.model.currentRevision == nil
            })
            panel.refresh()
            let commitNotEvaluated = commitRecord.map {
                panel.selfTestRowToolTip(id: $0.id) == "Not evaluated"
            } ?? false
            let historyBeforeCommitOpen = self.model.navigationHistory.records.count
            let commitOpen = commitRecord.map { panel.selfTestPressOpen(id: $0.id) } ?? false
            let commitExact = commitOpen && waitUntil(timeout: 60, condition: {
                self.model.currentRevision == gitHEAD
                    && self.model.tabStrip.activeDocument?.contentID == commitRecord?.contentID
                    && self.model.navigationHistory.records.count == historyBeforeCommitOpen + 1
            })
            let commitBack = commitExact
                && performMenuShortcut(characters: "[", modifiers: [.command], window: window)
                && waitUntil(timeout: 60, condition: { self.model.currentRevision == nil })
            let worktreeFullAfterCommitBack = commitBack && waitUntil(timeout: 60, condition: {
                self.model.snapshotPhase == .fullReady && self.model.currentRevision == nil
            })
            let missing = BookmarkRecord(
                id: UUID(), projectPath: root.standardizedFileURL.path,
                snapshot: .commit(fullOID: String(repeating: "a", count: 40)),
                path: record.path, contentID: record.contentID, byteOffset: record.byteOffset,
                line: record.line, symbolName: nil, symbolKind: nil, note: "", updatedAt: .now
            )
            let missingAdded = self.model.bookmarkModel.toggle(missing) == .added
            panel.refresh()
            let missingHistory = self.model.navigationHistory.records.count
            let missingRevision = self.model.currentRevision
            let missingOpen = missingAdded && panel.selfTestPressOpen(id: missing.id)
            let missingAttempt = missingOpen && waitUntil(timeout: 15, condition: {
                self.model.bookmarkModel.lastAttemptMessage?.id == missing.id
                    && self.model.bookmarkModel.lastAttemptMessage?.message == "Bookmark revision is unavailable."
            })
            gitChecks = [
                "switchToCommit": commitReady,
                "commitCaptureFullOID": commitToggle && commitCaptured,
                "commitNotEvaluated": worktreeReady && commitNotEvaluated,
                "commitOpenExact": commitExact,
                "commitGoBack": worktreeFullAfterCommitBack,
                "missingObjectAttempt": missingAttempt,
                "missingObjectNoWorkspaceMutation": missingAttempt
                    && self.model.currentRevision == missingRevision
                    && self.model.navigationHistory.records.count == missingHistory,
            ]
        }
        let drift = BookmarkRecord(
            id: UUID(), projectPath: root.standardizedFileURL.path, snapshot: .worktree,
            path: record.path, contentID: ContentID.sha256(of: Data("bookmark drift\n".utf8)),
            byteOffset: 0, line: 999, symbolName: nil, symbolKind: nil,
            note: "drift note", updatedAt: .now
        )
        let driftAdded = self.model.currentRevision == nil
            && self.model.bookmarkModel.toggle(drift) == .added
        panel.refresh()
        let driftBefore = self.model.bookmarkModel.records.first { $0.id == drift.id }
        let expectedDriftTarget = self.model.explicitBookmarkLineOpen(drift, line: drift.line)
        let driftLineOpen = driftAdded && panel.selfTestPressOpenLine(id: drift.id)
        let driftLineOpened = driftLineOpen && waitUntil(timeout: 15, condition: {
            self.model.selectedByteOffset == expectedDriftTarget?.byteOffset
        })
        let driftReanchored = driftLineOpened && panel.selfTestPressReanchor(id: drift.id)
        let driftAfter = self.model.bookmarkModel.records.first { $0.id == drift.id }
        let driftExact = driftAfter.map { self.model.bookmarkStatus(for: $0) == .exactContent } ?? false
        let modelReloadURL = bookmarkSelfTestSessionURL().deletingLastPathComponent()
            .appendingPathComponent("bookmarks.json")
        self.model.bookmarkModel = BookmarkModel(store: BookmarkStore(fileURL: modelReloadURL))
        panel.refresh()
        let modelReload = self.model.bookmarkModel.records.contains(where: { $0.id == record.id })
            && self.model.bookmarkModel.records.first(where: { $0.id == drift.id })?.note == "drift note"
        var languageChecks: [String: Bool] = [:]
        if gitHEAD != nil {
            panel.selfTestSetFilter("")
            for item in languageFiles {
                controller.openFileForSelfTest(item.file)
                let readerReady = waitUntil(timeout: 15, condition: {
                    controller.displayedReaderFile?.standardizedFileURL == item.file
                })
                let existing = self.model.bookmarkModel.records.last { candidate in
                    candidate.projectPath == root.standardizedFileURL.path && candidate.snapshot == .worktree
                        && candidate.path == item.file.path.replacingOccurrences(
                            of: root.standardizedFileURL.path + "/", with: ""
                        )
                }
                controller.setReadingPositionForSelfTest(scrollByteOffset: 1, selectionByteOffset: 1)
                let languageToggle = existing != nil || (readerReady && performMenuShortcut(
                    characters: "m", modifiers: [.command, .shift], window: window
                ))
                let languageRecord = existing ?? self.model.bookmarkModel.records.last { candidate in
                    candidate.projectPath == root.standardizedFileURL.path && candidate.snapshot == .worktree
                        && candidate.path == item.file.path.replacingOccurrences(
                            of: root.standardizedFileURL.path + "/", with: ""
                        )
                }
                panel.refresh()
                let languageOpen = languageRecord.map { panel.selfTestPressOpen(id: $0.id) } ?? false
                let languageExact = languageOpen && waitUntil(timeout: 15, condition: {
                    self.model.tabStrip.activeDocument?.contentID == languageRecord?.contentID
                })
                languageChecks[bookmarkSelfTestLanguageName(item.language)] = languageToggle && languageExact
            }
        }
        let allLanguagesPresent = languageFiles.count == languages.count
        _ = self.model.compare.beginLoading(revision: "bookmark-self-test")
        let compareDisabled = !validateMenuItem(toggle)
            && toggle.accessibilityHelp() == "Compare views cannot be bookmarked."
        self.model.compare.clear()
        let themeCaptures = ReaderSettings.Theme.allCases.filter {
            [.light, .dark, .siClassic].contains($0)
        }.map { theme in
            var settings = self.readerSettings
            settings.theme = theme
            controller.applyReaderSettings(settings)
            panel.window?.orderFrontRegardless()
            let capture = self.bookmarkSelfTestCapture(
                window: window,
                panelWindow: panel.window,
                label: theme.rawValue
            )
            return (
                capture.pass && !controller.selfTestBookmarkMarkerLines.isEmpty,
                capture.json
            )
        }

        self.model.openReadingSet(title: "Bookmark unsupported", excerpts: [])
        pumpRunLoop()
        let readingSetDisabled = !validateMenuItem(toggle)
            && toggle.accessibilityHelp() == "Reading Sets cannot be bookmarked."

        let corruptBytes = Data([0x7B, 0xFF, 0x00])
        let corruptURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CodeInsightBookmarkCorrupt-\(UUID().uuidString).json"
        )
        try? corruptBytes.write(to: corruptURL)
        self.model.bookmarkModel = BookmarkModel(store: BookmarkStore(fileURL: corruptURL))
        panel.refresh()
        let corrupt = panel.selfTestState
        let errorAX = panel.selfTestAXTree()
        let exportPressed = panel.selfTestPressExport()
        let rawExportURL = ProcessInfo.processInfo.environment[
            "CAIRN_BOOKMARK_RAW_EXPORT_PATH"
        ].map(URL.init(fileURLWithPath:))
        let exported = rawExportURL.flatMap { try? Data(contentsOf: $0) } == corruptBytes
        let checks: [String: Bool] = [
            "toggleEnabled": toggleEnabled,
            "toggleShortcut": toggled,
            "panelShortcut": openedPanel,
            "panelShortcutUnique": panelShortcutIsUnique,
            "panelAX": shown.accessibilityLabel == "Bookmarks",
            "panelGeometry": panelGeometry.content.width >= 500
                && panelGeometry.content.height >= 400
                && panelGeometry.table.height > 200
                && panelGeometry.row.height > 0
                && panelGeometry.copyVisible
                && panelGeometry.markdownExportVisible
                && !panelGeometry.copy.intersects(panelGeometry.markdownExport)
                && panelGeometry.content.contains(panelGeometry.copy)
                && panelGeometry.content.contains(panelGeometry.markdownExport),
            "normalAX": axContains(normalAX, "Filter bookmarks")
                && axContains(normalAX, "Bookmarks")
                && axContains(normalAX, "Open bookmark")
                && axContains(normalAX, "Delete bookmark"),
            "noteWriteThrough": noteSelected && noteWriteThrough,
            "noteRestart": noteRestart && noteFinalized,
            "copyMarkdown": copiedMarkdown.contains("### Note")
                && copiedMarkdown.contains(
                    "\\* \\_ \\[ \\] \\# \\> \\| \\\\ \\` \\{ \\} \\( \\) \\+ \\- \\. \\!\nnext"
                ),
            "markdownExport": exportedMarkdown == copiedMarkdown,
            "exportZeroMutation": rawBookmarksUnchanged,
            "errorAX": axContains(errorAX, "Bookmark storage error")
                && axContains(errorAX, "Export Raw Copy…"),
            "statusToolTip": statusToolTip == "Exact content",
            "filter": filteredOut && filteredIn,
            "rowOpen": rowOpen && openedExact,
            "contentIDExactAtOpen": contentIDExactAtOpen,
            "goBack": returned,
            "gitMatrix": gitHEAD == nil || gitChecks.values.allSatisfy { $0 },
            "driftLineOpen": driftLineOpen && driftLineOpened,
            "driftReanchor": driftReanchored
                && driftBefore?.id == driftAfter?.id
                && driftBefore?.note == driftAfter?.note
                && driftBefore?.contentID != driftAfter?.contentID
                && driftBefore?.line != driftAfter?.line
                && driftExact,
            "modelReload": modelReload,
            "mixedLanguageCoverage": gitHEAD == nil || (
                allLanguagesPresent && languageChecks.count == languages.count
                    && languageChecks.values.allSatisfy { $0 }
            ),
            "gutterMarker": gutterMarker,
            "readingSetDisabled": readingSetDisabled,
            "compareDisabled": compareDisabled,
            "themeCaptures": themeCaptures.allSatisfy { $0.0 },
            "corruptExport": corrupt.exportVisible && corrupt.exportEnabled
                && corrupt.exportAccessibilityLabel == "Export Raw Copy…"
                && exportPressed && exported,
        ]
        Self.writeJSON([
            "channel": channel,
            "passed": checks.values.allSatisfy { $0 },
            "checks": checks,
            "menu": [
                "toggleEnabled": toggleEnabled,
                "toggleHelp": toggle.accessibilityHelp() ?? "",
                "panelShortcut": "⌘⌥B",
                "readingSetDisabled": readingSetDisabled,
                "compareDisabled": compareDisabled,
            ],
            "panel": [
                "rows": shown.rows,
                "rowIDs": shown.rowIDs,
                "accessibilityLabel": shown.accessibilityLabel,
                "statusToolTip": statusToolTip ?? "",
            ],
            "matrix": [
                "gitApplicable": gitHEAD != nil,
                "commitApplicable": gitHEAD != nil,
                "gitSkip": gitSkip,
                "modelReload": modelReload,
                "secondProcessReload": "not run",
                "processRestart": "run --self-test-bookmarks-restart after this process exits",
                "languages": languages.map(bookmarkSelfTestLanguageName),
                "languageFiles": languageFiles.map {
                    ["language": bookmarkSelfTestLanguageName($0.language), "path": $0.file.path]
                },
                "languageChecks": languageChecks,
                "gitChecks": gitChecks,
                "nonGit": [
                    "worktreeOnly": gitHEAD == nil,
                    "commitApplicable": false,
                    "missingObjectApplicable": false,
                ],
                "drift": [
                    "lineOpen": driftLineOpen && driftLineOpened,
                    "reanchor": driftReanchored && driftExact,
                ],
            ],
            "axTreeNormal": normalAX,
            "axTreeError": errorAX,
            "panelGeometry": [
                "content": NSStringFromRect(panelGeometry.content),
                "table": NSStringFromRect(panelGeometry.table),
                "row": NSStringFromRect(panelGeometry.row),
                "copy": NSStringFromRect(panelGeometry.copy),
                "markdownExport": NSStringFromRect(panelGeometry.markdownExport),
                "copyVisible": panelGeometry.copyVisible,
                "markdownExportVisible": panelGeometry.markdownExportVisible,
            ],
            "copy": ["length": copiedMarkdown.count, "pasteboardReadback": pasteboardReadback],
            "markdownPath": markdownPath,
            "markdownLength": copiedMarkdown.count,
            "pasteboardReadback": pasteboardReadback,
            "rawBookmarks": [
                "beforeLength": rawBookmarksBefore?.count ?? -1,
                "afterLength": rawBookmarksAfter?.count ?? -1,
                "unchanged": rawBookmarksUnchanged,
            ],
            "captures": themeCaptures.map { $0.1 },
            "historyCount": self.model.navigationHistory.records.count,
            "contentIDExactAtOpen": contentIDExactAtOpen,
            "rawExportByteIdentical": exported,
            "gutter": [
                "lines": gutterLines,
                "accessibilityLabel": gutterAccessibilityLabel,
            ],
            "sessionURL": bookmarkSelfTestSessionURL().path,
            "bookmarksURL": bookmarksURL.path,
        ])
        try? FileManager.default.removeItem(at: corruptURL)
        Self.exitSelfTest(channel: channel, status: checks.values.allSatisfy { $0 } ? 0 : 1)
    }

    private func performMenuShortcut(
        characters: String,
        modifiers: NSEvent.ModifierFlags,
        window: NSWindow
    ) -> Bool {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: 0
        ) else { return false }
        return NSApplication.shared.mainMenu?.performKeyEquivalent(with: event) == true
    }

    private func bookmarkSelfTestCapture(
        window: NSWindow,
        panelWindow: NSWindow?,
        label: String
    ) -> (pass: Bool, json: [String: Any]) {
        window.displayIfNeeded()
        panelWindow?.displayIfNeeded()
        pumpRunLoop()
        let directory = ProcessInfo.processInfo.environment[
            "CAIRN_BOOKMARK_CAPTURE_DIR"
        ] ?? "/tmp/cairn-bookmark-captures"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = "\(directory)/\(label).png"
        let panelPNG = "\(directory)/\(label)-panel.png"
        guard let panelWindow,
              let main = cachedPNG(of: window.contentView, path: path),
              let panelPath = cachedPNG(
                of: panelWindow.contentView,
                path: panelPNG
              )
        else { return (false, ["theme": label, "error": "AppKit capture failed"]) }
        return (main.visiblePixels && panelPath.visiblePixels, [
            "theme": label, "png": main.path, "width": main.width,
            "height": main.height, "visiblePixels": main.visiblePixels,
            "panelPNG": panelPath.path,
            "panelWidth": panelPath.width, "panelHeight": panelPath.height,
            "panelVisiblePixels": panelPath.visiblePixels,
            "capture": "AppKit cache",
            "panelCapture": "AppKit cache",
        ])
    }

    private func gutterLineScan(
        controller: MainWindowController,
        window: NSWindow,
        label: String
    ) -> (pass: Bool, json: [String: Any]) {
        window.displayIfNeeded()
        for _ in 0..<12 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let reading = controller.selfTestReadingGeometry
        let tabs = controller.selfTestTabGeometry
        guard let contentView = window.contentView,
              let bitmap = cachedBitmap(of: contentView)
        else { return (false, ["error": "window cache failed"]) }
        let frame = contentView.bounds
        let scale = Double(bitmap.pixelsWide) / Double(frame.width)
        let captureDirectory = ProcessInfo.processInfo.environment[
            "CAIRN_GUTTER_CAPTURE_DIR"
        ] ?? "/tmp/cairn-gutter-line"
        try? FileManager.default.createDirectory(
            atPath: captureDirectory,
            withIntermediateDirectories: true
        )
        let pngPath = "\(captureDirectory)/\(label).png"
        try? bitmap.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: pngPath))

        // Window points (bottom-left origin) → image pixels (top-left origin).
        func pixelX(_ x: CGFloat) -> Int { Int((Double(x) * scale).rounded()) }
        func pixelY(_ y: CGFloat) -> Int {
            Int(((Double(frame.height) - Double(y)) * scale).rounded())
        }

        let gutter = contentView.convert(reading.rulerFrame, from: nil)
        let header = contentView.convert(tabs.headerFrame, from: nil)
        let gutterX = gutter.maxX
        let rowStart = max(0, pixelY(header.maxY - 3))
        let rowEnd = min(bitmap.pixelsHigh, pixelY(header.minY + 3))
        let columnStart = max(0, pixelX(gutterX - 8))
        let columnEnd = min(bitmap.pixelsWide, pixelX(gutterX + 8))
        guard rowEnd > rowStart, columnEnd > columnStart else {
            return (false, ["error": "empty scan region", "png": pngPath])
        }

        var brightnessByColumn: [Int: [Double]] = [:]
        var allSamples: [Double] = []
        for px in columnStart..<columnEnd {
            var column: [Double] = []
            for py in rowStart..<rowEnd {
                guard let color = bitmap.colorAt(x: px, y: py)?
                    .usingColorSpace(.sRGB) else { continue }
                let value = Double(color.brightnessComponent)
                column.append(value)
                allSamples.append(value)
            }
            brightnessByColumn[px] = column
        }
        let background = allSamples.sorted()[allSamples.count / 2]
        func coverage(_ px: Int) -> Double {
            guard let column = brightnessByColumn[px], !column.isEmpty else {
                return 0
            }
            let deviant = column.filter { abs($0 - background) > 0.06 }.count
            return Double(deviant) / Double(column.count)
        }
        let lineColumns = (columnStart..<columnEnd).filter { coverage($0) >= 0.7 }
        let lineNumberRGB = ReaderTheme(settings: ReaderSettings(theme: .light))
            .lineNumberRGB(isDark: false)
        let target = (
            red: CGFloat((lineNumberRGB >> 16) & 0xFF) / 255,
            green: CGFloat((lineNumberRGB >> 8) & 0xFF) / 255,
            blue: CGFloat(lineNumberRGB & 0xFF) / 255
        )
        let numberColumnStart = max(0, pixelX(gutter.minX))
        let numberColumnEnd = min(
            bitmap.pixelsWide,
            pixelX(gutter.minX + min(34, reading.rulerThickness))
        )
        let rulerRowStart = max(0, pixelY(gutter.maxY))
        let rulerRowEnd = min(bitmap.pixelsHigh, pixelY(gutter.minY))
        var lineNumberPixelCount = 0
        for px in numberColumnStart..<numberColumnEnd {
            for py in rulerRowStart..<rulerRowEnd {
                guard let color = bitmap.colorAt(x: px, y: py)?
                    .usingColorSpace(.sRGB),
                      abs(color.redComponent - target.red) < 0.12,
                      abs(color.greenComponent - target.green) < 0.12,
                      abs(color.blueComponent - target.blue) < 0.12
                else { continue }
                lineNumberPixelCount += 1
            }
        }
        let lineNumbersVisible = lineNumberPixelCount >= 4
        let json: [String: Any] = [
            "png": pngPath,
            "gutterWindowX": Double(gutterX),
            "rulerThickness": Double(reading.rulerThickness),
            "headerBandWindowY": [Double(header.minY), Double(header.maxY)],
            "scanColumnsPx": [columnStart, columnEnd],
            "scanRowsPx": [rowStart, rowEnd],
            "lineColumnsPx": lineColumns,
            "lineDetected": !lineColumns.isEmpty,
            "lineNumberPixelCount": lineNumberPixelCount,
            "lineNumbersVisible": lineNumbersVisible,
        ]
        return (lineColumns.isEmpty && lineNumbersVisible, json)
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
            state.textView.display(document: loaded.document, fileURL: file)
            state.textView.view.textLayoutManager?
                .textViewportLayoutController.layoutViewport()
            guard
                let fragment = state.textView.view.textLayoutManager?
                    .textLayoutFragment(for: .zero),
                !fragment.textLineFragments.isEmpty
            else { Self.exitSelfTest(channel: "open", status: 1) }
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
            Self.exitSelfTest(channel: "open", status: 1)
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
        else { Self.exitSelfTest(channel: "open", status: 1) }
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

    private func enqueueOpenRequest(
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
    private final class LanguageSelectionGate: NSObject {
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

    private final class LanguageSelectionAlert: NSAlert {
        var gate = LanguageSelectionGate()

        var languageSelection: [LanguageID]? { gate.selection }
    }

    private func makeLanguageSelectionAlert(for root: URL) -> LanguageSelectionAlert {
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
                trustModel: trustListModel,
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

    @objc private func goToLine(_ sender: Any?) {
        projectCommandTarget()?.showPalette(prefill: ":")
    }

    @objc private func findInProject(_ sender: Any?) {
        projectCommandTarget()?.showProjectSearch()
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

    @objc private func openSelectedFileInNewTab(_ sender: Any?) {
        projectCommandTarget()?.openSelectedFileInNewTab()
    }

    @objc private func closeActiveTab(_ sender: Any?) {
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

    @objc private func selectPreviousTab(_ sender: Any?) {
        projectCommandTarget()?.selectPreviousTab()
    }

    @objc private func selectNextTab(_ sender: Any?) {
        projectCommandTarget()?.selectNextTab()
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

    @objc private func showResolutionInspector(_ sender: Any?) {
        projectCommandTarget()?.showResolutionInspector()
    }

    @objc private func showReadingTrail(_ sender: Any?) {
        projectCommandTarget()?.showReadingTrail()
    }

    @objc private func toggleFold(_ sender: Any?) {
        _ = projectCommandTarget()?.toggleFoldAtSelection()
    }

    @objc private func toggleBookmark(_ sender: Any?) {
        projectCommandTarget()?.toggleBookmark()
    }

    @objc private func showBookmarks(_ sender: Any?) {
        projectCommandTarget()?.showBookmarks()
    }

    @objc private func closeBookmarks(_ sender: Any?) {
        projectCommandTarget()?.closeBookmarks()
    }

    @objc private func useFullReadingHeight(_ sender: Any?) {
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

    @objc private func increaseReaderFontSize(_ sender: Any?) {
        changeReaderFontSize(by: 1)
    }

    @objc private func decreaseReaderFontSize(_ sender: Any?) {
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

    // Option-only key equivalents can be consumed by NSTextView's text input
    // before reaching the menu. Handle this application preference once,
    // before responder dispatch, including while Settings owns the key window.
    func handleWrapKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.intersection([.command, .option, .control, .shift]) == .option,
              event.charactersIgnoringModifiers?.lowercased() == "z" else { return false }
        if !event.isARepeat { toggleWrapLines(nil) }
        return true
    }

    private func commitReaderSettings(_ settings: ReaderSettings) {
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
        case #selector(refreshProjectIndex(_:)):
            return target?.canRefreshIndex == true
        case #selector(findInFile(_:)), #selector(findNext(_:)),
            #selector(findPrevious(_:)):
            return target?.canFindInFile == true
        case #selector(goBack(_:)):
            return model?.navigationHistory.canGoBack == true
        case #selector(goForward(_:)):
            return model?.navigationHistory.canGoForward == true
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
            #selector(openSymbol(_:)):
            return target != nil
        default:
            return true
        }
    }

    /// Internal for the menu wiring tests: the wrap command must stay
    /// reachable and checkable without any project window (D1.1).
    func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Cairn")
        let aboutItem = NSMenuItem(
            title: localized("app.menu.about.cairn"),
            action: #selector(showAbout(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = self
        appMenu.addItem(aboutItem)
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(
            title: localized("app.menu.settings"),
            action: #selector(showSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: localized("app.menu.quit.cairn"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApplication.shared
        appMenu.addItem(quitItem)
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: localized("app.menu.file"))
        let openItem = NSMenuItem(
            title: localized("app.menu.open.project"),
            action: #selector(openProject(_:)),
            keyEquivalent: "o"
        )
        openItem.target = self
        fileMenu.addItem(openItem)
        let newWindowItem = NSMenuItem(
            title: localized("app.menu.new.window"),
            action: #selector(newWindow(_:)),
            keyEquivalent: "n"
        )
        newWindowItem.target = self
        fileMenu.addItem(newWindowItem)
        let openPythonItem = NSMenuItem(
            title: localized("app.menu.open.python.project"),
            action: #selector(openPythonProject(_:)),
            keyEquivalent: ""
        )
        openPythonItem.target = self
        fileMenu.addItem(openPythonItem)
        let openTypeScriptItem = NSMenuItem(
            title: localized("app.menu.open.typescript.project"),
            action: #selector(openTypeScriptProject(_:)),
            keyEquivalent: ""
        )
        openTypeScriptItem.target = self
        fileMenu.addItem(openTypeScriptItem)
        let quickOpenItem = NSMenuItem(
            title: localized("app.menu.quick.open"),
            action: #selector(quickOpen(_:)),
            keyEquivalent: "p"
        )
        quickOpenItem.target = self
        fileMenu.addItem(quickOpenItem)
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
        let openInNewTabItem = NSMenuItem(
            title: localized("app.menu.open.in.new.tab"),
            action: #selector(openSelectedFileInNewTab(_:)),
            keyEquivalent: "\r"
        )
        openInNewTabItem.keyEquivalentModifierMask = [.command, .shift]
        openInNewTabItem.target = self
        fileMenu.addItem(openInNewTabItem)
        let closeTabItem = NSMenuItem(
            title: localized("app.menu.close.tab"),
            action: #selector(closeActiveTab(_:)),
            keyEquivalent: "w"
        )
        closeTabItem.target = self
        fileMenu.addItem(closeTabItem)
        let closeWindowItem = NSMenuItem(
            title: localized("app.menu.close.window"),
            action: #selector(closeProjectWindow(_:)),
            keyEquivalent: "w"
        )
        closeWindowItem.keyEquivalentModifierMask = [.command, .shift]
        closeWindowItem.target = self
        fileMenu.addItem(closeWindowItem)
        let clearSessionItem = NSMenuItem(
            title: localized("app.menu.clear.reading.session"),
            action: #selector(clearReadingSession(_:)),
            keyEquivalent: ""
        )
        clearSessionItem.target = self
        fileMenu.addItem(clearSessionItem)
        fileMenu.addItem(.separator())
        let refreshIndexItem = NSMenuItem(
            title: localized("app.menu.refresh.index"),
            action: #selector(refreshProjectIndex(_:)),
            keyEquivalent: "r"
        )
        refreshIndexItem.target = self
        fileMenu.addItem(refreshIndexItem)
        fileMenu.addItem(.separator())
        let trustItem = NSMenuItem(
            title: localized("app.menu.trust.this.repository"),
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
        let editMenu = NSMenu(title: localized("app.menu.edit"))
        editMenu.addItem(NSMenuItem(
            title: localized("app.menu.cut"),
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        ))
        editMenu.addItem(NSMenuItem(
            title: localized("app.menu.copy"),
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        ))
        editMenu.addItem(NSMenuItem(
            title: localized("app.menu.paste"),
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        ))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(
            title: localized("app.menu.select.all"),
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        ))
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let findItem = NSMenuItem()
        let findMenu = NSMenu(title: localized("app.menu.find"))
        let findInFileItem = NSMenuItem(
            title: localized("app.menu.find.in.file"),
            action: #selector(findInFile(_:)),
            keyEquivalent: "f"
        )
        findInFileItem.target = self
        findMenu.addItem(findInFileItem)
        let findNextItem = NSMenuItem(
            title: localized("app.menu.find.next"),
            action: #selector(findNext(_:)),
            keyEquivalent: "g"
        )
        findNextItem.target = self
        findMenu.addItem(findNextItem)
        let findPreviousItem = NSMenuItem(
            title: localized("app.menu.find.previous"),
            action: #selector(findPrevious(_:)),
            keyEquivalent: "g"
        )
        findPreviousItem.keyEquivalentModifierMask = [.command, .shift]
        findPreviousItem.target = self
        findMenu.addItem(findPreviousItem)
        findMenu.addItem(.separator())
        let findInProjectItem = NSMenuItem(
            title: localized("app.menu.find.in.project"),
            action: #selector(findInProject(_:)),
            keyEquivalent: "f"
        )
        findInProjectItem.keyEquivalentModifierMask = [.command, .shift]
        findInProjectItem.target = self
        findMenu.addItem(findInProjectItem)
        findItem.submenu = findMenu
        mainMenu.addItem(findItem)

        let goItem = NSMenuItem()
        let goMenu = NSMenu(title: localized("app.menu.go"))
        let commandPaletteItem = NSMenuItem(
            title: localized("app.menu.command.palette"),
            action: #selector(openCommandPalette(_:)),
            keyEquivalent: "p"
        )
        commandPaletteItem.keyEquivalentModifierMask = [.command, .shift]
        commandPaletteItem.target = self
        goMenu.addItem(commandPaletteItem)
        let symbolItem = NSMenuItem(
            title: localized("app.menu.open.symbol"),
            action: #selector(openSymbol(_:)),
            keyEquivalent: "t"
        )
        symbolItem.target = self
        goMenu.addItem(symbolItem)
        let lineItem = NSMenuItem(
            title: localized("app.menu.go.to.line"),
            action: #selector(goToLine(_:)),
            keyEquivalent: "l"
        )
        lineItem.target = self
        goMenu.addItem(lineItem)
        goMenu.addItem(.separator())
        let backItem = NSMenuItem(
            title: localized("app.menu.back"),
            action: #selector(goBack(_:)),
            keyEquivalent: "\u{F702}"
        )
        backItem.keyEquivalentModifierMask = [.command, .control]
        backItem.target = self
        goMenu.addItem(backItem)
        let forwardItem = NSMenuItem(
            title: localized("app.menu.forward"),
            action: #selector(goForward(_:)),
            keyEquivalent: "\u{F703}"
        )
        forwardItem.keyEquivalentModifierMask = [.command, .control]
        forwardItem.target = self
        goMenu.addItem(forwardItem)
        let alternateBackItem = NSMenuItem(
            title: localized("app.menu.back"),
            action: #selector(goBack(_:)),
            keyEquivalent: "["
        )
        alternateBackItem.keyEquivalentModifierMask = .command
        alternateBackItem.target = self
        alternateBackItem.isHidden = true
        alternateBackItem.allowsKeyEquivalentWhenHidden = true
        goMenu.addItem(alternateBackItem)
        let alternateForwardItem = NSMenuItem(
            title: localized("app.menu.forward"),
            action: #selector(goForward(_:)),
            keyEquivalent: "]"
        )
        alternateForwardItem.keyEquivalentModifierMask = .command
        alternateForwardItem.target = self
        alternateForwardItem.isHidden = true
        alternateForwardItem.allowsKeyEquivalentWhenHidden = true
        goMenu.addItem(alternateForwardItem)
        let previousTabItem = NSMenuItem(
            title: localized("app.menu.previous.tab"),
            action: #selector(selectPreviousTab(_:)),
            keyEquivalent: "["
        )
        previousTabItem.keyEquivalentModifierMask = [.command, .shift]
        previousTabItem.target = self
        goMenu.addItem(previousTabItem)
        let nextTabItem = NSMenuItem(
            title: localized("app.menu.next.tab"),
            action: #selector(selectNextTab(_:)),
            keyEquivalent: "]"
        )
        nextTabItem.keyEquivalentModifierMask = [.command, .shift]
        nextTabItem.target = self
        goMenu.addItem(nextTabItem)
        goMenu.addItem(.separator())
        let previousCandidate = NSMenuItem(
            title: localized("app.menu.previous.context.candidate"),
            action: #selector(previousContextCandidate(_:)),
            keyEquivalent: "\u{F702}"
        )
        previousCandidate.keyEquivalentModifierMask = [.command, .option]
        previousCandidate.target = self
        goMenu.addItem(previousCandidate)
        let nextCandidate = NSMenuItem(
            title: localized("app.menu.next.context.candidate"),
            action: #selector(nextContextCandidate(_:)),
            keyEquivalent: "\u{F703}"
        )
        nextCandidate.keyEquivalentModifierMask = [.command, .option]
        nextCandidate.target = self
        goMenu.addItem(nextCandidate)
        goMenu.addItem(.separator())
        let previousHunk = NSMenuItem(
            title: localized("app.menu.previous.diff.hunk"),
            action: #selector(previousDiffHunk(_:)),
            keyEquivalent: "\u{F700}"
        )
        previousHunk.keyEquivalentModifierMask = [.command, .option]
        previousHunk.target = self
        goMenu.addItem(previousHunk)
        let nextHunk = NSMenuItem(
            title: localized("app.menu.next.diff.hunk"),
            action: #selector(nextDiffHunk(_:)),
            keyEquivalent: "\u{F701}"
        )
        nextHunk.keyEquivalentModifierMask = [.command, .option]
        nextHunk.target = self
        goMenu.addItem(nextHunk)
        goItem.submenu = goMenu
        mainMenu.addItem(goItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: localized("app.menu.view"))
        let presetItem = NSMenuItem(title: localized("app.menu.preset"), action: nil, keyEquivalent: "")
        let presetMenu = NSMenu(title: localized("app.menu.preset"))
        let presets: [(PanelPresetModel, String, String)] = [
            (.reading, localized("app.menu.reading"), "1"),
            (.relations, localized("app.menu.relations"), "2"),
            (.compare, localized("app.menu.compare"), "3"),
            (.focus, localized("app.menu.focus"), "4"),
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
        let closeComparisonItem = NSMenuItem(
            title: localized("app.menu.close.comparison"),
            action: #selector(closeComparison(_:)),
            keyEquivalent: "w"
        )
        closeComparisonItem.keyEquivalentModifierMask = [.control, .command]
        closeComparisonItem.target = self
        viewMenu.addItem(closeComparisonItem)
        viewMenu.addItem(.separator())
        let foldingItem = NSMenuItem(
            title: localized("app.menu.folding"),
            action: nil,
            keyEquivalent: ""
        )
        let foldingMenu = NSMenu(title: localized("app.menu.folding"))
        let toggleFoldItem = NSMenuItem(
            title: localized("app.menu.toggle.fold"),
            action: #selector(toggleFold(_:)),
            keyEquivalent: "["
        )
        // ⌘⇧[ is already Previous Tab. P0 explicitly permits a non-conflicting
        // replacement, so keep the bracket mnemonic with ⌃⌘[.
        toggleFoldItem.keyEquivalentModifierMask = [.command, .control]
        toggleFoldItem.target = self
        foldingMenu.addItem(toggleFoldItem)
        let levels: [(String, Selector, String)] = [
            (localized("app.menu.full"), #selector(useFullReadingHeight(_:)), "0"),
            (localized("app.menu.structure"), #selector(useStructureReadingHeight(_:)), "1"),
            (localized("app.menu.overview"), #selector(useOverviewReadingHeight(_:)), "2"),
        ]
        for (title, action, key) in levels {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = [.command, .option]
            item.target = self
            foldingMenu.addItem(item)
        }
        foldingMenu.addItem(.separator())
        let focusItem = NSMenuItem(
            title: localized("app.menu.focus.current.scope"),
            action: #selector(focusCurrentScope(_:)),
            keyEquivalent: "f"
        )
        focusItem.keyEquivalentModifierMask = [.command, .option]
        focusItem.target = self
        foldingMenu.addItem(focusItem)
        foldingItem.submenu = foldingMenu
        viewMenu.addItem(foldingItem)
        viewMenu.addItem(.separator())
        let toggleBookmarkItem = NSMenuItem(
            title: localized("app.menu.toggle.bookmark"),
            action: #selector(toggleBookmark(_:)),
            keyEquivalent: "m"
        )
        toggleBookmarkItem.keyEquivalentModifierMask = [.command, .shift]
        toggleBookmarkItem.target = self
        viewMenu.addItem(toggleBookmarkItem)
        let showBookmarksItem = NSMenuItem(
            title: localized("app.menu.show.bookmarks"),
            action: #selector(showBookmarks(_:)),
            keyEquivalent: "b"
        )
        showBookmarksItem.keyEquivalentModifierMask = [.command, .option]
        showBookmarksItem.target = self
        viewMenu.addItem(showBookmarksItem)
        let closeBookmarksItem = NSMenuItem(
            title: localized("app.menu.hide.bookmarks"),
            action: #selector(closeBookmarks(_:)),
            keyEquivalent: ""
        )
        closeBookmarksItem.target = self
        viewMenu.addItem(closeBookmarksItem)
        viewMenu.addItem(.separator())
        let increaseFontItem = NSMenuItem(
            title: localized("app.menu.increase.font.size"),
            action: #selector(increaseReaderFontSize(_:)),
            keyEquivalent: "+"
        )
        increaseFontItem.keyEquivalentModifierMask = .command
        increaseFontItem.target = self
        viewMenu.addItem(increaseFontItem)
        let decreaseFontItem = NSMenuItem(
            title: localized("app.menu.decrease.font.size"),
            action: #selector(decreaseReaderFontSize(_:)),
            keyEquivalent: "-"
        )
        decreaseFontItem.keyEquivalentModifierMask = .command
        decreaseFontItem.target = self
        viewMenu.addItem(decreaseFontItem)
        let wrapLinesItem = NSMenuItem(
            title: localized("app.menu.wrap.lines"),
            action: #selector(toggleWrapLines(_:)),
            keyEquivalent: "z"
        )
        // ⌥Z (decision C1), grouped with the global reader settings.
        wrapLinesItem.keyEquivalentModifierMask = .option
        wrapLinesItem.target = self
        viewMenu.addItem(wrapLinesItem)
        viewMenu.addItem(.separator())
        let trailItem = NSMenuItem(
            title: localized("app.menu.show.reading.trail"),
            action: #selector(showReadingTrail(_:)),
            keyEquivalent: "t"
        )
        trailItem.keyEquivalentModifierMask = [.command, .option]
        trailItem.target = self
        viewMenu.addItem(trailItem)
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        let relationsItem = NSMenuItem()
        let relationsMenu = NSMenu(title: localized("app.menu.relations"))
        let toggleItem = NSMenuItem(
            title: localized("app.menu.show.hide.relations"),
            action: #selector(toggleRelations(_:)),
            keyEquivalent: "r"
        )
        toggleItem.keyEquivalentModifierMask = [.command, .control]
        toggleItem.target = self
        relationsMenu.addItem(toggleItem)
        relationsMenu.addItem(.separator())
        let callersItem = NSMenuItem(
            title: localized("app.menu.show.callers"),
            action: #selector(showCallers(_:)),
            keyEquivalent: "h"
        )
        callersItem.keyEquivalentModifierMask = [.command, .shift]
        callersItem.target = self
        relationsMenu.addItem(callersItem)
        let callsItem = NSMenuItem(
            title: localized("app.menu.show.calls"),
            action: #selector(showCalls(_:)),
            keyEquivalent: ""
        )
        callsItem.target = self
        relationsMenu.addItem(callsItem)
        let implementationsItem = NSMenuItem(
            title: localized("app.menu.show.implementations"),
            action: #selector(showImplementations(_:)),
            keyEquivalent: ""
        )
        implementationsItem.target = self
        relationsMenu.addItem(implementationsItem)
        relationsMenu.addItem(.separator())
        let inspectorItem = NSMenuItem(
            title: localized("app.menu.show.resolution.inspector"),
            action: #selector(showResolutionInspector(_:)),
            keyEquivalent: "i"
        )
        inspectorItem.keyEquivalentModifierMask = .command
        inspectorItem.target = self
        relationsMenu.addItem(inspectorItem)
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

    private static func menuItems(in menu: NSMenu?) -> [NSMenuItem] {
        guard let menu else { return [] }
        return menu.items.flatMap { item in
            [item] + menuItems(in: item.submenu)
        }
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
            exitSelfTest(channel: "base", status: passed ? 0 : 1)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exitSelfTest(channel: "base", status: 1)
        }
    }

    private static func tabGeometryChecks(
        _ geometry: (
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
        ),
        prefix: String,
        expectsVisibleStrip: Bool
    ) -> [String: Bool] {
        let tolerance: CGFloat = 1
        let contentBounds = geometry.contentFrame.insetBy(
            dx: -tolerance,
            dy: -tolerance
        )
        if expectsVisibleStrip {
            return [
                "\(prefix)StripVisible":
                    !geometry.stripHidden
                    && !geometry.stripHiddenOrHasHiddenAncestor
                    && geometry.stripFrame.width > 0
                    && geometry.stripFrame.height > 0,
                "\(prefix)StripInsideWindowContent":
                    contentBounds.contains(geometry.stripFrame),
                "\(prefix)StripInsideHeader":
                    geometry.headerFrame.insetBy(
                        dx: -tolerance,
                        dy: -tolerance
                    ).contains(geometry.stripFrame),
                "\(prefix)StripSharesReadingHeightRow":
                    abs(geometry.stripFrame.midY - geometry.controlFrame.midY)
                        <= tolerance,
                "\(prefix)StripStopsBeforeReadingHeight":
                    geometry.stripFrame.maxX
                        <= geometry.controlFrame.minX - 10 + tolerance,
                "\(prefix)ReadingHeightRightAligned":
                    abs(
                        geometry.controlFrame.maxX
                            - (geometry.headerFrame.maxX - 13)
                    ) <= tolerance,
                "\(prefix)ReaderFillsContainerHeight":
                    abs(
                        geometry.readerFrame.height
                            - geometry.containerFrame.height
                    ) <= tolerance,
                "\(prefix)ReaderFillsContainerWidth":
                    abs(
                        geometry.readerFrame.width
                            - geometry.containerFrame.width
                    ) <= tolerance,
            ]
        }
        return [
            "\(prefix)StripHidden":
                geometry.stripHidden
                && geometry.stripHiddenOrHasHiddenAncestor,
            "\(prefix)ReaderRestoresFullHeight":
                abs(
                    geometry.readerFrame.height
                        - geometry.containerFrame.height
                ) <= tolerance,
            "\(prefix)ReaderRestoresFullWidth":
                abs(
                    geometry.readerFrame.width
                        - geometry.containerFrame.width
                ) <= tolerance,
            "\(prefix)ReaderRestoresContainerTop":
                abs(
                    geometry.readerFrame.maxY
                        - geometry.containerFrame.maxY
                ) <= tolerance,
            "\(prefix)ReaderRestoresContainerBottom":
                abs(
                    geometry.readerFrame.minY
                        - geometry.containerFrame.minY
                ) <= tolerance,
        ]
    }

    private static func tabGeometryJSON(
        _ geometry: (
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
        )
    ) -> [String: Double] {
        [
            "stripMinY": geometry.stripFrame.minY,
            "stripMaxY": geometry.stripFrame.maxY,
            "stripWidth": geometry.stripFrame.width,
            "stripHeight": geometry.stripFrame.height,
            "headerMinY": geometry.headerFrame.minY,
            "headerMaxY": geometry.headerFrame.maxY,
            "controlMinX": geometry.controlFrame.minX,
            "controlMaxX": geometry.controlFrame.maxX,
            "scopeHeight": geometry.scopeHidden ? 0 : geometry.scopeFrame.height,
            "readerMinY": geometry.readerFrame.minY,
            "readerMaxY": geometry.readerFrame.maxY,
            "readerWidth": geometry.readerFrame.width,
            "readerHeight": geometry.readerFrame.height,
            "containerWidth": geometry.containerFrame.width,
            "containerHeight": geometry.containerFrame.height,
            "contentWidth": geometry.contentFrame.width,
            "contentHeight": geometry.contentFrame.height,
        ]
    }

    private static func finishTabsSelfTest(
        checks: [String: Bool],
        geometry: [String: Double],
        error: String?
    ) -> Never {
        let passed = error == nil
            && !checks.isEmpty
            && checks.values.allSatisfy { $0 }
        var summary: [String: Any] = checks
        summary["step"] = "summary"
        summary["geometry"] = geometry
        summary["passed"] = passed
        if let error { summary["error"] = error }
        writeJSON(summary)
        exitSelfTest(channel: "tabs", status: passed ? 0 : 1)
    }

    private static func finishReadingSelfTest(
        checks: [String: Bool],
        metrics: [String: Double],
        error: String?
    ) -> Never {
        let passed = error == nil
            && !checks.isEmpty
            && checks.values.allSatisfy { $0 }
        var summary: [String: Any] = checks
        summary["step"] = "summary"
        summary["metrics"] = metrics
        summary["passed"] = passed
        if let error { summary["error"] = error }
        writeJSON(summary)
        exitSelfTest(channel: "reading", status: passed ? 0 : 1)
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
            let projectIndexReadyWithinBudget =
                indexReadyMS < SelfTestBudgets.projectIndexReadyMS
            var object: [String: Any] = [
                "treeVisibleMS": treeVisibleMS,
                "indexReadyMS": indexReadyMS,
                "fileCount": fileCount,
                "reused": reused,
                "extracted": extracted,
                "projectIndexReadyWithinBudget":
                    projectIndexReadyWithinBudget,
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
            exitSelfTest(
                channel: "project",
                status: ready
                    && emptyStateRemoved
                    && readerDocumentVisible
                    && commitPickerShowsCurrentBranch
                    && indexStatusVisibleDuringIndexing
                    && statusBarVisibleAfterReady
                    && indexStatusHiddenAfterFullReady
                    && layoutChecks.values.allSatisfy { $0 }
                    && treeVisibleMS < SelfTestBudgets.projectTreeVisibleMS
                    && projectIndexReadyWithinBudget
                    ? 0 : 1
            )
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exitSelfTest(channel: "project", status: 1)
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
            exitSelfTest(
                channel: "switch",
                status: firstPaintMS >= 0
                    && firstPaintMS < SelfTestBudgets.snapshotFirstPaintMS
                    && cachedReadyMS >= firstPaintMS
                    && fullReadyMS >= cachedReadyMS
                    && ready
                    ? 0 : 1
            )
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exitSelfTest(channel: "switch", status: 1)
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
        exitSelfTest(channel: "history", status: passed ? 0 : 1)
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

    private static func exitSelfTest(
        channel: String,
        status: Int32
    ) -> Never {
        let marker = "SELF_TEST_FINISH"
            + " timestamp=\(Date().timeIntervalSince1970)"
            + " pid=\(getpid()) channel=\(channel) exit=\(status)\n"
        FileHandle.standardError.write(Data(marker.utf8))
        Darwin.exit(status)
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
            exitSelfTest(channel: "open", status: withinBudget ? 0 : 1)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exitSelfTest(channel: "open", status: 1)
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
    let referenceLocations: [ExactLocation]
    let dependencyFile: URL
    let dependencyBytes: [UInt8]
    let dependencyDefinition: ExactLocation
    let relationFile: URL
    let relationCallOffset: UInt32
    let relationRootOffset: UInt32?
    let localReferenceDeclarationOffset: UInt32?
    let localReferenceUseOffset: UInt32?
    let signatureTraitOffset: UInt32?
    let externalRootOffset: UInt32?
    let externalCallOffset: UInt32?
    let typedReceiverRootOffset: UInt32?
    let inferredReceiverRootOffset: UInt32?
    let traitObjectReceiverRootOffset: UInt32?
}

private struct ExactSelfTestIndexService: IndexService {
    func index(root: URL, language: LanguageID) async throws -> EngineSession {
        try await Task.detached(priority: .userInitiated) {
            try ProjectIndexer().index(root: root, language: language)
        }.value
    }
}

struct ExactSelfTestDirectorySnapshot: Snapshot {
    let snapshotID = SnapshotID(rawValue: UUID())
    let objectFormat = GitObjectFormat.sha1
    let sourceKind = SourceKind.untracked
    let configurationPaths = ["Cargo.toml"]
    private let root: URL
    private let files = ["src/lib.rs", "src/main.rs"]

    init(root: URL) throws {
        self.root = root.standardizedFileURL
        for file in files {
            _ = try Data(contentsOf: self.root.appendingPathComponent(file))
        }
        _ = try Data(
            contentsOf: root.appendingPathComponent("Cargo.toml"),
            options: .mappedIfSafe
        )
    }

    func listFiles() -> [(path: String, contentID: ContentID, fileMode: FileMode)] {
        files.compactMap { path in
            guard let bytes = try? readBytes(path: path) else { return nil }
            return (path, ContentID.sha256(of: bytes), .regular)
        }
    }

    func readBytes(path: String) throws -> [UInt8] {
        if path == "Cargo.toml" {
            return [UInt8](try Data(
                contentsOf: root.appendingPathComponent(path),
                options: .mappedIfSafe
            ))
        }
        guard files.contains(path) else { throw GitError.missingPath(path) }
        return [UInt8](try Data(
            contentsOf: root.appendingPathComponent(path),
            options: .mappedIfSafe
        ))
    }

}

final class InProcessExactProvider: ExactProvider, @unchecked Sendable {
    let language: LanguageID = .rust
    let capabilities: ExactCapabilities
    let toolVersion = "in-process-fake-1"
    private let negotiatedCapabilities: ExactCapabilities
    private let location: ExactLocation?
    private let implementationLocations: [ExactLocation]?
    private let referenceLocations: [ExactLocation]?
    private let callHierarchyItems: [ExactCallHierarchyItem]?
    private let incomingRelations: [ExactCallRelation]?
    private let outgoingRelations: [ExactCallRelation]?
    private let externalFile: String?
    private let externalOffset: Int?
    private let externalLocation: ExactLocation?
    private let state: ExactSelfTestProviderState?
    private let limitations: Set<ExactAnalysisLimitation>?

    init(
        location: ExactLocation?,
        capabilities: ExactCapabilities = [.definition],
        negotiatedCapabilities: ExactCapabilities? = nil,
        implementationLocations: [ExactLocation]? = nil,
        referenceLocations: [ExactLocation]? = nil,
        callHierarchyItems: [ExactCallHierarchyItem]? = nil,
        incomingRelations: [ExactCallRelation]? = nil,
        outgoingRelations: [ExactCallRelation]? = nil,
        externalFile: String? = nil,
        externalOffset: Int? = nil,
        externalLocation: ExactLocation? = nil,
        state: ExactSelfTestProviderState? = nil,
        limitations: Set<ExactAnalysisLimitation>? = nil
    ) {
        self.location = location
        self.capabilities = capabilities
        self.negotiatedCapabilities = negotiatedCapabilities ?? capabilities
        self.implementationLocations = implementationLocations
        self.referenceLocations = referenceLocations
        self.callHierarchyItems = callHierarchyItems
        self.incomingRelations = incomingRelations
        self.outgoingRelations = outgoingRelations
        self.externalFile = externalFile
        self.externalOffset = externalOffset
        self.externalLocation = externalLocation
        self.state = state
        self.limitations = limitations
    }

    func prepare(
        snapshot: any Snapshot,
        profile: ExactProfileKey,
        trustMode: TrustMode
    ) throws -> any ExactSession {
        let ordinal = state?.recordPrepare(
            trustMode: trustMode,
            featureSelection: profile.featureSelection
        )
        return InProcessExactSession(
            negotiatedCapabilities: negotiatedCapabilities,
            location: location,
            implementationLocations: implementationLocations,
            referenceLocations: referenceLocations,
            callHierarchyItems: callHierarchyItems,
            incomingRelations: incomingRelations,
            outgoingRelations: outgoingRelations,
            externalFile: externalFile,
            externalOffset: externalOffset,
            externalLocation: externalLocation,
            attribution: ExactAttribution(
                provider: "fake-exact",
                toolVersion: toolVersion,
                configFingerprint: profile.configFingerprint,
                environmentFingerprint: profile.environmentFingerprint,
                featureSelection: profile.featureSelection,
                environment: ExactAnalysisEnvironment(
                    trustMode: trustMode,
                    limitations: limitations ?? (trustMode == .safe
                        ? [.buildScriptsDisabled, .procMacrosDisabled]
                        : [])
                ),
                generatedAt: Date(timeIntervalSince1970: 0)
            ),
            ordinal: ordinal,
            state: state
        )
    }
}

private final class InProcessExactSession: ExactSession, @unchecked Sendable {
    let negotiatedCapabilities: ExactCapabilities
    let readiness: ExactReadiness = .ready
    let attribution: ExactAttribution
    private let location: ExactLocation?
    private let implementationLocations: [ExactLocation]?
    private let referenceLocations: [ExactLocation]?
    private let callHierarchyItems: [ExactCallHierarchyItem]?
    private let incomingRelations: [ExactCallRelation]?
    private let outgoingRelations: [ExactCallRelation]?
    private let externalFile: String?
    private let externalOffset: Int?
    private let externalLocation: ExactLocation?
    private let ordinal: Int?
    private let state: ExactSelfTestProviderState?

    init(
        negotiatedCapabilities: ExactCapabilities,
        location: ExactLocation?,
        implementationLocations: [ExactLocation]?,
        referenceLocations: [ExactLocation]?,
        callHierarchyItems: [ExactCallHierarchyItem]?,
        incomingRelations: [ExactCallRelation]?,
        outgoingRelations: [ExactCallRelation]?,
        externalFile: String?,
        externalOffset: Int?,
        externalLocation: ExactLocation?,
        attribution: ExactAttribution,
        ordinal: Int?,
        state: ExactSelfTestProviderState?
    ) {
        self.negotiatedCapabilities = negotiatedCapabilities
        self.location = location
        self.implementationLocations = implementationLocations
        self.referenceLocations = referenceLocations
        self.callHierarchyItems = callHierarchyItems
        self.incomingRelations = incomingRelations
        self.outgoingRelations = outgoingRelations
        self.externalFile = externalFile
        self.externalOffset = externalOffset
        self.externalLocation = externalLocation
        self.attribution = attribution
        self.ordinal = ordinal
        self.state = state
    }

    func definition(
        file: String,
        byteOffset: Int
    ) throws -> ExactDefinitionQueryResult {
        guard negotiatedCapabilities.contains(.definition) else {
            return .unavailable("definition unsupported")
        }
        state?.recordDefinitionRequest()
        let wasBlocked = state?.waitIfDefinitionIsBlocked() == true
        defer {
            if wasBlocked { state?.recordBlockedDefinitionReturned() }
        }
        Thread.sleep(forTimeInterval: 0.25)
        if file == externalFile, byteOffset == externalOffset {
            return .completed(externalLocation.map {
                [ExactTarget(location: $0)]
            } ?? [])
        }
        return .completed(location.map { [ExactTarget(location: $0)] } ?? [])
    }

    func implementations(
        file: String,
        byteOffset: Int
    ) throws -> [ExactLocation]? {
        guard negotiatedCapabilities.contains(.implementations) else {
            return nil
        }
        return implementationLocations
    }

    func references(
        file: String,
        byteOffset: Int,
        includeDeclaration: Bool
    ) throws -> [ExactLocation]? {
        guard negotiatedCapabilities.contains(.references) else {
            return nil
        }
        return referenceLocations
    }

    func prepareCallHierarchy(
        file: String,
        byteOffset: Int
    ) throws -> [ExactCallHierarchyItem]? {
        guard negotiatedCapabilities.contains(.callHierarchy) else {
            return nil
        }
        return callHierarchyItems
    }

    func incomingCalls(
        item: ExactCallHierarchyItem
    ) throws -> [ExactCallRelation]? {
        guard negotiatedCapabilities.contains(.callHierarchy) else {
            return nil
        }
        state?.waitForNextRelationDelay()
        let wasBlocked = state?.waitIfRelationIsBlocked() == true
        defer {
            if wasBlocked { state?.recordBlockedRelationReturned() }
        }
        return incomingRelations
    }

    func outgoingCalls(
        item: ExactCallHierarchyItem
    ) throws -> [ExactCallRelation]? {
        guard negotiatedCapabilities.contains(.callHierarchy) else {
            return nil
        }
        state?.waitForNextRelationDelay()
        let wasBlocked = state?.waitIfRelationIsBlocked() == true
        defer {
            if wasBlocked { state?.recordBlockedRelationReturned() }
        }
        return outgoingRelations
    }

    func cancel() {}
    func close() {
        if let ordinal { state?.recordClose(ordinal: ordinal) }
    }
}

final class ExactSelfTestProviderState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRoot: URL?
    private var storedTrustModes: [String] = []
    private var storedFeatureSelections: [FeatureSelection] = []
    private var storedClosedSessions: Set<Int> = []
    private var storedDefinitionRequestCount = 0
    private var nextRelationDelay: TimeInterval = 0
    private let definitionCondition = NSCondition()
    private var shouldBlockNextDefinition = false
    private var blockedDefinition = false
    private var didReturnBlockedDefinition = false
    private let relationCondition = NSCondition()
    private var shouldBlockNextRelation = false
    private var blockedRelation = false
    private var didReturnBlockedRelation = false

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

    var featureSelections: [FeatureSelection] {
        lock.lock()
        defer { lock.unlock() }
        return storedFeatureSelections
    }

    var definitionRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedDefinitionRequestCount
    }

    func recordDefinitionRequest() {
        lock.lock()
        storedDefinitionRequestCount += 1
        lock.unlock()
    }

    func delayNextRelation(by delay: TimeInterval) {
        lock.lock()
        nextRelationDelay = min(max(delay, 0), 1)
        lock.unlock()
    }

    func waitForNextRelationDelay() {
        lock.lock()
        let delay = nextRelationDelay
        nextRelationDelay = 0
        lock.unlock()
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
    }

    var definitionIsBlocked: Bool {
        definitionCondition.lock()
        defer { definitionCondition.unlock() }
        return blockedDefinition
    }

    var blockedDefinitionReturned: Bool {
        definitionCondition.lock()
        defer { definitionCondition.unlock() }
        return didReturnBlockedDefinition
    }

    var relationIsBlocked: Bool {
        relationCondition.lock()
        defer { relationCondition.unlock() }
        return blockedRelation
    }

    var blockedRelationReturned: Bool {
        relationCondition.lock()
        defer { relationCondition.unlock() }
        return didReturnBlockedRelation
    }

    func recordPrepare(
        trustMode: TrustMode,
        featureSelection: FeatureSelection
    ) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let mode = switch trustMode {
        case .safe: "safe"
        case .trusted: "trusted"
        }
        storedTrustModes.append(mode)
        storedFeatureSelections.append(featureSelection)
        return storedTrustModes.count
    }

    func blockNextDefinition() {
        definitionCondition.lock()
        shouldBlockNextDefinition = true
        blockedDefinition = false
        didReturnBlockedDefinition = false
        definitionCondition.unlock()
    }

    func waitIfDefinitionIsBlocked() -> Bool {
        definitionCondition.lock()
        guard shouldBlockNextDefinition else {
            definitionCondition.unlock()
            return false
        }
        shouldBlockNextDefinition = false
        blockedDefinition = true
        definitionCondition.broadcast()
        while blockedDefinition { definitionCondition.wait() }
        definitionCondition.unlock()
        return true
    }

    func releaseBlockedDefinition() {
        definitionCondition.lock()
        shouldBlockNextDefinition = false
        blockedDefinition = false
        definitionCondition.broadcast()
        definitionCondition.unlock()
    }

    func recordBlockedDefinitionReturned() {
        definitionCondition.lock()
        didReturnBlockedDefinition = true
        definitionCondition.broadcast()
        definitionCondition.unlock()
    }

    func blockNextRelation() {
        relationCondition.lock()
        shouldBlockNextRelation = true
        blockedRelation = false
        didReturnBlockedRelation = false
        relationCondition.unlock()
    }

    func waitIfRelationIsBlocked() -> Bool {
        relationCondition.lock()
        guard shouldBlockNextRelation else {
            relationCondition.unlock()
            return false
        }
        shouldBlockNextRelation = false
        blockedRelation = true
        relationCondition.broadcast()
        while blockedRelation { relationCondition.wait() }
        relationCondition.unlock()
        return true
    }

    func releaseBlockedRelation() {
        relationCondition.lock()
        shouldBlockNextRelation = false
        blockedRelation = false
        relationCondition.broadcast()
        relationCondition.unlock()
    }

    func recordBlockedRelationReturned() {
        relationCondition.lock()
        didReturnBlockedRelation = true
        relationCondition.broadcast()
        relationCondition.unlock()
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
    let dependencyFile = root.deletingLastPathComponent()
        .appendingPathComponent(
            "fake-registry/registry/src/"
                + "index.crates.io-1949cf8c6b5b557f/"
                + "dependency-fixture-1.2.3/src/lib.rs"
        )
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
          let clickCoordinate = LineTable(bytes: Array(source.utf8))
              .lineColumn(at: clickOffset),
          let coordinate = LineTable(bytes: Array(definitionSource.utf8))
              .lineColumn(at: definitionOffset),
          let relationCallCoordinate = LineTable(
              bytes: Array(definitionSource.utf8)
          ).lineColumn(at: relationCallOffset)
    else { return nil }
    let relationRootOffset = definitionSource.range(
        of: "pub fn relation_root"
    ).flatMap {
        definitionSource[$0].range(of: "relation_root")
    }.flatMap {
        UInt32(exactly: definitionSource[..<$0.lowerBound].utf8.count)
    }
    let localReferenceDeclarationOffset = definitionSource.range(
        of: "receiver = InferredReceiver::new()"
    ).flatMap {
        UInt32(exactly: definitionSource[..<$0.lowerBound].utf8.count)
    }
    let localReferenceUseOffset = definitionSource.range(
        of: "receiver.inferred_edge()"
    ).flatMap {
        UInt32(exactly: definitionSource[..<$0.lowerBound].utf8.count)
    }
    let dependencyBytes: [UInt8]
    let dependencyDefinition: ExactLocation
    let resolvedDependencyFile: URL
    if let bytes = try? [UInt8](Data(contentsOf: dependencyFile)),
       let dependencySource = String(bytes: bytes, encoding: .utf8),
       let dependencyRange = dependencySource.range(of: "dependency_target"),
       let dependencyOffset = UInt32(exactly: dependencySource[
           ..<dependencyRange.lowerBound
       ].utf8.count),
       let dependencyCoordinate = LineTable(bytes: bytes)
           .lineColumn(at: dependencyOffset)
    {
        dependencyBytes = bytes
        resolvedDependencyFile = dependencyFile
        dependencyDefinition = ExactLocation(
            file: dependencyFile.path,
            byteOffset: Int(dependencyOffset),
            line: Int(dependencyCoordinate.line),
            column: Int(dependencyCoordinate.column)
        )
    } else {
        dependencyBytes = Array(definitionSource.utf8)
        resolvedDependencyFile = relationFile
        dependencyDefinition = ExactLocation(
            file: definitionPath,
            byteOffset: Int(definitionOffset),
            line: Int(coordinate.line),
            column: Int(coordinate.column)
        )
    }
    let signatureTraitOffset = definitionSource.range(
        of: "pub trait Backend"
    ).flatMap {
        definitionSource[$0].range(of: "Backend")
    }.flatMap {
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
    let typedReceiverRootOffset = definitionSource.range(
        of: "typed_receiver_call"
    ).flatMap {
        UInt32(exactly: definitionSource[..<$0.lowerBound].utf8.count)
    }
    let inferredReceiverRootOffset = definitionSource.range(
        of: "inferred_receiver_call"
    ).flatMap {
        UInt32(exactly: definitionSource[..<$0.lowerBound].utf8.count)
    }
    let traitObjectReceiverRootOffset = definitionSource.range(
        of: "trait_object_receiver_call"
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
        referenceLocations: [
            ExactLocation(
                file: path,
                byteOffset: Int(clickOffset),
                line: Int(clickCoordinate.line),
                column: Int(clickCoordinate.column)
            ),
            ExactLocation(
                file: definitionPath,
                byteOffset: Int(relationCallOffset),
                line: Int(relationCallCoordinate.line),
                column: Int(relationCallCoordinate.column)
            ),
        ],
        dependencyFile: resolvedDependencyFile,
        dependencyBytes: dependencyBytes,
        dependencyDefinition: dependencyDefinition,
        relationFile: relationFile,
        relationCallOffset: relationCallOffset,
        relationRootOffset: relationRootOffset,
        localReferenceDeclarationOffset: localReferenceDeclarationOffset,
        localReferenceUseOffset: localReferenceUseOffset,
        signatureTraitOffset: signatureTraitOffset,
        externalRootOffset: externalRootOffset,
        externalCallOffset: externalCallOffset,
        typedReceiverRootOffset: typedReceiverRootOffset,
        inferredReceiverRootOffset: inferredReceiverRootOffset,
        traitObjectReceiverRootOffset: traitObjectReceiverRootOffset
    )
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

private func makeTabsSelfTestRepository() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "CodeInsightTabsFixture-\(UUID().uuidString)",
        isDirectory: true
    )
    do {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("src"),
            withIntermediateDirectories: true
        )
        try Data(
            "[package]\nname='tabs'\nversion='0.1.0'\nedition='2021'\n".utf8
        ).write(to: root.appendingPathComponent("Cargo.toml"))
        let lines = (0..<240).map {
            String(format: "    let anchor_%03d = %d;", $0, $0)
        }
        let sourceA = (["pub fn a() {"] + lines + ["}"]).joined(separator: "\n")
        try Data(sourceA.utf8).write(
            to: root.appendingPathComponent("src/a.rs")
        )
        try exactSelfTestGit(root, "init", "-q")
        try exactSelfTestGit(root, "config", "user.name", "CodeInsight Tests")
        try exactSelfTestGit(
            root,
            "config",
            "user.email",
            "tests@codeinsight.invalid"
        )
        try exactSelfTestGit(root, "add", "-A")
        try exactSelfTestGit(root, "commit", "-q", "-m", "A only")
        try Data("pub fn b() -> &'static str { \"tab B\" }\n".utf8).write(
            to: root.appendingPathComponent("src/b.rs")
        )
        try exactSelfTestGit(root, "add", "-A")
        try exactSelfTestGit(root, "commit", "-q", "-m", "add B")
        return root
    } catch {
        try? FileManager.default.removeItem(at: root)
        throw error
    }
}

private func makeSearchSelfTestDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodeInsightSearchSelfTest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    var nextMatch = 0
    for fileIndex in 0..<11 {
        let matchCount = fileIndex < 10 ? 182 : 181
        var source = ""
        for _ in 0..<matchCount {
            source += "fn item_\(nextMatch)() { let zzqqmarker = \(nextMatch); }\n"
            nextMatch += 1
        }
        try Data(source.utf8).write(
            to: root.appendingPathComponent("fixture_\(fileIndex).rs")
        )
    }
    precondition(nextMatch == 2_001)
    return root
}

private func makeReadingSelfTestDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "CodeInsightReadingFixture-\(UUID().uuidString)",
        isDirectory: true
    )
    do {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try Data("""
            [package]
            name = "reading-self-test"
            version = "0.1.0"
            edition = "2021"
            """.utf8).write(to: root.appendingPathComponent("Cargo.toml"))
        try Data("""
            fn alpha() {}
            fn beta() { alpha(); }
            fn gamma() { alpha(); beta(); } fn p0() {}
            """.utf8).write(to: root.appendingPathComponent("regular.rs"))
        let huge = String(repeating: "needle\n", count: 200)
            + String(repeating: "\n", count: 99_799)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("target"),
            withIntermediateDirectories: true
        )
        try Data(huge.utf8).write(
            to: root.appendingPathComponent("target/huge.rs")
        )
        let referenceFixture = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath
        ).appendingPathComponent("Tests/Fixtures/m6_reference_density.rust")
        try FileManager.default.copyItem(
            at: referenceFixture,
            to: root.appendingPathComponent("target/m6_reference_density.rs")
        )
        try Data("fn use_reference() { p0(); }\n".utf8).write(
            to: root.appendingPathComponent("a_reference_use.rs")
        )
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

@MainActor
private func runFoldPerformance(
    mode: String,
    fixture: URL,
    output: URL
) -> Never {
    func write(_ object: [String: Any], status: Int32) -> Never {
        do {
            let data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
            try data.write(to: output, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            Darwin.exit(1)
        }
        Darwin.exit(status)
    }

    let collector = PerfResolutionCollector()
    let loader = DocumentLoader(
        source: { file in Array(try Data(contentsOf: file, options: .mappedIfSafe)) },
        foldResolutionObserver: { milliseconds, candidates, accepted in
            collector.record(
                milliseconds: milliseconds,
                candidates: candidates,
                accepted: accepted
            )
        }
    )
    let initial: ReaderDocument
    do {
        initial = try loader.load(file: fixture).document
    } catch {
        write([
            "schemaVersion": 1,
            "mode": mode,
            "status": "error",
            "error": "fixture load failed: \(error)",
        ], status: 1)
    }

    let peakBytes = OSAllocatedUnfairLock(
        initialState: physicalFootprintBytes() ?? 0
    )
    let samplerQueue = DispatchQueue(label: "com.codeinsight.fold-perf-sampler")
    let sampler = DispatchSource.makeTimerSource(queue: samplerQueue)
    sampler.schedule(
        deadline: .now(),
        repeating: .milliseconds(25),
        leeway: .milliseconds(2)
    )
    let sampleMemory: @Sendable () -> Void = {
        guard let bytes = physicalFootprintBytes() else { return }
        peakBytes.withLock { $0 = max($0, bytes) }
    }
    sampler.setEventHandler(handler: sampleMemory)
    sampler.resume()

    func stopSampler() -> UInt64 {
        sampler.cancel()
        samplerQueue.sync {}
        return peakBytes.withLock { $0 }
    }

    let reader = ReaderTextView()
    var settings = ReaderSettings()
    settings.fontSize = 13
    settings.wrapLines = false
    settings.lineNumbers = true
    settings.theme = .siClassic
    reader.apply(settings: settings)

    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 1440, height: 900))
    window.contentView = host
    let scrollView = NSScrollView(
        frame: NSRect(x: 100, y: 60, width: 1220, height: 780)
    )
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true
    scrollView.documentView = reader.view
    host.addSubview(scrollView)
    reader.view.frame = scrollView.contentView.bounds
    reader.display(document: initial, fileURL: fixture)

    func fitViewport() {
        for _ in 0..<4 {
            scrollView.tile()
            let size = scrollView.contentView.bounds.size
            let delta = NSSize(width: 1200 - size.width, height: 760 - size.height)
            guard abs(delta.width) > 0.01 || abs(delta.height) > 0.01 else {
                break
            }
            scrollView.setFrameSize(NSSize(
                width: scrollView.frame.width + delta.width,
                height: scrollView.frame.height + delta.height
            ))
        }
        scrollView.tile()
    }
    fitViewport()
    window.displayIfNeeded()

    let syntaxResult = OSAllocatedUnfairLock(
        initialState: Optional<Result<ReaderDocument, RustHighlighterError>>.none
    )
    loader.loadSyntax(for: initial) { result in
        syntaxResult.withLock { $0 = result }
    }
    guard waitUntil(timeout: 10, condition: {
        syntaxResult.withLock { $0 != nil }
    }), let result = syntaxResult.withLock({ $0 })
    else {
        let peak = stopSampler()
        write([
            "schemaVersion": 1,
            "mode": mode,
            "status": "timeout",
            "samplePeriodMs": 25,
            "peakPhysBytes": peak,
        ], status: 1)
    }
    let document: ReaderDocument
    switch result {
    case .success(let loaded):
        document = loaded
    case .failure(let error):
        let peak = stopSampler()
        write([
            "schemaVersion": 1,
            "mode": mode,
            "status": "error",
            "error": "syntax load failed: \(error)",
            "samplePeriodMs": 25,
            "peakPhysBytes": peak,
        ], status: 1)
    }

    reader.updateSyntax(document: document)
    fitViewport()
    reader.view.textLayoutManager?.textViewportLayoutController.layoutViewport()
    window.displayIfNeeded()
    pumpRunLoop()

    var foldLatencyMS: Double?
    let observedCounts: (logical: Int, rendered: Int)
    if mode == "fold" {
        let started = ContinuousClock.now
        guard let counts = reader.applyFoldPerformanceOverview() else {
            let peak = stopSampler()
            write([
                "schemaVersion": 1,
                "mode": mode,
                "status": "error",
                "error": "overview projection failed",
                "samplePeriodMs": 25,
                "peakPhysBytes": peak,
            ], status: 1)
        }
        observedCounts = counts
        fitViewport()
        reader.view.textLayoutManager?.textViewportLayoutController.layoutViewport()
        window.displayIfNeeded()
        foldLatencyMS = milliseconds(since: started)
        pumpRunLoop()
        pumpRunLoop()
    } else {
        observedCounts = reader.foldPerformanceCounts
        pumpRunLoop()
        pumpRunLoop()
    }

    guard waitUntil(timeout: 10, condition: {
        guard let fragment = reader.view.textLayoutManager?
            .textLayoutFragment(for: .zero)
        else { return false }
        return !fragment.textLineFragments.isEmpty
    }) else {
        let peak = stopSampler()
        write([
            "schemaVersion": 1,
            "mode": mode,
            "status": "timeout",
            "samplePeriodMs": 25,
            "peakPhysBytes": peak,
        ], status: 1)
    }

    let peak = stopSampler()
    let samples = collector.snapshot()
    guard samples.count == 1, let resolution = samples.first else {
        write([
            "schemaVersion": 1,
            "mode": mode,
            "status": "error",
            "error": "expected exactly one resolution sample, got \(samples.count)",
            "samplePeriodMs": 25,
            "peakPhysBytes": peak,
        ], status: 1)
    }
    let storage = reader.view.textStorage
    let resolvedFont: NSFont? = storage.flatMap { storage in
        guard storage.length > 0 else { return nil }
        return storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    }
    let viewport = scrollView.contentView.bounds.size
    let windowSize = window.contentView?.bounds.size ?? .zero
    let effective = reader.foldPerformanceEffectiveSettings
    let themeName = switch effective.theme {
    case .siClassic: "SI Classic"
    case .dark: "Dark"
    case .light: "Light"
    case .auto: "Auto"
    }
    let wrapLines = reader.view.textContainer?.widthTracksTextView == true
    let fixtureSHA = document.contentID.bytes
        .map { String(format: "%02x", $0) }
        .joined()
    var object: [String: Any] = [
        "schemaVersion": 1,
        "mode": mode,
        "fixtureSHA256": fixtureSHA,
        "samplePeriodMs": 25,
        "perfConfig": [
            "wrapLines": wrapLines,
            "resolvedFontName": resolvedFont?.fontName ?? "",
            "resolvedFontSizePt": resolvedFont?.pointSize ?? 0,
            "windowPt": [windowSize.width, windowSize.height],
            "viewportPt": [viewport.width, viewport.height],
            "lineNumbers": effective.lineNumbers,
            "theme": themeName,
        ],
        "observed": [
            "candidateCount": resolution.candidates,
            "acceptedFoldCount": resolution.accepted,
            "logicalFoldCount": observedCounts.logical,
            "renderedFoldCount": observedCounts.rendered,
        ],
        "status": "ok",
        "resolutionMs": resolution.milliseconds,
        "peakPhysBytes": peak,
    ]
    if let foldLatencyMS { object["foldLatencyMs"] = foldLatencyMS }
    let configurationIsExact = abs(viewport.width - 1200) < 0.01
        && abs(viewport.height - 760) < 0.01
        && abs(windowSize.width - 1440) < 0.01
        && abs(windowSize.height - 900) < 0.01
        && resolvedFont != nil
        && abs((resolvedFont?.pointSize ?? 0) - 13) < 0.01
        && !wrapLines
        && effective.lineNumbers
        && effective.theme == .siClassic
    if !configurationIsExact {
        object["status"] = "error"
        object["error"] = "effective performance configuration mismatch"
    }
    withExtendedLifetime((reader, window, scrollView)) {}
    write(object, status: configurationIsExact ? 0 : 1)
}

/// Soft-wrap performance mode (§7.4.1/§7.4.2). Unlike the fold runner, this
/// entry must not hard-code `wrapLines = false`: the requested wrap state is
/// a parameter, and the effective configuration (width tracking, scroller
/// visibility) is verified against the request instead of echoing it back.
@MainActor
private func runWrapPerformance(_ request: WrapPerformanceRequest) -> Never {
    func write(_ object: [String: Any], status: Int32) -> Never {
        do {
            let data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
            try data.write(to: request.output, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            Darwin.exit(1)
        }
        Darwin.exit(status)
    }

    var fixtureBytes: [UInt8] = []
    do {
        fixtureBytes = Array(try Data(
            contentsOf: request.fixture,
            options: .mappedIfSafe
        ))
    } catch {
        write([
            "schemaVersion": 1,
            "codeSHA": request.codeSHA,
            "scenario": request.scenario,
            "status": "error",
            "error": "fixture read failed: \(error)",
        ], status: 1)
    }

    let peakBytes = OSAllocatedUnfairLock(
        initialState: physicalFootprintBytes() ?? 0
    )
    let samplerQueue = DispatchQueue(label: "com.codeinsight.wrap-perf-sampler")
    let sampler = DispatchSource.makeTimerSource(queue: samplerQueue)
    sampler.schedule(
        deadline: .now(),
        repeating: .milliseconds(25),
        leeway: .milliseconds(2)
    )
    let sampleMemory: @Sendable () -> Void = {
        guard let bytes = physicalFootprintBytes() else { return }
        peakBytes.withLock { $0 = max($0, bytes) }
    }
    sampler.setEventHandler(handler: sampleMemory)
    sampler.resume()

    // Main-thread stall probe: a 5ms heartbeat on a background queue whose
    // main-queue continuations record how late they actually ran. The maximum
    // lateness over the window approximates the longest contiguous stall.
    let stallWindow = OSAllocatedUnfairLock(initialState: 0.0)
    let stallQueue = DispatchQueue(label: "com.codeinsight.wrap-perf-stall")
    let stallTimer = DispatchSource.makeTimerSource(queue: stallQueue)
    stallTimer.schedule(
        deadline: .now(),
        repeating: .milliseconds(5),
        leeway: .milliseconds(1)
    )
    // Explicit @Sendable typing keeps this handler nonisolated: it runs on the
    // probe queue, only its main-queue continuation touches main state.
    let heartbeat: @Sendable () -> Void = {
        let scheduled = ContinuousClock.now
        DispatchQueue.main.async {
            let lateness = milliseconds(since: scheduled)
            stallWindow.withLock { $0 = max($0, lateness) }
        }
    }
    stallTimer.setEventHandler(handler: heartbeat)
    stallTimer.resume()

    func stopProbes() -> (peak: UInt64, longestStallMs: Double) {
        sampler.cancel()
        stallTimer.cancel()
        samplerQueue.sync {}
        stallQueue.sync {}
        return (peakBytes.withLock { $0 }, stallWindow.withLock { $0 })
    }

    // Stall samples during fixture load and initial setup would swamp the
    // per-scenario budget; the measurement window starts clean (§7.4.2).
    func resetStallProbe() {
        stallWindow.withLock { $0 = 0 }
    }

    let reader = ReaderTextView()
    var baseSettings = ReaderSettings()
    baseSettings.fontSize = 13
    baseSettings.lineNumbers = true
    baseSettings.theme = .siClassic

    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 1440, height: 900))
    window.contentView = host
    let scrollView = NSScrollView(
        frame: NSRect(x: 100, y: 60, width: 1220, height: 780)
    )
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true
    // Overlay + autohide scrollers never consume content-view space, so the
    // clip geometry stays exactly 1200x760 across wrap toggles (legacy
    // scrollers appearing and disappearing would drift it by a knob width
    // and break the configuration check).
    scrollView.scrollerStyle = .overlay
    scrollView.autohidesScrollers = true
    scrollView.documentView = reader.view
    host.addSubview(scrollView)
    reader.view.frame = scrollView.contentView.bounds

    func fitViewport() {
        for _ in 0..<4 {
            scrollView.tile()
            let size = scrollView.contentView.bounds.size
            let delta = NSSize(width: 1200 - size.width, height: 760 - size.height)
            guard abs(delta.width) > 0.01 || abs(delta.height) > 0.01 else {
                break
            }
            scrollView.setFrameSize(NSSize(
                width: scrollView.frame.width + delta.width,
                height: scrollView.frame.height + delta.height
            ))
        }
        scrollView.tile()
    }

    func layoutLooksComplete() -> Bool {
        guard let manager = reader.view.textLayoutManager else { return false }
        guard manager.textViewportLayoutController.viewportRange != nil
        else { return false }
        guard let fragment = manager.textLayoutFragment(for: .zero)
        else { return false }
        return !fragment.textLineFragments.isEmpty
    }

    // Offscreen windows never order front, so displayIfNeeded performs no
    // drawing. cacheDisplay runs the real draw callbacks (including the
    // reader's background pass) into a bitmap: that counter is the honest
    // "frame actually rendered" signal (§7.4.2).
    guard let drawBitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 1200 * 2,
        pixelsHigh: 760 * 2,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        write([
            "schemaVersion": 1,
            "codeSHA": request.codeSHA,
            "scenario": request.scenario,
            "status": "error",
            "error": "draw bitmap allocation failed",
        ], status: 1)
    }

    func measureFirstFrame(
        since start: ContinuousClock.Instant,
        timeout: TimeInterval
    ) -> Double? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        let baselineDraws = reader.backgroundDrawCount
        while Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.004))
            reader.view.textLayoutManager?.textViewportLayoutController
                .layoutViewport()
            window.displayIfNeeded()
            // Render the VISIBLE region, exactly what a real first frame
            // paints; rendering the full document bounds would charge
            // off-screen layout to the first-frame metric.
            var drawRect = reader.view.visibleRect.intersection(reader.view.bounds)
            if drawRect.isEmpty { drawRect = reader.view.bounds }
            reader.view.cacheDisplay(in: drawRect, to: drawBitmap)
            if reader.backgroundDrawCount > baselineDraws, layoutLooksComplete() {
                return milliseconds(since: start)
            }
        }
        return nil
    }

    // Settled = geometry stops moving for three consecutive 16ms pumps. This
    // is an observed quiet period, not a fixed sleep, and each geometry
    // adjustment during the window is counted (the pre-S1 stand-in for
    // restorePassCount diagnostics).
    func measureSettled(timeout: TimeInterval) -> (ms: Double, adjustments: Int)? {
        let started = ContinuousClock.now
        let deadline = Date(timeIntervalSinceNow: timeout)
        var lastSignature: (height: CGFloat, originY: CGFloat)?
        var stablePumps = 0
        var adjustments = 0
        while Date() < deadline {
            // 5ms pumps keep the quiet-period floor small while still letting
            // main-queue follow-ups (deferred validation, TextKit height
            // corrections) land and register as signature changes.
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
            reader.view.textLayoutManager?.textViewportLayoutController
                .layoutViewport()
            window.displayIfNeeded()
            let signature = (
                height: reader.view.frame.height,
                originY: reader.view.enclosingScrollView?.contentView.bounds.minY ?? 0
            )
            if let lastSignature,
               lastSignature.height == signature.height,
               lastSignature.originY == signature.originY
            {
                stablePumps += 1
                if stablePumps >= 3 {
                    return (milliseconds(since: started), adjustments)
                }
            } else {
                stablePumps = 0
                if lastSignature != nil { adjustments += 1 }
                lastSignature = signature
            }
        }
        return nil
    }

    if request.scenario == "reading-set" {
        // F5 is a bundle of frozen excerpts, not a source file. Preserve the
        // omission marker literally, as the production excerpt model does.
        let chunks = String(decoding: fixtureBytes, as: UTF8.self)
            .components(separatedBy: "### card ").dropFirst()
        let capturedAt = Date(timeIntervalSince1970: 0)
        let excerpts = chunks.enumerated().compactMap { index, chunk -> ReadingSetExcerpt? in
            guard let newline = chunk.firstIndex(of: "\n") else { return nil }
            let source = String(chunk[chunk.index(after: newline)...])
            let bytes = Array(source.utf8)
            let symbol = "F5 card \(index)"
            let inspector = ReadingSetExcerpt.FrozenInspectorDisplay(
                nodeTitle: symbol, badge: .verified, why: "F5 fixture",
                sourceBody: "Frozen source", verificationTitle: "VERIFICATION",
                verificationBody: "Fixture", correctionBody: "",
                availabilityBody: "Captured", environmentBody: "Performance fixture",
                auditRows: [], accessibilityValue: symbol, capturedAt: capturedAt,
                formerCandidateAvailable: false
            )
            return ReadingSetExcerpt(
                role: "DEFINITION", symbol: symbol, path: "f5.rs", line: 1,
                column: 1, firstLine: 1,
                byteRange: ByteRange(lowerBound: 0, upperBound: UInt32(bytes.count)),
                sourceText: source, contentID: .sha256(of: bytes), revision: nil,
                capturedAt: capturedAt, sourceKind: .worktreeCaptured,
                inspector: inspector, caveat: nil
            )
        }
        guard excerpts.count == 31, excerpts.last?.sourceText.contains("\n…\n") == true else {
            _ = stopProbes()
            write(["status": "error", "error": "F5 requires 30 cards and one omission card"], status: 1)
        }
        scrollView.removeFromSuperview()
        let readingSet = ReadingSetView(frame: NSRect(x: 100, y: 60, width: 1200, height: 760))
        readingSet.translatesAutoresizingMaskIntoConstraints = true
        host.addSubview(readingSet)
        func applyWrap(_ enabled: Bool) {
            var settings = baseSettings
            settings.wrapLines = enabled
            readingSet.apply(settings: settings)
        }
        applyWrap(!request.wrapOn)
        readingSet.display(title: "F5", excerpts: excerpts)
        let codeViews = readingSet.selfTestCodeViews
        func geometryValid(wrap: Bool) -> Bool {
            guard codeViews.count == 31, !readingSet.selfTestLayoutPending else { return false }
            let validText = codeViews.allSatisfy { view in
                guard view.textLayoutManager != nil, let container = view.textContainer else { return false }
                return container.widthTracksTextView == wrap
                    && view.isHorizontallyResizable == !wrap
                    && view.string.utf16.count > 0
            }
            return validText
                && readingSet.selfTestCodeScrollViews.allSatisfy { $0.hasHorizontalScroller == !wrap }
                && readingSet.selfTestLayoutState.allSatisfy {
                    $0.heightConstraints == 1 && $0.contentBottom > 0
                        && $0.contentBottom <= $0.documentHeight + 0.5
                }
        }
        // cacheDisplay invokes the real AppKit drawing callbacks offscreen.
        // Stability includes every card, outer scroll position, and measurement
        // count; elapsed time always starts BEFORE the settings action.
        func settle(since started: ContinuousClock.Instant, wrap: Bool) -> (first: Double, settled: Double)? {
            let deadline = Date(timeIntervalSinceNow: 10)
            let baselineDraws = readingSet.selfTestDrawCount
            var firstFrame: Double?
            var previous: [CGFloat] = []
            var stable = 0
            while Date() < deadline {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
                host.layoutSubtreeIfNeeded()
                readingSet.cacheDisplay(in: readingSet.bounds, to: drawBitmap)
                guard readingSet.selfTestDrawCount > baselineDraws, geometryValid(wrap: wrap) else { stable = 0; continue }
                if firstFrame == nil { firstFrame = milliseconds(since: started) }
                let signature = readingSet.selfTestCardFrames.flatMap {
                    [$0.minY, $0.width, $0.height]
                } + [CGFloat(readingSet.scrollOffset), CGFloat(readingSet.selfTestMeasurementCount)]
                stable = signature == previous ? stable + 1 : 0
                previous = signature
                if stable >= 3, let firstFrame {
                    return (firstFrame, milliseconds(since: started))
                }
            }
            return nil
        }
        var samples: [[String: Any]] = []
        var failure: String?
        var lastAnchorError: CGFloat = 0
        if settle(since: .now, wrap: !request.wrapOn) == nil {
            failure = "initial Reading Set layout timed out"
        }
        // Anchor a middle card, so the test exercises outer restoration rather
        // than trivially preserving zero. Keep a nonempty selection in every card.
        let anchorIndex = 12
        let anchorOffset: CGFloat = 8
        if failure == nil {
            readingSet.restoreScrollOffset(Double(readingSet.selfTestCardFrames[anchorIndex].minY + anchorOffset))
            for view in codeViews { view.setSelectedRange(NSRange(location: 3, length: 8)) }
            _ = settle(since: .now, wrap: !request.wrapOn)
            resetStallProbe()
            for cycle in 0..<(request.warmupCount + request.sampleCount) {
                let countBefore = readingSet.selfTestMeasurementCount
                let started = ContinuousClock.now
                applyWrap(request.wrapOn)
                guard let timing = settle(since: started, wrap: request.wrapOn) else {
                    failure = "Reading Set toggle layout or drawing timed out"; break
                }
                let frames = readingSet.selfTestCardFrames
                lastAnchorError = abs(CGFloat(readingSet.scrollOffset) - frames[anchorIndex].minY - anchorOffset)
                let selectionOK = codeViews.allSatisfy { $0.selectedRange() == NSRange(location: 3, length: 8) }
                let measureCount = readingSet.selfTestMeasurementCount - countBefore
                let heightOK = zip(frames, frames.dropFirst()).allSatisfy { $1.minY >= $0.maxY }
                samples.append([
                    "cycle": cycle, "warmup": cycle < request.warmupCount,
                    "toggleFirstFrameMs": timing.first, "toggleSettledMs": timing.settled,
                    "cardMeasureCount": measureCount, "anchorErrorPt": lastAnchorError,
                    "selectionPreserved": selectionOK, "cardHeightsValid": heightOK,
                    "effectiveWrap": codeViews.allSatisfy { $0.textContainer?.widthTracksTextView == true },
                    "textContainerWidthsPt": codeViews.map { $0.textContainer?.size.width ?? 0 },
                ])
                if !selectionOK || !heightOK || lastAnchorError > 1 || measureCount != 31 {
                    failure = "selection, anchor, card height or single-measure invariant failed"; break
                }
                applyWrap(!request.wrapOn)
                guard settle(since: .now, wrap: !request.wrapOn) != nil else {
                    failure = "Reading Set return toggle timed out"; break
                }
            }
        }
        let probes = stopProbes()
        let measured = samples.filter { !($0["warmup"] as? Bool ?? true) }
        func summary(_ key: String) -> [String: Double] {
            let values = measured.compactMap { $0[key] as? Double }.sorted()
            guard !values.isEmpty else { return [:] }
            return ["p50": values[Int(ceil(Double(values.count) * 0.5)) - 1],
                    "p95": values[Int(ceil(Double(values.count) * 0.95)) - 1], "max": values.last!]
        }
        let font = codeViews.first?.font
        var object: [String: Any] = [
            "schemaVersion": 2, "codeSHA": request.codeSHA,
            "fixtureSHA256": ContentID.sha256(of: fixtureBytes).bytes.map { String(format: "%02x", $0) }.joined(),
            "scenario": request.scenario, "requestedWrap": request.wrapOn,
            "status": failure == nil ? "ok" : "error", "samplePeriodMs": 25,
            "warmupCount": request.warmupCount, "sampleCount": measured.count,
            "peakPhysBytes": probes.peak, "samples": samples,
            "summary": ["toggleFirstFrameMs": summary("toggleFirstFrameMs"), "toggleSettledMs": summary("toggleSettledMs")],
            "perfConfig": ["cardCount": readingSet.selfTestCardCount,
                           "measuredWrapLines": samples.last?["effectiveWrap"] ?? NSNull(),
                           "cardScrollerStyles": readingSet.selfTestCodeScrollViews.map { $0.scrollerStyle == .legacy ? "legacy" : "overlay" },
                           "textContainerWidthsPt": samples.last?["textContainerWidthsPt"] ?? [],
                           "lineHeightMultiple": baseSettings.lineHeightMultiple,
                           "resolvedFontName": font?.fontName ?? "", "resolvedFontSizePt": font?.pointSize ?? 0,
                           "windowPt": [host.bounds.width, host.bounds.height],
                           "viewportPt": [readingSet.bounds.width, readingSet.bounds.height],
                           "backingScale": window.backingScaleFactor, "lineNumbers": true,
                           "theme": "SI Classic", "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
                           "machineModel": sysctlString("hw.model") ?? ""],
            "observed": ["cardMeasureCount": readingSet.selfTestMeasurementCount,
                         "drawPassCount": readingSet.selfTestDrawCount,
                         "anchorErrorPt": lastAnchorError, "longestMainThreadStallMs": probes.longestStallMs],
        ]
        if let failure { object["error"] = failure }
        write(object, status: failure == nil ? 0 : 1)
    }

    let loader = DocumentLoader(
        source: { file in Array(try Data(contentsOf: file, options: .mappedIfSafe)) }
    )
    let initialDocument: ReaderDocument
    do {
        initialDocument = try loader.load(file: request.fixture).document
    } catch {
        let probes = stopProbes()
        write([
            "schemaVersion": 1,
            "codeSHA": request.codeSHA,
            "scenario": request.scenario,
            "status": "error",
            "error": "fixture load failed: \(error)",
            "peakPhysBytes": probes.peak,
        ], status: 1)
    }
    let syntaxResult = OSAllocatedUnfairLock(
        initialState: Optional<Result<ReaderDocument, RustHighlighterError>>.none
    )
    loader.loadSyntax(for: initialDocument) { result in
        syntaxResult.withLock { $0 = result }
    }
    guard waitUntil(timeout: 30, condition: {
        syntaxResult.withLock { $0 != nil }
    }), let result = syntaxResult.withLock({ $0 })
    else {
        let probes = stopProbes()
        write([
            "schemaVersion": 1,
            "codeSHA": request.codeSHA,
            "scenario": request.scenario,
            "status": "timeout",
            "error": "syntax load timed out",
            "samplePeriodMs": 25,
            "peakPhysBytes": probes.peak,
        ], status: 1)
    }
    let document: ReaderDocument
    switch result {
    case .success(let loaded):
        document = loaded
    case .failure(let error):
        let probes = stopProbes()
        write([
            "schemaVersion": 1,
            "codeSHA": request.codeSHA,
            "scenario": request.scenario,
            "status": "error",
            "error": "syntax load failed: \(error)",
            "peakPhysBytes": probes.peak,
        ], status: 1)
    }

    func settingsFor(wrap: Bool) -> ReaderSettings {
        var settings = baseSettings
        settings.wrapLines = wrap
        return settings
    }

    var samples: [[String: Any]] = []
    var timedOut = false
    // Wrap-state bits captured while the requested configuration was actually
    // installed: the toggle scenario leaves the opposite state behind for the
    // next cycle, so reading end state would misreport the measured run.
    var measuredWrapState: (
        widthTracking: Bool,
        horizontalScroller: Bool,
        horizontallyResizable: Bool,
        viewportSize: NSSize
    )?
    func captureWrapState() {
        // The machine's legacy scroll-bar preference can be re-delivered
        // mid-run (long fixtures), resetting scrollers styled before it;
        // re-pin per cycle so the measured geometry stays overlay-stable.
        scrollView.scrollerStyle = .overlay
        measuredWrapState = (
            widthTracking: reader.view.textContainer?.widthTracksTextView == true,
            horizontalScroller: scrollView.hasHorizontalScroller,
            horizontallyResizable: reader.view.isHorizontallyResizable,
            viewportSize: scrollView.contentView.bounds.size
        )
    }
    let measurementStart = {
        // The machine's real scroll-bar preference (often legacy "Always")
        // is only delivered once the runloop runs during fixture/syntax
        // loading, and that notification resets scrollers that were styled
        // before it arrived. Re-pin the overlay style here so the clip
        // geometry is stable across the whole measurement window.
        scrollView.scrollerStyle = .overlay
        window.displayIfNeeded()
        fitViewport()
        // Stall samples during fixture load and initial setup would swamp
        // the per-scenario budget; the window starts clean (§7.4.2).
        stallWindow.withLock { $0 = 0 }
    }

    switch request.scenario {
    case "initial":
        reader.apply(settings: settingsFor(wrap: request.wrapOn))
        _ = measurementStart()
        for cycle in 0..<(request.warmupCount + request.sampleCount) {
            // The timed action is the full re-display: projection build,
            // storage install, layout, and first render.
            let started = ContinuousClock.now
            reader.display(document: document, fileURL: request.fixture)
            guard let firstFrame = measureFirstFrame(
                since: started,
                timeout: 10
            ), let settled = measureSettled(timeout: 10)
            else {
                timedOut = true
                break
            }
            captureWrapState()
            samples.append([
                "cycle": cycle,
                "warmup": cycle < request.warmupCount,
                "firstFrameMs": firstFrame,
                "settledMs": settled.ms,
                "settleAdjustments": settled.adjustments,
            ])
        }
    case "toggle":
        reader.apply(settings: settingsFor(wrap: !request.wrapOn))
        reader.display(document: document, fileURL: request.fixture)
        _ = measurementStart()
        guard measureFirstFrame(
            since: ContinuousClock.now,
            timeout: 10
        ) != nil, measureSettled(timeout: 10) != nil
        else {
            timedOut = true
            break
        }
        for cycle in 0..<(request.warmupCount + request.sampleCount) {
            // Timed half: the settings apply that flips to the requested
            // wrap state, through the first rendered frame.
            let started = ContinuousClock.now
            reader.apply(settings: settingsFor(wrap: request.wrapOn))
            guard let firstFrame = measureFirstFrame(
                since: started,
                timeout: 10
            ), let settled = measureSettled(timeout: 10)
            else {
                timedOut = true
                break
            }
            captureWrapState()
            samples.append([
                "cycle": cycle,
                "warmup": cycle < request.warmupCount,
                "toggleFirstFrameMs": firstFrame,
                "toggleSettledMs": milliseconds(since: started),
                "settleQuietPeriodMs": settled.ms,
                "settleAdjustments": settled.adjustments,
            ])
            // Untimed half: return to the opposite state for the next cycle.
            reader.apply(settings: settingsFor(wrap: !request.wrapOn))
            if measureFirstFrame(since: ContinuousClock.now, timeout: 10) == nil
                || measureSettled(timeout: 10) == nil
            {
                timedOut = true
                break
            }
        }
    case "resize":
        reader.apply(settings: settingsFor(wrap: request.wrapOn))
        reader.display(document: document, fileURL: request.fixture)
        _ = measurementStart()
        guard measureFirstFrame(
            since: ContinuousClock.now,
            timeout: 10
        ) != nil, measureSettled(timeout: 10) != nil
        else {
            timedOut = true
            break
        }
        let baseWidth = scrollView.frame.width
        for cycle in 0..<(request.warmupCount + request.sampleCount) {
            var steps: [[String: Any]] = []
            for targetWidth in [baseWidth - 340, baseWidth] {
                let started = ContinuousClock.now
                scrollView.setFrameSize(NSSize(
                    width: targetWidth,
                    height: scrollView.frame.height
                ))
                scrollView.tile()
                guard let firstFrame = measureFirstFrame(
                    since: started,
                    timeout: 10
                ), let settled = measureSettled(timeout: 10)
                else {
                    timedOut = true
                    break
                }
                steps.append([
                    "widthPt": targetWidth,
                    "stepMs": milliseconds(since: started),
                    "firstFrameMs": firstFrame,
                    "settledMs": settled.ms,
                    "settleAdjustments": settled.adjustments,
                ])
            }
            samples.append([
                "cycle": cycle,
                "warmup": cycle < request.warmupCount,
                "steps": steps,
                "rawResizeRequests": steps.count,
            ])
            captureWrapState()
            if timedOut { break }
        }
    default:
        let probes = stopProbes()
        write([
            "schemaVersion": 1,
            "codeSHA": request.codeSHA,
            "scenario": request.scenario,
            "status": "error",
            "error": "unexpected scenario \(request.scenario)",
            "peakPhysBytes": probes.peak,
        ], status: 1)
    }

    let probes = stopProbes()
    if timedOut {
        write([
            "schemaVersion": 1,
            "codeSHA": request.codeSHA,
            "fixtureSHA256": document.contentID.bytes
                .map { String(format: "%02x", $0) }.joined(),
            "scenario": request.scenario,
            "requestedWrap": request.wrapOn,
            "status": "timeout",
            "error": "layout or draw did not settle within the 10s budget",
            "samplePeriodMs": 25,
            "peakPhysBytes": probes.peak,
        ], status: 1)
    }

    func summarize(_ values: [Double]) -> [String: Double] {
        let sorted = values.sorted()
        func percentile(_ p: Double) -> Double {
            let rank = Int(ceil(p / 100 * Double(sorted.count))) - 1
            return sorted[min(max(rank, 0), sorted.count - 1)]
        }
        return [
            "p50": percentile(50),
            "p95": percentile(95),
            "max": sorted.last ?? 0,
        ]
    }

    let measured = samples.filter { !($0["warmup"] as? Bool ?? true) }
    var summary: [String: Any] = [:]
    switch request.scenario {
    case "initial":
        let firstFrame = measured.compactMap {
            $0["firstFrameMs"] as? Double
        }
        let settled = measured.compactMap { $0["settledMs"] as? Double }
        if !firstFrame.isEmpty { summary["firstFrameMs"] = summarize(firstFrame) }
        if !settled.isEmpty { summary["settledMs"] = summarize(settled) }
    case "toggle":
        let firstFrame = measured.compactMap {
            $0["toggleFirstFrameMs"] as? Double
        }
        let settled = measured.compactMap { $0["toggleSettledMs"] as? Double }
        if !firstFrame.isEmpty {
            summary["toggleFirstFrameMs"] = summarize(firstFrame)
        }
        if !settled.isEmpty { summary["toggleSettledMs"] = summarize(settled) }
    case "resize":
        let stepMs = measured.flatMap { sample in
            (sample["steps"] as? [[String: Any]])?.compactMap {
                $0["stepMs"] as? Double
            } ?? []
        }
        if !stepMs.isEmpty { summary["resizeStepMs"] = summarize(stepMs) }
    default:
        break
    }

    let storage = reader.view.textStorage
    let resolvedFont: NSFont? = storage.flatMap { storage in
        guard storage.length > 0 else { return nil }
        return storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    }
    let viewport = scrollView.contentView.bounds.size
    let windowSize = window.contentView?.bounds.size ?? .zero
    let wrapState = measuredWrapState ?? (
        widthTracking: reader.view.textContainer?.widthTracksTextView == true,
        horizontalScroller: scrollView.hasHorizontalScroller,
        horizontallyResizable: reader.view.isHorizontallyResizable,
        viewportSize: scrollView.contentView.bounds.size
    )
    let lineHeight = reader.view.textLayoutManager?
        .textLayoutFragment(for: .zero)?.layoutFragmentFrame.height ?? 0
    let lineStarts = document.lineTable.lineStarts
    var maxLineUTF8Bytes = 0
    for index in lineStarts.indices.dropLast() {
        let length = Int(lineStarts[index + 1] - lineStarts[index])
        maxLineUTF8Bytes = max(maxLineUTF8Bytes, length)
    }

    var object: [String: Any] = [
        "schemaVersion": 2,
        "codeSHA": request.codeSHA,
        "fixtureSHA256": document.contentID.bytes
            .map { String(format: "%02x", $0) }.joined(),
        "scenario": request.scenario,
        "requestedWrap": request.wrapOn,
        "samplePeriodMs": 25,
        "warmupCount": request.warmupCount,
        "sampleCount": measured.count,
        "perfConfig": [
            "wrapLines": wrapState.widthTracking,
            "widthTracksTextView": wrapState.widthTracking,
            "horizontalScroller": wrapState.horizontalScroller,
            "resolvedFontName": resolvedFont?.fontName ?? "",
            "resolvedFontSizePt": resolvedFont?.pointSize ?? 0,
            "windowPt": [windowSize.width, windowSize.height],
            "viewportPt": [wrapState.viewportSize.width, wrapState.viewportSize.height],
            "lineNumbers": reader.foldPerformanceEffectiveSettings.lineNumbers,
            "theme": "SI Classic",
            "gutterThicknessPt": reader.rulerThickness,
            "renderedFoldCount": reader.foldPerformanceCounts.rendered,
            "scrollerStyle": NSScroller.preferredScrollerStyle == .legacy
                ? "legacy" : "overlay",
            "scrollViewScrollerStyle": scrollView.scrollerStyle == .legacy
                ? "legacy" : "overlay",
            "scrollViewAutohidesScrollers": scrollView.autohidesScrollers,
            "backingScale": window.backingScaleFactor,
            "lineHeightPt": lineHeight,
            "logicalLineCount": lineStarts.count,
            "maxLineUTF8Bytes": maxLineUTF8Bytes,
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "machineModel": sysctlString("hw.model") ?? "",
        ],
        "observed": [
            "reflowCount": reader.projectionInstallCount,
            "drawPassCount": reader.backgroundDrawCount,
            "paragraphUpdateCount": reader.paragraphUpdateCount,
            "restorePassCount": reader.viewportRestorePassCount,
            "anchorErrorPt": reader.lastViewportAnchorErrorPt ?? NSNull(),
            "mergedResizeRequests": reader.mergedWidthReflowCount,
            "rawResizeRequests": samples.reduce(0) {
                $0 + ($1["rawResizeRequests"] as? Int ?? 0)
            } + reader.widthReflowNotificationCount,
            "longestMainThreadStallMs": probes.longestStallMs,
        ],
        "samples": samples,
        "summary": summary,
        "status": "ok",
        "peakPhysBytes": probes.peak,
    ]

    // Independent configuration validation for wrap scenarios (§7.4.1): the
    // observed layout must match the request, not echo it.
    let configurationIsExact = wrapState.widthTracking == request.wrapOn
        && wrapState.horizontalScroller == !request.wrapOn
        && wrapState.horizontallyResizable == !request.wrapOn
        && abs(wrapState.viewportSize.width - 1200) < 0.01
        && abs(wrapState.viewportSize.height - 760) < 0.01
        && abs(windowSize.width - 1440) < 0.01
        && abs(windowSize.height - 900) < 0.01
        && resolvedFont != nil
        && abs((resolvedFont?.pointSize ?? 0) - 13) < 0.01
        && reader.foldPerformanceEffectiveSettings.lineNumbers
        && reader.foldPerformanceEffectiveSettings.theme == .siClassic
    if !configurationIsExact {
        object["status"] = "error"
        object["error"] = "effective wrap configuration does not match request"
    }
    withExtendedLifetime((reader, window, scrollView, drawBitmap)) {}
    write(object, status: configurationIsExact ? 0 : 1)
}

private func sysctlString(_ name: String) -> String? {
    var length = 0
    guard sysctlbyname(name, nil, &length, nil, 0) == 0, length > 0
    else { return nil }
    var buffer = [CChar](repeating: 0, count: length)
    guard sysctlbyname(name, &buffer, &length, nil, 0) == 0
    else { return nil }
    return String(cString: buffer)
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

extension ProjectState {
    /// Ready check shared by the multi-window self-test.
    var isReadyForMultiWindowSelfTest: Bool {
        if case .ready = self { return true }
        return false
    }
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
        if node.isDirectory { return rustFiles(in: node.children) }
        return LanguageMode.classify(path: node.url.path, language: .rust) != nil
            ? [node.url] : []
    }
}

private func bookmarkSelfTestLanguages() -> [LanguageID] {
    let raw = ProcessInfo.processInfo.environment["CAIRN_BOOKMARK_LANGUAGES"] ?? "rust"
    let languages = raw.split(separator: ",").compactMap { part -> LanguageID? in
        switch part.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "rust": .rust
        case "python": .python
        case "typescript", "ts": .typescript
        default: nil
        }
    }
    return languages.isEmpty ? [.rust] : Array(Set(languages)).sorted { $0.rawValue < $1.rawValue }
}

private func bookmarkSelfTestFiles(
    in root: URL,
    languages: [LanguageID]
) -> [(language: LanguageID, file: URL)] {
    let files = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    )
    let regular = files?.compactMap { $0 as? URL }.filter {
        (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    } ?? []
    return languages.compactMap { language in
        guard let file = regular.first(where: { LanguageMode.classify(
            path: $0.path, language: language
        ) != nil }) else { return nil }
        return (language, file.standardizedFileURL)
    }
}

private func bookmarkSelfTestGitHEAD(in root: URL) -> String? {
    func output(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch { return nil }
        guard process.terminationStatus == 0 else { return nil }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard output(["rev-parse", "--show-toplevel"]).map({
        URL(fileURLWithPath: $0).standardizedFileURL == root.standardizedFileURL
    }) == true,
    let value = output(["rev-parse", "--verify", "HEAD"]),
    (value.count == 40 || value.count == 64),
    value.allSatisfy(\.isHexDigit)
    else { return nil }
    return value
}

@MainActor
private func runBookmarkSelfTestRestart(sessionURL: URL) -> Never {
    let bookmarksURL = sessionURL.standardizedFileURL.deletingLastPathComponent()
        .appendingPathComponent("bookmarks.json")
    let model = BookmarkModel(store: BookmarkStore(fileURL: bookmarksURL))
    let checks: [String: Bool] = [
        "loaded": model.storageError == nil,
        "records": !model.records.isEmpty,
        "note": model.records.contains { !$0.note.isEmpty },
    ]
    let output: [String: Any] = [
        "channel": "bookmarks-restart",
        "passed": checks.values.allSatisfy { $0 },
        "processRestart": true,
        "checks": checks,
        "records": model.records.map { [
            "id": $0.id.uuidString,
            "note": $0.note,
            "path": $0.path,
        ] },
        "bookmarksURL": bookmarksURL.path,
    ]
    if let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
    Darwin.exit(checks.values.allSatisfy { $0 } ? 0 : 1)
}

private func bookmarkSelfTestLanguageName(_ language: LanguageID) -> String {
    switch language {
    case .rust: "rust"
    case .python: "python"
    case .typescript: "typescript"
    case .javascript: "javascript"
    }
}

private func axContains(_ tree: [[String: String]], _ label: String) -> Bool {
    tree.contains { $0["label"] == label }
}

@MainActor
private func bookmarkSelfTestSessionURL() -> URL {
    ProcessInfo.processInfo.environment["CAIRN_BOOKMARK_SESSION_URL"]
        .map(URL.init(fileURLWithPath:)) ?? AppModel.defaultSessionURL
}

@MainActor
private func cachedBitmap(of view: NSView?) -> NSBitmapImageRep? {
    guard let view else { return nil }
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    else { return nil }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    return bitmap
}

@MainActor
private func cachedPNG(of view: NSView?, path: String) -> (
    path: String, width: Int, height: Int, visiblePixels: Bool
)? {
    guard let bitmap = cachedBitmap(of: view) else { return nil }
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        return nil
    }
    do {
        try data.write(to: URL(fileURLWithPath: path))
        return (
            path,
            bitmap.pixelsWide,
            bitmap.pixelsHigh,
            bookmarkBitmapHasVisiblePixels(bitmap)
        )
    } catch {
        return nil
    }
}

func bookmarkBitmapHasVisiblePixels(_ bitmap: NSBitmapImageRep) -> Bool {
    guard bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else { return false }
    let stepX = max(1, bitmap.pixelsWide / 64)
    let stepY = max(1, bitmap.pixelsHigh / 64)
    var reference: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)?
    for y in stride(from: 0, to: bitmap.pixelsHigh, by: stepY) {
        for x in stride(from: 0, to: bitmap.pixelsWide, by: stepX) {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
            else { continue }
            let sample = (
                red: color.redComponent,
                green: color.greenComponent,
                blue: color.blueComponent,
                alpha: color.alphaComponent
            )
            if let reference {
                let delta = max(
                    abs(sample.red - reference.red),
                    abs(sample.green - reference.green),
                    abs(sample.blue - reference.blue),
                    abs(sample.alpha - reference.alpha)
                )
                if delta >= 0.05 { return true }
            } else {
                reference = sample
            }
        }
    }
    return false
}

private func pythonFiles(in nodes: [FileTreeNode]) -> [URL] {
    nodes.flatMap { node in
        node.isDirectory ? pythonFiles(in: node.children) : [node.url]
    }
}

private func utf8Offsets(
    of needle: String,
    in bytes: [UInt8]
) -> [Int] {
    guard !needle.isEmpty else { return [] }
    let data = Data(bytes)
    let pattern = Data(needle.utf8)
    var result: [Int] = []
    var start = data.startIndex
    while start < data.endIndex,
          let range = data.range(of: pattern, in: start ..< data.endIndex)
    {
        result.append(range.lowerBound)
        start = range.upperBound
    }
    return result
}

@MainActor
private func contentSearchHits(
    session: EngineSession,
    context: QueryContext,
    query: ContentSearchQuery
) async throws -> [String] {
    var paths: [String] = []
    for try await batch in try session.search(query, context: context) {
        for pathID in batch.matchesByPath.keys {
            paths.append(session.paths.resolve(pathID))
        }
    }
    return paths
}

private func previousCommitRevision(root: URL) -> String? {
    guard (try? CommitSnapshot(
        repositoryURL: root,
        revision: "HEAD~1"
    )) != nil else { return nil }
    return "HEAD~1"
}
