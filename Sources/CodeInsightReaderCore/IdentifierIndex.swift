import CodeInsightCore
import Foundation

/// Paired `()`, `[]`, `{}` outside strings and comments, from one byte scan.
package struct BracketPairs: Sendable {
    /// Byte offsets of every counted bracket, ascending.
    package let offsets: [UInt32]
    /// Index into `offsets` of each bracket's partner, or -1 when unmatched.
    package let partners: [Int32]

    package static let empty = BracketPairs(offsets: [], partners: [])

    private init(offsets: [UInt32], partners: [Int32]) {
        self.offsets = offsets
        self.partners = partners
    }

    /// `excluded` must be sorted and non-overlapping (strings and comments).
    package init(bytes: [UInt8], excluded: [ByteRange]) {
        var offsets: [UInt32] = []
        var partners: [Int32] = []
        var stack: [Int] = []
        var exclusionCursor = 0
        for (index, byte) in bytes.enumerated() {
            guard let kind = Self.kind(of: byte) else { continue }
            let offset = UInt32(index)
            while exclusionCursor < excluded.count, excluded[exclusionCursor].upperBound <= offset {
                exclusionCursor += 1
            }
            if exclusionCursor < excluded.count, excluded[exclusionCursor].contains(offset) { continue }
            let position = offsets.count
            offsets.append(offset)
            partners.append(-1)
            if kind.isOpening {
                stack.append(position)
            } else if let top = stack.last, Self.kind(of: bytes[Int(offsets[top])])?.shape == kind.shape {
                stack.removeLast()
                partners[top] = Int32(position)
                partners[position] = Int32(top)
            }
            // A closer that does not match the innermost opener stays unmatched
            // and leaves the stack alone, so one stray bracket damages only itself.
        }
        self.offsets = offsets
        self.partners = partners
    }

    /// The bracket that starts at `offset`, if any.
    package func bracket(at offset: UInt32) -> (offset: UInt32, partner: UInt32?)? {
        guard let index = index(of: offset) else { return nil }
        let partner = partners[index]
        return (offsets[index], partner < 0 ? nil : offsets[Int(partner)])
    }

    /// The innermost matched pair whose interior covers `lower..<upper`, other
    /// than the pair whose interior is exactly that range; repeated calls with
    /// the previous interior therefore widen one level at a time.
    package func enclosingPair(lower: UInt32, upper: UInt32) -> (open: UInt32, close: UInt32)? {
        var low = 0
        var high = offsets.count
        while low < high {
            let middle = low + (high - low) / 2
            if offsets[middle] < lower { low = middle + 1 } else { high = middle }
        }
        var index = low - 1
        while index >= 0 {
            let partner = partners[index]
            if partner > index {
                let open = offsets[index]
                let close = offsets[Int(partner)]
                if close >= upper, !(open + 1 == lower && close == upper) {
                    return (open, close)
                }
            }
            index -= 1
        }
        return nil
    }

    var estimatedByteCount: Int {
        offsets.count * (MemoryLayout<UInt32>.stride + MemoryLayout<Int32>.stride)
    }

    private func index(of offset: UInt32) -> Int? {
        var low = 0
        var high = offsets.count
        while low < high {
            let middle = low + (high - low) / 2
            if offsets[middle] < offset { low = middle + 1 } else { high = middle }
        }
        return low < offsets.count && offsets[low] == offset ? low : nil
    }

    private struct Kind {
        let shape: UInt8
        let isOpening: Bool
    }

    private static func kind(of byte: UInt8) -> Kind? {
        switch byte {
        case UInt8(ascii: "("): Kind(shape: 0, isOpening: true)
        case UInt8(ascii: ")"): Kind(shape: 0, isOpening: false)
        case UInt8(ascii: "["): Kind(shape: 1, isOpening: true)
        case UInt8(ascii: "]"): Kind(shape: 1, isOpening: false)
        case UInt8(ascii: "{"): Kind(shape: 2, isOpening: true)
        case UInt8(ascii: "}"): Kind(shape: 2, isOpening: false)
        default: nil
        }
    }
}

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
    package let brackets: BracketPairs
    private let sourceBytes: [UInt8]

    /// Array storage for bytes is shared with ReaderDocument, not copied.
    package var estimatedByteCount: Int {
        // Count retained source bytes conservatively even when COW storage is shared.
        sourceBytes.count + tokensBySource.count * MemoryLayout<Token>.stride
            + postingOffsets.count * MemoryLayout<Int>.stride
            + occurrenceRanges.count * MemoryLayout<ByteRange>.stride
            + names.reduce(0) { $0 + $1.utf8.count + MemoryLayout<String>.stride }
            + brackets.estimatedByteCount
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
            brackets = .empty
            return
        }

        let excluded = Self.mergedRanges(of: highlightSpans, where: Self.excludes)

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
        brackets = BracketPairs(
            bytes: bytes,
            excluded: Self.mergedRanges(of: highlightSpans, where: Self.hidesBrackets)
        )
    }

    /// The identifier token covering `byteOffset`, if one does.
    package func name(at byteOffset: UInt32) -> String? {
        guard let index = tokenIndex(at: byteOffset) else { return nil }
        return names[tokensBySource[index].nameIndex]
    }

    /// Every counted occurrence of `name`, in source order.
    package func occurrences(named name: String) -> ArraySlice<ByteRange> {
        guard let nameIndex = names.firstIndex(of: name) else { return occurrenceRanges[0..<0] }
        return occurrenceRanges[postingOffsets[nameIndex]..<postingOffsets[nameIndex + 1]]
    }

    package func occurrences(at byteOffset: UInt32) -> ArraySlice<ByteRange> {
        guard let index = tokenIndex(at: byteOffset) else { return occurrenceRanges[0..<0] }
        let name = tokensBySource[index].nameIndex
        return occurrenceRanges[postingOffsets[name]..<postingOffsets[name + 1]]
    }

    private func tokenIndex(at byteOffset: UInt32) -> Int? {
        guard Int(byteOffset) < sourceBytes.count,
              sourceBytes[Int(byteOffset)] & 0xC0 != 0x80 else { return nil }
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
        guard lower > 0, tokensBySource[lower - 1].range.contains(byteOffset) else { return nil }
        return lower - 1
    }

    private static func isKeyword(_ value: String, languageMode: LanguageMode) -> Bool {
        switch languageMode.language {
        case .rust: RustHighlighter.isKeyword(value)
        case .python: pythonReaderIsKeyword(value)
        case .typescript: typeScriptReaderIsKeyword(value)
        case .javascript: true
        }
    }

    /// Sorted, non-overlapping union of the spans whose kind passes `include`.
    private static func mergedRanges(
        of spans: [HighlightSpan], where include: (HighlightKind) -> Bool
    ) -> [ByteRange] {
        var merged: [ByteRange] = []
        for span in spans.filter({ include($0.kind) }).sorted(by: {
            $0.range.lowerBound < $1.range.lowerBound
        }) {
            guard span.range.lowerBound < span.range.upperBound else { continue }
            if let last = merged.last, span.range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = ByteRange(
                    lowerBound: last.lowerBound, upperBound: max(last.upperBound, span.range.upperBound))
            } else {
                merged.append(span.range)
            }
        }
        return merged
    }

    private static func hidesBrackets(_ kind: HighlightKind) -> Bool {
        switch kind {
        case .comment, .commentFigure, .string: true
        default: false
        }
    }

    private static func excludes(_ kind: HighlightKind) -> Bool {
        switch kind {
        case .keyword, .comment, .commentFigure, .string, .number: true
        default: false
        }
    }
}
