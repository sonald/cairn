import CodeInsightAppModel
import CodeInsightCore
import CodeInsightEngine
import CodeInsightExact
import CodeInsightGit
import CodeInsightReaderCore
import Darwin
import Foundation

/// The snapshot a conversation reads: the one showing when it started. Every
/// tool reads only files in its file list; there are no write, run or
/// network tools.
public struct AISnapshot: Sendable {
    public let root: URL
    /// nil for the working tree.
    public let revision: String?
    public let id: SnapshotID?
    let files: [String]
    private let fileSet: Set<String>
    private let source: DocumentLoader.ContentSource?
    private let sessions: [(EngineSession, QueryContext)]
    /// The window's exact analysis. It follows the reader, not the
    /// conversation, so every use checks what it covers now.
    let exact: ExactCoordinator?

    init(
        root: URL,
        revision: String?,
        id: SnapshotID?,
        files: [String],
        source: DocumentLoader.ContentSource?,
        sessions: [(EngineSession, QueryContext)],
        exact: ExactCoordinator? = nil
    ) {
        self.root = root.standardizedFileURL
        self.revision = revision
        self.id = id
        self.files = files.sorted()
        fileSet = Set(files)
        self.source = source
        self.sessions = sessions
        self.exact = exact
    }

    /// nil until a project's file tree is showing.
    @MainActor
    public init?(model: AppModel) {
        guard let tree = model.fileTree else { return nil }
        let root = tree.root.standardizedFileURL
        func flatten(_ nodes: [FileTreeNode]) -> [URL] {
            nodes.flatMap { $0.isDirectory ? flatten($0.children) : [$0.url] }
        }
        let prefix = root.pathComponents
        let files = flatten(tree.children).compactMap { url -> String? in
            let parts = url.standardizedFileURL.pathComponents
            guard parts.starts(with: prefix), parts.count > prefix.count else { return nil }
            return parts.dropFirst(prefix.count).joined(separator: "/")
        }
        self.init(
            root: root,
            revision: model.currentRevision,
            id: model.currentSnapshotID,
            files: files,
            source: model.documentSource,
            sessions: model.querySessions,
            exact: model.exactCoordinator
        )
    }

    public func url(of path: String) -> URL { root.appendingPathComponent(path) }

    func contains(_ path: String) -> Bool { fileSet.contains(path) }

    /// The snapshot file a citation names: the exact path, or the one file
    /// whose path ends with it (models often cite `File.swift:12`).
    public func resolve(cited: String) -> String? {
        let path = AITools.normalized(cited)
        if fileSet.contains(path) { return path }
        let suffix = "/" + path
        let matches = files.lazy.filter { $0.hasSuffix(suffix) }.prefix(2)
        return matches.count == 1 ? matches.first : nil
    }

    /// Where `line` (1-based) starts in the snapshot's copy of `path`.
    public func byteOffset(of path: String, line: Int) -> UInt32? {
        guard let bytes = try? bytes(of: path) else { return nil }
        let starts = LineTable(bytes: bytes).lineStarts
        return starts.isEmpty ? nil : starts[min(max(line, 1), starts.count) - 1]
    }

    /// The file's bytes as the snapshot has them: indexed source first, then
    /// the snapshot's own reader (a commit's blobs), then the working tree.
    func bytes(of path: String) throws -> [UInt8] {
        guard fileSet.contains(path) else { throw AIToolError("not a file in this snapshot: \(path)") }
        for (session, _) in sessions {
            // A source that cannot be read back is an error, not a reason
            // to fall back to other bytes.
            if let captured = try session.capturedSource(atManifestPath: path) { return captured.bytes }
        }
        let url = url(of: path)
        if let source { return try source(url) }
        // Working tree: the name is in the snapshot, but refuse a path that
        // now leads outside the project through a symlink.
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard resolved.starts(with: root.resolvingSymlinksInPath().standardizedFileURL.pathComponents) else {
            throw AIToolError("not a file in this snapshot: \(path)")
        }
        return Array(try Data(contentsOf: url))
    }

    var querySessions: [(EngineSession, QueryContext)] { sessions }

    var hasGit: Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) }

    /// The index of `path` and the session that holds it.
    func indexed(_ path: String) -> (session: EngineSession, context: QueryContext, pathID: PathID, index: ContentIndex)? {
        for (session, context) in sessions {
            // ponytail: linear in the unit's files per lookup; a path map if large repos make it show.
            guard let file = session.manifest.files.first(where: { session.paths.resolve($0.pathID) == path }),
                  let index = session.contentForCLI(at: file.pathID)
            else { continue }
            return (session, context, file.pathID, index)
        }
        return nil
    }

    /// What the model learns before its first tool call, so it does not
    /// spend rounds finding its way around.
    @MainActor
    func overview() -> String {
        let place = revision.map { "commit \($0.prefix(12))" } ?? "the working tree"
        var lines = ["Project \(root.lastPathComponent), \(place), \(files.count) files. Git history: \(hasGit ? "available (history tool)" : "none, not a Git repository")."]
        let units = sessions.map { session, _ in
            let profile = session.analysisProfile
            let dir = session.paths.resolve(profile.projectRoot)
            return "\(profile.language) unit \(profile.projectUnitName) at \(dir.isEmpty ? "/" : dir + "/") (\(session.manifest.files.count) files)"
        }
        lines.append(units.isEmpty ? "No analyzed languages: search and symbol are unavailable; use read." : "Analyzed: " + units.joined(separator: "; ") + ".")
        lines.append("Exact analysis (language server): " + AITools.exactSummary(exact, snapshot: self) + ".")
        var directories: [String: Int] = [:]
        var topFiles: [String] = []
        for file in files {
            if let slash = file.firstIndex(of: "/") { directories[String(file[..<slash]), default: 0] += 1 } else { topFiles.append(file) }
        }
        let shownDirectories = directories.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        var top = shownDirectories.prefix(20).map { "\($0.key)/ (\($0.value))" } + topFiles.prefix(12)
        if shownDirectories.count > 20 || topFiles.count > 12 { top.append("…") }
        lines.append("Top level: " + top.joined(separator: ", ") + ".")
        return lines.joined(separator: "\n")
    }
}

struct AIToolError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// A tool call the model asked for.
public struct AIToolCall: Sendable {
    public let callID: String
    public let name: String
    /// The arguments object, as JSON.
    public let arguments: Data

    public init(callID: String, name: String, arguments: Data) {
        self.callID = callID
        self.name = name
        self.arguments = arguments
    }
}

/// One step of the trace shown under a question.
public struct AIToolStep: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case list, read, search, callers, callees, references, implementations, history, unknown
    }
    public let kind: Kind
    /// The path, query or name the step was about.
    public let subject: String
    /// Lines read, or results found; nil when the step failed or is running.
    public let count: Int?
}

/// Code a step points at, opened when the step is clicked.
public struct AIEvidence: Sendable, Equatable, Identifiable {
    public let id: String
    public let path: String
    public let startLine: Int
    public let endLine: Int
    /// The start line's byte offset, for opening the reader there.
    public let byteOffset: UInt32
    public let excerpt: String
    /// The trace step that read it, 1-based.
    public let step: Int
}

/// The model's four tools, one per question it asks of the code: what is
/// here (`read`), where is this text (`search`), what is this symbol and who
/// uses it (`symbol`), and why is this code like this (`history`). Each call
/// answers its question in one go: totals first, results grouped, a stated
/// reason for anything empty, and a `help:` line naming the next call.
enum AITools {
    static let readWindow = 100
    static let maxReadLines = 200
    /// The most selected lines sent with a question.
    static let maxSelectionLines = 400
    static let maxLineLength = 300
    static let maxSearchHits = 50
    static let maxListed = 200
    static let maxRelations = 30
    static let maxCandidates = 10
    static let historyCommits = 8
    static let historyDiffs = 3
    static let maxDiffLines = 60
    static let maxMessageLines = 20
    static let exactTimeout: Double = 15
    static let historyTimeout: Double = 20
    static let excerptLines = 6

    static let parameters: [String: (all: [String], required: [String])] = [
        "read": (["path", "start_line", "end_line"], ["path"]),
        "search": (["query", "regex", "path"], ["query"]),
        "symbol": (["name", "path", "line", "relation"], ["name"]),
        "history": (["path", "start_line", "end_line"], ["path"]),
    ]
    static let relations = ["callers", "callees", "references", "implementations"]

    /// The tools as the helper sends them to the model.
    static var specs: [[String: Any]] {
        func object(_ properties: [String: Any], required: [String]) -> [String: Any] {
            ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
        }
        func described(_ type: String, _ text: String) -> [String: Any] { ["type": type, "description": text] }
        return [
            [
                "name": "read",
                "description": "Read a file of the snapshot as numbered lines, \(readWindow) from start_line by default (set end_line for up to \(maxReadLines)), headed by the total line count and the symbol the first line is in. Given a directory (\"\" for the project root), lists its subdirectories with file counts and its files with line counts.",
                "schema": object([
                    "path": described("string", "Project-relative file or directory."),
                    "start_line": described("integer", "First line, from 1."),
                    "end_line": described("integer", "Last line."),
                ], required: ["path"]),
            ],
            [
                "name": "search",
                "description": "Search the analyzed source files for text; case-insensitive unless the query has an uppercase letter. Up to \(maxSearchHits) matches come back grouped by file, each with its line and enclosing symbol; more come back as counts per file, to narrow. Markdown, JSON and other non-source files are not searched; read them.",
                "schema": object([
                    "query": described("string", "Text to find, or a regular expression with regex."),
                    "regex": described("boolean", "Treat query as a regular expression."),
                    "path": described("string", "Only files under this directory, or matching this glob (e.g. src/**/*.rs)."),
                ], required: ["query"]),
            ],
            [
                "name": "symbol",
                "description": "Look up a function, method, type or constant: its definition, signature and one relation, \(relations.joined(separator: ", ")) (default callers). With a name alone it finds the definitions by name; if several share it, call again with the path and line of the one you mean. path and line may also point at a use of the name, which finds what that use refers to. Answers come from the language server where it covers the file ([exact]), else from Cairn's index ([index]).",
                "schema": object([
                    "name": described("string", "The symbol's name."),
                    "path": described("string", "File of the definition or of a use."),
                    "line": described("integer", "Line of the name in that file."),
                    "relation": ["type": "string", "enum": relations],
                ], required: ["name"]),
            ],
            [
                "name": "history",
                "description": "Why lines are as they are: blames start_line–end_line of a file (the whole file by default) and groups the lines by the commit that last changed them, newest first, with each commit's date and full message, and for the newest \(historyDiffs) the change it made to those lines (against its first parent). Lines changed since the last commit are counted as uncommitted.",
                "schema": object([
                    "path": described("string", "Project-relative file."),
                    "start_line": described("integer", "First line, from 1."),
                    "end_line": described("integer", "Last line."),
                ], required: ["path"]),
            ],
        ]
    }

    // MARK: Calls

    struct Arguments {
        let values: [String: Any]

        func string(_ key: String) -> String? {
            switch values[key] {
            case let value as String: value
            case let value as NSNumber: value.stringValue
            default: nil
            }
        }

        func int(_ key: String) -> Int? {
            switch values[key] {
            case let value as NSNumber: value.intValue
            case let value as String: Int(value.trimmingCharacters(in: .whitespaces))
            default: nil
            }
        }

        func bool(_ key: String) -> Bool {
            switch values[key] {
            case let value as Bool: value
            case let value as NSNumber: value.boolValue
            case let value as String: value.lowercased() == "true"
            default: false
            }
        }
    }

    /// The arguments, or what is wrong with them: a misspelt parameter fails
    /// loudly instead of being ignored.
    static func arguments(of call: AIToolCall) -> Result<Arguments, AIToolError> {
        guard let shape = parameters[call.name] else {
            return .failure(AIToolError("unknown tool \(call.name); the tools are \(parameters.keys.sorted().joined(separator: ", "))"))
        }
        let parsed: Any? = call.arguments.isEmpty ? [String: Any]() : try? JSONSerialization.jsonObject(with: call.arguments)
        guard let values = parsed as? [String: Any] else {
            return .failure(AIToolError("the arguments are not a JSON object"))
        }
        let usage = shape.all.map { shape.required.contains($0) ? "\($0) (required)" : $0 }.joined(separator: ", ")
        if let unknown = values.keys.sorted().first(where: { !shape.all.contains($0) }) {
            return .failure(AIToolError("unknown parameter \"\(unknown)\"; \(call.name) takes \(usage)"))
        }
        if let missing = shape.required.first(where: { values[$0] == nil || values[$0] is NSNull }) {
            return .failure(AIToolError("\(call.name) needs \(missing); it takes \(usage)"))
        }
        return .success(Arguments(values: values))
    }

    /// The step a call is about to take, shown while it runs.
    static func step(for call: AIToolCall, in snapshot: AISnapshot) -> AIToolStep {
        let values = (try? arguments(of: call).get())?.values ?? [:]
        let arguments = Arguments(values: values)
        switch call.name {
        case "read":
            let path = normalized(arguments.string("path") ?? "")
            return AIToolStep(kind: snapshot.contains(path) ? .read : .list, subject: path, count: nil)
        case "search":
            return AIToolStep(kind: .search, subject: arguments.string("query") ?? "", count: nil)
        case "symbol":
            let kind = AIToolStep.Kind(rawValue: arguments.string("relation") ?? "callers") ?? .callers
            return AIToolStep(kind: kind, subject: arguments.string("name") ?? "", count: nil)
        case "history":
            let path = normalized(arguments.string("path") ?? "")
            let range = arguments.int("start_line").map { start in ":\(start)" + (arguments.int("end_line").map { "–\($0)" } ?? "") } ?? ""
            return AIToolStep(kind: .history, subject: path + range, count: nil)
        default:
            return AIToolStep(kind: .unknown, subject: call.name, count: nil)
        }
    }

    /// Runs one call; failures come back as text for the model, never thrown.
    static func run(
        _ call: AIToolCall, step: Int, in snapshot: AISnapshot
    ) async -> (output: String, step: AIToolStep, evidence: [AIEvidence]) {
        let planned = self.step(for: call, in: snapshot)
        func failed(_ error: Any) -> (String, AIToolStep, [AIEvidence]) {
            ("error: \(error)", AIToolStep(kind: planned.kind, subject: planned.subject, count: nil), [])
        }
        let arguments: Arguments
        switch self.arguments(of: call) {
        case .success(let parsed): arguments = parsed
        case .failure(let error): return failed(error)
        }
        do {
            let result: Outcome = switch call.name {
            case "read":
                try read(arguments.string("path") ?? "", from: arguments.int("start_line"),
                         to: arguments.int("end_line"), step: step, in: snapshot)
            case "search":
                try await search(arguments.string("query") ?? "", isRegex: arguments.bool("regex"),
                                 path: arguments.string("path"), in: snapshot)
            case "symbol":
                try await symbol(arguments.string("name") ?? "", path: arguments.string("path"),
                                 line: arguments.int("line"), relation: arguments.string("relation"),
                                 step: step, in: snapshot)
            default:
                try await history(arguments.string("path") ?? "", from: arguments.int("start_line"),
                                  to: arguments.int("end_line"), step: step, in: snapshot)
            }
            let kind = result.kind ?? planned.kind
            return (result.output, AIToolStep(kind: kind, subject: planned.subject, count: result.count), result.evidence)
        } catch {
            return failed(error)
        }
    }

    struct Outcome {
        var output: String
        var count: Int
        var evidence: [AIEvidence] = []
        var kind: AIToolStep.Kind?
    }

    /// Project-relative, without a leading `./` or `/` (models add both).
    static func normalized(_ path: String) -> String {
        var path = path.trimmingCharacters(in: .whitespaces)
        while path.hasPrefix("./") { path.removeFirst(2) }
        while path.hasPrefix("/") { path.removeFirst() }
        while path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// A snapshot file for `raw`, accepting a unique path suffix; otherwise
    /// an error naming files with the same base name.
    static func file(_ raw: String, in snapshot: AISnapshot) throws -> String {
        let path = normalized(raw)
        if snapshot.contains(path) { return path }
        if let resolved = snapshot.resolve(cited: path) { return resolved }
        let base = (path as NSString).lastPathComponent
        let similar = snapshot.files.filter { ($0 as NSString).lastPathComponent == base }.prefix(5)
        throw AIToolError("no file \(path) in this snapshot"
            + (similar.isEmpty ? "; read(\"\") lists the project" : "; files with that name: " + similar.joined(separator: ", ")))
    }

    // MARK: read

    static func read(_ raw: String, from start: Int?, to end: Int?, step: Int, in snapshot: AISnapshot) throws -> Outcome {
        let path = normalized(raw)
        if !snapshot.contains(path), path.isEmpty || snapshot.files.contains(where: { $0.hasPrefix(path + "/") }) {
            return list(path, in: snapshot)
        }
        let file = try file(path, in: snapshot)
        let bytes = try snapshot.bytes(of: file)
        if bytes.prefix(8_192).contains(0) { throw AIToolError("\(file) is a binary file") }
        let table = LineTable(bytes: bytes)
        let lineCount = lineCount(bytes, table)
        guard lineCount > 0 else { return Outcome(output: "\(file) is empty", count: 0, kind: .read) }
        let first = min(max(start ?? 1, 1), lineCount)
        let last = min(end.map { max($0, first) } ?? (first + readWindow - 1), first + maxReadLines - 1, lineCount)
        let lines = (first...last).map { text(ofLine: $0, bytes, table) }
        var header = "\(file) · lines \(first)–\(last) of \(lineCount)"
        if let within = enclosing(file, offset: table.lineStarts[first - 1], in: snapshot) { header += " · in \(within)" }
        var output = header + "\n" + lines.enumerated().map { "\(first + $0.offset)\t\($0.element)" }.joined(separator: "\n")
        if first > 1 || last < lineCount {
            output += "\n(\(first - 1) lines above, \(lineCount - last) below"
            output += last < lineCount ? "; read(\"\(file)\", start_line: \(last + 1)) continues)" : ")"
        }
        let evidence = AIEvidence(
            id: "\(step):\(file):\(first)", path: file, startLine: first, endLine: last,
            byteOffset: table.lineStarts[first - 1],
            excerpt: lines.prefix(excerptLines).joined(separator: "\n"), step: step)
        return Outcome(output: output, count: last - first + 1, evidence: [evidence], kind: .read)
    }

    static func list(_ directory: String, in snapshot: AISnapshot) -> Outcome {
        let prefix = directory.isEmpty ? "" : directory + "/"
        var directories: [String: Int] = [:]
        var files: [String] = []
        var total = 0
        for file in snapshot.files where file.hasPrefix(prefix) {
            total += 1
            let rest = file.dropFirst(prefix.count)
            if let slash = rest.firstIndex(of: "/") { directories[String(rest[..<slash]), default: 0] += 1 } else { files.append(file) }
        }
        let name = directory.isEmpty ? "the project root" : prefix
        var lines = ["\(name): \(directories.count) directories, \(files.count) files (\(total) files in all)"]
        for (child, count) in directories.sorted(by: { $0.key < $1.key }).prefix(maxListed) {
            lines.append("  \(child)/  \(count) files")
        }
        for file in files.prefix(max(0, maxListed - directories.count)) {
            let name = String(file.dropFirst(prefix.count))
            if let bytes = try? snapshot.bytes(of: file) {
                lines.append(bytes.prefix(8_192).contains(0) ? "  \(name)  binary" : "  \(name)  \(lineCount(bytes, LineTable(bytes: bytes))) lines")
            } else {
                lines.append("  \(name)")
            }
        }
        let shown = lines.count - 1
        if directories.count + files.count > shown { lines.append("… \(directories.count + files.count - shown) more entries") }
        return Outcome(output: lines.joined(separator: "\n"), count: total, kind: .list)
    }

    static func lineCount(_ bytes: [UInt8], _ table: LineTable) -> Int {
        var count = table.lineStarts.count
        if count > 1, table.lineStarts.last == UInt32(bytes.count) { count -= 1 }
        return bytes.isEmpty ? 0 : count
    }

    static func text(ofLine line: Int, _ bytes: [UInt8], _ table: LineTable) -> String {
        guard table.lineStarts.indices.contains(line - 1) else { return "" }
        let lower = Int(table.lineStarts[line - 1])
        let upper = line < table.lineStarts.count ? Int(table.lineStarts[line]) : bytes.count
        var text = String(decoding: bytes[lower..<upper], as: UTF8.self)
        while text.hasSuffix("\n") || text.hasSuffix("\r") { text.removeLast() }
        if text.count > maxLineLength { text = String(text.prefix(maxLineLength)) + "…" }
        return text
    }

    /// The innermost declaration around `offset`, with its parents, e.g.
    /// `impl Parser › fn parse (lines 110–260)`.
    static func enclosing(_ path: String, offset: UInt32, in snapshot: AISnapshot) -> String? {
        guard let (session, _, _, index) = snapshot.indexed(path) else { return nil }
        guard let innermost = index.symbols.indices.filter({
            index.symbols[$0].range.lowerBound <= offset && offset < index.symbols[$0].range.upperBound
        }).min(by: { index.symbols[$0].range.upperBound - index.symbols[$0].range.lowerBound
            < index.symbols[$1].range.upperBound - index.symbols[$1].range.lowerBound })
        else { return nil }
        return describe(Int(innermost), in: index, session: session, withLines: true)
    }

    static func describe(_ facetIndex: Int, in index: ContentIndex, session: EngineSession, withLines: Bool) -> String {
        var chain: [String] = []
        var current: Int? = facetIndex
        while let at = current, index.symbols.indices.contains(at), chain.count < 3 {
            let facet = index.symbols[at]
            chain.insert("\(kindName(facet.kind)) \(session.names.resolve(facet.nameID))", at: 0)
            current = facet.parentFacetIndex.map(Int.init)
        }
        let facet = index.symbols[facetIndex]
        guard withLines,
              let first = index.lineTable.lineColumn(at: facet.range.lowerBound)?.line,
              let last = index.lineTable.lineColumn(at: max(facet.range.upperBound, 1) - 1)?.line
        else { return chain.joined(separator: " › ") }
        return chain.joined(separator: " › ") + " (lines \(first)–\(last))"
    }

    /// `rustFn` → `fn`, `typescriptInterface` → `interface`.
    static func kindName(_ kind: DeclarationKind) -> String {
        var name = "\(kind)"
        for prefix in ["typescript", "python", "rust", "go"] where name.hasPrefix(prefix) {
            name.removeFirst(prefix.count)
            break
        }
        return name.prefix(1).lowercased() + name.dropFirst()
    }

    // MARK: search

    static func search(_ query: String, isRegex: Bool, path filter: String?, in snapshot: AISnapshot) async throws -> Outcome {
        guard !query.isEmpty else { throw AIToolError("empty query") }
        let sessions = snapshot.querySessions
        guard !sessions.isEmpty else {
            throw AIToolError("no source files are analyzed (yet), so there is nothing to search; use read")
        }
        let caseSensitive = query.contains { $0.isUppercase }
        let parsed = try ProjectSearchQuery.parse(isRegex ? query : ProjectSearchQuery.quoted(query), isRegex: isRegex)
        let filter = filter.map(normalized).flatMap { $0.isEmpty ? nil : $0 }
        var perFile: [String: Int] = [:]
        var hits: [(path: String, line: UInt32, symbol: String?, text: String)] = []
        var total = 0
        var truncated = false
        var searched = 0
        for (session, context) in sessions {
            searched += session.manifest.files.count
            for try await batch in try session.search(
                parsed, caseSensitive: caseSensitive, wholeWord: false, isRegex: isRegex, context: context
            ) {
                if batch.completeness == .truncated { truncated = true }
                for (pathID, matches) in batch.matchesByPath {
                    let path = session.paths.resolve(pathID)
                    guard filter.map({ pathMatches(path, $0) }) ?? true else { continue }
                    perFile[path, default: 0] += matches.count
                    total += matches.count
                    for match in matches where hits.count <= maxSearchHits {
                        hits.append((path, match.line, match.symbolName, match.lineText.trimmingCharacters(in: .whitespaces)))
                    }
                }
            }
        }
        let scope = filter.map { " under \($0)" } ?? ""
        let lowerBound = truncated ? " (the search stopped early; counts are lower bounds)" : ""
        guard total > 0 else {
            return Outcome(output: "no matches for \"\(query)\"\(scope) in the \(searched) analyzed source files"
                + "\(lowerBound). Non-source files (Markdown, JSON, config) are not searched; read them.", count: 0)
        }
        var lines = ["\(total) matches in \(perFile.count) files for \"\(query)\"\(scope)\(lowerBound)"]
        if total <= maxSearchHits {
            let grouped = Dictionary(grouping: hits, by: \.path)
            for path in grouped.keys.sorted() {
                lines.append("\(path) (\(perFile[path] ?? 0))")
                for hit in grouped[path]!.sorted(by: { $0.line < $1.line }) {
                    let text = hit.text.count > maxLineLength ? String(hit.text.prefix(maxLineLength)) + "…" : hit.text
                    lines.append("  \(hit.line)\t" + (hit.symbol.map { "[\($0)] " } ?? "") + text)
                }
            }
            lines.append("help: read(path, start_line) shows a match in context; symbol(name) gives a definition and its callers")
        } else {
            lines[0] += " — too many to list. Matches per file, most first:"
            for (path, count) in perFile.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }).prefix(maxRelations) {
                lines.append("  \(path)  \(count)")
            }
            if perFile.count > maxRelations { lines.append("  … \(perFile.count - maxRelations) more files") }
            lines.append("help: narrow it with a more specific query, regex: true, or path: \"some/dir\"")
        }
        return Outcome(output: lines.joined(separator: "\n"), count: total)
    }

    /// A directory prefix, or a glob when the filter has glob characters.
    static func pathMatches(_ path: String, _ filter: String) -> Bool {
        if filter.contains(where: { "*?[".contains($0) }) {
            // `**/` also matches no directory at all, as in .gitignore.
            let globs = [filter, filter.replacingOccurrences(of: "**/", with: "")]
            return globs.contains { fnmatch($0, path, 0) == 0 }
        }
        return path == filter || path.hasPrefix(filter + "/")
    }

    // MARK: Exact analysis

    /// Why exact analysis cannot answer for `path` in this conversation's
    /// snapshot, or what it covers when it can.
    enum ExactScope {
        case covered(ExactCoordinator, ExactCoordinator.Coverage)
        case unused(String)
    }

    @MainActor
    static func exactScope(for path: String?, in snapshot: AISnapshot) -> ExactScope {
        guard let exact = snapshot.exact else { return .unused("exact analysis is not available here") }
        switch exact.readiness {
        case .off(let reason), .unavailable(let reason):
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return .unused("exact analysis is unavailable: " + reason.replacingOccurrences(of: home, with: "~"))
        case .preparing where !exact.acceptsRequests: return .unused("exact analysis is still preparing")
        case .preparing, .ready: break
        }
        guard let coverage = exact.coverage else { return .unused("exact analysis is still preparing") }
        // Snapshot IDs are fresh per capture, so the reader's generation,
        // which every switch and refresh advances, says whether exact
        // analysis still serves this conversation's snapshot.
        guard snapshot.querySessions.contains(where: { $0.1.generation == coverage.generation }) else {
            return .unused("exact analysis has moved on to another snapshot the reader switched to")
        }
        if let path, !coverage.unitPrefix.isEmpty, !path.hasPrefix(coverage.unitPrefix + "/") {
            return .unused("exact analysis covers analysis unit \(coverage.unitName) (\(coverage.unitPrefix)/) only, which this file is outside")
        }
        return .covered(exact, coverage)
    }

    @MainActor
    static func exactSummary(_ exact: ExactCoordinator?, snapshot: AISnapshot) -> String {
        switch exactScope(for: nil, in: snapshot) {
        case .covered(_, let coverage):
            let unit = coverage.unitPrefix.isEmpty ? "the whole project" : "unit \(coverage.unitName) (\(coverage.unitPrefix)/)"
            return "ready with \(coverage.provider), covering \(unit); elsewhere symbol answers from the index"
        case .unused(let reason):
            return reason.replacingOccurrences(of: "exact analysis ", with: "") + "; symbol answers from the index"
        }
    }

    /// `work`, or nil after `seconds`. The work is not awaited past that:
    /// a language server or a blame cannot be interrupted midway.
    static func withTimeout<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async -> T?) async -> T?? {
        let stream = AsyncStream<T??> { continuation in
            let worker = Task {
                continuation.yield(.some(await work()))
                continuation.finish()
            }
            let timer = Task {
                try? await Task.sleep(for: .seconds(seconds))
                continuation.yield(.none)
                continuation.finish()
            }
            continuation.onTermination = { _ in
                worker.cancel()
                timer.cancel()
            }
        }
        for await value in stream { return value }
        return .none
    }

    /// An absolute location outside the project, without the user's home
    /// directory: from the package directory on where there is one.
    static func outsidePath(_ file: String) -> String {
        // Package roots: `…/node_modules/pkg/…`, `…/registry/src/<index>/crate-1.0/…`.
        for (marker, skip) in [("/node_modules/", 0), ("/site-packages/", 0), ("/pkg/mod/", 0),
                               ("/registry/src/", 1), ("/rustlib/src/rust/", 0)] {
            if let range = file.range(of: marker, options: .backwards) {
                let rest = file[range.upperBound...].split(separator: "/").dropFirst(skip)
                if !rest.isEmpty { return rest.joined(separator: "/") }
            }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return file.hasPrefix(home + "/") ? "~" + file.dropFirst(home.count) : (file as NSString).lastPathComponent
    }

    // MARK: symbol

    struct Definition {
        let session: EngineSession
        let context: QueryContext
        let path: String
        let pathID: PathID
        let facetIndex: Int
        let index: ContentIndex

        var facet: DeclarationFacet { index.symbols[facetIndex] }
        var line: Int { index.lineTable.lineColumn(at: facet.nameRange.lowerBound).map { Int($0.line) } ?? 1 }
        var occurrence: SymbolOccurrenceID {
            SymbolOccurrenceID(snapshotID: session.snapshotID, pathID: pathID, localKind: .declarationFacet,
                               localIndex: UInt32(facetIndex))
        }
    }

    static func symbol(
        _ rawName: String, path rawPath: String?, line: Int?, relation rawRelation: String?, step: Int, in snapshot: AISnapshot
    ) async throws -> Outcome {
        let name = bareName(rawName)
        guard !name.isEmpty else { throw AIToolError("empty name") }
        let relation = rawRelation ?? "callers"
        guard relations.contains(relation) else {
            throw AIToolError("unknown relation \"\(relation)\"; it is one of \(relations.joined(separator: ", "))")
        }
        let kind = AIToolStep.Kind(rawValue: relation)
        if line != nil, rawPath == nil { throw AIToolError("line needs path") }
        guard !snapshot.querySessions.isEmpty else {
            throw AIToolError("no source files are analyzed (yet); use search or read")
        }
        let path = try rawPath.map { try file($0, in: snapshot) }
        var notes: [String] = []
        // Where the language server is asked: the definition's name, or the
        // use the model pointed at.
        var query: (path: String, offset: UInt32)?
        var definition: Definition?
        var candidates: [Definition] = []

        if let path, let line {
            let bytes = try snapshot.bytes(of: path)
            let located = try locate(name, near: line, in: bytes)
            if located.line != line { notes.append("\"\(name)\" is on line \(located.line), not \(line)") }
            query = (path, located.offset)
            definition = definitionAt(path, offset: located.offset, name: name, in: snapshot)
        } else {
            candidates = definitions(named: name, in: snapshot).filter { path == nil || $0.path == path }
            if candidates.count == 1 { definition = candidates[0] }
            if let only = definition { query = (only.path, only.facet.nameRange.lowerBound) }
        }

        let scope = await exactScope(for: query?.path, in: snapshot)
        var external: String?
        if definition == nil, let query, case .covered(let exact, let coverage) = scope {
            // A use: ask the server what it refers to.
            let result = await withTimeout(exactTimeout) {
                await exact.definition(file: query.path, byteOffset: query.offset, generation: coverage.generation)
            }
            if case .some(.some(.completed(let entries))) = result, entries.isEmpty {
                notes.append("the language server found no definition for this use")
            }
            if case .some(.some(.completed(let entries))) = result, let target = entries.first?.location {
                if exactLocationIsInDependency(target.file) {
                    external = "\(outsidePath(target.file)):\(target.line) (outside the project, not readable)"
                } else if snapshot.contains(target.file) {
                    definition = definitionAt(target.file, offset: UInt32(target.byteOffset), name: nil, in: snapshot)
                    if definition == nil { external = "\(target.file):\(target.line)" }
                }
            }
        }
        if definition == nil, external == nil, let query, let indexed = snapshot.indexed(query.path) {
            // The index's own resolution of the use.
            let resolved = (try? indexed.session.resolve(file: indexed.pathID, offset: query.offset, context: indexed.context)) ?? []
            let found = resolved.compactMap { candidate -> (Definition, Certainty)? in
                let target = candidate.target
                guard target.localKind == .declarationFacet, let index = indexed.session.contentForCLI(at: target.pathID)
                else { return nil }
                return (Definition(session: indexed.session, context: indexed.context,
                                   path: indexed.session.paths.resolve(target.pathID), pathID: target.pathID,
                                   facetIndex: Int(target.localIndex), index: index), candidate.certainty)
            }
            if found.count > 1 {
                // A method matched by name only: the index cannot tell which, so neither do we.
                return ambiguous(name, candidates: found.map(\.0), relation: relation, kind: kind,
                                 heading: "\"\(name)\" at \(query.path):\(line ?? 0) could be any of \(found.count) definitions (the index matched it by name\(notes.isEmpty ? "" : "; " + notes.joined(separator: "; "))); call again with the path and line of the one you mean:")
            }
            if let (only, certainty) = found.first {
                definition = only
                if certainty != .exact { notes.append("the index matched it by name (\(certainty))") }
            }
        }

        // Nothing to look up: say why, and what to try.
        if definition == nil, external == nil {
            if candidates.count > 1 {
                return ambiguous(name, candidates: candidates, relation: relation, kind: kind)
            }
            if let query {
                return Outcome(output: "no definition found for \"\(name)\" at \(query.path):\(line ?? 0)"
                    + notesText(notes, scope) + "\nhelp: search(\"\(name)\") finds where it is written", count: 0, kind: kind)
            }
            let similar = fuzzy(name, in: snapshot)
            return Outcome(output: "no symbol named \"\(name)\"\(path.map { " in \($0)" } ?? "")"
                + (similar.isEmpty ? "" : ". Similar names:\n" + similar.joined(separator: "\n"))
                + "\nhelp: search(\"\(name)\") finds the text; symbol(name, path, line) at a use resolves it", count: 0, kind: kind)
        }

        let target = definition.map { ($0.path, $0.facet.nameRange.lowerBound) } ?? query!
        var lines: [String] = []
        var evidence: [AIEvidence] = []
        var signature: String?
        if case .covered(let exact, let coverage) = scope {
            let limits = (await exact.analysisEnvironment?.limitations ?? []).map(\.displayName).sorted()
            lines.append("[exact · \(coverage.provider)\(coverage.unitPrefix.isEmpty ? "" : " · unit \(coverage.unitName)")"
                + (limits.isEmpty ? "" : " · " + limits.joined(separator: ", ") + "; answers that go through dependencies may be missing") + "]")
            let batch = ExactRequestBatch()
            let hover = await withTimeout(exactTimeout) {
                await exact.hover(file: target.0, byteOffset: target.1, generation: coverage.generation, batch: batch)
            }
            if hover == nil { batch.cancel() }
            if case .some(.some(.completed(.some(let markdown), _))) = hover { signature = signatureText(markdown) }
        } else {
            lines.append("[index]" + notesText([], scope))
        }
        if signature == nil, let definition {
            signature = text(ofLine: definition.line, (try? snapshot.bytes(of: definition.path)) ?? [], definition.index.lineTable)
                .trimmingCharacters(in: .whitespaces)
        }
        if let signature { lines.append(signature) }
        if let definition {
            let place = "\(definition.path):\(definition.line)"
            lines.append("defined at \(place) · \(describe(definition.facetIndex, in: definition.index, session: definition.session, withLines: true))")
            if let offset = snapshot.byteOffset(of: definition.path, line: definition.line) {
                evidence.append(AIEvidence(id: "\(step):\(place)", path: definition.path, startLine: definition.line,
                                           endLine: definition.line, byteOffset: offset, excerpt: signature ?? place, step: step))
            }
        } else if let external {
            lines.append("defined at \(external)")
        }
        if !notes.isEmpty { lines.append("note: " + notes.joined(separator: "; ")) }

        var count = 0
        var related: [String]?
        if case .covered(let exact, let coverage) = scope {
            let direction: RelationTreeModel.Direction = switch relation {
            case "callees": .calls
            case "references": .references
            case "implementations": .implementations
            default: .callers
            }
            let batch = ExactRequestBatch()
            let result = await withTimeout(exactTimeout) {
                await exact.relations(file: target.0, byteOffset: target.1, item: nil, direction: direction,
                                      generation: coverage.generation, batch: batch)
            }
            switch result {
            case .some(.some(.relations(let found, _, _))):
                (related, count) = exactRelations(found, relation: relation, in: snapshot)
            case .some(.some(.notApplicable)):
                related = ["\(relation): not applicable to this symbol"]
            case .some(.some(.unsupported)):
                lines.append("note: \(coverage.provider) gave no usable answer for \(relation); from the index:")
            case .some(.none):
                lines.append("note: exact analysis did not answer; from the index:")
            case .none:
                batch.cancel()
                lines.append("note: exact analysis did not answer within \(Int(exactTimeout)) s; from the index:")
            }
        }
        if related == nil {
            (related, count) = indexRelations(name, definition: definition, relation: relation, in: snapshot)
        }
        lines += related ?? []
        if let definition {
            lines.append("help: read(\"\(definition.path)\", start_line: \(definition.line)) shows it; other relations: "
                + relations.filter { $0 != relation }.joined(separator: ", "))
        }
        return Outcome(output: lines.joined(separator: "\n"), count: count, evidence: evidence, kind: kind)
    }

    /// `Parser::parse`, `self.parse` and `parse()` all name `parse`.
    static func bareName(_ name: String) -> String {
        var name = name.trimmingCharacters(in: .whitespaces)
        if name.hasSuffix("()") { name.removeLast(2) }
        for separator in ["::", "->", "."] {
            if let range = name.range(of: separator, options: .backwards) { name = String(name[range.upperBound...]) }
        }
        return name
    }

    /// The name as a whole word on `line`, else on the nearest line within
    /// five; the model's line numbers are often a little off.
    static func locate(_ name: String, near line: Int, in bytes: [UInt8]) throws -> (line: Int, offset: UInt32) {
        let table = LineTable(bytes: bytes)
        let count = lineCount(bytes, table)
        guard count > 0 else { throw AIToolError("the file is empty") }
        let needle = Array(name.utf8)
        func isWord(_ byte: UInt8) -> Bool { byte == 0x5F || (byte >= 0x30 && byte <= 0x39) || (byte | 0x20 >= 0x61 && byte | 0x20 <= 0x7A) || byte >= 0x80 }
        func find(on line: Int) -> UInt32? {
            guard line >= 1, line <= count else { return nil }
            let lower = Int(table.lineStarts[line - 1])
            let upper = line < table.lineStarts.count ? Int(table.lineStarts[line]) : bytes.count
            var at = lower
            while at + needle.count <= upper {
                if bytes[at..<(at + needle.count)].elementsEqual(needle),
                   at == lower || !isWord(bytes[at - 1]),
                   at + needle.count == upper || !isWord(bytes[at + needle.count]) {
                    return UInt32(at)
                }
                at += 1
            }
            return nil
        }
        for distance in 0...5 {
            for candidate in distance == 0 ? [line] : [line - distance, line + distance] {
                if let offset = find(on: candidate) { return (candidate, offset) }
            }
        }
        throw AIToolError("no \"\(name)\" on or near line \(line) (the file has \(count) lines); read it to find the line")
    }

    static func definitionAt(_ path: String, offset: UInt32, name: String?, in snapshot: AISnapshot) -> Definition? {
        guard let (session, context, pathID, index) = snapshot.indexed(path),
              let at = index.symbols.firstIndex(where: {
                  $0.nameRange.lowerBound <= offset && offset <= $0.nameRange.upperBound
                      && (name == nil || session.names.resolve($0.nameID) == name)
              })
        else { return nil }
        return Definition(session: session, context: context, path: path, pathID: pathID, facetIndex: at, index: index)
    }

    static func definitions(named name: String, in snapshot: AISnapshot) -> [Definition] {
        snapshot.querySessions.flatMap { session, context in
            ((try? session.definitions(of: name, context: context)) ?? []).compactMap { occurrence, _, pathID in
                guard let index = session.contentForCLI(at: pathID) else { return nil }
                return Definition(session: session, context: context, path: session.paths.resolve(pathID),
                                  pathID: pathID, facetIndex: Int(occurrence.localIndex), index: index)
            }
        }.sorted { ($0.path, $0.line) < ($1.path, $1.line) }
    }

    static func fuzzy(_ name: String, in snapshot: AISnapshot) -> [String] {
        snapshot.querySessions.flatMap { session, context in
            ((try? session.searchSymbols(query: name, limit: maxCandidates, boost: SearchBoost(), context: context)) ?? []).map {
                "  \(session.names.resolve($0.nameID))  \(kindName($0.facet.kind))  \($0.path):\($0.line)"
            }
        }.prefix(maxCandidates).map { $0 }
    }

    static func ambiguous(
        _ name: String, candidates: [Definition], relation: String, kind: AIToolStep.Kind?, heading: String? = nil
    ) -> Outcome {
        var lines = [heading ?? "\(candidates.count) definitions are named \"\(name)\"; call again with the path and line of the one you mean:"]
        for candidate in candidates.prefix(maxCandidates) {
            lines.append("  \(candidate.path):\(candidate.line)  \(describe(candidate.facetIndex, in: candidate.index, session: candidate.session, withLines: false))")
        }
        if candidates.count > maxCandidates { lines.append("  … \(candidates.count - maxCandidates) more") }
        return Outcome(output: lines.joined(separator: "\n"), count: candidates.count, kind: kind)
    }

    /// The hover's code, without Markdown fences, at most eight lines.
    static func signatureText(_ markdown: String) -> String? {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("```") && $0 != "---" }
        guard !lines.isEmpty else { return nil }
        return lines.prefix(8).joined(separator: "\n") + (lines.count > 8 ? "\n…" : "")
    }

    static func notesText(_ notes: [String], _ scope: ExactScope) -> String {
        var all = notes
        if case .unused(let reason) = scope { all.append(reason) }
        return all.isEmpty ? "" : " (" + all.joined(separator: "; ") + ")"
    }

    /// One line per site, grouped by file: `  45  in main · let x = parse(…)`.
    static func grouped(_ sites: [(path: String, line: Int, label: String)], heading: String, in snapshot: AISnapshot) -> [String] {
        var lines = [heading]
        let files = Dictionary(grouping: sites, by: \.path)
        var shown = 0
        for path in files.keys.sorted() {
            guard shown < maxRelations else { break }
            lines.append(path)
            let bytes = snapshot.contains(path) ? (try? snapshot.bytes(of: path)) : nil
            let table = bytes.map { LineTable(bytes: $0) }
            for site in files[path]!.sorted(by: { $0.line < $1.line }) where shown < maxRelations {
                let code = bytes.map { text(ofLine: site.line, $0, table!).trimmingCharacters(in: .whitespaces) } ?? ""
                lines.append("  \(site.line)\t" + [site.label, code].filter { !$0.isEmpty }.joined(separator: " · "))
                shown += 1
            }
        }
        if sites.count > shown { lines.append("… \(sites.count - shown) more") }
        return lines
    }

    static func exactRelations(
        _ found: [ExactCoordinator.Relation], relation: String, in snapshot: AISnapshot
    ) -> ([String], Int) {
        func place(_ location: ExactLocation) -> String {
            exactLocationIsInDependency(location.file) ? outsidePath(location.file) : location.file
        }
        var sites: [(path: String, line: Int, label: String)] = []
        switch relation {
        case "callers":
            for caller in found {
                let label = caller.name.map { "in \($0)" } ?? ""
                for site in caller.callSites.isEmpty ? [caller.location] : caller.callSites {
                    sites.append((place(site), site.line, label))
                }
            }
            let functions = Set(found.map { "\($0.location.file):\($0.location.line)" }).count
            let files = Set(sites.map(\.path)).count
            guard !sites.isEmpty else { return (["callers: none found (by the language server)"], 0) }
            return (grouped(sites, heading: "callers: \(sites.count) call sites in \(functions) functions across \(files) files", in: snapshot), sites.count)
        case "callees":
            guard !found.isEmpty else { return (["callees: it calls nothing the language server resolves"], 0) }
            var lines = ["callees: \(found.count) functions"]
            for callee in found.prefix(maxRelations) {
                let first = callee.callSites.first.map { " · first called on line \($0.line)" } ?? ""
                lines.append("  \(callee.name ?? "?")  defined at \(place(callee.location)):\(callee.location.line)\(first)")
            }
            if found.count > maxRelations { lines.append("… \(found.count - maxRelations) more") }
            return (lines, found.count)
        default:
            for item in found {
                let location = item.location
                let label = snapshot.contains(location.file)
                    ? enclosing(location.file, offset: UInt32(location.byteOffset), in: snapshot).map { "in \($0)" } ?? ""
                    : "outside the project"
                sites.append((place(location), location.line, label))
            }
            guard !sites.isEmpty else { return (["\(relation): none found (by the language server)"], 0) }
            return (grouped(sites, heading: "\(relation): \(sites.count) in \(Set(sites.map(\.path)).count) files", in: snapshot), sites.count)
        }
    }

    static func indexRelations(
        _ name: String, definition: Definition?, relation: String, in snapshot: AISnapshot
    ) -> ([String], Int) {
        switch relation {
        case "callers":
            var sites: [(path: String, line: Int, label: String)] = []
            for (session, context) in snapshot.querySessions {
                let callers: [CallerResult]
                if let definition {
                    guard definition.session === session else { continue }
                    callers = (try? session.callers(of: definition.occurrence, context: context)) ?? []
                } else {
                    callers = (try? session.callers(of: name, context: context)) ?? []
                }
                for caller in callers {
                    let site = caller.callSite
                    guard let index = session.contentForCLI(at: site.pathID),
                          index.calls.indices.contains(Int(site.localIndex)),
                          let line = index.lineTable.lineColumn(at: index.calls[Int(site.localIndex)].range.lowerBound)?.line
                    else { continue }
                    let within = caller.associatedFacet.map { "in \(session.names.resolve($0.nameID))" }
                    let certainty = caller.certainty == .exact ? nil : "\(caller.certainty)"
                    sites.append((session.paths.resolve(site.pathID), Int(line),
                                  [within, certainty.map { "[\($0)]" }].compactMap { $0 }.joined(separator: " ")))
                }
            }
            guard !sites.isEmpty else { return (["callers: none found by name in the index"], 0) }
            let scope = definition == nil ? "all analysis units" : "the definition's analysis unit"
            let heading = "callers: \(sites.count) call sites across \(Set(sites.map(\.path)).count) files in \(scope) (index: matched by name and resolved where it can; [possible] and [probable] may be other symbols)"
            return (grouped(sites, heading: heading, in: snapshot), sites.count)
        case "callees":
            guard let definition,
                  let result = try? definition.session.outgoingCalls(from: definition.occurrence, context: definition.context)
            else { return (["callees: the index has no calls for this symbol"], 0) }
            guard !result.calls.isEmpty else { return (["callees: it calls nothing"], 0) }
            var lines = ["callees: \(result.calls.count) calls (index)"]
            for call in result.calls.prefix(maxRelations) {
                let line = definition.index.lineTable.lineColumn(at: call.call.nameRange.lowerBound)?.line ?? 0
                var target = "unresolved"
                if let candidate = call.candidates.first, candidate.target.localKind == .declarationFacet,
                   let index = definition.session.contentForCLI(at: candidate.target.pathID),
                   index.symbols.indices.contains(Int(candidate.target.localIndex)),
                   let at = index.lineTable.lineColumn(at: index.symbols[Int(candidate.target.localIndex)].nameRange.lowerBound)?.line {
                    target = "\(definition.session.paths.resolve(candidate.target.pathID)):\(at)"
                    if candidate.certainty != .exact { target += " [\(candidate.certainty)]" }
                }
                lines.append("  \(line)\t\(call.calleeName) → \(target)")
            }
            if result.calls.count > maxRelations { lines.append("… \(result.calls.count - maxRelations) more") }
            return (lines, result.calls.count)
        case "implementations":
            var sites: [(path: String, line: Int, label: String)] = []
            for (session, context) in snapshot.querySessions {
                for found in (try? session.implementations(ofTrait: name, context: context)) ?? [] {
                    let target = found.implementation
                    guard let index = session.contentForCLI(at: target.pathID),
                          index.symbols.indices.contains(Int(target.localIndex)),
                          let line = index.lineTable.lineColumn(at: index.symbols[Int(target.localIndex)].range.lowerBound)?.line
                    else { continue }
                    sites.append((session.paths.resolve(target.pathID), Int(line), "for \(found.typeName)"))
                }
            }
            guard !sites.isEmpty else {
                return (["implementations: none in the index (it knows only Rust trait impls; other languages need exact analysis)"], 0)
            }
            return (grouped(sites, heading: "implementations: \(sites.count) (index)", in: snapshot), sites.count)
        default:
            return (["references: only exact analysis finds references; search(\"\\\\b\(name)\\\\b\", regex: true) finds the text instead"], 0)
        }
    }

    // MARK: history

    static func history(_ raw: String, from start: Int?, to end: Int?, step: Int, in snapshot: AISnapshot) async throws -> Outcome {
        let path = try file(raw, in: snapshot)
        guard snapshot.hasGit else { throw AIToolError("this project is not a Git repository, so it has no history") }
        let bytes = try snapshot.bytes(of: path)
        let table = LineTable(bytes: bytes)
        let lineCount = lineCount(bytes, table)
        guard lineCount > 0 else { return Outcome(output: "\(path) is empty", count: 0) }
        let first = min(max(start ?? 1, 1), lineCount)
        let last = min(max(end ?? lineCount, first), lineCount)
        let root = snapshot.root
        let revision = snapshot.revision
        let blamed = await withTimeout(historyTimeout) { () -> Result<[BlameHunk], Error>? in
            await Task.detached(priority: .userInitiated) {
                Result { try GitBlame.blame(repositoryURL: root, path: path, revision: revision,
                                            workingTreeBytes: revision == nil ? bytes : nil) }
            }.value
        }
        let hunks: [BlameHunk]
        switch blamed {
        case .some(.some(.success(let found))): hunks = found
        case .some(.some(.failure(let error))): throw AIToolError("no history for \(path): \(error)")
        default: throw AIToolError("the blame of \(path) did not finish within \(Int(historyTimeout)) s; ask about fewer lines")
        }

        // Lines of the range by commit; nil is uncommitted.
        var owned: [String: (commit: CommitInfo, lines: [Int])] = [:]
        var uncommitted: [Int] = []
        for hunk in hunks {
            for line in hunk.lines where line >= first && line <= last {
                if let commit = hunk.commit {
                    owned[commit.fullSHA, default: (commit, [])].lines.append(line)
                } else {
                    uncommitted.append(line)
                }
            }
        }
        let commits = owned.values.sorted { $0.commit.date > $1.commit.date }
        let place = revision.map { "commit \($0.prefix(12))" } ?? "the working tree"
        var lines = ["[git · \(place)] \(path) lines \(first)–\(last): \(commits.count) commits"
            + (uncommitted.isEmpty ? "" : ", \(uncommitted.count) uncommitted lines (\(ranges(uncommitted)))")]
        let dates = DateFormatter()
        dates.dateFormat = "yyyy-MM-dd"
        dates.locale = Locale(identifier: "en_US_POSIX")
        for (offset, entry) in commits.prefix(historyCommits).enumerated() {
            let commit = entry.commit
            lines.append("")
            lines.append("\(commit.shortSHA) \(dates.string(from: commit.date)) · \(entry.lines.count) lines (\(ranges(entry.lines)))")
            lines += message(of: commit, root: root, path: path, withDiff: offset < historyDiffs,
                             current: Set(entry.lines.map { text(ofLine: $0, bytes, table).trimmingCharacters(in: .whitespaces) }
                                 .filter(identifiesHunk)))
        }
        if commits.count > historyCommits {
            let rest = commits.dropFirst(historyCommits)
            lines.append("")
            lines.append("… \(rest.count) older commits own \(rest.reduce(0) { $0 + $1.lines.count }) lines; ask about fewer lines to see them")
        }
        lines.append("help: symbol(name, path, line) explains what the code does now")
        var evidence: [AIEvidence] = []
        evidence.append(AIEvidence(
            id: "\(step):\(path):\(first):history", path: path, startLine: first, endLine: last,
            byteOffset: table.lineStarts[first - 1],
            excerpt: commits.first.map { "\($0.commit.shortSHA) \($0.commit.summary)" } ?? "uncommitted", step: step))
        return Outcome(output: lines.joined(separator: "\n"), count: commits.count, evidence: evidence)
    }

    /// A `}`, a blank line or a lone `1` is in most hunks; only a line with
    /// a word of its own says which hunk added it.
    static func identifiesHunk(_ line: String) -> Bool {
        line.count >= 4 && line.contains { $0.isLetter }
    }

    /// `3–7, 12`.
    static func ranges(_ lines: [Int]) -> String {
        var runs: [ClosedRange<Int>] = []
        for line in lines.sorted() {
            if let last = runs.last, line <= last.upperBound + 1 {
                runs[runs.count - 1] = last.lowerBound...max(line, last.upperBound)
            } else {
                runs.append(line...line)
            }
        }
        let parts = runs.map { $0.count == 1 ? "\($0.lowerBound)" : "\($0.lowerBound)–\($0.upperBound)" }
        return parts.prefix(6).joined(separator: ", ") + (parts.count > 6 ? ", …" : "")
    }

    /// The commit's full message, without trailers that name people
    /// (`Signed-off-by: Name <mail>`), then the change it made to the lines
    /// it still owns: the diff hunks that add one of `current`.
    static func message(of commit: CommitInfo, root: URL, path: String, withDiff: Bool, current: Set<String>) -> [String] {
        guard let change = try? GitBlame.change(repositoryURL: root, sha: commit.fullSHA, path: path) else {
            return ["  " + commit.summary]
        }
        let people = try? NSRegularExpression(pattern: #"^[A-Za-z-]+:\s.*<[^>]*@[^>]*>\s*$"#)
        var body = change.message.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { line in people.map { $0.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) == nil } ?? true }
        while body.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { body.removeLast() }
        var lines = body.prefix(maxMessageLines).map { "  " + $0 }
        if body.count > maxMessageLines { lines.append("  … (\(body.count - maxMessageLines) more message lines)") }
        guard withDiff else { return lines }
        guard let after = change.after else {
            lines.append("  (the file had another path in this commit; no diff)")
            return lines
        }
        guard let before = change.before else {
            lines.append("  (the file was added in this commit)")
            return lines
        }
        let diff = DiffCore().compare(left: before, right: after)
        func text(_ bytes: [UInt8], _ range: Range<Int>?) -> String {
            guard let range else { return "" }
            var text = String(decoding: bytes[range], as: UTF8.self)
            while text.hasSuffix("\n") || text.hasSuffix("\r") { text.removeLast() }
            return text.count > maxLineLength ? String(text.prefix(maxLineLength)) + "…" : text
        }
        let relevant = diff.hunks.filter { hunk in
            hunk.lines.contains { $0.kind == .added && current.contains(text(after, $0.rightByteRange).trimmingCharacters(in: .whitespaces)) }
        }
        guard !relevant.isEmpty else {
            lines.append("  (no hunk of this commit adds these lines as they read now; they moved or changed shape later)")
            return lines
        }
        lines.append("  change to \(path):")
        var shown = 0
        for hunk in relevant {
            guard shown < maxDiffLines else { break }
            if let line = hunk.lines.first(where: { $0.rightLine != nil })?.rightLine { lines.append("  @@ line \(line)") }
            for line in hunk.lines where shown < maxDiffLines {
                switch line.kind {
                case .added: lines.append("  +" + text(after, line.rightByteRange))
                case .removed: lines.append("  -" + text(before, line.leftByteRange))
                case .context: lines.append("   " + text(after, line.rightByteRange))
                }
                shown += 1
            }
        }
        let total = relevant.reduce(0) { $0 + $1.lines.count }
        if total > shown { lines.append("  … \(total - shown) more diff lines") }
        return lines
    }
}
