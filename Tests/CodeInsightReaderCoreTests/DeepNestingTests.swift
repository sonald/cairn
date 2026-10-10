import CodeInsightCore
import Foundation
import Testing
@testable import CodeInsightReaderCore

/// Reader syntax is built on cooperative threads (`loadSyntax(for:completion:)`,
/// the context window's detached loads), whose stacks are 512 KB. The Python
/// and TypeScript walks recurse per syntax node, so a 3000-term `+` chain
/// crashed the process before the walk moved to a large-stack thread.
@Test
func readerSyntaxSurvivesDeeplyNestedExpressions() throws {
    let depth = 3000
    let terms = Array(repeating: "kw", count: depth).joined(separator: " +\n  ")
    for (name, source, mode) in [
        ("deep.rs", "fn f() -> i32 { \(terms) }\n", LanguageMode(language: .rust)),
        ("deep.py", "s = \(terms)\n", LanguageMode(language: .python)),
        ("deep.ts", "const s = \(terms);\n", LanguageMode(language: .typescript)),
    ] {
        let bytes = Array(source.utf8)
        let document = try DocumentLoader(source: { _ in bytes })
            .load(file: URL(fileURLWithPath: "/" + name), languageMode: mode).document
        // The protected failure is the crash; the document only has to come back whole.
        #expect(document.languageMode == mode, "\(name)")
        #expect(document.lineTable.lineStarts.count >= depth, "\(name)")
    }
}
