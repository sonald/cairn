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
}

public extension Snapshot {
    var projectRootName: String { "." }
    var configurationPaths: [String] { [] }
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

    public let snapshotID: SnapshotID
    public let objectFormat: GitObjectFormat
    public let sourceKind: SourceKind = .tracked
    public let revision: String
    public let commitOID: GitOID
    public let projectRootName: String
    public let configurationPaths: [String]

    public init(repositoryURL: URL, revision: String = "HEAD") throws {
        let loaded: ([String: CapturedFile], GitObjectFormat, GitOID) =
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
                for entry in collector.entries {
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
                return (captured, repository.objectFormat, oidString(commitID))
            }

        snapshotID = SnapshotID(rawValue: UUID())
        objectFormat = loaded.1
        self.revision = revision
        commitOID = loaded.2
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
}

public final class WorktreeSnapshot: Snapshot, Sendable {
    // Keep synchronized with CodeInsightEngine.ProjectIndexer.skippedDirectories.
    private static let skippedDirectories: Set<String> = [
        ".git", "target", "node_modules", ".build", "venv", ".venv",
        "__pycache__", "dist", "build",
    ]

    private let files: [String: CapturedFile]
    private let configurationFiles: [String: CapturedFile]

    public let snapshotID: SnapshotID
    public let objectFormat: GitObjectFormat
    public let projectRootName: String
    public let configurationPaths: [String]
    // A directory import has no per-file Git status in the M1 model, so all
    // captured worktree files retain the existing .untracked convention.
    public let sourceKind: SourceKind = .untracked

    public convenience init(repositoryURL: URL) throws {
        try self.init(repositoryURL: repositoryURL, language: .rust)
    }

    public convenience init(repositoryURL: URL, language: LanguageID) throws {
        try self.init(repositoryURL: repositoryURL, languages: [language])
    }

    public init(repositoryURL: URL, languages: [LanguageID]) throws {
        let selectedLanguages = try LanguageMode.normalize(languages: languages)
        let repositoryInfo: (URL, GitObjectFormat) = try LibGit2Executor.sync {
            let repository = try GitRepository(url: repositoryURL)
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
        for file in try Self.sourceFiles(
            under: root,
            languages: selectedLanguages
        ) {
            let bytes = [UInt8](try Data(contentsOf: file, options: .mappedIfSafe))
            let relative = Self.relativePath(of: file, under: root)
            captured[relative] = CapturedFile(
                bytes: bytes,
                contentID: ContentID.sha256(of: bytes),
                fileMode: capturedFileMode(bytes, fallback: .regular)
            )
        }

        var configurationFiles: [String: CapturedFile] = [:]
        for file in (try? Self.configurationFiles(under: root,
            selected: selectedLanguages)) ?? [] {
            guard let data = try? Data(contentsOf: file, options: .mappedIfSafe)
            else { continue }
            let bytes = [UInt8](data)
            configurationFiles[Self.relativePath(of: file, under: root)] = CapturedFile(
                bytes: bytes,
                contentID: ContentID.sha256(of: bytes),
                fileMode: .regular
            )
        }

        snapshotID = SnapshotID(rawValue: UUID())
        objectFormat = repositoryInfo.1
        projectRootName = root.lastPathComponent
        files = captured
        self.configurationFiles = configurationFiles
        configurationPaths = configurationFiles.keys.sorted()
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
        guard let file = files[path] ?? configurationFiles[path] else {
            throw GitError.missingPath(path)
        }
        return file.bytes
    }

    private static func sourceFiles(
        under root: URL,
        languages: [LanguageID]
    ) throws -> [URL] {
        var result: [URL] = []
        for url in try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            ]
        ) {
            if url.lastPathComponent == ".DS_Store" { continue }
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            ])
            if values.isDirectory == true {
                guard values.isSymbolicLink != true,
                      !skippedDirectories.contains(url.lastPathComponent)
                else { continue }
                result += try sourceFiles(under: url, languages: languages)
            } else if values.isSymbolicLink != true,
                      values.isRegularFile == true,
                      LanguageMode.classify(path: url.path, languages: languages) != nil
            {
                result.append(url)
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    private static func configurationFiles(
        under root: URL,
        selected: [LanguageID]
    ) throws -> [URL] {
        var result: [URL] = []
        for url in try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            ]
        ) {
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            ])
            if values.isDirectory == true {
                guard values.isSymbolicLink != true,
                      !skippedDirectories.contains(url.lastPathComponent)
                else { continue }
                result += try configurationFiles(under: url, selected: selected)
            } else if values.isSymbolicLink != true,
                      values.isRegularFile == true,
                      configurationLanguage(for: url.lastPathComponent)
                        .map(selected.contains) == true
            {
                result.append(url)
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    private static func relativePath(of file: URL, under root: URL) -> String {
        file.standardizedFileURL.pathComponents
            .dropFirst(root.pathComponents.count)
            .joined(separator: "/")
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
