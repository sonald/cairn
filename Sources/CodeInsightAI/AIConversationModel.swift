import Foundation
import Observation

/// One window's AI conversation: questions about the snapshot that was
/// showing when it started, answered by the configured model through the
/// helper, which reads code only through `AITools`. Not saved.
@MainActor
@Observable
public final class AIConversationModel {
    public enum TurnState: Equatable, Sendable {
        /// Waiting for the model or running its tools.
        case working
        /// The answer is streaming in.
        case answering
        case done
        case cancelled
        case failed(String)

        public var isRunning: Bool { self == .working || self == .answering }
    }

    /// Code the user selected to ask about.
    public struct Selection: Equatable, Sendable {
        public let path: String
        public let startLine: Int
        public let endLine: Int
        public let text: String

        public init(path: String, startLine: Int, endLine: Int, text: String) {
            self.path = path
            self.startLine = startLine
            self.endLine = endLine
            self.text = text
        }

        /// The selection as the model reads it, before the question.
        var prompt: String {
            var body = Substring(text)
            while body.last?.isNewline == true { body = body.dropLast() }
            let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
            let kept = lines.prefix(AITools.maxSelectionLines).joined(separator: "\n")
            let more = lines.count > AITools.maxSelectionLines
                ? "\n(selection cut at \(AITools.maxSelectionLines) lines; read the file for the rest)" : ""
            let range = startLine == endLine ? "line \(startLine)" : "lines \(startLine)-\(endLine)"
            return "The user selected \(path) \(range):\n```\n\(kept)\n```\(more)"
        }
    }

    public struct Turn: Identifiable, Sendable {
        public let id: Int
        public let question: String
        public let selection: Selection?
        public internal(set) var answer = ""
        public internal(set) var steps: [AIToolStep] = []
        public internal(set) var evidence: [AIEvidence] = []
        /// The step running now, shown until it finishes.
        public internal(set) var runningStep: AIToolStep?
        public internal(set) var state = TurnState.working
        public let startedAt: Date
        public internal(set) var elapsed: TimeInterval?
        public internal(set) var outputTokens: Int?
    }

    /// Why a question cannot be sent yet.
    public enum Blocker: Equatable, Sendable {
        case noProject
        case needsSettings
        case needsKey
        case helperMissing
        /// Code from this project has not been allowed to go to this host.
        case needsConsent(host: String)
    }

    /// The most tool rounds one question may use; after it the model is
    /// told to answer with what it has.
    public static let maxRounds = 15

    public private(set) var turns: [Turn] = []
    /// The snapshot this conversation reads; nil before the first question.
    public private(set) var snapshot: AISnapshot?

    @ObservationIgnored private let helper: @MainActor () throws -> AIHelper?
    @ObservationIgnored private let settings: @MainActor () -> AIProviderSettings
    @ObservationIgnored private let apiKey: @MainActor () -> String?
    /// Whether a key is stored, without reading it: reading the secret can
    /// raise a Keychain prompt, so only asking does.
    @ObservationIgnored private let hasKey: @MainActor () -> Bool
    @ObservationIgnored private let consent: AIConsentStore
    @ObservationIgnored private var conversationID: String?
    @ObservationIgnored private weak var connectedHelper: AIHelper?
    @ObservationIgnored private(set) var round = 0
    @ObservationIgnored private var roundsThisTurn = 0
    @ObservationIgnored private var toolTask: Task<Void, Never>?

    public init(
        helper: @escaping @MainActor () throws -> AIHelper? = { try AIHelper.shared() },
        settings: @escaping @MainActor () -> AIProviderSettings = { AIProviderSettings.load() },
        apiKey: @escaping @MainActor () -> String? = { AIKeychain.read() },
        hasKey: (@MainActor () -> Bool)? = nil,
        consent: AIConsentStore = AIConsentStore()
    ) {
        self.helper = helper
        self.settings = settings
        self.apiKey = apiKey
        self.hasKey = hasKey ?? { AIKeychain.exists() }
        self.consent = consent
    }

    public var isRunning: Bool { turns.last?.state.isRunning ?? false }

    /// What stops a question about `project` now, if anything.
    public func blocker(project: URL?) -> Blocker? {
        guard let project = snapshot?.root ?? project else { return .noProject }
        let settings = settings()
        guard settings.isComplete else { return .needsSettings }
        if !settings.isLocal, !hasKey() { return .needsKey }
        if AIHelper.locate() == nil, connectedHelper == nil { return .helperMissing }
        if !settings.isLocal, let host = settings.host, !consent.allows(project, host: host) {
            return .needsConsent(host: host)
        }
        return nil
    }

    public func allowSending(project: URL) {
        guard let host = settings().host else { return }
        consent.allow(project, host: host)
    }

    /// Starts a new conversation on `snapshot` when there is none, then asks.
    /// The caller checks `blocker` first.
    public func ask(_ question: String, about selection: Selection? = nil,
                    snapshot newSnapshot: @autoclosure () -> AISnapshot?) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        cancel()
        if conversationID == nil || snapshot == nil {
            guard let fresh = newSnapshot() else { return }
            snapshot = fresh
        }
        turns.append(Turn(id: turns.count, question: question, selection: selection, startedAt: Date()))
        let settings = settings()
        guard let helper = connect() else { return }
        let request: [String: Any] = [
            "type": "ask",
            "conversation": conversationID!,
            "config": settings.helperConfig(apiKey: apiKey() ?? ""),
            "text": selection.map { $0.prompt + "\n\n" + question } ?? question,
            "round": nextRound(),
            // Used only when the helper creates the conversation.
            "system": systemPrompt(),
            "tools": AITools.specs,
        ]
        roundsThisTurn = 0
        helper.send(request)
    }

    public func cancel() {
        toolTask?.cancel()
        toolTask = nil
        guard isRunning, let last = turns.indices.last else { return }
        turns[last].state = .cancelled
        turns[last].runningStep = nil
        turns[last].elapsed = Date().timeIntervalSince(turns[last].startedAt)
        round += 1
        if let conversationID { connectedHelper?.send(["type": "cancel", "conversation": conversationID]) }
    }

    /// Forgets the conversation; the next question starts a new one on the
    /// snapshot showing then.
    public func reset() {
        cancel()
        if let conversationID { connectedHelper?.forget(conversationID) }
        conversationID = nil
        turns = []
        snapshot = nil
    }

    // MARK: Rounds

    private func connect() -> AIHelper? {
        do {
            guard let helper = try helper() else { return fail("helperMissing") }
            if helper !== connectedHelper || conversationID == nil {
                // A new helper does not know the old conversation: start over there.
                if let conversationID { connectedHelper?.forget(conversationID) }
                conversationID = UUID().uuidString
                connectedHelper = helper
                helper.observe(conversationID!) { [weak self] round, event in
                    // The main queue keeps the deltas in order.
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(event, round: round) } }
                }
            }
            return helper
        } catch {
            return fail(String(describing: error))
        }
    }

    private func fail(_ message: String) -> AIHelper? {
        if let last = turns.indices.last {
            turns[last].state = .failed(message)
            turns[last].runningStep = nil
            turns[last].elapsed = Date().timeIntervalSince(turns[last].startedAt)
        }
        return nil
    }

    private func nextRound() -> Int {
        round += 1
        return round
    }

    func handle(_ event: AIHelperEvent, round eventRound: Int) {
        guard eventRound == round || eventRound == -1,
              let last = turns.indices.last, turns[last].state.isRunning
        else { return }
        switch event {
        case .text(let delta):
            turns[last].answer += delta
            if !delta.isEmpty { turns[last].state = .answering }
        case .reasoning, .models:
            break
        case .toolCalls(let calls):
            runTools(calls)
        case .done(_, let outputTokens):
            turns[last].state = .done
            turns[last].outputTokens = outputTokens
            turns[last].elapsed = Date().timeIntervalSince(turns[last].startedAt)
        case .failed(let message):
            if eventRound == -1 { conversationID = nil }
            _ = fail(message)
        }
    }

    private func runTools(_ calls: [AIToolCall]) {
        guard let snapshot, let conversationID, let last = turns.indices.last else { return }
        roundsThisTurn += 1
        if roundsThisTurn > Self.maxRounds + 1 {
            cancel()
            turns[last].state = .failed("roundLimit")
            return
        }
        // Text before tool calls is the model thinking aloud, not the answer.
        turns[last].answer = ""
        turns[last].state = .working
        let overBudget = roundsThisTurn > Self.maxRounds
        let firstStep = turns[last].steps.count + 1
        let expectedRound = round
        toolTask = Task { [weak self] in
            var results: [[String: String]] = []
            for (offset, call) in calls.enumerated() {
                if overBudget {
                    results.append(["call_id": call.callID, "content": "error: the tool budget for this question is used up; answer now with what you have read"])
                    continue
                }
                // Each step shows while it runs and joins the trace as it ends.
                guard let self, self.isCurrent(expectedRound) else { return }
                let last = self.turns.count - 1
                self.turns[last].runningStep = AITools.step(for: call, in: snapshot)
                let ran = await AITools.run(call, step: firstStep + offset, in: snapshot)
                guard !Task.isCancelled, self.isCurrent(expectedRound) else { return }
                self.turns[last].runningStep = nil
                results.append(["call_id": call.callID, "content": ran.output])
                self.turns[last].steps.append(ran.step)
                for item in ran.evidence where !self.turns[last].evidence.contains(where: {
                    $0.path == item.path && $0.startLine == item.startLine && $0.endLine == item.endLine
                }) {
                    self.turns[last].evidence.append(item)
                }
            }
            guard let self, !Task.isCancelled, self.isCurrent(expectedRound) else { return }
            self.connectedHelper?.send([
                "type": "tool_results", "conversation": conversationID, "results": results, "round": self.nextRound(),
            ])
        }
    }

    private func isCurrent(_ expectedRound: Int) -> Bool {
        expectedRound == round && turns.last?.state.isRunning == true
    }

    private func systemPrompt() -> String {
        """
        You are the code-reading assistant inside Cairn, a read-only code reader. You answer questions \
        about one snapshot of a project. Look at the code with the tools before answering and do not guess \
        about code you have not read: symbol answers what a name is and who uses it, history why code is \
        as it is, search where text appears, read what a file or directory holds. Cite the code you rely on \
        as project-relative path:line or path:start-end. Answer in the language of the question, concisely, \
        with short excerpts rather than whole files. You cannot change files or run anything.

        \(snapshot?.overview() ?? "")
        """
    }

    // MARK: Test connection

    public enum ConnectionCheck: Equatable, Sendable {
        case ok
        case noToolCalls
        case failed(String)
    }

    /// Asks the endpoint to call a tool once: a provider without tool calling
    /// cannot answer questions about code.
    public static func checkConnection(
        _ settings: AIProviderSettings, apiKey: String, helper: AIHelper
    ) async -> ConnectionCheck {
        await oneShot(helper, timeout: .failed("timeout"), [
            "type": "ask",
            "config": settings.helperConfig(apiKey: apiKey),
            "system": "Call the ping tool once.",
            "tools": [["name": "ping", "description": "Checks the connection.",
                       "schema": ["type": "object", "properties": [String: Any]()]]],
            "text": "ping",
            "round": 1,
        ]) { event in
            switch event {
            case .toolCalls: .ok
            case .done: .noToolCalls
            case .failed(let message): .failed(message)
            case .text, .reasoning, .models: nil
            }
        }
    }

    public enum ModelList: Equatable, Sendable {
        case models([String])
        case failed(String)
    }

    /// The models the endpoint offers, for choosing one in Settings.
    public static func listModels(
        _ settings: AIProviderSettings, apiKey: String, helper: AIHelper
    ) async -> ModelList {
        await oneShot(helper, timeout: .failed("timeout"), [
            "type": "list_models", "config": settings.helperConfig(apiKey: apiKey),
        ]) { event in
            switch event {
            case .models(let names): .models(names)
            case .failed(let message): .failed(message)
            default: nil
            }
        }
    }

    /// Sends one request under a fresh ID and waits for the first event
    /// `answer` maps to a result, or 45 seconds.
    private static func oneShot<T: Sendable>(
        _ helper: AIHelper, timeout: T, _ request: [String: Any],
        answer: @escaping @Sendable (AIHelperEvent) -> T?
    ) async -> T {
        let id = "oneshot-" + UUID().uuidString
        var request = request
        request["conversation"] = id
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            let once = OnceBox(continuation)
            helper.observe(id) { _, event in
                if let result = answer(event) { once.resume(result) }
            }
            helper.send(request)
            Task {
                try? await Task.sleep(for: .seconds(45))
                once.resume(timeout)
            }
        }
        helper.forget(id)
        return result
    }
}

private final class OnceBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    init(_ continuation: CheckedContinuation<T, Never>) { self.continuation = continuation }
    func resume(_ value: T) {
        lock.withLock { () -> CheckedContinuation<T, Never>? in
            defer { continuation = nil }
            return continuation
        }?.resume(returning: value)
    }
}
