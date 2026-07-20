import Foundation
import GitSnapshotProbe
import XCTest

final class GitSnapshotProbeTests: XCTestCase {
    func testDirtyFileCaptureIsImmutable() throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }

        let file = fixture.root.appendingPathComponent("sample.rs")
        try Data("committed".utf8).write(to: file)
        try fixture.git("add", "sample.rs")
        try fixture.git("-c", "user.name=Probe", "-c", "user.email=probe@example.com", "commit", "-m", "fixture")

        let capturedBytes = Data("captured dirty bytes".utf8)
        try capturedBytes.write(to: file)
        let snapshot = try WorktreeSnapshot(repositoryURL: fixture.root)

        try Data("modified after capture".utf8).write(to: file)
        XCTAssertEqual(try snapshot.read(path: "sample.rs"), capturedBytes)
        XCTAssertEqual(snapshot.stats.copiedFiles, 1)
    }

    func testStaleGenerationResultIsDropped() async throws {
        let display = GenerationDisplay(snapshot: "A")
        let generationA = await display.token()
        let slowA = Task {
            try await Task.sleep(for: .milliseconds(100))
            return await display.publish(snapshot: "A", generation: generationA)
        }

        await display.switchTo(snapshot: "B")
        let acceptedA = try await slowA.value
        let displayed = await display.displayed()
        XCTAssertFalse(acceptedA)
        XCTAssertEqual(displayed, "B")
    }
}

private final class GitFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitSnapshotProbeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git("init", "-q")
    }

    func git(_ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = root
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let error = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "git failed"
            throw FixtureError.git(error)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private enum FixtureError: Error {
    case git(String)
}
