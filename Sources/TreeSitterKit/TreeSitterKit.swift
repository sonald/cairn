import CodeInsightCore
import CTreeSitter
import Darwin

public struct ByteRange: Equatable, Sendable {
    public var lowerBound: UInt32
    public var upperBound: UInt32

    public init(lowerBound: UInt32, upperBound: UInt32) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }
}

public final class Parser {
    private let raw: OpaquePointer

    public init?(language: OpaquePointer) {
        guard let parser = ts_parser_new() else { return nil }
        guard ts_parser_set_language(parser, language) else {
            ts_parser_delete(parser)
            return nil
        }
        raw = parser
    }

    deinit {
        ts_parser_delete(raw)
    }

    public func parse(_ bytes: [UInt8]) -> Tree? {
        guard let length = UInt32(exactly: bytes.count) else { return nil }

        let tree: OpaquePointer?
        if bytes.isEmpty {
            var terminator: CChar = 0
            tree = ts_parser_parse_string(raw, nil, &terminator, 0)
        } else {
            tree = bytes.withUnsafeBytes { buffer in
                ts_parser_parse_string(
                    raw,
                    nil,
                    buffer.baseAddress!.assumingMemoryBound(to: CChar.self),
                    length
                )
            }
        }
        return tree.map(Tree.init)
    }

    /// Parses like `parse(_:)` but halts early, returning nil, once
    /// `shouldCancel` reports true. Tree-sitter polls it periodically.
    public func parse(_ bytes: [UInt8], shouldCancel: () -> Bool) -> Tree? {
        guard let length = UInt32(exactly: bytes.count) else { return nil }
        guard !bytes.isEmpty else { return shouldCancel() ? nil : parse(bytes) }
        return withoutActuallyEscaping(shouldCancel) { shouldCancel in
            let cancellation = ParseCancellation(shouldCancel)
            return bytes.withUnsafeBytes { buffer in
                var source = ParseSource(
                    base: buffer.baseAddress!.assumingMemoryBound(to: CChar.self),
                    length: length
                )
                return withUnsafeMutablePointer(to: &source) { sourcePointer in
                    let input = TSInput(
                        payload: UnsafeMutableRawPointer(sourcePointer),
                        read: { payload, byteIndex, _, bytesRead in
                            let source = payload!.assumingMemoryBound(to: ParseSource.self).pointee
                            bytesRead!.pointee = byteIndex < source.length
                                ? source.length - byteIndex
                                : 0
                            return source.base + Int(min(byteIndex, source.length))
                        },
                        encoding: TSInputEncodingUTF8,
                        decode: nil
                    )
                    let options = TSParseOptions(
                        payload: Unmanaged.passUnretained(cancellation).toOpaque(),
                        progress_callback: { state in
                            Unmanaged<ParseCancellation>
                                .fromOpaque(state!.pointee.payload)
                                .takeUnretainedValue()
                                .shouldCancel()
                        }
                    )
                    let tree = withExtendedLifetime(cancellation) {
                        ts_parser_parse_with_options(raw, nil, input, options)
                    }
                    return tree.map(Tree.init)
                }
            }
        }
    }
}

private struct ParseSource {
    let base: UnsafePointer<CChar>
    let length: UInt32
}

private final class ParseCancellation {
    let shouldCancel: () -> Bool

    init(_ shouldCancel: @escaping () -> Bool) {
        self.shouldCancel = shouldCancel
    }
}

public final class Tree {
    private let raw: OpaquePointer

    fileprivate init(_ raw: OpaquePointer) {
        self.raw = raw
    }

    deinit {
        ts_tree_delete(raw)
    }

    public var rootNode: Node {
        Node(raw: ts_tree_root_node(raw), tree: self)
    }
}

public struct Node {
    private let raw: TSNode
    private let tree: Tree

    fileprivate init(raw: TSNode, tree: Tree) {
        self.raw = raw
        self.tree = tree
    }

    public var kind: String {
        String(cString: ts_node_type(raw))
    }

    public var byteRange: ByteRange {
        ByteRange(
            lowerBound: ts_node_start_byte(raw),
            upperBound: ts_node_end_byte(raw)
        )
    }

    public var childCount: UInt32 {
        ts_node_child_count(raw)
    }

    public func child(at index: UInt32) -> Node? {
        guard index < childCount else { return nil }
        let child = ts_node_child(raw, index)
        guard !ts_node_is_null(child) else { return nil }
        return Node(raw: child, tree: tree)
    }

    package func child(namedField name: String) -> Node? {
        let field = ts_node_child_by_field_name(raw, name, UInt32(name.utf8.count))
        guard !ts_node_is_null(field) else { return nil }
        return Node(raw: field, tree: tree)
    }

    public var namedChildren: [Node] {
        (0..<ts_node_named_child_count(raw)).map { index in
            Node(raw: ts_node_named_child(raw, index), tree: tree)
        }
    }

    public var hasError: Bool {
        ts_node_has_error(raw)
    }

    public var isNamed: Bool {
        ts_node_is_named(raw)
    }

    public var sExpression: String {
        guard let string = ts_node_string(raw) else { return "" }
        defer { free(string) }
        return String(cString: string)
    }

    public func depthFirst() -> [Node] {
        var nodes: [Node] = []
        var stack = [self]

        while let node = stack.popLast() {
            nodes.append(node)
            for index in (0..<node.childCount).reversed() {
                if let child = node.child(at: index) {
                    stack.append(child)
                }
            }
        }

        return nodes
    }
}

// A cursor visits the existing tree without allocating child arrays or retaining a node stack.
extension Node {
    func contentRegions(language: LanguageID) -> [ContentRegion] {
        var regions: [ContentRegion] = []
        var cursor = ts_tree_cursor_new(raw)
        defer { ts_tree_cursor_delete(&cursor) }
        while true {
            let node = ts_tree_cursor_current_node(&cursor)
            let kind = contentRegionKind(nodeKind: String(cString: ts_node_type(node)), language: language)
            if let kind {
                let lower = ts_node_start_byte(node)
                let upper = ts_node_end_byte(node)
                if lower < upper {
                    regions.append(ContentRegion(
                        range: CodeInsightCore.ByteRange(lowerBound: lower, upperBound: upper),
                        kind: kind
                    ))
                }
            } else if ts_tree_cursor_goto_first_child(&cursor) {
                continue
            }
            // A recognized parent covers its children, matching reader highlighting.
            while !ts_tree_cursor_goto_next_sibling(&cursor) {
                guard ts_tree_cursor_goto_parent(&cursor) else { return regions }
            }
        }
    }
}
