import CodeInsightCore
import CodeInsightReaderCore
import Foundation
import Testing
@testable import CodeInsightReaderUI

// Seed and generator are frozen with the oracle; no system random state is used.
private func readonlyFixture(seed: UInt64, count: Int) -> String {
    var state = seed
    return (0..<count).map { _ in
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return "value\(state % 13)"
    }.joined(separator: " ")
}

@Test
func readonlyIdentifierOracleMatchesEveryByteInMultilingualFixtures() throws {
    let fixtures: [(String, LanguageMode)] = [
        ("fn f() { let café = 1; let cafe\u{301} = café; /* café */ let 中文 = \"中文🚀\"; r#value; }", .init(language: .rust)),
        ("def f(value):\r\n    # value\r\n    return value + value\r\n", .init(language: .python)),
        ("function f($value: number) { return $value; } // $value", .init(language: .typescript)),
        ("const C = () => <div title=\"value\">{value}</div>;", .init(language: .typescript, variant: "tsx")),
        (readonlyFixture(seed: 0xCA17, count: 100), .init(language: .rust)),
        ("", .init(language: .rust)),
    ]
    for (source, mode) in fixtures {
        let document = try DocumentLoader(source: { _ in Array(source.utf8) })
            .load(file: URL(fileURLWithPath: "/readonly-fixture"), languageMode: mode).document
        let oracle = ReadonlyIdentifierOracle(document)
        for offset in 0...document.bytes.count {
            #expect(document.identifierOccurrences(at: UInt32(offset))
                == oracle.occurrences(at: UInt32(offset)))
        }
        #expect(oracle.occurrences(at: .max).isEmpty)
    }
}

@Test
func readonlyProjectionOraclePreservesUnicodeMappingAndCopy() throws {
    let source = "head\r\n中文 🚀 e\u{301}\r\ntail\n"
    let bytes = Array(source.utf8)
    let lines = LineTable(bytes: bytes)
    let fold = FoldRegion(
        id: FoldID(rawValue: 901), kind: .declaration,
        headerRange: ByteRange(lowerBound: 0, upperBound: 4),
        bodyRange: ByteRange(lowerBound: lines.lineStarts[1], upperBound: lines.lineStarts[2]),
        outlineDepth: 0, summary: FoldSummary(hiddenLineCount: 1)
    )
    let document = ReaderDocument(
        bytes: bytes, lineTable: lines, byteUTF16Map: ByteUTF16Map(validUTF8: bytes),
        highlightSpans: [], outlineFacets: [], foldRegions: [fold]
    )
    for ids: Set<FoldID> in [[], [fold.id]] {
        let actual = try #require(DisplayMap(document: document, renderedFoldIDs: ids))
        let oracle = try #require(ReadonlyDisplayMapOracle(document: document, renderedFoldIDs: ids))
        #expect(actual.projectedString == oracle.projectedString)
        #expect(actual.projectedUTF16Length == oracle.projectedUTF16Length)
        for byte in 0...bytes.count {
            switch (actual.displayPosition(ofByte: UInt32(byte)), oracle.displayPosition(ofByte: UInt32(byte))) {
            case (.visible(let a), .visible(let b)): #expect(a == b)
            case (.hidden(let a), .hidden(let b)): #expect(a == b)
            case (nil, nil): break
            default: Issue.record("Source mapping differs at byte \(byte)")
            }
        }
        for lower in 0...actual.projectedUTF16Length {
            for upper in lower...actual.projectedUTF16Length {
                let selection = NSRange(location: lower, length: upper - lower)
                #expect(actual.sourceRanges(forDisplay: selection) == oracle.sourceRanges(forDisplay: selection))
                #expect(actual.visibleSourceRanges(forDisplay: selection) == oracle.visibleSourceRanges(forDisplay: selection))
            }
        }
    }
}

@Test
func readonlyCallOwnershipOracleFreezesTiesContainmentAndLimit() {
    let regions = [
        ExecutableRegionRecord(id: .init(rawValue: 1), kind: .function,
            range: .init(lowerBound: 0, upperBound: 100), enclosingScopeID: .init(rawValue: 0), associatedFacetIndex: 0),
        ExecutableRegionRecord(id: .init(rawValue: 2), kind: .function,
            range: .init(lowerBound: 20, upperBound: 40), enclosingScopeID: .init(rawValue: 0), associatedFacetIndex: 1),
        ExecutableRegionRecord(id: .init(rawValue: 3), kind: .function,
            range: .init(lowerBound: 20, upperBound: 40), enclosingScopeID: .init(rawValue: 0), associatedFacetIndex: 2),
    ]
    #expect(ReadonlyStructuralOracle.callOwner(at: 25, regions: regions) == 2)
    #expect(ReadonlyStructuralOracle.callOwner(at: 40, regions: regions) == 0)
    #expect(ReadonlyStructuralOracle.callOwner(at: 100, regions: regions) == nil)
    for count in [0, 512, 513] {
        let result = ReadonlyStructuralOracle.outgoingCallIndices(
            facet: 0, range: .init(lowerBound: 0, upperBound: 100),
            calls: Array(repeating: .init(lowerBound: 1, upperBound: 2), count: count), regions: regions
        )
        #expect(result.indices == Array(0..<min(count, 512)))
        #expect(result.truncated == (count > 512))
    }
    let excluded = ReadonlyStructuralOracle.outgoingCallIndices(
        facet: 0, range: .init(lowerBound: 0, upperBound: 100),
        calls: [.init(lowerBound: 25, upperBound: 26), .init(lowerBound: 99, upperBound: 101)], regions: regions
    )
    #expect(excluded.indices.isEmpty)
}

@Test
func readonlyFoldOracleFreezesSiblingAndHiddenDescendantSelection() {
    func fold(_ id: UInt32, _ lower: UInt32, _ upper: UInt32, _ depth: Int) -> FoldRegion {
        FoldRegion(id: .init(rawValue: id), kind: .declaration,
            headerRange: .init(lowerBound: lower, upperBound: lower),
            bodyRange: .init(lowerBound: lower, upperBound: upper),
            outlineDepth: depth, summary: .init(hiddenLineCount: 3))
    }
    let regions = [fold(1, 0, 100, 0), fold(2, 10, 40, 1),
        fold(3, 20, 30, 2), fold(4, 50, 80, 1), fold(5, 110, 150, 0)]
    #expect(ReadonlyStructuralOracle.recursiveSiblings(of: regions[1], in: regions)
        == [FoldID(rawValue: 2), FoldID(rawValue: 3), FoldID(rawValue: 4)])
    #expect(ReadonlyStructuralOracle.maximalFoldIDs(
        [FoldID(rawValue: 1), FoldID(rawValue: 3)], in: regions) == [FoldID(rawValue: 1)])
    #expect(ReadonlyStructuralOracle.maximalFoldIDs(
        [FoldID(rawValue: 3)], in: regions) == [FoldID(rawValue: 3)])
}
