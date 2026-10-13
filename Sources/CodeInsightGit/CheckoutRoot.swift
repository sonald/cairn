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
    /// Held (flock) for the life of this object so another Cairn process
    /// — a packaged self-test beside the running app — never mistakes the
    /// directory for a leftover and deletes it.
    private var lockDescriptor: Int32 = -1

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
        lockDescriptor = open(Self.lockPath(for: url), O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard lockDescriptor >= 0, flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            if lockDescriptor >= 0 { close(lockDescriptor) }
            lockDescriptor = -1
            throw CheckoutError.directoriesInUse([url.path])
        }
    }

    deinit {
        if lockDescriptor >= 0 { close(lockDescriptor) }
    }

    static func lockPath(for directory: URL) -> String {
        directory.appendingPathComponent(".git/cairn.lock").path
    }

    /// True while a live `CheckoutRoot` (this process or another) holds the
    /// directory's lock.
    static func isHeld(_ directory: URL) -> Bool {
        let descriptor = open(lockPath(for: directory), O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        return flock(descriptor, LOCK_EX | LOCK_NB) != 0
    }

    /// Symlinks this checkout holds into the user's workspace, borrowing
    /// ignored dependency directories (`node_modules`, a configured venv),
    /// by checkout-relative path → workspace directory.
    public private(set) var borrowedLinks: [String: URL] = [:]

    /// Makes the directory hold exactly `commit`'s regular files. The
    /// current HEAD is the baseline, so only changed paths are rewritten;
    /// untracked files that are not in the way are left alone.
    ///
    /// `links` is the borrowed-link set wanted for this commit. Links no
    /// longer wanted, pointing elsewhere, or sitting on a path the commit
    /// tracks are removed *before* the checkout, so it never writes through
    /// a link into the workspace; the rest are created afterwards where the
    /// parent directory exists and nothing occupies the path (tracked
    /// content wins).
    public func checkout(commit: GitOID, links: [String: URL] = [:]) throws {
        guard FileManager.default.fileExists(atPath: sourceObjectsPath) else {
            throw CheckoutError.sourceObjectsUnavailable(sourceObjectsPath)
        }
        var wanted: [String: URL] = [:]
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

            var entries: [TreeEntry] = []
            var tree: OpaquePointer?
            try check(git_commit_tree(&tree, peeled), "git_commit_tree")
            if let tree {
                defer { git_tree_free(tree) }
                let collector = TreeWalkCollector()
                let payload = Unmanaged.passUnretained(collector).toOpaque()
                try check(
                    git_tree_walk(tree, GIT_TREEWALK_PRE, collectTreeEntry, payload),
                    "git_tree_walk"
                )
                entries = collector.entries
            }
            // Every tracked path and its ancestors.
            var tracked = Set<String>()
            for entry in entries {
                var path = Substring(entry.path)
                tracked.insert(String(path))
                while let slash = path.lastIndex(of: "/") {
                    path = path[..<slash]
                    tracked.insert(String(path))
                }
            }
            // A link needs its parent directory in the commit; it must
            // not stand where the commit puts its own content.
            wanted = links.filter { path, _ in
                let parent = path.split(separator: "/").dropLast().joined(separator: "/")
                return !tracked.contains(path) && (parent.isEmpty || tracked.contains(parent))
            }
            for (path, destination) in borrowedLinks where wanted[path] != destination {
                try unlinkBorrowed(path)
            }

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
            return entries
                .filter { $0.fileMode == .symlink || $0.fileMode == .gitlink }
                .map { ($0.path, $0.fileMode) }
        }
        // FORCE recreates missing baseline entries, so this runs after
        // every checkout: with core.symlinks off a link lands as a plain
        // file holding its target, and a gitlink as an empty directory.
        for entry in specialPaths {
            let path = fileURL(entry.path)
            guard FileManager.default.fileExists(atPath: path.path) else { continue }
            try FileManager.default.removeItem(at: path)
            try removeEmptyParents(of: path)
        }
        for (path, destination) in wanted.sorted(by: { $0.key < $1.key })
            where borrowedLinks[path] == nil
        {
            let link = fileURL(path)
            guard isRealDirectory(link.deletingLastPathComponent()),
                  !occupied(link)
            else { continue }
            try FileManager.default.createSymbolicLink(
                atPath: link.path,
                withDestinationPath: destination.path
            )
            borrowedLinks[path] = destination
        }
    }

    private func fileURL(_ relative: String) -> URL {
        relative.split(separator: "/").reduce(url) {
            $0.appendingPathComponent(String($1))
        }
    }

    /// Removes the link itself, never what it points at, and the
    /// directories its removal emptied.
    private func unlinkBorrowed(_ path: String) throws {
        borrowedLinks[path] = nil
        let link = fileURL(path)
        var status = stat()
        guard lstat(link.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFLNK
        else { return }
        guard unlink(link.path) == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: link.path])
        }
        try removeEmptyParents(of: link)
    }

    /// Like checkout's own removals, drops the directories that became empty.
    private func removeEmptyParents(of removed: URL) throws {
        var path = removed.deletingLastPathComponent()
        while path.standardizedFileURL != url,
              try FileManager.default.contentsOfDirectory(atPath: path.path).isEmpty
        {
            try FileManager.default.removeItem(at: path)
            path = path.deletingLastPathComponent()
        }
    }

    private func occupied(_ file: URL) -> Bool {
        var status = stat()
        return lstat(file.path, &status) == 0
    }

    /// True for a directory reached from the checkout root without passing
    /// through a symlink, so a new link never lands inside the workspace.
    private func isRealDirectory(_ directory: URL) -> Bool {
        var current = directory.standardizedFileURL
        while current != url {
            var status = stat()
            guard lstat(current.path, &status) == 0,
                  status.st_mode & S_IFMT == S_IFDIR
            else { return false }
            current = current.deletingLastPathComponent().standardizedFileURL
        }
        return true
    }

    /// Deletes the directory. The libgit2 handle is released on deinit.
    public func remove() throws {
        if lockDescriptor >= 0 {
            close(lockDescriptor)
            lockDescriptor = -1
        }
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

    /// Deletes every checkout directory. Refused while any live root — in
    /// this process or another — still holds one: its language server may
    /// be reading it.
    public func removeAll() throws {
        lock.lock()
        defer { lock.unlock() }
        let inUse = children().filter(CheckoutRoot.isHeld).map(\.path).sorted()
        guard inUse.isEmpty else { throw CheckoutError.directoriesInUse(inUse) }
        guard FileManager.default.fileExists(atPath: parentURL.path) else { return }
        try FileManager.default.removeItem(at: parentURL)
    }

    /// Launch cleanup: deletes directories no live root holds.
    public func removeUnowned() {
        lock.lock()
        defer { lock.unlock() }
        for child in children() where !CheckoutRoot.isHeld(child) {
            try? FileManager.default.removeItem(at: child)
        }
    }

    private func children() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: parentURL,
            includingPropertiesForKeys: nil
        )) ?? []).map(\.standardizedFileURL)
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
