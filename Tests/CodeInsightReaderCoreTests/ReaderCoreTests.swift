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
func commentContentClassifierProtectsFiguresAndAllowsProse() {
    #expect(CommentContentKind.classify("""
        +-----+
        | API |
        +-----+
        """) == .figure)
    #expect(CommentContentKind.classify("""
        | name | value |
        | foo  | 1     |
        """) == .figure)
    #expect(CommentContentKind.classify(
        "This comment explains why the fallback is safe."
    ) == .prose)
    #expect(CommentContentKind.classify(
        "这里解释为什么回退路径是安全的。"
    ) == .prose)
    #expect(CommentContentKind.classify("""
        Explanation before the diagram.
        +---+
        | A |
        +---+
        """) == .figure)
}

@Test
func rustHighlighterStylesEveryDeclarationWithoutTouchingCalls() throws {
    let source = """
        mod outer {
            struct Widget;
            enum State { Ready }
            trait Work {
                fn required(&self);
            }
            impl Work for Widget {
                fn run(&self) {}
            }
            const LIMIT: usize = 3;
            static FLAG: bool = true;
            type Alias = Widget;
            fn call_site() { run(); }
        }
        fn top() {}
        """
    let result = try RustHighlighter().highlight(bytes: Array(source.utf8))
    let declarationKinds: Set<HighlightKind> = [
        .functionName, .declarationTitle, .declarationEmphasis,
    ]

    for facet in result.outlineFacets {
        let matching = result.spans.filter {
            $0.range == facet.nameRange && declarationKinds.contains($0.kind)
        }
        switch facet.kind {
        case .fn, .method:
            #expect(matching.map(\.kind) == [.functionName])
        case .struct, .enum, .trait, .typeAlias:
            #expect(matching.map(\.kind) == [.declarationTitle])
        case .mod, .const, .static:
            #expect(matching.map(\.kind) == [.declarationEmphasis])
        case .impl:
            #expect(matching.isEmpty)
        }
    }

    for kind in [
        OutlineKind.fn, .method, .struct, .enum, .trait, .impl, .mod,
        .const, .static, .typeAlias,
    ] {
        #expect(result.outlineFacets.contains { $0.kind == kind })
    }
    let callRange = try #require(source.range(of: "run();", options: .backwards))
    let callOffset = UInt32(source[..<callRange.lowerBound].utf8.count)
    #expect(!result.spans.contains {
        declarationKinds.contains($0.kind) && $0.range.contains(callOffset)
    })
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
        "4..<6:declarationEmphasis",
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
func viewportGatingHandlesEmptySingleAndBoundaryRanges() {
    let span = HighlightSpan(
        range: ByteRange(lowerBound: 10, upperBound: 20),
        kind: .keyword
    )

    #expect(ViewportGating.spans(
        [],
        intersecting: ByteRange(lowerBound: 10, upperBound: 20),
        buffer: 0
    ).isEmpty)
    #expect(ViewportGating.spans(
        [span],
        intersecting: ByteRange(lowerBound: 10, upperBound: 20),
        buffer: 0
    ) == [span])
    #expect(ViewportGating.spans(
        [span],
        intersecting: ByteRange(lowerBound: 20, upperBound: 21),
        buffer: 0
    ).isEmpty)
    #expect(ViewportGating.spans(
        [span],
        intersecting: ByteRange(lowerBound: 9, upperBound: 10),
        buffer: 0
    ).isEmpty)
}

@Test
func viewportGatingMatchesLinearScanForLargeSortedInput() {
    let spans = (0..<20_000).map { index in
        let lower = UInt32(index * 7)
        return HighlightSpan(
            range: ByteRange(lowerBound: lower, upperBound: lower + 3),
            kind: .keyword
        )
    }

    for viewport in stride(from: UInt32(0), to: 140_000, by: 997) {
        let range = ByteRange(lowerBound: viewport, upperBound: viewport + 311)
        let lower = viewport > 17 ? viewport - 17 : 0
        let upper = range.upperBound + 17
        let buffered = ByteRange(lowerBound: lower, upperBound: upper)
        #expect(ViewportGating.spans(
            spans,
            intersecting: range,
            buffer: 17
        ) == spans.filter { $0.range.overlaps(buffered) })
    }
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
    #expect(loaded.document.contentID == ContentID.sha256(of: loaded.document.bytes))
    #expect(loaded.document.highlightSpans.isEmpty)
    let completed = await withCheckedContinuation { continuation in
        loader.loadSyntax(for: loaded.document) { result in
            continuation.resume(returning: result)
        }
    }
    let document = try completed.get()
    #expect(document.contentID == loaded.document.contentID)
    #expect(!document.highlightSpans.isEmpty)
    #expect(document.outlineFacets.count == 10_001)
}

@Test
func hugeDocumentDeclarationSpanProbe() throws {
    var lines: [String] = []
    lines.reserveCapacity(100_000)
    for index in 0..<10_000 {
        lines.append("const ITEM_\(index): usize = \(index);")
        for proseLine in 0..<9 {
            lines.append("// prose comment \(proseLine)")
        }
    }
    let result = try RustHighlighter().highlight(
        bytes: Array(lines.joined(separator: "\n").utf8)
    )

    print("S6 huge span probe: spans=\(result.spans.count) declarations=\(result.outlineFacets.count)")
    #expect(result.spans.count == 130_000)
    #expect(result.outlineFacets.count == 10_000)
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
