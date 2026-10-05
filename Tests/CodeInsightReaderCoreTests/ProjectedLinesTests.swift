import CodeInsightCore
import CodeInsightReaderCore
import Foundation
import Testing

/// Random text with folds over arbitrary character boundaries, checked
/// against line breaks counted in the materialized projection.
@Test(arguments: 0..<40)
func projectedLinesMatchLineBreaksInTheRenderedProjection(seed: UInt64) throws {
    var state = seed &+ 0x9E37_79B9
    func next(_ bound: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 33) % UInt64(bound))
    }
    let pieces = ["a", "bc", "\n", "\n", "é", "  ", "{", "}", "\n\n"]
    let text = (0..<(20 + next(200))).map { _ in pieces[next(pieces.count)] }.joined()
    let bytes = Array(text.utf8)
    let boundaries = (0...bytes.count).filter { $0 == bytes.count || bytes[$0] & 0xC0 != 0x80 }
    var bodies: [ByteRange] = []
    var cursor = 0
    while cursor < boundaries.count - 1, next(3) != 0 {
        let lower = cursor + next(max(1, (boundaries.count - cursor) / 2))
        let upper = lower + 1 + next(max(1, (boundaries.count - lower) / 2))
        guard upper < boundaries.count else { break }
        bodies.append(ByteRange(lowerBound: UInt32(boundaries[lower]), upperBound: UInt32(boundaries[upper])))
        cursor = upper
    }
    let folds = bodies.enumerated().map { index, range in
        FoldRegion(id: FoldID(rawValue: UInt32(index)), kind: .declaration,
                   headerRange: ByteRange(lowerBound: range.lowerBound, upperBound: range.lowerBound),
                   bodyRange: range, outlineDepth: 0, summary: FoldSummary(hiddenLineCount: 1))
    }
    let document = ReaderDocument(bytes: bytes, lineTable: LineTable(bytes: bytes),
                                  byteUTF16Map: ByteUTF16Map(validUTF8: bytes), highlightSpans: [],
                                  outlineFacets: [], foldRegions: folds)
    let projection = try #require(ReaderProjection(document: document, renderedFoldIDs: Set(folds.map(\.id))))
    let lines = ProjectedLines(projection: projection, lineStarts: document.lineTable.lineStarts)
    let rendered = Array(projection.materialize().utf16)
    func breaks(before offset: Int) -> Int { rendered[..<offset].lazy.filter { $0 == 0x0A }.count }

    #expect(lines.count == breaks(before: rendered.count) + 1)
    for byte in boundaries {
        switch projection.displayPosition(ofByte: UInt32(byte)) {
        case .visible(let offset):
            #expect(lines.displayLine(ofByte: UInt32(byte)) == (breaks(before: offset), false), "byte \(byte)")
        case .hidden(let id):
            let placeholder = try #require(projection.placeholderOffset(for: id))
            #expect(lines.displayLine(ofByte: UInt32(byte)) == (breaks(before: placeholder), true), "byte \(byte)")
        case nil:
            Issue.record("no display position for boundary \(byte)")
        }
    }
    for line in 0..<lines.count {
        let start = lines.sourceByte(ofDisplayLine: line)
        #expect(lines.displayLine(ofByte: start).line == line, "display line \(line)")
        if let earlier = document.lineTable.lineStarts.last(where: { $0 < start }) {
            #expect(lines.displayLine(ofByte: earlier).line < line, "first source line of display line \(line)")
        }
    }
}
