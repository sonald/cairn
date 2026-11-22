import CTreeSitterPython
import CTreeSitterRust
import CodeInsightCore
import Foundation
import TreeSitterKit

/// One line of a file's distilled skeleton: simplified code taken from the
/// source by fixed rules, mapped back to the source lines it came from.
public struct SkeletonLine: Equatable, Sendable {
    public let text: String
    /// 1-based closed range of source lines; nil for a blank separator.
    public let sourceLines: ClosedRange<Int>?

    public init(text: String, sourceLines: ClosedRange<Int>?) {
        self.text = text
        self.sourceLines = sourceLines
    }
}

/// The distilled skeleton of one Rust or Python file, in source order:
/// each type as one row, each function on the main line with its key
/// statements, every other function as its signature. A block of several
/// rows stands apart by blank rows; the first source lines of the rows
/// strictly increase. Nil for other languages or when the source
/// cannot be parsed; empty when there is nothing to show. Callers treat
/// nil and empty alike: the file keeps its ordinary Overview.
///
/// `scores` are answers to the file's `SkeletonQuestions`, by question id:
/// a candidate function scored 0.5 or more is on the main line, one scored
/// less is a signature; a statement the rules drop is kept when scored 0.5
/// or more. Without a score the rules decide; entries are always on the
/// main line. No scores gives the rule-based skeleton.
public func distillSkeleton(
    bytes: [UInt8], language: LanguageID, scores: [String: Double] = [:]
) -> [SkeletonLine]? {
    withDistiller(bytes: bytes, language: language) { distiller, root in
        distiller.scores = scores
        return distiller.run(root: root)
    }
}

private func withDistiller<T>(
    bytes: [UInt8], language: LanguageID, _ body: (inout SkeletonDistiller, Node) -> T
) -> T? {
    let grammar: OpaquePointer?
    switch language {
    case .rust: grammar = tree_sitter_rust()
    case .python: grammar = tree_sitter_python()
    default: return nil
    }
    guard let grammar,
          let parser = Parser(language: grammar),
          let tree = parser.parse(bytes)
    else { return nil }
    var distiller = SkeletonDistiller(bytes: bytes, rust: language == .rust)
    return body(&distiller, tree.rootNode)
}

/// What a scoring service is asked about one file, in one request: the code
/// as `state`, and one yes/no question per choice the scores can change.
public struct SkeletonQuestions: Sendable {
    public struct Question: Equatable, Sendable {
        /// Stable for the same content: from the item's source position.
        public let id: String
        /// 1-based source lines the question is about.
        public let lines: ClosedRange<Int>
        public let instructions: String
    }

    /// Goes into every score cache key: a change to the questions or to how
    /// scores select makes earlier scores useless.
    public static let ruleVersion = 1
    public static let model = "jev-latest"
    /// A larger request is never sent; that file keeps the rule-based skeleton.
    public static let maxRequestBytes = 150_000

    /// The file without blank lines, comments and Python docstrings; each
    /// line is its source line number, a space, and the code.
    public let state: String
    public let questions: [Question]
    /// The request body as sent: model, state and every question.
    public let requestBody: Data

    /// Nil for other languages, unparsable source, nothing to ask, or a
    /// request over `maxRequestBytes`.
    public init?(bytes: [UInt8], language: LanguageID) {
        guard let (state, questions) = withDistiller(bytes: bytes, language: language, { distiller, root in
            distiller.questions(root: root)
        }), !questions.isEmpty else { return nil }
        struct Ask: Encodable { let type = "noul"; let instructions: String }
        struct Body: Encodable { let model: String; let state: String; let questions: [String: Ask] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let body = try? encoder.encode(Body(
            model: Self.model, state: state,
            questions: Dictionary(questions.map { ($0.id, Ask(instructions: $0.instructions)) }) { first, _ in first }
        )), body.count <= Self.maxRequestBytes else { return nil }
        self.state = state
        self.questions = questions
        requestBody = body
    }
}

/// How skeleton rows (0-based) stand for source lines (1-based). Rows are
/// in source order: their first lines strictly increase.
public struct SkeletonLineMap: Equatable, Sendable {
    public let ranges: [ClosedRange<Int>?]

    public init(_ lines: [SkeletonLine]) {
        ranges = lines.map(\.sourceLines)
    }

    /// The gutter number: the row's first source line; none for a blank row.
    public func label(ofRow row: Int) -> Int? {
        ranges.indices.contains(row) ? ranges[row]?.lowerBound : nil
    }

    /// The source line to land on when leaving from a row: its own first
    /// line; a blank row takes the next row's, the last one the previous row's.
    public func sourceLine(ofRow row: Int) -> Int? {
        guard !ranges.isEmpty else { return nil }
        let row = min(max(row, 0), ranges.count - 1)
        return ranges[row...].lazy.compactMap { $0?.lowerBound }.first
            ?? ranges[..<row].reversed().lazy.compactMap { $0?.lowerBound }.first
    }

    /// The row to land on for a source line: the last row whose range
    /// contains it; else the first row after it; else the last row. The last
    /// containing row is the one starting latest, so a row's own first line
    /// lands back on that row: leaving and re-entering never drifts.
    public func row(forSourceLine line: Int) -> Int? {
        let mapped = ranges.indices.filter { ranges[$0] != nil }
        return mapped.last { ranges[$0]!.contains(line) }
            ?? mapped.first { ranges[$0]!.lowerBound > line }
            ?? mapped.last
    }
}

/// A Rust or Python file's Overview as a document of its own: the skeleton
/// text, highlighted, with no folds, and the map back to the source.
package struct SkeletonOverview: Sendable {
    package let document: ReaderDocument
    package let map: SkeletonLineMap

    /// Nil when the file has no skeleton; it keeps its ordinary Overview.
    package init?(source: ReaderDocument, scores: [String: Double] = [:]) {
        guard let lines = distillSkeleton(bytes: source.bytes, language: source.languageMode.language, scores: scores),
              !lines.isEmpty
        else { return nil }
        let bytes = Array(lines.map(\.text).joined(separator: "\n").utf8)
        let highlighted = try? DocumentLoader.highlightWithFolds(
            bytes: bytes, languageMode: source.languageMode, resolutionObserver: nil
        )
        document = ReaderDocument(
            bytes: bytes, languageMode: source.languageMode,
            lineTable: LineTable(bytes: bytes), byteUTF16Map: ByteUTF16Map(validUTF8: bytes),
            highlightSpans: highlighted?.spans ?? [], outlineFacets: [], foldRegions: []
        )
        map = SkeletonLineMap(lines)
    }
}

// MARK: - Model

private struct SkeletonFunction {
    let node: Node
    let body: Node
    let name: String
    /// The impl type, trait or class the function belongs to.
    let owner: String?
    let lines: ClosedRange<Int>
    let headerEndLine: Int
    /// Lines after the header that hold code: not blank, comment or docstring.
    let bodyLineCount: Int
    var callees: [Int] = []
}

/// One statement of a body; a match arm counts as a statement of its match.
private struct SkeletonStatement {
    let node: Node
    let range: Range<Int>
    /// The last expression of a Rust block, kept as the block's value.
    let isValue: Bool
}

/// Every choice a walk left to a score, in walk order.
private final class QuestionLog {
    var functions: [SkeletonFunction] = []
    var statements: [(SkeletonFunction, SkeletonStatement)] = []
}

private struct Row {
    var text: String
    var depth: Int
    var lines: ClosedRange<Int>
}

/// A deletion of source bytes, optionally replaced by fixed punctuation.
private struct Edit {
    let range: Range<Int>
    var insert = ""
}

private struct RenderedBody {
    var rows: [Row] = []
    /// Kept statements that each became exactly one non-compound row.
    var simpleStatements = 0
    var keptStatements = 0
    /// The block holds nothing but its value (`|| { V }`).
    var holdsOnlyValue = false
}

// MARK: - Distiller

private struct SkeletonDistiller {
    let bytes: [UInt8]
    let rust: Bool
    let lineTable: LineTable

    var functions: [SkeletonFunction] = []
    var typeNodes: [Node] = []
    var enumNames: Set<String> = []
    var typeNames: Set<String> = []
    var moduleNames: Set<String> = []
    var freeFunctions: [String: Int] = [:]
    var methods: [String: [String: Int]] = [:]
    var methodsByName: [String: Int] = [:]
    /// The function whose statements are being walked.
    var current: SkeletonFunction?
    /// Answers by question id; see `distillSkeleton(bytes:language:scores:)`.
    var scores: [String: Double] = [:]
    /// Set while building questions: every choice left to a score is taken
    /// as kept and recorded, so the questions are exactly the choices the
    /// walk makes.
    var asked: QuestionLog?
    /// Python docstrings (module, class and function), by byte range.
    var docstrings: Set<Range<Int>> = []

    static let maxLine = 120
    static let maxDepth = 48
    static let noiseMethods: Set<String> = ["clone", "to_string", "to_owned", "into", "as_str", "as_ref"]
    static let effectNames: Set<String> = ["send", "spawn", "append", "insert", "push"]

    init(bytes: [UInt8], rust: Bool) {
        self.bytes = bytes
        self.rust = rust
        self.lineTable = LineTable(bytes: bytes)
    }

    mutating func run(root: Node) -> [SkeletonLine] {
        if !rust {
            forEachNode(in: root) { node in
                let body = node.kind == "module" ? node
                    : ["function_definition", "class_definition"].contains(node.kind) ? node.field("body") : nil
                if let body, let docstring = docstring(of: body) { docstrings.insert(docstring.start..<docstring.end) }
                return true
            }
        }
        if rust { collectRust(root, owner: nil) } else { collectPython(root, owner: nil) }
        for index in functions.indices {
            functions[index].callees = callees(of: functions[index])
        }
        let (entries, order) = mainLineOrder()

        var distilled: [Int: [Row]] = [:]
        for index in order {
            guard entries.contains(index) || takesMainLine(functions[index]) else { continue }
            if let rows = distill(functions[index]) {
                // A function with nothing to distil is a signature whatever its score.
                if !entries.contains(index) { asked?.functions.append(functions[index]) }
                distilled[index] = rows
            }
        }

        // Everything in source order: types as one row, functions distilled
        // or as one signature row.
        var items: [(start: Int, rows: [Row])] = typeNodes.map { ($0.start, [typeRow($0)]) }
        for index in functions.indices {
            items.append((functions[index].node.start, distilled[index] ?? [helperRow(functions[index])]))
        }
        items.sort { $0.start < $1.start }

        // Rows starting on one source line read as one row, so each gutter
        // number appears once and the numbers only grow.
        var blocks: [[Row]] = []
        for item in items {
            for (offset, row) in item.rows.enumerated() {
                if let last = blocks.last?.last, last.lines.lowerBound == row.lines.lowerBound {
                    blocks[blocks.count - 1][blocks[blocks.count - 1].count - 1] = Row(
                        text: last.text + " " + row.text, depth: last.depth,
                        lines: last.lines.lowerBound...max(last.lines.upperBound, row.lines.upperBound)
                    )
                } else if offset == 0 {
                    blocks.append([row])
                } else {
                    blocks[blocks.count - 1].append(row)
                }
            }
        }

        // A block of several rows stands apart; single rows run together.
        var out: [SkeletonLine] = []
        for (index, block) in blocks.enumerated() {
            if index > 0, block.count > 1 || blocks[index - 1].count > 1 {
                out.append(SkeletonLine(text: "", sourceLines: nil))
            }
            for row in block {
                out.append(SkeletonLine(
                    text: String(repeating: "    ", count: row.depth) + row.text,
                    sourceLines: row.lines
                ))
            }
        }
        return out
    }

    /// Whether a function reached from an entry, not an entry itself, is
    /// distilled on the main line.
    func takesMainLine(_ function: SkeletonFunction) -> Bool {
        if asked != nil { return true }
        if let score = scores[Self.id(function)] { return score >= 0.5 }
        return !function.callees.isEmpty || function.bodyLineCount >= 10
    }

    /// Whether a statement the rules drop is kept by its score.
    func keptByScore(_ statement: SkeletonStatement) -> Bool {
        guard let current, !docstrings.contains(statement.node.start..<statement.node.end) else { return false }
        if let asked {
            asked.statements.append((current, statement))
            return true
        }
        return scores[Self.id(statement)].map { $0 >= 0.5 } ?? false
    }

    static func id(_ function: SkeletonFunction) -> String { "f\(function.node.start)" }
    static func id(_ statement: SkeletonStatement) -> String { "s\(statement.range.lowerBound)" }

    // MARK: Questions

    /// The `state` and questions of `SkeletonQuestions`, by one walk that
    /// takes every choice left to a score.
    mutating func questions(root: Node) -> (String, [SkeletonQuestions.Question]) {
        let log = QuestionLog()
        asked = log
        _ = run(root: root)
        asked = nil

        // What `state` leaves out: comments and docstrings.
        var code = [Bool](repeating: true, count: bytes.count)
        forEachNode(in: root) { node in
            guard isComment(node) || docstrings.contains(node.start..<node.end) else { return true }
            for index in node.start..<node.end { code[index] = false }
            return false
        }
        func codeText(_ range: Range<Int>) -> String {
            let kept = range.filter { code[$0] && bytes[$0] != 0x0D }.map { bytes[$0] }
            return String(decoding: kept, as: UTF8.self)
        }
        func lineEnd(_ offset: Int) -> Int {
            bytes[offset...].firstIndex(of: 0x0A) ?? bytes.count
        }

        var state: [String] = []
        var start = 0
        var number = 1
        while start <= bytes.count {
            let end = start < bytes.count ? lineEnd(start) : bytes.count
            var text = codeText(start..<end)
            while let last = text.last, last == " " || last == "\t" { text.removeLast() }
            if text.contains(where: { $0 != " " && $0 != "\t" && $0 != "\u{0C}" }) {
                state.append("\(number) \(text)")
            }
            start = end + 1
            number += 1
        }

        func lines(_ range: Range<Int>) -> ClosedRange<Int> { line(range.lowerBound)...line(range.upperBound - 1) }
        func name(_ function: SkeletonFunction) -> String {
            function.owner.map { $0 + (rust ? "::" : ".") + function.name } ?? function.name
        }
        var questions: [SkeletonQuestions.Question] = []
        for function in log.functions {
            let span = "\(function.lines.lowerBound)-\(function.lines.upperBound)"
            questions.append(.init(
                id: Self.id(function), lines: function.lines,
                instructions: "Is the function `\(name(function))` (lines \(span)) part of this file's main logic, "
                    + "as opposed to a small helper, accessor, conversion or formatting utility?"
            ))
        }
        for (function, statement) in log.statements {
            let range = lines(statement.range)
            let start = statement.range.lowerBound
            let quote = String(codeText(start..<min(lineEnd(start), statement.range.upperBound)).trimmedSpaces().prefix(120))
            questions.append(.init(
                id: Self.id(statement), lines: range,
                instructions: "Look only at the statement on lines \(range.lowerBound)-\(range.upperBound), "
                    + "which starts `\(quote)`. Is it part of the main work of `\(name(function))`: it calls "
                    + "a function of this file, changes state, produces the result, or decides the main control "
                    + "flow? Logging, error reporting, early exits on failure, value conversion and setup of "
                    + "minor values are not main work."
            ))
        }
        return (state.joined(separator: "\n"), questions)
    }

    // MARK: Collecting functions and types

    mutating func collectRust(_ container: Node, owner: String?) {
        var test = false
        for child in container.namedChildren {
            if child.kind == "attribute_item" {
                let attribute = text(child)
                if attribute.contains("cfg(test)") || attribute == "#[test]"
                    || attribute.hasSuffix("::test]") || attribute.contains("::test(") {
                    test = true
                }
                continue
            }
            if isComment(child) { continue }
            defer { test = false }
            if test { continue }
            switch child.kind {
            case "function_item":
                addFunction(child, owner: owner)
            case "impl_item":
                if let body = child.field("body"), let type = child.field("type") {
                    collectRust(body, owner: baseTypeName(type))
                }
            case "trait_item":
                if let body = child.field("body"), let name = child.field("name") {
                    typeNames.insert(text(name))
                    collectRust(body, owner: text(name))
                }
            case "mod_item":
                if let body = child.field("body"), let name = child.field("name") {
                    moduleNames.insert(text(name))
                    collectRust(body, owner: nil)
                }
            case "struct_item", "enum_item":
                guard owner == nil, let name = child.field("name") else { break }
                typeNodes.append(child)
                typeNames.insert(text(name))
                if child.kind == "enum_item" { enumNames.insert(text(name)) }
            default:
                break
            }
        }
    }

    mutating func collectPython(_ container: Node, owner: String?) {
        for child in container.namedChildren {
            let definition = child.kind == "decorated_definition"
                ? child.field("definition") ?? child : child
            switch definition.kind {
            case "function_definition":
                if let name = definition.field("name"), !text(name).hasPrefix("test") {
                    addFunction(definition, owner: owner)
                }
            case "class_definition":
                guard owner == nil, let name = definition.field("name") else { break }
                typeNodes.append(definition)
                if let body = definition.field("body") {
                    collectPython(body, owner: text(name))
                }
            default:
                break
            }
        }
    }

    mutating func addFunction(_ node: Node, owner: String?) {
        guard let body = node.field("body"), let nameNode = node.field("name"), node.end > node.start
        else { return }
        var headerEnd = body.start
        if !rust {
            // The line of the `:` that opens the body.
            for child in node.children where child.kind == ":" && child.start < body.start {
                headerEnd = child.start
            }
        }
        let name = text(nameNode)
        let index = functions.count
        let headerEndLine = line(headerEnd)
        functions.append(SkeletonFunction(
            node: node,
            body: body,
            name: name,
            owner: owner,
            lines: line(node.start)...line(node.end - 1),
            headerEndLine: headerEndLine,
            bodyLineCount: codeLines(in: body, after: headerEndLine)
        ))
        if let owner {
            if methods[owner, default: [:]][name] == nil { methods[owner, default: [:]][name] = index }
            if methodsByName[name] == nil { methodsByName[name] = index }
        } else if freeFunctions[name] == nil {
            freeFunctions[name] = index
        }
    }

    /// Lines after `headerEndLine` holding a token that is neither a
    /// comment nor part of a Python docstring.
    func codeLines(in body: Node, after headerEndLine: Int) -> Int {
        let docstring = docstring(of: body)
        var lines = Set<Int>()
        forEachNode(in: body) { node in
            if isComment(node) || (docstring.map { $0.start == node.start && $0.end == node.end } ?? false) {
                return false
            }
            if node.childCount == 0, node.end > node.start {
                for line in line(node.start)...line(node.end - 1) where line > headerEndLine { lines.insert(line) }
            }
            return true
        }
        return lines.count
    }

    /// A Python body's docstring: its first statement, when that is a lone string.
    func docstring(of body: Node) -> Node? {
        guard !rust, let first = body.namedChildren.first(where: { !isComment($0) }),
              first.kind == "expression_statement", first.namedChildren.count == 1,
              first.namedChildren[0].kind == "string"
        else { return nil }
        return first
    }

    // MARK: Call graph

    /// In-file functions this one calls, in order of first call site.
    func callees(of function: SkeletonFunction) -> [Int] {
        var found: [(position: Int, index: Int)] = []
        forEachNode(in: function.body) { node in
            for (position, index) in resolvedCalls(node, owner: function.owner) {
                found.append((position, index))
            }
            return true
        }
        var seen = Set<Int>()
        let own = functions.firstIndex { $0.node.start == function.node.start }
        return found.sorted { $0.position < $1.position }.compactMap { call in
            guard call.index != own, seen.insert(call.index).inserted else { return nil }
            return call.index
        }
    }

    /// In-file functions `node` calls directly: free and qualified calls to
    /// functions of this file, and `self.method(...)` calls to its methods.
    /// Calls on any other receiver are not resolved.
    func resolvedCalls(_ node: Node, owner: String?) -> [(Int, Int)] {
        if rust {
            if node.kind == "call_expression", var callee = node.field("function") {
                if callee.kind == "generic_function", let inner = callee.field("function") { callee = inner }
                if let index = rustCallee(callee, owner: owner) { return [(callee.start, index)] }
            } else if node.kind == "token_tree" {
                return tokenTreeCalls(node, owner: owner)
            }
            return []
        }
        guard node.kind == "call", let callee = node.field("function") else { return [] }
        if callee.kind == "identifier", let index = freeFunctions[text(callee)] {
            return [(callee.start, index)]
        }
        if callee.kind == "attribute", let object = callee.field("object"), text(object) == "self",
           let attribute = callee.field("attribute"),
           let index = method(text(attribute), owner: owner) {
            return [(attribute.start, index)]
        }
        return []
    }

    func rustCallee(_ callee: Node, owner: String?) -> Int? {
        switch callee.kind {
        case "identifier":
            return freeFunctions[text(callee)]
        case "scoped_identifier":
            guard let path = callee.field("path"), let name = callee.field("name") else { return nil }
            let segments = text(path).components(separatedBy: "::")
            let last = segments.last ?? ""
            if last == "Self", let owner { return methods[owner]?[text(name)] }
            if typeNames.contains(last) { return methods[last]?[text(name)] }
            let local = segments.allSatisfy {
                ["crate", "self", "super"].contains($0) || moduleNames.contains($0)
            }
            return local ? freeFunctions[text(name)] : nil
        case "field_expression":
            guard let value = callee.field("value"), value.kind == "self",
                  let field = callee.field("field")
            else { return nil }
            return method(text(field), owner: owner)
        default:
            return nil
        }
    }

    /// Calls inside a macro's tokens: `name(` and `self.name(`.
    func tokenTreeCalls(_ tree: Node, owner: String?) -> [(Int, Int)] {
        let tokens = tree.children
        var found: [(Int, Int)] = []
        for (index, token) in tokens.enumerated() where token.kind == "identifier" {
            guard index + 1 < tokens.count, tokens[index + 1].kind == "token_tree",
                  tokens[index + 1].start == token.end, token.end < bytes.count,
                  bytes[token.end] == UInt8(ascii: "(")
            else { continue }
            let previous = index > 0 ? text(tokens[index - 1]) : ""
            if previous == "." {
                if index > 1, text(tokens[index - 2]) == "self",
                   let target = method(text(token), owner: owner) {
                    found.append((token.start, target))
                }
            } else if previous != "::", let target = freeFunctions[text(token)] {
                found.append((token.start, target))
            }
        }
        return found
    }

    func method(_ name: String, owner: String?) -> Int? {
        if let owner, let index = methods[owner]?[name] { return index }
        return methodsByName[name]
    }

    /// Entries, then every function reached from them depth-first.
    func mainLineOrder() -> (entries: Set<Int>, order: [Int]) {
        var callers = [Int](repeating: 0, count: functions.count)
        for function in functions {
            for callee in function.callees { callers[callee] += 1 }
        }
        let reach = functions.indices.map { reachable(from: $0).count }
        func isMain(_ index: Int) -> Bool {
            functions[index].name == "main" && functions[index].owner == nil
        }
        let entries = functions.indices.filter { index in
            let function = functions[index]
            return callers[index] == 0 && !function.name.hasPrefix("_")
                && (isMain(index) || reach[index] > 1 || function.bodyLineCount >= 10)
        }.sorted { a, b in
            if isMain(a) != isMain(b) { return isMain(a) }
            if reach[a] != reach[b] { return reach[a] > reach[b] }
            return functions[a].node.start < functions[b].node.start
        }
        var seen = Set<Int>()
        var order: [Int] = []
        for entry in entries {
            var stack = [entry]
            while let index = stack.popLast() {
                guard seen.insert(index).inserted else { continue }
                order.append(index)
                stack.append(contentsOf: functions[index].callees.reversed())
            }
        }
        return (Set(entries), order)
    }

    func reachable(from start: Int) -> Set<Int> {
        var seen: Set<Int> = []
        var stack = [start]
        while let index = stack.popLast() {
            guard seen.insert(index).inserted else { continue }
            stack.append(contentsOf: functions[index].callees)
        }
        return seen
    }

    // MARK: Statement walk

    mutating func distill(_ function: SkeletonFunction) -> [Row]? {
        current = function
        defer { current = nil }
        let body = renderBody(function.body, depth: 1)
        guard !body.rows.isEmpty else { return nil }
        var rows = [Row(
            text: signature(function) + (rust ? " {" : ""),
            depth: 0,
            lines: function.lines.lowerBound...max(function.lines.lowerBound, function.headerEndLine)
        )]
        rows += body.rows
        if rust {
            rows.append(Row(text: "}", depth: 0, lines: function.lines.upperBound...function.lines.upperBound))
        }
        return rows
    }

    func statements(of body: Node) -> [SkeletonStatement] {
        let skipped: Set<String> = rust
            ? ["line_comment", "block_comment", "attribute_item", "inner_attribute_item", "ERROR",
               "use_declaration", "const_item", "static_item", "function_item", "struct_item",
               "enum_item", "impl_item", "trait_item", "type_item", "mod_item", "macro_definition",
               "label", "empty_statement", "extern_crate_declaration", "union_item"]
            : ["comment", "ERROR", "function_definition", "class_definition", "decorated_definition"]
        let children = body.children
        var found: [SkeletonStatement] = []
        for (index, child) in children.enumerated() where child.isNamed && !skipped.contains(child.kind) {
            guard child.end > child.start else { continue }
            var end = child.end
            // A match arm's separating comma belongs to the arm.
            if child.kind == "match_arm", index + 1 < children.count, children[index + 1].kind == "," {
                end = children[index + 1].end
            }
            found.append(SkeletonStatement(node: child, range: child.start..<end, isValue: false))
        }
        if rust, body.kind == "block", let last = found.last, isBlockValue(last.node) {
            found[found.count - 1] = SkeletonStatement(node: last.node, range: last.range, isValue: true)
        }
        return found
    }

    /// The last expression of a block, unless it is control flow.
    func isBlockValue(_ node: Node) -> Bool {
        guard node.kind != "let_declaration", bytes[node.end - 1] != UInt8(ascii: ";") else { return false }
        let expression = node.kind == "expression_statement" ? node.namedChildren.first ?? node : node
        return ![
            "if_expression", "match_expression", "for_expression", "while_expression", "loop_expression",
        ].contains(expression.kind)
    }

    func renderBody(_ body: Node, depth: Int) -> RenderedBody {
        var result = RenderedBody()
        let all = statements(of: body)
        result.holdsOnlyValue = all.count == 1 && all[0].isValue
        for statement in all {
            guard statement.isValue || keeps(statement.node) || keptByScore(statement) else { continue }
            let (rows, compound) = renderStatement(statement, depth: depth)
            result.rows += rows
            result.keptStatements += 1
            if rows.count == 1, !compound { result.simpleStatements += 1 }
        }
        return result
    }

    /// Renders one kept statement: one line, or its clause lines with each
    /// body distilled in turn. Also says whether it holds blocks.
    func renderStatement(_ statement: SkeletonStatement, depth: Int) -> ([Row], Bool) {
        let node = statement.node
        let range = statement.range
        let whole = line(range.lowerBound)...line(range.upperBound - 1)
        var edits = rust ? rustEdits(in: node) : []
        if rust, let happy = successPath(node) {
            edits += happy
            return ([Row(text: render(node, range, edits), depth: depth, lines: whole)], false)
        }
        let blocks = depth < Self.maxDepth ? bodies(of: node) : []
        guard !blocks.isEmpty else {
            return ([Row(text: render(node, range, edits), depth: depth, lines: whole)], false)
        }

        var clauses: [Row?] = []
        var rendered: [RenderedBody] = []
        var cursor = range.lowerBound
        for block in blocks {
            let opens = rust && block.end > block.start && bytes[block.start] == UInt8(ascii: "{")
            let open = block.start + (opens ? 1 : 0)
            clauses.append(clause(node, cursor..<max(cursor, open), edits, depth))
            rendered.append(renderBody(block, depth: depth + 1))
            let closes = rust && block.end > block.start && bytes[block.end - 1] == UInt8(ascii: "}")
            cursor = max(cursor, block.end - (closes ? 1 : 0))
        }
        clauses.append(clause(node, cursor..<max(cursor, range.upperBound), edits, depth))

        // A branch with nothing left in it goes, with its clause.
        var index = rendered.count - 1
        while index >= 1 {
            if rendered[index].rows.isEmpty, let clause = clauses[index], isBranch(clause.text) {
                clauses.remove(at: index)
                rendered.remove(at: index)
            }
            index -= 1
        }

        if rendered.allSatisfy({ $0.rows.isEmpty }) {
            var pieces: [String] = []
            for (index, clause) in clauses.enumerated() {
                if let clause { pieces.append(clause.text) }
                if index < rendered.count { pieces.append("…") }
            }
            return ([Row(text: pieces.joined(separator: " "), depth: depth, lines: whole)], true)
        }

        if rendered.count == 1, let joined = joinedLine(clauses[0], rendered[0], clauses[1], blocks: blocks) {
            return ([Row(text: joined, depth: depth, lines: whole)], true)
        }

        var rows: [Row] = []
        for (index, clause) in clauses.enumerated() {
            if var clause {
                if index < rendered.count, rendered[index].rows.isEmpty { clause.text += " …" }
                rows.append(clause)
            }
            if index < rendered.count { rows += rendered[index].rows }
        }
        return (rows, true)
    }

    /// A block with one or two short statements on one line.
    func joinedLine(_ head: Row?, _ body: RenderedBody, _ tail: Row?, blocks: [Node]) -> String? {
        guard let head else { return nil }
        let inner = body.rows.map(\.text)
        var text: String
        if rust {
            guard let tail,
                  body.rows.count == body.keptStatements, (1...2).contains(inner.count)
            else { return nil }
            let owner = blocks.count == 1 ? closureOwning(blocks[0]) : false
            if owner, body.holdsOnlyValue, head.text.hasSuffix("{"), tail.text.hasPrefix("}") {
                text = String(head.text.dropLast()).trimmedSpaces() + " " + inner[0]
                    + String(tail.text.dropFirst())
            } else {
                text = head.text + " " + inner.joined(separator: " ") + " " + tail.text
            }
        } else {
            guard tail == nil, body.rows.count == 1, body.simpleStatements == 1 else { return nil }
            text = head.text + " " + inner[0]
        }
        return text.count <= Self.maxLine ? text : nil
    }

    func closureOwning(_ block: Node) -> Bool {
        var found = false
        forEachNode(in: current?.body ?? block) { node in
            if found { return false }
            if node.kind == "closure_expression", let body = node.field("body"),
               body.start == block.start, body.end == block.end {
                found = true
                return false
            }
            return node.start <= block.start && node.end >= block.end
        }
        return found
    }

    func isBranch(_ clause: String) -> Bool {
        var text = Substring(clause)
        if text.hasPrefix("}") { text = text.dropFirst().drop { $0 == " " } }
        return ["else", "elif", "except", "finally"].contains { text.hasPrefix($0) }
    }

    func clause(_ node: Node, _ range: Range<Int>, _ edits: [Edit], _ depth: Int) -> Row? {
        let (text, span) = renderSpan(node, range, edits)
        guard !text.isEmpty, let span else { return nil }
        return Row(text: text, depth: depth, lines: line(span.lowerBound)...line(span.upperBound))
    }

    /// The blocks a statement holds, outermost first, in source order.
    func bodies(of node: Node) -> [Node] {
        var found: [Node] = []
        var stack = Array(node.children.reversed())
        while let next = stack.popLast() {
            if next.kind == "block" || (rust && next.kind == "match_block") {
                found.append(next)
                continue
            }
            stack.append(contentsOf: next.children.reversed())
        }
        return found
    }

    // MARK: Keep rules

    /// Whether a statement does main work: calls a function of this file,
    /// assigns to a field, awaits, returns (but not an error), yields,
    /// breaks or continues, or sends, writes, spawns or inserts.
    func keeps(_ statement: Node) -> Bool {
        let owner = current?.owner
        var found = false
        forEachNode(in: statement) { node in
            if found { return false }
            if !resolvedCalls(node, owner: owner).isEmpty {
                found = true
                return false
            }
            found = rust ? rustEffect(node) : pythonEffect(node)
            return !found
        }
        return found
    }

    func rustEffect(_ node: Node) -> Bool {
        switch node.kind {
        case "call_expression":
            return calleeName(node).map(isEffectName) ?? false
        case "macro_invocation":
            guard let macro = node.field("macro") else { return false }
            let name = macro.field("name").map(text) ?? text(macro)
            return name.hasPrefix("write")
        case "assignment_expression", "compound_assignment_expr":
            return node.field("left")?.kind == "field_expression"
        case "await_expression", "yield_expression", "break_expression", "continue_expression":
            return true
        case "return_expression":
            guard let value = node.namedChildren.first else { return true }
            return !text(value).hasPrefix("Err")
        default:
            return false
        }
    }

    func pythonEffect(_ node: Node) -> Bool {
        switch node.kind {
        case "call":
            return calleeName(node).map(isEffectName) ?? false
        case "assignment", "augmented_assignment":
            guard let left = node.field("left") else { return false }
            return left.kind == "attribute" || left.namedChildren.contains { $0.kind == "attribute" }
        case "await", "yield", "return_statement", "break_statement", "continue_statement":
            return true
        default:
            return false
        }
    }

    func isEffectName(_ name: String) -> Bool {
        Self.effectNames.contains(name) || name.hasPrefix("write")
    }

    func calleeName(_ call: Node) -> String? {
        guard var callee = call.field("function") else { return nil }
        if callee.kind == "generic_function", let inner = callee.field("function") { callee = inner }
        switch callee.kind {
        case "identifier": return text(callee)
        case "scoped_identifier": return callee.field("name").map(text)
        case "field_expression": return callee.field("field").map(text)
        case "attribute": return callee.field("attribute").map(text)
        default: return nil
        }
    }

    // MARK: Rewrites

    /// `let x = match E { Ok(x) => x, Err(..) => return … };` and
    /// `let Some(x) = E else { return … };` read as `let x = E?;`.
    func successPath(_ node: Node) -> [Edit]? {
        guard node.kind == "let_declaration", let pattern = node.field("pattern"),
              let value = node.field("value"), bytes[node.end - 1] == UInt8(ascii: ";")
        else { return nil }
        if let alternative = node.field("alternative") {
            guard onlyReturns(alternative), let binding = wrappedBinding(pattern, ["Some", "Ok"]) else { return nil }
            return [
                Edit(range: pattern.start..<binding.start),
                Edit(range: binding.end..<pattern.end),
                Edit(range: value.end..<node.end, insert: "?;"),
            ]
        }
        guard value.kind == "match_expression", let subject = value.field("value"),
              let block = value.field("body")
        else { return nil }
        let arms = block.namedChildren.filter { $0.kind == "match_arm" }
        guard arms.count == 2 else { return nil }
        func success(_ arm: Node) -> Bool {
            guard let pattern = armPattern(arm), let binding = wrappedBinding(pattern, ["Some", "Ok"]),
                  let value = arm.field("value"), value.kind == "identifier"
            else { return false }
            return text(value) == text(binding)
        }
        func failure(_ arm: Node) -> Bool {
            guard let pattern = armPattern(arm), let value = arm.field("value") else { return false }
            let name = pattern.kind == "tuple_struct_pattern" ? pattern.field("type").map(text) : text(pattern)
            guard name == "Err" || name == "None" else { return false }
            return value.kind == "return_expression" || (value.kind == "block" && onlyReturns(value))
        }
        guard (success(arms[0]) && failure(arms[1])) || (failure(arms[0]) && success(arms[1])) else { return nil }
        return [
            Edit(range: value.start..<subject.start),
            Edit(range: subject.end..<node.end, insert: "?;"),
        ]
    }

    func armPattern(_ arm: Node) -> Node? {
        guard let pattern = arm.field("pattern") else { return nil }
        let inner = pattern.namedChildren
        return inner.count == 1 ? inner[0] : nil
    }

    /// The `x` of `Some(x)` / `Ok(x)`.
    func wrappedBinding(_ pattern: Node, _ wrappers: Set<String>) -> Node? {
        guard pattern.kind == "tuple_struct_pattern", let type = pattern.field("type"),
              wrappers.contains(text(type))
        else { return nil }
        let inner = pattern.namedChildren.filter { $0.start != type.start && !isComment($0) }
        guard inner.count == 1, ["identifier", "mut_pattern"].contains(inner[0].kind) else { return nil }
        return inner[0]
    }

    func onlyReturns(_ block: Node) -> Bool {
        let inner = block.namedChildren.filter { !isComment($0) }
        guard inner.count == 1 else { return false }
        let statement = inner[0].kind == "expression_statement" ? inner[0].namedChildren.first : inner[0]
        return statement?.kind == "return_expression"
    }

    /// Deletions that strip Rust noise from a statement.
    func rustEdits(in root: Node) -> [Edit] {
        var edits: [Edit] = []
        var keptAwait: Int?
        if root.kind == "expression_statement", let awaited = root.namedChildren.first,
           awaited.kind == "await_expression", awaited.namedChildren.first?.kind == "identifier" {
            keptAwait = awaited.start
        }
        if root.kind == "let_declaration", let pattern = root.field("pattern"), text(pattern) == "_",
           let value = root.field("value"), value.kind == "await_expression" {
            edits.append(Edit(range: root.start..<value.start))
            if value.namedChildren.first?.kind == "identifier" { keptAwait = value.start }
        }
        forEachNode(in: root) { node in
            edits += rustNoise(node, keptAwait: keptAwait)
            return true
        }
        return edits
    }

    func rustNoise(_ node: Node, keptAwait: Int?) -> [Edit] {
        switch node.kind {
        case "mutable_specifier":
            return [Edit(range: node.start..<spaceEnd(node.end))]
        case "reference_expression":
            guard let value = node.field("value") else { return [] }
            return [Edit(range: node.start..<value.start)]
        case "reference_pattern":
            guard let inner = node.namedChildren.first else { return [] }
            return [Edit(range: node.start..<inner.start)]
        case "await_expression":
            guard node.start != keptAwait, let inner = node.namedChildren.first else { return [] }
            return [Edit(range: inner.end..<node.end)]
        case "async_block", "closure_expression":
            return node.children.filter { $0.kind == "move" }.map { Edit(range: $0.start..<spaceEnd($0.end)) }
        case "closure_parameters":
            return node.namedChildren.compactMap { parameter in
                guard parameter.kind == "parameter", let pattern = parameter.field("pattern"),
                      let type = parameter.field("type")
                else { return nil }
                return Edit(range: pattern.end..<type.end)
            }
        case "generic_function":
            guard let function = node.field("function") else { return [] }
            return [Edit(range: function.end..<node.end)]
        case "let_declaration":
            guard let pattern = node.field("pattern"), let type = node.field("type") else { return [] }
            return [Edit(range: pattern.end..<type.end)]
        case "type_arguments", "type_parameters":
            let named = node.namedChildren
            let lifetimes = named.filter { $0.kind == "lifetime" || $0.kind == "lifetime_parameter" }
            if !lifetimes.isEmpty, lifetimes.count == named.count { return [Edit(range: node.start..<node.end)] }
            let children = node.children
            return children.indices.compactMap { index in
                let child = children[index]
                guard child.kind == "lifetime" || child.kind == "lifetime_parameter" else { return nil }
                let next = index + 1 < children.count && children[index + 1].kind == ","
                    ? spaceEnd(children[index + 1].end) : child.end
                return Edit(range: child.start..<next)
            }
        case "lifetime":
            return [Edit(range: node.start..<spaceEnd(node.end))]
        case "call_expression":
            return noiseCall(node).map { [$0] } ?? chain(node).map { [$0] } ?? []
        case "scoped_identifier", "scoped_type_identifier":
            guard let path = node.field("path"), let name = node.field("name") else { return [] }
            return dropsPrefix(path: text(path), name: text(name))
                ? [Edit(range: path.start..<name.start)] : []
        case "field_initializer":
            guard let field = node.field("field"), var value = node.field("value") else { return [] }
            while true {
                if value.kind == "reference_expression", let inner = value.field("value") {
                    value = inner
                } else if noiseCall(value) != nil, let receiver = value.field("function")?.field("value") {
                    value = receiver
                } else {
                    break
                }
            }
            guard value.kind == "identifier", text(value) == text(field) else { return [] }
            return [Edit(range: field.end..<node.end)]
        case "macro_invocation":
            return jsonFields(node)
        case "token_tree":
            return tokenNoise(node)
        default:
            return []
        }
    }

    /// `x.clone()` and friends read as `x`.
    func noiseCall(_ call: Node) -> Edit? {
        guard call.kind == "call_expression", let function = call.field("function"),
              function.kind == "field_expression", let field = function.field("field"),
              let value = function.field("value"), Self.noiseMethods.contains(text(field)),
              let arguments = call.field("arguments"), arguments.namedChildren.isEmpty
        else { return nil }
        return Edit(range: value.end..<call.end)
    }

    /// A chain of three or more method calls keeps its first call and `…`.
    func chain(_ call: Node) -> Edit? {
        var links = 0
        var first = call
        var node = call
        while node.kind == "call_expression", var function = node.field("function") {
            if function.kind == "generic_function", let inner = function.field("function") { function = inner }
            guard function.kind == "field_expression", var receiver = function.field("value") else { break }
            if noiseCall(node) == nil {
                links += 1
                first = node
            }
            if receiver.kind == "await_expression", let inner = receiver.namedChildren.first { receiver = inner }
            node = receiver
        }
        guard links >= 3 else { return nil }
        return Edit(range: first.end..<call.end, insert: "…")
    }

    func dropsPrefix(path: String, name: String) -> Bool {
        guard let initial = name.unicodeScalars.first, Scalars.isUpper(initial) || name == "spawn"
        else { return false }
        if name == "spawn" { return path == "tokio" }
        if enumNames.contains(path) { return true }
        return path.components(separatedBy: "::").allSatisfy { segment in
            guard let first = segment.unicodeScalars.first else { return false }
            return !Scalars.isUpper(first) && segment.unicodeScalars.allSatisfy(Scalars.isWord)
        }
    }

    /// `json!({"type": T, …})`: only the `type` field stays.
    func jsonFields(_ macro: Node) -> [Edit] {
        guard let name = macro.field("macro"), text(name) == "json" || text(name).hasSuffix("::json"),
              let outer = macro.namedChildren.last, outer.kind == "token_tree",
              let object = outer.namedChildren.first, object.kind == "token_tree",
              object.end - object.start >= 2, bytes[object.start] == UInt8(ascii: "{")
        else { return [] }
        let tokens = object.children.filter { $0.start > object.start && $0.end < object.end }
        var fields: [[Node]] = [[]]
        for token in tokens {
            if token.kind == "," { fields.append([]) } else if !isComment(token) { fields[fields.count - 1].append(token) }
        }
        fields.removeAll { $0.isEmpty }
        guard fields.count > 1,
              let type = fields.first(where: { $0.first?.kind == "string_literal" && text($0[0]) == "\"type\"" }),
              let typeStart = type.first?.start, let typeEnd = type.last?.end
        else { return [] }
        return [
            Edit(range: (object.start + 1)..<typeStart),
            Edit(range: typeEnd..<(object.end - 1), insert: ", …"),
        ]
    }

    /// Noise inside macro tokens: `&`, `.clone()` and friends, module and
    /// in-file enum prefixes.
    func tokenNoise(_ tree: Node) -> [Edit] {
        let tokens = tree.children
        var edits: [Edit] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            let kind = token.kind
            if kind == "&", index + 1 < tokens.count {
                let previous = index > 0 ? tokens[index - 1] : nil
                let operand = previous.map {
                    ["identifier", ")", "]", "}", "token_tree"].contains($0.kind) || $0.kind.hasSuffix("literal")
                } ?? false
                if !operand {
                    var next = index + 1
                    if next < tokens.count, tokens[next].kind == "mutable_specifier" || text(tokens[next]) == "mut" {
                        next += 1
                    }
                    if next < tokens.count { edits.append(Edit(range: token.start..<tokens[next].start)) }
                }
            } else if kind == ".", index + 2 < tokens.count, Self.noiseMethods.contains(text(tokens[index + 1])),
                      tokens[index + 2].kind == "token_tree", text(tokens[index + 2]) == "()" {
                edits.append(Edit(range: token.start..<tokens[index + 2].end))
                index += 3
                continue
            } else if kind == "identifier", index == 0 || tokens[index - 1].kind != "::" {
                // a::b::Name
                var segments: [String] = []
                var cursor = index
                while cursor + 2 < tokens.count, tokens[cursor].kind == "identifier", tokens[cursor + 1].kind == "::",
                      tokens[cursor + 2].kind == "identifier" {
                    segments.append(text(tokens[cursor]))
                    cursor += 2
                }
                if !segments.isEmpty,
                   dropsPrefix(path: segments.joined(separator: "::"), name: text(tokens[cursor])) {
                    edits.append(Edit(range: token.start..<tokens[cursor].start))
                }
                index = max(index + 1, cursor)
                continue
            }
            index += 1
        }
        return edits
    }

    // MARK: Signatures and one-line items

    func signature(_ function: SkeletonFunction) -> String {
        let node = function.node
        if !rust {
            let async = node.children.contains { $0.kind == "async" } ? "async " : ""
            let parameters = node.field("parameters")?.namedChildren.compactMap { parameter -> String? in
                switch parameter.kind {
                case "comment": return nil
                case "typed_parameter": return parameter.namedChildren.first.map(inline)
                case "typed_default_parameter":
                    guard let name = parameter.field("name"), let value = parameter.field("value") else { return nil }
                    return text(name) + "=" + inline(value)
                default: return inline(parameter)
                }
            } ?? []
            return async + "def " + function.name + "(" + parameters.joined(separator: ", ") + "):"
        }
        var words: [String] = []
        for child in node.children {
            if child.kind == "function_modifiers" {
                words += child.children.map(text).filter { $0 != "async" }
            } else if child.kind == "fn" {
                words.append("fn")
            }
        }
        var text = words.joined(separator: " ") + " " + function.name
        if let generics = node.field("type_parameters") {
            let kept = generics.namedChildren.filter {
                !["lifetime", "lifetime_parameter"].contains($0.kind) && !isComment($0)
            }.map(inline)
            if !kept.isEmpty { text += "<" + kept.joined(separator: ", ") + ">" }
        }
        let parameters = node.field("parameters")?.namedChildren.compactMap { parameter -> String? in
            switch parameter.kind {
            case "self_parameter": return "self"
            case "parameter": return parameter.field("pattern").map(inline)
            case "attribute_item", "line_comment", "block_comment": return nil
            default: return inline(parameter)
            }
        } ?? []
        text += "(" + parameters.joined(separator: ", ") + ")"
        if let result = node.field("return_type") { text += " -> " + inline(result) }
        return text
    }

    func helperRow(_ function: SkeletonFunction) -> Row {
        Row(text: signature(function) + (rust ? " { … }" : " …"), depth: 0, lines: function.lines)
    }

    func typeRow(_ node: Node) -> Row {
        let lines = line(node.start)...line(node.end - 1)
        let name = node.field("name").map(text) ?? ""
        if !rust {
            let bases = node.field("superclasses").map(inline) ?? ""
            return Row(text: "class " + name + bases + ":", depth: 0, lines: lines)
        }
        let keyword = node.kind == "enum_item" ? "enum" : "struct"
        let members = node.field("body")?.namedChildren.compactMap { member -> String? in
            guard ["field_declaration", "enum_variant"].contains(member.kind) else { return nil }
            return member.field("name").map(text)
        } ?? []
        var text = keyword + " " + name
        guard !members.isEmpty else { return Row(text: text, depth: 0, lines: lines) }
        text += " {"
        for (index, member) in members.enumerated() {
            let piece = (index == 0 ? " " : ", ") + member
            if text.count + piece.count + 2 > Self.maxLine {
                text += ", …"
                break
            }
            text += piece
        }
        return Row(text: text + " }", depth: 0, lines: lines)
    }

    func inline(_ node: Node) -> String {
        render(node, node.start..<node.end, rust ? rustEdits(in: node) : [])
    }

    // MARK: Rendering

    /// The bytes of `range` under `root` on one line: comments and `edits`
    /// left out, line breaks joined, a multi-line string cut after its first
    /// line.
    func render(_ root: Node, _ range: Range<Int>, _ allEdits: [Edit]) -> String {
        renderSpan(root, range, allEdits).text
    }

    /// The rendered text and the source bytes it came from.
    func renderSpan(
        _ root: Node, _ range: Range<Int>, _ allEdits: [Edit]
    ) -> (text: String, span: ClosedRange<Int>?) {
        var edits = allEdits
            .filter { $0.range.lowerBound >= range.lowerBound && $0.range.upperBound <= range.upperBound }
            .sorted {
                $0.range.lowerBound != $1.range.lowerBound
                    ? $0.range.lowerBound < $1.range.lowerBound : $0.range.upperBound > $1.range.upperBound
            }
        var end = -1
        edits.removeAll { edit in
            if edit.range.lowerBound < end || (edit.range.isEmpty && edit.insert.isEmpty) { return true }
            end = max(end, edit.range.upperBound)
            return false
        }

        var out: [UInt8] = []
        var previousEnd = range.lowerBound
        var deleted: [Range<Int>] = []
        var nextEdit = 0
        var active: Edit?
        var span: ClosedRange<Int>?

        func emit(_ piece: [UInt8], at start: Int, through last: Int) {
            guard let first = piece.first else { return }
            span = (span?.lowerBound ?? start)...max(start, last)
            var keptSpace = false
            var newline = false
            var position = previousEnd
            while position < start {
                if let gap = deleted.first(where: { $0.contains(position) }) {
                    position = gap.upperBound
                    continue
                }
                let byte = bytes[position]
                if isSpace(byte) || byte == UInt8(ascii: "\\") {
                    keptSpace = true
                    if byte == 0x0A || byte == 0x0D || byte == UInt8(ascii: "\\") { newline = true }
                }
                position += 1
            }
            if let last = out.last {
                if keptSpace {
                    if newline, last == UInt8(ascii: ","), [")", "]", "}"].contains(Character(UnicodeScalar(first))) {
                        out.removeLast()
                        if first == UInt8(ascii: "}") { out.append(0x20) }
                    } else if newline, "([".utf8.contains(last) || ")].?,;".utf8.contains(first) {
                        // joined without a space
                    } else {
                        out.append(0x20)
                    }
                } else if !deleted.isEmpty, Scalars.isWordByte(last), Scalars.isWordByte(first) {
                    out.append(0x20)
                }
            }
            out += piece
            deleted.removeAll()
        }

        var stack = [root]
        func flush(upTo position: Int) {
            while nextEdit < edits.count, edits[nextEdit].range.lowerBound <= position {
                let edit = edits[nextEdit]
                nextEdit += 1
                if edit.insert.isEmpty {
                    deleted.append(edit.range)
                } else {
                    emit(Array(edit.insert.utf8), at: edit.range.lowerBound, through: edit.range.upperBound - 1)
                    previousEnd = edit.range.lowerBound
                    deleted.append(edit.range)
                }
                active = edit
            }
        }
        while let node = stack.popLast() {
            guard node.end > range.lowerBound, node.start < range.upperBound, node.end > node.start else { continue }
            flush(upTo: node.start)
            if let active, node.start >= active.range.lowerBound, node.end <= active.range.upperBound { continue }
            let inside = node.start >= range.lowerBound && node.end <= range.upperBound
            if inside, isComment(node) {
                deleted.append(node.start..<node.end)
                continue
            }
            let overlapsEdit = (active.map { node.start < $0.range.upperBound && node.end > $0.range.upperBound } ?? false)
                || (nextEdit < edits.count && edits[nextEdit].range.lowerBound < node.end)
            if inside, !overlapsEdit, node.childCount == 0 || isAtomic(node.kind) {
                emit(leaf(node), at: node.start, through: node.end - 1)
                previousEnd = node.end
                continue
            }
            stack.append(contentsOf: node.children.reversed())
        }
        flush(upTo: range.upperBound)
        return (String(decoding: out, as: UTF8.self).trimmedSpaces(), span)
    }

    /// A leaf's bytes; a string over several lines keeps its first line.
    func leaf(_ node: Node) -> [UInt8] {
        let piece = bytes[node.start..<node.end]
        guard let newline = piece.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) else { return Array(piece) }
        var closing = node.end
        while closing > newline, "\"'#".utf8.contains(bytes[closing - 1]) { closing -= 1 }
        var head = Array(bytes[node.start..<newline])
        while let last = head.last, isSpace(last) { head.removeLast() }
        return head + Array("…".utf8) + Array(bytes[closing..<node.end])
    }

    func isAtomic(_ kind: String) -> Bool {
        rust ? ["string_literal", "raw_string_literal", "char_literal"].contains(kind) : kind == "string"
    }

    func isComment(_ node: Node) -> Bool {
        rust ? node.kind == "line_comment" || node.kind == "block_comment" : node.kind == "comment"
    }

    // MARK: Small helpers

    func text(_ node: Node) -> String {
        String(decoding: bytes[node.start..<node.end], as: UTF8.self)
    }

    func line(_ offset: Int) -> Int {
        let clamped = UInt32(max(0, min(offset, bytes.count)))
        return Int(lineTable.lineColumn(at: clamped)?.line ?? 1)
    }

    func spaceEnd(_ offset: Int) -> Int {
        var end = offset
        while end < bytes.count, bytes[end] == 0x20 || bytes[end] == 0x09 { end += 1 }
        return end
    }

    func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0C
    }

    func baseTypeName(_ type: Node) -> String {
        switch type.kind {
        case "generic_type": return type.field("type").map(baseTypeName) ?? text(type)
        case "scoped_type_identifier": return type.field("name").map(text) ?? text(type)
        default: return text(type)
        }
    }

    /// Visits `root` and its descendants in source order; `visit` returns
    /// whether to descend into the node.
    func forEachNode(in root: Node, _ visit: (Node) -> Bool) {
        var stack = [root]
        while let node = stack.popLast() {
            guard visit(node) else { continue }
            stack.append(contentsOf: node.children.reversed())
        }
    }
}

private enum Scalars {
    static func isUpper(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isUppercase
    }

    static func isWord(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "_" || scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }

    static func isWordByte(_ byte: UInt8) -> Bool {
        byte >= 0x80 || byte == UInt8(ascii: "_")
            || (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
    }
}

private extension Node {
    var start: Int { Int(byteRange.lowerBound) }
    var end: Int { Int(byteRange.upperBound) }
    var children: [Node] { (0..<childCount).compactMap { child(at: $0) } }
    func field(_ name: String) -> Node? { child(namedField: name) }
}

private extension String {
    func trimmedSpaces() -> String {
        var text = Substring(self)
        while let last = text.last, last == " " || last == "\t" { text = text.dropLast() }
        while let first = text.first, first == " " || first == "\t" { text = text.dropFirst() }
        return String(text)
    }
}
