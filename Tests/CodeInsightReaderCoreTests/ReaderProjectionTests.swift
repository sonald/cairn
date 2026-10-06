import CodeInsightCore
import CodeInsightReaderCore
import Foundation
import Testing
@testable import CodeInsightReaderUI

private func readonlyProjectionDocument(_ text: String, bodies: [ByteRange]) -> ReaderDocument {
    let bytes = Array(text.utf8)
    let folds = bodies.enumerated().map { index, range in
        FoldRegion(id: FoldID(rawValue: UInt32(index)), kind: .declaration,
                   headerRange: ByteRange(lowerBound: range.lowerBound, upperBound: range.lowerBound),
                   bodyRange: range, outlineDepth: 0, summary: FoldSummary(hiddenLineCount: 3))
    }
    return ReaderDocument(bytes: bytes, lineTable: LineTable(bytes: bytes),
                          byteUTF16Map: ByteUTF16Map(validUTF8: bytes), highlightSpans: [], outlineFacets: [], foldRegions: folds)
}

private func readonlyProjectionCheckOracle(_ document: ReaderDocument, ids: Set<FoldID>) throws {
    let projection = try #require(ReaderProjection(document: document, renderedFoldIDs: ids))
    let map = try #require(DisplayMap(document: document, renderedFoldIDs: ids))
    let oracle = try #require(ReadonlyDisplayMapOracle(document: document, renderedFoldIDs: ids))
    #expect(projection.materialize() == oracle.projectedString)
    #expect(map.projectedString == oracle.projectedString)
    #expect(projection.projectedUTF16Length == oracle.projectedUTF16Length)
    #expect(projection.renderedFoldIDs == oracle.renderedFoldIDs)
    #expect(projection.foldPlaceholders.map(\.id) == oracle.foldPlaceholders.map(\.id))
    #expect(projection.foldPlaceholders.map(\.offset) == oracle.foldPlaceholders.map(\.offset))
    for id in ids { #expect(projection.placeholderOffset(for: id) == oracle.placeholderOffset(for: id)) }
    for byte in 0...document.bytes.count + 1 {
        #expect(map.displayPosition(ofByte: UInt32(byte)) == projection.displayPosition(ofByte: UInt32(byte)))
        switch (projection.displayPosition(ofByte: UInt32(byte)), oracle.displayPosition(ofByte: UInt32(byte))) {
        case (.visible(let a), .visible(let b)): #expect(a == b)
        case (.hidden(let a), .hidden(let b)): #expect(a == b)
        case (nil, nil): break
        default: Issue.record("Source mapping differs at byte \(byte)")
        }
    }
    for display in -1...projection.projectedUTF16Length + 1 {
        #expect(map.sourcePosition(ofDisplay: display) == projection.sourcePosition(ofDisplay: display))
        switch (projection.sourcePosition(ofDisplay: display), oracle.sourcePosition(ofDisplay: display)) {
        case (.source(let a), .source(let b)): #expect(a == b)
        case (.placeholder(let a), .placeholder(let b)): #expect(a == b)
        case (nil, nil): break
        default: Issue.record("Display mapping differs at UTF16 offset \(display)")
        }
    }
    for lower in 0...projection.projectedUTF16Length {
        for upper in lower...projection.projectedUTF16Length {
            let range = NSRange(location: lower, length: upper - lower)
            #expect(projection.sourceRanges(forDisplay: range) == oracle.sourceRanges(forDisplay: range))
            #expect(projection.visibleSourceRanges(forDisplay: range) == oracle.visibleSourceRanges(forDisplay: range))
        }
    }
    for lower in stride(from: 0, through: document.bytes.count, by: 3) {
        for upper in stride(from: lower, through: document.bytes.count, by: 4) {
            let range = ByteRange(lowerBound: UInt32(lower), upperBound: UInt32(upper))
            let actual = projection.project(byteRange: range), expected = oracle.project(byteRange: range)
            #expect(actual?.visible == expected?.visible)
            #expect(actual?.folds == expected?.folds)
        }
    }
}

@Test(.isolatedReaderWorkCounters)
func readonlyProjectionConstructionDoesNotMaterializeEvenWithoutFolds() throws {
    for source in ["", "a", "中文😀e\u{301}\r\n", String(repeating: "line\n", count: 10_000)] {
        let document = readonlyProjectionDocument(source, bodies: [])
        let before = ReaderWorkCounters.snapshot()
        let projection = try #require(ReaderProjection(document: document, renderedFoldIDs: []))
        let map = try #require(DisplayMap(document: document, renderedFoldIDs: []))
        #expect(projection.segments == [.source(range: ByteRange(lowerBound: 0, upperBound: UInt32(document.bytes.count)),
                                               utf16Length: source.utf16.count)])
        #expect(projection.displayUTF16Starts == [0])
        #expect(projection.projectedUTF16Length == source.utf16.count)
        #expect(map.projectedUTF16Length == source.utf16.count)
        #expect(ReaderWorkCounters.snapshot().materializedUTF8Bytes == before.materializedUTF8Bytes)
        #expect(ReaderWorkCounters.snapshot().projectionPlanBuildCount == before.projectionPlanBuildCount + 2)
        #expect(projection.materialize() == source)
        #expect(ReaderWorkCounters.snapshot().materializedUTF8Bytes - before.materializedUTF8Bytes == document.bytes.count)
    }
}

@Test
func readonlyProjectionRandomSourceSlicesMatchFrozenMappingAndCopyOracle() throws {
    var state: UInt64 = 0xCA175A
    func next(_ limit: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int(state % UInt64(limit))
    }
    let atoms = ["a", "中", "😀", "e\u{301}", "\r\n", "\n", "\u{2028}", "\t"]
    for _ in 0..<32 {
        let text = (0..<14).map { _ in atoms[next(atoms.count)] }.joined()
        var boundaries: [UInt32] = [0]
        for scalar in text.unicodeScalars { boundaries.append(boundaries.last! + UInt32(scalar.utf8.count)) }
        var bodies: [ByteRange] = []
        var cursor = 0
        while cursor + 1 < boundaries.count {
            let lower = cursor + next(min(3, boundaries.count - cursor - 1))
            let upper = min(boundaries.count - 1, lower + 1 + next(3))
            bodies.append(ByteRange(lowerBound: boundaries[lower], upperBound: boundaries[upper]))
            cursor = upper + next(2)
        }
        let document = readonlyProjectionDocument(text, bodies: bodies)
        let all = Set(document.foldRegions.map(\.id))
        try readonlyProjectionCheckOracle(document, ids: all)
        try readonlyProjectionCheckOracle(document, ids: Set(document.foldRegions.enumerated().filter { $0.offset % 2 == 0 }.map { $0.element.id }))
    }
}

@Test
func readonlyProjectionPreservesHiddenCopyEOFSurrogatesAndCRLF() throws {
    for text in ["", "😀", "中\r\n😀e\u{301}\n", "a\r\nb", "a\n"] {
        let bytes = Array(text.utf8)
        let document = readonlyProjectionDocument(text, bodies: bytes.isEmpty ? [] : [ByteRange(lowerBound: 0, upperBound: UInt32(bytes.count))])
        try readonlyProjectionCheckOracle(document, ids: [])
        try readonlyProjectionCheckOracle(document, ids: Set(document.foldRegions.map(\.id)))
    }
    let visibleEmoji = try #require(ReaderProjection(document: ReaderDocument(bytes: Array("😀".utf8)), renderedFoldIDs: []))
    #expect(visibleEmoji.sourcePosition(ofDisplay: 1) == nil)
    #expect(visibleEmoji.sourceRanges(forDisplay: NSRange(location: 0, length: 1)) == nil)
    #expect(visibleEmoji.visibleSourceRanges(forDisplay: NSRange(location: 1, length: 1)) == nil)
    #expect(visibleEmoji.sourcePosition(ofDisplay: 2) == .source(4))
    #expect(visibleEmoji.displayPosition(ofByte: 4) == .visible(2))
}

@Test
func readonlyProjectionRejectsUnknownDuplicateOverlappingAndInvalidRanges() throws {
    let document = readonlyProjectionDocument("abcdef", bodies: [ByteRange(lowerBound: 1, upperBound: 3)])
    #expect(ReaderProjection(document: document, renderedFoldIDs: [FoldID(rawValue: 99)]) == nil)
    let zero = readonlyProjectionDocument("abcdef", bodies: [ByteRange(lowerBound: 1, upperBound: 1)])
    #expect(ReaderProjection(document: zero, renderedFoldIDs: [FoldID(rawValue: 0)]) == nil)
    let outside = readonlyProjectionDocument("abcdef", bodies: [ByteRange(lowerBound: 1, upperBound: 7)])
    #expect(ReaderProjection(document: outside, renderedFoldIDs: [FoldID(rawValue: 0)]) == nil)
    let surrogate = readonlyProjectionDocument("a😀b", bodies: [ByteRange(lowerBound: 2, upperBound: 5)])
    #expect(ReaderProjection(document: surrogate, renderedFoldIDs: [FoldID(rawValue: 0)]) == nil)
    let crossing = readonlyProjectionDocument("abcdef", bodies: [.init(lowerBound: 0, upperBound: 3), .init(lowerBound: 2, upperBound: 5)])
    #expect(ReaderProjection(document: crossing, renderedFoldIDs: [FoldID(rawValue: 0), FoldID(rawValue: 1)]) == nil)
    let first = document.foldRegions[0]
    let duplicate = FoldRegion(id: first.id, kind: first.kind, headerRange: first.headerRange,
                               bodyRange: ByteRange(lowerBound: 4, upperBound: 5), outlineDepth: 0, summary: first.summary)
    let duplicated = ReaderDocument(bytes: document.bytes, lineTable: document.lineTable,
                                    byteUTF16Map: document.byteUTF16Map, highlightSpans: [], outlineFacets: [], foldRegions: [first, duplicate])
    // Equal counts must not hide a missing ID and cause unique-key dictionary traps.
    #expect(ReaderProjection(document: duplicated, renderedFoldIDs: [first.id, FoldID(rawValue: 99)]) == nil)
    let projection = try #require(ReaderProjection(document: document, renderedFoldIDs: []))
    for range in [NSRange(location: -1, length: 1), NSRange(location: 0, length: -1),
                  NSRange(location: Int.max, length: 1), NSRange(location: 0, length: 7)] {
        #expect(projection.sourceRanges(forDisplay: range) == nil)
        #expect(projection.visibleSourceRanges(forDisplay: range) == nil)
    }
}

@Test(.isolatedReaderWorkCounters)
func readonlyProjectionLargeCollapsedBodyMaterializesOnlyVisibleSlices() throws {
    let source = String(repeating: "a", count: 1_048_576)
    let document = readonlyProjectionDocument(source, bodies: [ByteRange(lowerBound: 1, upperBound: UInt32(source.utf8.count - 1))])
    let before = ReaderWorkCounters.snapshot()
    let projection = try #require(ReaderProjection(document: document, renderedFoldIDs: [FoldID(rawValue: 0)]))
    #expect(ReaderWorkCounters.snapshot().materializedUTF8Bytes == before.materializedUTF8Bytes)
    #expect(projection.displayUTF16Starts == [0, 1, 2])
    #expect(projection.projectedUTF16Length == 3)
    #expect(projection.materialize() == "a\u{FFFC}a")
    #expect(ReaderWorkCounters.snapshot().materializedUTF8Bytes - before.materializedUTF8Bytes == 2)
    #expect(projection.sourceRanges(forDisplay: NSRange(location: 1, length: 1))
            == [ByteRange(lowerBound: 1, upperBound: UInt32(source.utf8.count - 1))])
}
