import CodeInsightCore
import CodeInsightEngine
import Foundation
import Testing
@testable import CodeInsightAppModel

@MainActor
@Test
func searchPanelDebouncesRapidQueries() async throws {
    let fixture = try SearchPanelFixture()
    defer { fixture.remove() }
    let counter = CountingSearcher()
    let model = SearchPanelModel(searcher: counter.search)
    model.updateProjectState(.ready(fixture.session, fixture.context))

    model.setQuery("first")
    model.setQuery("second")

    #expect(await searchWaitUntil { await counter.queries.count == 1 })
    #expect(await counter.queries == ["second"])
}

@MainActor
@Test
func searchPanelDiscardsLateQueryResults() async throws {
    let fixture = try SearchPanelFixture()
    defer { fixture.remove() }
    let gate = GatedSearcher()
    let model = SearchPanelModel(searcher: gate.search)
    model.updateProjectState(.ready(fixture.session, fixture.context))

    model.setQuery("old")
    #expect(await searchWaitUntil { await gate.isPending("old") })
    model.setQuery("new")
    #expect(await searchWaitUntil { await gate.isPending("new") })

    await gate.release("new", batches: [SearchBatch(
        matchesByPath: [fixture.b: [searchMatch(path: fixture.b, offset: 2)]],
        isFinal: true,
        completeness: .complete
    )])
    #expect(await searchWaitUntil { model.totalMatches == 1 })
    await gate.release("old", batches: [SearchBatch(
        matchesByPath: [fixture.a: [searchMatch(path: fixture.a, offset: 1)]],
        isFinal: true,
        completeness: .complete
    )])
    for _ in 0..<10 { await Task.yield() }

    #expect(model.groups.map(\.path) == ["b.rs"])
    #expect(model.openSelection()?.byteOffset == 2)
}

@MainActor
@Test
func searchPanelOrdersGroupsWrapsSelectionAndOpensMatch() async throws {
    let fixture = try SearchPanelFixture()
    defer { fixture.remove() }
    let batch = SearchBatch(
        matchesByPath: [
            fixture.b: [searchMatch(path: fixture.b, offset: 30)],
            fixture.a: [
                searchMatch(path: fixture.a, offset: 20),
                searchMatch(path: fixture.a, offset: 10),
            ],
        ],
        isFinal: true,
        completeness: .truncated,
        truncatedPathIDs: [fixture.b]
    )
    let model = SearchPanelModel { _, _, _ in stream(batches: [batch]) }
    model.updateProjectState(.ready(fixture.session, fixture.context))
    model.setQuery("needle")
    #expect(await searchWaitUntil { model.totalMatches == 3 })

    #expect(model.groups.map(\.path) == ["a.rs", "b.rs"])
    #expect(model.groups[0].matches.map(\.byteRange.lowerBound) == [10, 20])
    #expect(model.fileCount == 2)
    #expect(model.isTruncated)
    #expect(model.selectedIndex == 0)

    model.selectPrevious()
    #expect(model.selectedIndex == 2)
    #expect(model.openSelection()?.path == "b.rs")
    #expect(model.openSelection()?.byteOffset == 30)

    model.selectNext()
    model.selectNext()
    #expect(model.selectedIndex == 1)
    #expect(model.openSelection()?.path == "a.rs")
    #expect(model.openSelection()?.byteOffset == 20)
}

@MainActor
@Test
func searchPanelShowsEmptyAndIndexingPlaceholders() throws {
    let fixture = try SearchPanelFixture()
    defer { fixture.remove() }
    let model = SearchPanelModel()

    model.updateProjectState(.empty)
    #expect(model.placeholder == "Open a project to search.")
    model.updateProjectState(.indexing(root: fixture.root, startedAt: .now))
    #expect(model.placeholder == "Indexing project…")
    #expect(!model.isSearching)
}

private actor CountingSearcher {
    private(set) var queries: [String] = []

    func search(
        session: EngineSession,
        query: ContentSearchQuery,
        context: QueryContext
    ) async throws -> AsyncThrowingStream<SearchBatch, Error> {
        queries.append(query.pattern)
        return stream(batches: [SearchBatch(
            matchesByPath: [:],
            isFinal: true,
            completeness: .complete
        )])
    }
}

private actor GatedSearcher {
    private var continuations: [
        String: CheckedContinuation<AsyncThrowingStream<SearchBatch, Error>, Never>
    ] = [:]

    func search(
        session: EngineSession,
        query: ContentSearchQuery,
        context: QueryContext
    ) async throws -> AsyncThrowingStream<SearchBatch, Error> {
        await withCheckedContinuation { continuations[query.pattern] = $0 }
    }

    func isPending(_ query: String) -> Bool {
        continuations[query] != nil
    }

    func release(_ query: String, batches: [SearchBatch]) {
        continuations.removeValue(forKey: query)?.resume(
            returning: stream(batches: batches)
        )
    }
}

private struct SearchPanelFixture {
    let root: URL
    let session: EngineSession
    let context: QueryContext
    let a: PathID
    let b: PathID

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SearchPanelModelTests-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try "needle".write(
            to: root.appendingPathComponent("a.rs"),
            atomically: true,
            encoding: .utf8
        )
        try "needle".write(
            to: root.appendingPathComponent("b.rs"),
            atomically: true,
            encoding: .utf8
        )
        let indexed = try ProjectIndexer().index(root: root)
        let queryContext = QueryContext(
            snapshotID: indexed.snapshotID,
            analysisProfileID: indexed.analysisProfile.id,
            generation: 1
        )
        let aPath = indexed.manifest.files.first {
            indexed.paths.resolve($0.pathID) == "a.rs"
        }!.pathID
        let bPath = indexed.manifest.files.first {
            indexed.paths.resolve($0.pathID) == "b.rs"
        }!.pathID
        session = indexed
        context = queryContext
        a = aPath
        b = bPath
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func searchMatch(path: PathID, offset: UInt32) -> SearchMatch {
    SearchMatch(
        pathID: path,
        byteRange: ByteRange(lowerBound: offset, upperBound: offset + 1),
        line: 1,
        column: offset + 1,
        lineText: "needle"
    )
}

private func stream(
    batches: [SearchBatch]
) -> AsyncThrowingStream<SearchBatch, Error> {
    AsyncThrowingStream { continuation in
        for batch in batches { continuation.yield(batch) }
        continuation.finish()
    }
}

@MainActor
private func searchWaitUntil(
    _ condition: @escaping @MainActor () async -> Bool
) async -> Bool {
    for _ in 0..<200 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}
