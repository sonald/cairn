import CodeInsightGit
import Foundation
import Observation

@MainActor
@Observable
public final class CommitPickerModel {
    typealias Loader = @Sendable (URL, _ after: String?) async throws -> CommitLog
    typealias Resolver = @Sendable (URL, _ revision: String) async -> CommitInfo?

    public private(set) var commits: [CommitInfo]
    public private(set) var filteredCommits: [CommitInfo]
    public private(set) var query = ""
    /// The commit the repository resolves the query to when no loaded commit
    /// matches; shown above the list.
    public private(set) var resolvedCommit: CommitInfo?
    public private(set) var currentRevision: String?
    public private(set) var currentCommit: CommitInfo?
    public private(set) var currentBranchName: String?
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    public private(set) var hasMore = false
    public private(set) var isLoadingMore = false
    public private(set) var loadMoreError: String?

    private let loader: Loader
    private let resolver: Resolver
    @ObservationIgnored private var repositoryURL: URL?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var loadGeneration: UInt64 = 0
    @ObservationIgnored private var resolveTask: Task<Void, Never>?
    @ObservationIgnored private var queryGeneration: UInt64 = 0

    public convenience init() {
        self.init(pageSize: 500)
    }

    init(pageSize: Int) {
        commits = []
        filteredCommits = []
        loader = { url, after in
            try await Task.detached {
                try CommitLog(repositoryURL: url, after: after, pageSize: pageSize)
            }.value
        }
        resolver = { url, revision in
            await Task.detached { CommitLog.resolve(repositoryURL: url, revision: revision) }.value
        }
    }

    init(
        commits: [CommitInfo],
        resolver: @escaping @Sendable (String) async -> CommitInfo? = { _ in nil }
    ) {
        self.commits = commits
        filteredCommits = commits
        loader = { _, _ in CommitLog(commits: commits, hasMore: false) }
        self.resolver = { _, revision in await resolver(revision) }
        repositoryURL = URL(fileURLWithPath: "/")
    }

    public func load(repositoryURL: URL) {
        loadTask?.cancel()
        loadGeneration &+= 1
        let generation = loadGeneration
        self.repositoryURL = repositoryURL
        isLoading = true
        errorMessage = nil
        commits = []
        hasMore = false
        isLoadingMore = false
        loadMoreError = nil
        currentBranchName = nil
        applyFilter()
        let loader = loader
        loadTask = Task { [weak self] in
            do {
                let log = try await loader(repositoryURL, nil)
                let branchName = await Task.detached {
                    CodeInsightGit.currentBranchName(repositoryURL: repositoryURL)
                }.value
                guard let self,
                      !Task.isCancelled,
                      loadGeneration == generation
                else { return }
                commits = log.commits
                hasMore = log.hasMore
                currentBranchName = branchName
                isLoading = false
                applyFilter()
                updateCurrentCommit()
            } catch is CancellationError {
                return
            } catch {
                guard let self, loadGeneration == generation else { return }
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Appends the next page of first-parent history.
    public func loadMore() {
        guard hasMore, !isLoading, !isLoadingMore,
              let repositoryURL, let last = commits.last?.fullSHA
        else { return }
        let generation = loadGeneration
        isLoadingMore = true
        loadMoreError = nil
        let loader = loader
        Task { [weak self] in
            do {
                let log = try await loader(repositoryURL, last)
                guard let self, loadGeneration == generation else { return }
                commits += log.commits
                hasMore = log.hasMore
                isLoadingMore = false
                applyFilter()
                updateCurrentCommit()
            } catch {
                guard let self, loadGeneration == generation else { return }
                isLoadingMore = false
                loadMoreError = error.localizedDescription
            }
        }
    }

    public func setQuery(_ query: String) {
        self.query = query
        applyFilter()
    }

    public func setCurrentRevision(_ revision: String?) {
        currentRevision = revision
        updateCurrentCommit()
    }

    private func applyFilter() {
        queryGeneration &+= 1
        resolveTask?.cancel()
        resolvedCommit = nil
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !needle.isEmpty else {
            filteredCommits = commits
            // Keep the current commit visible (and highlighted) when it lies
            // beyond the loaded pages, e.g. after a direct `HEAD~600` hit.
            if let currentCommit, !commits.contains(currentCommit) {
                filteredCommits.insert(currentCommit, at: 0)
            }
            return
        }
        filteredCommits = commits.filter {
            $0.fullSHA.lowercased().hasPrefix(needle)
                || $0.summary.lowercased().contains(needle)
                || $0.branchNames.contains { $0.lowercased().contains(needle) }
                || $0.tagNames.contains { $0.lowercased().contains(needle) }
        }
        guard filteredCommits.isEmpty, let repositoryURL else { return }
        let generation = queryGeneration
        let resolver = resolver
        let revision = query.trimmingCharacters(in: .whitespacesAndNewlines)
        resolveTask = Task { [weak self] in
            let commit = await resolver(repositoryURL, revision)
            guard let self, !Task.isCancelled, queryGeneration == generation else { return }
            resolvedCommit = commit
        }
    }

    private func updateCurrentCommit() {
        guard let revision = currentRevision?.lowercased() else {
            currentCommit = nil
            return
        }
        func matches(_ commit: CommitInfo) -> Bool {
            commit.fullSHA.lowercased() == revision || commit.shortSHA.lowercased() == revision
        }
        // A commit chosen through the resolved row is not in `commits`; keep
        // what we already know about it instead of degrading to a bare SHA.
        currentCommit = commits.first(where: matches)
            ?? [resolvedCommit, currentCommit].compactMap { $0 }.first(where: matches)
        if query.isEmpty { applyFilter() }
    }
}
