import CodeInsightCore
import Foundation
import Testing

@Test
func internerIsIdempotentAndTyped() {
    let names = Interner<NameID>()
    let paths = Interner<PathID>()
    let strings = Interner<StringID>()

    let firstName = names.intern("main")
    let repeatedName = names.intern("main")
    let path = paths.intern("main")
    let string = strings.intern("main")

    #expect(firstName == repeatedName)
    #expect(names.resolve(firstName) == "main")
    #expect(paths.resolve(path) == "main")
    #expect(strings.resolve(string) == "main")
    #expect(firstName.rawValue == path.rawValue)
    #expect(path.rawValue == string.rawValue)
}

@Test
func contentIDUsesSHA256() {
    let bytes = Array("same".utf8)
    let first = ContentID.sha256(of: bytes)
    let second = ContentID.sha256(of: Data(bytes))
    let different = ContentID.sha256(of: Array("different".utf8))

    #expect(first == second)
    #expect(first != different)
    #expect(first.algorithm == 1)
    #expect(first.bytes.count == 32)
}

@Test
func languageModeUsesStableIdentityAndOneRustPathClassifier() throws {
    #expect([
        LanguageID.rust.rawValue,
        LanguageID.python.rawValue,
        LanguageID.typescript.rawValue,
        LanguageID.javascript.rawValue,
    ] == [0, 1, 2, 3])

    let composed = LanguageMode(language: .typescript, variant: "caf\u{e9}")
    let decomposed = LanguageMode(language: .typescript, variant: "cafe\u{301}")
    #expect(composed == decomposed)
    #expect(decomposed.variant == "caf\u{e9}")

    #expect(LanguageMode.classify(path: "src/lib.py", language: .python)
        == LanguageMode(language: .python))
    #expect(LanguageMode.classify(path: "src/lib.rs", language: .rust)
        == LanguageMode(language: .rust))
    #expect(LanguageMode.classify(path: "src/LIB.RS", language: .rust) == nil)
    #expect(LanguageMode.classify(path: "src/lib.pyi", language: .python) == nil)
    #expect(LanguageMode.classify(path: "src/lib.pyw", language: .python) == nil)
    #expect(LanguageMode.classify(path: "src/lib.PY", language: .python) == nil)
    #expect(LanguageMode.classify(path: "src/lib.py", language: .rust) == nil)
    #expect(LanguageMode.classify(path: "src/lib.rs", language: .python) == nil)

    let encoded = try JSONEncoder().encode(decomposed)
    #expect(try JSONDecoder().decode(LanguageMode.self, from: encoded) == composed)
}

@Test
func typescriptClassifierMatchesF1bMatrixAndKeepsTsTsxKeysDistinct() throws {
    func mode(_ path: String, _ expected: LanguageMode?) {
        #expect(LanguageMode.classify(path: path, language: .typescript) == expected)
    }

    mode("src/lib.ts", LanguageMode(language: .typescript))
    mode("src/lib.tsx", LanguageMode(language: .typescript, variant: "tsx"))
    mode("src/lib.d.ts", nil)
    mode("src/lib.mts", nil)
    mode("src/lib.cts", nil)
    mode("src/lib.d.mts", nil)
    mode("src/lib.d.cts", nil)
    mode("src/lib.js", nil)
    mode("src/lib.jsx", nil)
    mode("src/lib.TS", nil)
    mode("src/lib.Tsx", nil)
    mode("src/lib.tSX", nil)
    mode("src/lib.d.TS", nil)

    let bytes = Array("export const value = 1\n".utf8)
    let contentID = ContentID.sha256(of: bytes)
    let tsKey = ContentIndexKey(
        contentID: contentID,
        languageMode: LanguageMode(language: .typescript),
        grammarVersion: 1,
        extractorVersion: 1
    )
    let tsxKey = ContentIndexKey(
        contentID: contentID,
        languageMode: LanguageMode(language: .typescript, variant: "tsx"),
        grammarVersion: 1,
        extractorVersion: 1
    )
    #expect(tsKey != tsxKey)

    let encoded = try JSONEncoder().encode(tsxKey)
    #expect(try JSONDecoder().decode(ContentIndexKey.self, from: encoded) == tsxKey)
}

@Test
func pythonDeclarationKindsUseFixedTailRawsAndRoundTrip() throws {
    let rawKinds: [(DeclarationKind, UInt8)] = [
        (.rustFn, 0),
        (.rustStruct, 1),
        (.rustEnum, 2),
        (.rustTrait, 3),
        (.rustImpl, 4),
        (.rustMod, 5),
        (.rustConst, 6),
        (.rustStatic, 7),
        (.rustTypeAlias, 8),
        (.rustMethod, 9),
        (.rustField, 10),
        (.pythonFunction, 11),
        (.pythonClass, 12),
    ]

    for (kind, expected) in rawKinds {
        #expect(kind.rawValue == expected)
        #expect(DeclarationKind(rawValue: expected) == kind)
        let encoded = try JSONEncoder().encode(kind)
        #expect(try JSONDecoder().decode(DeclarationKind.self, from: encoded) == kind)
    }
}

@Test
func cacheKeyIsIsolatedByContentIDAndLanguageMode() throws {
    let defID = ContentID.sha256(of: Array("def f(): pass".utf8))
    let fnID = ContentID.sha256(of: Array("fn main() {}".utf8))
    let rustKey = ContentIndexKey(
        contentID: defID,
        languageMode: LanguageMode(language: .rust),
        grammarVersion: 1,
        extractorVersion: 1
    )
    let pythonKey = ContentIndexKey(
        contentID: defID,
        languageMode: LanguageMode(language: .python),
        grammarVersion: 1,
        extractorVersion: 1
    )
    let otherPythonKey = ContentIndexKey(
        contentID: fnID,
        languageMode: LanguageMode(language: .python),
        grammarVersion: 1,
        extractorVersion: 1
    )

    #expect(rustKey != pythonKey)
    #expect(pythonKey != otherPythonKey)
    #expect(rustKey != otherPythonKey)

    let encoded = try JSONEncoder().encode(pythonKey)
    #expect(try JSONDecoder().decode(ContentIndexKey.self, from: encoded) == pythonKey)
}

@Test
func byteRangeUsesHalfOpenBounds() {
    let range = ByteRange(lowerBound: 4, upperBound: 8)

    #expect(range.length == 4)
    #expect(range.contains(4))
    #expect(range.contains(7))
    #expect(!range.contains(8))
    #expect(range.overlaps(ByteRange(lowerBound: 7, upperBound: 9)))
    #expect(!range.overlaps(ByteRange(lowerBound: 8, upperBound: 10)))
    #expect(!range.overlaps(ByteRange(lowerBound: 6, upperBound: 6)))
    #expect(!ByteRange(lowerBound: 6, upperBound: 6).contains(6))
}

@Test
func lineTableHandlesLFAndCRLF() throws {
    let lf = LineTable(bytes: Array("a\nb".utf8))
    let crlf = LineTable(bytes: Array("a\r\nb".utf8))

    #expect(lf.lineStarts == [0, 2])
    #expect(crlf.lineStarts == [0, 3])
    #expect(try #require(crlf.lineColumn(at: 2)).line == 1)
    #expect(try #require(crlf.lineColumn(at: 2)).column == 3)
    #expect(try #require(crlf.lineColumn(at: 3)).line == 2)
    #expect(try #require(crlf.lineColumn(at: 3)).column == 1)
}

@Test
func lineTableHandlesEmptyAndUnterminatedFiles() throws {
    let empty = LineTable(bytes: [])
    let unterminated = LineTable(bytes: Array("abc".utf8))

    #expect(empty.lineStarts == [0])
    #expect(empty.byteOffset(line: 1, column: 1) == 0)
    #expect(try #require(unterminated.lineColumn(at: 3)).line == 1)
    #expect(try #require(unterminated.lineColumn(at: 3)).column == 4)
    #expect(unterminated.byteOffset(line: 1, column: 4) == 3)
    #expect(unterminated.byteOffset(line: 0, column: 1) == nil)
    #expect(unterminated.byteOffset(line: 1, column: 5) == nil)
}

@Test
func literalSearchUsesSharedASCIIFoldAndLeftmostNonoverlappingRanges() throws {
    let bytes = Array("AaAa éÉ".utf8)

    #expect(asciiFold(Character("A").asciiValue!) == Character("a").asciiValue!)
    #expect(asciiFold(0xC3) == 0xC3)
    #expect(try literalRanges(
        Array("aa".utf8),
        in: bytes,
        caseSensitive: false
    ) == [
        ByteRange(lowerBound: 0, upperBound: 2),
        ByteRange(lowerBound: 2, upperBound: 4),
    ])
    #expect(try literalRanges(
        Array("aa".utf8),
        in: bytes,
        caseSensitive: true
    ).isEmpty)
    #expect(try literalRanges([], in: bytes, caseSensitive: false).isEmpty)
}

@Test
func literalSearchCancellationThrowsInsteadOfPublishingPartialRanges() async {
    let worker = Task.detached {
        try literalRanges(
            [0x61],
            in: Array(repeating: 0x61, count: 20_000_000),
            caseSensitive: true
        )
    }
    worker.cancel()
    await #expect(throws: CancellationError.self) {
        _ = try await worker.value
    }
}

@Test
func lineTableUsesUTF8ByteColumnsAndRoundTrips() throws {
    let table = LineTable(bytes: Array("é\nz".utf8))

    #expect(table.lineStarts == [0, 3])
    #expect(try #require(table.lineColumn(at: 2)).column == 3)

    for offset: UInt32 in 0...4 {
        let coordinate = try #require(table.lineColumn(at: offset))
        #expect(table.byteOffset(
            line: coordinate.line,
            column: coordinate.column
        ) == offset)
    }
}

@Test
func importFlagsCompose() {
    let flags: ImportFlags = [.wildcard, .reexport, .conditional]

    #expect(flags.contains(.wildcard))
    #expect(flags.contains(.reexport))
    #expect(flags.contains(.conditional))
    #expect(!flags.contains(.typeOnly))
    #expect(!flags.contains(.dynamic))
}

@Test
func publicModelsCompose() {
    let bytes = Array("fn main() {}".utf8)
    let contentID = ContentID.sha256(of: bytes)
    let pathID = PathID(rawValue: 0)
    let nameID = NameID(rawValue: 0)
    let stringID = StringID(rawValue: 0)
    let scopeID = ScopeID(rawValue: 0)
    let regionID = ExecutableRegionID(rawValue: 0)
    let range = ByteRange(lowerBound: 0, upperBound: UInt32(bytes.count))
    let key = ContentIndexKey(
        contentID: contentID,
        languageMode: LanguageMode(language: .rust),
        grammarVersion: 1,
        extractorVersion: 1
    )
    let scope = ScopeRecord(
        id: scopeID,
        parent: nil,
        kind: .module,
        range: range
    )
    let region = ExecutableRegionRecord(
        id: regionID,
        kind: .function,
        range: range,
        enclosingScopeID: scopeID,
        associatedFacetIndex: 0
    )
    let facet = DeclarationFacet(
        symbolGroupID: SymbolGroupID(rawValue: 0),
        space: .value,
        kind: .rustFn,
        nameID: nameID,
        range: range,
        nameRange: ByteRange(lowerBound: 3, upperBound: 7),
        parentFacetIndex: nil,
        signatureFingerprint: contentID,
        bodyFingerprint: nil
    )
    let call = UnresolvedCall(
        regionID: regionID,
        nameID: nameID,
        range: range,
        nameRange: range,
        syntacticKind: .directCall,
        qualifierRange: nil,
        receiverRange: nil,
        argumentCount: 0
    )
    let imported = ImportBinding(
        moduleSpecifier: stringID,
        importedName: nameID,
        localName: nameID,
        kind: .named,
        flags: [],
        scopeID: scopeID,
        range: range
    )
    let index = ContentIndex(
        key: key,
        scopes: [scope],
        bindings: [],
        executableRegions: [region],
        symbols: [facet],
        calls: [call],
        imports: [imported],
        exports: [ExportRecord(
            exportedName: nameID,
            sourceBindingIndex: 0,
            range: range
        )],
        lineTable: LineTable(bytes: bytes)
    )

    let snapshotID = SnapshotID(rawValue: UUID())
    let manifest = SnapshotManifest(
        snapshotID: snapshotID,
        files: [FileOccurrence(
            occurrenceID: FileOccurrenceID(rawValue: 0),
            pathID: pathID,
            contentID: contentID,
            detectedLanguage: .rust,
            sourceKind: .tracked,
            fileMode: .regular,
            size: UInt64(bytes.count)
        )]
    )
    let profile = AnalysisProfile.placeholder(language: .rust, root: pathID)
    let context = QueryContext(
        snapshotID: snapshotID,
        analysisProfileID: profile.id,
        generation: 1
    )
    let candidate = ResolutionCandidate(
        target: SymbolOccurrenceID(
            snapshotID: snapshotID,
            pathID: pathID,
            localKind: .declarationFacet,
            localIndex: 0
        ),
        certainty: .strong,
        dispatch: .direct,
        provenance: .fuzzyResolver,
        completeness: .complete,
        evidence: [.sameFile(pathID: pathID), .nameOnly(nameID: nameID)]
    )

    #expect(index.symbols.count == 1)
    #expect(manifest.files.count == 1)
    #expect(context.generation == 1)
    #expect(candidate.certainty > .possible)
}
