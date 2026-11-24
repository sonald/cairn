import CLibGit2
import CodeInsightCore
import Dispatch
import Foundation

enum LibGit2Executor {
    private static let marker = DispatchSpecificKey<UInt8>()
    private static let queue: DispatchQueue = {
        let queue = DispatchQueue(label: "CodeInsightGit.libgit2")
        queue.setSpecific(key: marker, value: 1)
        return queue
    }()
    private static let initializationCode: Int32 = {
        let code = git_libgit2_init()
        guard code >= 0 else { return code }
        // Repository snapshots must not depend on ambient user or system config.
        return codeinsight_use_repository_config_only()
    }()

    static func sync<T>(_ operation: () throws -> T) throws -> T {
        if DispatchQueue.getSpecific(key: marker) != nil {
            return try initialized(operation)
        }
        return try queue.sync { try initialized(operation) }
    }

    private static func initialized<T>(_ operation: () throws -> T) throws -> T {
        guard initializationCode >= 0 else {
            throw gitError(
                operation: "git_libgit2_init",
                code: initializationCode
            )
        }
        return try operation()
    }
}

public struct GitOID: Hashable, Sendable, CustomStringConvertible {
    public let hex: String

    public init(hex: String) {
        self.hex = hex
    }

    public var description: String { hex }
}

public enum GitObjectFormat: String, Hashable, Sendable, Codable {
    case sha1
    case sha256
}

public enum GitError: Error, LocalizedError {
    case git(operation: String, code: Int32, message: String)
    case missingPath(String)
    /// A worktree file is gone or no longer has the content it was
    /// captured with.
    case changedSinceCapture(String)
    case notAWorktree(String)
    case unsupportedObjectFormat(Int32)

    public var errorDescription: String? {
        switch self {
        case let .git(operation, code, message):
            return "\(operation) failed (\(code)): \(message)"
        case let .missingPath(path):
            return "snapshot path not found: \(path)"
        case let .changedSinceCapture(path):
            return "file changed since capture: \(path)"
        case let .notAWorktree(path):
            return "repository has no worktree: \(path)"
        case let .unsupportedObjectFormat(rawValue):
            return "unsupported Git object format: \(rawValue)"
        }
    }
}

public protocol Snapshot: Sendable {
    var snapshotID: SnapshotID { get }
    var objectFormat: GitObjectFormat { get }
    var sourceKind: SourceKind { get }
    var projectRootName: String { get }

    func listFiles() -> [(path: String, contentID: ContentID, fileMode: FileMode)]
    func readBytes(path: String) throws -> [UInt8]
    /// The file's byte count, without reading it where the snapshot knows it.
    func fileSize(path: String) throws -> UInt64

    var configurationPaths: [String] { get }
    /// Paths the project's own exclusion rules removed: the topmost excluded
    /// directory or file of each pruned branch, sorted. Built-in skips are
    /// not listed.
    var ruleExcludedPaths: [String] { get }
    /// Worktree files that could not be read and were left out, sorted.
    var unreadablePaths: [String] { get }
    /// Supported languages with at least one source file in this snapshot,
    /// sorted by `rawValue`.
    var languages: [LanguageID] { get }
}

public extension Snapshot {
    var projectRootName: String { "." }
    var configurationPaths: [String] { [] }
    var ruleExcludedPaths: [String] { [] }
    var unreadablePaths: [String] { [] }
    var languages: [LanguageID] { detectedLanguages(in: listFiles()) }
    func fileSize(path: String) throws -> UInt64 { UInt64(try readBytes(path: path).count) }
}

/// Symlinks and gitlinks are not sources: the worktree walk never captures
/// them, so a commit must not count them either.
func detectedLanguages(
    in files: [(path: String, contentID: ContentID, fileMode: FileMode)]
) -> [LanguageID] {
    var found = Set<LanguageID>()
    for file in files where file.fileMode == .regular || file.fileMode == .lfsPointer {
        if let mode = LanguageMode.classify(path: file.path) {
            found.insert(mode.language)
        }
    }
    return LanguageMode.supported.filter(found.contains)
}

/// Every use of `raw` goes through `LibGit2Executor`, so a snapshot may
/// keep the repository open and read from it on any thread.
public final class GitRepository: @unchecked Sendable {
    let raw: OpaquePointer

    public let objectFormat: GitObjectFormat

    public init(url: URL) throws {
        let opened: (OpaquePointer, GitObjectFormat) = try LibGit2Executor.sync {
            var repository: OpaquePointer?
            do {
                try url.withUnsafeFileSystemRepresentation { path in
                    try check(git_repository_open(&repository, path), "git_repository_open")
                }
                guard let repository else {
                    throw GitError.git(
                        operation: "git_repository_open",
                        code: -1,
                        message: "returned no repository"
                    )
                }

                let oidType = codeinsight_repository_oid_type(repository)
                let objectFormat: GitObjectFormat
                switch oidType {
                case codeinsight_oid_sha1():
                    objectFormat = .sha1
                case codeinsight_oid_sha256():
                    objectFormat = .sha256
                default:
                    throw GitError.unsupportedObjectFormat(oidType)
                }
                return (repository, objectFormat)
            } catch {
                if let repository { git_repository_free(repository) }
                throw error
            }
        }
        raw = opened.0
        objectFormat = opened.1
    }

    deinit {
        let raw = raw
        try? LibGit2Executor.sync { git_repository_free(raw) }
    }

    /// Identifies this repository's object store for blob reuse: object IDs
    /// are only shared between captures of the same repository.
    var reuseKey: String {
        let path = git_repository_path(raw).map { String(cString: $0) } ?? ""
        return "\(objectFormat.rawValue):\(path)"
    }

    func readBlob(oid: git_oid) throws -> [UInt8] {
        try LibGit2Executor.sync {
            var oid = oid
            var blob: OpaquePointer?
            try check(git_blob_lookup(&blob, raw, &oid), "git_blob_lookup")
            guard let blob else { return [] }
            defer { git_blob_free(blob) }

            let count = git_blob_rawsize(blob)
            guard count > 0, let bytes = git_blob_rawcontent(blob) else { return [] }
            return Array(UnsafeBufferPointer(start: bytes.assumingMemoryBound(to: UInt8.self), count: Int(count)))
        }
    }
}

public final class CommitSnapshot: Snapshot, Sendable {
    /// A manifest, not the content: each file's bytes are read from the
    /// object database by object ID when asked for.
    private let files: [String: ManifestFile]
    private let repository: GitRepository
    /// Blobs whose content ID was already known from an earlier capture of
    /// the same repository, so they were not read; diagnostic.
    package let reusedBlobCount: Int
    public let ruleExcludedPaths: [String]

    public let snapshotID: SnapshotID
    public let objectFormat: GitObjectFormat
    public let sourceKind: SourceKind = .tracked
    public let revision: String
    public let commitOID: GitOID
    public let projectRootName: String
    public let configurationPaths: [String]
    public let languages: [LanguageID]

    /// Built-in skipped directories never hide tracked files here; only the
    /// user's rules do, and excluded blobs are never read. A blob seen by an
    /// earlier capture of this repository in this process is not read again:
    /// an object ID names one content, so its content ID is the same. A new
    /// blob is read and hashed once, and its bytes are dropped.
    public init(
        repositoryURL: URL,
        revision: String = "HEAD",
        pathRules: ProjectPathRules = ProjectPathRules()
    ) throws {
        let repository = try GitRepository(url: repositoryURL)
        // The tree walk holds the serial libgit2 queue once; each blob read
        // below takes it on its own, so other readers interleave.
        let walked: (entries: [TreeEntry], commitOID: GitOID) = try LibGit2Executor.sync {
            var object: OpaquePointer?
            try revision.withCString { spec in
                try check(
                    git_revparse_single(&object, repository.raw, spec),
                    "git_revparse_single"
                )
            }
            guard let object else {
                throw GitError.git(
                    operation: "git_revparse_single",
                    code: -1,
                    message: "returned no object"
                )
            }
            defer { git_object_free(object) }

            var commit: OpaquePointer?
            try check(
                git_object_peel(&commit, object, GIT_OBJECT_COMMIT),
                "git_object_peel(commit)"
            )
            guard let commit, let commitID = git_object_id(commit) else {
                throw GitError.git(
                    operation: "git_object_peel(commit)",
                    code: -1,
                    message: "returned no commit"
                )
            }
            defer { git_object_free(commit) }

            var tree: OpaquePointer?
            try check(git_commit_tree(&tree, commit), "git_commit_tree")
            guard let tree else {
                throw GitError.git(
                    operation: "git_commit_tree",
                    code: -1,
                    message: "returned no tree"
                )
            }
            defer { git_tree_free(tree) }

            let collector = TreeWalkCollector()
            let payload = Unmanaged.passUnretained(collector).toOpaque()
            try check(
                git_tree_walk(tree, GIT_TREEWALK_PRE, collectTreeEntry, payload),
                "git_tree_walk"
            )
            return (collector.entries, oidString(commitID))
        }

        let reuseKey = repository.reuseKey
        var known = knownBlobs.facts(for: reuseKey)
        var learned: [GitOID: BlobFacts] = [:]
        var captured: [String: ManifestFile] = [:]
        var reused = 0
        var excluded: [String] = []
        // As in the worktree walk, a file under an excluded directory
        // stays out even if a `!` rule matches the file itself.
        var excludedDirectory: [String: Bool] = [:]
        func isExcluded(_ path: String) -> Bool {
            var directory = ""
            for component in path.split(separator: "/").dropLast() {
                directory += directory.isEmpty ? String(component) : "/" + component
                let verdict = excludedDirectory[directory] ?? pathRules.verdict(
                    for: directory, isDirectory: true, appliesDefaults: false
                ).isExcluded
                excludedDirectory[directory] = verdict
                if verdict { return true }
            }
            return pathRules.verdict(for: path, isDirectory: false, appliesDefaults: false).isExcluded
        }
        for entry in walked.entries {
            if isExcluded(entry.path) {
                excluded.append(entry.path)
                continue
            }
            // A gitlink names a commit, not a blob; its bytes are the
            // object ID itself.
            let facts: BlobFacts
            if entry.fileMode == .gitlink {
                facts = BlobFacts(bytes: Array(entry.oid.hex.utf8))
            } else if let seen = known[entry.oid] {
                facts = seen
                if learned.updateValue(seen, forKey: entry.oid) == nil { reused += 1 }
            } else {
                facts = BlobFacts(bytes: try repository.readBlob(oid: entry.rawOID))
                known[entry.oid] = facts
                learned[entry.oid] = facts
            }
            // The mode is this entry's own: one blob can be a file in one
            // place and a symlink target in another.
            captured[entry.path] = ManifestFile(
                oid: entry.rawOID,
                contentID: facts.contentID,
                fileMode: entry.fileMode == .regular && facts.isLFSPointer
                    ? .lfsPointer : entry.fileMode,
                size: facts.size
            )
        }
        knownBlobs.record(learned, for: reuseKey)

        snapshotID = SnapshotID(rawValue: UUID())
        self.repository = repository
        reusedBlobCount = reused
        objectFormat = repository.objectFormat
        self.revision = revision
        commitOID = walked.commitOID
        ruleExcludedPaths = Self.topmostExcluded(excluded, rules: pathRules)
        projectRootName = repositoryURL.standardizedFileURL.lastPathComponent
        files = captured
        configurationPaths = captured.keys
            .filter { entry in
                guard configurationLanguage(
                    for: fileName(of: entry)
                ) != nil,
                      captured[entry]?.fileMode != .symlink
                else { return false }
                return true
            }
            .sorted()
        languages = detectedLanguages(in: captured.map { ($0.key, $0.value.contentID, $0.value.fileMode) })
    }

    public func listFiles() -> [(
        path: String,
        contentID: ContentID,
        fileMode: FileMode
    )] {
        files.keys.sorted().compactMap { path in
            files[path].map { (path, $0.contentID, $0.fileMode) }
        }
    }

    /// Reads the blob again; throws when the object database no longer
    /// has it. The bytes are not checked against the content ID here.
    public func readBytes(path: String) throws -> [UInt8] {
        guard let file = files[path] else { throw GitError.missingPath(path) }
        if file.fileMode == .gitlink {
            var oid = file.oid
            return Array(oidString(&oid).hex.utf8)
        }
        return try repository.readBlob(oid: file.oid)
    }

    public func fileSize(path: String) throws -> UInt64 {
        guard let file = files[path] else { throw GitError.missingPath(path) }
        return file.size
    }

    /// Forgets the blobs this process has seen in the repository, so the
    /// next capture reads every blob; for tests.
    package static func forgetKnownBlobs(repositoryURL: URL) throws {
        knownBlobs.forget(try GitRepository(url: repositoryURL).reuseKey)
    }

    /// Reports excluded files the way a worktree walk does: the topmost
    /// directory a rule excludes stands for everything below it, so the
    /// count means the same in both kinds of snapshot.
    private static func topmostExcluded(_ paths: [String], rules: ProjectPathRules) -> [String] {
        var result = Set<String>()
        for path in paths {
            let components = path.split(separator: "/").map(String.init)
            let directory = (1..<max(1, components.count)).lazy
                .map { components.prefix($0).joined(separator: "/") }
                .first { rules.verdict(for: $0, isDirectory: true, appliesDefaults: false).isExcluded }
            result.insert(directory ?? path)
        }
        return result.sorted()
    }
}

public final class WorktreeSnapshot: Snapshot, Sendable {
    /// A manifest, not the content: each file is read again from disk when
    /// asked for and must still have the content it was captured with.
    private let files: [String: WorktreeFile]
    private let root: URL
    public let ruleExcludedPaths: [String]
    public let unreadablePaths: [String]

    public let snapshotID: SnapshotID
    public let objectFormat: GitObjectFormat
    public let projectRootName: String
    public let configurationPaths: [String]
    public let languages: [LanguageID]
    // A directory import has no per-file Git status in the M1 model, so all
    // captured worktree files retain the existing .untracked convention.
    public let sourceKind: SourceKind = .untracked

    /// A directory that is not itself a Git repository (including a
    /// repository subdirectory: `git_repository_open` does not search
    /// upward) is captured as a plain directory; other Git errors throw.
    /// Every file is read once, one at a time, to hash it; no bytes are
    /// kept.
    public init(
        repositoryURL: URL,
        pathRules: ProjectPathRules = ProjectPathRules()
    ) throws {
        let repositoryInfo: (URL, GitObjectFormat) = try LibGit2Executor.sync {
            let repository: GitRepository
            do {
                repository = try GitRepository(url: repositoryURL)
            } catch let GitError.git(operation, code, _)
                where operation == "git_repository_open" && code == GIT_ENOTFOUND.rawValue
            {
                return (repositoryURL.standardizedFileURL, .sha1)
            }
            guard let workdir = git_repository_workdir(repository.raw) else {
                throw GitError.notAWorktree(repositoryURL.path)
            }
            return (
                URL(
                    fileURLWithPath: String(cString: workdir),
                    isDirectory: true
                ).standardizedFileURL,
                repository.objectFormat
            )
        }
        let root = repositoryInfo.0

        var captured: [String: WorktreeFile] = [:]
        var excluded: [String] = []
        let walked = try ProjectTreeWalk.regularFiles(under: root, rules: pathRules)
        var unreadable = walked.unreadableDirectories
        excluded = walked.ruleExcluded
        for file in walked.files {
            let relative = ProjectTreeWalk.relativePath(of: file, under: root)
            // One unreadable file (permissions, a vanished file) must not
            // stop the open; it is left out and reported instead.
            guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
                unreadable.append(relative)
                continue
            }
            captured[relative] = WorktreeFile(
                contentID: ContentID.sha256(of: data),
                fileMode: data.starts(with: lfsPointerPrefix) ? .lfsPointer : .regular,
                size: UInt64(data.count)
            )
        }

        snapshotID = SnapshotID(rawValue: UUID())
        objectFormat = repositoryInfo.1
        projectRootName = root.lastPathComponent
        self.root = root
        files = captured
        ruleExcludedPaths = excluded
        unreadablePaths = unreadable.sorted()
        configurationPaths = captured.keys.filter { entry in
            configurationLanguage(
                for: fileName(of: entry)
            ) != nil
        }.sorted()
        languages = detectedLanguages(in: captured.map { ($0.key, $0.value.contentID, $0.value.fileMode) })
    }

    public func listFiles() -> [(
        path: String,
        contentID: ContentID,
        fileMode: FileMode
    )] {
        files.keys.sorted().compactMap { path in
            files[path].map { (path, $0.contentID, $0.fileMode) }
        }
    }

    /// Reads the file again; throws `changedSinceCapture` when it is gone
    /// or its bytes no longer hash to the captured content ID, so a caller
    /// never gets other content under the captured identity.
    public func readBytes(path: String) throws -> [UInt8] {
        guard let file = files[path] else {
            throw GitError.missingPath(path)
        }
        guard let data = try? Data(contentsOf: root.appendingPathComponent(path), options: .mappedIfSafe),
              ContentID.sha256(of: data) == file.contentID
        else { throw GitError.changedSinceCapture(path) }
        return [UInt8](data)
    }

    public func fileSize(path: String) throws -> UInt64 {
        guard let file = files[path] else { throw GitError.missingPath(path) }
        return file.size
    }

}

/// The one worktree walk shared by snapshot capture, directory indexing and
/// the file tree: regular non-symlink files, pruned by `ProjectPathRules`.
public enum ProjectTreeWalk {
    public static func regularFiles(
        under root: URL,
        rules: ProjectPathRules
    ) throws -> (files: [URL], ruleExcluded: [String], unreadableDirectories: [String]) {
        var files: [URL] = []
        var excluded: [String] = []
        var unreadable: [String] = []
        try walk(
            root, root: root, rules: rules,
            files: &files, excluded: &excluded, unreadable: &unreadable
        )
        return (files.sorted { $0.path < $1.path }, excluded.sorted(), unreadable.sorted())
    }

    public static func relativePath(of file: URL, under root: URL) -> String {
        file.standardizedFileURL.pathComponents
            .dropFirst(root.standardizedFileURL.pathComponents.count)
            .joined(separator: "/")
    }

    private static func walk(
        _ directory: URL,
        root: URL,
        rules: ProjectPathRules,
        files: inout [URL],
        excluded: inout [String],
        unreadable: inout [String]
    ) throws {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        // Only an unreadable root fails the walk; an unreadable subfolder
        // (permissions, privacy protection) or a vanished entry is skipped.
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: keys
            )
        } catch where directory != root {
            unreadable.append(relativePath(of: directory, under: root))
            return
        }
        for url in entries {
            if url.lastPathComponent == ".DS_Store" { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            guard values.isSymbolicLink != true else { continue }
            let isDirectory = values.isDirectory == true
            guard isDirectory || values.isRegularFile == true else { continue }
            let relative = relativePath(of: url, under: root)
            switch rules.verdict(for: relative, isDirectory: isDirectory) {
            case .included:
                if isDirectory {
                    try walk(
                        url, root: root, rules: rules,
                        files: &files, excluded: &excluded, unreadable: &unreadable
                    )
                } else {
                    files.append(url)
                }
            case .excludedByRule:
                excluded.append(relative)
            case .skippedByDefault, .alwaysSkipped:
                continue
            }
        }
    }
}

/// The last component of a snapshot-relative path. Plain string work: a
/// relative file URL would ask the system for the working directory on
/// every one of thousands of paths.
private func fileName(of path: String) -> String {
    path.split(separator: "/").last.map(String.init) ?? path
}

private func configurationLanguage(for name: String) -> LanguageID? {
    switch name {
    case "Cargo.toml", "Cargo.lock":
        return .rust
    case "pyrightconfig.json", "pyproject.toml", "uv.lock":
        return .python
    case "tsconfig.json", "package.json", "bun.lockb":
        return .typescript
    case "go.mod", "go.sum", "go.work", "go.work.sum":
        return .go
    default:
        return nil
    }
}

private struct WorktreeFile: Sendable {
    let contentID: ContentID
    let fileMode: FileMode
    let size: UInt64
}

private struct ManifestFile: @unchecked Sendable {
    let oid: git_oid
    let contentID: ContentID
    let fileMode: FileMode
    let size: UInt64
}

/// What a blob's bytes say about it, kept after the bytes are dropped.
private struct BlobFacts: Sendable {
    let contentID: ContentID
    let isLFSPointer: Bool
    let size: UInt64

    init(bytes: [UInt8]) {
        contentID = ContentID.sha256(of: bytes)
        isLFSPointer = bytes.starts(with: lfsPointerPrefix)
        size = UInt64(bytes.count)
    }
}

/// Blob facts by object ID for each repository this process captured from
/// (keyed like `GitRepository.reuseKey`). It holds no bytes and is never
/// trimmed: about a hundred bytes per distinct blob seen.
private final class KnownBlobs: @unchecked Sendable {
    private let lock = NSLock()
    private var tables: [String: [GitOID: BlobFacts]] = [:]

    func facts(for key: String) -> [GitOID: BlobFacts] {
        lock.withLock { tables[key] ?? [:] }
    }

    func record(_ facts: [GitOID: BlobFacts], for key: String) {
        guard !facts.isEmpty else { return }
        lock.withLock { tables[key, default: [:]].merge(facts) { current, _ in current } }
    }

    func forget(_ key: String) {
        _ = lock.withLock { tables.removeValue(forKey: key) }
    }
}

private let knownBlobs = KnownBlobs()

private let lfsPointerPrefix = Array(
    "version https://git-lfs.github.com/spec".utf8
)

struct TreeEntry {
    let path: String
    let oid: GitOID
    let rawOID: git_oid
    let fileMode: FileMode
}

final class TreeWalkCollector {
    var entries: [TreeEntry] = []
}

let collectTreeEntry: git_treewalk_cb = { root, entry, payload in
    guard let root, let entry, let payload,
          let name = git_tree_entry_name(entry),
          let oid = git_tree_entry_id(entry),
          let fileMode = fileMode(of: entry)
    else { return 0 }

    let collector = Unmanaged<TreeWalkCollector>
        .fromOpaque(payload)
        .takeUnretainedValue()
    collector.entries.append(TreeEntry(
        path: String(cString: root) + String(cString: name),
        oid: oidString(oid),
        rawOID: oid.pointee,
        fileMode: fileMode
    ))
    return 0
}

private func fileMode(of entry: OpaquePointer) -> FileMode? {
    switch git_tree_entry_filemode(entry) {
    case GIT_FILEMODE_BLOB, GIT_FILEMODE_BLOB_EXECUTABLE:
        return .regular
    case GIT_FILEMODE_LINK:
        return .symlink
    case GIT_FILEMODE_COMMIT:
        return .gitlink
    default:
        return nil
    }
}

func oidString(_ oid: UnsafePointer<git_oid>) -> GitOID {
    GitOID(hex: String(cString: git_oid_tostr_s(oid)))
}

func check(_ code: Int32, _ operation: String) throws {
    guard code < 0 else { return }
    throw gitError(operation: operation, code: code)
}

func gitError(operation: String, code: Int32) -> GitError {
    let message = git_error_last().map { error in
        String(cString: error.pointee.message)
    } ?? "unknown libgit2 error"
    return .git(operation: operation, code: code, message: message)
}
