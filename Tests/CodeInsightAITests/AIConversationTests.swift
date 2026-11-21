@testable import CodeInsightAI
import Foundation
import Testing

/// The real helper against a local endpoint replaying recorded DeepSeek
/// streams (Fixtures, recorded 2026-11-18 from deepseek-v4-pro, thinking on).
@MainActor
@Suite(.serialized)
struct AIConversationTests {
    nonisolated static let helperURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/cairn-ai/release/cairn-ai")

    /// Starts a helper when there is none or the last one stopped, as the app does.
    final class Helpers {
        var current: AIHelper?
        func get() throws -> AIHelper? {
            if let current, current.isRunning { return current }
            current = try AIHelper(executable: AIConversationTests.helperURL)
            return current
        }
    }

    struct Fixture {
        let model: AIConversationModel
        let snapshot: AISnapshot
        let helpers: Helpers
    }

    func fixture(provider: FakeProvider, wire: AIProviderSettings.WireProtocol) throws -> Fixture? {
        guard FileManager.default.isExecutableFile(atPath: Self.helperURL.path) else {
            Issue.record("Build the helper first: bash scripts/build-ai-helper.sh")
            return nil
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ai-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "alpha\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "beta\n".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let base = wire == .openAI ? "http://127.0.0.1:\(provider.port)/v1" : "http://127.0.0.1:\(provider.port)"
        let helpers = Helpers()
        let model = AIConversationModel(
            helper: { try helpers.get() },
            settings: { AIProviderSettings(wireProtocol: wire, baseURL: base, model: "deepseek-v4-pro") },
            apiKey: { "test-key" },
            consent: AIConsentStore(suiteName: NSTemporaryDirectory() + "cairn-ai-tests-\(UUID().uuidString)")
        )
        let snapshot = AISnapshot(root: root, revision: nil, id: nil, files: ["a.txt", "b.txt"], source: nil, sessions: [])
        return Fixture(model: model, snapshot: snapshot, helpers: helpers)
    }

    func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test(arguments: [AIProviderSettings.WireProtocol.openAI, .anthropic])
    func parallelToolCallsRoundTripWithReasoningAndOneResultMessage(wire: AIProviderSettings.WireProtocol) async throws {
        let name = wire == .openAI ? "openai" : "anthropic"
        let provider = try FakeProvider(replies: [
            .init(body: FakeProvider.fixture("\(name)-1-tools")),
            .init(body: FakeProvider.fixture("\(name)-2-answer")),
        ])
        defer { provider.stop() }
        guard let f = try fixture(provider: provider, wire: wire) else { return }
        f.model.ask("What do a.txt and b.txt contain?", snapshot: f.snapshot)
        try await waitUntil { !f.model.isRunning }

        let turn = try #require(f.model.turns.last)
        #expect(turn.state == .done)
        #expect(turn.answer.contains("alpha") && turn.answer.contains("beta"))
        #expect(turn.steps.map(\.kind) == [.read, .read])
        #expect(Set(turn.evidence.map(\.path)) == ["a.txt", "b.txt"])

        let requests = provider.requests
        try #require(requests.count == 2)
        #expect(requests[0].head.hasPrefix(wire == .openAI ? "POST /v1/chat/completions" : "POST /v1/messages"))
        #expect(requests[0].head.lowercased().contains(wire == .openAI ? "authorization: bearer test-key" : "x-api-key: test-key"))
        let messages = try #require(requests[1].json["messages"] as? [[String: Any]])
        if wire == .openAI {
            let assistant = try #require(messages.first { $0["role"] as? String == "assistant" })
            #expect((assistant["tool_calls"] as? [Any])?.count == 2)
            #expect(!((assistant["reasoning_content"] as? String) ?? "").isEmpty)
            let results = messages.filter { $0["role"] as? String == "tool" }.compactMap { $0["content"] as? String }
            #expect(results.count == 2 && results.allSatisfy { $0.contains("alpha") || $0.contains("beta") })
        } else {
            let assistant = try #require(messages.first { $0["role"] as? String == "assistant" })
            let blocks = try #require(assistant["content"] as? [[String: Any]])
            #expect(blocks.contains { $0["type"] as? String == "thinking" && !(($0["signature"] as? String) ?? "").isEmpty })
            #expect(blocks.filter { $0["type"] as? String == "tool_use" }.count == 2)
            let last = try #require(messages.last)
            let results = try #require(last["content"] as? [[String: Any]])
            #expect(results.filter { $0["type"] as? String == "tool_result" }.count == 2)
        }
    }

    @Test func cancelledRoundLeavesItsAnswerAndTheNextQuestionWorks() async throws {
        let provider = try FakeProvider(replies: [.init(body: FakeProvider.fixture("openai-2-answer"), hangAfterEvents: 8)])
        defer { provider.stop() }
        guard let f = try fixture(provider: provider, wire: .openAI) else { return }
        f.model.ask("first", snapshot: f.snapshot)
        try await waitUntil { f.model.turns.last?.state == .answering }
        f.model.cancel()
        let partial = f.model.turns[0].answer
        #expect(f.model.turns[0].state == .cancelled)

        provider.enqueue(.init(body: FakeProvider.fixture("openai-2-answer")))
        f.model.ask("second", snapshot: f.snapshot)
        try await waitUntil { !f.model.isRunning }
        #expect(f.model.turns[1].state == .done)
        #expect(f.model.turns[1].answer.contains("beta"))
        #expect(f.model.turns[0].answer == partial)
        // The follow-up went out on the same conversation.
        let messages = try #require(provider.requests.last?.json["messages"] as? [[String: Any]])
        #expect(messages.filter { $0["role"] as? String == "user" }.count == 2)
    }

    @Test func helperExitFailsTheRoundAndTheNextQuestionStartsAnotherHelper() async throws {
        let provider = try FakeProvider(replies: [.init(body: FakeProvider.fixture("openai-2-answer"), hangAfterEvents: 8)])
        defer { provider.stop() }
        guard let f = try fixture(provider: provider, wire: .openAI) else { return }
        f.model.ask("first", snapshot: f.snapshot)
        try await waitUntil { f.model.turns.last?.state == .answering }
        let first = try #require(f.helpers.current)
        kill(first.processIdentifier, SIGKILL)
        try await waitUntil { !f.model.isRunning }
        #expect(f.model.turns[0].state == .failed(AIHelper.exitedMessage))

        provider.enqueue(.init(body: FakeProvider.fixture("openai-2-answer")))
        f.model.ask("second", snapshot: f.snapshot)
        try await waitUntil { !f.model.isRunning }
        #expect(f.model.turns[1].state == .done)
        #expect(f.helpers.current !== first)
    }

    /// A model that never stops calling tools must not run up a bill: after
    /// the budget it gets errors instead of results, then the turn stops.
    @Test func aModelThatKeepsCallingToolsIsStoppedAfterTheBudget() async throws {
        let rounds = AIConversationModel.maxRounds + 2
        let provider = try FakeProvider(replies: Array(repeating: .init(body: FakeProvider.fixture("openai-1-tools")), count: rounds + 3))
        defer { provider.stop() }
        guard let f = try fixture(provider: provider, wire: .openAI) else { return }
        f.model.ask("loop", snapshot: f.snapshot)
        try await waitUntil { !f.model.isRunning }

        let turn = try #require(f.model.turns.last)
        #expect(turn.state == .failed("roundLimit"))
        #expect(turn.steps.count == AIConversationModel.maxRounds * 2)
        try await Task.sleep(for: .milliseconds(300))
        let requests = provider.requests
        #expect(requests.count == rounds)
        let lastResults = (requests.last?.json["messages"] as? [[String: Any]] ?? [])
            .suffix(2).compactMap { $0["content"] as? String }
        #expect(lastResults.count == 2 && lastResults.allSatisfy { $0.contains("budget") })
    }

    /// A recorded stream reporting `tokens` of input instead of what it used.
    func reporting(_ tokens: Int, _ fixture: String) -> String {
        FakeProvider.fixture(fixture).replacingOccurrences(
            of: #""(input|prompt)_tokens":\d+"#, with: "\"$1_tokens\":\(tokens)", options: .regularExpression)
    }

    /// The tool results the last request sent, and whether it sent reasoning back.
    func sentResults(_ request: FakeProvider.Received, wire: AIProviderSettings.WireProtocol) -> (results: [String], reasoning: Bool) {
        let messages = request.json["messages"] as? [[String: Any]] ?? []
        if wire == .openAI {
            return (messages.filter { $0["role"] as? String == "tool" }.compactMap { $0["content"] as? String },
                    messages.contains { !(($0["reasoning_content"] as? String) ?? "").isEmpty })
        }
        let blocks = messages.flatMap { $0["content"] as? [[String: Any]] ?? [] }
        return (blocks.filter { $0["type"] as? String == "tool_result" }.compactMap { $0["content"] as? String },
                blocks.contains { $0["type"] as? String == "thinking" })
    }

    /// A round whose input is over the budget gets "answer now" instead of
    /// results; the next question goes out with the old results cleared and,
    /// on Anthropic, without the earlier thinking, which Claude would reject
    /// once an earlier message changed (a 400, measured 2026-11-21).
    @Test(arguments: [AIProviderSettings.WireProtocol.openAI, .anthropic])
    func aLongConversationIsToldToAnswerAndTheNextQuestionClearsOldResults(wire: AIProviderSettings.WireProtocol) async throws {
        let name = wire == .openAI ? "openai" : "anthropic"
        let provider = try FakeProvider(replies: [
            .init(body: reporting(AIConversationModel.answerAbove + 1, "\(name)-1-tools")),
            .init(body: reporting(AIConversationModel.trimAbove + 1, "\(name)-2-answer")),
            .init(body: FakeProvider.fixture("\(name)-2-answer")),
        ])
        defer { provider.stop() }
        guard let f = try fixture(provider: provider, wire: wire) else { return }
        f.model.ask("first", snapshot: f.snapshot)
        try await waitUntil { !f.model.isRunning }
        #expect(f.model.turns[0].state == .done)
        #expect(f.model.turns[0].steps.isEmpty)
        let answered = sentResults(try #require(provider.requests.last), wire: wire)
        #expect(answered.results.count == 2 && answered.results.allSatisfy { $0.contains("budget") })

        f.model.ask("second", snapshot: f.snapshot)
        try await waitUntil { !f.model.isRunning }
        #expect(f.model.turns[1].state == .done)
        let trimmed = sentResults(try #require(provider.requests.last), wire: wire)
        #expect(trimmed.results.count == 2 && trimmed.results.allSatisfy { $0.contains("cleared") })
        // OpenAI-compatible providers do not bind reasoning to the history, so it stays.
        #expect(trimmed.reasoning == (wire == .openAI))
    }

    /// A question the provider rejects as longer than the model's context is
    /// sent once more with the earlier tool results cleared.
    @Test func aQuestionRejectedAsTooLongIsRetriedWithOldResultsCleared() async throws {
        let tooLong = #"{"type":"error","error":{"type":"invalid_request_error","message":"prompt is too long: 1048577 tokens > 1048576 maximum"}}"#
        let provider = try FakeProvider(replies: [
            .init(body: FakeProvider.fixture("anthropic-1-tools")),
            .init(body: FakeProvider.fixture("anthropic-2-answer")),
            .init(body: tooLong, contentType: "application/json", status: "400 Bad Request"),
            .init(body: FakeProvider.fixture("anthropic-2-answer")),
        ])
        defer { provider.stop() }
        guard let f = try fixture(provider: provider, wire: .anthropic) else { return }
        f.model.ask("first", snapshot: f.snapshot)
        try await waitUntil { !f.model.isRunning }
        f.model.ask("second", snapshot: f.snapshot)
        try await waitUntil { !f.model.isRunning }

        #expect(f.model.turns[1].state == .done)
        let requests = provider.requests
        try #require(requests.count == 4)
        #expect(sentResults(requests[2], wire: .anthropic).results.allSatisfy { $0.contains("alpha") || $0.contains("beta") })
        let retried = sentResults(requests[3], wire: .anthropic)
        #expect(retried.results.count == 2 && retried.results.allSatisfy { $0.contains("cleared") })
        #expect(!retried.reasoning)
    }

    /// An Anthropic stream with one tool call.
    func toolUse(_ name: String, _ input: [String: Any], id: String) throws -> String {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)
        let events: [[String: Any]] = [
            ["type": "message_start", "message": ["id": "m", "type": "message", "role": "assistant", "model": "m",
                                                  "content": [Any](), "usage": ["input_tokens": 10, "output_tokens": 1]]],
            ["type": "content_block_start", "index": 0, "content_block": ["type": "tool_use", "id": id, "name": name, "input": [String: Any]()]],
            ["type": "content_block_delta", "index": 0, "delta": ["type": "input_json_delta", "partial_json": json]],
            ["type": "content_block_stop", "index": 0],
            ["type": "message_delta", "delta": ["stop_reason": "tool_use"], "usage": ["output_tokens": 5]],
            ["type": "message_stop"],
        ]
        return try events.map { event in
            "event: \(event["type"]!)\ndata: " + String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self) + "\n\n"
        }.joined()
    }

    /// A guide is written through the shared loop: the model reads, hands in
    /// a draft, gets the checker's errors back, fixes them, and the accepted
    /// guide is saved by file content (out of date once the file changes).
    @Test func aGuideIsCheckedFixedSavedAndMarkedStaleWhenTheFileChanges() async throws {
        let bad = "---\ntitle: a.txt\n---\nAlpha at `L9`.\n"
        let good = "---\ntitle: a.txt\n---\nAlpha at `L1`.\n"
        let provider = try FakeProvider(replies: [
            .init(body: try toolUse("read", ["path": "a.txt"], id: "t1")),
            .init(body: try toolUse("submit_guide", ["draft": bad], id: "t2")),
            .init(body: try toolUse("submit_guide", ["draft": good], id: "t3")),
        ])
        defer { provider.stop() }
        guard let f = try fixture(provider: provider, wire: .anthropic) else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("guides-\(UUID().uuidString)")
        let model = AIGuideModel(
            helper: { try f.helpers.get() },
            settings: { AIProviderSettings(wireProtocol: .anthropic, baseURL: "http://127.0.0.1:\(provider.port)", model: "m") },
            apiKey: { "k" }, consent: AIConsentStore(suiteName: NSTemporaryDirectory() + "guide-\(UUID().uuidString)"),
            directory: directory)
        model.show(path: "a.txt", in: f.snapshot)
        #expect(model.guide == nil)
        model.generate(language: "English")
        try await waitUntil { !model.state.isRunning }

        #expect(model.state == .done)
        #expect(model.steps.map(\.kind) == [.read])
        #expect(model.guide?.draft == good && model.isStale == false)
        let fixRequest = try #require(provider.requests.last?.json["messages"] as? [[String: Any]])
        let returned = fixRequest.flatMap { $0["content"] as? [[String: Any]] ?? [] }
            .filter { $0["type"] as? String == "tool_result" }.compactMap { $0["content"] as? String }
        #expect(returned.last?.contains("L4: 9-9 is not inside the file (1-1)") == true, "\(returned)")

        model.show(path: "b.txt", in: f.snapshot)
        #expect(model.guide == nil)
        model.show(path: "a.txt", in: f.snapshot)
        #expect(model.guide?.draft == good && model.isStale == false)
        try "alpha changed\n".write(to: f.snapshot.root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        model.show(path: "a.txt", in: f.snapshot)
        #expect(model.guide?.draft == good && model.isStale)
    }

    /// Settings offers the endpoint's own model list; each protocol has its
    /// own path and key header.
    @Test(arguments: [AIProviderSettings.WireProtocol.openAI, .anthropic])
    func modelListComesFromTheConfiguredEndpoint(wire: AIProviderSettings.WireProtocol) async throws {
        let provider = try FakeProvider(replies: [
            .init(body: #"{"data":[{"id":"m-b"},{"id":"m-a"}]}"#, contentType: "application/json"),
        ])
        defer { provider.stop() }
        guard FileManager.default.isExecutableFile(atPath: Self.helperURL.path) else {
            Issue.record("Build the helper first: bash scripts/build-ai-helper.sh"); return
        }
        let helper = try AIHelper(executable: Self.helperURL)
        let base = wire == .openAI ? "http://127.0.0.1:\(provider.port)/v1" : "http://127.0.0.1:\(provider.port)"
        let result = await AIConversationModel.listModels(
            AIProviderSettings(wireProtocol: wire, baseURL: base), apiKey: "test-key", helper: helper)
        #expect(result == .models(["m-a", "m-b"]))
        let head = try #require(provider.requests.first?.head)
        #expect(head.hasPrefix("GET /v1/models"))
        #expect(head.lowercased().contains(wire == .openAI ? "authorization: bearer test-key" : "x-api-key: test-key"))
    }

    @Test func eventsOfAnEarlierRoundDoNotReachTheCurrentTurn() async throws {
        let provider = try FakeProvider(replies: [.init(body: "", hangAfterEvents: 0)])
        defer { provider.stop() }
        guard let f = try fixture(provider: provider, wire: .openAI) else { return }
        f.model.ask("q", snapshot: f.snapshot)
        let current = f.model.run.round
        f.model.run.handle(.text("stale"), round: current - 1)
        #expect(f.model.turns.last?.answer == "")
        f.model.run.handle(.text("fresh"), round: current)
        #expect(f.model.turns.last?.answer == "fresh")
        f.model.cancel()
    }

    /// Asking again while the last round's tool calls have no results (the
    /// user cancelled while tools ran) must not send those calls unanswered.
    @Test(arguments: [AIProviderSettings.WireProtocol.openAI, .anthropic])
    func askingAfterACancelDuringToolsDropsTheUnansweredCalls(wire: AIProviderSettings.WireProtocol) async throws {
        let name = wire == .openAI ? "openai" : "anthropic"
        let provider = try FakeProvider(replies: [
            .init(body: FakeProvider.fixture("\(name)-1-tools")),
            .init(body: FakeProvider.fixture("\(name)-2-answer")),
        ])
        defer { provider.stop() }
        guard FileManager.default.isExecutableFile(atPath: Self.helperURL.path) else {
            Issue.record("Build the helper first: bash scripts/build-ai-helper.sh"); return
        }
        let helper = try AIHelper(executable: Self.helperURL)
        final class Events: @unchecked Sendable { let lock = NSLock(); var list: [AIHelperEvent] = [] }
        let events = Events()
        helper.observe("c") { _, event in events.lock.withLock { events.list.append(event) } }
        let base = wire == .openAI ? "http://127.0.0.1:\(provider.port)/v1" : "http://127.0.0.1:\(provider.port)"
        let config: [String: Any] = ["protocol": wire.rawValue, "base_url": base, "model": "m", "api_key": "k"]
        func last() -> AIHelperEvent? { events.lock.withLock { events.list.last } }
        helper.send(["type": "ask", "conversation": "c", "config": config, "text": "first", "round": 1,
                     "tools": AITools.specs, "system": "s"])
        try await waitUntil { if case .toolCalls = last() { true } else { false } }
        helper.send(["type": "cancel", "conversation": "c"])
        helper.send(["type": "ask", "conversation": "c", "config": config, "text": "second", "round": 2])
        try await waitUntil { if case .done = last() { true } else { false } }

        let messages = try #require(provider.requests.last?.json["messages"] as? [[String: Any]])
        let roles = messages.map { $0["role"] as? String ?? "" }
        #expect(roles.filter { $0 == "assistant" }.isEmpty, "\(roles)")
        #expect(roles.filter { $0 == "user" }.count == 2)
    }
}
