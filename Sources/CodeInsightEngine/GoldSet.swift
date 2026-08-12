import CodeInsightCore
import Foundation

public struct GoldSetReport: Codable, Sendable {
    public let total: Int
    public let defTop1Passed: Int
    public let defTop1Total: Int
    public let def5Top5Passed: Int
    public let def5Top5Total: Int
    public let noStrongViolations: Int
    public let unresolvedPassed: Int
    public let unresolvedTotal: Int
    public let noResults: Int
    public let knownFailures: Int
    public let failures: [String]

    public var unexpectedFailures: Int { failures.count }
}

public func evaluateGoldSet(
    at goldFile: URL,
    corpus: URL,
    persist: Bool = false,
    language: LanguageID = .rust
) throws -> GoldSetReport {
    let indexer = persist ? ProjectIndexer(persistingProjectAt: corpus) : ProjectIndexer()
    let session = try indexer.index(root: corpus, language: language)
    if persist { indexer.flushPersistentWrites() }
    let context = QueryContext(
        snapshotID: session.snapshotID,
        analysisProfileID: session.analysisProfile.id,
        generation: 1
    )
    let assertions = parseAssertions(
        try String(contentsOf: goldFile, encoding: .utf8)
    )
    var metrics = GoldSetMetrics()

    for assertion in assertions {
        metrics.total += 1
        if assertion.knownFailure { metrics.knownFailures += 1 }
        do {
            let result = try evaluate(assertion.text, session: session, context: context)
            metrics.record(result)
            if !result.passed && !assertion.knownFailure {
                metrics.failures.append("\(goldFile.lastPathComponent):\(assertion.line): \(result.message)")
            }
        } catch {
            if !assertion.knownFailure {
                metrics.failures.append("\(goldFile.lastPathComponent):\(assertion.line): \(error)")
            }
        }
    }

    return GoldSetReport(
        total: metrics.total,
        defTop1Passed: metrics.defTop1Passed,
        defTop1Total: metrics.defTop1Total,
        def5Top5Passed: metrics.def5Top5Passed,
        def5Top5Total: metrics.def5Top5Total,
        noStrongViolations: metrics.noStrongViolations,
        unresolvedPassed: metrics.unresolvedPassed,
        unresolvedTotal: metrics.unresolvedTotal,
        noResults: metrics.noResults,
        knownFailures: metrics.knownFailures,
        failures: metrics.failures
    )
}

private struct GoldAssertion {
    let line: Int
    let text: String
    let knownFailure: Bool
}

private struct GoldPosition: Hashable, Comparable, CustomStringConvertible {
    let file: String
    let line: UInt32
    let column: UInt32

    var description: String { "\(file):\(line):\(column)" }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.file != rhs.file { return lhs.file < rhs.file }
        if lhs.line != rhs.line { return lhs.line < rhs.line }
        return lhs.column < rhs.column
    }
}

private struct AssertionResult {
    let operation: String
    let passed: Bool
    let noResult: Bool
    let noStrongViolation: Bool
    let message: String
}

private struct GoldSetMetrics {
    var total = 0
    var defTop1Passed = 0
    var defTop1Total = 0
    var def5Top5Passed = 0
    var def5Top5Total = 0
    var noStrongViolations = 0
    var unresolvedPassed = 0
    var unresolvedTotal = 0
    var noResults = 0
    var knownFailures = 0
    var failures: [String] = []

    mutating func record(_ result: AssertionResult) {
        if result.noResult { noResults += 1 }
        if result.noStrongViolation { noStrongViolations += 1 }
        switch result.operation {
        case "def":
            defTop1Total += 1
            if result.passed { defTop1Passed += 1 }
        case "def5":
            def5Top5Total += 1
            if result.passed { def5Top5Passed += 1 }
        case "unresolved":
            unresolvedTotal += 1
            if result.passed { unresolvedPassed += 1 }
        default:
            break
        }
    }
}

private func parseAssertions(_ contents: String) -> [GoldAssertion] {
    var comments: [String] = []
    var result: [GoldAssertion] = []
    for (offset, rawLine) in contents.components(separatedBy: .newlines).enumerated() {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty {
            comments.removeAll()
        } else if line.hasPrefix("#") {
            comments.append(line)
        } else {
            let parts = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 { comments.append(String(parts[1])) }
            result.append(GoldAssertion(
                line: offset + 1,
                text: String(parts[0]).trimmingCharacters(in: .whitespaces),
                knownFailure: comments.contains { $0.contains("KNOWN-FAIL:") }
            ))
            comments.removeAll()
        }
    }
    return result
}

private func evaluate(
    _ assertion: String,
    session: EngineSession,
    context: QueryContext
) throws -> AssertionResult {
    let parts = assertion.split(maxSplits: 1, whereSeparator: \Character.isWhitespace)
    guard parts.count == 2 else { throw GoldSetError("invalid assertion: \(assertion)") }
    let operation = String(parts[0])
    let body = String(parts[1]).trimmingCharacters(in: .whitespaces)

    switch operation {
    case "def", "def5", "bind":
        let pair = try split(body, separator: "->")
        let source = try parsePosition(pair.0)
        let expected = try parsePosition(pair.1)
        let candidates = try resolve(source, session: session, context: context)
        let limit = operation == "def5" ? 5 : 1
        let actual = try candidates.prefix(limit).map { try targetPosition(of: $0, session: session) }
        let passed = actual.contains(expected)
        return AssertionResult(
            operation: operation,
            passed: passed,
            noResult: candidates.isEmpty,
            noStrongViolation: false,
            message: "\(assertion), got \(actual)"
        )

    case "callers":
        let pair = try split(body, separator: "==")
        let definition = try parsePosition(pair.0)
        let expected = try pair.1.split(separator: ",").map { try parsePosition(String($0)) }.sorted()
        let name = try definitionName(at: definition, session: session)
        let callers = try session.callers(of: name, context: context)
        let actual = try callers.compactMap { caller -> GoldPosition? in
            guard caller.callSite.localKind == .callSite,
                  let index = session.content(at: caller.callSite.pathID)?.1,
                  index.calls.indices.contains(Int(caller.callSite.localIndex))
            else { throw GoldSetError("caller location is unavailable") }
            let call = index.calls[Int(caller.callSite.localIndex)]
            let source = try position(
                pathID: caller.callSite.pathID,
                offset: call.range.lowerBound,
                session: session
            )
            let query = try position(
                pathID: caller.callSite.pathID,
                offset: call.nameRange.lowerBound,
                session: session
            )
            let targets = try resolve(query, session: session, context: context)
            return try targets.contains {
                try targetPosition(of: $0, session: session) == definition
            } ? source : nil
        }.sorted()
        return AssertionResult(
            operation: operation,
            passed: actual == expected,
            noResult: actual.isEmpty,
            noStrongViolation: false,
            message: "\(assertion), got \(actual)"
        )

    case "unresolved", "nostrong", "strong":
        let source = try parsePosition(body)
        let candidates = try resolve(source, session: session, context: context)
        let violation = operation == "nostrong" && candidates.contains { $0.certainty > .possible }
        let passed = switch operation {
        case "unresolved":
            candidates.isEmpty
                || candidates.allSatisfy { $0.certainty == .unresolved }
        case "strong":
            candidates.first?.certainty == .strong
        default:
            !violation
        }
        return AssertionResult(
            operation: operation,
            passed: passed,
            noResult: candidates.isEmpty,
            noStrongViolation: violation,
            message: "\(assertion), got \(candidates.map(\.certainty))"
        )

    default:
        throw GoldSetError("unknown assertion: \(operation)")
    }
}

private struct GoldSetError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func split(_ value: String, separator: String) throws -> (String, String) {
    guard let range = value.range(of: separator) else {
        throw GoldSetError("missing \(separator): \(value)")
    }
    return (
        String(value[..<range.lowerBound]).trimmingCharacters(in: .whitespaces),
        String(value[range.upperBound...]).trimmingCharacters(in: .whitespaces)
    )
}

private func parsePosition(_ value: String) throws -> GoldPosition {
    let parts = value.trimmingCharacters(in: .whitespaces)
        .split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count >= 3,
          let line = UInt32(parts[parts.count - 2]), line > 0,
          let column = UInt32(parts[parts.count - 1]), column > 0
    else { throw GoldSetError("invalid position: \(value)") }
    return GoldPosition(
        file: parts.dropLast(2).joined(separator: ":"),
        line: line,
        column: column
    )
}

private func resolve(
    _ source: GoldPosition,
    session: EngineSession,
    context: QueryContext
) throws -> [ResolutionCandidate] {
    let pathID = try requirePath(source.file, session: session)
    guard let index = session.content(at: pathID)?.1,
          let offset = index.lineTable.byteOffset(line: source.line, column: source.column)
    else { throw GoldSetError("source position is outside file: \(source)") }
    return try session.resolve(file: pathID, offset: offset, context: context)
}

private func targetPosition(
    of candidate: ResolutionCandidate,
    session: EngineSession
) throws -> GoldPosition {
    guard let index = session.content(at: candidate.target.pathID)?.1 else {
        throw GoldSetError("target content is unavailable")
    }
    var range: ByteRange?
    for evidence in candidate.evidence {
        if case let .lexicalBinding(bindingIndex) = evidence,
           index.bindings.indices.contains(Int(bindingIndex)) {
            range = index.bindings[Int(bindingIndex)].declarationRange
        }
    }
    if range == nil {
        let localIndex = Int(candidate.target.localIndex)
        switch candidate.target.localKind {
        case .declarationFacet where index.symbols.indices.contains(localIndex):
            range = index.symbols[localIndex].nameRange
        case .callSite where index.calls.indices.contains(localIndex):
            range = index.calls[localIndex].range
        case .importBinding where index.imports.indices.contains(localIndex):
            range = index.imports[localIndex].range
        default:
            break
        }
    }
    guard let range else { throw GoldSetError("target range is unavailable") }
    return try position(
        pathID: candidate.target.pathID,
        offset: range.lowerBound,
        session: session
    )
}

private func definitionName(
    at source: GoldPosition,
    session: EngineSession
) throws -> String {
    let pathID = try requirePath(source.file, session: session)
    guard let index = session.content(at: pathID)?.1,
          let offset = index.lineTable.byteOffset(line: source.line, column: source.column),
          let facet = index.symbols.first(where: { $0.nameRange.contains(offset) })
    else { throw GoldSetError("no definition at \(source)") }
    return session.names.resolve(facet.nameID)
}

private func position(
    pathID: PathID,
    offset: UInt32,
    session: EngineSession
) throws -> GoldPosition {
    guard let index = session.content(at: pathID)?.1,
          let coordinate = index.lineTable.lineColumn(at: offset)
    else { throw GoldSetError("byte offset is outside target") }
    return GoldPosition(
        file: session.paths.resolve(pathID),
        line: coordinate.line,
        column: coordinate.column
    )
}

private func requirePath(_ path: String, session: EngineSession) throws -> PathID {
    guard let file = session.manifest.files.first(where: {
        session.paths.resolve($0.pathID) == path
    }) else { throw GoldSetError("file is not indexed: \(path)") }
    return file.pathID
}
