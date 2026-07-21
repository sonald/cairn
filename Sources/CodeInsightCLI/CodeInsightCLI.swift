import ArgumentParser
import CodeInsightCore
import CodeInsightEngine
import CTreeSitterRust
import Foundation
import TreeSitterKit

@main
struct CodeInsight: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Inspect Rust source with CodeInsight.",
        subcommands: [
            Parse.self, Index.self, Dump.self, Defs.self, Callers.self,
            Calls.self, Resolve.self, Symsearch.self, Goldset.self,
        ]
    )
}

struct GlobalOptions: ParsableArguments {
    @Flag(name: .long, help: "Emit Codable JSON output.")
    var json = false
}

struct ProjectOptions: ParsableArguments {
    @Option(name: .long, help: "Project root to index.")
    var project: String

    @OptionGroup var global: GlobalOptions
}

extension CodeInsight {
    struct Parse: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Parse a Rust source file."
        )

        @Argument(help: "Path to a Rust source file.")
        var file: String

        @OptionGroup var global: GlobalOptions

        func run() throws {
            let data = try Data(contentsOf: URL(fileURLWithPath: file))
            guard
                let parser = Parser(language: RustLanguage.language),
                let tree = parser.parse(Array(data))
            else {
                throw ValidationError("Unable to initialize or run tree-sitter.")
            }
            if global.json {
                try printJSON(ParseJSON(
                    sExpression: tree.rootNode.sExpression,
                    hasError: tree.rootNode.hasError
                ))
            } else {
                print(tree.rootNode.sExpression)
                print("hasError: \(tree.rootNode.hasError)")
            }
        }
    }

    struct Index: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Index a Rust project in memory."
        )

        @Argument(help: "Project root to index.")
        var path: String

        @Flag(name: .long, help: "Print detailed index statistics.")
        var stats = false

        @OptionGroup var global: GlobalOptions

        func run() throws {
            let session = try indexProject(path)
            if global.json {
                try printJSON(IndexStatsJSON(session.stats))
            } else if stats {
                printStats(session.stats)
            } else {
                print("indexed \(session.stats.fileCount) Rust files (\(session.stats.uniqueContentCount) unique contents)")
            }
        }
    }

    struct Dump: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print a canonical ContentIndex dump."
        )

        @Argument(help: "Project-relative Rust file.")
        var file: String

        @OptionGroup var options: ProjectOptions

        func run() throws {
            let session = try indexProject(options.project)
            let pathID = try findPath(file, project: options.project, session: session)
            let index = try content(at: pathID, in: session)
            let dump = CanonicalDump.render(index, names: session.names, strings: session.strings)
            if options.global.json {
                try printJSON(DumpJSON(file: session.paths.resolve(pathID), dump: dump))
            } else {
                print(dump, terminator: "")
            }
        }
    }

    struct Defs: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List definition candidates by name."
        )

        @Argument(help: "Definition name.")
        var name: String

        @OptionGroup var options: ProjectOptions

        func run() throws {
            let session = try indexProject(options.project)
            let definitions = try session.definitions(
                of: name,
                context: queryContext(for: session)
            )
            let certainty: Certainty = definitions.count == 1 ? .probable : .possible
            let output = try definitions.map { occurrence, facet, pathID in
                let index = try content(at: pathID, in: session)
                return DefinitionJSON(
                    kind: String(describing: facet.kind),
                    name: session.names.resolve(facet.nameID),
                    certainty: String(describing: certainty),
                    location: location(
                        file: session.paths.resolve(pathID),
                        offset: facet.nameRange.lowerBound,
                        table: index.lineTable
                    ),
                    byteRange: ByteRangeJSON(facet.nameRange)
                )
            }
            if options.global.json {
                try printJSON(output)
            } else {
                for definition in output {
                    print("\(definition.kind) \(definition.name) \(definition.location.text) \(definition.certainty)")
                }
            }
        }
    }

    struct Callers: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List callers grouped by certainty."
        )

        @Argument(help: "Definition name.")
        var name: String

        @OptionGroup var options: ProjectOptions

        func run() throws {
            let session = try indexProject(options.project)
            let callers = try session.callers(
                of: name,
                context: queryContext(for: session)
            )
            let output = try callers.map { caller in
                let index = try content(at: caller.callSite.pathID, in: session)
                guard caller.callSite.localKind == .callSite,
                      index.calls.indices.contains(Int(caller.callSite.localIndex))
                else {
                    throw ValidationError("Caller location is unavailable.")
                }
                let call = index.calls[Int(caller.callSite.localIndex)]
                return CallerJSON(
                    certainty: String(describing: caller.certainty),
                    dispatch: String(describing: caller.dispatch),
                    location: location(
                        file: session.paths.resolve(caller.callSite.pathID),
                        offset: call.range.lowerBound,
                        table: index.lineTable
                    ),
                    byteRange: ByteRangeJSON(call.range),
                    regionKind: String(describing: caller.region.kind),
                    function: caller.associatedFacet.map {
                        session.names.resolve($0.nameID)
                    }
                )
            }
            if options.global.json {
                try printJSON(output)
            } else {
                for certainty in [Certainty.strong, .probable, .possible, .unresolved] {
                    let group = output.filter {
                        $0.certainty == String(describing: certainty)
                    }
                    guard !group.isEmpty else { continue }
                    print("\(certainty):")
                    for caller in group {
                        print("  \(caller.location.text) region=\(caller.regionKind) function=\(caller.function ?? "-")")
                    }
                }
            }
        }
    }

    struct Calls: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List calls made by the function at a source line."
        )

        @OptionGroup var options: ProjectOptions

        @Option(name: .long, help: "Project-relative Rust file.")
        var file: String

        @Option(name: .long, help: "One-based source line in the function.")
        var line: UInt32

        func validate() throws {
            guard line > 0 else {
                throw ValidationError("--line must be greater than zero.")
            }
        }

        func run() throws {
            let session = try indexProject(options.project)
            let pathID = try findPath(file, project: options.project, session: session)
            let index = try content(at: pathID, in: session)
            guard let lineStart = index.lineTable.byteOffset(line: line, column: 1)
            else {
                throw ValidationError("Line is outside \(file): \(line)")
            }
            let match = index.symbols.enumerated().filter { _, facet in
                guard facet.kind == .rustFn || facet.kind == .rustMethod else {
                    return false
                }
                return facet.range.contains(lineStart)
                    || index.lineTable.lineColumn(
                        at: facet.range.lowerBound
                    )?.line == line
            }.min {
                if $0.element.range.length != $1.element.range.length {
                    return $0.element.range.length < $1.element.range.length
                }
                return $0.element.range.lowerBound > $1.element.range.lowerBound
            }
            guard let match, let facetIndex = UInt32(exactly: match.offset) else {
                throw ValidationError(
                    "No function facet at or starting on \(file):\(line)."
                )
            }

            let result = try session.outgoingCalls(
                from: SymbolOccurrenceID(
                    snapshotID: session.snapshotID,
                    pathID: pathID,
                    localKind: .declarationFacet,
                    localIndex: facetIndex
                ),
                context: queryContext(for: session)
            )
            let output = try result.calls.map { outgoing in
                let topCandidate = try outgoing.candidates.first.map { candidate in
                    let target = try target(of: candidate, in: session)
                    return ResolutionJSON(
                        certainty: String(describing: candidate.certainty),
                        dispatch: String(describing: candidate.dispatch),
                        provenance: String(describing: candidate.provenance),
                        completeness: String(describing: candidate.completeness),
                        evidence: candidate.evidence.map(evidenceSummary),
                        target: location(
                            file: session.paths.resolve(candidate.target.pathID),
                            offset: target.range.lowerBound,
                            table: target.index.lineTable
                        ),
                        byteRange: ByteRangeJSON(target.range)
                    )
                }
                return OutgoingCallJSON(
                    calleeName: outgoing.calleeName,
                    kind: String(describing: outgoing.call.syntacticKind),
                    location: location(
                        file: session.paths.resolve(outgoing.callSite.pathID),
                        offset: outgoing.call.range.lowerBound,
                        table: index.lineTable
                    ),
                    byteRange: ByteRangeJSON(outgoing.call.range),
                    topCandidate: topCandidate
                )
            }
            if options.global.json {
                try printJSON(OutgoingCallsJSON(
                    completeness: String(describing: result.completeness),
                    calls: output
                ))
            } else if output.isEmpty {
                print("No outgoing calls (\(result.completeness)).")
            } else {
                for call in output {
                    let top = call.topCandidate.map {
                        "\($0.certainty)·\($0.dispatch) -> \($0.target.text)"
                    } ?? "unresolved·- -> -"
                    print("\(call.calleeName) \(call.kind) \(call.location.text) \(top)")
                }
                if result.completeness == .truncated {
                    print("truncated after \(output.count) calls")
                }
            }
        }
    }

    struct Resolve: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Resolve a project source position."
        )

        @Argument(help: "Position as file:line:column (UTF-8 byte column).")
        var position: String

        @OptionGroup var options: ProjectOptions

        func run() throws {
            let session = try indexProject(options.project)
            let parsed = try parsePosition(position)
            let pathID = try findPath(parsed.file, project: options.project, session: session)
            let sourceIndex = try content(at: pathID, in: session)
            guard let offset = sourceIndex.lineTable.byteOffset(
                line: parsed.line,
                column: parsed.column
            ) else {
                throw ValidationError("Position is outside \(parsed.file).")
            }
            let candidates = try session.resolve(
                file: pathID,
                offset: offset,
                context: queryContext(for: session)
            )
            let output = try candidates.map { candidate -> ResolutionJSON in
                let target = try target(of: candidate, in: session)
                return ResolutionJSON(
                    certainty: String(describing: candidate.certainty),
                    dispatch: String(describing: candidate.dispatch),
                    provenance: String(describing: candidate.provenance),
                    completeness: String(describing: candidate.completeness),
                    evidence: candidate.evidence.map(evidenceSummary),
                    target: location(
                        file: session.paths.resolve(candidate.target.pathID),
                        offset: target.range.lowerBound,
                        table: target.index.lineTable
                    ),
                    byteRange: ByteRangeJSON(target.range)
                )
            }
            if options.global.json {
                try printJSON(output)
            } else {
                for candidate in output {
                    print("\(candidate.certainty) \(candidate.dispatch) [\(candidate.evidence.joined(separator: ", "))] -> \(candidate.target.text)")
                }
            }
        }
    }

    struct Symsearch: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "symsearch",
            abstract: "Fuzzily search project symbols."
        )

        @Argument(help: "Symbol query.")
        var query: String

        @OptionGroup var options: ProjectOptions

        @Option(name: .long, help: "Maximum number of results.")
        var limit = 20

        func validate() throws {
            guard limit > 0 else {
                throw ValidationError("--limit must be greater than zero.")
            }
        }

        func run() throws {
            let session = try indexProject(options.project)
            let hits = try session.searchSymbols(
                query: query,
                limit: limit,
                boost: SearchBoost(),
                context: queryContext(for: session)
            )
            let output = hits.enumerated().map { offset, hit in
                SymbolSearchJSON(
                    rank: offset + 1,
                    score: hit.score,
                    kind: String(describing: hit.facet.kind),
                    name: session.names.resolve(hit.nameID),
                    file: hit.path,
                    line: hit.line,
                    column: hit.column,
                    byteRange: ByteRangeJSON(hit.facet.nameRange),
                    matchRanges: hit.matchRanges.map {
                        MatchRangeJSON(lowerBound: $0.lowerBound, upperBound: $0.upperBound)
                    }
                )
            }
            if options.global.json {
                try printJSON(output)
            } else if output.isEmpty {
                print("No symbols matched \"\(query)\".")
            } else {
                for hit in output {
                    print(String(
                        format: "%d  %.2f  %@  %@  %@:%u:%u",
                        hit.rank,
                        hit.score,
                        hit.kind,
                        hit.name,
                        hit.file,
                        hit.line,
                        hit.column
                    ))
                }
            }
        }
    }

    struct Goldset: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Evaluate resolution assertions against a corpus."
        )

        @Argument(help: "Gold-set assertion file.")
        var goldFile: String

        @Option(name: .long, help: "Corpus root to index.")
        var corpus: String

        @OptionGroup var global: GlobalOptions

        func run() throws {
            let report = try evaluateGoldSet(
                at: URL(fileURLWithPath: goldFile),
                corpus: URL(fileURLWithPath: corpus, isDirectory: true)
            )
            if global.json {
                try printJSON(report)
            } else {
                printGoldSet(report)
            }
            if report.unexpectedFailures > 0 { throw ExitCode.failure }
        }
    }
}

private enum RustLanguage {
    static var language: OpaquePointer { tree_sitter_rust()! }
}

private struct ParseJSON: Codable {
    let sExpression: String
    let hasError: Bool
}

private struct IndexStatsJSON: Codable {
    let files: Int
    let uniqueContents: Int
    let scopes: Int
    let bindings: Int
    let symbols: Int
    let calls: Int
    let imports: Int
    let elapsedMilliseconds: UInt64
    let filesWithErrorNodes: Int

    init(_ stats: IndexStats) {
        files = stats.fileCount
        uniqueContents = stats.uniqueContentCount
        scopes = stats.scopeCount
        bindings = stats.bindingCount
        symbols = stats.symbolCount
        calls = stats.callCount
        imports = stats.importCount
        elapsedMilliseconds = stats.elapsedMilliseconds
        filesWithErrorNodes = stats.filesWithErrorNodes
    }
}

private struct DumpJSON: Codable {
    let file: String
    let dump: String
}

private struct ByteRangeJSON: Codable {
    let lowerBound: UInt32
    let upperBound: UInt32

    init(_ range: CodeInsightCore.ByteRange) {
        lowerBound = range.lowerBound
        upperBound = range.upperBound
    }
}

private struct LocationJSON: Codable {
    let file: String
    let line: UInt32
    let column: UInt32
    let byteOffset: UInt32

    var text: String { "\(file):\(line):\(column)" }
}

private struct DefinitionJSON: Codable {
    let kind: String
    let name: String
    let certainty: String
    let location: LocationJSON
    let byteRange: ByteRangeJSON
}

private struct CallerJSON: Codable {
    let certainty: String
    let dispatch: String
    let location: LocationJSON
    let byteRange: ByteRangeJSON
    let regionKind: String
    let function: String?
}

private struct OutgoingCallJSON: Codable {
    let calleeName: String
    let kind: String
    let location: LocationJSON
    let byteRange: ByteRangeJSON
    let topCandidate: ResolutionJSON?
}

private struct OutgoingCallsJSON: Codable {
    let completeness: String
    let calls: [OutgoingCallJSON]
}

private struct ResolutionJSON: Codable {
    let certainty: String
    let dispatch: String
    let provenance: String
    let completeness: String
    let evidence: [String]
    let target: LocationJSON
    let byteRange: ByteRangeJSON
}

private struct MatchRangeJSON: Codable {
    let lowerBound: Int
    let upperBound: Int
}

private struct SymbolSearchJSON: Codable {
    let rank: Int
    let score: Double
    let kind: String
    let name: String
    let file: String
    let line: UInt32
    let column: UInt32
    let byteRange: ByteRangeJSON
    let matchRanges: [MatchRangeJSON]
}

private func indexProject(_ path: String) throws -> EngineSession {
    try ProjectIndexer().index(root: URL(fileURLWithPath: path, isDirectory: true))
}

private func queryContext(for session: EngineSession) -> QueryContext {
    QueryContext(
        snapshotID: session.snapshotID,
        analysisProfileID: session.analysisProfile.id,
        generation: 1
    )
}

private func findPath(
    _ input: String,
    project: String,
    session: EngineSession
) throws -> PathID {
    let projectURL = URL(fileURLWithPath: project, isDirectory: true).standardizedFileURL
    let direct = input.hasPrefix("./") ? String(input.dropFirst(2)) : input
    let absoluteURL = URL(fileURLWithPath: input).standardizedFileURL
    let relative = absoluteURL.pathComponents.starts(with: projectURL.pathComponents)
        ? absoluteURL.pathComponents.dropFirst(projectURL.pathComponents.count)
            .joined(separator: "/")
        : direct
    guard let file = session.manifest.files.first(where: { occurrence in
        let indexed = session.paths.resolve(occurrence.pathID)
        return indexed == direct || indexed == relative
    }) else {
        throw ValidationError("File is not indexed: \(input)")
    }
    return file.pathID
}

private func content(at pathID: PathID, in session: EngineSession) throws -> ContentIndex {
    guard let file = session.manifest.files.first(where: { $0.pathID == pathID }),
          let index = session.contentIndexes.first(where: {
              $0.key.contentID == file.contentID
          })?.value
    else {
        throw ValidationError("Indexed content is unavailable.")
    }
    return index
}

private func parsePosition(
    _ value: String
) throws -> (file: String, line: UInt32, column: UInt32) {
    let parts = value.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count >= 3,
          let line = UInt32(parts[parts.count - 2]), line > 0,
          let column = UInt32(parts[parts.count - 1]), column > 0
    else {
        throw ValidationError("Expected file:line:column.")
    }
    return (parts.dropLast(2).joined(separator: ":"), line, column)
}

private func location(
    file: String,
    offset: UInt32,
    table: LineTable
) -> LocationJSON {
    let coordinate = table.lineColumn(at: offset) ?? (0, 0)
    return LocationJSON(
        file: file,
        line: coordinate.line,
        column: coordinate.column,
        byteOffset: offset
    )
}

private func target(
    of candidate: ResolutionCandidate,
    in session: EngineSession
) throws -> (index: ContentIndex, range: CodeInsightCore.ByteRange) {
    let index = try content(at: candidate.target.pathID, in: session)
    for evidence in candidate.evidence {
        if case let .lexicalBinding(bindingIndex) = evidence,
           index.bindings.indices.contains(Int(bindingIndex))
        {
            return (index, index.bindings[Int(bindingIndex)].declarationRange)
        }
    }
    let localIndex = Int(candidate.target.localIndex)
    switch candidate.target.localKind {
    case .declarationFacet where index.symbols.indices.contains(localIndex):
        return (index, index.symbols[localIndex].nameRange)
    case .callSite where index.calls.indices.contains(localIndex):
        return (index, index.calls[localIndex].range)
    case .importBinding where index.imports.indices.contains(localIndex):
        return (index, index.imports[localIndex].range)
    default:
        throw ValidationError("Resolution target is unavailable.")
    }
}

private func evidenceSummary(_ evidence: ResolutionEvidence) -> String {
    switch evidence {
    case let .lexicalBinding(index): "lexicalBinding#\(index)"
    case let .uniqueImport(index): "uniqueImport#\(index)"
    case let .sameFile(pathID): "sameFile#\(pathID.rawValue)"
    case let .nameOnly(nameID): "nameOnly#\(nameID.rawValue)"
    case let .methodNameOnly(nameID): "methodNameOnly#\(nameID.rawValue)"
    }
}

private func printStats(_ stats: IndexStats) {
    print("files: \(stats.fileCount)")
    print("uniqueContents: \(stats.uniqueContentCount)")
    print("scopes: \(stats.scopeCount)")
    print("bindings: \(stats.bindingCount)")
    print("symbols: \(stats.symbolCount)")
    print("calls: \(stats.callCount)")
    print("imports: \(stats.importCount)")
    print("elapsedMilliseconds: \(stats.elapsedMilliseconds)")
    print("filesWithErrorNodes: \(stats.filesWithErrorNodes)")
}

private func printGoldSet(_ report: GoldSetReport) {
    func ratio(_ passed: Int, _ total: Int) -> String {
        let percent = total == 0 ? 0 : Double(passed) * 100 / Double(total)
        return "\(passed)/\(total) (\(String(format: "%.1f", percent))%)"
    }
    print("metric\tvalue")
    print("total\t\(report.total)")
    print("def Top-1\t\(ratio(report.defTop1Passed, report.defTop1Total))")
    print("def5 Top-5\t\(ratio(report.def5Top5Passed, report.def5Top5Total))")
    print("nostrong violations\t\(report.noStrongViolations)")
    print("unresolved\t\(ratio(report.unresolvedPassed, report.unresolvedTotal))")
    print("no results\t\(report.noResults)")
    print("KNOWN-FAIL\t\(report.knownFailures)")
    print("unexpected failures\t\(report.unexpectedFailures)")
    for failure in report.failures { print("FAIL\t\(failure)") }
}

private func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}
