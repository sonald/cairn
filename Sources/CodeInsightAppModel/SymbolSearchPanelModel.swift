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

    public init() {}

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
            let pathIDs = Dictionary(uniqueKeysWithValues: session.manifest.files.map {
                (session.paths.resolve($0.pathID), $0.pathID)
            })
            let boost = SearchBoost(
                currentFile: currentPath.flatMap { pathIDs[$0] },
                recentFiles: recentPaths.compactMap { pathIDs[$0] }
            )
            Task { [weak self] in
                let hits = await Task.detached(priority: .userInitiated) {
                    (try? session.searchSymbols(
                        query: query,
                        limit: 50,
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
