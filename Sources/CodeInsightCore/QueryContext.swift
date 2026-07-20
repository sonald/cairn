import Foundation

public struct AnalysisProfileID: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public enum TrustMode: Sendable {
    case safe
    case trusted
}

public struct AnalysisProfile: Sendable {
    public let id: AnalysisProfileID
    public let language: LanguageID
    public let projectRoot: PathID
    public let trustMode: TrustMode

    public init(
        id: AnalysisProfileID,
        language: LanguageID,
        projectRoot: PathID,
        trustMode: TrustMode
    ) {
        self.id = id
        self.language = language
        self.projectRoot = projectRoot
        self.trustMode = trustMode
    }

    public static func placeholder(
        language: LanguageID,
        root: PathID
    ) -> AnalysisProfile {
        AnalysisProfile(
            id: AnalysisProfileID(rawValue: UUID()),
            language: language,
            projectRoot: root,
            trustMode: .safe
        )
    }
}

public struct QueryContext: Sendable {
    public let snapshotID: SnapshotID
    public let analysisProfileID: AnalysisProfileID
    public let generation: UInt64

    public init(
        snapshotID: SnapshotID,
        analysisProfileID: AnalysisProfileID,
        generation: UInt64
    ) {
        self.snapshotID = snapshotID
        self.analysisProfileID = analysisProfileID
        self.generation = generation
    }
}
