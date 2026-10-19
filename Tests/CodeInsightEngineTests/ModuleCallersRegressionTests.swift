import CodeInsightCore
@testable import CodeInsightEngine
import Foundation
import Testing

@Test
func rustFileModuleResolvesChildWithinItsOwnDirectory() throws {
    let source = "mod foo;\nuse crate::foo::child::hello;\n\npub fn entry() {\n    hello();\n}\n"
    for hasDecoy in [false, true] {
        var files = [
            "Cargo.toml": "[package]\nname = \"modmap\"\nversion = \"0.1.0\"\nedition = \"2021\"\n",
            "src/lib.rs": source,
            "src/foo.rs": "pub mod child;\n",
            "src/foo/child.rs": "pub fn hello() {}\n",
        ]
        if hasDecoy { files["src/child.rs"] = "pub fn hello() {}\n" }
        try withRegressionProject(files) { session in
            let path = try #require(regressionPath("src/lib.rs", in: session))
            let context = regressionContext(session)
            let candidates = try session.resolve(
                file: path,
                offset: UInt32(source[..<source.range(of: "hello();")!.lowerBound].utf8.count),
                context: context
            )
            let candidate = try #require(candidates.first)
            #expect(candidate.certainty == .strong)
            #expect(session.paths.resolve(candidate.target.pathID) == "src/foo/child.rs")
        }
    }
}

@Test
func occurrenceCallersExcludeCallsResolvedToAnotherDefinition() throws {
    try withRegressionProject([
        "src/lib.rs": "mod a;\nmod b;\n",
        "src/a.rs": "fn run() {}\nfn caller_a() { run(); }\n",
        "src/b.rs": "fn run() {}\nfn caller_b() { run(); }\n",
    ]) { session in
        let context = regressionContext(session)
        let definition = try #require(session.definitions(of: "run", context: context).first {
            session.paths.resolve($0.2) == "src/a.rs"
        }?.0)
        let callers = try session.callers(of: definition, context: context)
        #expect(callers.map { session.paths.resolve($0.callSite.pathID) } == ["src/a.rs"])
        #expect(callers.first?.certainty == .strong)
        #expect(try session.callers(of: "run", context: context).count == 2)
    }
}

private func withRegressionProject(
    _ files: [String: String],
    test: (EngineSession) throws -> Void
) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "module-callers-\(UUID().uuidString)"
    )
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

private func regressionPath(_ path: String, in session: EngineSession) -> PathID? {
    session.manifest.files.first { session.paths.resolve($0.pathID) == path }?.pathID
}

private func regressionContext(_ session: EngineSession) -> QueryContext {
    QueryContext(
        snapshotID: session.snapshotID,
        analysisProfileID: session.analysisProfile.id,
        generation: 1
    )
}
