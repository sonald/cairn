import CodeInsightCore
@testable import CodeInsightEngine
import CodeInsightRustExtractor
import CodeInsightPythonExtractor
import CodeInsightTypeScriptExtractor
import Foundation
import Testing

@Test
func oldExtractorCachesReextractAndPersistContentRegions() throws {
    let fixtures: [(any LanguageExtractor, String, String)] = [
        (RustExtractor(), "rs", "fn main() { println!(\"hello\"); } // comment\n"),
        (PythonExtractor(), "py", "def run():\n    \"\"\"docstring\"\"\"\n    pass # comment\n"),
        (TypeScriptExtractor(), "ts", "export const value = `hello ${1}`; // comment\n")
    ]
    for (extractor, suffix, source) in fixtures {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try source.write(to: root.appendingPathComponent("input.\(suffix)"), atomically: true, encoding: .utf8)
        let cache = try IndexCache(fileURL: root.appendingPathComponent("cache/index.sqlite"))
        let old = ProjectIndexer(parallelism: 1, cache: cache, extractor: PreviousRegionExtractor(base: extractor))
        let before = try old.index(root: root, language: extractor.language)
        old.flushPersistentWrites()
        #expect(before.stats.extractedCount == 1)
        #expect(before.contentIndexes.values.allSatisfy { $0.regions.isEmpty })

        let current = ProjectIndexer(parallelism: 1, cache: cache)
        let rebuilt = try current.index(root: root, language: extractor.language)
        current.flushPersistentWrites()
        #expect(rebuilt.stats.extractedCount == 1)
        #expect(rebuilt.stats.reusedCount == 0)
        #expect(rebuilt.contentIndexes.values.allSatisfy { !$0.regions.isEmpty })
        let hot = try ProjectIndexer(parallelism: 1, cache: cache).index(root: root, language: extractor.language)
        #expect(hot.stats.extractedCount == 0)
        #expect(hot.stats.reusedCount == 1)
        #expect(hot.contentIndexes.values.first?.regions == rebuilt.contentIndexes.values.first?.regions)
    }
}

private struct PreviousRegionExtractor: LanguageExtractor {
    let base: any LanguageExtractor
    var language: LanguageID { base.language }
    var grammarVersion: UInt32 { base.grammarVersion }
    var extractorVersion: UInt32 { base.extractorVersion - 1 }

    func extractWithDiagnostics(bytes: [UInt8], key: ContentIndexKey, interner: ExtractionInterners) throws
        -> (index: ContentIndex, containsErrorNodes: Bool) {
        let result = try base.extractWithDiagnostics(bytes: bytes, key: key, interner: interner)
        let index = result.index
        return (ContentIndex(
            key: key, scopes: index.scopes, bindings: index.bindings,
            executableRegions: index.executableRegions, symbols: index.symbols,
            implRelations: index.implRelations, calls: index.calls,
            imports: index.imports, exports: index.exports, lineTable: index.lineTable
        ), result.containsErrorNodes)
    }

    func identifierRanges(named name: String, in bytes: [UInt8], mode: LanguageMode) throws -> [ByteRange] {
        try base.identifierRanges(named: name, in: bytes, mode: mode)
    }
}

@Test
func malformedContentRegionCacheCannotEnterSearchIndex() throws {
    let bytes = Array("// comment\n\"string\"".utf8)
    let key = ContentIndexKey(
        contentID: ContentID.sha256(of: bytes), languageMode: LanguageMode(language: .rust),
        grammarVersion: RustExtractorInfo.grammarVersion, extractorVersion: RustExtractorInfo.extractorVersion
    )
    let invalidRegions: [[ContentRegion]] = [
        [.init(range: ByteRange(lowerBound: 4, upperBound: 8), kind: .comment),
         .init(range: ByteRange(lowerBound: 2, upperBound: 6), kind: .string)],
        [.init(range: ByteRange(lowerBound: 0, upperBound: 99), kind: .comment)]
    ]
    for ranges in invalidRegions {
        let draft = ExtractionDraft(
            order: 0, bytes: bytes,
            index: ContentIndex(
                key: key, scopes: [], bindings: [], executableRegions: [], symbols: [],
                calls: [], imports: [], exports: [], lineTable: LineTable(bytes: bytes), regions: ranges
            ), names: Interner<NameID>(), strings: Interner<StringID>(), containsErrorNodes: false
        )
        let data = try ContentIndexDraftCodec.encode(draft)
        #expect(throws: DraftCodecError.self) {
            try ContentIndexDraftCodec.decode(data, order: 0, bytes: bytes, expectedKey: key)
        }
    }
}
