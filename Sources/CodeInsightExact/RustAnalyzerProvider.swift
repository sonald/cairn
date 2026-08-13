import CodeInsightCore
import CodeInsightGit
import Foundation

public final class RustAnalyzerProvider: ExactProvider, @unchecked Sendable {
    public let language: LanguageID = .rust
    public let capabilities: ExactCapabilities = [
        .definition, .implementations, .callHierarchy, .references,
    ]
    public let toolVersion: String

    private let projectURL: URL
    private let executableURL: URL
    private let cacheURL: URL
    private let requestTimeout: TimeInterval
    private let closeGrace: TimeInterval
    private let diagnosticObserver: (@Sendable (String) -> Void)?

    public convenience init(
        projectURL: URL,
        executableURL: URL,
        cacheURL: URL? = nil,
        requestTimeout: TimeInterval = 30,
        closeGrace: TimeInterval = 1
    ) throws {
        try self.init(
            projectURL: projectURL,
            executableURL: executableURL,
            cacheURL: cacheURL,
            requestTimeout: requestTimeout,
            closeGrace: closeGrace,
            diagnosticObserver: nil
        )
    }

    public init(
        projectURL: URL,
        executableURL: URL,
        cacheURL: URL?,
        requestTimeout: TimeInterval,
        closeGrace: TimeInterval,
        diagnosticObserver: (@Sendable (String) -> Void)?
    ) throws {
        self.projectURL = projectURL.standardizedFileURL
        self.executableURL = executableURL.standardizedFileURL
        self.cacheURL = cacheURL ?? Self.defaultCacheURL
        self.requestTimeout = requestTimeout
        self.closeGrace = closeGrace
        self.diagnosticObserver = diagnosticObserver
        toolVersion = try Self.readToolVersion(
            executableURL: executableURL,
            projectURL: projectURL,
            cacheURL: self.cacheURL
        )
    }

    public static func findExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        CodeInsightExact.findExecutable(
            named: "rust-analyzer",
            environment: environment,
            projectRoot: nil
        )
    }

    public func prepare(
        snapshot: any Snapshot,
        profile: ExactProfileKey,
        trustMode: TrustMode
    ) throws -> any ExactSession {
        guard profile.language == language else {
            throw ExactError.unavailable(
                "provider language \(String(describing: language)) does not match "
                    + "profile language \(String(describing: profile.language))"
            )
        }
        let options = Self.initializationOptions(
            trustMode: trustMode,
            featureSelection: profile.featureSelection
        )
        let environment = ExactAnalysisEnvironment(
            trustMode: trustMode,
            limitations: trustMode == .safe
                ? [.buildScriptsDisabled, .procMacrosDisabled]
                : []
        )

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
        do {
            return try RustAnalyzerSession.start(
                client: client,
                restartClient: {
                    try LSPClient(
                        executableURL: launch.executableURL,
                        arguments: launch.arguments,
                        workingDirectory: launch.workingDirectoryURL,
                        environment: launch.environment
                    )
                },
                projectURL: projectURL,
                snapshot: snapshot,
                initializationOptions: options,
                requestTimeout: requestTimeout,
                closeGrace: closeGrace,
                diagnosticObserver: diagnosticObserver,
                attribution: ExactAttribution(
                    provider: "rust-analyzer",
                    toolVersion: toolVersion,
                    configFingerprint: profile.configFingerprint,
                    environmentFingerprint: profile.environmentFingerprint,
                    featureSelection: profile.featureSelection,
                    environment: environment,
                    generatedAt: Date()
                )
            )
        } catch {
            client.close(grace: closeGrace)
            throw error
        }
    }

    static func initializationOptions(
        trustMode: TrustMode,
        featureSelection: FeatureSelection
    ) -> [String: Any] {
        var options: [String: Any]
        var cargo: [String: Any]
        switch trustMode {
        case .safe:
            cargo = ["buildScripts": ["enable": false]]
            options = [
                "procMacro": ["enable": false],
                "checkOnSave": false,
            ]
        case .trusted:
            cargo = [:]
            options = [:]
        }
        switch featureSelection {
        case .defaultFeatures:
            break
        case .allFeatures:
            cargo["features"] = "all"
        case .noDefaultFeatures:
            cargo["noDefaultFeatures"] = true
        }
        if !cargo.isEmpty { options["cargo"] = cargo }
        return options
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

func findExecutable(
    named name: String,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    projectRoot: URL? = nil
) -> URL? {
    for directory in executableSearchDirectories(
        environment: environment,
        projectRoot: projectRoot
    ) {
        let candidate = directory.appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate.standardizedFileURL
        }
    }
    return nil
}

func executableSearchDirectories(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    projectRoot: URL? = nil
) -> [URL] {
    var raw = environment["PATH", default: ""]
        .split(separator: ":", omittingEmptySubsequences: false)
        .map(String.init)
    raw.append(contentsOf: ["/opt/homebrew/bin", "/usr/local/bin"])

    let canonicalProject = projectRoot?.resolvingSymlinksInPath()
        .standardizedFileURL.resolvingSymlinksInPath().path
    var seen = Set<String>()
    var result: [URL] = []
    for entry in raw {
        guard entry.hasPrefix("/"), !entry.isEmpty else { continue }
        let url = URL(fileURLWithPath: entry)
            .standardizedFileURL
        let canonicalPath = url.resolvingSymlinksInPath().path
        if let canonicalProject,
           canonicalPath == canonicalProject
               || (canonicalProject != "/"
                   && canonicalPath.hasPrefix(canonicalProject + "/"))
               || (canonicalProject == "/"
                   && canonicalPath.hasPrefix("/"))
        {
            continue
        }
        guard seen.insert(canonicalPath).inserted else { continue }
        result.append(url)
    }
    return result
}

func sanitizedChildEnvironment(
    _ environment: [String: String],
    projectRoot: URL
) -> [String: String] {
    var clean = environment
    clean["PATH"] = executableSearchDirectories(
        environment: environment,
        projectRoot: projectRoot
    )
    .map { $0.resolvingSymlinksInPath().path }
    .joined(separator: ":")
    for key in [
        "PYTHONPATH",
        "PYTHONHOME",
        "PYTHONSTARTUP",
        "VIRTUAL_ENV",
        "CONDA_PREFIX",
        "NODE_PATH",
        "NODE_OPTIONS",
    ] {
        clean.removeValue(forKey: key)
    }
    clean["PYTHONNOUSERSITE"] = "1"
    clean["PYTHONDONTWRITEBYTECODE"] = "1"
    clean["PYTHONSAFEPATH"] = "1"
    return clean
}

final class RustAnalyzerSession: ExactSession, @unchecked Sendable {
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

    private let stateLock = NSLock()
    private let operationLock = NSLock()
    private let restartClient: @Sendable () throws -> LSPClient
    private let projectURL: URL
    private let snapshot: any Snapshot
    private let initializationOptions: [String: Any]
    private let requestTimeout: TimeInterval
    private let closeGrace: TimeInterval
    private let diagnosticObserver: (@Sendable (String) -> Void)?
    private var client: LSPClient
    private var state: ExactReadiness = .preparing
    private var openedFiles: Set<String> = []
    private var cancelled = false
    private var activeBatch: ExactRequestBatch?
    private var didRestart = false
    private let baseAttribution: ExactAttribution
    private var currentEnvironment: ExactAnalysisEnvironment
    private var environmentObserver: (@Sendable (ExactAnalysisEnvironment) -> Void)?

    var readiness: ExactReadiness {
        stateLock.lock()
        defer { stateLock.unlock() }
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
        initializationOptions: [String: Any],
        requestTimeout: TimeInterval,
        closeGrace: TimeInterval,
        diagnosticObserver: (@Sendable (String) -> Void)?,
        attribution: ExactAttribution
    ) throws -> RustAnalyzerSession {
        let initializeResult = try client.initialize(
            rootURL: projectURL,
            initializationOptions: initializationOptions,
            timeout: requestTimeout
        )
        return RustAnalyzerSession(
            client: client,
            restartClient: restartClient,
            negotiatedCapabilities: negotiatedCapabilities(
                from: initializeResult
            ),
            projectURL: projectURL,
            snapshot: snapshot,
            initializationOptions: initializationOptions,
            requestTimeout: requestTimeout,
            closeGrace: closeGrace,
            diagnosticObserver: diagnosticObserver,
            attribution: attribution
        )
    }

    private init(
        client: LSPClient,
        restartClient: @escaping @Sendable () throws -> LSPClient,
        negotiatedCapabilities: ExactCapabilities,
        projectURL: URL,
        snapshot: any Snapshot,
        initializationOptions: [String: Any],
        requestTimeout: TimeInterval,
        closeGrace: TimeInterval,
        diagnosticObserver: (@Sendable (String) -> Void)?,
        attribution: ExactAttribution
    ) {
        self.client = client
        self.restartClient = restartClient
        self.negotiatedCapabilities = negotiatedCapabilities
        self.projectURL = projectURL
        self.snapshot = snapshot
        self.initializationOptions = initializationOptions
        self.requestTimeout = requestTimeout
        self.closeGrace = closeGrace
        self.diagnosticObserver = diagnosticObserver
        baseAttribution = attribution
        currentEnvironment = attribution.environment
        observe(client)
    }

    private static func negotiatedCapabilities(
        from initializeResult: Any
    ) -> ExactCapabilities {
        var negotiated: ExactCapabilities = [.definition]
        guard let result = initializeResult as? [String: Any],
              let capabilities = result["capabilities"] as? [String: Any]
        else { return negotiated }
        if let provider = capabilities["implementationProvider"],
           (provider as? Bool) == true || provider is [String: Any]
        {
            negotiated.insert(.implementations)
        }
        if let provider = capabilities["callHierarchyProvider"],
           (provider as? Bool) == true || provider is [String: Any]
        {
            negotiated.insert(.callHierarchy)
        }
        if let provider = capabilities["referencesProvider"],
           (provider as? Bool) == true || provider is [String: Any]
        {
            negotiated.insert(.references)
        }
        return negotiated
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

    private func requestLocations<Result>(
        file: String,
        byteOffset: Int,
        method: String,
        includeDeclaration: Bool? = nil,
        batch: ExactRequestBatch? = nil,
        parse: (Any) throws -> Result?
    ) throws -> Result? {
        let path = try relativePath(file)
        let bytes = try snapshot.readBytes(path: path)
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
            beforeRequest: { client in
                try self.open(path: path, bytes: bytes, client: client)
            },
            batch: batch,
            parse: parse
        )
    }

    private func request<Result>(
        method: String,
        params: Any,
        beforeRequest: (LSPClient) throws -> Void,
        batch: ExactRequestBatch? = nil,
        parse: (Any) throws -> Result?
    ) throws -> Result? {
        guard batch?.acquire() != false else { return nil }
        defer { batch?.release() }
        var activeClient: LSPClient?
        var retriedAfterCrash = false
        var attempt = 0
        while true {
            do {
                let readyClient: LSPClient = try withOperationLock(batch: batch) {
                    stateLock.lock()
                    cancelled = false
                    activeBatch = batch
                    stateLock.unlock()
                    guard batch?.isCurrent != false else {
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
                try readyClient.waitForQuiescence(
                    method: method,
                    timeout: requestTimeout,
                    shouldContinue: { [weak self] in
                        guard let self else { return false }
                        return batch?.isCurrent != false && !self.isCancelled
                    }
                )
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
            ) = try withOperationLock(batch: batch) {
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
                    let requestWasReady = currentClient.isQuiescent
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
                    if requestWasReady && currentClient.isQuiescent {
                        markReady()
                        return (nil, false, false, false)
                    }
                    markPreparing()
                    return (nil, true, false, false)
                } catch LSPError.requestFailed(let code, _)
                    where code == -32801 && attempt < 2
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
        _ operation: () throws -> Result
    ) throws -> Result {
        if let batch {
            while batch.isCurrent {
                if operationLock.lock(
                    before: Date().addingTimeInterval(0.01)
                ) {
                    guard batch.isCurrent else {
                        operationLock.unlock()
                        throw CancellationError()
                    }
                    break
                }
            }
            guard batch.isCurrent else { throw CancellationError() }
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

    private func requestCallRelations(
        item: ExactCallHierarchyItem,
        method: String,
        itemKey: String,
        callSiteURI: @escaping (ExactCallHierarchyItem) -> String,
        batch: ExactRequestBatch? = nil
    ) throws -> [ExactCallRelation]? {
        try request(
            method: method,
            params: ["item": try callHierarchyItemObject(item)],
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
        let newClient = try restartClient()
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
        observedClient.observeDiagnostics { [weak self, weak observedClient] diagnostic in
            guard let self, let observedClient else { return }
            diagnosticObserver?(diagnostic)
            publishEnvironment(
                rustAnalyzerEnvironment(
                    base: baseAttribution.environment,
                    diagnostic: diagnostic
                ),
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
                    "languageId": "rust",
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
        guard let path = projectRelativePath(
            of: url,
            projectURL: projectURL
        ) else { return }
        try open(
            path: path,
            bytes: snapshot.readBytes(path: path),
            client: client
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
        _ item: ExactCallHierarchyItem
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

    private func exhaustedError() -> ExactError {
        stateLock.lock()
        if state != .closed {
            state = .unavailable("rust-analyzer restart exhausted")
        }
        stateLock.unlock()
        return ExactError.unavailable("rust-analyzer restart exhausted")
    }
}

func rustAnalyzerEnvironment(
    base: ExactAnalysisEnvironment,
    diagnostic: String
) -> ExactAnalysisEnvironment {
    let diagnostic = diagnostic.lowercased()
    let offline = diagnostic.contains("--offline")
        || diagnostic.contains("offline mode")
        || diagnostic.contains("cargo_net_offline")
    let dependencyFailure = diagnostic.contains("failed to download")
        || diagnostic.contains("no matching package named")
        || diagnostic.contains("attempting to make an http request")
        || diagnostic.contains("can't check for updates in offline mode")
        || (diagnostic.contains("failed to get")
            && diagnostic.contains("as a dependency of package"))
    guard offline,
          dependencyFailure
    else { return base }
    var limitations = base.limitations
    limitations.insert(.dependenciesUnavailableOffline)
    return ExactAnalysisEnvironment(
        trustMode: base.trustMode,
        limitations: limitations
    )
}
