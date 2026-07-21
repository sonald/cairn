import CodeInsightCore
@testable import CodeInsightEngine
import Foundation
import Testing

private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

@Test
func resolvesUniqueRustImportAndFindsCaller() throws {
    let main = """
        mod db;
        mod util;
        use db::connect as open_db;
        fn main() { open_db(); }
        """
    try withProject([
        "main.rs": main,
        "db.rs": "pub fn connect() {}",
        "util.rs": "pub fn connect() {}",
    ]) { session in
        let context = queryContext(for: session)
        let mainPath = try #require(pathID("main.rs", in: session))
        let resolved = try session.resolve(
            file: mainPath,
            offset: offset(of: "open_db();", in: main),
            context: context
        )
        let top = try #require(resolved.first)

        #expect(session.paths.resolve(top.target.pathID) == "db.rs")
        #expect(top.certainty == .strong)
        #expect(hasUniqueImport(top.evidence))
        #expect(session.paths.resolve(top.target.pathID) != "util.rs")

        let callers = try session.callers(of: "connect", context: context)
        let caller = try #require(callers.first {
            session.paths.resolve($0.callSite.pathID) == "main.rs"
        })
        #expect(caller.callSite.localKind == .callSite)
        #expect(caller.certainty == .strong)
        #expect(hasUniqueImport(caller.evidence))

        let definitions = try session.definitions(of: "connect", context: context)
        #expect(definitions.allSatisfy { $0.0.localKind == .declarationFacet })
        #expect(definitions.map { session.paths.resolve($0.2) } == ["db.rs", "util.rs"])
    }
}

@Test
func resolvesNearestShadowedBinding() throws {
    let source = "fn f() { let g = 1; { let g = 2; g; } }"
    try withProject(["main.rs": source]) { session in
        let path = try #require(pathID("main.rs", in: session))
        let offset = offset(of: "g;", in: source, options: .backwards)
        let resolved = try session.resolve(
            file: path,
            offset: offset,
            context: queryContext(for: session)
        )
        let top = try #require(resolved.first)

        #expect(top.certainty == .strong)
        #expect(top.target.localIndex == 1)
        #expect(hasLexicalBinding(top.evidence, index: 1))
    }
}

@Test
func tokenRangeLocatesNameWithoutResolvingCandidates() throws {
    let source = "fn target() {}\nfn main() { target(); }"
    try withProject(["main.rs": source]) { session in
        let path = try #require(pathID("main.rs", in: session))
        let start = offset(of: "target();", in: source)

        #expect(try session.tokenRange(
            file: path,
            offset: start + 2,
            context: queryContext(for: session)
        ) == ByteRange(lowerBound: start, upperBound: start + 8))
        #expect(try session.tokenRange(
            file: path,
            offset: offset(of: " { target", in: source),
            context: queryContext(for: session)
        ) == nil)
    }
}

@Test
func marksFunctionValueCallAsCallback() throws {
    let source = "fn f() { let h = |x: u32| x; h(1); }"
    try withProject(["main.rs": source]) { session in
        let path = try #require(pathID("main.rs", in: session))
        let resolved = try session.resolve(
            file: path,
            offset: offset(of: "h(1)", in: source),
            context: queryContext(for: session)
        )
        let top = try #require(resolved.first)

        #expect(top.certainty == .strong)
        #expect(top.dispatch == .callback)
        #expect(hasLexicalBinding(top.evidence, index: 0))
    }
}

@Test
func methodCallsStayPossibleAcrossImpls() throws {
    let source = """
        struct A; impl A { fn close(&self) {} }
        struct B; impl B { fn close(&self) {} }
        fn f(c: A) { c.close(); }
        """
    try withProject(["main.rs": source]) { session in
        let path = try #require(pathID("main.rs", in: session))
        let resolved = try session.resolve(
            file: path,
            offset: offset(of: "close();", in: source),
            context: queryContext(for: session)
        )

        #expect(resolved.count == 2)
        #expect(resolved.allSatisfy { $0.certainty == .possible })
        #expect(resolved.allSatisfy { $0.dispatch == .dynamicDispatch })
        #expect(resolved.allSatisfy { hasMethodNameOnly($0.evidence) })
    }
}

@Test
func outgoingCallsResolveEveryRustCallKind() throws {
    let source = """
        fn direct_target() {}
        fn qualified_target() {}
        struct Receiver;
        impl Receiver { fn method_target(&self) {} }
        fn caller(receiver: Receiver) {
            direct_target();
            crate::qualified_target();
            receiver.method_target();
            unknown_macro!();
        }
        """
    try withProject(["main.rs": source]) { session in
        let context = queryContext(for: session)
        let caller = try #require(
            session.definitions(of: "caller", context: context).first?.0
        )
        let result = try session.outgoingCalls(from: caller, context: context)

        #expect(result.completeness == .complete)
        #expect(result.calls.map(\.calleeName) == [
            "direct_target", "qualified_target", "method_target", "unknown_macro",
        ])
        #expect(result.calls.map(\.call.syntacticKind) == [
            .directCall, .qualifiedCall, .methodCall, .macroInvocation,
        ])

        let direct = try #require(result.calls[0].candidates.first)
        #expect(direct.certainty == .strong)
        #expect(direct.dispatch == .direct)
        #expect(direct.provenance == .fuzzyResolver)
        #expect(direct.completeness == .complete)

        let qualified = try #require(result.calls[1].candidates.first)
        #expect(qualified.certainty == .strong)
        #expect(qualified.dispatch == .direct)
        #expect(qualified.provenance == .fuzzyResolver)
        #expect(qualified.completeness == .complete)

        let method = try #require(result.calls[2].candidates.first)
        #expect(method.certainty == .possible)
        #expect(method.dispatch == .dynamicDispatch)
        #expect(method.provenance == .fuzzyResolver)
        #expect(method.completeness == .complete)
        #expect(result.calls[3].candidates.isEmpty)
    }
}

@Test
func outgoingCallsIncludeClosuresButExcludeNestedNamedFunctions() throws {
    let source = """
        fn direct() {}
        fn in_closure() {}
        fn in_nested() {}
        fn outer() {
            direct();
            let closure = || in_closure();
            fn nested() { in_nested(); }
            nested();
        }
        """
    try withProject(["main.rs": source]) { session in
        let context = queryContext(for: session)
        let outer = try #require(
            session.definitions(of: "outer", context: context).first?.0
        )
        let nested = try #require(
            session.definitions(of: "nested", context: context).first?.0
        )

        #expect(try session.outgoingCalls(
            from: outer,
            context: context
        ).calls.map(\.calleeName) == ["direct", "in_closure", "nested"])
        #expect(try session.outgoingCalls(
            from: nested,
            context: context
        ).calls.map(\.calleeName) == ["in_nested"])
    }
}

@Test
func outgoingCallsFollowConstantInitializerRegionOwnership() throws {
    let source = "fn initialize() {}\nconst VALUE: () = initialize();"
    try withProject(["main.rs": source]) { session in
        let context = queryContext(for: session)
        let constant = try #require(
            session.definitions(of: "VALUE", context: context).first?.0
        )
        let result = try session.outgoingCalls(from: constant, context: context)

        #expect(result.completeness == .complete)
        #expect(result.calls.map(\.calleeName) == ["initialize"])
    }
}

@Test
func outgoingCallsTruncateAfterFirst512CallSites() throws {
    let body = Array(repeating: "target();", count: 513).joined(separator: "\n")
    let source = "fn target() {}\nfn caller() {\n\(body)\n}"
    try withProject(["main.rs": source]) { session in
        let context = queryContext(for: session)
        let caller = try #require(
            session.definitions(of: "caller", context: context).first?.0
        )
        let result = try session.outgoingCalls(from: caller, context: context)

        #expect(result.completeness == .truncated)
        #expect(result.calls.count == 512)
        #expect(result.calls.map(\.call.range.lowerBound) == result.calls
            .map(\.call.range.lowerBound).sorted())
        #expect(result.calls.last?.callSite.localIndex == 511)
    }
}

@Test
func findsTraitImplementationsAndMethodOverrides() throws {
    try withProject([
        "main.rs": """
            trait Render { fn render(&self); }
            struct Simple;
            impl Render for Simple { fn render(&self) {} }
            struct Boxed<T>(T);
            impl<T> Render for Boxed<T> { fn render(&self) {} }
            struct Inherent;
            impl Inherent { fn render(&self) {} }
            """,
        "a.rs": """
            trait Duplicate { fn act(&self); }
            struct A;
            impl Duplicate for A { fn act(&self) {} }
            """,
        "b.rs": """
            trait Duplicate { fn act(&self); }
            struct B;
            impl Duplicate for B { fn act(&self) {} }
            """,
    ]) { session in
        let context = queryContext(for: session)
        let implementations = try session.implementations(
            ofTrait: "Render",
            context: context
        )
        #expect(implementations.map(\.typeName) == ["Simple", "Boxed"])
        #expect(implementations.allSatisfy { $0.certainty == .strong })
        #expect(implementations.allSatisfy {
            $0.traitDefinitions.count == 1
                && $0.traitDefinitions[0].certainty == .strong
                && $0.traitDefinitions[0].dispatch == .traitDispatch
        })

        let renderTrait = try #require(session.definitions(
            of: "Render",
            context: context
        ).first)
        let renderIndex = try #require(session.contentIndexes.first(where: {
            key, _ in key.contentID == session.manifest.files.first(where: {
                $0.pathID == renderTrait.2
            })?.contentID
        })?.value)
        let renderMethodIndex = try #require(renderIndex.symbols.firstIndex {
            $0.kind == .rustMethod
                && $0.parentFacetIndex == renderTrait.0.localIndex
                && session.names.resolve($0.nameID) == "render"
        })
        let overrides = try session.overrides(
            ofTraitMethod: SymbolOccurrenceID(
                snapshotID: session.snapshotID,
                pathID: renderTrait.2,
                localKind: .declarationFacet,
                localIndex: UInt32(renderMethodIndex)
            ),
            context: context
        )
        #expect(overrides.count == 2)
        #expect(overrides.allSatisfy {
            $0.certainty == .strong && $0.dispatch == .traitDispatch
        })

        let ambiguous = try session.implementations(
            ofTrait: "Duplicate",
            context: context
        )
        #expect(ambiguous.map(\.typeName) == ["A", "B"])
        #expect(ambiguous.allSatisfy {
            $0.certainty == .possible
                && $0.traitDefinitions.count == 2
                && $0.traitDefinitions.allSatisfy { $0.certainty == .possible }
        })
    }
}

@Test
func deduplicatesContentButKeepsEveryManifestPath() throws {
    let source = "pub fn same() {}"
    try withProject(["a.rs": source, "nested/b.rs": source]) { session in
        #expect(session.stats.fileCount == 2)
        #expect(session.stats.uniqueContentCount == 1)
        #expect(session.manifest.files.count == 2)
        #expect(Set(session.manifest.files.map {
            session.paths.resolve($0.pathID)
        }) == ["a.rs", "nested/b.rs"])
    }
}

@Test
func indexingIsDeterministicAcrossRuns() throws {
    try withProjectRoot(determinismFixture) { root in
        let first = try ProjectIndexer().index(root: root)
        let second = try ProjectIndexer().index(root: root)

        #expect(canonicalSessionDump(first) == canonicalSessionDump(second))
        #expect(aggregateStatsDump(first.stats) == aggregateStatsDump(second.stats))
    }
}

@Test
func parallelIndexMatchesSerialIndex() throws {
    try withProjectRoot(determinismFixture) { root in
        let serial = try ProjectIndexer(parallelism: 1).index(root: root)
        let parallel = try ProjectIndexer(parallelism: 4).index(root: root)

        #expect(canonicalSessionDump(serial) == canonicalSessionDump(parallel))
        #expect(aggregateStatsDump(serial.stats) == aggregateStatsDump(parallel.stats))
    }
}

@Test
func rejectsWrongSnapshotAcrossEveryQueryAPI() throws {
    try withProject(["main.rs": "fn main() {}"] ) { session in
        let definition = try #require(session.definitions(
            of: "main",
            context: queryContext(for: session)
        ).first?.0)
        let wrong = QueryContext(
            snapshotID: SnapshotID(rawValue: UUID()),
            analysisProfileID: session.analysisProfile.id,
            generation: 1
        )
        let path = try #require(pathID("main.rs", in: session))
        var failures = 0
        do { _ = try session.definitions(of: "main", context: wrong) }
        catch { failures += 1 }
        do { _ = try session.callers(of: "main", context: wrong) }
        catch { failures += 1 }
        do { _ = try session.resolve(file: path, offset: 3, context: wrong) }
        catch { failures += 1 }
        do { _ = try session.tokenRange(file: path, offset: 3, context: wrong) }
        catch { failures += 1 }
        do { _ = try session.outgoingCalls(from: definition, context: wrong) }
        catch { failures += 1 }
        do { _ = try session.implementations(ofTrait: "main", context: wrong) }
        catch { failures += 1 }
        do { _ = try session.overrides(ofTraitMethod: definition, context: wrong) }
        catch { failures += 1 }
        do {
            _ = try session.searchSymbols(
                query: "main",
                limit: 10,
                boost: SearchBoost(),
                context: wrong
            )
        } catch { failures += 1 }
        #expect(failures == 8)
    }
}

@Test
func rejectsWrongProfileAcrossEveryQueryAPI() throws {
    try withProject(["main.rs": "fn main() {}"] ) { session in
        let definition = try #require(session.definitions(
            of: "main",
            context: queryContext(for: session)
        ).first?.0)
        let wrong = QueryContext(
            snapshotID: session.snapshotID,
            analysisProfileID: AnalysisProfileID(rawValue: UUID()),
            generation: 1
        )
        let path = try #require(pathID("main.rs", in: session))
        var failures = 0
        do { _ = try session.definitions(of: "main", context: wrong) }
        catch { failures += 1 }
        do { _ = try session.callers(of: "main", context: wrong) }
        catch { failures += 1 }
        do { _ = try session.resolve(file: path, offset: 3, context: wrong) }
        catch { failures += 1 }
        do { _ = try session.tokenRange(file: path, offset: 3, context: wrong) }
        catch { failures += 1 }
        do { _ = try session.outgoingCalls(from: definition, context: wrong) }
        catch { failures += 1 }
        do { _ = try session.implementations(ofTrait: "main", context: wrong) }
        catch { failures += 1 }
        do { _ = try session.overrides(ofTraitMethod: definition, context: wrong) }
        catch { failures += 1 }
        do {
            _ = try session.searchSymbols(
                query: "main",
                limit: 10,
                boost: SearchBoost(),
                context: wrong
            )
        } catch { failures += 1 }
        #expect(failures == 8)
    }
}

@Test
func externalRustImportDoesNotCrash() throws {
    let source = "use std::io::Read; fn f() { Read(); }"
    try withProject(["main.rs": source]) { session in
        let path = try #require(pathID("main.rs", in: session))
        let resolved = try session.resolve(
            file: path,
            offset: offset(of: "Read();", in: source),
            context: queryContext(for: session)
        )

        let top = try #require(resolved.first)
        #expect(top.certainty == .unresolved)
        #expect(top.target.localKind == .importBinding)
    }
}

@Test
func indexesProgrammaticallyGeneratedProject() throws {
    let files = Dictionary(uniqueKeysWithValues: (0..<200).map { fileIndex in
        let source = (0..<20).map {
            "fn file_\(fileIndex)_function_\($0)() {}"
        }.joined(separator: "\n")
        return ("file_\(fileIndex).rs", source)
    })

    try withProject(files) { session in
        #expect(session.stats.fileCount == 200)
        #expect(session.stats.uniqueContentCount == 200)
        #expect(session.stats.symbolCount == 4_000)
        #expect(session.stats.bindingCount == 0)
        #expect(session.stats.callCount == 0)
        #expect(session.stats.importCount == 0)
        #expect(session.stats.filesWithErrorNodes == 0)
    }
}

@Test
func evaluatesGoldSetMetricsAndKnownFailures() throws {
    let fixture = repositoryRoot.appendingPathComponent("goldset/fixtures/runner")
    let report = try evaluateGoldSet(
        at: fixture.appendingPathComponent("sample.gold"),
        corpus: fixture
    )

    #expect(report.total == 8)
    #expect(report.defTop1Passed == 1)
    #expect(report.defTop1Total == 2)
    #expect(report.def5Top5Passed == 1)
    #expect(report.def5Top5Total == 1)
    #expect(report.noStrongViolations == 1)
    #expect(report.unresolvedPassed == 1)
    #expect(report.unresolvedTotal == 1)
    #expect(report.noResults == 1)
    #expect(report.knownFailures == 2)
    #expect(report.unexpectedFailures == 0)

    let failing = try evaluateGoldSet(
        at: fixture.appendingPathComponent("unexpected.gold"),
        corpus: fixture
    )
    #expect(failing.total == 1)
    #expect(failing.unexpectedFailures == 1)
}

@Test
func symbolSearchNormalizesAndUsesEveryRecallRoute() throws {
    let normalized = SymbolSearchIndex.normalize("HTTPServer_value")
    #expect(normalized.text == "httpservervalue")
    #expect(normalized.wordStarts == [0, 4, 10])
    #expect(normalized.acronym == "hsv")

    try withProject([
        "main.rs": "fn handle_connection() {} fn hyper_client() {} fn middle() {}",
    ]) { session in
        let context = queryContext(for: session)
        let prefix = try searchedNames("hand", session: session, context: context)
        let acronym = try searchedNames("hc", session: session, context: context)
        let trigram = try searchedNames("ddl", session: session, context: context)
        #expect(prefix.contains("handle_connection"))
        #expect(acronym.contains("hyper_client"))
        #expect(trigram.contains("middle"))
    }
}

@Test
func symbolSearchRanksSubsequenceAndWordBoundaries() throws {
    try withProject([
        "main.rs": """
            fn handle_connection() {}
            fn handleconnection() {}
            fn handle_disconnected_connection() {}
            """,
    ]) { session in
        let context = queryContext(for: session)
        let fuzzy = try searchedNames("hndlconn", session: session, context: context)
        #expect(fuzzy.first == "handle_connection")

        let boundary = try searchedNames("handlecon", session: session, context: context)
        #expect(boundary.first == "handle_connection")
    }
}

@Test
func symbolSearchBoostsCurrentFileAndIsDeterministic() throws {
    try withProject([
        "a.rs": "fn target_name() {}",
        "nested/b.rs": "fn target_name() {}",
    ]) { session in
        let context = queryContext(for: session)
        let current = try #require(pathID("nested/b.rs", in: session))
        let boost = SearchBoost(currentFile: current, recentFiles: [])
        let first = try session.searchSymbols(
            query: "target",
            limit: 10,
            boost: boost,
            context: context
        )
        let second = try session.searchSymbols(
            query: "target",
            limit: 10,
            boost: boost,
            context: context
        )

        #expect(first.first?.path == "nested/b.rs")
        #expect(first.count == second.count)
        #expect(zip(first, second).allSatisfy { lhs, rhs in
            lhs.path == rhs.path
                && lhs.occurrence.localIndex == rhs.occurrence.localIndex
                && lhs.score == rhs.score
                && lhs.matchRanges == rhs.matchRanges
        })
    }
}

private func withProject(
    _ files: [String: String],
    test: (EngineSession) throws -> Void
) throws {
    try withProjectRoot(files) { root in
        try test(ProjectIndexer().index(root: root))
    }
}

private func withProjectRoot(
    _ files: [String: String],
    test: (URL) throws -> Void
) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodeInsightEngineTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    for (path, contents) in files {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: file, atomically: true, encoding: .utf8)
    }
    try test(root)
}

private let determinismFixture = [
    "a.rs": "use crate::z::run as go; fn main() { go(); }",
    "copy.rs": "pub fn run() {}",
    "nested/model.rs": "struct Model { value: u32 } impl Model { fn read(&self) {} }",
    "z.rs": "pub fn run() {}",
]

private func canonicalSessionDump(_ session: EngineSession) -> String {
    var lines: [String] = []
    var seen: Set<ContentIndexKey> = []
    for file in session.manifest.files {
        lines.append("path #\(file.pathID.rawValue) \(session.paths.resolve(file.pathID))")
        let entry = session.contentIndexes.first { key, _ in
            key.contentID == file.contentID && key.languageMode.language == .rust
        }!
        guard seen.insert(entry.key).inserted else { continue }
        let index = entry.value
        lines.append(CanonicalDump.render(
            index,
            names: session.names,
            strings: session.strings
        ))
        lines.append("bindingNames \(index.bindings.map { $0.localNameID.rawValue })")
        lines.append("bindingTargets \(index.bindings.map { $0.targetHint?.nameID.rawValue })")
        lines.append("symbolNames \(index.symbols.map { $0.nameID.rawValue })")
        lines.append("callNames \(index.calls.map { $0.nameID.rawValue })")
        lines.append("importStrings \(index.imports.map { $0.moduleSpecifier.rawValue })")
        lines.append("importNames \(index.imports.map { [$0.importedName?.rawValue, $0.localName?.rawValue] })")
        lines.append("exportNames \(index.exports.map { $0.exportedName.rawValue })")
    }
    return lines.joined(separator: "\n")
}

private func aggregateStatsDump(_ stats: IndexStats) -> String {
    [
        stats.fileCount,
        stats.uniqueContentCount,
        stats.scopeCount,
        stats.bindingCount,
        stats.symbolCount,
        stats.callCount,
        stats.importCount,
        stats.filesWithErrorNodes,
    ].map(String.init).joined(separator: ",")
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

private func searchedNames(
    _ query: String,
    session: EngineSession,
    context: QueryContext
) throws -> [String] {
    try session.searchSymbols(
        query: query,
        limit: 20,
        boost: SearchBoost(),
        context: context
    ).map { session.names.resolve($0.nameID) }
}

private func offset(
    of needle: String,
    in source: String,
    options: String.CompareOptions = []
) -> UInt32 {
    let range = source.range(of: needle, options: options)!
    return UInt32(source[..<range.lowerBound].utf8.count)
}

private func hasUniqueImport(_ evidence: [ResolutionEvidence]) -> Bool {
    evidence.contains {
        if case .uniqueImport = $0 { return true }
        return false
    }
}

private func hasLexicalBinding(
    _ evidence: [ResolutionEvidence],
    index: UInt32
) -> Bool {
    evidence.contains {
        if case let .lexicalBinding(bindingIndex) = $0 {
            return bindingIndex == index
        }
        return false
    }
}

private func hasMethodNameOnly(_ evidence: [ResolutionEvidence]) -> Bool {
    evidence.contains {
        if case .methodNameOnly = $0 { return true }
        return false
    }
}
