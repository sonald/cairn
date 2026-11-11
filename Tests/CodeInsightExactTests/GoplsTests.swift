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

/// Messages as gopls v0.19.1 logged them in the feasibility probes.
@Test
func goplsOutputMarksMissingModulesAndNamesTheToolchainGoNeeds() {
    let base = ExactAnalysisEnvironment(trustMode: .safe)
    let lookup = "window/logMessage: initial workspace load failed: packages.Load error: "
        + "err: exit status 1: stderr: go: github.com/cpuguy83/go-md2man/v2@v2.0.6: "
        + "module lookup disabled by GOPROXY=off"
    #expect(goplsEnvironment(base: base, diagnostic: lookup).limitations
        == [.dependenciesUnavailableOffline])
    #expect(goplsEnvironment(base: base, diagnostic: "Created View (#1)").limitations.isEmpty)

    let toolchain = #"window/logMessage: Optional(["message": "go/packages.Load #1: err: "#
        + #"exit status 1: stderr: go: go.mod requires go >= 1.99 (running go 1.27.3; "#
        + #"GOTOOLCHAIN=local)\n\n\tview_id=\"1\""])"#
    #expect(goplsUnavailableReason(toolchain)
        == "go.mod requires go >= 1.99 (running go 1.27.3; GOTOOLCHAIN=local)")
    #expect(goplsUnavailableReason(lookup) == nil)
}

@Test(.enabled(if: goTools != nil, "gopls or go is not installed"))
func goplsLabelsAModuleWhoseRequirementIsNotInTheModuleCache() throws {
    // `go 1.15` has no pruned module graph: go list needs every required
    // module's go.mod, and the test's module cache is empty.
    let fixture = try GoFixture([
        "go.mod": "module example.com/missing\n\ngo 1.15\n\nrequire example.invalid/dep v1.0.0\n",
        "go.sum": """
            example.invalid/dep v1.0.0 h1:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
            example.invalid/dep v1.0.0/go.mod h1:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=

            """,
        "main.go": "package main\n\nfunc answer() int { return 1 }\n\nfunc main() { _ = answer() }\n",
    ])
    let session = try fixture.session()
    defer { session.close() }
    _ = try? session.definition(
        file: "main.go",
        byteOffset: fixture.offset(of: "answer", in: "main.go", occurrence: 2)
    )
    #expect(eventually {
        session.attribution.environment.limitations.contains(.dependenciesUnavailableOffline)
    })
}

@Test(.enabled(if: goTools != nil, "gopls or go is not installed"))
func goplsBecomesUnavailableWithGosWordsWhenGoModNeedsANewerGo() throws {
    let fixture = try GoFixture([
        "go.mod": "module example.com/newgo\n\ngo 1.99\n",
        "main.go": "package main\n\nfunc answer() int { return 1 }\n\nfunc main() { _ = answer() }\n",
    ])
    let session = try fixture.session()
    defer { session.close() }
    _ = try? session.definition(
        file: "main.go",
        byteOffset: fixture.offset(of: "answer", in: "main.go", occurrence: 2)
    )
    #expect(eventually {
        guard case .unavailable(let reason) = session.readiness else { return false }
        return reason.hasPrefix("go.mod requires go >= 1.99 (running go ")
            && reason.contains("; GOTOOLCHAIN=local)")
    })
    // No restart: the same toolchain would fail the same way.
    #expect(throws: ExactError.self) {
        try session.definition(file: "main.go", byteOffset: 0)
    }
}
