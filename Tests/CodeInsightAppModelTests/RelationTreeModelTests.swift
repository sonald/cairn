import CodeInsightCore
import CodeInsightEngine
import CodeInsightExact
import CodeInsightGit
import CodeInsightReaderCore
import Foundation
import Testing
@testable import CodeInsightAppModel

@MainActor
@Test
func relationTreeShowsSemanticLocalReferencesWithoutTheDeclaration() throws {
    let source = """
        fn f(x: i32) {
            x;
            let y = x;
        }
        """
    let root = try relationTemporaryProject(["main.rs": source])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try ProjectIndexer().index(root: root)
    let context = relationQueryContext(for: session)
    let file = root.appendingPathComponent("main.rs")
    let document = try DocumentLoader().load(file: file).document
    let ranges = relationTokenRanges(of: "x", in: source)
    let binding = try #require(document.localBinding(at: ranges[0].lowerBound))
    let pathID = try #require(session.manifest.files.first {
        session.paths.resolve($0.pathID) == "main.rs"
    }?.pathID)
    let bindingIndex = try #require(UInt32(exactly: binding.bindingIndex))
    let model = RelationTreeModel()
    model.updateProjectState(.ready(session, context))

    model.setRoot(
        target: .localBinding(
            pathID: pathID,
            bindingIndex: bindingIndex
        ),
        direction: .references,
        document: document
    )

    let references = try relationGroup("References (2)", in: model.root)
    #expect(model.root?.subtitle == "Parameter")
    #expect(references.children?.compactMap { $0.target?.byteOffset }
        == [ranges[1].lowerBound, ranges[2].lowerBound])
    #expect(references.children?.contains {
        $0.target?.byteOffset == binding.binding.declarationRange.lowerBound
    } == false)
}

@MainActor
@Test
func relationTreeLocalReferencesSeparateNestedShadowing() throws {
    let source = """
        fn f() {
            let x = 0;
            x;
            {
                let x = x + 1;
                x;
            }
            x;
        }
        """
    let outer = try relationReferenceResult(
        source: source,
        token: "x",
        declarationIndex: 0
    )
    let inner = try relationReferenceResult(
        source: source,
        token: "x",
        declarationIndex: 2
    )

    #expect(outer.offsets == [1, 3, 5].map {
        outer.tokenRanges[$0].lowerBound
    })
    #expect(inner.offsets == [inner.tokenRanges[4].lowerBound])
}

@MainActor
@Test
func relationTreeLocalReferencesSeparateSiblingScopes() throws {
    let source = """
        fn first() {
            let x = 0;
            x;
        }
        fn second() {
            let x = 1;
            x;
        }
        """
    let first = try relationReferenceResult(
        source: source,
        token: "x",
        declarationIndex: 0
    )
    let second = try relationReferenceResult(
        source: source,
        token: "x",
        declarationIndex: 2
    )

    #expect(first.offsets == [first.tokenRanges[1].lowerBound])
    #expect(second.offsets == [second.tokenRanges[3].lowerBound])
}

@MainActor
@Test
func relationTreeLocalReferencesExcludeTokensBeforeTheDeclaration() throws {
    let source = """
        fn f() {
            x();
            let x = || {};
            x();
        }
        """
    let result = try relationReferenceResult(
        source: source,
        token: "x",
        declarationIndex: 1
    )

    #expect(result.offsets == [result.tokenRanges[2].lowerBound])
    #expect(!result.offsets.contains(result.tokenRanges[0].lowerBound))
    #expect(!result.offsets.contains(result.declarationOffset))
}

@MainActor
@Test
func relationTreeLocalReferencesDistinguishParameterFromShadowingLocal() throws {
    let source = """
        fn f(x: i32) {
            x;
            let x = x + 1;
            x;
        }
        """
    let parameter = try relationReferenceResult(
        source: source,
        token: "x",
        declarationIndex: 0
    )
    let local = try relationReferenceResult(
        source: source,
        token: "x",
        declarationIndex: 2
    )

    #expect(parameter.subtitle == "Parameter")
    #expect(parameter.offsets == [1, 3].map {
        parameter.tokenRanges[$0].lowerBound
    })
    #expect(local.subtitle == "Local")
    #expect(local.offsets == [local.tokenRanges[4].lowerBound])
}

@MainActor
@Test
func relationTreeEngineReferencesFindCrossFileTypeUses() async throws {
    let root = try relationTemporaryProject([
        "Cargo.toml": """
            [package]
            name = "reference-safe-offline"
            version = "0.1.0"

            [dependencies]
            codeinsight-definitely-missing-offline-dependency = "99.99.99"
            """,
        "a.rs": "pub struct Foo { value: i32 }\n",
        "b.rs": """
            use crate::a::Foo;
            struct Holder<T>(T);
            fn make() -> Foo {
                let typed: Foo = Foo { value: 1 };
                let generic: Holder<Foo> = Holder(typed);
                generic.0
            }
            """,
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try ProjectIndexer().index(root: root)
    let context = relationQueryContext(for: session)
    let symbol = try #require(
        session.definitions(of: "Foo", context: context).first?.0
    )
    let model = RelationTreeModel()
    model.updateProjectState(.ready(session, context))

    let task = model.setRoot(target: .engine(symbol), direction: .references)
    await task?.value

    if case .safe = session.analysisProfile.trustMode {} else {
        Issue.record("Fuzzy references fixture must stay in Safe/offline mode")
    }
    let references = try relationGroup("References", in: model.root)
    #expect(references.children?.count == 5)
    #expect(Set(references.children?.compactMap { $0.target?.path } ?? []) == ["b.rs"])
    #expect(references.subtitle == "5 references")
    #expect(model.root?.children?.contains {
        $0.title == "Exact unavailable: no exact session"
    } == true)
}

@MainActor
@Test
func relationTreeConsumesExactReferences() async throws {
    let fixture = try RelationFixture()
    defer { fixture.remove() }
    let exactLocation = relationExactLocation(
        file: "/dependency/src/lib.rs",
        offset: 12
    )
    let model = RelationTreeModel(
        loader: { _, _, _, _ in
            .init(edges: [], isTruncated: false)
        },
        exactRelationsResolver: { _, _, _, direction, _ in
            #expect(direction == .references)
            return .relations([
                .init(
                    name: nil,
                    location: exactLocation,
                    item: nil,
                    callSites: []
                ),
            ], origin: .worktree, coverage: .full)
        }
    )
    model.updateProjectState(.ready(fixture.session, fixture.context))

    await model.setRoot(
        target: .engine(fixture.a),
        direction: .references
    )?.value

    let exact = try relationGroup("Exact (1)", in: model.root)
    #expect(exact.children?.map { $0.target?.path } == [exactLocation.file])
    #expect(exact.children?.map { $0.target?.byteOffset } == [12])
}

@MainActor
@Test
func relationTreeReferenceMergeKeepsAllThreeEvidenceCases() async throws {
    let fixture = try RelationFixture()
    defer { fixture.remove() }
    let overlap = relationExactLocation(file: "main.rs", offset: 10)
    let exactOnly = relationExactLocation(file: "exact-only.rs", offset: 30)
    let fuzzyOnly = RelationTreeModel.LoadedEdge(
        title: "fuzzy-only",
        certainty: .possible,
        dispatch: .direct,
        symbol: nil,
        path: "fuzzy-only.rs",
        byteOffset: 20,
        line: 1,
        evidence: []
    )
    let model = RelationTreeModel(
        loader: { _, _, _, _ in
            .init(edges: [
                .init(
                    title: "overlap",
                    certainty: .possible,
                    dispatch: .direct,
                    symbol: nil,
                    path: overlap.file,
                    byteOffset: UInt32(overlap.byteOffset),
                    line: 1,
                    evidence: []
                ),
                fuzzyOnly,
            ], isTruncated: false)
        },
        exactRelationsResolver: { _, _, _, _, _ in
            .relations([
                .init(
                    name: nil,
                    location: overlap,
                    item: nil,
                    callSites: []
                ),
                .init(
                    name: nil,
                    location: exactOnly,
                    item: nil,
                    callSites: []
                ),
            ], origin: .worktree, coverage: .full)
        }
    )
    model.updateProjectState(.ready(fixture.session, fixture.context))

    await model.setRoot(
        target: .engine(fixture.a),
        direction: .references
    )?.value

    let rows = relationVisibleEdgeRows(model.root)
    #expect(rows.count == 3)
    #expect(rows.filter {
        $0.target?.path == overlap.file
            && $0.target?.byteOffset == UInt32(overlap.byteOffset)
            && $0.subtitle == "Exact · heuristic also matched"
    }.count == 1)
    #expect(rows.contains {
        $0.target?.path == exactOnly.file
            && $0.target?.byteOffset == UInt32(exactOnly.byteOffset)
            && $0.badge == "Exact · lsp"
    } == true)
    #expect(rows.contains {
        $0.target?.path == fuzzyOnly.path
            && $0.target?.byteOffset == fuzzyOnly.byteOffset
            && $0.badge == nil
    } == true)
}

@MainActor
@Test
func relationTreeFuzzyReferencesExcludeOnlyTheDeclarationRange() async throws {
    let source = "pub struct Foo;\nfn use_it(_: Foo) {}\n"
    let root = try relationTemporaryProject(["main.rs": source])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try ProjectIndexer().index(root: root)
    let context = relationQueryContext(for: session)
    let symbol = try #require(
        session.definitions(of: "Foo", context: context).first?.0
    )
    let ranges = relationTokenRanges(of: "Foo", in: source)
    let model = RelationTreeModel()
    model.updateProjectState(.ready(session, context))

    await model.setRoot(
        target: .engine(symbol),
        direction: .references
    )?.value

    let fuzzy = try relationGroup("References", in: model.root)
    #expect(fuzzy.children?.map { $0.target?.byteOffset }
        == [ranges[1].lowerBound])
    #expect(fuzzy.children?.contains {
        $0.target?.byteOffset == ranges[0].lowerBound
    } == false)
}

@MainActor
@Test
func relationTreeLocalReferencesDoNotMixSameNamedBindingsAcrossFiles() throws {
    let source = "fn a() { let local = 1; local; }\n"
    let root = try relationTemporaryProject([
        "a.rs": source,
        "b.rs": "fn b() { let local = 2; local; }\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try ProjectIndexer().index(root: root)
    let context = relationQueryContext(for: session)
    let document = try DocumentLoader().load(
        file: root.appendingPathComponent("a.rs")
    ).document
    let ranges = relationTokenRanges(of: "local", in: source)
    let binding = try #require(document.localBinding(at: ranges[0].lowerBound))
    let file = try #require(session.manifest.files.first {
        session.paths.resolve($0.pathID) == "a.rs"
    })
    let model = RelationTreeModel()
    model.updateProjectState(.ready(session, context))

    model.setRoot(
        target: .localBinding(
            pathID: file.pathID,
            bindingIndex: UInt32(binding.bindingIndex)
        ),
        direction: .references,
        document: document
    )

    let references = try relationGroup("References (1)", in: model.root)
    #expect(references.children?.map { $0.target?.path } == ["a.rs"])
    #expect(references.children?.map { $0.target?.byteOffset }
        == [ranges[1].lowerBound])
}

@MainActor
@Test
func relationTreeLocalReferencesSeparateDisplayCapFromTrueTotal() throws {
    let source =
        "fn f(x: i32) {\n"
        + String(repeating: "    x;\n", count: 501)
        + "}\n"
    let result = try relationReferenceResult(
        source: source,
        token: "x",
        declarationIndex: 0
    )

    #expect(result.offsets.count == 500)
    #expect(result.footerTitle == "Showing first 500 of 501 references")
}

@MainActor
@Test
func relationTreeProjectReferenceCountCopyKeepsThreeCompletenessStates()
    async throws
{
    let fixture = try RelationFixture()
    defer { fixture.remove() }

    let complete = try await relationProjectReferenceStatus(
        fixture: fixture,
        edgeCount: 2,
        isTruncated: false,
        exactCount: 1
    )
    let displayCap = try await relationProjectReferenceStatus(
        fixture: fixture,
        edgeCount: 500,
        isTruncated: false,
        exactCount: 1
    )
    let servicePartial = try await relationProjectReferenceStatus(
        fixture: fixture,
        edgeCount: 7,
        isTruncated: true,
        exactCount: 1
    )

    #expect(complete.referenceSubtitle == "2 references")
    #expect(complete.footerTitle == nil)
    #expect(displayCap.referenceSubtitle == nil)
    #expect(displayCap.footerTitle == "Showing first 500 of 501 references")
    #expect(servicePartial.referenceSubtitle == nil)
    #expect(servicePartial.footerTitle == "8 verified references · partial")
    #expect(servicePartial.footerTitle?.contains(" of ") == false)
    #expect(servicePartial.footerTitle?.contains("999") == false)
}

@MainActor
@Test
func relationTreeCompleteReferenceCountsStayWithinEachSource() async throws {
    let fixture = try RelationFixture()
    defer { fixture.remove() }

    let fuzzyOnly = try await relationProjectReferenceStatus(
        fixture: fixture,
        edgeCount: 2,
        isTruncated: false
    )
    let exactOnly = try await relationProjectReferenceStatus(
        fixture: fixture,
        edgeCount: 0,
        isTruncated: false,
        exactCount: 2
    )
    let mixed = try await relationProjectReferenceStatus(
        fixture: fixture,
        edgeCount: 1,
        isTruncated: false,
        exactCount: 2
    )

    #expect(fuzzyOnly.exactTitle == "Exact (0): no references")
    #expect(fuzzyOnly.exactRowCount == 0)
    #expect(fuzzyOnly.referenceSubtitle == "2 references")
    #expect(fuzzyOnly.referenceRowCount == 2)

    #expect(exactOnly.exactTitle == "Exact (2)")
    #expect(exactOnly.exactRowCount == 2)
    #expect(exactOnly.referenceSubtitle == "0 references")
    #expect(exactOnly.referenceRowCount == 0)

    #expect(mixed.exactTitle == "Exact (2)")
    #expect(mixed.exactRowCount == 2)
    #expect(mixed.referenceSubtitle == "1 references")
    #expect(mixed.referenceRowCount == 1)
    let mixedExactDisplayedCount = Int(
        mixed.exactTitle.dropFirst("Exact (".count).prefix { $0.isNumber }
    )
    let mixedReferenceDisplayedCount = Int(
        mixed.referenceSubtitle?.prefix { $0.isNumber } ?? ""
    )
    #expect(mixedExactDisplayedCount == mixed.exactRowCount)
    #expect(mixedReferenceDisplayedCount == mixed.referenceRowCount)
    #expect(mixedExactDisplayedCount != mixed.exactRowCount + mixed.referenceRowCount)
    #expect(mixedReferenceDisplayedCount != mixed.exactRowCount + mixed.referenceRowCount)
}

@MainActor
@Test
func relationTreeProjectReferencesReadHistoricalCommitSnapshot() async throws {
    let root = try relationTemporaryProject([
        "a.rs": "pub struct Historical;\n",
        "b.rs": "use crate::a::Historical;\nfn use_it(_: Historical) {}\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    try relationGit(root, "init", "-q")
    try relationGit(root, "add", ".")
    try relationGit(
        root,
        "-c", "user.name=CodeInsight",
        "-c", "user.email=codeinsight@example.com",
        "commit", "-q", "-m", "historical references"
    )
    let snapshot = try CommitSnapshot(repositoryURL: root)
    let session = try ProjectIndexer().indexSnapshot(
        snapshot,
        into: ProjectIndexStore()
    )
    let context = relationQueryContext(for: session)
    let symbol = try #require(
        session.definitions(of: "Historical", context: context).first?.0
    )
    let model = RelationTreeModel()
    model.updateProjectState(.ready(session, context))

    await model.setRoot(target: .engine(symbol), direction: .references)?.value

    #expect(session.manifest.files.filter {
        $0.detectedLanguage == .rust
    }.allSatisfy {
        if case .tracked = $0.sourceKind { return true }
        return false
    })
    let references = try relationGroup("References", in: model.root)
    #expect(references.children?.count == 2)
    #expect(Set(references.children?.compactMap { $0.target?.path } ?? []) == ["b.rs"])
}

@MainActor
@Test
func relationTreeConsumesExactCallersAndExpandsAnExactOnlyNode() async throws {
    let fixture = try RelationFixture()
    defer { fixture.remove() }
    try "[package]\nname='relation-test'\nversion='0.1.0'\n".write(
        to: fixture.root.appendingPathComponent("Cargo.toml"),
        atomically: true,
        encoding: .utf8
    )
    let session = RelationHierarchyExactSession()
    let coordinator = ExactCoordinator(
        providerFactory: { _ in RelationHierarchyExactProvider(session: session) },
        snapshotFactory: { _, _ in
            RelationExactSnapshot(files: [
                "Cargo.toml": "[package]\nname='relation-test'\nversion='0.1.0'\n",
                "main.rs": "fn a() {}\nfn b() {}\n",
            ])
        },
        sandboxAvailable: { true },
        trustRegistry: TrustRegistry(
            fileURL: fixture.root.appendingPathComponent("trust.json")
        )
    )
    coordinator.prepare(
        projectURL: fixture.root,
        revision: nil,
        generation: fixture.context.generation
    )
    #expect(await testWaitUntil("coordinator.readiness == .ready") { coordinator.readiness == .ready })
    let model = RelationTreeModel()
    model.attachExactCoordinator(coordinator)
    model.updateProjectState(.ready(fixture.session, fixture.context))

    model.setRoot(target: .engine(fixture.a), direction: .callers)
    #expect(await testWaitUntil("relationTreeFinishedLoading(model.root)") { relationTreeFinishedLoading(model.root) })
    let exact = try relationGroup("Exact (1)", in: model.root)
    let dependencyCaller = try #require(exact.children?.first)

    #expect(dependencyCaller.symbol == nil)
    #expect(dependencyCaller.isExpandable)
    await model.expand(dependencyCaller)
    let secondLevel = try relationGroup("Exact (1)", in: dependencyCaller)
    #expect(secondLevel.children?.map(\.title) == ["top_level_caller"])
}

@MainActor
@Test
func exactCoordinatorRequestsReferencesWithoutTheDeclaration() async throws {
    let fixture = try RelationFixture()
    defer { fixture.remove() }
    try "[package]\nname='relation-test'\nversion='0.1.0'\n".write(
        to: fixture.root.appendingPathComponent("Cargo.toml"),
        atomically: true,
        encoding: .utf8
    )
    let location = relationExactLocation(file: "main.rs", offset: 12)
    let session = RelationHierarchyExactSession(
        referenceLocations: [location]
    )
    let coordinator = ExactCoordinator(
        providerFactory: { _ in RelationHierarchyExactProvider(session: session) },
        snapshotFactory: { _, _ in
            RelationExactSnapshot(files: [
                "Cargo.toml": "[package]\nname='relation-test'\nversion='0.1.0'\n",
                "main.rs": "fn a() {}\nfn b() {}\n",
            ])
        },
        sandboxAvailable: { true },
        trustRegistry: TrustRegistry(
            fileURL: fixture.root.appendingPathComponent("trust.json")
        )
    )
    coordinator.prepare(
        projectURL: fixture.root,
        revision: nil,
        generation: fixture.context.generation
    )
    #expect(await testWaitUntil("coordinator.readiness == .ready") { coordinator.readiness == .ready })

    let result = await coordinator.relations(
        file: "main.rs",
        byteOffset: 3,
        item: nil,
        direction: .references,
        generation: fixture.context.generation
    )

    guard case let .relations(relations, _, coverage) = result else {
        Issue.record("expected exact references")
        return
    }
    #expect(relations.map(\.location) == [location])
    #expect(coverage == .full)
    #expect(session.referenceIncludeDeclarations == [false])
}

@MainActor
@Test
func relationTreeExactZeroCopyDistinguishesCoverage() async throws {
    let fixture = try RelationFixture()
    defer { fixture.remove() }

    func title(for coverage: ExactCoverage) async throws -> String {
        let session = RelationHierarchyExactSession(referenceLocations: [])
        let coordinator = try relationExactCoordinator(
            fixture: fixture,
            provider: RelationHierarchyExactProvider(
                session: session,
                coverage: coverage
            )
        )
        coordinator.prepare(
            projectURL: fixture.root,
            revision: nil,
            generation: fixture.context.generation
        )
        #expect(await testWaitUntil("coordinator.readiness == .ready && coordinator.coverage == coverage") {
            coordinator.readiness == .ready && coordinator.coverage == coverage
        })
        let model = RelationTreeModel()
        model.attachExactCoordinator(coordinator)
        model.updateProjectState(.ready(fixture.session, fixture.context))
        await model.setRoot(
            target: .engine(fixture.a),
            direction: .references
        )?.value
        let title = try #require(model.root?.children?.first {
            $0.kind == .group && $0.title.hasPrefix("Exact")
        }?.title)
        coordinator.shutdown()
        return title
    }

    let full = try await title(for: .full)
    let partial = try await title(for: .partial)
    let offline = try await title(for: .dependenciesUnavailableOffline)

    #expect(full == "Exact (0): no references")
    #expect(partial == "Exact incomplete (0 shown): partial coverage")
    #expect(offline == "Exact unavailable: deps unavailable (offline)")
    #expect(partial != "Exact (0): no references")
    #expect(offline != "Exact (0): no references")
    #expect(Set([full, partial, offline]).count == 3)
}

@MainActor
@Test
func relationTreeExactGroupsCountTheirOwnRowsInAllDirections() async throws {
    let fixture = try RelationFixture()
    defer { fixture.remove() }
    let traitRoot = try relationTemporaryProject([
        "main.rs": "trait Render { fn render(&self); }",
    ])
    defer { try? FileManager.default.removeItem(at: traitRoot) }
    let traitSession = try ProjectIndexer().index(root: traitRoot)
    let traitContext = relationQueryContext(for: traitSession)
    let trait = try #require(
        traitSession.definitions(of: "Render", context: traitContext).first?.0
    )
    let relations = [
        ExactCoordinator.Relation(
            name: "first",
            location: relationExactLocation(file: "first.rs", offset: 10),
            item: nil,
            callSites: []
        ),
        ExactCoordinator.Relation(
            name: "second",
            location: relationExactLocation(file: "second.rs", offset: 20),
            item: nil,
            callSites: []
        ),
    ]
    let cases: [
        (
            RelationTreeModel.Direction,
            EngineSession,
            QueryContext,
            SymbolOccurrenceID
        )
    ] = [
        (.callers, fixture.session, fixture.context, fixture.a),
        (.calls, fixture.session, fixture.context, fixture.a),
        (.implementations, traitSession, traitContext, trait),
        (.references, fixture.session, fixture.context, fixture.a),
    ]

    for (direction, session, context, symbol) in cases {
        let model = RelationTreeModel(
            loader: { _, _, _, _ in
                .init(edges: [], isTruncated: false)
            },
            exactRelationsResolver: { _, _, _, _, _ in
                .relations(relations, origin: .worktree, coverage: .full)
            }
        )
        model.updateProjectState(.ready(session, context))
        await model.setRoot(target: .engine(symbol), direction: direction)?.value
        let group = try #require(model.root?.children?.first {
            $0.kind == .group && $0.title.hasPrefix("Exact")
        })
        let displayedCount = group.title
            .dropFirst("Exact (".count)
            .prefix { $0.isNumber }
        #expect(Int(displayedCount) == group.children?.count)
    }
}

@MainActor
@Test
func exactCoordinatorDoesNotCallReferencesWithoutCapability() async throws {
    let fixture = try RelationFixture()
    defer { fixture.remove() }
    let session = RelationHierarchyExactSession()
    let coordinator = try relationExactCoordinator(
        fixture: fixture,
        provider: RelationHierarchyExactProvider(session: session)
    )
    coordinator.prepare(projectURL: fixture.root, revision: nil, generation: 1)
    #expect(await testWaitUntil("coordinator.readiness == .ready") { coordinator.readiness == .ready })

    let result = await coordinator.relations(
        file: "main.rs",
        byteOffset: 3,
        item: nil,
        direction: .references,
        generation: 1
    )

    let unsupported = if case .unsupported = result { true } else { false }
    #expect(unsupported)
    #expect(session.referenceIncludeDeclarations.isEmpty)
}

@MainActor
@Test
func exactCoordinatorDiscardsAStaleCallHierarchyResult() async throws {
    let fixture = try RelationFixture()
    defer { fixture.remove() }
    try "[package]\nname='relation-test'\nversion='0.1.0'\n".write(
        to: fixture.root.appendingPathComponent("Cargo.toml"),
        atomically: true,
        encoding: .utf8
    )
    let session = RelationHierarchyExactSession(blockIncoming: true)
    let coordinator = ExactCoordinator(
        providerFactory: { _ in RelationHierarchyExactProvider(session: session) },
        snapshotFactory: { _, _ in
            RelationExactSnapshot(files: [
                "Cargo.toml": "[package]\nname='relation-test'\nversion='0.1.0'\n",
                "main.rs": "fn a() {}\nfn b() {}\n",
            ])
        },
        sandboxAvailable: { true },
        trustRegistry: TrustRegistry(
            fileURL: fixture.root.appendingPathComponent("trust.json")
        )
    )
    coordinator.prepare(projectURL: fixture.root, revision: nil, generation: 1)
    #expect(await testWaitUntil("coordinator.readiness == .ready") { coordinator.readiness == .ready })

    let request = Task {
        await coordinator.relations(
            file: "main.rs",
            byteOffset: 3,
            item: nil,
            direction: .callers,
            generation: 1
        )
    }
    #expect(await testWaitUntil("session.incomingStarted") { session.incomingStarted })
    coordinator.invalidate(generation: 2)
    session.releaseIncoming()

    #expect(await request.value == nil)
    #expect(coordinator.readiness == .preparing)
}

@MainActor
@Test
func exactCoordinatorDiscardsCallHierarchyAfterSameGenerationTrustReprepare()
    async throws
{
    let fixture = try RelationFixture()
    defer { fixture.remove() }
    try "[package]\nname='relation-test'\nversion='0.1.0'\n".write(
        to: fixture.root.appendingPathComponent("Cargo.toml"),
        atomically: true,
        encoding: .utf8
    )
    let blocked = RelationHierarchyExactSession(blockIncoming: true)
    let replacement = RelationHierarchyExactSession()
    let provider = RelationRotatingExactProvider(
        sessions: [blocked, replacement]
    )
    let coordinator = ExactCoordinator(
        providerFactory: { _ in provider },
        snapshotFactory: { _, _ in
            RelationExactSnapshot(files: [
                "Cargo.toml": "[package]\nname='relation-test'\nversion='0.1.0'\n",
                "main.rs": "fn a() {}\nfn b() {}\n",
            ])
        },
        sandboxAvailable: { true },
        trustRegistry: TrustRegistry(
            fileURL: fixture.root.appendingPathComponent("trust.json")
        )
    )
    coordinator.prepare(projectURL: fixture.root, revision: nil, generation: 1)
    #expect(await testWaitUntil("coordinator.readiness == .ready && provider.prepareCount == 1") {
        coordinator.readiness == .ready && provider.prepareCount == 1
    })
    let request = Task {
        await coordinator.relations(
            file: "main.rs",
            byteOffset: 3,
            item: nil,
            direction: .callers,
            generation: 1
        )
    }
    #expect(await testWaitUntil("blocked.incomingStarted") { blocked.incomingStarted })

    coordinator.prepare(projectURL: fixture.root, revision: nil, generation: 1)
    #expect(await testWaitUntil("coordinator.readiness == .ready && provider.prepareCount == 2") {
        coordinator.readiness == .ready && provider.prepareCount == 2
    })
    blocked.releaseIncoming()

    #expect(await request.value == nil)
    #expect(coordinator.readiness == .ready)
}

@MainActor
@Test
func exactCoordinatorDiscardsReferencesAfterProfileSwitch() async throws {
    let fixture = try RelationFixture()
    defer { fixture.remove() }
    let blocked = RelationHierarchyExactSession(
        blockReferences: true,
        referenceLocations: [relationExactLocation(file: "stale.rs", offset: 1)]
    )
    let replacement = RelationHierarchyExactSession(
        referenceLocations: [relationExactLocation(file: "fresh.rs", offset: 2)]
    )
    let provider = RelationRotatingExactProvider(sessions: [blocked, replacement])
    let coordinator = try relationExactCoordinator(
        fixture: fixture,
        provider: provider
    )
    coordinator.prepare(projectURL: fixture.root, revision: nil, generation: 1)
    #expect(await testWaitUntil("coordinator.readiness == .ready") { coordinator.readiness == .ready })
    let request = Task {
        await coordinator.relations(
            file: "main.rs",
            byteOffset: 3,
            item: nil,
            direction: .references,
            generation: 1
        )
    }
    #expect(await testWaitUntil("blocked.referencesStarted") { blocked.referencesStarted })

    coordinator.prepare(
        projectURL: fixture.root,
        revision: nil,
        featureSelection: .allFeatures,
        generation: 1
    )
    #expect(await testWaitUntil("coordinator.readiness == .ready && provider.prepareCount == 2") {
        coordinator.readiness == .ready && provider.prepareCount == 2
    })
    blocked.releaseReferences()

    #expect(await request.value == nil)
}

@MainActor
@Test
func exactCoordinatorDiscardsReferencesAfterSessionReplacement() async throws {
    let fixture = try RelationFixture()
    defer { fixture.remove() }
    let blocked = RelationHierarchyExactSession(
        blockReferences: true,
        referenceLocations: [relationExactLocation(file: "stale.rs", offset: 1)]
    )
    let provider = RelationRotatingExactProvider(sessions: [
        blocked,
        RelationHierarchyExactSession(referenceLocations: []),
    ])
    let coordinator = try relationExactCoordinator(
        fixture: fixture,
        provider: provider
    )
    coordinator.prepare(projectURL: fixture.root, revision: nil, generation: 1)
    #expect(await testWaitUntil("coordinator.readiness == .ready") { coordinator.readiness == .ready })
    let request = Task {
        await coordinator.relations(
            file: "main.rs",
            byteOffset: 3,
            item: nil,
            direction: .references,
            generation: 1
        )
    }
    #expect(await testWaitUntil("blocked.referencesStarted") { blocked.referencesStarted })

    coordinator.prepare(projectURL: fixture.root, revision: nil, generation: 1)
    #expect(await testWaitUntil("coordinator.readiness == .ready && provider.prepareCount == 2") {
        coordinator.readiness == .ready && provider.prepareCount == 2
    })
    blocked.releaseReferences()

    #expect(await request.value == nil)
}

@MainActor
@Test
func exactCoordinatorDiscardsReferencesAfterSnapshotSwitch() async throws {
    let fixture = try RelationFixture()
    defer { fixture.remove() }
    let blocked = RelationHierarchyExactSession(
        blockReferences: true,
        referenceLocations: [relationExactLocation(file: "stale.rs", offset: 1)]
    )
    let provider = RelationRotatingExactProvider(sessions: [
        blocked,
        RelationHierarchyExactSession(referenceLocations: []),
    ])
    let coordinator = try relationExactCoordinator(
        fixture: fixture,
        provider: provider
    )
    coordinator.prepare(projectURL: fixture.root, revision: "old", generation: 1)
    #expect(await testWaitUntil("coordinator.readiness == .ready") { coordinator.readiness == .ready })
    let request = Task {
        await coordinator.relations(
            file: "main.rs",
            byteOffset: 3,
            item: nil,
            direction: .references,
            generation: 1
        )
    }
    #expect(await testWaitUntil("blocked.referencesStarted") { blocked.referencesStarted })

    coordinator.prepare(projectURL: fixture.root, revision: "new", generation: 2)
    #expect(await testWaitUntil("coordinator.readiness == .ready && provider.prepareCount == 2") {
        coordinator.readiness == .ready && provider.prepareCount == 2
    })
    blocked.releaseReferences()

    #expect(await request.value == nil)
}

@MainActor
@Test
func exactCoordinatorDiscardsReferencesAfterTrustSwitch() async throws {
    let fixture = try RelationFixture()
    defer { fixture.remove() }
    let blocked = RelationHierarchyExactSession(
        blockReferences: true,
        referenceLocations: [relationExactLocation(file: "stale.rs", offset: 1)]
    )
    let provider = RelationRotatingExactProvider(sessions: [
        blocked,
        RelationHierarchyExactSession(referenceLocations: []),
    ])
    let trustRegistry = TrustRegistry(
        fileURL: fixture.root.appendingPathComponent("trust.json")
    )
    let coordinator = try relationExactCoordinator(
        fixture: fixture,
        provider: provider,
        trustRegistry: trustRegistry
    )
    coordinator.prepare(projectURL: fixture.root, revision: nil, generation: 1)
    #expect(await testWaitUntil("coordinator.readiness == .ready && coordinator.trustMode == .safe") {
        coordinator.readiness == .ready && coordinator.trustMode == .safe
    })
    let request = Task {
        await coordinator.relations(
            file: "main.rs",
            byteOffset: 3,
            item: nil,
            direction: .references,
            generation: 1
        )
    }
    #expect(await testWaitUntil("blocked.referencesStarted") { blocked.referencesStarted })

    try await coordinator.grantTrust(fixture.root)
    coordinator.prepare(projectURL: fixture.root, revision: nil, generation: 1)
    #expect(await testWaitUntil("coordinator.readiness == .ready && coordinator.trustMode == .trusted && provider.prepareCount == 2") {
        coordinator.readiness == .ready
            && coordinator.trustMode == .trusted
            && provider.prepareCount == 2
    })
    blocked.releaseReferences()

    #expect(await request.value == nil)
}

@MainActor
@Test
func relationTreeDeduplicatesExactAndHeuristicAndCyclesCallSites() async throws {
    let fixture = try RelationFixture()
    defer { fixture.remove() }
    let index = try #require(relationContentIndex(at: fixture.b.pathID, in: fixture.session))
    let bFacet = index.symbols[Int(fixture.b.localIndex)]
    let targetOffset = bFacet.nameRange.lowerBound
    let item = relationCallItem(name: "b", file: "main.rs", offset: Int(targetOffset))
    let callSites = [
        relationExactLocation(file: "main.rs", offset: 4),
        relationExactLocation(file: "main.rs", offset: 8),
    ]
    let model = RelationTreeModel(
        loader: { _, _, _, _ in
            .init(edges: [
                .init(
                    title: "b",
                    certainty: .strong,
                    dispatch: .direct,
                    symbol: fixture.b,
                    path: "main.rs",
                    byteOffset: targetOffset,
                    line: 1,
                    evidence: [],
                    identityTarget: ("main.rs", targetOffset)
                ),
            ], isTruncated: false)
        },
        exactRelationsResolver: { _, _, _, _, _ in
            .relations([
                .init(
                    name: "b",
                    location: item.selectionRange,
                    item: item,
                    callSites: callSites
                ),
            ], origin: .worktree, coverage: .full)
        }
    )
    model.updateProjectState(.ready(fixture.session, fixture.context))

    model.setRoot(target: .engine(fixture.a), direction: .calls)
    #expect(await testWaitUntil("relationTreeFinishedLoading(model.root)") { relationTreeFinishedLoading(model.root) })
    let matchingRows = relationVisibleEdgeRows(model.root).filter {
        $0.target?.path == "main.rs"
            && $0.target?.byteOffset == targetOffset
    }
    let edge = try #require(matchingRows.first)

    #expect(matchingRows.count == 1)
    #expect(edge.badge == "Exact · lsp")
    #expect(edge.subtitle == "Exact · heuristic also matched · 2 call sites")
    var selectedOffsets: [UInt32] = []
    model.onSelect = { selectedOffsets.append($0.target?.byteOffset ?? .max) }
    model.select(edge)
    model.select(edge)
    model.select(edge)
    #expect(selectedOffsets == [4, 8, 4])
}

@MainActor
@Test
func relationTreeExactMergePreservesPublishedRowOrderAndIdentity() async throws {
    let fixture = try RelationFixture()
    defer { fixture.remove() }
    let exact = RelationAsyncGate()
    let model = RelationTreeModel(
        loader: { _, _, _, _ in
            .init(
                edges: [
                    .init(
                        title: "A",
                        certainty: .strong,
                        dispatch: .direct,
                        symbol: fixture.a,
                        path: "main.rs",
                        byteOffset: 10,
                        line: 1,
                        evidence: []
                    ),
                    .init(
                        title: "B",
                        certainty: .possible,
                        dispatch: .dynamicDispatch,
                        symbol: fixture.b,
                        path: "main.rs",
                        byteOffset: 20,
                        line: 1,
                        evidence: []
                    ),
                ],
                isTruncated: false
            )
        },
        exactRelationsResolver: { _, _, _, _, _ in
            await exact.wait()
            return .relations(
                [
                    .init(
                        name: "B",
                        location: relationExactLocation(
                            file: "./main.rs",
                            offset: 20
                        ),
                        item: nil,
                        callSites: []
                    ),
                    .init(
                        name: "A",
                        location: relationExactLocation(
                            file: "./main.rs",
                            offset: 10
                        ),
                        item: nil,
                        callSites: []
                    ),
                    .init(
                        name: "C",
                        location: relationExactLocation(
                            file: "./main.rs",
                            offset: 30
                        ),
                        item: nil,
                        callSites: []
                    ),
                ],
                origin: .worktree,
                coverage: .full
            )
        }
    )
    model.updateProjectState(.ready(fixture.session, fixture.context))
    let load = model.setRoot(target: .engine(fixture.a), direction: .callers)
    try #require(await testWaitUntil(
        "exact is pending and heuristic rows A, B are published"
    ) {
        exact.isPending
            && relationVisibleEdgeRows(model.root).map(\.title) == ["A", "B"]
    })
    let firstBatch = relationVisibleEdgeRows(model.root)
    let firstA = try #require(firstBatch.first)
    let firstB = try #require(firstBatch.last)

    exact.release()
    await load?.value
    let finalRows = relationVisibleEdgeRows(model.root)

    #expect(finalRows.map(\.title) == ["A", "B", "C"])
    #expect(finalRows[0] === firstA && finalRows[1] === firstB)
    #expect(
        finalRows[0].badge == "Exact · lsp"
            && finalRows[0].subtitle?.contains("heuristic also matched") == true
            && finalRows[1].badge == "Exact · lsp"
            && finalRows[1].subtitle?.contains("heuristic also matched") == true
    )
    #expect(finalRows.last?.title == "C")
    #expect(model.root?.children?.last { $0.children?.isEmpty == false }?.title == "Exact (1)")
}

@MainActor
@Test
func relationTreeRetainsEmptyExactGroupAfterInPlaceUpgradeInAllDirections()
    async throws
{
    let fixture = try RelationFixture()
    defer { fixture.remove() }
    let traitRoot = try relationTemporaryProject([
        "main.rs": "trait Render { fn render(&self); }",
    ])
    defer { try? FileManager.default.removeItem(at: traitRoot) }
    let traitSession = try ProjectIndexer().index(root: traitRoot)
    let traitContext = relationQueryContext(for: traitSession)
    let trait = try #require(
        traitSession.definitions(of: "Render", context: traitContext).first?.0
    )
    let cases: [
        (
            label: String,
            direction: RelationTreeModel.Direction,
            session: EngineSession,
            context: QueryContext,
            symbol: SymbolOccurrenceID,
            expectedTitle: String
        )
    ] = [
        (
            "callers",
            .callers,
            fixture.session,
            fixture.context,
            fixture.a,
            "Exact (0): no callers"
        ),
        (
            "calls",
            .calls,
            fixture.session,
            fixture.context,
            fixture.a,
            "Exact (0): no calls"
        ),
        (
            "implementations",
            .implementations,
            traitSession,
            traitContext,
            trait,
            "Exact (0): no implementations"
        ),
        (
            "references",
            .references,
            fixture.session,
            fixture.context,
            fixture.a,
            "Exact (0): no references"
        ),
    ]

    for testCase in cases {
        let exact = RelationAsyncGate()
        let model = RelationTreeModel(
            loader: { _, _, _, _ in
                .init(edges: [
                    .init(
                        title: "heuristic-first",
                        certainty: .strong,
                        dispatch: .direct,
                        symbol: nil,
                        path: "main.rs",
                        byteOffset: 20,
                        line: 1,
                        evidence: []
                    ),
                ], isTruncated: false)
            },
            exactRelationsResolver: { _, _, _, _, _ in
                await exact.wait()
                return .relations([
                    .init(
                        name: "heuristic-first",
                        location: relationExactLocation(
                            file: "main.rs",
                            offset: 20
                        ),
                        item: nil,
                        callSites: []
                    ),
                ], origin: .worktree, coverage: .full)
            }
        )
        model.updateProjectState(.ready(testCase.session, testCase.context))

        let load = model.setRoot(
            target: .engine(testCase.symbol),
            direction: testCase.direction
        )
        try #require(await testWaitUntil(
            "\(testCase.label) publishes heuristic rows while Exact is pending"
        ) {
            exact.isPending
                && relationVisibleEdgeRows(model.root).map(\.title)
                    == ["heuristic-first"]
        })
        let firstTitles = model.root?.children?.map(\.title) ?? []
        let firstRow = try #require(relationVisibleEdgeRows(model.root).first)
        #expect(!firstTitles.contains { $0.hasPrefix("Exact") })

        exact.release()
        await load?.value
        let exactGroup = model.root?.children?.first {
            $0.kind == .group && $0.title.hasPrefix("Exact")
        }

        #expect(relationVisibleEdgeRows(model.root).first === firstRow)
        #expect(firstRow.badge == "Exact · lsp")
        #expect(exactGroup?.children?.isEmpty == true)
        #expect(exactGroup?.title == testCase.expectedTitle)
    }
}

@MainActor
@Test
func relationTreeMarksAnExactSelectionRangeCycleAsAlreadyExpanded() async throws {
    let fixture = try RelationFixture()
    defer { fixture.remove() }
    let index = try #require(relationContentIndex(at: fixture.a.pathID, in: fixture.session))
    let aOffset = index.symbols[Int(fixture.a.localIndex)].nameRange.lowerBound
    let bOffset = index.symbols[Int(fixture.b.localIndex)].nameRange.lowerBound
    let a = relationCallItem(name: "a", file: "main.rs", offset: Int(aOffset))
    let b = relationCallItem(name: "b", file: "main.rs", offset: Int(bOffset))
    let model = RelationTreeModel(
        loader: { _, _, _, _ in
            .init(edges: [], isTruncated: false)
        },
        exactRelationsResolver: { _, _, item, _, _ in
            let relation = item?.name == "b"
                ? ExactCoordinator.Relation(
                    name: "a",
                    location: a.selectionRange,
                    item: a,
                    callSites: []
                )
                : ExactCoordinator.Relation(
                    name: "b",
                    location: b.selectionRange,
                    item: b,
                    callSites: []
                )
            return .relations([relation], origin: .worktree, coverage: .full)
        }
    )
    model.updateProjectState(.ready(fixture.session, fixture.context))

    model.setRoot(target: .engine(fixture.a), direction: .callers)
    #expect(await testWaitUntil("relationTreeFinishedLoading(model.root)") { relationTreeFinishedLoading(model.root) })
    let first = try #require(
        try relationGroup("Exact (1)", in: model.root).children?.first
    )
    await model.expand(first)
    let cycle = try #require(
        try relationGroup("Exact (1)", in: first).children?.first
    )

    #expect(cycle.title == "a")
    #expect(cycle.subtitle == "Exact · Already expanded")
    #expect(!cycle.isExpandable)
}

@MainActor
@Test
func relationTreeUsesFiveDistinctExactEmptyStates() async throws {
    let fixture = try RelationFixture()
    defer { fixture.remove() }
    let callersUnsupported = try await relationExactEmptyTitle(
        session: fixture.session,
        context: fixture.context,
        symbol: fixture.a,
        direction: .callers,
        result: .unsupported
    )
    let callersNotApplicable = try await relationExactEmptyTitle(
        session: fixture.session,
        context: fixture.context,
        symbol: fixture.a,
        direction: .callers,
        result: .notApplicable
    )
    let callersEmpty = try await relationExactEmptyTitle(
        session: fixture.session,
        context: fixture.context,
        symbol: fixture.a,
        direction: .callers,
        result: .relations([], origin: .worktree, coverage: .full)
    )

    let traitRoot = try relationTemporaryProject([
        "main.rs": "trait Render { fn render(&self); }",
    ])
    defer { try? FileManager.default.removeItem(at: traitRoot) }
    let traitSession = try ProjectIndexer().index(root: traitRoot)
    let traitContext = relationQueryContext(for: traitSession)
    let trait = try #require(
        traitSession.definitions(of: "Render", context: traitContext).first?.0
    )
    let implementationsUnsupported = try await relationExactEmptyTitle(
        session: traitSession,
        context: traitContext,
        symbol: trait,
        direction: .implementations,
        result: .unsupported
    )
    let implementationsEmpty = try await relationExactEmptyTitle(
        session: traitSession,
        context: traitContext,
        symbol: trait,
        direction: .implementations,
        result: .relations([], origin: .worktree, coverage: .full)
    )

    #expect(callersUnsupported
        == "Exact unavailable: server does not support call hierarchy")
    #expect(callersNotApplicable
        == "Exact unavailable here: not a callable symbol")
    #expect(callersEmpty == "Exact (0): no callers")
    #expect(implementationsUnsupported
        == "Exact unavailable: server does not support implementations")
    #expect(implementationsEmpty == "Exact (0): no implementations")
    #expect(Set([
        callersUnsupported,
        callersNotApplicable,
        callersEmpty,
        implementationsUnsupported,
        implementationsEmpty,
    ]).count == 5)
}

@MainActor
@Test
func relationTreeUsesFourDistinctExactReferenceStates() async throws {
    let fixture = try RelationFixture()
    defer { fixture.remove() }
    let unsupported = try await relationExactEmptyTitle(
        session: fixture.session,
        context: fixture.context,
        symbol: fixture.a,
        direction: .references,
        result: .unsupported
    )
    let notApplicable = try await relationExactEmptyTitle(
        session: fixture.session,
        context: fixture.context,
        symbol: fixture.a,
        direction: .references,
        result: .notApplicable
    )
    let queried = try await relationExactEmptyTitle(
        session: fixture.session,
        context: fixture.context,
        symbol: fixture.a,
        direction: .references,
        result: .relations([], origin: .worktree, coverage: .full)
    )
    let legacyModel = RelationTreeModel(loader: { _, _, _, _ in
        .init(edges: [], isTruncated: false)
    })
    legacyModel.updateProjectState(.ready(fixture.session, fixture.context))
    await legacyModel.setRoot(
        target: .engine(fixture.a),
        direction: .references
    )?.value
    let legacy = try #require(legacyModel.root?.children?.first {
        $0.kind == .group && $0.title.hasPrefix("Exact")
    }?.title)

    #expect(unsupported
        == "Exact unavailable: server does not support references")
    #expect(notApplicable
        == "Exact unavailable here: references not applicable")
    #expect(queried == "Exact (0): no references")
    #expect(legacy == "Exact unavailable: no exact session")
    #expect(Set([unsupported, notApplicable, queried, legacy]).count == 4)
}

@MainActor
@Test
func relationTreeKeepsFuzzyReferencesWhenExactIsUnsupported() async throws {
    let fixture = try RelationFixture()
    defer { fixture.remove() }
    let exactSession = RelationHierarchyExactSession()
    let coordinator = try relationExactCoordinator(
        fixture: fixture,
        provider: RelationHierarchyExactProvider(session: exactSession)
    )
    coordinator.prepare(
        projectURL: fixture.root,
        revision: nil,
        generation: fixture.context.generation
    )
    #expect(await testWaitUntil("coordinator.readiness == .ready") { coordinator.readiness == .ready })
    let model = RelationTreeModel()
    model.attachExactCoordinator(coordinator)
    model.updateProjectState(.ready(fixture.session, fixture.context))

    await model.setRoot(
        target: .engine(fixture.b),
        direction: .references
    )?.value

    let exact = try relationGroup(
        "Exact unavailable: server does not support references",
        in: model.root
    )
    let references = try relationGroup("References", in: model.root)
    #expect(exact.children?.isEmpty == true)
    #expect(references.children?.count == 1)
    #expect(references.children?.first?.target?.path == "main.rs")
    #expect(references.subtitle == "1 references")
    #expect(exactSession.referenceIncludeDeclarations.isEmpty)
}

@MainActor
@Test
func relationTreeShowsExactOnlyImplementations() async throws {
    let root = try relationTemporaryProject([
        "main.rs": "trait Render { fn render(&self); }",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try ProjectIndexer().index(root: root)
    let context = relationQueryContext(for: session)
    let trait = try #require(
        session.definitions(of: "Render", context: context).first?.0
    )
    let dependency = relationExactLocation(
        file: "/dependency/src/view.rs",
        offset: 40
    )
    let model = RelationTreeModel(
        loader: { _, _, _, _ in
            .init(edges: [], isTruncated: false)
        },
        exactRelationsResolver: { _, _, _, _, _ in
            .relations([
                .init(
                    name: nil,
                    location: dependency,
                    item: nil,
                    callSites: []
                ),
            ], origin: .worktree, coverage: .full)
        }
    )
    model.updateProjectState(.ready(session, context))

    model.setRoot(target: .engine(trait), direction: .implementations)
    #expect(await testWaitUntil("relationTreeFinishedLoading(model.root)") { relationTreeFinishedLoading(model.root) })
    let exact = try relationGroup("Exact (1)", in: model.root)

    #expect(exact.children?.map(\.title) == ["view.rs:1"])
    #expect(exact.children?.first?.target?.path == dependency.file)
    #expect(exact.children?.first?.symbol == nil)
}

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

    model.setRoot(target: .engine(symbol), direction: .calls)
    #expect(await testWaitUntil("relationTreeFinishedLoading(model.root)") { relationTreeFinishedLoading(model.root) })

    let exact = try relationGroup(
        "Exact unavailable: no exact session",
        in: model.root
    )
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

    model.setRoot(target: .engine(fixture.a), direction: .calls)
    #expect(await testWaitUntil("relationTreeFinishedLoading(model.root)") { relationTreeFinishedLoading(model.root) })

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
func relationTreeDefaultLoadDoesNotPromoteIndividualHeuristicEdges() async throws {
    let fixture = try RelationFixture()
    defer { fixture.remove() }
    var definitionRequests = 0
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
        exactResolver: { _, _, _ in
            definitionRequests += 1
            return nil
        }
    )
    model.updateProjectState(.ready(fixture.session, fixture.context))

    model.setRoot(target: .engine(fixture.a), direction: .calls)
    #expect(await testWaitUntil("relationTreeFinishedLoading(model.root)") { relationTreeFinishedLoading(model.root) })

    let strong = try relationGroup("Strong", in: model.root)
    #expect(definitionRequests == 0)
    #expect(strong.children?.map(\.title) == [
        "matching",
        "mismatching",
        "no exact",
    ])
}

@MainActor
@Test
func relationTreeStartsHeuristicAndRootExactQueriesConcurrently() async throws {
    let fixture = try RelationFixture()
    defer { fixture.remove() }
    let loader = FakeRelationLoader(
        responses: [
            fixture.a: .init(edges: [], isTruncated: false),
        ],
        gated: [fixture.a]
    )
    let exact = RelationAsyncGate()
    let model = RelationTreeModel(
        loader: loader.load,
        exactRelationsResolver: { _, _, _, _, _ in
            await exact.wait()
            return .unsupported
        }
    )
    model.updateProjectState(.ready(fixture.session, fixture.context))

    let load = model.setRoot(target: .engine(fixture.a), direction: .calls)
    let overlapped = await testWaitUntil(
        "heuristic and root Exact queries are both pending"
    ) {
        await loader.isPending(fixture.a) && exact.isPending
    }
    await loader.release(fixture.a)
    if !exact.isPending {
        _ = await testWaitUntil("root Exact query is pending") { exact.isPending }
    }
    exact.release()
    await load?.value

    #expect(overlapped)
}

@MainActor
@Test
func relationAsyncGateLatchesReleaseBeforeWait() async {
    let gate = RelationAsyncGate()

    gate.release()
    await gate.wait()

    #expect(!gate.isPending)
}

@MainActor
@Test
func relationTreeLoadReturnsWhenGenerationChangesWithBothQueriesPending()
    async throws
{
    let fixture = try RelationFixture()
    defer { fixture.remove() }
    let loader = FakeRelationLoader(
        responses: [
            fixture.a: .init(edges: [], isTruncated: false),
        ],
        gated: [fixture.a]
    )
    let exact = RelationAsyncGate()
    let model = RelationTreeModel(
        loader: loader.load,
        exactRelationsResolver: { _, _, _, _, _ in
            await exact.wait()
            return .unsupported
        }
    )
    model.updateProjectState(.ready(fixture.session, fixture.context))

    let load = try #require(
        model.setRoot(target: .engine(fixture.a), direction: .calls)
    )
    try #require(await testWaitUntil(
        "both relation queries are pending before generation changes"
    ) {
        await loader.isPending(fixture.a) && exact.isPending
    })
    model.updateProjectState(.ready(fixture.session, fixture.context))
    await load.value
    await loader.release(fixture.a)
    exact.release()
}

@MainActor
@Test
func relationTreeKeepsFastRowsAndReturnsAtTheQueryDeadline() async throws {
    let fixture = try RelationFixture()
    defer { fixture.remove() }
    let exact = RelationAsyncGate()
    let model = RelationTreeModel(
        loader: { _, _, _, _ in
            .init(edges: [
                .init(
                    title: "heuristic-first",
                    certainty: .strong,
                    dispatch: .direct,
                    symbol: fixture.b,
                    path: "main.rs",
                    byteOffset: 20,
                    line: 1,
                    evidence: []
                ),
            ], isTruncated: false)
        },
        exactRelationsResolver: { _, _, _, _, _ in
            await exact.wait()
            return .unsupported
        },
        queryTimeout: .milliseconds(50)
    )
    model.updateProjectState(.ready(fixture.session, fixture.context))

    let load = try #require(
        model.setRoot(target: .engine(fixture.a), direction: .calls)
    )
    try #require(await testWaitUntil(
        "fast heuristic rows publish while root Exact is pending"
    ) {
        exact.isPending
            && relationVisibleEdgeRows(model.root).map(\.title)
                == ["heuristic-first"]
    })
    await load.value
    exact.release()

    #expect(relationVisibleEdgeRows(model.root).map(\.title) == ["heuristic-first"])
    #expect(model.root?.children?.contains { $0.kind == .loading } == false)
}

@MainActor
@Test
func relationTreePublishesHeuristicRowsBeforeRootExactFinishes() async throws {
    let fixture = try RelationFixture()
    defer { fixture.remove() }
    let exact = RelationAsyncGate()
    let model = RelationTreeModel(
        loader: { _, _, _, _ in
            .init(edges: [
                .init(
                    title: "heuristic-first",
                    certainty: .strong,
                    dispatch: .direct,
                    symbol: fixture.b,
                    path: "main.rs",
                    byteOffset: 20,
                    line: 1,
                    evidence: []
                ),
            ], isTruncated: false)
        },
        exactRelationsResolver: { _, _, _, _, _ in
            await exact.wait()
            return .unsupported
        }
    )
    model.updateProjectState(.ready(fixture.session, fixture.context))

    let load = model.setRoot(target: .engine(fixture.a), direction: .calls)
    let publishedWhileExactWasPending = await testWaitUntil(
        "heuristic rows publish before root Exact finishes"
    ) {
        exact.isPending
            && model.root?.children?.first {
                $0.kind == .group && $0.title == "Strong"
            }?.children?.map(\.title) == ["heuristic-first"]
    }
    exact.release()
    await load?.value

    #expect(publishedWhileExactWasPending)
}

@MainActor
@Test
func relationTreeFreezesExactFirstRowOrderWhenHeuristicArrives() async throws {
    let fixture = try RelationFixture()
    defer { fixture.remove() }
    let loader = FakeRelationLoader(
        responses: [
            fixture.a: .init(
                edges: [
                    .init(
                        title: "A",
                        certainty: .strong,
                        dispatch: .direct,
                        symbol: fixture.a,
                        path: "main.rs",
                        byteOffset: 10,
                        line: 1,
                        evidence: []
                    ),
                    .init(
                        title: "B",
                        certainty: .strong,
                        dispatch: .direct,
                        symbol: fixture.b,
                        path: "main.rs",
                        byteOffset: 20,
                        line: 1,
                        evidence: []
                    ),
                    .init(
                        title: "D",
                        certainty: .strong,
                        dispatch: .direct,
                        symbol: nil,
                        path: "main.rs",
                        byteOffset: 40,
                        line: 1,
                        evidence: []
                    ),
                ],
                isTruncated: false
            ),
        ],
        gated: [fixture.a]
    )
    let model = RelationTreeModel(
        loader: loader.load,
        exactRelationsResolver: { _, _, _, _, _ in
            .relations([
                .init(
                    name: "B",
                    location: relationExactLocation(file: "main.rs", offset: 20),
                    item: nil,
                    callSites: []
                ),
                .init(
                    name: "A",
                    location: relationExactLocation(file: "main.rs", offset: 10),
                    item: nil,
                    callSites: []
                ),
            ], origin: .worktree, coverage: .full)
        }
    )
    model.updateProjectState(.ready(fixture.session, fixture.context))

    let load = model.setRoot(target: .engine(fixture.a), direction: .callers)
    #expect(await testWaitUntil(
        "exact-first rows preserve returned order while heuristic is pending"
    ) {
        await loader.isPending(fixture.a)
            && model.root?.children?.first {
                $0.kind == .group && $0.title == "Exact (2)"
            }?.children?.map { $0.target?.byteOffset } == [20, 10]
    })
    await loader.release(fixture.a)
    await load?.value
    let exact = try relationGroup("Exact (2)", in: model.root)

    #expect(exact.children?.map { $0.target?.byteOffset } == [20, 10])
    #expect(try relationGroup("Strong", in: model.root).children?.map(\.title) == ["D"])
}

@MainActor
@Test
func relationTreeDefaultLoadDoesNotDemoteNameOnlyCallsThroughDefinitions()
    async throws
{
    let fixture = try RelationFixture()
    defer { fixture.remove() }
    var definitionRequests = 0
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
        exactResolver: { _, _, _ in
            definitionRequests += 1
            return nil
        }
    )
    model.updateProjectState(.ready(fixture.session, fixture.context))

    model.setRoot(target: .engine(fixture.a), direction: .calls)
    #expect(await testWaitUntil("relationTreeFinishedLoading(model.root)") { relationTreeFinishedLoading(model.root) })

    let strong = try relationGroup("Strong", in: model.root)
    let probable = try relationGroup("Probable", in: model.root)
    let possible = try relationGroup("Possible", in: model.root)
    #expect(definitionRequests == 0)
    #expect(strong.children?.map(\.title) == ["strong"])
    #expect(probable.children?.map(\.title) == ["no exact"])
    #expect(possible.children?.map(\.title) == ["external", "matching"])
    #expect(
        try relationGroup("External / Unresolved (0)", in: model.root)
            .children?.isEmpty == true
    )
}

@MainActor
@Test
func dependencyPathDoesNotTriggerDefaultRelationPromotion() async throws {
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
    #expect(await testWaitUntil("contextModel.selectedCandidate?.path == dependency.path") {
        contextModel.selectedCandidate?.path == dependency.path
    })

    let methodName = fixture.session.names.intern("method")
    var definitionRequests = 0
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
            definitionRequests += 1
            return relationExactEntry(
                file: dependency.path,
                byteOffset: dependencyOffset
            )
        }
    )
    relationModel.updateProjectState(.ready(fixture.session, fixture.context))
    await relationModel.setRoot(
        target: .engine(fixture.a),
        direction: .calls
    )?.value
    let possible = try relationGroup(
        "Possible",
        in: relationModel.root
    )

    #expect(exactLocationIsInDependency(dependency.path))
    #expect(contextModel.selectedCandidate?.label == "External · in dependency")
    #expect(definitionRequests == 0)
    #expect(
        possible.children?.first?.subtitle
            == "Possible · dynamic · name match only"
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

    model.setRoot(target: .engine(symbol), direction: .calls)
    #expect(await testWaitUntil("relationTreeFinishedLoading(model.root)") { relationTreeFinishedLoading(model.root) })

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

    model.setRoot(target: .engine(symbol), direction: .calls)
    #expect(await testWaitUntil("relationTreeFinishedLoading(model.root)") { relationTreeFinishedLoading(model.root) })

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

    model.setRoot(target: .engine(fixture.a), direction: .calls)
    #expect(await testWaitUntil("relationTreeFinishedLoading(model.root)") { relationTreeFinishedLoading(model.root) })
    let strong = try relationGroup("Strong", in: model.root)
    let symbolEdge = try #require(strong.children?.first)
    model.select(symbolEdge)
    let generation = model.generation

    model.setRoot(
        target: .engine(model.selectedRelationSymbol ?? fixture.a),
        direction: .callers
    )
    #expect(await testWaitUntil("relationTreeFinishedLoading(model.root)") { relationTreeFinishedLoading(model.root) })
    #expect(model.root?.title == "b")
    #expect(model.generation > generation)

    model.setRoot(target: .engine(fixture.a), direction: .calls)
    #expect(await testWaitUntil("relationTreeFinishedLoading(model.root)") { relationTreeFinishedLoading(model.root) })
    let external = try relationGroup("External / Unresolved", in: model.root)
    let unresolvedEdge = try #require(external.children?.first)
    model.select(unresolvedEdge)
    #expect(model.selectedRelationSymbol == nil)

    model.setRoot(
        target: .engine(model.selectedRelationSymbol ?? fixture.a),
        direction: .callers
    )
    #expect(await testWaitUntil("relationTreeFinishedLoading(model.root)") { relationTreeFinishedLoading(model.root) })
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
    model.setRoot(target: .engine(fixture.a), direction: .calls)
    #expect(await testWaitUntil("relationTreeFinishedLoading(model.root)") { relationTreeFinishedLoading(model.root) })
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

    model.setRoot(target: .engine(fixture.a), direction: .calls)
    #expect(await testWaitUntil("relationTreeFinishedLoading(model.root)") { relationTreeFinishedLoading(model.root) })

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

    model.setRoot(target: .engine(symbol), direction: .callers)
    #expect(await testWaitUntil("relationTreeFinishedLoading(model.root)") { relationTreeFinishedLoading(model.root) })
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

    model.setRoot(target: .engine(trait.0), direction: .implementations)
    #expect(await testWaitUntil("relationTreeFinishedLoading(model.root)") { relationTreeFinishedLoading(model.root) })
    let implementations = try relationGroup("Strong", in: model.root)
    #expect(implementations.children?.map(\.title) == ["View"])
    #expect(implementations.children?.first?.subtitle == "Strong · trait")

    model.setRoot(target: .engine(method), direction: .implementations)
    #expect(await testWaitUntil("relationTreeFinishedLoading(model.root)") { relationTreeFinishedLoading(model.root) })
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

    model.setRoot(target: .engine(fixture.a), direction: .calls)
    #expect(model.root?.children?.first?.kind == .loading)
    #expect(await testWaitUntil("await fake.isPending(fixture.a)") { await fake.isPending(fixture.a) })
    let root = try #require(model.root)
    await model.expand(root)
    await model.expand(root)

    #expect(await fake.count(for: fixture.a) == 1)
    await fake.release(fixture.a)
    #expect(await testWaitUntil("relationTreeFinishedLoading(model.root)") { relationTreeFinishedLoading(model.root) })
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

    model.setRoot(target: .engine(fixture.a), direction: .calls)
    #expect(await testWaitUntil("await fake.isPending(fixture.a)") { await fake.isPending(fixture.a) })
    model.setRoot(target: .engine(fixture.b), direction: .calls)
    #expect(await testWaitUntil("model.root?.children?.first { $0.kind == .group && $0.title == \"Strong\" }?.children?.first?.title == \"fresh\"") {
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
func relationTreeDiscardsStaleProjectReferencesAfterGenerationChange() async throws {
    let fixture = try RelationFixture()
    defer { fixture.remove() }
    let stale = RelationTreeModel.LoadedEdge(
        title: "stale-reference",
        certainty: .possible,
        dispatch: .direct,
        symbol: nil,
        path: "main.rs",
        byteOffset: 0,
        line: 1,
        evidence: []
    )
    let fake = FakeRelationLoader(
        responses: [
            fixture.a: .init(edges: [stale], isTruncated: false),
        ],
        gated: [fixture.a]
    )
    let model = RelationTreeModel(loader: fake.load)
    model.updateProjectState(.ready(fixture.session, fixture.context))

    model.setRoot(target: .engine(fixture.a), direction: .references)
    #expect(await testWaitUntil("await fake.isPending(fixture.a)") { await fake.isPending(fixture.a) })
    model.updateProjectState(.ready(fixture.session, fixture.context))
    await fake.release(fixture.a)
    for _ in 0..<10 { await Task.yield() }

    #expect(model.root == nil)
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

    model.setRoot(target: .engine(fixture.a), direction: .callers)
    #expect(await testWaitUntil("relationTreeFinishedLoading(model.root)") { relationTreeFinishedLoading(model.root) })

    let strong = try relationGroup("Strong", in: model.root)
    #expect(strong.children?.count == 500)
    #expect(model.root?.children?.last?.kind == .truncated)
    #expect(model.root?.children?.last?.title
        == "Showing first 500 of 501 relations")
    #expect(model.hasTruncatedResults)
}

@MainActor
@Test
func relationTreeCapsExactRelationsAndReportsTheirTrueTotal() async throws {
    let fixture = try RelationFixture()
    defer { fixture.remove() }
    let relations = (0...500).map {
        ExactCoordinator.Relation(
            name: "exact-\($0)",
            location: relationExactLocation(file: "dependency.rs", offset: $0),
            item: nil,
            callSites: []
        )
    }
    let model = RelationTreeModel(
        loader: { _, _, _, _ in
            .init(edges: [], isTruncated: false)
        },
        exactRelationsResolver: { _, _, _, _, _ in
            .relations(relations, origin: .worktree, coverage: .full)
        }
    )
    model.updateProjectState(.ready(fixture.session, fixture.context))

    model.setRoot(target: .engine(fixture.a), direction: .callers)
    #expect(await testWaitUntil("relationTreeFinishedLoading(model.root)") { relationTreeFinishedLoading(model.root) })

    let exact = try relationGroup("Exact (500)", in: model.root)
    #expect(exact.children?.count == 500)
    #expect(model.root?.children?.last?.kind == .truncated)
    #expect(model.root?.children?.last?.title
        == "Showing first 500 of 501 relations")
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
    model.setRoot(target: .engine(fixture.a), direction: .calls)
    #expect(await testWaitUntil("relationTreeFinishedLoading(model.root)") { relationTreeFinishedLoading(model.root) })
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

private final class RelationHierarchyExactProvider: ExactProvider, @unchecked Sendable {
    let capabilities: ExactCapabilities = [.callHierarchy, .references]
    let toolVersion = "relation-hierarchy-fake-1"
    private let session: RelationHierarchyExactSession
    private let coverage: ExactCoverage

    init(
        session: RelationHierarchyExactSession,
        coverage: ExactCoverage = .full
    ) {
        self.session = session
        self.coverage = coverage
    }

    func prepare(
        snapshot: any Snapshot,
        profile: ExactProfileKey,
        trustMode: TrustMode
    ) throws -> any ExactSession {
        session.attribution = ExactAttribution(
            provider: "relation-hierarchy-fake",
            toolVersion: toolVersion,
            configFingerprint: profile.configFingerprint,
            environmentFingerprint: profile.environmentFingerprint,
            featureSelection: profile.featureSelection,
            trustMode: trustMode,
            generatedAt: Date(timeIntervalSince1970: 0),
            coverage: coverage
        )
        return session
    }
}

private final class RelationRotatingExactProvider: ExactProvider, @unchecked Sendable {
    let capabilities: ExactCapabilities = [.callHierarchy, .references]
    let toolVersion = "relation-rotating-fake-1"
    private let lock = NSLock()
    private let sessions: [RelationHierarchyExactSession]
    private var nextSession = 0

    init(sessions: [RelationHierarchyExactSession]) {
        self.sessions = sessions
    }

    var prepareCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return nextSession
    }

    func prepare(
        snapshot: any Snapshot,
        profile: ExactProfileKey,
        trustMode: TrustMode
    ) throws -> any ExactSession {
        lock.lock()
        let index = min(nextSession, sessions.count - 1)
        nextSession += 1
        let session = sessions[index]
        lock.unlock()
        session.attribution = ExactAttribution(
            provider: "relation-rotating-fake",
            toolVersion: toolVersion,
            configFingerprint: profile.configFingerprint,
            environmentFingerprint: profile.environmentFingerprint,
            featureSelection: profile.featureSelection,
            trustMode: trustMode,
            generatedAt: Date(timeIntervalSince1970: 0),
            coverage: .full
        )
        return session
    }
}

private final class RelationHierarchyExactSession: ExactSession, @unchecked Sendable {
    let negotiatedCapabilities: ExactCapabilities
    let readiness: ExactReadiness = .ready
    var attribution = relationExactAttribution()
    private let condition = NSCondition()
    private var blockIncoming: Bool
    private var blockReferences: Bool
    private var didStartIncoming = false
    private var didStartReferences = false
    private let referenceLocations: [ExactLocation]?
    private var storedReferenceIncludeDeclarations: [Bool] = []

    private let root = relationCallItem(name: "a", file: "main.rs", offset: 3)
    private let dependency = relationCallItem(
        name: "dependency_caller",
        file: "/dependency/src/lib.rs",
        offset: 10
    )
    private let top = relationCallItem(
        name: "top_level_caller",
        file: "/dependency/src/top.rs",
        offset: 20
    )

    init(
        blockIncoming: Bool = false,
        blockReferences: Bool = false,
        referenceLocations: [ExactLocation]? = nil
    ) {
        self.blockIncoming = blockIncoming
        self.blockReferences = blockReferences
        self.referenceLocations = referenceLocations
        negotiatedCapabilities = referenceLocations == nil
            ? [.callHierarchy]
            : [.callHierarchy, .references]
    }

    var incomingStarted: Bool {
        condition.lock()
        defer { condition.unlock() }
        return didStartIncoming
    }

    var referencesStarted: Bool {
        condition.lock()
        defer { condition.unlock() }
        return didStartReferences
    }

    func definition(file: String, byteOffset: Int) throws -> ExactLocation? { nil }

    func implementations(
        file: String,
        byteOffset: Int
    ) throws -> [ExactLocation]? {
        nil
    }

    func references(
        file: String,
        byteOffset: Int,
        includeDeclaration: Bool
    ) throws -> [ExactLocation]? {
        condition.lock()
        storedReferenceIncludeDeclarations.append(includeDeclaration)
        if blockReferences {
            didStartReferences = true
            condition.broadcast()
            while blockReferences { condition.wait() }
        }
        condition.unlock()
        return referenceLocations
    }

    var referenceIncludeDeclarations: [Bool] {
        condition.lock()
        defer { condition.unlock() }
        return storedReferenceIncludeDeclarations
    }

    func prepareCallHierarchy(
        file: String,
        byteOffset: Int
    ) throws -> [ExactCallHierarchyItem]? {
        [root]
    }

    func incomingCalls(
        item: ExactCallHierarchyItem
    ) throws -> [ExactCallRelation]? {
        condition.lock()
        if blockIncoming {
            didStartIncoming = true
            condition.broadcast()
            while blockIncoming { condition.wait() }
        }
        condition.unlock()
        return switch item.name {
        case root.name:
            [ExactCallRelation(
                item: dependency,
                callSites: [relationExactLocation(file: "main.rs", offset: 5)]
            )]
        case dependency.name:
            [ExactCallRelation(
                item: top,
                callSites: [relationExactLocation(
                    file: "/dependency/src/lib.rs",
                    offset: 30
                )]
            )]
        default:
            []
        }
    }

    func outgoingCalls(
        item: ExactCallHierarchyItem
    ) throws -> [ExactCallRelation]? {
        []
    }

    func cancel() {}
    func close() {}

    func releaseIncoming() {
        condition.lock()
        blockIncoming = false
        condition.broadcast()
        condition.unlock()
    }

    func releaseReferences() {
        condition.lock()
        blockReferences = false
        condition.broadcast()
        condition.unlock()
    }
}

private final class RelationExactSnapshot: Snapshot, @unchecked Sendable {
    let snapshotID = SnapshotID(rawValue: UUID())
    let objectFormat = GitObjectFormat.sha1
    let sourceKind = SourceKind.untracked
    private let files: [String: [UInt8]]

    init(files: [String: String]) {
        self.files = files.mapValues { Array($0.utf8) }
    }

    func listFiles() -> [(path: String, contentID: ContentID, fileMode: FileMode)] {
        files.keys.sorted().map { path in
            (path, ContentID.sha256(of: files[path]!), .regular)
        }
    }

    func readBytes(path: String) throws -> [UInt8] {
        guard let bytes = files[path] else { throw RelationTestError.expected }
        return bytes
    }
}

private actor FakeRelationLoader {
    private let responses: [SymbolOccurrenceID: RelationTreeModel.LoadResult]
    private var gated: Set<SymbolOccurrenceID>
    private var waitingCounts: [SymbolOccurrenceID: Int] = [:]
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
            waitingCounts[symbol, default: 0] += 1
            defer {
                waitingCounts[symbol, default: 1] -= 1
                if waitingCounts[symbol] == 0 {
                    waitingCounts.removeValue(forKey: symbol)
                }
            }
            let deadline = ContinuousClock.now + .seconds(120)
            while gated.contains(symbol),
                  !Task.isCancelled,
                  ContinuousClock.now < deadline
            {
                try? await Task.sleep(for: .milliseconds(10))
            }
            if gated.contains(symbol), !Task.isCancelled {
                Issue.record(
                    "Timed out waiting for heuristic relation load release: \(symbol)"
                )
            }
        }
        return responses[symbol] ?? .init(edges: [], isTruncated: false)
    }

    func count(for symbol: SymbolOccurrenceID) -> Int {
        counts[symbol, default: 0]
    }

    func isPending(_ symbol: SymbolOccurrenceID) -> Bool {
        waitingCounts[symbol, default: 0] > 0
    }

    func release(_ symbol: SymbolOccurrenceID) {
        gated.remove(symbol)
    }
}

private func relationVisibleEdgeRows(
    _ root: RelationTreeModel.Node?
) -> [RelationTreeModel.Node] {
    root?.children?.flatMap {
        ($0.children ?? []).filter { $0.kind == .edge }
    } ?? []
}

@MainActor
private final class RelationAsyncGate {
    private var isReleased = false
    private var pendingCount = 0
    var isPending: Bool { pendingCount > 0 }

    func wait(_ waitingFor: String = "root Exact relation release") async {
        guard !isReleased else { return }
        pendingCount += 1
        defer { pendingCount -= 1 }
        let deadline = ContinuousClock.now + .seconds(120)
        while !isReleased,
              !Task.isCancelled,
              ContinuousClock.now < deadline
        {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if !isReleased, !Task.isCancelled {
            Issue.record("Timed out waiting for \(waitingFor)")
        }
    }

    func release() {
        isReleased = true
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

@MainActor
private func relationExactEmptyTitle(
    session: EngineSession,
    context: QueryContext,
    symbol: SymbolOccurrenceID,
    direction: RelationTreeModel.Direction,
    result: ExactCoordinator.RelationQueryResult
) async throws -> String {
    let model = RelationTreeModel(
        loader: { _, _, _, _ in
            .init(edges: [], isTruncated: false)
        },
        exactRelationsResolver: { _, _, _, _, _ in result }
    )
    model.updateProjectState(.ready(session, context))
    model.setRoot(target: .engine(symbol), direction: direction)
    #expect(await testWaitUntil("relationTreeFinishedLoading(model.root)") { relationTreeFinishedLoading(model.root) })
    return try #require(model.root?.children?.first {
        $0.kind == .group && $0.title.hasPrefix("Exact")
    }?.title)
}

@MainActor
private func relationProjectReferenceStatus(
    fixture: RelationFixture,
    edgeCount: Int,
    isTruncated: Bool,
    exactCount: Int = 0
) async throws -> (
    exactTitle: String,
    exactRowCount: Int,
    referenceSubtitle: String?,
    referenceRowCount: Int,
    footerTitle: String?
) {
    let edges = (0..<edgeCount).map {
        RelationTreeModel.LoadedEdge(
            title: "reference-\($0)",
            certainty: .possible,
            dispatch: .direct,
            symbol: nil,
            path: "main.rs",
            byteOffset: UInt32($0),
            line: 1,
            evidence: []
        )
    }
    let exact = (0..<exactCount).map {
        ExactCoordinator.Relation(
            name: nil,
            location: relationExactLocation(
                file: "exact-\($0).rs",
                offset: 10_000 + $0
            ),
            item: nil,
            callSites: []
        )
    }
    let exactResolver: RelationTreeModel.ExactRelationsResolver = {
        _, _, _, _, _ in
        .relations(exact, origin: .worktree, coverage: .full)
    }
    let model = RelationTreeModel(
        loader: { _, _, _, _ in
            .init(edges: edges, isTruncated: isTruncated)
        },
        exactRelationsResolver: exactResolver
    )
    model.updateProjectState(.ready(fixture.session, fixture.context))
    await model.setRoot(
        target: .engine(fixture.a),
        direction: .references
    )?.value
    let exactGroup = try #require(model.root?.children?.first {
        $0.kind == .group && $0.title.hasPrefix("Exact")
    })
    let referenceGroup = try relationGroup("References", in: model.root)
    return (
        exactGroup.title,
        exactGroup.children?.count ?? 0,
        referenceGroup.subtitle,
        referenceGroup.children?.count ?? 0,
        model.root?.children?.first { $0.kind == .truncated }?.title
    )
}

@MainActor
private func relationExactCoordinator(
    fixture: RelationFixture,
    provider: any ExactProvider,
    trustRegistry: TrustRegistry? = nil
) throws -> ExactCoordinator {
    let cargo = "[package]\nname='relation-test'\nversion='0.1.0'\n"
    try cargo.write(
        to: fixture.root.appendingPathComponent("Cargo.toml"),
        atomically: true,
        encoding: .utf8
    )
    return ExactCoordinator(
        providerFactory: { _ in provider },
        snapshotFactory: { _, _ in
            RelationExactSnapshot(files: [
                "Cargo.toml": cargo,
                "main.rs": "fn a() {}\nfn b() {}\n",
            ])
        },
        sandboxAvailable: { true },
        trustRegistry: trustRegistry ?? TrustRegistry(
            fileURL: fixture.root.appendingPathComponent("trust.json")
        )
    )
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

private func relationGit(_ root: URL, _ arguments: String...) throws {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = root
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw RelationTestError.expected
    }
}

@MainActor
private func relationReferenceResult(
    source: String,
    token: String,
    declarationIndex: Int
) throws -> (
    offsets: [UInt32],
    subtitle: String?,
    tokenRanges: [ByteRange],
    declarationOffset: UInt32,
    footerTitle: String?
) {
    let root = try relationTemporaryProject(["main.rs": source])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try ProjectIndexer().index(root: root)
    let context = relationQueryContext(for: session)
    let document = try DocumentLoader().load(
        file: root.appendingPathComponent("main.rs")
    ).document
    let ranges = relationTokenRanges(of: token, in: source)
    let declaration = try #require(ranges.indices.contains(declarationIndex)
        ? ranges[declarationIndex]
        : nil)
    let binding = try #require(document.localBinding(at: declaration.lowerBound))
    let pathID = try #require(session.manifest.files.first {
        session.paths.resolve($0.pathID) == "main.rs"
    }?.pathID)
    let bindingIndex = try #require(UInt32(exactly: binding.bindingIndex))
    let model = RelationTreeModel()
    model.updateProjectState(.ready(session, context))
    model.setRoot(
        target: .localBinding(
            pathID: pathID,
            bindingIndex: bindingIndex
        ),
        direction: .references,
        document: document
    )
    let group = try relationGroup(
        "References (\(binding.references.count))",
        in: model.root
    )
    return (
        group.children?.compactMap { $0.target?.byteOffset } ?? [],
        model.root?.subtitle,
        ranges,
        binding.binding.declarationRange.lowerBound,
        model.root?.children?.first { $0.kind == .truncated }?.title
    )
}

private func relationTokenRanges(
    of token: String,
    in source: String
) -> [ByteRange] {
    var result: [ByteRange] = []
    var start = source.startIndex
    while let range = source.range(of: token, range: start..<source.endIndex) {
        let lower = UInt32(source[..<range.lowerBound].utf8.count)
        result.append(ByteRange(
            lowerBound: lower,
            upperBound: lower + UInt32(token.utf8.count)
        ))
        start = range.upperBound
    }
    return result
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

private func relationCallItem(
    name: String,
    file: String,
    offset: Int
) -> ExactCallHierarchyItem {
    let location = relationExactLocation(file: file, offset: offset)
    return ExactCallHierarchyItem(
        name: name,
        kind: 12,
        uri: file.hasPrefix("/")
            ? URL(fileURLWithPath: file).absoluteString
            : URL(fileURLWithPath: "/project/\(file)").absoluteString,
        range: location,
        selectionRange: location,
        data: nil
    )
}

private func relationExactLocation(file: String, offset: Int) -> ExactLocation {
    ExactLocation(file: file, byteOffset: offset, line: 1, column: offset + 1)
}

private func relationExactAttribution() -> ExactAttribution {
    ExactAttribution(
        provider: "relation-hierarchy-fake",
        toolVersion: "relation-hierarchy-fake-1",
        configFingerprint: "config",
        environmentFingerprint: "environment",
        trustMode: .safe,
        generatedAt: Date(timeIntervalSince1970: 0),
        coverage: .full
    )
}
