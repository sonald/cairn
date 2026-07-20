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

public struct OutlineFacet: Equatable, Sendable {
    public let name: String
    public let range: CodeInsightCore.ByteRange

    public init(name: String, range: CodeInsightCore.ByteRange) {
        self.name = name
        self.range = range
    }
}

public struct ReaderDocument: Sendable {
    public let bytes: [UInt8]
    public let lineTable: LineTable
    public let byteUTF16Map: ByteUTF16Map
    public let highlightSpans: [HighlightSpan]
    public let outlineFacets: [OutlineFacet]

    public init(
        bytes: [UInt8],
        lineTable: LineTable,
        byteUTF16Map: ByteUTF16Map,
        highlightSpans: [HighlightSpan],
        outlineFacets: [OutlineFacet]
    ) {
        self.bytes = bytes
        self.lineTable = lineTable
        self.byteUTF16Map = byteUTF16Map
        self.highlightSpans = highlightSpans
        self.outlineFacets = outlineFacets
    }

    public init(
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
        var stack = [tree.rootNode]
        while let node = stack.popLast() {
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

            if kind == "function_item",
               let nameNode = node.namedChildren.first(where: { $0.kind == "identifier" }) {
                let range = coreRange(nameNode)
                spans.append(HighlightSpan(range: range, kind: .functionName))
                // S3 only consumes function outline names/ranges, so collect them in
                // this existing walk instead of running RustExtractor a second time.
                if let name = text(in: bytes, range: range) {
                    facets.append(OutlineFacet(name: name, range: range))
                }
            }

            for index in (0..<node.childCount).reversed() {
                if let child = node.child(at: index) { stack.append(child) }
            }
        }
        spans.sort {
            ($0.range.lowerBound, $0.range.upperBound, $0.kind.rawValue)
                < ($1.range.lowerBound, $1.range.upperBound, $1.kind.rawValue)
        }
        return (spans, facets)
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
        return spans.filter { $0.range.overlaps(buffered) }
    }
}

public struct DocumentLoader: Sendable {
    public init() {}

    public func load(
        file: URL
    ) throws -> (document: ReaderDocument, tier: FileTier) {
        let bytes = Array(try Data(contentsOf: file, options: .mappedIfSafe))
        guard String(bytes: bytes, encoding: .utf8) != nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let lineTable = LineTable(bytes: bytes)
        let map = ByteUTF16Map(validUTF8: bytes)
        let tier = FileTier(lineCount: lineTable.lineStarts.count)
        let plain = ReaderDocument(
            bytes: bytes,
            lineTable: lineTable,
            byteUTF16Map: map,
            highlightSpans: [],
            outlineFacets: []
        )

        if tier == .regular {
            let highlighted = try RustHighlighter().highlight(bytes: bytes)
            return (ReaderDocument(
                bytes: bytes,
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
