import CodeInsightCore
import CodeInsightEngine
import Foundation
import Observation

public enum SymbolSearchRow: Sendable {
    case placeholder(String)
    case result(name: String, hit: SymbolSearchHit)
}

@MainActor
@Observable
public final class SymbolSearchPanelModel {
    public private(set) var query = ""
    public private(set) var rows: [SymbolSearchRow] = []
    public private(set) var selectedIndex: Int?
    public private(set) var requestID: UInt64 = 0

    @ObservationIgnored private var pathIDsSnapshotID: SnapshotID?
    @ObservationIgnored private var pathIDsByPath: [String: PathID] = [:]
    private let symbolSearcher: @Sendable (
        EngineSession,
        String,
        SearchBoost,
        QueryContext
    ) async throws -> [SymbolSearchHit]

    public init() {
        symbolSearcher = { session, query, boost, context in
            try session.searchSymbols(
                query: query,
                limit: .max,
                boost: boost,
                context: context
            )
        }
    }

    init(
        symbolSearcher: @escaping @Sendable (
            EngineSession,
            String,
            SearchBoost,
            QueryContext
        ) async throws -> [SymbolSearchHit]
    ) {
        self.symbolSearcher = symbolSearcher
    }

    public func updateQuery(
        _ query: String,
        sessions: [(EngineSession, QueryContext)],
        currentPath: String? = nil,
        recentPaths: [String] = []
    ) {
        self.query = query
        requestID &+= 1
        let currentRequestID = requestID
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            rows = []
            selectedIndex = nil
            return
        }
        guard !sessions.isEmpty else {
            rows = []
            selectedIndex = nil
            return
        }

        let capturedSnapshotID = sessions.first?.0.snapshotID
        let capturedSessions = sessions
        let capturedCurrentPath = currentPath
        let capturedRecentPaths = recentPaths
        let symbolSearcher = symbolSearcher
        Task { [weak self] in
            let rows = await Task.detached(priority: .userInitiated) {
                try? await capturesRows(
                    query: query,
                    sessions: capturedSessions,
                    currentPath: capturedCurrentPath,
                    recentPaths: capturedRecentPaths,
                    pathIDsSnapshotID: capturedSnapshotID,
                    symbolSearcher: symbolSearcher
                )
            }.value
            guard let self, self.requestID == currentRequestID else { return }
            guard let rows, !rows.isEmpty else {
                self.rows = []
                self.selectedIndex = nil
                return
            }
            self.rows = rows
            self.selectedIndex = 0
        }
    }

    public func updateQuery(
        _ query: String,
        projectState: ProjectState,
        currentPath: String? = nil,
        recentPaths: [String] = []
    ) {
        self.query = query
        requestID &+= 1
        let currentRequestID = requestID

        switch projectState {
        case .indexing:
            rows = [.placeholder("Indexing symbols…")]
            selectedIndex = nil
        case let .ready(session, context):
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                rows = []
                selectedIndex = nil
                return
            }
            if pathIDsSnapshotID != session.snapshotID {
                pathIDsSnapshotID = session.snapshotID
                pathIDsByPath = Dictionary(
                    uniqueKeysWithValues: session.manifest.files.map {
                        (session.paths.resolve($0.pathID), $0.pathID)
                    }
                )
            }
            let boost = SearchBoost(
                currentFile: currentPath.flatMap { pathIDsByPath[$0] },
                recentFiles: recentPaths.compactMap { pathIDsByPath[$0] }
            )
            Task { [weak self] in
                let hits = await Task.detached(priority: .userInitiated) {
                    (try? session.searchSymbols(
                        query: query,
                        limit: .max,
                        boost: boost,
                        context: context
                    )) ?? []
                }.value
                guard let self, self.requestID == currentRequestID else { return }
                self.rows = hits.map {
                    .result(name: session.names.resolve($0.nameID), hit: $0)
                }
                self.selectedIndex = self.rows.isEmpty ? nil : 0
            }
        case .empty, .failed:
            rows = []
            selectedIndex = nil
        }
    }

    public func selectPrevious() {
        moveSelection(by: -1)
    }

    public func selectNext() {
        moveSelection(by: 1)
    }

    public func select(_ index: Int) {
        guard selectedIndex != index,
              rows.indices.contains(index),
              case .result = rows[index]
        else { return }
        selectedIndex = index
    }

    public func openSelection() -> (path: String, byteOffset: UInt32)? {
        guard let selectedIndex,
              rows.indices.contains(selectedIndex),
              case let .result(_, hit) = rows[selectedIndex]
        else { return nil }
        return (hit.path, hit.facet.nameRange.lowerBound)
    }

    public func reset() {
        requestID &+= 1
        query = ""
        rows = []
        selectedIndex = nil
    }

    private func moveSelection(by delta: Int) {
        let selectable = rows.indices.filter {
            if case .result = rows[$0] { return true }
            return false
        }
        guard !selectable.isEmpty else {
            selectedIndex = nil
            return
        }
        guard let selectedIndex,
              let position = selectable.firstIndex(of: selectedIndex)
        else {
            self.selectedIndex = delta < 0 ? selectable.last : selectable.first
            return
        }
        self.selectedIndex = selectable[
            (position + delta + selectable.count) % selectable.count
        ]
    }
}

private func capturesRows(
    query: String,
    sessions: [(EngineSession, QueryContext)],
    currentPath: String?,
    recentPaths: [String],
    pathIDsSnapshotID: SnapshotID?,
    symbolSearcher: @escaping @Sendable (
        EngineSession,
        String,
        SearchBoost,
        QueryContext
    ) async throws -> [SymbolSearchHit]
) async throws -> [SymbolSearchRow] {
    var result: [SymbolSearchRow] = []
    result.reserveCapacity(sessions.count)
    for (session, context) in sessions {
        guard session.snapshotID == pathIDsSnapshotID else { return [] }
        let pathsByPath = Dictionary(uniqueKeysWithValues: session.manifest.files.map {
            (session.paths.resolve($0.pathID), $0.pathID)
        })
        let boost = SearchBoost(
            currentFile: currentPath.flatMap { pathsByPath[$0] },
            recentFiles: recentPaths.compactMap { pathsByPath[$0] }
        )
        let hits = try await symbolSearcher(
            session,
            query,
            boost,
            context
        )
        result.append(contentsOf: hits.map {
            .result(name: session.names.resolve($0.nameID), hit: $0)
        })
    }
    return result.sorted { lhs, rhs in
        guard case let .result(_, lhsHit) = lhs,
              case let .result(_, rhsHit) = rhs
        else { return false }
        if lhsHit.score != rhsHit.score { return lhsHit.score > rhsHit.score }
        if lhsHit.path != rhsHit.path { return lhsHit.path < rhsHit.path }
        let lhsRange = lhsHit.facet.nameRange
        let rhsRange = rhsHit.facet.nameRange
        if lhsRange.lowerBound != rhsRange.lowerBound {
            return lhsRange.lowerBound < rhsRange.lowerBound
        }
        return lhsRange.upperBound < rhsRange.upperBound
    }
}
