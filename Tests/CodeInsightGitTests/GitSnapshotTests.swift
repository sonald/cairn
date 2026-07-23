import Dispatch
import Foundation
import Testing
import os
@testable import CodeInsightGit

private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

@Test
func libgit2SerialExecutorCompletesConcurrentHistoryAndSnapshotCapture() {
    let completion = DispatchSemaphore(value: 0)
    let failureDescription = OSAllocatedUnfairLock<String?>(initialState: nil)

    Task.detached {
        defer { completion.signal() }
        do {
            try await runLibGit2Stress()
        } catch {
            failureDescription.withLock { $0 = String(describing: error) }
        }
    }

    guard completion.wait(timeout: .now() + .seconds(60)) == .success else {
        Issue.record(
            "libgit2 stress hung: 5 rounds of 8 CommitLog + 8 snapshot captures exceeded 60s"
        )
        return
    }
    if let failure = failureDescription.withLock({ $0 }) {
        Issue.record("libgit2 stress error: \(failure)")
    }
}

private func runLibGit2Stress() async throws {
    var expected: (history: Int, commit: Int, worktree: Int)?
    for round in 1...5 {
        let counts = try await withThrowingTaskGroup(
            of: (kind: Int, count: Int).self,
            returning: (history: Int, commit: Int, worktree: Int).self
        ) { group in
            for index in 0..<8 {
                group.addTask {
                    (0, try CommitLog(repositoryURL: repositoryRoot).commits.count)
                }
                group.addTask {
                    if index.isMultiple(of: 2) {
                        return (
                            1,
                            try CommitSnapshot(repositoryURL: repositoryRoot)
                                .listFiles().count
                        )
                    }
                    return (
                        2,
                        try WorktreeSnapshot(repositoryURL: repositoryRoot)
                            .listFiles().count
                    )
                }
            }

            var histories: [Int] = []
            var commits: [Int] = []
            var worktrees: [Int] = []
            for try await result in group {
                switch result.kind {
                case 0: histories.append(result.count)
                case 1: commits.append(result.count)
                default: worktrees.append(result.count)
                }
            }
            guard let history = histories.first,
                  let commit = commits.first,
                  let worktree = worktrees.first,
                  histories.count == 8,
                  commits.count == 4,
                  worktrees.count == 4,
                  history > 0,
                  commit > 0,
                  worktree > 0,
                  histories.allSatisfy({ $0 == history }),
                  commits.allSatisfy({ $0 == commit }),
                  worktrees.allSatisfy({ $0 == worktree })
            else {
                throw NSError(
                    domain: "CodeInsightGitTests.libgit2Stress",
                    code: round,
                    userInfo: [NSLocalizedDescriptionKey: "round \(round) returned inconsistent results"]
                )
            }
            return (history, commit, worktree)
        }

        if let expected,
           counts.history != expected.history
            || counts.commit != expected.commit
            || counts.worktree != expected.worktree
        {
            throw NSError(
                domain: "CodeInsightGitTests.libgit2Stress",
                code: round,
                userInfo: [NSLocalizedDescriptionKey: "round \(round) differed from earlier rounds"]
            )
        }
        expected = counts
    }
}

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
func currentBranchNameReadsTheCheckedOutBranch() throws {
    let fixture = try GitFixture()
    defer { fixture.remove() }
    try Data("fn main() {}\n".utf8).write(
        to: fixture.root.appendingPathComponent("main.rs")
    )
    try fixture.git("add", "main.rs")
    try fixture.commit("base")
    try fixture.git("branch", "-M", "feature/toolbar")

    #expect(currentBranchName(repositoryURL: fixture.root) == "feature/toolbar")
}

@Test
func currentBranchNameReportsDetachedHead() throws {
    let fixture = try GitFixture()
    defer { fixture.remove() }
    try Data("fn main() {}\n".utf8).write(
        to: fixture.root.appendingPathComponent("main.rs")
    )
    try fixture.git("add", "main.rs")
    try fixture.commit("base")
    try fixture.git("checkout", "--detach", "-q")

    #expect(currentBranchName(repositoryURL: fixture.root) == "detached")
}

@Test
func currentBranchNameReturnsNilOutsideARepository() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "CodeInsightGitNonRepository-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(currentBranchName(repositoryURL: root) == nil)
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

@Test
func commitSnapshotMarksLFSPointersAndReturnsRawBytes() throws {
    let fixture = try GitFixture()
    defer { fixture.remove() }
    let pointer = """
        version https://git-lfs.github.com/spec/v1
        oid sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
        size 123456

        """
    try Data(pointer.utf8).write(
        to: fixture.root.appendingPathComponent("large.rs")
    )
    try fixture.git("add", "large.rs")
    try fixture.commit("lfs pointer")

    let snapshot = try CommitSnapshot(repositoryURL: fixture.root)
    let file = try #require(snapshot.listFiles().first { $0.path == "large.rs" })

    #expect(file.fileMode == .lfsPointer)
    #expect(try snapshot.readBytes(path: "large.rs") == Array(pointer.utf8))
}

@Test
func trackedIgnoredRustFileAppearsInCommitAndWorktreeSnapshots() throws {
    let fixture = try GitFixture()
    defer { fixture.remove() }
    let contents = Array("fn tracked_ignored() {}\n".utf8)
    try Data("ignored.rs\n".utf8).write(
        to: fixture.root.appendingPathComponent(".gitignore")
    )
    try Data(contents).write(
        to: fixture.root.appendingPathComponent("ignored.rs")
    )
    try fixture.git("add", ".gitignore")
    try fixture.git("add", "-f", "ignored.rs")
    try fixture.commit("tracked ignored file")

    let commit = try CommitSnapshot(repositoryURL: fixture.root)
    let worktree = try WorktreeSnapshot(repositoryURL: fixture.root)

    // .gitignore must not hide a file once Git tracks it in either view.
    #expect(commit.listFiles().contains { $0.path == "ignored.rs" })
    #expect(worktree.listFiles().contains { $0.path == "ignored.rs" })
    #expect(try commit.readBytes(path: "ignored.rs") == contents)
    #expect(try worktree.readBytes(path: "ignored.rs") == contents)
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
