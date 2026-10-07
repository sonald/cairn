import CodeInsightCore
import CodeInsightReaderCore
import Foundation
import Testing

@testable import CodeInsightApp

/// The Dash query is the only logic behind "Open in Dash": rust-analyzer's
/// containing path is prefixed, anything else sends the identifier alone.
@Test
func dashQueryPrefixesRustPathAndFallsBackToIdentifier() {
    let rustLock = SymbolDoc(location: "std::sync::Mutex", signature: "pub fn lock(&self)", source: .exact)
    #expect(DashIntegration.query(identifier: "lock", doc: rustLock, language: .rust) == "std::sync::Mutex::lock")

    // The path already names the symbol (a type hover): no double suffix.
    let rustType = SymbolDoc(location: "std::sync::Mutex", source: .exact)
    #expect(DashIntegration.query(identifier: "Mutex", doc: rustType, language: .rust) == "std::sync::Mutex")

    // Syntactic fallback carries "file:line" in location; never a path.
    let syntactic = SymbolDoc(location: "src/main.rs:12", source: .syntactic)
    #expect(DashIntegration.query(identifier: "lock", doc: syntactic, language: .rust) == "lock")

    // Pyright gives no qualified name.
    let python = SymbolDoc(signature: "def acquire(blocking: bool = True) -> bool", source: .exact)
    #expect(DashIntegration.query(identifier: "acquire", doc: python, language: .python) == "acquire")
    #expect(DashIntegration.query(identifier: "acquire", doc: nil, language: .python) == "acquire")

    // A bare "::" in the authority part would make URL(string:) return nil.
    #expect(DashIntegration.url(query: "std::sync::Mutex::lock")?.absoluteString
        == "dash-plugin://query=std%3A%3Async%3A%3AMutex%3A%3Alock")
}
