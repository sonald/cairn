import Foundation
import Testing
@testable import CodeInsightReaderCore

@Test
func byteAndUTF16OffsetsRoundTripAcrossCJKAndEmoji() throws {
    let source = "fn 世界() { let crab = \"🦀🚀\"; } // 注释\n"
    let bytes = Array(source.utf8)
    let map = ByteUTF16Map(validUTF8: bytes, stride: 5)
    var byte = 0
    var utf16 = 0

    for scalar in source.unicodeScalars {
        #expect(map.utf16Offset(forByte: byte) == utf16)
        #expect(map.byteOffset(forUTF16: utf16) == byte)
        byte += scalar.utf8.count
        utf16 += scalar.value > 0xffff ? 2 : 1
    }
    #expect(map.utf16Offset(forByte: byte) == utf16)
    #expect(map.byteOffset(forUTF16: utf16) == byte)
    #expect(map.byteOffset(forUTF16: 25) == nil) // Inside 🦀's surrogate pair.
    #expect(map.utf16Offset(forByte: 4) == nil) // Inside 世's UTF-8 sequence.
}

@Test
func byteRangeBecomesExpectedNSRange() throws {
    let source = "a中🦀z"
    let map = ByteUTF16Map(validUTF8: Array(source.utf8), stride: 2)
    let lower = source.utf8.distance(from: source.utf8.startIndex, to: source.utf8.index(after: source.utf8.startIndex))
    let upper = Array("a中🦀".utf8).count
    #expect(map.nsRange(byteLowerBound: lower, byteUpperBound: upper) == NSRange(location: 1, length: 3))
}
