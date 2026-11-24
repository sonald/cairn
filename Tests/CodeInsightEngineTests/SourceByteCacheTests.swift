import CodeInsightCore
@testable import CodeInsightEngine
import CodeInsightGit
import Foundation
import Testing

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state ^ (state >> 29)
    }
}

private struct ReadFailure: Error {}

/// Seeded random gets over a pool larger than a tiny budget: the cache never
/// holds more than the budget, every get returns the reference bytes (an
/// evicted entry reloads byte-identical), and a miss whose reader fails or
/// returns other bytes is an error, after which the entry is still absent.
@Test(arguments: [0x5EED as UInt64, 0xCAFE, 0xBEEF])
func sourceByteCacheStaysWithinItsBudgetAndReloadsOnlyIdenticalBytes(seed: UInt64) throws {
    var random = SeededGenerator(state: seed)
    let budget = 4096
    let pool: [(ContentID, [UInt8])] = (0..<48).map { index in
        // Sizes cover empty, small, and larger than the whole budget.
        let count = index == 0 ? 0 : index == 1 ? budget + 1 : Int.random(in: 1...1500, using: &random)
        let bytes = (0..<count).map { _ in UInt8.random(in: 0...255, using: &random) }
        return (ContentID.sha256(of: bytes), bytes)
    }
    let cache = SourceByteCache(budgetBytes: budget)
    var reads = 0
    for step in 0..<4000 {
        let (id, bytes) = pool[Int.random(in: 0..<pool.count, using: &random)]
        switch Int.random(in: 0..<10, using: &random) {
        case 0 where cache.cachedBytes(id) == nil:
            #expect(throws: SourceByteCache.Unavailable.self, "step \(step)") {
                try cache.bytes(for: id) { bytes + [0] }
            }
            #expect(cache.cachedBytes(id) == nil)
        case 1 where cache.cachedBytes(id) == nil:
            #expect(throws: SourceByteCache.Unavailable.self, "step \(step)") {
                try cache.bytes(for: id) { throw ReadFailure() }
            }
            #expect(cache.cachedBytes(id) == nil)
        default:
            let got = try cache.bytes(for: id) {
                reads += 1
                return bytes
            }
            #expect(got == bytes, "step \(step)")
        }
        #expect(cache.usedBytes <= budget, "step \(step)")
        #expect(cache.usedBytes == cache.byteCount(of: cache.contentIDs))
    }
    // The pool does not fit, so entries were evicted and read again.
    #expect(reads > pool.count)
}

/// A repository with several commits whose sources exceed a small budget:
/// switching among them in one store answers searches, resolution and the
/// module map exactly as an unlimited budget does, while the cache stays
/// within its budget.
@Test
func commitSwitchesUnderASmallSourceBudgetAnswerLikeAnUnlimitedOne() async throws {
    let root = try temporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }
    var random = SeededGenerator(state: 0x51DE)
    var revisions: [String] = []
    for commit in 0..<6 {
        var main = "mod util;\n"
        for file in 0..<8 {
            // Each commit changes some files; padding makes them sizable.
            let version = (commit + file) % 3 == 0 ? commit : 0
            let name = "f\(file)_v\(version)"
            let padding = String(repeating: "// shared marker line \(file)\n", count: 60 + Int.random(in: 0...40, using: &random))
            try write(root, "src/util/m\(file).rs", "pub fn \(name)() -> u32 { \(file) }\n\(padding)")
            main += "fn call\(file)() { util::m\(file)::\(name)(); }\n"
        }
        try write(root, "src/util.rs", (0..<8).map { "pub mod m\($0);\n" }.joined())
        try write(root, "src/main.rs", main)
        try git(root, "add", "-A")
        try git(root, "-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-q", "-m", "c\(commit)")
        revisions.append(try git(root, "rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    let budget = 8 << 10
    let small = ProjectIndexStore(sourceBytes: SourceByteCache(budgetBytes: budget))
    let indexer = ProjectIndexer(parallelism: 2)
    var order = revisions + revisions.reversed()
    order.shuffle(using: &random)
    var totalSource = 0
    for revision in order {
        let snapshot = try CommitSnapshot(repositoryURL: root, revision: revision)
        let limited = try indexer.indexSnapshot(snapshot, into: small, language: .rust)
        let unlimited = try indexer.indexSnapshot(
            snapshot,
            into: ProjectIndexStore(sourceBytes: SourceByteCache(budgetBytes: Int.max)),
            language: .rust
        )
        totalSource = max(totalSource, try allSourceBytes(of: unlimited).values.reduce(0) { $0 + $1.count })
        #expect(try await answers(of: limited) == answers(of: unlimited), "\(revision)")
        #expect(small.sourceBytes.usedBytes <= budget)
    }
    #expect(totalSource > budget, "the fixture must not fit the budget")

    // The working tree (the last commit) answers alike under the budget,
    // in the same store and cache as the commits.
    let worktree = try WorktreeSnapshot(repositoryURL: root)
    let limitedWorktree = try indexer.indexSnapshot(worktree, into: small, language: .rust)
    let unlimitedWorktree = try indexer.indexSnapshot(
        worktree,
        into: ProjectIndexStore(sourceBytes: SourceByteCache(budgetBytes: Int.max)),
        language: .rust
    )
    #expect(try await answers(of: limitedWorktree) == answers(of: unlimitedWorktree))
    #expect(small.sourceBytes.usedBytes <= budget)
}

/// A worktree capture keeps no bytes: a file modified or deleted after
/// capture is unavailable through the session and truncated in search,
/// never read with its new content; an untouched file reads the same.
@Test
func aWorktreeFileChangedAfterCaptureIsUnavailableNotItsNewContent() async throws {
    let root = try temporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = [
        "src/lib.rs": "pub fn kept_marker() {}\n",
        "src/edited.rs": "pub fn edited_marker() {}\n",
        "src/gone.rs": "pub fn gone_marker() {}\n",
        "src/early.rs": "pub fn early_marker() {}\n",
    ]
    for (path, source) in files { try write(root, path, source) }
    let snapshot = try WorktreeSnapshot(repositoryURL: root)
    // Changed between capture and indexing: the open still succeeds and
    // lists the file, but does not index it.
    try write(root, "src/early.rs", "pub fn early_marker() { changed_marker() }\n")
    // A zero budget keeps nothing, so every read goes to the disk.
    let session = try ProjectIndexer(parallelism: 1).indexSnapshot(
        snapshot,
        into: ProjectIndexStore(sourceBytes: SourceByteCache(budgetBytes: 0)),
        language: .rust
    )
    try write(root, "src/edited.rs", "pub fn edited_marker() { changed_marker() }\n")
    try FileManager.default.removeItem(at: root.appendingPathComponent("src/gone.rs"))

    let id = { (path: String) in ContentID.sha256(of: Array(files[path]!.utf8)) }
    #expect(try session.sourceBytes(for: id("src/lib.rs")) == Array(files["src/lib.rs"]!.utf8))
    #expect(!session.contentIndexes.keys.contains { $0.contentID == id("src/early.rs") })
    #expect(session.manifest.files.contains { session.paths.resolve($0.pathID) == "src/early.rs" })
    for path in ["src/edited.rs", "src/gone.rs", "src/early.rs"] {
        #expect(throws: (any Error).self, "\(path)") { try snapshot.readBytes(path: path) }
        #expect(throws: SourceByteCache.Unavailable.self, "\(path)") { try session.sourceBytes(for: id(path)) }
        #expect(throws: SourceByteCache.Unavailable.self, "\(path)") {
            try session.capturedSource(atManifestPath: path)
        }
    }
    let context = QueryContext(snapshotID: session.snapshotID, analysisProfileID: session.analysisProfile.id, generation: 1)
    var hits: Set<String> = []
    var truncated: Set<String> = []
    for try await batch in try session.search(ProjectSearchQuery.parse("marker", isRegex: false), context: context) {
        hits.formUnion(batch.matchesByPath.filter { !$0.value.isEmpty }.keys.map(session.paths.resolve))
        truncated.formUnion(batch.truncatedPathIDs.map(session.paths.resolve))
    }
    #expect(hits == ["src/lib.rs"])
    #expect(truncated == ["src/edited.rs", "src/gone.rs", "src/early.rs"])
}

/// After capture, a commit's blob that the object database no longer has
/// is an error through every reader, never empty or other bytes.
@Test
func aBlobRemovedAfterCaptureIsUnavailableNotOtherContent() async throws {
    let root = try temporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = "pub fn kept() {}\npub fn lost_marker() {}\n"
    try write(root, "src/lib.rs", source)
    try write(root, "src/other.rs", "pub fn other_marker() {}\n")
    try git(root, "add", "-A")
    try git(root, "-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-q", "-m", "one")

    let snapshot = try CommitSnapshot(repositoryURL: root)
    // A zero budget keeps nothing, so every later read goes to the snapshot.
    let session = try ProjectIndexer(parallelism: 1).indexSnapshot(
        snapshot,
        into: ProjectIndexStore(sourceBytes: SourceByteCache(budgetBytes: 0)),
        language: .rust
    )
    let id = ContentID.sha256(of: Array(source.utf8))
    #expect(try session.sourceBytes(for: id) == Array(source.utf8))

    let oid = try git(root, "rev-parse", "HEAD:src/lib.rs").trimmingCharacters(in: .whitespacesAndNewlines)
    try FileManager.default.removeItem(at: root.appendingPathComponent(
        ".git/objects/\(oid.prefix(2))/\(oid.dropFirst(2))"
    ))

    #expect(throws: (any Error).self) { try snapshot.readBytes(path: "src/lib.rs") }
    #expect(throws: SourceByteCache.Unavailable.self) { try session.sourceBytes(for: id) }
    #expect(throws: SourceByteCache.Unavailable.self) {
        try session.capturedSource(atManifestPath: "src/lib.rs")
    }
    #expect(session.bytes(for: id) == nil)
    // Search reports the file as truncated instead of searching other bytes.
    let context = QueryContext(snapshotID: session.snapshotID, analysisProfileID: session.analysisProfile.id, generation: 1)
    var truncated: Set<String> = []
    for try await batch in try session.search(ProjectSearchQuery.parse("marker", isRegex: false), context: context) {
        truncated.formUnion(batch.truncatedPathIDs.map(session.paths.resolve))
    }
    #expect(truncated == ["src/lib.rs"])
    #expect(try session.sourceBytes(for: ContentID.sha256(of: Array("pub fn other_marker() {}\n".utf8))) != nil)
}

/// Search hits, resolution of every call, and module children, spelled by
/// path so two stores' interned IDs compare.
private func answers(of session: EngineSession) async throws -> [String] {
    let context = QueryContext(snapshotID: session.snapshotID, analysisProfileID: session.analysisProfile.id, generation: 1)
    var lines: [String] = []
    for try await batch in try session.search(ProjectSearchQuery.parse("marker", isRegex: false), context: context) {
        for (pathID, matches) in batch.matchesByPath {
            lines += matches.map { "search \(session.paths.resolve(pathID)) \($0.byteRange.lowerBound) \($0.lineText)" }
        }
        lines += batch.truncatedPathIDs.map { "truncated \(session.paths.resolve($0))" }
    }
    for (key, index) in session.contentIndexes {
        guard let file = session.manifest.files.first(where: { $0.contentID == key.contentID }) else { continue }
        for call in index.calls {
            for candidate in try session.resolve(file: file.pathID, offset: call.nameRange.lowerBound, context: context) {
                lines.append("resolve \(session.paths.resolve(file.pathID)) \(call.nameRange.lowerBound) -> "
                    + "\(session.paths.resolve(candidate.target.pathID)) \(candidate.target.localIndex)")
            }
        }
    }
    for (parent, children) in session.moduleChildren {
        for (name, child) in children {
            lines.append("module \(session.paths.resolve(parent)) \(session.names.resolve(name)) \(session.paths.resolve(child))")
        }
    }
    return lines.sorted()
}

private func temporaryRepository() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodeInsightSourceByteCache-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try git(root, "init", "-q")
    return root
}

private func write(_ root: URL, _ path: String, _ contents: String) throws {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try contents.write(to: url, atomically: true, encoding: .utf8)
}

@discardableResult
private func git(_ root: URL, _ arguments: String...) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.environment = hermeticGitEnvironment
    process.arguments = arguments
    process.currentDirectoryURL = root
    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw ReadFailure() }
    return String(decoding: data, as: UTF8.self)
}
