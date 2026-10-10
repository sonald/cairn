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
        initialSnapshotID: initial.snapshotID,
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
    #expect(model.fileTree?.children.first?.children.map(\.name)
        == ["c.rs", "ignored.py"])
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
    // The commit keeps the worktree's set: its Python file is not analyzed.
    #expect(await service.preparedLanguages() == [.rust, .rust])
}

@MainActor
@Test
func mixedWorkspaceOpenDetectsItsLanguagesAndInstallsSharedSessions() async throws {
    let snapshot = TestSnapshot(label: "mixed", files: [
        "main.rs": "fn main() {}\n",
        "lib.py": "def f():\n    pass\n",
        "a.ts": "export function a() {}\n",
        "b.tsx": "export const b = 1\n",
    ])
    let fixture = try SnapshotGitFixture()
    defer { fixture.remove() }
    let service = ControlledSnapshotIndexService(
        worktreeSnapshot: snapshot,
        snapshots: [:]
    )
    let model = AppModel(indexService: service)
    await model.openProject(root: fixture.root).value

    #expect(model.projectLanguages == [.rust, .python, .typescript])
    #expect(model.querySessions.count == 3)
    #expect(model.querySessions.map { $0.0.analysisProfile.language }
        == [.rust, .python, .typescript])
    #expect(Set(model.querySessions.map { $0.0.snapshotID }).count == 1)
    #expect(await service.preparedLanguages() == [.rust, .python, .typescript])
}

@MainActor
@Test
func mixedOpenDoesNotPublishUntilAllFullSessionsComplete() async throws {
    let fixture = try SnapshotGitFixture()
    defer { fixture.remove() }
    let snapshot = TestSnapshot(label: "mixed", files: [
        "main.rs": "fn main() {}\n",
        "lib.py": "def f():\n    pass\n",
        "a.ts": "export function a() {}\n",
        "b.tsx": "export const b = 1\n",
    ])
    let service = ControlledSnapshotIndexService(
        worktreeSnapshot: snapshot,
        snapshots: [:],
        blockedFull: ["mixed-1"]
    )
    let model = AppModel(indexService: service)
    let task = Task {
        await model.openProject(root: fixture.root).value
    }
    #expect(await testWaitUntil("python full blocked after rust full") {
        await service.hasStartedFull(label: "mixed", language: .python)
    })
    #expect(model.snapshotPhase == .cachedReady)
    #expect(model.querySessions.count == 3)
    #expect(model.querySessions.first.map {
        $0.0.snapshotID
    } == snapshot.snapshotID)
    await service.releaseFull("mixed-1")
    try await task.value
    #expect(model.querySessions.count == 3)
}

@MainActor
@Test
func mixedCommitToWorktreeKeepsLanguagesSnapshotAndRoute() async throws {
    let fixture = try SnapshotGitFixture()
    defer { fixture.remove() }
    let worktree = TestSnapshot(label: "wt", files: [
        "main.rs": "fn worktree() {}\n",
        "lib.py": "def worktree():\n    pass\n",
    ])
    let commit = TestSnapshot(label: "commit", files: [
        "main.rs": "fn committed() {}\n",
        "lib.py": "def committed():\n    pass\n",
    ])
    let service = ControlledSnapshotIndexService(
        worktreeSnapshot: worktree,
        snapshots: ["C": commit]
    )
    let model = AppModel(
        indexService: service,
        commitPicker: CommitPickerModel(commits: [
            CommitInfo(shortSHA: "C", fullSHA: "C", summary: "c", authorName: "test", date: Date()),
        ])
    )
    await model.openProject(root: fixture.root).value

    model.switchToCommit("C")
    #expect(model.querySessions.isEmpty)
    #expect(await testWaitUntil("mixed commit full ready") {
        model.snapshotPhase == .fullReady && model.currentRevision == "C"
    })
    #expect(model.projectLanguages == [.rust, .python])
    let commitSnapshotID = model.currentSnapshotID
    model.navigate(to: fixture.root.appendingPathComponent("lib.py"))

    model.switchToWorktree()
    #expect(model.querySessions.isEmpty)
    #expect(await testWaitUntil("mixed worktree full ready") {
        model.snapshotPhase == .fullReady && model.currentRevision == nil
    })
    #expect(model.projectLanguages == [.rust, .python])
    let worktreeSnapshotID = try #require(model.currentSnapshotID)
    #expect(worktreeSnapshotID != commitSnapshotID)
    #expect(Set(model.querySessions.map { $0.0.snapshotID }).count == 1)
    guard case let .ready(active, _) = model.projectState else {
        Issue.record("expected worktree route")
        return
    }
    #expect(active.analysisProfile.language == .python)
}

@MainActor
@Test
func mixedZeroSourceRevisionRetainsEmptyTypeScriptSession() async throws {
    let fixture = try SnapshotGitFixture()
    defer { fixture.remove() }
    let worktree = TestSnapshot(label: "wt", files: [
        "main.rs": "fn main() {}\n",
        "lib.py": "def py():\n    pass\n",
        "a.ts": "export const a = 1\n",
    ])
    let commit = TestSnapshot(label: "commitNoTS", files: [
        "main.rs": "fn old() {}\n",
        "lib.py": "def old():\n    pass\n",
    ])
    let service = ControlledSnapshotIndexService(
        worktreeSnapshot: worktree,
        snapshots: ["C": commit]
    )
    let model = AppModel(
        indexService: service,
        commitPicker: CommitPickerModel(commits: [
            CommitInfo(shortSHA: "C", fullSHA: "C", summary: "c", authorName: "test", date: Date()),
        ])
    )
    await model.openProject(root: fixture.root).value
    model.switchToCommit("C")
    #expect(await testWaitUntil("zero-source mixed commit ready") {
        model.snapshotPhase == .fullReady && model.currentRevision == "C"
    })
    #expect(model.projectLanguages == [.rust, .python, .typescript])
    let sessions = model.querySessions.map { $0.0.analysisProfile.language }
    #expect(sessions.contains(.typescript))
    let ts = try #require(model.querySessions.first {
        $0.0.analysisProfile.language == .typescript
    })
    #expect(ts.0.contentIndexes.isEmpty)
}

@MainActor
@Test
func staleMixedOpenCompletionIsDiscarded() async throws {
    let first = TestSnapshot(label: "first", files: [
        "main.rs": "fn a() {}\n",
        "lib.py": "def b():\n    pass\n",
    ])
    let fixture = try SnapshotGitFixture()
    defer { fixture.remove() }
    let service = ControlledSnapshotIndexService(
        worktreeSnapshot: first,
        snapshots: [:],
        blockedCached: ["second"],
        blockedFull: ["first-1"]
    )
    let model = AppModel(indexService: service)
    let firstTask = Task {
        await model.openProject(root: fixture.root).value
    }
    #expect(await testWaitUntil("first python full started") {
        await service.hasStartedFull(label: "first", language: .python)
    })
    let secondRoot = try snapshotTemporaryProject(["main.rs": "fn second() {}"])
    defer { try? FileManager.default.removeItem(at: secondRoot) }
    let second = TestSnapshot(label: "second", files: ["main.rs": "fn second() {}"])
    await service.setWorktreeSnapshot(second)
    let secondTask = Task {
        await model.openProject(root: secondRoot).value
    }
    #expect(await testWaitUntil("second cached started") {
        await service.hasStartedCached("second")
    })
    #expect(model.querySessions.isEmpty)
    await service.releaseCached("second")
    try await secondTask.value
    #expect(model.snapshotPhase == .fullReady)
    await service.releaseFull("first-1")
    try await firstTask.value
    #expect(model.projectLanguages == [.rust])
    #expect(model.currentSnapshotID == second.snapshotID)
    #expect(model.querySessions.allSatisfy { $0.0.snapshotID == second.snapshotID })
    #expect(model.projectRoot?.standardizedFileURL == secondRoot.standardizedFileURL)
}

@MainActor
@Test
func wrongLanguageMixedFullFailsAndClearsSessions() async throws {
    let fixture = try SnapshotGitFixture()
    defer { fixture.remove() }
    let snapshot = TestSnapshot(label: "wrong", files: [
        "main.rs": "fn main() {}\n",
        "lib.py": "def f():\n    pass\n",
    ])
    let service = ControlledSnapshotIndexService(
        worktreeSnapshot: snapshot,
        snapshots: [:],
        completedLanguageOverrides: ["wrong": .typescript]
    )
    let model = AppModel(indexService: service)
    await model.openProject(root: fixture.root).value

    #expect(model.querySessions.isEmpty)
    guard case .failed = model.projectState else {
        Issue.record("expected failed mixed state")
        return
    }
    #expect(model.projectRoot?.standardizedFileURL == fixture.root.standardizedFileURL)
    #expect(model.projectLanguages == [.rust, .python])
}

@MainActor
@Test
func mixedOpenDoesNotExposeSessionsBeforeCachedArrayIsReady() async throws {
    let fixture = try SnapshotGitFixture()
    defer { fixture.remove() }
    let snapshot = TestSnapshot(label: "mixedprep", files: [
        "main.rs": "fn main() {}\n",
        "lib.py": "def f():\n    pass\n",
        "a.ts": "export function a() {}\n",
        "b.tsx": "export const b = 1\n",
    ])
    let service = ControlledSnapshotIndexService(
        worktreeSnapshot: snapshot,
        snapshots: [:],
        blockedCached: ["mixedprep"]
    )
    let model = AppModel(indexService: service)
    let task = Task {
        await model.openProject(root: fixture.root).value
    }
    #expect(await testWaitUntil("cached prepare started") {
        await service.hasStartedCached("mixedprep")
    })
    #expect(model.querySessions.isEmpty)
    #expect(model.snapshotPhase != .cachedReady)
    await service.releaseCached("mixedprep")
    try await task.value
    #expect(model.querySessions.count == 3)
}

@MainActor
@Test
func pythonSnapshotFirstPaintKeepsForeignFilesVisibleAndSnapshotReadable() async throws {
    let root = try snapshotTemporaryProject(["main.py": "def current():\n    pass\n"])
    defer { try? FileManager.default.removeItem(at: root) }
    let initial = try ProjectIndexer().index(root: root, language: .python)
    let service = ControlledSnapshotIndexService(
        initialSnapshotID: initial.snapshotID,
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

    model.openProject(root: root)
    #expect(await testWaitUntil("model.snapshotPhase == .fullReady") { model.snapshotPhase == .fullReady })
    model.navigate(to: foreign)
    #expect(model.selectedFile == foreign.standardizedFileURL)

    model.switchToCommit("C")
    #expect(await testWaitUntil("model.snapshotPhase == .firstPaint") { model.snapshotPhase == .firstPaint })

    #expect(model.selectedFile == foreign.standardizedFileURL)
    #expect(model.selectedByteOffset == nil)
    #expect(model.fileTree?.children.map(\.name) == ["foreign.rs", "main.py"])
    let source = try #require(model.documentSource)
    #expect(try source(foreign) == Array("fn foreign() {}\n".utf8))
    #expect(model.languageMode(for: foreign) == nil)
}

@MainActor
@Test
func snapshotFullSessionLanguageMismatchFailsBeforeFullPublication() async throws {
    let root = try snapshotTemporaryProject(["main.rs": "fn initial() {}"])
    defer { try? FileManager.default.removeItem(at: root) }
    let initial = try ProjectIndexer().index(root: root)
    let service = ControlledSnapshotIndexService(
        initialSnapshotID: initial.snapshotID,
        snapshots: ["C": TestSnapshot(label: "C", files: ["main.rs": "fn c() {}"])],
        blockedFull: ["C"],
        completedLanguageOverrides: ["C": .python]
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
    #expect(model.projectLanguages == [.rust])
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
    let perProjectURL = stateRoot.appendingPathComponent("sessions")
        .appendingPathComponent(
            AppModel.sessionProjectKey(for: root) + ".json"
        )
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: stateRoot)
        #expect(!FileManager.default.fileExists(atPath: perProjectURL.path))
    }
    let initial = try ProjectIndexer().index(root: root)
    let service = ControlledSnapshotIndexService(
        initialSnapshotID: initial.snapshotID,
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
    let worktreeData = try Data(contentsOf: perProjectURL)

    model.scheduleSessionCheckpoint(panelPreset: .compare)
    model.switchToCommit("C")
    #expect(await testWaitUntil("commit first paint installed") {
        model.snapshotPhase == .firstPaint && model.currentRevision == "C"
    })
    try await Task.sleep(for: .milliseconds(350))

    #expect(try Data(contentsOf: perProjectURL) == worktreeData)
    try model.writeSessionCheckpoint(panelPreset: .compare)
    #expect(try Data(contentsOf: perProjectURL) == worktreeData)

    model.closeTab(1)
    try model.writeSessionCheckpoint(
        panelPreset: .reading,
        allowsPendingTopology: true
    )
    let pendingTopology = try SessionCodec.decode(
        Data(contentsOf: perProjectURL),
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
        Data(contentsOf: perProjectURL),
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
func restoredTrailNodeReplaysByItsSavedRevisionAndWorktreeRecordSwitchesBack()
    async throws
{
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
    let model = AppModel(indexService: ProjectIndexService())

    // Restored trail: a commit node and a worktree node, both without a
    // runtime SnapshotID (as a decoded snapshot carries them).
    let commitNode = TrailNodeID()
    let worktreeNode = TrailNodeID()
    let commitJump = SessionCodec.Jump(
        path: "main.rs",
        contentID: nil,
        byteOffset: 0,
        line: 1,
        column: 1,
        symbolAnchor: "committed",
        revision: revision
    )
    let worktreeJump = SessionCodec.Jump(
        path: "main.rs",
        contentID: nil,
        byteOffset: 0,
        line: 1,
        column: 1,
        symbolAnchor: "worktree",
        revision: nil
    )
    let snapshot = SessionCodec.Snapshot(
        projectRoot: fixture.root.path,
        language: .rust,
        revision: nil,
        activeTabOrdinal: 0,
        panelPreset: PanelPresetModel.reading.rawValue,
        tabs: [
            .file(.init(
                path: "main.rs",
                anchorContentID: nil,
                scrollAnchor: nil,
                selectionAnchor: nil
            )),
        ],
        readingTrail: SessionCodec.TrailState(
            nodes: [
                .init(id: commitNode.rawValue, jump: commitJump),
                .init(id: worktreeNode.rawValue, jump: worktreeJump),
            ],
            edges: [
                .init(
                    from: commitNode.rawValue,
                    to: worktreeNode.rawValue,
                    cause: "relation",
                    frozenInspectorDisplay: nil,
                    readingSetRole: nil
                ),
            ],
            activeNodeID: worktreeNode.rawValue
        )
    )
    #expect(await model.restoreSession(snapshot))
    #expect(model.currentRevision == nil)
    #expect(model.readingTrail.nodes.count == 2)

    // Replaying the commit node must switch to that version even though
    // no in-process SnapshotID maps to it.
    model.restoreTrailNode(commitNode)
    try #require(await testWaitUntil("commit version installed") {
        model.currentRevision == revision
            && model.snapshotPhase == .fullReady
    })
    #expect(model.activeNavigationRequest?.cause == .historyReplay)

    // Replaying the worktree node switches back to the worktree instead
    // of reusing the commit that is on screen.
    model.restoreTrailNode(worktreeNode)
    try #require(await testWaitUntil("worktree restored") {
        model.currentRevision == nil && model.snapshotPhase == .fullReady
    })
}

@MainActor
@Test
func replayingAnUnavailableSavedRevisionKeepsTheCurrentView() async throws {
    let fixture = try SnapshotGitFixture()
    defer { fixture.remove() }
    try snapshotWrite(
        "fn worktree() {}\n",
        to: fixture.root.appendingPathComponent("main.rs")
    )
    let model = AppModel(indexService: ProjectIndexService())
    let ghostNode = TrailNodeID()
    let snapshot = SessionCodec.Snapshot(
        projectRoot: fixture.root.path,
        language: .rust,
        revision: nil,
        activeTabOrdinal: 0,
        panelPreset: PanelPresetModel.reading.rawValue,
        tabs: [
            .file(.init(
                path: "main.rs",
                anchorContentID: nil,
                scrollAnchor: nil,
                selectionAnchor: nil
            )),
        ],
        readingTrail: SessionCodec.TrailState(
            nodes: [
                .init(
                    id: ghostNode.rawValue,
                    jump: SessionCodec.Jump(
                        path: "main.rs",
                        contentID: nil,
                        byteOffset: 0,
                        line: 1,
                        column: 1,
                        symbolAnchor: "ghost",
                        revision: "0123456789abcdef0123456789abcdef01234567"
                    )
                ),
            ],
            edges: [],
            activeNodeID: ghostNode.rawValue
        )
    )
    #expect(await model.restoreSession(snapshot))
    let generationBefore = model.generation
    let activeBefore = model.readingTrail.activeNodeID

    model.restoreTrailNode(ghostNode)

    try #require(await testWaitUntil("unavailable version reported") {
        model.replayNotice?.contains("unavailable") == true
    })
    // The viewport, generation, and active trail node are untouched.
    #expect(model.generation == generationBefore)
    #expect(model.currentRevision == nil)
    #expect(model.snapshotPhase == .fullReady)
    #expect(model.readingTrail.activeNodeID == activeBefore)
}

@MainActor
@Test
func switchingAgainCancelsAndDiscardsTheOlderSnapshot() async throws {
    let root = try snapshotTemporaryProject(["main.rs": "fn initial() {}"])
    defer { try? FileManager.default.removeItem(at: root) }
    let initial = try ProjectIndexer().index(root: root)
    let service = ControlledSnapshotIndexService(
        initialSnapshotID: initial.snapshotID,
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
func contextClickBeforeTheFullIndexResolvesWhenItLands() async throws {
    let source = "fn target() {}\nfn main() { target(); }"
    let root = try snapshotTemporaryProject(["main.rs": source])
    defer { try? FileManager.default.removeItem(at: root) }
    // Nothing is cached, so the cached session has no content for main.rs
    // until the full index completes.
    let service = ControlledSnapshotIndexService(snapshots: [:], blockedFull: ["worktree"])
    let model = AppModel(indexService: service)
    let offset = UInt32(source[..<source.range(of: "target();")!.lowerBound].utf8.count)

    model.openProject(root: root)
    #expect(await testWaitUntil("cached session published") {
        model.snapshotPhase == .cachedReady
    })
    model.contextWindow.tokenClicked(file: "main.rs", offset: offset)
    for _ in 0..<20 { await Task.yield() }
    await service.releaseFull("worktree")

    #expect(await testWaitUntil("the click resolves against the full index") {
        model.snapshotPhase == .fullReady && model.contextWindow.candidateCount > 0
    })
}

@MainActor
@Test
func snapshotSwitchInvalidatesAnOlderContextRequest() async throws {
    let source = "fn target() {}\nfn main() { target(); }"
    let root = try snapshotTemporaryProject(["main.rs": source])
    defer { try? FileManager.default.removeItem(at: root) }
    let initial = try ProjectIndexer().index(root: root)
    let service = ControlledSnapshotIndexService(
        initialSnapshotID: initial.snapshotID,
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
    let readme = fixture.root.appendingPathComponent("README.md")
    try snapshotWrite("fn value() { /* X */ }", to: file)
    try snapshotWrite("README X\n", to: readme)
    try fixture.git("add", "main.rs", "README.md")
    try fixture.commit("X")
    try snapshotWrite("fn value() { /* Y */ }", to: file)
    try snapshotWrite("README Y\n", to: readme)
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
    #expect(String(
        bytes: try source(readme),
        encoding: .utf8
    ) == "README X\n")

    let commitSnapshotID = model.currentSnapshotID
    model.switchToWorktree()
    #expect(await testWaitUntil("model.snapshotPhase != nil && model.currentSnapshotID != commitSnapshotID") {
        model.snapshotPhase != nil && model.currentSnapshotID != commitSnapshotID
    })
    #expect(model.documentSource == nil)
    let live = try DocumentLoader().load(file: file).document
    #expect(String(bytes: live.bytes, encoding: .utf8)?.contains("Y") == true)
    #expect(String(
        data: try Data(contentsOf: readme),
        encoding: .utf8
    ) == "README Y\n")
}

@MainActor
@Test
func passiveHistoryReplayRestoresCurrentSnapshotNonSourceFile() async throws {
    let root = try snapshotTemporaryProject([
        "main.rs": "fn main() {}\n",
        "README.md": "# Read me\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let initial = try ProjectIndexer().index(root: root)
    let model = AppModel(indexService: ControlledSnapshotIndexService(
        initialSnapshotID: initial.snapshotID,
        snapshots: [:]
    ))

    model.openProject(root: root)
    #expect(await testWaitUntil("model.snapshotPhase == .fullReady") {
        model.snapshotPhase == .fullReady
    })
    let readme = root.appendingPathComponent("README.md")
    let main = root.appendingPathComponent("main.rs")
    model.navigate(to: readme)
    let readmeRecord = JumpRecord(
        path: "README.md",
        contentID: nil,
        byteOffset: 0,
        line: 0,
        column: 0,
        symbolAnchor: nil,
        snapshotID: model.currentSnapshotID
    )
    model.navigate(to: main, leaving: readmeRecord)
    let mainRecord = JumpRecord(
        path: "main.rs",
        contentID: nil,
        byteOffset: 0,
        line: 1,
        column: 1,
        symbolAnchor: nil,
        snapshotID: model.currentSnapshotID
    )

    model.goBack(from: mainRecord)

    #expect(await testWaitUntil("non-source replay loaded") {
        model.selectedFile?.standardizedFileURL == readme.standardizedFileURL
    })
    #expect(model.selectedByteOffset == nil)
    #expect(model.tabStrip.activeDocument == nil)
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
        initialSnapshotID: initial.snapshotID,
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
        initialSnapshotID: initial.snapshotID,
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
        initialSnapshotID: initial.snapshotID,
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
        initialSnapshotID: initial.snapshotID,
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
        initialSnapshotID: initial.snapshotID,
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
        initialSnapshotID: initial.snapshotID,
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
    let service = ControlledSnapshotIndexService(initialSnapshotID: initial.snapshotID, snapshots: [:])
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
func mixedCompareUsesSelectedFileModeAndDiscardsStaleDiffAfterLanguageRoute()
    async throws
{
    let root = try snapshotTemporaryProject([
        "main.rs": "fn target() {}\n",
        "lib.py": "def target():\n    pass\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let initial = try ProjectIndexer().index(root: root)
    let service = ControlledSnapshotIndexService(
        initialSnapshotID: initial.snapshotID,
        snapshots: ["C": TestSnapshot(label: "C", files: [
            "main.rs": "fn target() { next }\n",
            "lib.py": "def target():\n    return 1\n",
        ])],
        blockedCached: ["C"],
        blockedFull: ["C"]
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
    await model.openProject(root: root).value

    model.navigate(to: root.appendingPathComponent("main.rs"))
    model.selectCompareCommit("C")
    #expect(await testWaitUntil("rust compare completes") {
        model.compare.rightRevision == "C" && model.compare.diff != nil
    })
    #expect(model.compare.functionChanges.contains {
        $0.kind == .bodyChanged
    })

    model.navigate(to: root.appendingPathComponent("lib.py"))
    #expect(model.compare.diff == nil)
    #expect(model.compare.functionChanges.isEmpty)
    #expect(model.compare.rightRevision == "C")
    #expect(await testWaitUntil("python compare completes") {
        model.compare.diff != nil
    })
    await service.releaseFull("C")
}

@MainActor
@Test
func switchingMainSnapshotClearsAndReleasesCompareSnapshot() async throws {
    let root = try snapshotTemporaryProject(["main.rs": "fn current() {}"])
    defer { try? FileManager.default.removeItem(at: root) }
    let initial = try ProjectIndexer().index(root: root)
    let service = ControlledSnapshotIndexService(initialSnapshotID: initial.snapshotID, snapshots: [:])
    let model = AppModel(indexService: service)

    model.openProject(root: root)
    #expect(await testWaitUntil("model.snapshotPhase == .fullReady") { model.snapshotPhase == .fullReady })
    model.navigate(to: root.appendingPathComponent("main.rs"))

    var right: TestSnapshot? = TestSnapshot(
        label: "right",
        files: ["main.rs": "fn previous() {}"]
    )
    weak var retainedRight: TestSnapshot?
    retainedRight = right
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

final class TestSnapshot: Snapshot, @unchecked Sendable {
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

actor ControlledSnapshotIndexService: IndexService {
    private let initialSnapshotID: SnapshotID
    private var worktreeSnapshot: TestSnapshot?
    private let snapshots: [String: TestSnapshot]
    private let externalSnapshots: [String: any Snapshot]
    private let store = ProjectIndexStore()
    private var blockedCached: Set<String>
    private var blockedFull: Set<String>
    private let ignoresCachedCancellation: Set<String>
    private let failedCapture: Set<String>
    private let failedPrepare: Set<String>
    private let failedFull: Set<String>
    private let cachedLanguageOverrides: [String: LanguageID]
    private var labelsBySnapshotID: [SnapshotID: String] = [:]
    private var fullStarted: Set<String> = []
    private var cachedStarted: Set<String> = []
    private var cancelled: Set<String> = []
    private var prepareLanguages: [LanguageID] = []
    private let completedLanguageOverrides: [String: LanguageID]

    /// Without `worktreeSnapshot`, a worktree capture reads the project
    /// directory into a snapshot identified by `initialSnapshotID`.
    init(
        initialSnapshotID: SnapshotID = SnapshotID(rawValue: UUID()),
        worktreeSnapshot: TestSnapshot? = nil,
        snapshots: [String: TestSnapshot],
        externalSnapshots: [String: any Snapshot] = [:],
        blockedCached: Set<String> = [],
        blockedFull: Set<String> = [],
        ignoresCachedCancellation: Set<String> = [],
        failedCapture: Set<String> = [],
        failedPrepare: Set<String> = [],
        failedFull: Set<String> = [],
        cachedLanguageOverrides: [String: LanguageID] = [:],
        completedLanguageOverrides: [String: LanguageID] = [:]
    ) {
        self.initialSnapshotID = initialSnapshotID
        self.worktreeSnapshot = worktreeSnapshot
        self.snapshots = snapshots
        self.externalSnapshots = externalSnapshots
        self.blockedCached = blockedCached
        self.blockedFull = blockedFull
        self.ignoresCachedCancellation = ignoresCachedCancellation
        self.failedCapture = failedCapture
        self.failedPrepare = failedPrepare
        self.failedFull = failedFull
        self.cachedLanguageOverrides = cachedLanguageOverrides
        self.completedLanguageOverrides = completedLanguageOverrides
    }

    func captureSnapshot(root: URL, revision: String?) async throws -> any Snapshot {
        let snapshot: (any Snapshot)? = if let revision {
            externalSnapshots[revision] ?? snapshots[revision]
        } else {
            try worktreeSnapshot ?? directorySnapshot(root: root)
        }
        guard let snapshot else { throw SnapshotTestError.missing(revision ?? "worktree") }
        let label = revision
            ?? (snapshot as? TestSnapshot)?.label
            ?? "snapshot"
        if failedCapture.contains(label) { throw SnapshotTestError.missing(label) }
        labelsBySnapshotID[snapshot.snapshotID] = label
        return snapshot
    }

    private func directorySnapshot(root: URL) throws -> TestSnapshot {
        var files: [String: String] = [:]
        for file in try ProjectTreeWalk.regularFiles(under: root, rules: ProjectPathRules()).files {
            files[ProjectTreeWalk.relativePath(of: file, under: root)] =
                try String(contentsOf: file, encoding: .utf8)
        }
        return TestSnapshot(label: "worktree", snapshotID: initialSnapshotID, files: files)
    }

    private func prepare(
        _ snapshot: any Snapshot,
        language: LanguageID
    ) async throws -> ProjectIndexer.PreparedSnapshot {
        prepareLanguages.append(language)
        let label = try label(for: snapshot.snapshotID)
        if failedPrepare.contains(label) { throw SnapshotTestError.missing(label) }
        cachedStarted.insert(label)
        let cacheBlock = blockedCached.contains(label) ? label : nil
        while let cacheBlock {
            if !ignoresCachedCancellation.contains(label) {
                try Task.checkCancellation()
            }
            await Task.yield()
            if !blockedCached.contains(cacheBlock) { break }
        }
        return try ProjectIndexer().prepareSnapshot(
            snapshot,
            into: store,
            language: cachedLanguageOverrides[label] ?? language
        )
    }

    func prepareSnapshots(
        _ snapshot: any Snapshot,
        root: URL,
        languages: [LanguageID]
    ) async throws -> [ProjectIndexer.PreparedSnapshot] {
        var result: [ProjectIndexer.PreparedSnapshot] = []
        for language in languages {
            result.append(try await prepare(snapshot, language: language))
        }
        return result
    }

    func completeSnapshot(
        _ prepared: ProjectIndexer.PreparedSnapshot
    ) async throws -> EngineSession {
        let label = try label(for: prepared.cachedSession.snapshotID)
        let language = prepared.cachedSession.analysisProfile.language
        let key = "\(label)-\(language.rawValue)"
        fullStarted.insert(key)
        if failedFull.contains(label) { throw SnapshotTestError.missing(label) }
        do {
            while blockedFull.contains(label) || blockedFull.contains(key) {
                try Task.checkCancellation()
                await Task.yield()
            }
            let session = try ProjectIndexer().completeSnapshot(prepared)
            guard let completedLanguageOverride = completedLanguageOverrides[label] else { return session }
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
    func hasStartedFull(_ label: String) -> Bool {
        fullStarted.contains { started in
            started == label || started.hasPrefix(label + "-")
        }
    }
    func hasStartedFull(label: String, language: LanguageID) -> Bool {
        fullStarted.contains("\(label)-\(language.rawValue)")
    }
    func hasStartedCached(_ label: String) -> Bool { cachedStarted.contains(label) }
    func wasCancelled(_ label: String) -> Bool { cancelled.contains(label) }
    func snapshotID(for label: String) -> SnapshotID? { snapshots[label]?.snapshotID }
    /// Languages of every prepared session, in request order.
    func preparedLanguages() -> [LanguageID] { prepareLanguages }

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

// MARK: - S2c Refresh Index

@MainActor
@Test
func refreshIndexRepublishesDriftedWorktreeAndClearsStaleState() async throws {
    let fixture = try SnapshotGitFixture()
    defer { fixture.remove() }
    let file = fixture.root.appendingPathComponent("main.rs")
    let original = "pub fn target() -> i32 { 42 }\n"
    try snapshotWrite(original, to: file)
    try fixture.git("add", "main.rs")
    try fixture.commit("initial")
    let model = AppModel(indexService: ProjectIndexService())
    model.openProject(root: fixture.root)
    #expect(await testWaitUntil("fullReady after open") {
        model.snapshotPhase == .fullReady
    })
    model.navigate(to: file)
    let tabsAfterOpen = model.tabStrip.tabs.count

    // External drift (review repro): prefix comment lines plus a rename.
    let drifted = String(repeating: "// drift\n", count: 8)
        + "pub fn renamed() -> i32 { 42 }\n"
    try snapshotWrite(drifted, to: file)
    let oldIdentity = ContentID.sha256(of: Array(original.utf8))
    model.navigate(NavigationRequest(
        destination: SourceDestination(
            file: file,
            byteOffset: 4,
            expectedContentID: oldIdentity
        ),
        cause: .search,
        policy: .explicitSemantic
    ))
    #expect(await testWaitUntil("stale notice set") {
        model.staleIndexNotice != nil
    })

    model.refreshIndex(leaving: nil)
    #expect(await testWaitUntil("refresh installed") {
        model.snapshotPhase == .fullReady && !model.isRefreshingIndex
    })
    #expect(model.indexRefreshNotice == nil)
    guard case let .ready(session, context) = model.projectState else {
        Issue.record("expected refreshed session")
        return
    }
    let renamedHits = try await session.searchSymbols(
        query: "renamed",
        limit: 10,
        boost: SearchBoost(),
        context: context
    )
    #expect(!renamedHits.isEmpty, "#renamed must be indexed after refresh")
    let targetHits = try await session.searchSymbols(
        query: "target",
        limit: 10,
        boost: SearchBoost(),
        context: context
    )
    #expect(targetHits.isEmpty, "#target must no longer be indexed")
    let refreshedIdentity = session.manifest.files.first {
        session.paths.resolve($0.pathID) == "main.rs"
    }?.contentID
    #expect(refreshedIdentity == ContentID.sha256(of: Array(drifted.utf8)))

    #expect(model.staleIndexNotice == nil)
    #expect(model.tabStrip.tabs.count == tabsAfterOpen)

    // Navigation carrying the refreshed identity is accepted again.
    let renamedOffset = UInt32(
        drifted[..<drifted.range(of: "renamed")!.lowerBound].utf8.count
    )
    model.navigate(NavigationRequest(
        destination: SourceDestination(
            file: file,
            byteOffset: renamedOffset,
            expectedContentID: ContentID.sha256(of: Array(drifted.utf8))
        ),
        cause: .search,
        policy: .explicitSemantic
    ))
    #expect(await testWaitUntil("refreshed offset applied") {
        model.selectedByteOffset == renamedOffset
    })
}

@MainActor
@Test
func refreshIndexPreservesTabsTrailHistoryAndBookmarks() async throws {
    let fixture = try SnapshotGitFixture()
    defer { fixture.remove() }
    let file = fixture.root.appendingPathComponent("main.rs")
    let other = fixture.root.appendingPathComponent("other.rs")
    let source = "pub fn target() -> i32 { 42 }\n"
    try snapshotWrite(source, to: file)
    try snapshotWrite("pub fn other() {}\n", to: other)
    try fixture.git("add", "main.rs", "other.rs")
    try fixture.commit("initial")
    let model = AppModel(indexService: ProjectIndexService())
    model.openProject(root: fixture.root)
    #expect(await testWaitUntil("fullReady after open") {
        model.snapshotPhase == .fullReady
    })
    model.navigate(to: file)
    let identity = ContentID.sha256(of: Array(source.utf8))
    model.navigate(
        NavigationRequest(
            destination: SourceDestination(
                file: file,
                byteOffset: 4,
                expectedContentID: identity
            ),
            cause: .search,
            policy: .explicitSemantic
        ),
        leaving: snapshotJumpRecord(
            "main.rs",
            offset: 4,
            snapshotID: try #require(model.currentSnapshotID)
        )
    )
    #expect(await testWaitUntil("trail recorded") {
        model.readingTrail.edges.count == 1
    })
    model.openInNewTab(other)
    let bookmark = BookmarkRecord(
        id: UUID(),
        projectPath: fixture.root.standardizedFileURL.path,
        snapshot: .worktree,
        path: "main.rs",
        contentID: identity,
        byteOffset: 4,
        line: 1,
        symbolName: nil,
        symbolKind: nil,
        note: "",
        updatedAt: .now
    )
    #expect(model.bookmarkModel.toggle(bookmark) == .added)
    let tabsBefore = model.tabStrip.tabs.count
    let historyBefore = model.navigationHistory.records.count

    try snapshotWrite("// drift\npub fn renamed() -> i32 { 42 }\n", to: file)
    model.refreshIndex(leaving: nil)
    #expect(await testWaitUntil("refresh installed") {
        model.snapshotPhase == .fullReady && !model.isRefreshingIndex
    })

    #expect(model.tabStrip.tabs.count == tabsBefore)
    #expect(model.readingTrail.edges.count == 1)
    #expect(model.navigationHistory.records.count == historyBefore)
    #expect(model.bookmarkModel.records.count == 1)
    #expect(
        model.tabStrip.tabs.contains {
            $0.fileURL?.standardizedFileURL == other.standardizedFileURL
        }
    )
}

@MainActor
@Test
func refreshIndexFailureRestoresThePreviousIndexAndAllowsRetry() async throws {
    let fixture = try SnapshotGitFixture()
    defer { fixture.remove() }
    let mixedFiles = [
        "main.rs": "fn main() {}\n",
        "lib.py": "def f():\n    pass\n",
        "a.ts": "export function a() {}\n",
    ]
    for (path, contents) in mixedFiles {
        try snapshotWrite(contents, to: fixture.root.appendingPathComponent(path))
    }
    try fixture.git("add", "main.rs", "lib.py", "a.ts")
    try fixture.commit("initial")
    let service = ControlledSnapshotIndexService(
        worktreeSnapshot: TestSnapshot(label: "open", files: mixedFiles),
        snapshots: [:],
        failedCapture: ["refresh"]
    )
    let model = AppModel(indexService: service)
    await model.openProject(root: fixture.root).value
    #expect(await testWaitUntil("fullReady after open") {
        model.snapshotPhase == .fullReady
    })
    #expect(model.querySessions.count == 3)

    await service.setWorktreeSnapshot(TestSnapshot(
        label: "refresh",
        files: mixedFiles
    ))
    model.refreshIndex(leaving: nil)
    #expect(await testWaitUntil("refresh failed and restored") {
        model.indexRefreshNotice != nil && !model.isRefreshingIndex
    })
    #expect(model.snapshotPhase == .fullReady)
    #expect(model.querySessions.count == 3)
    guard case .ready = model.projectState else {
        Issue.record("expected the previous index restored as ready")
        return
    }

    // Retry with a capturable snapshot succeeds and clears the notice.
    await service.setWorktreeSnapshot(TestSnapshot(
        label: "retry",
        files: mixedFiles
    ))
    model.refreshIndex(leaving: nil)
    #expect(await testWaitUntil("retry refresh installed") {
        model.snapshotPhase == .fullReady
            && !model.isRefreshingIndex
            && model.indexRefreshNotice == nil
    })
}

@MainActor
@Test
func refreshRedetectsLanguagesAndAFailedRefreshKeepsThePreviousSet() async throws {
    let fixture = try SnapshotGitFixture()
    defer { fixture.remove() }
    let service = ControlledSnapshotIndexService(
        worktreeSnapshot: TestSnapshot(label: "open", files: ["main.rs": "fn main() {}\n"]),
        snapshots: [:],
        failedPrepare: ["broken"]
    )
    let model = AppModel(indexService: service)
    await model.openProject(root: fixture.root).value
    #expect(model.projectLanguages == [.rust])

    // A Python file appears; a refresh that fails after capture restores
    // the previous set together with the previous sessions.
    let withPython = ["main.rs": "fn main() {}\n", "tool.py": "def tool():\n    pass\n"]
    await service.setWorktreeSnapshot(TestSnapshot(label: "broken", files: withPython))
    model.refreshIndex(leaving: nil)
    #expect(await testWaitUntil("failed refresh restored") {
        model.indexRefreshNotice != nil && !model.isRefreshingIndex
    })
    #expect(model.projectLanguages == [.rust])
    #expect(model.querySessions.map { $0.0.analysisProfile.language } == [.rust])

    await service.setWorktreeSnapshot(TestSnapshot(label: "refreshed", files: withPython))
    model.refreshIndex(leaving: nil)
    #expect(await testWaitUntil("refresh installed") {
        model.snapshotPhase == .fullReady && !model.isRefreshingIndex
            && model.indexRefreshNotice == nil
    })
    #expect(model.projectLanguages == [.rust, .python])
    #expect(model.querySessions.map { $0.0.analysisProfile.language } == [.rust, .python])
}

@MainActor
@Test
func openingAFolderWithoutSupportedSourcesFailsWithItsReason() async throws {
    let root = try snapshotTemporaryProject([
        "README.md": "# notes\n",
        "app.js": "const app = 1\n",
        "types.d.ts": "export declare const x: number\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(indexService: ProjectIndexService())

    await model.openProject(root: root).value

    guard case .failed = model.projectState else {
        Issue.record("expected the open to fail")
        return
    }
    #expect(model.projectLanguages.isEmpty)
    #expect(model.projectFailureReason
        == "No supported source files found (Rust, Python, TypeScript)")
}

@MainActor
@Test
func refreshInProgressSuppressesSessionCheckpoints() async throws {
    let fixture = try SnapshotGitFixture()
    defer { fixture.remove() }
    let mixedFiles = [
        "main.rs": "fn main() {}\n",
        "lib.py": "def f():\n    pass\n",
        "a.ts": "export function a() {}\n",
    ]
    for (path, contents) in mixedFiles {
        try snapshotWrite(contents, to: fixture.root.appendingPathComponent(path))
    }
    try fixture.git("add", "main.rs", "lib.py", "a.ts")
    try fixture.commit("initial")
    let sessionURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodeInsightRefreshCheckpoint-\(UUID().uuidString).json")
    let perProjectURL = sessionURL.deletingLastPathComponent()
        .appendingPathComponent("sessions")
        .appendingPathComponent(
            AppModel.sessionProjectKey(for: fixture.root) + ".json"
        )
    defer {
        try? FileManager.default.removeItem(at: sessionURL)
        try? FileManager.default.removeItem(
            at: perProjectURL.deletingLastPathComponent()
        )
    }
    let service = ControlledSnapshotIndexService(
        worktreeSnapshot: TestSnapshot(label: "open", files: mixedFiles),
        snapshots: [:],
        blockedFull: ["refresh"]
    )
    let model = AppModel(
        sessionURL: sessionURL,
        indexService: service
    )
    await model.openProject(root: fixture.root).value
    #expect(await testWaitUntil("fullReady after open") {
        model.snapshotPhase == .fullReady
    })

    await service.setWorktreeSnapshot(TestSnapshot(
        label: "refresh",
        files: mixedFiles
    ))
    model.refreshIndex(leaving: nil)
    #expect(await testWaitUntil("refresh mid-flight at cached phase") {
        model.snapshotPhase == .cachedReady || model.snapshotPhase == .firstPaint
    })
    model.scheduleSessionCheckpoint(panelPreset: .reading)
    try await Task.sleep(for: .milliseconds(400))
    #expect(
        !FileManager.default.fileExists(atPath: perProjectURL.path),
        "a half-installed refresh must not be checkpointed"
    )
    await service.releaseFull("refresh")
    #expect(await testWaitUntil("refresh completed") {
        model.snapshotPhase == .fullReady && !model.isRefreshingIndex
    })
    model.scheduleSessionCheckpoint(panelPreset: .reading)
    #expect(await testWaitUntil("checkpoint after completion") {
        FileManager.default.fileExists(atPath: perProjectURL.path)
    })
}

@MainActor
@Test
func refreshIndexWorksForPlainNonGitDirectories() async throws {
    let root = try snapshotTemporaryProject(["main.rs": "fn target() {}\n"])
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(indexService: ProjectIndexService())
    model.openProject(root: root)
    #expect(await testWaitUntil("fullReady after open") {
        model.snapshotPhase == .fullReady
    })
    let file = root.appendingPathComponent("main.rs")
    try snapshotWrite("fn renamed() {}\n", to: file)

    model.refreshIndex(leaving: nil)
    #expect(await testWaitUntil("non-git refresh installed") {
        model.snapshotPhase == .fullReady && !model.isRefreshingIndex
    })
    guard case let .ready(session, context) = model.projectState else {
        Issue.record("expected refreshed session")
        return
    }
    let hits = try await session.searchSymbols(
        query: "renamed",
        limit: 10,
        boost: SearchBoost(),
        context: context
    )
    #expect(!hits.isEmpty)
}

@MainActor
@Test
func refreshYieldsToAProjectSwitchMidFlight() async throws {
    let first = try SnapshotGitFixture()
    let second = try SnapshotGitFixture()
    defer {
        first.remove()
        second.remove()
    }
    let mixedFiles = [
        "main.rs": "fn main() {}\n",
        "lib.py": "def f():\n    pass\n",
        "a.ts": "export function a() {}\n",
    ]
    for (path, contents) in mixedFiles {
        try snapshotWrite(contents, to: first.root.appendingPathComponent(path))
    }
    try first.git("add", "main.rs", "lib.py", "a.ts")
    try first.commit("initial")
    try snapshotWrite("fn solo() {}\n", to: second.root.appendingPathComponent("solo.rs"))
    try second.git("add", "solo.rs")
    try second.commit("initial")
    let service = ControlledSnapshotIndexService(
        worktreeSnapshot: TestSnapshot(label: "open", files: mixedFiles),
        snapshots: [:],
        blockedFull: ["refresh"]
    )
    let model = AppModel(indexService: service)
    await model.openProject(root: first.root).value
    #expect(await testWaitUntil("fullReady after open") {
        model.snapshotPhase == .fullReady
    })
    await service.setWorktreeSnapshot(TestSnapshot(
        label: "refresh",
        files: mixedFiles
    ))
    model.refreshIndex(leaving: nil)
    #expect(await testWaitUntil("refresh mid-flight") {
        model.snapshotPhase == .firstPaint
            || model.snapshotPhase == .cachedReady
    })

    // Opening another project mid-refresh must take over; the in-flight
    // refresh may not publish anything into the new workspace afterwards.
    await service.setWorktreeSnapshot(TestSnapshot(
        label: "second",
        files: ["solo.rs": "fn solo() {}\n"]
    ))
    let secondModelTask = Task { @MainActor in
        await model.openProject(root: second.root).value
    }
    await service.releaseFull("refresh")
    _ = await secondModelTask.value
    #expect(await testWaitUntil("second project ready") {
        model.snapshotPhase == .fullReady
            && model.projectRoot?.standardizedFileURL
                == second.root.standardizedFileURL
    })
    #expect(model.fileTree?.children.map(\.name) == ["solo.rs"])
    #expect(!model.isRefreshingIndex)
}

// MARK: - S3a open-flow convergence

@MainActor
@Test
func openingASecondProjectCancelsTheInFlightMultiLanguageOpen() async throws {
    let first = try SnapshotGitFixture()
    let second = try SnapshotGitFixture()
    defer {
        first.remove()
        second.remove()
    }
    let firstFiles = [
        "main.rs": "fn main() {}\n",
        "lib.py": "def f():\n    pass\n",
        "a.ts": "export function a() {}\n",
    ]
    let secondFiles = [
        "main.rs": "fn second_main() {}\n",
        "lib.py": "def g():\n    pass\n",
        "a.ts": "export function b() {}\n",
    ]
    for (path, contents) in firstFiles {
        try snapshotWrite(contents, to: first.root.appendingPathComponent(path))
    }
    try first.git("add", "main.rs", "lib.py", "a.ts")
    try first.commit("initial")
    for (path, contents) in secondFiles {
        try snapshotWrite(contents, to: second.root.appendingPathComponent(path))
    }
    try second.git("add", "main.rs", "lib.py", "a.ts")
    try second.commit("initial")
    let service = ControlledSnapshotIndexService(
        worktreeSnapshot: TestSnapshot(label: "first", files: firstFiles),
        snapshots: [:],
        blockedFull: ["first"]
    )
    let model = AppModel(indexService: service)
    let firstOpen = Task { @MainActor in
        await model.openProject(root: first.root).value
    }
    #expect(await testWaitUntil("first open blocked at full") {
        await service.hasStartedFull("first")
    })

    await service.setWorktreeSnapshot(TestSnapshot(
        label: "second",
        files: secondFiles
    ))
    let secondOpen = Task { @MainActor in
        await model.openProject(root: second.root).value
    }
    _ = await secondOpen.value
    #expect(await testWaitUntil("second project published") {
        model.snapshotPhase == .fullReady
            && model.projectRoot?.standardizedFileURL
                == second.root.standardizedFileURL
    })
    #expect(
        await testWaitUntil("first open cancelled") {
            await service.wasCancelled("first")
        },
        "opening a new project must cancel the in-flight open, not just abandon it"
    )
    #expect(model.fileTree?.children.map(\.name).contains("main.rs") == true)
}

@MainActor
@Test
func singleLanguageOpenSharesTheWorkspaceResetBoundaries() async throws {
    let root = try snapshotTemporaryProject([
        "main.rs": "fn main() {}\n",
        "other.rs": "fn other() {}\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel()
    model.navigate(to: root.appendingPathComponent("main.rs"))
    model.navigationHistory.push(NavigationRecord(
        jump: snapshotJumpRecord(
            "main.rs",
            offset: 0,
            snapshotID: SnapshotID(rawValue: UUID())
        )
    ))
    _ = model.readingTrail.recordNavigation(
        from: nil,
        to: snapshotJumpRecord(
            "main.rs",
            offset: 0,
            snapshotID: SnapshotID(rawValue: UUID())
        )
    )
    #expect(!model.tabStrip.tabs.isEmpty || model.selectedFile != nil)

    model.openProject(root: root)
    #expect(await testWaitUntil("fullReady after open") {
        model.snapshotPhase == .fullReady
    })

    #expect(model.selectedFile == nil)
    #expect(model.selectedByteOffset == nil)
    #expect(model.tabStrip.tabs.isEmpty)
    #expect(model.navigationHistory.records.isEmpty)
    #expect(model.readingTrail.edges.isEmpty)
    #expect(model.replayNotice == nil)
    #expect(model.staleIndexNotice == nil)
    #expect(model.isRefreshingIndex == false)
    #expect(model.compare.rightRevision == nil)
    #expect(!model.hasPendingReplay)
}

@MainActor
@Test
func restoredHistoryLoadsFileOnlyPresentInCommit() async throws {
    let fixture = try SnapshotGitFixture()
    defer { fixture.remove() }
    let target = fixture.root.appendingPathComponent("old.rs")
    let current = fixture.root.appendingPathComponent("main.rs")
    try snapshotWrite("fn old() {}\n", to: target)
    try snapshotWrite("fn main() {}\n", to: current)
    try fixture.git("add", ".")
    try fixture.commit("saved")
    let revision = try fixture.git("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
    try FileManager.default.removeItem(at: target)
    let model = AppModel()
    model.openProject(root: fixture.root)
    try #require(await testWaitUntil("ready") { model.snapshotPhase == .fullReady })
    model.navigate(to: current)
    let saved = JumpRecord(path: "old.rs", contentID: nil, byteOffset: 3, line: 1, column: 4, symbolAnchor: nil, snapshotID: nil, revision: revision)
    model.navigationHistory.push(saved)
    model.goBack(from: snapshotJumpRecord("main.rs", offset: 0, snapshotID: try #require(model.currentSnapshotID)))
    for _ in 0..<200 {
        if model.selectedFile == target && model.currentRevision == revision { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(model.selectedFile == target && model.currentRevision == revision)
    #expect(model.navigationHistory.cursor == 0)
    model.goForward()
    try #require(await testWaitUntil("forward returns to worktree") { model.selectedFile == current && model.currentRevision == nil })
    #expect(model.navigationHistory.cursor == 1)
}

@MainActor
@Test(arguments: [false, true])
func historyReadFailureKeepsCursorVersionAndViewport(crossVersion: Bool) async throws {
    let fixture = try SnapshotGitFixture()
    defer { fixture.remove() }
    let target = fixture.root.appendingPathComponent("old.rs")
    let current = fixture.root.appendingPathComponent("main.rs")
    try snapshotWrite("fn main() {}\n", to: current)
    try fixture.git("add", ".")
    try fixture.commit("without target")
    let revision = try fixture.git("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
    try snapshotWrite("fn old() {}\n", to: target)
    let model = AppModel()
    model.openProject(root: fixture.root)
    try #require(await testWaitUntil("ready") { model.snapshotPhase == .fullReady })
    model.navigate(to: current, byteOffset: 3)
    let saved = JumpRecord(path: "old.rs", contentID: nil, byteOffset: 0, line: 1, column: 1, symbolAnchor: nil, snapshotID: nil, revision: crossVersion ? revision : nil)
    model.navigationHistory.push(saved)
    let history = model.navigationHistory.exportState()
    let active = model.readingTrail.activeNodeID
    let snapshot = model.currentSnapshotID
    if !crossVersion {
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    }
    model.goBack(from: snapshotJumpRecord("main.rs", offset: 3, snapshotID: try #require(snapshot)))
    for _ in 0..<200 {
        if model.replayNotice?.contains("unavailable") == true { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.replayNotice?.contains("unavailable") == true)
    #expect(model.navigationHistory.cursor == history.cursor)
    #expect(model.navigationHistory.exportState().forwardRecord == history.forwardRecord)
    #expect(model.currentSnapshotID == snapshot)
    #expect(model.currentRevision == nil)
    #expect(model.selectedFile == current)
    #expect(model.selectedByteOffset == 3)
    #expect(model.readingTrail.activeNodeID == active)
}

// MARK: - P5 project exclusion rules

@MainActor
@Test
func exclusionRulesRefreshIndexKeepTabsAndPersistOutsideTheRepository() async throws {
    let fixture = try SnapshotGitFixture()
    defer { fixture.remove() }
    let state = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodeInsightRules-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: state) }
    let main = fixture.root.appendingPathComponent("main.rs")
    try snapshotWrite("pub fn kept() -> i32 { 1 }\n", to: main)
    try snapshotWrite("pub fn vendored() -> i32 { 2 }\n", to: fixture.root.appendingPathComponent("vendor/dep.rs"))
    try snapshotWrite("pub fn built() -> i32 { 3 }\n", to: fixture.root.appendingPathComponent("build/gen.rs"))
    try fixture.git("add", "-A")
    try fixture.commit("initial")
    let sessionURL = state.appendingPathComponent("session.json")

    let model = AppModel(sessionURL: sessionURL, indexService: ProjectIndexService())
    model.openProject(root: fixture.root)
    #expect(await testWaitUntil("ready") { model.snapshotPhase == .fullReady })
    model.navigate(to: main)
    let tabs = model.tabStrip.tabs.count
    #expect(model.fileTree?.ruleExcludedPaths == [])

    try model.updatePathRules(lines: ["vendor/", "!build/"], leaving: nil)
    #expect(await testWaitUntil("refreshed") { model.snapshotPhase == .fullReady && !model.isRefreshingIndex })
    #expect(model.fileTree?.ruleExcludedPaths == ["vendor"])
    guard case let .ready(session, _) = model.projectState else {
        Issue.record("expected a ready session")
        return
    }
    let indexed = Set(session.manifest.files.compactMap { session.paths.resolve($0.pathID) })
    #expect(indexed.contains("main.rs") && indexed.contains("build/gen.rs"))
    #expect(!indexed.contains("vendor/dep.rs"))
    #expect(model.tabStrip.tabs.count == tabs, "a rules refresh keeps the reading session")

    // The rules live in application data, keyed by project, never in the repository.
    #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(".cairnignore").path))
    let reopened = AppModel(sessionURL: sessionURL, indexService: ProjectIndexService())
    reopened.openProject(root: fixture.root)
    #expect(reopened.pathRules.lines == ["vendor/", "!build/"])
    #expect(await testWaitUntil("reopened ready") { reopened.snapshotPhase == .fullReady })
    #expect(reopened.fileTree?.ruleExcludedPaths == ["vendor"])
}
