import CodeInsightCore
import CTreeSitterRust
import TreeSitterKit

public struct RustExtractor: LanguageExtractor, Sendable {
    #if DEBUG
    @TaskLocal public static var parseObserver: (@Sendable () -> Void)?
    #endif

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
        guard let tree = observedParse(parser, bytes: bytes) else {
            throw RustExtractionError.parseFailed
        }

        return extractWithDiagnostics(
            tree: tree,
            parser: parser,
            bytes: bytes,
            key: key,
            interner: interner
        )
    }

    public func extractWithDiagnostics(
        tree: Tree,
        parser: Parser,
        bytes: [UInt8],
        key: ContentIndexKey,
        interner: ExtractionInterners
    ) -> (index: ContentIndex, containsErrorNodes: Bool) {
        var scopes = RustScopeBuilder(bytes: bytes, names: interner.names)
        var declarations = RustDeclarations(bytes: bytes, names: interner.names)
        var calls = RustCalls(bytes: bytes, names: interner.names)
        var imports = RustImports(
            bytes: bytes,
            names: interner.names,
            strings: interner.strings
        )
        traverse(
            root: tree.rootNode,
            parser: parser,
            bytes: bytes,
            scopes: &scopes,
            declarations: &declarations,
            calls: &calls,
            imports: &imports
        )

        return (ContentIndex(
            key: key,
            scopes: scopes.scopes,
            bindings: scopes.bindings,
            executableRegions: scopes.executableRegions,
            symbols: declarations.facets,
            implRelations: declarations.implRelations,
            calls: calls.calls,
            imports: imports.imports,
            exports: imports.exports,
            lineTable: LineTable(bytes: bytes)
        ), tree.rootNode.hasError)
    }

    public func localReferences(
        tree: Tree,
        bytes: [UInt8]
    ) -> (
        bindings: [BindingRecord],
        referencesByBinding: [[CodeInsightCore.ByteRange]]
    ) {
        let names = Interner<NameID>()
        var scopes = RustScopeBuilder(
            bytes: bytes,
            names: names,
            collectReferences: true
        )
        var declarations = RustDeclarations(bytes: bytes, names: names)
        var calls = RustCalls(bytes: bytes, names: names)
        var imports = RustImports(
            bytes: bytes,
            names: names,
            strings: Interner<StringID>()
        )
        traverse(
            root: tree.rootNode,
            parser: nil,
            bytes: bytes,
            bindingsOnly: true,
            scopes: &scopes,
            declarations: &declarations,
            calls: &calls,
            imports: &imports
        )

        let localIndices = scopes.bindings.indices.filter {
            let kind = scopes.bindings[$0].kind
            return kind == .param || kind == .letBinding
        }
        return (
            localIndices.map { scopes.bindings[$0] },
            localIndices.map { scopes.referencesByBinding[$0] }
        )
    }

    public func identifierRanges(
        named name: String,
        in bytes: [UInt8]
    ) throws -> [CodeInsightCore.ByteRange] {
        guard
            let language = tree_sitter_rust(),
            let parser = Parser(language: language)
        else {
            throw RustExtractionError.parserUnavailable
        }
        guard let tree = observedParse(parser, bytes: bytes) else {
            throw RustExtractionError.parseFailed
        }
        let name = Array(name.utf8)
        return tree.rootNode.depthFirst().compactMap { node in
            let range = node.byteRange
            let lower = Int(range.lowerBound)
            let upper = Int(range.upperBound)
            guard node.kind.contains("identifier"),
                  upper - lower == name.count,
                  lower >= 0,
                  upper <= bytes.count,
                  bytes[lower..<upper].elementsEqual(name)
            else { return nil }
            return CodeInsightCore.ByteRange(
                lowerBound: range.lowerBound,
                upperBound: range.upperBound
            )
        }
    }

    private func traverse(
        root: Node,
        parser: Parser?,
        bytes: [UInt8],
        byteOffset: UInt32 = 0,
        macroDepth: Int = 0,
        baseAncestors: [Node] = [],
        bindingsOnly: Bool = false,
        scopes: inout RustScopeBuilder,
        declarations: inout RustDeclarations,
        calls: inout RustCalls,
        imports: inout RustImports
    ) {
        var cursor = RustTreeCursor(root: root)
        var ancestors = baseAncestors

        while let event = cursor.next() {
            switch event {
            case let .enter(node):
                let parent = ancestors.last
                let site = bindingsOnly
                    ? RustDeclarationSite.none
                    : declarations.enter(
                        node,
                        parent: parent,
                        ancestors: ancestors,
                        byteOffset: byteOffset
                    )
                scopes.enter(
                    node,
                    parent: parent,
                    ancestors: ancestors,
                    declaration: site,
                    byteOffset: byteOffset
                )
                if !bindingsOnly {
                    calls.enter(
                        node,
                        regionID: scopes.currentRegionID,
                        byteOffset: byteOffset
                    )
                    imports.enter(
                        node,
                        scopeID: scopes.currentImportScopeID,
                        byteOffset: byteOffset
                    )
                }
                ancestors.append(node)

                if node.kind == "macro_invocation" {
                    if !bindingsOnly,
                       macroDepth < 3,
                       let parser,
                       isItemMacroPosition(parent),
                       let body = macroBody(
                           of: node,
                           parser: parser,
                           bytes: bytes,
                           byteOffset: byteOffset
                       )
                    {
                        for item in body.items {
                            traverse(
                                root: item,
                                parser: parser,
                                bytes: bytes,
                                byteOffset: body.byteOffset,
                                macroDepth: macroDepth + 1,
                                baseAncestors: Array(ancestors.dropLast()),
                                bindingsOnly: false,
                                scopes: &scopes,
                                declarations: &declarations,
                                calls: &calls,
                                imports: &imports
                            )
                        }
                    }
                    cursor.skipChildren()
                } else if node.kind == "macro_definition" {
                    cursor.skipChildren()
                } else if node.kind == "use_declaration"
                    || node.kind == "extern_crate_declaration"
                {
                    // RustImports has already expanded these syntax-only subtrees.
                    cursor.skipChildren()
                }

            case let .exit(node):
                _ = ancestors.popLast()
                scopes.exit(node, byteOffset: byteOffset)
                if !bindingsOnly {
                    declarations.exit(node, byteOffset: byteOffset)
                }
            }
        }
    }

    private func isItemMacroPosition(_ parent: Node?) -> Bool {
        switch parent?.kind {
        case "source_file", "declaration_list", "block", "expression_statement":
            return true
        default:
            return false
        }
    }

    private func macroBody(
        of node: Node,
        parser: Parser,
        bytes: [UInt8],
        byteOffset: UInt32
    ) -> (items: [Node], byteOffset: UInt32)? {
        guard let tokenTree = node.directNamedChild(where: {
            $0.kind == "token_tree"
        }) else { return nil }
        let range = tokenTree.byteRange
        let lower = Int(byteOffset) + Int(range.lowerBound)
        let upper = Int(byteOffset) + Int(range.upperBound)
        guard lower < upper,
              upper <= bytes.count,
              bytes[lower] == 0x7B,
              bytes[upper - 1] == 0x7D,
              let bodyOffset = UInt32(exactly: lower + 1),
              let tree = observedParse(
                  parser,
                  bytes: Array(bytes[(lower + 1)..<(upper - 1)])
              ),
              tree.rootNode.kind == "source_file",
              !tree.rootNode.hasError
        else { return nil }

        let namedChildren = tree.rootNode.namedChildren
        guard namedChildren.allSatisfy({
            isAcceptedMacroItem($0.kind) || isItemTrivia($0.kind)
        }) else {
            return nil
        }
        return (
            namedChildren.filter { isAcceptedMacroItem($0.kind) },
            bodyOffset
        )
    }

    private func observedParse(
        _ parser: Parser,
        bytes: [UInt8]
    ) -> Tree? {
        #if DEBUG
        Self.parseObserver?()
        #endif
        return parser.parse(bytes)
    }

    private func isAcceptedMacroItem(_ kind: String) -> Bool {
        switch kind {
        case "function_item", "struct_item", "enum_item", "impl_item",
             "trait_item", "mod_item", "const_item", "static_item",
             "type_item", "use_declaration", "macro_invocation":
            return true
        default:
            return false
        }
    }

    private func isItemTrivia(_ kind: String) -> Bool {
        kind == "line_comment"
            || kind == "block_comment"
            || kind == "attribute_item"
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

    init(_ node: Node, byteOffset: UInt32 = 0) {
        kind = node.kind
        lowerBound = node.byteRange.lowerBound + byteOffset
        upperBound = node.byteRange.upperBound + byteOffset
    }
}

extension Node {
    func coreByteRange(byteOffset: UInt32 = 0) -> CodeInsightCore.ByteRange {
        CodeInsightCore.ByteRange(
            lowerBound: byteRange.lowerBound + byteOffset,
            upperBound: byteRange.upperBound + byteOffset
        )
    }

    func directNamedChild(where predicate: (Node) -> Bool) -> Node? {
        namedChildren.first(where: predicate)
    }

    func text(in bytes: [UInt8], byteOffset: UInt32 = 0) -> String? {
        let lower = Int(byteRange.lowerBound) + Int(byteOffset)
        let upper = Int(byteRange.upperBound) + Int(byteOffset)
        guard lower <= upper, upper <= bytes.count else { return nil }
        return String(bytes: bytes[lower..<upper], encoding: .utf8)
    }
}
