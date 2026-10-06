import CodeInsightCore
import CodeInsightReaderCore
import Foundation
import Testing

private func readonlyDeltaDocument(_ source: String, ranges: [ByteRange]) -> ReaderDocument {
    let bytes = Array(source.utf8)
    let regions = ranges.enumerated().map { index, range in
        FoldRegion(id: FoldID(rawValue: UInt32(index)), kind: .declaration,
                   headerRange: ByteRange(lowerBound: range.lowerBound, upperBound: range.lowerBound),
                   bodyRange: range, outlineDepth: index, summary: FoldSummary(hiddenLineCount: 3))
    }
    return ReaderDocument(bytes: bytes, lineTable: LineTable(bytes: bytes), byteUTF16Map: ByteUTF16Map(validUTF8: bytes),
                          highlightSpans: [], outlineFacets: [], foldRegions: regions)
}

private func readonlyDeltaApply(_ old: ReaderProjection, _ new: ReaderProjection) throws -> ProjectionDelta {
    let delta = try #require(ProjectionDelta(old: old, new: new))
    let text = NSMutableString(string: old.materialize())
    #expect(delta.isApplicable(current: old, target: new, storageUTF16Length: text.length))
    for patch in delta.patches.reversed() {
        let replacement = try #require(new.materialize(displayRange: patch.newDisplayRange))
        #expect(replacement.utf16.count == patch.newDisplayRange.length)
        text.replaceCharacters(in: patch.oldDisplayRange, with: replacement)
    }
    #expect(text as String == new.materialize())
    return delta
}

@Test(.isolatedReaderWorkCounters)
func readonlyProjectionDeltaSingleMiddleFoldReplacesOnlyItsSourceWindow() throws {
    let source = String(repeating: "a", count: 10_000)
    let hidden = ByteRange(lowerBound: 4_000, upperBound: 4_200)
    let document = readonlyDeltaDocument(source, ranges: [hidden])
    let old = try #require(ReaderProjection(document: document, renderedFoldIDs: []))
    let new = try #require(ReaderProjection(document: document, renderedFoldIDs: [FoldID(rawValue: 0)]))
    let delta = try readonlyDeltaApply(old, new)
    let patch = try #require(delta.patches.first)
    #expect(delta.patches.count == 1)
    #expect(patch.oldDisplayRange == NSRange(location: 4_000, length: 200))
    #expect(patch.newDisplayRange == NSRange(location: 4_000, length: 1))
    #expect(patch.sourceRange == hidden)
    let before = ReaderWorkCounters.snapshot().materializedUTF8Bytes
    #expect(new.materialize(displayRange: patch.newDisplayRange) == "\u{FFFC}")
    #expect(ReaderWorkCounters.snapshot().materializedUTF8Bytes == before)
    let expanded = try #require(ProjectionDelta(old: new, new: old))
    let expansion = try #require(expanded.patches.first)
    #expect(old.materialize(displayRange: expansion.newDisplayRange)?.utf8.count == 200)
    #expect(ReaderWorkCounters.snapshot().materializedUTF8Bytes - before == 200)
}

@Test
func readonlyProjectionDeltaAncestorExpansionRetainsNestedChildPlaceholder() throws {
    let source = "0123456789abcdefghijklmnopqrstuvwxyz"
    let outer = ByteRange(lowerBound: 2, upperBound: 30)
    let inner = ByteRange(lowerBound: 10, upperBound: 20)
    let document = readonlyDeltaDocument(source, ranges: [outer, inner])
    let old = try #require(ReaderProjection(document: document, renderedFoldIDs: [FoldID(rawValue: 0)]))
    let new = try #require(ReaderProjection(document: document, renderedFoldIDs: [FoldID(rawValue: 1)]))
    let delta = try readonlyDeltaApply(old, new)
    let patch = try #require(delta.patches.first)
    #expect(delta.patches.count == 1)
    #expect(patch.sourceRange == outer)
    #expect(patch.oldDisplayRange.length == 1)
    #expect(new.materialize(displayRange: patch.newDisplayRange) == "23456789\u{FFFC}klmnopqrst")
}

@Test
func readonlyProjectionDeltaMultiplePatchesPreserveUnchangedFoldBetweenThem() throws {
    let source = "abcdefghijklmnopqrstuvwxyz0123456789"
    let document = readonlyDeltaDocument(source, ranges: [
        .init(lowerBound: 2, upperBound: 6), .init(lowerBound: 10, upperBound: 15), .init(lowerBound: 20, upperBound: 26),
    ])
    let old = try #require(ReaderProjection(document: document, renderedFoldIDs: [FoldID(rawValue: 1)]))
    let new = try #require(ReaderProjection(document: document, renderedFoldIDs: [FoldID(rawValue: 0), FoldID(rawValue: 1), FoldID(rawValue: 2)]))
    let delta = try readonlyDeltaApply(old, new)
    #expect(delta.patches.count == 2)
    #expect(delta.patches[0].oldDisplayRange == NSRange(location: 2, length: 4))
    #expect(delta.patches[1].oldDisplayRange == NSRange(location: 16, length: 6))
    let unchangedPlaceholder = try #require(old.placeholderOffset(for: FoldID(rawValue: 1)))
    #expect(!delta.patches.contains { NSLocationInRange(unchangedPlaceholder, $0.oldDisplayRange) })
    _ = try readonlyDeltaApply(new, old)
}

@Test
func readonlyProjectionDeltaGeneratedUnicodeTransitionsEqualCompleteMaterialization() throws {
    var state: UInt64 = 0xDE175A
    func next(_ limit: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int(state % UInt64(limit))
    }
    let atoms = ["a", "中", "😀", "e\u{301}", "\r\n", "\n", "\t"]
    for _ in 0..<50 {
        let source = (0..<20).map { _ in atoms[next(atoms.count)] }.joined()
        var boundaries: [UInt32] = [0]
        for scalar in source.unicodeScalars { boundaries.append(boundaries.last! + UInt32(scalar.utf8.count)) }
        var bodies: [ByteRange] = []
        var cursor = 0
        while cursor + 1 < boundaries.count {
            let end = min(boundaries.count - 1, cursor + 1 + next(3))
            bodies.append(.init(lowerBound: boundaries[cursor], upperBound: boundaries[end]))
            cursor = end + next(2)
        }
        let document = readonlyDeltaDocument(source, ranges: bodies)
        let oldIDs = Set(document.foldRegions.filter { _ in next(2) == 0 }.map(\.id))
        let newIDs = Set(document.foldRegions.filter { _ in next(2) == 0 }.map(\.id))
        let old = try #require(ReaderProjection(document: document, renderedFoldIDs: oldIDs))
        let new = try #require(ReaderProjection(document: document, renderedFoldIDs: newIDs))
        _ = try readonlyDeltaApply(old, new)
        _ = try readonlyDeltaApply(new, old)
    }
}

@Test
func readonlyProjectionDeltaPreflightRejectsDifferentContentStaleTargetsAndUnknownFolds() throws {
    let document = readonlyDeltaDocument("abc😀\r\n", ranges: [.init(lowerBound: 3, upperBound: 7)])
    let old = try #require(ReaderProjection(document: document, renderedFoldIDs: []))
    let new = try #require(ReaderProjection(document: document, renderedFoldIDs: [FoldID(rawValue: 0)]))
    let delta = try #require(ProjectionDelta(old: old, new: new))
    let sameGeometryNewIdentity = try #require(ReaderProjection(document: document, renderedFoldIDs: []))
    #expect(!delta.isApplicable(current: sameGeometryNewIdentity, target: new, storageUTF16Length: old.projectedUTF16Length))
    #expect(!delta.isApplicable(current: old, target: sameGeometryNewIdentity, storageUTF16Length: old.projectedUTF16Length))
    #expect(!delta.isApplicable(current: old, target: new, storageUTF16Length: old.projectedUTF16Length + 1))
    let other = try #require(ReaderProjection(document: ReaderDocument(bytes: Array("other".utf8)), renderedFoldIDs: []))
    #expect(ProjectionDelta(old: old, new: other) == nil)
    #expect(ReaderProjection(document: document, renderedFoldIDs: [FoldID(rawValue: 999)]) == nil)
    #expect(old.materialize(displayRange: NSRange(location: 3, length: 1)) == nil)
    #expect(old.materialize(displayRange: NSRange(location: Int.max, length: 1)) == nil)
}

@Test
func readonlyProjectionDeltaNoChangeAndEOFFoldRequireNoUnrelatedMaterialization() throws {
    for source in ["", "x", "😀e\u{301}\r\n"] {
        let ranges: [ByteRange] = source.isEmpty ? [] : [.init(lowerBound: 0, upperBound: UInt32(source.utf8.count))]
        let document = readonlyDeltaDocument(source, ranges: ranges)
        let old = try #require(ReaderProjection(document: document, renderedFoldIDs: []))
        let same = try #require(ReaderProjection(document: document, renderedFoldIDs: []))
        let unchanged = try #require(ProjectionDelta(old: old, new: same))
        #expect(unchanged.patches.isEmpty)
        let folded = try #require(ReaderProjection(document: document, renderedFoldIDs: Set(document.foldRegions.map(\.id))))
        _ = try readonlyDeltaApply(old, folded)
        _ = try readonlyDeltaApply(folded, old)
    }
}

@Test
func readonlyProjectionDeltaTracksChangedFoldGeometryAndPlaceholderIdentity() throws {
    let first = readonlyDeltaDocument("abcdefgh", ranges: [.init(lowerBound: 2, upperBound: 4)])
    let moved = readonlyDeltaDocument("abcdefgh", ranges: [.init(lowerBound: 3, upperBound: 5)])
    let old = try #require(ReaderProjection(document: first, renderedFoldIDs: [FoldID(rawValue: 0)]))
    let new = try #require(ReaderProjection(document: moved, renderedFoldIDs: [FoldID(rawValue: 0)]))
    let movedDelta = try readonlyDeltaApply(old, new)
    #expect(movedDelta.patches.first?.sourceRange == ByteRange(lowerBound: 2, upperBound: 5))
    let changedIdentity = readonlyDeltaDocument("abcdefgh", ranges: [
        .init(lowerBound: 6, upperBound: 7), .init(lowerBound: 2, upperBound: 4),
    ])
    let otherID = try #require(ReaderProjection(document: changedIdentity, renderedFoldIDs: [FoldID(rawValue: 1)]))
    let identityDelta = try readonlyDeltaApply(old, otherID)
    #expect(identityDelta.patches.count == 1)
    #expect(identityDelta.patches[0].oldDisplayRange == NSRange(location: 2, length: 1))
    #expect(identityDelta.patches[0].newDisplayRange == NSRange(location: 2, length: 1))
}
