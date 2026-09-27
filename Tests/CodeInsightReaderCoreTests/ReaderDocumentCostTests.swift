import Testing
@testable import CodeInsightReaderCore

@Test
func readonlyCostPreservesLineBoundariesAndRejectsInvalidMetadata() throws {
    let empty = try #require(ReaderDocumentCost(byteCount: 0, lineStarts: [0], highlightSpanCount: 0, foldRegionCount: 0))
    #expect(empty.logicalLineCount == 1)
    #expect(empty.maximumLineByteLength == 0)
    // Bytes: 中文 + CRLF + emoji + LF. Source line lengths include newline bytes.
    let unicode = try #require(ReaderDocumentCost(byteCount: 13, lineStarts: [0, 8, 13], highlightSpanCount: 2, foldRegionCount: 1))
    #expect(unicode.maximumLineByteLength == 8)
    #expect(unicode.logicalLineCount == 3)
    #expect(unicode.highlightSpanCount == 2 && unicode.foldRegionCount == 1)
    #expect(ReaderDocumentCost(byteCount: 3, lineStarts: [0, 4], highlightSpanCount: 0, foldRegionCount: 0) == nil)
    #expect(ReaderDocumentCost(byteCount: 3, lineStarts: [0, 0], highlightSpanCount: 0, foldRegionCount: 0) == nil)
    #expect(ReaderDocumentCost(byteCount: 3, lineStarts: [], highlightSpanCount: 0, foldRegionCount: 0) == nil)
}

@Test
func readonlyCostGatesLargeFilesAndLongLinesIndependentlyOfViewportPresence() throws {
    let policy = ReaderReflowPolicy()
    let atLimit = try #require(ReaderDocumentCost(byteCount: 7_999, lineStarts: (0..<8_000).map(UInt32.init), highlightSpanCount: 0, foldRegionCount: 0))
    let overLimit = try #require(ReaderDocumentCost(byteCount: 8_000, lineStarts: (0...8_000).map(UInt32.init), highlightSpanCount: 0, foldRegionCount: 0))
    #expect(!policy.requiresViewportOnlyLayout(for: atLimit))
    #expect(policy.requiresViewportOnlyLayout(for: overLimit))
    let longLine = try #require(ReaderDocumentCost(byteCount: 1_048_576, lineStarts: [0], highlightSpanCount: 1, foldRegionCount: 0))
    #expect(policy.requiresViewportOnlyLayout(for: longLine))
    let boundaryLine = try #require(ReaderDocumentCost(byteCount: 65_536, lineStarts: [0], highlightSpanCount: 0, foldRegionCount: 0))
    #expect(!policy.requiresViewportOnlyLayout(for: boundaryLine))
    #expect(ReaderReflowPolicy(maximumSynchronousLineBytes: 65_535).requiresViewportOnlyLayout(for: boundaryLine))
    // No viewport argument exists: both mounted and absent-viewport branches share this decision.
}
