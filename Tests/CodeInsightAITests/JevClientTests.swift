@testable import CodeInsightAI
import CodeInsightCore
import CodeInsightReaderCore
import Foundation
import Testing

/// The one Jev call against a stubbed URL loader: what is sent, how busy
/// and failed connections are retried, and that the key never shows.
@Suite(.serialized) struct JevClientTests {
    static let key = "test-only-jev-key-5c1e"

    let questions = SkeletonQuestions(bytes: Array("""
        fn main() {
            let config = load();
            let name = config.name.clone();
            run(config);
        }
        fn load() -> Config { Config::default() }
        fn run(config: Config) { config.apply(); }
        """.utf8), language: .rust)!

    func client(_ replies: [StubLoader.Reply], key: String? = JevClientTests.key) -> (JevClient, Pauses) {
        StubLoader.start(replies)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubLoader.self]
        let pauses = Pauses()
        let client = JevClient(session: URLSession(configuration: configuration), key: { key }) { seconds in
            pauses.append(seconds)
        }
        return (client, pauses)
    }

    func answers(_ score: Double = 0.7) -> StubLoader.Reply {
        let body = ["answers": Dictionary(uniqueKeysWithValues: questions.questions.map { ($0.id, ["noul": score]) }),
                    "usage": ["input_tokens": 120]]
        return .status(200, try! JSONSerialization.data(withJSONObject: body))
    }

    /// Fails when the key shows in what an error says about itself.
    func expectNoKey(_ error: any Error) {
        let leaks = String(reflecting: error).contains(Self.key) || "\(error)".contains(Self.key)
            || error.localizedDescription.contains(Self.key)
        #expect(!leaks, "an error description carries the key")
    }

    @Test func sendsOnePostWithTheKeyAndEveryQuestion() async throws {
        let (client, pauses) = client([answers()])
        let scores = try await client.scores(for: questions)
        #expect(scores == Dictionary(uniqueKeysWithValues: questions.questions.map { ($0.id, 0.7) }))
        let requests = StubLoader.requests()
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.url == URL(string: "https://api.typesafe.ai/v1/systemone"))
        #expect(request.method == "POST" && request.contentType == "application/json")
        // Compared into a Bool, so a failure never prints the header.
        let authorized = request.authorization == "Bearer " + Self.key
        #expect(authorized, "Authorization is not the bearer key")
        #expect(request.timeout == 30)
        #expect(request.body == questions.requestBody)
        let body = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        #expect(body["model"] as? String == "jev-latest" && body["state"] as? String == questions.state)
        let asked = try #require(body["questions"] as? [String: [String: String]])
        #expect(Set(asked.keys) == Set(questions.questions.map(\.id)))
        #expect(asked.values.allSatisfy { $0["type"] == "noul" && !($0["instructions"] ?? "").isEmpty })
        #expect(pauses.values.isEmpty)
    }

    @Test func aBusyServiceIsTriedAgainAfterOneThenTwoSeconds() async throws {
        let (client, pauses) = client([.status(429, Data()), .status(529, Data()), answers(0.2)])
        let scores = try await client.scores(for: questions)
        #expect(scores.values.allSatisfy { $0 == 0.2 })
        #expect(StubLoader.requests().count == 3)
        #expect(pauses.values == [1, 2])
    }

    @Test func aServiceStillBusyAfterThreeRetriesFails() async throws {
        let (client, pauses) = client(Array(repeating: .status(529, Data()), count: 5))
        let error = await #expect(throws: JevClient.Failure.status(529)) { try await client.scores(for: questions) }
        #expect(StubLoader.requests().count == 4)
        #expect(pauses.values == [1, 2, 4])
        if let error { expectNoKey(error) }
    }

    @Test func aDroppedConnectionIsTriedAgainAndThenFailsAsTransport() async throws {
        let (client, pauses) = client([.drop, answers()])
        _ = try await client.scores(for: questions)
        #expect(StubLoader.requests().count == 2 && pauses.values == [1])

        let (failing, failingPauses) = self.client(Array(repeating: .drop, count: 5))
        let error = await #expect(throws: JevClient.Failure.transport) { try await failing.scores(for: questions) }
        #expect(StubLoader.requests().count == 4 && failingPauses.values == [1, 2, 4])
        if let error { expectNoKey(error) }
    }

    @Test func otherStatusesFailAtOnce() async throws {
        let (client, pauses) = client([.status(401, Data("{\"error\":\"bad key\"}".utf8))])
        let error = await #expect(throws: JevClient.Failure.status(401)) { try await client.scores(for: questions) }
        #expect(StubLoader.requests().count == 1 && pauses.values.isEmpty)
        if let error { expectNoKey(error) }
    }

    @Test func cancellingStopsTheRequestWithoutARetry() async throws {
        let (client, pauses) = client([.hang])
        let task = Task { try await client.scores(for: questions) }
        while StubLoader.requests().isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(StubLoader.requests().count == 1 && pauses.values.isEmpty)
    }

    @Test func missingOrMalformedAnswersAreRejected() async throws {
        let first = try #require(questions.questions.first?.id)
        var partial = Dictionary(uniqueKeysWithValues: questions.questions.map { ($0.id, ["noul": 0.5]) })
        partial[first] = [:]
        var outOfRange = Dictionary(uniqueKeysWithValues: questions.questions.map { ($0.id, ["noul": 0.5]) })
        outOfRange[first] = ["noul": 1.5]
        for body in [Data("not json".utf8), Data("{\"usage\":{}}".utf8),
                     try JSONSerialization.data(withJSONObject: ["answers": partial]),
                     try JSONSerialization.data(withJSONObject: ["answers": outOfRange])] {
            let (client, _) = client([.status(200, body)])
            let error = await #expect(throws: JevClient.Failure.malformedResponse) { try await client.scores(for: questions) }
            if let error { expectNoKey(error) }
        }
    }

    @Test func withoutAKeyNothingIsSent() async throws {
        for key in [nil, "  "] {
            let (client, _) = client([answers()], key: key)
            await #expect(throws: JevClient.Failure.notConfigured) { try await client.scores(for: questions) }
            #expect(StubLoader.requests().isEmpty)
        }
    }

    @Test func cachedScoresComeBackOnlyForTheSameContentLanguageAndRuleVersion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jev-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = JevScoreCache(directory: directory)
        let scores = Dictionary(uniqueKeysWithValues: questions.questions.map { ($0.id, 0.25) })
        #expect(cache.scores(contentHash: "abc", language: .rust) == nil)
        cache.save(scores, contentHash: "abc", language: .rust)
        #expect(cache.scores(contentHash: "abc", language: .rust) == scores)
        #expect(JevScoreCache(directory: directory).scores(contentHash: "abc", language: .rust) == scores)
        #expect(cache.scores(contentHash: "abd", language: .rust) == nil)
        #expect(cache.scores(contentHash: "abc", language: .python) == nil)
        #expect(JevScoreCache(directory: directory, ruleVersion: SkeletonQuestions.ruleVersion + 1)
            .scores(contentHash: "abc", language: .rust) == nil)

        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        let stored = try String(contentsOf: try #require(files.first), encoding: .utf8)
        for code in ["fn ", "main", "config", "load", "run(", "noul"] {
            #expect(!stored.contains(code), "the cache file holds `\(code)`")
        }
        #expect(try JSONDecoder().decode([String: Double].self, from: Data(stored.utf8)) == scores)
    }
}

final class Pauses: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Int] = []
    func append(_ seconds: Int) { lock.withLock { recorded.append(seconds) } }
    var values: [Int] { lock.withLock { recorded } }
}

/// Answers each request with the next reply, and records what was sent.
final class StubLoader: URLProtocol, @unchecked Sendable {
    enum Reply {
        case status(Int, Data)
        case drop
        case hang
    }

    struct Sent {
        let url: URL?
        let method: String?
        let authorization: String?
        let contentType: String?
        let timeout: TimeInterval
        let body: Data
    }

    nonisolated(unsafe) private static var replies: [Reply] = []
    nonisolated(unsafe) private static var sent: [Sent] = []
    private static let lock = NSLock()

    static func start(_ replies: [Reply]) { lock.withLock { self.replies = replies; sent = [] } }
    static func requests() -> [Sent] { lock.withLock { sent } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // Inside a URL loader the body arrives as a stream.
        var body = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(buffer, count: count)
            }
            stream.close()
        } else if let data = request.httpBody {
            body = data
        }
        let reply: Reply = Self.lock.withLock {
            Self.sent.append(Sent(
                url: request.url, method: request.httpMethod,
                authorization: request.value(forHTTPHeaderField: "Authorization"),
                contentType: request.value(forHTTPHeaderField: "Content-Type"),
                timeout: request.timeoutInterval, body: body
            ))
            return Self.replies.isEmpty ? .drop : Self.replies.removeFirst()
        }
        switch reply {
        case .status(let code, let data):
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .drop:
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        case .hang:
            break
        }
    }

    override func stopLoading() {}
}
