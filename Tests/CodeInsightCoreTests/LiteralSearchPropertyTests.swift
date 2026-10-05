import os
import Testing
@testable import CodeInsightCore

/// P0 implementation, retained verbatim (apart from its name) as the scan reference.
private func referenceLiteralRanges(
    _ pattern: [UInt8],
    in bytes: [UInt8],
    caseSensitive: Bool,
    wordBoundary: WordBoundary? = nil,
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
                let range = ByteRange(lowerBound: UInt32(offset), upperBound: UInt32(offset + needle.count))
                if matches, let wordBoundary, !wordBoundary.isWholeWord(range, in: bytes) {
                    // Not a whole word here; a later overlapping start may still be one.
                    offset += 1
                } else if matches {
                    ranges.append(range)
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

/// An explicit generator keeps failing inputs reproducible across Swift versions.
private func nextLiteralSearchValue(_ state: inout UInt64, below upperBound: Int) -> Int {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return Int((state >> 32) % UInt64(upperBound))
}

@Test
func literalSearchMatchesP0ReferenceForGeneratedUTF8AndLimits() throws {
    let pieces = ["a", "A", "b", "B", "aa", "Aa", "é", "É", "中", "🚀", "_", "$", "1", " ", "\n", "a\u{301}"]
    let boundaries: [WordBoundary?] = [nil, WordBoundary(allowsDollar: false), WordBoundary(allowsDollar: true)]
    let limits: [Int?] = [nil, 0, 1, 2, 200]
    for seed in UInt64(1)...400 {
        var state = seed
        var text = ""
        for _ in 0..<nextLiteralSearchValue(&state, below: 100) {
            text += pieces[nextLiteralSearchValue(&state, below: pieces.count)]
        }
        var pattern = ""
        for _ in 0..<nextLiteralSearchValue(&state, below: 5) {
            pattern += pieces[nextLiteralSearchValue(&state, below: pieces.count)]
        }
        // Alternate arbitrary input with guaranteed frequent/overlapping hits.
        if seed % 4 == 0 { text = String(repeating: pattern, count: 205) }
        if seed % 7 == 0 { pattern = text + "longer" }
        let bytes = Array(text.utf8)
        let needle = Array(pattern.utf8)
        for caseSensitive in [false, true] {
            for boundary in boundaries {
                for limit in limits {
                    let actual = try literalRanges(needle, in: bytes, caseSensitive: caseSensitive,
                                                   wordBoundary: boundary, maximumMatches: limit)
                    let expected = try referenceLiteralRanges(needle, in: bytes, caseSensitive: caseSensitive,
                                                            wordBoundary: boundary, maximumMatches: limit)
                    #expect(actual == expected, "seed \(seed), caseSensitive \(caseSensitive), limit \(String(describing: limit))")
                }
            }
        }
    }
    // Whole-word rejection must advance one byte: the second, overlapping
    // occurrence of `a a` is a whole word although the first touches `x`.
    for (pattern, text) in [("aa", "aaaa"), ("a a", "xa a a "), ("Aa", String(repeating: "aA ", count: 205)),
                            (String(repeating: "a", count: 5000), " " + String(repeating: String(repeating: "a", count: 5000) + " ", count: 3))] {
        for caseSensitive in [false, true] {
            for boundary in boundaries {
                for limit in limits {
                    #expect(try literalRanges(Array(pattern.utf8), in: Array(text.utf8), caseSensitive: caseSensitive,
                                              wordBoundary: boundary, maximumMatches: limit)
                            == referenceLiteralRanges(Array(pattern.utf8), in: Array(text.utf8), caseSensitive: caseSensitive,
                                                      wordBoundary: boundary, maximumMatches: limit))
                }
            }
        }
    }
}

@Test
func literalSearchChecksDeadlineAfterMatchSkipsCheckpoint() throws {
    // Three-byte hits skip offset 4096; timeout must still be observed at 4098.
    for caseSensitive in [false, true] {
        let checks = OSAllocatedUnfairLock(initialState: 0)
        let ranges = try literalRanges(Array("aaa".utf8), in: Array(repeating: 0x61, count: 16000),
                                       caseSensitive: caseSensitive, wallClockExpired: {
            checks.withLock { count in
                count += 1
                return count == 2
            }
        })
        #expect(checks.withLock { $0 } == 2)
        #expect(ranges.count == 1366)
        #expect(ranges.last?.upperBound == 4098)
    }
}
