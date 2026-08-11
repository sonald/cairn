import CProcessGuard
import CProcessGuardTestSupport
import CodeInsightCore
import CodeInsightGit
import Darwin
import Foundation
import Testing

@testable import CodeInsightExact

@Test
func exactReferencesCapabilityUsesTheNextUnusedBit() {
    #expect(ExactCapabilities.references.rawValue == 1 << 3)
}

@Test
func frameDecoderReadsSingleFrame() throws {
    var decoder = LSPFrameDecoder()
    let messages = try decoder.append(
        LSPFraming.encode([
            "jsonrpc": "2.0", "id": 1, "result": true,
        ]))

    #expect(messages.count == 1)
    #expect(messages[0]["result"] as? Bool == true)
}

@Test
func frameDecoderRetainsSplitFrame() throws {
    let frame = try LSPFraming.encode([
        "jsonrpc": "2.0", "id": 1, "result": "split",
    ])
    var decoder = LSPFrameDecoder()

    #expect(try decoder.append(frame.prefix(9)).isEmpty)
    #expect(try decoder.append(frame.dropFirst(9).prefix(17)).isEmpty)
    let messages = try decoder.append(frame.dropFirst(26))

    #expect(messages.count == 1)
    #expect(messages[0]["result"] as? String == "split")
}

@Test
func frameDecoderReadsCoalescedFrames() throws {
    let first = try LSPFraming.encode([
        "jsonrpc": "2.0", "id": 1, "result": 1,
    ])
    let second = try LSPFraming.encode([
        "jsonrpc": "2.0", "id": 2, "result": 2,
    ])
    var decoder = LSPFrameDecoder()

    let messages = try decoder.append(first + second)

    #expect(messages.count == 2)
    #expect((messages[0]["result"] as? NSNumber)?.intValue == 1)
    #expect((messages[1]["result"] as? NSNumber)?.intValue == 2)
}

@Test
func frameDecoderCountsUTF8Bytes() throws {
    let body = Data(#"{"jsonrpc":"2.0","result":"你好😀"}"#.utf8)
    var frame = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
    frame.append(body)
    var decoder = LSPFrameDecoder()

    let messages = try decoder.append(frame)

    #expect(messages[0]["result"] as? String == "你好😀")
}

@Test
func byteAndLSPUTF16PositionsRoundTrip() throws {
    let bytes = Array("a你😀z\n汉🙂b".utf8)
    let map = try #require(LSPPositionMap(utf8: bytes))
    let positions = [
        (0, LSPPosition(line: 0, character: 0)),
        (1, LSPPosition(line: 0, character: 1)),
        (4, LSPPosition(line: 0, character: 2)),
        (8, LSPPosition(line: 0, character: 4)),
        (10, LSPPosition(line: 1, character: 0)),
        (13, LSPPosition(line: 1, character: 1)),
        (17, LSPPosition(line: 1, character: 3)),
        (18, LSPPosition(line: 1, character: 4)),
    ]

    for (byteOffset, position) in positions {
        #expect(map.position(forByteOffset: byteOffset) == position)
        #expect(map.byteOffset(for: position) == byteOffset)
    }
    #expect(map.position(forByteOffset: 2) == nil)
    #expect(map.byteOffset(for: LSPPosition(line: 0, character: 3)) == nil)
}

@Test
func exactProfileKeyHashesCargoFileBytes() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/exact_fixture", isDirectory: true)

    let profile = try ExactProfileKey(projectURL: root)

    #expect(profile.language == .rust)
    #expect(
        profile.configFingerprint
            == "940ac77af3bcb2c15c059645193eceadc81f5d3b516f312736ef6d6b7afd40a9"
    )
    #expect(
        profile.environmentFingerprint
            == "7f33dae8274d15e6219fcb8705a73a5f5e952fe8404d815ac8cb68685605e3e4"
    )
    #expect(profile.featureSelection == .defaultFeatures)
    #expect(
        try ExactProfileKey(
            projectURL: root,
            featureSelection: .allFeatures
        ).featureSelection == .allFeatures
    )
    #expect(
        try ExactProfileKey(
            projectURL: root,
            language: .rust
        ) == profile
    )
    do {
        _ = try ExactProfileKey(projectURL: root, language: .python)
        Issue.record("expected unsupported exact fingerprint language")
    } catch let error as CocoaError {
        #expect(error.code == .featureUnsupported)
        #expect(
            (error.userInfo[NSLocalizedFailureReasonErrorKey] as? String)?
                .contains("python") == true
        )
    }
}

@Test
func rustAnalyzerMapsFeatureSelectionsToInitializationOptions() {
    let defaultOptions = RustAnalyzerProvider.initializationOptions(
        trustMode: .safe,
        featureSelection: .defaultFeatures
    )
    let allOptions = RustAnalyzerProvider.initializationOptions(
        trustMode: .safe,
        featureSelection: .allFeatures
    )
    let noDefaultOptions = RustAnalyzerProvider.initializationOptions(
        trustMode: .trusted,
        featureSelection: .noDefaultFeatures
    )
    let defaultCargo = defaultOptions["cargo"] as? [String: Any]
    let allCargo = allOptions["cargo"] as? [String: Any]
    let noDefaultCargo = noDefaultOptions["cargo"] as? [String: Any]

    #expect(defaultCargo?["features"] == nil)
    #expect(defaultCargo?["noDefaultFeatures"] == nil)
    #expect(allCargo?["features"] as? String == "all")
    #expect(allCargo?["noDefaultFeatures"] == nil)
    #expect(noDefaultCargo?["features"] == nil)
    #expect(noDefaultCargo?["noDefaultFeatures"] as? Bool == true)
}

@Test
func dependencyFreeProjectIgnoresGenericOfflineFailure() {
    let diagnostic = "workspace loading failed; --offline was specified"

    let base = ExactAnalysisEnvironment(
        trustMode: .safe,
        limitations: [.buildScriptsDisabled, .procMacrosDisabled]
    )
    #expect(rustAnalyzerEnvironment(
        base: base,
        diagnostic: diagnostic
    ).limitations == base.limitations)
}

@Test
func explicitOfflineDependencyFailureAddsLimitation() {
    let diagnostic = """
        error: failed to get `codeinsight-definitely-missing-offline-dependency` \
        as a dependency of package `exact_fixture`

        Caused by:
          error in environment variable `CARGO_NET_OFFLINE`: \
        provided string was not `true` or `false`
        """

    let environment = rustAnalyzerEnvironment(
        base: ExactAnalysisEnvironment(
            trustMode: .trusted,
            limitations: []
        ),
        diagnostic: diagnostic
    )
    #expect(environment.trustMode == .trusted)
    #expect(environment.limitations == [.dependenciesUnavailableOffline])

    let safeEnvironment = rustAnalyzerEnvironment(
        base: ExactAnalysisEnvironment(
            trustMode: .safe,
            limitations: [.buildScriptsDisabled, .procMacrosDisabled]
        ),
        diagnostic: diagnostic
    )
    #expect(safeEnvironment.trustMode == .safe)
    #expect(safeEnvironment.limitations == [
        .buildScriptsDisabled,
        .procMacrosDisabled,
        .dependenciesUnavailableOffline,
    ])
}

@Test
func materializerUsesCommitAndProfileLayoutAndSkipsSpecialFiles() throws {
    let fixture = try MaterializerGitFixture()
    defer { fixture.remove() }
    try fixture.write("[package]\nname='materialized'\nversion='0.1.0'\n", to: "Cargo.toml")
    try fixture.write("pub fn answer() -> u8 { 1 }\n", to: "src/lib.rs")
    try fixture.write(
        "version https://git-lfs.github.com/spec/v1\noid sha256:00\nsize 1\n",
        to: "large.rs"
    )
    try FileManager.default.createSymbolicLink(
        atPath: fixture.root.appendingPathComponent("link.rs").path,
        withDestinationPath: "src/lib.rs"
    )
    try fixture.commit("regular and special files")
    let commit = try #require(
        fixture.git("rev-parse", "HEAD").split(separator: "\n").last.map(String.init)
    )
    try fixture.git(
        "update-index", "--add", "--cacheinfo",
        "160000", commit, "dependency"
    )
    try fixture.git("commit", "-q", "-m", "gitlink")

    let snapshot = try CommitSnapshot(repositoryURL: fixture.root)
    let profile = try ExactProfileKey(snapshot: snapshot)
    let cache = fixture.root.appendingPathComponent("cache/materialized")
    let result = try Materializer(rootURL: cache).materialize(
        snapshot,
        configFingerprint: profile.configFingerprint
    )

    #expect(result.url == cache
        .appendingPathComponent(snapshot.commitOID.hex)
        .appendingPathComponent(profile.configFingerprint))
    #expect(FileManager.default.fileExists(
        atPath: result.url.appendingPathComponent("Cargo.toml").path))
    #expect(FileManager.default.fileExists(
        atPath: result.url.appendingPathComponent("src/lib.rs").path))
    #expect(!FileManager.default.fileExists(
        atPath: result.url.appendingPathComponent("link.rs").path))
    #expect(!FileManager.default.fileExists(
        atPath: result.url.appendingPathComponent("large.rs").path))
    #expect(!FileManager.default.fileExists(
        atPath: result.url.appendingPathComponent("dependency").path))
    #expect(result.filesWritten == snapshot.listFiles().count {
        $0.fileMode == .regular
    })
}

@Test
func materializerReusesACompleteDirectoryWithoutCopying() throws {
    let fixture = try simpleMaterializerFixture()
    defer { fixture.remove() }
    let snapshot = try CommitSnapshot(repositoryURL: fixture.root)
    let profile = try ExactProfileKey(snapshot: snapshot)
    let materializer = Materializer(
        rootURL: fixture.root.appendingPathComponent("cache/materialized")
    )
    let first = try materializer.materialize(
        snapshot,
        configFingerprint: profile.configFingerprint
    )
    let file = first.url.appendingPathComponent("src/lib.rs")
    let modified = try FileManager.default.attributesOfItem(atPath: file.path)[
        .modificationDate
    ] as? Date

    let hit = try materializer.materialize(
        snapshot,
        configFingerprint: profile.configFingerprint
    )

    #expect(hit.url == first.url)
    #expect(hit.filesWritten == 0)
    #expect(try FileManager.default.attributesOfItem(atPath: file.path)[
        .modificationDate
    ] as? Date == modified)
}

@Test
func materializerEvictsTheLeastRecentlyAccessedDirectory() throws {
    let fixture = try MaterializerGitFixture()
    defer { fixture.remove() }
    try fixture.write("[package]\nname='lru'\nversion='0.1.0'\n", to: "Cargo.toml")
    for version in 1...3 {
        try fixture.write(
            "pub fn answer() -> u8 { \(version) }\n",
            to: "src/lib.rs"
        )
        try fixture.commit("version \(version)")
    }
    let oldest = try CommitSnapshot(
        repositoryURL: fixture.root,
        revision: "HEAD~2"
    )
    let middle = try CommitSnapshot(
        repositoryURL: fixture.root,
        revision: "HEAD~1"
    )
    let newest = try CommitSnapshot(repositoryURL: fixture.root)
    let profile = try ExactProfileKey(snapshot: oldest)
    let oneDirectorySize = try oldest.listFiles().reduce(UInt64(0)) {
        $0 + UInt64(try oldest.readBytes(path: $1.path).count)
    }
    let materializer = Materializer(
        rootURL: fixture.root.appendingPathComponent("cache/materialized"),
        quotaBytes: oneDirectorySize * 2
    )
    let old = try materializer.materialize(
        oldest,
        configFingerprint: profile.configFingerprint
    ).url
    let mid = try materializer.materialize(
        middle,
        configFingerprint: profile.configFingerprint
    ).url
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 1)],
        ofItemAtPath: mid.path
    )
    _ = try materializer.materialize(
        oldest,
        configFingerprint: profile.configFingerprint
    )
    let latest = try materializer.materialize(
        newest,
        configFingerprint: profile.configFingerprint
    ).url

    #expect(FileManager.default.fileExists(atPath: old.path))
    #expect(!FileManager.default.fileExists(atPath: mid.path))
    #expect(FileManager.default.fileExists(atPath: latest.path))
}

@Test
func materializedPathRoundTripsToSnapshotPath() throws {
    let root = URL(fileURLWithPath: "/tmp/materialized/commit/config")
    let materialized = try Materializer.materializedURL(
        for: "src/lib.rs",
        under: root
    )

    #expect(materialized.path == "/tmp/materialized/commit/config/src/lib.rs")
    #expect(try Materializer.snapshotPath(
        for: materialized,
        under: root
    ) == "src/lib.rs")
}

@Test
func rustAnalyzerUsesEachMaterializedCommitWhenInstalled() throws {
    guard let executable = RustAnalyzerProvider.findExecutable() else { return }
    let fixture = try MaterializerGitFixture()
    defer { fixture.remove() }
    try fixture.write("[package]\nname='history'\nversion='0.1.0'\nedition='2021'\n", to: "Cargo.toml")
    try fixture.write("pub fn answer() -> u8 { 1 }\n", to: "src/lib.rs")
    try fixture.write("use history::answer;\nfn main() { let _ = answer(); }\n", to: "src/main.rs")
    try fixture.commit("definition line 1")
    try fixture.write("// moved\n// again\npub fn answer() -> u8 { 2 }\n", to: "src/lib.rs")
    try fixture.commit("definition line 3")

    let head = try CommitSnapshot(repositoryURL: fixture.root)
    let previous = try CommitSnapshot(
        repositoryURL: fixture.root,
        revision: "HEAD~1"
    )
    let materializer = Materializer(
        rootURL: fixture.root.appendingPathComponent("materialized")
    )
    do {
        let headLocation = try materializedDefinition(
            snapshot: head,
            materializer: materializer,
            executable: executable,
            cache: fixture.root.appendingPathComponent("ra-head")
        )
        let previousLocation = try materializedDefinition(
            snapshot: previous,
            materializer: materializer,
            executable: executable,
            cache: fixture.root.appendingPathComponent("ra-previous")
        )
        #expect(headLocation.line == 3)
        #expect(previousLocation.line == 1)
        #expect(headLocation.line != previousLocation.line)
        print(
            "historical-exact HEAD=\(headLocation.line):\(headLocation.column)"
                + " HEAD~1=\(previousLocation.line):\(previousLocation.column)"
        )
    } catch ExactError.unavailable(let detail)
        where detail.contains("sandbox-exec")
    {
        print("SKIP historical exact: \(detail); noBareExecution=true")
    }
}

@Test
func pipeFakeRunsInitializeDefinitionShutdownLifecycle() async throws {
    let (exitEvents, exitContinuation) = AsyncStream<Void>.makeStream()
    let (diagnostics, diagnosticContinuation) = AsyncStream<String>.makeStream()

    try await confirmation("fake LSP server received exit") { receivedExit in
        let clientToServer = Pipe()
        let serverToClient = Pipe()
        let server = PipeFakeLSPServer(
            input: clientToServer.fileHandleForReading,
            output: serverToClient.fileHandleForWriting,
            done: {
                receivedExit()
                exitContinuation.finish()
            }
        )
        server.start()
        let client = LSPClient(
            readHandle: serverToClient.fileHandleForReading,
            writeHandle: clientToServer.fileHandleForWriting
        )
        client.observeDiagnostics { [weak client] diagnostic in
            _ = client?.diagnosticText
            diagnosticContinuation.yield(diagnostic)
        }

        _ = try client.initialize(
            rootURL: URL(fileURLWithPath: "/fixture", isDirectory: true),
            timeout: 30
        )
        let diagnostic = await nextDiagnostic(diagnostics)
        let result = try client.request(
            "textDocument/definition",
            params: [
                "textDocument": ["uri": "file:///fixture/src/main.rs"],
                "position": ["line": 0, "character": 0],
            ],
            timeout: 30
        )
        client.close(grace: 30)

        for await _ in exitEvents {}
        #expect(server.error == nil)
        #expect(
            server.requestMethods == [
                "initialize", "textDocument/definition", "shutdown",
            ])
        #expect(Set(server.requestIDs).count == 3)
        #expect(server.receivedInitialized)
        #expect(server.receivedExit)
        #expect(server.receivedRegisterCapabilityResponse)
        #expect(server.receivedImplementationCapability)
        #expect(server.receivedCallHierarchyCapability)
        #expect(server.receivedReferencesCapability)
        #expect(diagnostic?.contains("failed to resolve dependency in offline mode") == true)
        let location = try #require(result as? [String: Any])
        #expect(location["uri"] as? String == "file:///fixture/src/lib.rs")
    }
}

@Test
func rustAnalyzerParsesEveryLocationLinkImplementation() throws {
    let targetURI = exactFixtureURL()
        .appendingPathComponent("src/lib.rs")
        .absoluteString
    let links: [[String: Any]] = [
        [
            "targetUri": targetURI,
            "targetRange": lspRange(line: 0, character: 0),
            "targetSelectionRange": lspRange(line: 0, character: 7),
        ],
        [
            "targetUri": targetURI,
            "targetRange": lspRange(line: 2, character: 0),
            "targetSelectionRange": lspRange(line: 2, character: 7),
        ],
    ]

    try withFakeRustAnalyzerSession(implementationResult: links) { session in
        let startedAt = ContinuousClock.now
        let locations = try #require(try session.implementations(
            file: "src/lib.rs",
            byteOffset: 7
        ))
        print(String(
            format: "M6_IMPLEMENTATIONS shape=LocationLink[] elapsedMS=%.3f",
            exactTestMilliseconds(since: startedAt)
        ))

        #expect(locations.count == 2)
        #expect(locations.map(\.line) == [1, 3])
        #expect(locations.map(\.column) == [8, 8])
    }
}

@Test
func rustAnalyzerParsesSingleLocationImplementation() throws {
    let location: [String: Any] = [
        "uri": exactFixtureURL()
            .appendingPathComponent("src/lib.rs")
            .absoluteString,
        "range": lspRange(line: 0, character: 7),
    ]

    try withFakeRustAnalyzerSession(implementationResult: location) { session in
        let startedAt = ContinuousClock.now
        let locations = try #require(try session.implementations(
            file: "src/lib.rs",
            byteOffset: 7
        ))
        print(String(
            format: "M6_IMPLEMENTATIONS shape=Location elapsedMS=%.3f",
            exactTestMilliseconds(since: startedAt)
        ))

        #expect(locations.count == 1)
        #expect(locations[0].file == "src/lib.rs")
        #expect(locations[0].line == 1)
        #expect(locations[0].column == 8)
    }
}

@Test
func rustAnalyzerParsesEveryLocationImplementation() throws {
    let dependencyRoot = try temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: dependencyRoot) }
    let dependency = dependencyRoot.appendingPathComponent("dependency.rs")
    try Data("pub fn external() {}\n".utf8).write(to: dependency)
    let locations: [[String: Any]] = [
        [
            "uri": exactFixtureURL()
                .appendingPathComponent("src/lib.rs")
                .absoluteString,
            "range": lspRange(line: 0, character: 7),
        ],
        [
            "uri": dependency.absoluteString,
            "range": lspRange(line: 0, character: 7),
        ],
    ]

    try withFakeRustAnalyzerSession(implementationResult: locations) { session in
        let startedAt = ContinuousClock.now
        let parsed = try #require(try session.implementations(
            file: "src/lib.rs",
            byteOffset: 7
        ))
        print(String(
            format: "M6_IMPLEMENTATIONS shape=Location[] elapsedMS=%.3f",
            exactTestMilliseconds(since: startedAt)
        ))

        #expect(parsed.count == 2)
        #expect(parsed.map(\.file) == ["src/lib.rs", dependency.path])
        #expect(parsed.map(\.column) == [8, 8])
    }
}

@Test
func rustAnalyzerTreatsNullImplementationAsNoResult() throws {
    try withFakeRustAnalyzerSession(
        implementationResult: NSNull()
    ) { session in
        let startedAt = ContinuousClock.now
        let result = try session.implementations(
            file: "src/lib.rs",
            byteOffset: 7
        )
        print(String(
            format: "M6_IMPLEMENTATIONS shape=null elapsedMS=%.3f",
            exactTestMilliseconds(since: startedAt)
        ))
        #expect(result == nil)
    }
}

@Test
func rustAnalyzerRequestsReferencesWithoutTheDeclaration() throws {
    let locations: [[String: Any]] = [[
        "uri": exactFixtureURL()
            .appendingPathComponent("src/main.rs")
            .absoluteString,
        "range": lspRange(line: 3, character: 12),
    ]]

    try withFakeRustAnalyzerSession(
        referencesProvider: true,
        referenceResult: locations,
        serverCheck: { server in
            #expect(server.receivedReferencesCapability)
            #expect(server.referenceIncludeDeclarations == [false])
        }
    ) { session in
        #expect(session.negotiatedCapabilities.contains(.references))
        let references = try #require(try session.references(
            file: "src/lib.rs",
            byteOffset: 7,
            includeDeclaration: false
        ))
        #expect(references.count == 1)
        #expect(references[0].file == "src/main.rs")
        #expect(references[0].line == 4)
        #expect(references[0].column == 13)
    }
}

@Test
func rustAnalyzerNegotiatesReferenceOptionsProvider() throws {
    try withFakeRustAnalyzerSession(
        referencesProvider: [String: Any]()
    ) { session in
        #expect(session.negotiatedCapabilities.contains(.references))
    }
}

@Test
func rustAnalyzerDoesNotNegotiateMissingReferenceProvider() throws {
    try withFakeRustAnalyzerSession(referencesProvider: nil) { session in
        #expect(!session.negotiatedCapabilities.contains(.references))
    }
}

@Test
func rustAnalyzerNegotiatesImplementationBooleanProvider() throws {
    try withFakeRustAnalyzerSession(
        implementationProvider: true,
        implementationResult: NSNull()
    ) { session in
        #expect(session.negotiatedCapabilities.contains(.implementations))
    }
}

@Test
func rustAnalyzerNegotiatesImplementationObjectProvider() throws {
    try withFakeRustAnalyzerSession(
        implementationProvider: [String: Any](),
        implementationResult: NSNull()
    ) { session in
        #expect(session.negotiatedCapabilities.contains(.implementations))
    }
}

@Test
func rustAnalyzerDoesNotNegotiateMissingImplementationProvider() throws {
    try withFakeRustAnalyzerSession(
        implementationProvider: nil,
        implementationResult: NSNull()
    ) { session in
        #expect(!session.negotiatedCapabilities.contains(.implementations))
    }
}

@Test
func rustAnalyzerDoesNotNegotiateFalseImplementationProvider() throws {
    try withFakeRustAnalyzerSession(
        implementationProvider: false,
        implementationResult: NSNull()
    ) { session in
        #expect(!session.negotiatedCapabilities.contains(.implementations))
    }
}

@Test
func rustAnalyzerParsesIncomingCallHierarchyRelation() throws {
    let root = try temporaryCallHierarchyFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let aURI = root.appendingPathComponent("src/a.rs").absoluteString
    let bURI = root.appendingPathComponent("src/b.rs").absoluteString
    let incoming: [[String: Any]] = [[
        "from": [
            "name": "foo",
            "kind": 12,
            "uri": aURI,
            "range": lspRange(line: 2, character: 0),
            "selectionRange": lspRange(line: 2, character: 7),
        ],
        "fromRanges": [
            lspRange(line: 3, character: 16),
            lspRange(line: 4, character: 17),
        ],
    ]]
    let bar = ExactCallHierarchyItem(
        name: "bar",
        kind: 12,
        uri: bURI,
        range: ExactLocation(file: "src/b.rs", byteOffset: 0, line: 1, column: 1),
        selectionRange: ExactLocation(
            file: "src/b.rs",
            byteOffset: 7,
            line: 1,
            column: 8
        ),
        data: nil
    )

    try withFakeRustAnalyzerSession(
        root: root,
        snapshotFiles: ["src/a.rs", "src/b.rs"],
        incomingCallResult: incoming
    ) { session in
        let startedAt = ContinuousClock.now
        let relations = try #require(try session.incomingCalls(item: bar))
        print(String(
            format: "M6_CALL_HIERARCHY step=incoming elapsedMS=%.3f",
            exactTestMilliseconds(since: startedAt)
        ))

        #expect(relations.count == 1)
        #expect(relations[0].item.name == "foo")
        #expect(relations[0].item.selectionRange.file == "src/a.rs")
        #expect(relations[0].callSites.count == 2)
        #expect(relations[0].callSites.map(\.file) == ["src/a.rs", "src/a.rs"])
        #expect(relations[0].callSites.map(\.line) == [4, 5])
    }
}

@Test
func rustAnalyzerPreparesEveryItemAndUsesSourceURIForOutgoingCallSites() throws {
    let root = try temporaryCallHierarchyFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let aURI = root.appendingPathComponent("src/a.rs").absoluteString
    let bURI = root.appendingPathComponent("src/b.rs").absoluteString
    let foo: [String: Any] = [
        "name": "foo",
        "kind": 12,
        "uri": aURI,
        "range": lspRange(line: 2, character: 0),
        "selectionRange": lspRange(line: 2, character: 7),
    ]
    let bar: [String: Any] = [
        "name": "bar",
        "kind": 12,
        "uri": bURI,
        "range": lspRange(line: 0, character: 0),
        "selectionRange": lspRange(line: 0, character: 7),
    ]
    let outgoing: [[String: Any]] = [[
        "to": bar,
        "fromRanges": [
            lspRange(line: 3, character: 16),
            lspRange(line: 4, character: 17),
        ],
    ]]

    try withFakeRustAnalyzerSession(
        root: root,
        snapshotFiles: ["src/a.rs", "src/b.rs"],
        prepareCallHierarchyResult: [foo, bar],
        outgoingCallResult: outgoing
    ) { session in
        let prepareStartedAt = ContinuousClock.now
        let items = try #require(try session.prepareCallHierarchy(
            file: "src/a.rs",
            byteOffset: 0
        ))
        print(String(
            format: "M6_CALL_HIERARCHY step=prepare elapsedMS=%.3f",
            exactTestMilliseconds(since: prepareStartedAt)
        ))
        #expect(items.map(\.name) == ["foo", "bar"])

        let outgoingStartedAt = ContinuousClock.now
        let relations = try #require(try session.outgoingCalls(item: items[0]))
        print(String(
            format: "M6_CALL_HIERARCHY step=outgoing elapsedMS=%.3f",
            exactTestMilliseconds(since: outgoingStartedAt)
        ))
        #expect(relations.count == 1)
        #expect(relations[0].item.selectionRange.file == "src/b.rs")
        #expect(relations[0].callSites.count == 2)
        #expect(relations[0].callSites.map(\.file) == ["src/a.rs", "src/a.rs"])
        #expect(!relations[0].callSites.contains { $0.file == "src/b.rs" })
        #expect(relations[0].callSites.map(\.line) == [4, 5])
    }
}

@Test
func rustAnalyzerTreatsEmptyCallHierarchyPrepareAsEmpty() throws {
    let root = try temporaryCallHierarchyFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try withFakeRustAnalyzerSession(
        root: root,
        snapshotFiles: ["src/a.rs", "src/b.rs"],
        prepareCallHierarchyResult: []
    ) { session in
        let items = try #require(try session.prepareCallHierarchy(
            file: "src/a.rs",
            byteOffset: 0
        ))
        #expect(items.isEmpty)
    }
}

@Test
func rustAnalyzerNegotiatesCallHierarchyBooleanProvider() throws {
    try withFakeRustAnalyzerSession(callHierarchyProvider: true) { session in
        #expect(session.negotiatedCapabilities.contains(.callHierarchy))
    }
}

@Test
func rustAnalyzerNegotiatesCallHierarchyObjectProvider() throws {
    try withFakeRustAnalyzerSession(
        callHierarchyProvider: [String: Any]()
    ) { session in
        #expect(session.negotiatedCapabilities.contains(.callHierarchy))
    }
}

@Test
func rustAnalyzerDoesNotNegotiateMissingCallHierarchyProvider() throws {
    try withFakeRustAnalyzerSession(callHierarchyProvider: nil) { session in
        #expect(!session.negotiatedCapabilities.contains(.callHierarchy))
    }
}

@Test
func lspClientWaitsForServerStatusQuiescent() throws {
    let clientToServer = Pipe()
    let serverToClient = Pipe()
    let done = DispatchSemaphore(value: 0)
    let server = PipeFakeLSPServer(
        input: clientToServer.fileHandleForReading,
        output: serverToClient.fileHandleForWriting,
        serverStatusQuiescent: false,
        done: { done.signal() }
    )
    server.start()
    let client = LSPClient(
        readHandle: serverToClient.fileHandleForReading,
        writeHandle: clientToServer.fileHandleForWriting
    )
    defer {
        client.close(grace: 1)
        _ = done.wait(timeout: .now() + 1)
    }

    _ = try client.initialize(
        rootURL: URL(fileURLWithPath: "/fixture", isDirectory: true),
        timeout: 1
    )
    #expect(!client.isQuiescent)
    Thread.detachNewThread {
        Thread.sleep(forTimeInterval: 0.05)
        try? server.sendServerStatus(quiescent: true)
    }
    try client.waitForQuiescence(method: "test/readiness", timeout: 1)

    #expect(client.isQuiescent)
    #expect(server.receivedServerStatusCapability)
}

@Test
func rustAnalyzerReturnsReadyNullWithoutBlindRetry() throws {
    try withFakeRustAnalyzerSession(
        requestResponder: { method, _ in
            method == "textDocument/definition" ? .result(NSNull()) : .useDefault
        },
        serverCheck: { server in
            #expect(
                server.requestMethods.filter { $0 == "textDocument/definition" }
                    .count == 1
            )
            #expect(server.receivedServerStatusCapability)
        }
    ) { session in
        let result = try session.definition(file: "src/main.rs", byteOffset: 0)
        guard case .completed(let targets) = result else {
            Issue.record("expected completed empty definition result")
            return
        }
        #expect(targets.isEmpty)
    }
}

@Test
func rustAnalyzerPreservesEveryDefinitionTarget() throws {
    let targetURI = exactFixtureURL()
        .appendingPathComponent("src/lib.rs")
        .absoluteString
    let targets: [[String: Any]] = [0, 2].map { line in
        [
            "targetUri": targetURI,
            "targetRange": lspRange(line: line, character: 0),
            "targetSelectionRange": lspRange(line: line, character: 7),
        ]
    }
    try withFakeRustAnalyzerSession(
        requestResponder: { method, _ in
            method == "textDocument/definition"
                ? .result(targets) : .useDefault
        }
    ) { session in
        let result = try session.definition(file: "src/main.rs", byteOffset: 0)
        guard case .completed(let parsed) = result else {
            Issue.record("definition query did not complete")
            return
        }
        #expect(parsed.map(\.location.line) == [1, 3])
    }
}

@Test
func rustAnalyzerCancelledReadinessWaitDoesNotSendRequest() throws {
    try withFakeRustAnalyzerSession(
        serverStatusQuiescent: false,
        serverCheck: { server in
            #expect(
                !server.requestMethods.contains("textDocument/definition")
            )
        }
    ) { session in
        let batch = ExactRequestBatch()
        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            _ = try? session.definition(
                file: "src/main.rs",
                byteOffset: 0,
                batch: batch
            )
            finished.signal()
        }
        Thread.sleep(forTimeInterval: 0.05)
        session.cancel(batch: batch)
        #expect(finished.wait(timeout: .now() + 1) == .success)
    }
}

@Test
func rustAnalyzerContentModifiedRetryDoesNotBlockOperationLock() throws {
    let responses = RetryResponseState()
    try withFakeRustAnalyzerSession(
        requestResponder: { method, _ in
            guard method == "textDocument/definition" else {
                return .useDefault
            }
            return responses.next()
        }
    ) { session in
        let firstDone = DispatchSemaphore(value: 0)
        let secondDone = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            _ = try? session.definition(file: "src/main.rs", byteOffset: 0)
            firstDone.signal()
        }
        #expect(waitUntil("content-modified request reaches the provider", timeout: 1) {
            responses.count >= 1
        })

        Thread.detachNewThread {
            _ = try? session.definition(file: "src/main.rs", byteOffset: 0)
            secondDone.signal()
        }
        let secondEnteredDuringRetry =
            secondDone.wait(timeout: .now() + 0.5) == .success
        #expect(firstDone.wait(timeout: .now() + 3) == .success)
        #expect(
            secondEnteredDuringRetry
                || secondDone.wait(timeout: .now() + 3) == .success
        )

        print(
            "retry lock releasedDuringDelay=\(secondEnteredDuringRetry)"
                + " requests=\(responses.count)"
        )
        #expect(secondEnteredDuringRetry)
    }
}

@Test
func exactRequestBatchCapsProviderBoundaryConcurrency() {
    let expectedLimit = 4
    #expect(ExactRequestBatch.maximumConcurrentRequests == expectedLimit)
    let batch = ExactRequestBatch()
    let probe = BatchConcurrencyProbe()
    let workersDone = DispatchGroup()
    for _ in 0..<12 {
        workersDone.enter()
        Thread.detachNewThread {
            defer { workersDone.leave() }
            guard batch.acquire() else { return }
            probe.enter()
            probe.waitForRelease()
            probe.leave()
            batch.release()
        }
    }

    #expect(waitUntil("provider batch reaches its concurrency cap", timeout: 1) {
        probe.active == expectedLimit
    })
    probe.release()
    #expect(workersDone.wait(timeout: .now() + 3) == .success)

    print(
        "batch concurrency limit=\(ExactRequestBatch.maximumConcurrentRequests)"
            + " maxInFlight=\(probe.maximumActive)"
    )
    #expect(probe.maximumActive == expectedLimit)
}

@Test
func rustAnalyzerCancelledBatchNeverEntersProviderAfterOperationQueue()
    throws
{
    let responses = CancellationResponseState(
        successURI: exactFixtureURL()
            .appendingPathComponent("src/lib.rs")
            .absoluteString
    )
    try withFakeRustAnalyzerSession(
        requestResponder: { method, _ in
            guard method == "textDocument/definition" else {
                return .useDefault
            }
            return responses.next()
        }
    ) { session in
        let staleBatch = ExactRequestBatch()
        let staleFanout = 32
        let started = DispatchSemaphore(value: 0)
        let staleDone = DispatchGroup()
        for _ in 0..<staleFanout {
            staleDone.enter()
            Thread.detachNewThread {
                defer { staleDone.leave() }
                started.signal()
                _ = try? session.definition(
                    file: "src/main.rs",
                    byteOffset: 0,
                    batch: staleBatch
                )
            }
        }
        for _ in 0..<staleFanout {
            #expect(started.wait(timeout: .now() + 1) == .success)
        }
        #expect(waitUntil("first stale-batch request reaches the provider", timeout: 1) {
            responses.count == 1
        })
        Thread.sleep(forTimeInterval: 0.05)

        session.cancel(batch: staleBatch)
        #expect(staleDone.wait(timeout: .now() + 3) == .success)
        let staleRequestsAfterCancel = responses.count
        Thread.sleep(forTimeInterval: 0.05)
        #expect(responses.count == staleRequestsAfterCancel)
        let current = try session.definition(
            file: "src/main.rs",
            byteOffset: 0,
            batch: ExactRequestBatch()
        )

        print(
            "cancelled batch provider requests staleQueued=\(staleFanout)"
                + " staleActual=\(staleRequestsAfterCancel)"
                + " totalAfterCurrent=\(responses.count)"
        )
        if case .completed = current {
            // expected
        } else {
            Issue.record("current definition request did not complete")
        }
        #expect(staleRequestsAfterCancel == 1)
        #expect(responses.count == 2)
    }
}

@Test
func diagnosticObserverFiresForStderrOutsideClientLock() async throws {
    let client = try LSPClient(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: [
            "-c",
            "printf 'failed to resolve dependency; --offline was specified' >&2; sleep 5",
        ]
    )
    defer { client.close(grace: 0.05) }
    let (diagnostics, continuation) = AsyncStream<String>.makeStream()
    client.observeDiagnostics { [weak client] diagnostic in
        _ = client?.diagnosticText
        continuation.yield(diagnostic)
    }

    let diagnostic = await nextDiagnostic(diagnostics)

    #expect(diagnostic?.contains("--offline was specified") == true)
}

@Test
func closeForceKillsAndReapsUnresponsiveProcess() throws {
    let client = try LSPClient(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "trap '' 15; while :; do :; done"]
    )
    let pid = try #require(client.processIdentifier)
    Thread.sleep(forTimeInterval: 0.05)

    let started = Date()
    client.close(grace: 0.05)

    #expect(Date().timeIntervalSince(started) < 1)
    #expect(!client.isRunning)
    #expect(client.didForceKill)
    #expect(client.didReap)
    errno = 0
    #expect(waitpid(pid, nil, WNOHANG) == -1)
    #expect(errno == ECHILD)
}

@Test
func childProcessRegistryRegistersAndUnregistersConcurrently() async {
    #expect(ci_process_guard_install())
    let results = await withTaskGroup(
        of: (pid_t, Bool).self,
        returning: [(pid_t, Bool)].self
    ) { group in
        for worker in 0..<24 {
            group.addTask {
                let pid = pid_t(2_000_000 + worker)
                for _ in 0..<500 {
                    guard ci_process_guard_register(pid),
                          ci_process_guard_contains(pid),
                          ci_process_guard_unregister(pid)
                    else {
                        return (pid, false)
                    }
                }
                return (pid, !ci_process_guard_contains(pid))
            }
        }
        var results: [(pid_t, Bool)] = []
        for await result in group {
            results.append(result)
        }
        return results
    }

    let failures = results.filter { !$0.1 }.map(\.0).sorted()
    print(
        "process-guard concurrency workers=24 iterations=500"
            + " failures=\(failures)"
    )
    #expect(failures.isEmpty)
}

@Test
func crashGuardKillsRegisteredGrandchildAndReraisesAbort() throws {
    var helperPID: pid_t = 0
    var fakeChildPID: pid_t = 0
    try #require(ci_test_spawn_abort_helper(
        false,
        &helperPID,
        &fakeChildPID
    ))
    let unguardedStatus = try waitForProcess(helperPID)
    let unguardedSignal = unguardedStatus & 0x7f
    let orphanSurvived = processExists(fakeChildPID)
    print(
        "process-guard control handler=off"
            + " helperSignal=\(unguardedSignal)"
            + " orphanAlive=\(orphanSurvived)"
    )
    #expect(unguardedSignal == SIGABRT)
    #expect(orphanSurvived)
    Darwin.kill(fakeChildPID, SIGKILL)
    #expect(waitForProcessToDisappear(fakeChildPID))

    try #require(ci_test_spawn_abort_helper(
        true,
        &helperPID,
        &fakeChildPID
    ))
    let guardedStatus = try waitForProcess(helperPID)
    let guardedSignal = guardedStatus & 0x7f
    let orphanDisappeared = waitForProcessToDisappear(fakeChildPID)
    print(
        "process-guard fixed handler=on"
            + " helperSignal=\(guardedSignal)"
            + " orphanAlive=\(!orphanDisappeared)"
    )
    #expect(guardedSignal == SIGABRT)
    #expect(orphanDisappeared)
    if !orphanDisappeared {
        Darwin.kill(fakeChildPID, SIGKILL)
    }
}

@Test
func terminationGuardKillsRegisteredGrandchildAndPreservesDefaultSignal()
    async throws
{
    for signal in [SIGTERM, SIGINT, SIGHUP] {
        let (deliveredSignal, orphanDisappeared) =
            try await guardedSignalResult(signal)
        print(
            "process-guard termination signal=\(signal)"
                + " helperSignal=\(deliveredSignal)"
                + " orphanAlive=\(!orphanDisappeared)"
        )

        #expect(deliveredSignal == signal)
        #expect(orphanDisappeared)
    }
}

@Test
func reaperKillsRegisteredGrandchildAfterParentSIGKILL() async throws {
    let (deliveredSignal, orphanDisappeared) =
        try await guardedSignalResult(SIGKILL)
    print(
        "process-guard uncatchable signal=\(SIGKILL)"
            + " helperSignal=\(deliveredSignal)"
            + " orphanAlive=\(!orphanDisappeared)"
    )

    #expect(deliveredSignal == SIGKILL)
    #expect(orphanDisappeared)
}

@Test
func rustAnalyzerFindsCrossFileDefinitionWhenInstalled() throws {
    guard let executableURL = RustAnalyzerProvider.findExecutable() else {
        // Environmental coverage: CI without rust-analyzer remains green.
        return
    }
    let fixture = try copiedFixture()
    defer { try? FileManager.default.removeItem(at: fixture) }
    let cache = FileManager.default.temporaryDirectory.appendingPathComponent(
        "CodeInsightExactCache-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: cache) }
    let snapshot = try DirectorySnapshot(root: fixture)
    let provider: RustAnalyzerProvider
    let session: any ExactSession
    do {
        provider = try RustAnalyzerProvider(
            projectURL: fixture,
            executableURL: executableURL,
            cacheURL: cache,
            requestTimeout: 30,
            closeGrace: 30
        )
        session = try provider.prepare(
            snapshot: snapshot,
            profile: ExactProfileKey(projectURL: fixture),
            trustMode: .safe
        )
    } catch ExactError.unavailable(let detail)
        where detail.contains("sandbox-exec")
    {
        // Safe exact is intentionally disabled instead of running bare.
        print("SKIP rust-analyzer: \(detail); noBareExecution=true")
        return
    }
    defer { session.close() }
    #expect(session.readiness == .preparing)
    let bytes = try snapshot.readBytes(path: "src/main.rs")
    let source = try #require(String(data: Data(bytes), encoding: .utf8))
    let call = try #require(
        source.range(of: "answer();", options: .backwards)
    )
    let byteOffset = source[..<call.lowerBound].utf8.count

    let location = try onlyDefinitionLocation(try session.definition(
        file: "src/main.rs",
        byteOffset: byteOffset
    ))

    #expect(session.readiness == .ready)
    #expect(location.file == "src/lib.rs")
    #expect(location.line == 1)
    #expect(location.column == 8)
    // This fixture's build.rs makes Cargo load its cc toolchain dependency.
    // Safe limitations remain explicit; an offline miss is an additional,
    // orthogonal limitation.
    #expect(session.attribution.environment.trustMode == .safe)
    #expect(session.attribution.environment.limitations.contains(.buildScriptsDisabled))
    #expect(session.attribution.environment.limitations.contains(.procMacrosDisabled))
    #expect(session.attribution.configFingerprint.count == 64)
    #expect(session.attribution.environmentFingerprint.count == 64)
}

@Test
func sandboxDeniesProjectWrites() throws {
    let root = try temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("project", isDirectory: true)
    let cache = root.appendingPathComponent("cache", isDirectory: true)
    try FileManager.default.createDirectory(
        at: project, withIntermediateDirectories: true)
    let denied = project.appendingPathComponent("DENIED")
    guard
        let sandbox = try availableSandbox(
            project: project,
            cache: cache,
            mode: .safe,
            helper: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf denied > \"$1\"", "probe", denied.path]
        )
    else { return }

    let result = try run(sandbox)

    #expect(result.status != 0)
    #expect(!FileManager.default.fileExists(atPath: denied.path))
    #expect(sandbox.environment["CARGO_NET_OFFLINE"] == "true")
    print("sandbox-semantics projectWrite=denied status=\(result.status)")
}

@Test
func sandboxAllowsPrivateCacheWrites() throws {
    let root = try temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("project", isDirectory: true)
    let cache = root.appendingPathComponent("cache", isDirectory: true)
    try FileManager.default.createDirectory(
        at: project, withIntermediateDirectories: true)
    let allowed = cache.appendingPathComponent("ALLOWED")
    guard
        let sandbox = try availableSandbox(
            project: project,
            cache: cache,
            mode: .safe,
            helper: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf allowed > \"$1\"", "probe", allowed.path]
        )
    else { return }

    let result = try run(sandbox)

    if result.status != 0 { print("cache-write output=\(result.output)") }
    #expect(result.status == 0)
    #expect(try String(contentsOf: allowed, encoding: .utf8) == "allowed")
    print("sandbox-semantics cacheWrite=allowed status=\(result.status)")
}

@Test
func sandboxDeniesNetworkToLocalListener() throws {
    let root = try temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("project", isDirectory: true)
    let cache = root.appendingPathComponent("cache", isDirectory: true)
    try FileManager.default.createDirectory(
        at: project, withIntermediateDirectories: true)
    guard
        try availableSandbox(
            project: project,
            cache: cache,
            mode: .safe,
            helper: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: []
        ) != nil
    else { return }
    let (listener, port) = try localListener()
    defer { Darwin.close(listener) }

    let direct = try run(
        executable: URL(fileURLWithPath: "/usr/bin/nc"),
        arguments: ["-z", "-w", "1", "127.0.0.1", String(port)]
    )
    #expect(direct.status == 0)
    guard
        let deniedLaunch = try availableSandbox(
            project: project,
            cache: cache,
            mode: .safe,
            helper: URL(fileURLWithPath: "/usr/bin/nc"),
            arguments: ["-z", "-w", "1", "127.0.0.1", String(port)]
        )
    else { return }
    let denied = try run(deniedLaunch)

    #expect(denied.status != 0)
    print("sandbox-semantics network=denied status=\(denied.status)")
}

@Test
func trustedSandboxAllowsTargetButStillDeniesNetwork() throws {
    let root = try temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("project", isDirectory: true)
    let target = project.appendingPathComponent("target", isDirectory: true)
    let cache = root.appendingPathComponent("cache", isDirectory: true)
    try FileManager.default.createDirectory(
        at: target, withIntermediateDirectories: true)
    let allowed = target.appendingPathComponent("ALLOWED")
    guard
        let writeSandbox = try availableSandbox(
            project: project,
            cache: cache,
            mode: .trusted,
            helper: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf target > \"$1\"", "probe", allowed.path]
        )
    else { return }

    let write = try run(writeSandbox)
    if write.status != 0 { print("target-write output=\(write.output)") }
    #expect(write.status == 0)
    #expect(try String(contentsOf: allowed, encoding: .utf8) == "target")
    #expect(writeSandbox.environment["CARGO_NET_OFFLINE"] == "true")

    let (listener, port) = try localListener()
    defer { Darwin.close(listener) }
    let networkSandbox = try Sandbox(
        projectURL: project,
        cacheURL: cache,
        trustMode: .trusted,
        helperURL: URL(fileURLWithPath: "/usr/bin/nc"),
        helperArguments: ["-z", "-w", "1", "127.0.0.1", String(port)]
    )
    let network = try run(networkSandbox)
    #expect(network.status != 0)
    print(
        "sandbox-semantics trustedTarget=allowed network=denied"
            + " offline=1"
    )
}

@Test
func sandboxShimSetsCPUAndAddressSpaceLimits() throws {
    let root = try temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("project", isDirectory: true)
    let cache = root.appendingPathComponent("cache", isDirectory: true)
    try FileManager.default.createDirectory(
        at: project, withIntermediateDirectories: true)
    let script = """
        test "$(ulimit -S -t)" = "$1" && test "$(ulimit -S -v)" = "$2"
        """
    guard
        let sandbox = try availableSandbox(
            project: project,
            cache: cache,
            mode: .safe,
            helper: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c", script, "probe",
                String(Sandbox.cpuTimeLimitSeconds),
                String(Sandbox.addressSpaceLimitKiB),
            ]
        )
    else { return }

    let result = try run(sandbox)

    #expect(result.status == 0)
    print(
        "rlimit cpuSeconds=\(Sandbox.cpuTimeLimitSeconds)"
            + " addressSpaceKiB=\(Sandbox.addressSpaceLimitKiB)"
    )
}

@Test
func trustRegistryRoundTrip() async throws {
    let root = try temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("trust.json")
    let repository = root.appendingPathComponent("repo", isDirectory: true)
    try FileManager.default.createDirectory(
        at: repository,
        withIntermediateDirectories: true
    )
    let registry = TrustRegistry(fileURL: file)
    let grantedAt = Date(timeIntervalSince1970: 1_700_000_000)

    try await registry.grant(
        repository.appendingPathComponent("../repo"),
        mode: .trusted,
        grantedAt: grantedAt
    )
    #expect(modeName(await registry.query(repository)) == "trusted")
    let object = try #require(
        try JSONSerialization.jsonObject(with: Data(contentsOf: file))
            as? [String: Any]
    )
    let entry = try #require(object[repository.path] as? [String: Any])
    #expect(entry["mode"] as? String == "trusted")
    #expect(entry["grantedAt"] as? String != nil)
    let reloaded = TrustRegistry(fileURL: file)
    #expect(modeName(await reloaded.query(repository)) == "trusted")
    try await reloaded.revoke(repository)
    #expect(await reloaded.query(repository) == nil)
}

@Test
func trustRegistryTreatsCorruptJSONAsEmptyAndRecovers() async throws {
    let root = try temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("trust.json")
    try Data("{not-json".utf8).write(to: file)
    let repository = root.appendingPathComponent("repo", isDirectory: true)
    let registry = TrustRegistry(fileURL: file)

    #expect(await registry.query(repository) == nil)
    try await registry.grant(repository, mode: .safe)
    let reloaded = TrustRegistry(fileURL: file)
    #expect(modeName(await reloaded.query(repository)) == "safe")
}

@Test
func trustRegistrySerializesConcurrentWrites() async throws {
    let root = try temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("trust.json")
    let registry = TrustRegistry(fileURL: file)
    let repositories = (0..<24).map {
        root.appendingPathComponent("repo-\($0)", isDirectory: true)
    }

    try await withThrowingTaskGroup(of: Void.self) { group in
        for repository in repositories {
            group.addTask {
                try await registry.grant(repository, mode: .trusted)
            }
        }
        try await group.waitForAll()
    }

    let reloaded = TrustRegistry(fileURL: file)
    for repository in repositories {
        #expect(modeName(await reloaded.query(repository)) == "trusted")
    }
}

@Test
func rustAnalyzerSafeMarkerControlWhenInstalled() throws {
    guard let executableURL = RustAnalyzerProvider.findExecutable() else {
        // Environmental coverage: CI without rust-analyzer remains green.
        return
    }
    let root = try temporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let safeFixture = try copiedFixture(into: root.appendingPathComponent("safe"))
    let trustedFixture = try copiedFixture(
        into: root.appendingPathComponent("trusted")
    )

    do {
        let safe = try runDefinition(
            fixture: safeFixture,
            cache: root.appendingPathComponent("safe-cache"),
            executable: executableURL,
            mode: .safe
        )
        #expect(safe.file == "src/lib.rs")
        #expect(safe.line == 1)
        #expect(safe.column == 8)
        let safeTarget = safeFixture.appendingPathComponent("target")
        let safeMarker = safeTarget.appendingPathComponent("BUILD_SCRIPT_RAN")
        #expect(!FileManager.default.fileExists(atPath: safeMarker.path))
        #expect(!FileManager.default.fileExists(atPath: safeTarget.path))

        let marker = trustedFixture.appendingPathComponent(
            "target/BUILD_SCRIPT_RAN"
        )
        let trusted = try runDefinition(
            fixture: trustedFixture,
            cache: root.appendingPathComponent("trusted-cache"),
            executable: executableURL,
            mode: .trusted,
            waitFor: marker
        )
        #expect(trusted.file == "src/lib.rs")
        #expect(trusted.line == 1)
        #expect(trusted.column == 8)
        #expect(FileManager.default.fileExists(atPath: marker.path))
        print(
            "marker-control safeMarkerAbsent=true safeTargetAbsent=true"
                + " trustedMarkerPresent=true"
        )
    } catch ExactError.unavailable(let detail)
        where detail.contains("sandbox-exec")
    {
        // The control must never bypass an unavailable OS sandbox.
        print("SKIP marker-control: \(detail); noBareExecution=true")
    }
}

private func copiedFixture() throws -> URL {
    let source = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/exact_fixture", isDirectory: true)
    let destination = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "CodeInsightExactTests-\(UUID().uuidString)",
            isDirectory: true
        )
    try FileManager.default.copyItem(at: source, to: destination)
    return destination
}

private func copiedFixture(into destination: URL) throws -> URL {
    let source = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/exact_fixture", isDirectory: true)
    try FileManager.default.copyItem(at: source, to: destination)
    return destination
}

private func temporaryTestDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "CodeInsightExactTests-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func availableSandbox(
    project: URL,
    cache: URL,
    mode: TrustMode,
    helper: URL,
    arguments: [String]
) throws -> Sandbox? {
    do {
        return try Sandbox(
            projectURL: project,
            cacheURL: cache,
            trustMode: mode,
            helperURL: helper,
            helperArguments: arguments
        )
    } catch ExactError.unavailable(let detail) {
        #expect(detail.contains("sandbox-exec"))
        print("sandbox-exec unavailable: \(detail); noBareExecution=true")
        return nil
    }
}

private struct ProcessResult {
    let status: Int32
    let output: String
}

private func run(_ sandbox: Sandbox) throws -> ProcessResult {
    try run(
        executable: sandbox.executableURL,
        arguments: sandbox.arguments,
        environment: sandbox.environment,
        workingDirectory: sandbox.workingDirectoryURL
    )
}

private func run(
    executable: URL,
    arguments: [String],
    environment: [String: String]? = nil,
    workingDirectory: URL? = nil
) throws -> ProcessResult {
    let process = Process()
    let output = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = environment
    process.currentDirectoryURL = workingDirectory
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    return ProcessResult(
        status: process.terminationStatus,
        output: String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
    )
}

private func localListener() throws -> (descriptor: Int32, port: UInt16) {
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw currentPOSIXError() }
    do {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bindResult == 0 else { throw currentPOSIXError() }
        guard Darwin.listen(descriptor, 4) == 0 else {
            throw currentPOSIXError()
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &length)
            }
        }
        guard nameResult == 0 else { throw currentPOSIXError() }
        return (descriptor, UInt16(bigEndian: address.sin_port))
    } catch {
        Darwin.close(descriptor)
        throw error
    }
}

private func currentPOSIXError() -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
}

private func modeName(_ mode: TrustMode?) -> String? {
    switch mode {
    case .safe: "safe"
    case .trusted: "trusted"
    case nil: nil
    }
}

private func runDefinition(
    fixture: URL,
    cache: URL,
    executable: URL,
    mode: TrustMode,
    waitFor marker: URL? = nil
) throws -> ExactLocation {
    let snapshot = try DirectorySnapshot(root: fixture)
    let provider = try RustAnalyzerProvider(
        projectURL: fixture,
        executableURL: executable,
        cacheURL: cache,
        requestTimeout: 30,
        // The test only needs the definition + marker; force-kill promptly on
        // close instead of waiting up to 30s for a busy rust-analyzer to exit
        // gracefully (that wait dominated the runtime — two sessions x 30s).
        closeGrace: 2
    )
    let session = try provider.prepare(
        snapshot: snapshot,
        profile: ExactProfileKey(projectURL: fixture),
        trustMode: mode
    )
    defer { session.close() }
    let bytes = try snapshot.readBytes(path: "src/main.rs")
    let source = try #require(String(data: Data(bytes), encoding: .utf8))
    let call = try #require(source.range(of: "answer();", options: .backwards))
    let location = try onlyDefinitionLocation(try session.definition(
        file: "src/main.rs",
        byteOffset: source[..<call.lowerBound].utf8.count
    ))
    if let marker {
        // Cargo/build-script completion is asynchronous; this is a hang fuse,
        // not a performance budget.
        try #require(waitForFile(marker, timeout: 120))
    }
    return location
}

private func materializedDefinition(
    snapshot: CommitSnapshot,
    materializer: Materializer,
    executable: URL,
    cache: URL
) throws -> ExactLocation {
    let profile = try ExactProfileKey(snapshot: snapshot)
    let root = try materializer.materialize(
        snapshot,
        configFingerprint: profile.configFingerprint
    ).url
    let provider = try RustAnalyzerProvider(
        projectURL: root,
        executableURL: executable,
        cacheURL: cache,
        requestTimeout: 30,
        closeGrace: 30
    )
    let session = try provider.prepare(
        snapshot: snapshot,
        profile: profile,
        trustMode: .safe
    )
    defer { session.close() }
    let source = try #require(String(
        data: Data(snapshot.readBytes(path: "src/main.rs")),
        encoding: .utf8
    ))
    let call = try #require(source.range(of: "answer();"))
    return try onlyDefinitionLocation(try session.definition(
        file: "src/main.rs",
        byteOffset: source[..<call.lowerBound].utf8.count
    ))
}

private func onlyDefinitionLocation(
    _ result: ExactDefinitionQueryResult
) throws -> ExactLocation {
    guard case .completed(let targets) = result else {
        throw DefinitionTestError.notCompleted
    }
    return try #require(targets.first).location
}

private enum DefinitionTestError: Error {
    case notCompleted
}

private func simpleMaterializerFixture() throws -> MaterializerGitFixture {
    let fixture = try MaterializerGitFixture()
    do {
        try fixture.write(
            "[package]\nname='simple'\nversion='0.1.0'\n",
            to: "Cargo.toml"
        )
        try fixture.write("pub fn answer() -> u8 { 1 }\n", to: "src/lib.rs")
        try fixture.commit("simple")
        return fixture
    } catch {
        fixture.remove()
        throw error
    }
}

private final class MaterializerGitFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CodeInsightMaterializerTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        do {
            try git("init", "-q")
            try git("config", "user.name", "CodeInsight Tests")
            try git("config", "user.email", "tests@codeinsight.invalid")
        } catch {
            remove()
            throw error
        }
    }

    func write(_ contents: String, to path: String) throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: file)
    }

    func commit(_ message: String) throws {
        try git("add", "-A")
        try git("commit", "-q", "-m", message)
    }

    @discardableResult
    func git(_ arguments: String...) throws -> String {
        let result = try run(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: arguments,
            workingDirectory: root
        )
        guard result.status == 0 else {
            throw MaterializerTestError.git(result.output)
        }
        return result.output
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private enum MaterializerTestError: Error {
    case git(String)
}

private func waitForFile(_ url: URL, timeout: TimeInterval) -> Bool {
    let deadline = ContinuousClock.now + .seconds(timeout)
    while ContinuousClock.now < deadline {
        if FileManager.default.fileExists(atPath: url.path) { return true }
        Thread.sleep(forTimeInterval: 0.05)
    }
    if FileManager.default.fileExists(atPath: url.path) { return true }
    FileHandle.standardError.write(Data(
        "Hang fuse expired while waiting for file: \(url.path)\n".utf8
    ))
    return false
}

private func waitUntil(
    _ description: String,
    timeout: TimeInterval,
    _ predicate: () -> Bool
) -> Bool {
    let deadline = ContinuousClock.now + .seconds(timeout)
    while ContinuousClock.now < deadline {
        if predicate() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    if predicate() { return true }
    FileHandle.standardError.write(Data(
        "Timed out after \(timeout)s waiting for: \(description)\n".utf8
    ))
    return false
}

private enum PipeFakeRequestResponse {
    case useDefault
    case result(Any)
    case error(code: Int, message: String)
    case noResponse
}

private final class RetryResponseState: @unchecked Sendable {
    private let lock = NSLock()
    private var responses = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return responses
    }

    func next() -> PipeFakeRequestResponse {
        lock.lock()
        defer { lock.unlock() }
        responses += 1
        return responses == 1
            ? .error(code: -32801, message: "content modified")
            : .useDefault
    }
}

private final class CancellationResponseState: @unchecked Sendable {
    private let lock = NSLock()
    private let successURI: String
    private var responses = 0

    init(successURI: String) {
        self.successURI = successURI
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return responses
    }

    func next() -> PipeFakeRequestResponse {
        lock.lock()
        defer { lock.unlock() }
        responses += 1
        guard responses > 1 else { return .noResponse }
        return .result([
            "uri": successURI,
            "range": [
                "start": ["line": 0, "character": 7],
                "end": ["line": 0, "character": 13],
            ],
        ])
    }
}

private final class BatchConcurrencyProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false
    private var activeCount = 0
    private var maximumActiveCount = 0

    var active: Int {
        condition.lock()
        defer { condition.unlock() }
        return activeCount
    }

    var maximumActive: Int {
        condition.lock()
        defer { condition.unlock() }
        return maximumActiveCount
    }

    func enter() {
        condition.lock()
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        condition.broadcast()
        condition.unlock()
    }

    func leave() {
        condition.lock()
        activeCount -= 1
        condition.unlock()
    }

    func waitForRelease() {
        condition.lock()
        let deadline = Date().addingTimeInterval(120)
        while !released, condition.wait(until: deadline) {}
        condition.unlock()
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class PipeFakeLSPServer: @unchecked Sendable {
    private let input: FileHandle
    private let output: FileHandle
    private let done: () -> Void
    private let lock = NSLock()
    private var _requestMethods: [String] = []
    private var _requestIDs: [Int] = []
    private var _receivedInitialized = false
    private var _receivedExit = false
    private var _receivedRegisterCapabilityResponse = false
    private var _receivedImplementationCapability = false
    private var _receivedCallHierarchyCapability = false
    private var _receivedReferencesCapability = false
    private var _receivedServerStatusCapability = false
    private var _referenceIncludeDeclarations: [Bool] = []
    private let implementationProvider: Any?
    private let implementationResult: Any
    private let callHierarchyProvider: Any?
    private let prepareCallHierarchyResult: Any
    private let incomingCallResult: Any
    private let outgoingCallResult: Any
    private let referencesProvider: Any?
    private let referenceResult: Any
    private let serverStatusQuiescent: Bool
    private let requestResponder: ((String, Int) -> PipeFakeRequestResponse)?
    private var _error: Error?

    var requestMethods: [String] { locked { _requestMethods } }
    var requestIDs: [Int] { locked { _requestIDs } }
    var receivedInitialized: Bool { locked { _receivedInitialized } }
    var receivedExit: Bool { locked { _receivedExit } }
    var receivedRegisterCapabilityResponse: Bool {
        locked { _receivedRegisterCapabilityResponse }
    }
    var receivedImplementationCapability: Bool {
        locked { _receivedImplementationCapability }
    }
    var receivedCallHierarchyCapability: Bool {
        locked { _receivedCallHierarchyCapability }
    }
    var receivedReferencesCapability: Bool {
        locked { _receivedReferencesCapability }
    }
    var receivedServerStatusCapability: Bool {
        locked { _receivedServerStatusCapability }
    }
    var referenceIncludeDeclarations: [Bool] {
        locked { _referenceIncludeDeclarations }
    }
    var error: Error? { locked { _error } }

    init(
        input: FileHandle,
        output: FileHandle,
        implementationProvider: Any? = true,
        implementationResult: Any = NSNull(),
        callHierarchyProvider: Any? = true,
        prepareCallHierarchyResult: Any = NSNull(),
        incomingCallResult: Any = NSNull(),
        outgoingCallResult: Any = NSNull(),
        referencesProvider: Any? = true,
        referenceResult: Any = NSNull(),
        serverStatusQuiescent: Bool = true,
        requestResponder: ((String, Int) -> PipeFakeRequestResponse)? = nil,
        done: @escaping () -> Void
    ) {
        self.input = input
        self.output = output
        self.implementationProvider = implementationProvider
        self.implementationResult = implementationResult
        self.callHierarchyProvider = callHierarchyProvider
        self.prepareCallHierarchyResult = prepareCallHierarchyResult
        self.incomingCallResult = incomingCallResult
        self.outgoingCallResult = outgoingCallResult
        self.referencesProvider = referencesProvider
        self.referenceResult = referenceResult
        self.serverStatusQuiescent = serverStatusQuiescent
        self.requestResponder = requestResponder
        self.done = done
    }

    func start() {
        Thread.detachNewThread { self.run() }
    }

    private func run() {
        var decoder = LSPFrameDecoder()
        do {
            while true {
                let data = input.availableData
                guard !data.isEmpty else { break }
                for message in try decoder.append(data) {
                    if try handle(message) { return }
                }
            }
        } catch {
            locked { _error = error }
        }
        done()
    }

    private func handle(_ message: [String: Any]) throws -> Bool {
        if let method = message["method"] as? String {
            if let id = (message["id"] as? NSNumber)?.intValue {
                locked {
                    _requestMethods.append(method)
                    _requestIDs.append(id)
                }
                switch requestResponder?(method, id) ?? .useDefault {
                case .useDefault:
                    break
                case .result(let result):
                    try write([
                        "jsonrpc": "2.0", "id": id, "result": result,
                    ])
                    return false
                case let .error(code, message):
                    try write([
                        "jsonrpc": "2.0", "id": id,
                        "error": ["code": code, "message": message],
                    ])
                    return false
                case .noResponse:
                    return false
                }
                switch method {
                case "initialize":
                    let params = message["params"] as? [String: Any]
                    let capabilities = params?["capabilities"] as? [String: Any]
                    let textDocument = capabilities?["textDocument"]
                        as? [String: Any]
                    let experimental = capabilities?["experimental"]
                        as? [String: Any]
                    locked {
                        _receivedImplementationCapability =
                            textDocument?["implementation"] != nil
                        _receivedCallHierarchyCapability =
                            textDocument?["callHierarchy"] != nil
                        _receivedReferencesCapability =
                            textDocument?["references"] != nil
                        _receivedServerStatusCapability =
                            experimental?["serverStatusNotification"] as? Bool
                                == true
                    }
                    try write([
                        "jsonrpc": "2.0",
                        "method": "window/logMessage",
                        "params": [
                            "type": 2,
                            "message": "failed to resolve dependency in offline mode",
                        ],
                    ])
                    try write([
                        "jsonrpc": "2.0", "id": 900,
                        "method": "client/registerCapability",
                        "params": ["registrations": []],
                    ])
                    var serverCapabilities: [String: Any] = [:]
                    if let implementationProvider {
                        serverCapabilities["implementationProvider"] =
                            implementationProvider
                    }
                    if let callHierarchyProvider {
                        serverCapabilities["callHierarchyProvider"] =
                            callHierarchyProvider
                    }
                    if let referencesProvider {
                        serverCapabilities["referencesProvider"] =
                            referencesProvider
                    }
                    try write([
                        "jsonrpc": "2.0", "id": id,
                        "result": [
                            "capabilities": serverCapabilities,
                        ],
                    ])
                    if serverStatusQuiescent {
                        try sendServerStatus(quiescent: true)
                    }
                case "textDocument/definition":
                    try write([
                        "jsonrpc": "2.0", "id": id,
                        "result": [
                            "uri": "file:///fixture/src/lib.rs",
                            "range": [
                                "start": ["line": 0, "character": 7],
                                "end": ["line": 0, "character": 13],
                            ],
                        ],
                    ])
                case "textDocument/implementation":
                    try write([
                        "jsonrpc": "2.0", "id": id,
                        "result": implementationResult,
                    ])
                case "textDocument/references":
                    let params = message["params"] as? [String: Any]
                    let context = params?["context"] as? [String: Any]
                    let includeDeclaration = context?["includeDeclaration"]
                        as? Bool
                    locked {
                        if let includeDeclaration {
                            _referenceIncludeDeclarations.append(
                                includeDeclaration
                            )
                        }
                    }
                    try write([
                        "jsonrpc": "2.0", "id": id,
                        "result": referenceResult,
                    ])
                case "textDocument/prepareCallHierarchy":
                    try write([
                        "jsonrpc": "2.0", "id": id,
                        "result": prepareCallHierarchyResult,
                    ])
                case "callHierarchy/incomingCalls":
                    try write([
                        "jsonrpc": "2.0", "id": id,
                        "result": incomingCallResult,
                    ])
                case "callHierarchy/outgoingCalls":
                    try write([
                        "jsonrpc": "2.0", "id": id,
                        "result": outgoingCallResult,
                    ])
                case "shutdown":
                    try write([
                        "jsonrpc": "2.0", "id": id, "result": NSNull(),
                    ])
                default:
                    try write([
                        "jsonrpc": "2.0", "id": id, "result": NSNull(),
                    ])
                }
            } else if method == "initialized" {
                locked { _receivedInitialized = true }
            } else if method == "exit" {
                locked { _receivedExit = true }
                try output.close()
                done()
                return true
            }
        } else if (message["id"] as? NSNumber)?.intValue == 900,
                  message.keys.contains("result")
        {
            locked { _receivedRegisterCapabilityResponse = true }
        }
        return false
    }

    func sendServerStatus(quiescent: Bool) throws {
        try write([
            "jsonrpc": "2.0",
            "method": "experimental/serverStatus",
            "params": ["health": "ok", "quiescent": quiescent],
        ])
    }

    private func write(_ message: [String: Any]) throws {
        try output.write(contentsOf: LSPFraming.encode(message))
    }

    private func locked<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

private func exactTestMilliseconds(
    since start: ContinuousClock.Instant
) -> Double {
    let duration = start.duration(to: .now)
    return Double(duration.components.seconds) * 1_000
        + Double(duration.components.attoseconds) / 1_000_000_000_000_000
}

private func withFakeRustAnalyzerSession<T>(
    root: URL = exactFixtureURL(),
    snapshotFiles: [String] = ["src/lib.rs", "src/main.rs"],
    implementationProvider: Any? = true,
    implementationResult: Any = NSNull(),
    callHierarchyProvider: Any? = true,
    prepareCallHierarchyResult: Any = NSNull(),
    incomingCallResult: Any = NSNull(),
    outgoingCallResult: Any = NSNull(),
    referencesProvider: Any? = true,
    referenceResult: Any = NSNull(),
    serverStatusQuiescent: Bool = true,
    requestResponder: ((String, Int) -> PipeFakeRequestResponse)? = nil,
    serverCheck: ((PipeFakeLSPServer) -> Void)? = nil,
    body: (any ExactSession) throws -> T
) throws -> T {
    let snapshot = try DirectorySnapshot(root: root, files: snapshotFiles)
    let clientToServer = Pipe()
    let serverToClient = Pipe()
    let done = DispatchSemaphore(value: 0)
    let server = PipeFakeLSPServer(
        input: clientToServer.fileHandleForReading,
        output: serverToClient.fileHandleForWriting,
        implementationProvider: implementationProvider,
        implementationResult: implementationResult,
        callHierarchyProvider: callHierarchyProvider,
        prepareCallHierarchyResult: prepareCallHierarchyResult,
        incomingCallResult: incomingCallResult,
        outgoingCallResult: outgoingCallResult,
        referencesProvider: referencesProvider,
        referenceResult: referenceResult,
        serverStatusQuiescent: serverStatusQuiescent,
        requestResponder: requestResponder,
        done: { done.signal() }
    )
    server.start()
    let client = LSPClient(
        readHandle: serverToClient.fileHandleForReading,
        writeHandle: clientToServer.fileHandleForWriting
    )
    let session = try RustAnalyzerSession.start(
        client: client,
        restartClient: {
            throw ExactError.unavailable("fake restart unavailable")
        },
        projectURL: root,
        snapshot: snapshot,
        initializationOptions: [:],
        requestTimeout: 5,
        closeGrace: 5,
        diagnosticObserver: nil,
        attribution: ExactAttribution(
            provider: "fake-rust-analyzer",
            toolVersion: "fake",
            configFingerprint: "config",
            environmentFingerprint: "",
            environment: ExactAnalysisEnvironment(
                trustMode: .safe,
                limitations: [.buildScriptsDisabled, .procMacrosDisabled]
            ),
            generatedAt: Date(timeIntervalSince1970: 0)
        )
    )
    defer {
        session.close()
        _ = done.wait(timeout: .now() + 5)
    }
    let result = try body(session)
    serverCheck?(server)
    return result
}

private func exactFixtureURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/exact_fixture", isDirectory: true)
}

private func temporaryCallHierarchyFixture() throws -> URL {
    let root = try temporaryTestDirectory()
    let source = root.appendingPathComponent("src", isDirectory: true)
    try FileManager.default.createDirectory(
        at: source,
        withIntermediateDirectories: true
    )
    try Data("""
        use crate::b::bar;

        pub fn foo() -> i32 {
            let first = bar();
            let second = bar();
            first + second
        }
        """.utf8).write(to: source.appendingPathComponent("a.rs"))
    try Data("""
        pub fn bar() -> i32 {
            1
        }
        // wrong-base padding
        // wrong-base padding
        """.utf8).write(to: source.appendingPathComponent("b.rs"))
    return root
}

private func lspRange(line: Int, character: Int) -> [String: Any] {
    [
        "start": ["line": line, "character": character],
        "end": ["line": line, "character": character + 1],
    ]
}

private func nextDiagnostic(_ diagnostics: AsyncStream<String>) async -> String? {
    await withTaskGroup(of: String?.self) { group in
        group.addTask {
            var iterator = diagnostics.makeAsyncIterator()
            return await iterator.next()
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(2))
            return nil
        }
        let diagnostic = await group.next() ?? nil
        group.cancelAll()
        return diagnostic
    }
}

private func waitForProcess(_ pid: pid_t) throws -> Int32 {
    var status: Int32 = 0
    while waitpid(pid, &status, 0) == -1 {
        if errno != EINTR {
            throw CocoaError(.executableRuntimeMismatch)
        }
    }
    return status
}

private func processExists(_ pid: pid_t) -> Bool {
    errno = 0
    return Darwin.kill(pid, 0) == 0 || errno != ESRCH
}

private func waitForProcessToDisappear(_ pid: pid_t) -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while ContinuousClock.now < deadline {
        if !processExists(pid) { return true }
        usleep(1_000)
    }
    return !processExists(pid)
}

private func guardedSignalResult(
    _ signal: Int32
) async throws -> (deliveredSignal: Int32, orphanDisappeared: Bool) {
    try await withCheckedThrowingContinuation { continuation in
        Thread.detachNewThread {
            var helperPID: pid_t = 0
            var fakeChildPID: pid_t = 0
            guard ci_test_spawn_signal_helper(
                true,
                signal,
                &helperPID,
                &fakeChildPID
            ) else {
                continuation.resume(
                    throwing: CocoaError(.executableRuntimeMismatch)
                )
                return
            }
            do {
                let status = try waitForProcess(helperPID)
                let orphanDisappeared =
                    waitForProcessToDisappear(fakeChildPID)
                if !orphanDisappeared {
                    Darwin.kill(fakeChildPID, SIGKILL)
                }
                continuation.resume(
                    returning: (status & 0x7f, orphanDisappeared)
                )
            } catch {
                if fakeChildPID > 1 {
                    Darwin.kill(fakeChildPID, SIGKILL)
                }
                continuation.resume(throwing: error)
            }
        }
    }
}

private struct DirectorySnapshot: Snapshot {
    let snapshotID = SnapshotID(rawValue: UUID())
    let objectFormat: GitObjectFormat = .sha1
    let sourceKind: SourceKind = .untracked
    let root: URL
    private let files: [String]

    init(
        root: URL,
        files: [String] = ["src/lib.rs", "src/main.rs"]
    ) throws {
        self.root = root
        self.files = files
        for file in files {
            _ = try Data(contentsOf: root.appendingPathComponent(file))
        }
    }

    func listFiles() -> [(
        path: String,
        contentID: ContentID,
        fileMode: FileMode
    )] {
        files.compactMap { path in
            guard let bytes = try? readBytes(path: path) else { return nil }
            return (path, ContentID.sha256(of: bytes), .regular)
        }
    }

    func readBytes(path: String) throws -> [UInt8] {
        guard files.contains(path) else { throw GitError.missingPath(path) }
        return [UInt8](try Data(
            contentsOf: root.appendingPathComponent(path),
            options: .mappedIfSafe
        ))
    }
}
