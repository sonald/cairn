import CodeInsightCore
import CodeInsightReaderCore
import CodeInsightRustExtractor
import CodeInsightPythonExtractor
import CodeInsightTypeScriptExtractor
import Foundation
import Testing

@Test
func indexedRegionsMatchReaderAndKnownSyntaxBoundaries() throws {
    let fixtures: [(any LanguageExtractor, String, [String], String?)] = [
        (RustExtractor(), #"""
        // 注释
        fn main() { println!("macro 文本", r#"raw"#); /* nested /* inner */ comment */ let c = 'x'; }
        """#, ["\"macro 文本\"", "r#\"raw\"#", "'x'"], nil),
        (PythonExtractor(), #"""
        # 注释
        def run():
            """docstring 文本"""
            return f"hello {name}" "world"
        """#, ["\"\"\"docstring 文本\"\"\"", "f\"hello {name}\" \"world\""], nil),
        (TypeScriptExtractor(), #"""
        import x from "./module";
        // 注释
        export const value = `before ${x + "inside"} after`;
        export function run() { return /hello+/; }
        class Example { "quoted"() { return "body"; } }
        """#, ["\"./module\"", "before ", "\"inside\"", " after", "/hello+/", "\"quoted\"", "\"body\""], "x +")
    ]
    for (extractor, source, expectedStrings, code) in fixtures {
        let bytes = Array(source.utf8)
        let mode = LanguageMode(language: extractor.language)
        let key = ContentIndexKey(
            contentID: ContentID.sha256(of: bytes), languageMode: mode,
            grammarVersion: extractor.grammarVersion, extractorVersion: extractor.extractorVersion
        )
        let index = try extractor.extract(bytes: bytes, key: key, interner: ExtractionInterners(
            names: Interner<NameID>(), strings: Interner<StringID>()
        ))
        let reader = try DocumentLoader(source: { _ in bytes }).load(
            file: URL(fileURLWithPath: "/fixture"), languageMode: mode
        ).document
        let readerRegions = reader.highlightSpans.compactMap { span -> ContentRegion? in
            switch span.kind {
            case .comment, .commentFigure: return ContentRegion(range: span.range, kind: .comment)
            case .string: return ContentRegion(range: span.range, kind: .string)
            default: return nil
            }
        }.sorted { $0.range < $1.range }
        #expect(index.regions == readerRegions)
        #expect(index.regions.contains { $0.kind == .comment })
        for (left, right) in zip(index.regions, index.regions.dropFirst()) {
            #expect(left.range.upperBound <= right.range.lowerBound)
        }
        // Independent source-text expectations ensure two consumers cannot agree on a missing region.
        let strings = index.regions.filter { $0.kind == .string }.map {
            String(decoding: bytes[Int($0.range.lowerBound)..<Int($0.range.upperBound)], as: UTF8.self)
        }
        for expected in expectedStrings { #expect(strings.contains(expected)) }
        if let code, let range = source.range(of: code) {
            let offset = UInt32(source[..<range.lowerBound].utf8.count)
            #expect(!index.regions.contains { $0.range.contains(offset) })
        }
    }
}
