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

/// A session on `.gopls` talking to a fake server over pipes, with
/// `main.go` = "package main\n\nfunc main() {}\n".
private func withFakeGoplsSession(
    requestTimeout: TimeInterval = 5,
    requestResponder: @escaping (_ method: String, _ mainURI: String) -> PipeFakeRequestResponse
        = { _, _ in .useDefault },
    body: (LSPLanguageSession, PipeFakeLSPServer) throws -> Void
) throws {
    let root = try temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("package main\n\nfunc main() {}\n".utf8)
        .write(to: root.appendingPathComponent("main.go"))
    let mainURI = root.appendingPathComponent("main.go").absoluteString
    let clientToServer = Pipe()
    let serverToClient = Pipe()
    let done = DispatchSemaphore(value: 0)
    let server = PipeFakeLSPServer(
        input: clientToServer.fileHandleForReading,
        output: serverToClient.fileHandleForWriting,
        serverStatusQuiescent: false,
        requestResponder: { method, _ in requestResponder(method, mainURI) },
        done: { done.signal() }
    )
    server.start()
    let session = try LSPLanguageSession.start(
        client: LSPClient(
            readHandle: serverToClient.fileHandleForReading,
            writeHandle: clientToServer.fileHandleForWriting
        ),
        restartClient: { throw ExactError.unavailable("fake restart unavailable") },
        projectURL: root,
        snapshot: try DirectorySnapshot(root: root, files: ["main.go"]),
        language: .gopls,
        requestTimeout: requestTimeout,
        closeGrace: 5,
        attribution: exactTestAttribution(provider: "fake-gopls")
    )
    defer {
        session.close()
        _ = done.wait(timeout: .now() + 5)
    }
    try body(session, server)
}

private func sendWorkspaceLoad(_ kind: String, to server: PipeFakeLSPServer) throws {
    try server.sendNotification("$/progress", [
        "token": "1",
        "value": kind == "begin"
            ? ["kind": "begin", "title": "Setting up workspace"]
            : ["kind": "end", "message": "Finished loading packages."],
    ])
}

/// gopls answers nothing until its workspace load ends, which on a large
/// workspace outlasts the request timeout; requests wait for the load's
/// `$/progress` end instead of timing out.
@Test
func goplsRequestsWaitOutAWorkspaceLoadLongerThanTheRequestTimeout() throws {
    let loaded = NSLockedFlag()
    try withFakeGoplsSession(
        requestTimeout: 0.5,
        requestResponder: { method, mainURI in
            guard method == "textDocument/definition" else { return .useDefault }
            // Held while loading, as gopls does; the client gives up first.
            return loaded.value
                ? .result([
                    "uri": mainURI,
                    "range": [
                        "start": ["line": 2, "character": 5],
                        "end": ["line": 2, "character": 9],
                    ],
                ])
                : .noResponse
        }
    ) { session, server in
        try sendWorkspaceLoad("begin", to: server)
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
            loaded.set()
            try? sendWorkspaceLoad("end", to: server)
        }

        let location = try onlyDefinitionLocation(try session.definition(
            file: "main.go",
            byteOffset: "package main\n\nfunc ".utf8.count
        ))

        #expect(location.file == "main.go")
        #expect(location.line == 3)
        #expect(session.readiness == .ready)
    }
}

/// The status bar says preparing while gopls loads and ready once it is
/// done, without a request in between.
@Test
func goplsSessionIsPreparingUntilTheWorkspaceLoadEnds() throws {
    try withFakeGoplsSession { session, server in
        let ready = DispatchSemaphore(value: 0)
        session.onReady = { ready.signal() }
        try sendWorkspaceLoad("begin", to: server)
        #expect(session.readiness == .preparing)
        #expect(ready.wait(timeout: .now() + 0.5) == .timedOut)
        try sendWorkspaceLoad("end", to: server)
        #expect(ready.wait(timeout: .now() + 5) == .success)
        #expect(session.readiness == .ready)
    }
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

/// Evidence §2: after a warm switch the first request already answers from
/// the target commit, including a file that was never opened.
@Test(.enabled(if: goTools != nil, "gopls or go is not installed"))
func goplsWarmSwitchAnswersFromTheTargetCommitAtOnce() throws {
    let tools = try #require(goTools)
    let fixture = try ExactGitFixture()
    defer { fixture.remove() }
    try fixture.write("module example.com/history\n\ngo 1.22\n", to: "go.mod")
    try fixture.write("package history\n\nfunc Answer() int { return 1 }\n", to: "answer.go")
    try fixture.write("package history\n\nvar value = Answer()\n", to: "use.go")
    try fixture.commit("definition line 3")
    try fixture.write(
        "package history\n\n// moved\n// again\nfunc Answer() int { return 2 }\n",
        to: "answer.go"
    )
    try fixture.commit("definition line 5")
    let head = try CommitSnapshot(repositoryURL: fixture.root)
    let previous = try CommitSnapshot(repositoryURL: fixture.root, revision: "HEAD~1")
    let scratch = try temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let checkout = try CheckoutRoot(
        directory: scratch.appendingPathComponent("checkout"),
        source: fixture.root
    )
    defer { try? checkout.remove() }
    try FileManager.default.createDirectory(
        at: scratch.appendingPathComponent("modcache"),
        withIntermediateDirectories: true
    )
    try checkout.checkout(commit: head.commitOID)
    let session: any ExactSession
    do {
        session = try GoplsProvider(
            projectURL: checkout.url,
            executableURL: tools.gopls,
            goURL: tools.go,
            cacheURL: scratch.appendingPathComponent("cache"),
            requestTimeout: 60,
            closeGrace: 2,
            environmentOverrides: [
                "GOMODCACHE": scratch.appendingPathComponent("modcache").path,
            ]
        ).prepare(
            snapshot: head,
            profile: ExactProfileKey(snapshot: head, language: .go),
            trustMode: .safe
        )
    } catch ExactError.unavailable(let detail) where detail.contains("sandbox-exec") {
        try Test.cancel("gopls warm switch: \(detail); noBareExecution=true")
    }
    defer { session.close() }
    let call = "package history\n\nvar value = ".utf8.count
    let before = try onlyDefinitionLocation(try session.definition(file: "use.go", byteOffset: call))

    try session.switchSnapshot(
        to: previous,
        profile: ExactProfileKey(snapshot: previous, language: .go),
        changes: ExactFileChange.changes(from: head, to: previous, under: checkout.url),
        configChanged: false,
        prepareFiles: { try checkout.checkout(commit: previous.commitOID) }
    )
    let after = try onlyDefinitionLocation(try session.definition(file: "use.go", byteOffset: call))

    #expect("\(before.file):\(before.line)" == "answer.go:5")
    #expect("\(after.file):\(after.line)" == "answer.go:3")
}

// MARK: Dependency download

/// Every file under `root` (`.git` excluded) with its bytes.
private func tree(_ root: URL) throws -> [String: Data] {
    var files: [String: Data] = [:]
    let base = root.resolvingSymlinksInPath().path + "/"
    let walk = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
    for case let url as URL in walk {
        let path = String(url.resolvingSymlinksInPath().path.dropFirst(base.count))
        if path == ".git" { walk.skipDescendants(); continue }
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        files[path] = isDirectory.boolValue ? Data() : try Data(contentsOf: url)
    }
    return files
}

/// The download's environment with a module cache the test owns.
private func downloadEnvironment(modcache: URL) -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    environment["GOMODCACHE"] = modcache.path
    // The module cache is read-only by default; the test deletes it.
    environment["GOFLAGS"] = "-modcacherw"
    return environment
}

@Test(.enabled(if: goTools != nil, "go is not installed"))
func goDownloadRunsPerWorkspaceModuleAgainstCopiesAndLeavesTheRepositoryUnchanged() async throws {
    let fixture = try GoFixture([
        "go.work": "go 1.22\n\nuse (\n\t./a // first\n\t\"./b\"\n)\n",
        "a/go.mod": "module example.com/a\n\ngo 1.22\n",
        "a/go.sum": "",
        "a/a.go": "package a\n",
        "b/go.mod": "module example.com/b\n\ngo 1.22\n",
        "b/go.sum": "",
        "b/b.go": "package b\n",
    ])
    #expect(goModules(unitRoot: fixture.root) == [
        fixture.root.appendingPathComponent("a").standardizedFileURL,
        fixture.root.appendingPathComponent("b").standardizedFileURL,
    ])
    let setup = try #require(DependencySetup.suggestion(language: .go, unitRoot: fixture.root))
    #expect(setup.command == "go mod download")
    #expect(setup.runsInApp)
    let before = try tree(fixture.root)

    // In workspace mode go refuses `-modfile`.
    try await setup.fetch(
        environment: downloadEnvironment(modcache: fixture.scratch.appendingPathComponent("modcache"))
    )

    #expect(try tree(fixture.root) == before)
    try FileManager.default.createDirectory(
        at: fixture.root.appendingPathComponent("vendor"),
        withIntermediateDirectories: true
    )
    #expect(DependencySetup.suggestion(language: .go, unitRoot: fixture.root)?.runsInApp == false)
}

@Test(.enabled(if: goTools != nil, "go is not installed"))
func goDownloadReportsGosWordsWhenGoModNeedsANewerGo() async throws {
    let fixture = try GoFixture([
        "go.mod": "module example.com/newgo\n\ngo 1.99\n",
        "go.sum": "",
    ])
    let setup = try #require(DependencySetup.suggestion(language: .go, unitRoot: fixture.root))
    // Without GOTOOLCHAIN=local go would try to download go1.99 instead.
    await #expect {
        try await setup.fetch(
            environment: downloadEnvironment(modcache: fixture.scratch.appendingPathComponent("modcache"))
        )
    } throws: { error in
        guard case ExactError.unavailable(let detail) = error else { return false }
        return detail.hasPrefix("go: go.mod requires go >= 1.99 (running go ")
            && detail.hasSuffix("; GOTOOLCHAIN=local)")
    }
}

private let cobraCorpus = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".cache/cairn-corpora/cobra", isDirectory: true)

/// Evidence §5 on cobra adbc881 with two `go.sum` lines removed: the
/// download fills the test's module cache while the repository, its
/// incomplete `go.sum` included, stays byte for byte the same.
@Test(.enabled(
    if: goTools != nil
        && FileManager.default.fileExists(atPath: cobraCorpus.appendingPathComponent(".git").path),
    "go or ~/.cache/cairn-corpora/cobra is unavailable"
))
func goDownloadFillsTheModuleCacheWithoutTouchingAnIncompleteGoSum() async throws {
    let scratch = try temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let clone = scratch.appendingPathComponent("cobra", isDirectory: true)
    let git = URL(fileURLWithPath: "/usr/bin/git")
    for arguments in [
        ["clone", "-q", "--local", "--no-checkout", cobraCorpus.path, clone.path],
        ["-C", clone.path, "checkout", "-q", "--detach", "adbc8813901bba65827259daa8e22ff94ec1f30e"],
    ] {
        let result = try run(executable: git, arguments: arguments)
        try #require(result.status == 0, "\(result.output)")
    }
    let goSum = clone.appendingPathComponent("go.sum")
    let lines = try String(contentsOf: goSum, encoding: .utf8)
        .split(separator: "\n", omittingEmptySubsequences: false)
    try Data(lines.filter { !$0.hasPrefix("github.com/spf13/pflag v1.0.9") }
        .joined(separator: "\n").utf8).write(to: goSum)
    let before = try tree(clone)
    let status = try run(executable: git, arguments: ["-C", clone.path, "status", "--porcelain"])
    let modcache = scratch.appendingPathComponent("modcache")
    let setup = try #require(DependencySetup.suggestion(language: .go, unitRoot: clone))
    #expect(setup.runsInApp)

    do {
        try await setup.fetch(environment: downloadEnvironment(modcache: modcache))
    } catch ExactError.unavailable(let detail)
        where ["dial tcp", "no such host", "i/o timeout", "connection refused", "TLS handshake"]
            .contains(where: detail.contains)
    {
        #expect(try tree(clone) == before)
        try Test.cancel("cobra download: network unavailable: \(detail)")
    }

    #expect(try tree(clone) == before)
    #expect(try run(executable: git, arguments: ["-C", clone.path, "status", "--porcelain"]).output
        == status.output)
    #expect(FileManager.default.fileExists(atPath: modcache
        .appendingPathComponent("cache/download/github.com/spf13/pflag/@v/v1.0.9.zip").path))
}
