import AppKit
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

    /// The search text for `identifier`. rust-analyzer's hover carries the
    /// containing path (`std::sync::Mutex`); prefixing it disambiguates `lock`.
    /// Other servers give no qualified name, so the identifier alone is sent.
    static func query(identifier: String, doc: SymbolDoc?, language: LanguageID) -> String {
        guard language == .rust, let doc, doc.source == .exact,
              let path = doc.location, !path.isEmpty, !path.contains(" ")
        else { return identifier }
        return path.hasSuffix("::\(identifier)") || path == identifier ? path : "\(path)::\(identifier)"
    }

    static func open(query: String) {
        guard let url = url(query: query) else { return }
        NSWorkspace.shared.open(url)
    }
}
