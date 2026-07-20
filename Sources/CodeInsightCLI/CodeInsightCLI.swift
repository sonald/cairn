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
        subcommands: [Parse.self, Index.self, Dump.self, Defs.self, Callers.self, Resolve.self]
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
                let call = index.calls[Int(caller.callSite.localSymbolIndex)]
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

private struct ResolutionJSON: Codable {
    let certainty: String
    let dispatch: String
    let provenance: String
    let completeness: String
    let evidence: [String]
    let target: LocationJSON
    let byteRange: ByteRangeJSON
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
        if candidate.certainty == .unresolved,
           case let .uniqueImport(importBindingIndex) = evidence,
           index.imports.indices.contains(Int(importBindingIndex))
        {
            return (index, index.imports[Int(importBindingIndex)].range)
        }
    }
    guard index.symbols.indices.contains(Int(candidate.target.localSymbolIndex)) else {
        throw ValidationError("Resolution target is unavailable.")
    }
    return (index, index.symbols[Int(candidate.target.localSymbolIndex)].nameRange)
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

private func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}
