import CodeInsightCore
import CodeInsightEngine
import Foundation
import Observation

public struct QueryState: Codable, Equatable, Sendable {
    public var text: String
    public var caseSensitive: Bool
    public var wholeWord: Bool
    public var isRegex: Bool

    public init(text: String, caseSensitive: Bool = false, wholeWord: Bool = false, isRegex: Bool = false) {
        self.text = text
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
        self.isRegex = isRegex
    }
}

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
        public let contentID: ContentID?
        public fileprivate(set) var matches: [Match]
        public fileprivate(set) var isTruncated = false

        fileprivate init(
            pathID: PathID,
            path: String,
            contentID: ContentID?,
            matches: [Match]
        ) {
            self.pathID = pathID
            self.path = path
            self.contentID = contentID
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
    public private(set) var placeholder = localized("model.search.open")
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
    public private(set) var isWholeWord = false
    /// Comma-separated path globs as the user typed them.
    public private(set) var includePaths = ""
    public private(set) var excludePaths = ""
    /// Files searched and files the path filters removed, summed over sessions.
    public private(set) var searchedFileCount = 0
    public private(set) var excludedFileCount = 0

    public var displayedMatchCount: Int {
        min(totalMatches, Self.displayLimit)
    }

    public private(set) var parsedQuery: ProjectSearchQuery?
    public private(set) var syntaxError: ProjectSearchQuery.ParseError?
    public private(set) var isStale = false
    public private(set) var history: [QueryState] = []
    public private(set) var searchedLanguages: [LanguageID] = []
    public private(set) var nonSourcePathCount = 0
    public private(set) var projectExcludedPathCount: Int?
    public private(set) var regexSkippedPathCount = 0
    public private(set) var truncatedConditionIndices: Set<Int> = []
    public var syntaxErrorMessage: String? {
        syntaxError.map { localized($0.localizationKey) }
    }
    public var currentQueryState: QueryState {
        QueryState(text: query, caseSensitive: isCaseSensitive, wholeWord: isWholeWord, isRegex: isRegex)
    }
    public var onStateChanged: (() -> Void)?
    public internal(set) var suggestionsEnabled = true
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored var dismissedSuggestionRequest: UInt64?
    private let searcher: Searcher?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var workspaceSessions: [(EngineSession, QueryContext)] = []
    @ObservationIgnored private var projectState = ProjectState.empty
    @ObservationIgnored private var groupsByPath: [PathID: Group] = [:]
    @ObservationIgnored private var selectionToRestore: (path: String, contentID: ContentID, range: ByteRange)?
    @ObservationIgnored private var isRestoringSelection = false
    @ObservationIgnored private var displayedQueryState: QueryState?
    @ObservationIgnored private var matchedPathIDs: Set<PathID> = []
    @ObservationIgnored private var scopeBySession: [ObjectIdentifier: (searched: Int, excluded: Int, regexSkipped: Int)] = [:]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        searcher = nil
    }

    init(searcher: @escaping Searcher) {
        self.searcher = searcher
        defaults = .standard
    }

    deinit {
        searchTask?.cancel()
    }

    public func updateProjectState(_ state: ProjectState) {
        if case let .ready(oldSession, oldContext) = projectState,
           case let .ready(session, context) = state,
           oldSession === session, oldContext.generation == context.generation,
           oldContext.snapshotID == context.snapshotID,
           oldContext.analysisProfileID == context.analysisProfileID { return }
        invalidateResults()
        projectState = state
        workspaceSessions = []
        restart(preservingSelection: true)
    }

    public func updateWorkspaceSessions(_ sessions: [(EngineSession, QueryContext)]) {
        if workspaceSessions.count == sessions.count,
           zip(workspaceSessions, sessions).allSatisfy({ old, new in
               old.0 === new.0 && old.1.snapshotID == new.1.snapshotID
                   && old.1.analysisProfileID == new.1.analysisProfileID
                   && old.1.generation == new.1.generation
           }) { return }
        invalidateResults()
        workspaceSessions = sessions
        projectState = .empty
        restart(preservingSelection: true)
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

    public func setWholeWord(_ enabled: Bool) {
        guard isWholeWord != enabled else { return }
        isWholeWord = enabled
        restart()
    }

    public func setPathFilters(include: String, exclude: String) {
        guard include != includePaths || exclude != excludePaths else { return }
        includePaths = include
        excludePaths = exclude
        guard var parsed = try? ProjectSearchQuery.parse(query, isRegex: isRegex) else { return }
        parsed.includeGlobs = PathGlob.list(include).map(\.pattern)
        parsed.excludeGlobs = PathGlob.list(exclude).map(\.pattern)
        query = parsed.serialized
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
        isRestoringSelection = false
        selectionToRestore = nil
        selectedIndex = flatIndex
    }

    public func openSelection() -> (
        path: String, byteOffset: UInt32, contentID: ContentID?
    )? {
        guard !isStale, let selectedIndex,
              let selection = selection(at: selectedIndex),
              selection.group.contentID != nil
        else { return nil }
        if let displayedQueryState { rememberQuery(displayedQueryState) }
        return (
            selection.group.path,
            selection.match.value.byteRange.lowerBound,
            selection.group.contentID
        )
    }

    public var selectedMatch: SearchMatch? {
        guard !isStale, let selectedIndex,
              let selection = selection(at: selectedIndex),
              selection.group.contentID != nil else { return nil }
        return selection.match.value
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

    private func invalidateResults() {
        if !isStale, !isRestoringSelection, !groups.isEmpty {
            isRestoringSelection = true
            selectionToRestore = selectedIndex.flatMap { index in
                guard let selected = selection(at: index), let contentID = selected.group.contentID else { return nil }
                return (selected.group.path, contentID, selected.match.value.byteRange)
            }
        }
        isStale = !groups.isEmpty
    }

    private func restart(preservingSelection: Bool = false) {
        if !preservingSelection {
            isRestoringSelection = false
            selectionToRestore = nil
        }
        requestID &+= 1
        let currentRequestID = requestID
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
        syntaxError = nil
        onStateChanged?()
        let parsed: ProjectSearchQuery
        do {
            parsed = try ProjectSearchQuery.parse(query, isRegex: isRegex)
        } catch let error as ProjectSearchQuery.ParseError {
            searchTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled, let self, requestID == currentRequestID else { return }
                syntaxError = error
            }
            return
        } catch { return }
        parsedQuery = parsed
        if parsed.isEmpty {
            clearResults()
            placeholder = localized("model.search.query")
            return
        }

        let sessions: [(EngineSession, QueryContext)]
        if !workspaceSessions.isEmpty {
            sessions = workspaceSessions
        } else {
            switch projectState {
            case .empty:
                placeholder = localized("model.search.open")
                return
            case .indexing:
                placeholder = localized("model.search.indexing")
                return
            case .failed:
                placeholder = localized("model.search.failed")
                return
            case let .ready(session, context):
                sessions = [(session, context)]
            }
        }
        guard !query.isEmpty else {
            placeholder = localized("model.search.query")
            return
        }
        placeholder = ""
        isSearching = true
        let legacyQuery = ContentSearchQuery(
            pattern: query,
            isRegex: isRegex,
            caseSensitive: isCaseSensitive,
            wholeWord: isWholeWord,
            includeGlobs: PathGlob.list(includePaths).map(\.pattern),
            excludeGlobs: PathGlob.list(excludePaths).map(\.pattern)
        )
        let searcher = searcher
        let searchedQueryState = currentQueryState
        let caseSensitive = isCaseSensitive, wholeWord = isWholeWord, regex = isRegex
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(150))
                guard let self,
                      !Task.isCancelled,
                      requestID == currentRequestID
                else { return }
                var replacingResults = true
                for (session, context) in sessions {
                    guard !Task.isCancelled,
                          requestID == currentRequestID
                    else { return }
                    let stream: AsyncThrowingStream<SearchBatch, Error>
                    if let searcher {
                        stream = try await searcher(session, legacyQuery, context)
                    } else {
                        stream = try session.search(parsed, caseSensitive: caseSensitive, wholeWord: wholeWord, isRegex: regex, context: context)
                    }
                    guard !Task.isCancelled,
                          requestID == currentRequestID
                    else { return }
                    for try await batch in stream {
                        guard !Task.isCancelled,
                              requestID == currentRequestID
                        else { return }
                        if replacingResults {
                            clearResults()
                            displayedQueryState = searchedQueryState
                            isSearching = true
                            replacingResults = false
                        }
                        apply(batch, session: session)
                    }
                }
                guard requestID == currentRequestID else { return }
                if replacingResults { clearResults() }
                isSearching = false
                if totalMatches > 0 { learnSyntax(parsed) }
                if totalMatches == 0 { placeholder = localized("model.search.empty") }
            } catch is CancellationError {
                return
            } catch {
                guard let self, requestID == currentRequestID else { return }
                clearResults()
                isSearching = false
                placeholder = localized("model.search.error")
            }
        }
    }

    private func clearResults() {
        isStale = false
        displayedQueryState = nil
        searchedLanguages = []
        nonSourcePathCount = 0
        projectExcludedPathCount = nil
        regexSkippedPathCount = 0
        truncatedConditionIndices = []
        groups = []
        groupsByPath = [:]
        isSearching = false
        totalMatches = 0
        fileCount = 0
        isTruncated = false
        displayTruncationMessage = nil
        selectedIndex = nil
        matchedPathIDs = []
        scopeBySession = [:]
        searchedFileCount = 0
        excludedFileCount = 0
    }

    private func apply(_ batch: SearchBatch, session: EngineSession) {
        searchedLanguages = Array(Set(searchedLanguages + batch.searchedLanguages)).sorted { $0.rawValue < $1.rawValue }
        nonSourcePathCount = max(nonSourcePathCount, batch.nonSourcePathCount)
        if let count = batch.projectExcludedPathCount { projectExcludedPathCount = max(projectExcludedPathCount ?? 0, count) }
        truncatedConditionIndices.formUnion(batch.truncatedConditionIndices)
        scopeBySession[ObjectIdentifier(session)] = (batch.searchedPathCount, batch.excludedPathCount, batch.regexSkippedPathCount)
        regexSkippedPathCount = scopeBySession.values.reduce(0) { $0 + $1.regexSkipped }
        searchedFileCount = scopeBySession.values.reduce(0) { $0 + $1.searched }
        excludedFileCount = scopeBySession.values.reduce(0) { $0 + $1.excluded }
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
                contentID: session.manifest.files.first {
                    $0.pathID == pathID
                }?.contentID,
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
        for pathID in batch.truncatedPathIDs {
            let group = groupsByPath[pathID] ?? Group(
                pathID: pathID, path: session.paths.resolve(pathID),
                contentID: session.manifest.files.first { $0.pathID == pathID }?.contentID,
                matches: []
            )
            group.isTruncated = true
            groupsByPath[pathID] = group
        }
        groups = groupsByPath.values.sorted { $0.path < $1.path }
        fileCount = matchedPathIDs.count
        isTruncated = isTruncated || batch.completeness == .truncated
        displayTruncationMessage = totalMatches > Self.displayLimit
            ? localizedFormat("model.search.truncated", Self.displayLimit, totalMatches)
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
        if isRestoringSelection {
            selectedIndex = nil
            if let target = selectionToRestore {
                var index = 0
                for group in groups {
                    if group.path == target.path, group.contentID == target.contentID,
                       let offset = group.matches.firstIndex(where: { $0.value.byteRange == target.range }) {
                        selectedIndex = index + offset
                        isRestoringSelection = false
                        selectionToRestore = nil
                        return
                    }
                    index += group.matches.count
                }
            }
            return
        }
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

    public func restoreHistory(_ history: [QueryState], lastQuery: QueryState?) {
        self.history = Array(history.filter { !$0.text.isEmpty }.prefix(20))
        setQueryState(lastQuery ?? QueryState(text: "", caseSensitive: isCaseSensitive, wholeWord: isWholeWord, isRegex: isRegex))
    }

    public func applyHistory(_ state: QueryState) {
        setQueryState(state)
        commitQuery()
    }

    private func setQueryState(_ state: QueryState) {
        query = state.text
        isCaseSensitive = state.caseSensitive
        isWholeWord = state.wholeWord
        isRegex = state.isRegex
        restart()
    }

    public func clearHistory() {
        history = []
        onStateChanged?()
    }

    public func clearSession() {
        history = []
        query = ""
        restart()
    }

    public func setQueryFromSelection(_ text: String) {
        setQuery(text.contains(where: \.isWhitespace) ? ProjectSearchQuery.quoted(text) : text)
    }

    /// Record an explicit submission or the query left when the search surface closes.
    /// Live search and periodic session checkpoints do not commit partially typed text.
    public func commitQuery() {
        guard let parsed = try? ProjectSearchQuery.parse(query, isRegex: isRegex), !parsed.isEmpty else { return }
        rememberQuery(currentQueryState)
    }

    private func rememberQuery(_ state: QueryState) {
        guard history.first != state else { return }
        history.removeAll { $0 == state }
        history.insert(state, at: 0)
        history = Array(history.prefix(20))
        onStateChanged?()
    }

    private func moveSelection(by delta: Int) {
        isRestoringSelection = false
        selectionToRestore = nil
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
