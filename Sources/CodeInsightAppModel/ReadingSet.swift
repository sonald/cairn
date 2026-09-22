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
    atCapture: Bool = true,
    language: String? = nil
) -> ReadingSetExcerpt.FrozenInspectorDisplay? {
    if language == nil && atCapture {
        let displays = Dictionary(uniqueKeysWithValues: ["en", "zh-Hans"].compactMap { (language: String) in
            makeInspectorDisplay(
                node: node, context: context, correctedTitles: correctedTitles,
                readiness: readiness, sourceKind: sourceKind, revision: revision,
                contentID: contentID, capturedAt: capturedAt, atCapture: atCapture,
                language: language
            ).map { (language, $0) }
        })
        guard var display = displays[modelDisplayLanguage] ?? displays["en"] else { return nil }
        display.localizedDisplays = displays
        return display
    }
    guard let explanation = node.explanation else { return nil }
    let clauses = narrativeClauses(for: explanation, context: context)
    let sourceClauses = clauses.filter(inspectorIsSourceClause)
    let verificationClauses = clauses.filter { !inspectorIsSourceClause($0) }
    let sourceText = sourceClauses.map { renderLocalized($0, language: language) }.joined(separator: " ")
    let verificationText = verificationClauses.map { renderLocalized($0, language: language) }
        .joined(separator: " ")
    let why = (sourceClauses.first ?? verificationClauses.first)
        .map { renderLocalized($0, language: language) } ?? localized("model.inspector.noExplanation", language: language)
    let badge: ReadingSetExcerpt.FrozenInspectorDisplay.Badge = switch node.certainty {
    case .exact: .verified
    case .unresolved: .unresolved
    default: .inferred
    }
    let provenance = switch sourceKind {
    case .projectCommit:
        revision.map { localizedFormat("model.inspector.projectCommit", language: language, $0) } ?? localized("model.inspector.projectCaptured", language: language)
    case .worktreeCaptured: localized("model.inspector.worktreeCaptured", language: language)
    case .dependencyCaptured: localized("model.inspector.dependencyCaptured", language: language)
    }
    let availability = switch (readiness, atCapture) {
    case (.preparing, true): localized("model.inspector.preparingCaptured", language: language)
    case (.preparing, false): localized("model.inspector.preparing", language: language)
    case (.ready, true): localized("model.inspector.readyCaptured", language: language)
    case (.ready, false): localized("model.inspector.ready", language: language)
    case (.unavailable(let reason), true):
        localizedFormat("model.inspector.unavailableCaptured", language: language, frozenReadinessReason(reason, language: language))
    case (.unavailable(let reason), false):
        localizedFormat("model.inspector.unavailable", language: language, frozenReadinessReason(reason, language: language))
    case (.off(let reason), true): localizedFormat("model.inspector.offCaptured", language: language, frozenReadinessReason(reason, language: language))
    case (.off(let reason), false): localizedFormat("model.inspector.off", language: language, frozenReadinessReason(reason, language: language))
    }
    let environment = inspectorEnvironment(
        explanation.primaryTrace,
        context: context
    ).map { value in
        let limitations = value.limitations
            .sorted { $0.rawValue < $1.rawValue }
            .map { limitation in
                switch limitation {
                case .buildScriptsDisabled: localized("model.limitation.buildScripts", language: language)
                case .procMacrosDisabled: localized("model.limitation.procMacros", language: language)
                case .dependenciesUnavailableOffline: localized("model.limitation.offline", language: language)
                }
            }
        let trust = switch value.trustMode {
        case .safe: localized("model.inspector.safe", language: language)
        case .trusted: localized("model.inspector.trusted", language: language)
        }
        return ([trust] + limitations).joined(separator: " · ")
    }
    let environmentBody = if atCapture {
        environment.map { localizedFormat("model.inspector.environmentCaptured", language: language, $0) }
            ?? localized("model.inspector.noEnvironment", language: language)
    } else {
        environment ?? ""
    }
    let contentPrefix = contentID.bytes.prefix(8).map {
        String(format: "%02x", $0)
    }.joined()
    let captured = ISO8601DateFormatter().string(from: capturedAt)
    let correction = correctedTitles.isEmpty ? "" :
        localizedFormat("model.inspector.replaced", language: language, correctedTitles.joined(separator: ", "))
    return ReadingSetExcerpt.FrozenInspectorDisplay(
        nodeTitle: node.title,
        badge: badge,
        why: why,
        sourceBody: sourceText,
        verificationTitle: verificationClauses.contains {
            if case .conflict = $0 { return true }
            return false
        } ? localized("model.inspector.conflict", language: language) : localized("model.inspector.verification", language: language),
        verificationBody: verificationText,
        correctionBody: correction,
        availabilityBody: availability,
        environmentBody: environmentBody,
        auditRows: [
            .init(label: localized("model.inspector.source", language: language), value: provenance),
            .init(label: localized("model.inspector.content", language: language), value: contentPrefix),
            .init(label: localized("model.inspector.capturedAt", language: language), value: captured),
        ],
        accessibilityValue: ([localized("model.relation." + badge.rawValue.lowercased(), language: language), why] + clauses.map { renderLocalized($0, language: language) })
            .compactMap { $0 }.joined(separator: ", "),
        capturedAt: capturedAt,
        formerCandidateAvailable: node.isCorrectedCandidate
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
    languageMode: LanguageMode,
    bytes: [UInt8],
    contentID: ContentID,
    revision: String?,
    sourceKind: ReadingSetExcerpt.SourceKind,
    capturedAt: Date = Date()
) -> ReadingSetExcerpt? {
    guard let target = node.target,
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
    return makeReadingSetExcerpt(
        role: role,
        symbol: node.title,
        path: target.path,
        targetByte: target.byteOffset,
        languageMode: languageMode,
        bytes: bytes,
        contentID: contentID,
        revision: revision,
        sourceKind: sourceKind,
        inspector: inspector
    )
}

package func makeReadingSetExcerpt(
    role: String,
    symbol: String,
    path: String,
    targetByte: UInt32,
    languageMode: LanguageMode,
    bytes: [UInt8],
    contentID: ContentID,
    revision: String?,
    sourceKind: ReadingSetExcerpt.SourceKind,
    inspector: ReadingSetExcerpt.FrozenInspectorDisplay
) -> ReadingSetExcerpt? {
    guard ContentID.sha256(of: bytes) == contentID else { return nil }
    let loader = DocumentLoader(source: { _ in bytes })
    guard let document = try? loader.load(
        file: URL(fileURLWithPath: path),
        languageMode: languageMode
    ).document,
          let coordinate = document.lineTable.lineColumn(at: targetByte)
    else { return nil }
    let facet = document.outlineFacets.filter {
        $0.range.contains(targetByte)
    }.min { $0.range.length < $1.range.length }
    guard let frozen = frozenReadingSetSource(
        bytes: bytes,
        targetByte: targetByte,
        enclosingRange: facet?.range
    ) else { return nil }
    return ReadingSetExcerpt(
        role: role,
        symbol: symbol,
        path: path,
        line: coordinate.line,
        column: coordinate.column,
        firstLine: frozen.firstLine,
        byteRange: frozen.byteRange,
        sourceText: frozen.sourceText,
        contentID: contentID,
        revision: revision,
        capturedAt: inspector.capturedAt,
        sourceKind: sourceKind,
        inspector: inspector,
        caveat: inspector.badge == .inferred ? "Name-only match" : nil,
        partialLine: frozen.partialLine
    )
}

package func expandedReadingSetExcerpt(
    _ excerpt: ReadingSetExcerpt,
    bytes: [UInt8]
) -> ReadingSetExcerpt? {
    guard ContentID.sha256(of: bytes) == excerpt.contentID,
          let targetByte = LineTable(bytes: bytes).byteOffset(
              line: excerpt.line,
              column: excerpt.column
          ),
          let frozen = frozenReadingSetSource(
              bytes: bytes,
              targetByte: targetByte,
              previousRange: excerpt.byteRange,
              previousWasPartialLine: excerpt.partialLine
          )
    else { return nil }
    return ReadingSetExcerpt(
        role: excerpt.role,
        symbol: excerpt.symbol,
        path: excerpt.path,
        line: excerpt.line,
        column: excerpt.column,
        firstLine: frozen.firstLine,
        byteRange: frozen.byteRange,
        sourceText: frozen.sourceText,
        contentID: excerpt.contentID,
        revision: excerpt.revision,
        capturedAt: excerpt.capturedAt,
        sourceKind: excerpt.sourceKind,
        inspector: excerpt.inspector,
        caveat: excerpt.caveat,
        partialLine: frozen.partialLine
    )
}

package func frozenReadingSetSource(
    bytes: [UInt8],
    targetByte: UInt32,
    enclosingRange: ByteRange? = nil,
    previousRange: ByteRange? = nil,
    previousWasPartialLine: Bool = false
) -> (
    byteRange: ByteRange,
    sourceText: String,
    firstLine: UInt32,
    partialLine: Bool
)? {
    guard String(bytes: bytes, encoding: .utf8) != nil else { return nil }
    let table = LineTable(bytes: bytes)
    guard let targetCoordinate = table.lineColumn(at: targetByte) else {
        return nil
    }
    let lineCount = table.lineStarts.count
    let targetLine = Int(targetCoordinate.line)
    let expanded = previousRange != nil
    let byteLimit = expanded ? 16 * 1_024 : 8 * 1_024
    let lineLimit = expanded ? 200 : 80

    if previousWasPartialLine {
        return partialReadingSetLine(
            bytes: bytes,
            table: table,
            targetByte: targetByte,
            targetLine: targetLine,
            byteLimit: byteLimit
        )
    }

    let outerLower: Int
    let outerUpper: Int
    var requestedLower: Int
    var requestedUpper: Int
    if let previousRange,
       let previousLower = table.lineColumn(at: previousRange.lowerBound)?.line,
       previousRange.upperBound > 0,
       let previousUpper = table.lineColumn(
           at: min(UInt32(bytes.count), previousRange.upperBound) &- 1
       )?.line
    {
        outerLower = 1
        outerUpper = lineCount
        requestedLower = max(outerLower, Int(previousLower) - 40)
        requestedUpper = min(outerUpper, Int(previousUpper) + 40)
    } else if let enclosingRange,
              enclosingRange.upperBound > enclosingRange.lowerBound,
              let lower = table.lineColumn(at: enclosingRange.lowerBound)?.line
    {
        let lastByte = max(
            enclosingRange.lowerBound,
            min(UInt32(bytes.count), enclosingRange.upperBound) &- 1
        )
        guard let upper = table.lineColumn(at: lastByte)?.line else { return nil }
        outerLower = Int(lower)
        outerUpper = Int(upper)
        requestedLower = outerLower
        requestedUpper = outerUpper
    } else {
        outerLower = max(1, targetLine - 20)
        outerUpper = min(lineCount, targetLine + 20)
        requestedLower = outerLower
        requestedUpper = outerUpper
    }

    requestedLower = min(requestedLower, targetLine)
    requestedUpper = max(requestedUpper, targetLine)
    var lowerLine = max(requestedLower, targetLine - (lineLimit - 1) / 2)
    var upperLine = min(requestedUpper, lowerLine + lineLimit - 1)
    lowerLine = max(requestedLower, upperLine - lineLimit + 1)

    func byteRange(_ lower: Int, _ upper: Int) -> ByteRange {
        let start = table.lineStarts[lower - 1]
        let end = upper < lineCount
            ? table.lineStarts[upper]
            : UInt32(bytes.count)
        return ByteRange(lowerBound: start, upperBound: end)
    }
    func markerBytes(_ lower: Int, _ upper: Int) -> Int {
        (lower > outerLower ? 4 : 0) + (upper < outerUpper ? 4 : 0)
    }

    var frozenRange = byteRange(lowerLine, upperLine)
    while Int(frozenRange.length) + markerBytes(lowerLine, upperLine) > byteLimit,
          lowerLine < upperLine
    {
        if targetLine - lowerLine > upperLine - targetLine {
            lowerLine += 1
        } else {
            upperLine -= 1
        }
        frozenRange = byteRange(lowerLine, upperLine)
    }
    if Int(frozenRange.length) + markerBytes(lowerLine, upperLine) > byteLimit {
        return partialReadingSetLine(
            bytes: bytes,
            table: table,
            targetByte: targetByte,
            targetLine: targetLine,
            byteLimit: byteLimit
        )
    }
    guard let lower = Int(exactly: frozenRange.lowerBound),
          let upper = Int(exactly: frozenRange.upperBound),
          upper <= bytes.count,
          let source = String(bytes: bytes[lower..<upper], encoding: .utf8)
    else { return nil }
    let prefix = lowerLine > outerLower ? "…\n" : ""
    let suffix = upperLine < outerUpper
        ? (source.hasSuffix("\n") ? "…" : "\n…")
        : ""
    let text = prefix + source + suffix
    guard text.utf8.count <= byteLimit else { return nil }
    return (frozenRange, text, UInt32(lowerLine), false)
}

private func partialReadingSetLine(
    bytes: [UInt8],
    table: LineTable,
    targetByte: UInt32,
    targetLine: Int,
    byteLimit: Int
) -> (
    byteRange: ByteRange,
    sourceText: String,
    firstLine: UInt32,
    partialLine: Bool
)? {
    let lineStart = Int(table.lineStarts[targetLine - 1])
    let nextLine = targetLine < table.lineStarts.count
        ? Int(table.lineStarts[targetLine])
        : bytes.count
    var lineEnd = nextLine
    if lineEnd > lineStart, bytes[lineEnd - 1] == 0x0A { lineEnd -= 1 }
    if lineEnd > lineStart, bytes[lineEnd - 1] == 0x0D { lineEnd -= 1 }
    guard lineStart < lineEnd else { return nil }

    let target = min(max(Int(targetByte), lineStart), lineEnd - 1)
    var scalarStart = target
    while scalarStart > lineStart, bytes[scalarStart] & 0xC0 == 0x80 {
        scalarStart -= 1
    }
    var scalarEnd = scalarStart + 1
    while scalarEnd < lineEnd, bytes[scalarEnd] & 0xC0 == 0x80 {
        scalarEnd += 1
    }
    let prefixBytes = scalarStart > lineStart ? 3 : 0
    let suffixBytes = scalarEnd < lineEnd ? 3 : 0
    let sourceBudget = byteLimit - prefixBytes - suffixBytes
    guard sourceBudget >= scalarEnd - scalarStart else { return nil }

    var lower = max(lineStart, scalarStart - sourceBudget / 2)
    while lower > lineStart, bytes[lower] & 0xC0 == 0x80 { lower -= 1 }
    var upper = min(lineEnd, lower + sourceBudget)
    while upper > scalarEnd, upper < lineEnd, bytes[upper] & 0xC0 == 0x80 {
        upper -= 1
    }
    if upper < scalarEnd {
        upper = scalarEnd
        lower = max(lineStart, upper - sourceBudget)
        while lower < scalarStart, bytes[lower] & 0xC0 == 0x80 { lower += 1 }
    }
    while upper < lineEnd,
          upper - lower < sourceBudget,
          bytes[upper] & 0xC0 != 0x80
    {
        let next = upper + 1
        var scalarBoundary = next
        while scalarBoundary < lineEnd, bytes[scalarBoundary] & 0xC0 == 0x80 {
            scalarBoundary += 1
        }
        guard scalarBoundary - lower <= sourceBudget else { break }
        upper = scalarBoundary
    }
    guard lower <= scalarStart,
          upper >= scalarEnd,
          let source = String(bytes: bytes[lower..<upper], encoding: .utf8)
    else { return nil }
    let prefix = lower > lineStart ? "…" : ""
    let suffix = upper < lineEnd ? "…" : ""
    let text = prefix + source + suffix
    guard text.utf8.count <= byteLimit else { return nil }
    return (
        ByteRange(lowerBound: UInt32(lower), upperBound: UInt32(upper)),
        text,
        UInt32(targetLine),
        lower > lineStart || upper < lineEnd
    )
}

package struct ReadingSetExcerpt: Sendable {
    package enum SourceKind: Sendable {
        case projectCommit
        case worktreeCaptured
        case dependencyCaptured
    }

    package struct FrozenInspectorDisplay: Sendable {
        // Leaves contain only frozen text; selecting a language retains both snapshots.
        package var localizedDisplays: [String: FrozenInspectorDisplay]? = nil

        package func display(language: String = modelDisplayLanguage) -> Self {
            guard let localizedDisplays,
                  var selected = localizedDisplays[language] ?? localizedDisplays["en"]
            else { return self }
            selected.localizedDisplays = localizedDisplays
            return selected
        }

        package enum Badge: String, Sendable {
            case verified = "VERIFIED"
            case inferred = "INFERRED"
            case unresolved = "UNRESOLVED"

            package var displayText: String {
                switch self {
                case .verified: localized("model.relation.verified")
                case .inferred: localized("model.relation.inferred")
                case .unresolved: localized("model.relation.unresolved")
                }
            }
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

package func readingSetDisplayText(_ stored: String) -> String {
    let keys = [
        "model.app.noEvidence", "model.app.noContentID", "model.app.languageUnsupported",
        "model.app.invalidPath", "model.app.revisionUnavailable", "model.app.worktreeUnavailable",
        "model.app.sourceUnreadable", "model.app.sourceChanged", "model.app.languageUnavailable",
        "model.app.excerptFailed", "model.app.nodeUnavailable", "model.app.trailTarget",
    ]
    if stored == "Name-only match" || stored == "name match only" { return localized("model.inspector.nameOnly") }
    for key in keys where stored == localized(key, language: "en") {
        return localized(key)
    }
    return stored
}

private func frozenReadinessReason(_ reason: String, language: String?) -> String {
    // Only application-owned fixed reasons are translated; tool diagnostics stay verbatim.
    let keys = [
        "model.exact.noProject", "model.exact.pyrightMissing", "model.exact.typescriptMissing",
        "model.exact.rustMissing", "model.exact.terminating", "model.exact.revoking",
        "model.exact.maintenance", "model.exact.sandboxMissing", "model.exact.closed",
        "model.exact.revoked", "model.exact.cacheCleared",
    ]
    for key in keys where ["en", "zh-Hans"].contains(where: {
        localized(key, language: $0) == reason
    }) {
        return localized(key, language: language)
    }
    for key in ["model.exact.safeDisabled", "model.exact.restartExhausted", "model.exact.restartFailed", "model.exact.unsupportedLanguage"] {
        for sourceLanguage in ["en", "zh-Hans"] {
            let parts = localized(key, language: sourceLanguage).components(separatedBy: "%@")
            guard parts.count == 2, reason.hasPrefix(parts[0]), reason.hasSuffix(parts[1]),
                  reason.count >= parts[0].count + parts[1].count else { continue }
            let detail = String(reason.dropFirst(parts[0].count).dropLast(parts[1].count))
            return localizedFormat(key, language: language, detail)
        }
    }
    return reason
}
