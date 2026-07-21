import CodeInsightCore
import CodeInsightEngine
import Foundation
import Observation

@MainActor
@Observable
public final class SearchPanelModel {
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
    public private(set) var isTruncated = false
    public private(set) var selectedIndex: Int?
    public private(set) var requestID: UInt64 = 0
    public private(set) var isCaseSensitive = false
    public private(set) var isRegex = false

    private let searcher: Searcher
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var projectState = ProjectState.empty
    @ObservationIgnored private var groupsByPath: [PathID: Group] = [:]

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
        guard flatIndex >= 0, flatIndex < totalMatches else { return }
        selectedIndex = flatIndex
    }

    public func openSelection() -> (path: String, byteOffset: UInt32)? {
        guard var remaining = selectedIndex else { return nil }
        for group in groups {
            if remaining < group.matches.count {
                return (
                    group.path,
                    group.matches[remaining].value.byteRange.lowerBound
                )
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

        switch projectState {
        case .empty:
            placeholder = "Open a project to search."
        case .indexing:
            placeholder = "Indexing project…"
        case .failed:
            placeholder = "Project indexing failed."
        case let .ready(session, context):
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
                    guard requestID == currentRequestID else { return }
                    isSearching = false
                    if totalMatches == 0 { placeholder = "No matches." }
                } catch is CancellationError {
                    return
                } catch {
                    guard let self, requestID == currentRequestID else { return }
                    isSearching = false
                    placeholder = "Search failed."
                }
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
        selectedIndex = nil
    }

    private func apply(_ batch: SearchBatch, session: EngineSession) {
        for (pathID, matches) in batch.matchesByPath {
            let group = groupsByPath[pathID] ?? Group(
                pathID: pathID,
                path: session.paths.resolve(pathID),
                matches: []
            )
            groupsByPath[pathID] = group
            group.matches.append(contentsOf: matches.map(Match.init))
            group.matches.sort {
                $0.value.byteRange.lowerBound < $1.value.byteRange.lowerBound
            }
        }
        groups = groupsByPath.values.sorted { $0.path < $1.path }
        totalMatches = groups.reduce(0) { $0 + $1.matches.count }
        fileCount = groups.count
        isTruncated = isTruncated || batch.completeness == .truncated
        if selectedIndex == nil, totalMatches > 0 {
            selectedIndex = 0
        } else if let selectedIndex, selectedIndex >= totalMatches {
            self.selectedIndex = totalMatches > 0 ? totalMatches - 1 : nil
        }
        if batch.isFinal {
            isSearching = false
            if totalMatches == 0 { placeholder = "No matches." }
        }
    }

    private func moveSelection(by delta: Int) {
        guard totalMatches > 0 else {
            selectedIndex = nil
            return
        }
        guard let selectedIndex else {
            self.selectedIndex = delta < 0 ? totalMatches - 1 : 0
            return
        }
        self.selectedIndex = (
            selectedIndex + delta + totalMatches
        ) % totalMatches
    }
}
