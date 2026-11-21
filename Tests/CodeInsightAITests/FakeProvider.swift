import Foundation
import Network

/// A local HTTP endpoint that replays recorded provider streams in order and
/// keeps every request it received.
final class FakeProvider: @unchecked Sendable {
    struct Reply {
        let body: String
        /// Send only this many SSE events, then keep the connection open.
        var hangAfterEvents: Int? = nil
        var contentType = "text/event-stream"
        var status = "200 OK"
    }

    struct Received {
        let head: String
        let body: Data
        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-provider")
    private let lock = NSLock()
    private var replies: [Reply]
    private var received: [Received] = []
    private var open: [NWConnection] = []

    init(replies: [Reply]) throws {
        self.replies = replies
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
    }

    var port: UInt16 { listener.port?.rawValue ?? 0 }

    var requests: [Received] { lock.withLock { received } }

    func enqueue(_ reply: Reply) { lock.withLock { replies.append(reply) } }

    func stop() {
        listener.cancel()
        for connection in lock.withLock({ open }) { connection.cancel() }
    }

    static func fixture(_ name: String) -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name).sse")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func accept(_ connection: NWConnection) {
        lock.withLock { open.append(connection) }
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                let length = head.split(separator: "\r\n")
                    .first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                let body = buffer[end.upperBound...]
                if body.count >= length {
                    self.respond(connection, Received(head: head, body: Data(body.prefix(length))))
                    return
                }
            }
            if done || error != nil { connection.cancel(); return }
            self.read(connection, buffer: buffer)
        }
    }

    private func respond(_ connection: NWConnection, _ request: Received) {
        let reply = lock.withLock { () -> Reply? in
            received.append(request)
            return replies.isEmpty ? nil : replies.removeFirst()
        }
        guard let reply else {
            let missing = "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(missing.utf8), completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        let head = "HTTP/1.1 \(reply.status)\r\nContent-Type: \(reply.contentType)\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        var events = reply.body.components(separatedBy: "\n\n").filter { !$0.isEmpty }.map { $0 + "\n\n" }
        if let hang = reply.hangAfterEvents { events = Array(events.prefix(hang)) }
        connection.send(content: Data(head.utf8), completion: .idempotent)
        for event in events {
            connection.send(content: Data(event.utf8), completion: .idempotent)
        }
        if reply.hangAfterEvents == nil {
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
