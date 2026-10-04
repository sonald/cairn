import Foundation
import Testing
@testable import CodeInsightReaderCore

@Test
func byteAndUTF16MappingPreservesScalarBoundariesAndRanges() {
    let alphabet = ["a", "é", "中", "🦀", "\u{0301}", "\n"]
    var sources = ["", "\r\n", "e\u{0301}", "👩🏽‍💻", "🇨🇳", String(repeating: "a中🦀\n", count: 8)]
    // Deterministic combinations exercise different scalar orders and checkpoint alignments.
    for (first, a) in alphabet.enumerated() {
        for (second, b) in alphabet.enumerated() {
            sources.append(a + b + alphabet[(first + second) % alphabet.count])
        }
    }

    for source in sources {
        var byteToUTF16 = [0: 0]
        var utf16ToByte = [0: 0]
        var byteCount = 0
        var utf16Count = 0
        // Swift's Unicode views are the oracle; do not duplicate the map's UTF-8 decoder.
        for scalar in source.unicodeScalars {
            let text = String(scalar)
            byteCount += text.utf8.count
            utf16Count += text.utf16.count
            byteToUTF16[byteCount] = utf16Count
            utf16ToByte[utf16Count] = byteCount
        }

        for stride in [1, 2, 5, 16, 256] {
            let map = ByteUTF16Map(validUTF8: Array(source.utf8), stride: stride)
            #expect(map.utf16Count == source.utf16.count)
            for byte in -1...(byteCount + 1) {
                let offset = map.utf16Offset(forByte: byte)
                #expect(offset == byteToUTF16[byte], "source=\(source.debugDescription), stride=\(stride), byte=\(byte)")
                if let offset {
                    #expect(map.byteOffset(forUTF16: offset) == byte)
                }
            }
            for utf16 in -1...(utf16Count + 1) {
                let offset = map.byteOffset(forUTF16: utf16)
                #expect(offset == utf16ToByte[utf16], "source=\(source.debugDescription), stride=\(stride), utf16=\(utf16)")
                if let offset {
                    #expect(map.utf16Offset(forByte: offset) == utf16)
                }
            }
            // All endpoint pairs include empty, reversed, out-of-bounds and split-scalar ranges.
            for lower in -1...(byteCount + 1) {
                for upper in -1...(byteCount + 1) {
                    let expected: NSRange?
                    if let start = byteToUTF16[lower], let end = byteToUTF16[upper], lower <= upper {
                        expected = NSRange(location: start, length: end - start)
                    } else {
                        expected = nil
                    }
                    #expect(map.nsRange(byteLowerBound: lower, byteUpperBound: upper) == expected,
                            "source=\(source.debugDescription), stride=\(stride), range=\(lower)..<\(upper)")
                }
            }
        }
    }
}
