import Darwin
import Foundation

public enum LSPError: Error, LocalizedError {
    case invalidFrame(String)
    case invalidMessage
    case requestFailed(String)
    case timeout(String)
    case processExited(Int32, String)

    public var errorDescription: String? {
        switch self {
        case .invalidFrame(let detail): "invalid LSP frame: \(detail)"
        case .invalidMessage: "LSP message is not a JSON object"
        case .requestFailed(let detail): "LSP request failed: \(detail)"
        case .timeout(let method): "LSP request timed out: \(method)"
        case .processExited(let status, let stderr): "LSP process exited (\(status)): \(stderr)"
        }
    }
}

public enum LSPFraming {
    public static func encode(_ message: [String: Any]) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
        var frame = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        frame.append(body)
        return frame
    }
}

public struct LSPFrameDecoder {
    private var buffer = Data()
    private static let separator = Data([13, 10, 13, 10])

    public init() {}

    public mutating func append<D: DataProtocol>(_ bytes: D) throws -> [[String: Any]] {
        buffer.append(contentsOf: bytes)
        var messages: [[String: Any]] = []

        while let headerRange = buffer.range(of: Self.separator) {
            guard let header = String(data: buffer[..<headerRange.lowerBound], encoding: .ascii) else {
                throw LSPError.invalidFrame("header is not ASCII")
            }
            guard let lengthLine = header
                .components(separatedBy: "\r\n")
                .first(where: { $0.lowercased().hasPrefix("content-length:") }),
                let length = Int(lengthLine.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces))
            else {
                throw LSPError.invalidFrame("missing Content-Length")
            }

            let bodyStart = headerRange.upperBound
            guard buffer.count >= bodyStart + length else { break }
            let body = buffer[bodyStart..<(bodyStart + length)]
            guard let message = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                throw LSPError.invalidMessage
            }
            messages.append(message)
            buffer.removeSubrange(..<(bodyStart + length))
        }
        return messages
    }
}

public final class LSPClient: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let condition = NSCondition()
    private let writeLock = NSLock()
    private var decoder = LSPFrameDecoder()
    private var nextID = 1
    private var responses: [Int: [String: Any]] = [:]
    private var stderr = Data()
    private var readError: Error?
    public private(set) var didForceKill = false

    public var isRunning: Bool { process.isRunning }

    public init(executable: String, arguments: [String] = [], workingDirectory: URL? = nil) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.receive(data)
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            condition.lock()
            stderr.append(data)
            condition.unlock()
        }
        process.terminationHandler = { [weak self] _ in
            self?.condition.lock()
            self?.condition.broadcast()
            self?.condition.unlock()
        }
        try process.run()
    }

    public func notify(_ method: String, params: Any? = nil) throws {
        var message: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { message["params"] = params }
        try send(message)
    }

    public func request(_ method: String, params: Any? = nil, timeout: TimeInterval = 20) throws -> Any {
        condition.lock()
        let id = nextID
        nextID += 1
        condition.unlock()

        var message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { message["params"] = params }
        try send(message)

        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while responses[id] == nil, readError == nil, process.isRunning, condition.wait(until: deadline) {}

        if let response = responses.removeValue(forKey: id) {
            if let error = response["error"] {
                throw LSPError.requestFailed(String(describing: error))
            }
            return response["result"] ?? NSNull()
        }
        if let readError { throw readError }
        if !process.isRunning {
            let detail = String(data: stderr, encoding: .utf8) ?? ""
            throw LSPError.processExited(process.terminationStatus, detail)
        }
        throw LSPError.timeout(method)
    }

    public func close(grace: TimeInterval = 2) {
        guard process.isRunning else {
            releaseHandles()
            return
        }
        _ = try? request("shutdown", timeout: grace)
        try? notify("exit")
        if waitForExit(grace) {
            releaseHandles()
            return
        }

        process.terminate()
        if !waitForExit(min(grace, 0.25)) {
            didForceKill = true
            Darwin.kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        releaseHandles()
    }

    deinit {
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
        releaseHandles()
    }

    private func send(_ message: [String: Any]) throws {
        let data = try LSPFraming.encode(message)
        writeLock.lock()
        defer { writeLock.unlock() }
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    private func receive(_ data: Data) {
        condition.lock()
        do {
            for message in try decoder.append(data) {
                if message["method"] != nil, let id = message["id"] {
                    respondToServerRequest(id: id, method: message["method"] as? String ?? "", params: message["params"])
                } else if let id = (message["id"] as? NSNumber)?.intValue {
                    responses[id] = message
                }
            }
        } catch {
            readError = error
        }
        condition.broadcast()
        condition.unlock()
    }

    private func respondToServerRequest(id: Any, method: String, params: Any?) {
        let result: Any
        if method == "workspace/configuration",
           let dictionary = params as? [String: Any],
           let items = dictionary["items"] as? [Any] {
            result = items.map { _ in NSNull() }
        } else {
            result = NSNull()
        }
        try? send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func waitForExit(_ seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        return !process.isRunning
    }

    private func releaseHandles() {
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
        try? errors.fileHandleForReading.close()
    }
}
