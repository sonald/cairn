@preconcurrency import AppKit
import CodeInsightCore
import CodeInsightReaderCore
import Foundation
import Testing
@testable import CodeInsightReaderUI

private func readonlyTopologyRegion(_ id: UInt32, _ lower: UInt32, _ upper: UInt32,
                                    depth: Int, kind: FoldKind = .declaration) -> FoldRegion {
    FoldRegion(id: FoldID(rawValue: id), kind: kind,
               headerRange: ByteRange(lowerBound: lower, upperBound: lower),
               bodyRange: ByteRange(lowerBound: lower, upperBound: upper), outlineDepth: depth,
               summary: FoldSummary(hiddenLineCount: 3))
}

private func readonlyTopologyDocument(_ regions: [FoldRegion], facets: [OutlineFacet] = [], size: Int = 512) -> ReaderDocument {
    let bytes = (0..<size).map { UInt8($0 % 10 == 9 ? 10 : 32) }
    return ReaderDocument(bytes: bytes, lineTable: LineTable(bytes: bytes),
                          byteUTF16Map: ByteUTF16Map(validUTF8: bytes), highlightSpans: [],
                          outlineFacets: facets, foldRegions: regions)
}

private func readonlyTopologyCompare(_ document: ReaderDocument) throws {
    let topology = try #require(document.foldTopology)
    for region in document.foldRegions {
        #expect(topology.region(for: region.id) == region)
        #expect(topology.recursiveSiblings(of: region.id)
                == ReadonlyStructuralOracle.recursiveSiblings(of: region, in: document.foldRegions))
        #expect(topology.associatedFacet(for: region.id)
                == ReadonlyStructuralOracle.associatedFacet(for: region, in: document.outlineFacets))
    }
    for byte in stride(from: UInt32(0), through: UInt32(document.bytes.count), by: 3) {
        #expect(topology.containing(byte) == document.foldRegions.filter { $0.bodyRange.contains(byte) })
        let actual = topology.focusTarget(at: byte)
        let expected = ReadonlyStructuralOracle.focusTarget(at: byte, in: document)
        #expect(actual?.facet == expected?.facet)
        #expect(actual?.region == expected?.region)
    }
    for residue in 0..<5 {
        let logical = Set(document.foldRegions.enumerated().filter { $0.offset % 5 != residue }.map { $0.element.id })
        #expect(topology.maximalFoldIDs(logical)
                == ReadonlyStructuralOracle.maximalFoldIDs(logical, in: document.foldRegions))
    }
}

@Test
func readonlyFoldTopologyLaminarParentsSubtreesAndOriginalOrderMatchOracle() throws {
    let regions = [readonlyTopologyRegion(4, 80, 90, depth: 2),
                   readonlyTopologyRegion(1, 0, 200, depth: 0),
                   readonlyTopologyRegion(3, 60, 100, depth: 1),
                   readonlyTopologyRegion(2, 10, 50, depth: 1)]
    let document = readonlyTopologyDocument(regions)
    let topology = try #require(document.foldTopology)
    #expect(!topology.usesCompatibilityRelations)
    #expect(topology.preorder == [1, 3, 2, 0])
    #expect(topology.parentIndices == [2, nil, 1, 1])
    #expect(topology.children[1] == [3, 2])
    #expect(topology.subtreeEnds[1] == 4)
    #expect(topology.subtreeEnds[3] == 2)
    #expect(topology.headerLine(for: regions[0].id) == 9)
    #expect(topology.compatibilityRecordVisits == 0)
    try readonlyTopologyCompare(document)
}

@Test
func readonlyFoldTopologyEqualRangesCrossingsAndDepthAnomaliesUseFrozenSemantics() throws {
    let cases = [
        [readonlyTopologyRegion(1, 0, 100, depth: 0), readonlyTopologyRegion(2, 0, 100, depth: 1, kind: .block)],
        [readonlyTopologyRegion(1, 0, 100, depth: 0), readonlyTopologyRegion(2, 50, 150, depth: 1),
         readonlyTopologyRegion(3, 60, 70, depth: 2)],
        [readonlyTopologyRegion(1, 0, 200, depth: 4), readonlyTopologyRegion(2, 10, 100, depth: 0),
         readonlyTopologyRegion(3, 20, 30, depth: 1)],
        [readonlyTopologyRegion(2, 10, 100, depth: 0), readonlyTopologyRegion(1, 0, 200, depth: 0),
         readonlyTopologyRegion(3, 20, 30, depth: 1)],
    ]
    for regions in cases {
        let document = readonlyTopologyDocument(regions)
        let topology = try #require(document.foldTopology)
        #expect(topology.usesCompatibilityRelations)
        #expect(topology.compatibilityReason != nil)
        #expect(topology.compatibilityRecordVisits > 0)
        try readonlyTopologyCompare(document)
    }
}

@Test
func readonlyFoldTopologyRejectsDuplicateIDsEmptyBodiesAndInvalidBoundaries() {
    let valid = readonlyTopologyRegion(1, 0, 100, depth: 0)
    let duplicate = readonlyTopologyDocument([valid, readonlyTopologyRegion(1, 110, 130, depth: 1)])
    #expect(duplicate.foldTopology == nil)
    #expect(duplicate.foldTopologyFailureReason == "duplicate fold ID")
    let empty = readonlyTopologyDocument([readonlyTopologyRegion(2, 10, 10, depth: 0)])
    #expect(empty.foldTopology == nil)
    #expect(empty.foldTopologyFailureReason == "empty fold body")
    let outside = readonlyTopologyDocument([readonlyTopologyRegion(2, 10, 513, depth: 0)])
    #expect(outside.foldTopology == nil)
    #expect(outside.foldTopologyFailureReason == "invalid fold source boundary")
    let bytes = Array("中\n".utf8)
    let splitScalar = ReaderDocument(bytes: bytes, lineTable: LineTable(bytes: bytes),
                                     byteUTF16Map: ByteUTF16Map(validUTF8: bytes), highlightSpans: [], outlineFacets: [],
                                     foldRegions: [readonlyTopologyRegion(3, 1, 3, depth: 0)])
    #expect(splitScalar.foldTopology == nil)
    #expect(splitScalar.foldTopologyFailureReason == "invalid fold source boundary")
}

@Test
func readonlyFoldTopologyFocusAssociationsPreserveKindAndTieBreaks() throws {
    let facets = [
        OutlineFacet(kind: .class, name: "C", range: ByteRange(lowerBound: 0, upperBound: 300),
                     nameRange: ByteRange(lowerBound: 0, upperBound: 1), depth: 0),
        OutlineFacet(kind: .fn, name: "first", range: ByteRange(lowerBound: 10, upperBound: 200),
                     nameRange: ByteRange(lowerBound: 10, upperBound: 15), depth: 1),
        OutlineFacet(kind: .fn, name: "nested", range: ByteRange(lowerBound: 40, upperBound: 80),
                     nameRange: ByteRange(lowerBound: 40, upperBound: 45), depth: 2),
        OutlineFacet(kind: .method, name: "sameRangeLater", range: ByteRange(lowerBound: 40, upperBound: 80),
                     nameRange: ByteRange(lowerBound: 40, upperBound: 45), depth: 2),
    ]
    let document = readonlyTopologyDocument([
        readonlyTopologyRegion(1, 5, 290, depth: 0, kind: .container),
        readonlyTopologyRegion(2, 20, 190, depth: 1),
        readonlyTopologyRegion(3, 45, 75, depth: 2),
        readonlyTopologyRegion(4, 50, 60, depth: 3, kind: .block),
    ], facets: facets)
    let topology = try #require(document.foldTopology)
    #expect(topology.associatedFacet(for: FoldID(rawValue: 1)) == nil) // Preserve the old class-association gap.
    #expect(topology.focusTarget(at: 60)?.facet.name == "nested")
    #expect(topology.focusTarget(at: 60)?.region.id == FoldID(rawValue: 3))
    try readonlyTopologyCompare(document)
}

@Test(.isolatedReaderWorkCounters)
func readonlyFoldTopologyGeneratedIntervalsMatchOracleWithoutRebuilding() throws {
    var state: UInt64 = 0xCA17
    var regions: [FoldRegion] = []
    for root in 0..<16 {
        let base = UInt32(root * 30)
        regions.append(readonlyTopologyRegion(UInt32(regions.count), base, base + 29, depth: 0))
        regions.append(readonlyTopologyRegion(UInt32(regions.count), base + 2, base + 14, depth: 1))
        regions.append(readonlyTopologyRegion(UInt32(regions.count), base + 4, base + 10, depth: 2))
        regions.append(readonlyTopologyRegion(UInt32(regions.count), base + 17, base + 27, depth: 1))
    }
    for i in regions.indices.reversed() where i > 0 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        regions.swapAt(i, Int(state % UInt64(i + 1)))
    }
    let beforeBuild = ReaderWorkCounters.snapshot().topologyBuildCount
    let document = readonlyTopologyDocument(regions)
    let topology = try #require(document.foldTopology)
    #expect(!topology.usesCompatibilityRelations)
    #expect(ReaderWorkCounters.snapshot().topologyBuildCount == beforeBuild + 1)
    try readonlyTopologyCompare(document)
    let before = ReaderWorkCounters.snapshot().topologyBuildCount
    for _ in 0..<20 {
        for region in regions { _ = topology.recursiveSiblings(of: region.id) }
        _ = topology.containing(200)
        _ = topology.maximalFoldIDs(Set(regions.map(\.id)))
    }
    #expect(ReaderWorkCounters.snapshot().topologyBuildCount == before)
}

@Test
func readonlyFoldTopologyAncestorToggleRetainsLatentChildState() throws {
    let outer = readonlyTopologyRegion(1, 0, 100, depth: 0)
    let inner = readonlyTopologyRegion(2, 10, 20, depth: 1)
    let topology = try #require(readonlyTopologyDocument([outer, inner]).foldTopology)
    var logical: Set<FoldID> = [inner.id, outer.id]
    #expect(topology.maximalFoldIDs(logical) == [outer.id])
    logical.remove(inner.id)
    #expect(topology.maximalFoldIDs(logical) == [outer.id])
    logical.insert(inner.id)
    logical.remove(outer.id)
    #expect(topology.maximalFoldIDs(logical) == [inner.id])
    #expect(topology.containing(15).map(\.id) == [outer.id, inner.id])
}

@MainActor
@Test
func readonlyFoldTopologyRejectedDocumentCannotTrapOrReplaceExistingReaderText() {
    let reader = ReaderTextView()
    reader.display(document: ReaderDocument(bytes: Array("existing text\n".utf8)))
    let before = reader.view.string
    let invalid = readonlyTopologyDocument([
        readonlyTopologyRegion(1, 0, 10, depth: 0),
        readonlyTopologyRegion(1, 20, 30, depth: 0),
    ])
    #expect(invalid.foldTopologyFailureReason == "duplicate fold ID")
    reader.display(document: invalid)
    #expect(reader.view.string == before)
    reader.clear()
}

@Test
func readonlyFoldTopologyLargeFlatAssociationsPruneUnrelatedFacets() throws {
    let count = 2_048
    var regions: [FoldRegion] = []
    var facets: [OutlineFacet] = []
    for i in 0..<count {
        let start = UInt32(i * 16)
        regions.append(readonlyTopologyRegion(UInt32(i), start + 2, start + 10, depth: 0))
        facets.append(OutlineFacet(kind: .fn, name: "function\(i)",
                                  range: ByteRange(lowerBound: start, upperBound: start + 12),
                                  nameRange: ByteRange(lowerBound: start, upperBound: start + 1), depth: 0))
    }
    // Reverse source order and duplicate some facets: traversal order must not replace input-order ties.
    facets.reverse()
    facets.append(contentsOf: Array(facets.prefix(32)))
    let document = readonlyTopologyDocument(regions, facets: facets, size: count * 16)
    let topology = try #require(document.foldTopology)
    #expect(!topology.usesCompatibilityRelations)
    #expect(topology.associatedFacets.count == count)
    for region in regions {
        #expect(topology.associatedFacet(for: region.id)
                == ReadonlyStructuralOracle.associatedFacet(for: region, in: facets))
    }
    #expect(topology.associationRecordVisits < count * 40)
    #expect(topology.associationRecordVisits < regions.count * facets.count / 20)
    let before = topology.associationRecordVisits
    for region in regions { _ = topology.associatedFacet(for: region.id) }
    #expect(topology.associationRecordVisits == before)
}
