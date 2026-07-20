import CodeInsightCore
import CodeInsightEngine
import Foundation
import Testing

private let fixturesRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Fixtures", isDirectory: true)

private let fixtureDirectories: [URL] = (
    try? FileManager.default.contentsOfDirectory(
        at: fixturesRoot,
        includingPropertiesForKeys: [.isDirectoryKey]
    ).filter {
        try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
    }.sorted { $0.lastPathComponent < $1.lastPathComponent }
) ?? []

@Test(arguments: fixtureDirectories)
func semanticFixture(_ fixture: URL) throws {
    let session = try ProjectIndexer().index(root: fixture)
    let context = QueryContext(
        snapshotID: session.snapshotID,
        analysisProfileID: session.analysisProfile.id,
        generation: 1
    )
    let expectURL = fixture.appendingPathComponent("expect.txt")
    let lines = try String(contentsOf: expectURL, encoding: .utf8)
        .components(separatedBy: .newlines)

    for (offset, rawLine) in lines.enumerated() {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("#") else { continue }
        let label = "\(fixture.lastPathComponent):\(offset + 1)"
        try check(
            line,
            label: label,
            session: session,
            context: context
        )
    }

    let goldenURL = fixture.appendingPathComponent("dump.golden")
    if FileManager.default.fileExists(atPath: goldenURL.path) {
        let pathID = try requirePath("main.rs", session: session, label: fixture.lastPathComponent)
        let dump = CanonicalDump.render(
            try content(at: pathID, in: session),
            names: session.names,
            strings: session.strings
        )
        if ProcessInfo.processInfo.environment["RECORD"] == "1" {
            try dump.write(to: goldenURL, atomically: true, encoding: .utf8)
        } else {
            let expected = try String(contentsOf: goldenURL, encoding: .utf8)
            #expect(dump == expected, "\(fixture.lastPathComponent): dump.golden")
        }
    }
}

private func check(
    _ assertion: String,
    label: String,
    session: EngineSession,
    context: QueryContext
) throws {
    let parts = assertion.split(maxSplits: 1, whereSeparator: \Character.isWhitespace)
    guard parts.count == 2 else {
        Issue.record("\(label): invalid assertion: \(assertion)")
        return
    }
    let operation = String(parts[0])
    let body = String(parts[1]).trimmingCharacters(in: .whitespaces)

    switch operation {
    case "def", "def5", "bind":
        let pair = try split(body, separator: "->", label: label)
        let source = try parsePosition(pair.0, label: label)
        let expected = try parsePosition(pair.1, label: label)
        let candidates = try resolve(source, session: session, context: context, label: label)
        let limit = operation == "def5" ? 5 : 1
        let actual = try candidates.prefix(limit).map {
            try targetPosition(of: $0, session: session, label: label)
        }
        if operation == "bind" {
            #expect(actual.first == expected, "\(label): \(assertion), got \(actual)")
        } else {
            #expect(actual.contains(expected), "\(label): \(assertion), got \(actual)")
        }

    case "callers":
        let pair = try split(body, separator: "==", label: label)
        let definition = try parsePosition(pair.0, label: label)
        let expected = try pair.1.split(separator: ",").map {
            try parsePosition(String($0), label: label)
        }
        let name = try definitionName(at: definition, session: session, label: label)
        let callers = try session.callers(of: name, context: context)
        let actual = try callers.compactMap { caller -> FixturePosition? in
            let index = try content(at: caller.callSite.pathID, in: session)
            guard caller.callSite.localKind == .callSite,
                  index.calls.indices.contains(Int(caller.callSite.localIndex))
            else {
                throw FixtureError("\(label): call index is unavailable")
            }
            let call = index.calls[Int(caller.callSite.localIndex)]
            let source = try position(
                pathID: caller.callSite.pathID,
                offset: call.range.lowerBound,
                session: session,
                label: label
            )
            let targets = try resolve(
                source,
                session: session,
                context: context,
                label: label
            )
            guard try targets.contains(where: {
                try targetPosition(of: $0, session: session, label: label) == definition
            }) else { return nil }
            return source
        }.sorted()
        #expect(actual == expected.sorted(), "\(label): \(assertion), got \(actual)")

    case "candidates":
        let pair = try split(body, separator: ">=", label: label)
        let source = try parsePosition(pair.0, label: label)
        guard let minimum = Int(pair.1) else {
            throw FixtureError("\(label): invalid candidate count: \(pair.1)")
        }
        let candidates = try resolve(source, session: session, context: context, label: label)
        #expect(
            candidates.count >= minimum,
            "\(label): \(assertion), got \(candidates.count)"
        )

    case "strong":
        let source = try parsePosition(body, label: label)
        let candidates = try resolve(source, session: session, context: context, label: label)
        #expect(
            candidates.first?.certainty == .strong,
            "\(label): \(assertion), got \(candidates.map(\.certainty))"
        )

    case "unresolved":
        let source = try parsePosition(body, label: label)
        let candidates = try resolve(source, session: session, context: context, label: label)
        #expect(
            candidates.isEmpty || candidates.allSatisfy { $0.certainty == .unresolved },
            "\(label): \(assertion), got \(candidates.map(\.certainty))"
        )

    case "nostrong":
        let source = try parsePosition(body, label: label)
        let candidates = try resolve(source, session: session, context: context, label: label)
        #expect(
            candidates.allSatisfy { $0.certainty <= .possible },
            "\(label): \(assertion), got \(candidates.map(\.certainty))"
        )

    default:
        Issue.record("\(label): unknown assertion: \(operation)")
    }
}

private struct FixturePosition: Comparable, CustomStringConvertible {
    let file: String
    let line: UInt32
    let column: UInt32

    var description: String { "\(file):\(line):\(column)" }

    static func < (lhs: FixturePosition, rhs: FixturePosition) -> Bool {
        if lhs.file != rhs.file { return lhs.file < rhs.file }
        if lhs.line != rhs.line { return lhs.line < rhs.line }
        return lhs.column < rhs.column
    }
}

private struct FixtureError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func split(
    _ value: String,
    separator: String,
    label: String
) throws -> (String, String) {
    guard let range = value.range(of: separator) else {
        throw FixtureError("\(label): missing \(separator)")
    }
    return (
        String(value[..<range.lowerBound]).trimmingCharacters(in: .whitespaces),
        String(value[range.upperBound...]).trimmingCharacters(in: .whitespaces)
    )
}

private func parsePosition(_ value: String, label: String) throws -> FixturePosition {
    let parts = value.trimmingCharacters(in: .whitespaces)
        .split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count >= 3,
          let line = UInt32(parts[parts.count - 2]), line > 0,
          let column = UInt32(parts[parts.count - 1]), column > 0
    else {
        throw FixtureError("\(label): invalid position: \(value)")
    }
    return FixturePosition(
        file: parts.dropLast(2).joined(separator: ":"),
        line: line,
        column: column
    )
}

private func resolve(
    _ source: FixturePosition,
    session: EngineSession,
    context: QueryContext,
    label: String
) throws -> [ResolutionCandidate] {
    let pathID = try requirePath(source.file, session: session, label: label)
    let index = try content(at: pathID, in: session)
    guard let offset = index.lineTable.byteOffset(
        line: source.line,
        column: source.column
    ) else {
        throw FixtureError("\(label): source position is outside file: \(source)")
    }
    return try session.resolve(file: pathID, offset: offset, context: context)
}

private func targetPosition(
    of candidate: ResolutionCandidate,
    session: EngineSession,
    label: String
) throws -> FixturePosition {
    let index = try content(at: candidate.target.pathID, in: session)
    var range: ByteRange?
    for evidence in candidate.evidence {
        if case let .lexicalBinding(bindingIndex) = evidence,
           index.bindings.indices.contains(Int(bindingIndex))
        {
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
    guard let range else {
        throw FixtureError("\(label): target range is unavailable")
    }
    return try position(
        pathID: candidate.target.pathID,
        offset: range.lowerBound,
        session: session,
        label: label
    )
}

private func definitionName(
    at source: FixturePosition,
    session: EngineSession,
    label: String
) throws -> String {
    let pathID = try requirePath(source.file, session: session, label: label)
    let index = try content(at: pathID, in: session)
    guard let offset = index.lineTable.byteOffset(line: source.line, column: source.column),
          let facet = index.symbols.first(where: { $0.nameRange.contains(offset) })
    else {
        throw FixtureError("\(label): no definition at \(source)")
    }
    return session.names.resolve(facet.nameID)
}

private func position(
    pathID: PathID,
    offset: UInt32,
    session: EngineSession,
    label: String
) throws -> FixturePosition {
    let index = try content(at: pathID, in: session)
    guard let coordinate = index.lineTable.lineColumn(at: offset) else {
        throw FixtureError("\(label): byte offset is outside target")
    }
    return FixturePosition(
        file: session.paths.resolve(pathID),
        line: coordinate.line,
        column: coordinate.column
    )
}

private func requirePath(
    _ path: String,
    session: EngineSession,
    label: String
) throws -> PathID {
    guard let file = session.manifest.files.first(where: {
        session.paths.resolve($0.pathID) == path
    }) else {
        throw FixtureError("\(label): file is not indexed: \(path)")
    }
    return file.pathID
}

private func content(at pathID: PathID, in session: EngineSession) throws -> ContentIndex {
    guard let file = session.manifest.files.first(where: { $0.pathID == pathID }),
          let index = session.contentIndexes.first(where: {
              $0.key.contentID == file.contentID
          })?.value
    else {
        throw FixtureError("indexed content is unavailable")
    }
    return index
}
