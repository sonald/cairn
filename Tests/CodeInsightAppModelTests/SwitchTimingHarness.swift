import CodeInsightCore
import CodeInsightExact
import CodeInsightGit
import Foundation
import Testing
@testable import CodeInsightAppModel
@testable import CodeInsightEngine

// Opt-in timing of the app's commit switch without the UI, skipped unless
// CAIRN_SWITCH_HARNESS names a repository. Exact uses a fake provider, so
// "exactReady" is the moment the Exact session activates; a real cold
// server would still be loading then. Phases shorter than the 1 ms poll
// print -1.
// Release build, run through the Swift Testing helper:
//   swift build -c release -Xswiftc -enable-testing --target CodeInsightAppModelTests
//   CAIRN_SWITCH_HARNESS=<repo> CAIRN_SWITCH_REVISION=HEAD~5 CAIRN_SWITCH_RUNS=3 \
//   CAIRN_SWITCH_FILE=<file selected before switching> CODEINSIGHT_INDEX_CACHE_ROOT=<scratch> \
//   DYLD_FRAMEWORK_PATH=$(xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks \
//   DYLD_LIBRARY_PATH=$(xcode-select -p)/Platforms/MacOSX.platform/Developer/usr/lib \
//   $(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper \
//     --test-bundle-path .build/out/Products/Release/CodeInsightAppModelTests.xctest/Contents/MacOS/CodeInsightAppModelTests \
//     --testing-library swift-testing --filter switchTimingHarness

private let harnessRoot = ProcessInfo.processInfo.environment["CAIRN_SWITCH_HARNESS"]
private let harnessRevision = ProcessInfo.processInfo.environment["CAIRN_SWITCH_REVISION"] ?? "HEAD~5"
private let harnessRuns = Int(ProcessInfo.processInfo.environment["CAIRN_SWITCH_RUNS"] ?? "3") ?? 3

private func ms(_ start: ContinuousClock.Instant) -> Int {
    let d = ContinuousClock.now - start
    return Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
}

@MainActor
@Test(.enabled(if: harnessRoot != nil))
func switchTimingHarnessEndToEnd() async throws {
    _ = isolatedIndexCacheRoot
    let root = URL(fileURLWithPath: harnessRoot!, isDirectory: true).standardizedFileURL
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("cairn-switch-harness-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: scratch) }
    let state = ExactProviderState()
    let coordinator = ExactCoordinator(
        providerFactory: { _, language in ExactTestProvider(language: language, state: state) },
        trustRegistry: TrustRegistry(fileURL: scratch.appendingPathComponent("trust.json")),
        checkoutStore: CheckoutStore(parentURL: scratch.appendingPathComponent("checkouts"))
    )
    let model = AppModel(exactCoordinator: coordinator)
    let openStart = ContinuousClock.now
    await model.openProject(root: root).value
    if let file = ProcessInfo.processInfo.environment["CAIRN_SWITCH_FILE"] {
        model.navigate(to: root.appendingPathComponent(file))
        // A selected file routes Exact to its unit, as in the app.
        try await Task.sleep(for: .milliseconds(500))
    }
    while model.exactCoordinator.readiness == .preparing {
        if ms(openStart) > 60_000 {
            print("HARNESS open timeout readiness=\(model.exactCoordinator.readiness) phase=\(String(describing: model.snapshotPhase))")
            return
        }
        try await Task.sleep(for: .milliseconds(2))
    }
    print("HARNESS open worktree total=\(ms(openStart)) readiness=\(model.exactCoordinator.readiness) languages=\(model.projectLanguages) sessions=\(model.querySessions.count)")

    // Warm-up switch fills the persistent cache for the commit, and the
    // checkout directory (first checkout writes the whole tree).
    for run in 0...harnessRuns {
        for revision in [harnessRevision, nil] as [String?] {
            let start = ContinuousClock.now
            if let revision { model.switchToCommit(revision) } else { model.switchToWorktree() }
            var marks: [String: Int] = [:]
            while true {
                let t = ms(start)
                if model.snapshotPhase == .firstPaint, marks["firstPaint"] == nil { marks["firstPaint"] = t }
                if model.snapshotPhase == .cachedReady, marks["cachedReady"] == nil { marks["cachedReady"] = t }
                if model.snapshotPhase == .fullReady, marks["fullReady"] == nil { marks["fullReady"] = t }
                if model.snapshotPhase == .fullReady, model.exactCoordinator.readiness != .preparing {
                    marks["exactReady"] = t
                    break
                }
                if t > 60_000 {
                    print("HARNESS switch timeout readiness=\(model.exactCoordinator.readiness) phase=\(String(describing: model.snapshotPhase))")
                    return
                }
                try await Task.sleep(for: .milliseconds(1))
            }
            let label = revision ?? "worktree"
            print("HARNESS run=\(run)\(run == 0 ? "(warmup)" : "") to=\(label) firstPaint=\(marks["firstPaint"] ?? -1) cachedReady=\(marks["cachedReady"] ?? -1) fullReady=\(marks["fullReady"] ?? -1) exactReady=\(marks["exactReady"] ?? -1) readiness=\(model.exactCoordinator.readiness)")
        }
    }
    await coordinator.shutdownAndWait()
}

/// The same work the app does for one commit switch, step by step, off the
/// main actor, so each stage can be timed on its own.
@Test(.enabled(if: harnessRoot != nil))
func switchTimingHarnessStages() async throws {
    _ = isolatedIndexCacheRoot
    let root = URL(fileURLWithPath: harnessRoot!, isDirectory: true).standardizedFileURL
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("cairn-switch-stages-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: scratch) }
    let service = ProjectIndexService()
    let worktree = try await service.captureSnapshot(root: root, revision: nil)
    let languages = worktree.languages
    let wtPrepared = try await service.prepareSnapshots(worktree, root: root, languages: languages)
    for item in wtPrepared { _ = try await service.completeSnapshot(item) }
    let store = CheckoutStore(parentURL: scratch.appendingPathComponent("checkouts"))
    let owner = UUID()

    for run in 0...harnessRuns {
        var line = "STAGES run=\(run)\(run == 0 ? "(warmup)" : "") rev=\(harnessRevision)"
        var t = ContinuousClock.now
        let snapshot = try await service.captureSnapshot(root: root, revision: harnessRevision)
        line += " capture=\(ms(t))"
        t = ContinuousClock.now
        let prepared = try await service.prepareSnapshots(snapshot, root: root, languages: languages)
        line += " prepare=\(ms(t))"
        var sessions: [EngineSession] = []
        for item in prepared {
            t = ContinuousClock.now
            sessions += try await service.completeSnapshot(item)
            line += " complete[\(item.cachedSessions.first.map { String(describing: $0.analysisProfile.language) } ?? "?")]=\(ms(t))"
        }
        line += " units=\(sessions.count)"
        let rust = sessions.filter { $0.analysisProfile.language == .rust }
            .max { $0.activePathIDs.count < $1.activePathIDs.count }!
        let rawPrefix = rust.paths.resolve(rust.analysisProfile.projectRoot)
        let prefix = rawPrefix == "." ? "" : rawPrefix
        t = ContinuousClock.now
        let exactSnapshot = try CommitSnapshot(repositoryURL: root, revision: harnessRevision)
        line += " exactSnapshot=\(ms(t))"
        t = ContinuousClock.now
        let links = DependencyBorrowing.links(language: .rust, snapshot: exactSnapshot, workspaceRoot: root, unitPrefix: prefix)
        _ = try ExactProfileKey(snapshot: exactSnapshot, language: .rust, pathPrefix: prefix)
        line += " links+profile=\(ms(t))"
        t = ContinuousClock.now
        let checkout = try store.root(owner: owner, source: root)
        try checkout.checkout(commit: exactSnapshot.commitOID, links: links)
        line += " checkout=\(ms(t))"
        t = ContinuousClock.now
        let changes = ExactFileChange.changes(from: worktree, to: exactSnapshot, under: checkout.url)
        line += " diff=\(ms(t)) (\(changes.count) changes)"
        // Return the checkout to the worktree's HEAD so every run rewrites
        // the same paths (the app alternates the same way).
        let head = try CommitSnapshot(repositoryURL: root, revision: "HEAD")
        try checkout.checkout(commit: head.commitOID, links: links)
        print(line)
    }
}
