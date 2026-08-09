import CodeInsightCore
import CodeInsightExact
import CodeInsightReaderCore
import Foundation

package enum TabContent: Sendable {
    case file(URL)
    case readingSet(title: String, excerpts: [ReadingSetExcerpt])

    package var fileURL: URL? {
        guard case .file(let file) = self else { return nil }
        return file
    }

    package var title: String {
        switch self {
        case .file(let file): file.lastPathComponent
        case .readingSet(let title, _): title
        }
    }
}

package func makeInspectorDisplay(
    node: RelationTreeModel.Node,
    context: RelationQueryContext,
    correctedTitles: [String],
    readiness: ExactCoordinator.Readiness,
    sourceKind: ReadingSetExcerpt.SourceKind,
    revision: String?,
    contentID: ContentID,
    capturedAt: Date,
    atCapture: Bool = true
) -> ReadingSetExcerpt.FrozenInspectorDisplay? {
    guard let explanation = node.explanation else { return nil }
    let clauses = narrativeClauses(for: explanation, context: context)
    let sourceClauses = clauses.filter(inspectorIsSourceClause)
    let verificationClauses = clauses.filter { !inspectorIsSourceClause($0) }
    let sourceText = sourceClauses.map(renderEnglish).joined(separator: " ")
    let verificationText = verificationClauses.map(renderEnglish)
        .joined(separator: " ")
    let why = (sourceClauses.first ?? verificationClauses.first)
        .map(renderEnglish) ?? "No resolution explanation was captured."
    let badge: ReadingSetExcerpt.FrozenInspectorDisplay.Badge = switch node.badge {
    case "Verified": .verified
    case "Unresolved": .unresolved
    default: .inferred
    }
    let provenance = switch sourceKind {
    case .projectCommit:
        revision.map { "project commit \($0)" } ?? "project captured"
    case .worktreeCaptured: "worktree captured"
    case .dependencyCaptured: "dependency captured"
    }
    let availability = switch (readiness, atCapture) {
    case (.preparing, true): "Exact provider was preparing at capture."
    case (.preparing, false): "Preparing exact provider…"
    case (.ready, true): "Exact provider was ready at capture."
    case (.ready, false): "Exact provider is ready."
    case (.unavailable(let reason), true):
        "Exact provider was unavailable at capture: \(reason)"
    case (.unavailable(let reason), false):
        "Exact provider unavailable: \(reason)"
    case (.off(let reason), true): "Exact provider was off at capture: \(reason)"
    case (.off(let reason), false): "Exact provider is off: \(reason)"
    }
    let environment = inspectorEnvironment(
        explanation.primaryTrace,
        context: context
    ).map { value in
        let limitations = value.limitations
            .sorted { $0.rawValue < $1.rawValue }
            .map(\.displayName)
        let trust = switch value.trustMode {
        case .safe: "Safe"
        case .trusted: "Trusted"
        }
        return ([trust] + limitations).joined(separator: " · ")
    }
    let environmentBody = if atCapture {
        environment.map { "\($0) at capture." }
            ?? "No exact analysis environment was recorded at capture."
    } else {
        environment ?? ""
    }
    let contentPrefix = contentID.bytes.prefix(8).map {
        String(format: "%02x", $0)
    }.joined()
    let captured = ISO8601DateFormatter().string(from: capturedAt)
    let correction = correctedTitles.isEmpty ? "" :
        "This target replaced earlier source candidates: "
            + correctedTitles.joined(separator: ", ") + "."
    return ReadingSetExcerpt.FrozenInspectorDisplay(
        nodeTitle: node.title,
        badge: badge,
        why: why,
        sourceBody: sourceText,
        verificationTitle: verificationClauses.contains {
            if case .conflict = $0 { return true }
            return false
        } ? "VERIFICATION CONFLICT" : "VERIFICATION",
        verificationBody: verificationText,
        correctionBody: correction,
        availabilityBody: availability,
        environmentBody: environmentBody,
        auditRows: [
            .init(label: "Source", value: provenance),
            .init(label: "Content", value: contentPrefix),
            .init(label: "Captured at", value: captured),
        ],
        accessibilityValue: ([node.badge, why] + clauses.map(renderEnglish))
            .compactMap { $0 }.joined(separator: ", "),
        capturedAt: capturedAt,
        formerCandidateAvailable: node.modifiers.contains("Conflict/Corrected")
    )
}

private func inspectorIsSourceClause(_ clause: NarrativeClause) -> Bool {
    switch clause {
    case .sourceEvidence, .candidateCompleteness, .candidateRelationSet: true
    default: false
    }
}

private func inspectorEnvironment(
    _ trace: ResolutionTrace,
    context: RelationQueryContext
) -> ExactAnalysisEnvironment? {
    let attribution: ExactAttribution? = switch trace {
    case .verificationOnly(let observation),
         .corroborated(_, let observation): observation.attribution
    case .candidateOnly, .conflict:
        if case .completed(.completed(let value, _, _)) = context.exactQuery {
            value
        } else {
            nil
        }
    }
    return attribution?.environment
}

package func makeReadingSetExcerpt(
    role: String,
    node: RelationTreeModel.Node,
    context: RelationQueryContext,
    correctedTitles: [String],
    readiness: ExactCoordinator.Readiness,
    bytes: [UInt8],
    contentID: ContentID,
    revision: String?,
    sourceKind: ReadingSetExcerpt.SourceKind,
    capturedAt: Date = Date()
) -> ReadingSetExcerpt? {
    guard let target = node.target,
          String(bytes: bytes, encoding: .utf8) != nil
    else { return nil }
    let loader = DocumentLoader(source: { _ in bytes })
    guard let document = try? loader.load(
        file: URL(fileURLWithPath: target.path)
    ).document,
          contentID == document.contentID,
          let coordinate = document.lineTable.lineColumn(at: target.byteOffset),
          let inspector = makeInspectorDisplay(
              node: node,
              context: context,
              correctedTitles: correctedTitles,
              readiness: readiness,
              sourceKind: sourceKind,
              revision: revision,
              contentID: contentID,
              capturedAt: capturedAt
          )
    else { return nil }
    let lineCount = document.lineTable.lineStarts.count
    let targetLine = Int(coordinate.line)
    let facet = document.outlineFacets.filter {
        $0.range.contains(target.byteOffset)
    }.min { $0.range.length < $1.range.length }
    let firstLine = facet.flatMap {
        document.lineTable.lineColumn(at: $0.range.lowerBound)?.line
    }.map(Int.init) ?? max(1, targetLine - 20)
    let facetEnd = facet.map {
        max($0.range.lowerBound, $0.range.upperBound &- 1)
    }
    let lastLine = facetEnd.flatMap {
        document.lineTable.lineColumn(at: $0)?.line
    }.map(Int.init) ?? min(lineCount, targetLine + 20)
    var lowerLine = max(firstLine, targetLine - 39)
    var upperLine = min(lastLine, lowerLine + 79)
    lowerLine = max(firstLine, upperLine - 79)
    func range(_ lower: Int, _ upper: Int) -> ByteRange {
        let start = document.lineTable.lineStarts[lower - 1]
        let end = upper < lineCount
            ? document.lineTable.lineStarts[upper]
            : UInt32(bytes.count)
        return ByteRange(lowerBound: start, upperBound: end)
    }
    var frozenRange = range(lowerLine, upperLine)
    while frozenRange.length > 8 * 1_024 && lowerLine < upperLine {
        if targetLine - lowerLine > upperLine - targetLine {
            lowerLine += 1
        } else {
            upperLine -= 1
        }
        frozenRange = range(lowerLine, upperLine)
    }
    guard frozenRange.length <= 8 * 1_024,
          let lower = Int(exactly: frozenRange.lowerBound),
          let upper = Int(exactly: frozenRange.upperBound),
          bytes.indices.contains(lower) || lower == bytes.endIndex,
          upper <= bytes.count,
          let source = String(bytes: bytes[lower..<upper], encoding: .utf8)
    else { return nil }
    let prefix = lowerLine > firstLine ? "…\n" : ""
    let suffix = upperLine < lastLine ? "\n…" : ""
    return ReadingSetExcerpt(
        role: role,
        symbol: node.title,
        path: target.path,
        line: coordinate.line,
        column: coordinate.column,
        firstLine: UInt32(lowerLine),
        byteRange: frozenRange,
        sourceText: prefix + source + suffix,
        contentID: contentID,
        revision: revision,
        capturedAt: capturedAt,
        sourceKind: sourceKind,
        inspector: inspector,
        caveat: inspector.badge == .inferred ? "name match only" : nil
    )
}

package struct ReadingSetExcerpt: Sendable {
    package enum SourceKind: Sendable {
        case projectCommit
        case worktreeCaptured
        case dependencyCaptured
    }

    package struct FrozenInspectorDisplay: Sendable {
        package enum Badge: String, Sendable {
            case verified = "VERIFIED"
            case inferred = "INFERRED"
            case unresolved = "UNRESOLVED"
        }

        package struct AuditRow: Sendable {
            package let label: String
            package let value: String

            package init(label: String, value: String) {
                self.label = label
                self.value = value
            }
        }

        package let nodeTitle: String
        package let badge: Badge
        package let why: String
        package let sourceBody: String
        package let verificationTitle: String
        package let verificationBody: String
        package let correctionBody: String
        package let availabilityBody: String
        package let environmentBody: String
        package let auditRows: [AuditRow]
        package let accessibilityValue: String
        package let capturedAt: Date
        package let formerCandidateAvailable: Bool

        package init(
            nodeTitle: String,
            badge: Badge,
            why: String,
            sourceBody: String,
            verificationTitle: String,
            verificationBody: String,
            correctionBody: String,
            availabilityBody: String,
            environmentBody: String,
            auditRows: [AuditRow],
            accessibilityValue: String,
            capturedAt: Date,
            formerCandidateAvailable: Bool
        ) {
            self.nodeTitle = nodeTitle
            self.badge = badge
            self.why = why
            self.sourceBody = sourceBody
            self.verificationTitle = verificationTitle
            self.verificationBody = verificationBody
            self.correctionBody = correctionBody
            self.availabilityBody = availabilityBody
            self.environmentBody = environmentBody
            self.auditRows = auditRows
            self.accessibilityValue = accessibilityValue
            self.capturedAt = capturedAt
            self.formerCandidateAvailable = formerCandidateAvailable
        }
    }

    package let role: String
    package let symbol: String
    package let path: String
    package let line: UInt32
    package let column: UInt32
    package let firstLine: UInt32
    package let byteRange: ByteRange
    package let sourceText: String
    package let contentID: ContentID
    package let revision: String?
    package let capturedAt: Date
    package let sourceKind: SourceKind
    package let inspector: FrozenInspectorDisplay
    package let caveat: String?
    package let partialLine: Bool

    package init(
        role: String,
        symbol: String,
        path: String,
        line: UInt32,
        column: UInt32,
        firstLine: UInt32,
        byteRange: ByteRange,
        sourceText: String,
        contentID: ContentID,
        revision: String?,
        capturedAt: Date,
        sourceKind: SourceKind,
        inspector: FrozenInspectorDisplay,
        caveat: String? = nil,
        partialLine: Bool = false
    ) {
        self.role = role
        self.symbol = symbol
        self.path = path
        self.line = line
        self.column = column
        self.firstLine = firstLine
        self.byteRange = byteRange
        self.sourceText = sourceText
        self.contentID = contentID
        self.revision = revision
        self.capturedAt = capturedAt
        self.sourceKind = sourceKind
        self.inspector = inspector
        self.caveat = caveat
        self.partialLine = partialLine
    }
}
