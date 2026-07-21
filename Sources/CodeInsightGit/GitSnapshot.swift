import CLibGit2
import CodeInsightCore
import Foundation

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

    func listFiles() -> [(path: String, contentID: ContentID, fileMode: FileMode)]
    func readBytes(path: String) throws -> [UInt8]
}

public final class GitRepository {
    let raw: OpaquePointer

    public let objectFormat: GitObjectFormat

    public init(url: URL) throws {
        let initCode = git_libgit2_init()
        guard initCode >= 0 else {
            throw gitError(operation: "git_libgit2_init", code: initCode)
        }

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

            raw = repository
            self.objectFormat = objectFormat
        } catch {
            if let repository { git_repository_free(repository) }
            git_libgit2_shutdown()
            throw error
        }
    }

    deinit {
        git_repository_free(raw)
        git_libgit2_shutdown()
    }

    func readBlob(oid: git_oid) throws -> [UInt8] {
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

public final class CommitSnapshot: Snapshot, Sendable {
    private let files: [String: CapturedFile]

    public let snapshotID: SnapshotID
    public let objectFormat: GitObjectFormat
    public let revision: String
    public let commitOID: GitOID

    public init(repositoryURL: URL, revision: String = "HEAD") throws {
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
            let bytes: [UInt8]
            if entry.fileMode == .gitlink {
                bytes = Array(entry.oid.hex.utf8)
            } else {
                bytes = try repository.readBlob(oid: entry.rawOID)
            }
            captured[entry.path] = CapturedFile(
                bytes: bytes,
                contentID: ContentID.sha256(of: bytes),
                fileMode: entry.fileMode
            )
        }

        snapshotID = SnapshotID(rawValue: UUID())
        objectFormat = repository.objectFormat
        self.revision = revision
        self.commitOID = oidString(commitID)
        files = captured
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

    public let snapshotID: SnapshotID
    public let objectFormat: GitObjectFormat

    public init(repositoryURL: URL) throws {
        let repository = try GitRepository(url: repositoryURL)
        guard let workdir = git_repository_workdir(repository.raw) else {
            throw GitError.notAWorktree(repositoryURL.path)
        }
        let root = URL(
            fileURLWithPath: String(cString: workdir),
            isDirectory: true
        ).standardizedFileURL

        var captured: [String: CapturedFile] = [:]
        for file in try Self.rustFiles(under: root) {
            let bytes = [UInt8](try Data(contentsOf: file, options: .mappedIfSafe))
            captured[Self.relativePath(of: file, under: root)] = CapturedFile(
                bytes: bytes,
                contentID: ContentID.sha256(of: bytes),
                fileMode: .regular
            )
        }

        snapshotID = SnapshotID(rawValue: UUID())
        objectFormat = repository.objectFormat
        files = captured
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

    private static func rustFiles(under root: URL) throws -> [URL] {
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
                result += try rustFiles(under: url)
            } else if values.isRegularFile == true && url.pathExtension == "rs" {
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

private struct CapturedFile: Sendable {
    let bytes: [UInt8]
    let contentID: ContentID
    let fileMode: FileMode
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

private func oidString(_ oid: UnsafePointer<git_oid>) -> GitOID {
    GitOID(hex: String(cString: git_oid_tostr_s(oid)))
}

private func check(_ code: Int32, _ operation: String) throws {
    guard code < 0 else { return }
    throw gitError(operation: operation, code: code)
}

private func gitError(operation: String, code: Int32) -> GitError {
    let message = git_error_last().map { error in
        String(cString: error.pointee.message)
    } ?? "unknown libgit2 error"
    return .git(operation: operation, code: code, message: message)
}
