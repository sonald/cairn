import CTreeSitterGo
import CodeInsightCore
import Foundation
import TreeSitterKit

/// The 25 Go keywords. `true`, `nil`, `iota`, builtin types and functions are
/// predeclared identifiers: they highlight by role but stay selectable.
private let goKeywords: Set<String> = [
    "break", "case", "chan", "const", "continue", "default", "defer", "else",
    "fallthrough", "for", "func", "go", "goto", "if", "import", "interface",
    "map", "package", "range", "return", "select", "struct", "switch", "type", "var",
]

func goReaderIsKeyword(_ value: String) -> Bool {
    goKeywords.contains(value)
}

func goReaderHighlightWithFolds(
    bytes: [UInt8],
    shouldCancel: (() -> Bool)? = nil
) throws -> (
    spans: [HighlightSpan],
    outlineFacets: [OutlineFacet],
    folds: [FoldRegion],
    bindings: [BindingRecord],
    referencesByBinding: [[CodeInsightCore.ByteRange]]
) {
    guard
        let language = tree_sitter_go(),
        let parser = Parser(language: language)
    else { throw ReaderSyntaxError.parserUnavailable }
    let tree = try parseReaderTree(parser, bytes, shouldCancel: shouldCancel)

    var walk = GoReaderWalk(bytes: bytes)
    walk.visit(tree.rootNode, role: nil, owner: nil, depth: 0, foldDepth: 0, inFunction: false)
    try checkReaderCancellation(shouldCancel)
    let folds = walk.candidates.resolve(
        outlineFacets: walk.facets,
        observer: nil as (@Sendable (Double, Int, Int) -> Void)?
    )
    let references = goLocalReferences(in: tree, bytes: bytes)
    try checkReaderCancellation(shouldCancel)
    var spans = walk.spans
    appendLocalBindingHighlights(
        bindings: references.bindings,
        referencesByBinding: references.referencesByBinding,
        spans: &spans
    )
    spans.sort {
        ($0.range.lowerBound, $0.range.upperBound, $0.kind.rawValue)
            < ($1.range.lowerBound, $1.range.upperBound, $1.kind.rawValue)
    }
    return (spans, walk.facets, folds, references.bindings, references.referencesByBinding)
}

/// Where a body's fold header starts, what kind of fold it is and the fold
/// depth of its declaration or statement, passed to the child holding the
/// braces so top-level functions, types and groups share one depth.
private typealias FoldOwner = (headerStart: UInt32, kind: FoldKind, depth: Int)

/// One recursive pass for spans, outline facets and fold candidates; it runs
/// on `DocumentLoader`'s large-stack thread like the Python and TypeScript walks.
private struct GoReaderWalk {
    let bytes: [UInt8]
    var spans: [HighlightSpan] = []
    var facets: [OutlineFacet] = []
    var candidates = FoldCandidateAccumulator()

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func visit(
        _ node: Node,
        role: HighlightKind?,
        owner: FoldOwner?,
        depth: Int,
        foldDepth: Int,
        inFunction: Bool
    ) {
        let kind = node.kind
        if let region = contentRegionKind(nodeKind: kind, language: .go) {
            emit(node, region == .comment ? .comment : .string)
            if region == .comment { foldBlockComment(node, foldDepth: owner?.depth ?? foldDepth) }
            return
        }
        switch kind {
        case "identifier", "field_identifier", "type_identifier", "package_identifier":
            let fallback: HighlightKind? = switch kind {
            case "field_identifier": .property
            case "type_identifier": .typeName
            case "package_identifier": .declarationEmphasis
            default: nil
            }
            if let highlight = role ?? fallback { emit(node, highlight) }
            return
        case "int_literal", "float_literal", "imaginary_literal":
            emit(node, .number)
            return
        case "true", "false", "nil", "iota":
            emit(node, .keyword)
            return
        default:
            if !node.isNamed {
                if goKeywords.contains(kind) { emit(node, .keyword) }
                return
            }
        }

        // Whatever lies inside a fold sits one level deeper, so the topology stays a tree.
        let childFoldDepth = visitFold(node, owner: owner, foldDepth: foldDepth).map { $0 + 1 } ?? foldDepth
        if !inFunction { appendFacets(node, depth: depth) }

        let named = node.namedChildren
        if named.count >= 2 {
            candidates.appendRuns(
                in: named, matching: { $0.kind == "comment" },
                kind: .comment, foldDepth: childFoldDepth, bytes: bytes
            )
            if kind == "source_file" {
                candidates.appendRuns(
                    in: named, matching: { $0.kind == "import_declaration" },
                    kind: .imports, foldDepth: childFoldDepth, bytes: bytes
                )
            }
        }

        let nameRange = node.child(namedField: "name")?.byteRange
        let functionRange = kind == "call_expression"
            ? node.child(namedField: "function")?.byteRange : nil
        let fieldRange = kind == "selector_expression"
            ? node.child(namedField: "field")?.byteRange : nil
        let bodyRange = node.child(namedField: "body")?.byteRange
        let consequenceRange = kind == "if_statement"
            ? node.child(namedField: "consequence")?.byteRange : nil
        let alternative = kind == "if_statement" ? node.child(namedField: "alternative") : nil
        let typeRange = node.child(namedField: "type")?.byteRange
        let singleType = kind == "type_declaration" && isSingleSpec(node)
        var elseStart: UInt32?
        var previousNamedKind: String?
        let childDepth = depth + (kind == "struct_type" || kind == "interface_type" ? 1 : 0)
        for index in 0..<node.childCount {
            guard let child = node.child(at: index) else { continue }
            let range = child.byteRange
            if child.kind == "else" { elseStart = range.lowerBound }
            let isName = range == nameRange
            let childRole: HighlightKind?
            switch kind {
            case "function_declaration", "method_declaration", "method_elem":
                childRole = isName ? .functionName : nil
            case "type_spec", "type_alias":
                childRole = isName ? .declarationTitle : nil
            case "const_spec", "var_spec":
                childRole = !inFunction && child.kind == "identifier" ? .declarationEmphasis : nil
            case "type_parameter_declaration":
                childRole = child.kind == "identifier" ? .typeName : nil
            case "call_expression":
                childRole = range == functionRange ? .functionCall : nil
            case "selector_expression":
                childRole = range == fieldRange ? role : nil
            case "parenthesized_expression":
                childRole = role
            default:
                childRole = nil
            }
            var childOwner: FoldOwner?
            switch kind {
            case "function_declaration", "method_declaration", "func_literal":
                childOwner = range == bodyRange ? (node.byteRange.lowerBound, .declaration, foldDepth) : nil
            case "for_statement":
                childOwner = range == bodyRange ? (node.byteRange.lowerBound, .block, foldDepth) : nil
            case "if_statement":
                if range == consequenceRange {
                    childOwner = (node.byteRange.lowerBound, .block, foldDepth)
                } else if range == alternative?.byteRange, let elseStart {
                    childOwner = (elseStart, .block, foldDepth)
                } else {
                    childOwner = nil
                }
            case "type_declaration":
                // `type T struct {` folds from `type`; grouped specs fold from their name.
                childOwner = singleType ? (node.byteRange.lowerBound, .container, foldDepth) : nil
            case "type_spec", "type_alias", "field_declaration":
                childOwner = range == typeRange
                    ? (owner?.headerStart ?? node.byteRange.lowerBound, .container, owner?.depth ?? foldDepth) : nil
            case "composite_literal":
                childOwner = range == bodyRange ? (node.byteRange.lowerBound, .block, foldDepth) : nil
            default:
                childOwner = nil
            }
            if child.kind == previousNamedKind, child.kind == "comment" || child.kind == "import_declaration" {
                // Inside a run's body, so its own fold must nest deeper than the run.
                childOwner = (range.lowerBound, .comment, childFoldDepth + 1)
            }
            if child.isNamed { previousNamedKind = child.kind }
            visit(
                child,
                role: childRole,
                owner: childOwner,
                depth: childDepth,
                foldDepth: childFoldDepth,
                inFunction: inFunction || kind == "block"
            )
        }
    }

    private mutating func emit(_ node: Node, _ kind: HighlightKind) {
        let range = coreRange(node)
        guard range.lowerBound < range.upperBound else { return }
        spans.append(HighlightSpan(range: range, kind: kind))
    }

    // MARK: Folds

    /// Appends the candidates `node` owns and returns their fold depth. A body
    /// folds at its owner's depth; the owner itself folds nothing.
    private mutating func visitFold(_ node: Node, owner: FoldOwner?, foldDepth: Int) -> Int? {
        let start = node.byteRange.lowerBound
        let headerStart = owner?.headerStart ?? start
        let ownedDepth = owner?.depth ?? foldDepth
        switch node.kind {
        case "block":
            // Function and statement bodies fold from their owner's header.
            return braced(
                owner?.kind ?? .block, headerStart: headerStart,
                open: node.byteRange.lowerBound, close: node.byteRange.upperBound - 1,
                foldDepth: ownedDepth
            )
        case "literal_value":
            return braced(
                .block, headerStart: headerStart,
                open: node.byteRange.lowerBound, close: node.byteRange.upperBound - 1,
                foldDepth: ownedDepth
            )
        case "struct_type":
            guard let list = node.namedChildren.first(where: { $0.kind == "field_declaration_list" })
            else { return nil }
            return braced(
                .container, headerStart: headerStart,
                open: list.byteRange.lowerBound, close: list.byteRange.upperBound - 1,
                foldDepth: ownedDepth
            )
        case "interface_type":
            guard let braces = delimiters(of: node, open: "{", close: "}") else { return nil }
            return braced(
                .container, headerStart: headerStart,
                open: braces.open, close: braces.close, foldDepth: ownedDepth
            )
        case "expression_switch_statement", "type_switch_statement", "select_statement":
            guard let braces = delimiters(of: node, open: "{", close: "}") else { return nil }
            return braced(.block, headerStart: start, open: braces.open, close: braces.close, foldDepth: foldDepth)
        case "expression_case", "type_case", "communication_case", "default_case":
            var colon: UInt32?
            for index in 0..<node.childCount {
                if let child = node.child(at: index), child.kind == ":" {
                    colon = child.byteRange.upperBound
                    break
                }
            }
            guard let colon else { return nil }
            candidates.appendCandidate(
                kind: .block,
                headerRange: CodeInsightCore.ByteRange(lowerBound: start, upperBound: colon),
                bodyRange: CodeInsightCore.ByteRange(lowerBound: colon, upperBound: node.byteRange.upperBound),
                foldDepth: foldDepth,
                bytes: bytes
            )
            return foldDepth
        case "import_declaration", "const_declaration", "var_declaration", "type_declaration":
            let list = node.namedChildren.first {
                $0.kind == "import_spec_list" || $0.kind == "var_spec_list"
            }
            guard let parens = delimiters(of: list ?? node, open: "(", close: ")") else { return nil }
            // A grouped import inside a run of imports gets a deeper owner depth.
            let depth = owner?.depth ?? foldDepth
            candidates.appendCandidate(
                kind: node.kind == "import_declaration" ? .imports : .container,
                headerRange: CodeInsightCore.ByteRange(lowerBound: start, upperBound: parens.open + 1),
                bodyRange: CodeInsightCore.ByteRange(lowerBound: parens.open + 1, upperBound: parens.close),
                foldDepth: depth,
                bytes: bytes
            )
            return depth
        default:
            return nil
        }
    }

    /// Folds between `{` at `open` and `}` at `close`; the header ends after `{`.
    private mutating func braced(
        _ kind: FoldKind,
        headerStart: UInt32,
        open: UInt32,
        close: UInt32,
        foldDepth: Int
    ) -> Int? {
        guard open < close,
              Int(close) < bytes.count,
              bytes[Int(open)] == UInt8(ascii: "{"),
              bytes[Int(close)] == UInt8(ascii: "}")
        else { return nil }
        candidates.appendCandidate(
            kind: kind,
            headerRange: CodeInsightCore.ByteRange(lowerBound: headerStart, upperBound: open + 1),
            bodyRange: CodeInsightCore.ByteRange(lowerBound: open + 1, upperBound: close),
            foldDepth: foldDepth,
            bytes: bytes
        )
        return foldDepth
    }

    /// A `/* … */` spanning lines folds to its first line.
    private mutating func foldBlockComment(_ node: Node, foldDepth: Int) {
        let lower = Int(node.byteRange.lowerBound)
        let upper = min(Int(node.byteRange.upperBound), bytes.count)
        guard upper - lower > 4, bytes[lower + 1] == UInt8(ascii: "*"),
              let newline = bytes[lower..<upper].firstIndex(of: 0x0A)
        else { return }
        let lineEnd = newline > lower && bytes[newline - 1] == 0x0D ? newline - 1 : newline
        candidates.appendCandidate(
            kind: .comment,
            headerRange: CodeInsightCore.ByteRange(lowerBound: UInt32(lower), upperBound: UInt32(lineEnd)),
            bodyRange: CodeInsightCore.ByteRange(lowerBound: UInt32(newline + 1), upperBound: UInt32(upper)),
            foldDepth: foldDepth,
            bytes: bytes
        )
    }

    /// The first `open` and last `close` token among `node`'s direct children.
    private func delimiters(of node: Node, open: String, close: String) -> (open: UInt32, close: UInt32)? {
        var first: UInt32?
        var last: UInt32?
        for index in 0..<node.childCount {
            guard let child = node.child(at: index) else { continue }
            if first == nil, child.kind == open { first = child.byteRange.lowerBound }
            if child.kind == close { last = child.byteRange.lowerBound }
        }
        guard let first, let last, first < last else { return nil }
        return (first, last)
    }

    /// `type T …` rather than `type ( … )`; `var` keeps its parentheses in a list node.
    private func isSingleSpec(_ declaration: Node) -> Bool {
        !declaration.namedChildren.contains { $0.kind == "var_spec_list" }
            && delimiters(of: declaration, open: "(", close: ")") == nil
    }

    // MARK: Outline

    /// Package-level declarations, struct fields and interface methods, with
    /// the kinds `OutlineKind.init(_:isMethod:)` gives the indexed Go symbols.
    private mutating func appendFacets(_ node: Node, depth: Int) {
        switch node.kind {
        case "function_declaration", "method_declaration":
            appendFacet(
                node.kind == "function_declaration" ? .fn : .method,
                name: node.child(namedField: "name"), range: node, depth: depth,
                detail: signatureDetail(node)
            )
        case "method_elem":
            appendFacet(.method, name: node.child(namedField: "name"), range: node, depth: depth,
                        detail: signatureDetail(node))
        case "field_declaration":
            let names = node.namedChildren.filter { $0.kind == "field_identifier" }
            let type = node.child(namedField: "type")
            if names.isEmpty {
                appendFacet(.field, name: type.flatMap(embeddedTypeName), range: node, depth: depth)
            }
            for name in names {
                appendFacet(.field, name: name, range: node, depth: depth, detail: type.map(text) ?? "")
            }
        case "type_declaration":
            let single = isSingleSpec(node)
            for spec in node.namedChildren where spec.kind == "type_spec" || spec.kind == "type_alias" {
                let type = spec.child(namedField: "type")
                let kind: OutlineKind = switch (spec.kind, type?.kind ?? "") {
                case ("type_spec", "struct_type"): .struct
                case ("type_spec", "interface_type"): .trait
                default: .typeAlias
                }
                let parameters = spec.child(namedField: "type_parameters").map(text) ?? ""
                let detail = kind == .typeAlias
                    ? parameters + (spec.kind == "type_alias" ? " = " : " ") + (type.map(text) ?? "")
                    : parameters
                appendFacet(
                    kind, name: spec.child(namedField: "name"), range: single ? node : spec,
                    depth: depth, detail: detail.trimmingCharacters(in: .whitespaces)
                )
            }
        case "const_declaration", "var_declaration":
            let single = isSingleSpec(node)
            let list = node.namedChildren.first { $0.kind == "var_spec_list" } ?? node
            for spec in list.namedChildren where spec.kind == "const_spec" || spec.kind == "var_spec" {
                let detail = spec.child(namedField: "type").map(text) ?? ""
                for name in spec.namedChildren where name.kind == "identifier" {
                    appendFacet(
                        node.kind == "const_declaration" ? .const : .variable,
                        name: name, range: single ? node : spec, depth: depth, detail: detail
                    )
                }
            }
        default:
            break
        }
    }

    private mutating func appendFacet(
        _ kind: OutlineKind,
        name: Node?,
        range: Node,
        depth: Int,
        detail: String = ""
    ) {
        guard let name, name.byteRange.lowerBound < name.byteRange.upperBound else { return }
        let value = text(name)
        guard !value.isEmpty else { return }
        facets.append(OutlineFacet(
            kind: kind,
            name: value,
            range: coreRange(range),
            nameRange: coreRange(name),
            depth: depth,
            detail: detail.count > 120 ? String(detail.prefix(117)) + "…" : detail
        ))
    }

    /// `[T any](xs []T) error` for functions, methods and interface methods.
    private func signatureDetail(_ node: Node) -> String {
        let parameters = ["type_parameters", "parameters"]
            .compactMap { node.child(namedField: $0).map(text) }.joined()
        guard let result = node.child(namedField: "result") else { return parameters }
        return parameters + " " + text(result)
    }

    /// `*pkg.Base` → `Base`: an embedded field is named by its type.
    private func embeddedTypeName(_ node: Node) -> Node? {
        switch node.kind {
        case "type_identifier": node
        case "qualified_type": node.child(namedField: "name")
        case "generic_type": node.child(namedField: "type").flatMap(embeddedTypeName)
        default: node.namedChildren.last.flatMap(embeddedTypeName)
        }
    }

    private func text(_ node: Node) -> String {
        goText(bytes, node).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

private func goText(_ bytes: [UInt8], _ node: Node) -> String {
    let lower = Int(node.byteRange.lowerBound)
    let upper = min(Int(node.byteRange.upperBound), bytes.count)
    guard lower <= upper else { return "" }
    return String(decoding: bytes[lower..<upper], as: UTF8.self)
}

// MARK: - Local bindings

/// Parameters, receivers, named results and `:=`/`var`/`const`/`range`
/// names inside function bodies. Package-level names are not local.
private func goLocalReferences(
    in tree: Tree,
    bytes: [UInt8]
) -> (
    bindings: [BindingRecord],
    referencesByBinding: [[CodeInsightCore.ByteRange]]
) {
    let names = Interner<NameID>()
    var bindings: [BindingRecord] = []
    var references: [[CodeInsightCore.ByteRange]] = []
    var scopes: [[String: Int]] = [[:]]
    var scopeIDs: [UInt32] = [0]
    var nextScopeID: UInt32 = 1
    /// Per enclosing composite literal: map, slice and array keys are expressions.
    var keysAreExpressions: [Bool] = []

    /// `reusing`: `a, err := f()` assigns an `err` already declared in this scope.
    func declare(_ node: Node, kind: BindingKind, reusing: Bool = false) {
        guard scopes.count > 1, node.kind == "identifier" else { return }
        let name = goText(bytes, node)
        guard name != "_" else { return }
        if reusing, scopes[scopes.count - 1][name] != nil {
            reference(node)
            return
        }
        bindings.append(BindingRecord(
            scopeID: ScopeID(rawValue: scopeIDs[scopeIDs.count - 1]),
            localNameID: names.intern(name),
            space: .value,
            kind: kind,
            declarationRange: coreRange(node),
            targetHint: nil
        ))
        references.append([])
        scopes[scopes.count - 1][name] = bindings.count - 1
    }

    func reference(_ node: Node) {
        let name = goText(bytes, node)
        for scope in scopes.reversed() {
            if let index = scope[name] {
                references[index].append(coreRange(node))
                return
            }
        }
    }

    func scoped(_ body: () -> Void) {
        scopes.append([:])
        scopeIDs.append(nextScopeID)
        nextScopeID += 1
        body()
        scopes.removeLast()
        scopeIDs.removeLast()
    }

    func declareNames(in list: Node?, kind: BindingKind, reusing: Bool = false) {
        for name in list?.namedChildren ?? [] { declare(name, kind: kind, reusing: reusing) }
    }

    func hasShortAssignment(_ node: Node) -> Bool {
        (0..<node.childCount).contains { node.child(at: $0)?.kind == ":=" }
    }

    func visit(_ node: Node) {
        switch node.kind {
        case "function_declaration", "method_declaration", "func_literal":
            scoped {
                for field in ["receiver", "parameters", "result"] {
                    guard let list = node.child(namedField: field), list.kind == "parameter_list" else { continue }
                    for parameter in list.namedChildren {
                        declareNames(in: parameter, kind: .param)
                    }
                }
                if let body = node.child(namedField: "body") { visit(body) }
            }
        case "block", "if_statement", "for_statement", "expression_switch_statement",
             "select_statement", "expression_case", "type_case", "communication_case", "default_case":
            scoped { node.namedChildren.forEach(visit) }
        case "type_switch_statement":
            scoped {
                if let initializer = node.child(namedField: "initializer") { visit(initializer) }
                if let value = node.child(namedField: "value") { visit(value) }
                declareNames(in: node.child(namedField: "alias"), kind: .letBinding)
                for clause in node.namedChildren where clause.kind.hasSuffix("_case") { visit(clause) }
            }
        case "short_var_declaration":
            if let right = node.child(namedField: "right") { visit(right) }
            declareNames(in: node.child(namedField: "left"), kind: .letBinding, reusing: true)
        case "range_clause", "receive_statement":
            if let right = node.child(namedField: "right") { visit(right) }
            if let left = node.child(namedField: "left") {
                if hasShortAssignment(node) {
                    declareNames(in: left, kind: .letBinding)
                } else {
                    visit(left)
                }
            }
        case "var_spec", "const_spec":
            if let value = node.child(namedField: "value") { visit(value) }
            for name in node.namedChildren where name.kind == "identifier" {
                declare(name, kind: .letBinding)
            }
        case "composite_literal":
            let type = node.child(namedField: "type")
            if let type { visit(type) }
            keysAreExpressions.append(
                ["map_type", "slice_type", "array_type", "implicit_length_array_type"].contains(type?.kind ?? "")
            )
            if let body = node.child(namedField: "body") { visit(body) }
            keysAreExpressions.removeLast()
        case "literal_element" where node.namedChildren.first?.kind == "literal_value":
            // ponytail: an elided inner type (`map[K]T{k: {Name: v}}`) is read as a struct.
            keysAreExpressions.append(false)
            node.namedChildren.forEach(visit)
            keysAreExpressions.removeLast()
        case "keyed_element":
            // A bare `Name:` key of a struct literal names a field, not a local.
            if let key = node.child(namedField: "key"),
               keysAreExpressions.last == true
                || !(key.namedChildren.count == 1 && key.namedChildren[0].kind == "identifier")
            {
                visit(key)
            }
            if let value = node.child(namedField: "value") { visit(value) }
        case "parameter_list", "type_parameter_list":
            // Names in function types and type parameter lists are not locals.
            return
        case "identifier":
            reference(node)
        default:
            node.namedChildren.forEach(visit)
        }
    }

    visit(tree.rootNode)
    return (bindings, references)
}
