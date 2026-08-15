import CodeInsightCore
import CodeInsightEngine
import Foundation
import Observation

@MainActor
@Observable
public final class SearchPanelModel {
    public static let displayLimit = 2_000

    public final class Match: Sendable {
        public let value: SearchMatch

        fileprivate init(_ value: SearchMatch) {
            self.value = value
        }
    }

    public final class Group {
        public let pathID: PathID
        public let path: String
        public fileprivate(set) var matches: [Match]

        fileprivate init(pathID: PathID, path: String, matches: [Match]) {
            self.pathID = pathID
            self.path = path
            self.matches = matches
        }
    }

    typealias Searcher = @Sendable (
        EngineSession,
        ContentSearchQuery,
        QueryContext
    ) async throws -> AsyncThrowingStream<SearchBatch, Error>

    public private(set) var query = ""
    public private(set) var groups: [Group] = []
    public private(set) var placeholder = "Open a project to search."
    public private(set) var isSearching = false
    public private(set) var totalMatches = 0
    public private(set) var fileCount = 0
    /// Whether the search service itself returned incomplete results.
    public private(set) var isTruncated = false
    public private(set) var displayTruncationMessage: String?
    public private(set) var selectedIndex: Int?
    public private(set) var requestID: UInt64 = 0
    public private(set) var isCaseSensitive = false
    public private(set) var isRegex = false

    public var displayedMatchCount: Int {
        min(totalMatches, Self.displayLimit)
    }

    private let searcher: Searcher
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var workspaceSessions: [(EngineSession, QueryContext)] = []
    @ObservationIgnored private var projectState = ProjectState.empty
    @ObservationIgnored private var groupsByPath: [PathID: Group] = [:]
    @ObservationIgnored private var matchedPathIDs: Set<PathID> = []

    public init() {
        searcher = { session, query, context in
            try session.search(query, context: context)
        }
    }

    init(searcher: @escaping Searcher) {
        self.searcher = searcher
    }

    deinit {
        searchTask?.cancel()
    }

    public func updateProjectState(_ state: ProjectState) {
        projectState = state
        workspaceSessions = []
        restart()
    }

    public func updateWorkspaceSessions(_ sessions: [(EngineSession, QueryContext)]) {
        workspaceSessions = sessions
        projectState = .empty
        restart()
    }

    public func setQuery(_ query: String) {
        self.query = query
        restart()
    }

    public func setCaseSensitive(_ enabled: Bool) {
        guard isCaseSensitive != enabled else { return }
        isCaseSensitive = enabled
        restart()
    }

    public func setRegex(_ enabled: Bool) {
        guard isRegex != enabled else { return }
        isRegex = enabled
        restart()
    }

    public func selectPrevious() {
        moveSelection(by: -1)
    }

    public func selectNext() {
        moveSelection(by: 1)
    }

    public func select(_ flatIndex: Int) {
        guard flatIndex >= 0, flatIndex < displayedMatchCount else { return }
        selectedIndex = flatIndex
    }

    public func openSelection() -> (path: String, byteOffset: UInt32)? {
        guard let selectedIndex,
              let selection = selection(at: selectedIndex)
        else { return nil }
        return (
            selection.group.path,
            selection.match.value.byteRange.lowerBound
        )
    }

    private func selection(at flatIndex: Int) -> (group: Group, match: Match)? {
        var remaining = flatIndex
        for group in groups {
            if remaining < group.matches.count {
                return (group, group.matches[remaining])
            }
            remaining -= group.matches.count
        }
        return nil
    }

    private func restart() {
        requestID &+= 1
        let currentRequestID = requestID
        searchTask?.cancel()
        searchTask = nil
        clearResults()

        let sessions: [(EngineSession, QueryContext)]
        if !workspaceSessions.isEmpty {
            sessions = workspaceSessions
        } else {
            switch projectState {
            case .empty:
                placeholder = "Open a project to search."
                return
            case .indexing:
                placeholder = "Indexing project…"
                return
            case .failed:
                placeholder = "Project indexing failed."
                return
            case let .ready(session, context):
                sessions = [(session, context)]
            }
        }
        guard !query.isEmpty else {
            placeholder = "Enter a search query."
            return
        }
        placeholder = ""
        isSearching = true
        let query = ContentSearchQuery(
            pattern: query,
            isRegex: isRegex,
            caseSensitive: isCaseSensitive
        )
        let searcher = searcher
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(150))
                guard let self,
                      !Task.isCancelled,
                      requestID == currentRequestID
                else { return }
                for (session, context) in sessions {
                    guard !Task.isCancelled,
                          requestID == currentRequestID
                    else { return }
                    let stream = try await searcher(session, query, context)
                    guard !Task.isCancelled,
                          requestID == currentRequestID
                    else { return }
                    for try await batch in stream {
                        guard !Task.isCancelled,
                              requestID == currentRequestID
                        else { return }
                        apply(batch, session: session)
                    }
                }
                guard requestID == currentRequestID else { return }
                isSearching = false
                if totalMatches == 0 { placeholder = "No matches." }
            } catch is CancellationError {
                return
            } catch {
                guard let self, requestID == currentRequestID else { return }
                clearResults()
                isSearching = false
                placeholder = "Search failed."
            }
        }
    }

    private func clearResults() {
        groups = []
        groupsByPath = [:]
        isSearching = false
        totalMatches = 0
        fileCount = 0
        isTruncated = false
        displayTruncationMessage = nil
        selectedIndex = nil
        matchedPathIDs = []
    }

    private func apply(_ batch: SearchBatch, session: EngineSession) {
        let previousSelectedIndex = selectedIndex
        let selectedMatch = previousSelectedIndex.flatMap {
            selection(at: $0)?.match
        }
        var remainingDisplayCapacity = Self.displayLimit - displayedMatchCount
        for (pathID, matches) in batch.matchesByPath.sorted(by: {
            session.paths.resolve($0.key) < session.paths.resolve($1.key)
        }) where !matches.isEmpty {
            totalMatches += matches.count
            matchedPathIDs.insert(pathID)
            guard remainingDisplayCapacity > 0 else { continue }
            let group = groupsByPath[pathID] ?? Group(
                pathID: pathID,
                path: session.paths.resolve(pathID),
                matches: []
            )
            groupsByPath[pathID] = group
            let displayedMatches = matches
                .sorted {
                    $0.byteRange.lowerBound < $1.byteRange.lowerBound
                }
                .prefix(remainingDisplayCapacity)
            group.matches.append(contentsOf: displayedMatches.map(Match.init))
            remainingDisplayCapacity -= displayedMatches.count
            group.matches.sort {
                $0.value.byteRange.lowerBound < $1.value.byteRange.lowerBound
            }
        }
        groups = groupsByPath.values.sorted { $0.path < $1.path }
        fileCount = matchedPathIDs.count
        isTruncated = isTruncated || batch.completeness == .truncated
        displayTruncationMessage = totalMatches > Self.displayLimit
            ? "Showing first \(Self.displayLimit) of \(totalMatches) matches (truncated)"
            : nil
        reconcileSelection(
            preserving: selectedMatch,
            fallbackIndex: previousSelectedIndex
        )
    }

    func reconcileSelection(
        preserving selectedMatch: Match?,
        fallbackIndex: Int?
    ) {
        if let selectedMatch,
           let index = groups
               .flatMap(\.matches)
               .firstIndex(where: { $0 === selectedMatch })
        {
            selectedIndex = index
            return
        }
        selectedIndex = fallbackIndex
        if fallbackIndex == nil, displayedMatchCount > 0 {
            selectedIndex = 0
        } else if let fallbackIndex, fallbackIndex >= displayedMatchCount {
            self.selectedIndex = displayedMatchCount > 0
                ? displayedMatchCount - 1
                : nil
        }
    }

    private func moveSelection(by delta: Int) {
        guard displayedMatchCount > 0 else {
            selectedIndex = nil
            return
        }
        guard let selectedIndex else {
            self.selectedIndex = delta < 0 ? displayedMatchCount - 1 : 0
            return
        }
        self.selectedIndex = (
            selectedIndex + delta + displayedMatchCount
        ) % displayedMatchCount
    }
}
