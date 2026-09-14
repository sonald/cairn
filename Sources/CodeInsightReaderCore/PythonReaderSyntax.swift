import CTreeSitterPython
import CodeInsightPythonExtractor
import CodeInsightCore
import TreeSitterKit

private let pythonKeywords: Set<String> = [
    "and", "as", "assert", "async", "await", "break", "case", "class",
    "continue", "def", "del", "elif", "else", "except", "False", "finally",
    "for", "from", "global", "if", "import", "in", "is", "lambda", "None",
    "nonlocal", "not", "or", "pass", "raise", "return", "True", "try",
    "while", "with", "yield",
]

func pythonReaderIsKeyword(_ value: String) -> Bool {
    pythonKeywords.contains(value)
}

func pythonReaderHighlightWithFolds(
    bytes: [UInt8]
) throws -> (
    spans: [HighlightSpan],
    outlineFacets: [OutlineFacet],
    folds: [FoldRegion],
    bindings: [BindingRecord],
    referencesByBinding: [[CodeInsightCore.ByteRange]]
) {
    guard
        let language = tree_sitter_python(),
        let parser = Parser(language: language)
    else { throw RustHighlighterError.parserUnavailable }
    #if DEBUG
    DocumentLoader.pythonParseObserver?()
    #endif
    guard let tree = parser.parse(bytes) else {
        throw RustHighlighterError.parseFailed
    }

    var spans: [HighlightSpan] = []
    var facets: [OutlineFacet] = []
    var candidates = FoldCandidateAccumulator()
    pythonWalk(
        tree.rootNode,
        bytes: bytes,
        depth: 0,
        directClassMember: false,
        spans: &spans,
        facets: &facets,
        candidates: &candidates
    )
    let folds = candidates.resolve(
        outlineFacets: facets,
        observer: nil as (@Sendable (Double, Int, Int) -> Void)?
    )
    let refs = pythonLocalReferences(in: tree, bytes: bytes)
    appendLocalBindingHighlights(
        bindings: refs.bindings,
        referencesByBinding: refs.referencesByBinding,
        spans: &spans
    )
    spans.sort {
        ($0.range.lowerBound, $0.range.upperBound, $0.kind.rawValue)
            < ($1.range.lowerBound, $1.range.upperBound, $1.kind.rawValue)
    }
    return (spans, facets, folds, refs.bindings, refs.referencesByBinding)
}

private func pythonWalk(
    _ node: Node,
    bytes: [UInt8],
    depth: Int,
    directClassMember: Bool,
    role: HighlightKind? = nil,
    spans: inout [HighlightSpan],
    facets: inout [OutlineFacet],
    candidates: inout FoldCandidateAccumulator
) {
    if !node.isNamed, pythonKeywords.contains(node.kind) {
        spans.append(HighlightSpan(range: coreRange(node), kind: .keyword))
        return
    }
    switch node.kind {
    case "identifier":
        if let role {
            spans.append(HighlightSpan(range: coreRange(node), kind: role))
        }
        return
    case "true", "false", "none":
        spans.append(HighlightSpan(range: coreRange(node), kind: .keyword))
        return
    case "integer", "float":
        spans.append(HighlightSpan(range: coreRange(node), kind: .number))
        return
    case "string", "concatenated_string":
        spans.append(HighlightSpan(range: coreRange(node), kind: .string))
        return
    case "comment":
        spans.append(HighlightSpan(range: coreRange(node), kind: .comment))
        return
    case "decorated_definition":
        for decorator in node.namedChildren where decorator.kind == "decorator" {
            pythonWalk(
                decorator, bytes: bytes, depth: depth,
                directClassMember: false, spans: &spans,
                facets: &facets, candidates: &candidates
            )
        }
        if let definition = node.child(namedField: "definition"),
           definition.kind == "function_definition"
            || definition.kind == "class_definition"
        {
            pythonDeclarationWalk(
                definition,
                bytes: bytes,
                depth: depth,
                directClassMember: directClassMember,
                ownerRange: coreRange(node),
                spans: &spans,
                facets: &facets,
                candidates: &candidates,
                headerOwner: node
            )
        }
        return
    case "function_definition", "class_definition":
        pythonDeclarationWalk(
            node,
            bytes: bytes,
            depth: depth,
            directClassMember: directClassMember,
            ownerRange: coreRange(node),
            spans: &spans,
            facets: &facets,
            candidates: &candidates,
            headerOwner: nil
        )
        return
    default:
        break
    }
    if node.kind == "assignment", directClassMember,
       let name = node.child(namedField: "left"), name.kind == "identifier",
       let text = pythonText(bytes, range: coreRange(name))
    {
        let detail = node.child(namedField: "type")
            .flatMap { pythonText(bytes, range: coreRange($0)) }
            .map { ": " + $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") } ?? ""
        facets.append(OutlineFacet(
            kind: .field, name: text, range: coreRange(node),
            nameRange: coreRange(name), depth: depth, detail: detail
        ))
    }
    candidates.visitPython(node: node, foldDepth: depth, bytes: bytes)
    for index in 0..<node.childCount {
        guard let child = node.child(at: index) else { continue }
        let childDirect = directClassMember
            && (node.kind == "block" || node.kind == "expression_statement")
        let childRole: HighlightKind?
        switch node.kind {
        case "decorator", "parenthesized_expression":
            childRole = node.kind == "decorator" ? .attribute : role
        case "call":
            childRole = child.byteRange == node.child(namedField: "function")?.byteRange
                ? (role ?? .functionCall) : nil
        case "attribute":
            childRole = child.byteRange == node.child(namedField: "attribute")?.byteRange
                ? (role ?? .property) : nil
        case "assignment":
            childRole = directClassMember
                && child.byteRange == node.child(namedField: "left")?.byteRange
                ? .property : nil
        case "type", "generic_type", "member_type", "union_type":
            childRole = .typeName
        default:
            childRole = role == .typeName ? role : nil
        }
        pythonWalk(
            child,
            bytes: bytes,
            depth: depth,
            directClassMember: childDirect
                || (directClassMember && node.kind == "class_definition"),
            role: childRole,
            spans: &spans,
            facets: &facets,
            candidates: &candidates
        )
    }
}

private func pythonDeclarationWalk(
    _ node: Node,
    bytes: [UInt8],
    depth: Int,
    directClassMember: Bool,
    ownerRange: CodeInsightCore.ByteRange,
    spans: inout [HighlightSpan],
    facets: inout [OutlineFacet],
    candidates: inout FoldCandidateAccumulator,
    headerOwner: Node?
) {
    let isClass = node.kind == "class_definition"
    let kind: OutlineKind = isClass ? .class : (directClassMember ? .method : .fn)
    let range = ownerRange
    if let name = node.child(namedField: "name") {
        let nameRange = coreRange(name)
        spans.append(HighlightSpan(
            range: nameRange,
            kind: isClass ? .declarationTitle : .functionName
        ))
        if let text = pythonText(bytes, range: nameRange) {
            facets.append(OutlineFacet(
                kind: kind,
                name: text,
                range: range,
                nameRange: nameRange,
                depth: depth,
                detail: pythonDeclarationDetail(node, bytes: bytes)
            ))
        }
    }
    let foldOwner: Node = node
    candidates.visitPython(
        node: foldOwner,
        foldDepth: depth,
        bytes: bytes,
        headerOwner: headerOwner
    )
    for index in 0..<node.childCount {
        guard let child = node.child(at: index),
              child.byteRange != node.child(namedField: "name")?.byteRange,
              child.byteRange != node.child(namedField: "body")?.byteRange
        else { continue }
        pythonWalk(
            child, bytes: bytes, depth: depth, directClassMember: false,
            spans: &spans, facets: &facets, candidates: &candidates
        )
    }
    if let body = node.child(namedField: "body") {
        candidates.visitPython(node: body, foldDepth: depth, bytes: bytes)
        for child in body.namedChildren {
            pythonWalk(
                child,
                bytes: bytes,
                depth: depth + 1,
                directClassMember: isClass,
                spans: &spans,
                facets: &facets,
                candidates: &candidates
            )
        }
    }
}

private func pythonDeclarationDetail(_ node: Node, bytes: [UInt8]) -> String {
    guard let parameters = node.child(namedField: "parameters"),
          let text = pythonText(bytes, range: coreRange(parameters))
    else { return "" }
    var detail = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    if let type = node.child(namedField: "return_type"),
       let result = pythonText(bytes, range: coreRange(type))
    {
        detail += " -> " + result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    return detail
}

private func pythonText(
    _ bytes: [UInt8],
    range: CodeInsightCore.ByteRange
) -> String? {
    let lower = Int(range.lowerBound)
    let upper = Int(range.upperBound)
    guard lower <= upper, upper <= bytes.count else { return nil }
    return String(bytes: bytes[lower..<upper], encoding: .utf8)
}
