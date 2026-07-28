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
