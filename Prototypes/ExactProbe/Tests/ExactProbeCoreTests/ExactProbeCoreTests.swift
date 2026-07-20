import Foundation
import XCTest
@testable import ExactProbeCore

final class ExactProbeCoreTests: XCTestCase {
    func testFrameDecoderHandlesSplitAndCoalescedFrames() throws {
        let first = try LSPFraming.encode(["jsonrpc": "2.0", "id": 1, "result": "你好"])
        let second = try LSPFraming.encode(["jsonrpc": "2.0", "id": 2, "result": true])
        let bytes = first + second
        var decoder = LSPFrameDecoder()

        XCTAssertEqual(try decoder.append(bytes.prefix(7)).count, 0)
        XCTAssertEqual(try decoder.append(bytes.dropFirst(7).prefix(19)).count, 0)
        let messages = try decoder.append(bytes.dropFirst(26))

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["result"] as? String, "你好")
        XCTAssertEqual(messages[1]["result"] as? Bool, true)
    }

    func testCloseForceKillsUnresponsiveProcess() throws {
        let client = try LSPClient(
            executable: "/bin/sh",
            arguments: ["-c", "trap '' TERM; cat >/dev/null"]
        )

        client.close(grace: 0.1)

        XCTAssertFalse(client.isRunning)
        XCTAssertTrue(client.didForceKill)
    }

    func testSafeModeRequiresRustAnalyzer() throws {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/rust-analyzer") else {
            throw XCTSkip("requires rust-analyzer")
        }

        let result = try ExactProbe.runSafeMode(quiet: true)

        XCTAssertTrue(result.safeMarkerAbsent)
        XCTAssertTrue(result.safeTargetAbsent)
    }
}
