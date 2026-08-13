import CodeInsightCore
import CodeInsightGit
import Foundation

public final class TypeScriptLanguageServerProvider: ExactProvider, @unchecked Sendable {
    public static let supportedCapabilities: ExactCapabilities = [
        .definition,
        .implementations,
        .callHierarchy,
        .references,
    ]

    public let language: LanguageID = .typescript
    public let capabilities: ExactCapabilities =
        TypeScriptLanguageServerProvider.supportedCapabilities
    public let toolVersion: String

    private let projectURL: URL
    private let nodeURL: URL
    private let languageServerURL: URL
    private let tsserverURL: URL
    private let typescriptPackageURL: URL
    private let cacheURL: URL
    private let requestTimeout: TimeInterval
    private let closeGrace: TimeInterval

    public init(
        projectURL: URL,
        nodeURL: URL,
        languageServerURL: URL,
        tsserverURL: URL,
        typescriptPackageURL: URL? = nil,
        cacheURL: URL? = nil,
        requestTimeout: TimeInterval = 30,
        closeGrace: TimeInterval = 1
    ) throws {
        let project = projectURL.standardizedFileURL
        self.projectURL = project
        let resolvedNode = nodeURL.resolvingSymlinksInPath()
            .standardizedFileURL
        let resolvedLanguageServer = languageServerURL.resolvingSymlinksInPath()
            .standardizedFileURL
        let resolvedTsserver = tsserverURL.resolvingSymlinksInPath()
            .standardizedFileURL
        self.nodeURL = resolvedNode
        self.languageServerURL = resolvedLanguageServer
        self.tsserverURL = resolvedTsserver
        self.typescriptPackageURL = (typescriptPackageURL
            ?? resolvedTsserver
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("package.json")
        ).resolvingSymlinksInPath().standardizedFileURL
        self.cacheURL = cacheURL ?? Self.defaultCacheURL
        self.requestTimeout = requestTimeout
        self.closeGrace = closeGrace

        let canonicalProject = project.resolvingSymlinksInPath()
        try Self.requireOutsideProject(
            self.nodeURL,
            projectURL: canonicalProject
        )
        try Self.requireOutsideProject(
            self.languageServerURL,
            projectURL: canonicalProject
        )
        try Self.requireOutsideProject(
            self.tsserverURL,
            projectURL: canonicalProject
        )
        try Self.requireOutsideProject(
            self.typescriptPackageURL,
            projectURL: canonicalProject
        )
        try Self.requireReadableExecutable(
            self.nodeURL,
            name: "node"
        )
        try Self.requireReadableFile(
            self.languageServerURL,
            name: "typescript-language-server"
        )
        try Self.requireReadableFile(self.tsserverURL, name: "tsserver")
        try Self.requireReadableFile(
            self.typescriptPackageURL,
            name: "typescript package"
        )

        toolVersion = try Self.readToolVersion(
            projectURL: project,
            cacheURL: self.cacheURL,
            nodeURL: self.nodeURL,
            languageServerURL: self.languageServerURL,
            tsserverURL: self.tsserverURL,
            typescriptPackageURL: self.typescriptPackageURL
        )
    }

    public static func findExecutable(
        named name: String,
        projectURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        guard let found = CodeInsightExact.findExecutable(
            named: name,
            environment: environment,
            projectRoot: projectURL
        ) else { return nil }
        do {
            try requireOutsideProject(
                found,
                projectURL: projectURL
            )
            return found
        } catch {
            return nil
        }
    }

    static func requireOutsideProject(
        _ candidateURL: URL,
        projectURL: URL
    ) throws {
        let candidate = candidateURL
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        let project = projectURL.resolvingSymlinksInPath()
            .standardizedFileURL.path
        guard candidate != project,
              candidate != project + "/",
              project != "/",
              !candidate.hasPrefix(project + "/")
        else {
            throw ExactError.unavailable(
                "TypeScript executable is inside the project root"
            )
        }
    }

    static func requireReadableExecutable(
        _ url: URL,
        name: String
    ) throws {
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw ExactError.unavailable(
                "\(name) is missing or not executable: \(url.path)"
            )
        }
    }

    static func requireReadableFile(
        _ url: URL,
        name: String
    ) throws {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw ExactError.unavailable(
                "\(name) is missing or unreadable: \(url.path)"
            )
        }
    }

    static func readVersion(
        projectURL: URL,
        cacheURL: URL,
        nodeURL: URL,
        arguments: [String],
        failure: String
    ) throws -> String {
        let launch = try Sandbox(
            projectURL: projectURL,
            cacheURL: cacheURL,
            trustMode: .safe,
            helperURL: nodeURL,
            helperArguments: arguments
        )
        let process = Process()
        let pipe = Pipe()
        process.executableURL = launch.executableURL
        process.arguments = launch.arguments
        process.currentDirectoryURL = launch.workingDirectoryURL
        process.environment = sanitizedChildEnvironment(
            launch.environment,
            projectRoot: projectURL
        )
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw ExactError.unavailable(
                "\(failure) exited \(process.terminationStatus)"
            )
        }
        return String(data: output, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func readToolVersion(
        projectURL: URL,
        cacheURL: URL,
        nodeURL: URL,
        languageServerURL: URL,
        tsserverURL: URL,
        typescriptPackageURL: URL
    ) throws -> String {
        let nodeVersion = try readVersion(
            projectURL: projectURL,
            cacheURL: cacheURL,
            nodeURL: nodeURL,
            arguments: ["--version"],
            failure: "node --version"
        )
        let serverVersion: String
        if let packageURL = URL(
            string: languageServerURL.deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("package.json").absoluteString
        ) {
            let package = try? JSONSerialization.jsonObject(
                with: Data(contentsOf: packageURL),
                options: []
            ) as? [String: Any]
            serverVersion = package?["version"] as? String ?? "unknown"
        } else {
            serverVersion = "unknown"
        }
        let tsVersion = try Self.readJSONValueAtPath(
            typescriptPackageURL,
            key: "version"
        ) ?? "unknown"
        return "language-server \(serverVersion) | typescript \(tsVersion) | node \(nodeVersion)"
            + " | node=\(nodeURL.resolvingSymlinksInPath().path)"
            + " | server=\(languageServerURL.resolvingSymlinksInPath().path)"
            + " | tsserver=\(tsserverURL.resolvingSymlinksInPath().path)"
    }

    private static func readJSONValueAtPath(
        _ url: URL,
        key: String
    ) throws -> String? {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let object = try JSONSerialization.jsonObject(with: data)
            as? [String: Any]
        else { return nil }
        return object[key] as? String
    }

    private func safeLaunch() throws -> Sandbox {
        try Sandbox(
            projectURL: projectURL,
            cacheURL: cacheURL,
            trustMode: .safe,
            helperURL: nodeURL,
            helperArguments: [
                languageServerURL.path,
                "--stdio",
            ]
        )
    }

    private static func client(for launch: Sandbox, projectURL: URL) throws -> LSPClient {
        try LSPClient(
            executableURL: launch.executableURL,
            arguments: launch.arguments,
            workingDirectory: launch.workingDirectoryURL,
            environment: sanitizedChildEnvironment(
                launch.environment,
                projectRoot: projectURL
            )
        )
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

    private func initializationOptions() -> [String: Any] {
        Self.initializationOptions(tsserverPath: tsserverURL)
    }

    static func initializationOptions(
        tsserverPath: URL
    ) -> [String: Any] {
        [
            "disableAutomaticTypingAcquisition": true,
            "plugins": [],
            "tsserver": [
                "path": tsserverPath.path,
                "logVerbosity": "off",
                "trace": "off",
                "useSyntaxServer": "never",
            ],
        ]
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
        let environment = ExactAnalysisEnvironment(
            trustMode: trustMode,
            limitations: [.dependenciesUnavailableOffline]
        )
        let launch = try safeLaunch()
        let client = try Self.client(for: launch, projectURL: projectURL)
        do {
            return try TypeScriptLanguageServerSession.start(
                client: client,
                restartClient: {
                    try Self.client(
                        for: try self.safeLaunch(),
                        projectURL: self.projectURL
                    )
                },
                projectURL: projectURL,
                snapshot: snapshot,
                initializationOptions: initializationOptions(),
                requestTimeout: requestTimeout,
                closeGrace: closeGrace,
                attribution: ExactAttribution(
                    provider: "typescript-language-server",
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
}

final class TypeScriptLanguageServerSession: ExactSession, @unchecked Sendable {
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
        attribution: ExactAttribution
    ) throws -> TypeScriptLanguageServerSession {
        let initializeResult = try client.initialize(
            rootURL: projectURL,
            initializationOptions: initializationOptions,
            timeout: requestTimeout
        )
        let negotiated = Self.negotiatedCapabilities(
            from: initializeResult
        )
        guard negotiated.contains(.definition),
              negotiated.contains(.references)
        else {
            client.close(grace: closeGrace)
            throw ExactError.unavailable(
                "typescript-language-server must advertise definition and references"
            )
        }
        return TypeScriptLanguageServerSession(
            client: client,
            restartClient: restartClient,
            negotiatedCapabilities: negotiated,
            projectURL: projectURL,
            snapshot: snapshot,
            initializationOptions: initializationOptions,
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
        initializationOptions: [String: Any],
        requestTimeout: TimeInterval,
        closeGrace: TimeInterval,
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
        baseAttribution = attribution
        currentEnvironment = attribution.environment
        observe(client)
    }

    static func negotiatedCapabilities(
        from initializeResult: Any
    ) -> ExactCapabilities {
        var negotiated: ExactCapabilities = []
        guard let result = initializeResult as? [String: Any],
              let capabilities = result["capabilities"] as? [String: Any]
        else { return negotiated }
        if let provider = capabilities["definitionProvider"],
           (provider as? Bool) == true || provider is [String: Any]
        {
            negotiated.insert(.definition)
        }
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
        return negotiated.intersection(
            TypeScriptLanguageServerProvider.supportedCapabilities
        )
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

    private func requestLocations<Result>(
        file: String,
        byteOffset: Int,
        method: String,
        includeDeclaration: Bool? = nil,
        batch: ExactRequestBatch? = nil,
        parse: (Any) throws -> Result?
    ) throws -> Result? {
        let path = try relativePath(file)
        guard LanguageMode.classify(path: path, language: .typescript) != nil
        else {
            throw ExactError.invalidPath(path)
        }
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
        while true {
            do {
                _ = try withOperationLock(batch: batch) {
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
            } catch LSPError.processExited where !retriedAfterCrash {
                activeClient = try restartAfterCrash()
                retriedAfterCrash = true
                continue
            } catch LSPError.connectionClosed where !retriedAfterCrash {
                activeClient = try restartAfterCrash()
                retriedAfterCrash = true
                continue
            } catch LSPError.processExited {
                throw exhaustedError()
            } catch LSPError.connectionClosed {
                throw exhaustedError()
            }
            markReady()
            let outcome: (result: Any?, restart: Bool, cancelled: Bool) =
                try withOperationLock(batch: batch) {
                stateLock.lock()
                activeBatch = batch
                stateLock.unlock()
                guard batch?.isCurrent != false else {
                    return (nil, false, true)
                }
                if activeClient == nil {
                    activeClient = try clientForRequest()
                }
                guard let currentClient = activeClient else {
                    return (nil, false, true)
                }
                do {
                    try throwIfCancelled(method)
                    let response = try currentClient.request(
                        method,
                        params: params,
                        timeout: requestTimeout,
                        shouldStart: {
                            batch?.isCurrent != false && !self.isCancelled
                        }
                    )
                    let result = try parse(response)
                    markReady()
                    return (result, false, false)
                } catch LSPError.processExited where !retriedAfterCrash {
                    activeClient = try restartAfterCrash()
                    retriedAfterCrash = true
                    return (nil, true, false)
                } catch LSPError.connectionClosed where !retriedAfterCrash {
                    activeClient = try restartAfterCrash()
                    retriedAfterCrash = true
                    return (nil, true, false)
                } catch LSPError.processExited {
                    throw self.exhaustedError()
                } catch LSPError.connectionClosed {
                    throw self.exhaustedError()
                } catch LSPError.cancelled {
                    return (nil, false, true)
                }
            }
            if outcome.restart { continue }
            if outcome.cancelled { return nil }
            return outcome.result as? Result
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
                ? "session is closed" : "typescript restart exhausted"
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
                state = .unavailable("typescript restart exhausted: \(error)")
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
                initializationOptions: initializationOptions,
                timeout: requestTimeout
            )
        } catch {
            newClient.close(grace: closeGrace)
            stateLock.lock()
            if state != .closed {
                state = .unavailable("typescript restart failed: \(error)")
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
                state = .unavailable("typescript exited (\(status))")
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
                    "languageId": languageID(for: path),
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

    private func languageID(for path: String) -> String {
        path.hasSuffix(".tsx") ? "typescriptreact" : "typescript"
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

    private func markReady() {
        stateLock.lock()
        if state == .preparing || state == .ready { state = .ready }
        stateLock.unlock()
    }

    private func exhaustedError() -> ExactError {
        stateLock.lock()
        if state != .closed {
            state = .unavailable("typescript restart exhausted")
        }
        stateLock.unlock()
        return ExactError.unavailable("typescript restart exhausted")
    }
}
