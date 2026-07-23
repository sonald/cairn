import CLibGit2
import Foundation

public struct CommitInfo: Equatable, Hashable, Sendable {
    public let shortSHA: String
    public let fullSHA: String
    public let summary: String
    public let authorName: String
    public let date: Date
    public let branchNames: [String]
    public let tagNames: [String]

    public init(
        shortSHA: String,
        fullSHA: String,
        summary: String,
        authorName: String,
        date: Date,
        branchNames: [String] = [],
        tagNames: [String] = []
    ) {
        self.shortSHA = shortSHA
        self.fullSHA = fullSHA
        self.summary = summary
        self.authorName = authorName
        self.date = date
        self.branchNames = branchNames
        self.tagNames = tagNames
    }
}

public func currentBranchName(repositoryURL: URL) -> String? {
    try? LibGit2Executor.sync {
        let repository = try GitRepository(url: repositoryURL)
        var head: OpaquePointer?
        let code = git_repository_head(&head, repository.raw)
        if code == GIT_ENOTFOUND.rawValue || code == GIT_EUNBORNBRANCH.rawValue {
            return nil
        }
        try check(code, "git_repository_head")
        guard let head else { return nil }
        defer { git_reference_free(head) }

        let detached = git_repository_head_detached(repository.raw)
        if detached < 0 {
            try check(detached, "git_repository_head_detached")
        }
        if detached == 1 { return "detached" }
        return git_reference_shorthand(head).map(String.init(cString:))
    }
}

public struct CommitLog: Sendable {
    public let commits: [CommitInfo]

    public init(repositoryURL: URL) throws {
        commits = try LibGit2Executor.sync {
            let repository = try GitRepository(url: repositoryURL)
            let references = try Self.referencesByCommit(in: repository)

            var walk: OpaquePointer?
            try check(git_revwalk_new(&walk, repository.raw), "git_revwalk_new")
            guard let walk else {
                throw GitError.git(
                    operation: "git_revwalk_new",
                    code: -1,
                    message: "returned no revwalk"
                )
            }
            defer { git_revwalk_free(walk) }
            try check(git_revwalk_push_head(walk), "git_revwalk_push_head")
            try check(
                git_revwalk_simplify_first_parent(walk),
                "git_revwalk_simplify_first_parent"
            )

            var commits: [CommitInfo] = []
            var oid = git_oid()
            // ponytail: M3 caps history at 500; add paged revwalk state only when
            // repositories with deeper useful history require it.
            while commits.count < 500 {
                let code = git_revwalk_next(&oid, walk)
                if code == GIT_ITEROVER.rawValue { break }
                try check(code, "git_revwalk_next")

                var commit: OpaquePointer?
                try check(
                    git_commit_lookup(&commit, repository.raw, &oid),
                    "git_commit_lookup"
                )
                guard let commit else { continue }
                defer { git_commit_free(commit) }

                let fullSHA = withUnsafePointer(to: &oid) { oidString($0).hex }
                let labels = references[fullSHA] ?? (branches: [], tags: [])
                commits.append(CommitInfo(
                    shortSHA: String(fullSHA.prefix(7)),
                    fullSHA: fullSHA,
                    summary: git_commit_summary(commit).map(String.init(cString:)) ?? "",
                    authorName: git_commit_author(commit).map {
                        String(cString: $0.pointee.name)
                    } ?? "",
                    date: Date(timeIntervalSince1970: TimeInterval(git_commit_time(commit))),
                    branchNames: labels.branches,
                    tagNames: labels.tags
                ))
            }
            return commits
        }
    }

    private static func referencesByCommit(
        in repository: GitRepository
    ) throws -> [String: (branches: [String], tags: [String])] {
        var iterator: OpaquePointer?
        try check(
            git_reference_iterator_new(&iterator, repository.raw),
            "git_reference_iterator_new"
        )
        guard let iterator else { return [:] }
        defer { git_reference_iterator_free(iterator) }

        var result: [String: (branches: [String], tags: [String])] = [:]
        while true {
            var reference: OpaquePointer?
            let code = git_reference_next(&reference, iterator)
            if code == GIT_ITEROVER.rawValue { break }
            try check(code, "git_reference_next")
            guard let reference else { continue }
            defer { git_reference_free(reference) }

            guard let rawName = git_reference_name(reference) else { continue }
            let fullName = String(cString: rawName)
            let isBranch = fullName.hasPrefix("refs/heads/")
            let isTag = fullName.hasPrefix("refs/tags/")
            guard isBranch || isTag else { continue }

            var object: OpaquePointer?
            guard git_reference_peel(&object, reference, GIT_OBJECT_COMMIT) == 0,
                  let object,
                  let oid = git_object_id(object)
            else { continue }
            defer { git_object_free(object) }

            let name = git_reference_shorthand(reference)
                .map(String.init(cString:)) ?? fullName
            let sha = oidString(oid).hex
            var labels = result[sha] ?? (branches: [], tags: [])
            if isBranch {
                labels.branches.append(name)
            } else {
                labels.tags.append(name)
            }
            result[sha] = labels
        }

        return result.mapValues {
            (branches: $0.branches.sorted(), tags: $0.tags.sorted())
        }
    }
}
