import CLibGit2
import CodeInsightCore
import Foundation

public enum CheckoutError: Error, Equatable, LocalizedError {
    /// The user repository's object store that the checkout reads through
    /// its alternates is gone (the repository was moved or deleted).
    case sourceObjectsUnavailable(String)
    /// Clearing was refused because checkout directories still belong to
    /// live Exact sessions.
    case directoriesInUse([String])

    public var errorDescription: String? {
        switch self {
        case let .sourceObjectsUnavailable(path):
            return "repository objects not found: \(path)"
        case let .directoriesInUse(paths):
            return "checkout directories in use: \(paths.joined(separator: ", "))"
        }
    }
}

/// Cairn's own working directory for one window: a repository whose
/// `objects/info/alternates` points at the user's object store, so any
/// commit can be checked out here without writing anything into the user's
/// repository. Only regular files (100644/100755) stay on disk; symlinks
/// and gitlinks are removed after every checkout, and no filter (eol, ident,
/// smudge) ever runs, so the bytes match the Git objects the reader shows.
public final class CheckoutRoot: @unchecked Sendable {
    /// The directory language servers see as the project root.
    public let url: URL
    public let sourceRepositoryURL: URL
    private let sourceObjectsPath: String
    private let repository: GitRepository

    public init(directory: URL, source: URL) throws {
        let url = directory.standardizedFileURL
        self.url = url
        sourceRepositoryURL = source.standardizedFileURL
        let objectsPath = try LibGit2Executor.sync {
            let userRepository = try GitRepository(url: source)
            guard let commondir = git_repository_commondir(userRepository.raw) else {
                throw GitError.git(
                    operation: "git_repository_commondir",
                    code: -1,
                    message: "returned no common directory"
                )
            }
            return URL(fileURLWithPath: String(cString: commondir), isDirectory: true)
                .appendingPathComponent("objects", isDirectory: true)
                .standardizedFileURL.path
        }
        sourceObjectsPath = objectsPath
        guard FileManager.default.fileExists(atPath: objectsPath) else {
            throw CheckoutError.sourceObjectsUnavailable(objectsPath)
        }

        let gitDirectory: URL = try LibGit2Executor.sync {
            var repository: OpaquePointer?
            try url.withUnsafeFileSystemRepresentation { path in
                try check(git_repository_init(&repository, path, 0), "git_repository_init")
            }
            guard let repository else {
                throw GitError.git(
                    operation: "git_repository_init",
                    code: -1,
                    message: "returned no repository"
                )
            }
            defer { git_repository_free(repository) }

            var config: OpaquePointer?
            try check(git_repository_config(&config, repository), "git_repository_config")
            guard let config else {
                throw GitError.git(
                    operation: "git_repository_config",
                    code: -1,
                    message: "returned no config"
                )
            }
            defer { git_config_free(config) }
            try check(git_config_set_bool(config, "core.autocrlf", 0), "git_config_set_bool")
            try check(git_config_set_bool(config, "core.symlinks", 0), "git_config_set_bool")

            guard let path = git_repository_path(repository) else {
                throw GitError.git(
                    operation: "git_repository_path",
                    code: -1,
                    message: "returned no path"
                )
            }
            return URL(fileURLWithPath: String(cString: path), isDirectory: true)
        }

        // Alternates and attributes are plain files; libgit2 reads both on
        // the next open, so the repository is reopened afterwards.
        let objectsInfo = gitDirectory.appendingPathComponent("objects/info", isDirectory: true)
        try FileManager.default.createDirectory(at: objectsInfo, withIntermediateDirectories: true)
        try Data((objectsPath + "\n").utf8).write(
            to: objectsInfo.appendingPathComponent("alternates")
        )
        let info = gitDirectory.appendingPathComponent("info", isDirectory: true)
        try FileManager.default.createDirectory(at: info, withIntermediateDirectories: true)
        try Data("* -text -eol -filter -ident\n".utf8).write(
            to: info.appendingPathComponent("attributes")
        )
        repository = try GitRepository(url: url)
    }

    /// Makes the directory hold exactly `commit`'s regular files. The
    /// current HEAD is the baseline, so only changed paths are rewritten;
    /// untracked files that are not in the way are left alone.
    public func checkout(commit: GitOID) throws {
        guard FileManager.default.fileExists(atPath: sourceObjectsPath) else {
            throw CheckoutError.sourceObjectsUnavailable(sourceObjectsPath)
        }
        let specialPaths: [(path: String, fileMode: FileMode)] = try LibGit2Executor.sync {
            var object: OpaquePointer?
            try commit.hex.withCString { spec in
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
            var peeled: OpaquePointer?
            try check(git_object_peel(&peeled, object, GIT_OBJECT_COMMIT), "git_object_peel(commit)")
            guard let peeled, let oid = git_object_id(peeled) else {
                throw GitError.git(
                    operation: "git_object_peel(commit)",
                    code: -1,
                    message: "returned no commit"
                )
            }
            defer { git_object_free(peeled) }

            var options = git_checkout_options()
            try check(
                git_checkout_options_init(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)),
                "git_checkout_options_init"
            )
            options.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue
            try check(git_checkout_tree(repository.raw, peeled, &options), "git_checkout_tree")
            try check(
                git_repository_set_head_detached(repository.raw, oid),
                "git_repository_set_head_detached"
            )

            var tree: OpaquePointer?
            try check(git_commit_tree(&tree, peeled), "git_commit_tree")
            guard let tree else { return [] }
            defer { git_tree_free(tree) }
            let collector = TreeWalkCollector()
            let payload = Unmanaged.passUnretained(collector).toOpaque()
            try check(
                git_tree_walk(tree, GIT_TREEWALK_PRE, collectTreeEntry, payload),
                "git_tree_walk"
            )
            return collector.entries
                .filter { $0.fileMode == .symlink || $0.fileMode == .gitlink }
                .map { ($0.path, $0.fileMode) }
        }
        // FORCE recreates missing baseline entries, so this runs after
        // every checkout: with core.symlinks off a link lands as a plain
        // file holding its target, and a gitlink as an empty directory.
        for entry in specialPaths {
            var path = entry.path.split(separator: "/").reduce(url) {
                $0.appendingPathComponent(String($1))
            }
            guard FileManager.default.fileExists(atPath: path.path) else { continue }
            try FileManager.default.removeItem(at: path)
            // Like checkout's own removals, drop the directories this emptied.
            path = path.deletingLastPathComponent()
            while path.standardizedFileURL != url,
                  try FileManager.default.contentsOfDirectory(atPath: path.path).isEmpty
            {
                try FileManager.default.removeItem(at: path)
                path = path.deletingLastPathComponent()
            }
        }
    }

    /// Deletes the directory. The libgit2 handle is released on deinit.
    public func remove() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

/// The application's checkout parent: one directory per window owner,
/// deleted when the window closes. Directories left behind by an earlier
/// process (crash, forced quit) are removed at launch, when nothing owns
/// them yet.
public final class CheckoutStore: @unchecked Sendable {
    public let parentURL: URL
    private let lock = NSLock()
    private var roots: [UUID: CheckoutRoot] = [:]
    private var maintenanceDepth = 0

    public init(parentURL: URL? = nil) {
        self.parentURL = (parentURL ?? Self.defaultParentURL).standardizedFileURL
    }

    public static var defaultParentURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport.appendingPathComponent(
            "CodeInsight/checkouts",
            isDirectory: true
        )
    }

    public func directory(for owner: UUID) -> URL {
        parentURL.appendingPathComponent(owner.uuidString, isDirectory: true)
    }

    /// The owner's checkout root for `source`, created on first use. A
    /// root built for another repository is replaced.
    public func root(owner: UUID, source: URL) throws -> CheckoutRoot {
        lock.lock()
        defer { lock.unlock() }
        if let existing = roots[owner],
           existing.sourceRepositoryURL == source.standardizedFileURL
        {
            return existing
        }
        try roots.removeValue(forKey: owner)?.remove()
        let directory = directory(for: owner)
        try? FileManager.default.removeItem(at: directory)
        let root = try CheckoutRoot(directory: directory, source: source)
        roots[owner] = root
        return root
    }

    /// Deletes the owner's directory; a no-op for owners without one.
    public func release(owner: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        try roots.removeValue(forKey: owner)?.remove()
    }

    public var liveDirectoryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return roots.count
    }

    public func liveDirectories() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return roots.values.map(\.url).sorted { $0.path < $1.path }
    }

    /// Deletes every checkout directory. Refused while any owner still
    /// holds one: its language server may be reading it.
    public func removeAll() throws {
        lock.lock()
        defer { lock.unlock() }
        let inUse = roots.values.map(\.url.path).sorted()
        guard inUse.isEmpty else { throw CheckoutError.directoriesInUse(inUse) }
        guard FileManager.default.fileExists(atPath: parentURL.path) else { return }
        try FileManager.default.removeItem(at: parentURL)
    }

    /// Launch cleanup: deletes directories no owner in this process holds.
    public func removeUnowned() {
        lock.lock()
        defer { lock.unlock() }
        let owned = Set(roots.values.map(\.url.path))
        let children = (try? FileManager.default.contentsOfDirectory(
            at: parentURL,
            includingPropertiesForKeys: nil
        )) ?? []
        for child in children where !owned.contains(child.standardizedFileURL.path) {
            try? FileManager.default.removeItem(at: child)
        }
    }

    /// Bytes on disk under the parent, for the settings page.
    public func totalSize() -> UInt64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: parentURL,
            includingPropertiesForKeys: keys
        ) else { return 0 }
        var result: UInt64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { continue }
            result += UInt64(values.fileSize ?? 0)
        }
        return result
    }

    // MARK: - Maintenance

    /// True while an application-level clear is stopping sessions and
    /// deleting directories; coordinators refuse new prepares meanwhile so
    /// no fresh session can claim a directory mid-deletion.
    public var isUnderMaintenance: Bool {
        lock.lock()
        defer { lock.unlock() }
        return maintenanceDepth > 0
    }

    public func beginMaintenance() {
        lock.lock()
        defer { lock.unlock() }
        maintenanceDepth += 1
    }

    public func endMaintenance() {
        lock.lock()
        defer { lock.unlock() }
        maintenanceDepth = max(0, maintenanceDepth - 1)
    }
}
