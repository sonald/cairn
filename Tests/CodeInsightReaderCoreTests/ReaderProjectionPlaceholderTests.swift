import CodeInsightCore
import CodeInsightReaderCore
import Foundation
import Testing

private func readonlyPlaceholderDocument(_ text: String, bodies: [ByteRange]) -> ReaderDocument {
    let bytes = Array(text.utf8)
    let regions = bodies.enumerated().map { index, body in
        FoldRegion(id: FoldID(rawValue: UInt32(index)), kind: .declaration,
                   headerRange: ByteRange(lowerBound: body.lowerBound, upperBound: body.lowerBound),
                   bodyRange: body, outlineDepth: 0, summary: FoldSummary(hiddenLineCount: 2))
    }
    return ReaderDocument(bytes: bytes, lineTable: LineTable(bytes: bytes), byteUTF16Map: ByteUTF16Map(validUTF8: bytes),
                          highlightSpans: [], outlineFacets: [], foldRegions: regions)
}

@Test(.isolatedReaderWorkCounters)
func readonlyProjectionPlaceholderWindowsHaveBoundedActualRecordVisits() throws {
    let count = 2_048
    let bodies = (0..<count).map { index -> ByteRange in
        let start = UInt32(index * 4)
        return ByteRange(lowerBound: start + 1, upperBound: start + 3)
    }
    let document = readonlyPlaceholderDocument(String(repeating: "abcd", count: count), bodies: bodies)
    let foldIDs = Set(document.foldRegions.map { $0.id })
    let projection = try #require(ReaderProjection(document: document, renderedFoldIDs: foldIDs))
    let all = projection.foldPlaceholders
    let before = ReaderWorkCounters.snapshot()
    for placeholder in all {
        let selected = try #require(projection.foldPlaceholders(in: NSRange(location: placeholder.offset, length: 1)))
        #expect(selected.count == 1)
        #expect(selected.first?.id == placeholder.id)
        #expect(selected.first?.offset == placeholder.offset)
    }
    let delta = ReaderWorkCounters.snapshot().projectionPlaceholderRecordsVisited - before.projectionPlaceholderRecordsVisited
    #expect(delta >= count)
    #expect(delta < count * 20)
    #expect(ReaderWorkCounters.snapshot().materializedUTF8Bytes == before.materializedUTF8Bytes)
}

@Test
func readonlyProjectionPlaceholderWindowsPreserveHalfOpenAndUnicodeBoundaries() throws {
    let document = readonlyPlaceholderDocument("😀abcdef中", bodies: [
        .init(lowerBound: 4, upperBound: 6), .init(lowerBound: 8, upperBound: 10),
    ])
    let projection = try #require(ReaderProjection(document: document, renderedFoldIDs: Set(document.foldRegions.map(\.id))))
    let all = projection.foldPlaceholders
    for lower in 0...projection.projectedUTF16Length {
        for upper in lower...projection.projectedUTF16Length {
            let range = NSRange(location: lower, length: upper - lower)
            let actual = projection.foldPlaceholders(in: range)
            if projection.sourceRanges(forDisplay: range) == nil {
                #expect(actual == nil)
            } else {
                let expected = all.filter { NSLocationInRange($0.offset, range) }
                #expect(actual?.map(\.id) == expected.map(\.id))
                #expect(actual?.map(\.offset) == expected.map(\.offset))
            }
        }
    }
    #expect(projection.foldPlaceholders(in: NSRange(location: -1, length: 1)) == nil)
    #expect(projection.foldPlaceholders(in: NSRange(location: Int.max, length: 1)) == nil)
    #expect(projection.foldPlaceholders(in: NSRange(location: projection.projectedUTF16Length, length: 0))?.isEmpty == true)
}
