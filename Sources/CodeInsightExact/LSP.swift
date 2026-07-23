import CProcessGuard
import Darwin
import Foundation

public enum LSPError: Error, LocalizedError {
    case invalidFrame(String)
    case invalidMessage
    case requestFailed(code: Int?, message: String)
    case timeout(String)
    case cancelled(String)
    case connectionClosed
    case childProcessGuardUnavailable
    case processExited(Int32, String)

    public var errorDescription: String? {
        switch self {
        case .invalidFrame(let detail): "invalid LSP frame: \(detail)"
        case .invalidMessage: "LSP message is not a JSON object"
        case let .requestFailed(code, message):
            "LSP request failed\(code.map { " (\($0))" } ?? ""): \(message)"
        case .timeout(let method): "LSP request timed out: \(method)"
        case .cancelled(let method): "LSP request cancelled: \(method)"
        case .connectionClosed: "LSP connection closed"
        case .childProcessGuardUnavailable:
            "LSP child process crash guard unavailable"
        case let .processExited(status, stderr):
            "LSP process exited (\(status)): \(stderr)"
        }
    }
}

public enum LSPFraming {
    public static func encode(_ message: [String: Any]) throws -> Data {
        let body = try JSONSerialization.data(
            withJSONObject: message,
            options: [.sortedKeys]
        )
        var frame = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        frame.append(body)
        return frame
    }
}

public struct LSPFrameDecoder {
    private static let separator = Data([13, 10, 13, 10])
    private var buffer = Data()

    public init() {}

    public mutating func append<D: DataProtocol>(
        _ bytes: D
    ) throws -> [[String: Any]] {
        buffer.append(contentsOf: bytes)
        var messages: [[String: Any]] = []

        while let headerRange = buffer.range(of: Self.separator) {
            guard let header = String(
                data: buffer[..<headerRange.lowerBound],
                encoding: .ascii
            ) else {
                throw LSPError.invalidFrame("header is not ASCII")
            }
            let contentLength = header.components(separatedBy: "\r\n")
                .compactMap { line -> Int? in
                    let parts = line.split(
                        separator: ":",
                        maxSplits: 1,
                        omittingEmptySubsequences: false
                    )
                    guard parts.count == 2,
                          parts[0].trimmingCharacters(in: .whitespaces)
                            .lowercased() == "content-length"
                    else { return nil }
                    return Int(parts[1].trimmingCharacters(in: .whitespaces))
                }
                .first
            guard let contentLength, contentLength >= 0 else {
                throw LSPError.invalidFrame("missing or invalid Content-Length")
            }

            let bodyStart = headerRange.upperBound
            guard contentLength <= Int.max - bodyStart else {
                throw LSPError.invalidFrame("Content-Length overflow")
            }
            let bodyEnd = bodyStart + contentLength
            guard buffer.count >= bodyEnd else { break }
            let body = buffer[bodyStart..<bodyEnd]
            guard String(data: body, encoding: .utf8) != nil else {
                throw LSPError.invalidFrame("body is not UTF-8")
            }
            guard let message = try JSONSerialization.jsonObject(with: body)
                as? [String: Any]
            else {
                throw LSPError.invalidMessage
            }
            messages.append(message)
            buffer.removeSubrange(..<bodyEnd)
        }
        return messages
    }
}

public final class LSPClient: @unchecked Sendable {
    private let process: Process?
    private let inputHandle: FileHandle
    private let outputHandle: FileHandle
    private let errorHandle: FileHandle?
    private let condition = NSCondition()
    private let writeLock = NSLock()
    private var decoder = LSPFrameDecoder()
    private var nextID = 1
    private var pendingRequestIDs: Set<Int> = []
    private var cancelledRequestIDs: Set<Int> = []
    private var responses: [Int: [String: Any]] = [:]
    private var stderr = Data()
    private var serverDiagnostics = ""
    private var readError: Error?
    private var reachedEOF = false
    private var closed = false
    private var closing = false
    private var handlesReleased = false
    private var terminationObserver: (@Sendable (Int32) -> Void)?
    private var diagnosticObserver: (@Sendable (String) -> Void)?

    public private(set) var didForceKill = false
    public private(set) var didReap = false

    public var isRunning: Bool {
        process?.isRunning ?? (!reachedEOF && !closed)
    }

    public var processIdentifier: Int32? {
        process?.processIdentifier
    }

    var diagnosticText: String {
        condition.lock()
        defer { condition.unlock() }
        return diagnosticTextLocked
    }

    private var diagnosticTextLocked: String {
        return (String(data: stderr, encoding: .utf8) ?? "")
            + serverDiagnostics
    }

    public init(
        executableURL: URL,
        arguments: [String] = [],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil
    ) throws {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        self.process = process
        inputHandle = input.fileHandleForWriting
        outputHandle = output.fileHandleForReading
        errorHandle = errors.fileHandleForReading
        guard ci_process_guard_install() else {
            releaseHandles()
            throw LSPError.childProcessGuardUnavailable
        }
        installHandlers()
        do {
            try process.run()
        } catch {
            releaseHandles()
            throw error
        }
        guard ci_process_guard_register(process.processIdentifier) else {
            Darwin.kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            releaseHandles()
            throw LSPError.childProcessGuardUnavailable
        }
        if !process.isRunning {
            ci_process_guard_unregister(process.processIdentifier)
        }
    }

    init(readHandle: FileHandle, writeHandle: FileHandle) {
        process = nil
        inputHandle = writeHandle
        outputHandle = readHandle
        errorHandle = nil
        installHandlers()
    }

    public func observeTermination(
        _ observer: @escaping @Sendable (Int32) -> Void
    ) {
        condition.lock()
        if let process, !process.isRunning {
            let status = process.terminationStatus
            condition.unlock()
            observer(status)
            return
        }
        terminationObserver = observer
        condition.unlock()
    }

    public func observeDiagnostics(
        _ observer: @escaping @Sendable (String) -> Void
    ) {
        condition.lock()
        diagnosticObserver = observer
        let diagnostic = diagnosticTextLocked
        condition.unlock()
        if !diagnostic.isEmpty { observer(diagnostic) }
    }

    @discardableResult
    public func initialize(
        rootURL: URL,
        initializationOptions: [String: Any] = [:],
        timeout: TimeInterval
    ) throws -> Any {
        let result = try request("initialize", params: [
            "processId": ProcessInfo.processInfo.processIdentifier,
            "clientInfo": ["name": "CodeInsight", "version": "4"],
            "rootUri": rootURL.absoluteString,
            "workspaceFolders": [[
                "uri": rootURL.absoluteString,
                "name": rootURL.lastPathComponent,
            ]],
            "capabilities": [
                "textDocument": ["definition": ["linkSupport": true]],
                "window": ["workDoneProgress": true],
                "workspace": ["configuration": true],
            ],
            "initializationOptions": initializationOptions,
            "trace": "off",
        ], timeout: timeout)
        try notify("initialized", params: [:])
        return result
    }

    public func notify(_ method: String, params: Any? = nil) throws {
        var message: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { message["params"] = params }
        try send(message)
    }

    public func request(
        _ method: String,
        params: Any? = nil,
        timeout: TimeInterval
    ) throws -> Any {
        condition.lock()
        guard !closed else {
            condition.unlock()
            throw LSPError.connectionClosed
        }
        let id = nextID
        nextID += 1
        pendingRequestIDs.insert(id)
        condition.unlock()

        var message: [String: Any] = [
            "jsonrpc": "2.0", "id": id, "method": method,
        ]
        if let params { message["params"] = params }
        do {
            try send(message)
        } catch {
            condition.lock()
            pendingRequestIDs.remove(id)
            condition.unlock()
            throw error
        }

        let deadline = Date().addingTimeInterval(max(0, timeout))
        condition.lock()
        defer {
            pendingRequestIDs.remove(id)
            cancelledRequestIDs.remove(id)
            responses.removeValue(forKey: id)
            condition.unlock()
        }
        while responses[id] == nil,
              !cancelledRequestIDs.contains(id),
              readError == nil,
              transportIsOpen,
              condition.wait(until: deadline)
        {}

        if let response = responses[id] {
            if let error = response["error"] as? [String: Any] {
                let code = (error["code"] as? NSNumber)?.intValue
                let message = error["message"] as? String
                    ?? String(describing: error)
                throw LSPError.requestFailed(code: code, message: message)
            }
            return response["result"] ?? NSNull()
        }
        if cancelledRequestIDs.contains(id) {
            throw LSPError.cancelled(method)
        }
        if let readError { throw readError }
        if let process, !process.isRunning {
            let detail = String(data: stderr, encoding: .utf8) ?? ""
            throw LSPError.processExited(process.terminationStatus, detail)
        }
        if reachedEOF { throw LSPError.connectionClosed }
        throw LSPError.timeout(method)
    }

    public func cancelOutstandingRequests() {
        condition.lock()
        let ids = Array(pendingRequestIDs)
        cancelledRequestIDs.formUnion(ids)
        condition.broadcast()
        condition.unlock()
        for id in ids {
            try? notify("$/cancelRequest", params: ["id": id])
        }
    }

    public func close(grace: TimeInterval = 1) {
        condition.lock()
        guard !closed, !closing else {
            condition.unlock()
            return
        }
        closing = true
        condition.unlock()

        cancelOutstandingRequests()
        let grace = max(0.01, grace)
        if process?.isRunning != false {
            _ = try? request("shutdown", timeout: grace)
            try? notify("exit")
        }

        if let process {
            if !waitForExit(grace) {
                process.terminate()
                if !waitForExit(grace) {
                    didForceKill = true
                    Darwin.kill(process.processIdentifier, SIGKILL)
                    process.waitUntilExit()
                    didReap = true
                }
            }
            ci_process_guard_unregister(process.processIdentifier)
        }
        finishClose()
    }

    deinit {
        outputHandle.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        if let process, process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        if let process {
            ci_process_guard_unregister(process.processIdentifier)
        }
        releaseHandles()
    }

    private var transportIsOpen: Bool {
        if let process { return process.isRunning }
        return !reachedEOF && !closed
    }

    private func installHandlers() {
        outputHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                condition.lock()
                reachedEOF = true
                condition.broadcast()
                condition.unlock()
            } else {
                receive(data)
            }
        }
        errorHandle?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            condition.lock()
            stderr.append(data)
            let observer = diagnosticObserver
            let diagnostic = diagnosticTextLocked
            condition.unlock()
            observer?(diagnostic)
        }
        process?.terminationHandler = { [weak self] process in
            ci_process_guard_unregister(process.processIdentifier)
            guard let self else { return }
            condition.lock()
            let observer = terminationObserver
            condition.broadcast()
            condition.unlock()
            observer?(process.terminationStatus)
        }
    }

    private func send(_ message: [String: Any]) throws {
        let data = try LSPFraming.encode(message)
        writeLock.lock()
        defer { writeLock.unlock() }
        try inputHandle.write(contentsOf: data)
    }

    private func receive(_ data: Data) {
        var serverRequests: [(id: Any, method: String, params: Any?)] = []
        var diagnosticsChanged = false
        condition.lock()
        do {
            for message in try decoder.append(data) {
                if let method = message["method"] as? String,
                   let id = message["id"]
                {
                    serverRequests.append((id, method, message["params"]))
                } else if let method = message["method"] as? String,
                          method == "window/showMessage"
                            || method == "window/logMessage"
                            || method.localizedCaseInsensitiveContains("status")
                {
                    serverDiagnostics += "\n\(method): \(String(describing: message["params"]))"
                    if serverDiagnostics.utf8.count > 65_536 {
                        serverDiagnostics = String(serverDiagnostics.suffix(32_768))
                    }
                    diagnosticsChanged = true
                } else if let id = (message["id"] as? NSNumber)?.intValue,
                          pendingRequestIDs.contains(id)
                {
                    responses[id] = message
                }
            }
        } catch {
            readError = error
        }
        let diagnosticObserver = diagnosticsChanged ? diagnosticObserver : nil
        let diagnostic = diagnosticsChanged ? diagnosticTextLocked : ""
        condition.broadcast()
        condition.unlock()

        diagnosticObserver?(diagnostic)
        for request in serverRequests {
            respondToServerRequest(
                id: request.id,
                method: request.method,
                params: request.params
            )
        }
    }

    private func respondToServerRequest(id: Any, method: String, params: Any?) {
        let result: Any
        switch method {
        case "workspace/configuration":
            let count = ((params as? [String: Any])?["items"] as? [Any])?.count
                ?? 0
            result = Array(repeating: NSNull(), count: count)
        case "workspace/workspaceFolders":
            result = []
        case "client/registerCapability", "window/workDoneProgress/create":
            result = NSNull()
        default:
            result = NSNull()
        }
        do {
            try send(["jsonrpc": "2.0", "id": id, "result": result])
        } catch {
            condition.lock()
            readError = error
            condition.broadcast()
            condition.unlock()
        }
    }

    private func waitForExit(_ seconds: TimeInterval) -> Bool {
        guard let process else { return true }
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard !process.isRunning else { return false }
        process.waitUntilExit()
        didReap = true
        return true
    }

    private func finishClose() {
        condition.lock()
        closed = true
        closing = false
        condition.broadcast()
        condition.unlock()
        releaseHandles()
    }

    private func releaseHandles() {
        condition.lock()
        guard !handlesReleased else {
            condition.unlock()
            return
        }
        handlesReleased = true
        condition.unlock()
        outputHandle.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        try? inputHandle.close()
        try? outputHandle.close()
        try? errorHandle?.close()
    }
}
