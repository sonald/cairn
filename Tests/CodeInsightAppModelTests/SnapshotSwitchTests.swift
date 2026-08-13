import CodeInsightCore
import CodeInsightGit
import CodeInsightReaderCore
import Foundation
import Testing
@testable import CodeInsightAppModel
@testable import CodeInsightEngine

private let snapshotSwitchRepositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

@MainActor
@Test
func snapshotSwitchPublishesFirstPaintCachedAndFullInOrder() async throws {
    let root = try snapshotTemporaryProject(["main.rs": "fn initial() {}"])
    defer { try? FileManager.default.removeItem(at: root) }
    let initial = try ProjectIndexer().index(root: root)
    let service = ControlledSnapshotIndexService(
        initialSession: initial,
        snapshots: ["C": TestSnapshot(label: "C", files: [
            "src/c.rs": "fn c() {}",
            "src/ignored.py": "def ignored(): pass",
        ])],
        blockedCached: ["C"],
        blockedFull: ["C"]
    )
    let model = AppModel(indexService: service)

    model.openProject(root: root)
    #expect(await testWaitUntil("model.snapshotPhase == .fullReady") { model.snapshotPhase == .fullReady })
    model.switchToCommit("C")

    #expect(await testWaitUntil("model.snapshotPhase == .firstPaint") { model.snapshotPhase == .firstPaint })
    #expect(model.fileTree?.children.first?.name == "src")
    #expect(model.fileTree?.children.first?.children.map(\.name) == ["c.rs"])
    #expect(model.coverage.filesIndexed == 0)
    #expect(model.coverage.filesTotal == 1)

    await service.releaseCached("C")
    #expect(await testWaitUntil("model.snapshotPhase == .cachedReady") { model.snapshotPhase == .cachedReady })
    guard case let .ready(_, cachedContext) = model.projectState else {
        Issue.record("expected cached session")
        return
    }
    #expect(cachedContext.generation == model.generation)

    await service.releaseFull("C")
    #expect(await testWaitUntil("model.snapshotPhase == .fullReady") { model.snapshotPhase == .fullReady })
    #expect(model.coverage.filesIndexed == 1)
    #expect(model.coverage.importsResolved == nil)
    let languages = await service.receivedLanguages()
    #expect(languages.index == [.rust])
    #expect(languages.capture == [.rust])
    #expect(languages.prepare == [.rust])
}

@MainActor
@Test
func pythonSnapshotFirstPaintFiltersForeignPathsFromSelectionAndSource() async throws {
    let root = try snapshotTemporaryProject(["main.py": "def current():\n    pass\n"])
    defer { try? FileManager.default.removeItem(at: root) }
    let initial = try ProjectIndexer().index(root: root, language: .python)
    let service = ControlledSnapshotIndexService(
        initialSession: initial,
        snapshots: ["C": TestSnapshot(label: "C", files: [
            "main.py": "def committed():\n    pass\n",
            "foreign.rs": "fn foreign() {}\n",
        ])],
        blockedCached: ["C"]
    )
    let model = AppModel(
        indexService: service,
        commitPicker: CommitPickerModel(commits: [
            CommitInfo(
                shortSHA: "C",
                fullSHA: "C",
                summary: "commit",
                authorName: "test",
                date: Date()
            ),
        ])
    )
    let foreign = root.appendingPathComponent("foreign.rs")

    try model.openProject(root: root, language: .python)
    #expect(await testWaitUntil("model.snapshotPhase == .fullReady") { model.snapshotPhase == .fullReady })
    model.navigate(to: foreign)
    #expect(model.selectedFile == foreign.standardizedFileURL)

    model.switchToCommit("C")
    #expect(await testWaitUntil("model.snapshotPhase == .firstPaint") { model.snapshotPhase == .firstPaint })

    #expect(model.selectedFile == nil)
    #expect(model.selectedByteOffset == nil)
    #expect(model.fileTree?.children.map(\.name) == ["main.py"])
    let source = try #require(model.documentSource)
    #expect(throws: CocoaError.self) {
        _ = try DocumentLoader(source: source).load(file: foreign)
    }
}

@MainActor
@Test
func snapshotFullSessionLanguageMismatchFailsBeforeFullPublication() async throws {
    let root = try snapshotTemporaryProject(["main.rs": "fn initial() {}"])
    defer { try? FileManager.default.removeItem(at: root) }
    let initial = try ProjectIndexer().index(root: root)
    let service = ControlledSnapshotIndexService(
        initialSession: initial,
        snapshots: ["C": TestSnapshot(label: "C", files: ["main.rs": "fn c() {}"])],
        blockedFull: ["C"],
        completedLanguageOverride: .python
    )
    let model = AppModel(indexService: service)

    model.openProject(root: root)
    #expect(await testWaitUntil("initial session ready") {
        model.snapshotPhase == .fullReady
    })
    model.switchToCommit("C")
    #expect(await testWaitUntil("cached session ready") {
        model.snapshotPhase == .cachedReady
    })
    let cachedSnapshotID = model.currentSnapshotID
    let cachedCoverage = model.coverage

    await service.releaseFull("C")
    #expect(await testWaitUntil("mismatched full session rejected") {
        if case .failed = model.projectState { return true }
        return false
    })
    #expect(model.snapshotPhase == .cachedReady)
    #expect(model.currentSnapshotID == cachedSnapshotID)
    #expect(model.coverage == cachedCoverage)
    #expect(model.projectLanguage == .rust)
}

@MainActor
@Test
func delayedSessionCheckpointNeverMixesSnapshotGenerations() async throws {
    let root = try snapshotTemporaryProject(["main.rs": "fn initial() {}"])
    let stateRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
        "CodeInsightSnapshotSession-\(UUID().uuidString)",
        isDirectory: true
    )
    let sessionURL = stateRoot.appendingPathComponent("session.json")
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: stateRoot)
        #expect(!FileManager.default.fileExists(atPath: sessionURL.path))
    }
    let initial = try ProjectIndexer().index(root: root)
    let service = ControlledSnapshotIndexService(
        initialSession: initial,
        snapshots: [
            "C": TestSnapshot(label: "C", files: ["main.rs": "fn committed() {}"]),
        ],
        blockedCached: ["C"]
    )
    let model = AppModel(sessionURL: sessionURL, indexService: service)

    model.openProject(root: root)
    #expect(await testWaitUntil("initial session ready") {
        model.snapshotPhase == .fullReady
    })
    model.openInNewTab(root.appendingPathComponent("main.rs"))
    model.openInNewTab(root.appendingPathComponent("other.rs"))
    try model.writeSessionCheckpoint(panelPreset: .reading)
    let worktreeData = try Data(contentsOf: sessionURL)

    model.scheduleSessionCheckpoint(panelPreset: .compare)
    model.switchToCommit("C")
    #expect(await testWaitUntil("commit first paint installed") {
        model.snapshotPhase == .firstPaint && model.currentRevision == "C"
    })
    try await Task.sleep(for: .milliseconds(350))

    #expect(try Data(contentsOf: sessionURL) == worktreeData)
    try model.writeSessionCheckpoint(panelPreset: .compare)
    #expect(try Data(contentsOf: sessionURL) == worktreeData)

    model.closeTab(1)
    try model.writeSessionCheckpoint(
        panelPreset: .reading,
        allowsPendingTopology: true
    )
    let pendingTopology = try SessionCodec.decode(
        Data(contentsOf: sessionURL),
        maximumTabCount: model.tabStrip.maximumCount,
        dependencyAllowed: { _ in false }
    )
    #expect(pendingTopology.revision == nil)
    #expect(pendingTopology.language == .rust)
    #expect(pendingTopology.tabs.count == 1)

    await service.releaseCached("C")
    #expect(await testWaitUntil("commit session fully installed") {
        model.snapshotPhase == .fullReady && model.currentRevision == "C"
    })
    try model.writeSessionCheckpoint(panelPreset: .compare)
    let committed = try SessionCodec.decode(
        Data(contentsOf: sessionURL),
        maximumTabCount: model.tabStrip.maximumCount,
        dependencyAllowed: { _ in false }
    )
    #expect(committed.revision == "C")
    #expect(committed.language == .rust)
    #expect(committed.panelPreset == PanelPresetModel.compare.rawValue)
    #expect(committed.tabs.count == 1)
}

@MainActor
@Test
func sessionRestoreInstallsRevisionBeforeActivatingFrozenReadingSet() async throws {
    let fixture = try SnapshotGitFixture()
    defer { fixture.remove() }
    try snapshotWrite(
        "fn committed() {}\n",
        to: fixture.root.appendingPathComponent("main.rs")
    )
    try fixture.git("add", "main.rs")
    try fixture.commit("saved")
    let revision = try fixture.git("rev-parse", "HEAD")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    try snapshotWrite(
        "fn worktree() {}\n",
        to: fixture.root.appendingPathComponent("main.rs")
    )
    let snapshot = SessionCodec.Snapshot(
        projectRoot: fixture.root.path,
        language: .rust,
        revision: revision,
        activeTabOrdinal: 0,
        panelPreset: PanelPresetModel.relations.rawValue,
        tabs: [
            .readingSet(.init(
                title: "captured evidence",
                excerpts: [],
                scrollOffset: 64,
                skippedReasons: ["recorded source is unreadable"]
            )),
        ]
    )
    let model = AppModel(indexService: ProjectIndexService())

    #expect(await model.restoreSession(snapshot))

    #expect(model.snapshotPhase == .fullReady)
    #expect(model.currentRevision == revision)
    #expect(model.tabStrip.activeIndex == 0)
    #expect(model.selectedFile == nil)
    guard case .readingSet(let title, let excerpts) = model.tabStrip.activeTab?.content
    else {
        Issue.record("expected the frozen Reading Set to be active")
        return
    }
    #expect(title == "captured evidence")
    #expect(excerpts.isEmpty)
    #expect(model.tabStrip.activeTab?.readingSetScrollOffset == 64)
    #expect(model.tabStrip.activeTab?.readingSetSkippedReasons
        == ["recorded source is unreadable"])
}

@MainActor
@Test
func switchingAgainCancelsAndDiscardsTheOlderSnapshot() async throws {
    let root = try snapshotTemporaryProject(["main.rs": "fn initial() {}"])
    defer { try? FileManager.default.removeItem(at: root) }
    let initial = try ProjectIndexer().index(root: root)
    let service = ControlledSnapshotIndexService(
        initialSession: initial,
        snapshots: [
            "C": TestSnapshot(label: "C", files: ["c.rs": "fn c() {}"]),
            "D": TestSnapshot(label: "D", files: ["d.rs": "fn d() {}"]),
        ],
        blockedFull: ["C"]
    )
    let model = AppModel(indexService: service)

    model.openProject(root: root)
    #expect(await testWaitUntil("model.snapshotPhase == .fullReady") { model.snapshotPhase == .fullReady })
    model.switchToCommit("C")
    #expect(await testWaitUntil("model.snapshotPhase == .cachedReady") { model.snapshotPhase == .cachedReady })
    try #require(await testWaitUntil("C full snapshot started") {
        await service.hasStartedFull("C")
    })

    let cSnapshotID = model.currentSnapshotID
    model.switchToCommit("D")
    #expect(model.currentSnapshotID == cSnapshotID)
    #expect(model.documentSource != nil)
    #expect(await testWaitUntil("model.snapshotPhase == .fullReady && model.currentRevision == \"D\"") {
        model.snapshotPhase == .fullReady && model.currentRevision == "D"
    })
    #expect(await testWaitUntil("C snapshot cancellation") {
        await service.wasCancelled("C")
    })
    #expect(model.generation == 3)
    #expect(model.fileTree?.children.map(\.name) == ["d.rs"])
    guard case let .ready(session, context) = model.projectState else {
        Issue.record("expected D session")
        return
    }
    let snapshotID = await service.snapshotID(for: "D")
    #expect(session.snapshotID == snapshotID)
    #expect(context.generation == model.generation)
}

@MainActor
@Test
func snapshotSwitchInvalidatesAnOlderContextRequest() async throws {
    let source = "fn target() {}\nfn main() { target(); }"
    let root = try snapshotTemporaryProject(["main.rs": source])
    defer { try? FileManager.default.removeItem(at: root) }
    let initial = try ProjectIndexer().index(root: root)
    let service = ControlledSnapshotIndexService(
        initialSession: initial,
        snapshots: ["C": TestSnapshot(label: "C", files: ["main.rs": source])],
        blockedCached: ["C"]
    )
    let resolver = SnapshotResolverGate()
    let contextWindow = ContextWindowModel(resolver.resolve)
    let model = AppModel(indexService: service, contextWindow: contextWindow)
    let offset = UInt32(source[..<source.range(of: "target();")!.lowerBound].utf8.count)

    model.openProject(root: root)
    #expect(await testWaitUntil("model.snapshotPhase == .fullReady") { model.snapshotPhase == .fullReady })
    contextWindow.tokenClicked(file: "main.rs", offset: offset)
    #expect(await testWaitUntil("resolver.isPending") { resolver.isPending })

    model.switchToCommit("C")
    let oldRequestID = contextWindow.requestID
    resolver.complete([])
    for _ in 0..<10 { await Task.yield() }

    #expect(contextWindow.requestID == oldRequestID)
    #expect(contextWindow.candidateCount == 0)
    #expect(contextWindow.isIndexBuilding)
}

@MainActor
@Test
func commitDocumentSourceReadsBlobWhileWorktreeReadsDisk() async throws {
    let fixture = try SnapshotGitFixture()
    defer { fixture.remove() }
    let file = fixture.root.appendingPathComponent("main.rs")
    try snapshotWrite("fn value() { /* X */ }", to: file)
    try fixture.git("add", "main.rs")
    try fixture.commit("X")
    try snapshotWrite("fn value() { /* Y */ }", to: file)
    let model = AppModel()

    model.openProject(root: fixture.root)
    #expect(await testWaitUntil("model.snapshotPhase == .fullReady") { model.snapshotPhase == .fullReady })
    model.navigate(to: file)
    let worktreeSnapshotID = model.currentSnapshotID
    let worktree = try DocumentLoader().load(file: file).document
    #expect(String(bytes: worktree.bytes, encoding: .utf8)?.contains("Y") == true)

    model.switchToCommit("HEAD")
    #expect(await testWaitUntil("model.currentRevision == \"HEAD\" && model.snapshotPhase != nil") {
        model.currentRevision == "HEAD" && model.snapshotPhase != nil
    })
    #expect(model.selectedFile == file.standardizedFileURL)
    #expect(model.currentSnapshotID != worktreeSnapshotID)
    let source = try #require(model.documentSource)
    let committed = try DocumentLoader(source: source).load(file: file).document
    #expect(String(bytes: committed.bytes, encoding: .utf8)?.contains("X") == true)
    #expect(String(bytes: committed.bytes, encoding: .utf8)?.contains("Y") == false)

    let commitSnapshotID = model.currentSnapshotID
    model.switchToWorktree()
    #expect(await testWaitUntil("model.snapshotPhase != nil && model.currentSnapshotID != commitSnapshotID") {
        model.snapshotPhase != nil && model.currentSnapshotID != commitSnapshotID
    })
    #expect(model.documentSource == nil)
    let live = try DocumentLoader().load(file: file).document
    #expect(String(bytes: live.bytes, encoding: .utf8)?.contains("Y") == true)
}

@MainActor
@Test
func appModelResolvesAgainstTheSelectedCommitSession() async throws {
    let fixture = try SnapshotGitFixture()
    defer { fixture.remove() }
    let library = fixture.root.appendingPathComponent("db.rs")
    let main = fixture.root.appendingPathComponent("main.rs")
    let oldMain = "mod db; use crate::db::old_target; fn main() { old_target(); }"
    try snapshotWrite("pub fn old_target() {}", to: library)
    try snapshotWrite(oldMain, to: main)
    try fixture.git("add", "db.rs", "main.rs")
    try fixture.commit("old")
    try snapshotWrite("pub fn new_target() {}", to: library)
    try snapshotWrite(
        "mod db; use crate::db::new_target; fn main() { new_target(); }",
        to: main
    )
    try fixture.git("add", "db.rs", "main.rs")
    try fixture.commit("new")
    let model = AppModel()

    model.openProject(root: fixture.root)
    #expect(await testWaitUntil("model.snapshotPhase == .fullReady") { model.snapshotPhase == .fullReady })
    model.switchToCommit("HEAD~1")
    #expect(await testWaitUntil("model.snapshotPhase == .fullReady") { model.snapshotPhase == .fullReady })
    let offset = UInt32(
        oldMain[..<oldMain.range(of: "old_target();")!.lowerBound].utf8.count
    )
    let candidate = await model.contextWindow.explicitJump(
        file: "main.rs",
        offset: offset
    )

    #expect(candidate?.path == "db.rs")
    #expect(candidate?.line == 1)
    guard case let .ready(_, context) = model.projectState else {
        Issue.record("expected commit session")
        return
    }
    #expect(context.generation == model.generation)
}

@MainActor
@Test
func snapshotSwitchAndFileOpenHaveBrowserHistorySemantics() async throws {
    let files = [
        "a.rs": "fn a() { let value = 1; }\n",
        "b.rs": "fn b() { let value = 2; }\n",
    ]
    let root = try snapshotTemporaryProject(files)
    defer { try? FileManager.default.removeItem(at: root) }
    let initial = try ProjectIndexer().index(root: root)
    let worktree = TestSnapshot(
        label: "worktree",
        snapshotID: initial.snapshotID,
        files: files
    )
    let commit = TestSnapshot(label: "C", files: files)
    let service = ControlledSnapshotIndexService(
        initialSession: initial,
        worktreeSnapshot: worktree,
        snapshots: ["C": commit]
    )
    let model = AppModel(indexService: service)
    let a = root.appendingPathComponent("a.rs")
    let b = root.appendingPathComponent("b.rs")
    let worktreeA = snapshotJumpRecord(
        "a.rs",
        offset: 8,
        snapshotID: worktree.snapshotID
    )
    let commitA = snapshotJumpRecord(
        "a.rs",
        offset: 8,
        snapshotID: commit.snapshotID
    )
    let commitB = snapshotJumpRecord(
        "b.rs",
        offset: 9,
        snapshotID: commit.snapshotID
    )

    model.openProject(root: root)
    #expect(await testWaitUntil("model.snapshotPhase == .fullReady") { model.snapshotPhase == .fullReady })
    model.navigate(to: a, byteOffset: 8)
    #expect(model.currentSnapshotID == worktree.snapshotID)
    #expect(model.selectedFile == a)
    let worktreeTrailNodeID = model.readingTrail.activeNodeID
    let trailEdgesBeforeSwitch = model.readingTrail.edges.count

    model.switchToCommit("C", leaving: worktreeA)
    #expect(model.navigationHistory.records.last?.snapshotID == worktree.snapshotID)
    #expect(await testWaitUntil("commit restores the precise reading position") {
        model.snapshotPhase == .fullReady
            && model.selectedFile == a
            && model.selectedByteOffset == 8
    })
    #expect(model.currentSnapshotID == commit.snapshotID)
    #expect(model.readingTrail.activeNodeID == worktreeTrailNodeID)
    #expect(model.readingTrail.edges.count == trailEdgesBeforeSwitch)

    model.navigate(to: b, byteOffset: 9, leaving: commitA)
    #expect(model.currentSnapshotID == commit.snapshotID)
    #expect(model.selectedFile == b)
    #expect(model.navigationHistory.records == [worktreeA, commitA])

    model.goBack(from: commitB)
    #expect(model.currentSnapshotID == commit.snapshotID)
    #expect(await testWaitUntil("model.selectedFile == a && model.selectedByteOffset == 8") {
        model.selectedFile == a && model.selectedByteOffset == 8
    })
    #expect(model.navigationHistory.records.count == 2)

    model.goBack(from: commitA)
    #expect(await testWaitUntil("model.currentSnapshotID == worktree.snapshotID && model.selectedFile == a && model.selectedByteOffset == 8") {
        model.currentSnapshotID == worktree.snapshotID
            && model.selectedFile == a
            && model.selectedByteOffset == 8
    })
    #expect(model.navigationHistory.records.count == 2)

    model.goForward()
    #expect(await testWaitUntil("model.currentSnapshotID == commit.snapshotID && model.selectedFile == a && model.selectedByteOffset == 8") {
        model.currentSnapshotID == commit.snapshotID
            && model.selectedFile == a
            && model.selectedByteOffset == 8
    })
    #expect(model.navigationHistory.records.count == 2)

    model.goForward()
    #expect(model.currentSnapshotID == commit.snapshotID)
    #expect(await testWaitUntil("model.selectedFile == b && model.selectedByteOffset == 9") {
        model.selectedFile == b && model.selectedByteOffset == 9
    })
    #expect(model.navigationHistory.records.count == 2)

    model.goBack(from: commitB)
    #expect(await testWaitUntil("back to commit A before rapid forward") {
        model.selectedFile == a && model.selectedByteOffset == 8
    })
    model.goBack(from: commitA)
    #expect(await testWaitUntil("back to worktree A before rapid forward") {
        model.currentSnapshotID == worktree.snapshotID
            && model.selectedFile == a
    })
    model.goForward()
    model.goForward()
    #expect(await testWaitUntil("latest rapid forward wins") {
        model.currentSnapshotID == commit.snapshotID
            && model.selectedFile == b
            && model.selectedByteOffset == 9
    })
}

@MainActor
@Test
func oldWorktreeReplayUsesCurrentWorktreeAndSaysSo() async throws {
    let files = ["a.rs": "fn a() {}\n", "b.rs": "fn b() {}\n"]
    let root = try snapshotTemporaryProject(files)
    defer { try? FileManager.default.removeItem(at: root) }
    let initial = try ProjectIndexer().index(root: root)
    let oldWorktree = TestSnapshot(
        label: "old-worktree",
        snapshotID: initial.snapshotID,
        files: files
    )
    let currentWorktree = TestSnapshot(
        label: "current-worktree",
        files: [
            "a.rs": "fn a() {} // changed\n",
            "b.rs": "fn b() {}\n",
        ]
    )
    let commit = TestSnapshot(label: "C", files: files)
    let service = ControlledSnapshotIndexService(
        initialSession: initial,
        worktreeSnapshot: oldWorktree,
        snapshots: ["C": commit]
    )
    let model = AppModel(indexService: service)
    let a = root.appendingPathComponent("a.rs")
    let oldJump = snapshotJumpRecord(
        "a.rs",
        offset: 3,
        snapshotID: oldWorktree.snapshotID
    )

    model.openProject(root: root)
    #expect(await testWaitUntil("initial worktree ready") {
        model.snapshotPhase == .fullReady
    })
    model.navigate(to: a, byteOffset: 3)
    let oldTrailNodeID = try #require(model.readingTrail.activeNodeID)
    model.switchToCommit("C", leaving: oldJump)
    #expect(await testWaitUntil("commit ready") {
        model.snapshotPhase == .fullReady
            && model.currentSnapshotID == commit.snapshotID
    })
    await service.setWorktreeSnapshot(currentWorktree)

    model.goBack(from: snapshotJumpRecord(
        "b.rs",
        offset: 3,
        snapshotID: commit.snapshotID
    ))

    #expect(await testWaitUntil("current worktree replay published") {
        model.currentSnapshotID == currentWorktree.snapshotID
            && model.selectedFile == a
            && model.selectedByteOffset == 3
            && model.replayNotice == "replayed against current worktree · "
                + "restored by unverified byte offset"
    })
    #expect(model.readingTrail.activeNodeID == oldTrailNodeID)
}

@MainActor
@Test
func snapshotSwitchDoesNotPushWithoutASelectedFile() async throws {
    let files = ["a.rs": "fn a() {}\n"]
    let root = try snapshotTemporaryProject(files)
    defer { try? FileManager.default.removeItem(at: root) }
    let initial = try ProjectIndexer().index(root: root)
    let commit = TestSnapshot(label: "C", files: files)
    let service = ControlledSnapshotIndexService(
        initialSession: initial,
        snapshots: ["C": commit]
    )
    let model = AppModel(indexService: service)

    model.openProject(root: root)
    #expect(await testWaitUntil("model.snapshotPhase == .fullReady") { model.snapshotPhase == .fullReady })
    model.switchToCommit("C", leaving: snapshotJumpRecord(
        "a.rs",
        offset: 0,
        snapshotID: initial.snapshotID
    ))

    #expect(model.navigationHistory.records.isEmpty)
    #expect(await testWaitUntil("model.snapshotPhase == .fullReady") { model.snapshotPhase == .fullReady })
}

@MainActor
@Test
func snapshotSwitchClearsASelectionMissingFromTheTarget() async throws {
    let files = ["a.rs": "fn a() {}\n"]
    let root = try snapshotTemporaryProject(files)
    defer { try? FileManager.default.removeItem(at: root) }
    let initial = try ProjectIndexer().index(root: root)
    let commit = TestSnapshot(label: "C", files: ["b.rs": "fn b() {}\n"])
    let service = ControlledSnapshotIndexService(
        initialSession: initial,
        snapshots: ["C": commit]
    )
    let model = AppModel(indexService: service)
    let a = root.appendingPathComponent("a.rs")

    model.openProject(root: root)
    #expect(await testWaitUntil("model.snapshotPhase == .fullReady") { model.snapshotPhase == .fullReady })
    model.navigate(to: a)
    model.switchToCommit("C", leaving: snapshotJumpRecord(
        "a.rs",
        offset: 0,
        snapshotID: initial.snapshotID
    ))

    #expect(await testWaitUntil("model.snapshotPhase == .fullReady") { model.snapshotPhase == .fullReady })
    #expect(model.selectedFile == nil)
}

@MainActor
@Test
func crossSnapshotReplayFallsBackToLineAndColumnAfterFileShrinks() async throws {
    let files = ["a.rs": "x\ny\n", "b.rs": "fn b() {}\n"]
    let root = try snapshotTemporaryProject(files)
    defer { try? FileManager.default.removeItem(at: root) }
    let initial = try ProjectIndexer().index(root: root)
    let worktree = TestSnapshot(
        label: "worktree",
        snapshotID: initial.snapshotID,
        files: files
    )
    let commit = TestSnapshot(label: "C", files: [
        "a.rs": "first line\nsecond line is much longer\n",
        "b.rs": "fn b() {}\n",
    ])
    let service = ControlledSnapshotIndexService(
        initialSession: initial,
        worktreeSnapshot: worktree,
        snapshots: ["C": commit]
    )
    let model = AppModel(indexService: service)
    let a = root.appendingPathComponent("a.rs")

    model.openProject(root: root)
    #expect(await testWaitUntil("model.snapshotPhase == .fullReady") { model.snapshotPhase == .fullReady })
    model.navigationHistory.push(snapshotJumpRecord(
        "a.rs",
        offset: 100,
        line: 2,
        column: 1,
        snapshotID: worktree.snapshotID
    ))
    model.switchToCommit("C")
    #expect(await testWaitUntil("model.snapshotPhase == .fullReady") { model.snapshotPhase == .fullReady })

    model.goBack(from: snapshotJumpRecord(
        "b.rs",
        offset: 0,
        snapshotID: commit.snapshotID
    ))

    #expect(await testWaitUntil("model.currentSnapshotID == worktree.snapshotID && model.selectedFile == a && model.selectedByteOffset == 2") {
        model.currentSnapshotID == worktree.snapshotID
            && model.selectedFile == a
            && model.selectedByteOffset == 2
    })
}

@MainActor
@Test
func crossSnapshotReplayFallsBackToSymbolAnchorWhenCoordinatesAreInvalid() async throws {
    let source = "fn moved_target() {\n    let value = 1;\n}\n"
    let files = ["a.rs": source, "b.rs": "fn b() {}\n"]
    let root = try snapshotTemporaryProject(files)
    defer { try? FileManager.default.removeItem(at: root) }
    let initial = try ProjectIndexer().index(root: root)
    let worktree = TestSnapshot(
        label: "worktree",
        snapshotID: initial.snapshotID,
        files: files
    )
    let commit = TestSnapshot(label: "C", files: [
        "a.rs": "fn replacement() {}\n",
        "b.rs": "fn b() {}\n",
    ])
    let service = ControlledSnapshotIndexService(
        initialSession: initial,
        worktreeSnapshot: worktree,
        snapshots: ["C": commit]
    )
    let model = AppModel(indexService: service)
    let a = root.appendingPathComponent("a.rs")
    let nameOffset = UInt32(source[..<source.range(of: "moved_target")!.lowerBound].utf8.count)

    model.openProject(root: root)
    #expect(await testWaitUntil("model.snapshotPhase == .fullReady") { model.snapshotPhase == .fullReady })
    model.navigationHistory.push(snapshotJumpRecord(
        "a.rs",
        offset: 100,
        line: 99,
        column: 99,
        symbolAnchor: "moved_target",
        snapshotID: worktree.snapshotID
    ))
    model.switchToCommit("C")
    #expect(await testWaitUntil("model.snapshotPhase == .fullReady") { model.snapshotPhase == .fullReady })

    model.goBack(from: snapshotJumpRecord(
        "b.rs",
        offset: 0,
        snapshotID: commit.snapshotID
    ))

    #expect(await testWaitUntil("model.currentSnapshotID == worktree.snapshotID && model.selectedFile == a && model.selectedByteOffset == nameOffset") {
        model.currentSnapshotID == worktree.snapshotID
            && model.selectedFile == a
            && model.selectedByteOffset == nameOffset
    })
}

@MainActor
@Test
func sameSnapshotReplayDoesNotStartAnotherSnapshotSwitch() async throws {
    let files = ["a.rs": "fn a() {}\n", "b.rs": "fn b() {}\n"]
    let root = try snapshotTemporaryProject(files)
    defer { try? FileManager.default.removeItem(at: root) }
    let initial = try ProjectIndexer().index(root: root)
    let service = ControlledSnapshotIndexService(initialSession: initial, snapshots: [:])
    let model = AppModel(indexService: service)
    let a = root.appendingPathComponent("a.rs")

    model.openProject(root: root)
    #expect(await testWaitUntil("model.snapshotPhase == .fullReady") { model.snapshotPhase == .fullReady })
    let generation = model.generation
    model.navigationHistory.push(snapshotJumpRecord(
        "a.rs",
        offset: 3,
        snapshotID: initial.snapshotID
    ))

    model.goBack(from: snapshotJumpRecord(
        "b.rs",
        offset: 4,
        snapshotID: initial.snapshotID
    ))

    #expect(model.generation == generation)
    #expect(model.snapshotPhase == .fullReady)
    #expect(await testWaitUntil("model.selectedFile == a && model.selectedByteOffset == 3") {
        model.selectedFile == a && model.selectedByteOffset == 3
    })
}

@MainActor
@Test
func compareModelUsesTheExplicitModeForDiffAndFunctionChanges() async throws {
    let root = try snapshotTemporaryProject([
        "main.rs": "fn target() { 1 }\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("main.rs")
    let model = CompareModel()
    let generation = model.beginLoading(revision: "RIGHT")
    #expect(model.install(
        snapshot: TestSnapshot(
            label: "right",
            files: ["main.rs": "fn target() { 2 }\n"]
        ),
        root: root,
        revision: "RIGHT",
        generation: generation
    ))

    model.update(
        file: file,
        leftSource: { _ in Array("fn target() { 1 }\n".utf8) },
        languageMode: LanguageMode(language: .rust)
    )

    #expect(await testWaitUntil("explicit-mode compare completes") {
        !model.isLoading && model.diff != nil
    })
    #expect((model.diff?.changeCount ?? 0) > 0)
    #expect(model.functionChanges.contains { $0.kind == .bodyChanged })
    #expect(model.errorMessage == nil)
}

@MainActor
@Test
func compareModelDoesNotPublishAnOlderModeCompletion() async throws {
    let root = try snapshotTemporaryProject([
        "main.rs": "fn target() { 1 }\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("main.rs")
    let model = CompareModel()
    let generation = model.beginLoading(revision: "RIGHT")
    #expect(model.install(
        snapshot: TestSnapshot(
            label: "right",
            files: ["main.rs": "fn target() { 2 }\n"]
        ),
        root: root,
        revision: "RIGHT",
        generation: generation
    ))

    model.update(
        file: file,
        leftSource: { _ in Array("fn target() { 1 }\n".utf8) },
        languageMode: LanguageMode(language: .rust)
    )
    model.update(
        file: file,
        leftSource: { _ in Array("fn target() { 1 }\n".utf8) },
        languageMode: LanguageMode(language: .javascript)
    )

    #expect(await testWaitUntil("new mode completion publishes") {
        !model.isLoading && model.diff == nil && model.errorMessage != nil
    })
    let currentError = model.errorMessage
    try await Task.sleep(for: .milliseconds(50))
    #expect(model.diff == nil)
    #expect(model.functionChanges.isEmpty)
    #expect(model.errorMessage == currentError)
}

@MainActor
@Test
func switchingMainSnapshotClearsAndReleasesCompareSnapshot() async throws {
    let root = try snapshotTemporaryProject(["main.rs": "fn current() {}"])
    defer { try? FileManager.default.removeItem(at: root) }
    let initial = try ProjectIndexer().index(root: root)
    let service = ControlledSnapshotIndexService(initialSession: initial, snapshots: [:])
    let model = AppModel(indexService: service)

    model.openProject(root: root)
    #expect(await testWaitUntil("model.snapshotPhase == .fullReady") { model.snapshotPhase == .fullReady })
    model.navigate(to: root.appendingPathComponent("main.rs"))

    var right: TestSnapshot? = TestSnapshot(
        label: "right",
        files: ["main.rs": "fn previous() {}"]
    )
    weak let retainedRight = right
    let compareGeneration = model.compare.beginLoading(revision: "RIGHT")
    #expect(model.compare.install(
        snapshot: right!,
        root: root,
        revision: "RIGHT",
        generation: compareGeneration
    ))
    model.compare.update(
        file: model.selectedFile,
        leftSource: model.documentSource,
        languageMode: LanguageMode(language: .rust)
    )
    right = nil
    #expect(retainedRight != nil)
    #expect(model.compare.rightBytes == Array("fn previous() {}".utf8))

    model.switchToCommit("C")

    #expect(model.compare.rightRevision == nil)
    #expect(model.compare.rightSnapshotID == nil)
    #expect(model.compare.rightSource == nil)
    #expect(model.compare.rightBytes == nil)
    #expect(model.compare.diff == nil)
    #expect(retainedRight == nil)
}

private final class TestSnapshot: Snapshot, @unchecked Sendable {
    let label: String
    let snapshotID: SnapshotID
    let objectFormat = GitObjectFormat.sha1
    let sourceKind = SourceKind.tracked
    private let files: [String: [UInt8]]

    init(
        label: String,
        snapshotID: SnapshotID = SnapshotID(rawValue: UUID()),
        files: [String: String]
    ) {
        self.label = label
        self.snapshotID = snapshotID
        self.files = files.mapValues { Array($0.utf8) }
    }

    func listFiles() -> [(path: String, contentID: ContentID, fileMode: FileMode)] {
        files.keys.sorted().map { path in
            (path, ContentID.sha256(of: files[path]!), .regular)
        }
    }

    func readBytes(path: String) throws -> [UInt8] {
        guard let bytes = files[path] else { throw SnapshotTestError.missing(path) }
        return bytes
    }
}

private actor ControlledSnapshotIndexService: IndexService {
    private let initialSession: EngineSession
    private var worktreeSnapshot: TestSnapshot?
    private let snapshots: [String: TestSnapshot]
    private let store = ProjectIndexStore()
    private var blockedCached: Set<String>
    private var blockedFull: Set<String>
    private var labelsBySnapshotID: [SnapshotID: String] = [:]
    private var fullStarted: Set<String> = []
    private var cancelled: Set<String> = []
    private var indexLanguages: [LanguageID] = []
    private var captureLanguages: [LanguageID] = []
    private var prepareLanguages: [LanguageID] = []
    private let completedLanguageOverride: LanguageID?

    init(
        initialSession: EngineSession,
        worktreeSnapshot: TestSnapshot? = nil,
        snapshots: [String: TestSnapshot],
        blockedCached: Set<String> = [],
        blockedFull: Set<String> = [],
        completedLanguageOverride: LanguageID? = nil
    ) {
        self.initialSession = initialSession
        self.worktreeSnapshot = worktreeSnapshot
        self.snapshots = snapshots
        self.blockedCached = blockedCached
        self.blockedFull = blockedFull
        self.completedLanguageOverride = completedLanguageOverride
    }

    func index(root: URL, language: LanguageID) async throws -> EngineSession {
        indexLanguages.append(language)
        return initialSession
    }

    func captureSnapshot(
        root: URL,
        revision: String?,
        language: LanguageID
    ) async throws -> any Snapshot {
        captureLanguages.append(language)
        let snapshot = if let revision {
            snapshots[revision]
        } else {
            worktreeSnapshot
        }
        guard let snapshot else { throw SnapshotTestError.missing(revision ?? "worktree") }
        labelsBySnapshotID[snapshot.snapshotID] = snapshot.label
        return snapshot
    }

    func prepareSnapshot(
        _ snapshot: any Snapshot,
        language: LanguageID
    ) async throws -> ProjectIndexer.PreparedSnapshot {
        prepareLanguages.append(language)
        let label = try label(for: snapshot.snapshotID)
        while blockedCached.contains(label) {
            try Task.checkCancellation()
            await Task.yield()
        }
        return try ProjectIndexer().prepareSnapshot(
            snapshot,
            into: store,
            language: language
        )
    }

    func completeSnapshot(
        _ prepared: ProjectIndexer.PreparedSnapshot
    ) async throws -> EngineSession {
        let label = try label(for: prepared.cachedSession.snapshotID)
        fullStarted.insert(label)
        do {
            while blockedFull.contains(label) {
                try Task.checkCancellation()
                await Task.yield()
            }
            let session = try ProjectIndexer().completeSnapshot(prepared)
            guard let completedLanguageOverride else { return session }
            return EngineSession(
                store: session.store,
                snapshotView: SnapshotView(
                    reprofiling: session.snapshotView,
                    analysisProfile: .placeholder(
                        language: completedLanguageOverride,
                        root: session.analysisProfile.projectRoot
                    )
                )
            )
        } catch is CancellationError {
            cancelled.insert(label)
            throw CancellationError()
        }
    }

    func releaseCached(_ label: String) { blockedCached.remove(label) }
    func releaseFull(_ label: String) { blockedFull.remove(label) }
    func setWorktreeSnapshot(_ snapshot: TestSnapshot) {
        worktreeSnapshot = snapshot
    }
    func hasStartedFull(_ label: String) -> Bool { fullStarted.contains(label) }
    func wasCancelled(_ label: String) -> Bool { cancelled.contains(label) }
    func snapshotID(for label: String) -> SnapshotID? { snapshots[label]?.snapshotID }
    func receivedLanguages() -> (
        index: [LanguageID],
        capture: [LanguageID],
        prepare: [LanguageID]
    ) {
        (indexLanguages, captureLanguages, prepareLanguages)
    }

    private func label(for snapshotID: SnapshotID) throws -> String {
        guard let label = labelsBySnapshotID[snapshotID] else {
            throw SnapshotTestError.missing("snapshot label")
        }
        return label
    }

}

@MainActor
private final class SnapshotResolverGate {
    private var continuation: CheckedContinuation<[ResolutionCandidate], Never>?
    var isPending: Bool { continuation != nil }

    func resolve(
        session: EngineSession,
        file: PathID,
        offset: UInt32,
        context: QueryContext
    ) async throws -> [ResolutionCandidate] {
        await withCheckedContinuation { continuation = $0 }
    }

    func complete(_ candidates: [ResolutionCandidate]) {
        continuation?.resume(returning: candidates)
        continuation = nil
    }
}

private final class SnapshotGitFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CodeInsightSnapshotSwitchTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git("init", "-q")
    }

    func commit(_ message: String) throws {
        try git(
            "-c", "user.name=CodeInsight",
            "-c", "user.email=codeinsight@example.com",
            "commit", "-q", "-m", message
        )
    }

    @discardableResult
    func git(_ arguments: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = root
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SnapshotTestError.git(String(
                data: error.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "git failed")
        }
        return String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private func snapshotTemporaryProject(_ files: [String: String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "CodeInsightSnapshotSwitchTests-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for (path, contents) in files {
        try snapshotWrite(contents, to: root.appendingPathComponent(path))
    }
    return root
}

private func snapshotWrite(_ contents: String, to file: URL) throws {
    try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try contents.write(to: file, atomically: true, encoding: .utf8)
}

private func snapshotJumpRecord(
    _ path: String,
    offset: UInt32,
    line: UInt32 = 1,
    column: UInt32? = nil,
    symbolAnchor: String? = nil,
    snapshotID: SnapshotID
) -> JumpRecord {
    JumpRecord(
        path: path,
        contentID: nil,
        byteOffset: offset,
        line: line,
        column: column ?? offset + 1,
        symbolAnchor: symbolAnchor,
        snapshotID: snapshotID
    )
}

private enum SnapshotTestError: Error {
    case missing(String)
    case git(String)
}
