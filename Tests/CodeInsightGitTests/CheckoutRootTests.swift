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

    // Checking the same commit out twice in a row covers FORCE recreating
    // the symlink and gitlink entries the previous cleanup removed.
    for commit in [first, second, second, first] {
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

    // A window that opens another repository keeps its owner id: the old
    // root (and its lock) must go before the replacement is built in the
    // same directory.
    let other = try GitFixture()
    defer { other.remove() }
    try other.writeFile("main.rs", "fn main() {}\n")
    try other.git("add", "main.rs")
    try other.commit("init")
    let replacement = try store.root(owner: owners.0, source: other.root)
    #expect(replacement !== a)
    #expect(replacement.url == a.url)
    try replacement.checkout(commit: CommitSnapshot(repositoryURL: other.root, revision: "HEAD").commitOID)
    #expect(try filesOnDisk(replacement.url).keys.sorted() == ["main.rs"])
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
    // A second store over the same parent (another Cairn process) sees the
    // live directory as held and leaves it alone, in both cleanup paths.
    let otherProcess = CheckoutStore(parentURL: store.parentURL)
    otherProcess.removeUnowned()
    #expect(FileManager.default.fileExists(atPath: live.url.appendingPathComponent("main.rs").path))
    #expect(throws: CheckoutError.directoriesInUse([live.url.path])) { try otherProcess.removeAll() }
    try store.release(owner: owner)
    try otherProcess.removeAll()
}

@Test
func checkoutRootRecomputesBorrowedLinksAndNeverWritesThroughThem() throws {
    let fixture = try GitFixture()
    defer { fixture.remove() }
    try fixture.writeFile("app/package.json", "{}\n")
    try fixture.writeFile("web/package.json", "{}\n")
    try fixture.git("add", "-A")
    try fixture.commit("two packages")
    let first = try CommitSnapshot(repositoryURL: fixture.root)
    // The next commit drops `web` and starts tracking a file inside
    // `app/node_modules`, so that link must go before the checkout.
    try fixture.git("rm", "-q", "-r", "web")
    try fixture.writeFile("app/node_modules/vendored.js", "// tracked\n")
    try fixture.git("add", "-f", "app/node_modules/vendored.js")
    try fixture.commit("vendored")
    let second = try CommitSnapshot(repositoryURL: fixture.root)

    // Workspace dependency directories live outside the checkout.
    let workspace = fixture.root.deletingLastPathComponent()
        .appendingPathComponent("deps-\(fixture.root.lastPathComponent)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: workspace) }
    let appModules = workspace.appendingPathComponent("app/node_modules", isDirectory: true)
    let webModules = workspace.appendingPathComponent("web/node_modules", isDirectory: true)
    let rootModules = workspace.appendingPathComponent("node_modules", isDirectory: true)
    for directory in [appModules, webModules, rootModules] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("dependency\n".utf8).write(to: directory.appendingPathComponent("index.js"))
    }
    let links = [
        "node_modules": rootModules,
        "app/node_modules": appModules,
        "web/node_modules": webModules,
        "missing/node_modules": rootModules,
    ]

    let store = CheckoutStore(parentURL: checkoutParent(beside: fixture))
    defer { try? store.removeAll() }
    let owner = UUID()
    let root = try store.root(owner: owner, source: fixture.root)
    func linkTarget(_ path: String) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(
            atPath: root.url.appendingPathComponent(path).path
        )
    }

    try root.checkout(commit: first.commitOID, links: links)
    #expect(root.borrowedLinks == [
        "node_modules": rootModules,
        "app/node_modules": appModules,
        "web/node_modules": webModules,
    ], "a link whose parent directory the commit lacks is not created")
    #expect(linkTarget("app/node_modules") == appModules.path)
    #expect(!FileManager.default.fileExists(atPath: root.url.appendingPathComponent("missing").path))

    try root.checkout(commit: second.commitOID, links: links)
    #expect(root.borrowedLinks == ["node_modules": rootModules])
    #expect(linkTarget("app/node_modules") == nil, "tracked content wins over the link")
    #expect(try Data(contentsOf: root.url.appendingPathComponent("app/node_modules/vendored.js"))
        == Data("// tracked\n".utf8))
    #expect(!FileManager.default.fileExists(atPath: root.url.appendingPathComponent("web").path),
            "the removed link's emptied parent goes too")
    // Nothing reached the workspace through a link.
    #expect(!FileManager.default.fileExists(atPath: appModules.appendingPathComponent("vendored.js").path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: appModules.path) == ["index.js"])

    // A different target for a kept path replaces the link; an empty set
    // removes the rest.
    try root.checkout(commit: first.commitOID, links: ["node_modules": webModules])
    #expect(root.borrowedLinks == ["node_modules": webModules])
    #expect(linkTarget("node_modules") == webModules.path)
    #expect(linkTarget("app/node_modules") == nil)
    try root.checkout(commit: first.commitOID)
    #expect(root.borrowedLinks.isEmpty)
    #expect(linkTarget("node_modules") == nil)

    // Deleting the checkout removes links, never the workspace directories.
    try root.checkout(commit: first.commitOID, links: links)
    try store.release(owner: owner)
    for directory in [appModules, webModules, rootModules] {
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("index.js").path))
    }
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
