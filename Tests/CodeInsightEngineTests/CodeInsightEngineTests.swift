import CodeInsightCore
import CodeInsightEngine
import Foundation
import Testing

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
func rejectsWrongSnapshotAcrossEveryQueryAPI() throws {
    try withProject(["main.rs": "fn main() {}"] ) { session in
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
        #expect(failures == 3)
    }
}

@Test
func rejectsWrongProfileAcrossEveryQueryAPI() throws {
    try withProject(["main.rs": "fn main() {}"] ) { session in
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
        #expect(failures == 3)
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

private func withProject(
    _ files: [String: String],
    test: (EngineSession) throws -> Void
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
    try test(ProjectIndexer().index(root: root))
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
