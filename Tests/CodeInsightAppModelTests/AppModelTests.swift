import CodeInsightEngine
import Foundation
import Testing
@testable import CodeInsightAppModel

private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

@MainActor
@Test
func projectStateAcceptsLegalTransitions() {
    let model = AppModel()
    let root = URL(fileURLWithPath: "/tmp/project", isDirectory: true)

    #expect(model.transition(to: .indexing(root: root, startedAt: .now)))
    #expect(model.transition(to: .failed))
    #expect(model.transition(to: .indexing(root: root, startedAt: .now)))
}

@MainActor
@Test
func projectStateRejectsIllegalTransitions() {
    let model = AppModel()
    let root = URL(fileURLWithPath: "/tmp/project", isDirectory: true)

    #expect(!model.transition(to: .failed))
    #expect(model.transition(to: .indexing(root: root, startedAt: .now)))
    #expect(!model.transition(to: .indexing(root: root, startedAt: .now)))
}

@Test
func fileTreeSortsSkipsAndKeepsOnlyRustBranches() throws {
    let root = try temporaryProject([
        "z.rs": "",
        "a.rs": "",
        "README.md": "ignored",
        "src/z.rs": "",
        "src/a.rs": "",
        "empty/note.txt": "ignored",
        "upper.RS": "ignored",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    for skipped in ProjectIndexer.skippedDirectories {
        try write("", to: root.appendingPathComponent(skipped).appendingPathComponent("skip.rs"))
    }

    let tree = try FileTreeModel(root: root)

    #expect(tree.children.map(\.name) == ["src", "a.rs", "z.rs"])
    #expect(tree.children[0].children.map(\.name) == ["a.rs", "z.rs"])
    #expect(tree.fileCount == 4)
}

@MainActor
@Test
func openingAnotherProjectDiscardsLateSession() async throws {
    let rootA = try temporaryProject(["a.rs": "fn a() {}"])
    let rootB = try temporaryProject(["b.rs": "fn b() {}"])
    defer {
        try? FileManager.default.removeItem(at: rootA)
        try? FileManager.default.removeItem(at: rootB)
    }
    let sessionA = try ProjectIndexer().index(root: rootA)
    let sessionB = try ProjectIndexer().index(root: rootB)
    let service = ControlledIndexService()
    let model = AppModel(indexService: service)

    model.openProject(root: rootA)
    model.openProject(root: rootB)

    #expect(model.generation == 2)
    #expect(model.fileTree?.root == rootB.standardizedFileURL)
    guard case let .indexing(root, _) = model.projectState else {
        Issue.record("expected indexing")
        return
    }
    #expect(root == rootB.standardizedFileURL)

    await service.complete(root: rootB, result: .success(sessionB))
    #expect(await waitUntil {
        if case .ready = model.projectState { return true }
        return false
    })

    await service.complete(root: rootA, result: .success(sessionA))
    #expect(await service.waitUntilDelivered(root: rootA))
    for _ in 0..<10 { await Task.yield() }

    guard case let .ready(session, context) = model.projectState else {
        Issue.record("expected ready")
        return
    }
    #expect(session.snapshotID == sessionB.snapshotID)
    #expect(context.snapshotID == sessionB.snapshotID)
    #expect(context.analysisProfileID == sessionB.analysisProfile.id)
    #expect(context.generation == 2)
}

@MainActor
@Test
func indexingFailureMovesProjectToFailed() async throws {
    let root = try temporaryProject(["main.rs": "fn main() {}"])
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(indexService: FailingIndexService())

    model.openProject(root: root)
    guard case .indexing = model.projectState else {
        Issue.record("expected indexing")
        return
    }
    #expect(await waitUntil {
        if case .failed = model.projectState { return true }
        return false
    })
}

@Test
func realIndexServiceBuildsFixtureSession() async throws {
    let fixture = repositoryRoot
        .appendingPathComponent("Tests/RustExtractorTests/Fixtures/use_alias")

    let session = try await ProjectIndexService().index(root: fixture)

    #expect(session.stats.fileCount == 2)
    #expect(session.stats.uniqueContentCount == 2)
    #expect(session.stats.symbolCount == 3)
    #expect(session.stats.callCount == 1)
    #expect(session.stats.importCount == 1)
}

private actor ControlledIndexService: IndexService {
    typealias Outcome = Result<EngineSession, any Error>
    private var pending: [String: CheckedContinuation<Outcome, Never>] = [:]
    private var completed: [String: Outcome] = [:]
    private var delivered: Set<String> = []

    func index(root: URL) async throws -> EngineSession {
        let key = root.standardizedFileURL.path
        let result: Outcome
        if let completed = completed.removeValue(forKey: key) {
            result = completed
        } else {
            result = await withCheckedContinuation { pending[key] = $0 }
        }
        delivered.insert(key)
        return try result.get()
    }

    func complete(root: URL, result: Outcome) {
        let key = root.standardizedFileURL.path
        if let continuation = pending.removeValue(forKey: key) {
            continuation.resume(returning: result)
        } else {
            completed[key] = result
        }
    }

    func waitUntilDelivered(root: URL) async -> Bool {
        let key = root.standardizedFileURL.path
        for _ in 0..<100 {
            if delivered.contains(key) { return true }
            await Task.yield()
        }
        return false
    }
}

private struct FailingIndexService: IndexService {
    func index(root: URL) async throws -> EngineSession {
        throw Failure.expected
    }
}

private enum Failure: Error {
    case expected
}

@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<100 {
        if condition() { return true }
        await Task.yield()
    }
    return false
}

private func temporaryProject(_ files: [String: String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodeInsightAppModelTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for (path, contents) in files {
        try write(contents, to: root.appendingPathComponent(path))
    }
    return root
}

private func write(_ contents: String, to file: URL) throws {
    try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try contents.write(to: file, atomically: true, encoding: .utf8)
}
