import CodeInsightCore
@testable import CodeInsightEngine
import Foundation
import Testing

// Frozen EngineSession ownership rule from f5e116d6477fe20ed9bd83b08b82f4a0512594a7.
// Do not delegate this reference scan to CallOwnershipIndex.
private func readonlyCallOwner(_ call: ByteRange, _ regions: [ExecutableRegionRecord]) -> UInt32? {
    regions.filter { $0.associatedFacetIndex != nil && $0.range.contains(call.lowerBound) }.min {
        if $0.range.length != $1.range.length { return $0.range.length < $1.range.length }
        return $0.id.rawValue > $1.id.rawValue
    }?.associatedFacetIndex
}

private func readonlyOwnedCalls(
    _ facetIndex: UInt32, _ facet: ByteRange, _ calls: [ByteRange], _ regions: [ExecutableRegionRecord]
) -> [Int] {
    calls.indices.filter {
        facet.lowerBound <= calls[$0].lowerBound && calls[$0].upperBound <= facet.upperBound
            && readonlyCallOwner(calls[$0], regions) == facetIndex
    }.sorted {
        if calls[$0].lowerBound != calls[$1].lowerBound {
            return calls[$0].lowerBound < calls[$1].lowerBound
        }
        return $0 < $1
    }
}

private func readonlyRegion(_ id: UInt32, _ lower: UInt32, _ upper: UInt32, _ facet: UInt32?) -> ExecutableRegionRecord {
    ExecutableRegionRecord(id: .init(rawValue: id), kind: facet == nil ? .closure : .function,
        range: .init(lowerBound: lower, upperBound: upper),
        enclosingScopeID: .init(rawValue: 0), associatedFacetIndex: facet)
}

@Test
func readonlyCallOwnershipMatchesCrossingsDuplicatesClosuresAndWholeRangeGuard() {
    let regions = [readonlyRegion(0, 0, 100, 0), readonlyRegion(1, 20, 60, 1),
        readonlyRegion(2, 40, 80, 2), readonlyRegion(3, 45, 55, nil),
        readonlyRegion(4, 40, 80, 3), readonlyRegion(4, 40, 80, 2),
        readonlyRegion(5, 70, 70, 1), readonlyRegion(6, 90, 95, 99)]
    let facets: [ByteRange] = [.init(lowerBound: 0, upperBound: 100),
        .init(lowerBound: 20, upperBound: 60), .init(lowerBound: 40, upperBound: 80),
        .init(lowerBound: 42, upperBound: 75)]
    let calls: [ByteRange] = [.init(lowerBound: 80, upperBound: 90), .init(lowerBound: 50, upperBound: 51),
        .init(lowerBound: 20, upperBound: 21), .init(lowerBound: 50, upperBound: 52),
        .init(lowerBound: 74, upperBound: 77), .init(lowerBound: 40, upperBound: 41),
        .init(lowerBound: 99, upperBound: 101), .init(lowerBound: 100, upperBound: 100),
        .init(lowerBound: 92, upperBound: 93)]
    let index = CallOwnershipIndex(regions: regions, callRanges: calls, facetRanges: facets)
    #expect(index.regionIndexByID[.init(rawValue: 4)] == 4)
    for facet in facets.indices {
        #expect(index.callIndicesByFacet[facet] == readonlyOwnedCalls(UInt32(facet), facets[facet], calls, regions))
    }
    #expect(index.callIndicesByFacet[3] == [1, 3])
    // Calls 4–6 exceed their owner facet; 7 has no owner; 8 has an
    // invalid owner ID. None may leak into an enclosing facet group.
    let grouped = Set(index.callIndicesByFacet.flatMap { $0 })
    #expect(grouped.isDisjoint(with: Set(4...8)))
}

@Test
func readonlyCallOwnershipMatchesSeededArbitraryIntervals() {
    var seed: UInt64 = 0xCA17
    func next(_ bound: UInt32) -> UInt32 {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return UInt32(seed % UInt64(bound))
    }
    for _ in 0..<12 {
        let facets = (0..<17).map { _ -> ByteRange in
            let lower = next(50)
            return .init(lowerBound: lower, upperBound: lower + 100)
        }
        let regions = (0..<120).map { offset -> ExecutableRegionRecord in
            let lower = next(180)
            return readonlyRegion(UInt32(offset % 53), lower, lower + next(60), offset % 7 == 0 ? nil : next(19))
        }
        let calls = (0..<220).map { _ -> ByteRange in
            let lower = next(220)
            return .init(lowerBound: lower, upperBound: lower + next(12))
        }
        let index = CallOwnershipIndex(regions: regions, callRanges: calls, facetRanges: facets)
        for facet in facets.indices {
            #expect(index.callIndicesByFacet[facet] == readonlyOwnedCalls(UInt32(facet), facets[facet], calls, regions))
        }
    }
}

private func readonlySession(_ source: String, extra: Bool = false, language: LanguageID = .rust) throws -> EngineSession {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("readonly-calls-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let filename = language == .python ? "main.py" : language == .typescript ? "main.ts" : "main.rs"
    try source.write(to: root.appendingPathComponent(filename), atomically: true, encoding: .utf8)
    if extra {
        try "fn unrelated() {}\nfn earlier() { unrelated(); }\n".write(
            to: root.appendingPathComponent("a.rs"), atomically: true, encoding: .utf8)
    }
    return try ProjectIndexer().index(root: root, language: language)
}

private func readonlyContext(_ session: EngineSession) -> QueryContext {
    QueryContext(snapshotID: session.snapshotID, analysisProfileID: session.analysisProfile.id, generation: 1)
}

@Test
func readonlyCallOwnershipKeepsZero512And513LimitsInActualSession() throws {
    for count in [0, 512, 513] {
        let source = "fn target() {}\nfn caller() {\n" + String(repeating: "target();\n", count: count) + "}\n"
        let session = try readonlySession(source)
        let context = readonlyContext(session)
        let caller = try #require(session.definitions(of: "caller", context: context).first?.0)
        let result = try session.outgoingCalls(from: caller, context: context)
        #expect(result.calls.count == min(count, 512))
        #expect(result.completeness == (count > 512 ? .truncated : .complete))
        #expect(result.calls.map(\.callSite.localIndex) == (0..<min(count, 512)).map(UInt32.init))
        #expect(result.calls.allSatisfy { $0.calleeName == "target" })
    }
}

@Test
func readonlyCallOwnershipKeepsStoresProfilesAndOldSessionsIndependent() throws {
    let source = "fn target() {}\nfn outer() { let closure = || target(); fn nested() { target(); } nested(); }\n"
    let first = try readonlySession(source)
    let second = try readonlySession(source, extra: true)
    #expect(first.store !== second.store)
    let reprofiled = first.reprofiled(featureSelection: .allFeatures)
    for session in [first, second, reprofiled, first] {
        let context = readonlyContext(session)
        let outer = try #require(session.definitions(of: "outer", context: context).first?.0)
        let nested = try #require(session.definitions(of: "nested", context: context).first?.0)
        #expect(try session.outgoingCalls(from: outer, context: context).calls.map(\.calleeName) == ["target", "nested"])
        #expect(try session.outgoingCalls(from: nested, context: context).calls.map(\.calleeName) == ["target"])
        let callers = try session.callers(of: "target", context: context)
        #expect(callers.count == 2)
        #expect(callers.allSatisfy { $0.callSite.snapshotID == session.snapshotID })
        #expect(callers.contains { $0.region.kind == .closure })
        #expect(try session.outgoingCalls(from: outer, context: context).calls.first?.candidates.first?.target.snapshotID
            == session.snapshotID)
    }
}

@Test
func readonlyCallOwnershipRepeatedQueriesHaveNoRegionScanOrRebuild() throws {
    ReaderWorkCounters.setEnabled(true)
    defer { ReaderWorkCounters.setEnabled(false) }
    let beforeBuild = ReaderWorkCounters.snapshot()
    let session = try readonlySession("fn target() {}\nfn caller() { target(); target(); }\n")
    let context = readonlyContext(session)
    let caller = try #require(session.definitions(of: "caller", context: context).first?.0)
    let built = ReaderWorkCounters.snapshot()
    #expect(built.ownershipBuildCount > beforeBuild.ownershipBuildCount)
    for _ in 0..<20 {
        #expect(try session.outgoingCalls(from: caller, context: context).calls.count == 2)
        #expect(try session.callers(of: "target", context: context).count == 2)
    }
    let queried = ReaderWorkCounters.snapshot()
    #expect(queried.ownershipBuildCount == built.ownershipBuildCount)
    #expect(queried.regionQueryRecordVisits == built.regionQueryRecordVisits)
}


@Test
func readonlyCallOwnershipMatchesExtractedMethodsDefaultArgumentsAndTopLevelCalls() throws {
    let fixtures: [(LanguageID, String)] = [
        (.python, "def target():\n    return 1\nclass Box:\n    def method(self, value=target()):\n        return target()\nresult = target()\n"),
        (.typescript, "function target() { return 1; } class Box { method(value = target()) { return target(); } } target();"),
    ]
    for (language, source) in fixtures {
        let session = try readonlySession(source, language: language)
        let context = readonlyContext(session)
        for file in session.manifest.files {
            let (_, content) = try #require(session.content(at: file.pathID))
            let ranges = content.calls.map(\.range)
            #expect(!ranges.isEmpty)
            for facet in content.symbols.indices {
                let definition = SymbolOccurrenceID(snapshotID: session.snapshotID, pathID: file.pathID,
                    localKind: .declarationFacet, localIndex: UInt32(facet))
                let expected = readonlyOwnedCalls(UInt32(facet), content.symbols[facet].range, ranges, content.executableRegions)
                let actual = try session.outgoingCalls(from: definition, context: context)
                #expect(actual.calls.map(\.callSite.localIndex) == expected.prefix(512).map(UInt32.init))
                #expect(actual.completeness == (expected.count > 512 ? .truncated : .complete))
            }
        }
    }
}
