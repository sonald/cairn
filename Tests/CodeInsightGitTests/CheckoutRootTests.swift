import CodeInsightCore
import Foundation
import Testing
@testable import CodeInsightGit

/// Regular files (including LFS pointers, which are plain 100644 blobs) by
/// path → content hash; symlinks and gitlinks are not expected on disk.
private func expectedFiles(_ snapshot: CommitSnapshot) -> [String: ContentID] {
    Dictionary(uniqueKeysWithValues: snapshot.listFiles()
        .filter { $0.fileMode == .regular || $0.fileMode == .lfsPointer }
        .map { ($0.path, $0.contentID) })
}

/// Every file under the checkout except the `.git` directory, by relative
/// path → content hash, following nothing.
private func filesOnDisk(_ root: URL) throws -> [String: ContentID] {
    var result: [String: ContentID] = [:]
    let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey]
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: keys,
        options: [.producesRelativePathURLs]
    ) else { return result }
    for case let url as URL in enumerator {
        if url.relativePath == ".git" { enumerator.skipDescendants(); continue }
        let values = try url.resourceValues(forKeys: Set(keys))
        if values.isSymbolicLink == true {
            result[url.relativePath + " (symlink)"] = ContentID.sha256(of: [])
            continue
        }
        guard values.isRegularFile == true else { continue }
        result[url.relativePath] = ContentID.sha256(of: Array(try Data(contentsOf: url)))
    }
    return result
}

/// Everything under the user's `.git` that a stray write would change.
private func gitDirectoryState(_ repository: URL) throws -> [String: Data] {
    let gitDirectory = repository.appendingPathComponent(".git")
    var state: [String: Data] = [:]
    guard let enumerator = FileManager.default.enumerator(
        at: gitDirectory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.producesRelativePathURLs]
    ) else { return state }
    for case let url as URL in enumerator
        where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
    {
        state[url.relativePath] = try Data(contentsOf: url)
    }
    return state
}

private func makeTwoCommitFixture() throws -> (GitFixture, first: String, second: String) {
    let fixture = try GitFixture()
    try fixture.writeFile("Cargo.toml", "[package]\nname = \"fixture\"\n")
    try fixture.writeFile("src/lib.rs", "pub fn one() -> u8 { 1 }\n")
    try fixture.writeFile("src/old.rs", "pub fn old() {}\n")
    try fixture.writeFile("tools/run.sh", "#!/bin/sh\necho run\n")
    try fixture.writeFile(
        "large.bin",
        "version https://git-lfs.github.com/spec/v1\noid sha256:00\nsize 1\n"
    )
    try FileManager.default.createSymbolicLink(
        atPath: fixture.root.appendingPathComponent("link.rs").path,
        withDestinationPath: "src/lib.rs"
    )
    try fixture.git("add", "-A")
    try fixture.git("update-index", "--chmod=+x", "tools/run.sh")
    try fixture.commit("first")
    let first = try fixture.git("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)

    try fixture.writeFile("src/lib.rs", "pub fn one() -> u8 { 2 }\n")
    try fixture.writeFile("src/new/deep.rs", "pub fn deep() {}\n")
    try fixture.git("rm", "-q", "src/old.rs", "link.rs")
    try fixture.git("add", "-A")
    try fixture.git("update-index", "--add", "--cacheinfo", "160000,\(first),vendor/dep")
    try fixture.commit("second")
    let second = try fixture.git("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
    return (fixture, first, second)
}

@Test
func checkoutRootMirrorsEachCommitsRegularFilesWithoutTouchingTheUserRepository() throws {
    let (fixture, first, second) = try makeTwoCommitFixture()
    defer { fixture.remove() }
    let store = CheckoutStore(parentURL: checkoutParent(beside: fixture))
    defer { try? store.removeAll() }
    let before = try gitDirectoryState(fixture.root)
    let statusBefore = try fixture.git("status", "--porcelain")

    let owner = UUID()
    let root = try store.root(owner: owner, source: fixture.root)
    #expect(root.url == store.directory(for: owner))
    #expect(!FileManager.default.fileExists(
        atPath: fixture.root.appendingPathComponent(".git/objects/info/alternates").path
    ))

    for commit in [first, second, first] {
        let snapshot = try CommitSnapshot(repositoryURL: fixture.root, revision: commit)
        try root.checkout(commit: snapshot.commitOID)
        #expect(try filesOnDisk(root.url) == expectedFiles(snapshot), "commit \(commit.prefix(7))")
        #expect(!FileManager.default.fileExists(atPath: root.url.appendingPathComponent("vendor").path))
        #expect(!FileManager.default.fileExists(atPath: root.url.appendingPathComponent("link.rs").path))
    }
    let runPermissions = try FileManager.default.attributesOfItem(
        atPath: root.url.appendingPathComponent("tools/run.sh").path
    )[.posixPermissions] as? Int
    #expect((runPermissions ?? 0) & 0o100 != 0, "100755 keeps its executable bit")

    // The user repository saw no write: HEAD, index and every other file
    // under .git are byte-identical, and nothing was added.
    #expect(try gitDirectoryState(fixture.root) == before)
    #expect(try fixture.git("status", "--porcelain") == statusBefore)
    #expect(store.liveDirectoryCount == 1)
    #expect(store.totalSize() > 0)
}

@Test
func checkoutRootKeepsUntrackedSymlinksAndDoesNotConvertLineEndings() throws {
    let fixture = try GitFixture()
    defer { fixture.remove() }
    try fixture.writeFile(".gitattributes", "*.txt text eol=crlf\n*.rs ident\n")
    try fixture.writeFile("notes.txt", "one\ntwo\n")
    try fixture.writeFile("src/lib.rs", "// $Id$\npub fn f() {}\n")
    try fixture.git("add", "-A")
    try fixture.commit("attributes")
    try fixture.writeFile("src/lib.rs", "// $Id$\npub fn f() { }\n")
    try fixture.git("add", "-A")
    try fixture.commit("second")
    let store = CheckoutStore(parentURL: checkoutParent(beside: fixture))
    defer { try? store.removeAll() }
    let root = try store.root(owner: UUID(), source: fixture.root)

    let previous = try CommitSnapshot(repositoryURL: fixture.root, revision: "HEAD~1")
    try root.checkout(commit: previous.commitOID)
    // A link somebody (S3's dependency borrowing) placed beside the sources
    // survives the next checkout, as do its untracked neighbours.
    try FileManager.default.createSymbolicLink(
        atPath: root.url.appendingPathComponent("node_modules").path,
        withDestinationPath: fixture.root.path
    )
    let head = try CommitSnapshot(repositoryURL: fixture.root)
    try root.checkout(commit: head.commitOID)

    #expect(try FileManager.default.destinationOfSymbolicLink(
        atPath: root.url.appendingPathComponent("node_modules").path
    ) == fixture.root.path)
    #expect(try Data(contentsOf: root.url.appendingPathComponent("notes.txt"))
        == Data("one\ntwo\n".utf8), "eol=crlf must not rewrite the blob bytes")
    #expect(try Array(Data(contentsOf: root.url.appendingPathComponent("src/lib.rs")))
        == head.readBytes(path: "src/lib.rs"), "ident must not expand $Id$")
}

@Test
func checkoutRootReportsAMovedSourceRepository() throws {
    let fixture = try GitFixture()
    defer { fixture.remove() }
    try fixture.writeFile("main.rs", "fn main() {}\n")
    try fixture.git("add", "-A")
    try fixture.commit("base")
    let parent = fixture.root.deletingLastPathComponent()
    let moved = parent.appendingPathComponent("moved-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: moved) }
    let checkouts = parent.appendingPathComponent("checkouts-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: checkouts) }
    let store = CheckoutStore(parentURL: checkouts)
    let root = try store.root(owner: UUID(), source: fixture.root)
    let head = try CommitSnapshot(repositoryURL: fixture.root)
    try root.checkout(commit: head.commitOID)

    try FileManager.default.moveItem(at: fixture.root, to: moved)
    defer { try? FileManager.default.moveItem(at: moved, to: fixture.root) }

    let objects = fixture.root.appendingPathComponent(".git/objects").path
    #expect(throws: CheckoutError.sourceObjectsUnavailable(objects)) {
        try root.checkout(commit: head.commitOID)
    }
}

@Test
func twoCheckoutRootsOnOneRepositoryDoNotInterfere() throws {
    let (fixture, first, second) = try makeTwoCommitFixture()
    defer { fixture.remove() }
    let store = CheckoutStore(parentURL: checkoutParent(beside: fixture))
    defer { try? store.removeAll() }
    let owners = (UUID(), UUID())
    let a = try store.root(owner: owners.0, source: fixture.root)
    let b = try store.root(owner: owners.1, source: fixture.root)
    #expect(a.url != b.url)
    let firstSnapshot = try CommitSnapshot(repositoryURL: fixture.root, revision: first)
    let secondSnapshot = try CommitSnapshot(repositoryURL: fixture.root, revision: second)

    try a.checkout(commit: firstSnapshot.commitOID)
    try b.checkout(commit: secondSnapshot.commitOID)
    #expect(try filesOnDisk(a.url) == expectedFiles(firstSnapshot))
    #expect(try filesOnDisk(b.url) == expectedFiles(secondSnapshot))

    // Releasing one window leaves the other's directory in place; a clear
    // is refused until the last owner is gone.
    try store.release(owner: owners.0)
    #expect(!FileManager.default.fileExists(atPath: a.url.path))
    #expect(try filesOnDisk(b.url) == expectedFiles(secondSnapshot))
    #expect(throws: CheckoutError.directoriesInUse([b.url.path])) { try store.removeAll() }
    try store.release(owner: owners.1)
    try store.release(owner: owners.1)
    try store.removeAll()
    #expect(!FileManager.default.fileExists(atPath: store.parentURL.path))
}

@Test
func checkoutStoreLaunchCleanupRemovesOnlyUnownedDirectories() throws {
    let fixture = try GitFixture()
    defer { fixture.remove() }
    try fixture.writeFile("main.rs", "fn main() {}\n")
    try fixture.git("add", "-A")
    try fixture.commit("base")
    let store = CheckoutStore(parentURL: checkoutParent(beside: fixture))
    defer { try? store.removeAll() }
    let stale = store.directory(for: UUID())
    try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
    try Data("left behind".utf8).write(to: stale.appendingPathComponent("main.rs"))
    let owner = UUID()
    let live = try store.root(owner: owner, source: fixture.root)
    try live.checkout(commit: try CommitSnapshot(repositoryURL: fixture.root).commitOID)

    store.removeUnowned()

    #expect(!FileManager.default.fileExists(atPath: stale.path))
    #expect(FileManager.default.fileExists(atPath: live.url.appendingPathComponent("main.rs").path))
    try store.release(owner: owner)
}

/// A checkout parent beside (not inside) the repository, so it never shows
/// up as an untracked path of the fixture.
private func checkoutParent(beside fixture: GitFixture) -> URL {
    fixture.root.deletingLastPathComponent()
        .appendingPathComponent("checkouts-\(fixture.root.lastPathComponent)", isDirectory: true)
}

private extension GitFixture {
    func writeFile(_ path: String, _ contents: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }
}
