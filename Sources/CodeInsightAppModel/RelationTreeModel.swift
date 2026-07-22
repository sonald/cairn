import CodeInsightCore
import CodeInsightEngine
import Foundation
import Observation

@MainActor
@Observable
public final class RelationTreeModel {
    public enum Direction: Hashable, Sendable {
        case callers
        case calls
        case implementations
    }

    public final class Node {
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
        public let target: (path: String, byteOffset: UInt32)?
        public let line: UInt32?
        public fileprivate(set) var children: [Node]?
        public fileprivate(set) var isExpandable: Bool

        fileprivate weak var parent: Node?
        fileprivate let symbol: SymbolOccurrenceID?
        fileprivate let evidence: [ResolutionEvidence]
        fileprivate let cycleKey: CycleKey?
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
            evidence: [ResolutionEvidence] = [],
            cycleKey: CycleKey? = nil
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
            self.evidence = evidence
            self.cycleKey = cycleKey
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
        let exactQuery: (file: String, byteOffset: UInt32)?
        let fuzzyTarget: (file: String, byteOffset: UInt32)?

        init(
            title: String,
            certainty: Certainty,
            dispatch: DispatchKind,
            symbol: SymbolOccurrenceID?,
            path: String,
            byteOffset: UInt32,
            line: UInt32,
            evidence: [ResolutionEvidence],
            exactQuery: (file: String, byteOffset: UInt32)? = nil,
            fuzzyTarget: (file: String, byteOffset: UInt32)? = nil
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
        }
    }

    struct LoadResult: Sendable {
        let edges: [LoadedEdge]
        let isTruncated: Bool
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

    public private(set) var root: Node?
    public private(set) var direction: Direction = .callers
    public private(set) var generation: UInt64 = 0
    public private(set) var requestID: UInt64 = 0
    public var onSelect: @MainActor (Node) -> Void = { _ in }

    private let loader: Loader
    private var exactResolver: ExactResolver?
    private var session: EngineSession?
    private var context: QueryContext?

    public init() {
        loader = { session, context, symbol, direction in
            try Self.load(
                session: session,
                context: context,
                symbol: symbol,
                direction: direction
            )
        }
        exactResolver = nil
    }

    init(
        loader: @escaping Loader,
        exactResolver: ExactResolver? = nil
    ) {
        self.loader = loader
        self.exactResolver = exactResolver
    }

    func attachExactCoordinator(_ coordinator: ExactCoordinator) {
        exactResolver = { [weak coordinator] file, offset, generation in
            await coordinator?.definition(
                file: file,
                byteOffset: offset,
                generation: generation
            )
        }
    }

    public func updateProjectState(_ state: ProjectState) {
        generation &+= 1
        requestID &+= 1
        root = nil
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
        symbol: SymbolOccurrenceID,
        direction: Direction
    ) -> Task<Void, Never>? {
        generation &+= 1
        self.direction = direction
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
            cycleKey: CycleKey(
                path: location.path,
                identity: "facet:\(symbol.localIndex)"
            )
        )
        if !node.isExpandable { node.children = [] }
        root = node
        return expansionTask(for: node)
    }

    public func expand(_ node: Node) async {
        await expansionTask(for: node)?.value
    }

    public func select(_ node: Node) {
        onSelect(node)
    }

    private func expansionTask(for node: Node) -> Task<Void, Never>? {
        guard node.isExpandable, node.children == nil,
              let symbol = node.symbol, let session, let context
        else { return nil }

        requestID &+= 1
        let currentRequestID = requestID
        let currentGeneration = generation
        node.loadRequestID = currentRequestID
        node.children = [Node(kind: .loading, title: "Loading…", parent: node)]

        let loader = self.loader
        let direction = self.direction
        return Task { [weak self, weak node] in
            let result = await Task.detached(priority: .userInitiated) {
                try await loader(session, context, symbol, direction)
            }.result
            guard let self, let node,
                  generation == currentGeneration,
                  node.loadRequestID == currentRequestID,
                  self.session === session
            else { return }

            switch result {
            case let .success(loaded):
                let loaded = await promoteExactEdges(
                    loaded,
                    generation: context.generation
                )
                guard generation == currentGeneration,
                      node.loadRequestID == currentRequestID,
                      self.session === session
                else { return }
                node.children = makeChildren(
                    from: loaded,
                    under: node,
                    direction: direction,
                    session: session
                )
            case .failure:
                node.children = [
                    Node(
                        kind: .error,
                        title: "Could not load relations.",
                        parent: node
                    ),
                ] + evidenceNodes(node.evidence, parent: node)
            }
        }
    }

    private func promoteExactEdges(
        _ loaded: LoadResult,
        generation: UInt64
    ) async -> LoadResult {
        guard let exactResolver else { return loaded }
        var edges = loaded.edges
        await withTaskGroup(of: (Int, Bool).self) { group in
            for (index, edge) in edges.prefix(500).enumerated() {
                guard let query = edge.exactQuery,
                      let fuzzyTarget = edge.fuzzyTarget
                else { continue }
                group.addTask {
                    let exact = await exactResolver(
                        query.file,
                        query.byteOffset,
                        generation
                    )
                    return (
                        index,
                        exact?.location.file == fuzzyTarget.file
                            && exact?.location.byteOffset
                                == Int(fuzzyTarget.byteOffset)
                    )
                }
            }
            for await (index, matches) in group where matches {
                edges[index].certainty = .exact
            }
        }
        return LoadResult(edges: edges, isTruncated: loaded.isTruncated)
    }

    private func makeChildren(
        from loaded: LoadResult,
        under parent: Node,
        direction: Direction,
        session: EngineSession
    ) -> [Node] {
        let capped = Array(loaded.edges.prefix(500))
        let exact = capped.filter { $0.certainty == .exact }
        var children = [
            makeGroup(
                // Keep the empty group visible: it teaches that no exact provider
                // contributed evidence instead of implying exact coverage.
                exact.isEmpty ? "Exact (0)" : "Exact",
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
                "Possible",
                edges: capped.filter {
                    $0.certainty == .probable
                        || $0.certainty == .possible
                },
                under: parent,
                direction: direction,
                session: session
            ),
        ]
        let external = capped.filter { $0.certainty == .unresolved }
        if direction == .calls, !external.isEmpty {
            children.append(makeGroup(
                "External / Unresolved",
                edges: external,
                under: parent,
                direction: direction,
                session: session
            ))
        }
        if loaded.isTruncated || loaded.edges.count > 500 {
            children.append(Node(
                kind: .truncated,
                title: "Truncated after 500 edges",
                parent: parent
            ))
        }
        children += evidenceNodes(parent.evidence, parent: parent)
        return children
    }

    private func makeGroup(
        _ title: String,
        edges: [LoadedEdge],
        under parent: Node,
        direction: Direction,
        session: EngineSession
    ) -> Node {
        let group = Node(
            kind: .group,
            title: title,
            children: [],
            isExpandable: !edges.isEmpty,
            parent: parent
        )
        let ancestorKeys = cycleKeys(from: parent)
        group.children = edges.map { edge in
            let identity: String
            if let symbol = edge.symbol,
               symbol.localKind == .declarationFacet
            {
                identity = "facet:\(symbol.localIndex)"
            } else {
                identity = "byte:\(edge.byteOffset)"
            }
            let cycleKey = CycleKey(
                path: edge.path,
                identity: identity
            )
            let isCycle = ancestorKeys.contains(cycleKey)
            let canExpand = !isCycle && edge.symbol.map {
                Self.canExpand($0, direction: direction, session: session)
            } == true
            let node = Node(
                kind: .edge,
                title: edge.title,
                subtitle: edge.certainty == .unresolved
                    ? "Unresolved"
                    : "\(resolutionCertaintyLabel(edge.certainty)) · \(resolutionDispatchLabel(edge.dispatch))",
                badge: edge.certainty == .exact
                    ? (isCycle ? "Exact · lsp · ↻" : "Exact · lsp")
                    : (isCycle ? "↻" : nil),
                target: (edge.path, edge.byteOffset),
                line: edge.line,
                children: canExpand ? nil : [],
                isExpandable: canExpand,
                parent: group,
                symbol: edge.symbol,
                evidence: edge.evidence,
                cycleKey: cycleKey
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
    ) throws -> LoadResult {
        switch direction {
        case .callers:
            guard let name = symbolTitle(symbol, in: session) else {
                return LoadResult(edges: [], isTruncated: false)
            }
            let fuzzyTarget = location(for: symbol, in: session)
            let callers = try session.callers(of: name, context: context)
            return LoadResult(
                edges: callers.compactMap { caller in
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
                        exactQuery: (location.path, location.byteOffset),
                        fuzzyTarget: fuzzyTarget.map { ($0.path, $0.byteOffset) }
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
                        exactQuery: callSite.map { ($0.path, $0.byteOffset) },
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
        }
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

    private nonisolated static func evidenceLabel(
        _ evidence: ResolutionEvidence
    ) -> String {
        switch evidence {
        case .sameFile: "same file"
        case .uniqueImport: "via import"
        case .lexicalBinding: "lexical binding"
        case .nameOnly: "name match"
        case .methodNameOnly: "method name match"
        }
    }

    fileprivate struct CycleKey: Hashable {
        let path: String
        let identity: String
    }
}
