import CProcessGuard
import Foundation

/// What the helper reports about one conversation.
public enum AIHelperEvent: Sendable {
    case text(String)
    case reasoning(String)
    /// `inputTokens`: what the round sent, history included.
    case toolCalls([AIToolCall], inputTokens: Int)
    case done(inputTokens: Int, outputTokens: Int)
    /// The answer to a model list request.
    case models([String])
    case failed(String)
}

/// The `cairn-ai` helper process: one per app, started on the first question.
/// Lines of JSON go in on stdin and come back on stdout (the protocol is
/// described in Helpers/cairn-ai/src/main.rs). If it exits, every waiting
/// conversation fails and the next question starts a new one.
public final class AIHelper: @unchecked Sendable {
    private let process = Process()
    private let input: FileHandle
    private let lock = NSLock()
    private var handlers: [String: @Sendable (Int, AIHelperEvent) -> Void] = [:]
    private var buffer = Data()
    private var exited = false

    public init(executable: URL) throws {
        let stdin = Pipe()
        let stdout = Pipe()
        process.executableURL = executable
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        // Only what the helper needs: no inherited secrets, proxies kept.
        let inherited = ProcessInfo.processInfo.environment
        process.environment = inherited.filter { key, _ in
            ["PATH", "HOME", "TMPDIR", "LANG"].contains(key) || key.lowercased().hasSuffix("_proxy")
        }
        input = stdin.fileHandleForWriting
        guard fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1) != -1, ci_process_guard_install() else {
            throw CocoaError(.executableLoad)
        }
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                self.terminated()
            } else {
                self.received(data)
            }
        }
        process.terminationHandler = { [weak self] _ in self?.terminated() }
        try process.run()
        ci_process_guard_register(process.processIdentifier, false)
    }

    deinit {
        try? input.close()
        if process.isRunning { process.terminate() }
        ci_process_guard_unregister(process.processIdentifier)
    }

    var processIdentifier: Int32 { process.processIdentifier }

    public var isRunning: Bool {
        lock.withLock { !exited }
    }

    /// Routes this conversation's events to `handler` with the round they
    /// belong to (-1 when the helper itself stopped), replacing any earlier one.
    public func observe(_ conversation: String, _ handler: @escaping @Sendable (Int, AIHelperEvent) -> Void) {
        let deliverExit = lock.withLock { () -> Bool in
            handlers[conversation] = handler
            return exited
        }
        if deliverExit { handler(-1, .failed(AIHelper.exitedMessage)) }
    }

    public func forget(_ conversation: String) {
        _ = lock.withLock { handlers.removeValue(forKey: conversation) }
        send(["type": "close", "conversation": conversation])
    }

    public func send(_ request: [String: Any]) {
        guard var line = try? JSONSerialization.data(withJSONObject: request) else { return }
        line.append(0x0A)
        let failed = lock.withLock { () -> Bool in
            guard !exited else { return true }
            do { try input.write(contentsOf: line) } catch { return true }
            return false
        }
        if failed, let conversation = request["conversation"] as? String {
            lock.withLock { handlers[conversation] }?(-1, .failed(AIHelper.exitedMessage))
        }
    }

    public static let exitedMessage = "The AI helper stopped."

    private func received(_ data: Data) {
        var lines: [Data] = []
        lock.withLock {
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                lines.append(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
            }
        }
        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let conversation = object["conversation"] as? String,
                  let event = Self.event(object)
            else { continue }
            let round = (object["round"] as? NSNumber)?.intValue ?? 0
            lock.withLock { handlers[conversation] }?(round, event)
        }
    }

    static func event(_ object: [String: Any]) -> AIHelperEvent? {
        switch object["type"] as? String {
        case "text": return .text(object["delta"] as? String ?? "")
        case "reasoning": return .reasoning(object["delta"] as? String ?? "")
        case "done":
            return .done(
                inputTokens: (object["input_tokens"] as? NSNumber)?.intValue ?? 0,
                outputTokens: (object["output_tokens"] as? NSNumber)?.intValue ?? 0)
        case "error": return .failed(object["message"] as? String ?? "")
        case "models": return .models(object["models"] as? [String] ?? [])
        case "tool_calls":
            let calls = (object["calls"] as? [[String: Any]] ?? []).compactMap { call -> AIToolCall? in
                guard let id = call["call_id"] as? String, let name = call["name"] as? String else { return nil }
                let arguments = call["arguments"].flatMap {
                    JSONSerialization.isValidJSONObject($0) ? try? JSONSerialization.data(withJSONObject: $0) : nil
                } ?? Data("{}".utf8)
                return AIToolCall(callID: id, name: name, arguments: arguments)
            }
            return .toolCalls(calls, inputTokens: (object["input_tokens"] as? NSNumber)?.intValue ?? 0)
        default: return nil
        }
    }

    private func terminated() {
        let waiting = lock.withLock { () -> [@Sendable (Int, AIHelperEvent) -> Void] in
            guard !exited else { return [] }
            exited = true
            return Array(handlers.values)
        }
        for handler in waiting { handler(-1, .failed(AIHelper.exitedMessage)) }
    }

    // MARK: Finding and sharing the helper

    /// In Cairn.app the helper sits in Contents/Helpers; in a `swift run`
    /// build, scripts/build-ai-helper.sh leaves it in .build/cairn-ai.
    public static func locate(bundle: Bundle = .main) -> URL? {
        let fileManager = FileManager.default
        let bundled = bundle.bundleURL.appendingPathComponent("Contents/Helpers/cairn-ai")
        if fileManager.isExecutableFile(atPath: bundled.path) { return bundled }
        var directory = bundle.executableURL?.deletingLastPathComponent()
        while let current = directory, current.pathComponents.count > 1 {
            if current.lastPathComponent == ".build" {
                let built = current.appendingPathComponent("cairn-ai/release/cairn-ai")
                return fileManager.isExecutableFile(atPath: built.path) ? built : nil
            }
            directory = current.deletingLastPathComponent()
        }
        return nil
    }

    @MainActor private static var current: AIHelper?

    /// The running helper, started if needed; nil when it cannot be found.
    @MainActor
    public static func shared() throws -> AIHelper? {
        if let current, current.isRunning { return current }
        guard let executable = locate() else { return nil }
        let helper = try AIHelper(executable: executable)
        current = helper
        return helper
    }
}
