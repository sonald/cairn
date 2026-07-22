import CodeInsightCore
import Foundation

struct Sandbox: Sendable {
    static let cpuTimeLimitSeconds: UInt64 = 60
    // macOS maps the dyld shared cache into a large virtual address range.
    static let addressSpaceLimitKiB: UInt64 = 512 * 1024 * 1024

    let executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
    let arguments: [String]
    let environment: [String: String]
    let workingDirectoryURL: URL

    init(
        projectURL: URL,
        cacheURL: URL,
        trustMode: TrustMode,
        helperURL: URL,
        helperArguments: [String] = []
    ) throws {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ExactError.unavailable("sandbox-exec is not available")
        }

        let project = projectURL.standardizedFileURL
        try FileManager.default.createDirectory(
            at: cacheURL,
            withIntermediateDirectories: true
        )
        let cache = cacheURL.standardizedFileURL
        let canonicalProject = project.resolvingSymlinksInPath()
        let canonicalCache = cache.resolvingSymlinksInPath()
        guard
            !canonicalCache.pathComponents.starts(
                with: canonicalProject.pathComponents
            )
        else {
            throw ExactError.unavailable(
                "private cache must be outside the project root"
            )
        }

        let temporary = cache.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: true
        )
        var environment = ProcessInfo.processInfo.environment
        environment["TMPDIR"] = temporary.path
        environment["XDG_CACHE_HOME"] = cache.path
        environment["CARGO_NET_OFFLINE"] = "1"

        let profile = Self.profile(
            projectURLs: Self.aliases(project),
            cacheURLs: Self.aliases(cache),
            trustMode: trustMode
        )
        let prefix = [
            "-p", profile,
            "/bin/sh", "-c", Self.rlimitScript, "codeinsight-rlimit",
            String(Self.cpuTimeLimitSeconds),
            String(Self.addressSpaceLimitKiB),
        ]
        arguments =
            prefix + [helperURL.standardizedFileURL.path]
            + helperArguments
        self.environment = environment
        workingDirectoryURL = project

        try probe(profile: profile, environment: environment, projectURL: project)
    }

    private func probe(
        profile: String,
        environment: [String: String],
        projectURL: URL
    ) throws {
        let process = Process()
        let errors = Pipe()
        process.executableURL = executableURL
        process.arguments = [
            "-p", profile,
            "/bin/sh", "-c", Self.rlimitScript, "codeinsight-rlimit",
            String(Self.cpuTimeLimitSeconds),
            String(Self.addressSpaceLimitKiB),
            "/usr/bin/true",
        ]
        process.environment = environment
        process.currentDirectoryURL = projectURL
        process.standardOutput = errors
        process.standardError = errors
        do {
            try process.run()
        } catch {
            throw ExactError.unavailable("sandbox-exec failed to start: \(error)")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail =
                String(
                    data: errors.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ExactError.unavailable(
                "sandbox-exec initialization failed"
                    + (detail.isEmpty ? "" : ": \(detail)")
            )
        }
    }

    private static func profile(
        projectURLs: [URL],
        cacheURLs: [URL],
        trustMode: TrustMode
    ) -> String {
        var writable =
            cacheURLs.map {
                "(subpath \"\(escaped($0.path))\")"
            } + [
                "(literal \"/dev/null\")"
            ]
        if case .trusted = trustMode {
            writable += projectURLs.map {
                let target = $0.appendingPathComponent(
                    "target",
                    isDirectory: true
                )
                return "(subpath \"\(escaped(target.path))\")"
            }
        }
        return """
            (version 1)
            (deny default)
            (import "system.sb")
            (allow file-read*)
            (allow process*)
            (allow file-write*
              \(writable.joined(separator: "\n  ")))
            (deny file-write-create (prefix "/cores/"))
            (deny network*)
            """
    }

    private static func escaped(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func aliases(_ url: URL) -> [URL] {
        var paths = Set([
            url.standardizedFileURL.path,
            url.resolvingSymlinksInPath().path,
        ])
        for path in Array(paths) where path == "/var" || path.hasPrefix("/var/") {
            paths.insert("/private\(path)")
        }
        return paths.sorted().map { URL(fileURLWithPath: $0) }
    }

    private static let rlimitScript = """
        ulimit -S -t "$1" || exit 125
        ulimit -S -v "$2" || exit 125
        shift 2
        exec "$@"
        """
}
