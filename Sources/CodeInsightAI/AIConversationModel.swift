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

    public typealias Blocker = AIAccess.Blocker

    /// The most tool rounds one question may use; after it the model is
    /// told to answer with what it has.
    public static let maxRounds = 15
    /// Input tokens per round. ponytail: fixed below the 100K-token prompt
    /// where Claude Haiku 5.5's price rises fivefold, not per model window;
    /// a smaller window is handled by the helper's retry on "too long".
    static let answerAbove = 80_000
    static let trimAbove = 60_000

    public private(set) var turns: [Turn] = []
    /// The snapshot this conversation reads; nil before the first question.
    public private(set) var snapshot: AISnapshot?

    @ObservationIgnored private let access: AIAccess
    @ObservationIgnored let run: AIRun

    public init(
        helper: @escaping @MainActor () throws -> AIHelper? = { try AIHelper.shared() },
        settings: @escaping @MainActor () -> AIProviderSettings = { AIProviderSettings.load() },
        apiKey: @escaping @MainActor () -> String? = { AIKeychain.read() },
        hasKey: (@MainActor () -> Bool)? = nil,
        consent: AIConsentStore = AIConsentStore()
    ) {
        access = AIAccess(settings: settings, apiKey: apiKey, hasKey: hasKey ?? { AIKeychain.exists() }, consent: consent)
        run = AIRun(helper: helper, tools: AITools.specs, maxRounds: Self.maxRounds,
                    answerAbove: Self.answerAbove, trimAbove: Self.trimAbove)
        run.update = { [weak self] in self?.apply($0) }
    }

    public var isRunning: Bool { turns.last?.state.isRunning ?? false }

    /// What stops a question about `project` now, if anything.
    public func blocker(project: URL?) -> Blocker? {
        access.blocker(project: snapshot?.root ?? project, helperConnected: run.connectedHelper != nil)
    }

    public func allowSending(project: URL) {
        access.allow(project)
    }

    /// Starts a new conversation on `snapshot` when there is none, then asks.
    /// The caller checks `blocker` first.
    public func ask(_ question: String, about selection: Selection? = nil,
                    snapshot newSnapshot: @autoclosure () -> AISnapshot?) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        cancel()
        if !run.hasConversation || snapshot == nil {
            guard let fresh = newSnapshot() else { return }
            snapshot = fresh
        }
        turns.append(Turn(id: turns.count, question: question, selection: selection, startedAt: Date()))
        run.ask(selection.map { $0.prompt + "\n\n" + question } ?? question,
                in: snapshot!, system: systemPrompt(), config: access.helperConfig)
    }

    public func cancel() {
        guard run.cancel(), let last = turns.indices.last else { return }
        turns[last].state = .cancelled
        turns[last].runningStep = nil
        turns[last].elapsed = Date().timeIntervalSince(turns[last].startedAt)
    }

    /// Forgets the conversation; the next question starts a new one on the
    /// snapshot showing then.
    public func reset() {
        cancel()
        run.reset()
        turns = []
        snapshot = nil
    }

    private func apply(_ update: AIRun.Update) {
        guard let last = turns.indices.last else { return }
        switch update {
        case .text(let delta):
            turns[last].answer += delta
            if !delta.isEmpty { turns[last].state = .answering }
        case .tools:
            // Text before tool calls is the model thinking aloud, not the answer.
            turns[last].answer = ""
            turns[last].state = .working
        case .stepStarted(let step):
            turns[last].runningStep = step
        case .stepFinished(let step, let evidence):
            turns[last].runningStep = nil
            turns[last].steps.append(step)
            for item in evidence where !turns[last].evidence.contains(where: {
                $0.path == item.path && $0.startLine == item.startLine && $0.endLine == item.endLine
            }) {
                turns[last].evidence.append(item)
            }
        case .done(let outputTokens):
            turns[last].state = .done
            turns[last].outputTokens = outputTokens
            turns[last].elapsed = Date().timeIntervalSince(turns[last].startedAt)
        case .submitted:
            break  // Asking has no terminal tool.
        case .failed(let message):
            turns[last].state = .failed(message)
            turns[last].runningStep = nil
            turns[last].elapsed = Date().timeIntervalSince(turns[last].startedAt)
        }
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
