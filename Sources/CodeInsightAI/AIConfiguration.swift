import Foundation
import Security

/// The one provider profile from Settings → AI. The key is in the Keychain;
/// everything else is in user defaults.
public struct AIProviderSettings: Equatable, Sendable {
    public enum WireProtocol: String, CaseIterable, Sendable {
        case openAI = "openai"
        case anthropic
    }

    public var wireProtocol: WireProtocol
    /// OpenAI-compatible: the base including the version (`https://api.openai.com/v1`);
    /// Anthropic: the host (`https://api.anthropic.com`).
    public var baseURL: String
    public var model: String

    public init(wireProtocol: WireProtocol = .openAI, baseURL: String = "", model: String = "") {
        self.wireProtocol = wireProtocol
        self.baseURL = baseURL
        self.model = model
    }

    private static let protocolKey = "ai.protocol"
    private static let baseURLKey = "ai.baseURL"
    private static let modelKey = "ai.model"

    public static func load(_ defaults: UserDefaults = .standard) -> AIProviderSettings {
        AIProviderSettings(
            wireProtocol: defaults.string(forKey: protocolKey).flatMap(WireProtocol.init(rawValue:)) ?? .openAI,
            baseURL: defaults.string(forKey: baseURLKey) ?? "",
            model: defaults.string(forKey: modelKey) ?? ""
        )
    }

    public func save(_ defaults: UserDefaults = .standard) {
        defaults.set(wireProtocol.rawValue, forKey: Self.protocolKey)
        defaults.set(baseURL.trimmingCharacters(in: .whitespaces), forKey: Self.baseURLKey)
        defaults.set(model.trimmingCharacters(in: .whitespaces), forKey: Self.modelKey)
    }

    /// The endpoint's host, shown when asking to send code there.
    public var host: String? {
        guard let url = URL(string: resolvedBaseURL),
              url.scheme == "https" || url.scheme == "http"
        else { return nil }
        return url.host
    }

    /// What an empty Base URL means: the protocol's official service.
    public static func defaultBaseURL(for wireProtocol: WireProtocol) -> String {
        wireProtocol == .openAI ? "https://api.openai.com/v1" : "https://api.anthropic.com"
    }

    var resolvedBaseURL: String {
        let typed = baseURL.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? Self.defaultBaseURL(for: wireProtocol) : typed
    }

    public var isComplete: Bool { host != nil && !model.trimmingCharacters(in: .whitespaces).isEmpty }

    /// A model on this machine sees nothing leave it, so it needs no consent.
    public var isLocal: Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".localhost")
    }

    func helperConfig(apiKey: String) -> [String: Any] {
        [
            "protocol": wireProtocol.rawValue,
            "base_url": resolvedBaseURL,
            "model": model.trimmingCharacters(in: .whitespaces),
            "api_key": apiKey,
        ]
    }
}

/// The AI provider's API key, and the Jev scoring key in an item of its own.
public enum AIKeychain {
    private static let provider = KeychainKey(service: "Cairn AI provider")
    /// Used by Overview to score skeletons; never by questions or guides.
    public static let jev = KeychainKey(service: "Cairn Jev scoring")

    public static func read() -> String? { provider.read() }
    public static func exists() -> Bool { provider.exists() }
    @discardableResult
    public static func write(_ key: String) -> Bool { provider.write(key) }
}

/// A key, as a generic password in the login Keychain.
public final class KeychainKey: @unchecked Sendable {
    private let service: String
    private let account = "api-key"
    /// Read once per launch: a build whose signature changed is asked about
    /// every read until the user picks Always Allow.
    private var cached: String??
    private var writes = 0
    private let lock = NSLock()

    /// A build with another bundle identifier (a test build, `swift test`)
    /// gets its own item: it never asks for the release build's key, so it
    /// never brings up the Keychain access prompt for it.
    init(service: String) {
        self.service = Bundle.main.bundleIdentifier == "dev.cairn.Cairn"
            ? service : "\(service) (\(Bundle.main.bundleIdentifier ?? "unbundled"))"
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// Changes on every save or removal in this run.
    public var revision: Int { lock.withLock { writes } }

    public func read() -> String? {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { cached = .some(nil); return nil }
        cached = .some(String(data: data, encoding: .utf8))
        return cached!
    }

    /// Asks only for the item's attributes, which needs no access prompt.
    public func exists() -> Bool {
        var query = query
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    /// An empty key removes it.
    @discardableResult
    public func write(_ key: String) -> Bool {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.withLock { cached = nil; writes += 1 }
        SecItemDelete(query as CFDictionary)
        guard !key.isEmpty else { return true }
        var item = query
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}

/// Projects whose code the user agreed to send to a provider host.
public struct AIConsentStore: Sendable {
    /// v2: what is sent grew to commit messages and past changes, so
    /// projects allowed before are asked again.
    private static let key = "ai.consentedProjects.v2"
    private let defaultsSuite: String?

    public init(suiteName: String? = nil) { defaultsSuite = suiteName }

    private var defaults: UserDefaults { defaultsSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    private static func entry(_ project: URL, host: String) -> String {
        host.lowercased() + "\t" + project.resolvingSymlinksInPath().standardizedFileURL.path
    }

    public func allows(_ project: URL, host: String) -> Bool {
        (defaults.stringArray(forKey: Self.key) ?? []).contains(Self.entry(project, host: host))
    }

    public func allow(_ project: URL, host: String) {
        var entries = defaults.stringArray(forKey: Self.key) ?? []
        let entry = Self.entry(project, host: host)
        guard !entries.contains(entry) else { return }
        entries.append(entry)
        defaults.set(entries, forKey: Self.key)
    }

    public func revokeAll() {
        defaults.removeObject(forKey: Self.key)
        defaults.removeObject(forKey: "ai.consentedProjects")
    }
}
