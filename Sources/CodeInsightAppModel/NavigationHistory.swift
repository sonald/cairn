import CodeInsightCore
import CodeInsightExact
import Foundation

public struct ResolutionExplanationID: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct RelationQueryContextID: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct ReconciliationID: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public enum ObservedTarget: Sendable {
    case candidate(CandidateEndpoint)
    case verification(ExactTarget)
}

public struct VerificationObservation: Sendable {
    public let target: ExactTarget
    public let attribution: ExactAttribution
    public let origin: ExactOrigin

    public init(
        target: ExactTarget,
        attribution: ExactAttribution,
        origin: ExactOrigin
    ) {
        self.target = target
        self.attribution = attribution
        self.origin = origin
    }
}

public enum RelationQueryObservation: Sendable {
    case completed(
        attribution: ExactAttribution,
        origin: ExactOrigin,
        exhaustiveness: QueryExhaustiveness
    )
    case unsupported
    case notApplicable
}

public struct RelationSetObservation: Sendable {
    public let completeness: Completeness
    public let returnedCount: Int
    public let totalCount: Int?

    public init(
        completeness: Completeness,
        returnedCount: Int,
        totalCount: Int? = nil
    ) {
        self.completeness = completeness
        self.returnedCount = returnedCount
        self.totalCount = totalCount
    }
}

public enum ReconciliationRole: Hashable, Sendable {
    case corroborated(candidateIndex: Int, targetIndex: Int)
    case correctedCandidate(candidateIndex: Int)
    case inconclusiveCandidate(candidateIndex: Int)
    case notCorroboratedCandidate(candidateIndex: Int)
    case providerOnly(targetIndex: Int)
}

public struct CallSiteReconciliation: Sendable {
    public let id: ReconciliationID
    public let querySite: SourceLocation
    public let candidates: [CandidateObservation]
    public let providerTargets: [VerificationObservation]
    public let roles: [ReconciliationRole]

    public init(
        id: ReconciliationID = ReconciliationID(),
        querySite: SourceLocation,
        candidates: [CandidateObservation],
        providerTargets: [VerificationObservation],
        roles: [ReconciliationRole]
    ) {
        self.id = id
        self.querySite = querySite
        self.candidates = candidates
        self.providerTargets = providerTargets
        self.roles = roles
    }
}

public struct ReconciliationRef: Hashable, Sendable {
    public let contextID: RelationQueryContextID
    public let reconciliationID: ReconciliationID
    public let role: ReconciliationRole

    public init(
        contextID: RelationQueryContextID,
        reconciliationID: ReconciliationID,
        role: ReconciliationRole
    ) {
        self.contextID = contextID
        self.reconciliationID = reconciliationID
        self.role = role
    }
}

public enum ResolutionTrace: Sendable {
    case candidateOnly(CandidateObservation)
    case verificationOnly(VerificationObservation)
    case corroborated(
        candidate: CandidateObservation,
        verification: VerificationObservation
    )
    case conflict(
        candidate: CandidateObservation,
        reconciliation: ReconciliationRef
    )
}

public enum CandidateRelationQueryState: Sendable {
    case pending
    case completed(RelationSetObservation)
    case failed
}

public enum ExactRelationQueryState: Sendable {
    case notStarted
    case pending
    case completed(RelationQueryObservation)
}

public struct RelationQueryContext: Sendable {
    public var candidateQuery: CandidateRelationQueryState
    public var exactQuery: ExactRelationQueryState
    public var reconciliations: [ReconciliationID: CallSiteReconciliation]

    public init(
        candidateQuery: CandidateRelationQueryState = .pending,
        exactQuery: ExactRelationQueryState = .notStarted,
        reconciliations: [ReconciliationID: CallSiteReconciliation] = [:]
    ) {
        self.candidateQuery = candidateQuery
        self.exactQuery = exactQuery
        self.reconciliations = reconciliations
    }
}

public struct RelationRowExplanation: Sendable {
    public let primaryTrace: ResolutionTrace
    public let contextID: RelationQueryContextID
    public let reconciliationRefs: [ReconciliationRef]

    public init(
        primaryTrace: ResolutionTrace,
        contextID: RelationQueryContextID,
        reconciliationRefs: [ReconciliationRef] = []
    ) {
        self.primaryTrace = primaryTrace
        self.contextID = contextID
        self.reconciliationRefs = reconciliationRefs
    }
}

public struct LiveResolutionExplanation: Sendable {
    public let trace: ResolutionTrace
    public let contextID: RelationQueryContextID
    public let reconciliationRefs: [ReconciliationRef]

    public init(
        trace: ResolutionTrace,
        contextID: RelationQueryContextID,
        reconciliationRefs: [ReconciliationRef] = []
    ) {
        self.trace = trace
        self.contextID = contextID
        self.reconciliationRefs = reconciliationRefs
    }
}

public struct RelationFactsSnapshot: Sendable {
    public let candidateRelationSet: RelationSetObservation?
    public let relationQuery: RelationQueryObservation?

    public init(
        candidateRelationSet: RelationSetObservation?,
        relationQuery: RelationQueryObservation?
    ) {
        self.candidateRelationSet = candidateRelationSet
        self.relationQuery = relationQuery
    }
}

public struct ReconciliationSnapshot: Sendable {
    public let querySite: SourceLocation
    public let candidates: [CandidateObservation]
    public let providerTargets: [VerificationObservation]
    public let roles: [ReconciliationRole]

    public init(_ reconciliation: CallSiteReconciliation) {
        querySite = reconciliation.querySite
        candidates = reconciliation.candidates
        providerTargets = reconciliation.providerTargets
        roles = reconciliation.roles
    }
}

public enum MaterializedResolutionTrace: Sendable {
    case candidateOnly(CandidateObservation)
    case verificationOnly(VerificationObservation)
    case corroborated(
        candidate: CandidateObservation,
        verification: VerificationObservation
    )
    case conflict(
        candidate: CandidateObservation,
        reconciliation: ReconciliationSnapshot
    )
}

public struct MaterializedResolutionExplanation: Sendable {
    public var trace: MaterializedResolutionTrace
    public var relationFacts: RelationFactsSnapshot?

    public init(
        trace: MaterializedResolutionTrace,
        relationFacts: RelationFactsSnapshot? = nil
    ) {
        self.trace = trace
        self.relationFacts = relationFacts
    }
}

public struct ResolutionExplanationSnapshot: Sendable {
    public let explanation: MaterializedResolutionExplanation
    public let capturedAt: Date

    public init(
        explanation: MaterializedResolutionExplanation,
        capturedAt: Date = Date()
    ) {
        self.explanation = explanation
        self.capturedAt = capturedAt
    }
}

public struct NavigationExplanation: Sendable {
    public let explanationID: ResolutionExplanationID
    public let observedAtNavigation: ResolutionExplanationSnapshot

    public init(
        explanationID: ResolutionExplanationID,
        observedAtNavigation: ResolutionExplanationSnapshot
    ) {
        self.explanationID = explanationID
        self.observedAtNavigation = observedAtNavigation
    }
}

public enum TargetScope: Sendable {
    case project
    case dependency
    case importBinding
}

public enum TargetAvailability: Sendable {
    case available
    case notIndexed
    case unavailable
}

public enum TargetComparison: Sendable {
    case same
    case different
    case notComparable
}

public struct SourceDestination: Sendable {
    public let file: URL
    public let byteOffset: UInt32?

    public init(file: URL, byteOffset: UInt32? = nil) {
        self.file = file
        self.byteOffset = byteOffset
    }
}

public enum NavigationCause: Equatable, Sendable {
    case fileSelection
    case outline
    case relation
    case search
    case historyReplay
    case tabActivation
}

public struct NavigationPolicy: Equatable, Sendable {
    public let blockViewportFollow: Bool
    public let recordInTrail: Bool

    public init(blockViewportFollow: Bool, recordInTrail: Bool) {
        self.blockViewportFollow = blockViewportFollow
        self.recordInTrail = recordInTrail
    }

    public static let explicitSemantic = NavigationPolicy(
        blockViewportFollow: true,
        recordInTrail: true
    )
    public static let passive = NavigationPolicy(
        blockViewportFollow: false,
        recordInTrail: false
    )
    public static let replay = NavigationPolicy(
        blockViewportFollow: true,
        recordInTrail: false
    )
}

public struct NavigationRequest: Sendable {
    public let destination: SourceDestination
    public let cause: NavigationCause
    public let policy: NavigationPolicy
    public let explanation: NavigationExplanation?

    public init(
        destination: SourceDestination,
        cause: NavigationCause,
        policy: NavigationPolicy,
        explanation: NavigationExplanation? = nil
    ) {
        self.destination = destination
        self.cause = cause
        self.policy = policy
        self.explanation = explanation
    }
}

public struct OutlineFollowArbitration: Sendable {
    public var suppressedBy: NavigationCause?

    public init(suppressedBy: NavigationCause? = nil) {
        self.suppressedBy = suppressedBy
    }

    public mutating func apply(_ request: NavigationRequest) {
        suppressedBy = request.policy.blockViewportFollow ? request.cause : nil
    }

    public mutating func didLiveScroll() {
        suppressedBy = nil
    }
}

public struct JumpRecord: Equatable, Sendable {
    public let path: String
    public let contentID: ContentID?
    public let byteOffset: UInt32
    public let line: UInt32
    public let column: UInt32
    public let symbolAnchor: String?
    public let snapshotID: SnapshotID?

    public init(
        path: String,
        contentID: ContentID?,
        byteOffset: UInt32,
        line: UInt32,
        column: UInt32,
        symbolAnchor: String?,
        snapshotID: SnapshotID?
    ) {
        self.path = path
        self.contentID = contentID
        self.byteOffset = byteOffset
        self.line = line
        self.column = column
        self.symbolAnchor = symbolAnchor
        self.snapshotID = snapshotID
    }
}

@MainActor
public final class NavigationHistory {
    public private(set) var records: [JumpRecord] = []
    public private(set) var cursor = 0

    private static let limit = 200
    private var forwardRecord: JumpRecord?

    public init() {}

    public var canGoBack: Bool {
        cursor > 0
    }

    public var canGoForward: Bool {
        cursor + 1 < records.count
            || (cursor + 1 == records.count && forwardRecord != nil)
    }

    public func push(_ record: JumpRecord) {
        if cursor < records.count {
            records.removeSubrange((cursor + 1)..<records.count)
            if records.indices.contains(cursor), records[cursor].path == record.path {
                records[cursor] = record
                forwardRecord = nil
                cursor = records.count
                return
            }
        }
        forwardRecord = nil
        if records.last != record {
            records.append(record)
        }
        if records.count > Self.limit {
            records.removeFirst(records.count - Self.limit)
        }
        cursor = records.count
    }

    public func goBack(from current: JumpRecord) -> JumpRecord? {
        guard canGoBack else { return nil }
        if cursor == records.count {
            forwardRecord = current
        }
        cursor -= 1
        return records[cursor]
    }

    public func goForward() -> JumpRecord? {
        guard canGoForward else { return nil }
        if cursor + 1 < records.count {
            cursor += 1
            return records[cursor]
        }
        cursor += 1
        return forwardRecord
    }

    public func reset() {
        records.removeAll(keepingCapacity: true)
        cursor = 0
        forwardRecord = nil
    }
}
