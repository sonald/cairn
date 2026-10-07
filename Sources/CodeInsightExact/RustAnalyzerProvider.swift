import CodeInsightCore
import CodeInsightGit
import Foundation

public final class RustAnalyzerProvider: ExactProvider, @unchecked Sendable {
    public let language: LanguageID = .rust
    public let capabilities: ExactCapabilities = [
        .definition, .implementations, .callHierarchy, .references, .hover,
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
            return try LSPLanguageSession.start(
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
                language: .rustAnalyzer(
                    initializationOptions: options,
                    diagnosticObserver: diagnosticObserver
                ),
                requestTimeout: requestTimeout,
                closeGrace: closeGrace,
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


extension LSPLanguageSpec {
    static func rustAnalyzer(
        initializationOptions: [String: Any],
        diagnosticObserver: (@Sendable (String) -> Void)?
    ) -> LSPLanguageSpec {
        LSPLanguageSpec(
            serverName: "rust-analyzer",
            initializationOptions: initializationOptions,
            requestFlow: .awaitQuiescence,
            capabilities: {
                // Definition is assumed; the advertised set is not narrowed.
                ExactCapabilities.definition.union(advertisedCapabilities($0, [
                    "implementationProvider": .implementations,
                    "typeDefinitionProvider": .typeDefinition,
                    "callHierarchyProvider": .callHierarchy,
                    "referencesProvider": .references,
                    "hoverProvider": .hover,
                ]))
            },
            languageID: { _ in "rust" },
            onDiagnostic: { base, diagnostic in
                diagnosticObserver?(diagnostic)
                return rustAnalyzerEnvironment(base: base, diagnostic: diagnostic)
            }
        )
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
