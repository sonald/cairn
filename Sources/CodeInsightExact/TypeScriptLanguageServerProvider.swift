import CodeInsightCore
import CodeInsightGit
import Foundation

public final class TypeScriptLanguageServerProvider: ExactProvider, @unchecked Sendable {
    public static let supportedCapabilities: ExactCapabilities = [
        .definition,
        .implementations,
        .callHierarchy,
        .references,
        .hover,
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

    @usableFromInline
    package static func tsserverURL(
        fromLanguageServer languageServerURL: URL
    ) -> URL? {
        let resolved = languageServerURL.resolvingSymlinksInPath()
            .standardizedFileURL
        let nodeModulesRoot = resolved
            .deletingLastPathComponent()  // lib
            .deletingLastPathComponent()  // typescript-language-server
            .deletingLastPathComponent()  // node_modules
        guard nodeModulesRoot.lastPathComponent == "node_modules" else {
            return nil
        }
        let candidate = nodeModulesRoot
            .appendingPathComponent("typescript/lib/tsserver.js")
        guard FileManager.default.isReadableFile(atPath: candidate.path) else {
            return nil
        }
        return candidate
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
            return try LSPLanguageSession.start(
                client: client,
                restartClient: {
                    try Self.client(
                        for: try self.safeLaunch(),
                        projectURL: self.projectURL
                    )
                },
                projectURL: projectURL,
                snapshot: snapshot,
                language: .typeScript(
                    initializationOptions: initializationOptions()
                ),
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

extension LSPLanguageSpec {
    static func typeScript(
        initializationOptions: [String: Any]
    ) -> LSPLanguageSpec {
        LSPLanguageSpec(
            serverName: "typescript",
            initializationOptions: initializationOptions,
            capabilities: {
                advertisedCapabilities($0, [
                    "definitionProvider": .definition,
                    "implementationProvider": .implementations,
                    "callHierarchyProvider": .callHierarchy,
                    "referencesProvider": .references,
                    "hoverProvider": .hover,
                ]).intersection(
                    TypeScriptLanguageServerProvider.supportedCapabilities
                )
            },
            startupCheck: { negotiated in
                guard negotiated.contains(.definition),
                      negotiated.contains(.references)
                else {
                    throw ExactError.unavailable(
                        "typescript-language-server must advertise definition and references"
                    )
                }
            },
            acceptsPath: {
                LanguageMode.classify(path: $0, language: .typescript) != nil
            },
            languageID: {
                $0.hasSuffix(".tsx") ? "typescriptreact" : "typescript"
            }
        )
    }
}
