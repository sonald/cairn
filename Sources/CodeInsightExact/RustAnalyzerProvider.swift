import CodeInsightCore
import CodeInsightGit
import Foundation

public final class RustAnalyzerProvider: ExactProvider, @unchecked Sendable {
    public let capabilities: ExactCapabilities = [
        .definition, .implementations, .callHierarchy,
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
        let options = Self.initializationOptions(
            trustMode: trustMode,
            featureSelection: profile.featureSelection
        )
        let coverage: ExactCoverage
        switch trustMode {
        case .safe:
            coverage = .partial
        case .trusted:
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
                    trustMode: trustMode,
                    generatedAt: Date(),
                    coverage: coverage
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

final class RustAnalyzerSession: ExactSession, @unchecked Sendable {
    let negotiatedCapabilities: ExactCapabilities

    var attribution: ExactAttribution {
        stateLock.lock()
        let coverage = currentCoverage
        stateLock.unlock()
        return ExactAttribution(
            provider: baseAttribution.provider,
            toolVersion: baseAttribution.toolVersion,
            configFingerprint: baseAttribution.configFingerprint,
            environmentFingerprint: baseAttribution.environmentFingerprint,
            featureSelection: baseAttribution.featureSelection,
            trustMode: baseAttribution.trustMode,
            generatedAt: baseAttribution.generatedAt,
            coverage: coverage
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
    private var didRestart = false
    private let baseAttribution: ExactAttribution
    private var currentCoverage: ExactCoverage
    private var coverageObserver: (@Sendable (ExactCoverage) -> Void)?

    var readiness: ExactReadiness {
        stateLock.lock()
        defer { stateLock.unlock() }
        return state
    }

    var onCoverageChange: (@Sendable (ExactCoverage) -> Void)? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return coverageObserver
        }
        set {
            stateLock.lock()
            coverageObserver = newValue
            let coverage = currentCoverage
            stateLock.unlock()
            newValue?(coverage)
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
        currentCoverage = attribution.coverage
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
        return negotiated
    }

    func definition(file: String, byteOffset: Int) throws -> ExactLocation? {
        try requestLocations(
            file: file,
            byteOffset: byteOffset,
            method: "textDocument/definition",
            parse: parseDefinition
        )
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
            parse: parseImplementations
        )
    }

    private func requestLocations<Result>(
        file: String,
        byteOffset: Int,
        method: String,
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

        return try request(
            method: method,
            params: [
                "textDocument": [
                    "uri": projectURL.appendingPathComponent(path).absoluteString,
                ],
                "position": [
                    "line": position.line,
                    "character": position.character,
                ],
            ],
            beforeRequest: { client in
                try self.open(path: path, bytes: bytes, client: client)
            },
            parse: parse
        )
    }

    private func request<Result>(
        method: String,
        params: Any,
        beforeRequest: (LSPClient) throws -> Void,
        parse: (Any) throws -> Result?
    ) throws -> Result? {
        operationLock.lock()
        defer { operationLock.unlock() }

        stateLock.lock()
        cancelled = false
        stateLock.unlock()
        var activeClient = try clientForRequest()
        var retriedAfterCrash = false
        while true {
            do {
                try beforeRequest(activeClient)
                for attempt in 0..<3 {
                    try throwIfCancelled(method)
                    do {
                        let response = try activeClient.request(
                            method,
                            params: params,
                            timeout: requestTimeout
                        )
                        if let result = try parse(response) {
                            markReady()
                            return result
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

    private func requestCallRelations(
        item: ExactCallHierarchyItem,
        method: String,
        itemKey: String,
        callSiteURI: @escaping (ExactCallHierarchyItem) -> String
    ) throws -> [ExactCallRelation]? {
        try request(
            method: method,
            params: ["item": try callHierarchyItemObject(item)],
            beforeRequest: { client in
                try self.open(item: item, client: client)
            },
            parse: {
                try self.parseCallRelations(
                    $0,
                    itemKey: itemKey,
                    callSiteURI: callSiteURI
                )
            }
        )
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
            publishCoverage(
                rustAnalyzerCoverage(
                    base: baseAttribution.coverage,
                    diagnostic: diagnostic
                ),
                from: observedClient
            )
        }
    }

    private func publishCoverage(
        _ coverage: ExactCoverage,
        from observedClient: LSPClient
    ) {
        stateLock.lock()
        guard state != .closed,
              client === observedClient,
              currentCoverage != coverage
        else {
            stateLock.unlock()
            return
        }
        currentCoverage = coverage
        let observer = coverageObserver
        stateLock.unlock()
        observer?(coverage)
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
        guard let path = projectRelativePath(of: url) else { return }
        try open(
            path: path,
            bytes: snapshot.readBytes(path: path),
            client: client
        )
    }

    private func parseCallHierarchyItems(
        _ value: Any
    ) throws -> [ExactCallHierarchyItem]? {
        if value is NSNull { return nil }
        guard let objects = value as? [[String: Any]] else {
            throw ExactError.invalidDefinitionResponse(String(describing: value))
        }
        return try objects.map(parseCallHierarchyItem)
    }

    private func parseCallHierarchyItem(
        _ object: [String: Any]
    ) throws -> ExactCallHierarchyItem {
        guard let name = object["name"] as? String,
              let kind = (object["kind"] as? NSNumber)?.intValue,
              let uri = object["uri"] as? String,
              let range = object["range"] as? [String: Any],
              let selectionRange = object["selectionRange"] as? [String: Any]
        else {
            throw ExactError.invalidDefinitionResponse(String(describing: object))
        }
        let data: Data?
        if let value = object["data"] {
            data = try JSONSerialization.data(
                withJSONObject: value,
                options: [.fragmentsAllowed, .sortedKeys]
            )
        } else {
            data = nil
        }
        return ExactCallHierarchyItem(
            name: name,
            kind: kind,
            uri: uri,
            range: try parseLocation(["uri": uri, "range": range]),
            selectionRange: try parseLocation([
                "uri": uri,
                "range": selectionRange,
            ]),
            data: data
        )
    }

    private func parseCallRelations(
        _ value: Any,
        itemKey: String,
        callSiteURI: (ExactCallHierarchyItem) -> String
    ) throws -> [ExactCallRelation]? {
        if value is NSNull { return nil }
        guard let objects = value as? [[String: Any]] else {
            throw ExactError.invalidDefinitionResponse(String(describing: value))
        }
        return try objects.map { object in
            guard let itemObject = object[itemKey] as? [String: Any],
                  let ranges = object["fromRanges"] as? [[String: Any]]
            else {
                throw ExactError.invalidDefinitionResponse(
                    String(describing: object)
                )
            }
            let item = try parseCallHierarchyItem(itemObject)
            let uri = callSiteURI(item)
            return ExactCallRelation(
                item: item,
                callSites: try ranges.map {
                    try parseLocation(["uri": uri, "range": $0])
                }
            )
        }
    }

    private func callHierarchyItemObject(
        _ item: ExactCallHierarchyItem
    ) throws -> [String: Any] {
        var object: [String: Any] = [
            "name": item.name,
            "kind": item.kind,
            "uri": item.uri,
            "range": try lspRange(for: item.range),
            "selectionRange": try lspRange(for: item.selectionRange),
        ]
        if let data = item.data {
            object["data"] = try JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
            )
        }
        return object
    }

    private func lspRange(for location: ExactLocation) throws -> [String: Any] {
        let bytes: [UInt8]
        if location.file.hasPrefix("/") {
            bytes = [UInt8](try Data(
                contentsOf: URL(fileURLWithPath: location.file),
                options: .mappedIfSafe
            ))
        } else {
            bytes = try snapshot.readBytes(path: relativePath(location.file))
        }
        guard let map = LSPPositionMap(utf8: bytes) else {
            throw ExactError.invalidUTF8(location.file)
        }
        guard let position = map.position(forByteOffset: location.byteOffset) else {
            throw ExactError.invalidPosition(location.file, location.byteOffset)
        }
        let point = ["line": position.line, "character": position.character]
        return ["start": point, "end": point]
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
        return try parseLocation(object)
    }

    private func parseImplementations(_ value: Any) throws -> [ExactLocation]? {
        if value is NSNull { return nil }
        let objects: [[String: Any]]
        if let dictionary = value as? [String: Any] {
            objects = [dictionary]
        } else if let array = value as? [[String: Any]] {
            objects = array
        } else {
            throw ExactError.invalidDefinitionResponse(String(describing: value))
        }
        return try objects.map(parseLocation)
    }

    private func parseLocation(_ object: [String: Any]) throws -> ExactLocation {
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

    private func throwIfCancelled(_ method: String) throws {
        stateLock.lock()
        let wasCancelled = cancelled
        stateLock.unlock()
        if wasCancelled { throw LSPError.cancelled(method) }
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

func rustAnalyzerCoverage(
    base: ExactCoverage,
    diagnostic: String
) -> ExactCoverage {
    let diagnostic = diagnostic.lowercased()
    let offline = diagnostic.contains("--offline")
        || diagnostic.contains("offline mode")
        || diagnostic.contains("cargo_net_offline")
    let dependencyFailure = diagnostic.contains("failed to download")
        || diagnostic.contains("no matching package named")
        || diagnostic.contains("attempting to make an http request")
        || diagnostic.contains("can't check for updates in offline mode")
    guard offline,
          dependencyFailure
    else { return base }
    return .dependenciesUnavailableOffline
}
