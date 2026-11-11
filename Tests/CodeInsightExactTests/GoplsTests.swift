import CodeInsightCore
import CodeInsightGit
import Foundation
import Testing

@testable import CodeInsightExact

private let goTools: (gopls: URL, go: URL)? = {
    let root = FileManager.default.temporaryDirectory
    guard let gopls = GoplsProvider.findExecutable(named: "gopls", projectURL: root),
          let go = GoplsProvider.findExecutable(named: "go", projectURL: root)
    else { return nil }
    return (gopls, go)
}()

/// A Go module written to a fresh directory, served by a sandboxed gopls
/// whose module cache is the test's own (empty unless the test fills it).
private final class GoFixture {
    let root: URL
    let scratch: URL
    let files: [String: String]

    init(_ files: [String: String]) throws {
        scratch = try temporaryTestDirectory()
        root = scratch.appendingPathComponent("module", isDirectory: true)
        self.files = files
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(text.utf8).write(to: url)
        }
        try FileManager.default.createDirectory(
            at: scratch.appendingPathComponent("modcache"),
            withIntermediateDirectories: true
        )
    }

    deinit { try? FileManager.default.removeItem(at: scratch) }

    func session(requestTimeout: TimeInterval = 60) throws -> any ExactSession {
        let tools = try #require(goTools)
        let snapshot = try DirectorySnapshot(root: root, files: files.keys.sorted())
        do {
            let provider = try GoplsProvider(
                projectURL: root,
                executableURL: tools.gopls,
                goURL: tools.go,
                cacheURL: scratch.appendingPathComponent("cache"),
                requestTimeout: requestTimeout,
                closeGrace: 2,
                environmentOverrides: [
                    "GOMODCACHE": scratch.appendingPathComponent("modcache").path,
                ]
            )
            return try provider.prepare(
                snapshot: snapshot,
                profile: ExactProfileKey(snapshot: snapshot, language: .go),
                trustMode: .safe
            )
        } catch ExactError.unavailable(let detail) where detail.contains("sandbox-exec") {
            try Test.cancel("gopls: \(detail); noBareExecution=true")
        }
    }

    /// Byte offset of the `occurrence`-th `needle` in `path`.
    func offset(of needle: String, in path: String, occurrence: Int = 1) throws -> Int {
        let text = try #require(files[path])
        var searchStart = text.startIndex
        var found: Range<String.Index>?
        for _ in 0..<occurrence {
            found = try #require(text.range(of: needle, range: searchStart..<text.endIndex))
            searchStart = found!.upperBound
        }
        return text[..<found!.lowerBound].utf8.count
    }
}

private let shapes: [String: String] = [
    "go.mod": "module example.com/shapes\n\ngo 1.22\n",
    "shape.go": """
        package shapes

        type Shape interface {
        \tArea() float64
        }

        """,
    "square.go": """
        package shapes

        type Square struct{ Side float64 }

        func (s Square) Area() float64 { return s.Side * s.Side }

        func Total(all []Shape) float64 {
        \tvar sum float64
        \tfor _, s := range all {
        \t\tsum += s.Area()
        \t}
        \treturn sum
        }

        """,
]

@Test(.enabled(if: goTools != nil, "gopls or go is not installed"))
func goplsAnswersDefinitionReferencesAndImplementationsAcrossFiles() throws {
    let fixture = try GoFixture(shapes)
    let session = try fixture.session()
    defer { session.close() }
    #expect(session.negotiatedCapabilities == GoplsProvider.supportedCapabilities)

    let definition = try onlyDefinitionLocation(try session.definition(
        file: "square.go",
        byteOffset: fixture.offset(of: "Shape", in: "square.go")
    ))
    #expect(definition.file == "shape.go")
    #expect(definition.line == 3)

    let references = try #require(try session.references(
        file: "shape.go",
        byteOffset: fixture.offset(of: "Area", in: "shape.go"),
        includeDeclaration: false
    ))
    #expect(references.map { "\($0.file):\($0.line)" } == ["square.go:10"])

    let implementations = try #require(try session.implementations(
        file: "shape.go",
        byteOffset: fixture.offset(of: "Shape", in: "shape.go")
    ))
    #expect(implementations.map { "\($0.file):\($0.line)" } == ["square.go:3"])
    #expect(session.readiness == .ready)
    print("gopls cross-file: \(session.attribution.toolVersion)")
}
