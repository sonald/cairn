import CodeInsightCore
import Foundation
import Testing
@testable import CodeInsightReaderCore

private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

@Test
func rustHighlighterProducesStableSpans() throws {
    let source = "fn greet(value: usize) -> String { // hi\n    let n = 42; \"ok\".to_string()\n}\n"
    let result = try RustHighlighter().highlight(bytes: Array(source.utf8))
    let snapshot = result.spans.map {
        "\($0.range.lowerBound)..<\($0.range.upperBound):\($0.kind)"
    }

    #expect(snapshot == [
        "0..<2:keyword",
        "3..<8:functionName",
        "16..<21:typeName",
        "26..<32:typeName",
        "35..<40:comment",
        "45..<48:keyword",
        "53..<55:number",
        "57..<61:string",
    ])
    #expect(result.outlineFacets == [OutlineFacet(
        name: "greet",
        range: ByteRange(lowerBound: 3, upperBound: 8)
    )])
}

@Test
func rustHighlighterMatchesFixtureSnapshot() throws {
    let fixture = repositoryRoot
        .appendingPathComponent("Tests/RustExtractorTests/Fixtures/use_alias/main.rs")
    let bytes = Array(try Data(contentsOf: fixture))
    let spans = try RustHighlighter().highlight(bytes: bytes).spans.map {
        "\($0.range.lowerBound)..<\($0.range.upperBound):\($0.kind)"
    }

    #expect(spans == [
        "0..<3:keyword",
        "8..<11:keyword",
        "24..<26:keyword",
        "36..<38:keyword",
        "39..<43:functionName",
    ])
}

@Test
func fileTierUsesLineCountBoundaries() {
    #expect(FileTier(lineCount: 10_000) == .regular)
    #expect(FileTier(lineCount: 10_001) == .large)
    #expect(FileTier(lineCount: 50_000) == .large)
    #expect(FileTier(lineCount: 50_001) == .huge)
}

@Test
func viewportGatingReturnsOnlyBufferedIntersections() {
    let spans = [
        HighlightSpan(range: ByteRange(lowerBound: 0, upperBound: 5), kind: .keyword),
        HighlightSpan(range: ByteRange(lowerBound: 10, upperBound: 15), kind: .string),
        HighlightSpan(range: ByteRange(lowerBound: 20, upperBound: 25), kind: .number),
        HighlightSpan(range: ByteRange(lowerBound: 30, upperBound: 35), kind: .comment),
    ]

    #expect(ViewportGating.spans(
        spans,
        intersecting: ByteRange(lowerBound: 16, upperBound: 19),
        buffer: 3
    ) == Array(spans[1...2]))
}

@Test
func largeDocumentLoadsPlainTextBeforeDetachedSyntax() async throws {
    let file = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodeInsightReaderCoreTests-\(UUID().uuidString).rs")
    let source = String(repeating: "fn item() {}\n", count: 10_001)
    try source.write(to: file, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: file) }
    let loader = DocumentLoader()

    let loaded = try loader.load(file: file)

    #expect(loaded.tier == .large)
    #expect(loaded.document.highlightSpans.isEmpty)
    let completed = await withCheckedContinuation { continuation in
        loader.loadSyntax(for: loaded.document) { result in
            continuation.resume(returning: result)
        }
    }
    let document = try completed.get()
    #expect(!document.highlightSpans.isEmpty)
    #expect(document.outlineFacets.count == 10_001)
}
