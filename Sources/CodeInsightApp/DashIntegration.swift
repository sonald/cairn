import AppKit
import CodeInsightAppModel
import CodeInsightCore
import CodeInsightReaderCore

/// "Open in Dash": hands a symbol to the Dash documentation browser through its
/// `dash-plugin://` URL scheme. Nothing here touches the network; Dash is a
/// separate app the user installed.
enum DashIntegration {
    /// Whether an app claims the `dash-plugin` scheme; false when Dash is not installed.
    static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(toOpen: URL(string: "dash-plugin://")!) != nil
    }

    /// `keys=` is deliberately omitted so third-party docsets (PyTorch, tokio…) are searched too.
    /// The query sits in the URL's authority part, so `::` must be percent-encoded
    /// (a bare colon reads as a port and the URL fails to parse); only RFC 3986
    /// unreserved characters are kept.
    static func url(query: String) -> URL? {
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        return URL(string: "dash-plugin://query=\(encoded)")
    }

    /// The search text for `identifier`.
    /// - Rust: rust-analyzer's hover carries the defining path
    ///   (`std::sync::poison::mutex::Mutex`). The full path is often not
    ///   where the docs live (std re-exports it as `std::sync::Mutex`), so
    ///   only its last segment is kept: `Mutex::lock`.
    /// - Python, TypeScript, JavaScript: the receiver written before a `.`
    ///   (`os.getenv`), one level, when `receiver` is given.
    /// - Otherwise the identifier alone.
    static func query(identifier: String, doc: SymbolDoc?, language: LanguageID, receiver: String? = nil) -> String {
        guard language == .rust else {
            return receiver.map { "\($0).\(identifier)" } ?? identifier
        }
        guard let doc, doc.source == .exact,
              let path = doc.location, !path.isEmpty, !path.contains(" "),
              let owner = path.components(separatedBy: "::").last, !owner.isEmpty
        else { return identifier }
        return owner == identifier ? identifier : "\(owner)::\(identifier)"
    }

    /// The identifier written right before `.` and the identifier around
    /// `offset` (`os` in `os.getenv`), or nil. One level only; `self` and
    /// `this` say nothing a docset could match.
    static func receiver(in bytes: [UInt8], identifierAt offset: UInt32) -> String? {
        func isIdentifier(_ byte: UInt8) -> Bool {
            byte >= 0x80 || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "$")
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte | 0x20)
        }
        var start = min(Int(offset), bytes.count)
        while start > 0, isIdentifier(bytes[start - 1]) { start -= 1 }
        guard start > 1, bytes[start - 1] == UInt8(ascii: ".") else { return nil }
        var receiverStart = start - 1
        while receiverStart > 0, isIdentifier(bytes[receiverStart - 1]) { receiverStart -= 1 }
        guard receiverStart < start - 1,
              !(UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[receiverStart]),
              let receiver = String(bytes: bytes[receiverStart..<(start - 1)], encoding: .utf8),
              receiver != "self", receiver != "this"
        else { return nil }
        return receiver
    }

    static func open(query: String) {
        guard let url = url(query: query) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Dash's direct-download and Setapp builds.
    static let bundleIdentifiers = ["com.kapeli.dashdoc", "com.kapeli.dash-setapp"]

    static var isRunning: Bool {
        bundleIdentifiers.contains { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
    }

    /// The documentation panel's source, shared by every window so the docset
    /// list is fetched once per run. It never launches Dash.
    static let documentationSource = DashDocumentationSource(
        isInstalled: { isInstalled },
        isRunning: { isRunning }
    )
}
