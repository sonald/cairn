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
    case notAWorktree(String)
    case unsupportedObjectFormat(Int32)

    public var errorDescription: String? {
        switch self {
        case let .git(operation, code, message):
            return "\(operation) failed (\(code)): \(message)"
        case let .missingPath(path):
            return "snapshot path not found: \(path)"
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

    var configurationPaths: [String] { get }
    /// Paths the project's own exclusion rules removed: the topmost excluded
    /// directory or file of each pruned branch, sorted. Built-in skips are
    /// not listed.
    var ruleExcludedPaths: [String] { get }
    /// Supported languages with at least one source file in this snapshot,
    /// sorted by `rawValue`.
    var languages: [LanguageID] { get }
}

public extension Snapshot {
    var projectRootName: String { "." }
    var configurationPaths: [String] { [] }
    var ruleExcludedPaths: [String] { [] }
    var languages: [LanguageID] { detectedLanguages(in: listFiles()) }
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

public final class GitRepository {
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

    func readBlob(oid: git_oid) throws -> [UInt8] {
        try LibGit2Executor.sync {
            var oid = oid
            var blob: OpaquePointer?
            try check(git_blob_lookup(&blob, raw, &oid), "git_blob_lookup")
            guard let blob else { return [] }
            defer { git_blob_free(blob) }

            let count = git_blob_rawsize(blob)
            guard count > 0, let bytes = git_blob_rawcontent(blob) else { return [] }
            return [UInt8](Data(bytes: bytes, count: Int(count)))
        }
    }
}

public final class CommitSnapshot: Snapshot, Sendable {
    private let files: [String: CapturedFile]
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
    /// user's rules do, and excluded blobs are never read.
    public init(
        repositoryURL: URL,
        revision: String = "HEAD",
        pathRules: ProjectPathRules = ProjectPathRules()
    ) throws {
        let loaded: ([String: CapturedFile], GitObjectFormat, GitOID, [String]) =
            try LibGit2Executor.sync {
                let repository = try GitRepository(url: repositoryURL)

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

                var captured: [String: CapturedFile] = [:]
                var excluded: [String] = []
                for entry in collector.entries {
                    if pathRules.verdict(for: entry.path, isDirectory: false, appliesDefaults: false).isExcluded {
                        excluded.append(entry.path)
                        continue
                    }
                    let bytes = if entry.fileMode == .gitlink {
                        Array(entry.oid.hex.utf8)
                    } else {
                        try repository.readBlob(oid: entry.rawOID)
                    }
                    captured[entry.path] = CapturedFile(
                        bytes: bytes,
                        contentID: ContentID.sha256(of: bytes),
                        fileMode: capturedFileMode(bytes, fallback: entry.fileMode)
                    )
                }
                return (
                    captured, repository.objectFormat, oidString(commitID),
                    Self.topmostExcluded(excluded, rules: pathRules)
                )
            }

        snapshotID = SnapshotID(rawValue: UUID())
        objectFormat = loaded.1
        self.revision = revision
        commitOID = loaded.2
        ruleExcludedPaths = loaded.3
        projectRootName = repositoryURL.standardizedFileURL.lastPathComponent
        let capturedFiles = loaded.0
        files = capturedFiles
        configurationPaths = capturedFiles.keys
            .filter { entry in
                guard configurationLanguage(
                    for: URL(fileURLWithPath: entry).lastPathComponent
                ) != nil,
                      capturedFiles[entry]?.fileMode != .symlink
                else { return false }
                return true
            }
            .sorted()
        languages = detectedLanguages(in: capturedFiles.map { ($0.key, $0.value.contentID, $0.value.fileMode) })
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

    public func read(path: String) throws -> Data {
        Data(try readBytes(path: path))
    }

    public func readBytes(path: String) throws -> [UInt8] {
        guard let file = files[path] else { throw GitError.missingPath(path) }
        return file.bytes
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
    private let files: [String: CapturedFile]
    public let ruleExcludedPaths: [String]

    public let snapshotID: SnapshotID
    public let objectFormat: GitObjectFormat
    public let projectRootName: String
    public let configurationPaths: [String]
    public let languages: [LanguageID]
    // A directory import has no per-file Git status in the M1 model, so all
    // captured worktree files retain the existing .untracked convention.
    public let sourceKind: SourceKind = .untracked

    public convenience init(repositoryURL: URL, language: LanguageID) throws {
        try self.init(repositoryURL: repositoryURL, languages: [language])
    }

    public convenience init(
        repositoryURL: URL,
        languages: [LanguageID],
        pathRules: ProjectPathRules = ProjectPathRules()
    ) throws {
        _ = try LanguageMode.normalize(languages: languages)
        try self.init(repositoryURL: repositoryURL, pathRules: pathRules)
    }

    /// A directory that is not itself a Git repository (including a
    /// repository subdirectory: `git_repository_open` does not search
    /// upward) is captured as a plain directory; other Git errors throw.
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

        var captured: [String: CapturedFile] = [:]
        var excluded: [String] = []
        let walked = try ProjectTreeWalk.regularFiles(under: root, rules: pathRules)
        excluded = walked.ruleExcluded
        for file in walked.files {
            let bytes = [UInt8](try Data(contentsOf: file, options: .mappedIfSafe))
            let relative = ProjectTreeWalk.relativePath(of: file, under: root)
            captured[relative] = CapturedFile(
                bytes: bytes,
                contentID: ContentID.sha256(of: bytes),
                fileMode: capturedFileMode(bytes, fallback: .regular)
            )
        }

        snapshotID = SnapshotID(rawValue: UUID())
        objectFormat = repositoryInfo.1
        projectRootName = root.lastPathComponent
        files = captured
        ruleExcludedPaths = excluded
        configurationPaths = captured.keys.filter { entry in
            configurationLanguage(
                for: URL(fileURLWithPath: entry).lastPathComponent
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

    public func read(path: String) throws -> Data {
        Data(try readBytes(path: path))
    }

    public func readBytes(path: String) throws -> [UInt8] {
        guard let file = files[path] else {
            throw GitError.missingPath(path)
        }
        return file.bytes
    }

}

/// The one worktree walk shared by snapshot capture, directory indexing and
/// the file tree: regular non-symlink files, pruned by `ProjectPathRules`.
public enum ProjectTreeWalk {
    public static func regularFiles(
        under root: URL,
        rules: ProjectPathRules
    ) throws -> (files: [URL], ruleExcluded: [String]) {
        var files: [URL] = []
        var excluded: [String] = []
        try walk(root, root: root, rules: rules, files: &files, excluded: &excluded)
        return (files.sorted { $0.path < $1.path }, excluded.sorted())
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
        excluded: inout [String]
    ) throws {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) {
            if url.lastPathComponent == ".DS_Store" { continue }
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true else { continue }
            let isDirectory = values.isDirectory == true
            guard isDirectory || values.isRegularFile == true else { continue }
            let relative = relativePath(of: url, under: root)
            switch rules.verdict(for: relative, isDirectory: isDirectory) {
            case .included:
                if isDirectory {
                    try walk(url, root: root, rules: rules, files: &files, excluded: &excluded)
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

private func configurationLanguage(for name: String) -> LanguageID? {
    switch name {
    case "Cargo.toml", "Cargo.lock":
        return .rust
    case "pyrightconfig.json", "pyproject.toml", "uv.lock":
        return .python
    case "tsconfig.json", "package.json", "bun.lockb":
        return .typescript
    default:
        return nil
    }
}

private struct CapturedFile: Sendable {
    let bytes: [UInt8]
    let contentID: ContentID
    let fileMode: FileMode
}

private let lfsPointerPrefix = Array(
    "version https://git-lfs.github.com/spec".utf8
)

private func capturedFileMode(
    _ bytes: [UInt8],
    fallback: FileMode
) -> FileMode {
    fallback == .regular && bytes.starts(with: lfsPointerPrefix)
        ? .lfsPointer : fallback
}

private struct TreeEntry {
    let path: String
    let oid: GitOID
    let rawOID: git_oid
    let fileMode: FileMode
}

private final class TreeWalkCollector {
    var entries: [TreeEntry] = []
}

private let collectTreeEntry: git_treewalk_cb = { root, entry, payload in
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
