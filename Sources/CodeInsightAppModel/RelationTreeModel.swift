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
        public let title: String
        public let subtitle: String?
        public let badge: String?
        public fileprivate(set) var target: (path: String, byteOffset: UInt32)?
        public fileprivate(set) var line: UInt32?
        public let symbol: SymbolOccurrenceID?
        public let expansionIdentity: ExpansionIdentity?
        public fileprivate(set) var children: [Node]?
        public fileprivate(set) var isExpandable: Bool

        fileprivate weak var parent: Node?
        fileprivate let evidence: [ResolutionEvidence]
        fileprivate let cycleKey: CycleKey?
        fileprivate let queryTarget: (path: String, byteOffset: UInt32)?
        fileprivate let callSites: [ExactLocation]
        fileprivate var nextCallSiteIndex = 0
        fileprivate var loadRequestID: UInt64?

        fileprivate init(
            kind: Kind,
            title: String,
            subtitle: String? = nil,
            badge: String? = nil,
            target: (path: String, byteOffset: UInt32)? = nil,
            line: UInt32? = nil,
            children: [Node]? = [],
            isExpandable: Bool = false,
            parent: Node? = nil,
            symbol: SymbolOccurrenceID? = nil,
            expansionIdentity: ExpansionIdentity? = nil,
            evidence: [ResolutionEvidence] = [],
            cycleKey: CycleKey? = nil,
            queryTarget: (path: String, byteOffset: UInt32)? = nil,
            callSites: [ExactLocation] = []
        ) {
            self.kind = kind
            self.title = title
            self.subtitle = subtitle
            self.badge = badge
            self.target = target
            self.line = line
            self.children = children
            self.isExpandable = isExpandable
            self.parent = parent
            self.symbol = symbol
            self.expansionIdentity = expansionIdentity
            self.evidence = evidence
            self.cycleKey = cycleKey
            self.queryTarget = queryTarget
            self.callSites = callSites
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
        let exactQuery: (file: String, byteOffset: UInt32, line: UInt32)?
        let fuzzyTarget: (file: String, byteOffset: UInt32)?
        let identityTarget: (file: String, byteOffset: UInt32)?
        let exactItem: ExactCallHierarchyItem?
        var callSites: [ExactLocation]
        var alsoHeuristic: Bool
        var exactOrigin: ExactOrigin?

        init(
            title: String,
            certainty: Certainty,
            dispatch: DispatchKind,
            symbol: SymbolOccurrenceID?,
            path: String,
            byteOffset: UInt32,
            line: UInt32,
            evidence: [ResolutionEvidence],
            exactQuery: (file: String, byteOffset: UInt32, line: UInt32)? = nil,
            fuzzyTarget: (file: String, byteOffset: UInt32)? = nil,
            identityTarget: (file: String, byteOffset: UInt32)? = nil,
            exactItem: ExactCallHierarchyItem? = nil,
            callSites: [ExactLocation] = [],
            alsoHeuristic: Bool = false,
            exactOrigin: ExactOrigin? = nil
        ) {
            self.title = title
            self.certainty = certainty
            self.dispatch = dispatch
            self.symbol = symbol
            self.path = path
            self.byteOffset = byteOffset
            self.line = line
            self.evidence = evidence
            self.exactQuery = exactQuery
            self.fuzzyTarget = fuzzyTarget
            self.identityTarget = identityTarget
            self.exactItem = exactItem
            self.callSites = callSites
            self.alsoHeuristic = alsoHeuristic
            self.exactOrigin = exactOrigin
        }
    }

    enum ExactState: Sendable {
        case legacy
        case unsupported
        case notApplicable
        case queried
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
        UInt64
    ) async -> ExactOverlay.Entry?
    typealias ExactRelationsResolver = @MainActor @Sendable (
        String,
        UInt32,
        ExactCallHierarchyItem?,
        Direction,
        UInt64
    ) async -> ExactCoordinator.RelationQueryResult?

    public private(set) var root: Node?
    public private(set) var direction: Direction = .callers
    public private(set) var generation: UInt64 = 0
    public private(set) var requestID: UInt64 = 0
    public private(set) var selectedRelationSymbol: SymbolOccurrenceID?
    public var onSelect: @MainActor (Node) -> Void = { _ in }
    public var hasTruncatedResults: Bool {
        root.map(Self.containsTruncatedNode) ?? false
    }

    private let loader: Loader
    private var exactResolver: ExactResolver?
    private var exactRelationsResolver: ExactRelationsResolver?
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
        exactResolver = nil
        exactRelationsResolver = nil
    }

    init(
        loader: @escaping Loader,
        exactResolver: ExactResolver? = nil,
        exactRelationsResolver: ExactRelationsResolver? = nil
    ) {
        self.loader = loader
        self.exactResolver = exactResolver
        self.exactRelationsResolver = exactRelationsResolver
    }

    func attachExactCoordinator(_ coordinator: ExactCoordinator) {
        exactResolver = { [weak coordinator] file, offset, generation in
            await coordinator?.definition(
                file: file,
                byteOffset: offset,
                generation: generation
            )
        }
        exactRelationsResolver = {
            [weak coordinator] file, offset, item, direction, generation in
            await coordinator?.relations(
                file: file,
                byteOffset: offset,
                item: item,
                direction: direction,
                generation: generation
            )
        }
    }

    public func updateProjectState(_ state: ProjectState) {
        generation &+= 1
        requestID &+= 1
        root = nil
        selectedRelationSymbol = nil
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
        generation &+= 1
        self.direction = direction
        selectedRelationSymbol = nil
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
        return expansionTask(for: node)
    }

    private func makeReferenceChildren(
        _ references: [CodeInsightCore.ByteRange],
        path: String,
        bindingKind: BindingKind,
        under parent: Node,
        document: ReaderDocument
    ) -> [Node] {
        let group = Node(
            kind: .group,
            title: "References (\(references.count))",
            children: [],
            isExpandable: !references.isEmpty,
            parent: parent
        )
        let label = bindingKind == .param ? "Parameter reference" : "Local reference"
        group.children = references.prefix(500).compactMap { range in
            guard let coordinate = document.lineTable.lineColumn(at: range.lowerBound)
            else { return nil }
            return Node(
                kind: .edge,
                title: "\(URL(fileURLWithPath: path).lastPathComponent):"
                    + "\(coordinate.line):\(coordinate.column)",
                subtitle: label,
                target: (path, range.lowerBound),
                line: coordinate.line,
                children: [],
                parent: group,
                cycleKey: Self.cycleKey(path: path, byteOffset: range.lowerBound)
            )
        }
        guard references.count > 500 else { return [group] }
        return [
            group,
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

    private func expansionTask(for node: Node) -> Task<Void, Never>? {
        guard node.isExpandable, node.children == nil,
              let identity = node.expansionIdentity, let session, let context
        else { return nil }

        requestID &+= 1
        let currentRequestID = requestID
        let currentGeneration = generation
        node.loadRequestID = currentRequestID
        node.children = [Node(kind: .loading, title: "Loading…", parent: node)]

        let loader = self.loader
        let exactRelationsResolver = self.exactRelationsResolver
        let direction = self.direction
        return Task { [weak self, weak node] in
            var loaded = LoadResult(edges: [], isTruncated: false)
            var engineLoadFailed = false
            if case let .engine(symbol) = identity {
                let result = await Task.detached(priority: .userInitiated) {
                    try await loader(session, context, symbol, direction)
                }.result
                switch result {
                case .success(let value):
                    loaded = value
                case .failure:
                    engineLoadFailed = true
                }
            }
            guard let self, let node,
                  generation == currentGeneration,
                  node.loadRequestID == currentRequestID,
                  self.session === session
            else { return }

            if case .engine = identity,
               !engineLoadFailed,
               direction != .references
            {
                loaded = await promoteExactEdges(
                    loaded,
                    direction: direction,
                    generation: context.generation
                )
            }
            let exactItem: ExactCallHierarchyItem? = if case let .exact(item) = identity {
                item
            } else {
                nil
            }
            let exactResult: ExactCoordinator.RelationQueryResult?
            if direction != .references,
               let exactRelationsResolver,
               let query = node.queryTarget ?? node.target
            {
                exactResult = await exactRelationsResolver(
                    query.path,
                    query.byteOffset,
                    exactItem,
                    direction,
                    context.generation
                )
            } else {
                exactResult = nil
            }
            guard generation == currentGeneration,
                  node.loadRequestID == currentRequestID,
                  self.session === session
            else { return }

            if let exactResult {
                loaded = mergeExact(
                    exactResult,
                    into: loaded,
                    direction: direction,
                    session: session
                )
            }
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
                return
            }
            node.children = makeChildren(
                from: loaded,
                under: node,
                direction: direction,
                session: session
            )
        }
    }

    private func promoteExactEdges(
        _ loaded: LoadResult,
        direction: Direction,
        generation: UInt64
    ) async -> LoadResult {
        guard let exactResolver else { return loaded }
        var edges = loaded.edges
        await withTaskGroup(of: (Int, ExactOverlay.Entry?).self) { group in
            for (index, edge) in edges.prefix(500).enumerated() {
                guard let query = edge.exactQuery,
                      edge.fuzzyTarget != nil
                else { continue }
                group.addTask {
                    let exact = await exactResolver(
                        query.file,
                        query.byteOffset,
                        generation
                    )
                    return (index, exact)
                }
            }
            for await (index, exact) in group {
                guard let exact else { continue }
                let edge = edges[index]
                if let fuzzyTarget = edge.fuzzyTarget,
                   exact.location.file == fuzzyTarget.file,
                   exact.location.byteOffset == Int(fuzzyTarget.byteOffset)
                {
                    edges[index].certainty = .exact
                    edges[index].exactOrigin = exact.origin
                } else if direction == .calls,
                          exactLocationIsInDependency(exact.location.file),
                          edge.certainty == .probable || edge.certainty == .possible,
                          !edge.evidence.isEmpty,
                          edge.evidence.allSatisfy({
                              if case .methodNameOnly = $0 { return true }
                              return false
                          }),
                          let query = edge.exactQuery
                {
                    edges[index] = LoadedEdge(
                        title: edge.title,
                        certainty: .unresolved,
                        dispatch: edge.dispatch,
                        symbol: nil,
                        path: query.file,
                        byteOffset: query.byteOffset,
                        line: query.line,
                        evidence: edge.evidence,
                        exactOrigin: exact.origin
                    )
                }
            }
        }
        return LoadResult(edges: edges, isTruncated: loaded.isTruncated)
    }

    private func mergeExact(
        _ result: ExactCoordinator.RelationQueryResult,
        into loaded: LoadResult,
        direction: Direction,
        session: EngineSession
    ) -> LoadResult {
        switch result {
        case .unsupported:
            return LoadResult(
                edges: loaded.edges,
                isTruncated: loaded.isTruncated,
                exactState: .unsupported
            )
        case .notApplicable:
            return LoadResult(
                edges: loaded.edges,
                isTruncated: loaded.isTruncated,
                exactState: .notApplicable
            )
        case let .relations(relations, origin):
            var exactEdges = relations.compactMap { relation -> LoadedEdge? in
                guard let byteOffset = UInt32(exactly: relation.location.byteOffset),
                      let line = UInt32(exactly: relation.location.line),
                      line > 0
                else { return nil }
                let symbol = Self.symbol(
                    at: relation.location,
                    in: session
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
                    identityTarget: (
                        relation.location.file,
                        byteOffset
                    ),
                    exactItem: relation.item,
                    callSites: relation.callSites.filter {
                        UInt32(exactly: $0.byteOffset) != nil
                            && UInt32(exactly: $0.line).map { $0 > 0 } == true
                    },
                    exactOrigin: origin
                )
            }
            exactEdges = Self.deduplicateExact(exactEdges)
            let exactKeys = Set(exactEdges.compactMap(Self.relationKey))
            let heuristicKeys = Set(loaded.edges.compactMap(Self.relationKey))
            for index in exactEdges.indices {
                if let key = Self.relationKey(exactEdges[index]),
                   heuristicKeys.contains(key)
                {
                    exactEdges[index].alsoHeuristic = true
                }
            }
            return LoadResult(
                edges: exactEdges + loaded.edges.filter {
                    guard let key = Self.relationKey($0) else { return true }
                    return !exactKeys.contains(key)
                },
                isTruncated: loaded.isTruncated,
                exactState: .queried
            )
        }
    }

    private func makeChildren(
        from loaded: LoadResult,
        under parent: Node,
        direction: Direction,
        session: EngineSession
    ) -> [Node] {
        if direction == .references {
            let visible = Array(loaded.edges.prefix(500))
            let status = if loaded.isTruncated {
                "\(loaded.edges.count) verified references · partial"
            } else if loaded.edges.count > 500 {
                "Showing first 500 of \(loaded.edges.count) references"
            } else {
                "\(loaded.edges.count) references"
            }
            let group = makeGroup(
                "References",
                subtitle: loaded.isTruncated || loaded.edges.count > 500
                    ? nil : status,
                edges: visible,
                under: parent,
                direction: direction,
                session: session
            )
            guard loaded.isTruncated || loaded.edges.count > 500 else {
                return [group]
            }
            return [
                group,
                Node(kind: .truncated, title: status, parent: parent),
            ]
        }
        let capped = Array(loaded.edges.prefix(500))
        let exact = capped.filter { $0.certainty == .exact }
        var children = [
            makeGroup(
                exactGroupTitle(
                    state: loaded.exactState,
                    count: exact.count,
                    direction: direction
                ),
                edges: exact,
                under: parent,
                direction: direction,
                session: session
            ),
            makeGroup(
                "Strong",
                edges: capped.filter { $0.certainty == .strong },
                under: parent,
                direction: direction,
                session: session
            ),
            makeGroup(
                "Probable",
                edges: capped.filter { $0.certainty == .probable },
                under: parent,
                direction: direction,
                session: session
            ),
            makeGroup(
                "Possible",
                edges: capped.filter { $0.certainty == .possible },
                under: parent,
                direction: direction,
                session: session
            ),
        ]
        let external = capped.filter { $0.certainty == .unresolved }
        if direction == .calls {
            children.append(makeGroup(
                external.isEmpty
                    ? "External / Unresolved (0)"
                    : "External / Unresolved",
                edges: external,
                under: parent,
                direction: direction,
                session: session
            ))
        }
        if loaded.isTruncated || loaded.edges.count > 500 {
            children.append(Node(
                kind: .truncated,
                title: loaded.edges.count > 500
                    ? "Showing first 500 of \(loaded.edges.count) relations"
                    : "Results truncated upstream",
                parent: parent
            ))
        }
        children += evidenceNodes(parent.evidence, parent: parent)
        return children
    }

    private func exactGroupTitle(
        state: ExactState,
        count: Int,
        direction: Direction
    ) -> String {
        guard count == 0 else { return "Exact" }
        return switch (state, direction) {
        case (.unsupported, .callers), (.unsupported, .calls):
            "Exact unavailable: server does not support call hierarchy"
        case (.notApplicable, .callers), (.notApplicable, .calls):
            "Exact unavailable here: not a callable symbol"
        case (.queried, .callers):
            "Exact (0): no callers"
        case (.queried, .calls):
            "Exact (0): no calls"
        case (.unsupported, .implementations):
            "Exact unavailable: server does not support implementations"
        case (.queried, .implementations):
            "Exact (0): no implementations"
        case (.notApplicable, .implementations):
            "Exact (0): no implementations"
        case (_, .references):
            "Exact (0)"
        case (.legacy, _):
            "Exact (0)"
        }
    }

    private func makeGroup(
        _ title: String,
        subtitle: String? = nil,
        edges: [LoadedEdge],
        under parent: Node,
        direction: Direction,
        session: EngineSession
    ) -> Node {
        let group = Node(
            kind: .group,
            title: title,
            subtitle: subtitle,
            children: [],
            isExpandable: !edges.isEmpty,
            parent: parent
        )
        let ancestorKeys = cycleKeys(from: parent)
        group.children = edges.map { edge in
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
            let isCycle = ancestorKeys.contains(cycleKey)
            let canExpand = !isCycle && {
                switch identity {
                case .exact:
                    return direction != .implementations
                case .engine(let symbol):
                    return Self.canExpand(
                        symbol,
                        direction: direction,
                        session: session
                    )
                case nil:
                    return false
                }
            }()
            let badge: String?
            if edge.certainty == .exact {
                var value = "Exact · lsp"
                if case .some(.materialized) = edge.exactOrigin {
                    value += " · hist"
                }
                if isCycle { value += " · ↻" }
                badge = value
            } else {
                badge = isCycle ? "↻" : nil
            }
            var subtitle = if edge.certainty == .exact {
                "Exact"
            } else if edge.certainty == .unresolved {
                edge.exactOrigin == nil
                    ? "Unresolved"
                    : "External · in dependency (rust-analyzer)"
            } else {
                "\(resolutionCertaintyLabel(edge.certainty)) · \(resolutionDispatchLabel(edge.dispatch))"
            }
            if direction == .calls,
               edge.certainty == .probable || edge.certainty == .possible,
               !edge.evidence.isEmpty,
               edge.evidence.allSatisfy({
                   if case .methodNameOnly = $0 { return true }
                   return false
               })
            {
                subtitle += " · name match only"
            }
            if edge.alsoHeuristic {
                subtitle += " · heuristic also matched"
            }
            if !edge.callSites.isEmpty {
                subtitle += " · \(edge.callSites.count) call "
                    + (edge.callSites.count == 1 ? "site" : "sites")
            }
            if isCycle {
                subtitle += " · Already expanded"
            }
            let node = Node(
                kind: .edge,
                title: edge.title,
                subtitle: subtitle,
                badge: badge,
                target: (edge.path, edge.byteOffset),
                line: edge.line,
                children: canExpand ? nil : [],
                isExpandable: canExpand,
                parent: group,
                symbol: edge.symbol,
                expansionIdentity: identity,
                evidence: edge.evidence,
                cycleKey: cycleKey,
                queryTarget: (
                    edge.identityTarget?.file ?? edge.path,
                    edge.identityTarget?.byteOffset ?? edge.byteOffset
                ),
                callSites: edge.callSites
            )
            if !canExpand {
                node.children = evidenceNodes(edge.evidence, parent: node)
            }
            return node
        }
        return group
    }

    private func cycleKeys(from node: Node) -> Set<CycleKey> {
        var result: Set<CycleKey> = []
        var current: Node? = node
        while let item = current {
            if let key = item.cycleKey { result.insert(key) }
            current = item.parent
        }
        return result
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
                        exactQuery: callSite.map {
                            ($0.path, $0.byteOffset, $0.line)
                        },
                        fuzzyTarget: (location.path, location.byteOffset)
                    ))
                }
                if !appendedCandidate,
                   let location = location(for: outgoing.callSite, in: session)
                {
                    edges.append(LoadedEdge(
                        title: outgoing.calleeName,
                        certainty: .unresolved,
                        dispatch: .direct,
                        symbol: nil,
                        path: location.path,
                        byteOffset: location.byteOffset,
                        line: location.line,
                        evidence: []
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
                            evidence: implementation.traitDefinitions.flatMap(\.evidence)
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
                        evidence: candidate.evidence
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
                            evidence: [.nameOnly(nameID: facet.nameID)]
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
