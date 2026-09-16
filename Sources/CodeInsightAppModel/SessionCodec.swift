import CodeInsightCore
import Foundation

package enum SessionCodec {
    /// Decode failures that callers must handle differently: future
    /// schema versions must be preserved untouched, while invalid data
    /// may be quarantined and re-recorded.
    package enum DecodeError: Error, Equatable {
        case unsupportedSchemaVersion(Int)
        case invalid
    }

    package struct Snapshot: Sendable {
        package let projectRoot: String
        package let languages: [LanguageID]
        package let revision: String?
        package let activeTabOrdinal: Int?
        package let panelPreset: String
        package let tabs: [Tab]
        package let navigationHistory: NavigationState?
        package let readingTrail: TrailState?

        package init(
            projectRoot: String,
            language: LanguageID,
            revision: String?,
            activeTabOrdinal: Int?,
            panelPreset: String,
            tabs: [Tab],
            navigationHistory: NavigationState? = nil,
            readingTrail: TrailState? = nil
        ) {
            self.init(
                projectRoot: projectRoot,
                languages: [language],
                revision: revision,
                activeTabOrdinal: activeTabOrdinal,
                panelPreset: panelPreset,
                tabs: tabs,
                navigationHistory: navigationHistory,
                readingTrail: readingTrail
            )
        }

        package init(
            projectRoot: String,
            languages: [LanguageID],
            revision: String?,
            activeTabOrdinal: Int?,
            panelPreset: String,
            tabs: [Tab],
            navigationHistory: NavigationState? = nil,
            readingTrail: TrailState? = nil
        ) {
            self.projectRoot = projectRoot
            self.languages = languages
            self.revision = revision
            self.activeTabOrdinal = activeTabOrdinal
            self.panelPreset = panelPreset
            self.tabs = tabs
            self.navigationHistory = navigationHistory
            self.readingTrail = readingTrail
        }

        package var language: LanguageID {
            languages.first ?? .rust
        }
    }

    package enum Tab: Sendable {
        case file(FileTab)
        case readingSet(ReadingSetTab)
    }

    package struct FileTab: Sendable {
        package let path: String
        package let anchorContentID: ContentID?
        package let scrollAnchor: Anchor?
        package let selectionAnchor: Anchor?
        /// Preview tabs are transient single-visit tabs; at most one may
        /// exist in a snapshot. Missing in v1/v2 data (always false).
        package let isPreview: Bool
        /// Relative LRU rank (0 = least recently activated). The runtime
        /// activation clock is never persisted; nil means unknown (v1/v2),
        /// in which case the saved tab order is the rank.
        package let activationRank: Int?

        package init(
            path: String,
            anchorContentID: ContentID?,
            scrollAnchor: Anchor?,
            selectionAnchor: Anchor?,
            isPreview: Bool = false,
            activationRank: Int? = nil
        ) {
            self.path = path
            self.anchorContentID = anchorContentID
            self.scrollAnchor = scrollAnchor
            self.selectionAnchor = selectionAnchor
            self.isPreview = isPreview
            self.activationRank = activationRank
        }
    }

    package struct ReadingSetTab: Sendable {
        package let title: String
        package let excerpts: [ReadingSetExcerpt]
        package let scrollOffset: Double?
        package let skippedReasons: [String]
        package let activationRank: Int?

        package init(
            title: String,
            excerpts: [ReadingSetExcerpt],
            scrollOffset: Double?,
            skippedReasons: [String] = [],
            activationRank: Int? = nil
        ) {
            self.title = title
            self.excerpts = excerpts
            self.scrollOffset = scrollOffset
            self.skippedReasons = skippedReasons
            self.activationRank = activationRank
        }
    }

    package struct Anchor: Sendable {
        package let byteOffset: UInt32
        package let line: UInt32
        package let column: UInt32
        package let symbolAnchor: String?

        package init(
            byteOffset: UInt32,
            line: UInt32,
            column: UInt32,
            symbolAnchor: String?
        ) {
            self.byteOffset = byteOffset
            self.line = line
            self.column = column
            self.symbolAnchor = symbolAnchor
        }
    }

    /// Persistable navigation jump: everything needed to relocate the
    /// position in a later run. The runtime SnapshotID is deliberately
    /// absent — it is process-local and rebinds on restore.
    package struct Jump: Sendable {
        package let path: String
        package let contentID: ContentID?
        package let byteOffset: UInt32
        package let line: UInt32
        package let column: UInt32
        package let symbolAnchor: String?
        /// Full commit SHA, or nil for the worktree.
        package let revision: String?

        package init(
            path: String,
            contentID: ContentID?,
            byteOffset: UInt32,
            line: UInt32,
            column: UInt32,
            symbolAnchor: String?,
            revision: String?
        ) {
            self.path = path
            self.contentID = contentID
            self.byteOffset = byteOffset
            self.line = line
            self.column = column
            self.symbolAnchor = symbolAnchor
            self.revision = revision
        }
    }

    package struct NavigationState: Sendable {
        package struct Record: Sendable {
            package let jump: Jump
            package let trailNodeID: UUID?

            package init(jump: Jump, trailNodeID: UUID?) {
                self.jump = jump
                self.trailNodeID = trailNodeID
            }
        }

        package let records: [Record]
        /// Legal range is 0...records.count.
        package let cursor: Int
        package let forwardRecord: Record?

        package init(
            records: [Record],
            cursor: Int,
            forwardRecord: Record?
        ) {
            self.records = records
            self.cursor = cursor
            self.forwardRecord = forwardRecord
        }
    }

    package struct TrailState: Sendable {
        package struct Node: Sendable {
            package let id: UUID
            package let jump: Jump

            package init(id: UUID, jump: Jump) {
                self.id = id
                self.jump = jump
            }
        }

        package struct Edge: Sendable {
            package let from: UUID
            package let to: UUID
            package let cause: String
            /// Evidence frozen at navigation time; restored edges carry
            /// no live explanation reference.
            package let frozenInspectorDisplay: ReadingSetExcerpt.FrozenInspectorDisplay?
            package let readingSetRole: String?

            package init(
                from: UUID,
                to: UUID,
                cause: String,
                frozenInspectorDisplay: ReadingSetExcerpt.FrozenInspectorDisplay?,
                readingSetRole: String?
            ) {
                self.from = from
                self.to = to
                self.cause = cause
                self.frozenInspectorDisplay = frozenInspectorDisplay
                self.readingSetRole = readingSetRole
            }
        }

        package let nodes: [Node]
        package let edges: [Edge]
        package let activeNodeID: UUID?

        package init(
            nodes: [Node],
            edges: [Edge],
            activeNodeID: UUID?
        ) {
            self.nodes = nodes
            self.edges = edges
            self.activeNodeID = activeNodeID
        }
    }

    package static func encode(
        _ snapshot: Snapshot,
        maximumTabCount: Int,
        dependencyAllowed: (String) -> Bool
    ) throws -> Data {
        try validate(
            snapshot,
            maximumTabCount: maximumTabCount,
            dependencyAllowed: dependencyAllowed
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Envelope(snapshot))
    }

    package static func decode(
        _ data: Data,
        maximumTabCount: Int,
        dependencyAllowed: (String) -> Bool
    ) throws -> Snapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let envelope: Envelope
        do {
            envelope = try decoder.decode(Envelope.self, from: data)
        } catch {
            // A newer Cairn may write fields this version cannot decode;
            // check the version before treating the data as corrupt so
            // future snapshots are preserved rather than quarantined.
            if let probe = try? decoder.decode(VersionProbe.self, from: data),
               !(1...3).contains(probe.schemaVersion)
            {
                throw DecodeError.unsupportedSchemaVersion(probe.schemaVersion)
            }
            throw error
        }
        guard (1...3).contains(envelope.schemaVersion) else {
            throw DecodeError.unsupportedSchemaVersion(envelope.schemaVersion)
        }
        let snapshot = try envelope.snapshot()
        try validate(
            snapshot,
            maximumTabCount: maximumTabCount,
            dependencyAllowed: dependencyAllowed
        )
        return snapshot
    }

    private static func validate(
        _ snapshot: Snapshot,
        maximumTabCount: Int,
        dependencyAllowed: (String) -> Bool
    ) throws {
        guard maximumTabCount > 0,
              !snapshot.projectRoot.isEmpty,
              snapshot.projectRoot.hasPrefix("/"),
              byteCount(snapshot.projectRoot) <= 4_096,
              (try? LanguageMode.normalize(languages: snapshot.languages))
                  == snapshot.languages,
              snapshot.tabs.count <= maximumTabCount,
              snapshot.activeTabOrdinal.map({ $0 >= 0 }) ?? true,
              PanelPresetModel(rawValue: snapshot.panelPreset) != nil,
              snapshot.revision.map({ byteCount($0) <= 4_096 }) ?? true
        else { throw CodecError.invalid }

        var previewCount = 0
        for tab in snapshot.tabs {
            switch tab {
            case .file(let file):
                try validateFilePath(
                    file.path,
                    dependencyAllowed: dependencyAllowed
                )
                try validateContentID(file.anchorContentID)
                try validateAnchor(file.scrollAnchor)
                try validateAnchor(file.selectionAnchor)
                try validateActivation(file.activationRank)
                if file.isPreview { previewCount += 1 }
            case .readingSet(let readingSet):
                guard byteCount(readingSet.title) <= 4_096,
                      readingSet.excerpts.count <= 50,
                      readingSet.scrollOffset.map({ $0.isFinite && $0 >= 0 }) ?? true,
                      readingSet.skippedReasons.allSatisfy({ byteCount($0) <= 4_096 })
                else { throw CodecError.invalid }
                try validateActivation(readingSet.activationRank)
                for excerpt in readingSet.excerpts {
                    try validate(excerpt)
                }
            }
        }
        guard previewCount <= 1 else { throw CodecError.invalid }
    }

    private static func validateActivation(_ rank: Int?) throws {
        guard rank.map({ $0 >= 0 }) ?? true else { throw CodecError.invalid }
    }

    private static func validateFilePath(
        _ path: String,
        dependencyAllowed: (String) -> Bool
    ) throws {
        guard !path.isEmpty, byteCount(path) <= 4_096 else {
            throw CodecError.invalid
        }
        if path.hasPrefix("/") {
            guard dependencyAllowed(path) else { throw CodecError.invalid }
        } else {
            try validateProjectPath(path)
        }
    }

    /// Causes that may appear on a persisted trail edge.
    private static let trailCauses: Set<String> = [
        "fileSelection", "outline", "relation", "search",
        "historyReplay", "tabActivation",
    ]

    /// Bounded, loss-tolerant normalization of a decoded trail: unknown
    /// data degrades to less navigation instead of failing the whole
    /// snapshot, per the validation layering contract.
    package static func sanitized(_ trail: TrailState) -> TrailState {
        var knownIDs = Set<UUID>()
        var nodes: [TrailState.Node] = []
        for node in trail.nodes where !knownIDs.contains(node.id) {
            guard byteCount(node.jump.path) <= 4_096,
                  node.jump.symbolAnchor.map({ byteCount($0) <= 4_096 }) ?? true,
                  node.jump.revision.map({ byteCount($0) <= 4_096 }) ?? true
            else { continue }
            knownIDs.insert(node.id)
            nodes.append(node)
        }
        var parent: [UUID: UUID] = [:]
        var edges: [TrailState.Edge] = []
        for edge in trail.edges {
            guard knownIDs.contains(edge.from),
                  knownIDs.contains(edge.to),
                  edge.from != edge.to,
                  trailCauses.contains(edge.cause),
                  parent[edge.to] == nil,
                  byteCount(edge.readingSetRole ?? "") <= 4_096
            else { continue }
            // A new edge must not close a cycle: walking up from `from`
            // must not reach `to` (each node has at most one parent, so
            // the walk is linear).
            var upstream: UUID? = edge.from
            var closedCycle = false
            while let current = upstream {
                if current == edge.to {
                    closedCycle = true
                    break
                }
                upstream = parent[current]
            }
            guard !closedCycle else { continue }
            parent[edge.to] = edge.from
            edges.append(edge)
        }
        // Cap the node count: the active node and its ancestor chain win,
        // and when the chain alone exceeds the limit the nodes nearest
        // the current end survive (the earliest survivor becomes a
        // truncated root). Remaining slots go to the most recent nodes.
        if nodes.count > 500 {
            var keepOrder: [UUID] = []
            var seen = Set<UUID>()
            var cursor: UUID? = trail.activeNodeID
            while let current = cursor, keepOrder.count < 500 {
                if knownIDs.contains(current), seen.insert(current).inserted {
                    keepOrder.append(current)
                }
                cursor = parent[current]
            }
            for node in nodes.reversed() where keepOrder.count < 500 {
                if seen.insert(node.id).inserted {
                    keepOrder.append(node.id)
                }
            }
            let keep = Set(keepOrder)
            nodes = nodes.filter { keep.contains($0.id) }
            edges = edges.filter {
                keep.contains($0.from) && keep.contains($0.to)
            }
        }
        let activeNodeID: UUID? = trail.activeNodeID.flatMap { active in
            nodes.contains { node in node.id == active } ? active : nil
        }
        return TrailState(
            nodes: nodes,
            edges: edges,
            activeNodeID: activeNodeID
        )
    }

    /// Bounded normalization of a decoded history: dangling trail
    /// references are nulled (the jump itself stays navigable), the cursor
    /// is clamped into its legal range, and the record limit keeps the
    /// most recent entries.
    package static func sanitized(
        _ history: NavigationState,
        trailNodeIDs: Set<UUID>
    ) -> NavigationState {
        func sanitized(_ record: NavigationState.Record) -> NavigationState.Record {
            NavigationState.Record(
                jump: record.jump,
                trailNodeID: record.trailNodeID.flatMap {
                    trailNodeIDs.contains($0) ? $0 : nil
                }
            )
        }
        let records = history.records
            .filter { byteCount($0.jump.path) <= 4_096 }
            .map(sanitized)
        let kept = Array(records.suffix(200))
        let shift = records.count - kept.count
        return NavigationState(
            records: kept,
            cursor: min(max(history.cursor - shift, 0), kept.count),
            forwardRecord: history.forwardRecord.map(sanitized)
        )
    }

    private static func validateProjectPath(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.hasPrefix("/"),
              !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw CodecError.invalid }
    }

    private static func validateAnchor(_ anchor: Anchor?) throws {
        guard let anchor else { return }
        guard anchor.symbolAnchor.map({ byteCount($0) <= 4_096 }) ?? true
        else { throw CodecError.invalid }
    }

    private static func validate(_ excerpt: ReadingSetExcerpt) throws {
        guard byteCount(excerpt.role) <= 4_096,
              byteCount(excerpt.symbol) <= 4_096,
              byteCount(excerpt.path) <= 4_096,
              byteCount(excerpt.sourceText) <= 16_384,
              excerpt.byteRange.lowerBound <= excerpt.byteRange.upperBound,
              excerpt.caveat.map({ byteCount($0) <= 4_096 }) ?? true,
              excerpt.revision.map({ byteCount($0) <= 4_096 }) ?? true
        else { throw CodecError.invalid }
        switch excerpt.sourceKind {
        case .projectCommit:
            guard excerpt.revision != nil else { throw CodecError.invalid }
            try validateProjectPath(excerpt.path)
        case .worktreeCaptured:
            try validateProjectPath(excerpt.path)
        case .dependencyCaptured:
            guard excerpt.path.hasPrefix("/") else { throw CodecError.invalid }
        }
        try validateContentID(excerpt.contentID)
        try validate(excerpt.inspector)
    }

    private static func validate(
        _ display: ReadingSetExcerpt.FrozenInspectorDisplay
    ) throws {
        guard display.auditRows.count <= 32 else { throw CodecError.invalid }
        let strings = [
            display.nodeTitle,
            display.why,
            display.sourceBody,
            display.verificationTitle,
            display.verificationBody,
            display.correctionBody,
            display.availabilityBody,
            display.environmentBody,
            display.accessibilityValue,
        ] + display.auditRows.flatMap { [$0.label, $0.value] }
        guard strings.reduce(0, { $0 + byteCount($1) }) <= 16_384
        else { throw CodecError.invalid }
    }

    private static func validateContentID(_ contentID: ContentID?) throws {
        guard let contentID else { return }
        guard contentID.algorithm == 1, contentID.bytes.count == 32
        else { throw CodecError.invalid }
    }

    private static func byteCount(_ string: String) -> Int {
        string.utf8.count
    }

    private enum CodecError: Error {
        case invalid
    }

    private struct VersionProbe: Codable {
        let schemaVersion: Int
    }

    private struct Envelope: Codable {
        let schemaVersion: Int
        let projectRoot: String
        let languages: [LanguageID]?
        let language: LanguageID?
        let revision: String?
        let activeTabOrdinal: Int?
        let panelPreset: String
        let tabs: [TabDTO]
        let navigationHistory: NavigationStateDTO?
        let readingTrail: TrailStateDTO?

        init(_ snapshot: Snapshot) {
            schemaVersion = 3
            projectRoot = snapshot.projectRoot
            languages = snapshot.languages
            language = nil
            revision = snapshot.revision
            activeTabOrdinal = snapshot.activeTabOrdinal
            panelPreset = snapshot.panelPreset
            tabs = snapshot.tabs.enumerated().map { TabDTO($1, ordinal: $0) }
            navigationHistory = snapshot.navigationHistory.map(
                NavigationStateDTO.init
            )
            readingTrail = snapshot.readingTrail.map(TrailStateDTO.init)
        }

        func snapshot() throws -> Snapshot {
            func decodeTabs() throws -> [Tab] {
                try tabs.enumerated().map { try $1.tab(ordinal: $0) }
            }
            switch schemaVersion {
            case 1:
                guard languages == nil else { throw CodecError.invalid }
                return Snapshot(
                    projectRoot: projectRoot,
                    language: language ?? .rust,
                    revision: revision,
                    activeTabOrdinal: activeTabOrdinal,
                    panelPreset: panelPreset,
                    tabs: try decodeTabs()
                )
            case 2, 3:
                guard language == nil,
                      let languages
                else { throw CodecError.invalid }
                // Sanitize before validation layering takes effect: a bad
                // edge or dangling reference degrades the navigation
                // blocks instead of failing the whole snapshot.
                let trail: TrailState? = if schemaVersion == 3 {
                    readingTrail.map { sanitized($0.state()) }
                } else {
                    nil
                }
                let history: NavigationState? = if schemaVersion == 3 {
                    navigationHistory.map {
                        sanitized(
                            $0.state(),
                            trailNodeIDs: Set(trail?.nodes.map(\.id) ?? [])
                        )
                    }
                } else {
                    nil
                }
                return Snapshot(
                    projectRoot: projectRoot,
                    languages: languages,
                    revision: revision,
                    activeTabOrdinal: activeTabOrdinal,
                    panelPreset: panelPreset,
                    tabs: try decodeTabs(),
                    navigationHistory: history,
                    readingTrail: trail
                )
            default:
                throw DecodeError.unsupportedSchemaVersion(schemaVersion)
            }
        }
    }

    private struct NavigationStateDTO: Codable {
        struct RecordDTO: Codable {
            let jump: JumpDTO
            let trailNodeID: UUID?
        }

        let records: [RecordDTO]
        let cursor: Int
        let forwardRecord: RecordDTO?

        init(_ state: NavigationState) {
            records = state.records.map { record in
                RecordDTO(
                    jump: JumpDTO(record.jump),
                    trailNodeID: record.trailNodeID
                )
            }
            cursor = state.cursor
            forwardRecord = state.forwardRecord.map { record in
                RecordDTO(
                    jump: JumpDTO(record.jump),
                    trailNodeID: record.trailNodeID
                )
            }
        }

        func state() -> NavigationState {
            NavigationState(
                records: records.map { record in
                    NavigationState.Record(
                        jump: record.jump.jump(),
                        trailNodeID: record.trailNodeID
                    )
                },
                cursor: cursor,
                forwardRecord: forwardRecord.map { record in
                    NavigationState.Record(
                        jump: record.jump.jump(),
                        trailNodeID: record.trailNodeID
                    )
                }
            )
        }
    }

    private struct TrailStateDTO: Codable {
        struct NodeDTO: Codable {
            let id: UUID
            let jump: JumpDTO
        }

        struct EdgeDTO: Codable {
            let from: UUID
            let to: UUID
            let cause: String
            let frozenInspectorDisplay: InspectorDTO?
            let readingSetRole: String?
        }

        let nodes: [NodeDTO]
        let edges: [EdgeDTO]
        let activeNodeID: UUID?

        init(_ state: TrailState) {
            nodes = state.nodes.map { node in
                NodeDTO(id: node.id, jump: JumpDTO(node.jump))
            }
            edges = state.edges.map { edge in
                EdgeDTO(
                    from: edge.from,
                    to: edge.to,
                    cause: edge.cause,
                    frozenInspectorDisplay: edge.frozenInspectorDisplay
                        .map(InspectorDTO.init),
                    readingSetRole: edge.readingSetRole
                )
            }
            activeNodeID = state.activeNodeID
        }

        func state() -> TrailState {
            TrailState(
                nodes: nodes.map { node in
                    TrailState.Node(id: node.id, jump: node.jump.jump())
                },
                edges: edges.map { edge in
                    TrailState.Edge(
                        from: edge.from,
                        to: edge.to,
                        cause: edge.cause,
                        frozenInspectorDisplay: edge.frozenInspectorDisplay?
                            .display,
                        readingSetRole: edge.readingSetRole
                    )
                },
                activeNodeID: activeNodeID
            )
        }
    }

    private struct JumpDTO: Codable {
        let path: String
        let contentID: ContentID?
        let byteOffset: UInt32
        let line: UInt32
        let column: UInt32
        let symbolAnchor: String?
        let revision: String?

        init(_ jump: Jump) {
            path = jump.path
            contentID = jump.contentID
            byteOffset = jump.byteOffset
            line = jump.line
            column = jump.column
            symbolAnchor = jump.symbolAnchor
            revision = jump.revision
        }

        func jump() -> Jump {
            Jump(
                path: path,
                contentID: contentID,
                byteOffset: byteOffset,
                line: line,
                column: column,
                symbolAnchor: symbolAnchor,
                revision: revision
            )
        }
    }

    private struct TabDTO: Codable {
        enum Kind: String, Codable {
            case file
            case readingSet
        }

        let kind: Kind
        let path: String?
        let anchorContentID: ContentID?
        let scrollAnchor: AnchorDTO?
        let selectionAnchor: AnchorDTO?
        let title: String?
        let excerpts: [ExcerptDTO]?
        let scrollOffset: Double?
        let skippedReasons: [String]?
        let isPreview: Bool?
        let activationRank: Int?

        init(_ tab: Tab, ordinal: Int) {
            switch tab {
            case .file(let file):
                kind = .file
                path = file.path
                anchorContentID = file.anchorContentID
                scrollAnchor = file.scrollAnchor.map(AnchorDTO.init)
                selectionAnchor = file.selectionAnchor.map(AnchorDTO.init)
                title = nil
                excerpts = nil
                scrollOffset = nil
                skippedReasons = nil
                isPreview = file.isPreview
                activationRank = file.activationRank ?? ordinal
            case .readingSet(let readingSet):
                kind = .readingSet
                path = nil
                anchorContentID = nil
                scrollAnchor = nil
                selectionAnchor = nil
                title = readingSet.title
                excerpts = readingSet.excerpts.map(ExcerptDTO.init)
                scrollOffset = readingSet.scrollOffset
                skippedReasons = readingSet.skippedReasons
                isPreview = nil
                activationRank = readingSet.activationRank ?? ordinal
            }
        }

        func tab(ordinal: Int) throws -> Tab {
            switch kind {
            case .file:
                guard let path,
                      title == nil,
                      excerpts == nil,
                      scrollOffset == nil,
                      skippedReasons == nil
                else { throw CodecError.invalid }
                return .file(FileTab(
                    path: path,
                    anchorContentID: anchorContentID,
                    scrollAnchor: scrollAnchor?.anchor,
                    selectionAnchor: selectionAnchor?.anchor,
                    isPreview: isPreview ?? false,
                    activationRank: activationRank ?? ordinal
                ))
            case .readingSet:
                guard let title, let excerpts, let skippedReasons,
                      path == nil,
                      anchorContentID == nil,
                      scrollAnchor == nil,
                      selectionAnchor == nil,
                      isPreview == nil
                else { throw CodecError.invalid }
                return .readingSet(ReadingSetTab(
                    title: title,
                    excerpts: excerpts.map { $0.excerpt },
                    scrollOffset: scrollOffset,
                    skippedReasons: skippedReasons,
                    activationRank: activationRank ?? ordinal
                ))
            }
        }
    }

    private struct AnchorDTO: Codable {
        let byteOffset: UInt32
        let line: UInt32
        let column: UInt32
        let symbolAnchor: String?

        init(_ anchor: Anchor) {
            byteOffset = anchor.byteOffset
            line = anchor.line
            column = anchor.column
            symbolAnchor = anchor.symbolAnchor
        }

        var anchor: Anchor {
            Anchor(
                byteOffset: byteOffset,
                line: line,
                column: column,
                symbolAnchor: symbolAnchor
            )
        }
    }

    private struct ExcerptDTO: Codable {
        let role: String
        let symbol: String
        let path: String
        let line: UInt32
        let column: UInt32
        let firstLine: UInt32
        let byteRange: ByteRange
        let sourceText: String
        let contentID: ContentID
        let revision: String?
        let capturedAt: Date
        let sourceKind: SourceKind
        let inspector: InspectorDTO
        let caveat: String?
        let partialLine: Bool

        enum SourceKind: String, Codable {
            case projectCommit
            case worktreeCaptured
            case dependencyCaptured
        }

        init(_ excerpt: ReadingSetExcerpt) {
            role = excerpt.role
            symbol = excerpt.symbol
            path = excerpt.path
            line = excerpt.line
            column = excerpt.column
            firstLine = excerpt.firstLine
            byteRange = excerpt.byteRange
            sourceText = excerpt.sourceText
            contentID = excerpt.contentID
            revision = excerpt.revision
            capturedAt = excerpt.capturedAt
            sourceKind = switch excerpt.sourceKind {
            case .projectCommit: .projectCommit
            case .worktreeCaptured: .worktreeCaptured
            case .dependencyCaptured: .dependencyCaptured
            }
            inspector = InspectorDTO(excerpt.inspector)
            caveat = excerpt.caveat
            partialLine = excerpt.partialLine
        }

        var excerpt: ReadingSetExcerpt {
            let restoredSourceKind: ReadingSetExcerpt.SourceKind = switch sourceKind {
            case .projectCommit: .projectCommit
            case .worktreeCaptured: .worktreeCaptured
            case .dependencyCaptured: .dependencyCaptured
            }
            return ReadingSetExcerpt(
                role: role,
                symbol: symbol,
                path: path,
                line: line,
                column: column,
                firstLine: firstLine,
                byteRange: byteRange,
                sourceText: sourceText,
                contentID: contentID,
                revision: revision,
                capturedAt: capturedAt,
                sourceKind: restoredSourceKind,
                inspector: inspector.display,
                caveat: caveat,
                partialLine: partialLine
            )
        }
    }

    private struct InspectorDTO: Codable {
        let nodeTitle: String
        let badge: Badge
        let why: String
        let sourceBody: String
        let verificationTitle: String
        let verificationBody: String
        let correctionBody: String
        let availabilityBody: String
        let environmentBody: String
        let auditRows: [AuditRowDTO]
        let accessibilityValue: String
        let capturedAt: Date
        let formerCandidateAvailable: Bool

        enum Badge: String, Codable {
            case verified
            case inferred
            case unresolved
        }

        init(_ display: ReadingSetExcerpt.FrozenInspectorDisplay) {
            nodeTitle = display.nodeTitle
            badge = switch display.badge {
            case .verified: .verified
            case .inferred: .inferred
            case .unresolved: .unresolved
            }
            why = display.why
            sourceBody = display.sourceBody
            verificationTitle = display.verificationTitle
            verificationBody = display.verificationBody
            correctionBody = display.correctionBody
            availabilityBody = display.availabilityBody
            environmentBody = display.environmentBody
            auditRows = display.auditRows.map(AuditRowDTO.init)
            accessibilityValue = display.accessibilityValue
            capturedAt = display.capturedAt
            formerCandidateAvailable = display.formerCandidateAvailable
        }

        var display: ReadingSetExcerpt.FrozenInspectorDisplay {
            let restoredBadge: ReadingSetExcerpt.FrozenInspectorDisplay.Badge = switch badge {
            case .verified: .verified
            case .inferred: .inferred
            case .unresolved: .unresolved
            }
            return ReadingSetExcerpt.FrozenInspectorDisplay(
                nodeTitle: nodeTitle,
                badge: restoredBadge,
                why: why,
                sourceBody: sourceBody,
                verificationTitle: verificationTitle,
                verificationBody: verificationBody,
                correctionBody: correctionBody,
                availabilityBody: availabilityBody,
                environmentBody: environmentBody,
                auditRows: auditRows.map(\.row),
                accessibilityValue: accessibilityValue,
                capturedAt: capturedAt,
                formerCandidateAvailable: formerCandidateAvailable
            )
        }
    }

    private struct AuditRowDTO: Codable {
        let label: String
        let value: String

        init(_ row: ReadingSetExcerpt.FrozenInspectorDisplay.AuditRow) {
            label = row.label
            value = row.value
        }

        var row: ReadingSetExcerpt.FrozenInspectorDisplay.AuditRow {
            .init(label: label, value: value)
        }
    }
}
