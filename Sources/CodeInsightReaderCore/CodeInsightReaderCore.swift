import CTreeSitterRust
import CodeInsightCore
import CodeInsightRustExtractor
import Foundation
import TreeSitterKit

public enum HighlightKind: UInt8, Sendable {
    case keyword
    case comment
    case string
    case number
    case functionName
    case typeName
    case declarationTitle
    case declarationEmphasis
    case commentFigure
}

public enum CommentContentKind: Sendable {
    case prose
    case figure

    public static func classify(_ text: String) -> Self {
        if text.unicodeScalars.contains(where: {
            (0x2500...0x259F).contains($0.value)
        }) {
            return .figure
        }

        let lines = text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        if lines.contains(where: isFigureLine) {
            return .figure
        }

        var alignedColumnCounts: [Int: Int] = [:]
        for line in lines {
            for column in alignedColumnStarts(in: line) {
                alignedColumnCounts[column, default: 0] += 1
            }
        }
        return alignedColumnCounts.values.contains(where: { $0 >= 2 })
            ? .figure
            : .prose
    }

    private static func isFigureLine(_ line: String) -> Bool {
        if line.contains("---") || line.contains("===") {
            return true
        }
        let plusCount = line.lazy.filter { $0 == "+" }.count
        if plusCount >= 2 && (line.contains("--") || line.contains("==")) {
            return true
        }
        return line.lazy.filter { $0 == "|" }.count >= 2
    }

    private static func alignedColumnStarts(in line: String) -> Set<Int> {
        let characters = Array(line)
        var result: Set<Int> = []
        var index = 0
        while index < characters.count {
            guard characters[index].isWhitespace else {
                index += 1
                continue
            }
            let start = index
            while index < characters.count, characters[index].isWhitespace {
                index += 1
            }
            if start > 0, index < characters.count, index - start >= 2 {
                result.insert(start)
            }
        }
        return result
    }
}

public struct HighlightSpan: Equatable, Sendable {
    public let range: CodeInsightCore.ByteRange
    public let kind: HighlightKind

    public init(range: CodeInsightCore.ByteRange, kind: HighlightKind) {
        self.range = range
        self.kind = kind
    }
}

public enum OutlineKind: String, Hashable, Sendable {
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
    case `class`
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
    public let languageMode: LanguageMode
    public let lineTable: LineTable
    public let byteUTF16Map: ByteUTF16Map
    public let highlightSpans: [HighlightSpan]
    public let outlineFacets: [OutlineFacet]
    package let foldRegions: [FoldRegion]
    public let localBindings: [BindingRecord]
    public let referencesByBinding: [[CodeInsightCore.ByteRange]]

    private let localReferenceRanges: [CodeInsightCore.ByteRange]
    private let localReferenceBindingIndices: [Int]

    package init(
        bytes: [UInt8],
        languageMode: LanguageMode = LanguageMode(language: .rust),
        contentID: ContentID? = nil,
        lineTable: LineTable,
        byteUTF16Map: ByteUTF16Map,
        highlightSpans: [HighlightSpan],
        outlineFacets: [OutlineFacet],
        foldRegions: [FoldRegion],
        localBindings: [BindingRecord] = [],
        referencesByBinding: [[CodeInsightCore.ByteRange]] = []
    ) {
        precondition(localBindings.count == referencesByBinding.count)
        self.bytes = bytes
        self.contentID = contentID ?? ContentID.sha256(of: bytes)
        self.languageMode = languageMode
        self.lineTable = lineTable
        self.byteUTF16Map = byteUTF16Map
        self.highlightSpans = highlightSpans
        self.outlineFacets = outlineFacets
        self.foldRegions = foldRegions
        self.localBindings = localBindings
        self.referencesByBinding = referencesByBinding
        let references = referencesByBinding.enumerated().flatMap {
            bindingIndex, ranges in
            ranges.map { (range: $0, bindingIndex: bindingIndex) }
        }.sorted {
            ($0.range.lowerBound, $0.range.upperBound)
                < ($1.range.lowerBound, $1.range.upperBound)
        }
        localReferenceRanges = references.map(\.range)
        localReferenceBindingIndices = references.map(\.bindingIndex)
    }

    public convenience init(
        bytes: [UInt8],
        languageMode: LanguageMode = LanguageMode(language: .rust),
        contentID: ContentID? = nil,
        lineTable: LineTable,
        byteUTF16Map: ByteUTF16Map,
        highlightSpans: [HighlightSpan],
        outlineFacets: [OutlineFacet],
        localBindings: [BindingRecord] = [],
        referencesByBinding: [[CodeInsightCore.ByteRange]] = []
    ) {
        self.init(
            bytes: bytes,
            languageMode: languageMode,
            contentID: contentID,
            lineTable: lineTable,
            byteUTF16Map: byteUTF16Map,
            highlightSpans: highlightSpans,
            outlineFacets: outlineFacets,
            foldRegions: [],
            localBindings: localBindings,
            referencesByBinding: referencesByBinding
        )
    }

    public convenience init(
        bytes: [UInt8],
        languageMode: LanguageMode = LanguageMode(language: .rust),
        highlightSpans: [HighlightSpan] = [],
        outlineFacets: [OutlineFacet] = [],
        localBindings: [BindingRecord] = [],
        referencesByBinding: [[CodeInsightCore.ByteRange]] = []
    ) {
        self.init(
            bytes: bytes,
            languageMode: languageMode,
            lineTable: LineTable(bytes: bytes),
            byteUTF16Map: ByteUTF16Map(validUTF8: bytes),
            highlightSpans: highlightSpans,
            outlineFacets: outlineFacets,
            localBindings: localBindings,
            referencesByBinding: referencesByBinding
        )
    }

    public func symbolAnchor(at byteOffset: UInt32) -> String? {
        outlineFacets
            .filter { $0.range.contains(byteOffset) }
            .min { $0.range.length < $1.range.length }?
            .name
    }

    public func localBinding(
        at byteOffset: UInt32
    ) -> (
        bindingIndex: Int,
        binding: BindingRecord,
        references: [CodeInsightCore.ByteRange]
    )? {
        var low = 0
        var high = localBindings.count
        while low < high {
            let middle = low + (high - low) / 2
            if localBindings[middle].declarationRange.lowerBound <= byteOffset {
                low = middle + 1
            } else {
                high = middle
            }
        }
        if low > 0,
           localBindings[low - 1].declarationRange.contains(byteOffset)
        {
            let index = low - 1
            return (index, localBindings[index], referencesByBinding[index])
        }

        low = 0
        high = localReferenceRanges.count
        while low < high {
            let middle = low + (high - low) / 2
            if localReferenceRanges[middle].lowerBound <= byteOffset {
                low = middle + 1
            } else {
                high = middle
            }
        }
        guard low > 0,
              localReferenceRanges[low - 1].contains(byteOffset)
        else { return nil }
        let index = localReferenceBindingIndices[low - 1]
        return (index, localBindings[index], referencesByBinding[index])
    }

    public func localReferences(
        intersectingBytes viewport: Range<UInt32>,
        buffer: UInt32 = 0
    ) -> [(
        range: CodeInsightCore.ByteRange,
        bindingIndex: Int,
        kind: BindingKind
    )] {
        let lower = viewport.lowerBound > buffer
            ? viewport.lowerBound - buffer
            : 0
        let upper = UInt32(min(
            UInt64(UInt32.max),
            UInt64(viewport.upperBound) + UInt64(buffer)
        ))
        guard lower < upper else { return [] }

        var low = 0
        var high = localReferenceRanges.count
        while low < high {
            let middle = low + (high - low) / 2
            if localReferenceRanges[middle].upperBound <= lower {
                low = middle + 1
            } else {
                high = middle
            }
        }

        var result: [(
            range: CodeInsightCore.ByteRange,
            bindingIndex: Int,
            kind: BindingKind
        )] = []
        for referenceIndex in low..<localReferenceRanges.count {
            let range = localReferenceRanges[referenceIndex]
            guard range.lowerBound < upper else { break }
            let bindingIndex = localReferenceBindingIndices[referenceIndex]
            result.append((
                range,
                bindingIndex,
                localBindings[bindingIndex].kind
            ))
        }
        return result
    }

    public func identifierOccurrences(at byteOffset: UInt32) -> [CodeInsightCore.ByteRange] {
        switch languageMode.language {
        case .rust, .python, .typescript:
            break
        case .javascript:
            return []
        }
        guard byteOffset < bytes.count,
              let source = String(bytes: bytes, encoding: .utf8),
              let selectedIndex = source.utf8.index(
                  source.utf8.startIndex,
                  offsetBy: Int(byteOffset),
                  limitedBy: source.utf8.endIndex
              )?.samePosition(in: source.unicodeScalars),
              selectedIndex < source.unicodeScalars.endIndex,
              isIdentifierContinue(source.unicodeScalars[selectedIndex])
        else { return [] }

        let scalars = source.unicodeScalars
        var lower = selectedIndex
        while lower > scalars.startIndex {
            let previous = scalars.index(before: lower)
            guard isIdentifierContinue(scalars[previous]) else { break }
            lower = previous
        }
        guard isIdentifierStart(scalars[lower]) else { return [] }

        var upper = selectedIndex
        while upper < scalars.endIndex,
              isIdentifierContinue(scalars[upper])
        {
            upper = scalars.index(after: upper)
        }
        let selected = String(scalars[lower..<upper])
        switch languageMode.language {
        case .rust:
            guard !RustHighlighter.isKeyword(selected) else { return [] }
        case .python:
            guard !pythonReaderIsKeyword(selected) else { return [] }
        case .typescript:
            guard !typeScriptReaderIsKeyword(selected) else { return [] }
        case .javascript:
            return []
        }

        var spanIndex = 0
        var result: [CodeInsightCore.ByteRange] = []
        var index = scalars.startIndex
        var bytePosition: UInt32 = 0
        while index < scalars.endIndex {
            let scalar = scalars[index]
            guard isIdentifierStart(scalar) else {
                bytePosition += UInt32(scalar.utf8.count)
                index = scalars.index(after: index)
                continue
            }

            let tokenStart = index
            let lowerByte = bytePosition
            while index < scalars.endIndex,
                  isIdentifierContinue(scalars[index])
            {
                bytePosition += UInt32(scalars[index].utf8.count)
                index = scalars.index(after: index)
            }
            guard String(scalars[tokenStart..<index]) == selected else { continue }
            let range = CodeInsightCore.ByteRange(
                lowerBound: lowerByte,
                upperBound: bytePosition
            )
            while highlightSpans.indices.contains(spanIndex),
                  highlightSpans[spanIndex].range.upperBound <= range.lowerBound
            {
                spanIndex += 1
            }
            var probe = spanIndex
            var excluded = false
            while highlightSpans.indices.contains(probe),
                  highlightSpans[probe].range.lowerBound < range.upperBound
            {
                if Self.excludesOccurrences(highlightSpans[probe].kind),
                   highlightSpans[probe].range.overlaps(range)
                {
                    excluded = true
                    break
                }
                probe += 1
            }
            if !excluded {
                result.append(range)
            }
        }
        return result
    }

    private func isIdentifierStart(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "_"
            || (languageMode.language == .typescript && scalar == "$")
            || scalar.properties.isXIDStart
    }

    private func isIdentifierContinue(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "_"
            || (languageMode.language == .typescript && scalar == "$")
            || scalar.properties.isXIDContinue
    }

    private static func excludesOccurrences(_ kind: HighlightKind) -> Bool {
        switch kind {
        case .keyword, .comment, .commentFigure, .string, .number:
            true
        case .functionName, .typeName, .declarationTitle, .declarationEmphasis:
            false
        }
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
    case unsupportedLanguage(LanguageID)
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

    public static func isKeyword(_ value: String) -> Bool {
        keywords.contains(value)
    }

    public func highlight(
        bytes: [UInt8]
    ) throws -> (
        spans: [HighlightSpan],
        outlineFacets: [OutlineFacet],
        bindings: [BindingRecord],
        referencesByBinding: [[CodeInsightCore.ByteRange]]
    ) {
        let highlighted = try highlightWithFolds(bytes: bytes)
        return (
            highlighted.spans,
            highlighted.outlineFacets,
            highlighted.bindings,
            highlighted.referencesByBinding
        )
    }

    package func highlightWithFolds(
        bytes: [UInt8],
        resolutionObserver: (@Sendable (Double, Int, Int) -> Void)? = nil
    ) throws -> (
        spans: [HighlightSpan],
        outlineFacets: [OutlineFacet],
        folds: [FoldRegion],
        bindings: [BindingRecord],
        referencesByBinding: [[CodeInsightCore.ByteRange]]
    ) {
        guard
            let language = tree_sitter_rust(),
            let parser = Parser(language: language)
        else { throw RustHighlighterError.parserUnavailable }
        #if DEBUG
        RustExtractor.parseObserver?()
        #endif
        guard let tree = parser.parse(bytes) else {
            throw RustHighlighterError.parseFailed
        }

        var spans: [HighlightSpan] = []
        var facets: [OutlineFacet] = []
        var foldCandidates = FoldCandidateAccumulator()
        var stack: [(
            node: Node,
            depth: Int,
            foldDepth: Int,
            parentKind: String?,
            member: OutlineKind?
        )] = [
            (tree.rootNode, 0, 0, nil, nil),
        ]
        while let current = stack.popLast() {
            let node = current.node
            let kind = node.kind
            foldCandidates.visit(
                node: node,
                foldDepth: current.foldDepth,
                bytes: bytes
            )
            let highlight: HighlightKind?
            if Self.comments.contains(kind) {
                let range = coreRange(node)
                highlight = text(in: bytes, range: range).map {
                    CommentContentKind.classify($0) == .figure
                        ? .commentFigure
                        : .comment
                } ?? .comment
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
            var declarationNameRange: CodeInsightCore.ByteRange?
            if let outline {
                let nameRange = coreRange(outline.nameNode)
                if let highlight = declarationHighlightKind(for: outline.kind) {
                    spans.append(HighlightSpan(range: nameRange, kind: highlight))
                    declarationNameRange = nameRange
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
            let createsFoldScope = isContainer
                || kind == "struct_item"
                || kind == "enum_item"
                || kind == "function_item"
                || kind == "if_expression"
                || kind == "else_clause"
                || kind == "for_expression"
                || kind == "loop_expression"
                || kind == "while_expression"
                || kind == "async_block"
                || kind == "unsafe_block"
                || kind == "const_block"
                || kind == "try_block"
                || kind == "gen_block"
                || kind == "closure_expression"
                || kind == "match_expression"
                || kind == "match_arm"
            let childFoldDepth = current.foldDepth + (createsFoldScope ? 1 : 0)
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
                    if let declarationNameRange,
                       coreRange(child) == declarationNameRange
                    {
                        continue
                    }
                    stack.append((child, childDepth, childFoldDepth, kind, childMember))
                }
            }
        }
        spans.sort {
            ($0.range.lowerBound, $0.range.upperBound, $0.kind.rawValue)
                < ($1.range.lowerBound, $1.range.upperBound, $1.kind.rawValue)
        }
        let references = RustExtractor().localReferences(
            tree: tree,
            bytes: bytes
        )
        let folds = foldCandidates.resolve(
            outlineFacets: facets,
            observer: resolutionObserver
        )
        return (
            spans,
            facets,
            folds,
            references.bindings,
            references.referencesByBinding
        )
    }

    private func declarationHighlightKind(
        for kind: OutlineKind
    ) -> HighlightKind? {
        switch kind {
        case .fn, .method:
            .functionName
        case .struct, .enum, .trait, .typeAlias, .class:
            .declarationTitle
        case .mod, .const, .static:
            .declarationEmphasis
        case .impl:
            nil
        }
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
    private let foldResolutionObserver: (@Sendable (Double, Int, Int) -> Void)?

    public init(source: @escaping ContentSource = { file in
        Array(try Data(contentsOf: file, options: .mappedIfSafe))
    }) {
        self.source = source
        foldResolutionObserver = nil
    }

    package init(
        source: @escaping ContentSource,
        foldResolutionObserver: (@Sendable (Double, Int, Int) -> Void)?
    ) {
        self.source = source
        self.foldResolutionObserver = foldResolutionObserver
    }

    public func load(
        file: URL
    ) throws -> (document: ReaderDocument, tier: FileTier) {
        try load(
            file: file,
            languageMode: LanguageMode(language: .rust)
        )
    }

    public func load(
        file: URL,
        languageMode: LanguageMode
    ) throws -> (document: ReaderDocument, tier: FileTier) {
        try Self.requireSupported(languageMode)
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
            languageMode: languageMode,
            contentID: contentID,
            lineTable: lineTable,
            byteUTF16Map: map,
            highlightSpans: [],
            outlineFacets: [],
            foldRegions: []
        )

        if tier == .regular {
            let highlighted = try Self.highlightWithFolds(
                bytes: bytes,
                languageMode: languageMode,
                resolutionObserver: foldResolutionObserver
            )
            return (ReaderDocument(
                bytes: bytes,
                languageMode: languageMode,
                contentID: contentID,
                lineTable: lineTable,
                byteUTF16Map: map,
                highlightSpans: highlighted.spans,
                outlineFacets: highlighted.outlineFacets,
                foldRegions: highlighted.folds,
                localBindings: highlighted.bindings,
                referencesByBinding: highlighted.referencesByBinding
            ), tier)
        }

        return (plain, tier)
    }

    private static func requireSupported(_ languageMode: LanguageMode) throws {
        switch languageMode.language {
        case .rust, .python:
            return
        case .typescript:
            try requireSupportedTypeScriptReaderMode(languageMode)
        case .javascript:
            throw RustHighlighterError.unsupportedLanguage(languageMode.language)
        }
    }

    package func loadSyntax(
        for document: ReaderDocument
    ) throws -> ReaderDocument {
        try Self.requireSupported(document.languageMode)
        let highlighted = try Self.highlightWithFolds(
            bytes: document.bytes,
            languageMode: document.languageMode,
            resolutionObserver: foldResolutionObserver
        )
        return ReaderDocument(
            bytes: document.bytes,
            languageMode: document.languageMode,
            contentID: document.contentID,
            lineTable: document.lineTable,
            byteUTF16Map: document.byteUTF16Map,
            highlightSpans: highlighted.spans,
            outlineFacets: highlighted.outlineFacets,
            foldRegions: highlighted.folds,
            localBindings: highlighted.bindings,
            referencesByBinding: highlighted.referencesByBinding
        )
    }

    private static func highlightWithFolds(
        bytes: [UInt8],
        languageMode: LanguageMode,
        resolutionObserver: (@Sendable (Double, Int, Int) -> Void)?
    ) throws -> (
        spans: [HighlightSpan],
        outlineFacets: [OutlineFacet],
        folds: [FoldRegion],
        bindings: [BindingRecord],
        referencesByBinding: [[CodeInsightCore.ByteRange]]
    ) {
        switch languageMode.language {
        case .rust:
            return try RustHighlighter().highlightWithFolds(
                bytes: bytes,
                resolutionObserver: resolutionObserver
            )
        case .python:
            try Self.requireSupported(languageMode)
            return try pythonReaderHighlightWithFolds(bytes: bytes)
        case .typescript:
            try Self.requireSupported(languageMode)
            return try typeScriptReaderHighlightWithFolds(
                bytes: bytes,
                mode: languageMode
            )
        case .javascript:
            throw RustHighlighterError.unsupportedLanguage(languageMode.language)
        }
    }

    public func loadSyntax(
        for document: ReaderDocument,
        completion: @escaping @Sendable (
            Result<ReaderDocument, RustHighlighterError>
        ) -> Void
    ) {
        Task.detached(priority: .userInitiated) {
            do {
                completion(.success(try loadSyntax(for: document)))
            } catch let error as RustHighlighterError {
                completion(.failure(error))
            } catch {
                completion(.failure(.parseFailed))
            }
        }
    }
}

#if DEBUG
extension DocumentLoader {
    @TaskLocal package static var pythonParseObserver: (@Sendable () -> Void)?
}
#endif
