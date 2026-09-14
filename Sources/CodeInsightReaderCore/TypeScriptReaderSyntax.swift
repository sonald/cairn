import CTreeSitterTypeScript
import CodeInsightCore
import CodeInsightTypeScriptExtractor
import Foundation
import TreeSitterKit

private let typeScriptKeywords: Set<String> = [
    "abstract", "as", "async", "await", "break", "case", "catch", "class",
    "const", "continue", "debugger", "default", "delete", "do", "else", "enum",
    "export", "extends", "finally", "for", "from", "function", "get", "if",
    "implements", "import", "in", "instanceof", "interface", "keyof", "let",
    "module", "namespace", "new", "of", "private", "protected", "public",
    "readonly", "return", "satisfies", "set", "static", "super", "switch",
    "throw", "type", "typeof", "var", "void", "while", "with", "yield",
]

func typeScriptReaderIsKeyword(_ value: String) -> Bool {
    typeScriptKeywords.contains(value)
}

func typeScriptReaderHighlightWithFolds(
    bytes: [UInt8],
    mode: LanguageMode
) throws -> (
    spans: [HighlightSpan],
    outlineFacets: [OutlineFacet],
    folds: [FoldRegion],
    bindings: [BindingRecord],
    referencesByBinding: [[CodeInsightCore.ByteRange]]
) {
    try requireSupportedTypeScriptReaderMode(mode)
    try requireSupportedTypeScriptBytes(bytes)
    guard
        let language = typeScriptGrammar(for: mode),
        let parser = Parser(language: language)
    else { throw RustHighlighterError.parserUnavailable }
    #if DEBUG
    TypeScriptExtractor.parseObserver?()
    #endif
    guard let tree = parser.parse(bytes) else {
        throw RustHighlighterError.parseFailed
    }

    var spans: [HighlightSpan] = []
    var facets: [OutlineFacet] = []
    var candidates = FoldCandidateAccumulator()
    typeScriptWalk(
        tree.rootNode,
        bytes: bytes,
        depth: 0,
        spans: &spans,
        facets: &facets,
        candidates: &candidates
    )
    let folds = candidates.resolve(
        outlineFacets: facets,
        observer: nil as (@Sendable (Double, Int, Int) -> Void)?
    )
    let references = typeScriptLocalReferences(in: tree, bytes: bytes)
    appendLocalBindingHighlights(
        bindings: references.bindings,
        referencesByBinding: references.referencesByBinding,
        spans: &spans
    )
    spans.sort {
        ($0.range.lowerBound, $0.range.upperBound, $0.kind.rawValue)
            < ($1.range.lowerBound, $1.range.upperBound, $1.kind.rawValue)
    }
    return (spans, facets, folds, references.bindings, references.referencesByBinding)
}

func requireSupportedTypeScriptReaderMode(_ mode: LanguageMode) throws {
    guard mode.language == .typescript,
          mode.variant == nil || mode.variant == "tsx"
    else {
        throw RustHighlighterError.unsupportedLanguage(mode.language)
    }
}

private func requireSupportedTypeScriptBytes(_ bytes: [UInt8]) throws {
    if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
        throw CocoaError(.fileReadCorruptFile)
    }
    guard String(bytes: bytes, encoding: .utf8) != nil else {
        throw CocoaError(.fileReadCorruptFile)
    }
}

private func typeScriptGrammar(for mode: LanguageMode) -> OpaquePointer? {
    mode.variant == "tsx" ? tree_sitter_tsx() : tree_sitter_typescript()
}

private func typeScriptTokenKind(_ node: Node) -> HighlightKind? {
    switch node.kind {
    case "comment": return .comment
    case "string", "regex", "string_fragment", "escape_sequence", "`": return .string
    case "number": return .number
    case "true", "false", "null", "undefined": return .keyword
    case "type_identifier", "predefined_type": return .typeName
    case "property_identifier", "private_property_identifier": return .property
    default:
        return !node.isNamed && typeScriptKeywords.contains(node.kind) ? .keyword : nil
    }
}

private func typeScriptWalk(
    _ node: Node,
    bytes: [UInt8],
    depth: Int,
    role: HighlightKind? = nil,
    spans: inout [HighlightSpan],
    facets: inout [OutlineFacet],
    candidates: inout FoldCandidateAccumulator
) {
    if let kind = role, node.kind == "identifier"
        || node.kind == "property_identifier" || node.kind == "private_property_identifier"
    {
        spans.append(HighlightSpan(range: coreRange(node), kind: kind))
        return
    }
    if let kind = typeScriptTokenKind(node) {
        spans.append(HighlightSpan(range: coreRange(node), kind: kind))
        return
    }
    visitTypeScriptFoldCandidate(
        node: node,
        foldDepth: depth,
        bytes: bytes,
        candidates: &candidates
    )
    switch node.kind {
    case "function_declaration", "generator_function_declaration":
        appendTypeScriptDeclaration(
            function: node,
            bytes: bytes,
            depth: depth,
            kind: .fn,
            spans: &spans,
            facets: &facets
        )
    case "class_declaration":
        appendTypeScriptDeclaration(
            function: node,
            bytes: bytes,
            depth: depth,
            kind: .class,
            spans: &spans,
            facets: &facets
        )
    case "method_definition":
        appendTypeScriptDeclaration(
            function: node,
            bytes: bytes,
            depth: depth,
            kind: .method,
            spans: &spans,
            facets: &facets
        )
    case "public_field_definition":
        appendTypeScriptDeclaration(
            function: node, bytes: bytes, depth: depth, kind: .field,
            spans: &spans, facets: &facets
        )
    case "enum_declaration":
        appendTypeScriptDeclaration(
            function: node, bytes: bytes, depth: depth, kind: .enum,
            spans: &spans, facets: &facets
        )
    case "enum_body":
        for member in node.namedChildren where member.kind != "comment" {
            let nameNode = member.kind == "enum_assignment"
                ? member.child(namedField: "name") : member
            guard let nameNode,
                  let name = typeScriptText(bytes, range: coreRange(nameNode))
            else { continue }
            facets.append(OutlineFacet(
                kind: .enumMember, name: name, range: coreRange(member),
                nameRange: coreRange(nameNode), depth: depth
            ))
        }
    case "lexical_declaration", "variable_declaration":
        appendTypeScriptVariableArrowFunctionFacet(
            node,
            bytes: bytes,
            depth: depth,
            spans: &spans,
            facets: &facets
        )
    default:
        break
    }

    for index in 0..<node.childCount {
        guard let child = node.child(at: index) else { continue }
        if ["function_declaration", "generator_function_declaration", "class_declaration",
            "method_definition", "public_field_definition", "enum_declaration"].contains(node.kind),
           child.byteRange == node.child(namedField: "name")?.byteRange,
           child.kind != "computed_property_name"
        { continue }
        let isBody = node.kind == "function_declaration"
            || node.kind == "generator_function_declaration"
            || node.kind == "method_definition"
        let childDepth = isBody
            && node.child(namedField: "body")?.byteRange == child.byteRange
            ? depth + 1
            : depth + (node.kind == "class_declaration" || node.kind == "enum_declaration" ? 1 : 0)
        let childRole: HighlightKind?
        switch node.kind {
        case "decorator": childRole = .attribute
        case "parenthesized_expression": childRole = role
        case "call_expression":
            childRole = child.byteRange == node.child(namedField: "function")?.byteRange
                ? (role ?? .functionCall) : nil
        case "member_expression":
            childRole = child.byteRange == node.child(namedField: "property")?.byteRange
                ? (role ?? .property) : nil
        case "enum_body": childRole = .enumMember
        case "enum_assignment":
            childRole = child.byteRange == node.child(namedField: "name")?.byteRange
                ? .enumMember : nil
        default: childRole = nil
        }
        typeScriptWalk(
            child,
            bytes: bytes,
            depth: childDepth,
            role: childRole,
            spans: &spans,
            facets: &facets,
            candidates: &candidates
        )
    }
}

private func appendTypeScriptDeclaration(
    function node: Node,
    bytes: [UInt8],
    depth: Int,
    kind: OutlineKind,
    spans: inout [HighlightSpan],
    facets: inout [OutlineFacet]
) {
    guard let nameNode = node.child(namedField: "name"),
          let name = typeScriptText(bytes, range: coreRange(nameNode))
    else { return }
    let nameRange = coreRange(nameNode)
    if nameNode.kind != "computed_property_name" {
        let highlight: HighlightKind = kind == .field ? .property
            : (kind == .class || kind == .enum ? .declarationTitle : .functionName)
        spans.append(HighlightSpan(range: nameRange, kind: highlight))
    }
    facets.append(OutlineFacet(
        kind: kind,
        name: name,
        range: coreRange(node),
        nameRange: nameRange,
        depth: depth,
        detail: typeScriptDeclarationDetail(node, bytes: bytes)
    ))
}

private func appendTypeScriptVariableArrowFunctionFacet(
    _ node: Node,
    bytes: [UInt8],
    depth: Int,
    spans: inout [HighlightSpan],
    facets: inout [OutlineFacet]
) {
    for declarator in node.namedChildren
        where declarator.kind == "variable_declarator"
    {
        guard let nameNode = declarator.child(namedField: "name"),
              let name = typeScriptText(bytes, range: coreRange(nameNode)),
              let value = declarator.child(namedField: "value"),
              value.kind == "arrow_function"
                || value.kind == "function_expression",
              value.child(namedField: "body")?.kind == "statement_block"
        else { continue }
        let nameRange = coreRange(nameNode)
        spans.append(HighlightSpan(range: nameRange, kind: .functionName))
        facets.append(OutlineFacet(
            kind: .fn,
            name: name,
            range: coreRange(value),
            nameRange: nameRange,
            depth: depth,
            detail: typeScriptDeclarationDetail(value, bytes: bytes)
        ))
    }
}

private func typeScriptDeclarationDetail(_ node: Node, bytes: [UInt8]) -> String {
    let fields = ["type_parameters", "parameters", "parameter", "return_type", "type"]
    return fields.compactMap { node.child(namedField: $0) }
        .compactMap { typeScriptText(bytes, range: coreRange($0)) }
        .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        .joined()
}

private func visitTypeScriptFoldCandidate(
    node: Node,
    foldDepth: Int,
    bytes: [UInt8],
    candidates: inout FoldCandidateAccumulator
) {
    switch node.kind {
    case "function_declaration", "generator_function_declaration",
         "method_definition", "class_declaration", "arrow_function",
         "function_expression", "class":
        if let body = node.child(namedField: "body") {
            appendTypeScriptBracedCandidate(
                kind: node.kind.contains("class") ? .container : .declaration,
                owner: node,
                body: body,
                foldDepth: foldDepth,
                bytes: bytes,
                candidates: &candidates
            )
        }
    case "statement_block", "class_body", "switch_body":
        appendTypeScriptBracedCandidate(
            kind: node.kind == "class_body" ? .container : .block,
            owner: node,
            body: node,
            foldDepth: foldDepth,
            bytes: bytes,
            candidates: &candidates
        )
    case "if_statement", "for_statement", "for_in_statement",
         "while_statement", "switch_statement", "try_statement",
         "catch_clause", "finally_clause", "else_clause":
        let body = node.child(namedField: "consequence")
            ?? node.child(namedField: "body")
            ?? node.namedChildren.first(where: {
                $0.kind == "statement_block" || $0.kind == "switch_body"
            })
        if let body {
            appendTypeScriptBracedCandidate(
                kind: .block,
                owner: node,
                body: body,
                foldDepth: foldDepth,
                bytes: bytes,
                candidates: &candidates
            )
        }
    default:
        break
    }
    if node.kind == "program" || node.kind == "source_file" {
        let children = node.namedChildren
        appendTypeScriptRuns(
            in: children,
            matching: { $0.kind == "import_statement" },
            kind: .imports,
            foldDepth: foldDepth,
            bytes: bytes,
            candidates: &candidates
        )
        appendTypeScriptRuns(
            in: children,
            matching: { $0.kind == "comment" },
            kind: .comment,
            foldDepth: foldDepth,
            bytes: bytes,
            candidates: &candidates
        )
    }
}

private func appendTypeScriptBracedCandidate(
    kind: FoldKind,
    owner: Node,
    body: Node,
    foldDepth: Int,
    bytes: [UInt8],
    candidates: inout FoldCandidateAccumulator
) {
    let bodyRange = body.byteRange
    guard bodyRange.upperBound >= bodyRange.lowerBound,
          bodyRange.upperBound - bodyRange.lowerBound >= 2,
          typeScriptByte(at: bodyRange.lowerBound, in: bytes) == UInt8(ascii: "{"),
          typeScriptByte(at: bodyRange.upperBound - 1, in: bytes) == UInt8(ascii: "}")
    else { return }
    candidates.appendCandidate(
        kind: kind,
        headerRange: CodeInsightCore.ByteRange(
            lowerBound: owner.byteRange.lowerBound,
            upperBound: bodyRange.lowerBound + 1
        ),
        bodyRange: CodeInsightCore.ByteRange(
            lowerBound: bodyRange.lowerBound + 1,
            upperBound: bodyRange.upperBound - 1
        ),
        foldDepth: foldDepth,
        bytes: bytes
    )
}

private func appendTypeScriptRuns(
    in children: [Node],
    matching predicate: (Node) -> Bool,
    kind: FoldKind,
    foldDepth: Int,
    bytes: [UInt8],
    candidates: inout FoldCandidateAccumulator
) {
    var start = children.startIndex
    while start < children.endIndex {
        guard predicate(children[start]) else {
            start += 1
            continue
        }
        var end = start + 1
        while end < children.endIndex, predicate(children[end]) {
            end += 1
        }
        if end - start >= 2 {
            let first = children[start].byteRange
            let last = children[end - 1].byteRange
            candidates.appendCandidate(
                kind: kind,
                headerRange: CodeInsightCore.ByteRange(
                    lowerBound: first.lowerBound,
                    upperBound: first.upperBound
                ),
                bodyRange: CodeInsightCore.ByteRange(
                    lowerBound: first.upperBound,
                    upperBound: last.upperBound
                ),
                foldDepth: foldDepth,
                bytes: bytes,
                itemCount: end - start
            )
        }
        start = end
    }
}

private func typeScriptText(
    _ bytes: [UInt8],
    range: CodeInsightCore.ByteRange
) -> String? {
    let lower = Int(range.lowerBound)
    let upper = Int(range.upperBound)
    guard lower <= upper, upper <= bytes.count else { return nil }
    return String(bytes: bytes[lower..<upper], encoding: .utf8)
}

private func typeScriptByte(
    at offset: UInt32,
    in bytes: [UInt8]
) -> UInt8? {
    guard let index = Int(exactly: offset), bytes.indices.contains(index) else {
        return nil
    }
    return bytes[index]
}

private func typeScriptLocalReferences(
    in tree: Tree,
    bytes: [UInt8]
) -> (
    bindings: [BindingRecord],
    referencesByBinding: [[CodeInsightCore.ByteRange]]
) {
    let names = Interner<NameID>()
    var bindings: [BindingRecord] = []
    var references: [[CodeInsightCore.ByteRange]] = []
    var localByName: [[String: Int]] = [[:]]
    var scopeIDStack: [UInt32] = [0]
    var nextScopeID: UInt32 = 1

    func currentLevel() -> Int {
        localByName.count - 1
    }

    func declare(_ name: String, kind: BindingKind, range: CodeInsightCore.ByteRange) {
        let index = bindings.count
        bindings.append(BindingRecord(
            scopeID: ScopeID(rawValue: scopeIDStack.last!),
            localNameID: names.intern(name),
            space: .value,
            kind: kind,
            declarationRange: range,
            targetHint: nil
        ))
        references.append([])
        localByName[currentLevel()][name] = index + 1
    }

    func appendReference(_ name: String, range: CodeInsightCore.ByteRange) {
        for level in (0..<localByName.count).reversed() {
            guard let index = localByName[level][name],
                  bindings[index - 1].declarationRange != range
            else { continue }
            references[index - 1].append(range)
            return
        }
    }

    func enterScope(_ node: Node) {
        localByName.append([:])
        scopeIDStack.append(nextScopeID)
        nextScopeID += 1
    }

    func leaveScope() {
        if localByName.count > 1 {
            localByName.removeLast()
            scopeIDStack.removeLast()
        }
    }

    func visit(_ node: Node) {
        let kind = node.kind
        switch kind {
        case "function_declaration", "generator_function_declaration",
             "method_definition", "arrow_function", "function_expression":
            if let body = node.child(namedField: "body") {
                enterScope(body)
                for parameter in typeScriptParameterNames(of: node, bytes: bytes) {
                    declare(parameter.name, kind: .param, range: parameter.range)
                }
                for child in body.namedChildren {
                    visit(child)
                }
                leaveScope()
                return
            }
        case "class_declaration", "class":
            if let body = node.child(namedField: "body") {
                if let name = node.child(namedField: "name"),
                   let text = typeScriptText(bytes, range: coreRange(name))
                {
                    declare(text, kind: .letBinding, range: coreRange(name))
                }
                enterScope(body)
                for child in body.namedChildren {
                    visit(child)
                }
                leaveScope()
                return
            }
        case "statement_block":
            enterScope(node)
            for child in node.namedChildren {
                visit(child)
            }
            leaveScope()
            return
        case "lexical_declaration", "variable_declaration":
            for declarator in node.namedChildren
                where declarator.kind == "variable_declarator"
            {
                if let value = declarator.child(namedField: "value") {
                    visit(value)
                }
                if let nameNode = declarator.child(namedField: "name"),
                   nameNode.kind == "identifier",
                   let name = typeScriptText(bytes, range: coreRange(nameNode))
                {
                    declare(name, kind: .letBinding, range: coreRange(nameNode))
                }
            }
            return
        case "identifier":
            if let name = typeScriptText(bytes, range: coreRange(node)) {
                appendReference(name, range: coreRange(node))
            }
            return
        default:
            for child in node.namedChildren {
                visit(child)
            }
        }
    }

    visit(tree.rootNode)
    return (bindings, references)
}

private func typeScriptParameterNames(
    of node: Node,
    bytes: [UInt8]
) -> [(name: String, range: CodeInsightCore.ByteRange)] {
    guard let formal = node.child(namedField: "parameters")
        ?? node.child(namedField: "parameter")
    else { return [] }
    var result: [(String, CodeInsightCore.ByteRange)] = []
    if formal.kind == "identifier",
       let text = typeScriptText(bytes, range: coreRange(formal))
    {
        return [(text, coreRange(formal))]
    }
    for parameter in formal.namedChildren {
        let name: Node?
        if let child = parameter.child(namedField: "name") {
            name = child
        } else if parameter.kind == "identifier" {
            name = parameter
        } else if let pattern = parameter.child(namedField: "pattern") {
            name = pattern
        } else {
            name = nil
        }
        guard let name, name.kind == "identifier",
              let text = typeScriptText(bytes, range: coreRange(name))
        else { continue }
        result.append((text, coreRange(name)))
    }
    return result
}
