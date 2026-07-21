import Foundation
import Testing
@testable import CodeInsightGit

private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

@Test
func commitLogReadsHeadFirstWithBranchLabels() throws {
    let commits = try CommitLog(repositoryURL: repositoryRoot).commits
    let expectedSHA = try repositoryGit("rev-parse", "HEAD")
    let expectedSummary = try repositoryGit("log", "-1", "--format=%s")

    #expect(commits.count > 10)
    let head = try #require(commits.first)
    #expect(head.fullSHA == expectedSHA)
    #expect(head.shortSHA == String(expectedSHA.prefix(7)))
    #expect(head.summary == expectedSummary)
    #expect(head.branchNames.contains("main"))
}

@Test
func commitSnapshotsReadTrackedRawBytesAndDistinguishAdjacentCommits() throws {
    let head = try CommitSnapshot(repositoryURL: repositoryRoot)
    let previous = try CommitSnapshot(repositoryURL: repositoryRoot, revision: "HEAD~1")
    let headFiles = head.listFiles()

    #expect(!headFiles.isEmpty)
    #expect(headFiles.contains { $0.path == "Package.swift" })
    #expect(headFiles.contains { $0.path == "Package.resolved" })
    #expect(head.objectFormat == .sha1)

    let packageBytes = try head.readBytes(path: "Package.swift")
    #expect(!packageBytes.isEmpty)
    #expect(String(bytes: packageBytes, encoding: .utf8)?.contains("PackageDescription") == true)

    let headContents = Dictionary(uniqueKeysWithValues: headFiles.map {
        ($0.path, $0.contentID)
    })
    let previousContents = Dictionary(uniqueKeysWithValues: previous.listFiles().map {
        ($0.path, $0.contentID)
    })
    #expect(headContents != previousContents)
}

@Test
func worktreeSnapshotKeepsCapturedBytesAfterTheFileChanges() throws {
    let fixture = try GitFixture()
    defer { fixture.remove() }

    let file = fixture.root.appendingPathComponent("sample.rs")
    let captured = Array("captured bytes".utf8)
    try Data(captured).write(to: file)
    let snapshot = try WorktreeSnapshot(repositoryURL: fixture.root)

    try Data("changed later".utf8).write(to: file)
    #expect(try snapshot.readBytes(path: "sample.rs") == captured)
}

@Test
func commitSnapshotPreservesTreeFileModes() throws {
    let fixture = try GitFixture()
    defer { fixture.remove() }

    try Data("fn main() {}".utf8).write(
        to: fixture.root.appendingPathComponent("sample.rs")
    )
    try FileManager.default.createSymbolicLink(
        atPath: fixture.root.appendingPathComponent("link.rs").path,
        withDestinationPath: "sample.rs"
    )
    try fixture.git("add", "sample.rs", "link.rs")
    try fixture.commit("base")

    let commit = try fixture.git("rev-parse", "HEAD")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    try fixture.git(
        "update-index", "--add", "--cacheinfo",
        "160000,\(commit),dependency"
    )
    try fixture.commit("gitlink")

    let snapshot = try CommitSnapshot(repositoryURL: fixture.root)
    let modes = Dictionary(uniqueKeysWithValues: snapshot.listFiles().map {
        ($0.path, $0.fileMode)
    })
    #expect(modes["sample.rs"] == .regular)
    #expect(modes["link.rs"] == .symlink)
    #expect(modes["dependency"] == .gitlink)
    #expect(String(bytes: try snapshot.readBytes(path: "link.rs"), encoding: .utf8) == "sample.rs")
}

private final class GitFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CodeInsightGitTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git("init", "-q")
    }

    func commit(_ message: String) throws {
        try git(
            "-c", "user.name=CodeInsight",
            "-c", "user.email=codeinsight@example.com",
            "commit", "-q", "-m", message
        )
    }

    @discardableResult
    func git(_ arguments: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = root
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "git failed"
            throw FixtureError.git(message)
        }
        return String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private enum FixtureError: Error {
    case git(String)
}

private func repositoryGit(_ arguments: String...) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = repositoryRoot
    let output = Pipe()
    let error = Pipe()
    process.standardOutput = output
    process.standardError = error
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw FixtureError.git(String(
            data: error.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? "git failed")
    }
    return String(
        data: output.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
    )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}
