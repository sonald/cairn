import CLibGit2
import Foundation

public struct BlameHunk: Equatable, Sendable {
    /// 1-based line numbers in the blamed content (the working-tree bytes when given).
    public let lines: ClosedRange<Int>
    /// nil = not committed (changed in the working tree, or the file is untracked).
    public let commit: CommitInfo?

    public init(lines: ClosedRange<Int>, commit: CommitInfo?) {
        self.lines = lines
        self.commit = commit
    }
}

public enum GitBlame {
    /// Runs libgit2's one-time setup on the serial executor once; blames
    /// themselves never wait on that queue.
    private static let initialized = Result { try LibGit2Executor.sync {} }

    /// `path` is repository-relative with "/" separators.
    /// `revision == nil` means the working tree: blame HEAD, then overlay `workingTreeBytes`
    /// with git_blame_buffer so lines changed since HEAD come back with `commit == nil`.
    /// An untracked file (not in HEAD) returns one hunk covering all lines with commit nil.
    /// A commit revision blames that commit (newest_commit) and ignores workingTreeBytes.
    ///
    /// Blaming a long history is slow, so this opens its own repository
    /// handle and runs on the caller's thread instead of the shared libgit2
    /// queue; separate handles may be used concurrently.
    public static func blame(
        repositoryURL: URL,
        path: String,
        revision: String?,
        workingTreeBytes: [UInt8]?
    ) throws -> [BlameHunk] {
        try initialized.get()

        var opened: OpaquePointer?
        try repositoryURL.withUnsafeFileSystemRepresentation { fsPath in
            try check(git_repository_open(&opened, fsPath), "git_repository_open")
        }
        guard let repository = opened else {
            throw GitError.git(operation: "git_repository_open", code: -1, message: "returned no repository")
        }
        defer { git_repository_free(repository) }

        let bytes = revision == nil ? workingTreeBytes : nil
        if bytes?.isEmpty == true { return [] }
        guard let commit = try commit(revision ?? "HEAD", in: repository, unbornIsNil: revision == nil) else {
            return uncommitted(bytes)
        }
        defer { git_commit_free(commit) }
        guard try contains(path, commit: commit) else {
            if revision != nil { throw GitError.missingPath(path) }
            return uncommitted(bytes)
        }

        var options = git_blame_options()
        try check(git_blame_options_init(&options, UInt32(GIT_BLAME_OPTIONS_VERSION)), "git_blame_options_init")
        options.newest_commit = git_commit_id(commit).pointee

        var base: OpaquePointer?
        try check(git_blame_file(&base, repository, path, &options), "git_blame_file")
        guard let base else { return [] }
        defer { git_blame_free(base) }

        var blame = base
        var overlay: OpaquePointer?
        defer { if let overlay { git_blame_free(overlay) } }
        if let bytes {
            try bytes.withUnsafeBufferPointer { buffer in
                try buffer.withMemoryRebound(to: CChar.self) { chars in
                    try check(git_blame_buffer(&overlay, base, chars.baseAddress, chars.count), "git_blame_buffer")
                }
            }
            if let overlay { blame = overlay }
        }

        // ponytail: paint one slot per line, then run-length encode, so the
        // result covers every line exactly once whatever libgit2's hunk edges.
        var raw: [(start: Int, count: Int, oid: git_oid?)] = []
        for index in 0..<git_blame_hunkcount(blame) {
            guard let hunk = git_blame_hunk_byindex(blame, index)?.pointee else { continue }
            var oid = hunk.final_commit_id
            raw.append((Int(hunk.final_start_line_number), Int(hunk.lines_in_hunk), git_oid_is_zero(&oid) == 1 ? nil : oid))
        }
        let lineCount = bytes.map(countLines) ?? raw.map { $0.start + $0.count - 1 }.max() ?? 0
        guard lineCount > 0 else { return [] }

        var lines = [String?](repeating: nil, count: lineCount)
        var commits: [String: CommitInfo] = [:]
        for hunk in raw {
            var sha: String?
            if var oid = hunk.oid {
                let key = oidString(&oid).hex
                if commits[key] == nil { commits[key] = try info(of: &oid, in: repository) }
                sha = key
            }
            let start = max(hunk.start, 1)
            let end = min(hunk.start + hunk.count - 1, lineCount)
            guard start <= end else { continue }
            for line in start...end { lines[line - 1] = sha }
        }

        var hunks: [BlameHunk] = []
        var runStart = 1
        for line in 2...(lineCount + 1) where line > lineCount || lines[line - 1] != lines[runStart - 1] {
            hunks.append(BlameHunk(lines: runStart...(line - 1), commit: lines[runStart - 1].flatMap { commits[$0] }))
            runStart = line
        }
        return hunks
    }

    private static func uncommitted(_ bytes: [UInt8]?) -> [BlameHunk] {
        let count = bytes.map(countLines) ?? 0
        return count > 0 ? [BlameHunk(lines: 1...count, commit: nil)] : []
    }

    private static func countLines(_ bytes: [UInt8]) -> Int {
        let newlines = bytes.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        return newlines + (bytes.last.map { $0 == 0x0A ? 0 : 1 } ?? 0)
    }

    /// The commit a revision names; nil only for an unborn HEAD when allowed.
    private static func commit(_ revision: String, in repository: OpaquePointer, unbornIsNil: Bool) throws -> OpaquePointer? {
        var object: OpaquePointer?
        let code = revision.withCString { git_revparse_single(&object, repository, $0) }
        if unbornIsNil, code == GIT_ENOTFOUND.rawValue || code == GIT_EUNBORNBRANCH.rawValue {
            return nil
        }
        try check(code, "git_revparse_single")
        guard let object else {
            throw GitError.git(operation: "git_revparse_single", code: -1, message: "returned no object")
        }
        defer { git_object_free(object) }
        var commit: OpaquePointer?
        try check(git_object_peel(&commit, object, GIT_OBJECT_COMMIT), "git_object_peel(commit)")
        return commit
    }

    private static func contains(_ path: String, commit: OpaquePointer) throws -> Bool {
        var tree: OpaquePointer?
        try check(git_commit_tree(&tree, commit), "git_commit_tree")
        defer { git_tree_free(tree) }
        var entry: OpaquePointer?
        let code = git_tree_entry_bypath(&entry, tree, path)
        if code == GIT_ENOTFOUND.rawValue { return false }
        try check(code, "git_tree_entry_bypath")
        defer { git_tree_entry_free(entry) }
        return git_tree_entry_type(entry) == GIT_OBJECT_BLOB
    }

    private static func info(of oid: UnsafePointer<git_oid>, in repository: OpaquePointer) throws -> CommitInfo {
        var commit: OpaquePointer?
        try check(git_commit_lookup(&commit, repository, oid), "git_commit_lookup")
        defer { git_commit_free(commit) }
        let fullSHA = oidString(oid).hex
        let author = git_commit_author(commit)
        return CommitInfo(
            shortSHA: String(fullSHA.prefix(7)),
            fullSHA: fullSHA,
            summary: git_commit_summary(commit).map(String.init(cString:)) ?? "",
            authorName: author.map { String(cString: $0.pointee.name) } ?? "",
            date: Date(timeIntervalSince1970: TimeInterval(author?.pointee.when.time ?? git_commit_time(commit)))
        )
    }
}
