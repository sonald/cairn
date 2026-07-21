import CodeInsightGit
import Foundation
import Observation

@MainActor
@Observable
public final class CommitPickerModel {
    typealias Loader = @Sendable (URL) async throws -> [CommitInfo]

    public private(set) var commits: [CommitInfo]
    public private(set) var filteredCommits: [CommitInfo]
    public private(set) var query = ""
    public private(set) var currentRevision: String?
    public private(set) var currentCommit: CommitInfo?
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?

    private let loader: Loader
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var loadGeneration: UInt64 = 0

    public init() {
        commits = []
        filteredCommits = []
        loader = ProjectIndexService.loadCommitHistory
    }

    init(commits: [CommitInfo]) {
        self.commits = commits
        filteredCommits = commits
        loader = { _ in commits }
    }

    public func load(repositoryURL: URL) {
        loadTask?.cancel()
        loadGeneration &+= 1
        let generation = loadGeneration
        isLoading = true
        errorMessage = nil
        commits = []
        applyFilter()
        let loader = loader
        loadTask = Task { [weak self] in
            do {
                let commits = try await loader(repositoryURL)
                guard let self,
                      !Task.isCancelled,
                      loadGeneration == generation
                else { return }
                self.commits = commits
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

    public func setQuery(_ query: String) {
        self.query = query
        applyFilter()
    }

    public func setCurrentRevision(_ revision: String?) {
        currentRevision = revision
        updateCurrentCommit()
    }

    private func applyFilter() {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !needle.isEmpty else {
            filteredCommits = commits
            return
        }
        filteredCommits = commits.filter {
            $0.fullSHA.lowercased().hasPrefix(needle)
                || $0.summary.lowercased().contains(needle)
        }
    }

    private func updateCurrentCommit() {
        guard let revision = currentRevision?.lowercased() else {
            currentCommit = nil
            return
        }
        currentCommit = commits.first {
            $0.fullSHA.lowercased() == revision
                || $0.shortSHA.lowercased() == revision
        }
    }
}
