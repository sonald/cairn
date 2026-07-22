import CodeInsightCore
import CodeInsightGit
import Darwin
import Foundation
import Testing

@testable import CodeInsightExact

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

    #expect(
        profile.configFingerprint
            == "940ac77af3bcb2c15c059645193eceadc81f5d3b516f312736ef6d6b7afd40a9"
    )
    #expect(
        profile.environmentFingerprint
            == "7f33dae8274d15e6219fcb8705a73a5f5e952fe8404d815ac8cb68685605e3e4"
    )
}

@Test
func pipeFakeRunsInitializeDefinitionShutdownLifecycle() async throws {
    let (exitEvents, exitContinuation) = AsyncStream<Void>.makeStream()

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

        _ = try client.initialize(
            rootURL: URL(fileURLWithPath: "/fixture", isDirectory: true),
            timeout: 1
        )
        let result = try client.request(
            "textDocument/definition",
            params: [
                "textDocument": ["uri": "file:///fixture/src/main.rs"],
                "position": ["line": 0, "character": 0],
            ],
            timeout: 1
        )
        client.close(grace: 0.2)

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
        let location = try #require(result as? [String: Any])
        #expect(location["uri"] as? String == "file:///fixture/src/lib.rs")
    }
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
            requestTimeout: 10,
            closeGrace: 0.5
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

    let location = try #require(
        try session.definition(
            file: "src/main.rs",
            byteOffset: byteOffset
        ))

    #expect(session.readiness == .ready)
    #expect(location.file == "src/lib.rs")
    #expect(location.line == 1)
    #expect(location.column == 8)
    #expect(session.attribution.coverage == .partial)
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
    #expect(writeSandbox.environment["CARGO_NET_OFFLINE"] == "1")

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
        requestTimeout: 15,
        closeGrace: 0.5
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
    let location = try #require(
        try session.definition(
            file: "src/main.rs",
            byteOffset: source[..<call.lowerBound].utf8.count
        ))
    if let marker {
        try #require(waitForFile(marker, timeout: 15))
    }
    return location
}

private func waitForFile(_ url: URL, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if FileManager.default.fileExists(atPath: url.path) { return true }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return FileManager.default.fileExists(atPath: url.path)
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
    private var _error: Error?

    var requestMethods: [String] { locked { _requestMethods } }
    var requestIDs: [Int] { locked { _requestIDs } }
    var receivedInitialized: Bool { locked { _receivedInitialized } }
    var receivedExit: Bool { locked { _receivedExit } }
    var receivedRegisterCapabilityResponse: Bool {
        locked { _receivedRegisterCapabilityResponse }
    }
    var error: Error? { locked { _error } }

    init(input: FileHandle, output: FileHandle, done: @escaping () -> Void) {
        self.input = input
        self.output = output
        self.done = done
    }

    func start() {
        DispatchQueue.global().async { self.run() }
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
                switch method {
                case "initialize":
                    try write([
                        "jsonrpc": "2.0", "id": 900,
                        "method": "client/registerCapability",
                        "params": ["registrations": []],
                    ])
                    try write([
                        "jsonrpc": "2.0", "id": id,
                        "result": ["capabilities": [:]],
                    ])
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

    private func write(_ message: [String: Any]) throws {
        try output.write(contentsOf: LSPFraming.encode(message))
    }

    private func locked<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

private struct DirectorySnapshot: Snapshot {
    let snapshotID = SnapshotID(rawValue: UUID())
    let objectFormat: GitObjectFormat = .sha1
    let sourceKind: SourceKind = .untracked
    let root: URL
    private let files = ["src/lib.rs", "src/main.rs"]

    init(root: URL) throws {
        self.root = root
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
