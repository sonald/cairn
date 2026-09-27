import CodeInsightCore
import Foundation

/// One immutable lexical scan. Query slices retain this index's posting storage.
package struct IdentifierIndex: Sendable {
    package struct Token: Sendable {
        package let range: ByteRange
        package let nameIndex: Int
    }

    package let tokensBySource: [Token]
    package let names: [String]
    package let postingOffsets: [Int]
    package let occurrenceRanges: [ByteRange]
    private let sourceBytes: [UInt8]

    /// Array storage for bytes is shared with ReaderDocument, not copied.
    package var estimatedByteCount: Int {
        // Count retained source bytes conservatively even when COW storage is shared.
        sourceBytes.count + tokensBySource.count * MemoryLayout<Token>.stride
            + postingOffsets.count * MemoryLayout<Int>.stride
            + occurrenceRanges.count * MemoryLayout<ByteRange>.stride
            + names.reduce(0) { $0 + $1.utf8.count + MemoryLayout<String>.stride }
    }

    package init(document: ReaderDocument) throws {
        try self.init(bytes: document.bytes, languageMode: document.languageMode,
                      highlightSpans: document.highlightSpans)
    }

    package init(bytes: [UInt8], languageMode: LanguageMode, highlightSpans: [HighlightSpan]) throws {
        try Task.checkCancellation()
        ReaderWorkCounters.record(\.identifierBuildCount)
        sourceBytes = bytes
        guard bytes.count <= Int(UInt32.max) else { throw CocoaError(.fileReadTooLarge) }
        ReaderWorkCounters.record(\.identifierDecodedBytes, bytes.count)
        guard let source = String(bytes: bytes, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        guard languageMode.language != .javascript else {
            tokensBySource = []; names = []; postingOffsets = [0]; occurrenceRanges = []
            return
        }

        var excluded: [ByteRange] = []
        for span in highlightSpans.filter({ Self.excludes($0.kind) }).sorted(by: {
            $0.range.lowerBound < $1.range.lowerBound
        }) {
            guard span.range.lowerBound < span.range.upperBound else { continue }
            if let last = excluded.last, span.range.lowerBound <= last.upperBound {
                excluded[excluded.count - 1] = ByteRange(
                    lowerBound: last.lowerBound, upperBound: max(last.upperBound, span.range.upperBound))
            } else {
                excluded.append(span.range)
            }
        }

        let scalars = source.unicodeScalars
        var cursor = scalars.startIndex
        var byteOffset: UInt32 = 0
        var cancellationCountdown = 4096
        var tokens: [Token] = []
        var interned: [String: Int] = [:]
        var names: [String] = []
        var postings: [[ByteRange]] = []
        var exclusionCursor = 0
        defer { ReaderWorkCounters.record(\.identifierScannedBytes, Int(byteOffset)) }

        func isStart(_ scalar: Unicode.Scalar) -> Bool {
            scalar == "_" || (languageMode.language == .typescript && scalar == "$")
                || scalar.properties.isXIDStart
        }
        func isContinue(_ scalar: Unicode.Scalar) -> Bool {
            scalar == "_" || (languageMode.language == .typescript && scalar == "$")
                || scalar.properties.isXIDContinue
        }
        func advance() throws {
            byteOffset += UInt32(scalars[cursor].utf8.count)
            cursor = scalars.index(after: cursor)
            cancellationCountdown -= 1
            if cancellationCountdown == 0 {
                try Task.checkCancellation()
                cancellationCountdown = 4096
            }
        }

        while cursor < scalars.endIndex {
            guard isContinue(scalars[cursor]) else {
                try advance()
                continue
            }
            // The old query rejects "1name", but its occurrence scan finds the
            // "name" suffix when another selectable "name" is clicked.
            let selectable = isStart(scalars[cursor])
            while cursor < scalars.endIndex, isContinue(scalars[cursor]), !isStart(scalars[cursor]) {
                try advance()
            }
            guard cursor < scalars.endIndex, isStart(scalars[cursor]) else { continue }
            let start = cursor
            let lower = byteOffset
            while cursor < scalars.endIndex, isContinue(scalars[cursor]) {
                try advance()
            }
            let name = String(scalars[start..<cursor])
            guard !Self.isKeyword(name, languageMode: languageMode) else { continue }
            let nameIndex: Int
            if let existing = interned[name] {
                nameIndex = existing
            } else {
                nameIndex = names.count
                interned[name] = nameIndex
                names.append(name)
                postings.append([])
            }
            let range = ByteRange(lowerBound: lower, upperBound: byteOffset)
            if selectable { tokens.append(Token(range: range, nameIndex: nameIndex)) }
            while exclusionCursor < excluded.count, excluded[exclusionCursor].upperBound <= lower {
                exclusionCursor += 1
            }
            if exclusionCursor == excluded.count || !excluded[exclusionCursor].overlaps(range) {
                postings[nameIndex].append(range)
            }
        }
        try Task.checkCancellation()
        var offsets = [0]
        var ranges: [ByteRange] = []
        ranges.reserveCapacity(postings.reduce(0) { $0 + $1.count })
        for posting in postings {
            try Task.checkCancellation()
            ranges.append(contentsOf: posting)
            offsets.append(ranges.count)
        }
        tokensBySource = tokens
        self.names = names
        postingOffsets = offsets
        occurrenceRanges = ranges
    }

    package func occurrences(at byteOffset: UInt32) -> ArraySlice<ByteRange> {
        guard Int(byteOffset) < sourceBytes.count,
              sourceBytes[Int(byteOffset)] & 0xC0 != 0x80 else { return occurrenceRanges[0..<0] }
        var lower = 0
        var upper = tokensBySource.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if tokensBySource[middle].range.lowerBound <= byteOffset {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower > 0, tokensBySource[lower - 1].range.contains(byteOffset) else {
            return occurrenceRanges[0..<0]
        }
        let name = tokensBySource[lower - 1].nameIndex
        return occurrenceRanges[postingOffsets[name]..<postingOffsets[name + 1]]
    }

    private static func isKeyword(_ value: String, languageMode: LanguageMode) -> Bool {
        switch languageMode.language {
        case .rust: RustHighlighter.isKeyword(value)
        case .python: pythonReaderIsKeyword(value)
        case .typescript: typeScriptReaderIsKeyword(value)
        case .javascript: true
        }
    }

    private static func excludes(_ kind: HighlightKind) -> Bool {
        switch kind {
        case .keyword, .comment, .commentFigure, .string, .number: true
        default: false
        }
    }
}
