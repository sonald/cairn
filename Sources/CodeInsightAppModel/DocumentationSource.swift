import Foundation

/// One search result a documentation source can show: a page on the local
/// documentation server, with the entry's name, kind and docset.
public struct DocumentationCandidate: Hashable, Sendable {
    public let name: String
    public let kind: String
    public let docset: String
    public let loadURL: URL
    public let sourceName: String

    public init(name: String, kind: String, docset: String, loadURL: URL, sourceName: String) {
        self.name = name
        self.kind = kind
        self.docset = docset
        self.loadURL = loadURL
        self.sourceName = sourceName
    }
}

public enum DocumentationAvailability: Equatable, Sendable {
    case available
    case notInstalled
    case notRunning
    /// Running, but its API server does not answer.
    case apiDisabled
}

public enum DocumentationSourceError: Error, Equatable, Sendable {
    case apiDisabled
    case trialExpired
    case http(Int)
}

/// A local documentation browser the documentation panel can search.
public protocol DocumentationSource: Sendable {
    var name: String { get }
    func availability() async -> DocumentationAvailability
    func search(_ query: String) async throws -> [DocumentationCandidate]
    /// Whether `candidate` is the entry `query` names, not just a fuzzy hit.
    func isExactMatch(_ candidate: DocumentationCandidate, for query: String) -> Bool
}

/// Dash's local HTTP API (Dash 8): `status.json` names the port; `/health`,
/// `/docsets/list` and `/search` answer on 127.0.0.1 only. Docset
/// identifiers are random per machine, so they are cached for this run only.
public actor DashDocumentationSource: DocumentationSource {
    public nonisolated let name = "Dash"
    private let isInstalled: @Sendable () -> Bool
    private let isRunning: @Sendable () -> Bool
    private let statusFile: URL
    private let session: URLSession
    private var docsets: (port: Int, identifiers: [String])?

    public static let defaultStatusFile = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Dash/.dash_api_server/status.json")

    public init(
        isInstalled: @escaping @Sendable () -> Bool,
        isRunning: @escaping @Sendable () -> Bool,
        statusFile: URL = DashDocumentationSource.defaultStatusFile
    ) {
        self.isInstalled = isInstalled
        self.isRunning = isRunning
        self.statusFile = statusFile
        // Nothing from the API may reach the disk cache.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    public func availability() async -> DocumentationAvailability {
        guard isInstalled() else { return .notInstalled }
        guard isRunning() else { return .notRunning }
        guard let port = port() else { return .apiDisabled }
        do {
            _ = try await get(port, "health", timeout: 1)
        } catch DocumentationSourceError.trialExpired {
            // The API answers; search reports the expired trial.
        } catch {
            return .apiDisabled
        }
        return .available
    }

    public func search(_ query: String) async throws -> [DocumentationCandidate] {
        guard let port = port() else { throw DocumentationSourceError.apiDisabled }
        let cached = docsets?.port == port ? docsets?.identifiers : nil
        var ids = cached ?? []
        if cached == nil { ids = try await identifiers(port: port) }
        let results = try await search(query, port: port, identifiers: ids)
        // A docset installed since the list was cached: refresh once.
        guard results.isEmpty, cached != nil else { return results }
        return try await search(query, port: port, identifiers: identifiers(port: port))
    }

    public nonisolated func isExactMatch(_ candidate: DocumentationCandidate, for query: String) -> Bool {
        Self.isExactMatch(name: candidate.name, loadURL: candidate.loadURL, query: query)
    }

    /// `query` is split into segments at `::` and `.`; the last must equal
    /// `name` and every other one must appear as whole tokens of the decoded
    /// `load_url` (split at `/ . # _ - :`). Sphinx puts the qualified name in
    /// the fragment (`//apple_ref/Method/threading.Thread.start`); rustdoc
    /// spreads it over the path and fragment (`std/sync/struct.Mutex.html`,
    /// `Method/lock`). Whole tokens keep `io` from matching `asyncio`.
    public static func isExactMatch(name: String, loadURL: URL, query: String) -> Bool {
        let segments = query.components(separatedBy: "::")
            .flatMap { $0.components(separatedBy: ".") }
            .filter { !$0.isEmpty }
        guard let last = segments.last, last == name else { return false }
        let url = loadURL.absoluteString.removingPercentEncoding ?? loadURL.absoluteString
        let tokens = Set(tokenize(url))
        // A segment such as `threading_helper` is itself split like the URL.
        return segments.dropLast().allSatisfy { tokenize($0).allSatisfy(tokens.contains) }
    }

    private static func tokenize(_ text: String) -> [Substring] {
        text.split(whereSeparator: { "/.#_-:".contains($0) })
    }

    /// Candidates from a `/search` body. No results come back as
    /// `[{}]`; entries without a name or URL are dropped.
    public static func candidates(fromSearchResponse data: Data, sourceName: String) -> [DocumentationCandidate] {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let results = object?["results"] as? [[String: Any]] ?? []
        return results.compactMap { result in
            guard let name = result["name"] as? String, !name.isEmpty,
                  let link = result["load_url"] as? String, let url = URL(string: link)
            else { return nil }
            return DocumentationCandidate(
                name: name,
                kind: result["type"] as? String ?? "",
                docset: result["docset"] as? String ?? "",
                loadURL: url,
                sourceName: sourceName
            )
        }
    }

    /// Dash answers 403 with this text once its trial is over.
    public static func isTrialExpired(status: Int, body: Data) -> Bool {
        status == 403 && String(decoding: body, as: UTF8.self)
            .contains("API access blocked due to Dash trial expiration")
    }

    // MARK: - HTTP

    private func port() -> Int? {
        guard let data = try? Data(contentsOf: statusFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["port"] as? Int
    }

    private func identifiers(port: Int) async throws -> [String] {
        let data = try await get(port, "docsets/list")
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let list = object?["docsets"] as? [[String: Any]] ?? []
        let identifiers = list.compactMap { $0["identifier"] as? String }
        docsets = (port, identifiers)
        return identifiers
    }

    private func search(_ query: String, port: Int, identifiers: [String]) async throws -> [DocumentationCandidate] {
        let data = try await get(port, "search", [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "docset_identifiers", value: identifiers.joined(separator: ",")),
            URLQueryItem(name: "search_snippets", value: "false"),
            URLQueryItem(name: "max_results", value: "20"),
        ])
        return Self.candidates(fromSearchResponse: data, sourceName: name)
    }

    private func get(
        _ port: Int,
        _ path: String,
        _ query: [URLQueryItem] = [],
        timeout: TimeInterval = 5
    ) async throws -> Data {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = port
        components.path = "/" + path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw DocumentationSourceError.apiDisabled }
        let (data, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: timeout))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if Self.isTrialExpired(status: status, body: data) { throw DocumentationSourceError.trialExpired }
        guard status == 200 else { throw DocumentationSourceError.http(status) }
        return data
    }
}
