import CodeInsightCore
import CodeInsightGit
import Foundation

/// How a request turns into a result.
enum LSPRequestFlow {
    /// Pyright, TypeScript: one request per call; the parsed response,
    /// empty or not, is the answer.
    case direct
    /// rust-analyzer: before every attempt, wait outside the operation lock
    /// until the server reports quiescence (stops when the batch goes stale
    /// or the session is cancelled). Inside the lock, an empty result from a
    /// server that was not quiescent retries without using the retry budget;
    /// `-32801` (content modified) retries while fewer than two such retries
    /// have been used.
    case awaitQuiescence
}

/// How a warm switch learns the server took in `didChangeWatchedFiles`
/// (S0 measurements, docs/evidence/warm-lsp-switch-2026-10).
enum LSPSwitchReadiness {
    /// Wait up to `LSPLanguageSession.signalWindow` for `$/progress`
    /// `rustAnalyzer/Fetching` to begin, then for the next `serverStatus
    /// quiescent=true`. In the sandbox a source-only change starts no
    /// reload and answers are already right, so no Fetching means ready.
    case rustAnalyzer
    /// No progress at all: a source change is ready at once; a changed
    /// configuration is ready once "Reloading configuration file" is
    /// logged (earlier answers use the old configuration).
    case pyright
    /// Wait for "Initializing JS/TS language features" to end when it
    /// begins within the signal window; tsserver answers requests only
    /// after a project load it starts later.
    case typeScript
}

/// What differs between the language servers behind `LSPLanguageSession`.
/// Executable checks and launch configuration stay in each provider.
struct LSPLanguageSpec {
    /// Used verbatim in error text: "<name> restart exhausted",
    /// "<name> restart failed: …", "<name> exited (status)".
    var serverName: String
    /// Sent with every `initialize`, including after a restart.
    var initializationOptions: [String: Any] = [:]
    var requestFlow: LSPRequestFlow = .direct
    /// nil: a warm switch is ready as soon as the changes are sent.
    var switchReadiness: LSPSwitchReadiness?
    /// `initialize` result → negotiated capabilities.
    var capabilities: (Any) -> ExactCapabilities
    /// Runs after capability derivation; a throw closes the client and fails
    /// `start` with that error.
    var startupCheck: ((ExactCapabilities) throws -> Void)?
    /// Paths outside this language are rejected with `invalidPath` before
    /// they are read.
    var acceptsPath: (String) -> Bool = { _ in true }
    /// `languageId` sent with `textDocument/didOpen`.
    var languageID: (String) -> String
    /// When set, the session subscribes to server diagnostics and publishes
    /// the environment this returns for each one.
    var onDiagnostic: (@Sendable (
        _ base: ExactAnalysisEnvironment,
        _ diagnostic: String
    ) -> ExactAnalysisEnvironment)?
}

/// Capabilities the server's `initialize` result advertises, for the given
/// `<name>Provider` keys. A provider counts when it is `true` or an options
/// object.
func advertisedCapabilities(
    _ initializeResult: Any,
    _ providers: KeyValuePairs<String, ExactCapabilities>
) -> ExactCapabilities {
    var advertised: ExactCapabilities = []
    guard let result = initializeResult as? [String: Any],
          let capabilities = result["capabilities"] as? [String: Any]
    else { return advertised }
    for (key, capability) in providers {
        if let provider = capabilities[key],
           (provider as? Bool) == true || provider is [String: Any]
        {
            advertised.insert(capability)
        }
    }
    return advertised
}

final class LSPLanguageSession: ExactSession, @unchecked Sendable {
    let negotiatedCapabilities: ExactCapabilities

    var attribution: ExactAttribution {
        stateLock.lock()
        let environment = currentEnvironment
        stateLock.unlock()
        return ExactAttribution(
            provider: baseAttribution.provider,
            toolVersion: baseAttribution.toolVersion,
            configFingerprint: baseAttribution.configFingerprint,
            environmentFingerprint: baseAttribution.environmentFingerprint,
            featureSelection: baseAttribution.featureSelection,
            environment: environment,
            generatedAt: baseAttribution.generatedAt
        )
    }

    /// A switch waits for its readiness signal no longer than this; a
    /// server that is not ready by then is replaced (decision 9).
    static let switchReadyLimit: TimeInterval = 120
    /// rust-analyzer and tsserver start their reload within this after the
    /// notification (S0: 0.11–0.33 s), or not at all.
    static let signalWindow: TimeInterval = 1
    /// Pyright logs the configuration reload within 0.2 s (S0); without
    /// it the switch fails and a cold start (≈0.4 s) replaces the session.
    static let configReloadWindow: TimeInterval = 5

    /// A condition so requests can wait out a switch.
    private let stateLock = NSCondition()
    private let operationLock = NSLock()
    private let restartClient: @Sendable () throws -> LSPClient
    private let projectURL: URL
    /// Written only while both locks are held (a switch), so readers
    /// holding either one see a stable value.
    private var snapshot: any Snapshot
    private let language: LSPLanguageSpec
    private let requestTimeout: TimeInterval
    private let closeGrace: TimeInterval
    private var client: LSPClient
    private var state: ExactReadiness = .preparing
    private var openedFiles: Set<String> = []
    private var cancelled = false
    private var activeBatch: ExactRequestBatch?
    private var didRestart = false
    private var baseAttribution: ExactAttribution
    private var currentEnvironment: ExactAnalysisEnvironment
    private var environmentObserver: (@Sendable (ExactAnalysisEnvironment) -> Void)?
    /// True while a switch runs; requests wait before reading the snapshot.
    private var switching = false
    /// Advances with every switch; a request that read the snapshot under
    /// an older value is cancelled instead of opening stale bytes.
    private var switchGeneration: UInt64 = 0

    var processIdentifier: Int32? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return client.processIdentifier
    }

    var readiness: ExactReadiness {
        stateLock.lock()
        defer { stateLock.unlock() }
        if case .unavailable(let reason) = state {
            // Read at presentation time so diagnostics arriving after process exit
            // are included too.
            let diagnostic = client.diagnosticSummary
            if !diagnostic.isEmpty {
                return .unavailable(reason + "\n" + diagnostic)
            }
        }
        return state
    }

    var onEnvironmentChange: (@Sendable (ExactAnalysisEnvironment) -> Void)? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return environmentObserver
        }
        set {
            stateLock.lock()
            environmentObserver = newValue
            let environment = currentEnvironment
            stateLock.unlock()
            newValue?(environment)
        }
    }

    static func start(
        client: LSPClient,
        restartClient: @escaping @Sendable () throws -> LSPClient,
        projectURL: URL,
        snapshot: any Snapshot,
        language: LSPLanguageSpec,
        requestTimeout: TimeInterval,
        closeGrace: TimeInterval,
        attribution: ExactAttribution
    ) throws -> LSPLanguageSession {
        let initializeResult = try client.initialize(
            rootURL: projectURL,
            initializationOptions: language.initializationOptions,
            timeout: requestTimeout
        )
        let negotiated = language.capabilities(initializeResult)
        if let startupCheck = language.startupCheck {
            do {
                try startupCheck(negotiated)
            } catch {
                client.close(grace: closeGrace)
                throw error
            }
        }
        return LSPLanguageSession(
            client: client,
            restartClient: restartClient,
            negotiatedCapabilities: negotiated,
            projectURL: projectURL,
            snapshot: snapshot,
            language: language,
            requestTimeout: requestTimeout,
            closeGrace: closeGrace,
            attribution: attribution
        )
    }

    private init(
        client: LSPClient,
        restartClient: @escaping @Sendable () throws -> LSPClient,
        negotiatedCapabilities: ExactCapabilities,
        projectURL: URL,
        snapshot: any Snapshot,
        language: LSPLanguageSpec,
        requestTimeout: TimeInterval,
        closeGrace: TimeInterval,
        attribution: ExactAttribution
    ) {
        self.client = client
        self.restartClient = restartClient
        self.negotiatedCapabilities = negotiatedCapabilities
        self.projectURL = projectURL
        self.snapshot = snapshot
        self.language = language
        self.requestTimeout = requestTimeout
        self.closeGrace = closeGrace
        baseAttribution = attribution
        currentEnvironment = attribution.environment
        observe(client)
    }

    func definition(
        file: String,
        byteOffset: Int
    ) throws -> ExactDefinitionQueryResult {
        try requestLocations(
            file: file,
            byteOffset: byteOffset,
            method: "textDocument/definition",
            parse: parseDefinition
        ) ?? .cancelled
    }

    func definition(
        file: String,
        byteOffset: Int,
        batch: ExactRequestBatch
    ) throws -> ExactDefinitionQueryResult {
        try requestLocations(
            file: file,
            byteOffset: byteOffset,
            method: "textDocument/definition",
            batch: batch,
            parse: parseDefinition
        ) ?? .cancelled
    }

    func typeDefinition(
        file: String,
        byteOffset: Int
    ) throws -> ExactDefinitionQueryResult {
        try requestLocations(
            file: file,
            byteOffset: byteOffset,
            method: "textDocument/typeDefinition",
            parse: parseDefinition
        ) ?? .cancelled
    }

    func typeDefinition(
        file: String,
        byteOffset: Int,
        batch: ExactRequestBatch
    ) throws -> ExactDefinitionQueryResult {
        try requestLocations(
            file: file,
            byteOffset: byteOffset,
            method: "textDocument/typeDefinition",
            batch: batch,
            parse: parseDefinition
        ) ?? .cancelled
    }

    func implementations(
        file: String,
        byteOffset: Int
    ) throws -> [ExactLocation]? {
        guard negotiatedCapabilities.contains(.implementations) else {
            return nil
        }
        return try requestLocations(
            file: file,
            byteOffset: byteOffset,
            method: "textDocument/implementation",
            parse: parseLocations
        )
    }

    func implementations(
        file: String,
        byteOffset: Int,
        batch: ExactRequestBatch
    ) throws -> [ExactLocation]? {
        guard negotiatedCapabilities.contains(.implementations) else {
            return nil
        }
        return try requestLocations(
            file: file,
            byteOffset: byteOffset,
            method: "textDocument/implementation",
            batch: batch,
            parse: parseLocations
        )
    }

    func references(
        file: String,
        byteOffset: Int,
        includeDeclaration: Bool
    ) throws -> [ExactLocation]? {
        guard negotiatedCapabilities.contains(.references) else {
            return nil
        }
        return try requestLocations(
            file: file,
            byteOffset: byteOffset,
            method: "textDocument/references",
            includeDeclaration: includeDeclaration,
            parse: parseLocations
        )
    }

    func references(
        file: String,
        byteOffset: Int,
        includeDeclaration: Bool,
        batch: ExactRequestBatch
    ) throws -> [ExactLocation]? {
        guard negotiatedCapabilities.contains(.references) else {
            return nil
        }
        return try requestLocations(
            file: file,
            byteOffset: byteOffset,
            method: "textDocument/references",
            includeDeclaration: includeDeclaration,
            batch: batch,
            parse: parseLocations
        )
    }

    func hover(
        file: String,
        byteOffset: Int,
        batch: ExactRequestBatch
    ) throws -> ExactHoverQueryResult? {
        guard negotiatedCapabilities.contains(.hover) else { return nil }
        return try requestLocations(
            file: file,
            byteOffset: byteOffset,
            method: "textDocument/hover",
            batch: batch,
            parse: { ExactHoverQueryResult.completed(exactHoverMarkdown($0)) }
        ) ?? .cancelled
    }

    func prepareCallHierarchy(
        file: String,
        byteOffset: Int
    ) throws -> [ExactCallHierarchyItem]? {
        guard negotiatedCapabilities.contains(.callHierarchy) else {
            return nil
        }
        return try requestLocations(
            file: file,
            byteOffset: byteOffset,
            method: "textDocument/prepareCallHierarchy",
            parse: parseCallHierarchyItems
        )
    }

    func prepareCallHierarchy(
        file: String,
        byteOffset: Int,
        batch: ExactRequestBatch
    ) throws -> [ExactCallHierarchyItem]? {
        guard negotiatedCapabilities.contains(.callHierarchy) else {
            return nil
        }
        return try requestLocations(
            file: file,
            byteOffset: byteOffset,
            method: "textDocument/prepareCallHierarchy",
            batch: batch,
            parse: parseCallHierarchyItems
        )
    }

    func incomingCalls(
        item: ExactCallHierarchyItem
    ) throws -> [ExactCallRelation]? {
        guard negotiatedCapabilities.contains(.callHierarchy) else {
            return nil
        }
        return try requestCallRelations(
            item: item,
            method: "callHierarchy/incomingCalls",
            itemKey: "from",
            callSiteURI: { $0.uri }
        )
    }

    func incomingCalls(
        item: ExactCallHierarchyItem,
        batch: ExactRequestBatch
    ) throws -> [ExactCallRelation]? {
        guard negotiatedCapabilities.contains(.callHierarchy) else {
            return nil
        }
        return try requestCallRelations(
            item: item,
            method: "callHierarchy/incomingCalls",
            itemKey: "from",
            callSiteURI: { $0.uri },
            batch: batch
        )
    }

    func outgoingCalls(
        item: ExactCallHierarchyItem
    ) throws -> [ExactCallRelation]? {
        guard negotiatedCapabilities.contains(.callHierarchy) else {
            return nil
        }
        return try requestCallRelations(
            item: item,
            method: "callHierarchy/outgoingCalls",
            itemKey: "to",
            callSiteURI: { _ in item.uri }
        )
    }

    func outgoingCalls(
        item: ExactCallHierarchyItem,
        batch: ExactRequestBatch
    ) throws -> [ExactCallRelation]? {
        guard negotiatedCapabilities.contains(.callHierarchy) else {
            return nil
        }
        return try requestCallRelations(
            item: item,
            method: "callHierarchy/outgoingCalls",
            itemKey: "to",
            callSiteURI: { _ in item.uri },
            batch: batch
        )
    }

    func cancel(batch: ExactRequestBatch) {
        batch.cancel()
        stateLock.lock()
        guard activeBatch === batch else {
            stateLock.unlock()
            return
        }
        let activeClient = client
        stateLock.unlock()
        activeClient.cancelOutstandingRequests()
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

    /// Decision 5's fixed order. The operation lock is held from closing
    /// documents to the readiness confirmation, so no request can open a
    /// file while the directory is rewritten or answer before the server
    /// has taken the change in.
    func switchSnapshot(
        to newSnapshot: any Snapshot,
        profile: ExactProfileKey,
        changes: [ExactFileChange],
        configChanged: Bool,
        prepareFiles: () throws -> Void
    ) throws {
        stateLock.lock()
        guard state == .ready || state == .preparing else {
            let current = state
            stateLock.unlock()
            throw ExactError.unavailable(
                "cannot switch a session that is \(current)"
            )
        }
        switching = true
        switchGeneration &+= 1
        state = .preparing
        cancelled = false
        let inFlight = client
        stateLock.unlock()
        // Requests that already read the old snapshot stop here or at
        // their next lock (generation check).
        inFlight.cancelOutstandingRequests()
        operationLock.lock()
        defer {
            operationLock.unlock()
            stateLock.lock()
            switching = false
            stateLock.broadcast()
            stateLock.unlock()
        }
        do {
            stateLock.lock()
            let activeClient = client
            stateLock.unlock()
            for path in openedFiles.sorted() {
                try activeClient.notify("textDocument/didClose", params: [
                    "textDocument": [
                        "uri": projectURL.appendingPathComponent(path).absoluteString,
                    ],
                ])
            }
            openedFiles.removeAll()
            try prepareFiles()
            stateLock.lock()
            snapshot = newSnapshot
            baseAttribution = ExactAttribution(
                provider: baseAttribution.provider,
                toolVersion: baseAttribution.toolVersion,
                configFingerprint: profile.configFingerprint,
                environmentFingerprint: profile.environmentFingerprint,
                featureSelection: baseAttribution.featureSelection,
                environment: baseAttribution.environment,
                generatedAt: Date()
            )
            stateLock.unlock()
            if !changes.isEmpty {
                let mark = activeClient.signalMark
                try activeClient.notify(
                    "workspace/didChangeWatchedFiles",
                    params: ["changes": changes.map {
                        ["uri": $0.url.absoluteString, "type": $0.kind.rawValue]
                    }]
                )
                try awaitSwitchReadiness(
                    activeClient,
                    after: mark,
                    configChanged: configChanged
                )
            }
            stateLock.lock()
            if state == .preparing { state = .ready }
            stateLock.unlock()
        } catch {
            stateLock.lock()
            if state != .closed {
                // Half switched: the old answers are wrong and a restart
                // would reopen the same directory, so stay unavailable
                // until the coordinator replaces the session.
                didRestart = true
                state = .unavailable(
                    "\(language.serverName) switch failed: \(error)"
                )
            }
            stateLock.unlock()
            throw error
        }
    }

    private func awaitSwitchReadiness(
        _ client: LSPClient,
        after mark: Int,
        configChanged: Bool
    ) throws {
        let shouldContinue: @Sendable () -> Bool = { [weak self] in
            self.map { !$0.isCancelled } ?? false
        }
        func progress(
            _ method: String,
            _ params: [String: Any],
            kind: String
        ) -> [String: Any]? {
            guard method == "$/progress",
                  let value = params["value"] as? [String: Any],
                  value["kind"] as? String == kind
            else { return nil }
            return value
        }
        func notReady(_ signal: String) -> LSPError {
            .timeout("\(language.serverName) \(signal) after switch")
        }
        switch language.switchReadiness {
        case nil:
            return
        case .rustAnalyzer:
            guard let fetching = try client.waitForSignal(
                after: mark,
                timeout: Self.signalWindow,
                shouldContinue: shouldContinue,
                matching: { method, params in
                    progress(method, params, kind: "begin") != nil
                        && params["token"] as? String == "rustAnalyzer/Fetching"
                }
            ) else { return }
            guard try client.waitForSignal(
                after: fetching.mark,
                timeout: Self.switchReadyLimit,
                shouldContinue: shouldContinue,
                matching: { method, params in
                    method == "experimental/serverStatus"
                        && params["quiescent"] as? Bool == true
                }
            ) != nil else { throw notReady("quiescence") }
        case .pyright:
            guard configChanged else { return }
            guard try client.waitForSignal(
                after: mark,
                timeout: Self.configReloadWindow,
                shouldContinue: shouldContinue,
                matching: { method, params in
                    method == "window/logMessage"
                        && (params["message"] as? String)?
                            .contains("Reloading configuration file") == true
                }
            ) != nil else { throw notReady("configuration reload") }
        case .typeScript:
            guard let begin = try client.waitForSignal(
                after: mark,
                timeout: Self.signalWindow,
                shouldContinue: shouldContinue,
                matching: { method, params in
                    (progress(method, params, kind: "begin")?["title"] as? String)?
                        .contains("Initializing JS/TS language features") == true
                }
            ) else { return }
            let token = "\(begin.params["token"] ?? "")"
            guard try client.waitForSignal(
                after: begin.mark,
                timeout: Self.switchReadyLimit,
                shouldContinue: shouldContinue,
                matching: { method, params in
                    progress(method, params, kind: "end") != nil
                        && "\(params["token"] ?? "")" == token
                }
            ) != nil else { throw notReady("project load") }
        }
    }

    /// Waits out a switch in progress, then returns the snapshot a request
    /// reads and the switch generation it belongs to; nil once `batch` is
    /// no longer current.
    private func currentView(
        batch: ExactRequestBatch?
    ) -> (snapshot: any Snapshot, generation: UInt64)? {
        stateLock.lock()
        defer { stateLock.unlock() }
        while switching {
            guard batch?.isCurrent != false else { return nil }
            _ = stateLock.wait(until: Date().addingTimeInterval(0.01))
        }
        return (snapshot, switchGeneration)
    }

    private func isSwitchGeneration(_ generation: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return switchGeneration == generation
    }

    private func requestLocations<Result>(
        file: String,
        byteOffset: Int,
        method: String,
        includeDeclaration: Bool? = nil,
        batch: ExactRequestBatch? = nil,
        parse: (Any) throws -> Result?
    ) throws -> Result? {
        let path = try relativePath(file)
        guard language.acceptsPath(path) else {
            throw ExactError.invalidPath(path)
        }
        guard let view = currentView(batch: batch) else { return nil }
        let bytes = try view.snapshot.readBytes(path: path)
        guard let map = LSPPositionMap(utf8: bytes) else {
            throw ExactError.invalidUTF8(path)
        }
        guard let position = map.position(forByteOffset: byteOffset) else {
            throw ExactError.invalidPosition(path, byteOffset)
        }
        var params: [String: Any] = [
            "textDocument": [
                "uri": projectURL.appendingPathComponent(path).absoluteString,
            ],
            "position": [
                "line": position.line,
                "character": position.character,
            ],
        ]
        if let includeDeclaration {
            params["context"] = [
                "includeDeclaration": includeDeclaration,
            ]
        }
        return try request(
            method: method,
            params: params,
            switchGeneration: view.generation,
            beforeRequest: { client in
                try self.open(path: path, bytes: bytes, client: client)
            },
            batch: batch,
            parse: parse
        )
    }

    /// Two phases per attempt, each under the operation lock: prepare (pick
    /// the client, open documents) and request. With `.awaitQuiescence` the
    /// session waits between them, outside the lock. A crash or closed
    /// connection in either phase restarts the server once; a second one is
    /// "restart exhausted". A switch since `switchGeneration` cancels the
    /// request: its bytes and positions belong to the old snapshot.
    private func request<Result>(
        method: String,
        params: Any,
        switchGeneration expectedSwitch: UInt64,
        beforeRequest: (LSPClient) throws -> Void,
        batch: ExactRequestBatch? = nil,
        parse: (Any) throws -> Result?
    ) throws -> Result? {
        guard batch?.acquire() != false else { return nil }
        defer { batch?.release() }
        let awaitsQuiescence = language.requestFlow == .awaitQuiescence
        var activeClient: LSPClient?
        var retriedAfterCrash = false
        // Content-modified retries used; only `.awaitQuiescence` retries.
        var attempt = 0
        while true {
            do {
                let prepared: LSPClient? = try withOperationLock(
                    batch: batch,
                    cancelledResult: nil
                ) {
                    stateLock.lock()
                    cancelled = false
                    activeBatch = batch
                    stateLock.unlock()
                    guard batch?.isCurrent != false,
                          isSwitchGeneration(expectedSwitch)
                    else {
                        throw LSPError.cancelled(method)
                    }
                    if activeClient == nil {
                        activeClient = try clientForRequest()
                    }
                    guard let currentClient = activeClient else {
                        throw LSPError.cancelled(method)
                    }
                    try beforeRequest(currentClient)
                    try throwIfCancelled(method)
                    return currentClient
                }
                guard let readyClient = prepared else { return nil }
                if awaitsQuiescence {
                    try readyClient.waitForQuiescence(
                        method: method,
                        timeout: requestTimeout,
                        shouldContinue: { [weak self] in
                            guard let self else { return false }
                            return batch?.isCurrent != false && !self.isCancelled
                                && self.isSwitchGeneration(expectedSwitch)
                        }
                    )
                }
            } catch LSPError.cancelled {
                return nil
            } catch LSPError.processExited where !retriedAfterCrash {
                activeClient = try restartAfterCrash()
                retriedAfterCrash = true
                attempt = 0
                continue
            } catch LSPError.connectionClosed where !retriedAfterCrash {
                activeClient = try restartAfterCrash()
                retriedAfterCrash = true
                attempt = 0
                continue
            } catch LSPError.processExited {
                throw exhaustedError()
            } catch LSPError.connectionClosed {
                throw exhaustedError()
            }
            markReady()
            let outcome: (
                result: Result?,
                retry: Bool,
                countsTowardRetry: Bool,
                restarted: Bool
            ) = try withOperationLock(
                batch: batch,
                cancelledResult: (nil, false, false, false)
            ) {
                stateLock.lock()
                activeBatch = batch
                stateLock.unlock()
                guard batch?.isCurrent != false else {
                    return (nil, false, false, false)
                }
                if activeClient == nil {
                    activeClient = try clientForRequest()
                }
                guard let currentClient = activeClient else {
                    return (nil, false, false, false)
                }
                do {
                    try throwIfCancelled(method)
                    guard isSwitchGeneration(expectedSwitch) else {
                        throw LSPError.cancelled(method)
                    }
                    let requestWasReady = awaitsQuiescence
                        && currentClient.isQuiescent
                    let response = try currentClient.request(
                        method,
                        params: params,
                        timeout: requestTimeout,
                        shouldStart: {
                            batch?.isCurrent != false && !self.isCancelled
                        }
                    )
                    if let result = try parse(response) {
                        markReady()
                        return (result, false, false, false)
                    }
                    if !awaitsQuiescence
                        || (requestWasReady && currentClient.isQuiescent)
                    {
                        markReady()
                        return (nil, false, false, false)
                    }
                    // Empty answer from a server still loading: retry
                    // without using the retry budget.
                    markPreparing()
                    return (nil, true, false, false)
                } catch LSPError.requestFailed(let code, _)
                    where awaitsQuiescence && code == -32801 && attempt < 2
                {
                    // rust-analyzer reports content-modified while its
                    // workspace snapshot catches up.
                    markPreparing()
                    return (nil, true, true, false)
                } catch LSPError.processExited where !retriedAfterCrash {
                    activeClient = try restartAfterCrash()
                    retriedAfterCrash = true
                    attempt = 0
                    return (nil, false, false, true)
                } catch LSPError.connectionClosed where !retriedAfterCrash {
                    activeClient = try restartAfterCrash()
                    retriedAfterCrash = true
                    attempt = 0
                    return (nil, false, false, true)
                } catch LSPError.processExited {
                    throw self.exhaustedError()
                } catch LSPError.connectionClosed {
                    throw self.exhaustedError()
                } catch LSPError.cancelled {
                    return (nil, false, false, false)
                }
            }
            if outcome.restarted { continue }
            if let result = outcome.result { return result }
            guard outcome.retry else { return nil }
            guard batch?.isCurrent != false else { return nil }
            if outcome.countsTowardRetry { attempt += 1 }
        }
    }

    private func withOperationLock<Result>(
        batch: ExactRequestBatch?,
        cancelledResult: Result,
        _ operation: () throws -> Result
    ) throws -> Result {
        if let batch {
            while batch.isCurrent {
                if operationLock.lock(
                    before: Date().addingTimeInterval(0.01)
                ) {
                    guard batch.isCurrent else {
                        operationLock.unlock()
                        return cancelledResult
                    }
                    break
                }
            }
            guard batch.isCurrent else { return cancelledResult }
        } else {
            operationLock.lock()
        }
        defer {
            stateLock.lock()
            if let batch, activeBatch === batch {
                activeBatch = nil
            }
            stateLock.unlock()
            operationLock.unlock()
        }
        return try operation()
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
                ? "session is closed" : "\(language.serverName) restart exhausted"
            stateLock.unlock()
            throw ExactError.unavailable(reason)
        }
        didRestart = true
        state = .preparing
        let oldClient = client
        stateLock.unlock()

        oldClient.close(grace: closeGrace)
        Thread.sleep(forTimeInterval: 0.1)
        let newClient: LSPClient
        do {
            newClient = try restartClient()
        } catch {
            stateLock.lock()
            if state != .closed {
                state = .unavailable(
                    "\(language.serverName) restart exhausted: \(error)"
                )
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
        client = newClient
        openedFiles.removeAll()
        stateLock.unlock()
        observe(newClient)
        do {
            _ = try newClient.initialize(
                rootURL: projectURL,
                initializationOptions: language.initializationOptions,
                timeout: requestTimeout
            )
        } catch {
            newClient.close(grace: closeGrace)
            stateLock.lock()
            if state != .closed {
                state = .unavailable(
                    "\(language.serverName) restart failed: \(error)"
                )
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
                state = .unavailable("\(language.serverName) exited (\(status))")
            }
            stateLock.unlock()
        }
        guard let onDiagnostic = language.onDiagnostic else { return }
        observedClient.observeDiagnostics { [weak self, weak observedClient] diagnostic in
            guard let self, let observedClient else { return }
            publishEnvironment(
                onDiagnostic(baseAttribution.environment, diagnostic),
                from: observedClient
            )
        }
    }

    private func publishEnvironment(
        _ environment: ExactAnalysisEnvironment,
        from observedClient: LSPClient
    ) {
        stateLock.lock()
        guard state != .closed,
              client === observedClient,
              currentEnvironment.limitations != environment.limitations
        else {
            stateLock.unlock()
            return
        }
        currentEnvironment = environment
        let observer = environmentObserver
        stateLock.unlock()
        observer?(environment)
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
                    "languageId": language.languageID(path),
                    "version": 1,
                    "text": text,
                ],
            ])
        }
    }

    private func open(
        item: ExactCallHierarchyItem,
        client: LSPClient
    ) throws {
        guard let url = URL(string: item.uri), url.isFileURL else {
            throw ExactError.invalidDefinitionResponse(item.uri)
        }
        // Dependency items (outside the project, or under it through a
        // borrowed link) are not snapshot files; the server reads them.
        guard let path = projectRelativePath(
            of: url,
            projectURL: projectURL
        ), let bytes = try? snapshot.readBytes(path: path)
        else { return }
        try open(path: path, bytes: bytes, client: client)
    }

    private func requestCallRelations(
        item: ExactCallHierarchyItem,
        method: String,
        itemKey: String,
        callSiteURI: @escaping (ExactCallHierarchyItem) -> String,
        batch: ExactRequestBatch? = nil
    ) throws -> [ExactCallRelation]? {
        guard let view = currentView(batch: batch) else { return nil }
        return try request(
            method: method,
            params: ["item": try callHierarchyItemObject(item, snapshot: view.snapshot)],
            switchGeneration: view.generation,
            beforeRequest: { client in
                try self.open(item: item, client: client)
            },
            batch: batch,
            parse: {
                try self.parseCallRelations(
                    $0,
                    itemKey: itemKey,
                    callSiteURI: callSiteURI
                )
            }
        )
    }

    private func parseCallHierarchyItems(
        _ value: Any
    ) throws -> [ExactCallHierarchyItem]? {
        try CodeInsightExact.parseCallHierarchyItems(
            value,
            projectURL: projectURL,
            snapshot: snapshot
        )
    }

    private func parseCallRelations(
        _ value: Any,
        itemKey: String,
        callSiteURI: (ExactCallHierarchyItem) -> String
    ) throws -> [ExactCallRelation]? {
        try CodeInsightExact.parseCallRelations(
            value,
            itemKey: itemKey,
            callSiteURI: callSiteURI,
            projectURL: projectURL,
            snapshot: snapshot
        )
    }

    private func callHierarchyItemObject(
        _ item: ExactCallHierarchyItem,
        snapshot: any Snapshot
    ) throws -> [String: Any] {
        var object: [String: Any] = [
            "name": item.name,
            "kind": item.kind,
            "uri": item.uri,
            "range": try exactLSPRange(
                for: item.range,
                projectURL: projectURL,
                snapshot: snapshot
            ),
            "selectionRange": try exactLSPRange(
                for: item.selectionRange,
                projectURL: projectURL,
                snapshot: snapshot
            ),
        ]
        if let data = item.data {
            object["data"] = try JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
            )
        }
        return object
    }

    private func parseDefinition(_ value: Any) throws -> ExactDefinitionQueryResult {
        if value is NSNull { return .completed([]) }
        let objects: [[String: Any]]
        if let dictionary = value as? [String: Any] {
            objects = [dictionary]
        } else if let array = value as? [[String: Any]] {
            objects = array
        } else {
            throw ExactError.invalidDefinitionResponse(String(describing: value))
        }
        return .completed(try objects.map {
            ExactTarget(location: try parseLocation($0))
        })
    }

    private func parseLocations(_ value: Any) throws -> [ExactLocation]? {
        try exactLocations(value, projectURL: projectURL, snapshot: snapshot)
    }

    private func parseLocation(_ object: [String: Any]) throws -> ExactLocation {
        try parseExactLocation(
            object,
            projectURL: projectURL,
            snapshot: snapshot
        )
    }

    private func relativePath(_ input: String) throws -> String {
        try relativeProjectPath(input, projectURL: projectURL)
    }

    private func throwIfCancelled(_ method: String) throws {
        stateLock.lock()
        let wasCancelled = cancelled
        stateLock.unlock()
        if wasCancelled { throw LSPError.cancelled(method) }
    }

    private var isCancelled: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cancelled || state == .closed
    }

    // A switch owns the state until it confirms readiness.
    private func markPreparing() {
        stateLock.lock()
        if !switching, state == .preparing || state == .ready {
            state = .preparing
        }
        stateLock.unlock()
    }

    private func markReady() {
        stateLock.lock()
        if !switching, state == .preparing || state == .ready { state = .ready }
        stateLock.unlock()
    }

    private func exhaustedError() -> ExactError {
        let reason = "\(language.serverName) restart exhausted"
        stateLock.lock()
        if state != .closed {
            state = .unavailable(reason)
        }
        stateLock.unlock()
        return ExactError.unavailable(reason)
    }
}
