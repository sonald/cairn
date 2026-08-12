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
    appendPythonKeywordSpans(root: tree.rootNode, spans: &spans)
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
    spans: inout [HighlightSpan],
    facets: inout [OutlineFacet],
    candidates: inout FoldCandidateAccumulator
) {
    switch node.kind {
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
    candidates.visitPython(node: node, foldDepth: depth, bytes: bytes)
    for child in node.namedChildren {
        let childDirect = directClassMember && node.kind == "block"
        pythonWalk(
            child,
            bytes: bytes,
            depth: depth,
            directClassMember: childDirect
                || (directClassMember && node.kind == "class_definition"),
            spans: &spans,
            facets: &facets,
            candidates: &candidates
        )
    }
}

private func appendPythonKeywordSpans(
    root: Node,
    spans: inout [HighlightSpan]
) {
    for node in root.depthFirst() where !node.isNamed {
        if pythonKeywords.contains(node.kind) {
            spans.append(HighlightSpan(range: coreRange(node), kind: .keyword))
        }
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
                depth: depth
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

private func pythonText(
    _ bytes: [UInt8],
    range: CodeInsightCore.ByteRange
) -> String? {
    let lower = Int(range.lowerBound)
    let upper = Int(range.upperBound)
    guard lower <= upper, upper <= bytes.count else { return nil }
    return String(bytes: bytes[lower..<upper], encoding: .utf8)
}
