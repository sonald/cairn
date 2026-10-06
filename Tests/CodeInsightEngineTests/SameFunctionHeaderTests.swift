import CodeInsightCore
@testable import CodeInsightEngine
import Foundation
import Testing

@Test
func sameFunctionIncludesNamesParametersAndNestedFunctionHeaders() async throws {
    let cases: [(LanguageID, String, String)] = [
        (.rust, "rs", """
        fn run(header_token: i32) {
            body_token();
            fn nested(inner_parameter: i32) { inner_body(); }
        }
        fn other() { unrelated(); }
        """),
        (.python, "py", """
        def run(header_token):
            body_token()
            def nested(inner_parameter):
                inner_body()
        def other():
            unrelated()
        """),
        (.typescript, "ts", """
        function run(header_token: number) {
            body_token();
            function nested(inner_parameter: number) { inner_body(); }
        }
        function other() { unrelated(); }
        """)
    ]
    for (language, suffix, source) in cases {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try source.write(to: root.appendingPathComponent("fixture.\(suffix)"), atomically: true, encoding: .utf8)
        let session = try ProjectIndexer().index(root: root, language: language)
        let context = QueryContext(snapshotID: session.snapshotID, analysisProfileID: session.analysisProfile.id, generation: 0)
        for (query, shouldMatch) in [
            ("run body_token same:fn", true),
            ("header_token body_token same:fn", true),
            ("nested inner_body same:fn", true),
            ("inner_parameter inner_body same:fn", true),
            ("inner_parameter body_token same:fn", false),
            ("header_token unrelated same:fn", false)
        ] {
            var matches: [SearchMatch] = []
            for try await batch in try session.search(ProjectSearchQuery.parse(query), context: context) {
                matches += batch.matchesByPath.values.flatMap { $0 }
            }
            #expect(!matches.isEmpty == shouldMatch, "\(language): \(query)")
            if shouldMatch {
                #expect(Set(matches.flatMap(\.conditionIndices)) == [0, 1], "\(language): both terms must be returned")
            }
        }
    }
}
