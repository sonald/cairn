import CodeInsightCore
import Foundation
import Testing
@testable import CodeInsightReaderCore

@Test
func readonlyIdentifierIndexMatchesFrozenOracleAtEveryByte() throws {
    let fixtures: [(String, LanguageMode)] = [
        ("fn f() { let café = 1; let cafe\u{301} = café; /* café */ let 中文 = \"中文🚀\"; r#value; value; 1value; 123; }", .init(language: .rust)),
        ("def f(value):\r\n    # value\r\n    return value + value\r\n", .init(language: .python)),
        ("function f($value: number) { return $value; } // $value", .init(language: .typescript)),
        ("const C = () => <div title=\"value\">{value}</div>;", .init(language: .typescript, variant: "tsx")),
        ("", .init(language: .rust)),
        ("a", .init(language: .rust)),
    ]
    for (source, mode) in fixtures {
        let document = try DocumentLoader(source: { _ in Array(source.utf8) })
            .load(file: URL(fileURLWithPath: "/readonly-fixture"), languageMode: mode).document
        let oracle = ReadonlyIdentifierOracle(document)
        let index = try IdentifierIndex(document: document)
        for offset in 0...document.bytes.count {
            #expect(Array(index.occurrences(at: UInt32(offset))) == oracle.occurrences(at: UInt32(offset)))
        }
        #expect(index.occurrences(at: .max).isEmpty)
        #expect(index.postingOffsets.count == index.names.count + 1)
        #expect(index.postingOffsets.last == index.occurrenceRanges.count)
    }
}

@Test
func readonlyIdentifierIndexPreservesNumericPrefixesAndCanonicalEquivalence() throws {
    let source = "name 1name \u{301}name café cafe\u{301} 🚀name name1 r#name"
    let bytes = Array(source.utf8)
    let document = ReaderDocument(bytes: bytes, lineTable: LineTable(bytes: bytes),
        byteUTF16Map: ByteUTF16Map(validUTF8: bytes), highlightSpans: [], outlineFacets: [])
    let index = try IdentifierIndex(document: document)
    let oracle = ReadonlyIdentifierOracle(document)
    for offset in 0...bytes.count {
        #expect(Array(index.occurrences(at: UInt32(offset))) == oracle.occurrences(at: UInt32(offset)))
    }
    #expect(index.names.filter { $0 == "café" }.count == 1)
    #expect(index.occurrences(at: 0).count == 5)
    #expect(index.occurrences(at: 7).isEmpty)
}

@Test
func readonlyIdentifierIndexMergesExclusionsAndStillSelectsCommentWords() throws {
    let bytes = Array("word word word word".utf8)
    let spans = [
        HighlightSpan(range: .init(lowerBound: 8, upperBound: 12), kind: .string),
        HighlightSpan(range: .init(lowerBound: 4, upperBound: 9), kind: .comment),
        HighlightSpan(range: .init(lowerBound: 12, upperBound: 14), kind: .number),
    ]
    let index = try IdentifierIndex(bytes: bytes, languageMode: .init(language: .rust), highlightSpans: spans)
    let expected = [ByteRange(lowerBound: 0, upperBound: 4), ByteRange(lowerBound: 15, upperBound: 19)]
    #expect(Array(index.occurrences(at: 6)) == expected)
    #expect(Array(index.occurrences(at: 11)) == expected)
}

@Test
func readonlyIdentifierIndexMatchesSeededAdversarialTokens() throws {
    var seed: UInt64 = 0xCA17
    let atoms = ["a", "a1", "1a", "123", "é", "e\u{301}", "\u{301}a", "中文", "🚀", "_", "$a", "r#a", "fn", "// a", "\"a\"", "\r\n", "\u{2028}"]
    var source = ""
    for _ in 0..<180 {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        source += atoms[Int(seed % UInt64(atoms.count))] + " "
    }
    let bytes = Array(source.utf8)
    for language: LanguageID in [.rust, .python, .typescript, .javascript] {
        let document = ReaderDocument(bytes: bytes, languageMode: .init(language: language),
            lineTable: LineTable(bytes: bytes), byteUTF16Map: ByteUTF16Map(validUTF8: bytes),
            highlightSpans: [], outlineFacets: [])
        let index = try IdentifierIndex(document: document)
        let oracle = ReadonlyIdentifierOracle(document)
        for offset in 0...bytes.count {
            #expect(Array(index.occurrences(at: UInt32(offset))) == oracle.occurrences(at: UInt32(offset)))
        }
    }
}

@Test
func readonlyIdentifierIndexRejectsInvalidUTF8AndHonorsCancellation() async throws {
    #expect(throws: CocoaError.self) {
        try IdentifierIndex(bytes: [0xFF], languageMode: .init(language: .rust), highlightSpans: [])
    }
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try IdentifierIndex(bytes: Array("name".utf8), languageMode: .init(language: .rust), highlightSpans: [])
    }
    do {
        _ = try await task.value
        Issue.record("Cancelled index build unexpectedly succeeded")
    } catch is CancellationError {
        // Expected before decoding or allocating derived tables.
    }
}

@Test(.isolatedReaderWorkCounters)
func readonlyIdentifierIndexHotQueriesDoNotScanOrBuild() throws {
    let bytes = Array("value value value".utf8)
    let initial = ReaderWorkCounters.snapshot()
    let index = try IdentifierIndex(bytes: bytes, languageMode: .init(language: .rust), highlightSpans: [])
    let before = ReaderWorkCounters.snapshot()
    #expect(before.identifierBuildCount - initial.identifierBuildCount == 1)
    #expect(before.identifierScannedBytes - initial.identifierScannedBytes == bytes.count)
    for _ in 0..<100 {
        #expect(index.occurrences(at: 0).count == 3)
        #expect(index.occurrences(at: 7).count == 3)
    }
    let after = ReaderWorkCounters.snapshot()
    #expect(after.identifierBuildCount == before.identifierBuildCount)
    #expect(after.identifierScannedBytes == before.identifierScannedBytes)
    #expect(after.identifierDecodedBytes == before.identifierDecodedBytes)
}
