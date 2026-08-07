import CodeInsightCore
import CodeInsightEngine
import CodeInsightExact
import CodeInsightReaderCore
import Foundation
import Observation

public enum ReferenceTarget: Sendable {
    case engine(SymbolOccurrenceID)
    case localBinding(pathID: PathID, bindingIndex: UInt32)
}

@MainActor
@Observable
public final class RelationTreeModel {
    public enum Direction: Hashable, Sendable {
        case callers
        case calls
        case implementations
        case references
    }

    public final class Node {
        public enum ExpansionIdentity: Sendable {
            case engine(SymbolOccurrenceID)
            case exact(ExactCallHierarchyItem)
        }

        public enum Kind: Hashable, Sendable {
            case root
            case group
            case edge
            case evidenceLine
            case truncated
            case loading
            case error
        }

        public let kind: Kind
        public fileprivate(set) var title: String
        public fileprivate(set) var subtitle: String?
        public fileprivate(set) var badge: String?
        public fileprivate(set) var dispatchLabel: String?
        public fileprivate(set) var modifiers: [String]
        public fileprivate(set) var target: (path: String, byteOffset: UInt32)?
        public fileprivate(set) var line: UInt32?
        public fileprivate(set) var symbol: SymbolOccurrenceID?
        public let representsLocation: Bool
        public fileprivate(set) var expansionIdentity: ExpansionIdentity?
        public fileprivate(set) var explanation: RelationRowExplanation?
        public internal(set) var explanationID: ResolutionExplanationID?
        public fileprivate(set) var children: [Node]?
        public fileprivate(set) var isExpandable: Bool

        fileprivate weak var parent: Node?
        fileprivate var evidence: [ResolutionEvidence]
        fileprivate let cycleKey: CycleKey?
        fileprivate(set) var queryTarget: (path: String, byteOffset: UInt32)?
        fileprivate var callSites: [ExactLocation]
        fileprivate var nextCallSiteIndex = 0
        fileprivate var loadRequestID: UInt64?
        fileprivate var loadTask: Task<Void, Never>?
        fileprivate var loadedEdge: LoadedEdge?

        fileprivate init(
            kind: Kind,
            title: String,
            subtitle: String? = nil,
            badge: String? = nil,
            dispatchLabel: String? = nil,
            modifiers: [String] = [],
            target: (path: String, byteOffset: UInt32)? = nil,
            line: UInt32? = nil,
            children: [Node]? = [],
            isExpandable: Bool = false,
            parent: Node? = nil,
            symbol: SymbolOccurrenceID? = nil,
            representsLocation: Bool = false,
            expansionIdentity: ExpansionIdentity? = nil,
            explanation: RelationRowExplanation? = nil,
            explanationID: ResolutionExplanationID? = nil,
            evidence: [ResolutionEvidence] = [],
            cycleKey: CycleKey? = nil,
            queryTarget: (path: String, byteOffset: UInt32)? = nil,
            callSites: [ExactLocation] = [],
            loadedEdge: LoadedEdge? = nil
        ) {
            self.kind = kind
            self.title = title
            self.subtitle = subtitle
            self.badge = badge
            self.dispatchLabel = dispatchLabel
            self.modifiers = modifiers
            self.target = target
            self.line = line
            self.children = children
            self.isExpandable = isExpandable
            self.parent = parent
            self.symbol = symbol
            self.representsLocation = representsLocation
            self.expansionIdentity = expansionIdentity
            self.explanation = explanation
            self.explanationID = explanationID
            self.evidence = evidence
            self.cycleKey = cycleKey
            self.queryTarget = queryTarget
            self.callSites = callSites
            self.loadedEdge = loadedEdge
        }
    }

    struct LoadedEdge: Sendable {
        let title: String
        var certainty: Certainty
        let dispatch: DispatchKind
        let symbol: SymbolOccurrenceID?
        let path: String
        let byteOffset: UInt32
        let line: UInt32
        let evidence: [ResolutionEvidence]
        var candidate: CandidateObservation?
        let exactQuery: (file: String, byteOffset: UInt32, line: UInt32)?
        let fuzzyTarget: (file: String, byteOffset: UInt32)?
        let identityTarget: (file: String, byteOffset: UInt32)?
        let exactItem: ExactCallHierarchyItem?
        var callSites: [ExactLocation]
        var exactOrigin: ExactOrigin?
        var explanation: RelationRowExplanation?
        var isCorrectedCandidate: Bool

        init(
            title: String,
            certainty: Certainty,
            dispatch: DispatchKind,
            symbol: SymbolOccurrenceID?,
            path: String,
            byteOffset: UInt32,
            line: UInt32,
            evidence: [ResolutionEvidence],
            candidate: CandidateObservation? = nil,
            exactQuery: (file: String, byteOffset: UInt32, line: UInt32)? = nil,
            fuzzyTarget: (file: String, byteOffset: UInt32)? = nil,
            identityTarget: (file: String, byteOffset: UInt32)? = nil,
            exactItem: ExactCallHierarchyItem? = nil,
            callSites: [ExactLocation] = [],
            exactOrigin: ExactOrigin? = nil,
            explanation: RelationRowExplanation? = nil,
            isCorrectedCandidate: Bool = false
        ) {
            self.title = title
            self.certainty = certainty
            self.dispatch = dispatch
            self.symbol = symbol
            self.path = path
            self.byteOffset = byteOffset
            self.line = line
            self.evidence = evidence
            self.candidate = candidate
            self.exactQuery = exactQuery
            self.fuzzyTarget = fuzzyTarget
            self.identityTarget = identityTarget
            self.exactItem = exactItem
            self.callSites = callSites
            self.exactOrigin = exactOrigin
            self.explanation = explanation
            self.isCorrectedCandidate = isCorrectedCandidate
        }
    }

    enum ExactState: Sendable {
        case legacy
        case unsupported
        case notApplicable
        case queried(ExactAnalysisEnvironment)
    }

    struct LoadResult: Sendable {
        let edges: [LoadedEdge]
        let isTruncated: Bool
        var exactState: ExactState = .legacy
    }

    typealias Loader = @Sendable (
        EngineSession,
        QueryContext,
        SymbolOccurrenceID,
        Direction
    ) async throws -> LoadResult
    typealias ExactResolver = @MainActor @Sendable (
        String,
        UInt32,
        UInt64,
        ExactRequestBatch
    ) async -> ExactCoordinator.DefinitionResult?
    typealias ExactRelationsResolver = @MainActor @Sendable (
        String,
        UInt32,
        ExactCallHierarchyItem?,
        Direction,
        UInt64,
        ExactRequestBatch
    ) async -> ExactCoordinator.RelationQueryResult?

    public private(set) var root: Node?
    public private(set) var direction: Direction = .callers
    public private(set) var generation: UInt64 = 0
    public private(set) var requestID: UInt64 = 0
    public private(set) var selectedRelationSymbol: SymbolOccurrenceID?
    public private(set) var heuristicCandidateCount = 0
    public private(set) var relationQueryContexts: [
        RelationQueryContextID: RelationQueryContext
    ] = [:]
    public static let possibleValidationBatchSize = 32
    public var onSelect: @MainActor (Node) -> Void = { _ in }
    public var onNodeChange: @MainActor (Node) -> Void = { _ in }
    public var onExplanationChange: @MainActor (Node) -> Void = { _ in }
    public var onContextsReset: @MainActor () -> Void = {}
    public var hasTruncatedResults: Bool {
        root.map(Self.containsTruncatedNode) ?? false
    }

    private let loader: Loader
    private let queryTimeout: Duration
    private var exactResolver: ExactResolver?
    private var exactRelationsResolver: ExactRelationsResolver?
    private var exactBatch: ExactRequestBatch?
    private var possibleValidationBatch: ExactRequestBatch?
    private var scheduledPossibleRows: Set<ObjectIdentifier> = []
    private var cancelExactBatch: (@MainActor (ExactRequestBatch) -> Void)?
    private var session: EngineSession?
    private var context: QueryContext?

    public init() {
        loader = { session, context, symbol, direction in
            try await Self.load(
                session: session,
                context: context,
                symbol: symbol,
                direction: direction
            )
        }
        queryTimeout = .seconds(30)
        exactResolver = nil
        exactRelationsResolver = nil
    }

    init(
        loader: @escaping Loader,
        exactResolver: ExactResolver? = nil,
        exactRelationsResolver: ExactRelationsResolver? = nil,
        queryTimeout: Duration = .seconds(30)
    ) {
        self.loader = loader
        self.queryTimeout = queryTimeout
        self.exactResolver = exactResolver
        self.exactRelationsResolver = exactRelationsResolver
    }

    func attachExactCoordinator(_ coordinator: ExactCoordinator) {
        exactResolver = { [weak coordinator] file, offset, generation, batch in
            await coordinator?.definition(
                file: file,
                byteOffset: offset,
                generation: generation,
                batch: batch
            )
        }
        exactRelationsResolver = {
            [weak coordinator] file, offset, item, direction, generation, batch in
            await coordinator?.relations(
                file: file,
                byteOffset: offset,
                item: item,
                direction: direction,
                generation: generation,
                batch: batch
            )
        }
        cancelExactBatch = { [weak coordinator] batch in
            coordinator?.cancel(batch: batch)
        }
    }

    public func updateProjectState(_ state: ProjectState) {
        cancelLoads()
        generation &+= 1
        requestID &+= 1
        root = nil
        selectedRelationSymbol = nil
        heuristicCandidateCount = 0
        relationQueryContexts.removeAll()
        onContextsReset()
        switch state {
        case let .ready(session, context):
            self.session = session
            self.context = context
        case .indexing:
            session = nil
            context = nil
            root = Node(kind: .loading, title: "Index building…")
        case .empty, .failed:
            session = nil
            context = nil
        }
    }

    @discardableResult
    public func setRoot(
        target: ReferenceTarget,
        direction: Direction,
        document: ReaderDocument? = nil
    ) -> Task<Void, Never>? {
        cancelLoads()
        generation &+= 1
        self.direction = direction
        selectedRelationSymbol = nil
        heuristicCandidateCount = 0
        relationQueryContexts.removeAll()
        onContextsReset()
        switch target {
        case let .localBinding(pathID, bindingIndex):
            guard direction == .references,
                  let session,
                  let document,
                  let file = session.manifest.files.first(where: {
                      $0.pathID == pathID && $0.contentID == document.contentID
                  }),
                  let index = Int(exactly: bindingIndex),
                  document.localBindings.indices.contains(index)
            else {
                root = nil
                return nil
            }
            let binding = document.localBindings[index]
            guard binding.kind == .param || binding.kind == .letBinding,
                  let coordinate = document.lineTable.lineColumn(
                      at: binding.declarationRange.lowerBound
                  ),
                  let title = Self.bindingTitle(binding, in: document)
            else {
                root = nil
                return nil
            }
            let path = session.paths.resolve(file.pathID)
            let node = Node(
                kind: .root,
                title: title,
                subtitle: binding.kind == .param ? "Parameter" : "Local",
                target: (path, binding.declarationRange.lowerBound),
                line: coordinate.line,
                children: [],
                cycleKey: Self.cycleKey(
                    path: path,
                    byteOffset: binding.declarationRange.lowerBound
                )
            )
            node.children = makeReferenceChildren(
                document.referencesByBinding[index],
                path: path,
                bindingKind: binding.kind,
                under: node,
                document: document
            )
            root = node
            return nil

        case let .engine(symbol):
            return setEngineRoot(symbol, direction: direction)
        }
    }

    private func setEngineRoot(
        _ symbol: SymbolOccurrenceID,
        direction: Direction
    ) -> Task<Void, Never>? {
        guard let session, let location = Self.location(for: symbol, in: session),
              let title = Self.symbolTitle(symbol, in: session)
        else {
            root = nil
            return nil
        }

        let node = Node(
            kind: .root,
            title: title,
            target: (location.path, location.byteOffset),
            line: location.line,
            children: nil,
            isExpandable: Self.canExpand(
                symbol,
                direction: direction,
                session: session
            ),
            symbol: symbol,
            expansionIdentity: .engine(symbol),
            cycleKey: Self.cycleKey(
                path: location.path,
                byteOffset: location.byteOffset
            ),
            queryTarget: (location.path, location.byteOffset)
        )
        if !node.isExpandable { node.children = [] }
        root = node
        exactBatch = ExactRequestBatch()
        return expansionTask(for: node)
    }

    private func makeReferenceChildren(
        _ references: [CodeInsightCore.ByteRange],
        path: String,
        bindingKind: BindingKind,
        under parent: Node,
        document: ReaderDocument
    ) -> [Node] {
        let label = bindingKind == .param ? "Parameter reference" : "Local reference"
        let rows = references.prefix(500).compactMap { range -> Node? in
            guard let coordinate = document.lineTable.lineColumn(at: range.lowerBound)
            else { return nil }
            return Node(
                kind: .edge,
                title: "\(URL(fileURLWithPath: path).lastPathComponent):"
                    + "\(coordinate.line):\(coordinate.column)",
                subtitle: label,
                badge: "Inferred",
                target: (path, range.lowerBound),
                line: coordinate.line,
                children: [],
                isExpandable: false,
                parent: parent,
                representsLocation: true,
                cycleKey: Self.cycleKey(path: path, byteOffset: range.lowerBound)
            )
        }
        guard references.count > 500 else { return rows }
        return rows + [
            Node(
                kind: .truncated,
                title: "Showing first 500 of \(references.count) references",
                parent: parent
            ),
        ]
    }

    public func expand(_ node: Node) async {
        await expansionTask(for: node)?.value
    }

    public func select(_ node: Node) {
        if !node.callSites.isEmpty {
            let callSite = node.callSites[node.nextCallSiteIndex % node.callSites.count]
            if let offset = UInt32(exactly: callSite.byteOffset),
               let line = UInt32(exactly: callSite.line)
            {
                node.target = (callSite.file, offset)
                node.line = line
            }
            node.nextCallSiteIndex = (node.nextCallSiteIndex + 1)
                % node.callSites.count
        }
        selectedRelationSymbol = node.kind == .edge
            && node.symbol?.localKind == .declarationFacet
            ? node.symbol
            : nil
        onSelect(node)
    }

    public func clearSelection() {
        selectedRelationSymbol = nil
    }

    public func validatePossible(_ nodes: [Node]) {
        guard exactResolver != nil, let context else { return }
        let candidates = nodes.compactMap { node -> (Node, LoadedEdge)? in
            guard node.kind == .edge,
                  let edge = node.loadedEdge,
                  edge.certainty == .probable || edge.certainty == .possible,
                  edge.exactQuery != nil,
                  edge.fuzzyTarget != nil,
                  !scheduledPossibleRows.contains(ObjectIdentifier(node))
            else { return nil }
            return (node, edge)
        }.prefix(Self.possibleValidationBatchSize)
        guard !candidates.isEmpty, let parent = candidates.first?.0.parent else {
            return
        }
        scheduledPossibleRows.formUnion(
            candidates.map { ObjectIdentifier($0.0) }
        )
        let batch = possibleValidationBatch ?? ExactRequestBatch()
        possibleValidationBatch = batch
        let currentGeneration = generation
        let direction = direction
        let rows = candidates.map(\.0)
        let loaded = LoadResult(
            edges: candidates.map(\.1),
            isTruncated: false
        )
        Task { [weak self, weak parent] in
            guard let self, let parent else { return }
            let promoted = await promoteExactEdges(
                loaded,
                direction: direction,
                generation: context.generation,
                batch: batch
            )
            guard batch.isCurrent,
                  possibleValidationBatch === batch,
                  generation == currentGeneration
            else { return }
            let container = parent.kind == .group ? parent.parent : parent
            guard let container else { return }
            let selectedIDs = Dictionary(
                uniqueKeysWithValues: zip(rows, promoted.edges.prefix(rows.count))
                    .map { (ObjectIdentifier($0.0), $0.1) }
            )
            var combined = relationEdgeRows(in: container).compactMap { row in
                selectedIDs[ObjectIdentifier(row)] ?? row.loadedEdge
            }
            combined += promoted.edges.dropFirst(rows.count)
            let wasTruncated = container.children?.contains {
                $0.kind == .truncated
                    && $0.title == "Results truncated upstream"
            } == true
            let children = makeChildren(
                from: LoadResult(
                    edges: Self.deduplicateExact(combined),
                    isTruncated: wasTruncated
                ),
                under: container,
                direction: direction
            )
            container.children = reusingPublishedRows(
                children,
                from: container.children ?? [],
                parent: container
            )
            onNodeChange(container)
        }
    }

    public func cancelPossibleValidation() {
        guard let possibleValidationBatch else { return }
        possibleValidationBatch.cancel()
        cancelExactBatch?(possibleValidationBatch)
        self.possibleValidationBatch = nil
        scheduledPossibleRows.removeAll()
    }

    public func materializedExplanation(
        for node: Node
    ) -> MaterializedResolutionExplanation? {
        guard let explanation = node.explanation else { return nil }
        let context = relationQueryContexts[explanation.contextID]
        let trace: MaterializedResolutionTrace
        switch explanation.primaryTrace {
        case .candidateOnly(let candidate):
            trace = .candidateOnly(candidate)
        case .verificationOnly(let verification):
            trace = .verificationOnly(verification)
        case .corroborated(let candidate, let verification):
            trace = .corroborated(
                candidate: candidate,
                verification: verification
            )
        case .conflict(let candidate, let reference):
            guard let reconciliation = context?
                .reconciliations[reference.reconciliationID]
            else { return nil }
            trace = .conflict(
                candidate: candidate,
                reconciliation: ReconciliationSnapshot(reconciliation)
            )
        }
        let candidateRelationSet: RelationSetObservation? = if case
            .completed(let observation) = context?.candidateQuery
        {
            observation
        } else {
            nil
        }
        let relationQuery: RelationQueryObservation? = if case
            .completed(let observation) = context?.exactQuery
        {
            observation
        } else {
            nil
        }
        let facts = context == nil ? nil : RelationFactsSnapshot(
            candidateRelationSet: candidateRelationSet,
            relationQuery: relationQuery
        )
        return MaterializedResolutionExplanation(
            trace: trace,
            relationFacts: facts
        )
    }

    private func cancelLoads() {
        cancelPossibleValidation()
        if let exactBatch {
            exactBatch.cancel()
            cancelExactBatch?(exactBatch)
            self.exactBatch = nil
        }
        func cancel(_ node: Node) {
            node.loadTask?.cancel()
            for child in node.children ?? [] { cancel(child) }
        }
        if let root { cancel(root) }
    }

    private func expansionTask(for node: Node) -> Task<Void, Never>? {
        guard node.isExpandable, node.children == nil,
              let identity = node.expansionIdentity, let session, let context,
              let exactBatch
        else { return nil }

        requestID &+= 1
        let currentRequestID = requestID
        let currentGeneration = generation
        node.loadRequestID = currentRequestID
        node.children = [Node(kind: .loading, title: "Loading…", parent: node)]

        let loader = self.loader
        let exactRelationsResolver = self.exactRelationsResolver
        let direction = self.direction
        let queryTimeout = self.queryTimeout
        let task = Task { [weak self, weak node] in
            guard let self, let node else { return }
            var loaded = LoadResult(edges: [], isTruncated: false)
            var engineLoadFailed = false
            var exactResult: ExactCoordinator.RelationQueryResult?
            var hasEngineResult = false
            var pendingQueryCount = 0
            let relationContextID = RelationQueryContextID()
            let hasCandidateQuery: Bool = if case .engine = identity {
                true
            } else {
                false
            }
            let exactItem: ExactCallHierarchyItem? = if case let .exact(item) = identity {
                item
            } else {
                nil
            }
            let query = node.queryTarget ?? node.target
            let (updates, continuation) = AsyncStream<(
                loaded: LoadResult?,
                exact: ExactCoordinator.RelationQueryResult?,
                engineFailed: Bool,
                timedOut: Bool
            )>.makeStream()
            var queryTasks: [Task<Void, Never>] = []
            if case let .engine(symbol) = identity {
                pendingQueryCount += 1
                queryTasks.append(Task.detached(priority: .userInitiated) {
                    guard !Task.isCancelled else { return }
                    do {
                        continuation.yield((
                            try await loader(session, context, symbol, direction),
                            nil,
                            false,
                            false
                        ))
                    } catch {
                        continuation.yield((nil, nil, true, false))
                    }
                })
            }
            if let exactRelationsResolver, let query {
                pendingQueryCount += 1
                queryTasks.append(Task { @MainActor in
                    guard !Task.isCancelled else { return }
                    continuation.yield((
                        nil,
                        await exactRelationsResolver(
                            query.path,
                            query.byteOffset,
                            exactItem,
                            direction,
                            context.generation,
                            exactBatch
                        ),
                        false,
                        false
                    ))
                })
            }
            relationQueryContexts[relationContextID] = RelationQueryContext(
                candidateQuery: hasCandidateQuery
                    ? .pending
                    : .completed(RelationSetObservation(
                        completeness: .complete,
                        returnedCount: 0
                    )),
                exactQuery: exactRelationsResolver != nil && query != nil
                    ? .pending
                    : .notStarted
            )
            if pendingQueryCount == 0 { continuation.finish() }
            let timeoutTask = Task.detached {
                do {
                    try await Task.sleep(for: queryTimeout)
                } catch {
                    return
                }
                continuation.yield((nil, nil, false, true))
                continuation.finish()
            }
            defer {
                timeoutTask.cancel()
                queryTasks.forEach { $0.cancel() }
                continuation.finish()
            }

            await withTaskCancellationHandler {
                for await result in updates {
                    if result.timedOut {
                        pendingQueryCount = 0
                        if !hasEngineResult { engineLoadFailed = true }
                    } else {
                        pendingQueryCount -= 1
                    }
                    guard generation == currentGeneration,
                          node.loadRequestID == currentRequestID,
                          self.session === session
                    else {
                        return
                    }
                    if let engineResult = result.loaded {
                        loaded = engineResult
                        hasEngineResult = true
                        heuristicCandidateCount = engineResult.edges.count
                        relationQueryContexts[relationContextID]?.candidateQuery =
                            .completed(RelationSetObservation(
                                completeness: engineResult.isTruncated
                                    ? .truncated
                                    : .complete,
                                returnedCount: engineResult.edges.count
                            ))
                    } else if result.engineFailed {
                        engineLoadFailed = true
                        relationQueryContexts[relationContextID]?.candidateQuery = .failed
                    } else {
                        exactResult = result.exact
                        if let exactResult {
                            relationQueryContexts[relationContextID]?.exactQuery =
                                .completed(Self.relationQueryObservation(exactResult))
                        }
                    }
                    guard hasEngineResult || exactResult != nil else {
                        if pendingQueryCount == 0 { break }
                        continue
                    }
                    let displayed = if let exactResult {
                        mergeExact(
                            exactResult,
                            into: loaded,
                            direction: direction,
                            session: session,
                            contextID: relationContextID
                        )
                    } else {
                        LoadResult(
                            edges: candidateOnlyEdges(
                                loaded.edges,
                                contextID: relationContextID
                            ),
                            isTruncated: loaded.isTruncated,
                            exactState: loaded.exactState
                        )
                    }
                    var children = makeChildren(
                        from: displayed,
                        under: node,
                        direction: direction
                    )
                    if pendingQueryCount > 0 {
                        children.removeAll {
                            ($0.kind == .group && $0.children?.isEmpty == true)
                                || ($0.kind == .truncated
                                    && ($0.title.hasPrefix("Verified ")
                                        || $0.title.hasPrefix("No verified ")
                                        || $0.title.hasPrefix("Analysis limited:")))
                        }
                        children.append(Node(
                            kind: .loading,
                            title: "Loading…",
                            parent: node
                        ))
                    }
                    node.children = preservingPublishedRows(
                        children,
                        from: node.children
                    )
                    onNodeChange(node)
                    if pendingQueryCount == 0 { break }
                }
            } onCancel: {
                continuation.finish()
            }
            guard !Task.isCancelled,
                  generation == currentGeneration,
                  node.loadRequestID == currentRequestID,
                  self.session === session
            else { return }
            if (engineLoadFailed && exactResult == nil)
                || (exactItem != nil && exactResult == nil)
            {
                node.children = [
                    Node(
                        kind: .error,
                        title: "Could not load relations.",
                        parent: node
                    ),
                ] + evidenceNodes(node.evidence, parent: node)
                onNodeChange(node)
            }
        }
        node.loadTask = task
        return task
    }

    private func promoteExactEdges(
        _ loaded: LoadResult,
        direction: Direction,
        generation: UInt64,
        batch: ExactRequestBatch
    ) async -> LoadResult {
        guard let exactResolver, let session else { return loaded }
        var edges = loaded.edges
        var grouped: [SourceLocation: [Int]] = [:]
        var groupOrder: [SourceLocation] = []
        for (index, edge) in edges.prefix(500).enumerated() {
            guard let query = edge.exactQuery,
                  edge.fuzzyTarget != nil,
                  candidateObservation(for: edge) != nil
            else { continue }
            let site = SourceLocation(
                path: query.file,
                byteOffset: query.byteOffset,
                line: query.line
            )
            if grouped[site] == nil { groupOrder.append(site) }
            grouped[site, default: []].append(index)
        }
        guard !groupOrder.isEmpty else { return loaded }

        var results: [SourceLocation: ExactCoordinator.DefinitionResult] = [:]
        await withTaskGroup(
            of: (SourceLocation, ExactCoordinator.DefinitionResult?).self
        ) { group in
            for site in groupOrder {
                group.addTask {
                    let exact = await exactResolver(
                        site.path,
                        site.byteOffset,
                        generation,
                        batch
                    )
                    return (site, exact)
                }
            }
            for await (site, result) in group {
                if let result { results[site] = result }
            }
        }

        let contextID = RelationQueryContextID()
        var context = RelationQueryContext(candidateQuery: .completed(
            RelationSetObservation(
                completeness: loaded.isTruncated ? .truncated : .complete,
                returnedCount: loaded.edges.count,
                totalCount: loaded.isTruncated ? nil : loaded.edges.count
            )
        ))
        var additions: [LoadedEdge] = []
        for site in groupOrder {
            guard case .completed(let entries) = results[site],
                  let indexes = grouped[site]
            else { continue }
            let candidatePairs = indexes.compactMap { index in
                candidateObservation(for: edges[index]).map { (index, $0) }
            }
            let candidates = candidatePairs.map(\.1)
            let providerTargets: [VerificationObservation] = entries.compactMap {
                entry in
                guard UInt32(exactly: entry.location.byteOffset) != nil,
                      UInt32(exactly: entry.location.line).map({ $0 > 0 }) == true
                else { return nil }
                return VerificationObservation(
                    target: ExactTarget(location: entry.location),
                    attribution: entry.attribution,
                    origin: entry.origin
                )
            }
            var roles: [ReconciliationRole] = []
            var matchedTargets: Set<Int> = []
            var candidateRoles: [Int: ReconciliationRole] = [:]
            for (candidateIndex, candidate) in candidates.enumerated() {
                let edge = edges[candidatePairs[candidateIndex].0]
                let comparisons = providerTargets.map {
                    Self.compare(
                        candidate: .candidate(candidate.target),
                        exact: $0.target,
                        candidateLocation: edge.fuzzyTarget,
                        in: session
                    )
                }
                let role: ReconciliationRole
                if let targetIndex = comparisons.firstIndex(where: {
                    if case .same = $0 { return true }
                    return false
                }) {
                    role = .corroborated(
                        candidateIndex: candidateIndex,
                        targetIndex: targetIndex
                    )
                    matchedTargets.insert(targetIndex)
                } else if comparisons.isEmpty {
                    role = .notCorroboratedCandidate(
                        candidateIndex: candidateIndex
                    )
                } else if comparisons.allSatisfy({
                    if case .different = $0 { return true }
                    return false
                }) {
                    role = .correctedCandidate(candidateIndex: candidateIndex)
                } else {
                    role = .inconclusiveCandidate(candidateIndex: candidateIndex)
                }
                roles.append(role)
                candidateRoles[candidateIndex] = role
            }
            for targetIndex in providerTargets.indices
                where !matchedTargets.contains(targetIndex)
            {
                roles.append(.providerOnly(targetIndex: targetIndex))
            }
            let reconciliation = CallSiteReconciliation(
                querySite: site,
                candidates: candidates,
                providerTargets: providerTargets,
                roles: roles
            )
            context.reconciliations[reconciliation.id] = reconciliation
            let refs = roles.map {
                ReconciliationRef(
                    contextID: contextID,
                    reconciliationID: reconciliation.id,
                    role: $0
                )
            }

            for (candidateIndex, pair) in candidatePairs.enumerated() {
                let (edgeIndex, candidate) = pair
                guard let role = candidateRoles[candidateIndex] else { continue }
                let ref = ReconciliationRef(
                    contextID: contextID,
                    reconciliationID: reconciliation.id,
                    role: role
                )
                switch role {
                case .corroborated(_, let targetIndex):
                    edges[edgeIndex] = verificationEdge(
                        providerTargets[targetIndex],
                        replacing: edges[edgeIndex],
                        direction: direction,
                        explanation: RelationRowExplanation(
                            primaryTrace: .corroborated(
                                candidate: candidate,
                                verification: providerTargets[targetIndex]
                            ),
                            contextID: contextID,
                            reconciliationRefs: refs
                        )
                    )
                case .correctedCandidate:
                    edges[edgeIndex].isCorrectedCandidate = true
                    edges[edgeIndex].explanation = RelationRowExplanation(
                        primaryTrace: .conflict(
                            candidate: candidate,
                            reconciliation: ref
                        ),
                        contextID: contextID,
                        reconciliationRefs: [ref]
                    )
                case .inconclusiveCandidate, .notCorroboratedCandidate:
                    edges[edgeIndex].explanation = RelationRowExplanation(
                        primaryTrace: .candidateOnly(candidate),
                        contextID: contextID,
                        reconciliationRefs: [ref]
                    )
                case .providerOnly:
                    break
                }
            }
            for targetIndex in providerTargets.indices
                where !matchedTargets.contains(targetIndex)
            {
                let exemplar = edges[candidatePairs.first?.0 ?? indexes[0]]
                additions.append(verificationEdge(
                    providerTargets[targetIndex],
                    replacing: exemplar,
                    direction: direction,
                    providerOnly: true,
                    explanation: RelationRowExplanation(
                        primaryTrace: .verificationOnly(
                            providerTargets[targetIndex]
                        ),
                        contextID: contextID,
                        reconciliationRefs: refs
                    )
                ))
            }
        }
        if !context.reconciliations.isEmpty {
            relationQueryContexts[contextID] = context
        }
        edges += additions
        return LoadResult(edges: edges, isTruncated: loaded.isTruncated)
    }

    private func candidateObservation(
        for edge: LoadedEdge
    ) -> CandidateObservation? {
        if let candidate = edge.candidate { return candidate }
        guard let symbol = edge.symbol else { return nil }
        return CandidateObservation(
            target: .occurrence(symbol),
            certainty: edge.certainty,
            dispatch: edge.dispatch,
            provenance: .fuzzyResolver,
            completeness: .unknown,
            evidence: edge.evidence
        )
    }

    nonisolated static func compare(
        candidate: ObservedTarget,
        exact: ExactTarget,
        in session: EngineSession
    ) -> TargetComparison {
        guard case .candidate(.occurrence(let candidateID)) = candidate,
              let candidateLocation = location(for: candidateID, in: session)
        else { return .notComparable }
        if let exactID = symbol(at: exact.location, in: session) {
            return exactID == candidateID ? .same : .different
        }
        guard normalizedPath(candidateLocation.path)
                == normalizedPath(exact.location.file),
              candidateLocation.byteOffset
                == UInt32(exactly: exact.location.byteOffset)
        else { return .notComparable }
        return .same
    }

    private nonisolated static func compare(
        candidate: ObservedTarget,
        exact: ExactTarget,
        candidateLocation: (file: String, byteOffset: UInt32)?,
        in session: EngineSession
    ) -> TargetComparison {
        if let candidateLocation,
              normalizedPath(candidateLocation.file)
                == normalizedPath(exact.location.file),
              candidateLocation.byteOffset
                == UInt32(exactly: exact.location.byteOffset)
        {
            return .same
        }
        return compare(candidate: candidate, exact: exact, in: session)
    }

    private func verificationEdge(
        _ verification: VerificationObservation,
        replacing edge: LoadedEdge,
        direction: Direction,
        providerOnly: Bool = false,
        explanation: RelationRowExplanation
    ) -> LoadedEdge {
        let location = verification.target.location
        let byteOffset = UInt32(location.byteOffset)
        let line = UInt32(location.line)
        let symbol = session.flatMap { Self.symbol(at: location, in: $0) }
        return LoadedEdge(
            title: providerOnly
                ? symbol.flatMap { symbol in
                    session.flatMap { Self.symbolTitle(symbol, in: $0) }
                } ?? Self.locationTitle(location)
                : edge.title,
            certainty: .exact,
            dispatch: direction == .implementations
                ? .traitDispatch
                : edge.dispatch,
            symbol: symbol,
            path: location.file,
            byteOffset: byteOffset,
            line: line,
            evidence: [],
            identityTarget: (location.file, byteOffset),
            exactOrigin: verification.origin,
            explanation: explanation
        )
    }

    private func mergeExact(
        _ result: ExactCoordinator.RelationQueryResult,
        into loaded: LoadResult,
        direction: Direction,
        session: EngineSession,
        contextID: RelationQueryContextID
    ) -> LoadResult {
        switch result {
        case .unsupported:
            return LoadResult(
                edges: candidateOnlyEdges(loaded.edges, contextID: contextID),
                isTruncated: loaded.isTruncated,
                exactState: .unsupported
            )
        case .notApplicable:
            return LoadResult(
                edges: candidateOnlyEdges(loaded.edges, contextID: contextID),
                isTruncated: loaded.isTruncated,
                exactState: .notApplicable
            )
        case let .relations(relations, origin, attribution):
            var exactEdges = relations.compactMap { relation -> LoadedEdge? in
                guard let byteOffset = UInt32(exactly: relation.location.byteOffset),
                      let line = UInt32(exactly: relation.location.line),
                      line > 0
                else { return nil }
                let symbol = Self.symbol(
                    at: relation.location,
                    in: session
                )
                let verification = VerificationObservation(
                    target: ExactTarget(location: relation.location),
                    attribution: attribution,
                    origin: origin
                )
                return LoadedEdge(
                    title: relation.name
                        ?? symbol.flatMap { Self.symbolTitle($0, in: session) }
                        ?? Self.locationTitle(relation.location),
                    certainty: .exact,
                    dispatch: direction == .implementations
                        ? .traitDispatch
                        : .direct,
                    symbol: symbol,
                    path: relation.location.file,
                    byteOffset: byteOffset,
                    line: line,
                    evidence: [],
                    identityTarget: direction == .references ? nil : (
                        relation.location.file,
                        byteOffset
                    ),
                    exactItem: relation.item,
                    callSites: relation.callSites.filter {
                        UInt32(exactly: $0.byteOffset) != nil
                            && UInt32(exactly: $0.line).map { $0 > 0 } == true
                    },
                    exactOrigin: origin,
                    explanation: RelationRowExplanation(
                        primaryTrace: .verificationOnly(verification),
                        contextID: contextID
                    )
                )
            }
            exactEdges = Self.deduplicateExact(exactEdges)
            var exactIndexes: [CycleKey: Int] = [:]
            for index in exactEdges.indices {
                if let key = Self.relationKey(exactEdges[index]) {
                    exactIndexes[key] = index
                }
            }
            var matchedExactIndexes: Set<Int> = []
            var edges = loaded.edges.map { heuristic in
                guard let key = Self.relationKey(heuristic),
                      let index = exactIndexes[key]
                else {
                    var candidateOnly = heuristic
                    if let candidate = candidateObservation(for: heuristic) {
                        candidateOnly.explanation = RelationRowExplanation(
                            primaryTrace: .candidateOnly(candidate),
                            contextID: contextID
                        )
                    }
                    return candidateOnly
                }
                matchedExactIndexes.insert(index)
                if let candidate = candidateObservation(for: heuristic),
                   case .verificationOnly(let verification) =
                    exactEdges[index].explanation?.primaryTrace
                {
                    exactEdges[index].candidate = candidate
                    exactEdges[index].explanation = RelationRowExplanation(
                        primaryTrace: .corroborated(
                            candidate: candidate,
                            verification: verification
                        ),
                        contextID: contextID
                    )
                }
                return exactEdges[index]
            }
            edges += exactEdges.indices.compactMap {
                matchedExactIndexes.contains($0) ? nil : exactEdges[$0]
            }
            return LoadResult(
                edges: edges,
                isTruncated: loaded.isTruncated,
                exactState: .queried(attribution.environment)
            )
        }
    }

    private func candidateOnlyEdges(
        _ edges: [LoadedEdge],
        contextID: RelationQueryContextID
    ) -> [LoadedEdge] {
        edges.map { edge in
            var edge = edge
            if let candidate = candidateObservation(for: edge) {
                edge.explanation = RelationRowExplanation(
                    primaryTrace: .candidateOnly(candidate),
                    contextID: contextID
                )
            }
            return edge
        }
    }

    private nonisolated static func relationQueryObservation(
        _ result: ExactCoordinator.RelationQueryResult
    ) -> RelationQueryObservation {
        switch result {
        case .unsupported:
            .unsupported
        case .notApplicable:
            .notApplicable
        case .relations(_, let origin, let attribution):
            .completed(
                attribution: attribution,
                origin: origin,
                exhaustiveness: .bestEffort
            )
        }
    }

    private func makeChildren(
        from loaded: LoadResult,
        under parent: Node,
        direction: Direction
    ) -> [Node] {
        let capped = Array(loaded.edges.prefix(500))
        let corrected = capped.filter(\.isCorrectedCandidate)
        let main = capped.filter { !$0.isCorrectedCandidate }
        let possible = main.filter { $0.certainty == .probable }
            + main.filter { $0.certainty == .possible }
        var children = makeRows(
            main.filter {
                $0.certainty != .probable && $0.certainty != .possible
            },
            under: parent,
            direction: direction
        )
        if !possible.isEmpty {
            let group = Node(
                kind: .group,
                title: "Show \(possible.count) possible matches",
                children: [],
                isExpandable: true,
                parent: parent
            )
            group.children = makeRows(
                possible,
                under: group,
                direction: direction
            )
            children.append(group)
        }
        if !corrected.isEmpty {
            let group = Node(
                kind: .group,
                title: "Show corrected candidates (\(corrected.count))",
                children: [],
                isExpandable: true,
                parent: parent
            )
            group.children = makeRows(
                corrected,
                under: group,
                direction: direction
            )
            children.append(group)
        }
        if !main.contains(where: { $0.certainty == .exact }),
           let title = verifiedStatusTitle(
               state: loaded.exactState,
               direction: direction
           )
        {
            children.append(Node(kind: .truncated, title: title, parent: parent))
        }
        if loaded.isTruncated || loaded.edges.count > 500 {
            let title = if direction == .references {
                loaded.isTruncated
                    ? "\(loaded.edges.count) verified references · partial"
                    : "Showing first 500 of \(loaded.edges.count) references"
            } else {
                loaded.edges.count > 500
                    ? "Showing first 500 of \(loaded.edges.count) relations"
                    : "Results truncated upstream"
            }
            children.append(Node(
                kind: .truncated,
                title: title,
                parent: parent
            ))
        }
        children += evidenceNodes(parent.evidence, parent: parent)
        return children
    }

    private func verifiedStatusTitle(
        state: ExactState,
        direction: Direction
    ) -> String? {
        if case .queried(let environment) = state {
            if !environment.limitations.isEmpty {
                let limitations = environment.limitations
                    .sorted { $0.rawValue < $1.rawValue }
                    .map(\.displayName)
                    .joined(separator: "; ")
                return "Analysis limited: \(limitations)"
            }
            return switch direction {
            case .callers: "No verified callers"
            case .calls: "No verified calls"
            case .implementations: "No verified implementations"
            case .references: "No verified references"
            }
        }
        return switch (state, direction) {
        case (.unsupported, .callers), (.unsupported, .calls):
            "Verified unavailable: server does not support call hierarchy"
        case (.notApplicable, .callers), (.notApplicable, .calls):
            "Verified unavailable here: not a callable symbol"
        case (.unsupported, .implementations):
            "Verified unavailable: server does not support implementations"
        case (.notApplicable, .implementations):
            "Verified unavailable here: implementations not applicable"
        case (.unsupported, .references):
            "Verified unavailable: server does not support references"
        case (.notApplicable, .references):
            "Verified unavailable here: references not applicable"
        case (.legacy, .references):
            "Verified unavailable: no rust-analyzer session"
        case (.legacy, _):
            "Verified unavailable: no rust-analyzer session"
        case (.queried, _):
            nil
        }
    }

    private func preservingPublishedRows(
        _ children: [Node],
        from previousChildren: [Node]?
    ) -> [Node] {
        let previousPublished = (previousChildren ?? []).filter {
            $0.kind == .edge
                || ($0.kind == .group && $0.children?.contains {
                    $0.kind == .edge
                } == true)
        }
        guard !previousPublished.isEmpty else { return children }

        var currentRows: [CycleKey: Node] = [:]
        for child in children {
            if child.kind == .edge, let key = child.cycleKey {
                currentRows[key] = child
            }
            if child.kind == .group {
                for row in child.children ?? [] where row.kind == .edge {
                    if let key = row.cycleKey { currentRows[key] = row }
                }
            }
        }
        var consumed: Set<CycleKey> = []
        var result: [Node] = []
        for item in previousPublished {
            if item.kind == .edge {
                guard let key = item.cycleKey,
                      let current = currentRows[key],
                      let parent = item.parent ?? current.parent
                else { continue }
                consumed.insert(key)
                updatePublishedRow(item, from: current, parent: parent)
                result.append(item)
                continue
            }
            item.children = item.children?.compactMap { previous in
                guard let key = previous.cycleKey,
                      let current = currentRows[key]
                else { return nil }
                consumed.insert(key)
                updatePublishedRow(previous, from: current, parent: item)
                return previous
            }
            item.isExpandable = item.children?.isEmpty == false
            if item.title.hasPrefix("Show corrected candidates") {
                item.title = "Show corrected candidates (\(item.children?.count ?? 0))"
            } else if item.title.hasPrefix("Show ") {
                item.title = "Show \(item.children?.count ?? 0) possible matches"
            }
            if item.children?.isEmpty == false { result.append(item) }
        }

        let isFinalBatch = children.contains { $0.kind == .loading } == false
        for child in children {
            if child.kind == .edge {
                guard let key = child.cycleKey,
                      !consumed.contains(key)
                else { continue }
                consumed.insert(key)
                result.append(child)
                continue
            }
            if child.kind == .group {
                child.children = child.children?.filter { row in
                    guard let key = row.cycleKey else { return true }
                    return !consumed.contains(key)
                }
                guard child.children?.isEmpty == false else { continue }
                if let existing = result.first(where: {
                    $0.kind == .group
                        && Self.stableGroupName($0.title)
                            == Self.stableGroupName(child.title)
                }) {
                    existing.children?.append(contentsOf: child.children ?? [])
                    existing.children?.forEach { $0.parent = existing }
                    if existing.title.hasPrefix("Show corrected candidates") {
                        existing.title = "Show corrected candidates (\(existing.children?.count ?? 0))"
                    } else if existing.title.hasPrefix("Show ") {
                        existing.title =
                            "Show \(existing.children?.count ?? 0) possible matches"
                    }
                } else {
                    result.append(child)
                }
                for row in child.children ?? [] {
                    if let key = row.cycleKey { consumed.insert(key) }
                }
                continue
            }
            if isFinalBatch { result.append(child) }
        }
        if !isFinalBatch {
            result.append(Node(
                kind: .loading,
                title: "Loading…",
                parent: previousPublished[0].parent
            ))
        }
        return result
    }

    private func relationEdgeRows(in parent: Node) -> [Node] {
        (parent.children ?? []).flatMap { child in
            child.kind == .group
                ? child.children?.filter { $0.kind == .edge } ?? []
                : child.kind == .edge ? [child] : []
        }
    }

    private func reusingPublishedRows(
        _ children: [Node],
        from previous: [Node],
        parent: Node
    ) -> [Node] {
        let previousRows = Dictionary(
            previous.flatMap { child in
                child.kind == .group ? child.children ?? [] : [child]
            }.compactMap { row in
                row.cycleKey.map { ($0, row) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let previousGroups = Dictionary(
            previous.filter { $0.kind == .group }.map {
                (Self.stableGroupName($0.title), $0)
            },
            uniquingKeysWith: { first, _ in first }
        )
        return children.map { child in
            if child.kind == .edge,
               let key = child.cycleKey,
               let old = previousRows[key]
            {
                updatePublishedRow(old, from: child, parent: parent)
                return old
            }
            guard child.kind == .group else { return child }
            let group = previousGroups[Self.stableGroupName(child.title)] ?? child
            group.title = child.title
            group.isExpandable = child.isExpandable
            group.parent = parent
            group.children = child.children?.map { row in
                guard let key = row.cycleKey,
                      let old = previousRows[key]
                else { return row }
                updatePublishedRow(old, from: row, parent: group)
                return old
            }
            group.children?.forEach { $0.parent = group }
            return group
        }
    }

    private func updatePublishedRow(
        _ previous: Node,
        from current: Node,
        parent: Node
    ) {
        let loadedChildren = previous.isExpandable
            && previous.children?.isEmpty == false
        previous.title = current.title
        previous.subtitle = current.subtitle
        previous.badge = current.badge
        previous.dispatchLabel = current.dispatchLabel
        previous.modifiers = current.modifiers
        previous.target = current.target
        previous.line = current.line
        previous.symbol = current.symbol
        previous.expansionIdentity = current.expansionIdentity
        previous.explanation = current.explanation
        previous.queryTarget = current.queryTarget
        previous.isExpandable = current.isExpandable
        previous.parent = parent
        previous.evidence = current.evidence
        previous.callSites = current.callSites
        previous.loadedEdge = current.loadedEdge
        if previous.explanationID != nil {
            onExplanationChange(previous)
        }
        if !loadedChildren {
            previous.children = current.children
        }
    }

    private nonisolated static func stableGroupName(_ title: String) -> String {
        if title.hasPrefix("Show corrected candidates") { return "Corrected" }
        return title.hasPrefix("Show ") ? "Possible" : title
    }

    private func makeRows(
        _ edges: [LoadedEdge],
        under parent: Node,
        direction: Direction
    ) -> [Node] {
        edges.map { edge in
            let identity: Node.ExpansionIdentity? = if let item = edge.exactItem {
                .exact(item)
            } else if let symbol = edge.symbol {
                .engine(symbol)
            } else {
                nil
            }
            let cycleKey = Self.cycleKey(
                path: edge.identityTarget?.file ?? edge.path,
                byteOffset: edge.identityTarget?.byteOffset ?? edge.byteOffset
            )
            let badge: String? = switch edge.certainty {
            case .exact: "Verified"
            case .unresolved: nil
            case .strong, .probable, .possible: "Inferred"
            }
            let dispatchLabel = edge.certainty == .unresolved ? nil
                : resolutionDispatchLabel(edge.dispatch)
            var modifiers: [String] = []
            if edge.certainty == .unresolved {
                modifiers.append(edge.exactOrigin == nil
                    ? "Unresolved"
                    : "External · in dependency (rust-analyzer)")
            }
            if direction == .calls,
               edge.certainty == .probable || edge.certainty == .possible,
               !edge.evidence.isEmpty,
               edge.evidence.allSatisfy({
                   if case .methodNameOnly = $0 { return true }
                   return false
               })
            {
                modifiers.append("name match only")
            }
            if case .corroborated = edge.explanation?.primaryTrace {
                modifiers.append("heuristic also matched")
            }
            if edge.isCorrectedCandidate {
                modifiers.append("Conflict/Corrected")
            }
            if !edge.callSites.isEmpty {
                modifiers.append("\(edge.callSites.count) call "
                    + (edge.callSites.count == 1 ? "site" : "sites"))
            }
            let subtitle = ([dispatchLabel] + modifiers).compactMap { $0 }
                .joined(separator: " · ")
            return Node(
                kind: .edge,
                title: edge.title,
                subtitle: subtitle,
                badge: badge,
                dispatchLabel: dispatchLabel,
                modifiers: modifiers,
                target: (edge.path, edge.byteOffset),
                line: edge.line,
                children: [],
                isExpandable: false,
                parent: parent,
                symbol: edge.symbol,
                representsLocation: direction == .references,
                expansionIdentity: identity,
                explanation: edge.explanation,
                evidence: edge.evidence,
                cycleKey: cycleKey,
                queryTarget: (
                    edge.identityTarget?.file ?? edge.path,
                    edge.identityTarget?.byteOffset ?? edge.byteOffset
                ),
                callSites: edge.callSites,
                loadedEdge: edge
            )
        }
    }

    private nonisolated static func cycleKey(
        path: String,
        byteOffset: UInt32
    ) -> CycleKey {
        CycleKey(
            path: normalizedPath(path),
            identity: "selection:\(byteOffset)"
        )
    }

    private nonisolated static func relationKey(_ edge: LoadedEdge) -> CycleKey? {
        let target = edge.identityTarget ?? (
            file: edge.path,
            byteOffset: edge.byteOffset
        )
        return cycleKey(path: target.file, byteOffset: target.byteOffset)
    }

    private nonisolated static func deduplicateExact(
        _ edges: [LoadedEdge]
    ) -> [LoadedEdge] {
        var result: [LoadedEdge] = []
        var indexes: [CycleKey: Int] = [:]
        for edge in edges {
            guard edge.certainty == .exact else {
                result.append(edge)
                continue
            }
            guard let key = relationKey(edge) else {
                result.append(edge)
                continue
            }
            if let index = indexes[key] {
                var existingCallSites = Set(result[index].callSites.map {
                    CycleKey(
                        path: normalizedPath($0.file),
                        identity: "selection:\($0.byteOffset)"
                    )
                })
                result[index].callSites += edge.callSites.filter {
                    existingCallSites.insert(CycleKey(
                        path: normalizedPath($0.file),
                        identity: "selection:\($0.byteOffset)"
                    )).inserted
                }
                if let existing = result[index].explanation,
                   let added = edge.explanation
                {
                    var refs = existing.reconciliationRefs
                    for ref in added.reconciliationRefs where !refs.contains(ref) {
                        refs.append(ref)
                    }
                    result[index].explanation = RelationRowExplanation(
                        primaryTrace: existing.primaryTrace,
                        contextID: existing.contextID,
                        reconciliationRefs: refs
                    )
                } else if result[index].explanation == nil {
                    result[index].explanation = edge.explanation
                }
            } else {
                indexes[key] = result.count
                result.append(edge)
            }
        }
        return result
    }

    private nonisolated static func normalizedPath(_ path: String) -> String {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
        return NSString(string: path).standardizingPath
    }

    private nonisolated static func locationTitle(_ location: ExactLocation) -> String {
        "\(URL(fileURLWithPath: location.file).lastPathComponent):\(location.line)"
    }

    private nonisolated static func symbol(
        at location: ExactLocation,
        in session: EngineSession
    ) -> SymbolOccurrenceID? {
        guard let offset = UInt32(exactly: location.byteOffset),
              let file = session.manifest.files.first(where: {
                  normalizedPath(session.paths.resolve($0.pathID))
                      == normalizedPath(location.file)
              }),
              let index = contentIndex(at: file.pathID, in: session),
              let facetIndex = index.symbols.firstIndex(where: {
                  $0.nameRange.lowerBound == offset
                      || $0.nameRange.contains(offset)
              })
        else { return nil }
        return SymbolOccurrenceID(
            snapshotID: session.snapshotID,
            pathID: file.pathID,
            localKind: .declarationFacet,
            localIndex: UInt32(facetIndex)
        )
    }

    private func evidenceNodes(
        _ evidence: [ResolutionEvidence],
        parent: Node
    ) -> [Node] {
        evidence.map {
            Node(
                kind: .evidenceLine,
                title: Self.evidenceLabel($0),
                parent: parent
            )
        }
    }

    private nonisolated static func load(
        session: EngineSession,
        context: QueryContext,
        symbol: SymbolOccurrenceID,
        direction: Direction
    ) async throws -> LoadResult {
        switch direction {
        case .callers:
            guard let name = symbolTitle(symbol, in: session) else {
                return LoadResult(edges: [], isTruncated: false)
            }
            let fuzzyTarget = location(for: symbol, in: session)
            let callers = try session.callers(of: name, context: context)
            return LoadResult(
                edges: callers.compactMap { caller -> LoadedEdge? in
                    guard let location = location(for: caller.callSite, in: session)
                    else { return nil }
                    let callerSymbol = caller.region.associatedFacetIndex.map {
                        SymbolOccurrenceID(
                            snapshotID: session.snapshotID,
                            pathID: caller.callSite.pathID,
                            localKind: .declarationFacet,
                            localIndex: $0
                        )
                    }
                    let callerTarget = callerSymbol.flatMap {
                        Self.location(for: $0, in: session)
                    }
                    return LoadedEdge(
                        title: caller.associatedFacet.map {
                            session.names.resolve($0.nameID)
                        } ?? location.path,
                        certainty: caller.certainty,
                        dispatch: caller.dispatch,
                        symbol: callerSymbol,
                        path: location.path,
                        byteOffset: location.byteOffset,
                        line: location.line,
                        evidence: caller.evidence,
                        candidate: CandidateObservation(
                            target: .occurrence(symbol),
                            certainty: caller.certainty,
                            dispatch: caller.dispatch,
                            provenance: caller.provenance,
                            completeness: caller.completeness,
                            evidence: caller.evidence
                        ),
                        exactQuery: (
                            location.path,
                            location.byteOffset,
                            location.line
                        ),
                        fuzzyTarget: fuzzyTarget.map { ($0.path, $0.byteOffset) },
                        identityTarget: callerTarget.map {
                            ($0.path, $0.byteOffset)
                        }
                    )
                },
                isTruncated: callers.contains { isTruncated($0.completeness) }
            )

        case .calls:
            let result = try session.outgoingCalls(from: symbol, context: context)
            var edges: [LoadedEdge] = []
            for outgoing in result.calls {
                let callSite = location(for: outgoing.callSite, in: session)
                var appendedCandidate = false
                for candidate in outgoing.candidates {
                    guard let location = location(
                        for: candidate.target,
                        evidence: candidate.evidence,
                        in: session
                    ) else { continue }
                    appendedCandidate = true
                    edges.append(LoadedEdge(
                        title: outgoing.calleeName,
                        certainty: candidate.certainty,
                        dispatch: candidate.dispatch,
                        symbol: hasLexicalBinding(candidate.evidence)
                            ? nil : candidate.target,
                        path: location.path,
                        byteOffset: location.byteOffset,
                        line: location.line,
                        evidence: candidate.evidence,
                        candidate: CandidateObservation(
                            target: .occurrence(candidate.target),
                            certainty: candidate.certainty,
                            dispatch: candidate.dispatch,
                            provenance: candidate.provenance,
                            completeness: candidate.completeness,
                            evidence: candidate.evidence
                        ),
                        exactQuery: callSite.map {
                            ($0.path, $0.byteOffset, $0.line)
                        },
                        fuzzyTarget: (location.path, location.byteOffset)
                    ))
                }
                if !appendedCandidate,
                   let location = location(for: outgoing.callSite, in: session)
                {
                    let hintKind: UnresolvedSymbolHintKind = switch
                        outgoing.call.syntacticKind
                    {
                    case .methodCall: .member
                    case .qualifiedCall: .qualified
                    default: .unqualified
                    }
                    edges.append(LoadedEdge(
                        title: outgoing.calleeName,
                        certainty: .unresolved,
                        dispatch: .direct,
                        symbol: nil,
                        path: location.path,
                        byteOffset: location.byteOffset,
                        line: location.line,
                        evidence: [],
                        candidate: CandidateObservation(
                            target: .unresolved(UnresolvedSymbolRef(
                                nameID: outgoing.call.nameID,
                                hintKind: hintKind
                            )),
                            certainty: .unresolved,
                            dispatch: .direct,
                            provenance: .fuzzyResolver,
                            completeness: result.completeness,
                            evidence: []
                        )
                    ))
                }
            }
            return LoadResult(
                edges: edges,
                isTruncated: isTruncated(result.completeness)
            )

        case .implementations:
            guard let (index, facet) = facet(for: symbol, in: session) else {
                return LoadResult(edges: [], isTruncated: false)
            }
            if facet.kind == .rustTrait {
                let results = try session.implementations(
                    ofTrait: session.names.resolve(facet.nameID),
                    context: context
                )
                return LoadResult(
                    edges: results.compactMap { implementation in
                        guard let location = location(
                            for: implementation.implementation,
                            in: session
                        ) else { return nil }
                        return LoadedEdge(
                            title: implementation.typeName,
                            certainty: implementation.certainty,
                            dispatch: .traitDispatch,
                            symbol: implementation.implementation,
                            path: location.path,
                            byteOffset: location.byteOffset,
                            line: location.line,
                            evidence: implementation.traitDefinitions.flatMap(\.evidence),
                            candidate: CandidateObservation(
                                target: .occurrence(implementation.implementation),
                                certainty: implementation.certainty,
                                dispatch: .traitDispatch,
                                provenance: .languageProof,
                                completeness: .complete,
                                evidence: implementation.traitDefinitions.flatMap(\.evidence)
                            )
                        )
                    },
                    isTruncated: false
                )
            }
            guard facet.kind == .rustMethod,
                  let parent = facet.parentFacetIndex,
                  index.symbols.indices.contains(Int(parent)),
                  index.symbols[Int(parent)].kind == .rustTrait
            else { return LoadResult(edges: [], isTruncated: false) }
            return LoadResult(
                edges: try session.overrides(
                    ofTraitMethod: symbol,
                    context: context
                ).compactMap { candidate in
                    guard let location = location(
                        for: candidate.target,
                        evidence: candidate.evidence,
                        in: session
                    ) else { return nil }
                    return LoadedEdge(
                        title: symbolTitle(candidate.target, in: session) ?? location.path,
                        certainty: candidate.certainty,
                        dispatch: candidate.dispatch,
                        symbol: candidate.target,
                        path: location.path,
                        byteOffset: location.byteOffset,
                        line: location.line,
                        evidence: candidate.evidence,
                        candidate: CandidateObservation(
                            target: .occurrence(candidate.target),
                            certainty: candidate.certainty,
                            dispatch: candidate.dispatch,
                            provenance: candidate.provenance,
                            completeness: candidate.completeness,
                            evidence: candidate.evidence
                        )
                    )
                },
                isTruncated: false
            )
        case .references:
            guard let (_, facet) = facet(for: symbol, in: session) else {
                return LoadResult(edges: [], isTruncated: false)
            }
            let stream = try session.searchReferences(
                ContentSearchQuery(
                    pattern: session.names.resolve(facet.nameID),
                    caseSensitive: true
                ),
                excludingPathID: symbol.pathID,
                excludingRange: facet.nameRange,
                context: context
            )
            var edges: [LoadedEdge] = []
            var isTruncated = false
            for try await batch in stream {
                try Task.checkCancellation()
                isTruncated = isTruncated || batch.completeness == .truncated
                for (pathID, matches) in batch.matchesByPath {
                    let path = session.paths.resolve(pathID)
                    edges += matches.map {
                        LoadedEdge(
                            title: "\(URL(fileURLWithPath: path).lastPathComponent):"
                                + "\($0.line):\($0.column)",
                            certainty: .possible,
                            dispatch: .direct,
                            symbol: nil,
                            path: path,
                            byteOffset: $0.byteRange.lowerBound,
                            line: $0.line,
                            evidence: [.nameOnly(nameID: facet.nameID)],
                            candidate: CandidateObservation(
                                target: .unresolved(UnresolvedSymbolRef(
                                    nameID: facet.nameID,
                                    hintKind: .unqualified
                                )),
                                certainty: .possible,
                                dispatch: .direct,
                                provenance: .fuzzyResolver,
                                completeness: batch.completeness,
                                evidence: [.nameOnly(nameID: facet.nameID)]
                            )
                        )
                    }
                }
            }
            edges.sort {
                $0.path == $1.path
                    ? $0.byteOffset < $1.byteOffset
                    : $0.path < $1.path
            }
            return LoadResult(edges: edges, isTruncated: isTruncated)
        }
    }

    private nonisolated static func canExpand(
        _ symbol: SymbolOccurrenceID,
        direction: Direction,
        session: EngineSession
    ) -> Bool {
        guard symbol.localKind == .declarationFacet,
              let (index, facet) = facet(for: symbol, in: session)
        else { return false }
        switch direction {
        case .callers, .calls:
            return true
        case .implementations:
            if facet.kind == .rustTrait { return true }
            guard facet.kind == .rustMethod,
                  let parent = facet.parentFacetIndex,
                  index.symbols.indices.contains(Int(parent))
            else { return false }
            return index.symbols[Int(parent)].kind == .rustTrait
        case .references:
            return true
        }
    }

    private nonisolated static func bindingTitle(
        _ binding: BindingRecord,
        in document: ReaderDocument
    ) -> String? {
        let lower = Int(binding.declarationRange.lowerBound)
        let upper = Int(binding.declarationRange.upperBound)
        guard lower >= 0, lower < upper, upper <= document.bytes.count else {
            return nil
        }
        return String(decoding: document.bytes[lower..<upper], as: UTF8.self)
    }

    private nonisolated static func symbolTitle(
        _ symbol: SymbolOccurrenceID,
        in session: EngineSession
    ) -> String? {
        facet(for: symbol, in: session).map {
            session.names.resolve($0.1.nameID)
        }
    }

    private nonisolated static func facet(
        for symbol: SymbolOccurrenceID,
        in session: EngineSession
    ) -> (ContentIndex, DeclarationFacet)? {
        guard symbol.snapshotID == session.snapshotID,
              symbol.localKind == .declarationFacet,
              let index = contentIndex(at: symbol.pathID, in: session),
              index.symbols.indices.contains(Int(symbol.localIndex))
        else { return nil }
        return (index, index.symbols[Int(symbol.localIndex)])
    }

    private nonisolated static func location(
        for symbol: SymbolOccurrenceID,
        evidence: [ResolutionEvidence] = [],
        in session: EngineSession
    ) -> (path: String, byteOffset: UInt32, line: UInt32)? {
        guard symbol.snapshotID == session.snapshotID,
              let index = contentIndex(at: symbol.pathID, in: session)
        else { return nil }
        let offset: UInt32
        if let bindingIndex = lexicalBindingIndex(evidence),
           index.bindings.indices.contains(Int(bindingIndex))
        {
            offset = index.bindings[Int(bindingIndex)].declarationRange.lowerBound
        } else {
            switch symbol.localKind {
            case .declarationFacet:
                guard index.symbols.indices.contains(Int(symbol.localIndex)) else {
                    return nil
                }
                offset = index.symbols[Int(symbol.localIndex)].nameRange.lowerBound
            case .callSite:
                guard index.calls.indices.contains(Int(symbol.localIndex)) else {
                    return nil
                }
                offset = index.calls[Int(symbol.localIndex)].range.lowerBound
            case .importBinding:
                guard index.imports.indices.contains(Int(symbol.localIndex)) else {
                    return nil
                }
                offset = index.imports[Int(symbol.localIndex)].range.lowerBound
            }
        }
        guard let line = index.lineTable.lineColumn(at: offset)?.line else {
            return nil
        }
        return (session.paths.resolve(symbol.pathID), offset, line)
    }

    private nonisolated static func contentIndex(
        at pathID: PathID,
        in session: EngineSession
    ) -> ContentIndex? {
        guard let file = session.manifest.files.first(where: { $0.pathID == pathID })
        else { return nil }
        return session.contentIndexes.first {
            $0.key.contentID == file.contentID
                && $0.key.languageMode.language == file.detectedLanguage
        }?.value
    }

    private nonisolated static func lexicalBindingIndex(
        _ evidence: [ResolutionEvidence]
    ) -> UInt32? {
        for item in evidence {
            if case let .lexicalBinding(bindingIndex) = item { return bindingIndex }
        }
        return nil
    }

    private nonisolated static func hasLexicalBinding(
        _ evidence: [ResolutionEvidence]
    ) -> Bool {
        lexicalBindingIndex(evidence) != nil
    }

    private nonisolated static func isTruncated(_ completeness: Completeness) -> Bool {
        if case .truncated = completeness { return true }
        return false
    }

    private static func containsTruncatedNode(_ node: Node) -> Bool {
        node.kind == .truncated
            || node.children?.contains(where: containsTruncatedNode) == true
    }

    private nonisolated static func evidenceLabel(
        _ evidence: ResolutionEvidence
    ) -> String {
        switch evidence {
        case .sameFile: "same file"
        case .uniqueImport: "via import"
        case .lexicalBinding: "lexical binding"
        case .nameOnly: "name match"
        case .methodNameOnly: "method name match"
        case .receiverType: "receiver type"
        }
    }

    fileprivate struct CycleKey: Hashable {
        let path: String
        let identity: String
    }
}
