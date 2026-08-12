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
