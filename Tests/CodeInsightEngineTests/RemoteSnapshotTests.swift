import CodeInsightCore
@testable import CodeInsightEngine
import CodeInsightGit
import Darwin
import Foundation
import Testing

/// Runs the remote command the way ssh does: every argument joined with
/// spaces and handed to the login shell (zsh, as on the target host), so a
/// quoting mistake in the bootstrap shows up here.
private let sshLikePrefix = ["/bin/sh", "-c", "exec /bin/zsh -c \"$*\"", "ssh"]

private func transport(
    _ root: URL,
    shell: Bool = false,
    gzip: Bool = false,
    prefix: [String] = sshLikePrefix,
    timeout: TimeInterval = 30
) throws -> SSHTransport {
    try SSHTransport(
        remotePath: root.path,
        commandPrefix: prefix,
        timeout: timeout,
        forceShellScripts: shell,
        forceGzip: gzip
    )
}

private func zstdOnPath() -> URL? {
    (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        .map { URL(fileURLWithPath: String($0)).appendingPathComponent("zstd") }
        .first { FileManager.default.isExecutableFile(atPath: $0.path) }
}

private final class Fixture {
    let root: URL
    private var locked: [URL] = []

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        for url in locked { chmod(url.path, 0o755) }
        try? FileManager.default.removeItem(at: root)
    }

    func write(_ path: String, _ bytes: [UInt8]) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: url)
    }

    func write(_ path: String, _ text: String) throws { try write(path, Array(text.utf8)) }

    func directory(_ path: String) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
    }

    func lock(_ path: String) {
        let url = root.appendingPathComponent(path)
        chmod(url.path, 0)
        locked.append(url)
    }

    func url(_ path: String) -> URL { root.appendingPathComponent(path) }
}

private let tricky = ProjectPathRules(lines: ["secret/", "*.log", "!node_modules/"])

/// Spaces, quotes, `$`, non-ASCII, symlinks (to a file, a folder, nowhere),
/// a hard link, a FIFO, unreadable files and folders, empty files and
/// folders, an LFS pointer outside the sources, `.DS_Store`, a nested `.git`
/// file, built-in and rule exclusions, a restored default skip, and paths
/// over 100 and over 255 bytes.
private func trickyTree() throws -> Fixture {
    let fixture = try Fixture()
    try fixture.write("src/main.rs", "fn main() {}\n")
    try fixture.write("src/lib with space.rs", "pub fn a() {}\n")
    try fixture.write("src/quote'd \"x\".py", "x = 1\n")
    try fixture.write("src/$HOME and `cmd` $(x).ts", "export const a = 1\n")
    try fixture.write("src/中文 名字.go", "package main\n")
    try fixture.write("src/back\\slash -dash.py", "y = 2\n")
    try fixture.write("-leading.rs", "fn x() {}\n")
    try fixture.write("Cargo.toml", "[package]\nname = \"a\"\n")
    try fixture.write("package.json", "{}\n")
    try fixture.write("sub/go.mod", "module x\n")
    try fixture.write("sub/.git", "gitdir: ../.git/worktrees/sub\n")
    try fixture.write(".git/config", "[core]\n")
    try fixture.write(".DS_Store", [0, 1, 2])
    var generator = SeededGenerator(state: 7)
    try fixture.write("assets/logo.png", (0..<5000).map { _ in UInt8.random(in: 0...255, using: &generator) })
    try fixture.write("assets/model.bin", "version https://git-lfs.github.com/spec/v1\noid sha256:abc\nsize 3\n")
    try fixture.write("src/pointer.rs", "version https://git-lfs.github.com/spec/v1\n")
    try fixture.write("empty.txt", "")
    try fixture.write("src/empty.py", "")
    try fixture.write("node_modules/pkg/index.ts", "export {}\n")
    try fixture.write("vendor/lib.go", "package vendor\n")
    try fixture.write("target/out.rs", "fn built() {}\n")
    try fixture.write("secret/key.ts", "const k = 1\n")
    try fixture.write("debug.log", "log\n")
    try fixture.directory("emptydir/inner")
    try FileManager.default.createSymbolicLink(atPath: fixture.url("link.rs").path, withDestinationPath: "src/main.rs")
    try FileManager.default.createSymbolicLink(atPath: fixture.url("dangling.rs").path, withDestinationPath: "missing.rs")
    try FileManager.default.createSymbolicLink(atPath: fixture.url("linkdir").path, withDestinationPath: "src")
    try FileManager.default.linkItem(at: fixture.url("src/main.rs"), to: fixture.url("src/hard.rs"))
    #expect(mkfifo(fixture.url("pipe.rs").path, 0o644) == 0)
    try fixture.write("locked/inside.rs", "fn hidden() {}\n")
    fixture.lock("locked")
    try fixture.write("src/locked.rs", "fn no() {}\n")
    fixture.lock("src/locked.rs")
    try fixture.write("assets/locked.png", [1, 2, 3])
    fixture.lock("assets/locked.png")
    let mid = "mid/" + String(repeating: "m", count: 60) + "/" + String(repeating: "n", count: 50) + ".py"
    try fixture.write(mid, "z = 3\n")
    let deep = "deep/" + (0..<4).map { String(repeating: Character(String($0)), count: 80) }.joined(separator: "/")
    try fixture.write(deep + "/file_long_名前.ts", "export const deep = 1\n")
    try fixture.write(deep + "/image.png", [9, 9, 9])
    return fixture
}

private func manifest(_ snapshot: any Snapshot) -> [String] {
    snapshot.listFiles().map { "\($0.path) \($0.contentID.bytes) \($0.fileMode)" }
}

private func expectSame(_ remote: RemoteSnapshot, _ local: WorktreeSnapshot) throws {
    #expect(manifest(remote) == manifest(local))
    #expect(remote.ruleExcludedPaths == local.ruleExcludedPaths)
    #expect(remote.unreadablePaths == local.unreadablePaths)
    #expect(remote.configurationPaths == local.configurationPaths)
    #expect(remote.languages == local.languages)
    #expect(remote.projectRootName == local.projectRootName)
    for file in local.listFiles() {
        #expect(try remote.fileSize(path: file.path) == local.fileSize(path: file.path))
        #expect(try remote.readBytes(path: file.path) == local.readBytes(path: file.path))
    }
}

@Test(arguments: [(false, false), (true, false), (false, true)])
func remoteSnapshotOfATrickyTreeEqualsTheWorktreeSnapshot(shell: Bool, gzip: Bool) throws {
    let fixture = try trickyTree()
    let local = try WorktreeSnapshot(repositoryURL: fixture.root, pathRules: tricky)
    let cache = SourceByteCache(budgetBytes: 1 << 24)
    let link = try transport(fixture.root, shell: shell, gzip: gzip)
    defer { link.close() }
    let remote = try RemoteSnapshot(transport: link, pathRules: tricky, sourceBytes: cache)
    try expectSame(remote, local)

    // The fixture exercises what it claims to.
    let paths = Set(local.listFiles().map(\.path))
    #expect(paths.contains { $0.utf8.count > 255 })
    #expect(paths.contains { $0.utf8.count > 100 && $0.utf8.count < 255 })
    #expect(paths.contains("node_modules/pkg/index.ts"))
    #expect(local.listFiles().contains { $0.path == "assets/model.bin" && $0.fileMode == .lfsPointer })
    #expect(local.unreadablePaths == ["assets/locked.png", "locked", "src/locked.rs"])
    #expect(local.ruleExcludedPaths == ["debug.log", "secret"])

    // Every source and configuration file came back in the capture stream.
    let sources = local.listFiles().filter {
        LanguageMode.classify(path: $0.path) != nil || local.configurationPaths.contains($0.path)
    }
    #expect(sources.count > 10)
    #expect(Set(sources.map(\.contentID)).isSubset(of: cache.contentIDs))
    #expect(!cache.contentIDs.contains(local.listFiles().first { $0.path == "assets/logo.png" }!.contentID))
    let expected = gzip || zstdOnPath() == nil ? "gzip" : "zstd"
    #expect(link.lastCaptureFormat == expected)
}

/// Fixed seeds; each tree mixes sources, other files, default-skipped and
/// awkward names. After capture, a changed or deleted file reads as
/// `changedSinceCapture`, an untouched one still reads.
@Test(arguments: 1...6)
func remoteSnapshotMatchesLocalOnGeneratedTreesAndDetectsChanges(seed: UInt64) throws {
    var generator = SeededGenerator(state: seed)
    let fixture = try Fixture()
    let names = ["a", "b c", "d'e", "f$g", "é", "名", "node_modules", "build", "h-i", "x\"y"]
    let extensions = [".rs", ".py", ".ts", ".go", ".txt", ".png", ".json", ""]
    var written: [String] = []
    for _ in 0..<40 {
        let depth = Int.random(in: 0...3, using: &generator)
        let directories = (0..<depth).map { _ in names.randomElement(using: &generator)! }
        let name = names.randomElement(using: &generator)! + "_\(written.count)"
            + extensions.randomElement(using: &generator)!
        let path = (directories + [name]).joined(separator: "/")
        let size = Int.random(in: 0...3000, using: &generator)
        try fixture.write(path, (0..<size).map { _ in UInt8.random(in: 0...255, using: &generator) })
        written.append(path)
    }
    let local = try WorktreeSnapshot(repositoryURL: fixture.root)
    let link = try transport(fixture.root)
    defer { link.close() }
    let remote = try RemoteSnapshot(transport: link)
    #expect(manifest(remote) == manifest(local))
    #expect(remote.unreadablePaths == local.unreadablePaths)

    let files = remote.listFiles().map(\.path)
    guard files.count >= 2 else { return }
    let changed = files.randomElement(using: &generator)!
    if Bool.random(using: &generator) {
        try FileManager.default.removeItem(at: fixture.url(changed))
    } else {
        let handle = try FileHandle(forWritingTo: fixture.url(changed))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x2A]))
        try handle.close()
    }
    #expect {
        try remote.readBytes(path: changed)
    } throws: { error in
        if case GitError.changedSinceCapture(changed) = error { return true }
        return false
    }
    let untouched = files.first { $0 != changed }!
    #expect(try remote.readBytes(path: untouched) == Array(Data(contentsOf: fixture.url(untouched))))
}

/// With a budget smaller than any file, the capture keeps nothing, and the
/// indexer's per-file path reads each source again over the loop.
@Test
func remoteSourcesStillReadWhenTheByteCacheIsTooSmall() throws {
    let fixture = try trickyTree()
    let cache = SourceByteCache(budgetBytes: 8)
    let link = try transport(fixture.root)
    defer { link.close() }
    let remote = try RemoteSnapshot(transport: link, pathRules: tricky, sourceBytes: cache)
    let reader = SourceReader.reading(remote)
    var read = 0
    for file in remote.listFiles() where LanguageMode.classify(path: file.path) != nil {
        let bytes = try reader.bytes(for: file.contentID, path: file.path, in: cache)
        #expect(bytes == Array(try Data(contentsOf: fixture.url(file.path))))
        read += 1
    }
    #expect(read > 10)
    #expect(cache.usedBytes <= 8)
}

/// A killed read loop is a lost connection, never empty content, until the
/// transport connects again.
@Test
func killedReadLoopReadsAsDisconnectedUntilReconnect() throws {
    let fixture = try Fixture()
    try fixture.write("a.png", [1, 2, 3])
    let link = try transport(fixture.root)
    defer { link.close() }
    let remote = try RemoteSnapshot(transport: link)
    let pid = try #require(link.loopProcessIdentifier)
    kill(-pid, SIGKILL)
    for _ in 0..<2 {
        #expect {
            try remote.readBytes(path: "a.png")
        } throws: { error in
            (error as? SSHTransport.Failure)?.isConnectionLoss == true
        }
    }
    #expect(!link.isConnected)
    try link.connect()
    #expect(try remote.readBytes(path: "a.png") == [1, 2, 3])
}

/// A source the byte cache no longer holds is read again over the loop; with
/// the loop gone that is the lost link, not an unavailable (unindexed) file.
@Test
func evictedSourceOverALostLinkFailsAsDisconnected() throws {
    let fixture = try Fixture()
    try fixture.write("main.rs", "fn main() {}\n")
    let link = try transport(fixture.root)
    defer { link.close() }
    let lost = LockedFlag()
    link.onConnectionLoss = { _ in lost.set() }
    let remote = try RemoteSnapshot(transport: link, sourceBytes: SourceByteCache(budgetBytes: 0))
    let file = try #require(remote.listFiles().first)
    kill(-(try #require(link.loopProcessIdentifier)), SIGKILL)
    #expect {
        try SourceReader.reading(remote).bytes(for: file.contentID, path: file.path, in: SourceByteCache(budgetBytes: 0))
    } throws: { error in
        (error as? SSHTransport.Failure)?.isConnectionLoss == true
    }
    #expect(lost.value)
}

/// A recapture given the previous one takes again only files whose size or
/// mtime changed, and a source only while the cache still has its bytes; the
/// manifest is the same as a fresh capture's.
@Test(arguments: [false, true])
func recaptureTakesOnlyChangedFiles(shell: Bool) throws {
    let fixture = try Fixture()
    try fixture.write("a.rs", "fn a() {}\n")
    try fixture.write("b.rs", "fn b() {}\n")
    try fixture.write("c.png", [1, 2, 3])
    try fixture.write("d.png", [4, 5, 6])
    let cache = SourceByteCache(budgetBytes: 1 << 24)
    let link = try transport(fixture.root, shell: shell)
    defer { link.close() }
    let first = try RemoteSnapshot(transport: link, sourceBytes: cache)
    #expect(Set(link.lastCapturedPaths) == ["a.rs", "b.rs"])
    #expect(Set(link.lastHashedPaths) == ["c.png", "d.png"])

    try fixture.write("b.rs", "fn b() { changed() }\n")
    try fixture.write("d.png", [4, 5, 6, 7])
    try fixture.write("e.rs", "fn e() {}\n")
    let second = try RemoteSnapshot(transport: link, sourceBytes: cache, previous: first)
    #expect(link.lastCapturedPaths.sorted() == ["b.rs", "e.rs"])
    #expect(link.lastHashedPaths == ["d.png"])
    #expect(manifest(second) == manifest(try WorktreeSnapshot(repositoryURL: fixture.root)))

    let empty = SourceByteCache(budgetBytes: 0)
    let third = try RemoteSnapshot(transport: link, sourceBytes: empty, previous: second)
    #expect(link.lastCapturedPaths.sorted() == ["a.rs", "b.rs", "e.rs"])
    #expect(link.lastHashedPaths.isEmpty)
    #expect(manifest(third) == manifest(second))
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    func set() { lock.withLock { raised = true } }
    var value: Bool { lock.withLock { raised } }
}

/// A remote side that never answers times out; a cancelled task stops the
/// wait. Both end the child process instead of waiting it out.
@Test
func silentRemoteTimesOutAndCancellationStopsTheWait() async throws {
    let fixture = try Fixture()
    let silent = ["/bin/sh", "-c", "sleep 30", "ssh"]
    let started = Date()
    let slow = try transport(fixture.root, prefix: silent, timeout: 0.5)
    #expect {
        try slow.connect()
    } throws: { error in
        if case SSHTransport.Failure.timedOut = error { return true }
        return false
    }
    #expect(Date().timeIntervalSince(started) < 5)

    let patient = try transport(fixture.root, prefix: silent, timeout: 60)
    let task = Task.detached { try patient.connect() }
    try await Task.sleep(nanoseconds: 300_000_000)
    let cancelled = Date()
    task.cancel()
    let result = await task.result
    #expect(throws: CancellationError.self) { try result.get() }
    #expect(Date().timeIntervalSince(cancelled) < 5)
}

/// `zstd --long=27` output (the remote default) decodes here, fed in pieces.
@Test
func longWindowZstdStreamDecodes() throws {
    guard let zstd = zstdOnPath() else {
        // ponytail: no zstd on this machine; nothing to produce the input.
        print("SKIP longWindowZstdStreamDecodes: no zstd on PATH")
        return
    }
    var generator = SeededGenerator(state: 27)
    let block = (0..<300_000).map { _ in UInt8.random(in: 0...255, using: &generator) }
    // Repeats far apart only a long window finds.
    let input = block + (0..<2_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) } + block
    let process = Process()
    process.executableURL = zstd
    process.arguments = ["-3", "--long=27", "-c", "-q"]
    let stdin = Pipe(), stdout = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    try process.run()
    let writer = Thread {
        stdin.fileHandleForWriting.write(Data(input))
        try? stdin.fileHandleForWriting.close()
    }
    writer.start()
    let compressed = [UInt8](stdout.fileHandleForReading.readDataToEndOfFile())
    process.waitUntilExit()
    #expect(compressed.count < input.count / 2)
    let decoder = try Decoder(magic: compressed)
    var output: [UInt8] = []
    var offset = 0
    while offset < compressed.count {
        let end = min(offset + 7_000, compressed.count)
        output += try decoder.decode(Array(compressed[offset..<end]))
        offset = end
    }
    #expect(decoder.format == "zstd")
    #expect(decoder.finished)
    #expect(output == input)
}

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state ^ (state >> 29)
    }
}

/// A real ssh host, only when `CAIRN_SSH_TEST_TARGET=host:/absolute/path`
/// is set (never by default): the three script paths agree on the same
/// directory, a hashed-only file reads back, and closing removes the control
/// socket. The remote side is only read.
@Test
func realHostCapturesAgreeAcrossScriptPaths() throws {
    guard let target = ProcessInfo.processInfo.environment["CAIRN_SSH_TEST_TARGET"],
          let colon = target.firstIndex(of: ":")
    else {
        print("SKIP realHostCapturesAgreeAcrossScriptPaths: CAIRN_SSH_TEST_TARGET not set")
        return
    }
    let host = String(target[..<colon]), path = String(target[target.index(after: colon)...])
    var manifests: [[String]] = []
    for (shell, gzip) in [(false, false), (true, false), (false, true)] {
        let probe = try SSHTransport(host: host, remotePath: path)
        // The same prefix and control socket the public initializer built.
        let link = try SSHTransport(
            host: host, remotePath: path, commandPrefix: probe.commandPrefixForTests,
            controlPath: probe.controlPathForTests, forceShellScripts: shell, forceGzip: gzip
        )
        let started = Date()
        let cache = SourceByteCache()
        let snapshot = try RemoteSnapshot(transport: link, sourceBytes: cache)
        print("real host shell=\(shell) gzip=\(gzip): \(snapshot.listFiles().count) files in "
            + "\(String(format: "%.2f", Date().timeIntervalSince(started))) s, \(link.lastCaptureFormat ?? "-")")
        manifests.append(manifest(snapshot))
        if let other = snapshot.listFiles().first(where: { LanguageMode.classify(path: $0.path) == nil }) {
            #expect(try snapshot.readBytes(path: other.path).count == Int(snapshot.fileSize(path: other.path)))
        }
        #expect(link.lastCaptureFormat == (gzip ? "gzip" : "zstd"))
        // Nothing changed: the recapture takes and hashes nothing again
        // (the mtime tokens of GNU stat and of Python agree with themselves).
        let again = try RemoteSnapshot(transport: link, sourceBytes: cache, previous: snapshot)
        #expect(link.lastCapturedPaths.isEmpty)
        #expect(link.lastHashedPaths.isEmpty)
        #expect(manifest(again) == manifest(snapshot))
        link.close()
        #expect(access(link.controlPathForTests!, F_OK) != 0)
    }
    #expect(throws: SSHTransport.Failure.invalidTarget("host -oProxyCommand=x")) {
        try SSHTransport(host: "-oProxyCommand=x", remotePath: path)
    }
    let nowhere = try SSHTransport(host: "cairn-no-such-host.invalid", remotePath: path, timeout: 15)
    #expect {
        try nowhere.connect()
    } throws: { error in
        guard case let SSHTransport.Failure.connectFailed(message, command) = error else { return false }
        print("unreachable host: \(message) | \(command)")
        return command.contains("cairn-no-such-host.invalid")
    }
    #expect(manifests[0].count > 0)
    #expect(manifests[0] == manifests[1])
    #expect(manifests[0] == manifests[2])
}
