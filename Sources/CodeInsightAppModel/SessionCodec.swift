import CodeInsightCore
import Foundation

package enum SessionCodec {
    package struct Snapshot: Sendable {
        package let projectRoot: String
        package let revision: String?
        package let activeTabOrdinal: Int?
        package let panelPreset: String
        package let tabs: [Tab]

        package init(
            projectRoot: String,
            revision: String?,
            activeTabOrdinal: Int?,
            panelPreset: String,
            tabs: [Tab]
        ) {
            self.projectRoot = projectRoot
            self.revision = revision
            self.activeTabOrdinal = activeTabOrdinal
            self.panelPreset = panelPreset
            self.tabs = tabs
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

        package init(
            path: String,
            anchorContentID: ContentID?,
            scrollAnchor: Anchor?,
            selectionAnchor: Anchor?
        ) {
            self.path = path
            self.anchorContentID = anchorContentID
            self.scrollAnchor = scrollAnchor
            self.selectionAnchor = selectionAnchor
        }
    }

    package struct ReadingSetTab: Sendable {
        package let title: String
        package let excerpts: [ReadingSetExcerpt]
        package let scrollOffset: Double?
        package let skippedReasons: [String]

        package init(
            title: String,
            excerpts: [ReadingSetExcerpt],
            scrollOffset: Double?,
            skippedReasons: [String] = []
        ) {
            self.title = title
            self.excerpts = excerpts
            self.scrollOffset = scrollOffset
            self.skippedReasons = skippedReasons
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
        let envelope = try decoder.decode(Envelope.self, from: data)
        guard envelope.schemaVersion == 1 else { throw CodecError.invalid }
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
              snapshot.tabs.count <= maximumTabCount,
              snapshot.activeTabOrdinal.map({ $0 >= 0 }) ?? true,
              PanelPresetModel(rawValue: snapshot.panelPreset) != nil,
              snapshot.revision.map({ byteCount($0) <= 4_096 }) ?? true
        else { throw CodecError.invalid }

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
            case .readingSet(let readingSet):
                guard byteCount(readingSet.title) <= 4_096,
                      readingSet.excerpts.count <= 50,
                      readingSet.scrollOffset.map({ $0.isFinite && $0 >= 0 }) ?? true,
                      readingSet.skippedReasons.allSatisfy({ byteCount($0) <= 4_096 })
                else { throw CodecError.invalid }
                for excerpt in readingSet.excerpts {
                    try validate(excerpt)
                }
            }
        }
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

    private struct Envelope: Codable {
        let schemaVersion: Int
        let projectRoot: String
        let revision: String?
        let activeTabOrdinal: Int?
        let panelPreset: String
        let tabs: [TabDTO]

        init(_ snapshot: Snapshot) {
            schemaVersion = 1
            projectRoot = snapshot.projectRoot
            revision = snapshot.revision
            activeTabOrdinal = snapshot.activeTabOrdinal
            panelPreset = snapshot.panelPreset
            tabs = snapshot.tabs.map(TabDTO.init)
        }

        func snapshot() throws -> Snapshot {
            Snapshot(
                projectRoot: projectRoot,
                revision: revision,
                activeTabOrdinal: activeTabOrdinal,
                panelPreset: panelPreset,
                tabs: try tabs.map { try $0.tab() }
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

        init(_ tab: Tab) {
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
            }
        }

        func tab() throws -> Tab {
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
                    selectionAnchor: selectionAnchor?.anchor
                ))
            case .readingSet:
                guard let title, let excerpts, let skippedReasons,
                      path == nil,
                      anchorContentID == nil,
                      scrollAnchor == nil,
                      selectionAnchor == nil
                else { throw CodecError.invalid }
                return .readingSet(ReadingSetTab(
                    title: title,
                    excerpts: excerpts.map { $0.excerpt },
                    scrollOffset: scrollOffset,
                    skippedReasons: skippedReasons
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
