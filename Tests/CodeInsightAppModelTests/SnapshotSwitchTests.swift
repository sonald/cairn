import CodeInsightCore
import CodeInsightEngine
import CodeInsightGit
import CodeInsightReaderCore
import Foundation
import Testing
@testable import CodeInsightAppModel

@MainActor
@Test
func snapshotSwitchPublishesFirstPaintCachedAndFullInOrder() async throws {
    let root = try snapshotTemporaryProject(["main.rs": "fn initial() {}"])
    defer { try? FileManager.default.removeItem(at: root) }
    let initial = try ProjectIndexer().index(root: root)
    let service = ControlledSnapshotIndexService(
        initialSession: initial,
        snapshots: ["C": TestSnapshot(label: "C", files: ["src/c.rs": "fn c() {}"])],
        blockedCached: ["C"],
        blockedFull: ["C"]
    )
    let model = AppModel(indexService: service)

    model.openProject(root: root)
    #expect(await snapshotWaitUntil { model.snapshotPhase == .fullReady })
    model.switchToCommit("C")

    #expect(await snapshotWaitUntil { model.snapshotPhase == .firstPaint })
    #expect(model.fileTree?.children.first?.name == "src")
    #expect(model.coverage.filesIndexed == 0)
    #expect(model.coverage.filesTotal == 1)

    await service.releaseCached("C")
    #expect(await snapshotWaitUntil { model.snapshotPhase == .cachedReady })
    guard case let .ready(_, cachedContext) = model.projectState else {
        Issue.record("expected cached session")
        return
    }
    #expect(cachedContext.generation == model.generation)

    await service.releaseFull("C")
    #expect(await snapshotWaitUntil { model.snapshotPhase == .fullReady })
    #expect(model.coverage.filesIndexed == 1)
    #expect(model.coverage.importsResolved == nil)
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
    #expect(await snapshotWaitUntil { model.snapshotPhase == .fullReady })
    model.switchToCommit("C")
    #expect(await snapshotWaitUntil { model.snapshotPhase == .cachedReady })

    let cSnapshotID = model.currentSnapshotID
    model.switchToCommit("D")
    #expect(model.currentSnapshotID == cSnapshotID)
    #expect(model.documentSource != nil)
    #expect(await snapshotWaitUntil {
        model.snapshotPhase == .fullReady && model.currentRevision == "D"
    })
    #expect(await service.wasCancelled("C"))
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
    #expect(await snapshotWaitUntil { model.snapshotPhase == .fullReady })
    contextWindow.tokenClicked(file: "main.rs", offset: offset)
    #expect(await snapshotWaitUntil { resolver.isPending })

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
    #expect(await snapshotWaitUntil { model.snapshotPhase == .fullReady })
    model.navigate(to: file)
    let worktreeSnapshotID = model.currentSnapshotID
    let worktree = try DocumentLoader().load(file: file).document
    #expect(String(bytes: worktree.bytes, encoding: .utf8)?.contains("Y") == true)

    model.switchToCommit("HEAD")
    #expect(await snapshotWaitUntil {
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
    #expect(await snapshotWaitUntil {
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
    #expect(await snapshotWaitUntil { model.snapshotPhase == .fullReady })
    model.switchToCommit("HEAD~1")
    #expect(await snapshotWaitUntil { model.snapshotPhase == .fullReady })
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
    #expect(await snapshotWaitUntil { model.snapshotPhase == .fullReady })
    model.navigate(to: a, byteOffset: 8)
    #expect(model.currentSnapshotID == worktree.snapshotID)
    #expect(model.selectedFile == a)

    model.switchToCommit("C", leaving: worktreeA)
    #expect(model.navigationHistory.records.last?.snapshotID == worktree.snapshotID)
    #expect(await snapshotWaitUntil { model.snapshotPhase == .fullReady })
    #expect(model.currentSnapshotID == commit.snapshotID)
    #expect(model.selectedFile == a)

    model.navigate(to: b, byteOffset: 9, leaving: commitA)
    #expect(model.currentSnapshotID == commit.snapshotID)
    #expect(model.selectedFile == b)
    #expect(model.navigationHistory.records == [worktreeA, commitA])

    model.goBack(from: commitB)
    #expect(model.currentSnapshotID == commit.snapshotID)
    #expect(model.selectedFile == a)
    #expect(model.selectedByteOffset == 8)
    #expect(model.navigationHistory.records.count == 2)

    model.goBack(from: commitA)
    #expect(await snapshotWaitUntil {
        model.currentSnapshotID == worktree.snapshotID
            && model.selectedFile == a
            && model.selectedByteOffset == 8
    })
    #expect(model.navigationHistory.records.count == 2)

    model.goForward()
    #expect(await snapshotWaitUntil {
        model.currentSnapshotID == commit.snapshotID
            && model.selectedFile == a
            && model.selectedByteOffset == 8
    })
    #expect(model.navigationHistory.records.count == 2)

    model.goForward()
    #expect(model.currentSnapshotID == commit.snapshotID)
    #expect(model.selectedFile == b)
    #expect(model.selectedByteOffset == 9)
    #expect(model.navigationHistory.records.count == 2)
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
    #expect(await snapshotWaitUntil { model.snapshotPhase == .fullReady })
    model.switchToCommit("C", leaving: snapshotJumpRecord(
        "a.rs",
        offset: 0,
        snapshotID: initial.snapshotID
    ))

    #expect(model.navigationHistory.records.isEmpty)
    #expect(await snapshotWaitUntil { model.snapshotPhase == .fullReady })
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
    #expect(await snapshotWaitUntil { model.snapshotPhase == .fullReady })
    model.navigate(to: a)
    model.switchToCommit("C", leaving: snapshotJumpRecord(
        "a.rs",
        offset: 0,
        snapshotID: initial.snapshotID
    ))

    #expect(await snapshotWaitUntil { model.snapshotPhase == .fullReady })
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
    #expect(await snapshotWaitUntil { model.snapshotPhase == .fullReady })
    model.navigationHistory.push(snapshotJumpRecord(
        "a.rs",
        offset: 100,
        line: 2,
        column: 1,
        snapshotID: worktree.snapshotID
    ))
    model.switchToCommit("C")
    #expect(await snapshotWaitUntil { model.snapshotPhase == .fullReady })

    model.goBack(from: snapshotJumpRecord(
        "b.rs",
        offset: 0,
        snapshotID: commit.snapshotID
    ))

    #expect(await snapshotWaitUntil {
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
    #expect(await snapshotWaitUntil { model.snapshotPhase == .fullReady })
    model.navigationHistory.push(snapshotJumpRecord(
        "a.rs",
        offset: 100,
        line: 99,
        column: 99,
        symbolAnchor: "moved_target",
        snapshotID: worktree.snapshotID
    ))
    model.switchToCommit("C")
    #expect(await snapshotWaitUntil { model.snapshotPhase == .fullReady })

    model.goBack(from: snapshotJumpRecord(
        "b.rs",
        offset: 0,
        snapshotID: commit.snapshotID
    ))

    #expect(await snapshotWaitUntil {
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
    #expect(await snapshotWaitUntil { model.snapshotPhase == .fullReady })
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
    #expect(model.selectedFile == a)
    #expect(model.selectedByteOffset == 3)
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
    private let worktreeSnapshot: TestSnapshot?
    private let snapshots: [String: TestSnapshot]
    private let store = ProjectIndexStore()
    private var blockedCached: Set<String>
    private var blockedFull: Set<String>
    private var labelsBySnapshotID: [SnapshotID: String] = [:]
    private var cancelled: Set<String> = []

    init(
        initialSession: EngineSession,
        worktreeSnapshot: TestSnapshot? = nil,
        snapshots: [String: TestSnapshot],
        blockedCached: Set<String> = [],
        blockedFull: Set<String> = []
    ) {
        self.initialSession = initialSession
        self.worktreeSnapshot = worktreeSnapshot
        self.snapshots = snapshots
        self.blockedCached = blockedCached
        self.blockedFull = blockedFull
    }

    func index(root: URL) async throws -> EngineSession { initialSession }

    func captureSnapshot(root: URL, revision: String?) async throws -> any Snapshot {
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
        _ snapshot: any Snapshot
    ) async throws -> ProjectIndexer.PreparedSnapshot {
        let label = try label(for: snapshot.snapshotID)
        while blockedCached.contains(label) {
            try Task.checkCancellation()
            await Task.yield()
        }
        return try ProjectIndexer().prepareSnapshot(snapshot, into: store)
    }

    func completeSnapshot(
        _ prepared: ProjectIndexer.PreparedSnapshot
    ) async throws -> EngineSession {
        let label = try label(for: prepared.cachedSession.snapshotID)
        do {
            while blockedFull.contains(label) {
                try Task.checkCancellation()
                await Task.yield()
            }
            return try ProjectIndexer().completeSnapshot(prepared)
        } catch is CancellationError {
            cancelled.insert(label)
            throw CancellationError()
        }
    }

    func releaseCached(_ label: String) { blockedCached.remove(label) }
    func releaseFull(_ label: String) { blockedFull.remove(label) }
    func wasCancelled(_ label: String) -> Bool { cancelled.contains(label) }
    func snapshotID(for label: String) -> SnapshotID? { snapshots[label]?.snapshotID }

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

@MainActor
private func snapshotWaitUntil(
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
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
