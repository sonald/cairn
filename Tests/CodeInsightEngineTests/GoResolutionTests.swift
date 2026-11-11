import CodeInsightCore
@testable import CodeInsightEngine
import CodeInsightGit
import Foundation
import Testing

private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

/// Go's package model end to end on a small module: same-package
/// visibility across files, `pkg.F` through `go.mod`, receiver-typed method
/// calls, build-tag variants, external test packages and `vendor/`.
@Test
func goModuleResolvesPackagesImportsAndReceiversThroughGoldSet() async throws {
    let fixture = repositoryRoot.appendingPathComponent("goldset/fixtures/go-packages")
    let report = try evaluateGoldSet(
        at: fixture.appendingPathComponent("go-packages.gold"), corpus: fixture, language: .go
    )
    #expect(report.total == 21)
    #expect(report.failures.isEmpty, "\(report.failures)")

    let session = try ProjectIndexer().index(root: fixture, language: .go)
    let paths = session.manifest.files.map { session.paths.resolve($0.pathID) }
    #expect(!paths.contains { $0.hasPrefix("vendor/") })
    #expect(session.analysisProfile.projectUnitName == "example.com/shapes")
    let context = QueryContext(snapshotID: session.snapshotID, analysisProfileID: session.analysisProfile.id, generation: 1)

    // Build-tag variants are both project source; neither wins.
    let math = try #require(session.manifest.files.first { session.paths.resolve($0.pathID) == "math.go" })
    let osName = try #require(session.content(at: math.pathID)?.1.calls.first { session.names.resolve($0.nameID) == "osName" })
    let variants = try session.resolve(file: math.pathID, offset: osName.nameRange.lowerBound, context: context)
    #expect(variants.map(\.certainty) == [.probable, .probable])

    let listing = try session.projectSymbols(context: context)
    let area = try #require(listing.symbols.first { $0.name == "Area" && $0.kind == .goMethod && $0.parentFacetIndex == nil })
    #expect(area.receiverTypeName == "Circle")
    let main = try #require(listing.files.first { $0.path == "cmd/app/main.go" })
    #expect(main.modulePath == ["example.com", "shapes", "cmd", "app"])

    var symbolNames: Set<String> = []
    for try await batch in try session.search(ProjectSearchQuery.parse("c.R"), context: context) {
        symbolNames.formUnion(batch.matchesByPath.values.flatMap { $0 }.compactMap(\.symbolName))
    }
    #expect(symbolNames == ["Circle.Area"])
}

/// `go.work` and `go.mod` mark units; a workspace is one unit whose modules
/// import each other, separate modules are separate units.
@Test
func goWorkspaceIsOneUnitAndSeparateModulesAreUnitsOfTheirOwn() throws {
    let hello = Array("package a\n\nfunc Hello() {}\n".utf8)
    let caller = Array("package main\n\nimport \"example.com/a\"\n\nfunc main() { a.Hello() }\n".utf8)
    func snapshot(workspace: Bool) -> GoTestSnapshot {
        var files: [String: [UInt8]] = [
            "a/go.mod": Array("module example.com/a // the library\n".utf8),
            "a/hello.go": hello,
            "b/go.mod": Array("module \"example.com/b\"\n\nrequire example.com/a v0.0.0\n".utf8),
            "b/main.go": caller,
        ]
        if workspace { files["go.work"] = Array("go 1.22\n\nuse (\n\t./a\n\t./b\n)\n".utf8) }
        return GoTestSnapshot(files: files)
    }

    let store = ProjectIndexStore()
    let workspace = try ProjectIndexer().completeSnapshot(
        ProjectIndexer().prepareSnapshot(snapshot(workspace: true), into: store, language: .go)
    )
    #expect(workspace.map(\.analysisProfile.projectUnitName) == ["go.work"])
    let session = try #require(workspace.first)
    let mainPath = try #require(session.manifest.files.first { session.paths.resolve($0.pathID) == "b/main.go" })
    let callOffset = UInt32(caller.count - "Hello() }\n".utf8.count)
    let context = QueryContext(snapshotID: session.snapshotID, analysisProfileID: session.analysisProfile.id, generation: 1)
    let targets = try session.resolve(file: mainPath.pathID, offset: callOffset, context: context)
    #expect(targets.map { session.paths.resolve($0.target.pathID) } == ["a/hello.go"])
    #expect(targets.first?.certainty == .strong)

    let modules = try ProjectIndexer().completeSnapshot(
        ProjectIndexer().prepareSnapshot(snapshot(workspace: false), into: ProjectIndexStore(), language: .go)
    )
    #expect(modules.map(\.analysisProfile.projectUnitName).sorted() == ["example.com/a", "example.com/b"])
    // Across units the import is outside the unit's modules.
    let separate = try #require(modules.first { $0.analysisProfile.projectUnitName == "example.com/b" })
    let separateMain = try #require(separate.manifest.files.first { separate.paths.resolve($0.pathID) == "b/main.go" })
    let separateContext = QueryContext(snapshotID: separate.snapshotID, analysisProfileID: separate.analysisProfile.id, generation: 1)
    #expect(try separate.resolve(file: separateMain.pathID, offset: callOffset, context: separateContext)
        .allSatisfy { $0.certainty == .unresolved })
}

private struct GoTestSnapshot: Snapshot {
    let snapshotID = SnapshotID(rawValue: UUID())
    let objectFormat: GitObjectFormat = .sha1
    let sourceKind: SourceKind = .untracked
    let projectRootName = "workspace"
    let files: [String: [UInt8]]

    /// What GitSnapshot reports once it knows the Go markers.
    var configurationPaths: [String] {
        files.keys.filter { $0.hasSuffix("go.mod") || $0 == "go.work" }.sorted()
    }

    func listFiles() -> [(path: String, contentID: ContentID, fileMode: FileMode)] {
        files.keys.sorted().map { ($0, ContentID.sha256(of: files[$0]!), .regular) }
    }

    func readBytes(path: String) throws -> [UInt8] {
        guard let bytes = files[path] else { throw CocoaError(.fileNoSuchFile) }
        return bytes
    }
}
