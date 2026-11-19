import CodeInsightAppModel
import CodeInsightCore
import CodeInsightEngine
import CodeInsightReaderCore
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

    init(
        root: URL,
        revision: String?,
        id: SnapshotID?,
        files: [String],
        source: DocumentLoader.ContentSource?,
        sessions: [(EngineSession, QueryContext)]
    ) {
        self.root = root.standardizedFileURL
        self.revision = revision
        self.id = id
        self.files = files.sorted()
        fileSet = Set(files)
        self.source = source
        self.sessions = sessions
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
            sessions: model.querySessions
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
            if let captured = session.capturedSource(atManifestPath: path) { return captured.bytes }
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
    public enum Kind: String, Sendable { case listFiles, readFile, search, findSymbol, findCallers, unknown }
    public let kind: Kind
    /// The path, query or name the step was about.
    public let subject: String
    /// Lines read, or results found; nil when the step failed.
    public let count: Int?
}

/// Code the model actually read, shown as a card that opens it.
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

enum AITools {
    static let maxReadLines = 400
    static let maxLineLength = 400
    static let maxSearchHits = 100
    static let maxListedFiles = 500
    static let maxSymbols = 50
    static let maxCallers = 100
    static let excerptLines = 6

    /// The tools as the helper sends them to the model.
    static var specs: [[String: Any]] {
        func object(_ properties: [String: Any], required: [String]) -> [String: Any] {
            ["type": "object", "properties": properties, "required": required]
        }
        let string = ["type": "string"]
        let integer = ["type": "integer"]
        let boolean = ["type": "boolean"]
        return [
            [
                "name": "list_files",
                "description": "List the files of the code snapshot under a directory (project-relative; empty for the root), recursively, at most \(maxListedFiles).",
                "schema": object(["directory": string], required: []),
            ],
            [
                "name": "read_file",
                "description": "Read lines of a file in the snapshot, numbered from 1, at most \(maxReadLines) lines per call.",
                "schema": object(["path": string, "start_line": integer, "end_line": integer], required: ["path"]),
            ],
            [
                "name": "search",
                "description": "Search the snapshot's analyzed source files for text (or a regular expression). Returns path:line: text, at most \(maxSearchHits) hits. Non-source files such as Markdown or JSON are not searched; use read_file for them.",
                "schema": object([
                    "query": string, "is_regex": boolean, "case_sensitive": boolean, "whole_word": boolean,
                ], required: ["query"]),
            ],
            [
                "name": "find_symbol",
                "description": "Find where a symbol (function, type, method, constant…) is defined, by exact name, falling back to a fuzzy match.",
                "schema": object(["name": string], required: ["name"]),
            ],
            [
                "name": "find_callers",
                "description": "Find the call sites of a function or method by name, with the calling function and how certain each resolution is.",
                "schema": object(["name": string], required: ["name"]),
            ],
        ]
    }

    /// Runs one call; failures come back as text for the model, never thrown.
    static func run(
        _ call: AIToolCall, step: Int, in snapshot: AISnapshot
    ) async -> (output: String, step: AIToolStep, evidence: [AIEvidence]) {
        let arguments = (try? JSONSerialization.jsonObject(with: call.arguments)) as? [String: Any] ?? [:]
        func string(_ key: String) -> String { (arguments[key] as? String) ?? "" }
        func int(_ key: String) -> Int? { (arguments[key] as? NSNumber)?.intValue }
        func bool(_ key: String) -> Bool { (arguments[key] as? Bool) ?? false }
        let kind: AIToolStep.Kind
        let subject: String
        do {
            switch call.name {
            case "list_files":
                kind = .listFiles
                subject = normalized(string("directory"))
                let (output, count) = listFiles(under: subject, in: snapshot)
                return (output, AIToolStep(kind: kind, subject: subject, count: count), [])
            case "read_file":
                kind = .readFile
                subject = normalized(string("path"))
                let read = try readFile(subject, from: int("start_line"), to: int("end_line"), step: step, in: snapshot)
                return (read.output, AIToolStep(kind: kind, subject: subject, count: read.evidence.endLine - read.evidence.startLine + 1), [read.evidence])
            case "search":
                kind = .search
                subject = string("query")
                let (output, count) = try await search(
                    subject, isRegex: bool("is_regex"), caseSensitive: bool("case_sensitive"),
                    wholeWord: bool("whole_word"), in: snapshot)
                return (output, AIToolStep(kind: kind, subject: subject, count: count), [])
            case "find_symbol":
                kind = .findSymbol
                subject = string("name")
                let (output, count) = try findSymbol(subject, in: snapshot)
                return (output, AIToolStep(kind: kind, subject: subject, count: count), [])
            case "find_callers":
                kind = .findCallers
                subject = string("name")
                let (output, count) = try findCallers(subject, in: snapshot)
                return (output, AIToolStep(kind: kind, subject: subject, count: count), [])
            default:
                return ("error: unknown tool \(call.name)", AIToolStep(kind: .unknown, subject: call.name, count: nil), [])
            }
        } catch {
            let stepKind: AIToolStep.Kind = switch call.name {
            case "read_file": .readFile
            case "search": .search
            case "find_symbol": .findSymbol
            case "find_callers": .findCallers
            case "list_files": .listFiles
            default: .unknown
            }
            let subject = string("path").isEmpty ? (string("query").isEmpty ? string("name") : string("query")) : string("path")
            return ("error: \(error)", AIToolStep(kind: stepKind, subject: subject, count: nil), [])
        }
    }

    /// Project-relative, without a leading `./` or `/` (models add both).
    static func normalized(_ path: String) -> String {
        var path = path.trimmingCharacters(in: .whitespaces)
        while path.hasPrefix("./") { path.removeFirst(2) }
        while path.hasPrefix("/") { path.removeFirst() }
        while path.hasSuffix("/") { path.removeLast() }
        return path
    }

    static func listFiles(under directory: String, in snapshot: AISnapshot) -> (String, Int) {
        let prefix = directory.isEmpty ? "" : directory + "/"
        let matches = snapshot.files.filter { $0.hasPrefix(prefix) }
        guard !matches.isEmpty else { return ("no files under \(directory.isEmpty ? "the root" : directory)", 0) }
        var output = matches.prefix(maxListedFiles).joined(separator: "\n")
        if matches.count > maxListedFiles {
            output += "\n… \(matches.count - maxListedFiles) more; list a subdirectory"
        }
        return (output, matches.count)
    }

    static func readFile(
        _ path: String, from start: Int?, to end: Int?, step: Int, in snapshot: AISnapshot
    ) throws -> (output: String, evidence: AIEvidence) {
        let bytes = try snapshot.bytes(of: path)
        if bytes.prefix(8_192).contains(0) { throw AIToolError("binary file: \(path)") }
        let table = LineTable(bytes: bytes)
        var lineCount = table.lineStarts.count
        if lineCount > 1, table.lineStarts.last == UInt32(bytes.count) { lineCount -= 1 }
        let first = min(max(start ?? 1, 1), max(lineCount, 1))
        let last = min(max(end ?? (first + maxReadLines - 1), first), first + maxReadLines - 1, max(lineCount, 1))
        var lines: [String] = []
        for line in first...last {
            let lower = Int(table.lineStarts[line - 1])
            let upper = line < table.lineStarts.count ? Int(table.lineStarts[line]) : bytes.count
            var text = String(decoding: bytes[lower..<upper], as: UTF8.self)
            while text.hasSuffix("\n") || text.hasSuffix("\r") { text.removeLast() }
            if text.count > maxLineLength { text = String(text.prefix(maxLineLength)) + "…" }
            lines.append(text)
        }
        var output = "\(path) lines \(first)–\(last) of \(lineCount)\n"
        output += lines.enumerated().map { "\(first + $0.offset)\t\($0.element)" }.joined(separator: "\n")
        if last < lineCount, end == nil || end! > last { output += "\n… read on from line \(last + 1)" }
        let evidence = AIEvidence(
            id: "\(step):\(path):\(first)", path: path, startLine: first, endLine: last,
            byteOffset: table.lineStarts[first - 1],
            excerpt: lines.prefix(excerptLines).joined(separator: "\n"), step: step)
        return (output, evidence)
    }

    static func search(
        _ query: String, isRegex: Bool, caseSensitive: Bool, wholeWord: Bool, in snapshot: AISnapshot
    ) async throws -> (String, Int) {
        guard !query.isEmpty else { throw AIToolError("empty query") }
        let sessions = snapshot.querySessions
        guard !sessions.isEmpty else { throw AIToolError("the project is still being analyzed; use list_files and read_file") }
        let parsed = try ProjectSearchQuery.parse(
            isRegex ? query : ProjectSearchQuery.quoted(query), isRegex: isRegex)
        var hits: [String] = []
        var total = 0
        var truncated = false
        for (session, context) in sessions {
            for try await batch in try session.search(
                parsed, caseSensitive: caseSensitive, wholeWord: wholeWord, isRegex: isRegex, context: context
            ) {
                if batch.completeness == .truncated { truncated = true }
                for (path, matches) in batch.matchesByPath
                    .map({ (session.paths.resolve($0.key), $0.value) }).sorted(by: { $0.0 < $1.0 }) {
                    for match in matches {
                        total += 1
                        if hits.count < maxSearchHits {
                            hits.append("\(path):\(match.line): \(match.lineText.trimmingCharacters(in: .whitespaces))")
                        }
                    }
                }
            }
        }
        guard !hits.isEmpty else { return ("no matches", 0) }
        var output = hits.joined(separator: "\n")
        if total > hits.count || truncated {
            output += "\n… more matches exist; narrow the query"
        }
        return (output, total)
    }

    static func findSymbol(_ name: String, in snapshot: AISnapshot) throws -> (String, Int) {
        guard !name.isEmpty else { throw AIToolError("empty name") }
        let sessions = snapshot.querySessions
        guard !sessions.isEmpty else { throw AIToolError("the project is still being analyzed; use search later, or read_file") }
        var lines: [String] = []
        for (session, context) in sessions {
            for (_, facet, pathID) in try session.definitions(of: name, context: context) {
                let line = session.contentForCLI(at: pathID)?.lineTable.lineColumn(at: facet.nameRange.lowerBound)?.line
                lines.append("\(session.paths.resolve(pathID)):\(line.map(String.init) ?? "?") \(facet.kind) \(name)")
            }
        }
        if lines.isEmpty {
            for (session, context) in sessions {
                for hit in try session.searchSymbols(query: name, limit: maxSymbols, boost: SearchBoost(), context: context) {
                    lines.append("\(hit.path):\(hit.line) \(hit.facet.kind) \(session.names.resolve(hit.nameID)) (fuzzy)")
                }
            }
        }
        guard !lines.isEmpty else { return ("no symbol named \(name)", 0) }
        return (lines.prefix(maxSymbols).joined(separator: "\n"), lines.count)
    }

    static func findCallers(_ name: String, in snapshot: AISnapshot) throws -> (String, Int) {
        guard !name.isEmpty else { throw AIToolError("empty name") }
        let sessions = snapshot.querySessions
        guard !sessions.isEmpty else { throw AIToolError("the project is still being analyzed; use search instead") }
        var lines: [String] = []
        for (session, context) in sessions {
            for caller in try session.callers(of: name, context: context) {
                let site = caller.callSite
                guard let index = session.contentForCLI(at: site.pathID),
                      index.calls.indices.contains(Int(site.localIndex)),
                      let line = index.lineTable.lineColumn(at: index.calls[Int(site.localIndex)].range.lowerBound)?.line
                else { continue }
                let within = caller.associatedFacet.map { " in \(session.names.resolve($0.nameID))" } ?? ""
                lines.append("\(session.paths.resolve(site.pathID)):\(line)\(within) [\(caller.certainty)]")
            }
        }
        guard !lines.isEmpty else { return ("no call sites of \(name) found", 0) }
        var output = lines.prefix(maxCallers).joined(separator: "\n")
        if lines.count > maxCallers { output += "\n… \(lines.count - maxCallers) more" }
        return (output, lines.count)
    }
}
