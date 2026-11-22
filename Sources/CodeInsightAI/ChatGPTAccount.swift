import CryptoKit
import Foundation
import Network
import Security

/// Signing in with ChatGPT, so AI requests use the account's ChatGPT plan
/// instead of an API key: OAuth with PKCE in the system browser, the code
/// coming back to a one-shot listener on 127.0.0.1. The tokens are one
/// Keychain item; the client ID OpenAI issued to this installation and the
/// account's email are in user defaults.
///
/// Written from the published protocol (developers.openai.com/siwc), not from
/// the DevKit, whose code is under a noncommercial license.
public enum ChatGPTAccount {
    public static let usageURL = URL(string: "https://chatgpt.com/settings/usage")!

    static let issuer = "https://auth.openai.com"
    // ponytail: endpoints copied from auth.openai.com/.well-known/openid-configuration
    // (2026-11-22) instead of fetching it on every sign-in; fetch it if they move.
    static let authorizeURL = URL(string: "https://auth.openai.com/api/accounts/authorize")!
    static let tokenURL = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    static let revokeURL = URL(string: "https://auth.openai.com/api/accounts/oauth/revoke")!
    static let keysURL = URL(string: "https://auth.openai.com/.well-known/jwks.json")!
    static let resource = "https://api.openai.com/v1"
    static let planScope = "chatgpt.tokens.use.direct"
    static let scopes = "openid profile email offline_access resource.invoke " + planScope
    static let callbackPath = "/auth/callback"

    /// Why a request could not get a token; the panels show `signInAgain` as text of their own.
    public enum Failure: Error, CustomStringConvertible {
        /// No tokens, or the refresh token was refused: sign in again.
        case signInAgain
        /// The account did not grant use of its plan.
        case planNotShared
        /// OAuth said no, or answered something unexpected; the code or text it gave.
        case refused(String)

        public var description: String {
            switch self {
            case .signInAgain: "chatgptSignIn"
            case .planNotShared: "chatgptPlanNotShared"
            case .refused(let reason): reason
            }
        }
    }

    private struct Tokens: Codable {
        var access: String
        var refresh: String
        var expiresAt: Date
    }

    private static let keychain = KeychainKey(service: "Cairn ChatGPT sign-in")
    private static let clientIDKey = "ai.chatgpt.clientID"
    private static let emailKey = "ai.chatgpt.email"
    private static var defaults: UserDefaults { .standard }

    /// Whether tokens are stored, without reading them (which can prompt).
    public static func isSignedIn() -> Bool { keychain.exists() }

    /// The signed-in account's email, for Settings.
    public static var email: String? { defaults.string(forKey: emailKey) }

    /// Changes on every sign-in or sign-out in this run.
    public static var revision: Int { keychain.revision }

    // MARK: Sign in

    /// Opens the browser at OpenAI's sign-in page and waits for its answer.
    /// Cancelling the task stops waiting.
    public static func signIn(open: @Sendable (URL) -> Void) async throws {
        let state = random(), nonce = random(), verifier = random()
        let listener = try await LoopbackListener.start()
        defer { listener.stop() }
        let redirect = "http://127.0.0.1:\(listener.port)\(callbackPath)"
        let saved = defaults.string(forKey: clientIDKey)
        var url = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        url.queryItems = [
            // The first sign-in registers this installation; later ones reuse what it was issued.
            .init(name: "client_id", value: saved ?? "dynamic_agent_client"),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "scope", value: scopes),
            .init(name: "resource", value: resource),
            .init(name: "state", value: state),
            .init(name: "nonce", value: nonce),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: sha256(verifier)),
            // No `ext_agent_host_id`: auth.openai.com answered "invalid_authorize_request"
            // for it (2026-11-22); the DevKit also leaves it off unless told otherwise.
        ]
        if saved == nil { url.queryItems!.append(.init(name: "agent_name_hint", value: "Cairn")) }
        if let email { url.queryItems!.append(.init(name: "login_hint", value: email)) }
        // `+` is a space in a query; keep it literal in the challenge and the rest.
        url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        open(url.url!)

        let answer = try await listener.callback(state: state)
        if let error = answer["error"] { throw Failure.refused(error) }
        let returned = answer["client_id"]
        guard let code = answer["code"], let clientID = returned ?? saved,
              clientID != "dynamic_agent_client",
              clientID.range(of: #"^[A-Za-z0-9_-]{1,200}$"#, options: .regularExpression) != nil,
              saved == nil || returned == nil || returned == saved
        else { throw Failure.refused("the sign-in did not complete the app's registration") }
        // Kept before the exchange: a code that fails must not register Cairn a second time.
        defaults.set(clientID, forKey: clientIDKey)

        let body = try await tokenRequest([
            "grant_type": "authorization_code", "client_id": clientID, "code": code,
            "code_verifier": verifier, "redirect_uri": redirect, "resource": resource,
        ])
        let identity = try verifyIdentity(body["id_token"] as? String, clientID: clientID, nonce: nonce,
                                          keys: try await signingKeys())
        try save(body, previous: nil)
        defaults.set(identity.email, forKey: emailKey)
    }

    /// Forgets the tokens here and asks OpenAI to revoke them. The issued
    /// client ID stays, so signing in again reuses the registration.
    public static func signOut() async {
        let tokens = read()
        keychain.write("")
        defaults.removeObject(forKey: emailKey)
        await refresher.reset()
        guard let tokens, let clientID = defaults.string(forKey: clientIDKey) else { return }
        // Best effort: the user can also disconnect Cairn in ChatGPT's settings.
        _ = try? await post(revokeURL, ["token": tokens.refresh, "token_type_hint": "refresh_token", "client_id": clientID])
    }

    // MARK: Tokens for requests

    /// A token that stays valid for at least a few more minutes, refreshing
    /// it first when needed. Concurrent callers share one refresh: a refresh
    /// token works once.
    public static func accessToken() async throws -> String {
        try await refresher.token()
    }

    private static let refresher = Refresher()

    private actor Refresher {
        private var running: Task<String, Error>?

        func token() async throws -> String {
            if let running { return try await running.value }
            let task = Task.detached { try await ChatGPTAccount.validToken() }
            running = task
            defer { running = nil }
            return try await task.value
        }

        func reset() { running = nil }
    }

    /// ponytail: a token lasts an hour and is renewed when under five minutes
    /// are left, so a run longer than that can fail mid-way with a 401; renew
    /// per round if guides grow that long.
    /// Refresh errors that mean the session is gone (developers.openai.com/siwc, errors and recovery).
    private static let reauthErrors: Set = [
        "invalid_grant", "invalid_refresh_token", "token_expired",
        "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused",
    ]

    private static func validToken() async throws -> String {
        guard let tokens = read() else { throw Failure.signInAgain }
        if tokens.expiresAt.timeIntervalSinceNow > 5 * 60 { return tokens.access }
        guard let clientID = defaults.string(forKey: clientIDKey) else { throw Failure.signInAgain }
        let body: [String: Any]
        do {
            body = try await tokenRequest([
                "grant_type": "refresh_token", "client_id": clientID,
                "refresh_token": tokens.refresh, "resource": resource,
            ])
        } catch Failure.refused(let reason) where reauthErrors.contains(reason) {
            // A refused refresh token will not work again; other failures may pass.
            keychain.write("")
            throw Failure.signInAgain
        }
        // Saved at once: the old refresh token is spent, so losing these means signing in again.
        // A refreshed ID token is not checked; it only ever served the email shown in Settings.
        return try save(body, previous: tokens).access
    }

    // MARK: Models

    /// The models this account's plan offers, in the server's order.
    public static func models() async throws -> [String] {
        var request = URLRequest(url: URL(string: resource + "/models")!, timeoutInterval: 30)
        request.setValue("Bearer " + (try await accessToken()), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (response as? HTTPURLResponse)?.statusCode == 200, let models = body?["models"] as? [[String: Any]] else {
            throw Failure.refused(errorCode(body) ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return models.compactMap { $0["visibility"] as? String == "list" ? $0["slug"] as? String : nil }
    }

    // MARK: Plumbing

    private static func read() -> Tokens? {
        keychain.read().flatMap { try? JSONDecoder().decode(Tokens.self, from: Data($0.utf8)) }
    }

    /// Stores what a token response granted; `previous` keeps the refresh token if none came back.
    @discardableResult
    private static func save(_ body: [String: Any], previous: Tokens?) throws -> Tokens {
        let scopes = (body["scope"] as? String)?.split(separator: " ").map(String.init)
        guard let access = body["access_token"] as? String, !access.isEmpty,
              (body["token_type"] as? String)?.lowercased() == "bearer",
              let seconds = body["expires_in"] as? Double, seconds > 0,
              let refresh = body["refresh_token"] as? String ?? previous?.refresh
        else { throw Failure.refused("ChatGPT returned incomplete credentials") }
        // A refresh may leave out unchanged scopes.
        if let scopes, !scopes.contains(planScope) { throw Failure.planNotShared }
        let tokens = Tokens(access: access, refresh: refresh, expiresAt: Date(timeIntervalSinceNow: seconds))
        let json = String(decoding: try JSONEncoder().encode(tokens), as: UTF8.self)
        guard keychain.write(json) else { throw Failure.refused("the Keychain did not save the sign-in") }
        return tokens
    }

    /// OpenAI's published signing keys (JWKS), fetched once per sign-in.
    private static func signingKeys() async throws -> Data {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: URLRequest(url: keysURL, timeoutInterval: 30))
        } catch { throw Failure.refused("network") }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure.refused("ChatGPT's signing keys could not be fetched; try again shortly")
        }
        return data
    }

    /// Checks the sign-in's ID token: its RS256 signature against OpenAI's keys,
    /// then issuer, audience, expiry and nonce.
    private static func verifyIdentity(_ token: String?, clientID: String, nonce: String?, keys: Data) throws -> (subject: String, email: String?) {
        let parts = token?.split(separator: ".") ?? []
        guard let token, signatureIsValid(token, keys: keys),
              parts.count == 3, let payload = base64URLDecoded(String(parts[1])),
              let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              claims["iss"] as? String == issuer,
              let subject = claims["sub"] as? String, !subject.isEmpty,
              let expires = claims["exp"] as? Double, expires > Date().timeIntervalSince1970 - 5,
              (claims["aud"] as? String == clientID) || ((claims["aud"] as? [String])?.contains(clientID) ?? false),
              nonce == nil || claims["nonce"] as? String == nonce
        else { throw Failure.refused("ChatGPT's identity token did not check out; sign in again") }
        return (subject, claims["email"] as? String)
    }

    /// Whether `token` is a JWT signed with RS256 by the key its header names
    /// among `keys` (a JWKS document).
    static func signatureIsValid(_ token: String, keys: Data) -> Bool {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              let headerData = base64URLDecoded(parts[0]),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header["alg"] as? String == "RS256", let kid = header["kid"] as? String,
              let signature = base64URLDecoded(parts[2]),
              let set = try? JSONSerialization.jsonObject(with: keys) as? [String: Any],
              let jwk = (set["keys"] as? [[String: Any]])?.first(where: { $0["kid"] as? String == kid }),
              jwk["kty"] as? String == "RSA", (jwk["alg"] as? String).map({ $0 == "RS256" }) ?? true,
              let modulus = (jwk["n"] as? String).flatMap(base64URLDecoded),
              let exponent = (jwk["e"] as? String).flatMap(base64URLDecoded),
              let key = SecKeyCreateWithData(rsaPublicKey(modulus: modulus, exponent: exponent) as CFData, [
                  kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic,
              ] as CFDictionary, nil)
        else { return false }
        return SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256,
                                     Data((parts[0] + "." + parts[1]).utf8) as CFData, signature as CFData, nil)
    }

    /// The PKCS #1 DER form Security reads: SEQUENCE { INTEGER n, INTEGER e }.
    static func rsaPublicKey(modulus: Data, exponent: Data) -> Data {
        func element(_ tag: UInt8, _ body: Data) -> Data {
            var out = Data([tag])
            if body.count < 0x80 {
                out.append(UInt8(body.count))
            } else {
                let length = withUnsafeBytes(of: UInt32(body.count).bigEndian) { Array($0) }.drop { $0 == 0 }
                out.append(0x80 | UInt8(length.count))
                out.append(contentsOf: length)
            }
            return out + body
        }
        func integer(_ value: Data) -> Data {
            var bytes = Data(value.drop { $0 == 0 })
            // A set top bit would read as negative.
            if (bytes.first ?? 0x80) & 0x80 != 0 { bytes.insert(0, at: 0) }
            return element(0x02, bytes)
        }
        return element(0x30, integer(modulus) + integer(exponent))
    }

    private static func tokenRequest(_ form: [String: String]) async throws -> [String: Any] {
        let (status, body) = try await post(tokenURL, form)
        guard status == 200, let body else {
            throw Failure.refused(errorCode(body) ?? "HTTP \(status)")
        }
        return body
    }

    /// A form POST; a transport failure throws `.refused("network")`.
    private static func post(_ url: URL, _ form: [String: String]) async throws -> (Int, [String: Any]?) {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = Data(form.map { key, value in
            key + "=" + value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").utf8)
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) } catch { throw Failure.refused("network") }
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, try? JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// OAuth errors are `{"error": "code"}`; API errors `{"error": {"code": …}}`.
    private static func errorCode(_ body: [String: Any]?) -> String? {
        if let code = body?["error"] as? String { return code }
        let error = body?["error"] as? [String: Any]
        return error?["code"] as? String ?? error?["message"] as? String ?? body?["detail"] as? String
    }

    private static func random() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func sha256(_ text: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(text.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecoded(_ text: String) -> Data? {
        var text = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        return Data(base64Encoded: text)
    }
}

/// Waits on 127.0.0.1 for the browser to come back to `/auth/callback`
/// with the sign-in's state; anything else is turned away and waiting goes on.
private final class LoopbackListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "Cairn ChatGPT sign-in")
    private let lock = NSLock()
    private var waiting: CheckedContinuation<[String: String], Error>?
    private var finished: Result<[String: String], Error>?
    private var state = ""
    private(set) var port: UInt16 = 0

    private init(_ listener: NWListener) { self.listener = listener }

    static func start() async throws -> LoopbackListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let me = LoopbackListener(try NWListener(using: parameters))
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            let pending = Pending(ready)
            me.listener.stateUpdateHandler = { state in
                switch state {
                case .ready: pending.resume(.success(()))
                case .failed(let error): pending.resume(.failure(error))
                case .cancelled: pending.resume(.failure(CancellationError()))
                default: break
                }
            }
            me.listener.newConnectionHandler = { [weak me] connection in me?.serve(connection) }
            me.listener.start(queue: me.queue)
        }
        me.port = me.listener.port?.rawValue ?? 0
        return me
    }

    func callback(state: String) async throws -> [String: String] {
        lock.withLock { self.state = state }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let done = lock.withLock { () -> Result<[String: String], Error>? in
                    if finished == nil { waiting = continuation }
                    return finished
                }
                if let done { continuation.resume(with: done) }
            }
        } onCancel: {
            finish(.failure(CancellationError()))
        }
    }

    func stop() {
        listener.cancel()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<[String: String], Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<[String: String], Error>? in
            guard finished == nil else { return nil }
            finished = result
            defer { waiting = nil }
            return waiting
        }
        continuation?.resume(with: result)
    }

    private func serve(_ connection: NWConnection, received: Data = Data()) {
        if received.isEmpty { connection.start(queue: queue) }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            let request = received + (data ?? Data())
            guard let header = String(data: request, encoding: .utf8), header.contains("\r\n\r\n") else {
                // Keep reading a request that came in pieces, up to a sane size.
                if error == nil, !isComplete, request.count < 16_384 { self.serve(connection, received: request) } else { connection.cancel() }
                return
            }
            self.answer(header, on: connection)
        }
    }

    private func answer(_ header: String, on connection: NWConnection) {
        let lines = header.components(separatedBy: "\r\n")
        let words = lines[0].split(separator: " ")
        let host = lines.first { $0.lowercased().hasPrefix("host:") }?.dropFirst(5).trimmingCharacters(in: .whitespaces)
        let url = words.count == 3 ? URLComponents(string: String(words[1])) : nil
        var query: [String: String] = [:]
        var repeated = false
        for item in url?.queryItems ?? [] {
            if query[item.name] != nil { repeated = true }
            query[item.name] = item.value ?? ""
        }
        let expected = lock.withLock { state }
        let matches = words.first == "GET" && host == "127.0.0.1:\(port)" && url?.path == ChatGPTAccount.callbackPath
            && !repeated && !expected.isEmpty && query["state"] == expected
        let page = matches
            ? "<!doctype html><meta charset=utf-8><title>Cairn</title><body style=\"font:16px system-ui;margin:18vh auto;max-width:32em\"><h1>Return to Cairn</h1><p>Cairn is finishing the ChatGPT sign-in. You can close this tab.</p>"
            : "Not found"
        let response = "HTTP/1.1 \(matches ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Cache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\nContent-Length: \(page.utf8.count)\r\n\r\n" + page
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        if matches { finish(.success(query)) }
    }
}

/// Resumes its continuation once; the listener reports states after `.ready` too.
private final class Pending: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
    func resume(_ result: Result<Void, Error>) {
        lock.withLock { () -> CheckedContinuation<Void, Error>? in
            defer { continuation = nil }
            return continuation
        }?.resume(with: result)
    }
}
