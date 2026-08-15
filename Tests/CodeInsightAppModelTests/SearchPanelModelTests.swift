import CodeInsightCore
import CodeInsightEngine
import Foundation
import Testing
@testable import CodeInsightAppModel

@MainActor
@Test
func searchPanelDebouncesRapidQueries() async throws {
    let fixture = try await SearchPanelFixture()
    defer { fixture.remove() }
    let counter = CountingSearcher()
    let model = SearchPanelModel(searcher: counter.search)
    model.setCaseSensitive(true)
    model.setRegex(true)
    model.updateProjectState(.ready(fixture.session, fixture.context))

    model.setQuery("first")
    model.setQuery("second")

    #expect(await testWaitUntil("await counter.queries.count == 1") { await counter.queries.count == 1 })
    #expect((await counter.queries).map(\.pattern) == ["second"])
    #expect((await counter.queries).map(\.caseSensitive) == [true])
    #expect((await counter.queries).map(\.isRegex) == [true])
}

@MainActor
@Test
func searchPanelDiscardsLateQueryResults() async throws {
    let fixture = try await SearchPanelFixture()
    defer { fixture.remove() }
    let gate = GatedSearcher()
    let model = SearchPanelModel(searcher: gate.search)
    model.updateProjectState(.ready(fixture.session, fixture.context))

    model.setQuery("old")
    #expect(await testWaitUntil("await gate.isPending(\"old\")") { await gate.isPending("old") })
    model.setQuery("new")
    #expect(await testWaitUntil("await gate.isPending(\"new\")") { await gate.isPending("new") })

    await gate.release("new", batches: [SearchBatch(
        matchesByPath: [fixture.b: [searchMatch(path: fixture.b, offset: 2)]],
        isFinal: true,
        completeness: .complete
    )])
    #expect(await testWaitUntil("model.totalMatches == 1") { model.totalMatches == 1 })
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
    let fixture = try await SearchPanelFixture()
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
    #expect(await testWaitUntil("model.totalMatches == 2") { model.totalMatches == 2 })
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
    #expect(await testWaitUntil("model.totalMatches == 5") { model.totalMatches == 5 })

    #expect(model.selectedIndex == 4)
    #expect(model.openSelection()?.path == "b.rs")
    #expect(model.openSelection()?.byteOffset == 20)
}

@MainActor
@Test
func searchPanelKeepsSelectedMatchWhenItsGroupGetsAnEarlierMatch() async throws {
    let fixture = try await SearchPanelFixture()
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
    #expect(await testWaitUntil("model.totalMatches == 2") { model.totalMatches == 2 })
    model.select(1)

    continuation.yield(SearchBatch(
        matchesByPath: [fixture.b: [
            searchMatch(path: fixture.b, offset: 10),
        ]],
        isFinal: true,
        completeness: .complete
    ))
    continuation.finish()
    #expect(await testWaitUntil("model.totalMatches == 3") { model.totalMatches == 3 })

    #expect(model.selectedIndex == 2)
    #expect(model.openSelection()?.path == "b.rs")
    #expect(model.openSelection()?.byteOffset == 30)
}

@MainActor
@Test
func searchPanelCapsDisplayedMatchesAndReportsTrueTotal() async throws {
    let fixture = try await SearchPanelFixture()
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
    let fixture = try await SearchPanelFixture()
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
    #expect(await testWaitUntil("model.totalMatches == SearchPanelModel.displayLimit + 3") {
        model.totalMatches == SearchPanelModel.displayLimit + 3
    })

    #expect(model.groups.map(\.path) == ["a.rs"])
    #expect(model.fileCount == 2)
    #expect(displayedMatches(in: model) == SearchPanelModel.displayLimit)
}

@MainActor
@Test
func searchPanelDoesNotTruncateBelowDisplayLimit() async throws {
    let fixture = try await SearchPanelFixture()
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
    let fixture = try await SearchPanelFixture()
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
    let fixture = try await SearchPanelFixture()
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
    let fixture = try await SearchPanelFixture()
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
    let fixture = try await SearchPanelFixture()
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
    #expect(await testWaitUntil("model.totalMatches == SearchPanelModel.displayLimit") {
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
    #expect(await testWaitUntil("model.totalMatches == SearchPanelModel.displayLimit + 1_000") {
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
    let fixture = try await SearchPanelFixture()
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
    #expect(await testWaitUntil("model.totalMatches == 5") { model.totalMatches == 5 })
    model.select(4)
    let selectedMatch = model.groups[0].matches[4]

    model.setQuery("new")
    #expect(await testWaitUntil("model.totalMatches == 2") { model.totalMatches == 2 })
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
    let fixture = try await SearchPanelFixture()
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
    #expect(await testWaitUntil("model.totalMatches == 3") { model.totalMatches == 3 })

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
func searchPanelShowsEmptyAndIndexingPlaceholders() async throws {
    let fixture = try await SearchPanelFixture()
    defer { fixture.remove() }
    let model = SearchPanelModel()

    model.updateProjectState(.empty)
    #expect(model.placeholder == "Open a project to search.")
    model.updateProjectState(.indexing(root: fixture.root, startedAt: .now))
    #expect(model.placeholder == "Indexing project…")
    #expect(!model.isSearching)
}

@MainActor
@Test
func searchPanelAggregatesAllWorkspaceSessionsAndSortsPathsStably() async throws {
    let fixture = try await SearchPanelFixture(workspace: true)
    defer { fixture.remove() }
    let model = SearchPanelModel { session, _, _ in
        let path = try #require(activeWorkspacePathID(fixture: fixture, session: session))
        return stream(batches: [SearchBatch(
            matchesByPath: [path: [searchMatch(path: path, offset: 2)]],
            isFinal: true,
            completeness: .complete
        )])
    }
    model.updateWorkspaceSessions(fixture.workspace)
    model.setQuery("needle")

    #expect(await testWaitUntil("model.totalMatches == 3") { model.totalMatches == 3 })
    #expect(model.groups.map(\.path) == ["a.rs", "b.py", "b.ts"])
    #expect(model.groups.map { $0.matches.map(\.value.byteRange.lowerBound) }
        == [[2], [2], [2]])
}

@MainActor
@Test
func searchPanelWorkspaceDisplayLimitCountsAllSessionsAndWaitsForAllFinals() async throws {
    let fixture = try await SearchPanelFixture(workspace: true)
    defer { fixture.remove() }
    let page1 = SearchPanelModel.displayLimit / 2
    let page2 = SearchPanelModel.displayLimit / 2 + 3
    let displayLimit = SearchPanelModel.displayLimit
    let model = SearchPanelModel { session, _, _ in
        let path = try #require(activeWorkspacePathID(fixture: fixture, session: session))
        if session.analysisProfile.language == .rust {
            return stream(batches: [
                SearchBatch(
                    matchesByPath: [path: (0..<page1).map {
                        searchMatch(path: path, offset: UInt32($0))
                    }],
                    isFinal: false,
                    completeness: .complete
                ),
                SearchBatch(
                    matchesByPath: [path: (page1..<page2).map {
                        searchMatch(path: path, offset: UInt32($0))
                    }],
                    isFinal: true,
                    completeness: .complete
                ),
            ])
        }
        return stream(batches: [
            SearchBatch(
                matchesByPath: [path: (0..<displayLimit).map {
                    searchMatch(path: path, offset: UInt32($0))
                }],
                isFinal: false,
                completeness: .complete
            ),
            SearchBatch(
                matchesByPath: [path: (displayLimit..<(displayLimit + 10)).map {
                    searchMatch(path: path, offset: UInt32($0))
                }],
                isFinal: true,
                completeness: .complete
            ),
        ])
    }
    model.updateWorkspaceSessions(fixture.workspace)
    model.setQuery("needle")

    #expect(await testWaitUntil(
        "model.totalMatches == page2 + 2 * (displayLimit + 10)"
    ) {
        model.totalMatches == page2 + 2 * (displayLimit + 10)
    })
    #expect(displayedMatches(in: model) == displayLimit)
    #expect(model.fileCount == 3)
    #expect(model.totalMatches == page2 + 2 * (displayLimit + 10))
}

@MainActor
@Test
func searchPanelWorkspaceAnyStreamErrorFailsOverallSearch() async throws {
    let fixture = try await SearchPanelFixture(workspace: true)
    defer { fixture.remove() }
    let model = SearchPanelModel { session, _, _ in
        if session.analysisProfile.language == .python {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: SearchPanelFailure.expected)
            }
        }
        return stream(batches: [SearchBatch(
            matchesByPath: [:],
            isFinal: true,
            completeness: .complete
        )])
    }
    model.updateWorkspaceSessions(fixture.workspace)
    model.setQuery("needle")

    #expect(await testWaitUntil("model.placeholder == \"Search failed.\"") {
        model.placeholder == "Search failed."
    })
    #expect(!model.isSearching)
}

@MainActor
@Test
func searchPanelWorkspaceNewQueryDropsAllOldStreams() async throws {
    let fixture = try await SearchPanelFixture(workspace: true)
    defer { fixture.remove() }
    let gate = GatedSearcher()
    let model = SearchPanelModel(searcher: gate.search)
    model.updateWorkspaceSessions(fixture.workspace)

    model.setQuery("old")
    #expect(await testWaitUntil("gate.pending(\"old\")") { await gate.pending("old") })
    model.setQuery("new")
    #expect(await testWaitUntil("gate.pending(\"new\")") { await gate.pending("new") })

    await gate.release("new", batches: [SearchBatch(
        matchesByPath: [fixture.rust.pathID: [
            searchMatch(path: fixture.rust.pathID, offset: 1),
        ]],
        isFinal: true,
        completeness: .complete
    )])
    #expect(await testWaitUntil("model.totalMatches == 1") { model.totalMatches == 1 })
    #expect(await testWaitUntil("gate.pending(\"new\")") { await gate.pending("new") })

    await gate.release("new", batches: [SearchBatch(
        matchesByPath: [fixture.python.pathID: [
            searchMatch(path: fixture.python.pathID, offset: 1),
        ]],
        isFinal: true,
        completeness: .complete
    )])
    #expect(await testWaitUntil("model.totalMatches == 2") { model.totalMatches == 2 })
    #expect(await testWaitUntil("gate.pending(\"new\")") { await gate.pending("new") })

    await gate.release("new", batches: [SearchBatch(
        matchesByPath: [fixture.typescript.pathID: [
            searchMatch(path: fixture.typescript.pathID, offset: 1),
        ]],
        isFinal: true,
        completeness: .complete
    )])
    #expect(await testWaitUntil("model.totalMatches == 3") { model.totalMatches == 3 })
    #expect(await testWaitUntil("gate.returnedCount(\"new\") == 3") {
        await gate.returnedCount("new") == 3
    })

    await gate.release("old", batches: [SearchBatch(
        matchesByPath: [fixture.python.pathID: [
            searchMatch(path: fixture.python.pathID, offset: 9),
        ]],
        isFinal: true,
        completeness: .complete
    )])
    #expect(await testWaitUntil("gate.returnedCount(\"old\") == 1") {
        await gate.returnedCount("old") == 1
    })

    #expect(model.totalMatches == 3)
    #expect(model.groups.map(\.path) == ["a.rs", "b.py", "b.ts"])
}

@MainActor
@Test
func searchWorkspaceNewQueryResetsOldResultsAndPlaceholder() async throws {
    let fixture = try await SearchPanelFixture(workspace: true)
    defer { fixture.remove() }
    let model = SearchPanelModel { session, query, _ in
        let path = try #require(activeWorkspacePathID(fixture: fixture, session: session))
        let count = query.pattern == "old" ? 3 : 0
        return stream(batches: [SearchBatch(
            matchesByPath: count == 0
                ? [:]
                : [path: (0..<count).map {
                    searchMatch(path: path, offset: UInt32($0))
                }],
            isFinal: true,
            completeness: count == 0 ? .complete : .truncated
        )])
    }
    model.updateWorkspaceSessions(fixture.workspace)
    model.setQuery("old")
    #expect(await testWaitUntil("model.totalMatches == 9") { model.totalMatches == 9 })
    #expect(model.isTruncated)

    model.setQuery("new")
    #expect(await testWaitUntil("model.totalMatches == 0 && !model.isTruncated") {
        model.totalMatches == 0 && !model.isTruncated && model.placeholder == "No matches."
    })
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
    private var returnedCounts: [String: Int] = [:]

    func search(
        session: EngineSession,
        query: ContentSearchQuery,
        context: QueryContext
    ) async throws -> AsyncThrowingStream<SearchBatch, Error> {
        let result = await withCheckedContinuation { continuation in
            continuations[query.pattern] = continuation
        }
        returnedCounts[query.pattern, default: 0] += 1
        return result
    }

    func isPending(_ query: String) -> Bool {
        continuations[query] != nil
    }

    func pending(_ query: String) -> Bool {
        isPending(query)
    }

    func returnedCount(_ query: String) -> Int {
        returnedCounts[query, default: 0]
    }

    func release(_ query: String, batches: [SearchBatch]) {
        continuations.removeValue(forKey: query)?.resume(
            returning: stream(batches: batches)
        )
    }
}

@MainActor
private struct SearchPanelFixture {
    let root: URL
    let session: EngineSession
    let context: QueryContext
    let a: PathID
    let b: PathID
    let workspace: [(EngineSession, QueryContext)]
    let rust: (session: EngineSession, context: QueryContext, pathID: PathID)
    let python: (session: EngineSession, context: QueryContext, pathID: PathID)
    let typescript: (session: EngineSession, context: QueryContext, pathID: PathID)

    init(workspace: Bool = false) async throws {
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
        try "needle".write(
            to: root.appendingPathComponent("b.py"),
            atomically: true,
            encoding: .utf8
        )
        try "needle".write(
            to: root.appendingPathComponent("b.ts"),
            atomically: true,
            encoding: .utf8
        )
        let gitInit = Process()
        gitInit.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        gitInit.arguments = ["-C", root.path, "init", "-q"]
        try gitInit.run()
        gitInit.waitUntilExit()
        guard gitInit.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
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
        if workspace {
            let model = AppModel(indexService: ProjectIndexService())
            try await model.openProject(root: root, languages: [.typescript, .rust, .python])
            let querySessions = model.querySessions
            guard querySessions.count == 3 else {
                throw CocoaError(.featureUnsupported)
            }
            let rust = try #require(querySessions.first {
                $0.0.analysisProfile.language == .rust
            }.map(\.0))
            let python = try #require(querySessions.first {
                $0.0.analysisProfile.language == .python
            }.map(\.0))
            let ts = try #require(querySessions.first {
                $0.0.analysisProfile.language == .typescript
            }.map(\.0))
            let rustContext = try #require(querySessions.first {
                $0.0.analysisProfile.language == .rust
            }.map(\.1))
            let pythonContext = try #require(querySessions.first {
                $0.0.analysisProfile.language == .python
            }.map(\.1))
            let tsContext = try #require(querySessions.first {
                $0.0.analysisProfile.language == .typescript
            }.map(\.1))
            let rustPath = try Self.fid(rust, "a.rs")
            let pythonPath = try Self.fid(python, "b.py")
            let tsPath = try Self.fid(ts, "b.ts")
            let tuples: [(EngineSession, QueryContext, PathID)] = [
                (rust, rustContext, rustPath),
                (python, pythonContext, pythonPath),
                (ts, tsContext, tsPath),
            ]
            self.workspace = tuples.map { ($0.0, $0.1) }
            self.rust = (tuples[0].0, tuples[0].1, tuples[0].2)
            self.python = (tuples[1].0, tuples[1].1, tuples[1].2)
            self.typescript = (tuples[2].0, tuples[2].1, tuples[2].2)
        } else {
            self.workspace = []
            self.rust = (indexed, queryContext, aPath)
            self.python = (indexed, queryContext, aPath)
            self.typescript = (indexed, queryContext, aPath)
        }
    }

    private static func fid(_ session: EngineSession, _ path: String) throws -> PathID {
        try #require(session.manifest.files.first {
            session.paths.resolve($0.pathID) == path
        }?.pathID)
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

private enum SearchPanelFailure: Error {
    case expected
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
    #expect(await testWaitUntil("model.totalMatches == matchCount") { model.totalMatches == matchCount })
    return model
}

@MainActor
private func displayedMatches(in model: SearchPanelModel) -> Int {
    model.groups.reduce(0) { $0 + $1.matches.count }
}

private func activeWorkspacePathID(
    fixture: SearchPanelFixture,
    session: EngineSession
) -> PathID? {
    switch session.analysisProfile.language {
    case .rust:
        return fixture.rust.pathID
    case .python:
        return fixture.python.pathID
    case .typescript:
        return fixture.typescript.pathID
    case .javascript:
        return nil
    }
}
