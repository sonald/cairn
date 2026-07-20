import CryptoKit
import Foundation

public enum ProbeError: Error, LocalizedError {
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .failed(let detail): detail
        }
    }
}

public struct ProviderResult: Sendable {
    public let provider: String
    public let handshakeMilliseconds: Double
    public let queryMilliseconds: [Double]
    public let definitionPath: String
    public let definitionLine: Int
    public let definitionCharacter: Int
    public let configFingerprint: String
    public let environmentFingerprint: String
}

public struct SafeModeResult: Sendable {
    public let safeMarkerAbsent: Bool
    public let safeTargetAbsent: Bool
    public let defaultMarkerRan: Bool
    public let defaultTargetCreated: Bool
    public let safeHandshakeMilliseconds: Double
    public let safeQueryMilliseconds: Double
    public let defaultHandshakeMilliseconds: Double
    public let defaultQueryMilliseconds: Double
}

public struct MaterializeResult: Sendable {
    public let commit: String
    public let configFingerprint: String
    public let directory: String
    public let materializeMilliseconds: Double
    public let cacheHitMilliseconds: Double
    public let definitionLine: Int
    public let currentDefinitionLine: Int
}

private struct Fixture {
    let root: URL
    let definition: URL
    let caller: URL
    let languageID: String
    let callLine: Int
    let callCharacter: Int
    let expectedLine: Int
    let expectedCharacter: Int
    let config: URL
    let lockfiles: [URL]
    let oldCommit: String?
}

private struct DefinitionLocation {
    let path: String
    let line: Int
    let character: Int
}

private struct SessionResult {
    let handshakeMilliseconds: Double
    let queryMilliseconds: [Double]
    let locations: [DefinitionLocation]
}

public enum ExactProbe {
    private static var safeRustOptions: [String: Any] {
        [
            "cargo": ["buildScripts": ["enable": false]],
            "procMacro": ["enable": false],
            "checkOnSave": false,
        ]
    }

    public static func runRust(quiet: Bool = false) throws -> ProviderResult {
        let fixture = try makeRustFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        return try runProvider(
            name: "rust-analyzer",
            executable: executable(named: "rust-analyzer", preferred: "/opt/homebrew/bin/rust-analyzer"),
            arguments: [],
            fixture: fixture,
            initializationOptions: safeRustOptions,
            quiet: quiet
        )
    }

    public static func runTypeScript(quiet: Bool = false) throws -> ProviderResult {
        let fixture = try makeTypeScriptFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        return try runProvider(
            name: "typescript-language-server",
            executable: executable(named: "typescript-language-server"),
            arguments: ["--stdio"],
            fixture: fixture,
            initializationOptions: [:],
            quiet: quiet
        )
    }

    public static func runPython(quiet: Bool = false) throws -> ProviderResult {
        let fixture = try makePythonFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        return try runProvider(
            name: "pyright-langserver",
            executable: executable(named: "pyright-langserver"),
            arguments: ["--stdio"],
            fixture: fixture,
            initializationOptions: [:],
            quiet: quiet
        )
    }

    public static func runSafeMode(quiet: Bool = false) throws -> SafeModeResult {
        let fixture = try makeRustFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let marker = fixture.root.appendingPathComponent("BUILD_SCRIPT_RAN")
        let target = fixture.root.appendingPathComponent("target")
        let rustAnalyzer = executable(named: "rust-analyzer", preferred: "/opt/homebrew/bin/rust-analyzer")

        try removeIfPresent(marker)
        try removeIfPresent(target)
        let safe = try runDefinitions(
            executable: rustAnalyzer,
            arguments: [],
            fixture: fixture,
            initializationOptions: safeRustOptions,
            settleLimit: 2,
            settleUntil: { FileManager.default.fileExists(atPath: marker.path) || FileManager.default.fileExists(atPath: target.path) }
        )
        try assertLocations(safe.locations, fixture: fixture)
        let safeMarkerAbsent = !FileManager.default.fileExists(atPath: marker.path)
        let safeTargetAbsent = !FileManager.default.fileExists(atPath: target.path)
        guard safeMarkerAbsent, safeTargetAbsent else {
            throw ProbeError.failed("Safe Mode executed project code or created target/")
        }

        try removeIfPresent(marker)
        try removeIfPresent(target)
        let normal = try runDefinitions(
            executable: rustAnalyzer,
            arguments: [],
            fixture: fixture,
            initializationOptions: [:],
            settleLimit: 10,
            settleUntil: { FileManager.default.fileExists(atPath: marker.path) }
        )
        try assertLocations(normal.locations, fixture: fixture)
        let result = SafeModeResult(
            safeMarkerAbsent: safeMarkerAbsent,
            safeTargetAbsent: safeTargetAbsent,
            defaultMarkerRan: FileManager.default.fileExists(atPath: marker.path),
            defaultTargetCreated: FileManager.default.fileExists(atPath: target.path),
            safeHandshakeMilliseconds: safe.handshakeMilliseconds,
            safeQueryMilliseconds: safe.queryMilliseconds[0],
            defaultHandshakeMilliseconds: normal.handshakeMilliseconds,
            defaultQueryMilliseconds: normal.queryMilliseconds[0]
        )
        if !quiet {
            print("safemode markerAbsent=\(result.safeMarkerAbsent) targetAbsent=\(result.safeTargetAbsent)")
            print("default markerRan=\(result.defaultMarkerRan) targetCreated=\(result.defaultTargetCreated)")
            print("latency safe=\(milliseconds(result.safeHandshakeMilliseconds))/\(milliseconds(result.safeQueryMilliseconds)) ms default=\(milliseconds(result.defaultHandshakeMilliseconds))/\(milliseconds(result.defaultQueryMilliseconds)) ms (initialize/definition)")
        }
        return result
    }

    public static func runMaterialize(quiet: Bool = false) throws -> MaterializeResult {
        let fixture = try makeRustFixture(keepInCache: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        guard let oldCommit = fixture.oldCommit else { throw ProbeError.failed("fixture has no historical commit") }
        let configFingerprint = try fingerprint(files: [fixture.config])
        let cacheRoot = cacheDirectory()
            .appendingPathComponent("materialized", isDirectory: true)
            .appendingPathComponent(oldCommit, isDirectory: true)
            .appendingPathComponent(configFingerprint, isDirectory: true)
        try FileManager.default.createDirectory(at: cacheRoot.deletingLastPathComponent(), withIntermediateDirectories: true)

        let firstStart = Date()
        guard !FileManager.default.fileExists(atPath: cacheRoot.path) else {
            throw ProbeError.failed("fresh materialization path unexpectedly exists")
        }
        let archive = cacheRoot.deletingLastPathComponent().appendingPathComponent("\(oldCommit).tar")
        _ = try command("/usr/bin/git", ["archive", "--format=tar", "--output", archive.path, oldCommit], at: fixture.root)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        _ = try command("/usr/bin/tar", ["-xf", archive.path, "-C", cacheRoot.path], at: nil)
        try FileManager.default.removeItem(at: archive)
        let materializeMilliseconds = elapsedMilliseconds(since: firstStart)

        let secondStart = Date()
        let cacheHit = FileManager.default.fileExists(atPath: cacheRoot.path)
        let cacheHitMilliseconds = elapsedMilliseconds(since: secondStart)
        guard cacheHit else { throw ProbeError.failed("repeat materialization missed its cache directory") }

        let historical = Fixture(
            root: cacheRoot,
            definition: cacheRoot.appendingPathComponent("src/lib.rs"),
            caller: cacheRoot.appendingPathComponent("src/main.rs"),
            languageID: "rust",
            callLine: fixture.callLine,
            callCharacter: fixture.callCharacter,
            expectedLine: 0,
            expectedCharacter: fixture.expectedCharacter,
            config: cacheRoot.appendingPathComponent("Cargo.toml"),
            lockfiles: [],
            oldCommit: nil
        )
        let oldSession = try runDefinitions(
            executable: executable(named: "rust-analyzer", preferred: "/opt/homebrew/bin/rust-analyzer"),
            arguments: [],
            fixture: historical,
            initializationOptions: safeRustOptions
        )
        try assertLocations(oldSession.locations, fixture: historical)

        let currentSession = try runDefinitions(
            executable: executable(named: "rust-analyzer", preferred: "/opt/homebrew/bin/rust-analyzer"),
            arguments: [],
            fixture: fixture,
            initializationOptions: safeRustOptions
        )
        try assertLocations(currentSession.locations, fixture: fixture)
        guard historical.expectedLine != fixture.expectedLine else {
            throw ProbeError.failed("historical definition did not differ from HEAD")
        }

        let result = MaterializeResult(
            commit: oldCommit,
            configFingerprint: configFingerprint,
            directory: cacheRoot.path,
            materializeMilliseconds: materializeMilliseconds,
            cacheHitMilliseconds: cacheHitMilliseconds,
            definitionLine: oldSession.locations[0].line,
            currentDefinitionLine: currentSession.locations[0].line
        )
        if !quiet {
            print("materialize commit=\(oldCommit) config=\(configFingerprint)")
            print("directory=\(cacheRoot.path)")
            print("first=\(milliseconds(materializeMilliseconds)) ms repeatCacheHit=true (\(milliseconds(cacheHitMilliseconds)) ms)")
            print("definition historical=\(result.definitionLine + 1):\(historical.expectedCharacter + 1) HEAD=\(result.currentDefinitionLine + 1):\(fixture.expectedCharacter + 1)")
        }
        return result
    }

    private static func runProvider(
        name: String,
        executable: String,
        arguments: [String],
        fixture: Fixture,
        initializationOptions: [String: Any],
        quiet: Bool
    ) throws -> ProviderResult {
        let original = try Data(contentsOf: fixture.config)
        let configFingerprint = try fingerprint(files: [fixture.config])
        let environmentFingerprint = try fingerprint(files: fixture.lockfiles.filter { FileManager.default.fileExists(atPath: $0.path) }, emptyIsEmpty: true)
        try (original + Data("\n".utf8)).write(to: fixture.config)
        let changed = try fingerprint(files: [fixture.config])
        try original.write(to: fixture.config)
        let restored = try fingerprint(files: [fixture.config])
        guard changed != configFingerprint, restored == configFingerprint else {
            throw ProbeError.failed("profile fingerprint did not change and restore")
        }

        let session = try runDefinitions(
            executable: executable,
            arguments: arguments,
            fixture: fixture,
            initializationOptions: initializationOptions
        )
        try assertLocations(session.locations, fixture: fixture)
        let location = session.locations[0]
        let result = ProviderResult(
            provider: name,
            handshakeMilliseconds: session.handshakeMilliseconds,
            queryMilliseconds: session.queryMilliseconds,
            definitionPath: location.path,
            definitionLine: location.line,
            definitionCharacter: location.character,
            configFingerprint: configFingerprint,
            environmentFingerprint: environmentFingerprint
        )
        if !quiet {
            print("provider=\(name) initialize=\(milliseconds(result.handshakeMilliseconds)) ms definitions=\(result.queryMilliseconds.map(milliseconds).joined(separator: ",")) ms")
            print("definition=\(result.definitionPath):\(result.definitionLine + 1):\(result.definitionCharacter + 1) requests=\(session.locations.count)")
            print("configFingerprint=\(result.configFingerprint) changed=true restored=true environmentFingerprint=\(result.environmentFingerprint.isEmpty ? "<empty>" : result.environmentFingerprint)")
        }
        return result
    }

    private static func runDefinitions(
        executable: String,
        arguments: [String],
        fixture: Fixture,
        initializationOptions: [String: Any],
        settleLimit: TimeInterval = 0,
        settleUntil: (() -> Bool)? = nil
    ) throws -> SessionResult {
        let client = try LSPClient(executable: executable, arguments: arguments, workingDirectory: fixture.root)
        defer { client.close() }
        let initializeStart = Date()
        _ = try client.request("initialize", params: [
            "processId": ProcessInfo.processInfo.processIdentifier,
            "clientInfo": ["name": "ExactProbe", "version": "0"],
            "rootUri": fixture.root.absoluteString,
            "workspaceFolders": [["uri": fixture.root.absoluteString, "name": fixture.root.lastPathComponent]],
            "capabilities": ["textDocument": ["definition": ["linkSupport": true]]],
            "initializationOptions": initializationOptions,
            "trace": "off",
        ], timeout: 30)
        let handshakeMilliseconds = elapsedMilliseconds(since: initializeStart)
        try client.notify("initialized", params: [:])
        try open(fixture.definition, languageID: fixture.languageID, with: client)
        try open(fixture.caller, languageID: fixture.languageID, with: client)

        var locations: [DefinitionLocation] = []
        var queryMilliseconds: [Double] = []
        for _ in 0..<3 {
            let queryStart = Date()
            let deadline = Date().addingTimeInterval(30)
            var result: Any = NSNull()
            repeat {
                do {
                    result = try client.request("textDocument/definition", params: [
                        "textDocument": ["uri": fixture.caller.absoluteString],
                        "position": ["line": fixture.callLine, "character": fixture.callCharacter],
                    ], timeout: 30)
                } catch LSPError.requestFailed(let detail) where detail.contains("-32801") {
                    Thread.sleep(forTimeInterval: 0.1)
                    continue
                }
                if !(result is NSNull), (result as? [Any])?.isEmpty != true { break }
                Thread.sleep(forTimeInterval: 0.1)
            } while Date() < deadline
            queryMilliseconds.append(elapsedMilliseconds(since: queryStart))
            locations.append(try parseDefinition(result))
        }

        if let settleUntil, settleLimit > 0 {
            let deadline = Date().addingTimeInterval(settleLimit)
            while !settleUntil(), Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        }
        return SessionResult(
            handshakeMilliseconds: handshakeMilliseconds,
            queryMilliseconds: queryMilliseconds,
            locations: locations
        )
    }

    private static func open(_ file: URL, languageID: String, with client: LSPClient) throws {
        try client.notify("textDocument/didOpen", params: [
            "textDocument": [
                "uri": file.absoluteString,
                "languageId": languageID,
                "version": 1,
                "text": try String(contentsOf: file, encoding: .utf8),
            ],
        ])
    }

    private static func parseDefinition(_ value: Any) throws -> DefinitionLocation {
        let object: [String: Any]
        if let dictionary = value as? [String: Any] {
            object = dictionary
        } else if let array = value as? [[String: Any]], let first = array.first {
            object = first
        } else {
            throw ProbeError.failed("definition response was empty: \(value)")
        }
        guard let uri = (object["targetUri"] ?? object["uri"]) as? String,
              let range = (object["targetSelectionRange"] ?? object["range"]) as? [String: Any],
              let start = range["start"] as? [String: Any],
              let line = (start["line"] as? NSNumber)?.intValue,
              let character = (start["character"] as? NSNumber)?.intValue,
              let url = URL(string: uri)
        else {
            throw ProbeError.failed("unrecognized definition response: \(object)")
        }
        return DefinitionLocation(path: url.standardizedFileURL.path, line: line, character: character)
    }

    private static func assertLocations(_ locations: [DefinitionLocation], fixture: Fixture) throws {
        let expectedPath = fixture.definition.standardizedFileURL.path
        for location in locations where location.path != expectedPath || location.line != fixture.expectedLine || location.character != fixture.expectedCharacter {
            throw ProbeError.failed(
                "definition mismatch: got \(location.path):\(location.line):\(location.character), expected \(expectedPath):\(fixture.expectedLine):\(fixture.expectedCharacter)"
            )
        }
    }

    private static func makeRustFixture(keepInCache: Bool = false) throws -> Fixture {
        let root = try fixtureDirectory("rust", keepInCache: keepInCache)
        let source = root.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let cargo = root.appendingPathComponent("Cargo.toml")
        let definition = source.appendingPathComponent("lib.rs")
        let caller = source.appendingPathComponent("main.rs")
        try write("""
        [package]
        name = "exact_fixture"
        version = "0.1.0"
        edition = "2021"
        build = "build.rs"
        """, to: cargo)
        try write("// \(UUID().uuidString)\nfn main() { std::fs::write(\"BUILD_SCRIPT_RAN\", \"ran\").unwrap(); }\n", to: root.appendingPathComponent("build.rs"))
        try write("pub fn answer() -> i32 { 42 }\n", to: definition)
        try write("""
        use exact_fixture::answer;

        fn main() {
            println!("{}", answer());
        }
        """, to: caller)
        try initializeGit(at: root)
        _ = try command("/usr/bin/git", ["add", "."], at: root)
        _ = try command("/usr/bin/git", ["-c", "commit.gpgsign=false", "commit", "-q", "-m", "initial definition"], at: root)
        let oldCommit = try command("/usr/bin/git", ["rev-parse", "HEAD"], at: root).trimmingCharacters(in: .whitespacesAndNewlines)
        try write("// moved in second commit\n\npub fn answer() -> i32 { 42 }\n", to: definition)
        _ = try command("/usr/bin/git", ["add", "src/lib.rs"], at: root)
        _ = try command("/usr/bin/git", ["-c", "commit.gpgsign=false", "commit", "-q", "-m", "move definition"], at: root)
        return Fixture(
            root: root,
            definition: definition,
            caller: caller,
            languageID: "rust",
            callLine: 3,
            callCharacter: 19,
            expectedLine: 2,
            expectedCharacter: 7,
            config: cargo,
            lockfiles: [root.appendingPathComponent("Cargo.lock")],
            oldCommit: oldCommit
        )
    }

    private static func makeTypeScriptFixture() throws -> Fixture {
        let root = try fixtureDirectory("ts")
        let source = root.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let config = root.appendingPathComponent("tsconfig.json")
        let definition = source.appendingPathComponent("definition.ts")
        let caller = source.appendingPathComponent("main.ts")
        try write("""
        {"compilerOptions":{"strict":true,"target":"ES2022","module":"NodeNext","moduleResolution":"NodeNext"},"include":["src"]}
        """, to: config)
        try write("export function answer(): number { return 42; }\n", to: definition)
        try write("import { answer } from \"./definition\";\nconsole.log(answer());\n", to: caller)
        return Fixture(
            root: root,
            definition: definition,
            caller: caller,
            languageID: "typescript",
            callLine: 1,
            callCharacter: 12,
            expectedLine: 0,
            expectedCharacter: 16,
            config: config,
            lockfiles: [root.appendingPathComponent("package-lock.json")],
            oldCommit: nil
        )
    }

    private static func makePythonFixture() throws -> Fixture {
        let root = try fixtureDirectory("py")
        let config = root.appendingPathComponent("pyproject.toml")
        let definition = root.appendingPathComponent("definition.py")
        let caller = root.appendingPathComponent("main.py")
        try write("[tool.pyright]\ninclude = [\".\"]\npythonVersion = \"3.11\"\n", to: config)
        try write("def answer() -> int:\n    return 42\n", to: definition)
        try write("from definition import answer\n\nprint(answer())\n", to: caller)
        return Fixture(
            root: root,
            definition: definition,
            caller: caller,
            languageID: "python",
            callLine: 2,
            callCharacter: 6,
            expectedLine: 0,
            expectedCharacter: 4,
            config: config,
            lockfiles: [root.appendingPathComponent("uv.lock")],
            oldCommit: nil
        )
    }

    private static func fixtureDirectory(_ name: String, keepInCache: Bool = false) throws -> URL {
        let parent = keepInCache ? cacheDirectory().appendingPathComponent("fixtures", isDirectory: true) : FileManager.default.temporaryDirectory.appendingPathComponent("CodeInsight-ExactProbe", isDirectory: true)
        let root = parent.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func cacheDirectory() -> URL {
        // ponytail: /tmp mirrors the App cache layout because this spike's sandbox cannot write ~/Library/Caches.
        FileManager.default.temporaryDirectory
            .appendingPathComponent("CodeInsight", isDirectory: true)
            .appendingPathComponent("ExactProbe", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
    }

    private static func initializeGit(at root: URL) throws {
        _ = try command("/usr/bin/git", ["init", "-q"], at: root)
        _ = try command("/usr/bin/git", ["config", "user.name", "Exact Probe"], at: root)
        _ = try command("/usr/bin/git", ["config", "user.email", "exact-probe@example.invalid"], at: root)
    }

    private static func executable(named name: String, preferred: String? = nil) -> String {
        if let preferred, FileManager.default.isExecutableFile(atPath: preferred) { return preferred }
        return (try? command("/usr/bin/which", [name], at: nil).trimmingCharacters(in: .whitespacesAndNewlines)) ?? name
    }

    @discardableResult
    private static func command(_ executable: String, _ arguments: [String], at directory: URL?) throws -> String {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw ProbeError.failed("\(executable) \(arguments.joined(separator: " ")) failed: \(String(data: stderr, encoding: .utf8) ?? "")")
        }
        return String(data: stdout, encoding: .utf8) ?? ""
    }

    private static func fingerprint(files: [URL], emptyIsEmpty: Bool = false) throws -> String {
        if files.isEmpty, emptyIsEmpty { return "" }
        var data = Data()
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            data.append(Data(file.lastPathComponent.utf8))
            data.append(0)
            data.append(try Data(contentsOf: file))
            data.append(0)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    private static func removeIfPresent(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func elapsedMilliseconds(since start: Date) -> Double {
        Date().timeIntervalSince(start) * 1_000
    }

    private static func milliseconds(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
