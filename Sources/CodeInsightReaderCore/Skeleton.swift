import CTreeSitterGo
import CTreeSitterPython
import CTreeSitterRust
import CTreeSitterTypeScript
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

/// The distilled skeleton of one Rust, Python, TypeScript or Go file, in source order:
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
///
/// `variant` is the TypeScript variant of `LanguageMode`: "tsx" parses JSX,
/// anything else plain TypeScript, whose `<T>x` and generic arrows TSX reads
/// differently. JavaScript always parses as TSX.
public func distillSkeleton(
    bytes: [UInt8], language: LanguageID, variant: String? = nil, scores: [String: Double] = [:]
) -> [SkeletonLine]? {
    withDistiller(bytes: bytes, language: language, variant: variant) { distiller, root in
        distiller.scores = scores
        return distiller.run(root: root)
    }
}

private func withDistiller<T>(
    bytes: [UInt8], language: LanguageID, variant: String?, _ body: (inout SkeletonDistiller, Node) -> T
) -> T? {
    let grammar: OpaquePointer?
    let kind: SkeletonLanguage
    switch language {
    case .rust: (grammar, kind) = (tree_sitter_rust(), .rust)
    case .python: (grammar, kind) = (tree_sitter_python(), .python)
    case .typescript: (grammar, kind) = (variant == "tsx" ? tree_sitter_tsx() : tree_sitter_typescript(), .typescript)
    case .javascript: (grammar, kind) = (tree_sitter_tsx(), .typescript)
    case .go: (grammar, kind) = (tree_sitter_go(), .go)
    }
    guard let grammar,
          let parser = Parser(language: grammar),
          let tree = parser.parse(bytes)
    else { return nil }
    var distiller = SkeletonDistiller(bytes: bytes, language: kind)
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
    public init?(bytes: [UInt8], language: LanguageID, variant: String? = nil) {
        guard let (state, questions) = withDistiller(bytes: bytes, language: language, variant: variant, { distiller, root in
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

/// A Rust, Python, TypeScript or Go file's Overview as a document of its own: the skeleton
/// text, highlighted, with no folds, and the map back to the source.
package struct SkeletonOverview: Sendable {
    package let document: ReaderDocument
    package let map: SkeletonLineMap

    /// Nil when the file has no skeleton; it keeps its ordinary Overview.
    package init?(source: ReaderDocument, scores: [String: Double] = [:]) {
        guard let lines = distillSkeleton(
            bytes: source.bytes, language: source.languageMode.language,
            variant: source.languageMode.variant, scores: scores
        ),
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
    /// A Go method's receiver variable: `e` of `func (e *Engine) …`.
    var receiver: String?
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

private enum SkeletonLanguage { case rust, python, typescript, go }

private struct SkeletonDistiller {
    let bytes: [UInt8]
    let language: SkeletonLanguage
    let lineTable: LineTable
    /// Rust, TypeScript and Go: bodies open with `{` and close with `}`.
    var braces: Bool { language != .python }

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
    static let typeScriptNoiseMethods: Set<String> = ["toString", "slice"]
    static let typeScriptOpaque: Set<String> = ["object", "jsx_element", "jsx_self_closing_element", "jsx_fragment"]
    static let effectNames: Set<String> = ["send", "spawn", "append", "insert", "push"]
    static let goSwitches: Set<String> = ["expression_switch_statement", "type_switch_statement", "select_statement"]
    static let goCases: Set<String> = ["expression_case", "type_case", "communication_case", "default_case"]

    init(bytes: [UInt8], language: SkeletonLanguage) {
        self.bytes = bytes
        self.language = language
        self.lineTable = LineTable(bytes: bytes)
    }

    mutating func run(root: Node) -> [SkeletonLine] {
        if language == .python {
            forEachNode(in: root) { node in
                let body = node.kind == "module" ? node
                    : ["function_definition", "class_definition"].contains(node.kind) ? node.field("body") : nil
                if let body, let docstring = docstring(of: body) { docstrings.insert(docstring.start..<docstring.end) }
                return true
            }
        }
        switch language {
        case .rust: collectRust(root, owner: nil)
        case .python: collectPython(root, owner: nil)
        case .typescript: collectTypeScript(root)
        case .go: collectGo(root)
        }
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
        // A returning `if err != nil` stays dropped: scores near 0.5 kept
        // about half of them, so the error plumbing came and went.
        if errorCheck(statement.node) != nil { return false }
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
            function.owner.map { $0 + (language == .rust ? "::" : ".") + function.name } ?? function.name
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

    /// Top-level functions, arrow-function constants, classes with their
    /// methods, interfaces, enums and type aliases; `export` is looked through.
    mutating func collectTypeScript(_ program: Node) {
        for child in program.namedChildren {
            let node = child.kind == "export_statement" ? child.field("declaration") ?? child : child
            switch node.kind {
            case "function_declaration", "generator_function_declaration":
                addFunction(node, owner: nil)
            case "lexical_declaration", "variable_declaration":
                // ponytail: one declarator only, so the function's id (its start) stays unique.
                let declarators = node.namedChildren.filter { $0.kind == "variable_declarator" }
                guard declarators.count == 1, let name = declarators[0].field("name"), name.kind == "identifier",
                      let value = functionValue(declarators[0])
                else { break }
                addFunction(node, owner: nil, name: name, body: value.field("body"))
            case "class_declaration", "abstract_class_declaration":
                guard let name = node.field("name") else { break }
                typeNodes.append(node)
                for member in node.field("body")?.namedChildren ?? [] {
                    if member.kind == "method_definition" {
                        addFunction(member, owner: text(name))
                    } else if member.kind == "public_field_definition", let field = member.field("name"),
                              let value = functionValue(member) {
                        addFunction(member, owner: text(name), name: field, body: value.field("body"))
                    }
                }
            case "interface_declaration", "enum_declaration", "type_alias_declaration":
                typeNodes.append(node)
            default:
                break
            }
        }
    }

    /// Functions, methods (owned by their receiver's type) and types; test
    /// functions are left out.
    mutating func collectGo(_ file: Node) {
        for node in file.namedChildren {
            switch node.kind {
            case "function_declaration":
                if let name = node.field("name"), !isGoTest(node, name: text(name)) { addFunction(node, owner: nil) }
            case "method_declaration":
                let receiver = node.field("receiver")?.namedChildren.first { $0.kind == "parameter_declaration" }
                guard let type = receiver?.field("type") else { break }
                addFunction(node, owner: baseTypeName(type))
                if !functions.isEmpty, functions[functions.count - 1].node.start == node.start {
                    functions[functions.count - 1].receiver = receiver?.field("name").map(text)
                }
            case "type_declaration":
                for spec in node.namedChildren where ["type_spec", "type_alias"].contains(spec.kind) {
                    typeNodes.append(spec)
                    if let name = spec.field("name") { typeNames.insert(text(name)) }
                }
            default:
                break
            }
        }
    }

    /// What `go test` runs: `TestX(*testing.T)`, `BenchmarkX`, `FuzzX`, and
    /// `ExampleX()`. ponytail: by shape, not by a `_test.go` path, as Python's `test` prefix.
    func isGoTest(_ node: Node, name: String) -> Bool {
        guard let prefix = ["Test", "Benchmark", "Fuzz", "Example"].first(where: name.hasPrefix) else { return false }
        if let next = name.dropFirst(prefix.count).unicodeScalars.first, next.properties.isLowercase { return false }
        let parameters = node.field("parameters").map(text) ?? ""
        return prefix == "Example" ? parameters == "()" && node.field("result") == nil : parameters.contains("testing.")
    }

    /// The arrow function or function expression a declarator or class field holds.
    func functionValue(_ holder: Node) -> Node? {
        guard let value = holder.field("value"), ["arrow_function", "function_expression"].contains(value.kind)
        else { return nil }
        return value
    }

    /// `name` and `body` default to the node's own fields.
    mutating func addFunction(_ node: Node, owner: String?, name: Node? = nil, body: Node? = nil) {
        guard let body = body ?? node.field("body"), let nameNode = name ?? node.field("name"), node.end > node.start
        else { return }
        var headerEnd = body.start
        if language == .python {
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
        guard language == .python, let first = body.namedChildren.first(where: { !isComment($0) }),
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
            for (position, index) in resolvedCalls(node, owner: function.owner, receiver: function.receiver) {
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
    func resolvedCalls(_ node: Node, owner: String?, receiver: String? = nil) -> [(Int, Int)] {
        switch language {
        case .rust:
            if node.kind == "call_expression", var callee = node.field("function") {
                if callee.kind == "generic_function", let inner = callee.field("function") { callee = inner }
                if let index = rustCallee(callee, owner: owner) { return [(callee.start, index)] }
            } else if node.kind == "token_tree" {
                return tokenTreeCalls(node, owner: owner)
            }
            return []
        case .python:
            return memberCalls(node, owner: owner, call: "call", member: "attribute", name: "attribute", receiver: "self")
        case .typescript:
            return memberCalls(
                node, owner: owner, call: "call_expression", member: "member_expression", name: "property", receiver: "this"
            )
        case .go:
            // A method called on anything but the receiver is not resolved.
            return memberCalls(
                node, owner: owner, call: "call_expression", member: "selector_expression", name: "field",
                receiver: receiver ?? "", object: "operand"
            )
        }
    }

    /// `name(...)` to a free function, `self.name(...)` / `this.name(...)` to a method.
    func memberCalls(
        _ node: Node, owner: String?, call: String, member: String, name: String, receiver: String,
        object: String = "object"
    ) -> [(Int, Int)] {
        guard node.kind == call, let callee = node.field("function") else { return [] }
        if callee.kind == "identifier", let index = freeFunctions[text(callee)] {
            return [(callee.start, index)]
        }
        if callee.kind == member, !receiver.isEmpty, let object = callee.field(object), text(object) == receiver,
           let attribute = callee.field(name),
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
            (functions[index].name == "main" || (language == .go && functions[index].name == "init"))
                && functions[index].owner == nil
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
        // An arrow function with an expression body is one row.
        guard language != .typescript || function.body.kind == "statement_block" else { return nil }
        current = function
        defer { current = nil }
        let body = renderBody(function.body, depth: 1)
        guard !body.rows.isEmpty else { return nil }
        var rows = [Row(
            text: signature(function) + (braces ? " {" : ""),
            depth: 0,
            lines: function.lines.lowerBound...max(function.lines.lowerBound, function.headerEndLine)
        )]
        rows += body.rows
        if braces {
            rows.append(Row(text: "}", depth: 0, lines: function.lines.upperBound...function.lines.upperBound))
        }
        return rows
    }

    func statements(of body: Node) -> [SkeletonStatement] {
        let skipped: Set<String> = switch language {
        case .rust: ["line_comment", "block_comment", "attribute_item", "inner_attribute_item", "ERROR",
               "use_declaration", "const_item", "static_item", "function_item", "struct_item",
               "enum_item", "impl_item", "trait_item", "type_item", "mod_item", "macro_definition",
               "label", "empty_statement", "extern_crate_declaration", "union_item"]
        case .python: ["comment", "ERROR", "function_definition", "class_definition", "decorated_definition"]
        case .typescript: ["comment", "ERROR", "function_declaration", "generator_function_declaration",
                           "class_declaration", "abstract_class_declaration", "interface_declaration",
                           "type_alias_declaration", "enum_declaration", "import_statement", "empty_statement"]
        case .go: ["comment", "ERROR", "type_declaration", "const_declaration", "empty_statement"]
        }
        var children = body.children
        if language == .go {
            // A switch's statements are its cases; a block's and a case's are in a list.
            if Self.goSwitches.contains(body.kind) {
                children = children.filter { Self.goCases.contains($0.kind) }
            } else if Self.goCases.contains(body.kind) || body.kind == "block" {
                children = children.first { $0.kind == "statement_list" }?.children ?? []
            }
        }
        // A switch case's statements follow its `case value:`.
        let first = body.kind == "switch_case" ? caseColon(body)?.end ?? body.end : body.start
        var found: [SkeletonStatement] = []
        for (index, child) in children.enumerated()
        where child.isNamed && !skipped.contains(child.kind) && child.start >= first {
            guard child.end > child.start else { continue }
            var end = child.end
            // A match arm's separating comma belongs to the arm.
            if child.kind == "match_arm", index + 1 < children.count, children[index + 1].kind == "," {
                end = children[index + 1].end
            }
            found.append(SkeletonStatement(node: child, range: child.start..<end, isValue: false))
        }
        if language == .rust, body.kind == "block", let last = found.last, isBlockValue(last.node) {
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
        for (index, statement) in all.enumerated() {
            guard statement.isValue || keeps(statement.node) || keptByScore(statement) else { continue }
            let checked = index + 1 < all.count && errorCheck(all[index + 1].node) != nil
            let (rows, compound) = renderStatement(statement, depth: depth, extra: checked ? errorBinding(statement.node) : [])
            result.rows += rows
            result.keptStatements += 1
            if rows.count == 1, !compound { result.simpleStatements += 1 }
        }
        return result
    }

    /// Renders one kept statement: one line, or its clause lines with each
    /// body distilled in turn. Also says whether it holds blocks.
    func renderStatement(_ statement: SkeletonStatement, depth: Int, extra: [Edit] = []) -> ([Row], Bool) {
        let node = statement.node
        let range = statement.range
        let whole = line(range.lowerBound)...line(range.upperBound - 1)
        var edits = noiseEdits(in: node) + extra
        if language == .rust, let happy = successPath(node) {
            edits += happy
            return ([Row(text: render(node, range, edits), depth: depth, lines: whole)], false)
        }
        // `if err := f(); err != nil { return … }` reads as `f()`.
        if let check = errorCheck(node), let call = check.initializer?.field("right") {
            return renderStatement(SkeletonStatement(node: call, range: call.start..<call.end, isValue: false), depth: depth)
        }
        if depth < Self.maxDepth, let colon = caseColon(node) {
            return (caseRows(statement, colon: colon, edits: edits, depth: depth), true)
        }
        let blocks = depth >= Self.maxDepth ? []
            : language == .typescript && node.kind == "statement_block" ? [node]
            : language == .go && (node.kind == "block" || Self.goSwitches.contains(node.kind)) ? [node]
            : bodies(of: node)
        guard !blocks.isEmpty else {
            return ([Row(text: render(node, range, edits), depth: depth, lines: whole)], false)
        }

        var clauses: [Row?] = []
        var rendered: [RenderedBody] = []
        var cursor = range.lowerBound
        for block in blocks {
            let (open, close) = innerBounds(block)
            clauses.append(clause(node, cursor..<max(cursor, open), edits, depth))
            rendered.append(renderBody(block, depth: depth + 1))
            cursor = max(cursor, close)
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
            return ([Row(text: fitted(pieces.joined(separator: " ")), depth: depth, lines: whole)], true)
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

    /// Where a block's statements start and end: inside its braces. A Go
    /// switch is its own block, braced after its header.
    func innerBounds(_ block: Node) -> (Int, Int) {
        if language == .go, Self.goSwitches.contains(block.kind) {
            let children = block.children
            return (children.first { $0.kind == "{" }?.end ?? block.end, children.last { $0.kind == "}" }?.start ?? block.end)
        }
        let opens = braces && block.end > block.start && bytes[block.start] == UInt8(ascii: "{")
        let closes = braces && block.end > block.start && bytes[block.end - 1] == UInt8(ascii: "}")
        return (block.start + (opens ? 1 : 0), block.end - (closes ? 1 : 0))
    }

    /// A block with one or two short statements on one line.
    func joinedLine(_ head: Row?, _ body: RenderedBody, _ tail: Row?, blocks: [Node]) -> String? {
        // Go cases have no `;` or `break` to tell them apart on one line.
        guard let head, !(language == .go && blocks.contains { Self.goSwitches.contains($0.kind) }) else { return nil }
        let inner = body.rows.map(\.text)
        var text: String
        if braces {
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
        let words = switch language {
        case .typescript: ["else", "catch", "finally"]
        case .go: ["else"]
        default: ["else", "elif", "except", "finally"]
        }
        return words.contains { text.hasPrefix($0) }
    }

    /// The `:` ending a TypeScript or Go `case value:` or `default:`.
    func caseColon(_ node: Node) -> Node? {
        let cases: Set<String> = language == .go ? Self.goCases
            : language == .typescript ? ["switch_case", "switch_default"] : []
        guard cases.contains(node.kind) else { return nil }
        return node.children.first { $0.kind == ":" }
    }

    /// A switch case as its `case value:` line and its statements, or one
    /// line when a single short statement is left.
    func caseRows(_ statement: SkeletonStatement, colon: Node, edits: [Edit], depth: Int) -> [Row] {
        let node = statement.node
        let whole = line(statement.range.lowerBound)...line(statement.range.upperBound - 1)
        guard let head = clause(node, statement.range.lowerBound..<colon.end, edits, depth) else {
            return [Row(text: render(node, statement.range, edits), depth: depth, lines: whole)]
        }
        // `case X: { … }`: the block is the case's body, at the case's depth.
        let inner = statements(of: node)
        if inner.count == 1, inner[0].node.kind == (language == .go ? "block" : "statement_block") {
            return [head] + renderStatement(inner[0], depth: depth).0
        }
        let body = renderBody(node, depth: depth + 1)
        if body.rows.isEmpty { return [Row(text: head.text + " …", depth: depth, lines: whole)] }
        if body.rows.count == 1, body.simpleStatements == 1 {
            let text = head.text + " " + body.rows[0].text
            if text.count <= Self.maxLine { return [Row(text: text, depth: depth, lines: whole)] }
        }
        return [head] + body.rows
    }

    func clause(_ node: Node, _ range: Range<Int>, _ edits: [Edit], _ depth: Int) -> Row? {
        let (text, span) = renderSpan(node, range, edits)
        guard !text.isEmpty, let span else { return nil }
        return Row(text: text, depth: depth, lines: line(span.lowerBound)...line(span.upperBound))
    }

    func isBlock(_ node: Node) -> Bool {
        switch language {
        case .rust: node.kind == "block" || node.kind == "match_block"
        case .python: node.kind == "block"
        case .typescript: node.kind == "statement_block" || node.kind == "switch_body"
        case .go: node.kind == "block" || Self.goSwitches.contains(node.kind)
        }
    }

    /// The blocks a statement holds, outermost first, in source order.
    func bodies(of node: Node) -> [Node] {
        var found: [Node] = []
        var stack = Array(node.children.reversed())
        while let next = stack.popLast() {
            if isBlock(next) {
                found.append(next)
                continue
            }
            // An object literal or JSX reads as one line, callbacks and all.
            if language == .typescript, Self.typeScriptOpaque.contains(next.kind) { continue }
            if language == .go, next.kind == "composite_literal" { continue }
            stack.append(contentsOf: next.children.reversed())
        }
        return found
    }

    // MARK: Keep rules

    /// Whether a statement does main work: calls a function of this file,
    /// assigns to a field, awaits, returns (but not an error), yields,
    /// breaks or continues, or sends, writes, spawns or inserts.
    func keeps(_ statement: Node) -> Bool {
        // `if err != nil { … }` handles an error: only its initializer's work counts.
        if let check = errorCheck(statement) { return check.initializer.map(keeps) ?? false }
        let owner = current?.owner
        let receiver = current?.receiver
        var found = false
        forEachNode(in: statement) { node in
            if found { return false }
            if !resolvedCalls(node, owner: owner, receiver: receiver).isEmpty {
                found = true
                return false
            }
            switch language {
            case .rust: found = rustEffect(node)
            case .python: found = pythonEffect(node)
            case .typescript: found = typeScriptEffect(node)
            case .go: found = goEffect(node)
            }
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

    func typeScriptEffect(_ node: Node) -> Bool {
        switch node.kind {
        case "call_expression":
            return calleeName(node).map(isEffectName) ?? false
        case "assignment_expression", "augmented_assignment_expression":
            return node.field("left")?.kind == "member_expression"
        case "await_expression", "yield_expression", "return_statement", "break_statement", "continue_statement":
            return true
        default:
            return false
        }
    }

    func goEffect(_ node: Node) -> Bool {
        switch node.kind {
        case "call_expression":
            return calleeName(node).map(isEffectName) ?? false
        case "assignment_statement":
            return node.field("left")?.namedChildren.contains { $0.kind == "selector_expression" } ?? false
        case "inc_statement", "dec_statement":
            return node.namedChildren.first?.kind == "selector_expression"
        case "go_statement", "defer_statement", "send_statement", "break_statement", "continue_statement":
            return true
        case "return_statement":
            return !returnsOnlyAnError(node)
        default:
            return false
        }
    }

    /// `return err`, `return nil, errClosed`, `return nil, fmt.Errorf(…)`:
    /// an error after zero values.
    func returnsOnlyAnError(_ node: Node) -> Bool {
        guard let values = node.namedChildren.first(where: { $0.kind == "expression_list" })?.namedChildren
            .filter({ !isComment($0) }), let last = values.last
        else { return false }
        let error: Bool
        switch last.kind {
        case "identifier":
            let name = text(last).lowercased()
            error = name.hasPrefix("err") || name.hasSuffix("err")
        case "call_expression":
            let callee = last.field("function").map(text) ?? ""
            error = callee == "fmt.Errorf" || callee.hasPrefix("errors.")
        default:
            error = false
        }
        let zeros: Set<String> = ["nil", "0", "\"\"", "false"]
        return error && values.dropLast().allSatisfy { value in
            zeros.contains(text(value)) || (value.kind == "composite_literal"
                && value.field("body").map { $0.namedChildren.filter { !isComment($0) }.isEmpty } ?? false)
        }
    }

    /// `if err != nil { … return … }` with no `else`; its initializer if it has one.
    func errorCheck(_ node: Node) -> (initializer: Node?, Void)? {
        guard language == .go, node.kind == "if_statement", node.field("alternative") == nil,
              let condition = node.field("condition"),
              text(condition).filter({ !$0.isWhitespace }) == "err!=nil",
              let consequence = node.field("consequence"),
              statements(of: consequence).last?.node.kind == "return_statement"
        else { return nil }
        let initializer = node.field("initializer")
        if let initializer, initializer.kind != "short_var_declaration" && initializer.kind != "assignment_statement" {
            return nil
        }
        return (initializer, ())
    }

    /// `x, err := f()` reads as `x := f()`, `err = f()` as `f()`: the
    /// error is checked by the next statement.
    func errorBinding(_ node: Node) -> [Edit] {
        guard ["short_var_declaration", "assignment_statement"].contains(node.kind),
              let left = node.field("left"), let right = node.field("right")
        else { return [] }
        let names = left.namedChildren.filter { !isComment($0) }
        guard let last = names.last, last.kind == "identifier", text(last) == "err" else { return [] }
        if node.kind == "assignment_statement", node.field("operator").map(text) != "=" { return [] }
        // `_, err := f()` reads as `f()` too.
        return names.dropLast().allSatisfy({ text($0) == "_" }) ? [Edit(range: node.start..<right.start)]
            : [Edit(range: names[names.count - 2].end..<last.end)]
    }

    func isEffectName(_ name: String) -> Bool {
        // Go exports `Write` and `Send`.
        let name = language == .go ? name.prefix(1).lowercased() + name.dropFirst() : name
        return Self.effectNames.contains(name) || name.hasPrefix("write")
    }

    func calleeName(_ call: Node) -> String? {
        guard var callee = call.field("function") else { return nil }
        if callee.kind == "generic_function", let inner = callee.field("function") { callee = inner }
        switch callee.kind {
        case "identifier": return text(callee)
        case "scoped_identifier": return callee.field("name").map(text)
        case "field_expression": return callee.field("field").map(text)
        case "attribute": return callee.field("attribute").map(text)
        case "member_expression": return callee.field("property").map(text)
        case "selector_expression": return callee.field("field").map(text)
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
        let noise = language == .typescript ? Self.typeScriptNoiseMethods : language == .go ? [] : Self.noiseMethods
        guard call.kind == "call_expression", let function = call.field("function"),
              let (value, field) = member(function), noise.contains(text(field)),
              let arguments = call.field("arguments"), arguments.namedChildren.isEmpty
        else { return nil }
        return Edit(range: value.end..<call.end)
    }

    /// The receiver and name of `a.b`: a Rust field or a TypeScript member expression.
    func member(_ node: Node) -> (Node, Node)? {
        let fields = switch node.kind {
        case "field_expression": ("value", "field")
        case "member_expression": ("object", "property")
        case "selector_expression": ("operand", "field")
        default: ("", "")
        }
        guard !fields.0.isEmpty, let receiver = node.field(fields.0), let name = node.field(fields.1) else { return nil }
        return (receiver, name)
    }

    /// A chain of three or more method calls keeps its first call and `…`.
    func chain(_ call: Node) -> Edit? {
        var links = 0
        var first = call
        var node = call
        while node.kind == "call_expression", var function = node.field("function") {
            if function.kind == "generic_function", let inner = function.field("function") { function = inner }
            guard var receiver = member(function)?.0 else { break }
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
        if language == .python {
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
        if language == .typescript { return typeScriptSignature(function) }
        if language == .go { return goSignature(function) }
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

    /// `function name(params): R`, `static get name(params): R`,
    /// `const name = (params): R =>`: parameters without types or modifiers,
    /// no `async`, `export`, accessibility or `readonly`.
    func typeScriptSignature(_ function: SkeletonFunction) -> String {
        let node = function.node
        var callable = node
        var text: String
        switch node.kind {
        case "lexical_declaration", "variable_declaration":
            callable = node.namedChildren.first { $0.kind == "variable_declarator" }.flatMap(functionValue) ?? node
            text = (node.children.first.map(self.text) ?? "const") + " " + function.name + " = "
        case "method_definition", "public_field_definition":
            text = ""
            let name = node.field("name")?.start ?? node.end
            for child in node.children where child.start < name {
                if ["static", "get", "set"].contains(child.kind) { text += self.text(child) + " " }
                if child.kind == "*" { text += "*" }
            }
            text += function.name
            if node.kind == "public_field_definition" {
                callable = functionValue(node) ?? node
                text += " = "
            }
        default:
            text = "function" + (node.kind == "generator_function_declaration" ? "* " : " ") + function.name
        }
        if callable.kind == "function_expression" {
            text += "function" + (callable.children.contains { $0.kind == "*" } ? "*" : "")
                + (callable.field("name").map { " " + self.text($0) } ?? "")
        }
        if let generics = callable.field("type_parameters") { text += render(generics, generics.start..<generics.end, []) }
        if let single = callable.field("parameter") {
            text += inline(single)
        } else {
            let parameters = callable.field("parameters")?.namedChildren.compactMap { parameter -> String? in
                switch parameter.kind {
                case "required_parameter", "optional_parameter":
                    guard let pattern = parameter.field("pattern") ?? parameter.field("name"), pattern.kind != "this"
                    else { return nil }
                    return inline(pattern) + (parameter.field("value").map { " = " + inline($0) } ?? "")
                case "comment": return nil
                default: return inline(parameter)
                }
            } ?? []
            text += "(" + parameters.joined(separator: ", ") + ")"
        }
        if let result = callable.field("return_type") { text += render(result, result.start..<result.end, []) }
        if callable.kind == "arrow_function" { text += " =>" }
        return fitted(text)
    }

    /// `func Name(params) R`: no receiver or type parameters, parameter
    /// names without types; the result as written.
    func goSignature(_ function: SkeletonFunction) -> String {
        let node = function.node
        let parameters = node.field("parameters")?.namedChildren.flatMap { parameter -> [String] in
            guard parameter.kind == "parameter_declaration" || parameter.kind == "variadic_parameter_declaration"
            else { return [] }
            let names = parameter.namedChildren.filter { $0.kind == "identifier" }.map(text)
            // An unnamed parameter is its type.
            return names.isEmpty ? parameter.field("type").map { [inline($0)] } ?? [] : names
        } ?? []
        var text = "func " + function.name + "(" + parameters.joined(separator: ", ") + ")"
        if let result = node.field("result") { text += " " + inline(result) }
        return fitted(text)
    }

    func helperRow(_ function: SkeletonFunction) -> Row {
        if language == .typescript, function.body.kind != "statement_block" {
            return Row(text: fitted(signature(function) + " " + inline(function.body)), depth: 0, lines: function.lines)
        }
        return Row(text: signature(function) + (braces ? " { … }" : " …"), depth: 0, lines: function.lines)
    }

    func typeRow(_ node: Node) -> Row {
        let lines = line(node.start)...line(node.end - 1)
        let name = node.field("name").map(text) ?? ""
        if language == .python {
            let bases = node.field("superclasses").map(inline) ?? ""
            return Row(text: "class " + name + bases + ":", depth: 0, lines: lines)
        }
        if language == .go { return goTypeRow(node, name: name, lines: lines) }
        var text: String
        let children: [Node]
        switch node.kind {
        case "class_declaration", "abstract_class_declaration":
            let heritage = node.namedChildren.first { $0.kind == "class_heritage" }.map { " " + inline($0) } ?? ""
            let keyword = node.kind == "class_declaration" ? "class " : "abstract class "
            return Row(text: fitted(keyword + name + heritage), depth: 0, lines: lines)
        case "interface_declaration", "enum_declaration":
            text = (node.kind == "enum_declaration" ? "enum " : "interface ") + name
            children = node.field("body")?.namedChildren ?? []
        case "type_alias_declaration":
            guard let value = node.field("value"), value.kind == "object_type" else {
                return Row(text: "type " + name, depth: 0, lines: lines)
            }
            text = "type " + name + " ="
            children = value.namedChildren
        default:
            text = (node.kind == "enum_item" ? "enum" : "struct") + " " + name
            children = node.field("body")?.namedChildren ?? []
        }
        let memberKinds: Set<String> = [
            "field_declaration", "enum_variant", "property_signature", "method_signature", "enum_assignment",
        ]
        let members = children.compactMap { member -> String? in
            if memberKinds.contains(member.kind) { return member.field("name").map(self.text) }
            // A plain TypeScript enum member is its name.
            return node.kind == "enum_declaration" && !isComment(member) ? self.text(member) : nil
        }
        return Row(text: listing(text, members), depth: 0, lines: lines)
    }

    /// `head { a, b, … }`, within `maxLine` columns; `head` alone without members.
    func listing(_ head: String, _ members: [String]) -> String {
        guard !members.isEmpty else { return head }
        var text = head + " {"
        for (index, member) in members.enumerated() {
            let piece = (index == 0 ? " " : ", ") + member
            if text.count + piece.count + 2 > Self.maxLine {
                text += ", …"
                break
            }
            text += piece
        }
        return text + " }"
    }

    /// `type Name struct { fields }`, `type Name interface { methods }`,
    /// any other type `type Name`. Embedded types by their base name.
    func goTypeRow(_ spec: Node, name: String, lines: ClosedRange<Int>) -> Row {
        // A spec inside `type ( … )` has no `type` on its own line.
        let lineStart = bytes[..<spec.start].lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
        let before = String(decoding: bytes[lineStart..<spec.start], as: UTF8.self).trimmedSpaces()
        let head = (before == "type" ? "type " : "") + name
        guard spec.kind == "type_spec", let type = spec.field("type"),
              type.kind == "struct_type" || type.kind == "interface_type"
        else { return Row(text: head, depth: 0, lines: lines) }
        let keyword = type.kind == "struct_type" ? " struct" : " interface"
        let list = type.kind == "struct_type" ? type.namedChildren.first { $0.kind == "field_declaration_list" } : type
        let members = (list?.namedChildren ?? []).flatMap { member -> [String] in
            switch member.kind {
            case "field_declaration":
                let names = member.namedChildren.filter { $0.kind == "field_identifier" }.map(text)
                return names.isEmpty ? member.field("type").map { [embeddedName($0)] } ?? [] : names
            case "method_elem":
                return member.field("name").map { [text($0)] } ?? []
            case "type_elem":
                let inner = member.namedChildren.filter { !isComment($0) }
                return [inner.count == 1 ? embeddedName(inner[0]) : inline(member)]
            default:
                return []
            }
        }
        return Row(text: listing(head + keyword, members), depth: 0, lines: lines)
    }

    /// An embedded type by its base name; a type with no name (`struct { … }`) on one line.
    func embeddedName(_ type: Node) -> String {
        let name = baseTypeName(type)
        return name.contains { $0.isWhitespace } ? inline(type) : name
    }

    func inline(_ node: Node) -> String {
        render(node, node.start..<node.end, noiseEdits(in: node))
    }

    func noiseEdits(in node: Node) -> [Edit] {
        switch language {
        case .rust: rustEdits(in: node)
        case .python: []
        case .typescript: typeScriptEdits(in: node)
        case .go: goEdits(in: node)
        }
    }

    /// `&x` reads as `x`; a chain of three or more calls keeps its first.
    func goEdits(in root: Node) -> [Edit] {
        var edits: [Edit] = []
        forEachNode(in: root) { node in
            if node.kind == "unary_expression", node.field("operator").map(text) == "&",
               let operand = node.field("operand") {
                edits.append(Edit(range: node.start..<operand.start))
            } else if node.kind == "call_expression", let edit = chain(node) {
                edits.append(edit)
            }
            return true
        }
        return edits
    }

    /// Deletions that strip types and `async`/`await` from a TypeScript statement.
    func typeScriptEdits(in root: Node) -> [Edit] {
        var keptAwait: Int?
        if root.kind == "expression_statement", let awaited = root.namedChildren.first,
           awaited.kind == "await_expression", awaited.namedChildren.first?.kind == "identifier" {
            keptAwait = awaited.start
        }
        var edits: [Edit] = []
        forEachNode(in: root) { node in
            // `(await x)` reads as `x`: an await's operand never needs the
            // parentheses. A statement's own condition keeps them.
            if !["if_statement", "while_statement", "do_statement", "switch_statement"].contains(node.kind) {
                for child in node.namedChildren where child.kind == "parenthesized_expression" {
                    let inner = child.namedChildren.filter { !isComment($0) }
                    guard inner.count == 1, inner[0].kind == "await_expression", inner[0].start != keptAwait,
                          child.end - child.start >= 2
                    else { continue }
                    edits.append(Edit(range: child.start..<(child.start + 1)))
                    edits.append(Edit(range: (child.end - 1)..<child.end))
                }
            }
            switch node.kind {
            case "type_annotation", "type_arguments", "asserts_annotation", "type_predicate_annotation":
                edits.append(Edit(range: node.start..<node.end))
                return false
            case "as_expression", "satisfies_expression", "non_null_expression":
                if let inner = node.namedChildren.first { edits.append(Edit(range: inner.end..<node.end)) }
            case "await_expression":
                if node.start != keptAwait, let inner = node.namedChildren.first {
                    edits.append(Edit(range: node.start..<inner.start))
                }
            case "arrow_function", "function_expression", "for_in_statement":
                edits += node.children.filter { $0.kind == "async" || $0.kind == "await" }.map { Edit(range: $0.start..<spaceEnd($0.end)) }
            case "optional_parameter":
                edits += node.children.filter { $0.kind == "?" }.map { Edit(range: $0.start..<$0.end) }
            case "call_expression":
                if let edit = noiseCall(node) ?? chain(node) { edits.append(edit) }
            default:
                break
            }
            return true
        }
        return edits
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
                    } else if newline, "([".utf8.contains(last) || joinsTight(piece) {
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
        let text = String(decoding: out, as: UTF8.self).trimmedSpaces()
        return (fitted(text), span)
    }

    /// TypeScript object literals and JSX, and Go composite literals, join into long lines: past
    /// `maxLine` columns the text is cut at a word boundary and ends in `…`.
    func fitted(_ text: String) -> String {
        guard language == .typescript || language == .go, text.count > Self.maxLine else { return text }
        var cut = Substring(text.prefix(Self.maxLine - 3))
        func isWord(_ character: Character?) -> Bool {
            character?.unicodeScalars.first.map(Scalars.isWord) ?? false
        }
        // Half an identifier is not in the source.
        if isWord(text.dropFirst(cut.count).first) {
            while isWord(cut.last) { cut = cut.dropLast() }
        }
        return String(cut).trimmedSpaces() + "…"
    }

    /// A piece that follows a line break with no space: a closing bracket, a
    /// separator, a method on its own line (Rust also `?`; not TypeScript's
    /// ternary `?` or spread `...`).
    func joinsTight(_ piece: [UInt8]) -> Bool {
        guard language == .typescript else { return ")].?,;".utf8.contains(piece[0]) }
        return ")],;".utf8.contains(piece[0]) || (piece[0] == UInt8(ascii: ".") && !piece.starts(with: "...".utf8))
    }

    /// A leaf's bytes; a string over several lines keeps its first line.
    func leaf(_ node: Node) -> [UInt8] {
        let piece = bytes[node.start..<node.end]
        guard let newline = piece.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) else { return Array(piece) }
        var closing = node.end
        let closers = language == .typescript || language == .go ? "\"'`" : "\"'#"
        while closing > newline, closers.utf8.contains(bytes[closing - 1]) { closing -= 1 }
        var head = Array(bytes[node.start..<newline])
        while let last = head.last, isSpace(last) { head.removeLast() }
        return head + Array("…".utf8) + Array(bytes[closing..<node.end])
    }

    func isAtomic(_ kind: String) -> Bool {
        switch language {
        case .rust: ["string_literal", "raw_string_literal", "char_literal"].contains(kind)
        case .python: kind == "string"
        case .typescript: kind == "string" || kind == "template_string"
        case .go: ["interpreted_string_literal", "raw_string_literal", "rune_literal"].contains(kind)
        }
    }

    func isComment(_ node: Node) -> Bool {
        language == .rust ? node.kind == "line_comment" || node.kind == "block_comment" : node.kind == "comment"
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
        case "qualified_type" where language == .go: return type.field("name").map(text) ?? text(type)
        case "pointer_type" where language == .go: return type.namedChildren.first.map(baseTypeName) ?? text(type)
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
