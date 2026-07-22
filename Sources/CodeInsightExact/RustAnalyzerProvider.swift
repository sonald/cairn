import CodeInsightCore
import CodeInsightGit
import Foundation

public final class RustAnalyzerProvider: ExactProvider, @unchecked Sendable {
    public let capabilities: ExactCapabilities = [.definition]
    public let toolVersion: String

    private let projectURL: URL
    private let executableURL: URL
    private let cacheURL: URL
    private let requestTimeout: TimeInterval
    private let closeGrace: TimeInterval

    public init(
        projectURL: URL,
        executableURL: URL,
        cacheURL: URL? = nil,
        requestTimeout: TimeInterval = 30,
        closeGrace: TimeInterval = 1
    ) throws {
        self.projectURL = projectURL.standardizedFileURL
        self.executableURL = executableURL.standardizedFileURL
        self.cacheURL = cacheURL ?? Self.defaultCacheURL
        self.requestTimeout = requestTimeout
        self.closeGrace = closeGrace
        toolVersion = try Self.readToolVersion(
            executableURL: executableURL,
            projectURL: projectURL,
            cacheURL: self.cacheURL
        )
    }

    public static func findExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        for directory in environment["PATH", default: ""]
            .split(separator: ":", omittingEmptySubsequences: false)
        {
            let root = directory.isEmpty ? "." : String(directory)
            let candidate = URL(fileURLWithPath: root, isDirectory: true)
                .appendingPathComponent("rust-analyzer")
                .standardizedFileURL
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    public func prepare(
        snapshot: any Snapshot,
        profile: ExactProfileKey,
        trustMode: TrustMode
    ) throws -> any ExactSession {
        let options: [String: Any]
        let coverage: ExactCoverage
        switch trustMode {
        case .safe:
            options = [
                "cargo": ["buildScripts": ["enable": false]],
                "procMacro": ["enable": false],
                "checkOnSave": false,
            ]
            coverage = .partial
        case .trusted:
            options = [:]
            coverage = .full
        }

        let launch = try Sandbox(
            projectURL: projectURL,
            cacheURL: cacheURL,
            trustMode: trustMode,
            helperURL: executableURL
        )
        let client = try LSPClient(
            executableURL: launch.executableURL,
            arguments: launch.arguments,
            workingDirectory: launch.workingDirectoryURL,
            environment: launch.environment
        )
        let session = RustAnalyzerSession(
            client: client,
            launch: launch,
            projectURL: projectURL,
            snapshot: snapshot,
            initializationOptions: options,
            requestTimeout: requestTimeout,
            closeGrace: closeGrace,
            attribution: ExactAttribution(
                provider: "rust-analyzer",
                toolVersion: toolVersion,
                configFingerprint: profile.configFingerprint,
                environmentFingerprint: profile.environmentFingerprint,
                trustMode: trustMode,
                generatedAt: Date(),
                coverage: coverage
            )
        )
        do {
            try session.start()
            return session
        } catch {
            client.close(grace: closeGrace)
            throw error
        }
    }

    private static var defaultCacheURL: URL {
        let root = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches", isDirectory: true)
        return root.appendingPathComponent(
            "CodeInsight/Exact",
            isDirectory: true
        )
    }

    private static func readToolVersion(
        executableURL: URL,
        projectURL: URL,
        cacheURL: URL
    ) throws -> String {
        let launch = try Sandbox(
            projectURL: projectURL,
            cacheURL: cacheURL,
            trustMode: .safe,
            helperURL: executableURL,
            helperArguments: ["--version"]
        )
        let process = Process()
        let pipe = Pipe()
        process.executableURL = launch.executableURL
        process.arguments = launch.arguments
        process.currentDirectoryURL = launch.workingDirectoryURL
        process.environment = launch.environment
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw ExactError.unavailable(
                "rust-analyzer --version exited \(process.terminationStatus)"
            )
        }
        let version = String(data: output, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return version.isEmpty ? "unknown" : version
    }
}

private final class RustAnalyzerSession: ExactSession, @unchecked Sendable {
    let attribution: ExactAttribution

    private let stateLock = NSLock()
    private let operationLock = NSLock()
    private let launch: Sandbox
    private let projectURL: URL
    private let snapshot: any Snapshot
    private let initializationOptions: [String: Any]
    private let requestTimeout: TimeInterval
    private let closeGrace: TimeInterval
    private var client: LSPClient
    private var state: ExactReadiness = .preparing
    private var openedFiles: Set<String> = []
    private var cancelled = false
    private var didRestart = false

    var readiness: ExactReadiness {
        stateLock.lock()
        defer { stateLock.unlock() }
        return state
    }

    init(
        client: LSPClient,
        launch: Sandbox,
        projectURL: URL,
        snapshot: any Snapshot,
        initializationOptions: [String: Any],
        requestTimeout: TimeInterval,
        closeGrace: TimeInterval,
        attribution: ExactAttribution
    ) {
        self.client = client
        self.launch = launch
        self.projectURL = projectURL
        self.snapshot = snapshot
        self.initializationOptions = initializationOptions
        self.requestTimeout = requestTimeout
        self.closeGrace = closeGrace
        self.attribution = attribution
        observe(client)
    }

    func start() throws {
        _ = try client.initialize(
            rootURL: projectURL,
            initializationOptions: initializationOptions,
            timeout: requestTimeout
        )
    }

    func definition(file: String, byteOffset: Int) throws -> ExactLocation? {
        operationLock.lock()
        defer { operationLock.unlock() }

        stateLock.lock()
        cancelled = false
        stateLock.unlock()
        var activeClient = try clientForRequest()
        let path = try relativePath(file)
        let bytes = try snapshot.readBytes(path: path)
        guard let map = LSPPositionMap(utf8: bytes) else {
            throw ExactError.invalidUTF8(path)
        }
        guard let position = map.position(forByteOffset: byteOffset) else {
            throw ExactError.invalidPosition(path, byteOffset)
        }

        var retriedAfterCrash = false
        while true {
            do {
                try open(
                    path: path,
                    bytes: bytes,
                    client: activeClient
                )
                for attempt in 0..<3 {
                    try throwIfCancelled()
                    do {
                        let response = try activeClient.request(
                            "textDocument/definition",
                            params: [
                                "textDocument": [
                                    "uri": projectURL.appendingPathComponent(path)
                                        .absoluteString,
                                ],
                                "position": [
                                    "line": position.line,
                                    "character": position.character,
                                ],
                            ],
                            timeout: requestTimeout
                        )
                        if let location = try parseDefinition(response) {
                            markReady()
                            return location
                        }
                        markPreparing()
                    } catch LSPError.requestFailed(let code, _)
                        where code == -32801 && attempt < 2
                    {
                        // rust-analyzer reports content-modified while its
                        // workspace snapshot catches up.
                        markPreparing()
                    }
                    guard attempt < 2 else {
                        markReady()
                        return nil
                    }
                    Thread.sleep(
                        forTimeInterval: Double(attempt + 1)
                    )
                }
                return nil
            } catch LSPError.processExited where !retriedAfterCrash {
                activeClient = try restartAfterCrash()
                retriedAfterCrash = true
            } catch LSPError.connectionClosed where !retriedAfterCrash {
                activeClient = try restartAfterCrash()
                retriedAfterCrash = true
            }
        }
    }

    func cancel() {
        stateLock.lock()
        cancelled = true
        let activeClient = client
        stateLock.unlock()
        activeClient.cancelOutstandingRequests()
    }

    func close() {
        stateLock.lock()
        guard state != .closed else {
            stateLock.unlock()
            return
        }
        state = .closed
        cancelled = true
        let activeClient = client
        stateLock.unlock()
        activeClient.cancelOutstandingRequests()
        activeClient.close(grace: closeGrace)
    }

    deinit {
        close()
    }

    private func clientForRequest() throws -> LSPClient {
        stateLock.lock()
        let currentState = state
        let activeClient = client
        let canRestart = !didRestart
        stateLock.unlock()
        switch currentState {
        case .preparing, .ready:
            return activeClient
        case .unavailable where canRestart:
            return try restartAfterCrash()
        case .unavailable(let reason):
            throw ExactError.unavailable(reason)
        case .closed:
            throw ExactError.unavailable("session is closed")
        }
    }

    private func restartAfterCrash() throws -> LSPClient {
        stateLock.lock()
        guard state != .closed, !didRestart else {
            let reason = state == .closed
                ? "session is closed" : "rust-analyzer restart exhausted"
            stateLock.unlock()
            throw ExactError.unavailable(reason)
        }
        didRestart = true
        state = .preparing
        let oldClient = client
        stateLock.unlock()

        oldClient.close(grace: closeGrace)
        Thread.sleep(forTimeInterval: 0.1)
        let newClient = try LSPClient(
            executableURL: launch.executableURL,
            arguments: launch.arguments,
            workingDirectory: launch.workingDirectoryURL,
            environment: launch.environment
        )
        stateLock.lock()
        guard state != .closed else {
            stateLock.unlock()
            newClient.close(grace: closeGrace)
            throw ExactError.unavailable("session is closed")
        }
        client = newClient
        openedFiles.removeAll()
        stateLock.unlock()
        observe(newClient)
        do {
            _ = try newClient.initialize(
                rootURL: projectURL,
                initializationOptions: initializationOptions,
                timeout: requestTimeout
            )
        } catch {
            newClient.close(grace: closeGrace)
            stateLock.lock()
            if state != .closed {
                state = .unavailable("rust-analyzer restart failed: \(error)")
            }
            stateLock.unlock()
            throw error
        }

        stateLock.lock()
        guard state != .closed else {
            stateLock.unlock()
            newClient.close(grace: closeGrace)
            throw ExactError.unavailable("session is closed")
        }
        stateLock.unlock()
        return newClient
    }

    private func observe(_ observedClient: LSPClient) {
        observedClient.observeTermination { [weak self, weak observedClient] status in
            guard let self, let observedClient else { return }
            stateLock.lock()
            if state != .closed, client === observedClient {
                state = .unavailable("rust-analyzer exited (\(status))")
            }
            stateLock.unlock()
        }
    }

    private func open(
        path: String,
        bytes: [UInt8],
        client: LSPClient
    ) throws {
        if openedFiles.insert(path).inserted {
            guard let text = String(data: Data(bytes), encoding: .utf8) else {
                throw ExactError.invalidUTF8(path)
            }
            try client.notify("textDocument/didOpen", params: [
                "textDocument": [
                    "uri": projectURL.appendingPathComponent(path).absoluteString,
                    "languageId": "rust",
                    "version": 1,
                    "text": text,
                ],
            ])
        }
    }

    private func parseDefinition(_ value: Any) throws -> ExactLocation? {
        if value is NSNull { return nil }
        let object: [String: Any]
        if let dictionary = value as? [String: Any] {
            object = dictionary
        } else if let array = value as? [[String: Any]] {
            guard let first = array.first else { return nil }
            object = first
        } else {
            throw ExactError.invalidDefinitionResponse(String(describing: value))
        }

        guard let uri = (object["targetUri"] ?? object["uri"]) as? String,
              let range = (object["targetSelectionRange"] ?? object["range"])
                as? [String: Any],
              let start = range["start"] as? [String: Any],
              let line = (start["line"] as? NSNumber)?.intValue,
              let character = (start["character"] as? NSNumber)?.intValue,
              let url = URL(string: uri), url.isFileURL
        else {
            throw ExactError.invalidDefinitionResponse(String(describing: object))
        }

        let targetURL = url.standardizedFileURL
        let relative = projectRelativePath(of: targetURL)
        let bytes: [UInt8]
        if let relative, let captured = try? snapshot.readBytes(path: relative) {
            bytes = captured
        } else {
            bytes = [UInt8](try Data(contentsOf: targetURL, options: .mappedIfSafe))
        }
        guard let map = LSPPositionMap(utf8: bytes) else {
            throw ExactError.invalidUTF8(targetURL.path)
        }
        guard let byteOffset = map.byteOffset(
            for: LSPPosition(line: line, character: character)
        ), let coordinate = map.lineAndByteColumn(at: byteOffset) else {
            throw ExactError.invalidDefinitionResponse(
                "position \(line):\(character) is outside \(targetURL.path)"
            )
        }
        return ExactLocation(
            file: relative ?? targetURL.path,
            byteOffset: byteOffset,
            line: coordinate.line,
            column: coordinate.column
        )
    }

    private func relativePath(_ input: String) throws -> String {
        let candidate = input.hasPrefix("/")
            ? URL(fileURLWithPath: input)
            : projectURL.appendingPathComponent(input)
        guard let relative = projectRelativePath(of: candidate.standardizedFileURL),
              !relative.isEmpty
        else { throw ExactError.invalidPath(input) }
        return relative
    }

    private func projectRelativePath(of url: URL) -> String? {
        let rootComponents = projectURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard components.starts(with: rootComponents) else { return nil }
        return components.dropFirst(rootComponents.count).joined(separator: "/")
    }

    private func throwIfCancelled() throws {
        stateLock.lock()
        let wasCancelled = cancelled
        stateLock.unlock()
        if wasCancelled { throw LSPError.cancelled("textDocument/definition") }
    }

    private func markPreparing() {
        stateLock.lock()
        if state == .preparing || state == .ready { state = .preparing }
        stateLock.unlock()
    }

    private func markReady() {
        stateLock.lock()
        if state == .preparing || state == .ready { state = .ready }
        stateLock.unlock()
    }
}
