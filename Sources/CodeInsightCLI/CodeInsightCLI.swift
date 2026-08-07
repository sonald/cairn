import ArgumentParser
import CodeInsightCore
import CodeInsightEngine
import CodeInsightExact
import CodeInsightGit
import CTreeSitterRust
import Foundation
import TreeSitterKit

@main
struct CodeInsight: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Inspect Rust source with CodeInsight.",
        subcommands: [
            Parse.self, Index.self, Dump.self, Defs.self, Callers.self,
            Calls.self, Impls.self, Overrides.self, Resolve.self,
            Search.self, Symsearch.self, SnapshotCommand.self, SwitchStats.self,
            Goldset.self, ExactDef.self,
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

    @Flag(name: .long, help: "Persist extracted content indexes.")
    var persist = false

    @OptionGroup var global: GlobalOptions
}

extension CodeInsight {
    struct ExactDef: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "exact-def",
            abstract: "Resolve a definition with rust-analyzer."
        )

        @Option(name: .long, help: "Git worktree root.")
        var project: String

        @Option(name: .long, help: "Project-relative Rust file.")
        var file: String

        @Option(name: .long, help: "One-based source line.")
        var line: Int

        @Option(name: .long, help: "One-based UTF-8 byte column.")
        var column: Int

        func validate() throws {
            guard line > 0, column > 0 else {
                throw ValidationError("--line and --column must be positive.")
            }
        }

        func run() throws {
            guard let executableURL = RustAnalyzerProvider.findExecutable()
            else { throw ValidationError("rust-analyzer not found") }

            let root = URL(fileURLWithPath: project, isDirectory: true)
                .standardizedFileURL
            let relative = file.hasPrefix("./")
                ? String(file.dropFirst(2)) : file
            guard !relative.hasPrefix("/") else {
                throw ValidationError("--file must be project-relative.")
            }
            let snapshot = try WorktreeSnapshot(repositoryURL: root)
            let bytes = try snapshot.readBytes(path: relative)
            guard let line = UInt32(exactly: line),
                  let column = UInt32(exactly: column),
                  let byteOffset = LineTable(bytes: bytes).byteOffset(
                    line: line,
                    column: column
                  )
            else {
                throw ValidationError("Position is outside \(relative).")
            }

            let provider = try RustAnalyzerProvider(
                projectURL: root,
                executableURL: executableURL
            )
            let session = try provider.prepare(
                snapshot: snapshot,
                profile: ExactProfileKey(projectURL: root),
                trustMode: .safe
            )
            defer { session.close() }
            let result = try session.definition(
                file: relative,
                byteOffset: Int(byteOffset)
            )
            let locations: [ExactTarget] = switch result {
            case .completed(let targets): targets
            case .cancelled: throw ValidationError("definition query cancelled")
            case .unavailable(let reason): throw ValidationError(reason)
            }
            guard !locations.isEmpty else {
                throw ValidationError("definition not found")
            }

            for target in locations {
                let location = target.location
                print("\(location.file):\(location.line):\(location.column)")
            }
            let attribution = session.attribution
            print(
                "attribution provider=\(attribution.provider) "
                    + "toolVersion=\(attribution.toolVersion) "
                    + "configFingerprint=\(attribution.configFingerprint) "
                    + "environmentFingerprint=\(attribution.environmentFingerprint) "
                    + "trustMode=safe "
                    + "generatedAt=\(ISO8601DateFormatter().string(from: attribution.generatedAt)) "
                    + "coverage=\(attribution.coverage.rawValue)"
            )
        }
    }

    struct SnapshotCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "snapshot",
            abstract: "List files in a worktree or commit snapshot."
        )

        @Option(name: .long, help: "Git repository root.")
        var project: String

        @Option(name: .long, help: "Commit revision; defaults to the worktree.")
        var commit: String?

        @OptionGroup var global: GlobalOptions

        func run() throws {
            let url = URL(fileURLWithPath: project, isDirectory: true)
            let snapshot: any CodeInsightGit.Snapshot = if let commit {
                try CommitSnapshot(repositoryURL: url, revision: commit)
            } else {
                try WorktreeSnapshot(repositoryURL: url)
            }
            let files = snapshot.listFiles().map(SnapshotFileJSON.init)
            if global.json {
                try printJSON(files)
            } else {
                for file in files {
                    print("\(file.path)\t\(file.contentID)\t\(file.fileMode)")
                }
            }
        }
    }

    struct SwitchStats: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "switch-stats",
            abstract: "Measure content reuse between two commits."
        )

        @Option(name: .long, help: "Git repository root.")
        var project: String

        @Option(name: .long, help: "Commit indexed first.")
        var from: String

        @Option(name: .long, help: "Commit switched to second.")
        var to: String

        func run() throws {
            let root = URL(fileURLWithPath: project, isDirectory: true)
            let indexer = ProjectIndexer()
            let store = ProjectIndexStore()
            let fromSnapshot = try CommitSnapshot(
                repositoryURL: root,
                revision: from
            )
            _ = try indexer.indexSnapshot(fromSnapshot, into: store)

            let startedAt = Date()
            let toSnapshot = try CommitSnapshot(repositoryURL: root, revision: to)
            let session = try indexer.indexSnapshot(toSnapshot, into: store)
            let elapsed = Date().timeIntervalSince(startedAt) * 1_000
            let total = session.stats.reusedCount + session.stats.extractedCount
            let hitRate = total == 0
                ? 0 : Double(session.stats.reusedCount) * 100 / Double(total)

            print("totalFiles: \(total)")
            print("reusedCount: \(session.stats.reusedCount)")
            print("extractedCount: \(session.stats.extractedCount)")
            print("hitRate: \(String(format: "%.1f%%", hitRate))")
            print("switchMilliseconds: \(String(format: "%.3f", elapsed))")
        }
    }

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

        @Flag(name: .long, help: "Persist extracted content indexes.")
        var persist = false

        @OptionGroup var global: GlobalOptions

        func run() throws {
            let session = try indexProject(path, persist: persist)
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
            let session = try indexProject(options.project, persist: options.persist)
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
            let session = try indexProject(options.project, persist: options.persist)
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
            let session = try indexProject(options.project, persist: options.persist)
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
                        offset: call.nameRange.lowerBound,
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
            let session = try indexProject(options.project, persist: options.persist)
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

    struct Impls: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List implementations of a Rust trait."
        )

        @Argument(help: "Trait name.")
        var traitName: String

        @OptionGroup var options: ProjectOptions

        func run() throws {
            let session = try indexProject(options.project, persist: options.persist)
            let implementations = try session.implementations(
                ofTrait: traitName,
                context: queryContext(for: session)
            )
            let output = try implementations.map { implementation in
                let index = try content(
                    at: implementation.implementation.pathID,
                    in: session
                )
                guard implementation.implementation.localKind == .declarationFacet,
                      index.symbols.indices.contains(
                        Int(implementation.implementation.localIndex)
                      )
                else {
                    throw ValidationError("Implementation location is unavailable.")
                }
                let facet = index.symbols[Int(implementation.implementation.localIndex)]
                let traitDefinitions = try implementation.traitDefinitions.map {
                    candidate -> LocationJSON in
                    let target = try target(of: candidate, in: session)
                    return location(
                        file: session.paths.resolve(candidate.target.pathID),
                        offset: target.range.lowerBound,
                        table: target.index.lineTable
                    )
                }
                return ImplementationJSON(
                    typeName: implementation.typeName,
                    certainty: String(describing: implementation.certainty),
                    location: location(
                        file: session.paths.resolve(
                            implementation.implementation.pathID
                        ),
                        offset: facet.nameRange.lowerBound,
                        table: index.lineTable
                    ),
                    traitDefinitions: traitDefinitions
                )
            }
            if options.global.json {
                try printJSON(output)
            } else {
                for implementation in output {
                    print("\(implementation.typeName) \(implementation.location.text) \(implementation.certainty)")
                }
            }
        }
    }

    struct Overrides: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List overrides of a Rust trait method."
        )

        @Argument(help: "Trait and method as Trait.method.")
        var traitMethod: String

        @OptionGroup var options: ProjectOptions

        func run() throws {
            guard let separator = traitMethod.lastIndex(of: "."),
                  separator != traitMethod.startIndex,
                  traitMethod.index(after: separator) != traitMethod.endIndex
            else {
                throw ValidationError("Expected Trait.method.")
            }
            let traitName = String(traitMethod[..<separator])
            let methodName = String(traitMethod[traitMethod.index(after: separator)...])
            let session = try indexProject(options.project, persist: options.persist)
            let context = queryContext(for: session)
            let traitDefinitions = try session.definitions(
                of: traitName,
                context: context
            ).filter { $0.1.kind == .rustTrait }
            let traitMethod = try traitDefinitions.lazy.compactMap {
                occurrence, _, pathID -> SymbolOccurrenceID? in
                let index = try content(at: pathID, in: session)
                guard let facetIndex = index.symbols.firstIndex(where: {
                    $0.kind == .rustMethod
                        && $0.parentFacetIndex == occurrence.localIndex
                        && session.names.resolve($0.nameID) == methodName
                }), let facetIndex = UInt32(exactly: facetIndex)
                else { return nil }
                return SymbolOccurrenceID(
                    snapshotID: session.snapshotID,
                    pathID: pathID,
                    localKind: .declarationFacet,
                    localIndex: facetIndex
                )
            }.first
            guard let traitMethod else {
                throw ValidationError(
                    "Trait method is not indexed: \(traitName).\(methodName)"
                )
            }

            let overrides = try session.overrides(
                ofTraitMethod: traitMethod,
                context: context
            )
            let output = try overrides.map { candidate in
                let index = try content(at: candidate.target.pathID, in: session)
                guard candidate.target.localKind == .declarationFacet,
                      index.symbols.indices.contains(Int(candidate.target.localIndex))
                else { throw ValidationError("Override location is unavailable.") }
                let method = index.symbols[Int(candidate.target.localIndex)]
                guard let parent = method.parentFacetIndex,
                      index.symbols.indices.contains(Int(parent))
                else { throw ValidationError("Override type is unavailable.") }
                return OverrideJSON(
                    typeName: session.names.resolve(index.symbols[Int(parent)].nameID),
                    methodName: session.names.resolve(method.nameID),
                    certainty: String(describing: candidate.certainty),
                    dispatch: String(describing: candidate.dispatch),
                    location: location(
                        file: session.paths.resolve(candidate.target.pathID),
                        offset: method.nameRange.lowerBound,
                        table: index.lineTable
                    )
                )
            }
            if options.global.json {
                try printJSON(output)
            } else {
                for override in output {
                    print("\(override.typeName)::\(override.methodName) \(override.location.text) \(override.certainty) \(override.dispatch)")
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
            let session = try indexProject(options.project, persist: options.persist)
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
            let session = try indexProject(options.project, persist: options.persist)
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

    struct Search: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Search project source contents."
        )

        @Argument(help: "Literal or regular expression to search for.")
        var pattern: String

        @OptionGroup var options: ProjectOptions

        @Flag(name: .long, help: "Interpret the pattern as a regular expression.")
        var regex = false

        @Flag(name: .long, help: "Match case sensitively.")
        var caseSensitive = false

        func run() async throws {
            let session = try indexProject(options.project, persist: options.persist)
            let stream = try session.search(
                ContentSearchQuery(
                    pattern: pattern,
                    isRegex: regex,
                    caseSensitive: caseSensitive
                ),
                context: queryContext(for: session)
            )
            var matchesByPath: [PathID: [SearchMatch]] = [:]
            var completeness = Completeness.complete
            var truncatedPathIDs: Set<PathID> = []
            for try await batch in stream {
                for (pathID, matches) in batch.matchesByPath {
                    matchesByPath[pathID, default: []].append(contentsOf: matches)
                }
                completeness = batch.completeness
                truncatedPathIDs.formUnion(batch.truncatedPathIDs)
            }

            let files = matchesByPath.map { pathID, matches in
                ContentSearchFileJSON(
                    file: session.paths.resolve(pathID),
                    matches: matches.sorted {
                        $0.byteRange.lowerBound < $1.byteRange.lowerBound
                    }.map(ContentSearchMatchJSON.init),
                    isTruncated: truncatedPathIDs.contains(pathID)
                )
            }.sorted { $0.file < $1.file }
            let totalMatches = files.reduce(0) { $0 + $1.matches.count }
            let truncatedFiles = truncatedPathIDs.map(session.paths.resolve).sorted()

            if options.global.json {
                try printJSON(ContentSearchJSON(
                    completeness: String(describing: completeness),
                    totalMatches: totalMatches,
                    fileCount: files.count,
                    files: files,
                    truncatedFiles: truncatedFiles
                ))
            } else {
                for file in files {
                    for match in file.matches {
                        print("\(file.file):\(match.line):\(match.column): \(match.lineText)")
                    }
                }
                print("\(totalMatches) matches in \(files.count) files")
                if completeness == .truncated {
                    print("Results truncated.")
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

        @Flag(name: .long, help: "Persist extracted content indexes.")
        var persist = false

        @OptionGroup var global: GlobalOptions

        func run() throws {
            let corpusURL = URL(fileURLWithPath: corpus, isDirectory: true)
            try Self.validateCorpus(corpusURL)
            let report = try evaluateGoldSet(
                at: URL(fileURLWithPath: goldFile),
                corpus: corpusURL,
                persist: persist
            )
            if global.json {
                try printJSON(report)
            } else {
                printGoldSet(report)
            }
            if report.unexpectedFailures > 0 { throw ExitCode.failure }
        }

        private static func validateCorpus(_ url: URL) throws {
            let fm = FileManager.default
            var isDir: ObjCBool = false

            guard fm.fileExists(atPath: url.path, isDirectory: &isDir),
                  isDir.boolValue
            else {
                throw ValidationError(
                    "corpus not found or not a directory: \(url.path)\n"
                        + "Run: bash scripts/provision-corpora.sh"
                )
            }

            let gitDir = url.appendingPathComponent(".git")
            guard fm.fileExists(atPath: gitDir.path) else {
                throw ValidationError(
                    "corpus has no .git directory: \(url.path)\n"
                        + "A git history is required for rust-analyzer readiness.\n"
                        + "The directory may have been destroyed by the macOS "
                        + "temp-file cleaner.\n"
                        + "Run: bash scripts/provision-corpora.sh"
                )
            }

            let headFile = gitDir.appendingPathComponent("HEAD")
            guard fm.fileExists(atPath: headFile.path) else {
                throw ValidationError(
                    "corpus .git is corrupted (no HEAD): \(url.path)\n"
                        + "Remove the directory and re-provision:\n"
                        + "  rm -rf '\(url.path)'\n"
                        + "  bash scripts/provision-corpora.sh"
                )
            }

            let cargoToml = url.appendingPathComponent("Cargo.toml")
            guard fm.fileExists(atPath: cargoToml.path) else {
                throw ValidationError(
                    "corpus has no Cargo.toml: \(url.path)\n"
                        + "Source files may have been destroyed.\n"
                        + "Remove the directory and re-provision:\n"
                        + "  rm -rf '\(url.path)'\n"
                        + "  bash scripts/provision-corpora.sh"
                )
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

private struct SnapshotFileJSON: Codable {
    let path: String
    let contentID: String
    let fileMode: String

    init(_ file: (path: String, contentID: ContentID, fileMode: FileMode)) {
        path = file.path
        contentID = file.contentID.bytes
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(12)
            .description
        fileMode = switch file.fileMode {
        case .regular: "regular"
        case .symlink: "symlink"
        case .gitlink: "gitlink"
        case .lfsPointer: "lfsPointer"
        }
    }
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

private struct ImplementationJSON: Codable {
    let typeName: String
    let certainty: String
    let location: LocationJSON
    let traitDefinitions: [LocationJSON]
}

private struct OverrideJSON: Codable {
    let typeName: String
    let methodName: String
    let certainty: String
    let dispatch: String
    let location: LocationJSON
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

private struct ContentSearchJSON: Codable {
    let completeness: String
    let totalMatches: Int
    let fileCount: Int
    let files: [ContentSearchFileJSON]
    let truncatedFiles: [String]
}

private struct ContentSearchFileJSON: Codable {
    let file: String
    let matches: [ContentSearchMatchJSON]
    let isTruncated: Bool
}

private struct ContentSearchMatchJSON: Codable {
    let line: UInt32
    let column: UInt32
    let byteRange: ByteRangeJSON
    let lineText: String

    init(_ match: SearchMatch) {
        line = match.line
        column = match.column
        byteRange = ByteRangeJSON(match.byteRange)
        lineText = match.lineText
    }
}

private func indexProject(_ path: String, persist: Bool = false) throws -> EngineSession {
    let root = URL(fileURLWithPath: path, isDirectory: true)
    let indexer = persist ? ProjectIndexer(persistingProjectAt: root) : ProjectIndexer()
    let session = try indexer.index(root: root)
    if persist { indexer.flushPersistentWrites() }
    return session
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
    case let .receiverType(nameID): "receiverType#\(nameID.rawValue)"
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
