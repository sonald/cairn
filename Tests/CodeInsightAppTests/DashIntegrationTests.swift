import CodeInsightCore
import CodeInsightReaderCore
import Foundation
import Testing

@testable import CodeInsightApp

/// The Dash query behind "Open in Dash" and the docs panel: the last
/// segment of rust-analyzer's defining path, or the receiver before a `.`,
/// is prefixed; anything else sends the identifier alone.
@Test
func dashQueryPrefixesRustPathAndFallsBackToIdentifier() {
    // rust-analyzer gives the defining path; std documents it as std::sync::Mutex.
    let rustLock = SymbolDoc(location: "std::sync::poison::mutex::Mutex", signature: "pub fn lock(&self)", source: .exact)
    #expect(DashIntegration.query(identifier: "lock", doc: rustLock, language: .rust) == "Mutex::lock")

    // The path already names the symbol (a type hover): the identifier alone.
    let rustType = SymbolDoc(location: "std::sync::poison::mutex::Mutex", source: .exact)
    #expect(DashIntegration.query(identifier: "Mutex", doc: rustType, language: .rust) == "Mutex")
    // Rust ignores a receiver; the path is the qualifier.
    #expect(DashIntegration.query(identifier: "lock", doc: rustLock, language: .rust, receiver: "m") == "Mutex::lock")

    // Syntactic fallback carries "file:line" in location; never a path.
    let syntactic = SymbolDoc(location: "src/main.rs:12", source: .syntactic)
    #expect(DashIntegration.query(identifier: "lock", doc: syntactic, language: .rust) == "lock")

    // Pyright gives no qualified name.
    let python = SymbolDoc(signature: "def acquire(blocking: bool = True) -> bool", source: .exact)
    #expect(DashIntegration.query(identifier: "acquire", doc: python, language: .python) == "acquire")
    #expect(DashIntegration.query(identifier: "acquire", doc: nil, language: .python) == "acquire")
    #expect(DashIntegration.query(identifier: "getenv", doc: python, language: .python, receiver: "os") == "os.getenv")

    // A bare "::" in the authority part would make URL(string:) return nil.
    #expect(DashIntegration.url(query: "std::sync::Mutex::lock")?.absoluteString
        == "dash-plugin://query=std%3A%3Async%3A%3AMutex%3A%3Alock")
}

/// One receiver level, read from the bytes around the identifier.
@Test
func dashReceiverIsTheIdentifierRightBeforeTheDot() {
    func receiver(_ source: String, at marker: String) -> String? {
        let bytes = Array(source.utf8)
        let offset = source.utf8.count - source.components(separatedBy: marker).last!.utf8.count - marker.utf8.count
        // Anywhere inside the identifier, as a right-click gives it.
        return DashIntegration.receiver(in: bytes, identifierAt: UInt32(offset + 1))
    }
    #expect(receiver("x = os.getenv(\"HOME\")", at: "getenv") == "os")
    #expect(receiver("lock = threading.Lock()", at: "Lock") == "threading")
    #expect(receiver("a.b.c()", at: "c") == "b", "one level only")
    #expect(receiver("self.repo.open()", at: "repo") == nil)
    #expect(receiver("this.state.x", at: "state") == nil)
    #expect(receiver("getenv()", at: "getenv") == nil)
    #expect(receiver("f(...args)", at: "args") == nil)
    #expect(receiver("x = 1.5", at: "5") == nil)
    #expect(receiver("a?.b", at: "b") == nil)
    #expect(receiver("café.ouvrir()", at: "ouvrir") == "café")
}
