import CodeInsightCore
import CTreeSitterRust
import TreeSitterKit

public struct RustExtractor: LanguageExtractor, Sendable {
    public init() {}

    public func extract(
        bytes: [UInt8],
        key: ContentIndexKey,
        interner: ExtractionInterners
    ) throws -> ContentIndex {
        try extractWithDiagnostics(
            bytes: bytes,
            key: key,
            interner: interner
        ).index
    }

    public func extractWithDiagnostics(
        bytes: [UInt8],
        key: ContentIndexKey,
        interner: ExtractionInterners
    ) throws -> (index: ContentIndex, containsErrorNodes: Bool) {
        guard
            let language = tree_sitter_rust(),
            let parser = Parser(language: language)
        else {
            throw RustExtractionError.parserUnavailable
        }
        guard let tree = parser.parse(bytes) else {
            throw RustExtractionError.parseFailed
        }

        var scopes = RustScopeBuilder(bytes: bytes, names: interner.names)
        var declarations = RustDeclarations(bytes: bytes, names: interner.names)
        var calls = RustCalls(bytes: bytes, names: interner.names)
        var imports = RustImports(
            bytes: bytes,
            names: interner.names,
            strings: interner.strings
        )
        var cursor = RustTreeCursor(root: tree.rootNode)
        var ancestors: [Node] = []

        while let event = cursor.next() {
            switch event {
            case let .enter(node):
                let site = declarations.enter(
                    node,
                    parent: ancestors.last,
                    ancestors: ancestors
                )
                scopes.enter(
                    node,
                    parent: ancestors.last,
                    ancestors: ancestors,
                    declaration: site
                )
                calls.enter(node, regionID: scopes.currentRegionID)
                imports.enter(node, scopeID: scopes.currentImportScopeID)
                ancestors.append(node)

                if node.kind == "macro_definition"
                    || node.kind == "macro_invocation"
                {
                    // Macro-generated symbols are unavailable without expansion;
                    // skip token subtrees and degrade honestly instead of guessing.
                    cursor.skipChildren()
                } else if node.kind == "use_declaration"
                    || node.kind == "extern_crate_declaration"
                {
                    // RustImports has already expanded these syntax-only subtrees.
                    cursor.skipChildren()
                }

            case let .exit(node):
                _ = ancestors.popLast()
                scopes.exit(node)
                declarations.exit(node)
            }
        }

        return (ContentIndex(
            key: key,
            scopes: scopes.scopes,
            bindings: scopes.bindings,
            executableRegions: scopes.executableRegions,
            symbols: declarations.facets,
            calls: calls.calls,
            imports: imports.imports,
            exports: imports.exports,
            lineTable: LineTable(bytes: bytes)
        ), tree.rootNode.hasError)
    }
}

private enum RustExtractionError: Error {
    case parserUnavailable
    case parseFailed
}

enum RustTraversalEvent {
    case enter(Node)
    case exit(Node)
}

struct RustTreeCursor {
    private struct Frame {
        let node: Node
        var entered = false
        var nextChild: UInt32 = 0
    }

    private var stack: [Frame]

    init(root: Node) {
        stack = [Frame(node: root)]
    }

    mutating func next() -> RustTraversalEvent? {
        while !stack.isEmpty {
            let index = stack.index(before: stack.endIndex)
            if !stack[index].entered {
                stack[index].entered = true
                return .enter(stack[index].node)
            }

            if stack[index].nextChild < stack[index].node.childCount {
                let childIndex = stack[index].nextChild
                stack[index].nextChild += 1
                if let child = stack[index].node.child(at: childIndex) {
                    stack.append(Frame(node: child))
                }
                continue
            }

            return .exit(stack.removeLast().node)
        }
        return nil
    }

    mutating func skipChildren() {
        guard let index = stack.indices.last else { return }
        stack[index].nextChild = stack[index].node.childCount
    }
}

struct RustNodeKey: Hashable {
    let kind: String
    let lowerBound: UInt32
    let upperBound: UInt32

    init(_ node: Node) {
        kind = node.kind
        lowerBound = node.byteRange.lowerBound
        upperBound = node.byteRange.upperBound
    }
}

extension Node {
    var coreByteRange: CodeInsightCore.ByteRange {
        CodeInsightCore.ByteRange(
            lowerBound: byteRange.lowerBound,
            upperBound: byteRange.upperBound
        )
    }

    func directNamedChild(where predicate: (Node) -> Bool) -> Node? {
        namedChildren.first(where: predicate)
    }

    func text(in bytes: [UInt8]) -> String? {
        let lower = Int(byteRange.lowerBound)
        let upper = Int(byteRange.upperBound)
        guard lower <= upper, upper <= bytes.count else { return nil }
        return String(bytes: bytes[lower..<upper], encoding: .utf8)
    }
}
