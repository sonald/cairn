import CodeInsightCore
import CodeInsightEngine
import CodeInsightExact
import Foundation
import Testing
@testable import CodeInsightAppModel

@MainActor
@Test
func relationTreeGroupsStrongProbableAndPossibleCandidates() async throws {
    let root = try relationTemporaryProject([
        "main.rs": """
            fn strong_target() {}
            fn root() {
                strong_target();
                probable_target();
                ambiguous_target();
            }
            """,
        "probable.rs": "pub fn probable_target() {}",
        "a.rs": "pub fn ambiguous_target() {}",
        "b.rs": "pub fn ambiguous_target() {}",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try ProjectIndexer().index(root: root)
    let context = relationQueryContext(for: session)
    let symbol = try #require(
        session.definitions(of: "root", context: context).first?.0
    )
    let model = RelationTreeModel()
    model.updateProjectState(.ready(session, context))

    model.setRoot(symbol: symbol, direction: .calls)
    #expect(await relationWaitUntil { relationTreeFinishedLoading(model.root) })

    let exact = try relationGroup("Exact (0)", in: model.root)
    let strong = try relationGroup("Strong", in: model.root)
    let probable = try relationGroup("Probable", in: model.root)
    let possible = try relationGroup("Possible", in: model.root)
    #expect(exact.children?.isEmpty == true)
    #expect(strong.children?.map(\.title) == ["strong_target"])
    #expect(probable.children?.contains {
        $0.title == "probable_target" && $0.subtitle == "Probable · direct"
    } == true)
    #expect(possible.children?.filter {
        $0.title == "ambiguous_target" && $0.subtitle == "Possible · direct"
    }.count == 2)
}

@MainActor
@Test
func relationTreeLabelsNameOnlyCallsHonestly() async throws {
    let fixture = try RelationFixture()
    defer { fixture.remove() }
    let methodName = fixture.session.names.intern("method")
    let edges = [
        RelationTreeModel.LoadedEdge(
            title: "possible-name-only",
            certainty: .possible,
            dispatch: .dynamicDispatch,
            symbol: fixture.b,
            path: "main.rs",
            byteOffset: 15,
            line: 1,
            evidence: [.methodNameOnly(nameID: methodName)]
        ),
        RelationTreeModel.LoadedEdge(
            title: "probable-name-only",
            certainty: .probable,
            dispatch: .dynamicDispatch,
            symbol: fixture.b,
            path: "main.rs",
            byteOffset: 15,
            line: 1,
            evidence: [.methodNameOnly(nameID: methodName)]
        ),
        RelationTreeModel.LoadedEdge(
            title: "same-file",
            certainty: .possible,
            dispatch: .dynamicDispatch,
            symbol: fixture.b,
            path: "main.rs",
            byteOffset: 15,
            line: 1,
            evidence: [
                .methodNameOnly(nameID: methodName),
                .sameFile(pathID: fixture.a.pathID),
            ]
        ),
        RelationTreeModel.LoadedEdge(
            title: "unique-import",
            certainty: .probable,
            dispatch: .dynamicDispatch,
            symbol: fixture.b,
            path: "main.rs",
            byteOffset: 15,
            line: 1,
            evidence: [
                .methodNameOnly(nameID: methodName),
                .uniqueImport(importBindingIndex: 0),
            ]
        ),
    ]
    let model = RelationTreeModel(loader: { _, _, _, _ in
        .init(edges: edges, isTruncated: false)
    })
    model.updateProjectState(.ready(fixture.session, fixture.context))

    model.setRoot(symbol: fixture.a, direction: .calls)
    #expect(await relationWaitUntil { relationTreeFinishedLoading(model.root) })

    let possible = try relationGroup("Possible", in: model.root)
    let probable = try relationGroup("Probable", in: model.root)
    let possibleSubtitles = Dictionary(
        uniqueKeysWithValues: possible.children?.compactMap { node in
            node.subtitle.map { (node.title, $0) }
        } ?? []
    )
    let probableSubtitles = Dictionary(
        uniqueKeysWithValues: probable.children?.compactMap { node in
            node.subtitle.map { (node.title, $0) }
        } ?? []
    )
    #expect(possibleSubtitles == [
        "possible-name-only": "Possible · dynamic · name match only",
        "same-file": "Possible · dynamic",
    ])
    #expect(probableSubtitles == [
        "probable-name-only": "Probable · dynamic · name match only",
        "unique-import": "Probable · dynamic",
    ])
}

@MainActor
@Test
func relationTreePromotesOnlyMatchingExactDefinitions() async throws {
    let fixture = try RelationFixture()
    defer { fixture.remove() }
    let edges = [
        ("matching", UInt32(10)),
        ("mismatching", UInt32(11)),
        ("no exact", UInt32(12)),
    ].map { title, queryOffset in
        RelationTreeModel.LoadedEdge(
            title: title,
            certainty: .strong,
            dispatch: .direct,
            symbol: fixture.b,
            path: "main.rs",
            byteOffset: 20,
            line: 1,
            evidence: [],
            exactQuery: ("main.rs", queryOffset, 1),
            fuzzyTarget: ("main.rs", 20)
        )
    }
    let model = RelationTreeModel(
        loader: { _, _, _, _ in
            .init(edges: edges, isTruncated: false)
        },
        exactResolver: { _, offset, _ in
            switch offset {
            case 10: relationExactEntry(
                file: "main.rs",
                byteOffset: 20,
                origin: .materialized(commitOID: "0123456789abcdef")
            )
            case 11: relationExactEntry(file: "main.rs", byteOffset: 21)
            default: nil
            }
        }
    )
    model.updateProjectState(.ready(fixture.session, fixture.context))

    model.setRoot(symbol: fixture.a, direction: .calls)
    #expect(await relationWaitUntil { relationTreeFinishedLoading(model.root) })

    let exact = try relationGroup("Exact", in: model.root)
    let strong = try relationGroup("Strong", in: model.root)
    #expect(exact.children?.map(\.title) == ["matching"])
    #expect(exact.children?.first?.badge == "Exact · lsp · hist")
    #expect(strong.children?.map(\.title) == ["mismatching", "no exact"])
}

@MainActor
@Test
func relationTreeDemotesProviderProvenExternalNameOnlyCalls() async throws {
    let fixture = try RelationFixture()
    defer { fixture.remove() }
    let methodName = fixture.session.names.intern("method")
    let edges = [
        ("external", Certainty.possible, UInt32(10)),
        ("matching", Certainty.possible, UInt32(11)),
        ("no exact", Certainty.probable, UInt32(12)),
        ("strong", Certainty.strong, UInt32(13)),
    ].map { title, certainty, queryOffset in
        RelationTreeModel.LoadedEdge(
            title: title,
            certainty: certainty,
            dispatch: .dynamicDispatch,
            symbol: fixture.b,
            path: "main.rs",
            byteOffset: 20,
            line: 1,
            evidence: [.methodNameOnly(nameID: methodName)],
            exactQuery: ("main.rs", queryOffset, 1),
            fuzzyTarget: ("main.rs", 20)
        )
    }
    let model = RelationTreeModel(
        loader: { _, _, _, _ in
            .init(edges: edges, isTruncated: false)
        },
        exactResolver: { _, offset, _ in
            switch offset {
            case 10, 13:
                relationExactEntry(
                    file: "/dependency/src/client.rs",
                    byteOffset: 40
                )
            case 11:
                relationExactEntry(file: "main.rs", byteOffset: 20)
            default:
                nil
            }
        }
    )
    model.updateProjectState(.ready(fixture.session, fixture.context))

    model.setRoot(symbol: fixture.a, direction: .calls)
    #expect(await relationWaitUntil { relationTreeFinishedLoading(model.root) })

    let exact = try relationGroup("Exact", in: model.root)
    let strong = try relationGroup("Strong", in: model.root)
    let probable = try relationGroup("Probable", in: model.root)
    #expect(exact.children?.map(\.title) == ["matching"])
    #expect(strong.children?.map(\.title) == ["strong"])
    #expect(probable.children?.map(\.title) == ["no exact"])
    let external = model.root?.children?.first {
        $0.kind == .group && $0.title == "External / Unresolved"
    }
    let externalEdge = external?.children?.first
    #expect(external != nil)
    #expect(externalEdge?.title == "external")
    #expect(externalEdge?.subtitle == "External · in dependency (rust-analyzer)")
    #expect(externalEdge?.target?.path == "main.rs")
    #expect(externalEdge?.target?.byteOffset == 10)
    #expect(externalEdge?.children?.map(\.title) == ["method name match"])
}

@MainActor
@Test
func contextAndRelationsShareTheDependencyPathConvention() async throws {
    let fixture = try RelationFixture()
    defer { fixture.remove() }
    let dependency = exactDependencyFixture()
    let dependencySource = try String(contentsOf: dependency, encoding: .utf8)
    let dependencyRange = try #require(
        dependencySource.range(of: "dependency_target")
    )
    let dependencyOffset = UInt32(
        dependencySource[..<dependencyRange.lowerBound].utf8.count
    )
    let contextModel = ContextWindowModel(
        { session, file, offset, context in
            try session.resolve(file: file, offset: offset, context: context)
        },
        exactResolver: { _, _, _ in
            relationExactEntry(
                file: dependency.path,
                byteOffset: dependencyOffset
            )
        }
    )
    contextModel.updateProjectState(
        .ready(fixture.session, fixture.context),
        root: fixture.root
    )
    contextModel.tokenClicked(file: "main.rs", offset: 9)
    #expect(await relationWaitUntil {
        contextModel.selectedCandidate?.path == dependency.path
    })

    let methodName = fixture.session.names.intern("method")
    let relationModel = RelationTreeModel(
        loader: { _, _, _, _ in
            .init(edges: [
                RelationTreeModel.LoadedEdge(
                    title: "external",
                    certainty: .possible,
                    dispatch: .dynamicDispatch,
                    symbol: fixture.b,
                    path: "main.rs",
                    byteOffset: 9,
                    line: 1,
                    evidence: [.methodNameOnly(nameID: methodName)],
                    exactQuery: ("main.rs", 9, 1),
                    fuzzyTarget: ("main.rs", 20)
                ),
            ], isTruncated: false)
        },
        exactResolver: { _, _, _ in
            relationExactEntry(
                file: dependency.path,
                byteOffset: dependencyOffset
            )
        }
    )
    relationModel.updateProjectState(.ready(fixture.session, fixture.context))
    relationModel.setRoot(symbol: fixture.a, direction: .calls)
    #expect(await relationWaitUntil {
        relationTreeFinishedLoading(relationModel.root)
    })
    let external = try relationGroup(
        "External / Unresolved",
        in: relationModel.root
    )

    #expect(exactLocationIsInDependency(dependency.path))
    #expect(contextModel.selectedCandidate?.label == "External · in dependency")
    #expect(
        external.children?.first?.subtitle
            == "External · in dependency (rust-analyzer)"
    )
}

@MainActor
@Test
func relationTreeShowsExternalCallsAsUnresolved() async throws {
    let root = try relationTemporaryProject([
        "main.rs": """
            struct Client;
            struct Service { client: Client }
            impl Service {
                fn root(&self) {
                    self.client.post();
                    tokio::spawn(async {});
                }
            }
            """,
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try ProjectIndexer().index(root: root)
    let context = relationQueryContext(for: session)
    let symbol = try #require(
        session.definitions(of: "root", context: context).first?.0
    )
    let model = RelationTreeModel()
    model.updateProjectState(.ready(session, context))

    model.setRoot(symbol: symbol, direction: .calls)
    #expect(await relationWaitUntil { relationTreeFinishedLoading(model.root) })

    let external = try relationGroup("External / Unresolved", in: model.root)
    #expect(external.children?.map(\.title) == ["post", "spawn"])
    #expect(external.children?.allSatisfy { $0.subtitle == "Unresolved" } == true)
}

@MainActor
@Test
func relationTreeShowsEmptyExternalCallsGroupForSignatureOnlyTrait() async throws {
    let root = try relationTemporaryProject([
        "main.rs": """
            trait Backend {
                fn get_completion(&self) -> String;
            }
            """,
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try ProjectIndexer().index(root: root)
    let context = relationQueryContext(for: session)
    let symbol = try #require(
        session.definitions(of: "Backend", context: context).first?.0
    )
    let model = RelationTreeModel()
    model.updateProjectState(.ready(session, context))

    model.setRoot(symbol: symbol, direction: .calls)
    #expect(await relationWaitUntil { relationTreeFinishedLoading(model.root) })

    let external = try relationGroup("External / Unresolved (0)", in: model.root)
    #expect(external.children?.isEmpty == true)
}

@MainActor
@Test
func selectedRelationSymbolDrivesRootAndUnresolvedFallsBack() async throws {
    let fixture = try RelationFixture()
    defer { fixture.remove() }
    let edges = [
        RelationTreeModel.LoadedEdge(
            title: "b",
            certainty: .strong,
            dispatch: .direct,
            symbol: fixture.b,
            path: "main.rs",
            byteOffset: 15,
            line: 1,
            evidence: []
        ),
        RelationTreeModel.LoadedEdge(
            title: "external",
            certainty: .unresolved,
            dispatch: .direct,
            symbol: nil,
            path: "main.rs",
            byteOffset: 10,
            line: 1,
            evidence: []
        ),
    ]
    let model = RelationTreeModel(loader: { _, _, _, _ in
        .init(edges: edges, isTruncated: false)
    })
    model.updateProjectState(.ready(fixture.session, fixture.context))

    model.setRoot(symbol: fixture.a, direction: .calls)
    #expect(await relationWaitUntil { relationTreeFinishedLoading(model.root) })
    let strong = try relationGroup("Strong", in: model.root)
    let symbolEdge = try #require(strong.children?.first)
    model.select(symbolEdge)
    let generation = model.generation

    model.setRoot(
        symbol: model.selectedRelationSymbol ?? fixture.a,
        direction: .callers
    )
    #expect(await relationWaitUntil { relationTreeFinishedLoading(model.root) })
    #expect(model.root?.title == "b")
    #expect(model.generation > generation)

    model.setRoot(symbol: fixture.a, direction: .calls)
    #expect(await relationWaitUntil { relationTreeFinishedLoading(model.root) })
    let external = try relationGroup("External / Unresolved", in: model.root)
    let unresolvedEdge = try #require(external.children?.first)
    model.select(unresolvedEdge)
    #expect(model.selectedRelationSymbol == nil)

    model.setRoot(
        symbol: model.selectedRelationSymbol ?? fixture.a,
        direction: .callers
    )
    #expect(await relationWaitUntil { relationTreeFinishedLoading(model.root) })
    #expect(model.root?.title == "a")
}

@MainActor
@Test
func clearingRelationSelectionDoesNotNotifyContext() async throws {
    let fixture = try RelationFixture()
    defer { fixture.remove() }
    let edge = RelationTreeModel.LoadedEdge(
        title: "b",
        certainty: .strong,
        dispatch: .direct,
        symbol: fixture.b,
        path: "main.rs",
        byteOffset: 15,
        line: 1,
        evidence: []
    )
    let model = RelationTreeModel(loader: { _, _, _, _ in
        .init(edges: [edge], isTruncated: false)
    })
    model.updateProjectState(.ready(fixture.session, fixture.context))
    model.setRoot(symbol: fixture.a, direction: .calls)
    #expect(await relationWaitUntil { relationTreeFinishedLoading(model.root) })
    let strong = try relationGroup("Strong", in: model.root)
    let child = try #require(strong.children?.first)
    var selectedTitles: [String] = []
    model.onSelect = { selectedTitles.append($0.title) }
    model.select(child)
    let selectedBeforeClear = model.selectedRelationSymbol

    model.clearSelection()

    #expect(
        selectedBeforeClear == fixture.b
            && model.selectedRelationSymbol == nil
            && selectedTitles == ["b"]
    )
}

@MainActor
@Test
func relationTreeShowsAnErrorRowWhenLoadingFails() async throws {
    let fixture = try RelationFixture()
    defer { fixture.remove() }
    let model = RelationTreeModel(loader: { _, _, _, _ in
        throw RelationTestError.expected
    })
    model.updateProjectState(.ready(fixture.session, fixture.context))

    model.setRoot(symbol: fixture.a, direction: .calls)
    #expect(await relationWaitUntil { relationTreeFinishedLoading(model.root) })

    #expect(model.root?.children?.first?.kind == .error)
    #expect(model.root?.children?.first?.title == "Could not load relations.")
}

@MainActor
@Test
func relationTreeShowsIndexBuildingPlaceholder() {
    let model = RelationTreeModel()

    model.updateProjectState(.indexing(
        root: URL(fileURLWithPath: "/tmp/project"),
        startedAt: .now
    ))

    #expect(model.root?.kind == .loading)
    #expect(model.root?.title == "Index building…")
}

@MainActor
@Test
func relationTreeMarksPathLocalCallerCycle() async throws {
    let root = try relationTemporaryProject([
        "main.rs": "fn a() { b(); }\nfn b() { a(); }",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try ProjectIndexer().index(root: root)
    let context = relationQueryContext(for: session)
    let symbol = try #require(
        session.definitions(of: "a", context: context).first?.0
    )
    let model = RelationTreeModel()
    model.updateProjectState(.ready(session, context))

    model.setRoot(symbol: symbol, direction: .callers)
    #expect(await relationWaitUntil { relationTreeFinishedLoading(model.root) })
    let firstStrong = try relationGroup("Strong", in: model.root)
    let callerB = try #require(firstStrong.children?.first { $0.title == "b" })

    await model.expand(callerB)
    let secondStrong = try relationGroup("Strong", in: callerB)
    let callerA = try #require(secondStrong.children?.first { $0.title == "a" })

    #expect(callerA.badge == "↻")
    #expect(!callerA.isExpandable)
}

@MainActor
@Test
func relationTreeLoadsTraitImplementationsAndMethodOverrides() async throws {
    let root = try relationTemporaryProject([
        "main.rs": """
            trait Render { fn render(&self); }
            struct View;
            impl Render for View { fn render(&self) {} }
            """,
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try ProjectIndexer().index(root: root)
    let context = relationQueryContext(for: session)
    let trait = try #require(
        session.definitions(of: "Render", context: context).first
    )
    let index = try #require(relationContentIndex(at: trait.2, in: session))
    let methodIndex = try #require(index.symbols.firstIndex {
        $0.kind == .rustMethod && $0.parentFacetIndex == trait.0.localIndex
    })
    let method = SymbolOccurrenceID(
        snapshotID: session.snapshotID,
        pathID: trait.2,
        localKind: .declarationFacet,
        localIndex: UInt32(methodIndex)
    )
    let model = RelationTreeModel()
    model.updateProjectState(.ready(session, context))

    model.setRoot(symbol: trait.0, direction: .implementations)
    #expect(await relationWaitUntil { relationTreeFinishedLoading(model.root) })
    let implementations = try relationGroup("Strong", in: model.root)
    #expect(implementations.children?.map(\.title) == ["View"])
    #expect(implementations.children?.first?.subtitle == "Strong · trait")

    model.setRoot(symbol: method, direction: .implementations)
    #expect(await relationWaitUntil { relationTreeFinishedLoading(model.root) })
    let overrides = try relationGroup("Strong", in: model.root)
    #expect(overrides.children?.map(\.title) == ["render"])
    #expect(overrides.children?.first?.subtitle == "Strong · trait")
}

@MainActor
@Test
func relationTreeExpandIsIdempotentWhileLoading() async throws {
    let fixture = try RelationFixture()
    defer { fixture.remove() }
    let fake = FakeRelationLoader(
        responses: [fixture.a: .init(edges: [], isTruncated: false)],
        gated: [fixture.a]
    )
    let model = RelationTreeModel(loader: fake.load)
    model.updateProjectState(.ready(fixture.session, fixture.context))

    model.setRoot(symbol: fixture.a, direction: .calls)
    #expect(model.root?.children?.first?.kind == .loading)
    #expect(await relationWaitUntil { await fake.isPending(fixture.a) })
    let root = try #require(model.root)
    await model.expand(root)
    await model.expand(root)

    #expect(await fake.count(for: fixture.a) == 1)
    await fake.release(fixture.a)
    #expect(await relationWaitUntil { relationTreeFinishedLoading(model.root) })
}

@MainActor
@Test
func relationTreeDiscardsLateResultAfterChangingRoot() async throws {
    let fixture = try RelationFixture()
    defer { fixture.remove() }
    let oldEdge = RelationTreeModel.LoadedEdge(
        title: "stale",
        certainty: .strong,
        dispatch: .direct,
        symbol: fixture.b,
        path: "main.rs",
        byteOffset: 0,
        line: 1,
        evidence: []
    )
    let newEdge = RelationTreeModel.LoadedEdge(
        title: "fresh",
        certainty: .strong,
        dispatch: .direct,
        symbol: fixture.a,
        path: "main.rs",
        byteOffset: 0,
        line: 1,
        evidence: []
    )
    let fake = FakeRelationLoader(
        responses: [
            fixture.a: .init(edges: [oldEdge], isTruncated: false),
            fixture.b: .init(edges: [newEdge], isTruncated: false),
        ],
        gated: [fixture.a]
    )
    let model = RelationTreeModel(loader: fake.load)
    model.updateProjectState(.ready(fixture.session, fixture.context))

    model.setRoot(symbol: fixture.a, direction: .calls)
    #expect(await relationWaitUntil { await fake.isPending(fixture.a) })
    model.setRoot(symbol: fixture.b, direction: .calls)
    #expect(await relationWaitUntil {
        model.root?.children?.first {
            $0.kind == .group && $0.title == "Strong"
        }?.children?.first?.title == "fresh"
    })
    await fake.release(fixture.a)
    for _ in 0..<10 { await Task.yield() }

    #expect(model.root?.title == "b")
    #expect(try relationGroup("Strong", in: model.root).children?.first?.title == "fresh")
}

@MainActor
@Test
func relationTreeCapsEachExpansionAtFiveHundredEdges() async throws {
    let fixture = try RelationFixture()
    defer { fixture.remove() }
    let edges = (0...500).map {
        RelationTreeModel.LoadedEdge(
            title: "edge-\($0)",
            certainty: .strong,
            dispatch: .direct,
            symbol: nil,
            path: "main.rs",
            byteOffset: UInt32($0),
            line: 1,
            evidence: []
        )
    }
    let fake = FakeRelationLoader(
        responses: [fixture.a: .init(edges: edges, isTruncated: false)]
    )
    let model = RelationTreeModel(loader: fake.load)
    model.updateProjectState(.ready(fixture.session, fixture.context))

    model.setRoot(symbol: fixture.a, direction: .callers)
    #expect(await relationWaitUntil { relationTreeFinishedLoading(model.root) })

    let strong = try relationGroup("Strong", in: model.root)
    #expect(strong.children?.count == 500)
    #expect(model.root?.children?.last?.kind == .truncated)
    #expect(model.hasTruncatedResults)
}

@MainActor
@Test
func relationTreeRendersEvidenceLinesAtTheEndAndSelectsByIdentity() async throws {
    let fixture = try RelationFixture()
    defer { fixture.remove() }
    let edge = RelationTreeModel.LoadedEdge(
        title: "b",
        certainty: .strong,
        dispatch: .direct,
        symbol: fixture.b,
        path: "main.rs",
        byteOffset: 15,
        line: 1,
        evidence: [
            .sameFile(pathID: fixture.a.pathID),
            .uniqueImport(importBindingIndex: 3),
            .lexicalBinding(bindingIndex: 4),
            .nameOnly(nameID: fixture.session.names.intern("b")),
            .methodNameOnly(nameID: fixture.session.names.intern("method")),
            .receiverType(nameID: fixture.session.names.intern("Receiver")),
        ]
    )
    let fake = FakeRelationLoader(responses: [
        fixture.a: .init(edges: [edge], isTruncated: false),
        fixture.b: .init(edges: [], isTruncated: false),
    ])
    let model = RelationTreeModel(loader: fake.load)
    model.updateProjectState(.ready(fixture.session, fixture.context))
    model.setRoot(symbol: fixture.a, direction: .calls)
    #expect(await relationWaitUntil { relationTreeFinishedLoading(model.root) })
    let strong = try relationGroup("Strong", in: model.root)
    let child = try #require(strong.children?.first)

    await model.expand(child)
    let evidenceSnapshot = child.children?
        .filter { $0.kind == .evidenceLine }
        .map(\.title)
        .joined(separator: "\n")
    #expect(evidenceSnapshot == """
        same file
        via import
        lexical binding
        name match
        method name match
        receiver type
        """)
    #expect(child.children?.suffix(6).allSatisfy { $0.kind == .evidenceLine } == true)

    var selected: RelationTreeModel.Node?
    model.onSelect = { selected = $0 }
    model.select(child)
    #expect(selected === child)
}

private enum RelationTestError: Error {
    case expected
}

private actor FakeRelationLoader {
    private let responses: [SymbolOccurrenceID: RelationTreeModel.LoadResult]
    private var gated: Set<SymbolOccurrenceID>
    private var continuations: [
        SymbolOccurrenceID: CheckedContinuation<Void, Never>
    ] = [:]
    private var counts: [SymbolOccurrenceID: Int] = [:]

    init(
        responses: [SymbolOccurrenceID: RelationTreeModel.LoadResult],
        gated: Set<SymbolOccurrenceID> = []
    ) {
        self.responses = responses
        self.gated = gated
    }

    func load(
        session: EngineSession,
        context: QueryContext,
        symbol: SymbolOccurrenceID,
        direction: RelationTreeModel.Direction
    ) async throws -> RelationTreeModel.LoadResult {
        counts[symbol, default: 0] += 1
        if gated.contains(symbol) {
            await withCheckedContinuation { continuations[symbol] = $0 }
        }
        return responses[symbol] ?? .init(edges: [], isTruncated: false)
    }

    func count(for symbol: SymbolOccurrenceID) -> Int {
        counts[symbol, default: 0]
    }

    func isPending(_ symbol: SymbolOccurrenceID) -> Bool {
        continuations[symbol] != nil
    }

    func release(_ symbol: SymbolOccurrenceID) {
        gated.remove(symbol)
        continuations.removeValue(forKey: symbol)?.resume()
    }
}

private struct RelationFixture {
    let root: URL
    let session: EngineSession
    let context: QueryContext
    let a: SymbolOccurrenceID
    let b: SymbolOccurrenceID

    init() throws {
        root = try relationTemporaryProject([
            "main.rs": "fn a() { b(); }\nfn b() {}",
        ])
        session = try ProjectIndexer().index(root: root)
        context = relationQueryContext(for: session)
        a = try #require(session.definitions(of: "a", context: context).first?.0)
        b = try #require(session.definitions(of: "b", context: context).first?.0)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private func relationWaitUntil(
    _ condition: @escaping @MainActor () async -> Bool
) async -> Bool {
    for _ in 0..<200 {
        if await condition() { return true }
        await Task.yield()
    }
    return false
}

@MainActor
private func relationTreeFinishedLoading(_ root: RelationTreeModel.Node?) -> Bool {
    guard let children = root?.children else { return false }
    return !children.contains { $0.kind == .loading }
}

@MainActor
private func relationGroup(
    _ title: String,
    in parent: RelationTreeModel.Node?
) throws -> RelationTreeModel.Node {
    try #require(parent?.children?.first {
        $0.kind == .group && $0.title == title
    })
}

private func relationTemporaryProject(_ files: [String: String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RelationTreeModelTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for (path, contents) in files {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: file, atomically: true, encoding: .utf8)
    }
    return root
}

private func relationQueryContext(for session: EngineSession) -> QueryContext {
    QueryContext(
        snapshotID: session.snapshotID,
        analysisProfileID: session.analysisProfile.id,
        generation: 1
    )
}

private func relationContentIndex(
    at pathID: PathID,
    in session: EngineSession
) -> ContentIndex? {
    guard let file = session.manifest.files.first(where: { $0.pathID == pathID })
    else { return nil }
    return session.contentIndexes.first {
        $0.key.contentID == file.contentID
            && $0.key.languageMode.language == file.detectedLanguage
    }?.value
}

private func relationExactEntry(
    file: String,
    byteOffset: UInt32,
    origin: ExactOrigin = .worktree
) -> ExactOverlay.Entry {
    ExactOverlay.Entry(
        location: ExactLocation(
            file: file,
            byteOffset: Int(byteOffset),
            line: 1,
            column: Int(byteOffset) + 1
        ),
        attribution: ExactAttribution(
            provider: "fake-exact",
            toolVersion: "fake-1",
            configFingerprint: "config",
            environmentFingerprint: "environment",
            trustMode: .safe,
            generatedAt: Date(timeIntervalSince1970: 0),
            coverage: .partial
        ),
        origin: origin
    )
}
