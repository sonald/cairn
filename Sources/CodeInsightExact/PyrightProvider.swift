import CodeInsightCore
import CodeInsightGit
import Foundation

public final class PyrightProvider: ExactProvider, @unchecked Sendable {
    public static let supportedCapabilities: ExactCapabilities = [
        .definition,
        .references,
        .callHierarchy,
        .hover,
    ]

    public let language: LanguageID = .python
    public let capabilities: ExactCapabilities = PyrightProvider.supportedCapabilities
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
        let project = projectURL.standardizedFileURL
        self.projectURL = project
        self.executableURL = executableURL.standardizedFileURL
        self.cacheURL = cacheURL ?? Self.defaultCacheURL
        self.requestTimeout = requestTimeout
        self.closeGrace = closeGrace

        let canonicalProject = project.resolvingSymlinksInPath()
        try Self.requireOutsideProject(
            self.executableURL,
            projectURL: canonicalProject
        )
        let companion = self.executableURL
            .deletingLastPathComponent()
            .appendingPathComponent("pyright")
        try Self.requireOutsideProject(
            companion,
            projectURL: canonicalProject
        )
        guard FileManager.default.isExecutableFile(atPath: companion.path) else {
            throw ExactError.unavailable(
                "pyright companion CLI is missing next to pyright-langserver"
            )
        }
        let version = try Self.readCompilerVersion(
            projectURL: project,
            cacheURL: self.cacheURL,
            executableURL: companion
        )
        let interpreter = Self.interpreterIdentity(
            projectURL: project,
            cacheURL: self.cacheURL,
            environment: ProcessInfo.processInfo.environment
        )
        toolVersion = [
            version.isEmpty ? "pyright unknown" : version,
            interpreter,
        ].joined(separator: " | ")
    }

    public static func findExecutable(
        projectURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        guard let found = CodeInsightExact.findExecutable(
            named: "pyright-langserver",
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
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .appendingPathComponent(
                candidateURL.lastPathComponent
            )
            .standardizedFileURL.path
        let project = projectURL.resolvingSymlinksInPath()
            .standardizedFileURL.path
        guard candidate != project,
              candidate != project + "/",
              project != "/",
              !candidate.hasPrefix(project + "/")
        else {
            throw ExactError.unavailable(
                "pyright executable is inside the project root"
            )
        }
    }

    private static func readCompilerVersion(
        projectURL: URL,
        cacheURL: URL,
        executableURL: URL
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
                "pyright --version exited \(process.terminationStatus)"
            )
        }
        return String(data: output, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func interpreterIdentity(
        projectURL: URL,
        cacheURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let directories = executableSearchDirectories(
            environment: environment,
            projectRoot: projectURL
        )
        for name in ["python3", "python"] {
            for directory in directories {
                let candidate = directory.appendingPathComponent(name)
                    .standardizedFileURL
                guard FileManager.default.isExecutableFile(
                    atPath: candidate.path
                ) else { continue }
                let process = Process()
                let pipe = Pipe()
                process.executableURL = candidate.resolvingSymlinksInPath()
                process.arguments = ["--version"]
                process.currentDirectoryURL = projectURL
                process.environment = sanitizedChildEnvironment(
                    environment,
                    projectRoot: projectURL
                )
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                    process.waitUntilExit()
                    let output = pipe.fileHandleForReading.readDataToEndOfFile()
                    guard process.terminationStatus == 0 else {
                        return "interpreter=unavailable"
                    }
                    let version = String(data: output, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return "interpreter=\(candidate.resolvingSymlinksInPath().path)"
                        + (version.isEmpty ? "" : " \(version)")
                } catch {
                    return "interpreter=unavailable"
                }
            }
        }
        return "interpreter=unavailable"
    }

    private func safeLaunch(
        helperURL: URL,
        helperArguments: [String]
    ) throws -> Sandbox {
        try Sandbox(
            projectURL: projectURL,
            cacheURL: cacheURL,
            trustMode: .safe,
            helperURL: helperURL,
            helperArguments: helperArguments
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

    static func baseEnvironment(trustMode: TrustMode) -> ExactAnalysisEnvironment {
        ExactAnalysisEnvironment(
            trustMode: trustMode,
            limitations: [.dependenciesUnavailableOffline]
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
        let environment = Self.baseEnvironment(trustMode: trustMode)
        let launch = try safeLaunch(
            helperURL: executableURL,
            helperArguments: ["--stdio"]
        )
        let client = try LSPClient(
            executableURL: launch.executableURL,
            arguments: launch.arguments,
            workingDirectory: launch.workingDirectoryURL,
            environment: sanitizedChildEnvironment(
                launch.environment,
                projectRoot: projectURL
            )
        )
        do {
            return try LSPLanguageSession.start(
                client: client,
                restartClient: {
                    let restart = try self.safeLaunch(
                        helperURL: self.executableURL,
                        helperArguments: ["--stdio"]
                    )
                    return try LSPClient(
                        executableURL: restart.executableURL,
                        arguments: restart.arguments,
                        workingDirectory: restart.workingDirectoryURL,
                        environment: sanitizedChildEnvironment(
                            restart.environment,
                            projectRoot: self.projectURL
                        )
                    )
                },
                projectURL: projectURL,
                snapshot: snapshot,
                language: .pyright,
                requestTimeout: requestTimeout,
                closeGrace: closeGrace,
                attribution: ExactAttribution(
                    provider: "pyright",
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
    static var pyright: LSPLanguageSpec {
        LSPLanguageSpec(
            serverName: "pyright",
            capabilities: {
                advertisedCapabilities($0, [
                    "definitionProvider": .definition,
                    "callHierarchyProvider": .callHierarchy,
                    "referencesProvider": .references,
                    "hoverProvider": .hover,
                ]).intersection(PyrightProvider.supportedCapabilities)
            },
            languageID: { _ in "python" }
        )
    }
}
