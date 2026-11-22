import Foundation

/// What every AI feature checks before code goes out: settings, key, helper,
/// and the user's permission to send this project to the provider's host.
@MainActor
public struct AIAccess {
    /// Why a request cannot be sent yet.
    public enum Blocker: Equatable, Sendable {
        case noProject
        case needsSettings
        case needsKey
        case helperMissing
        /// Code from this project has not been allowed to go to this host.
        case needsConsent(host: String)
    }

    let settings: @MainActor () -> AIProviderSettings
    let apiKey: @MainActor () -> String?
    /// Whether a key is stored, without reading it: reading the secret can
    /// raise a Keychain prompt, so only sending does.
    let hasKey: @MainActor () -> Bool
    let consent: AIConsentStore

    /// What stops a request about `project` now, if anything.
    func blocker(project: URL?, helperConnected: Bool) -> Blocker? {
        guard let project else { return .noProject }
        let settings = settings()
        guard settings.isComplete else { return .needsSettings }
        if !settings.isLocal, !(settings.wireProtocol == .chatGPT ? ChatGPTAccount.isSignedIn() : hasKey()) { return .needsKey }
        if AIHelper.locate() == nil, !helperConnected { return .helperMissing }
        if !settings.isLocal, let host = settings.host, !consent.allows(project, host: host) {
            return .needsConsent(host: host)
        }
        return nil
    }

    func allow(_ project: URL) {
        guard let host = settings().host else { return }
        consent.allow(project, host: host)
    }

    /// The provider settings for the helper; reads the key, or gets a fresh
    /// ChatGPT token.
    func helperConfig() async throws -> [String: Any] {
        let settings = settings()
        let key = settings.wireProtocol == .chatGPT ? try await ChatGPTAccount.accessToken() : apiKey() ?? ""
        return settings.helperConfig(apiKey: key)
    }
}

/// One AI task's loop on the helper, shared by every feature: sends the
/// task's messages, runs the model's tool calls on the snapshot, keeps the
/// tool budget, and drops events of rounds that were cancelled or replaced.
/// The feature keeps its own record of what happened from `update`.
@MainActor
final class AIRun {
    enum Update {
        case text(String)
        /// The model called tools: any text before them was thinking aloud.
        case tools
        case stepStarted(AIToolStep)
        case stepFinished(AIToolStep, evidence: [AIEvidence])
        case done(outputTokens: Int)
        /// The model handed in its work through the task's terminal tool and
        /// the check accepted it; the run is over.
        case submitted(AIToolCall)
        case failed(String)
    }

    /// A tool that ends the run, such as handing in a draft: `check` returns
    /// nil to accept the call, or what to fix, which goes back as its result.
    struct Terminal {
        let name: String
        let check: @MainActor (AIToolCall) -> String?
    }

    /// Tool rounds one request may use, and the input one round may send
    /// (history included) before the model is told to answer with what it
    /// has; if it calls tools again after that, the run stops.
    let maxRounds: Int
    let answerAbove: Int
    /// Input of the last round above which the helper clears the earlier
    /// tool results before the next request (they can be fetched again).
    let trimAbove: Int
    /// What the model is told to do once the budget is spent.
    let whenOverBudget: String
    let terminal: Terminal?
    var update: (Update) -> Void = { _ in }

    private let helper: @MainActor () throws -> AIHelper?
    private let tools: [[String: Any]]
    private var conversationID: String?
    private(set) weak var connectedHelper: AIHelper?
    private(set) var round = 0
    private(set) var isRunning = false
    private var roundsThisRequest = 0
    private var stepsThisRequest = 0
    private var toldToAnswer = false
    private var snapshot: AISnapshot?
    private var toolTask: Task<Void, Never>?

    init(helper: @escaping @MainActor () throws -> AIHelper?, tools: [[String: Any]],
         maxRounds: Int, answerAbove: Int, trimAbove: Int,
         whenOverBudget: String = "answer now with what you have read", terminal: Terminal? = nil) {
        self.helper = helper
        self.tools = tools
        self.maxRounds = maxRounds
        self.answerAbove = answerAbove
        self.trimAbove = trimAbove
        self.whenOverBudget = whenOverBudget
        self.terminal = terminal
    }

    /// Whether the helper holds this run's conversation, so a follow-up
    /// continues it.
    var hasConversation: Bool { conversationID != nil }

    /// Sends `text` on the conversation, starting one with `system` when there
    /// is none. `config` is read only once the helper is up; it may refresh a
    /// token first, and a request cancelled meanwhile is not sent.
    func ask(_ text: String, in snapshot: AISnapshot, system: String,
             config: @escaping @MainActor () async throws -> [String: Any]) {
        cancel()
        self.snapshot = snapshot
        isRunning = true
        guard let helper = connect() else { return }
        let conversationID = conversationID!
        let round = nextRound()
        roundsThisRequest = 0
        stepsThisRequest = 0
        toldToAnswer = false
        Task { [weak self] in
            let settings: [String: Any]
            do {
                settings = try await config()
            } catch {
                guard let self, self.isCurrent(round) else { return }
                _ = self.fail(String(describing: error))
                return
            }
            guard let self, self.isCurrent(round) else { return }
            helper.send([
                "type": "ask",
                "conversation": conversationID,
                "config": settings,
                "text": text,
                "round": round,
                // Used only when the helper creates the conversation.
                "system": system,
                "tools": self.tools,
                "trim_above": self.trimAbove,
            ])
        }
    }

    /// Stops the request in flight; returns whether one was running.
    @discardableResult
    func cancel() -> Bool {
        toolTask?.cancel()
        toolTask = nil
        guard isRunning else { return false }
        isRunning = false
        round += 1
        if let conversationID { connectedHelper?.send(["type": "cancel", "conversation": conversationID]) }
        return true
    }

    /// Forgets the conversation; the next request starts a new one.
    func reset() {
        cancel()
        if let conversationID { connectedHelper?.forget(conversationID) }
        conversationID = nil
        snapshot = nil
    }

    private func connect() -> AIHelper? {
        do {
            guard let helper = try helper() else { return fail("helperMissing") }
            if helper !== connectedHelper || conversationID == nil {
                // A new helper does not know the old conversation: start over there.
                if let conversationID { connectedHelper?.forget(conversationID) }
                let id = UUID().uuidString
                conversationID = id
                connectedHelper = helper
                helper.observe(id) { [weak self] round, event in
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
        isRunning = false
        update(.failed(message))
        return nil
    }

    private func nextRound() -> Int {
        round += 1
        return round
    }

    func handle(_ event: AIHelperEvent, round eventRound: Int) {
        guard eventRound == round || eventRound == -1, isRunning else { return }
        switch event {
        case .text(let delta):
            update(.text(delta))
        case .reasoning, .models:
            break
        case .toolCalls(let calls, let inputTokens):
            runTools(calls, inputTokens: inputTokens)
        case .done(_, let outputTokens):
            isRunning = false
            update(.done(outputTokens: outputTokens))
        case .failed(let message):
            if eventRound == -1 { conversationID = nil }
            _ = fail(message)
        }
    }

    private func runTools(_ calls: [AIToolCall], inputTokens: Int) {
        guard let snapshot, let conversationID else { return }
        roundsThisRequest += 1
        let overBudget = roundsThisRequest > maxRounds || inputTokens > answerAbove
        if overBudget, toldToAnswer {
            cancel()
            update(.failed(roundsThisRequest > maxRounds ? "roundLimit" : "contextLimit"))
            return
        }
        toldToAnswer = overBudget
        update(.tools)
        let expectedRound = round
        toolTask = Task { [weak self] in
            var results: [[String: String]] = []
            for call in calls {
                if let terminal = self?.terminal, call.name == terminal.name {
                    guard let self, self.isCurrent(expectedRound) else { return }
                    if let problems = terminal.check(call) {
                        results.append(["call_id": call.callID, "content": problems])
                        continue
                    }
                    self.isRunning = false
                    self.update(.submitted(call))
                    return
                }
                if overBudget {
                    results.append(["call_id": call.callID, "content": "error: the tool budget is used up; \(self?.whenOverBudget ?? "")"])
                    continue
                }
                // Each step shows while it runs and joins the trace as it ends.
                guard let self, self.isCurrent(expectedRound) else { return }
                self.update(.stepStarted(AITools.step(for: call, in: snapshot)))
                self.stepsThisRequest += 1
                let ran = await AITools.run(call, step: self.stepsThisRequest, in: snapshot)
                guard !Task.isCancelled, self.isCurrent(expectedRound) else { return }
                results.append(["call_id": call.callID, "content": ran.output])
                self.update(.stepFinished(ran.step, evidence: ran.evidence))
            }
            guard let self, !Task.isCancelled, self.isCurrent(expectedRound) else { return }
            self.connectedHelper?.send([
                "type": "tool_results", "conversation": conversationID, "results": results, "round": self.nextRound(),
            ])
        }
    }

    private func isCurrent(_ expectedRound: Int) -> Bool {
        expectedRound == round && isRunning
    }
}
