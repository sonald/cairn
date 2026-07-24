import CTreeSitterRust
import CodeInsightCore
import Foundation
import TreeSitterKit

public enum HighlightKind: UInt8, Sendable {
    case keyword
    case comment
    case string
    case number
    case functionName
    case typeName
}

public struct HighlightSpan: Equatable, Sendable {
    public let range: CodeInsightCore.ByteRange
    public let kind: HighlightKind

    public init(range: CodeInsightCore.ByteRange, kind: HighlightKind) {
        self.range = range
        self.kind = kind
    }
}

public enum OutlineKind: String, Sendable {
    case fn
    case method
    case `struct`
    case `enum`
    case trait
    case `impl`
    case mod
    case `const`
    case `static`
    case typeAlias
}

public struct OutlineFacet: Equatable, Sendable {
    public let kind: OutlineKind
    public let name: String
    public let range: CodeInsightCore.ByteRange
    public let nameRange: CodeInsightCore.ByteRange
    public let depth: Int

    public init(
        kind: OutlineKind,
        name: String,
        range: CodeInsightCore.ByteRange,
        nameRange: CodeInsightCore.ByteRange,
        depth: Int
    ) {
        self.kind = kind
        self.name = name
        self.range = range
        self.nameRange = nameRange
        self.depth = depth
    }
}

public final class ReaderDocument: Sendable {
    public let bytes: [UInt8]
    public let contentID: ContentID
    public let lineTable: LineTable
    public let byteUTF16Map: ByteUTF16Map
    public let highlightSpans: [HighlightSpan]
    public let outlineFacets: [OutlineFacet]

    public init(
        bytes: [UInt8],
        contentID: ContentID? = nil,
        lineTable: LineTable,
        byteUTF16Map: ByteUTF16Map,
        highlightSpans: [HighlightSpan],
        outlineFacets: [OutlineFacet]
    ) {
        self.bytes = bytes
        self.contentID = contentID ?? ContentID.sha256(of: bytes)
        self.lineTable = lineTable
        self.byteUTF16Map = byteUTF16Map
        self.highlightSpans = highlightSpans
        self.outlineFacets = outlineFacets
    }

    public convenience init(
        bytes: [UInt8],
        highlightSpans: [HighlightSpan] = [],
        outlineFacets: [OutlineFacet] = []
    ) {
        self.init(
            bytes: bytes,
            lineTable: LineTable(bytes: bytes),
            byteUTF16Map: ByteUTF16Map(validUTF8: bytes),
            highlightSpans: highlightSpans,
            outlineFacets: outlineFacets
        )
    }

    public func symbolAnchor(at byteOffset: UInt32) -> String? {
        outlineFacets
            .filter { $0.range.contains(byteOffset) }
            .min { $0.range.length < $1.range.length }?
            .name
    }
}

public enum FileTier: String, Sendable {
    case regular
    case large
    case huge

    public init(lineCount: Int) {
        if lineCount <= 10_000 {
            self = .regular
        } else if lineCount <= 50_000 {
            self = .large
        } else {
            self = .huge
        }
    }
}

public enum RustHighlighterError: Error, Sendable {
    case parserUnavailable
    case parseFailed
}

public struct RustHighlighter: Sendable {
    private static let keywords: Set<String> = [
        "as", "async", "await", "break", "const", "continue", "crate", "else",
        "enum", "extern", "fn", "for", "if", "impl", "in", "let", "loop",
        "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self",
        "static", "struct", "super", "trait", "type", "unsafe", "use", "where", "while",
    ]
    private static let comments: Set<String> = ["line_comment", "block_comment"]
    private static let strings: Set<String> = [
        "string_literal", "raw_string_literal", "char_literal",
    ]
    private static let numbers: Set<String> = [
        "integer_literal", "float_literal", "boolean_literal",
    ]
    private static let types: Set<String> = [
        "type_identifier", "primitive_type",
    ]

    public init() {}

    public func highlight(
        bytes: [UInt8]
    ) throws -> (spans: [HighlightSpan], outlineFacets: [OutlineFacet]) {
        guard
            let language = tree_sitter_rust(),
            let parser = Parser(language: language)
        else { throw RustHighlighterError.parserUnavailable }
        guard let tree = parser.parse(bytes) else {
            throw RustHighlighterError.parseFailed
        }

        var spans: [HighlightSpan] = []
        var facets: [OutlineFacet] = []
        var stack: [(node: Node, depth: Int, parentKind: String?, member: OutlineKind?)] = [
            (tree.rootNode, 0, nil, nil),
        ]
        while let current = stack.popLast() {
            let node = current.node
            let kind = node.kind
            let highlight: HighlightKind?
            if Self.comments.contains(kind) {
                highlight = .comment
            } else if Self.strings.contains(kind) {
                highlight = .string
            } else if Self.numbers.contains(kind) {
                highlight = .number
            } else if Self.types.contains(kind) {
                highlight = .typeName
            } else if !node.isNamed && Self.keywords.contains(kind) {
                highlight = .keyword
            } else {
                highlight = nil
            }

            if let highlight {
                spans.append(HighlightSpan(range: coreRange(node), kind: highlight))
                continue
            }

            let outline = outlineItem(
                for: node,
                nodeKind: kind,
                parentKind: current.parentKind,
                member: current.member
            )
            if let outline {
                let nameRange = coreRange(outline.nameNode)
                if kind == "function_item" || kind == "function_signature_item" {
                    spans.append(HighlightSpan(range: nameRange, kind: .functionName))
                }
                // Outline data belongs to this existing highlighter walk. Parsing
                // again through RustExtractor would duplicate the large-file cost.
                if let name = text(in: bytes, range: nameRange) {
                    facets.append(OutlineFacet(
                        kind: outline.kind,
                        name: name,
                        range: coreRange(node),
                        nameRange: nameRange,
                        depth: current.depth
                    ))
                }
            }

            let isContainer = kind == "impl_item"
                || kind == "trait_item"
                || (kind == "mod_item" && node.namedChildren.contains {
                    $0.kind == "declaration_list"
                })
            let childDepth = current.depth + (isContainer ? 1 : 0)
            let childMember: OutlineKind?
            switch kind {
            case "impl_item":
                childMember = .impl
            case "trait_item":
                childMember = .trait
            case "source_file", "mod_item", "function_item", "function_signature_item":
                childMember = nil
            default:
                childMember = current.member
            }
            for index in (0..<node.childCount).reversed() {
                if let child = node.child(at: index) {
                    stack.append((child, childDepth, kind, childMember))
                }
            }
        }
        spans.sort {
            ($0.range.lowerBound, $0.range.upperBound, $0.kind.rawValue)
                < ($1.range.lowerBound, $1.range.upperBound, $1.kind.rawValue)
        }
        return (spans, facets)
    }

    private func outlineItem(
        for node: Node,
        nodeKind: String,
        parentKind: String?,
        member: OutlineKind?
    ) -> (kind: OutlineKind, nameNode: Node)? {
        let kind: OutlineKind
        let nameNode: Node?
        switch nodeKind {
        case "function_item", "function_signature_item":
            kind = parentKind == "declaration_list"
                && (member == .impl || member == .trait)
                ? .method
                : .fn
            nameNode = node.namedChildren.first {
                $0.kind == "identifier" || $0.kind == "metavariable"
            }
        case "struct_item":
            kind = .struct
            nameNode = node.namedChildren.first { $0.kind == "type_identifier" }
        case "enum_item":
            kind = .enum
            nameNode = node.namedChildren.first { $0.kind == "type_identifier" }
        case "trait_item":
            kind = .trait
            nameNode = node.namedChildren.first { $0.kind == "type_identifier" }
        case "impl_item":
            guard let nameNode = implementedTypeName(in: node) else { return nil }
            return (.impl, nameNode)
        case "mod_item":
            kind = .mod
            nameNode = node.namedChildren.first { $0.kind == "identifier" }
        case "const_item":
            kind = .const
            nameNode = node.namedChildren.first { $0.kind == "identifier" }
        case "static_item":
            kind = .static
            nameNode = node.namedChildren.first { $0.kind == "identifier" }
        case "type_item":
            kind = .typeAlias
            nameNode = node.namedChildren.first { $0.kind == "type_identifier" }
        default:
            return nil
        }
        guard let nameNode else { return nil }
        return (kind, nameNode)
    }

    private func implementedTypeName(in node: Node) -> Node? {
        node.namedChildren.last(where: {
            $0.kind != "type_parameters"
                && $0.kind != "where_clause"
                && $0.kind != "declaration_list"
        }).flatMap(typeName)
    }

    private func typeName(in node: Node) -> Node? {
        switch node.kind {
        case "identifier", "type_identifier", "primitive_type":
            return node
        case "scoped_type_identifier":
            for child in node.namedChildren.reversed() {
                if let name = typeName(in: child) { return name }
            }
        default:
            for child in node.namedChildren {
                if let name = typeName(in: child) { return name }
            }
        }
        return nil
    }

    private func coreRange(_ node: Node) -> CodeInsightCore.ByteRange {
        CodeInsightCore.ByteRange(
            lowerBound: node.byteRange.lowerBound,
            upperBound: node.byteRange.upperBound
        )
    }

    private func text(in bytes: [UInt8], range: CodeInsightCore.ByteRange) -> String? {
        let lower = Int(range.lowerBound)
        let upper = Int(range.upperBound)
        guard upper <= bytes.count else { return nil }
        return String(bytes: bytes[lower..<upper], encoding: .utf8)
    }
}

public enum ViewportGating {
    public static func spans(
        _ spans: [HighlightSpan],
        intersectingBytes viewport: Range<UInt32>,
        buffer: UInt32
    ) -> [HighlightSpan] {
        Self.spans(
            spans,
            intersecting: CodeInsightCore.ByteRange(
                lowerBound: viewport.lowerBound,
                upperBound: viewport.upperBound
            ),
            buffer: buffer
        )
    }

    public static func spans(
        _ spans: [HighlightSpan],
        intersecting viewport: CodeInsightCore.ByteRange,
        buffer: UInt32
    ) -> [HighlightSpan] {
        let lower = viewport.lowerBound > buffer ? viewport.lowerBound - buffer : 0
        let upper = UInt32(min(
            UInt64(UInt32.max),
            UInt64(viewport.upperBound) + UInt64(buffer)
        ))
        let buffered = CodeInsightCore.ByteRange(lowerBound: lower, upperBound: upper)
        guard buffered.lowerBound < buffered.upperBound else { return [] }

        var low = 0
        var high = spans.count
        while low < high {
            let middle = low + (high - low) / 2
            if spans[middle].range.upperBound <= buffered.lowerBound {
                low = middle + 1
            } else {
                high = middle
            }
        }

        var result: [HighlightSpan] = []
        for span in spans[low...] {
            guard span.range.lowerBound < buffered.upperBound else { break }
            if span.range.overlaps(buffered) { result.append(span) }
        }
        return result
    }
}

public struct DocumentLoader: Sendable {
    public typealias ContentSource = @Sendable (URL) throws -> [UInt8]

    private let source: ContentSource

    public init(source: @escaping ContentSource = { file in
        Array(try Data(contentsOf: file, options: .mappedIfSafe))
    }) {
        self.source = source
    }

    public func load(
        file: URL
    ) throws -> (document: ReaderDocument, tier: FileTier) {
        let bytes = try source(file)
        guard String(bytes: bytes, encoding: .utf8) != nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let lineTable = LineTable(bytes: bytes)
        let map = ByteUTF16Map(validUTF8: bytes)
        let contentID = ContentID.sha256(of: bytes)
        let tier = FileTier(lineCount: lineTable.lineStarts.count)
        let plain = ReaderDocument(
            bytes: bytes,
            contentID: contentID,
            lineTable: lineTable,
            byteUTF16Map: map,
            highlightSpans: [],
            outlineFacets: []
        )

        if tier == .regular {
            let highlighted = try RustHighlighter().highlight(bytes: bytes)
            return (ReaderDocument(
                bytes: bytes,
                contentID: contentID,
                lineTable: lineTable,
                byteUTF16Map: map,
                highlightSpans: highlighted.spans,
                outlineFacets: highlighted.outlineFacets
            ), tier)
        }

        return (plain, tier)
    }

    public func loadSyntax(
        for document: ReaderDocument,
        completion: @escaping @Sendable (
            Result<ReaderDocument, RustHighlighterError>
        ) -> Void
    ) {
        Task.detached(priority: .userInitiated) {
            do {
                let highlighted = try RustHighlighter().highlight(bytes: document.bytes)
                completion(.success(ReaderDocument(
                    bytes: document.bytes,
                    contentID: document.contentID,
                    lineTable: document.lineTable,
                    byteUTF16Map: document.byteUTF16Map,
                    highlightSpans: highlighted.spans,
                    outlineFacets: highlighted.outlineFacets
                )))
            } catch let error as RustHighlighterError {
                completion(.failure(error))
            } catch {
                completion(.failure(.parseFailed))
            }
        }
    }
}
