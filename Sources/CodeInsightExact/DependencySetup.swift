import CodeInsightCore
import Foundation

/// How to put a unit's missing dependencies on this Mac. Analysis itself
/// stays offline; the downloads Cairn runs are `cargo fetch --locked` and
/// `go mod download`, which write only the user's cargo or module cache and
/// run no project code. The rest are commands the user runs, since they
/// execute install scripts and write into the repository.
public struct DependencySetup: Equatable, Sendable {
    public let command: String
    /// Where the command runs.
    public let directory: URL
    public let runsInApp: Bool
    let language: LanguageID
    let unitRoot: URL

    /// `unitRoot` is the directory the server analyzes: for a commit, the
    /// checkout (its `Cargo.lock` or `go.sum` is the commit's); TypeScript
    /// and Python pass the workspace unit, whose installs a commit borrows.
    public static func suggestion(language: LanguageID, unitRoot: URL) -> DependencySetup? {
        let unit = unitRoot.standardizedFileURL
        switch language {
        case .rust:
            // Without a lock file `cargo fetch` would write one into the repository.
            let locked = nearestAncestor(of: unit, containing: ["Cargo.lock"]) != nil
            return DependencySetup(
                command: locked ? "cargo fetch --locked" : "cargo fetch",
                directory: unit,
                runsInApp: locked,
                language: language,
                unitRoot: unit
            )
        case .typescript:
            let managers = [
                ("pnpm-lock.yaml", "pnpm install"),
                ("yarn.lock", "yarn install"),
                ("bun.lock", "bun install"),
                ("bun.lockb", "bun install"),
                ("package-lock.json", "npm install"),
            ]
            if let (directory, lock) = nearestAncestor(of: unit, containing: managers.map(\.0)),
               let command = managers.first(where: { $0.0 == lock })?.1
            {
                return DependencySetup(
                    command: command, directory: directory, runsInApp: false,
                    language: language, unitRoot: unit
                )
            }
            return DependencySetup(
                command: "npm install", directory: unit, runsInApp: false,
                language: language, unitRoot: unit
            )
        case .python:
            let fileManager = FileManager.default
            func has(_ name: String) -> Bool {
                fileManager.fileExists(atPath: unit.appendingPathComponent(name).path)
            }
            // Pyright looks for `.venv`/`venv` in the unit root.
            let command = if has("uv.lock") {
                "uv sync"
            } else if has("poetry.lock") {
                "POETRY_VIRTUALENVS_IN_PROJECT=true poetry install"
            } else if has("requirements.txt") {
                "python3 -m venv .venv && .venv/bin/pip install -r requirements.txt"
            } else {
                "python3 -m venv .venv && .venv/bin/pip install -e ."
            }
            return DependencySetup(
                command: command, directory: unit, runsInApp: false,
                language: language, unitRoot: unit
            )
        case .go:
            // A vendored unit has its dependencies; without `go.sum` the
            // download would not be pinned by the repository.
            let fileManager = FileManager.default
            let vendored = fileManager.fileExists(atPath: unit.appendingPathComponent("vendor").path)
            let summed = goModules(unitRoot: unit).allSatisfy {
                fileManager.fileExists(atPath: $0.appendingPathComponent("go.sum").path)
            }
            return DependencySetup(
                command: "go mod download", directory: unit, runsInApp: summed && !vendored,
                language: language, unitRoot: unit
            )
        default:
            return nil
        }
    }

    /// Whether a user install has landed since analysis started. Rust has
    /// no cheap marker; its download restarts analysis itself.
    public var isInstalled: Bool {
        switch language {
        case .typescript:
            nodeModulesIsVisible(from: unitRoot)
        case .python:
            DependencyBorrowing.pythonInterpreter(unitRoot: unitRoot) != nil
        default:
            false
        }
    }

    /// Runs the download with the network allowed: `cargo fetch --locked`,
    /// or for Go `go mod download` per module. Cancelling the task
    /// terminates the tool. Throws with the tool's last stderr line.
    public func fetch() async throws {
        try await fetch(environment: ProcessInfo.processInfo.environment)
    }

    func fetch(environment inherited: [String: String]) async throws {
        precondition(runsInApp)
        if language == .go {
            try await fetchGoModules(environment: inherited)
            return
        }
        // A Finder launch's PATH lacks rustup's `~/.cargo/bin`.
        let cargoHome = inherited["CARGO_HOME"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cargo")
        let rustup = cargoHome.appendingPathComponent("bin/cargo")
        guard let cargo = FileManager.default.isExecutableFile(atPath: rustup.path)
            ? rustup : findExecutable(named: "cargo", environment: inherited)
        else {
            throw ExactError.unavailable("cargo not found")
        }
        var environment = inherited
        environment.removeValue(forKey: "CARGO_NET_OFFLINE")
        environment["CARGO_TERM_COLOR"] = "never"
        // rustup's cargo proxy finds rustc through PATH.
        environment["PATH"] = ([cargo.deletingLastPathComponent()] + executableSearchDirectories(environment: inherited))
            .map(\.path).joined(separator: ":")
        try await Self.run(cargo, ["fetch", "--locked"], in: directory, environment: environment)
    }

    /// `go mod download` would rewrite an incomplete `go.sum`, so each module
    /// downloads against copies of its `go.mod`/`go.sum` outside the
    /// repository (`-modfile`); `-modfile` is refused in workspace mode,
    /// hence `GOWORK=off` (evidence §5). `GOTOOLCHAIN=local` makes a
    /// too-new `go.mod` fail with go's own words instead of fetching a
    /// toolchain.
    private func fetchGoModules(environment inherited: [String: String]) async throws {
        guard let go = GoplsProvider.findExecutable(
            named: "go", projectURL: unitRoot, environment: inherited
        ) else {
            throw ExactError.unavailable("go not found")
        }
        var environment = inherited
        environment["GOWORK"] = "off"
        environment["GOTOOLCHAIN"] = "local"
        // `direct` module paths fetch with git.
        environment["PATH"] = ([go.resolvingSymlinksInPath().deletingLastPathComponent()]
            + executableSearchDirectories(environment: inherited))
            .map(\.path).joined(separator: ":")
        let fileManager = FileManager.default
        for module in goModules(unitRoot: unitRoot) {
            let copy = fileManager.temporaryDirectory
                .appendingPathComponent("cairn-go-mod-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: copy, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: copy) }
            for name in ["go.mod", "go.sum"]
            where fileManager.fileExists(atPath: module.appendingPathComponent(name).path) {
                try fileManager.copyItem(
                    at: module.appendingPathComponent(name),
                    to: copy.appendingPathComponent(name)
                )
            }
            do {
                try await Self.run(
                    go,
                    ["mod", "download", "-modfile=" + copy.appendingPathComponent("go.mod").path],
                    in: module,
                    environment: environment
                )
            } catch ExactError.unavailable(let detail) {
                // go names the copy; say which of the unit's files it means.
                let relative = projectRelativePath(of: module, projectURL: unitRoot) ?? module.path
                throw ExactError.unavailable(detail.replacingOccurrences(
                    of: copy.path + "/",
                    with: relative.isEmpty ? "" : relative + "/"
                ))
            }
        }
    }

    private static func run(
        _ tool: URL,
        _ arguments: [String],
        in directory: URL,
        environment: [String: String]
    ) async throws {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        // A file, not a pipe: the tool logs one line per package and a full pipe would stall it.
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("cairn-\(tool.lastPathComponent)-fetch-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: log) }
        process.standardError = try FileHandle(forWritingTo: log)
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do {
                    try Task.checkCancellation()
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            // Terminating a process that never launched raises.
            if process.isRunning { process.terminate() }
        }
        try Task.checkCancellation()
        guard status == 0 else {
            let output = String(decoding: (try? Data(contentsOf: log)) ?? Data(), as: UTF8.self)
            let lastLine = output.split(whereSeparator: \.isNewline).last.map(String.init)
            throw ExactError.unavailable(
                lastLine ?? "\(tool.lastPathComponent) \(arguments[0]) exited with status \(status)"
            )
        }
    }
}

/// The modules a Go unit downloads for: each `use` directory of its
/// `go.work`, else the unit itself.
func goModules(unitRoot: URL) -> [URL] {
    guard let work = try? String(
        contentsOf: unitRoot.appendingPathComponent("go.work"),
        encoding: .utf8
    ) else { return [unitRoot] }
    var modules: [URL] = []
    var inBlock = false
    for raw in work.split(whereSeparator: \.isNewline) {
        var line = raw.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespaces)
        if inBlock {
            if line == ")" { inBlock = false; continue }
        } else if line == "use (" || line == "use(" {
            inBlock = true
            continue
        } else if line.hasPrefix("use ") {
            line = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
        } else {
            continue
        }
        let path = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"`"))
        guard !path.isEmpty else { continue }
        modules.append(
            (path.hasPrefix("/") ? URL(fileURLWithPath: path) : unitRoot.appendingPathComponent(path))
                .standardizedFileURL
        )
    }
    return modules
}

/// Node resolves packages from every ancestor's `node_modules`, so a
/// monorepo unit counts its root's install.
func nodeModulesIsVisible(from unitRoot: URL) -> Bool {
    nearestAncestor(of: unitRoot.standardizedFileURL, containing: ["node_modules"], directory: true) != nil
}

/// The closest of `directory` and its ancestors holding one of `names`
/// (earlier names win in the same directory).
private func nearestAncestor(
    of directory: URL,
    containing names: [String],
    directory wantsDirectory: Bool = false
) -> (URL, String)? {
    var current = directory
    while true {
        for name in names {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(
                atPath: current.appendingPathComponent(name).path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue == wantsDirectory {
                return (current, name)
            }
        }
        // `deletingLastPathComponent` of "/" is "/..", not "/".
        guard current.pathComponents.count > 1 else { return nil }
        current = current.deletingLastPathComponent().standardizedFileURL
    }
}
