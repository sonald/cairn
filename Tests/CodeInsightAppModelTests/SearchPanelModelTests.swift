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
    model.setCaseSensitive(true)
    model.setRegex(true)
    model.updateProjectState(.ready(fixture.session, fixture.context))

    model.setQuery("first")
    model.setQuery("second")

    #expect(await searchWaitUntil { await counter.queries.count == 1 })
    #expect((await counter.queries).map(\.pattern) == ["second"])
    #expect((await counter.queries).map(\.caseSensitive) == [true])
    #expect((await counter.queries).map(\.isRegex) == [true])
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
func searchPanelKeepsSelectedMatchWhenEarlierGroupArrives() async throws {
    let fixture = try SearchPanelFixture()
    defer { fixture.remove() }
    let (batches, continuation) =
        AsyncThrowingStream<SearchBatch, Error>.makeStream()
    let model = SearchPanelModel { _, _, _ in batches }
    model.updateProjectState(.ready(fixture.session, fixture.context))
    model.setQuery("needle")

    continuation.yield(SearchBatch(
        matchesByPath: [fixture.b: [
            searchMatch(path: fixture.b, offset: 10),
            searchMatch(path: fixture.b, offset: 20),
        ]],
        isFinal: false,
        completeness: .complete
    ))
    #expect(await searchWaitUntil { model.totalMatches == 2 })
    model.select(1)

    continuation.yield(SearchBatch(
        matchesByPath: [fixture.a: [
            searchMatch(path: fixture.a, offset: 1),
            searchMatch(path: fixture.a, offset: 2),
            searchMatch(path: fixture.a, offset: 3),
        ]],
        isFinal: true,
        completeness: .complete
    ))
    continuation.finish()
    #expect(await searchWaitUntil { model.totalMatches == 5 })

    #expect(model.selectedIndex == 4)
    #expect(model.openSelection()?.path == "b.rs")
    #expect(model.openSelection()?.byteOffset == 20)
}

@MainActor
@Test
func searchPanelKeepsSelectedMatchWhenItsGroupGetsAnEarlierMatch() async throws {
    let fixture = try SearchPanelFixture()
    defer { fixture.remove() }
    let (batches, continuation) =
        AsyncThrowingStream<SearchBatch, Error>.makeStream()
    let model = SearchPanelModel { _, _, _ in batches }
    model.updateProjectState(.ready(fixture.session, fixture.context))
    model.setQuery("needle")

    continuation.yield(SearchBatch(
        matchesByPath: [fixture.b: [
            searchMatch(path: fixture.b, offset: 20),
            searchMatch(path: fixture.b, offset: 30),
        ]],
        isFinal: false,
        completeness: .complete
    ))
    #expect(await searchWaitUntil { model.totalMatches == 2 })
    model.select(1)

    continuation.yield(SearchBatch(
        matchesByPath: [fixture.b: [
            searchMatch(path: fixture.b, offset: 10),
        ]],
        isFinal: true,
        completeness: .complete
    ))
    continuation.finish()
    #expect(await searchWaitUntil { model.totalMatches == 3 })

    #expect(model.selectedIndex == 2)
    #expect(model.openSelection()?.path == "b.rs")
    #expect(model.openSelection()?.byteOffset == 30)
}

@MainActor
@Test
func searchPanelCapsDisplayedMatchesAndReportsTrueTotal() async throws {
    let fixture = try SearchPanelFixture()
    defer { fixture.remove() }
    let model = await searchPanelModel(
        fixture: fixture,
        matchCount: 5_001
    )

    #expect(displayedMatches(in: model) == SearchPanelModel.displayLimit)
    #expect(model.totalMatches == 5_001)
    #expect(
        model.displayTruncationMessage
            == "Showing first 2000 of 5001 matches (truncated)"
    )
    #expect(model.displayedMatchCount + 1 == SearchPanelModel.displayLimit + 1)
    print(
        "M5_SEARCH_CAP "
            + #"{"displayedMatches":\#(model.displayedMatchCount),"displayedRows":\#(model.displayedMatchCount + 1),"totalMatches":\#(model.totalMatches)}"#
    )
}

@MainActor
@Test
func searchPanelDoesNotBuildGroupsPastDisplayLimit() async throws {
    let fixture = try SearchPanelFixture()
    defer { fixture.remove() }
    let batches = [
        SearchBatch(
            matchesByPath: [fixture.a: (0..<SearchPanelModel.displayLimit).map {
                searchMatch(path: fixture.a, offset: UInt32($0))
            }],
            isFinal: false,
            completeness: .complete
        ),
        SearchBatch(
            matchesByPath: [fixture.b: (0..<3).map {
                searchMatch(path: fixture.b, offset: UInt32($0))
            }],
            isFinal: true,
            completeness: .complete
        ),
    ]
    let model = SearchPanelModel { _, _, _ in stream(batches: batches) }
    model.updateProjectState(.ready(fixture.session, fixture.context))
    model.setQuery("needle")
    #expect(await searchWaitUntil {
        model.totalMatches == SearchPanelModel.displayLimit + 3
    })

    #expect(model.groups.map(\.path) == ["a.rs"])
    #expect(model.fileCount == 2)
    #expect(displayedMatches(in: model) == SearchPanelModel.displayLimit)
}

@MainActor
@Test
func searchPanelDoesNotTruncateBelowDisplayLimit() async throws {
    let fixture = try SearchPanelFixture()
    defer { fixture.remove() }
    let model = await searchPanelModel(
        fixture: fixture,
        matchCount: SearchPanelModel.displayLimit - 1
    )

    #expect(displayedMatches(in: model) == SearchPanelModel.displayLimit - 1)
    #expect(model.displayTruncationMessage == nil)
}

@MainActor
@Test
func searchPanelDoesNotTruncateAtDisplayLimit() async throws {
    let fixture = try SearchPanelFixture()
    defer { fixture.remove() }
    let model = await searchPanelModel(
        fixture: fixture,
        matchCount: SearchPanelModel.displayLimit
    )

    #expect(displayedMatches(in: model) == SearchPanelModel.displayLimit)
    #expect(model.displayTruncationMessage == nil)
}

@MainActor
@Test
func searchPanelTruncatesAboveDisplayLimit() async throws {
    let fixture = try SearchPanelFixture()
    defer { fixture.remove() }
    let model = await searchPanelModel(
        fixture: fixture,
        matchCount: SearchPanelModel.displayLimit + 1
    )

    #expect(displayedMatches(in: model) == SearchPanelModel.displayLimit)
    #expect(
        model.displayTruncationMessage
            == "Showing first 2000 of 2001 matches (truncated)"
    )
}

@MainActor
@Test
func searchPanelDistinguishesUpstreamAndDisplayTruncation() async throws {
    let fixture = try SearchPanelFixture()
    defer { fixture.remove() }
    let upstream = await searchPanelModel(
        fixture: fixture,
        matchCount: 10,
        completeness: .truncated
    )
    let display = await searchPanelModel(
        fixture: fixture,
        matchCount: SearchPanelModel.displayLimit + 1
    )

    #expect(upstream.isTruncated)
    #expect(upstream.displayTruncationMessage == nil)
    #expect(!display.isTruncated)
    #expect(display.displayTruncationMessage?.contains("truncated") == true)
}

@MainActor
@Test
func searchPanelKeepsSelectionWithinDisplayedMatchesAtCap() async throws {
    let fixture = try SearchPanelFixture()
    defer { fixture.remove() }
    let (batches, continuation) =
        AsyncThrowingStream<SearchBatch, Error>.makeStream()
    let model = SearchPanelModel { _, _, _ in batches }
    model.updateProjectState(.ready(fixture.session, fixture.context))
    model.setQuery("needle")

    continuation.yield(SearchBatch(
        matchesByPath: [fixture.a: (0..<SearchPanelModel.displayLimit).map {
            searchMatch(path: fixture.a, offset: UInt32($0))
        }],
        isFinal: false,
        completeness: .complete
    ))
    #expect(await searchWaitUntil {
        model.totalMatches == SearchPanelModel.displayLimit
    })
    model.select(1_234)
    let selectedMatch = model.groups[0].matches[1_234]

    continuation.yield(SearchBatch(
        matchesByPath: [fixture.a: (
            SearchPanelModel.displayLimit..<(SearchPanelModel.displayLimit + 1_000)
        ).map {
            searchMatch(path: fixture.a, offset: UInt32($0))
        }],
        isFinal: true,
        completeness: .complete
    ))
    continuation.finish()
    #expect(await searchWaitUntil {
        model.totalMatches == SearchPanelModel.displayLimit + 1_000
    })

    #expect(model.selectedIndex == 1_234)
    #expect(model.groups[0].matches[1_234] === selectedMatch)
    #expect(displayedMatches(in: model) == SearchPanelModel.displayLimit)

    let boundaryIndex = SearchPanelModel.displayLimit - 1
    model.select(boundaryIndex)
    let boundaryMatch = model.groups[0].matches[boundaryIndex]
    model.selectNext()
    #expect(model.selectedIndex == 0)
    model.selectPrevious()
    #expect(model.selectedIndex == boundaryIndex)
    #expect(model.groups[0].matches[boundaryIndex] === boundaryMatch)
    model.select(SearchPanelModel.displayLimit)
    #expect(model.selectedIndex == boundaryIndex)
}

@MainActor
@Test
func searchPanelClampsWhenPreservedMatchIsAbsentAfterRebuild() async throws {
    let fixture = try SearchPanelFixture()
    defer { fixture.remove() }
    let model = SearchPanelModel { _, query, _ in
        let matches = query.pattern == "old"
            ? [fixture.b: (1...5).map {
                searchMatch(path: fixture.b, offset: UInt32($0))
            }]
            : [fixture.a: [
                searchMatch(path: fixture.a, offset: 1),
                searchMatch(path: fixture.a, offset: 2),
            ]]
        return stream(batches: [SearchBatch(
            matchesByPath: matches,
            isFinal: true,
            completeness: query.pattern == "old" ? .complete : .truncated,
            truncatedPathIDs: query.pattern == "old" ? [] : [fixture.b]
        )])
    }
    model.updateProjectState(.ready(fixture.session, fixture.context))
    model.setQuery("old")
    #expect(await searchWaitUntil { model.totalMatches == 5 })
    model.select(4)
    let selectedMatch = model.groups[0].matches[4]

    model.setQuery("new")
    #expect(await searchWaitUntil { model.totalMatches == 2 })
    model.reconcileSelection(
        preserving: selectedMatch,
        fallbackIndex: 4
    )

    #expect(model.selectedIndex == 1)
    #expect(model.openSelection()?.path == "a.rs")
    #expect(model.openSelection()?.byteOffset == 2)
}

@MainActor
@Test
func searchPanelOrdersGroupsWrapsSelectionAndOpensMatch() async throws {
    let fixture = try SearchPanelFixture()
    defer { fixture.remove() }
    let batches = [SearchBatch(
        matchesByPath: [
            fixture.a: [
                searchMatch(path: fixture.a, offset: 20),
                searchMatch(path: fixture.a, offset: 10),
            ],
        ],
        isFinal: false,
        completeness: .complete
    ), SearchBatch(
        matchesByPath: [
            fixture.b: [searchMatch(path: fixture.b, offset: 30)],
        ],
        isFinal: true,
        completeness: .truncated,
        truncatedPathIDs: [fixture.b]
    )]
    let model = SearchPanelModel { _, _, _ in stream(batches: batches) }
    model.updateProjectState(.ready(fixture.session, fixture.context))
    model.setQuery("needle")
    #expect(await searchWaitUntil { model.totalMatches == 3 })

    #expect(model.groups.map(\.path) == ["a.rs", "b.rs"])
    #expect(model.groups[0].matches.map(\.value.byteRange.lowerBound) == [10, 20])
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
    private(set) var queries: [ContentSearchQuery] = []

    func search(
        session: EngineSession,
        query: ContentSearchQuery,
        context: QueryContext
    ) async throws -> AsyncThrowingStream<SearchBatch, Error> {
        queries.append(query)
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
        lineText: "needle",
        lineTextRange: ByteRange(lowerBound: offset, upperBound: offset + 6)
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
private func searchPanelModel(
    fixture: SearchPanelFixture,
    matchCount: Int,
    completeness: Completeness = .complete
) async -> SearchPanelModel {
    let matches = (0..<matchCount).map {
        searchMatch(path: fixture.a, offset: UInt32($0))
    }
    let model = SearchPanelModel { _, _, _ in stream(batches: [SearchBatch(
        matchesByPath: [fixture.a: matches],
        isFinal: true,
        completeness: completeness
    )]) }
    model.updateProjectState(.ready(fixture.session, fixture.context))
    model.setQuery("needle")
    #expect(await searchWaitUntil { model.totalMatches == matchCount })
    return model
}

@MainActor
private func displayedMatches(in model: SearchPanelModel) -> Int {
    model.groups.reduce(0) { $0 + $1.matches.count }
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
