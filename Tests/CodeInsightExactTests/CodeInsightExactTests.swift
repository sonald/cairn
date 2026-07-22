import CodeInsightCore
import CodeInsightGit
import Darwin
import Foundation
import XCTest
@testable import CodeInsightExact

final class CodeInsightExactTests: XCTestCase {
    func testFrameDecoderReadsSingleFrame() throws {
        var decoder = LSPFrameDecoder()
        let messages = try decoder.append(LSPFraming.encode([
            "jsonrpc": "2.0", "id": 1, "result": true,
        ]))

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["result"] as? Bool, true)
    }

    func testFrameDecoderRetainsSplitFrame() throws {
        let frame = try LSPFraming.encode([
            "jsonrpc": "2.0", "id": 1, "result": "split",
        ])
        var decoder = LSPFrameDecoder()

        XCTAssertTrue(try decoder.append(frame.prefix(9)).isEmpty)
        XCTAssertTrue(try decoder.append(frame.dropFirst(9).prefix(17)).isEmpty)
        let messages = try decoder.append(frame.dropFirst(26))

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["result"] as? String, "split")
    }

    func testFrameDecoderReadsCoalescedFrames() throws {
        let first = try LSPFraming.encode([
            "jsonrpc": "2.0", "id": 1, "result": 1,
        ])
        let second = try LSPFraming.encode([
            "jsonrpc": "2.0", "id": 2, "result": 2,
        ])
        var decoder = LSPFrameDecoder()

        let messages = try decoder.append(first + second)

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual((messages[0]["result"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual((messages[1]["result"] as? NSNumber)?.intValue, 2)
    }

    func testFrameDecoderCountsUTF8Bytes() throws {
        let body = Data(#"{"jsonrpc":"2.0","result":"你好😀"}"#.utf8)
        var frame = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        frame.append(body)
        var decoder = LSPFrameDecoder()

        let messages = try decoder.append(frame)

        XCTAssertEqual(messages[0]["result"] as? String, "你好😀")
    }

    func testByteAndLSPUTF16PositionsRoundTrip() throws {
        let bytes = Array("a你😀z\n汉🙂b".utf8)
        let map = try XCTUnwrap(LSPPositionMap(utf8: bytes))
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
            XCTAssertEqual(map.position(forByteOffset: byteOffset), position)
            XCTAssertEqual(map.byteOffset(for: position), byteOffset)
        }
        XCTAssertNil(map.position(forByteOffset: 2))
        XCTAssertNil(map.byteOffset(for: LSPPosition(line: 0, character: 3)))
    }

    func testExactProfileKeyHashesCargoFileBytes() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/exact_fixture", isDirectory: true)

        let profile = try ExactProfileKey(projectURL: root)

        XCTAssertEqual(
            profile.configFingerprint,
            "940ac77af3bcb2c15c059645193eceadc81f5d3b516f312736ef6d6b7afd40a9"
        )
        XCTAssertEqual(
            profile.environmentFingerprint,
            "7f33dae8274d15e6219fcb8705a73a5f5e952fe8404d815ac8cb68685605e3e4"
        )
    }

    func testPipeFakeRunsInitializeDefinitionShutdownLifecycle() throws {
        let clientToServer = Pipe()
        let serverToClient = Pipe()
        let done = expectation(description: "fake LSP server received exit")
        let server = PipeFakeLSPServer(
            input: clientToServer.fileHandleForReading,
            output: serverToClient.fileHandleForWriting,
            done: done
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

        wait(for: [done], timeout: 2)
        XCTAssertNil(server.error)
        XCTAssertEqual(server.requestMethods, [
            "initialize", "textDocument/definition", "shutdown",
        ])
        XCTAssertEqual(Set(server.requestIDs).count, 3)
        XCTAssertTrue(server.receivedInitialized)
        XCTAssertTrue(server.receivedExit)
        XCTAssertTrue(server.receivedRegisterCapabilityResponse)
        let location = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(location["uri"] as? String, "file:///fixture/src/lib.rs")
    }

    func testCloseForceKillsAndReapsUnresponsiveProcess() throws {
        let client = try LSPClient(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' 15; while :; do :; done"]
        )
        let pid = try XCTUnwrap(client.processIdentifier)
        Thread.sleep(forTimeInterval: 0.05)

        let started = Date()
        client.close(grace: 0.05)

        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertFalse(client.isRunning)
        XCTAssertTrue(client.didForceKill)
        XCTAssertTrue(client.didReap)
        errno = 0
        XCTAssertEqual(waitpid(pid, nil, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD)
    }

    func testRustAnalyzerFindsCrossFileDefinitionWhenInstalled() throws {
        guard let executableURL = RustAnalyzerProvider.findExecutable() else {
            throw XCTSkip("rust-analyzer not found")
        }
        let fixture = try copiedFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let snapshot = try DirectorySnapshot(root: fixture)
        let provider = try RustAnalyzerProvider(
            projectURL: fixture,
            executableURL: executableURL,
            requestTimeout: 10,
            closeGrace: 0.5
        )
        let session = try provider.prepare(
            snapshot: snapshot,
            profile: ExactProfileKey(projectURL: fixture),
            trustMode: .safe
        )
        defer { session.close() }
        XCTAssertEqual(session.readiness, .preparing)
        let bytes = try snapshot.readBytes(path: "src/main.rs")
        let source = try XCTUnwrap(String(data: Data(bytes), encoding: .utf8))
        let call = try XCTUnwrap(
            source.range(of: "answer();", options: .backwards)
        )
        let byteOffset = source[..<call.lowerBound].utf8.count

        let location = try XCTUnwrap(session.definition(
            file: "src/main.rs",
            byteOffset: byteOffset
        ))

        XCTAssertEqual(session.readiness, .ready)
        XCTAssertEqual(location.file, "src/lib.rs")
        XCTAssertEqual(location.line, 1)
        XCTAssertEqual(location.column, 8)
        XCTAssertEqual(session.attribution.coverage, .partial)
        XCTAssertEqual(session.attribution.configFingerprint.count, 64)
        XCTAssertEqual(session.attribution.environmentFingerprint.count, 64)
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
}

private final class PipeFakeLSPServer: @unchecked Sendable {
    private let input: FileHandle
    private let output: FileHandle
    private let done: XCTestExpectation
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

    init(input: FileHandle, output: FileHandle, done: XCTestExpectation) {
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
        done.fulfill()
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
                done.fulfill()
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
