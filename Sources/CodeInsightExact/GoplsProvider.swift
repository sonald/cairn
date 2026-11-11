import CodeInsightCore
import CodeInsightGit
import Foundation

public final class GoplsProvider: ExactProvider, @unchecked Sendable {
    public static let supportedCapabilities: ExactCapabilities = [
        .definition,
        .references,
        .callHierarchy,
        .hover,
        .implementations,
        .typeDefinition,
    ]

    public let language: LanguageID = .go
    public let capabilities: ExactCapabilities = GoplsProvider.supportedCapabilities
    public let toolVersion: String

    private let projectURL: URL
    private let executableURL: URL
    private let goURL: URL
    private let cacheURL: URL
    private let requestTimeout: TimeInterval
    private let closeGrace: TimeInterval
    /// Merged last into every Go child's environment (tests point
    /// `GOMODCACHE` at their own directory).
    private let environmentOverrides: [String: String]

    /// `goURL` is the toolchain gopls runs `go list` with; it goes first on
    /// the server's PATH. Both must live outside the project.
    public convenience init(
        projectURL: URL,
        executableURL: URL,
        goURL: URL,
        cacheURL: URL? = nil,
        requestTimeout: TimeInterval = 30,
        closeGrace: TimeInterval = 1
    ) throws {
        try self.init(
            projectURL: projectURL,
            executableURL: executableURL,
            goURL: goURL,
            cacheURL: cacheURL,
            requestTimeout: requestTimeout,
            closeGrace: closeGrace,
            environmentOverrides: [:]
        )
    }

    init(
        projectURL: URL,
        executableURL: URL,
        goURL: URL,
        cacheURL: URL?,
        requestTimeout: TimeInterval,
        closeGrace: TimeInterval,
        environmentOverrides: [String: String]
    ) throws {
        let project = projectURL.standardizedFileURL
        self.projectURL = project
        self.executableURL = executableURL.standardizedFileURL
        self.goURL = goURL.standardizedFileURL
        self.cacheURL = cacheURL ?? Self.defaultCacheURL
        self.requestTimeout = requestTimeout
        self.closeGrace = closeGrace
        self.environmentOverrides = environmentOverrides
        for tool in [self.executableURL, self.goURL] {
            try Self.requireOutsideProject(tool, projectURL: project)
            guard FileManager.default.isExecutableFile(atPath: tool.path) else {
                throw ExactError.unavailable(
                    "\(tool.lastPathComponent) is missing or not executable: \(tool.path)"
                )
            }
        }
        let environment = { [project, goURL = self.goURL, cache = self.cacheURL] in
            Self.childEnvironment(
                $0, projectURL: project, goURL: goURL, cacheURL: cache,
                overrides: environmentOverrides
            )
        }
        let gopls = try Self.readVersion(
            of: self.executableURL, arguments: ["version", "-json"],
            projectURL: project, cacheURL: self.cacheURL, environment: environment
        )
        let go = try Self.readVersion(
            of: self.goURL, arguments: ["version"],
            projectURL: project, cacheURL: self.cacheURL, environment: environment
        )
        toolVersion = Self.goplsVersion(gopls)
            + " | \(go.isEmpty ? "go unknown" : go)"
            + " | go=\(self.goURL.resolvingSymlinksInPath().path)"
    }

    /// `gopls` or `go` on PATH, the Homebrew directories, `$GOBIN`,
    /// every `$GOPATH/bin` (default `~/go/bin`, where `go install` puts
    /// gopls) and `/usr/local/go/bin`; never inside the project.
    public static func findExecutable(
        named name: String,
        projectURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        let home = environment["HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        let gopath = environment["GOPATH"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "\(home)/go"
        var search = environment
        search["PATH"] = (
            [environment["PATH", default: ""]]
                + [environment["GOBIN"]].compactMap { $0 }
                + gopath.split(separator: ":").map { "\($0)/bin" }
                + ["/usr/local/go/bin"]
        ).joined(separator: ":")
        guard let found = CodeInsightExact.findExecutable(
            named: name,
            environment: search,
            projectRoot: projectURL
        ), (try? requireOutsideProject(found, projectURL: projectURL)) != nil
        else { return nil }
        return found
    }

    static func requireOutsideProject(_ url: URL, projectURL: URL) throws {
        let tool = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let project = projectURL.resolvingSymlinksInPath().standardizedFileURL
            .pathComponents
        guard project.count > 1, !tool.starts(with: project) else {
            throw ExactError.unavailable(
                "\(url.lastPathComponent) is inside the project root"
            )
        }
    }

    /// The environment of every Go child: `gopls serve`, `gopls version`
    /// and `go version`. Set here because only Go children read these and
    /// the caches must sit in the sandbox's one writable directory:
    /// without `GOCACHE`/`GOPLSCACHE` there, references come back empty
    /// (docs/evidence/go-feasibility-2026-11 §4). `GOTOOLCHAIN=local`
    /// keeps go from fetching a newer toolchain and makes it say which
    /// version `go.mod` needs; `GOPROXY=off` fails module lookups at once
    /// instead of at the network wall. An inherited `GOFLAGS` is dropped:
    /// `-mod=readonly` breaks repositories that vendor. cgo stays on.
    static func childEnvironment(
        _ launch: [String: String],
        projectURL: URL,
        goURL: URL,
        cacheURL: URL,
        overrides: [String: String]
    ) -> [String: String] {
        var environment = sanitizedChildEnvironment(launch, projectRoot: projectURL)
        // A Finder launch's PATH lacks the toolchain gopls shells out to.
        environment["PATH"] = goURL.resolvingSymlinksInPath()
            .deletingLastPathComponent().path
            + ":" + environment["PATH", default: ""]
        environment["GOCACHE"] = cacheURL.appendingPathComponent("go-build").path
        environment["GOPLSCACHE"] = cacheURL.appendingPathComponent("gopls").path
        environment["GOTOOLCHAIN"] = "local"
        environment["GOPROXY"] = "off"
        environment.removeValue(forKey: "GOFLAGS")
        environment.merge(overrides) { $1 }
        return environment
    }

    private func childEnvironment(_ launch: [String: String]) -> [String: String] {
        Self.childEnvironment(
            launch, projectURL: projectURL, goURL: goURL, cacheURL: cacheURL,
            overrides: environmentOverrides
        )
    }

    private static func readVersion(
        of tool: URL,
        arguments: [String],
        projectURL: URL,
        cacheURL: URL,
        environment: ([String: String]) -> [String: String]
    ) throws -> String {
        let launch = try Sandbox(
            projectURL: projectURL,
            cacheURL: cacheURL,
            trustMode: .safe,
            helperURL: tool,
            helperArguments: arguments
        )
        let process = Process()
        let pipe = Pipe()
        process.executableURL = launch.executableURL
        process.arguments = launch.arguments
        process.currentDirectoryURL = launch.workingDirectoryURL
        process.environment = environment(launch.environment)
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ExactError.unavailable(
                "\(tool.lastPathComponent) \(arguments.joined(separator: " ")) exited "
                    + "\(process.terminationStatus)"
            )
        }
        return String(data: output, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// "gopls v0.19.1 (go1.24.5)" from `gopls version -json`.
    private static func goplsVersion(_ output: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(output.utf8))
            as? [String: Any],
            let version = (object["Main"] as? [String: Any])?["Version"] as? String
        else { return output.isEmpty ? "gopls unknown" : output }
        let built = (object["GoVersion"] as? String).map { " (\($0))" } ?? ""
        return "gopls \(version)\(built)"
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

    private func makeClient() throws -> LSPClient {
        let launch = try Sandbox(
            projectURL: projectURL,
            cacheURL: cacheURL,
            trustMode: .safe,
            helperURL: executableURL,
            helperArguments: ["serve"]
        )
        return try LSPClient(
            executableURL: launch.executableURL,
            arguments: launch.arguments,
            workingDirectory: launch.workingDirectoryURL,
            environment: childEnvironment(launch.environment)
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
        let client = try makeClient()
        do {
            return try LSPLanguageSession.start(
                client: client,
                restartClient: { try self.makeClient() },
                projectURL: projectURL,
                snapshot: snapshot,
                language: .gopls,
                requestTimeout: requestTimeout,
                closeGrace: closeGrace,
                attribution: ExactAttribution(
                    provider: "gopls",
                    toolVersion: toolVersion,
                    configFingerprint: profile.configFingerprint,
                    environmentFingerprint: profile.environmentFingerprint,
                    featureSelection: profile.featureSelection,
                    environment: ExactAnalysisEnvironment(trustMode: trustMode),
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
    static var gopls: LSPLanguageSpec {
        LSPLanguageSpec(
            serverName: "gopls",
            // gopls holds requests while it loads the workspace (13 s for
            // the standard library, evidence §6) and says when it is done.
            requestFlow: .awaitQuiescence,
            workspaceLoad: (title: "Setting up workspace", limit: 300),
            capabilities: {
                advertisedCapabilities($0, [
                    "definitionProvider": .definition,
                    "referencesProvider": .references,
                    "callHierarchyProvider": .callHierarchy,
                    "hoverProvider": .hover,
                    "implementationProvider": .implementations,
                    "typeDefinitionProvider": .typeDefinition,
                ]).intersection(GoplsProvider.supportedCapabilities)
            },
            acceptsPath: { LanguageMode.classify(path: $0, language: .go) != nil },
            languageID: { _ in "go" },
            onDiagnostic: goplsEnvironment,
            unavailableReason: goplsUnavailableReason
        )
    }
}

/// Module lookups fail when the module cache lacks what the unit needs.
/// A module without a pruned graph (`go` < 1.17) fails `go list` as a
/// whole and gopls logs the lookup failure (evidence §3).
func goplsEnvironment(
    base: ExactAnalysisEnvironment,
    diagnostic: String
) -> ExactAnalysisEnvironment {
    guard diagnostic.contains("module lookup disabled by GOPROXY=off") else { return base }
    var limitations = base.limitations
    limitations.insert(.dependenciesUnavailableOffline)
    return ExactAnalysisEnvironment(trustMode: base.trustMode, limitations: limitations)
}

/// go's own words when `go.mod` (or a dependency) needs a newer Go than the
/// local toolchain, e.g. "go.mod requires go >= 1.99 (running go 1.27.3;
/// GOTOOLCHAIN=local)": no package loads, and no restart changes that.
func goplsUnavailableReason(_ diagnostic: String) -> String? {
    diagnostic.firstMatch(of: #/\S+ requires go >= \S+ \(running go [^)]*\)/#)
        .map { String($0.output) }
}
