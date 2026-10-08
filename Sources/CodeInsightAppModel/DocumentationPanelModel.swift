import Foundation
import Observation

/// The documentation panel's search state. Each `show(query:)` starts a new
/// generation and cancels the previous search; a result arriving for an older
/// generation is dropped.
@MainActor
@Observable
public final class DocumentationPanelModel {
    /// Why the panel shows text instead of a page.
    public enum Notice: Equatable, Sendable {
        case notInstalled
        case notRunning
        case apiDisabled
        case trialExpired
        case noResults
        case failed(String)
    }

    public enum State: Equatable {
        case idle
        case unavailable(Notice)
        case searching(String)
        /// Several results and none to load on its own: the user picks.
        case candidates([DocumentationCandidate])
        case showing(DocumentationCandidate, [DocumentationCandidate])
    }

    public private(set) var state: State = .idle
    /// The text of the latest search.
    public private(set) var query = ""

    @ObservationIgnored private let source: any DocumentationSource
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0

    public init(source: any DocumentationSource) {
        self.source = source
    }

    public func show(query: String) {
        task?.cancel()
        generation &+= 1
        let current = generation
        self.query = query
        state = .searching(query)
        let source = source
        task = Task { [weak self] in
            let next = await Self.resolve(query, source: source)
            guard let self, generation == current, !Task.isCancelled else { return }
            state = next
            task = nil
        }
    }

    public func select(_ candidate: DocumentationCandidate) {
        switch state {
        case let .candidates(all), let .showing(_, all):
            guard all.contains(candidate) else { return }
            state = .showing(candidate, all)
        default:
            break
        }
    }

    private static func resolve(_ query: String, source: any DocumentationSource) async -> State {
        switch await source.availability() {
        case .notInstalled: return .unavailable(.notInstalled)
        case .notRunning: return .unavailable(.notRunning)
        case .apiDisabled: return .unavailable(.apiDisabled)
        case .available: break
        }
        do {
            let candidates = try await source.search(query)
            guard !candidates.isEmpty else { return .unavailable(.noResults) }
            let index = autoLoadIndex(query: query, candidates: candidates) {
                source.isExactMatch($0, for: query)
            }
            return index.map { .showing(candidates[$0], candidates) } ?? .candidates(candidates)
        } catch DocumentationSourceError.trialExpired {
            return .unavailable(.trialExpired)
        } catch DocumentationSourceError.apiDisabled {
            return .unavailable(.apiDisabled)
        } catch {
            return .unavailable(.failed(error.localizedDescription))
        }
    }

    /// The result to load without asking: the only result; the only exact
    /// match; for a qualified query (`a.b`, `a::b`), the first of several
    /// exact matches in the source's order. A bare identifier with several
    /// exact matches, or no exact match, waits for the user.
    public nonisolated static func autoLoadIndex(
        query: String,
        candidates: [DocumentationCandidate],
        isExact: (DocumentationCandidate) -> Bool
    ) -> Int? {
        if candidates.count == 1 { return 0 }
        let exact = candidates.indices.filter { isExact(candidates[$0]) }
        if exact.count == 1 { return exact[0] }
        let qualified = query.contains("::") || query.contains(".")
        return qualified ? exact.first : nil
    }
}
