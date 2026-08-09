package func asciiFold(_ byte: UInt8) -> UInt8 {
    (0x41...0x5A).contains(byte) ? byte + 0x20 : byte
}

package func literalRanges(
    _ pattern: [UInt8],
    in bytes: [UInt8],
    caseSensitive: Bool,
    maximumMatches: Int? = nil,
    wallClockExpired: @Sendable () -> Bool = { false }
) throws -> [ByteRange] {
    guard !pattern.isEmpty, pattern.count <= bytes.count else { return [] }
    var ranges: [ByteRange] = []
    var offset = 0
    return try bytes.withUnsafeBufferPointer { haystack in
        try pattern.withUnsafeBufferPointer { needle in
            while offset <= haystack.count - needle.count {
                if offset & 0xFFF == 0 {
                    try Task.checkCancellation()
                    if wallClockExpired() { break }
                }
                var matches = true
                for patternOffset in needle.indices {
                    let lhs = haystack[offset + patternOffset]
                    let rhs = needle[patternOffset]
                    if caseSensitive ? lhs != rhs : asciiFold(lhs) != asciiFold(rhs) {
                        matches = false
                        break
                    }
                }
                if matches {
                    ranges.append(ByteRange(
                        lowerBound: UInt32(offset),
                        upperBound: UInt32(offset + needle.count)
                    ))
                    if let maximumMatches, ranges.count > maximumMatches {
                        break
                    }
                    offset += needle.count
                } else {
                    offset += 1
                }
            }
            return ranges
        }
    }
}
