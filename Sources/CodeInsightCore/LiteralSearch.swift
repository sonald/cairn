package func asciiFold(_ byte: UInt8) -> UInt8 {
    (0x41...0x5A).contains(byte) ? byte + 0x20 : byte
}

/// Whole-word matching: a hit may not touch an identifier character on either
/// side. Identifier characters match the Reader's lexical scan: Unicode
/// XID_Continue and `_`, plus `$` where the language allows it (TypeScript).
package struct WordBoundary: Sendable {
    package let allowsDollar: Bool

    package init(allowsDollar: Bool) {
        self.allowsDollar = allowsDollar
    }

    package func isWholeWord(_ range: ByteRange, in bytes: [UInt8]) -> Bool {
        let lower = Int(range.lowerBound)
        let upper = Int(range.upperBound)
        guard lower <= upper, upper <= bytes.count else { return false }
        if lower > 0 {
            var start = lower - 1
            // Step back over UTF-8 continuation bytes to the scalar's first byte.
            while start > 0, lower - start < 4, bytes[start] & 0xC0 == 0x80 { start -= 1 }
            if let scalar = Self.scalar(in: bytes, at: start), isIdentifier(scalar) { return false }
        }
        if upper < bytes.count, let scalar = Self.scalar(in: bytes, at: upper), isIdentifier(scalar) {
            return false
        }
        return true
    }

    private func isIdentifier(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "_" || (allowsDollar && scalar == "$") || scalar.properties.isXIDContinue
    }

    private static func scalar(in bytes: [UInt8], at offset: Int) -> Unicode.Scalar? {
        var iterator = bytes[offset..<min(bytes.count, offset + 4)].makeIterator()
        var decoder = UTF8()
        if case let .scalarValue(scalar) = decoder.decode(&iterator) { return scalar }
        return nil
    }
}

package func literalRanges(
    _ pattern: [UInt8],
    in bytes: [UInt8],
    caseSensitive: Bool,
    wordBoundary: WordBoundary? = nil,
    maximumMatches: Int? = nil,
    accepting: ((ByteRange) -> Bool)? = nil,
    wallClockExpired: @Sendable () -> Bool = { false }
) throws -> [ByteRange] {
    guard !pattern.isEmpty, pattern.count <= bytes.count else { return [] }
    var ranges: [ByteRange] = []
    var offset = 0
    var nextCheckpoint = 0
    let comparisonPattern = caseSensitive ? pattern : pattern.map(asciiFold)
    return try bytes.withUnsafeBufferPointer { haystack in
        try comparisonPattern.withUnsafeBufferPointer { needle in
            let lastStart = haystack.count - needle.count
            let firstByte = needle[0]
            if caseSensitive {
                while offset <= lastStart {
                    if offset >= nextCheckpoint {
                        try Task.checkCancellation()
                        if wallClockExpired() { break }
                        // A match can jump across a 4 KiB boundary without landing on it.
                        nextCheckpoint = (offset / 4096 + 1) * 4096
                    }
                    guard haystack[offset] == firstByte else {
                        offset += 1
                        continue
                    }
                    var patternOffset = 1
                    while patternOffset < needle.count,
                          haystack[offset + patternOffset] == needle[patternOffset] {
                        patternOffset += 1
                    }
                    guard patternOffset == needle.count else {
                        offset += 1
                        continue
                    }
                    let range = ByteRange(lowerBound: UInt32(offset), upperBound: UInt32(offset + needle.count))
                    if let wordBoundary, !wordBoundary.isWholeWord(range, in: bytes) {
                        offset += 1
                        continue
                    }
                    if let accepting, !accepting(range) {
                        offset += needle.count
                        continue
                    }
                    ranges.append(range)
                    if let maximumMatches, ranges.count > maximumMatches { break }
                    offset += needle.count
                }
            } else {
                while offset <= lastStart {
                    if offset >= nextCheckpoint {
                        try Task.checkCancellation()
                        if wallClockExpired() { break }
                        nextCheckpoint = (offset / 4096 + 1) * 4096
                    }
                    guard asciiFold(haystack[offset]) == firstByte else {
                        offset += 1
                        continue
                    }
                    var patternOffset = 1
                    while patternOffset < needle.count,
                          asciiFold(haystack[offset + patternOffset]) == needle[patternOffset] {
                        patternOffset += 1
                    }
                    guard patternOffset == needle.count else {
                        offset += 1
                        continue
                    }
                    let range = ByteRange(lowerBound: UInt32(offset), upperBound: UInt32(offset + needle.count))
                    if let wordBoundary, !wordBoundary.isWholeWord(range, in: bytes) {
                        offset += 1
                        continue
                    }
                    if let accepting, !accepting(range) {
                        offset += needle.count
                        continue
                    }
                    ranges.append(range)
                    if let maximumMatches, ranges.count > maximumMatches { break }
                    offset += needle.count
                }
            }
            return ranges
        }
    }
}
