import CodeInsightCore
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
func navigationHistoryTruncatesForwardEntriesAfterNewPush() {
    let history = NavigationHistory()
    let a = jumpRecord("a.rs", offset: 10)
    let b = jumpRecord("b.rs", offset: 20)
    let c = jumpRecord("c.rs", offset: 30)

    history.push(a)
    history.push(b)
    #expect(history.goBack(from: c) == b)
    history.push(b)

    #expect(history.records == [a, b])
    #expect(!history.canGoForward)
}

@MainActor
@Test
func navigationHistoryDeduplicatesAdjacentRecords() {
    let history = NavigationHistory()
    let record = jumpRecord("main.rs", offset: 7)

    history.push(record)
    history.push(record)

    #expect(history.records == [record])
}

@MainActor
@Test
func navigationHistoryEvictsTheOldestRecordAboveTwoHundred() {
    let history = NavigationHistory()

    for index in 0...200 {
        history.push(jumpRecord("\(index).rs", offset: UInt32(index)))
    }

    #expect(history.records.count == 200)
    #expect(history.records.first?.path == "1.rs")
    #expect(history.records.last?.path == "200.rs")
}

@MainActor
@Test
func navigationHistoryBackAndForwardDoNotPush() {
    let history = NavigationHistory()
    let a = jumpRecord("a.rs", offset: 10)
    let b = jumpRecord("b.rs", offset: 20)
    let c = jumpRecord("c.rs", offset: 30)
    history.push(a)
    history.push(b)
    let count = history.records.count

    #expect(history.goBack(from: c) == b)
    #expect(history.goBack(from: b) == a)
    #expect(history.goForward() == b)
    #expect(history.records.count == count)
}

@MainActor
@Test
func navigationReplayFallsBackToLineAndColumnAfterFileShrinks() throws {
    let root = try temporaryProject([
        "a.rs": "first line\nsecond line is initially long\n",
        "b.rs": "fn b() {}\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    var opened: [(String, UInt32?)] = []
    let model = AppModel(indexService: FailingIndexService()) { file, offset in
        opened.append((file.lastPathComponent, offset))
    }
    model.openProject(root: root)
    let a = root.appendingPathComponent("a.rs")
    let b = root.appendingPathComponent("b.rs")
    let oldA = jumpRecord("a.rs", offset: 100, line: 2, column: 2)

    model.navigate(to: a)
    model.navigate(to: b, leaving: oldA)
    try write("x\ny", to: a)
    model.goBack(from: jumpRecord("b.rs", offset: 0))

    #expect(opened.last?.0 == "a.rs")
    #expect(opened.last?.1 == 3)
}

@MainActor
@Test
func appModelRoutesEveryNavigationAndHistoryReplayThroughOnePipeline() throws {
    let source = String(repeating: "0123456789", count: 10)
    let root = try temporaryProject([
        "a.rs": source,
        "b.rs": source,
        "c.rs": source,
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    var opened: [(String, UInt32?)] = []
    let model = AppModel(indexService: FailingIndexService()) { file, offset in
        opened.append((file.lastPathComponent, offset))
    }
    model.openProject(root: root)

    model.navigate(to: root.appendingPathComponent("a.rs"), byteOffset: 10)
    model.navigate(
        to: root.appendingPathComponent("b.rs"),
        byteOffset: 20,
        leaving: jumpRecord("a.rs", offset: 10)
    )
    model.navigate(
        to: root.appendingPathComponent("c.rs"),
        byteOffset: 30,
        leaving: jumpRecord("b.rs", offset: 20)
    )
    model.goBack(from: jumpRecord("c.rs", offset: 30))
    model.goBack(from: jumpRecord("b.rs", offset: 20))
    model.goForward()

    #expect(opened.map { "\($0.0):\($0.1 ?? 0)" } == [
        "a.rs:10", "b.rs:20", "c.rs:30", "b.rs:20", "a.rs:10", "b.rs:20",
    ])
}

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

@MainActor
@Test
func symbolSearchPanelBuildsRowsWrapsSelectionAndOpens() async throws {
    let root = try temporaryProject([
        "main.rs": "fn alpha() {}\nfn alpine() {}",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try ProjectIndexer().index(root: root)
    let context = QueryContext(
        snapshotID: session.snapshotID,
        analysisProfileID: session.analysisProfile.id,
        generation: 1
    )
    let model = SymbolSearchPanelModel()

    model.updateQuery("al", projectState: .ready(session, context))
    #expect(await waitUntil { model.rows.count == 2 })
    #expect(model.selectedIndex == 0)

    model.selectPrevious()
    #expect(model.selectedIndex == 1)
    model.selectNext()
    #expect(model.selectedIndex == 0)

    let request = try #require(model.openSelection())
    #expect(request.path == "main.rs")
    #expect(request.byteOffset == 3)

    model.reset()
    #expect(model.query.isEmpty)
    #expect(model.rows.isEmpty)
    #expect(model.selectedIndex == nil)

    model.updateQuery(
        "alpha",
        projectState: .indexing(root: root, startedAt: .now)
    )
    #expect(model.rows.count == 1)
    if case let .placeholder(message) = model.rows[0] {
        #expect(message == "Indexing symbols…")
    } else {
        Issue.record("expected indexing placeholder")
    }
}

@MainActor
@Test
func contextWindowDebouncesClicksInsideTheSameToken() async throws {
    let root = try temporaryProject([
        "main.rs": "fn target() {}\nfn main() { target(); }",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try ProjectIndexer().index(root: root)
    let context = queryContext(for: session)
    var resolveCount = 0
    let model = ContextWindowModel { session, file, offset, context in
        resolveCount += 1
        return try session.resolve(file: file, offset: offset, context: context)
    }
    model.updateProjectState(.ready(session, context), root: root)
    let offset = byteOffset(of: "target();", in: "fn target() {}\nfn main() { target(); }")

    model.tokenClicked(file: "main.rs", offset: offset)
    #expect(await waitUntil { model.candidateCount == 1 })
    model.tokenClicked(file: "main.rs", offset: offset + 2)
    for _ in 0..<10 { await Task.yield() }

    #expect(resolveCount == 1)
}

@MainActor
@Test
func contextWindowRecoversAfterClickOnUnresolvableLocation() async throws {
    let source = "fn target() {}\nfn main() { target(); }\n// plain comment\n"
    let root = try temporaryProject(["main.rs": source])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try ProjectIndexer().index(root: root)
    let context = queryContext(for: session)
    var resolveCount = 0
    let model = ContextWindowModel { session, file, offset, context in
        resolveCount += 1
        return try session.resolve(file: file, offset: offset, context: context)
    }
    model.updateProjectState(.ready(session, context), root: root)
    let tokenOffset = byteOffset(of: "target();", in: source)
    let commentOffset = byteOffset(of: "plain comment", in: source)

    model.tokenClicked(file: "main.rs", offset: tokenOffset)
    #expect(await waitUntil { model.candidateCount == 1 })

    // Click a location with no resolvable token: stage empties and the stale
    // located token must be cleared, not retained.
    model.tokenClicked(file: "main.rs", offset: commentOffset)
    for _ in 0..<10 { await Task.yield() }

    // Clicking the original token again must re-resolve instead of hitting the
    // debounce guard with a stale locatedToken and staying blank forever.
    model.tokenClicked(file: "main.rs", offset: tokenOffset)
    #expect(await waitUntil { model.candidateCount == 1 })
    #expect(resolveCount == 2)
}

@MainActor
@Test
func contextWindowDiscardsOutOfOrderRequests() async throws {
    let source = "fn alpha() {}\nfn beta() {}\nfn main() { alpha(); beta(); }"
    let root = try temporaryProject(["main.rs": source])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try ProjectIndexer().index(root: root)
    let context = queryContext(for: session)
    let path = try #require(pathID("main.rs", in: session))
    let alpha = byteOffset(of: "alpha();", in: source)
    let beta = byteOffset(of: "beta();", in: source)
    let gate = ControlledContextResolver()
    let model = ContextWindowModel(gate.resolve)
    model.updateProjectState(.ready(session, context), root: root)

    model.tokenClicked(file: "main.rs", offset: alpha)
    #expect(await waitUntil { gate.isPending(alpha) })
    model.tokenClicked(file: "main.rs", offset: beta)
    #expect(await waitUntil { gate.isPending(beta) })
    gate.complete(
        beta,
        with: try session.resolve(file: path, offset: beta, context: context)
    )
    #expect(await waitUntil { model.selectedCandidate?.line == 2 })
    gate.complete(
        alpha,
        with: try session.resolve(file: path, offset: alpha, context: context)
    )
    for _ in 0..<10 { await Task.yield() }

    #expect(model.selectedCandidate?.line == 2)
}

@MainActor
@Test
func pinnedContextIgnoresClickButExplicitJumpStillResolves() async throws {
    let source = "fn target() {}\nfn main() { target(); }"
    let root = try temporaryProject(["main.rs": source])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try ProjectIndexer().index(root: root)
    let context = queryContext(for: session)
    var resolveCount = 0
    let model = ContextWindowModel { session, file, offset, context in
        resolveCount += 1
        return try session.resolve(file: file, offset: offset, context: context)
    }
    model.updateProjectState(.ready(session, context), root: root)
    model.setMode(.pinned)
    let offset = byteOffset(of: "target();", in: source)

    model.tokenClicked(file: "main.rs", offset: offset)
    for _ in 0..<10 { await Task.yield() }
    #expect(resolveCount == 0)

    let target = await model.explicitJump(file: "main.rs", offset: offset)
    #expect(target?.line == 1)
    #expect(resolveCount == 1)
}

@MainActor
@Test
func relationSelectionUpdatesContextUnlessPinned() async throws {
    let source = "fn target() {}\nfn caller() { target(); }"
    let root = try temporaryProject(["main.rs": source])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try ProjectIndexer().index(root: root)
    let context = queryContext(for: session)
    var requests: [(path: String, offset: UInt32)] = []
    let contextWindow = ContextWindowModel { session, file, offset, context in
        requests.append((session.paths.resolve(file), offset))
        return try session.resolve(file: file, offset: offset, context: context)
    }
    let model = AppModel(
        indexService: FailingIndexService(),
        contextWindow: contextWindow
    )
    #expect(model.transition(to: .indexing(root: root, startedAt: .now)))
    #expect(model.transition(to: .ready(session, context)))
    let caller = try #require(
        session.definitions(of: "caller", context: context).first?.0
    )

    let loadTask = model.relationTree.setRoot(symbol: caller, direction: .calls)
    if let loadTask { await loadTask.value }
    let strong = try #require(model.relationTree.root?.children?.first {
        $0.kind == .group && $0.title == "Strong"
    })
    let edge = try #require(strong.children?.first { $0.title == "target" })

    contextWindow.setMode(.pinned)
    model.relationTree.select(edge)
    for _ in 0..<10 { await Task.yield() }
    #expect(requests.isEmpty)

    contextWindow.setMode(.follow)
    model.relationTree.select(edge)
    #expect(await waitUntil { requests.count == 1 })
    #expect(requests.first?.path == "main.rs")
    #expect(requests.first?.offset == byteOffset(of: "target() {}", in: source))
}

@MainActor
@Test
func contextCandidateSelectionWraps() async throws {
    let source = """
        struct A; impl A { fn close(&self) {} }
        struct B; impl B { fn close(&self) {} }
        fn f(value: A) { value.close(); }
        """
    let root = try temporaryProject(["main.rs": source])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try ProjectIndexer().index(root: root)
    let model = ContextWindowModel()
    model.updateProjectState(.ready(session, queryContext(for: session)), root: root)
    model.tokenClicked(file: "main.rs", offset: byteOffset(of: "close();", in: source))
    #expect(await waitUntil { model.candidateCount == 2 })

    model.selectPrevious()
    #expect(model.selectedIndex == 1)
    model.selectNext()
    #expect(model.selectedIndex == 0)
}

@MainActor
@Test
func contextPendingTokenResolvesWhenIndexBecomesReady() async throws {
    let source = "fn target() {}\nfn main() { target(); }"
    let root = try temporaryProject(["main.rs": source])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try ProjectIndexer().index(root: root)
    var resolveCount = 0
    let model = ContextWindowModel { session, file, offset, context in
        resolveCount += 1
        return try session.resolve(file: file, offset: offset, context: context)
    }
    model.updateProjectState(
        .indexing(root: root, startedAt: .now),
        root: root
    )

    model.tokenClicked(file: "main.rs", offset: byteOffset(of: "target();", in: source))
    #expect(model.isIndexBuilding)
    #expect(resolveCount == 0)

    model.updateProjectState(
        .ready(session, queryContext(for: session)),
        root: root
    )
    #expect(await waitUntil { model.candidateCount == 1 })
    #expect(resolveCount == 1)
}

@MainActor
@Test
func contextWindowResolvesUseAliasFixtureWithPresentationLabel() async throws {
    let root = repositoryRoot
        .appendingPathComponent("Tests/RustExtractorTests/Fixtures/use_alias")
    let source = try String(
        contentsOf: root.appendingPathComponent("main.rs"),
        encoding: .utf8
    )
    let session = try ProjectIndexer().index(root: root)
    let model = ContextWindowModel()
    model.updateProjectState(.ready(session, queryContext(for: session)), root: root)

    model.tokenClicked(
        file: "main.rs",
        offset: byteOffset(of: "open_db();", in: source)
    )
    #expect(await waitUntil { model.candidateCount == 1 })
    let candidate = try #require(model.selectedCandidate)

    #expect(candidate.label.lowercased().contains("strong"))
    #expect(candidate.path == "db.rs")
}

@MainActor
@Test
func contextWindowPresentsLocalBindingKind() async throws {
    let source = "fn f() {\n    let local = 1;\n    local;\n}"
    let root = try temporaryProject(["main.rs": source])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try ProjectIndexer().index(root: root)
    let model = ContextWindowModel()
    model.updateProjectState(.ready(session, queryContext(for: session)), root: root)

    model.tokenClicked(
        file: "main.rs",
        offset: byteOffset(of: "local;", in: source)
    )
    #expect(await waitUntil { model.candidateCount == 1 })

    #expect(model.selectedCandidate?.bindingKind == "letBinding")
    #expect(model.selectedCandidate?.line == 2)
}

@MainActor
@Test
func contextWindowExplainsUnresolvedExternalCrate() async throws {
    let source = "use std::io::Read;\nfn f() { Read(); }"
    let root = try temporaryProject(["main.rs": source])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try ProjectIndexer().index(root: root)
    let model = ContextWindowModel()
    model.updateProjectState(.ready(session, queryContext(for: session)), root: root)

    model.tokenClicked(
        file: "main.rs",
        offset: byteOffset(of: "Read();", in: source)
    )
    #expect(await waitUntil { model.candidateCount == 1 })

    #expect(model.selectedCandidate?.excerpt == "external crate — not resolved (M1)")
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

@MainActor
private final class ControlledContextResolver {
    private var pending: [UInt32: CheckedContinuation<[ResolutionCandidate], Never>] = [:]

    func resolve(
        session: EngineSession,
        file: PathID,
        offset: UInt32,
        context: QueryContext
    ) async throws -> [ResolutionCandidate] {
        await withCheckedContinuation { pending[offset] = $0 }
    }

    func isPending(_ offset: UInt32) -> Bool {
        pending[offset] != nil
    }

    func complete(_ offset: UInt32, with candidates: [ResolutionCandidate]) {
        pending.removeValue(forKey: offset)?.resume(returning: candidates)
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

private func queryContext(for session: EngineSession) -> QueryContext {
    QueryContext(
        snapshotID: session.snapshotID,
        analysisProfileID: session.analysisProfile.id,
        generation: 1
    )
}

private func pathID(_ path: String, in session: EngineSession) -> PathID? {
    session.manifest.files.first {
        session.paths.resolve($0.pathID) == path
    }?.pathID
}

private func byteOffset(of needle: String, in source: String) -> UInt32 {
    let range = source.range(of: needle)!
    return UInt32(source[..<range.lowerBound].utf8.count)
}

private func jumpRecord(
    _ path: String,
    offset: UInt32,
    line: UInt32 = 1,
    column: UInt32? = nil
) -> JumpRecord {
    JumpRecord(
        path: path,
        contentID: nil,
        byteOffset: offset,
        line: line,
        column: column ?? offset + 1,
        symbolAnchor: nil,
        snapshotID: SnapshotID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!
        )
    )
}
