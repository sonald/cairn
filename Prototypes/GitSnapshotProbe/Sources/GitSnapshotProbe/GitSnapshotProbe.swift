import CLibGit2
import CodeInsightCore
import CodeInsightEngine
import CodeInsightRustExtractor
import Foundation

public struct GitOID: Hashable, Sendable, CustomStringConvertible {
    public let hex: String

    public var description: String { hex }
}

public struct CommitSnapshotTiming: Sendable {
    public let treeWalkMilliseconds: Double
    public let blobReadMilliseconds: Double
    public let blobBytes: Int
}

public enum GitSnapshotProbeError: Error, LocalizedError {
    case git(operation: String, code: Int32, message: String)
    case notAWorktree(String)
    case missingPath(String)
    case lowReuse(actual: Double, required: Double)

    public var errorDescription: String? {
        switch self {
        case let .git(operation, code, message):
            return "\(operation) failed (\(code)): \(message)"
        case let .notAWorktree(path):
            return "repository has no worktree: \(path)"
        case let .missingPath(path):
            return "snapshot path not found: \(path)"
        case let .lowReuse(actual, required):
            return String(
                format: "cache hit rate %.1f%% did not exceed %.1f%%",
                actual * 100,
                required * 100
            )
        }
    }
}

private func check(_ code: Int32, _ operation: String) throws {
    guard code < 0 else { return }
    let message = git_error_last().map { error in
        String(cString: error.pointee.message)
    } ?? "unknown libgit2 error"
    throw GitSnapshotProbeError.git(
        operation: operation,
        code: code,
        message: message
    )
}

private func oidString(_ oid: UnsafePointer<git_oid>) -> GitOID {
    GitOID(hex: String(cString: git_oid_tostr_s(oid)))
}

private func elapsedMilliseconds(since start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

private final class GitRepository {
    let raw: OpaquePointer

    init(url: URL) throws {
        git_libgit2_init()
        var repository: OpaquePointer?
        do {
            try url.withUnsafeFileSystemRepresentation { path in
                try check(git_repository_open(&repository, path), "git_repository_open")
            }
            guard let repository else {
                throw GitSnapshotProbeError.git(
                    operation: "git_repository_open",
                    code: -1,
                    message: "returned no repository"
                )
            }
            raw = repository
        } catch {
            git_libgit2_shutdown()
            throw error
        }
    }

    deinit {
        git_repository_free(raw)
        git_libgit2_shutdown()
    }

    func readBlob(oid: GitOID) throws -> Data {
        var parsed = git_oid()
        try oid.hex.withCString { string in
            try check(git_oid_fromstr(&parsed, string), "git_oid_fromstr")
        }
        var blob: OpaquePointer?
        try check(git_blob_lookup(&blob, raw, &parsed), "git_blob_lookup")
        guard let blob else { return Data() }
        defer { git_blob_free(blob) }
        return blobData(blob)
    }
}

private func blobData(_ blob: OpaquePointer) -> Data {
    let count = git_blob_rawsize(blob)
    guard count > 0, let bytes = git_blob_rawcontent(blob) else { return Data() }
    return Data(bytes: bytes, count: Int(count))
}

private final class TreeWalkCollector {
    var files: [String: GitOID] = [:]
}

private let collectTreeEntry: git_treewalk_cb = { root, entry, payload in
    guard
        let root,
        let entry,
        let payload,
        git_tree_entry_type(entry) == GIT_OBJECT_BLOB,
        let name = git_tree_entry_name(entry),
        let oid = git_tree_entry_id(entry)
    else { return 0 }

    let collector = Unmanaged<TreeWalkCollector>
        .fromOpaque(payload)
        .takeUnretainedValue()
    collector.files[String(cString: root) + String(cString: name)] = oidString(oid)
    return 0
}

public final class CommitSnapshot {
    private let repository: GitRepository
    private let tree: OpaquePointer

    public let revision: String
    public let files: [String: GitOID]
    public let timing: CommitSnapshotTiming

    public init(repositoryURL: URL, revision: String = "HEAD") throws {
        let repository = try GitRepository(url: repositoryURL)
        var object: OpaquePointer?
        try revision.withCString { spec in
            try check(git_revparse_single(&object, repository.raw, spec), "git_revparse_single")
        }
        guard let object else {
            throw GitSnapshotProbeError.git(
                operation: "git_revparse_single",
                code: -1,
                message: "returned no object"
            )
        }
        defer { git_object_free(object) }

        var commitObject: OpaquePointer?
        try check(
            git_object_peel(&commitObject, object, GIT_OBJECT_COMMIT),
            "git_object_peel(commit)"
        )
        guard let commitObject else {
            throw GitSnapshotProbeError.git(
                operation: "git_object_peel(commit)",
                code: -1,
                message: "returned no commit"
            )
        }
        defer { git_object_free(commitObject) }

        var tree: OpaquePointer?
        try check(git_commit_tree(&tree, commitObject), "git_commit_tree")
        guard let tree else {
            throw GitSnapshotProbeError.git(
                operation: "git_commit_tree",
                code: -1,
                message: "returned no tree"
            )
        }

        let collector = TreeWalkCollector()
        let walkStarted = DispatchTime.now().uptimeNanoseconds
        let payload = Unmanaged.passUnretained(collector).toOpaque()
        do {
            try check(
                git_tree_walk(tree, GIT_TREEWALK_PRE, collectTreeEntry, payload),
                "git_tree_walk"
            )
        } catch {
            git_tree_free(tree)
            throw error
        }
        let treeWalkMilliseconds = elapsedMilliseconds(since: walkStarted)

        let blobStarted = DispatchTime.now().uptimeNanoseconds
        var blobBytes = 0
        do {
            for oid in collector.files.values {
                blobBytes += try repository.readBlob(oid: oid).count
            }
        } catch {
            git_tree_free(tree)
            throw error
        }

        self.repository = repository
        self.tree = tree
        self.revision = revision
        files = collector.files
        timing = CommitSnapshotTiming(
            treeWalkMilliseconds: treeWalkMilliseconds,
            blobReadMilliseconds: elapsedMilliseconds(since: blobStarted),
            blobBytes: blobBytes
        )
    }

    deinit {
        git_tree_free(tree)
    }

    public func read(path: String) throws -> Data {
        guard files[path] != nil else {
            throw GitSnapshotProbeError.missingPath(path)
        }
        var entry: OpaquePointer?
        try path.withCString { path in
            try check(git_tree_entry_bypath(&entry, tree, path), "git_tree_entry_bypath")
        }
        guard let entry else { throw GitSnapshotProbeError.missingPath(path) }
        defer { git_tree_entry_free(entry) }

        var blob: OpaquePointer?
        try check(
            git_blob_lookup(&blob, repository.raw, git_tree_entry_id(entry)),
            "git_blob_lookup"
        )
        guard let blob else { return Data() }
        defer { git_blob_free(blob) }
        return blobData(blob)
    }
}

private enum WorktreeSource {
    case gitBlob(GitOID)
    case stored(ContentID)
}

public struct WorktreeCaptureStats: Sendable {
    public let totalFiles: Int
    public let cleanTrackedFiles: Int
    public let copiedFiles: Int
    public let copiedBytes: Int
    public let captureMilliseconds: Double
}

public final class WorktreeSnapshot {
    private let repository: GitRepository
    private let contentStore: URL
    private let sources: [String: WorktreeSource]

    public let stats: WorktreeCaptureStats
    public var paths: [String] { sources.keys.sorted() }

    public init(repositoryURL: URL) throws {
        let started = DispatchTime.now().uptimeNanoseconds
        let repository = try GitRepository(url: repositoryURL)
        guard let workdir = git_repository_workdir(repository.raw) else {
            throw GitSnapshotProbeError.notAWorktree(repositoryURL.path)
        }
        let root = URL(fileURLWithPath: String(cString: workdir), isDirectory: true)
        let store = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitSnapshotProbe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)

        var index: OpaquePointer?
        do {
            try check(git_repository_index(&index, repository.raw), "git_repository_index")
        } catch {
            try? FileManager.default.removeItem(at: store)
            throw error
        }
        guard let index else {
            try? FileManager.default.removeItem(at: store)
            throw GitSnapshotProbeError.git(
                operation: "git_repository_index",
                code: -1,
                message: "returned no index"
            )
        }
        defer { git_index_free(index) }

        var captured: [String: WorktreeSource] = [:]
        var cleanCount = 0
        var copiedCount = 0
        var copiedBytes = 0

        do {
            for file in try Self.files(under: root) {
                let path = Self.relativePath(of: file, under: root)
                let tracked = path.withCString { git_index_get_bypath(index, $0, 0) }

                if let tracked {
                    var status: UInt32 = 0
                    // ponytail: per-file status rescans Git state; replace with one
                    // git_status_list when capture latency matters on large repos.
                    try path.withCString { path in
                        try check(git_status_file(&status, repository.raw, path), "git_status_file")
                    }
                    if status == UInt32(GIT_STATUS_CURRENT.rawValue) {
                        captured[path] = .gitBlob(oidString(withUnsafePointer(to: tracked.pointee.id) { $0 }))
                        cleanCount += 1
                        continue
                    }
                } else {
                    var ignored: Int32 = 0
                    try path.withCString { path in
                        try check(
                            git_ignore_path_is_ignored(&ignored, repository.raw, path),
                            "git_ignore_path_is_ignored"
                        )
                    }
                    if ignored != 0 { continue }
                }

                let data = try Data(contentsOf: file, options: .mappedIfSafe)
                let contentID = ContentID.sha256(of: data)
                let destination = store.appendingPathComponent(contentID.hex)
                if !FileManager.default.fileExists(atPath: destination.path) {
                    try data.write(to: destination, options: .atomic)
                }
                captured[path] = .stored(contentID)
                copiedCount += 1
                copiedBytes += data.count
            }
        } catch {
            try? FileManager.default.removeItem(at: store)
            throw error
        }

        self.repository = repository
        contentStore = store
        sources = captured
        stats = WorktreeCaptureStats(
            totalFiles: captured.count,
            cleanTrackedFiles: cleanCount,
            copiedFiles: copiedCount,
            copiedBytes: copiedBytes,
            captureMilliseconds: elapsedMilliseconds(since: started)
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: contentStore)
    }

    public func read(path: String) throws -> Data {
        guard let source = sources[path] else {
            throw GitSnapshotProbeError.missingPath(path)
        }
        switch source {
        case let .gitBlob(oid):
            return try repository.readBlob(oid: oid)
        case let .stored(contentID):
            return try Data(contentsOf: contentStore.appendingPathComponent(contentID.hex))
        }
    }

    private static func files(under root: URL) throws -> [URL] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator {
            if url.lastPathComponent == ".git" {
                enumerator.skipDescendants()
                continue
            }
            let values = try url.resourceValues(forKeys: keys)
            if values.isDirectory == true && values.isSymbolicLink == true {
                enumerator.skipDescendants()
            } else if values.isRegularFile == true && values.isSymbolicLink != true {
                files.append(url)
            }
        }
        return files
    }

    private static func relativePath(of file: URL, under root: URL) -> String {
        file.standardizedFileURL.pathComponents
            .dropFirst(root.standardizedFileURL.pathComponents.count)
            .joined(separator: "/")
    }
}

private extension ContentID {
    var hex: String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

public struct SwitchStats: Sendable {
    public let headFiles: Int
    public let totalFiles: Int
    public let cacheHits: Int
    public let newExtractions: Int
    public let elapsedMilliseconds: Double

    public var hitRate: Double {
        totalFiles == 0 ? 1 : Double(cacheHits) / Double(totalFiles)
    }
}

public enum SnapshotSwitchProbe {
    public static func run(repositoryURL: URL, minimumHitRate: Double = 0.80) throws -> SwitchStats {
        let head = try CommitSnapshot(repositoryURL: repositoryURL, revision: "HEAD")
        let names = Interner<NameID>()
        let strings = Interner<StringID>()
        let interners = ExtractionInterners(names: names, strings: strings)
        let extractor = RustExtractor()
        var cache: [ContentIndexKey: ContentIndex] = [:]

        for path in head.files.keys.sorted() where path.hasSuffix(".rs") {
            let bytes = [UInt8](try head.read(path: path))
            let key = indexKey(bytes)
            if cache[key] == nil {
                cache[key] = try extractor.extract(bytes: bytes, key: key, interner: interners)
            }
        }

        let switchStarted = DispatchTime.now().uptimeNanoseconds
        let previous = try CommitSnapshot(repositoryURL: repositoryURL, revision: "HEAD~1")
        var hits = 0
        var extractions = 0
        let rustPaths = previous.files.keys.sorted().filter { $0.hasSuffix(".rs") }
        for path in rustPaths {
            let bytes = [UInt8](try previous.read(path: path))
            let key = indexKey(bytes)
            if cache[key] != nil {
                hits += 1
            } else {
                cache[key] = try extractor.extract(bytes: bytes, key: key, interner: interners)
                extractions += 1
            }
        }

        let stats = SwitchStats(
            headFiles: head.files.keys.filter { $0.hasSuffix(".rs") }.count,
            totalFiles: rustPaths.count,
            cacheHits: hits,
            newExtractions: extractions,
            elapsedMilliseconds: elapsedMilliseconds(since: switchStarted)
        )
        guard stats.hitRate > minimumHitRate else {
            throw GitSnapshotProbeError.lowReuse(
                actual: stats.hitRate,
                required: minimumHitRate
            )
        }
        return stats
    }

    private static func indexKey(_ bytes: [UInt8]) -> ContentIndexKey {
        ContentIndexKey(
            contentID: ContentID.sha256(of: bytes),
            languageMode: LanguageMode(language: .rust),
            grammarVersion: RustExtractorInfo.grammarVersion,
            extractorVersion: RustExtractorInfo.extractorVersion
        )
    }
}

public actor GenerationDisplay {
    private var generation = 0
    private var displayedSnapshot: String

    public init(snapshot: String) {
        displayedSnapshot = snapshot
    }

    public func token() -> Int { generation }

    public func switchTo(snapshot: String) {
        generation += 1
        displayedSnapshot = snapshot
    }

    @discardableResult
    public func publish(snapshot: String, generation candidate: Int) -> Bool {
        guard candidate == generation else { return false }
        displayedSnapshot = snapshot
        return true
    }

    public func displayed() -> String { displayedSnapshot }
}
