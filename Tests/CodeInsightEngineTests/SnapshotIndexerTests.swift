import CodeInsightCore
@testable import CodeInsightEngine
import CodeInsightGit
import CodeInsightRustExtractor
import Foundation
import Testing

private let snapshotIndexerRepositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

@Test
func snapshotIndexerReusesContentAndResolvesEachCommit() throws {
    let fixture = try SnapshotGitFixture()
    defer { fixture.remove() }

    let store = ProjectIndexStore()
    let indexer = ProjectIndexer(parallelism: 2)
    let newerSnapshot = try CommitSnapshot(repositoryURL: fixture.root)
    let newer = try indexer.indexSnapshot(newerSnapshot, into: store)
    let olderSnapshot = try CommitSnapshot(
        repositoryURL: fixture.root,
        revision: "HEAD~1"
    )
    let preparedOlder = try indexer.prepareSnapshot(olderSnapshot, into: store)

    #expect(preparedOlder.pendingExtractionCount == 1)
    #expect(preparedOlder.cachedSession.stats.reusedCount == 1)
    #expect(preparedOlder.cachedSession.stats.extractedCount == 0)
    #expect(try preparedOlder.cachedSession.definitions(
        of: "shared",
        context: snapshotQueryContext(for: preparedOlder.cachedSession)
    ).count == 1)
    #expect(try preparedOlder.cachedSession.definitions(
        of: "a",
        context: snapshotQueryContext(for: preparedOlder.cachedSession)
    ).isEmpty)

    let older = try indexer.completeSnapshot(preparedOlder)
    #expect(newer.stats.reusedCount == 0)
    #expect(newer.stats.extractedCount == 2)
    #expect(older.stats.reusedCount == 1)
    #expect(older.stats.extractedCount == 1)
    #expect(try resolvedName("b", in: newer) == "b")
    #expect(try resolvedName("a", in: older) == "a")

    let package = try #require(older.manifest.files.first {
        older.paths.resolve($0.pathID) == "Package.swift"
    })
    #expect(package.detectedLanguage == nil)
    if case .tracked = package.sourceKind {} else {
        Issue.record("Commit snapshot files must be tracked")
    }
    #expect(!older.contentIndexes.keys.contains {
        $0.contentID == package.contentID
    })
    #expect(older.sourceBytesByContent[package.contentID] != nil)

    let repeated = try indexer.indexSnapshot(olderSnapshot, into: store)
    #expect(repeated.stats.reusedCount == 2)
    #expect(repeated.stats.extractedCount == 0)
    #expect(repeated.contentIndexes.count == older.contentIndexes.count)

    let worktree = try indexer.indexSnapshot(
        WorktreeSnapshot(repositoryURL: fixture.root),
        into: ProjectIndexStore()
    )
    #expect(worktree.manifest.files.allSatisfy {
        if case .untracked = $0.sourceKind { return true }
        return false
    })
}

@Test
func snapshotIndexingIsDeterministicForTheSameSequence() throws {
    let fixture = try SnapshotGitFixture()
    defer { fixture.remove() }

    let newer = try CommitSnapshot(repositoryURL: fixture.root)
    let older = try CommitSnapshot(repositoryURL: fixture.root, revision: "HEAD~1")

    func runSequence() throws -> String {
        let indexer = ProjectIndexer(parallelism: 4)
        let store = ProjectIndexStore()
        let first = try indexer.indexSnapshot(newer, into: store)
        let second = try indexer.indexSnapshot(older, into: store)
        return try [first, second].map(snapshotQueryDump).joined(separator: "\n---\n")
    }

    #expect(try runSequence() == runSequence())
}

@Test
func repositoryAdjacentCommitReuseExceedsEightyPercent() throws {
    let indexer = ProjectIndexer()
    let store = ProjectIndexStore()
    let head = try CommitSnapshot(repositoryURL: snapshotIndexerRepositoryRoot)
    _ = try indexer.indexSnapshot(head, into: store)

    let startedAt = Date()
    let previous = try CommitSnapshot(
        repositoryURL: snapshotIndexerRepositoryRoot,
        revision: "HEAD~1"
    )
    let session = try indexer.indexSnapshot(previous, into: store)
    let elapsed = Date().timeIntervalSince(startedAt) * 1_000
    let total = session.stats.reusedCount + session.stats.extractedCount
    let hitRate = total == 0 ? 0 : Double(session.stats.reusedCount) / Double(total)

    print(String(
        format: "S3 HEAD->HEAD~1 totalFiles=%d reusedCount=%d extractedCount=%d hitRate=%.1f%% switchMS=%.3f",
        total,
        session.stats.reusedCount,
        session.stats.extractedCount,
        hitRate * 100,
        elapsed
    ))
    #expect(hitRate > 0.8)
}

@Test
func snapshotIndexerCountsLFSPointerWithoutParsingItAsRust() throws {
    let fixture = try SnapshotGitFixture()
    defer { fixture.remove() }
    let pointer = Array("""
        version https://git-lfs.github.com/spec/v1
        oid sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
        size 123456

        """.utf8)
    try fixture.commitLFSPointer(pointer)

    let session = try ProjectIndexer().indexSnapshot(
        CommitSnapshot(repositoryURL: fixture.root),
        into: ProjectIndexStore()
    )
    let file = try #require(session.manifest.files.first {
        session.paths.resolve($0.pathID) == "src/large.rs"
    })

    #expect(file.fileMode == .lfsPointer)
    #expect(file.detectedLanguage == .rust)
    #expect(session.stats.fileCount == 3)
    #expect(session.stats.extractedCount == 2)
    #expect(session.sourceBytesByContent[file.contentID] == pointer)
    #expect(!session.contentIndexes.keys.contains { $0.contentID == file.contentID })
}

@Test
func persistentDraftRoundTripMatchesDirectExtractionFieldForField() throws {
    let fixture = try SnapshotGitFixture()
    defer { fixture.remove() }
    let cacheURL = temporaryCacheURL()
    defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }

    let direct = try ProjectIndexer(parallelism: 1).index(root: fixture.root)
    let cache = try IndexCache(fileURL: cacheURL)
    let writer = ProjectIndexer(
        parallelism: 2,
        cache: cache
    )
    let first = try writer.index(root: fixture.root)
    writer.flushPersistentWrites()
    let storedKey = try #require(first.contentIndexes.keys.first)
    let reloaded = try ProjectIndexer(
        parallelism: 2,
        cache: try IndexCache(fileURL: cacheURL)
    ).index(root: fixture.root)

    #expect(first.stats.extractedCount == 2)
    #expect(cache.payload(for: cacheKey(for: storedKey))?
        .starts(with: Data("CIDX".utf8)) == true)
    #expect(reloaded.stats.extractedCount == 0)
    #expect(reloaded.stats.reusedCount == 2)
    try expectEquivalentContent(direct, reloaded)
}

@Test
func extractorVersionBumpRemapsAndPersistsReceiverHintsAcrossFiles() throws {
    let fixture = snapshotIndexerRepositoryRoot.appendingPathComponent(
        "Tests/RustExtractorTests/Fixtures/receiver_type",
        isDirectory: true
    )
    let cacheURL = temporaryCacheURL()
    defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }

    var oldCache: IndexCache? = try IndexCache(
        fileURL: cacheURL,
        extractorVersion: 5
    )
    oldCache?.storeSynchronously([("v5-payload", Data([1, 2, 3]), 1)])
    oldCache?.flush()
    oldCache = nil

    let cache = try IndexCache(fileURL: cacheURL)
    #expect(cache.metadata.extractorVersion == RustExtractorInfo.extractorVersion)
    #expect(cache.payload(for: "v5-payload") == nil)
    let writer = ProjectIndexer(parallelism: 2, cache: cache)
    let first = try writer.index(root: fixture)
    writer.flushPersistentWrites()
    let reloaded = try ProjectIndexer(
        parallelism: 2,
        cache: try IndexCache(fileURL: cacheURL)
    ).index(root: fixture)

    #expect(first.stats.extractedCount == 2)
    #expect(reloaded.stats.extractedCount == 0)
    #expect(reloaded.stats.reusedCount == 2)
    try expectEquivalentContent(first, reloaded)

    let mainPath = try #require(reloaded.manifest.files.first {
        reloaded.paths.resolve($0.pathID) == "main.rs"
    }?.pathID)
    let mainIndex = try #require(reloaded.content(at: mainPath)?.1)
    let receiver = try #require(mainIndex.bindings.first {
        reloaded.names.resolve($0.localNameID) == "receiver"
            && $0.kind == .param
    })
    let targetHint = try #require(receiver.targetHint)
    #expect(reloaded.names.resolve(targetHint.nameID) == "T")
    #expect(targetHint.hintKind == .unqualified)

    let callOffset = try #require(mainIndex.lineTable.byteOffset(line: 5, column: 14))
    let candidate = try #require(try reloaded.resolve(
        file: mainPath,
        offset: callOffset,
        context: snapshotQueryContext(for: reloaded)
    ).first)
    #expect(candidate.certainty == .strong)
    #expect(reloaded.paths.resolve(candidate.target.pathID) == "a.rs")
    #expect(candidate.evidence.contains {
        if case let .receiverType(nameID) = $0 {
            return reloaded.names.resolve(nameID) == "T"
        }
        return false
    })
}

@Test
func corruptPersistentPayloadSilentlyFallsBackToExtraction() throws {
    let fixture = try SnapshotGitFixture()
    defer { fixture.remove() }
    let cacheURL = temporaryCacheURL()
    defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
    let cache = try IndexCache(fileURL: cacheURL)
    let indexer = ProjectIndexer(parallelism: 1, cache: cache)
    let snapshot = try WorktreeSnapshot(repositoryURL: fixture.root)
    let direct = try ProjectIndexer(parallelism: 1).indexSnapshot(
        snapshot,
        into: ProjectIndexStore()
    )
    _ = try indexer.indexSnapshot(snapshot, into: ProjectIndexStore())
    indexer.flushPersistentWrites()
    let firstRustContentID = try #require(direct.manifest.files.first {
        $0.detectedLanguage == .rust
    }?.contentID)
    let poisonedKey = try #require(direct.contentIndexes.keys.first {
        $0.contentID == firstRustContentID
    })
    cache.storeSynchronously([
        (cacheKey(for: poisonedKey), Data("not a draft".utf8), 1),
    ])

    let prepared = try indexer.prepareSnapshot(snapshot, into: ProjectIndexStore())
    #expect(prepared.pendingExtractionCount == 1)
    #expect(prepared.cachedSession.stats.reusedCount == 0)
    let recovered = try indexer.completeSnapshot(prepared)
    #expect(recovered.stats.extractedCount == 1)
    #expect(recovered.stats.reusedCount == 1)
    try expectEquivalentContent(direct, recovered)
}

@Test
func extractorVersionMismatchRebuildsTheWholeDatabase() throws {
    let cacheURL = temporaryCacheURL()
    defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
    var cache: IndexCache? = try IndexCache(fileURL: cacheURL, extractorVersion: 40)
    cache?.storeSynchronously([("old", Data([1, 2, 3]), 1)])
    #expect(cache?.payload(for: "old") == Data([1, 2, 3]))
    // payload(...) schedules an async LRU touch that retains the cache, so simply
    // dropping the reference would not close the v40 SQLite connection yet. Drain
    // the queue, then release, so the connection (and its -wal/-shm) is fully
    // closed before we reopen the same file. This models an app upgrade — a new
    // process opening the DB — which is the only situation the extractorVersion
    // actually changes. Reopening while the v40 connection is still live races the
    // rebuild's file removal against it and can surface SQLITE_IOERR under load.
    cache?.flush()
    cache = nil

    let bumped = try IndexCache(fileURL: cacheURL, extractorVersion: 41)
    #expect(bumped.payload(for: "old") == nil)
    #expect(bumped.metadata.extractorVersion == 41)
}

@Test
func persistentCacheEvictsLeastRecentlyUsedPayloads() throws {
    let cacheURL = temporaryCacheURL()
    defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
    let cache = try IndexCache(fileURL: cacheURL, quotaBytes: 8)
    cache.storeSynchronously([
        ("a", Data(repeating: 1, count: 4), 1),
        ("b", Data(repeating: 2, count: 4), 2),
    ])
    #expect(cache.payload(for: "a") != nil)
    cache.storeSynchronously([("c", Data(repeating: 3, count: 4), 3)])

    #expect(cache.payload(for: "a") != nil)
    #expect(cache.payload(for: "b") == nil)
    #expect(cache.payload(for: "c") != nil)
}

@Test
func batchInsertMatchesSequentialInsert() throws {
    let fixture = try SnapshotGitFixture()
    defer { fixture.remove() }
    let session = try ProjectIndexer(parallelism: 1).index(root: fixture.root)
    let entries = session.contentIndexes.values.sorted {
        cacheKey(for: $0.key) < cacheKey(for: $1.key)
    }.map { index in
        (
            index,
            session.sourceBytesByContent[index.key.contentID]!,
            false
        )
    }
    let sequential = ProjectIndexStore()
    for entry in entries {
        sequential.insert(
            entry.0,
            bytes: entry.1,
            containsErrorNodes: entry.2
        )
    }
    let batch = ProjectIndexStore()
    batch.insert(entries)

    let sequentialState = sequential.snapshot()
    let batchState = batch.snapshot()
    #expect(Set(sequentialState.contentIndexes.keys) == Set(batchState.contentIndexes.keys))
    #expect(sequentialState.sourceBytesByContent == batchState.sourceBytesByContent)
    #expect(sequentialState.containsErrorNodes == batchState.containsErrorNodes)
    for key in sequentialState.contentIndexes.keys {
        #expect(try encodedIndex(sequentialState.contentIndexes[key]!)
            == encodedIndex(batchState.contentIndexes[key]!))
    }
    #expect(postingDump(sequentialState.namePosting) == postingDump(batchState.namePosting))
}

private func expectEquivalentContent(
    _ direct: EngineSession,
    _ cached: EngineSession
) throws {
    #expect(Set(direct.contentIndexes.keys) == Set(cached.contentIndexes.keys))
    #expect(direct.sourceBytesByContent == cached.sourceBytesByContent)
    for key in direct.contentIndexes.keys {
        let directIndex = direct.contentIndexes[key]!
        let cachedIndex = cached.contentIndexes[key]!
        #expect(try encodedIndex(directIndex) == encodedIndex(cachedIndex))
        #expect(CanonicalDump.render(
            directIndex,
            names: direct.names,
            strings: direct.strings
        ) == CanonicalDump.render(
            cachedIndex,
            names: cached.names,
            strings: cached.strings
        ))
    }
}

private func encodedIndex(_ index: ContentIndex) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(index)
}

private func postingDump(_ posting: NamePosting) -> [String] {
    let definitions = posting.definitions.flatMap { name, values in
        values.map { "d:\(name.rawValue):\(cacheKey(for: $0.key)):\($0.facetIndex)" }
    }
    let calls = posting.calls.flatMap { name, values in
        values.map { "c:\(name.rawValue):\(cacheKey(for: $0.key)):\($0.callIndex)" }
    }
    return (definitions + calls).sorted()
}

private func temporaryCacheURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("CodeInsightIndexCacheTests-\(UUID().uuidString)")
        .appendingPathComponent("cache.sqlite3")
}

private func resolvedName(_ name: String, in session: EngineSession) throws -> String {
    let source = "fn \(name)() {}\nfn call() { \(name)(); }\n"
    let path = try #require(session.manifest.files.first {
        session.paths.resolve($0.pathID) == "src/main.rs"
    }?.pathID)
    let callOffset = UInt32(source.utf8.distance(
        from: source.utf8.startIndex,
        to: source.range(of: "\(name)();")!.lowerBound.samePosition(in: source.utf8)!
    ))
    let candidate = try #require(session.resolve(
        file: path,
        offset: callOffset,
        context: snapshotQueryContext(for: session)
    ).first)
    let (_, index) = try #require(session.content(at: candidate.target.pathID))
    let facet = try #require(index.symbols.indices.contains(Int(candidate.target.localIndex))
        ? index.symbols[Int(candidate.target.localIndex)] : nil)
    return session.names.resolve(facet.nameID)
}

private func snapshotQueryDump(_ session: EngineSession) throws -> String {
    let context = snapshotQueryContext(for: session)
    var lines: [String] = []
    var seen: Set<ContentIndexKey> = []
    for file in session.manifest.files {
        lines.append("path #\(file.pathID.rawValue) \(session.paths.resolve(file.pathID))")
        guard let (key, index) = session.content(at: file.pathID),
              seen.insert(key).inserted
        else { continue }
        lines.append(CanonicalDump.render(
            index,
            names: session.names,
            strings: session.strings
        ))
        lines.append("bindingNames \(index.bindings.map { $0.localNameID.rawValue })")
        lines.append("symbolNames \(index.symbols.map { $0.nameID.rawValue })")
        lines.append("callNames \(index.calls.map { $0.nameID.rawValue })")
        lines.append("importStrings \(index.imports.map { $0.moduleSpecifier.rawValue })")
    }
    lines += try ["a", "b", "shared"].map { name in
        let definitions = try session.definitions(of: name, context: context).map {
            occurrence, facet, pathID in
            "\(session.paths.resolve(pathID)):\(occurrence.localIndex):\(facet.nameID.rawValue)"
        }
        return "\(name)=\(definitions.joined(separator: ","))"
    }
    return lines.joined(separator: "\n")
}

private func snapshotQueryContext(for session: EngineSession) -> QueryContext {
    QueryContext(
        snapshotID: session.snapshotID,
        analysisProfileID: session.analysisProfile.id,
        generation: 1
    )
}

private final class SnapshotGitFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CodeInsightSnapshotIndexerTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git("init", "-q")
        try write("Package.swift", "// non-Rust manifest entry\n")
        try write("src/main.rs", "fn a() {}\nfn call() { a(); }\n")
        try write("src/shared.rs", "pub fn shared() {}\n")
        try git("add", ".")
        try commit("older")
        try write("src/main.rs", "fn b() {}\nfn call() { b(); }\n")
        try git("add", "src/main.rs")
        try commit("newer")
    }

    func commitLFSPointer(_ bytes: [UInt8]) throws {
        let file = root.appendingPathComponent("src/large.rs")
        try Data(bytes).write(to: file)
        try git("add", "src/large.rs")
        try commit("lfs pointer")
    }

    private func write(_ path: String, _ contents: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func commit(_ message: String) throws {
        try git(
            "-c", "user.name=CodeInsight",
            "-c", "user.email=codeinsight@example.com",
            "commit", "-q", "-m", message
        )
    }

    @discardableResult
    private func git(_ arguments: String...) throws -> String {
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
            throw SnapshotFixtureError.git(message)
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

private enum SnapshotFixtureError: Error {
    case git(String)
}
