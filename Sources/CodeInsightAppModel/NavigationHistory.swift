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

public enum NarrativeClause: Sendable {
    case sourceEvidence([ResolutionEvidence])
    case candidateCompleteness(Completeness)
    case candidateRelationSet(RelationSetObservation)
    case verified(origin: ExactOrigin)
    case corroborated
    case exactNotStarted
    case exactPending
    case notCorroborated(
        exhaustiveness: QueryExhaustiveness,
        origin: ExactOrigin
    )
    case exactUnsupported
    case exactNotApplicable
    case conflict
    case inconclusive
}

public func narrativeClauses(
    for explanation: RelationRowExplanation,
    context: RelationQueryContext
) -> [NarrativeClause] {
    let trace = explanation.primaryTrace
    var clauses: [NarrativeClause] = []
    let candidate: CandidateObservation? = switch trace {
    case .candidateOnly(let candidate), .conflict(let candidate, _): candidate
    case .corroborated(let candidate, _): candidate
    case .verificationOnly: nil
    }
    if let candidate {
        if !candidate.evidence.isEmpty {
            clauses.append(.sourceEvidence(candidate.evidence))
        }
        clauses.append(.candidateCompleteness(candidate.completeness))
        if case .completed(let observation) = context.candidateQuery {
            clauses.append(.candidateRelationSet(observation))
        }
    }

    switch trace {
    case .verificationOnly(let verification):
        clauses.append(.verified(origin: verification.origin))
    case .corroborated(_, let verification):
        clauses.append(.verified(origin: verification.origin))
        clauses.append(.corroborated)
    case .conflict:
        clauses.append(.conflict)
    case .candidateOnly:
        if explanation.reconciliationRefs.contains(where: {
            if case .inconclusiveCandidate = $0.role { return true }
            return false
        }) {
            clauses.append(.inconclusive)
            return clauses
        }
        switch context.exactQuery {
        case .notStarted:
            clauses.append(.exactNotStarted)
        case .pending:
            clauses.append(.exactPending)
        case .completed(.completed(
            _, let origin, let exhaustiveness
        )):
            clauses.append(.notCorroborated(
                exhaustiveness: exhaustiveness,
                origin: origin
            ))
        case .completed(.unsupported):
            clauses.append(.exactUnsupported)
        case .completed(.notApplicable):
            clauses.append(.exactNotApplicable)
        }
    }
    return clauses
}

public func renderEnglish(_ clause: NarrativeClause) -> String {
    switch clause {
    case .sourceEvidence(let evidence):
        return evidence.map { item in
            switch item {
            case .lexicalBinding: "Matched a lexical binding."
            case .uniqueImport: "Matched an import binding with no competing source match."
            case .sameFile: "Matched a declaration in the same file."
            case .nameOnly: "Matched by name only."
            case .methodNameOnly: "Matched by method name only."
            case .receiverType: "Receiver type narrowed the candidate."
            }
        }.joined(separator: " ")
    case .candidateCompleteness(let completeness):
        return "Candidate generation was \(completenessEnglish(completeness))."
    case .candidateRelationSet(let observation):
        let count = observation.returnedCount
        let noun = count == 1 ? "result" : "results"
        switch observation.completeness {
        case .complete:
            return "The source relation result set was complete with \(count) \(noun)."
        case .partial:
            return "The source relation result set was partial with \(count) \(noun) returned."
        case .truncated:
            if let total = observation.totalCount {
                return "The source relation result set was truncated after \(count) of about \(total) results."
            }
            return "The source relation result set was truncated after \(count) \(noun)."
        case .unknown:
            return "The source relation result set completeness is unknown; \(count) \(noun) were returned."
        }
    case .verified(let origin):
        return "rust-analyzer returned this target from \(originEnglish(origin))."
    case .corroborated:
        return "The source candidate and rust-analyzer target were corroborated."
    case .exactNotStarted:
        return "Exact verification was not attempted."
    case .exactPending:
        return "Exact verification is in progress."
    case .notCorroborated(let exhaustiveness, let origin):
        return "The \(exhaustivenessEnglish(exhaustiveness)) \(originEnglish(origin)) relation query did not corroborate this candidate; absence is not established."
    case .exactUnsupported:
        return "The provider does not support this exact relation query."
    case .exactNotApplicable:
        return "The exact relation query does not apply to this root."
    case .conflict:
        return "rust-analyzer returned a different target; this earlier candidate remains in the correction trail."
    case .inconclusive:
        return "The source candidate and rust-analyzer target could not be compared reliably."
    }
}

private func completenessEnglish(_ completeness: Completeness) -> String {
    switch completeness {
    case .complete: "complete"
    case .partial: "partial"
    case .truncated: "truncated"
    case .unknown: "of unknown completeness"
    }
}

private func exhaustivenessEnglish(
    _ exhaustiveness: QueryExhaustiveness
) -> String {
    switch exhaustiveness {
    case .guaranteed: "exhaustive"
    case .bestEffort: "best-effort"
    case .unknown: "unknown-exhaustiveness"
    }
}

private func originEnglish(_ origin: ExactOrigin) -> String {
    switch origin {
    case .worktree: "worktree"
    case .materialized(let commitOID): "materialized commit \(commitOID)"
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

@MainActor
public final class ResolutionExplanationStore {
    public private(set) var values: [
        ResolutionExplanationID: MaterializedResolutionExplanation
    ] = [:]

    public init() {}

    public func create(
        _ explanation: MaterializedResolutionExplanation
    ) -> ResolutionExplanationID {
        let id = ResolutionExplanationID()
        values[id] = explanation
        return id
    }

    public func update(
        _ id: ResolutionExplanationID,
        to explanation: MaterializedResolutionExplanation
    ) {
        values[id] = explanation
    }

    public func value(
        for id: ResolutionExplanationID
    ) -> MaterializedResolutionExplanation? {
        values[id]
    }

    public func retain(_ ids: Set<ResolutionExplanationID>) {
        values = values.filter { ids.contains($0.key) }
    }

    public func removeAll() {
        values.removeAll(keepingCapacity: true)
    }
}

public struct NavigationExplanation: Sendable {
    public let explanationID: ResolutionExplanationID
    public let observedAtNavigation: ResolutionExplanationSnapshot
    package let frozenInspectorDisplay: ReadingSetExcerpt.FrozenInspectorDisplay?
    package let readingSetRole: String?

    public init(
        explanationID: ResolutionExplanationID,
        observedAtNavigation: ResolutionExplanationSnapshot
    ) {
        self.explanationID = explanationID
        self.observedAtNavigation = observedAtNavigation
        frozenInspectorDisplay = nil
        readingSetRole = nil
    }

    package init(
        explanationID: ResolutionExplanationID,
        observedAtNavigation: ResolutionExplanationSnapshot,
        frozenInspectorDisplay: ReadingSetExcerpt.FrozenInspectorDisplay,
        readingSetRole: String
    ) {
        self.explanationID = explanationID
        self.observedAtNavigation = observedAtNavigation
        self.frozenInspectorDisplay = frozenInspectorDisplay
        self.readingSetRole = readingSetRole
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

public enum TargetComparison: Equatable, Sendable {
    case same
    case different
    case notComparable
}

public struct SourceDestination: Sendable {
    public let file: URL
    public let byteOffset: UInt32?
    public let symbolAnchor: String?

    public init(
        file: URL,
        byteOffset: UInt32? = nil,
        symbolAnchor: String? = nil
    ) {
        self.file = file
        self.byteOffset = byteOffset
        self.symbolAnchor = symbolAnchor
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
    public let revision: String?

    public init(
        path: String,
        contentID: ContentID?,
        byteOffset: UInt32,
        line: UInt32,
        column: UInt32,
        symbolAnchor: String?,
        snapshotID: SnapshotID?,
        revision: String? = nil
    ) {
        self.path = path
        self.contentID = contentID
        self.byteOffset = byteOffset
        self.line = line
        self.column = column
        self.symbolAnchor = symbolAnchor
        self.snapshotID = snapshotID
        self.revision = revision
    }
}

public struct TrailNodeID: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct NavigationRecord: Equatable, Sendable {
    public let jump: JumpRecord
    public let trailNodeID: TrailNodeID?

    public init(jump: JumpRecord, trailNodeID: TrailNodeID? = nil) {
        self.jump = jump
        self.trailNodeID = trailNodeID
    }
}

public struct TrailNode: Sendable {
    public let id: TrailNodeID
    public var jump: JumpRecord

    public init(id: TrailNodeID = TrailNodeID(), jump: JumpRecord) {
        self.id = id
        self.jump = jump
    }
}

public struct TrailEdge: Sendable {
    public let from: TrailNodeID
    public let to: TrailNodeID
    public let cause: NavigationCause
    public let observedAtNavigation: ResolutionExplanationSnapshot?
    public let currentExplanationID: ResolutionExplanationID?
    package let frozenInspectorDisplay: ReadingSetExcerpt.FrozenInspectorDisplay?
    package let readingSetRole: String?

    public init(
        from: TrailNodeID,
        to: TrailNodeID,
        cause: NavigationCause,
        observedAtNavigation: ResolutionExplanationSnapshot? = nil,
        currentExplanationID: ResolutionExplanationID? = nil
    ) {
        self.from = from
        self.to = to
        self.cause = cause
        self.observedAtNavigation = observedAtNavigation
        self.currentExplanationID = currentExplanationID
        frozenInspectorDisplay = nil
        readingSetRole = nil
    }

    package init(
        from: TrailNodeID,
        to: TrailNodeID,
        cause: NavigationCause,
        observedAtNavigation: ResolutionExplanationSnapshot?,
        currentExplanationID: ResolutionExplanationID?,
        frozenInspectorDisplay: ReadingSetExcerpt.FrozenInspectorDisplay?,
        readingSetRole: String?
    ) {
        self.from = from
        self.to = to
        self.cause = cause
        self.observedAtNavigation = observedAtNavigation
        self.currentExplanationID = currentExplanationID
        self.frozenInspectorDisplay = frozenInspectorDisplay
        self.readingSetRole = readingSetRole
    }
}

@MainActor
public final class ReadingTrail {
    public private(set) var nodes: [TrailNodeID: TrailNode] = [:]
    public private(set) var edges: [TrailEdge] = []
    public private(set) var activeNodeID: TrailNodeID?

    public init() {}

    @discardableResult
    public func recordNavigation(
        from current: JumpRecord?,
        to destination: JumpRecord,
        cause: NavigationCause = .relation,
        explanation: NavigationExplanation? = nil
    ) -> TrailNodeID {
        let sourceID = activeNodeID ?? current.map { appendNode($0) }
        if let current, let sourceID,
           nodes[sourceID]?.jump.path == current.path,
           nodes[sourceID]?.jump.snapshotID == current.snapshotID
        {
            nodes[sourceID]?.jump = current
        }
        let destinationID = appendNode(destination)
        if let sourceID {
            edges.append(TrailEdge(
                from: sourceID,
                to: destinationID,
                cause: cause,
                observedAtNavigation: explanation?.observedAtNavigation,
                currentExplanationID: explanation?.explanationID,
                frozenInspectorDisplay: explanation?.frozenInspectorDisplay,
                readingSetRole: explanation?.readingSetRole
            ))
        }
        activeNodeID = destinationID
        return destinationID
    }

    public func restore(_ id: TrailNodeID?) {
        activeNodeID = id.flatMap { nodes[$0] == nil ? nil : $0 }
    }

    public var referencedExplanationIDs: Set<ResolutionExplanationID> {
        Set(edges.compactMap(\.currentExplanationID))
    }

    public func reset() {
        nodes.removeAll(keepingCapacity: true)
        edges.removeAll(keepingCapacity: true)
        activeNodeID = nil
    }

    private func appendNode(_ jump: JumpRecord) -> TrailNodeID {
        let node = TrailNode(jump: jump)
        nodes[node.id] = node
        return node.id
    }
}

@MainActor
public final class NavigationHistory {
    public private(set) var navigationRecords: [NavigationRecord] = []
    public var records: [JumpRecord] { navigationRecords.map(\.jump) }
    public private(set) var cursor = 0

    private static let limit = 200
    private var forwardRecord: NavigationRecord?

    public init() {}

    public var canGoBack: Bool {
        cursor > 0
    }

    public var canGoForward: Bool {
        cursor + 1 < records.count
            || (cursor + 1 == records.count && forwardRecord != nil)
    }

    public func push(_ record: JumpRecord) {
        push(NavigationRecord(jump: record))
    }

    public func push(_ record: NavigationRecord) {
        if cursor < records.count {
            navigationRecords.removeSubrange((cursor + 1)..<records.count)
            if records.indices.contains(cursor),
               records[cursor].path == record.jump.path
            {
                navigationRecords[cursor] = record
                forwardRecord = nil
                cursor = records.count
                return
            }
        }
        forwardRecord = nil
        if navigationRecords.last?.jump != record.jump
            || navigationRecords.last?.trailNodeID != record.trailNodeID
        {
            navigationRecords.append(record)
        }
        if records.count > Self.limit {
            navigationRecords.removeFirst(records.count - Self.limit)
        }
        cursor = records.count
    }

    public func goBack(from current: JumpRecord) -> JumpRecord? {
        goBack(from: NavigationRecord(jump: current))?.jump
    }

    public func goBack(from current: NavigationRecord) -> NavigationRecord? {
        guard canGoBack else { return nil }
        if cursor == records.count {
            forwardRecord = current
        }
        cursor -= 1
        return navigationRecords[cursor]
    }

    public func goForward() -> JumpRecord? {
        goForwardRecord()?.jump
    }

    public func goForwardRecord() -> NavigationRecord? {
        guard canGoForward else { return nil }
        if cursor + 1 < records.count {
            cursor += 1
            return navigationRecords[cursor]
        }
        cursor += 1
        return forwardRecord
    }

    public func reset() {
        navigationRecords.removeAll(keepingCapacity: true)
        cursor = 0
        forwardRecord = nil
    }
}
