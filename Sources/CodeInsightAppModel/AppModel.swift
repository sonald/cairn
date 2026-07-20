import CodeInsightCore
import CodeInsightEngine
import Observation

public enum ProjectState: Sendable {
    case empty
    case indexing
    case ready(EngineSession, QueryContext)
    case failed
}

@MainActor
@Observable
public final class AppModel {
    public private(set) var projectState: ProjectState = .empty

    public init() {}

    @discardableResult
    public func transition(to next: ProjectState) -> Bool {
        switch (projectState, next) {
        case (.empty, .indexing),
             (.ready, .indexing),
             (.failed, .indexing),
             (.indexing, .ready),
             (.indexing, .failed):
            projectState = next
            return true
        default:
            return false
        }
    }
}
