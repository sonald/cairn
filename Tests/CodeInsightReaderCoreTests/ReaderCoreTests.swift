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
        kind: .fn,
        name: "greet",
        range: ByteRange(
            lowerBound: 0,
            upperBound: UInt32(source.dropLast().utf8.count)
        ),
        nameRange: ByteRange(lowerBound: 3, upperBound: 8),
        depth: 0
    )])
    let bodyOffset = UInt32(source[..<source.range(of: "let n")!.lowerBound].utf8.count)
    #expect(ReaderDocument(
        bytes: Array(source.utf8),
        highlightSpans: result.spans,
        outlineFacets: result.outlineFacets
    ).symbolAnchor(at: bodyOffset) == "greet")
}

@Test
func rustHighlighterProducesOutlineSnapshot() throws {
    let source = [
        "mod outer {",
        "    struct Widget;",
        "    enum State { Ready }",
        "    trait Work {",
        "        fn required(&self);",
        "    }",
        "    impl Work for Widget {",
        "        fn run(&self) {}",
        "    }",
        "    const LIMIT: usize = 3;",
        "    static FLAG: bool = true;",
        "    type Alias = Widget;",
        "}",
        "fn top() {}",
    ].joined(separator: "\n")

    let facets = try RustHighlighter().highlight(bytes: Array(source.utf8)).outlineFacets
    let snapshot = facets.map {
        "\($0.depth):\($0.kind.rawValue):\($0.name):"
            + "\($0.nameRange.lowerBound)..<\($0.nameRange.upperBound)"
    }

    #expect(snapshot == [
        "0:mod:outer:4..<9",
        "1:struct:Widget:23..<29",
        "1:enum:State:40..<45",
        "1:trait:Work:66..<70",
        "2:method:required:84..<92",
        "1:impl:Widget:125..<131",
        "2:method:run:145..<148",
        "1:const:LIMIT:175..<180",
        "1:static:FLAG:204..<208",
        "1:typeAlias:Alias:232..<237",
        "0:fn:top:253..<256",
    ])
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

@Test
func excerptAttachesAdjacentDocCommentsAndMarksOverflow() {
    let body = (1...26).map { "    let value\($0) = \($0);" }
    let source = ([
        "//! Module detail",
        "/// Opens the database.",
        "fn connect() {",
    ] + body + ["}"]).joined(separator: "\n")
    let start = UInt32(source.utf8.distance(
        from: source.utf8.startIndex,
        to: source.range(of: "fn connect")!.lowerBound
    ))
    let document = readerDocument(source)

    let value = excerpt(
        for: ByteRange(lowerBound: start, upperBound: UInt32(source.utf8.count)),
        in: document
    )

    #expect(value.hasPrefix("//! Module detail\n/// Opens the database.\nfn connect() {"))
    #expect(value.hasSuffix("… 4 more lines"))
}

@Test
func excerptStartsAtTargetWhenThereIsNoAdjacentDocComment() {
    let source = "// ordinary comment\n\nfn plain() {\n    work();\n}"
    let start = UInt32(source[..<source.range(of: "fn plain")!.lowerBound].utf8.count)

    let value = excerpt(
        for: ByteRange(lowerBound: start, upperBound: UInt32(source.utf8.count)),
        in: readerDocument(source)
    )

    #expect(value == "fn plain() {\n    work();\n}")
}

@Test
func excerptStopsCleanlyAtFileEnd() {
    let source = "fn tail() {\n    work();\n}"

    #expect(excerpt(
        for: ByteRange(lowerBound: 0, upperBound: UInt32(source.utf8.count)),
        in: readerDocument(source)
    ) == source)
}

@Test
func bindingExcerptUsesDeclarationLinePlusTwoLinesEachSide() {
    let source = (1...8).map { "line \($0)" }.joined(separator: "\n")
    let declaration = source.range(of: "line 5")!
    let start = UInt32(source[..<declaration.lowerBound].utf8.count)

    #expect(excerpt(
        for: ByteRange(lowerBound: start, upperBound: start + 6),
        in: readerDocument(source),
        binding: true
    ) == "line 3\nline 4\nline 5\nline 6\nline 7")
}

private func readerDocument(_ source: String) -> ReaderDocument {
    let bytes = Array(source.utf8)
    return ReaderDocument(
        bytes: bytes,
        lineTable: LineTable(bytes: bytes),
        byteUTF16Map: ByteUTF16Map(validUTF8: bytes),
        highlightSpans: [],
        outlineFacets: []
    )
}
