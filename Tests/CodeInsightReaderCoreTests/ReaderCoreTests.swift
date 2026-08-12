import CodeInsightCore
import CodeInsightRustExtractor
import Foundation
import os
import Testing
@testable import CodeInsightReaderCore

private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

@Test
func explicitRustDocumentLoadMatchesConvenienceAndCarriesMode() throws {
    let bytes = Array("fn greet(value: usize) { let copy = value; }\n".utf8)
    let loader = DocumentLoader(source: { _ in bytes })
    let file = URL(fileURLWithPath: "/fixture.rs")
    let mode = LanguageMode(language: .rust, variant: "artificial-test-mode")

    let convenience = try loader.load(file: file)
    let explicit = try loader.load(file: file, languageMode: mode)

    #expect(convenience.tier == explicit.tier)
    #expect(convenience.document.languageMode == LanguageMode(language: .rust))
    #expect(explicit.document.languageMode == mode)
    #expect(convenience.document.bytes == explicit.document.bytes)
    #expect(convenience.document.contentID == explicit.document.contentID)
    #expect(convenience.document.lineTable == explicit.document.lineTable)
    #expect(convenience.document.byteUTF16Map.bytes == explicit.document.byteUTF16Map.bytes)
    #expect(convenience.document.byteUTF16Map.utf16Count
        == explicit.document.byteUTF16Map.utf16Count)
    #expect(convenience.document.highlightSpans == explicit.document.highlightSpans)
    #expect(convenience.document.outlineFacets == explicit.document.outlineFacets)
    #expect(convenience.document.foldRegions == explicit.document.foldRegions)
    #expect(convenience.document.localBindings.map(\.kind.rawValue)
        == explicit.document.localBindings.map(\.kind.rawValue))
    #expect(convenience.document.localBindings.map(\.declarationRange)
        == explicit.document.localBindings.map(\.declarationRange))
    #expect(convenience.document.referencesByBinding
        == explicit.document.referencesByBinding)
}

#if DEBUG
@Test
func unsupportedDocumentModeFailsBeforeParsing() throws {
    let parseCount = OSAllocatedUnfairLock(initialState: 0)
    let loader = DocumentLoader(source: { _ in Array("const x: number = 1\n".utf8) })

    do {
        _ = try RustExtractor.$parseObserver.withValue({
            parseCount.withLock { $0 += 1 }
        }) {
            try loader.load(
                file: URL(fileURLWithPath: "/fixture.py"),
                languageMode: LanguageMode(language: .typescript)
            )
        }
        Issue.record("DocumentLoader accepted an unsupported TypeScript mode")
    } catch RustHighlighterError.unsupportedLanguage(let language) {
        #expect(language == .typescript)
    } catch {
        Issue.record("DocumentLoader returned the wrong error: \(error)")
    }

    #expect(parseCount.withLock { $0 } == 0)
}

@Test
func unsupportedAsyncSyntaxModeFailsBeforeHighlighting() async {
    let resolutionCount = OSAllocatedUnfairLock(initialState: 0)
    let loader = DocumentLoader(
        source: { _ in [] },
        foldResolutionObserver: { _, _, _ in
            resolutionCount.withLock { $0 += 1 }
        }
    )
    let document = ReaderDocument(
        bytes: Array("const x = 1\n".utf8),
        languageMode: LanguageMode(language: .typescript)
    )

    let completed = await withCheckedContinuation { continuation in
        loader.loadSyntax(for: document) { result in
            continuation.resume(returning: result)
        }
    }
    switch completed {
    case .success:
        Issue.record("Detached syntax accepted an unsupported TypeScript mode")
    case .failure(.unsupportedLanguage(let language)):
        #expect(language == .typescript)
    case .failure(let error):
        Issue.record("Detached syntax returned the wrong error: \(error)")
    }
    #expect(resolutionCount.withLock { $0 } == 0)
}
@Test
func pythonReaderUsesOneParseForSpansOutlineFoldAndLocalRefs() throws {
    let source = """
        import os
        import sys

        class Greeter:
            def hello(self, name):
                return name

        def top():
            n = 7
            g = "hi"
            return hello(g)
        """
    let parseCount = OSAllocatedUnfairLock(initialState: 0)
    let result = try DocumentLoader.$pythonParseObserver.withValue({
        parseCount.withLock { $0 += 1 }
    }) {
        try pythonReaderHighlightWithFolds(bytes: Array(source.utf8))
    }

    #expect(parseCount.withLock { $0 } == 1)
    #expect(result.outlineFacets.map(\.kind) == [
        OutlineKind.class, .method, .fn,
    ])
    #expect(result.folds.contains { $0.kind == .imports })
    #expect(result.folds.contains { $0.kind == .container })
    #expect(result.folds.contains { $0.kind == .declaration })
    #expect(result.spans.contains { $0.kind == .keyword })
    #expect(result.spans.contains { $0.kind == .number })
    #expect(result.spans.contains { $0.kind == .string })
    #expect(result.spans == result.spans.sorted {
        ($0.range.lowerBound, $0.range.upperBound, $0.kind.rawValue)
            < ($1.range.lowerBound, $1.range.upperBound, $1.kind.rawValue)
    })
    let clickedString = try #require(result.spans.first {
        $0.kind == .string
    })
    #expect(result.spans
        .filter { $0.range.overlaps(clickedString.range) }
        .allSatisfy { $0.kind == .string })
}
#endif

@Test
func pythonReaderLocalReferencesScopeAndRhsActivation() throws {
    let source = """
        def outer():
            x = 1
            x
            def inner():
                x = x + 1
                x
            inner()
        def sibling():
            x = 2
            x
        """
    let bytes = Array(source.utf8)
    let highlighted = try pythonReaderHighlightWithFolds(bytes: bytes)
    let document = ReaderDocument(
        bytes: bytes,
        languageMode: LanguageMode(language: .python),
        highlightSpans: highlighted.spans,
        outlineFacets: highlighted.outlineFacets,
        localBindings: highlighted.bindings,
        referencesByBinding: highlighted.referencesByBinding
    )

    let xs = tokenRanges(of: "x", in: source)
    let outer = try #require(document.localBinding(at: xs[0].lowerBound))
    let inner = try #require(document.localBinding(at: xs[2].lowerBound))
    let sibling = try #require(document.localBinding(at: xs[5].lowerBound))

    #expect(outer.references == [xs[1], xs[3]])
    #expect(inner.references == [xs[4]])
    #expect(sibling.references == [xs[6]])
}

@Test
func pythonReaderFoldsCommentsAndImportsInsideFunctionBodies() throws {
    let source = """
        def work():
            # one
            # two
            import os
            import sys
            return 1
        """
    let result = try pythonReaderHighlightWithFolds(bytes: Array(source.utf8))

    #expect(result.folds.contains { $0.kind == .comment && $0.summary.itemCount == 2 })
    #expect(result.folds.contains { $0.kind == .imports && $0.summary.itemCount == 2 })
}

@Test
func pythonReaderSpansAndOutlineIncludeBasicSyntax() throws {
    let source = [
        "class Widget:",
        "    def __init__(self, name):",
        "        self.name = name  # comment",
        "",
        "    async def render(self):",
        "        return f\"hi {self.name}\"",
        "",
        "@widget",
        "def make() -> Widget:",
        "    return Widget()",
    ].joined(separator: "\n")

    let result = try pythonReaderHighlightWithFolds(bytes: Array(source.utf8))

    #expect(result.outlineFacets == [
        OutlineFacet(
            kind: .class,
            name: "Widget",
            range: ByteRange(lowerBound: 0, upperBound: 141),
            nameRange: ByteRange(lowerBound: 6, upperBound: 12),
            depth: 0
        ),
        OutlineFacet(
            kind: .method,
            name: "__init__",
            range: ByteRange(lowerBound: 18, upperBound: 79),
            nameRange: ByteRange(lowerBound: 22, upperBound: 30),
            depth: 1
        ),
        OutlineFacet(
            kind: .method,
            name: "render",
            range: ByteRange(lowerBound: 85, upperBound: 141),
            nameRange: ByteRange(lowerBound: 95, upperBound: 101),
            depth: 1
        ),
        OutlineFacet(
            kind: .fn,
            name: "make",
            range: ByteRange(lowerBound: 143, upperBound: 192),
            nameRange: ByteRange(lowerBound: 155, upperBound: 159),
            depth: 0
        ),
    ])
    let comments = result.spans.filter { $0.kind == .comment }
    #expect(comments.count == 1)
    let strings = result.spans.filter { $0.kind == .string }
    #expect(strings.count == 1)
    let defKeyword = try #require(result.spans.first {
        text(in: source, range: $0.range) == "def"
    })
    #expect(defKeyword.kind == .keyword)
}

@Test
func identifierOccurrencesUseTheDocumentLanguageMode() {
    let bytes = Array("value value\n".utf8)
    let convenience = ReaderDocument(bytes: bytes)
    let explicitRust = ReaderDocument(
        bytes: bytes,
        languageMode: LanguageMode(language: .rust)
    )
    let python = ReaderDocument(
        bytes: bytes,
        languageMode: LanguageMode(language: .python)
    )

    #expect(convenience.identifierOccurrences(at: 0)
        == explicitRust.identifierOccurrences(at: 0))
    #expect(python.identifierOccurrences(at: 0)
        == explicitRust.identifierOccurrences(at: 0))

    let pythonKeyword = ReaderDocument(
        bytes: Array("def def\n".utf8),
        languageMode: LanguageMode(language: .python)
    )
    #expect(pythonKeyword.identifierOccurrences(at: 0).isEmpty)
}

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
func identifierOccurrencesMatchWholeTokensAndSkipCommentsStringsAndKeywords() throws {
    let source = """
        let value = 1;
        let value2 = value;
        println!("value");
        // value
        value
        """
    let bytes = Array(source.utf8)
    let highlighted = try RustHighlighter().highlight(bytes: bytes)
    let document = ReaderDocument(
        bytes: bytes,
        highlightSpans: highlighted.spans,
        outlineFacets: highlighted.outlineFacets
    )
    let clicked = try #require(source.range(of: "value"))
    let byteOffset = UInt32(source[..<clicked.lowerBound].utf8.count)

    #expect(document.identifierOccurrences(at: byteOffset).count == 3)
    #expect(document.identifierOccurrences(at: 0).isEmpty)

    let unicode = "let 值 = 1;\n值"
    let unicodeDocument = ReaderDocument(bytes: Array(unicode.utf8))
    let unicodeRange = try #require(unicode.range(of: "值"))
    let unicodeOffset = UInt32(unicode[..<unicodeRange.lowerBound].utf8.count)
    #expect(unicodeDocument.identifierOccurrences(at: unicodeOffset).count == 2)
}

@Test
func localReferenceIndexFindsKnownParameterAndLocalUses() throws {
    let source = """
        fn f(param: i32) {
            param;
            let local = param;
            local;
        }
        """
    let paramRanges = tokenRanges(of: "param", in: source)
    let localRanges = tokenRanges(of: "local", in: source)
    let document = try localReferenceDocument(source)

    let parameter = try #require(document.localBinding(
        at: paramRanges[0].lowerBound
    ))
    let local = try #require(document.localBinding(
        at: localRanges[0].lowerBound
    ))

    #expect(parameter.binding.kind == .param)
    #expect(parameter.references == Array(paramRanges.dropFirst()))
    #expect(local.binding.kind == .letBinding)
    #expect(local.references == Array(localRanges.dropFirst()))
    #expect(!parameter.references.contains(parameter.binding.declarationRange))
    #expect(!local.references.contains(local.binding.declarationRange))
}

@Test
func localReferenceIndexSeparatesNestedShadowing() throws {
    let source = """
        fn f() {
            let x = 0;
            x;
            {
                let x = x + 1;
                x;
            }
            x;
        }
        """
    let ranges = tokenRanges(of: "x", in: source)
    let document = try localReferenceDocument(source)
    let outer = try #require(document.localBinding(at: ranges[0].lowerBound))
    let inner = try #require(document.localBinding(at: ranges[2].lowerBound))

    #expect(outer.references == [ranges[1], ranges[3], ranges[5]])
    #expect(inner.references == [ranges[4]])
}

@Test
func localReferenceIndexSeparatesSiblingScopes() throws {
    let source = """
        fn first() {
            let x = 0;
            x;
        }
        fn second() {
            let x = 1;
            x;
        }
        """
    let ranges = tokenRanges(of: "x", in: source)
    let document = try localReferenceDocument(source)
    let first = try #require(document.localBinding(at: ranges[0].lowerBound))
    let second = try #require(document.localBinding(at: ranges[2].lowerBound))

    #expect(first.references == [ranges[1]])
    #expect(second.references == [ranges[3]])
}

@Test
func localReferenceIndexExcludesTokensBeforeAndAtDeclaration() throws {
    let source = """
        fn f() {
            x();
            let x = || {};
            x();
        }
        """
    let ranges = tokenRanges(of: "x", in: source)
    let document = try localReferenceDocument(source)
    let local = try #require(document.localBinding(at: ranges[1].lowerBound))

    #expect(local.references == [ranges[2]])
    #expect(!local.references.contains(ranges[0]))
    #expect(!local.references.contains(local.binding.declarationRange))
}

@Test
func localReferenceIndexDistinguishesShadowedParameterFromLocal() throws {
    let source = """
        fn f(x: i32) {
            x;
            let x = x + 1;
            x;
        }
        """
    let ranges = tokenRanges(of: "x", in: source)
    let document = try localReferenceDocument(source)
    let parameter = try #require(document.localBinding(at: ranges[0].lowerBound))
    let local = try #require(document.localBinding(at: ranges[2].lowerBound))

    #expect(parameter.binding.kind == .param)
    #expect(parameter.references == [ranges[1], ranges[3]])
    #expect(local.binding.kind == .letBinding)
    #expect(local.references == [ranges[4]])
}

#if DEBUG
@Test
func rustHighlighterBuildsMacroPartialLocalIndexWithOneParse() throws {
    let source = """
        item_wrapper! {
            fn generated(hidden: i32) {
                hidden;
            }
        }
        fn visible(visible: i32) {
            visible;
        }
        """
    let parseCount = OSAllocatedUnfairLock(initialState: 0)
    let highlighted = try RustExtractor.$parseObserver.withValue({
        parseCount.withLock { $0 += 1 }
    }) {
        try RustHighlighter().highlight(bytes: Array(source.utf8))
    }
    let visibleRanges = tokenRanges(of: "visible", in: source)

    #expect(parseCount.withLock { $0 } == 1)
    #expect(highlighted.bindings.count == 1)
    #expect(highlighted.bindings[0].declarationRange == visibleRanges[1])
    #expect(highlighted.referencesByBinding == [[visibleRanges[2]]])
}
#endif

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
func foldExtractionCoversSevenKindsAndSyntaxNodeBoundaries() throws {
    let source = """
        mod regular {
            use crate::alpha;
            use crate::beta;
            use crate::gamma;

            #[inline]
            #[cold]
            fn run(value: usize) {
                if value > 0 {
                    work();
                    work();
                }
                match value {
                    0 => {
                        zero();
                        zero();
                    },
                    _ => value,
                }
                let closure = |item| {
                    consume(item);
                    consume(item);
                };
            }
        }

        #[cfg(test)]
        mod tests {
            fn check() {
                assert!(true);
                assert!(true);
            }
        }

        // first comment
        // second comment
        // third comment

        fn after_comments() {}
        """
    let result = try RustHighlighter().highlightWithFolds(bytes: Array(source.utf8))
    let folds = result.folds

    #expect(Set(folds.map(\.kind)) == Set([
        FoldKind.cfgTest, .container, .declaration, .block, .comment, .imports,
        .attributes,
    ]))
    #expect(folds.map(\.id.rawValue) == Array(0..<UInt32(folds.count)))

    let container = try #require(folds.first {
        $0.kind == .container && text(in: source, range: $0.headerRange).contains("mod regular")
    })
    #expect(text(in: source, range: container.headerRange).hasSuffix("{"))
    #expect(!text(in: source, range: container.bodyRange).contains("mod regular"))
    #expect(container.summary.memberCounts[.fn] == 1)

    let cfgTest = try #require(folds.first { $0.kind == .cfgTest })
    #expect(text(in: source, range: cfgTest.headerRange).hasPrefix("#[cfg(test)]"))
    #expect(text(in: source, range: cfgTest.headerRange).hasSuffix("{"))
    #expect(!folds.contains {
        $0.kind == .container && $0.bodyRange == cfgTest.bodyRange
    })

    let declaration = try #require(folds.first {
        $0.kind == .declaration && text(in: source, range: $0.headerRange).contains("fn run")
    })
    #expect(text(in: source, range: declaration.headerRange).hasSuffix("{"))
    #expect(declaration.summary.leadingText == "if value > 0 {")

    let imports = try #require(folds.first { $0.kind == .imports })
    #expect(text(in: source, range: imports.headerRange) == "use crate::alpha;")
    #expect(text(in: source, range: imports.bodyRange).contains("use crate::gamma;"))
    #expect(imports.summary.itemCount == 3)

    let attributes = try #require(folds.first { $0.kind == .attributes })
    #expect(text(in: source, range: attributes.headerRange) == "#[inline]")
    #expect(text(in: source, range: attributes.bodyRange).contains("#[cold]"))
    #expect(attributes.summary.itemCount == 2)

    let comment = try #require(folds.first { $0.kind == .comment })
    #expect(text(in: source, range: comment.headerRange) == "// first comment\n")
    #expect(text(in: source, range: comment.bodyRange).contains("// third comment"))
    #expect(!text(in: source, range: comment.bodyRange).hasSuffix("\n"))
    #expect(Array(source.utf8)[Int(comment.bodyRange.upperBound)] == UInt8(ascii: "\n"))
    #expect(comment.summary.hiddenLineCount == 2)
    #expect(comment.summary.leadingText == "// second comment")

    let matchArm = try #require(folds.first {
        $0.kind == .block && text(in: source, range: $0.headerRange).contains("0 =>")
    })
    #expect(text(in: source, range: matchArm.headerRange).hasSuffix("=>"))
    #expect(!text(in: source, range: matchArm.bodyRange).hasSuffix(","))
    #expect(foldsAreLaminar(folds))
}

@Test
func foldExtractionRejectsEmptyAndSingleNodeRunsAndBracelessClosures() throws {
    let source = """
        use crate::{
            alpha,
            beta,
        };
        #[allow(
            dead_code
        )]
        /* one block
           comment */
        mod empty {}
        fn empty() {}
        fn closure() {
            let value = |item| item + 1;
        }
        """
    let folds = try RustHighlighter().highlightWithFolds(
        bytes: Array(source.utf8)
    ).folds

    #expect(!folds.contains { $0.kind == .imports })
    #expect(!folds.contains { $0.kind == .attributes })
    #expect(!folds.contains { $0.kind == .comment })
    #expect(!folds.contains {
        [.container, .declaration].contains($0.kind)
            && text(in: source, range: $0.headerRange).contains("empty")
    })
    #expect(!folds.contains {
        $0.kind == .block && text(in: source, range: $0.headerRange).contains("|item|")
    })
}

@Test
func foldResolverIsOrderIndependentAndHonorsConflictWinners() {
    let summary = FoldSummary(hiddenLineCount: 8)
    let cfg = foldCandidate(.cfgTest, header: 0..<10, body: 10..<100, summary: summary)
    let container = foldCandidate(
        .container,
        header: 2..<10,
        body: 10..<100,
        summary: summary
    )
    let declaration = foldCandidate(
        .declaration,
        header: 110..<120,
        body: 120..<220,
        summary: FoldSummary(hiddenLineCount: 12)
    )
    let overlappingBlock = foldCandidate(
        .block,
        header: 190..<200,
        body: 200..<260,
        summary: FoldSummary(hiddenLineCount: 4)
    )
    let largerSameKind = foldCandidate(
        .block,
        header: 300..<310,
        body: 310..<410,
        summary: FoldSummary(hiddenLineCount: 10)
    )
    let smallerSameKind = foldCandidate(
        .block,
        header: 390..<400,
        body: 400..<450,
        summary: FoldSummary(hiddenLineCount: 5)
    )
    let nested = foldCandidate(
        .block,
        header: 130..<140,
        body: 140..<180,
        summary: FoldSummary(hiddenLineCount: 3)
    )
    let candidates = [
        cfg, container, declaration, overlappingBlock, largerSameKind,
        smallerSameKind, nested, nested,
    ]
    let expected = resolveFoldCandidates(candidates)

    #expect(expected.map(\.kind) == [.cfgTest, .declaration, .block, .block])
    #expect(expected.map(\.bodyRange) == [
        byteRange(10..<100), byteRange(120..<220), byteRange(140..<180),
        byteRange(310..<410),
    ])
    #expect(expected.map(\.id.rawValue) == [0, 1, 2, 3])
    #expect(foldsAreLaminar(expected))
    for seed in 1...8 {
        #expect(resolveFoldCandidates(permuted(candidates, seed: UInt64(seed))) == expected)
    }
}

@Test
func foldResolverDeduplicatesTruthAndRejectsContradictorySummaries() {
    let geometry = (
        kind: FoldKind.declaration,
        header: 0..<10,
        body: 10..<40
    )
    let first = foldCandidate(
        geometry.kind,
        header: geometry.header,
        body: geometry.body,
        summary: FoldSummary(hiddenLineCount: 3, leadingText: "first")
    )
    let duplicate = first
    let contradiction = foldCandidate(
        geometry.kind,
        header: geometry.header,
        body: geometry.body,
        summary: FoldSummary(hiddenLineCount: 4, leadingText: "different")
    )

    #expect(resolveFoldCandidates([first, duplicate]).count == 1)
    #expect(resolveFoldCandidates([first, contradiction]).isEmpty)
}

@Test
func foldTransportSeamKeepsPublicInitializationEmptyAndLoadsBothPaths() async throws {
    let source = """
        mod sample {
            fn run() {
                if true {
                    work();
                    work();
                }
            }
        }
        """
    let bytes = Array(source.utf8)
    #expect(ReaderDocument(bytes: bytes).foldRegions.isEmpty)

    let samples = OSAllocatedUnfairLock(initialState: [(Double, Int, Int)]())
    let loader = DocumentLoader(
        source: { _ in bytes },
        foldResolutionObserver: { milliseconds, candidates, accepted in
            samples.withLock { $0.append((milliseconds, candidates, accepted)) }
        }
    )
    let loaded = try loader.load(file: URL(fileURLWithPath: "/fixture.rs"))
    #expect(!loaded.document.foldRegions.isEmpty)
    #expect(samples.withLock { $0.count } == 1)

    samples.withLock { $0.removeAll() }
    let asyncResult = await withCheckedContinuation { continuation in
        loader.loadSyntax(for: ReaderDocument(bytes: bytes)) { result in
            let samplesAtCompletion = samples.withLock { $0 }
            continuation.resume(returning: (result, samplesAtCompletion))
        }
    }
    let asyncDocument = try asyncResult.0.get()
    #expect(!asyncDocument.foldRegions.isEmpty)
    #expect(asyncResult.1.count == 1)
    #expect(asyncResult.1[0].0 >= 0)
    #expect(asyncResult.1[0].1 == asyncResult.1[0].2)
}

#if DEBUG
@Test
func highlightWithFoldsUsesTheExistingSingleParse() throws {
    let parseCount = OSAllocatedUnfairLock(initialState: 0)
    let result = try RustExtractor.$parseObserver.withValue({
        parseCount.withLock { $0 += 1 }
    }) {
        try RustHighlighter().highlightWithFolds(bytes: Array("fn run() {\nwork();\n}".utf8))
    }

    #expect(parseCount.withLock { $0 } == 1)
    #expect(result.folds.count == 1)
}
#endif

@Test
func foldPerformanceFixtureMatchesManifestAndResolutionBudget() throws {
    let fixture = repositoryRoot.appendingPathComponent("fixtures/fold_perf.rs")
    let manifestURL = repositoryRoot.appendingPathComponent(
        "fixtures/fold_perf.manifest.json"
    )
    let bytes = Array(try Data(contentsOf: fixture))
    let manifest = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL))
            as? [String: Any]
    )
    let sample = OSAllocatedUnfairLock(initialState: [(Double, Int, Int)]())
    let highlighted = try RustHighlighter().highlightWithFolds(
        bytes: bytes,
        resolutionObserver: { milliseconds, candidates, accepted in
            sample.withLock { $0.append((milliseconds, candidates, accepted)) }
        }
    )
    let samples = sample.withLock { $0 }
    #expect(samples.count == 1)
    let observed = try #require(samples.first)
    let sha = ContentID.sha256(of: bytes).bytes.map { String(format: "%02x", $0) }.joined()

    #expect(manifest["fixtureSHA256"] as? String == sha)
    #expect(manifest["byteCount"] as? Int == bytes.count)
    #expect(bytes.lazy.filter { $0 == 0x0A }.count == 50_000)
    #expect(observed.1 == 8_400)
    #expect(observed.2 == 8_400)
    #expect(highlighted.folds.count == 8_400)
    #expect(Dictionary(grouping: highlighted.folds, by: \.kind).mapValues(\.count) == [
        .container: 200,
        .imports: 200,
        .declaration: 4_000,
        .block: 4_000,
    ])
    #expect(Dictionary(grouping: highlighted.folds, by: \.outlineDepth).mapValues(\.count) == [
        0: 200,
        1: 4_200,
        2: 4_000,
    ])
    #expect(highlighted.folds.map(\.id.rawValue) == Array(0..<8_400))
    #expect(foldsAreLaminar(highlighted.folds))
    #if !DEBUG
    #expect(observed.0 <= 500)
    #endif
    print(
        "M11_FOLD_RESOLUTION resolutionMS=\(observed.0) "
            + "candidates=\(observed.1) accepted=\(observed.2)"
    )
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
        case .struct, .enum, .trait, .typeAlias, .class:
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
func m6FixtureLocalReferencesConvertOnlyViewportTokens() async throws {
    let (bytes, document) = try await m6ReferenceDocument()
    let marker = Array("}\n// f0 deterministic padding 0".utf8)
    let viewportUpper = try #require(bytes.firstRange(of: marker)?.upperBound)
    let visible = document.localReferences(
        intersectingBytes: 0..<UInt32(viewportUpper)
    )
    let converted = visible.compactMap {
        document.byteUTF16Map.nsRange(
            byteLowerBound: Int($0.range.lowerBound),
            byteUpperBound: Int($0.range.upperBound)
        )
    }
    let totalReferences = document.referencesByBinding.lazy
        .map(\.count)
        .reduce(0, +)

    #expect(document.localBindings.count == 20_000)
    #expect(totalReferences == 35_000)
    #expect(visible.count == 35)
    #expect(converted.count == 35)
    print(
        "M6_LOCAL_REFERENCE_VIEWPORT totalReferences=\(totalReferences) "
            + "viewportBytes=\(viewportUpper) queriedTokens=\(visible.count) "
            + "convertedTokens=\(converted.count)"
    )
}

func m6ReferenceDocument() async throws -> ([UInt8], ReaderDocument) {
    try await withCheckedThrowingContinuation { continuation in
        let thread = Thread {
            do {
                let fixture = repositoryRoot.appendingPathComponent(
                    "Tests/Fixtures/m6_reference_density.rust"
                )
                let bytes = [UInt8](try Data(contentsOf: fixture))
                let highlighted = try RustHighlighter().highlight(bytes: bytes)
                let document = ReaderDocument(
                    bytes: bytes,
                    highlightSpans: highlighted.spans,
                    outlineFacets: highlighted.outlineFacets,
                    localBindings: highlighted.bindings,
                    referencesByBinding: highlighted.referencesByBinding
                )
                continuation.resume(returning: (bytes, document))
            } catch {
                continuation.resume(throwing: error)
            }
        }
        thread.qualityOfService = .utility
        thread.start()
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
    let mode = LanguageMode(language: .rust, variant: "large-test-mode")

    let loaded = try loader.load(file: file, languageMode: mode)

    #expect(loaded.tier == .large)
    #expect(loaded.document.languageMode == mode)
    #expect(loaded.document.contentID == ContentID.sha256(of: loaded.document.bytes))
    #expect(loaded.document.highlightSpans.isEmpty)
    let completed = await withCheckedContinuation { continuation in
        loader.loadSyntax(for: loaded.document) { result in
            continuation.resume(returning: result)
        }
    }
    let document = try completed.get()
    #expect(document.languageMode == mode)
    #expect(document.contentID == loaded.document.contentID)
    #expect(!document.highlightSpans.isEmpty)
    #expect(document.outlineFacets.count == 10_001)
}

@Test
func pythonLargeDocumentLoadsPlainTextThenSyncSyntax() async throws {
    let file = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodeInsightReaderCoreTests-\(UUID().uuidString).py")
    let source = String(repeating: "def item():\n    pass\n", count: 10_001)
    try source.write(to: file, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: file) }
    let loader = DocumentLoader()
    let mode = LanguageMode(language: .python, variant: "large-test-mode")

    let loaded = try loader.load(file: file, languageMode: mode)

    #expect(loaded.tier == .large)
    #expect(loaded.document.highlightSpans.isEmpty)
    let document = try loader.loadSyntax(for: loaded.document)
    #expect(!document.highlightSpans.isEmpty)
    #expect(document.outlineFacets.count == 10_001)
}

@Test
func pythonHugeDocumentHighlightProbe() throws {
    var lines: [String] = []
    lines.reserveCapacity(60_000)
    for index in 0..<10_000 {
        lines.append("# prose \(index)")
        lines.append("def item_\(index)():")
        lines.append("    return 1")
        for _ in 0..<2 {
            lines.append("# comment")
        }
    }
    let result = try pythonReaderHighlightWithFolds(
        bytes: Array(lines.joined(separator: "\n").utf8)
    )

    #expect(result.outlineFacets.count == 10_000)
    #expect(!result.spans.isEmpty)
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

private func localReferenceDocument(_ source: String) throws -> ReaderDocument {
    let bytes = Array(source.utf8)
    let highlighted = try RustHighlighter().highlight(bytes: bytes)
    return ReaderDocument(
        bytes: bytes,
        highlightSpans: highlighted.spans,
        outlineFacets: highlighted.outlineFacets,
        localBindings: highlighted.bindings,
        referencesByBinding: highlighted.referencesByBinding
    )
}

private func tokenRanges(
    of token: String,
    in source: String
) -> [ByteRange] {
    var ranges: [ByteRange] = []
    var searchStart = source.startIndex
    while let range = source.range(
        of: token,
        range: searchStart..<source.endIndex
    ) {
        let lower = UInt32(source[..<range.lowerBound].utf8.count)
        ranges.append(ByteRange(
            lowerBound: lower,
            upperBound: lower + UInt32(token.utf8.count)
        ))
        searchStart = range.upperBound
    }
    return ranges
}

private func text(in source: String, range: ByteRange) -> String {
    let bytes = Array(source.utf8)
    return String(decoding: bytes[Int(range.lowerBound)..<Int(range.upperBound)], as: UTF8.self)
}

private func foldCandidate(
    _ kind: FoldKind,
    header: Range<Int>,
    body: Range<Int>,
    depth: Int = 0,
    summary: FoldSummary
) -> FoldCandidate {
    FoldCandidate(
        kind: kind,
        headerRange: byteRange(header),
        bodyRange: byteRange(body),
        outlineDepth: depth,
        summary: summary
    )
}

private func byteRange(_ range: Range<Int>) -> ByteRange {
    ByteRange(
        lowerBound: UInt32(range.lowerBound),
        upperBound: UInt32(range.upperBound)
    )
}

private func foldsAreLaminar(_ folds: [FoldRegion]) -> Bool {
    for left in folds.indices {
        for right in folds.indices where left < right {
            let lhs = folds[left].bodyRange
            let rhs = folds[right].bodyRange
            if lhs.upperBound <= rhs.lowerBound || rhs.upperBound <= lhs.lowerBound {
                continue
            }
            let lhsContains = lhs.lowerBound <= rhs.lowerBound
                && rhs.upperBound <= lhs.upperBound
                && lhs != rhs
            let rhsContains = rhs.lowerBound <= lhs.lowerBound
                && lhs.upperBound <= rhs.upperBound
                && lhs != rhs
            if !lhsContains && !rhsContains { return false }
        }
    }
    return true
}

private func permuted<T>(_ values: [T], seed: UInt64) -> [T] {
    var result = values
    var state = seed
    guard result.count > 1 else { return result }
    for index in stride(from: result.count - 1, through: 1, by: -1) {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        result.swapAt(index, Int(state % UInt64(index + 1)))
    }
    return result
}
