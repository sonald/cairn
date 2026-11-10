import CodeInsightCore
import Foundation

extension TextFormat {
    /// A reader document for a code-like text preview, so it folds like
    /// source. Bundled grammars keep their syntax folds; the lexical formats
    /// fold by sections (TOML, INI), files and hunks (diff) or indentation.
    /// `format == nil` is unhighlighted text folded by indentation.
    package static func previewDocument(bytes: [UInt8], format: TextFormat?) -> ReaderDocument {
        let lineTable = LineTable(bytes: bytes)
        let map = ByteUTF16Map(validUTF8: bytes)
        if case .syntaxTree(let mode) = format, map.utf16Count <= CodeSnippetHighlighter.snippetUTF16Limit {
            let parseMode = mode.language == .javascript ? LanguageMode(language: .typescript, variant: "tsx") : mode
            if let highlighted = try? DocumentLoader.highlightWithFolds(
                bytes: bytes, languageMode: parseMode, resolutionObserver: nil
            ) {
                return ReaderDocument(
                    bytes: bytes, languageMode: parseMode, lineTable: lineTable, byteUTF16Map: map,
                    highlightSpans: highlighted.spans, outlineFacets: highlighted.outlineFacets,
                    foldRegions: highlighted.folds, localBindings: highlighted.bindings,
                    referencesByBinding: highlighted.referencesByBinding, analysisPhase: .syntax
                )
            }
        }
        let spans = format.map { $0.highlight(String(decoding: bytes, as: UTF8.self)) } ?? []
        return ReaderDocument(
            bytes: bytes,
            // ponytail: `.javascript` is the reader's "no identifier analysis"
            // mode; a neutral LanguageID would reach the index and Exact.
            languageMode: LanguageMode(language: .javascript),
            lineTable: lineTable,
            byteUTF16Map: map,
            highlightSpans: spans.compactMap { span in
                guard let lower = map.byteOffset(forUTF16: span.range.lowerBound),
                      let upper = map.byteOffset(forUTF16: span.range.upperBound),
                      lower < upper
                else { return nil }
                return HighlightSpan(range: ByteRange(lowerBound: UInt32(lower), upperBound: UInt32(upper)), kind: span.kind)
            },
            outlineFacets: [],
            foldRegions: lexicalFoldRegions(bytes: bytes, lineTable: lineTable, format: format),
            analysisPhase: .syntax
        )
    }

    static func lexicalFoldRegions(bytes: [UInt8], lineTable: LineTable, format: TextFormat?) -> [FoldRegion] {
        var host = format
        if case .jinja(let inner) = format { host = inner }
        let lines = LexicalLines(bytes: bytes, lineTable: lineTable)
        var accumulator = FoldCandidateAccumulator()
        func emit(header: Int, last: Int, depth: Int) {
            guard last > header else { return }
            accumulator.appendCandidate(
                kind: .block,
                headerRange: ByteRange(lowerBound: lines.start(header), upperBound: lines.contentEnd(header)),
                bodyRange: ByteRange(lowerBound: lines.contentEnd(header), upperBound: lines.contentEnd(last)),
                foldDepth: depth,
                bytes: bytes
            )
        }
        switch host {
        case .toml, .ini:
            lines.sections(level: { lines.firstByte($0) == UInt8(ascii: "[") ? 0 : nil }, emit: emit)
        case .diff:
            lines.sections(level: {
                if lines.hasPrefix("diff ", $0) { return 0 }
                return lines.hasPrefix("@@", $0) ? 1 : nil
            }, emit: emit)
        default:
            lines.indentation(yamlSequences: host == .yaml, emit: emit)
        }
        return accumulator.resolve(outlineFacets: [], observer: nil)
    }
}

/// Line geometry for the lexical folders. A fold's header is its line; its
/// body runs from the header's line end to the last non-blank line it owns,
/// so the placeholder sits on the header line and trailing blanks stay.
private struct LexicalLines {
    let bytes: [UInt8]
    let lineTable: LineTable
    var count: Int { lineTable.lineStarts.count }

    func start(_ line: Int) -> UInt32 { lineTable.lineStarts[line] }

    func contentEnd(_ line: Int) -> UInt32 {
        var end = line + 1 < count ? Int(lineTable.lineStarts[line + 1]) - 1 : bytes.count
        if end > Int(start(line)), bytes[end - 1] == 0x0D { end -= 1 }
        return UInt32(end)
    }

    /// Leading whitespace width (tab = 4), or nil for a blank line.
    func indent(_ line: Int) -> Int? {
        var width = 0
        for index in Int(start(line))..<Int(contentEnd(line)) {
            switch bytes[index] {
            case 0x20: width += 1
            case 0x09: width += 4
            default: return width
            }
        }
        return nil
    }

    /// The line after its indentation.
    func content(_ line: Int) -> ArraySlice<UInt8> {
        bytes[Int(start(line))..<Int(contentEnd(line))].drop { $0 == 0x20 || $0 == 0x09 }
    }

    func firstByte(_ line: Int) -> UInt8? { content(line).first }

    func hasPrefix(_ prefix: String, _ line: Int) -> Bool {
        bytes[Int(start(line))..<Int(contentEnd(line))].starts(with: prefix.utf8)
    }

    /// Every non-blank line owns the following lines indented deeper than it.
    /// In YAML a `- ` item counts one deeper, so a key owns its flush list.
    func indentation(yamlSequences: Bool, emit: (Int, Int, Int) -> Void) {
        var open: [(line: Int, indent: Int)] = []
        var previous: Int?
        for line in 0..<count {
            guard var width = indent(line) else { continue }
            if yamlSequences, content(line).starts(with: "- ".utf8) || content(line).elementsEqual("-".utf8) {
                width += 1
            }
            while let top = open.last, top.indent >= width {
                open.removeLast()
                emit(top.line, previous!, open.count)
            }
            open.append((line, width))
            previous = line
        }
        while let top = open.popLast() { emit(top.line, previous!, open.count) }
    }

    /// Header lines open sections that run until a header of the same or a
    /// lower level.
    func sections(level: (Int) -> Int?, emit: (Int, Int, Int) -> Void) {
        var open: [(line: Int, level: Int)] = []
        var previous: Int?
        for line in 0..<count where indent(line) != nil {
            if let level = level(line) {
                while let top = open.last, top.level >= level {
                    open.removeLast()
                    emit(top.line, previous!, open.count)
                }
                open.append((line, level))
            }
            previous = line
        }
        while let top = open.popLast() { emit(top.line, previous!, open.count) }
    }
}
