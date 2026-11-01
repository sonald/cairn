import CodeInsightCore
import Foundation

/// How to put a unit's missing dependencies on this Mac. Analysis itself
/// stays offline; the only download Cairn runs is `cargo fetch --locked`,
/// which writes `~/.cargo` alone and runs no project code. The rest are
/// commands the user runs, since they execute install scripts and write
/// into the repository.
public struct DependencySetup: Equatable, Sendable {
    public let command: String
    /// Where the command runs.
    public let directory: URL
    public let runsInApp: Bool
    let language: LanguageID
    let unitRoot: URL

    /// `unitRoot` is the directory the server analyzes: for a commit, the
    /// checkout (its `Cargo.lock` is the commit's); TypeScript and Python
    /// pass the workspace unit, whose installs a commit borrows.
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

    /// Runs `cargo fetch --locked` with the network allowed. Cancelling the
    /// task terminates cargo. Throws with cargo's last stderr line.
    public func fetch() async throws {
        precondition(runsInApp)
        // A Finder launch's PATH lacks rustup's `~/.cargo/bin`.
        let cargoHome = ProcessInfo.processInfo.environment["CARGO_HOME"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cargo")
        let rustup = cargoHome.appendingPathComponent("bin/cargo")
        guard let cargo = FileManager.default.isExecutableFile(atPath: rustup.path)
            ? rustup : findExecutable(named: "cargo")
        else {
            throw ExactError.unavailable("cargo not found")
        }
        let process = Process()
        process.executableURL = cargo
        process.arguments = ["fetch", "--locked"]
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "CARGO_NET_OFFLINE")
        environment["CARGO_TERM_COLOR"] = "never"
        // rustup's cargo proxy finds rustc through PATH.
        environment["PATH"] = ([cargo.deletingLastPathComponent()] + executableSearchDirectories())
            .map(\.path).joined(separator: ":")
        process.environment = environment
        // A file, not a pipe: cargo logs one line per crate and a full pipe would stall it.
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("cairn-cargo-fetch-\(UUID().uuidString).log")
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
            throw ExactError.unavailable(lastLine ?? "cargo fetch exited with status \(status)")
        }
    }
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
