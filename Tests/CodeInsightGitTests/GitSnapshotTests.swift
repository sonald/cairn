import Dispatch
import CodeInsightCore
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
    let cargo = fixture.root.appendingPathComponent("Cargo.toml")
    let capturedCargo = Array("[package]\nname = \"sample\"\n".utf8)
    try Data(capturedCargo).write(to: cargo)
    let snapshot = try WorktreeSnapshot(repositoryURL: fixture.root)

    try Data("changed later".utf8).write(to: file)
    try Data("[package]\nname = \"changed\"\n".utf8).write(to: cargo)
    #expect(try snapshot.readBytes(path: "sample.rs") == captured)
    #expect(try snapshot.readBytes(path: "Cargo.toml") == capturedCargo)
    #expect(!snapshot.listFiles().contains { $0.path == "Cargo.toml" })
    #expect(snapshot.projectRootName == fixture.root.lastPathComponent)
}

@Test
func explicitRustWorktreeSnapshotMatchesTheCompatibilityInitializer() throws {
    let fixture = try GitFixture()
    defer { fixture.remove() }
    let files: [String: String] = [
        "src/lib.rs": "pub fn rust_only() {}\n",
        "src/ignored.py": "def python_only(): pass\n",
        "src/ignored.ts": "export const typescriptOnly = 1\n",
        "Cargo.toml": "[package]\nname = \"fixture\"\n",
        "Cargo.lock": "# lock\n",
    ]
    for (path, contents) in files {
        let url = fixture.root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }

    let compatibility = try WorktreeSnapshot(repositoryURL: fixture.root)
    let explicit = try WorktreeSnapshot(
        repositoryURL: fixture.root,
        language: .rust
    )
    let compatibilityFiles = compatibility.listFiles()
    let explicitFiles = explicit.listFiles()

    #expect(compatibilityFiles.map(\.path) == ["src/lib.rs"])
    #expect(explicitFiles.map(\.path) == compatibilityFiles.map(\.path))
    for (left, right) in zip(compatibilityFiles, explicitFiles) {
        #expect(left.contentID == right.contentID)
        #expect(left.fileMode == right.fileMode)
        #expect(try compatibility.readBytes(path: left.path)
            == explicit.readBytes(path: right.path))
    }
    #expect(try compatibility.readBytes(path: "Cargo.toml")
        == explicit.readBytes(path: "Cargo.toml"))
    #expect(try compatibility.readBytes(path: "Cargo.lock")
        == explicit.readBytes(path: "Cargo.lock"))
}

@Test
func unionWorktreeSnapshotCapturesSelectedModesAndNestedConfigInventory() throws {
    let fixture = try GitFixture()
    defer { fixture.remove() }
    let files: [String: String] = [
        "src/main.rs": "fn main() {}\n",
        "src/lib.rs": "pub fn lib() {}\n",
        "src/lib.py": "class Service: pass\n",
        "src/a.ts": "export const a = 1\n",
        "src/b.tsx": "export const b = 1\n",
        "src/ignored.d.ts": "export declare const x: number\n",
        "src/ignored.js": "const ignored = 1\n",
        "src/ignored.pyi": "class Stub: ...\n",
        "src/ignored.mts": "export const m = 1\n",
        "src/ignored.cts": "export const c = 1\n",
        "src/ignored.rs.old": "fn old() {}\n",
        "Cargo.toml": "[package]\nname = \"fixture\"\n",
        "Cargo.lock": "version = 4\n",
        "pyproject.toml": "[project]\nname = \"sample\"\n",
        "uv.lock": "version = 1\n",
        "tsconfig.json": "{}\n",
        "package.json": "{}\n",
        "node_modules/pkg.ts": "export const pkg = 1\n",
        ".build/generated.ts": "export const built = 1\n",
        "nested/Cargo.toml": "[package]\nname = \"nested\"\n",
        "nested/Cargo.lock": "# nested lock\n",
        "nested/pyproject.toml": "[project]\nname = \"nested\"\n",
        "nested/uv.lock": "version = 1\n",
        "nested/tsconfig.json": "{}\n",
        "nested/package.json": "{}\n",
        "nested/bun.lockb": Array(repeating: UInt8(ascii: "B"), count: 4).map(String.init).joined(),
    ]
    for (path, contents) in files {
        let url = fixture.root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }
    let projectBytes = try Data(
        contentsOf: fixture.root.appendingPathComponent("Cargo.toml")
    )
    let skippedBytes = try Data(
        contentsOf: fixture.root.appendingPathComponent("node_modules/pkg.ts")
    )
    try FileManager.default.createDirectory(
        at: fixture.root.appendingPathComponent("src/config-link"),
        withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(
        atPath: fixture.root.appendingPathComponent("src/config-link/tsconfig.json").path,
        withDestinationPath: "../../tsconfig.json"
    )

    let snapshot = try WorktreeSnapshot(
        repositoryURL: fixture.root,
        languages: [.rust, .python, .typescript]
    )

    #expect(snapshot.listFiles().map(\.path) == [
        "src/a.ts",
        "src/b.tsx",
        "src/lib.py",
        "src/lib.rs",
        "src/main.rs",
    ])
    #expect(Set(snapshot.configurationPaths) == Set([
        "Cargo.toml",
        "Cargo.lock",
        "pyproject.toml",
        "uv.lock",
        "tsconfig.json",
        "package.json",
        "nested/Cargo.toml",
        "nested/Cargo.lock",
        "nested/pyproject.toml",
        "nested/uv.lock",
        "nested/tsconfig.json",
        "nested/package.json",
        "nested/bun.lockb",
    ]))
    #expect(snapshot.configurationPaths.contains("src/config-link/tsconfig.json") == false)
    #expect(snapshot.listFiles().contains {
        $0.path.contains("Cargo")
            || $0.path.contains("pyproject")
            || $0.path.contains("tsconfig")
            || $0.path.hasSuffix(".lock")
            || $0.path.hasSuffix("package.json")
    } == false)
    #expect(try Data(contentsOf: fixture.root.appendingPathComponent("Cargo.toml"))
        == projectBytes)
    #expect(try Data(contentsOf: fixture.root.appendingPathComponent("node_modules/pkg.ts"))
        == skippedBytes)
}

@Test
func worktreeSnapshotRejectsUnsupportedLanguageArraysBeforeOpeningARepository() {
    let nonexistent = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodeInsightUnionRejects-\(UUID().uuidString)")

    let invalid: [[LanguageID]] = [
        [],
        [.rust, .rust],
        [.python, .python, .rust],
        [.javascript],
        [.rust, .javascript],
    ]
    for languages in invalid {
        do {
            _ = try WorktreeSnapshot(
                repositoryURL: nonexistent,
                languages: languages
            )
            Issue.record("Invalid union languages unexpectedly succeeded: \(languages)")
        } catch let error as CocoaError {
            #expect(error.code == .featureUnsupported)
        } catch {
            Issue.record("Invalid union preflight happened after repository access: \(error)")
        }
    }
}

@Test
func worktreeSingletonInitializerMatchesUnionInitializerForOneLanguage() throws {
    let fixture = try GitFixture()
    defer { fixture.remove() }
    let files: [String: String] = [
        "src/main.rs": "fn main() {}\n",
        "src/ignored.py": "def ignored(): pass\n",
        "Cargo.toml": "[package]\nname = \"fixture\"\n",
        "Cargo.lock": "# version = 4\n",
    ]
    for (path, contents) in files {
        let url = fixture.root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }

    let singleton = try WorktreeSnapshot(repositoryURL: fixture.root, language: .rust)
    let union = try WorktreeSnapshot(
        repositoryURL: fixture.root,
        languages: [.rust]
    )

    #expect(union.listFiles().map(\.path) == singleton.listFiles().map(\.path))
    #expect(union.configurationPaths == singleton.configurationPaths)
    for (path, file) in zip(singleton.listFiles(), union.listFiles()) {
        #expect(path.contentID == file.contentID)
        #expect(path.fileMode == file.fileMode)
        #expect(try singleton.readBytes(path: file.path) == union.readBytes(path: file.path))
    }
}

@Test
func commitSnapshotExposesHistoricalConfigurationInventoryAndExcludesSymlinkMarkers() throws {
    let fixture = try GitFixture()
    defer { fixture.remove() }
    let files: [String: String] = [
        "src/main.rs": "fn main() {}\n",
        "src/lib.py": "def f(): pass\n",
        "src/a.ts": "export const a = 1\n",
        "src/ignored.d.ts": "export declare const x: number\n",
        "src/ignored.js": "const ignored = 1\n",
        "Cargo.toml": "[package]\nname = \"fixture\"\n",
        "Cargo.lock": "# lock\n",
        "pyrightconfig.json": "{}\n",
        "uv.lock": "version = 1\n",
        "tsconfig.json": "{}\n",
        "package.json": "{}\n",
        "nested/Cargo.toml": "[package]\nname = \"nested\"\n",
        "nested/pyproject.toml": "[project]\nname = \"nested\"\n",
        "nested/tsconfig.json": "{}\n",
    ]
    for (path, contents) in files {
        let url = fixture.root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }
    try FileManager.default.createDirectory(
        at: fixture.root.appendingPathComponent("nested/link"),
        withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(
        atPath: fixture.root.appendingPathComponent("nested/link/Cargo.toml").path,
        withDestinationPath: "../../Cargo.toml"
    )
    try fixture.git("add", ".")
    try fixture.commit("base")

    let first = try CommitSnapshot(repositoryURL: fixture.root)
    let firstPaths = Set(first.configurationPaths)
    #expect(firstPaths.contains("Cargo.toml"))
    #expect(firstPaths.contains("Cargo.lock"))
    #expect(firstPaths.contains("pyrightconfig.json"))
    #expect(firstPaths.contains("pyproject.toml") == false)
    #expect(firstPaths.contains("tsconfig.json"))
    #expect(firstPaths.contains("package.json"))
    #expect(firstPaths.contains("nested/Cargo.toml"))
    #expect(firstPaths.contains("nested/pyproject.toml"))
    #expect(firstPaths.contains("nested/tsconfig.json"))
    #expect(firstPaths.contains("nested/link/Cargo.toml") == false)

    try fixture.git("rm", "-q", "nested/Cargo.toml")
    try Data("# new marker\n".utf8).write(
        to: fixture.root.appendingPathComponent("nested/Cargo.lock")
    )
    try fixture.git("add", "nested/Cargo.lock")
    try fixture.commit("nested marker inventory change")

    let second = try CommitSnapshot(repositoryURL: fixture.root)
    let secondPaths = Set(second.configurationPaths)
    #expect(secondPaths.contains("nested/Cargo.lock"))
    #expect(secondPaths.contains("nested/Cargo.toml") == false)
    #expect(try second.readBytes(path: "nested/Cargo.lock")
        == Array("# new marker\n".utf8))
    #expect(firstPaths != secondPaths)
    #expect(first.commitOID != second.commitOID)
}

@Test
func unsupportedWorktreeLanguagesFailBeforeOpeningARepository() {
    let nonexistent = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodeInsightUnsupported-\(UUID().uuidString)")

    do {
        _ = try WorktreeSnapshot(repositoryURL: nonexistent, language: .javascript)
        Issue.record("Unsupported language unexpectedly succeeded: \(LanguageID.javascript)")
    } catch let error as CocoaError {
        #expect(error.code == .featureUnsupported)
        #expect((error as NSError).localizedFailureReason?.contains(
            String(describing: LanguageID.javascript)
        ) == true)
    } catch {
        Issue.record("Unsupported preflight happened after repository access: \(error)")
    }
}

@Test
func pythonWorktreeSnapshotCapturesOnlyPythonFilesAndRootConfigs() throws {
    let fixture = try GitFixture()
    defer { fixture.remove() }
    let files: [String: String] = [
        "main.py": "print('main')\n",
        "src/service.py": "class Service: pass\n",
        "src/ignored.rs": "fn rust() {}\n",
        "src/ignored.ts": "const ignored = 1\n",
        "src/ignored.js": "const ignored = 1\n",
        "nested/pyproject.toml": "[tool.pyright]\n",
        ".venv/lib.py": "print('venv')\n",
        "__pycache__/main.cpython-311.pyc": "pyc",
        "build/generated.py": "print('build')\n",
        "dist/generated.py": "print('dist')\n",
        "pyrightconfig.json": "{\"venvPath\": \".\"}\n",
        "pyproject.toml": "[project]\nname = \"sample\"\n",
        "uv.lock": "version = 1\n",
    ]
    for (path, contents) in files {
        let url = fixture.root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }

    let snapshot = try WorktreeSnapshot(
        repositoryURL: fixture.root,
        language: .python
    )

    #expect(snapshot.listFiles().map(\.path) == ["main.py", "src/service.py"])
    #expect(try snapshot.readBytes(path: "pyrightconfig.json")
        == Array(files["pyrightconfig.json"]!.utf8))
    #expect(try snapshot.readBytes(path: "pyproject.toml")
        == Array(files["pyproject.toml"]!.utf8))
    #expect(try snapshot.readBytes(path: "uv.lock")
        == Array(files["uv.lock"]!.utf8))
    #expect(try snapshot.readBytes(path: "nested/pyproject.toml")
        == Array(files["nested/pyproject.toml"]!.utf8))
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

@Test
func typescriptWorktreeSnapshotCapturesOnlyClassifierApprovedTsAndRootConfigs() throws {
    let fixture = try GitFixture()
    defer { fixture.remove() }
    let files: [String: String] = [
        "src/a.ts": "export const a = 1\n",
        "src/b.tsx": "export const b = 1\n",
        "src/ignored.d.ts": "export declare const x: number\n",
        "src/ignored.js": "const ignored = 1\n",
        "src/ignored.rs": "fn rust() {}\n",
        "nested/tsconfig.json": "{}\n",
        ".gitignore": "node_modules/\n",
        "node_modules/pkg.ts": "export const pkg = 1\n",
        ".build/generated.ts": "export const built = 1\n",
        "tsconfig.json": "{}\n",
        "package.json": "{}\n",
        "bun.lockb": Array(repeating: UInt8(ascii: "B"), count: 8).map(String.init).joined(),
    ]
    for (path, contents) in files {
        let url = fixture.root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }
    try FileManager.default.createSymbolicLink(
        atPath: fixture.root.appendingPathComponent("src/link.ts").path,
        withDestinationPath: "b.tsx"
    )

    let snapshot = try WorktreeSnapshot(repositoryURL: fixture.root, language: .typescript)

    #expect(snapshot.listFiles().map(\.path) == ["src/a.ts", "src/b.tsx"])
    #expect(try snapshot.readBytes(path: "tsconfig.json") == Array(files["tsconfig.json"]!.utf8))
    #expect(try snapshot.readBytes(path: "package.json") == Array(files["package.json"]!.utf8))
    #expect(try snapshot.readBytes(path: "bun.lockb") == Array(files["bun.lockb"]!.utf8))
    #expect(try snapshot.readBytes(path: "nested/tsconfig.json")
        == Array(files["nested/tsconfig.json"]!.utf8))
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
