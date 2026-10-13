import CodeInsightCore
import CodeInsightGit
import Foundation
import Testing

@testable import CodeInsightExact

/// In-memory files standing in for a commit tree.
private struct TreeSnapshot: Snapshot {
    let snapshotID = SnapshotID(rawValue: UUID())
    let objectFormat: GitObjectFormat = .sha1
    let sourceKind: SourceKind = .tracked
    let files: [String: String]

    func listFiles() -> [(path: String, contentID: ContentID, fileMode: FileMode)] {
        files.keys.sorted().map { ($0, ContentID.sha256(of: Array(files[$0]!.utf8)), .regular) }
    }

    func readBytes(path: String) throws -> [UInt8] {
        guard let text = files[path] else { throw GitError.missingPath(path) }
        return Array(text.utf8)
    }
}

private func scratchDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("DependencyBorrowingTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeDirectories(_ paths: [String], under root: URL) throws {
    for path in paths {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(path, isDirectory: true),
            withIntermediateDirectories: true
        )
    }
}

@Test
func typeScriptBorrowsNodeModulesBesideTheRootAndEveryTrackedPackage() throws {
    let workspace = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: workspace) }
    try makeDirectories(
        ["node_modules", "tools/web/node_modules", "tools/gone/node_modules", "docs/node_modules"],
        under: workspace
    )
    let snapshot = TreeSnapshot(files: [
        "package.json": "{}",
        "tools/web/package.json": "{}",
        "tools/web/src/main.ts": "",
        "tools/cli/package.json": "{}",
        "docs/readme.md": "",
    ])

    let links = DependencyBorrowing.links(
        language: .typescript,
        snapshot: snapshot,
        workspaceRoot: workspace,
        unitPrefix: "tools/web"
    )

    // `tools/gone` is not a package of this commit, `docs` has no
    // package.json, and `tools/cli` has no workspace node_modules.
    #expect(links == [
        "node_modules": workspace.appendingPathComponent("node_modules", isDirectory: true),
        "tools/web/node_modules": workspace.appendingPathComponent("tools/web/node_modules", isDirectory: true),
    ])
    #expect(DependencyBorrowing.links(
        language: .rust,
        snapshot: snapshot,
        workspaceRoot: workspace,
        unitPrefix: ""
    ).isEmpty)
}

@Test
func pythonBorrowsOnlyTheCommitsOwnRelativeVenvPath() throws {
    let workspace = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: workspace) }
    try makeDirectories(["svc/envs/main", "envs", ".venv", "svc/.venv"], under: workspace)
    func links(_ files: [String: String], unit: String = "svc") -> [String: URL] {
        DependencyBorrowing.links(
            language: .python,
            snapshot: TreeSnapshot(files: files),
            workspaceRoot: workspace,
            unitPrefix: unit
        )
    }
    let mainEnv = workspace.appendingPathComponent("svc/envs/main", isDirectory: true)

    // pyrightconfig.json (comments allowed) wins over pyproject.toml.
    #expect(links([
        "svc/pyrightconfig.json": "{\n  // local envs\n  \"venvPath\": \"envs\", \"venv\": \"main\"\n}",
        "svc/pyproject.toml": "[tool.pyright]\nvenvPath = \"../envs\"\n",
    ]) == ["svc/envs/main": mainEnv])
    #expect(links([
        "svc/pyproject.toml": "[project]\nname = \"svc\"\nvenvPath = \"ignored\"\n\n[tool.pyright]\nvenvPath = '../envs'\n",
    ]) == ["envs": workspace.appendingPathComponent("envs", isDirectory: true)])
    // `venvPath = "."` names the unit root itself; with `venv` it names
    // the environment inside it.
    #expect(links(["svc/pyproject.toml": "[tool.pyright]\nvenvPath = \".\"\n"]).isEmpty)
    #expect(links(["svc/pyproject.toml": "[tool.pyright]\nvenvPath = \".\"\nvenv = \".venv\"\n"])
        == ["svc/.venv": workspace.appendingPathComponent("svc/.venv", isDirectory: true)])
    // Absolute, home-relative and escaping paths are never linked; nor is
    // an environment the workspace does not have.
    #expect(links(["svc/pyproject.toml": "[tool.pyright]\nvenvPath = \"/opt/envs\"\n"]).isEmpty)
    #expect(links(["svc/pyproject.toml": "[tool.pyright]\nvenvPath = \"~/envs\"\n"]).isEmpty)
    #expect(links(["svc/pyproject.toml": "[tool.pyright]\nvenvPath = \"../../outside\"\n"]).isEmpty)
    #expect(links(["svc/pyproject.toml": "[tool.pyright]\nvenvPath = \"missing\"\n"]).isEmpty)
    // Without configuration nothing is linked, even with a workspace .venv.
    #expect(links(["svc/pyproject.toml": "[project]\nname = \"svc\"\n"]).isEmpty)
    #expect(links([:], unit: "").isEmpty)
}

@Test
func pythonInterpreterIsTheUnitsVenvAndAbsentWithoutOne() throws {
    let workspace = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: workspace) }
    #expect(DependencyBorrowing.pythonInterpreter(unitRoot: workspace) == nil)

    let python = workspace.appendingPathComponent("venv/bin/python")
    try makeDirectories(["venv/bin"], under: workspace)
    try Data("#!/bin/sh\n".utf8).write(to: python)
    #expect(DependencyBorrowing.pythonInterpreter(unitRoot: workspace) == nil, "not executable")
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
    #expect(DependencyBorrowing.pythonInterpreter(unitRoot: workspace) == python)

    let dotVenv = workspace.appendingPathComponent(".venv/bin/python")
    try makeDirectories([".venv/bin"], under: workspace)
    try FileManager.default.createSymbolicLink(atPath: dotVenv.path, withDestinationPath: "/usr/bin/true")
    #expect(DependencyBorrowing.pythonInterpreter(unitRoot: workspace) == dotVenv, ".venv first")
}

@Test
func pyrightIdentityNamesTheAnsweredInterpreterWithoutRunningIt() throws {
    let root = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let marker = root.appendingPathComponent("ran")
    func makeVenv(_ name: String, version: String) throws -> URL {
        let python = root.appendingPathComponent("\(name)/bin/python")
        try makeDirectories(["\(name)/bin"], under: root)
        try Data("#!/bin/sh\ntouch '\(marker.path)'\necho Python 9.9\n".utf8).write(to: python)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
        try Data("home = /usr/bin\nversion = \(version)\n".utf8)
            .write(to: root.appendingPathComponent("\(name)/pyvenv.cfg"))
        return python
    }
    let a = try makeVenv("a", version: "3.12.4")
    let b = try makeVenv("b", version: "3.13.1")
    func identity(_ python: URL?) -> String {
        PyrightProvider.interpreterIdentity(
            projectURL: root,
            cacheURL: root.appendingPathComponent("cache"),
            environment: ["PATH": ""],
            pythonPath: python
        )
    }

    #expect(identity(a).contains(a.path))
    #expect(identity(a).contains("3.12.4"))
    #expect(identity(a) != identity(b))
    #expect(identity(a) != identity(nil), "the venv differs from PATH discovery")
    #expect(!FileManager.default.fileExists(atPath: marker.path), "the project's interpreter never runs unsandboxed")

    // The limitation follows what the server is actually given.
    #expect(PyrightProvider.baseEnvironment(trustMode: .safe).limitations == [.dependenciesUnavailableOffline])
    #expect(PyrightProvider.baseEnvironment(trustMode: .safe, pythonPath: a).limitations.isEmpty)
    #expect(PyrightProvider.baseEnvironment(trustMode: .safe, pythonPath: a, borrowedFromWorkspace: true)
        .limitations == [.dependenciesBorrowedFromWorkspace])
}

@Test
func typeScriptIsLabelledOfflineOnlyWithoutNodeModulesInTheUnit() throws {
    let unit = FileManager.default.temporaryDirectory
        .appendingPathComponent("ts-offline-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: unit, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: unit) }
    func limitations(borrowed: Bool = false) -> Set<ExactAnalysisLimitation> {
        TypeScriptLanguageServerProvider.baseEnvironment(
            trustMode: .safe,
            projectURL: unit,
            borrowedFromWorkspace: borrowed
        ).limitations
    }
    #expect(limitations() == [.dependenciesUnavailableOffline])
    // A file named node_modules is not an installation.
    try Data().write(to: unit.appendingPathComponent("node_modules"))
    #expect(limitations() == [.dependenciesUnavailableOffline])
    try FileManager.default.removeItem(at: unit.appendingPathComponent("node_modules"))
    try FileManager.default.createDirectory(
        at: unit.appendingPathComponent("node_modules"),
        withIntermediateDirectories: true
    )
    #expect(limitations().isEmpty)
    #expect(limitations(borrowed: true) == [.dependenciesBorrowedFromWorkspace])
}

@Test
func locationsOutsideTheSnapshotResolveToTheirRealDependencyPath() throws {
    let root = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let checkout = root.appendingPathComponent("checkout", isDirectory: true)
    let workspaceModules = root.appendingPathComponent("workspace/node_modules/lib", isDirectory: true)
    try makeDirectories(["checkout/src"], under: root)
    try FileManager.default.createDirectory(at: workspaceModules, withIntermediateDirectories: true)
    try Data("export class Tokenizer {}\n".utf8).write(to: workspaceModules.appendingPathComponent("index.d.ts"))
    try Data("import { Tokenizer } from 'lib'\n".utf8).write(to: checkout.appendingPathComponent("src/main.ts"))
    try FileManager.default.createSymbolicLink(
        at: checkout.appendingPathComponent("node_modules"),
        withDestinationURL: workspaceModules.deletingLastPathComponent()
    )
    let snapshot = TreeSnapshot(files: ["src/main.ts": "import { Tokenizer } from 'lib'\n"])
    let real = workspaceModules.appendingPathComponent("index.d.ts").resolvingSymlinksInPath().path
    func parse(_ url: URL) throws -> ExactLocation {
        try parseExactLocation(
            [
                "uri": url.absoluteString,
                "range": ["start": ["line": 0, "character": 13]],
            ],
            projectURL: checkout,
            snapshot: snapshot
        )
    }

    // Through the borrowed link, and as the real path the server may report.
    let linked = try parse(checkout.appendingPathComponent("node_modules/lib/index.d.ts"))
    let direct = try parse(workspaceModules.appendingPathComponent("index.d.ts"))
    for location in [linked, direct] {
        #expect(location.file == real)
        #expect(location.byteOffset == 13)
        #expect(location.line == 1 && location.column == 14)
    }
    // A snapshot file stays project-relative.
    #expect(try parse(checkout.appendingPathComponent("src/main.ts")).file == "src/main.ts")
}

/// Answers `initialize`, asks the client for the `python` configuration,
/// and serves call hierarchy whose callee lives in a dependency.
private final class DependencyFakeServer: @unchecked Sendable {
    private let input: FileHandle
    private let output: FileHandle
    private let dependencyURI: String
    private let lock = NSLock()
    private var answered: Any?
    private var opened: [String] = []

    init(input: FileHandle, output: FileHandle, dependencyURI: String) {
        self.input = input
        self.output = output
        self.dependencyURI = dependencyURI
    }

    var configurationAnswer: Any? { lock.withLock { answered } }
    var openedURIs: [String] { lock.withLock { opened } }

    func start() {
        Thread.detachNewThread { self.run() }
    }

    private func run() {
        var decoder = LSPFrameDecoder()
        while true {
            let data = input.availableData
            guard !data.isEmpty, let messages = try? decoder.append(data) else { return }
            for message in messages { handle(message) }
        }
    }

    private func handle(_ message: [String: Any]) {
        let method = message["method"] as? String
        let id = message["id"]
        let params = message["params"] as? [String: Any]
        let range: [String: Any] = [
            "start": ["line": 0, "character": 13],
            "end": ["line": 0, "character": 22],
        ]
        switch method {
        case "initialize":
            write(["jsonrpc": "2.0", "id": id!, "result": ["capabilities": [
                "definitionProvider": true,
                "referencesProvider": true,
                "callHierarchyProvider": true,
            ]]])
            write(["jsonrpc": "2.0", "id": 900, "method": "workspace/configuration", "params": [
                "items": [["section": "python"], ["section": "python.analysis"]],
            ]])
        case "textDocument/didOpen":
            let document = params?["textDocument"] as? [String: Any]
            lock.withLock { opened.append(document?["uri"] as? String ?? "") }
        case "callHierarchy/outgoingCalls":
            write(["jsonrpc": "2.0", "id": id!, "result": [[
                "to": [
                    "name": "Tokenizer", "kind": 5, "uri": dependencyURI,
                    "range": range, "selectionRange": range,
                ],
                "fromRanges": [range],
            ]]])
        case nil where (id as? NSNumber)?.intValue == 900:
            lock.withLock { answered = message["result"] }
        case .some:
            if let id { write(["jsonrpc": "2.0", "id": id, "result": NSNull()]) }
        default:
            break
        }
    }

    private func write(_ message: [String: Any]) {
        try? output.write(contentsOf: LSPFraming.encode(message))
    }
}

@Test
func relationExpansionFromADependencyItemAndPythonPathAnswer() throws {
    let root = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let checkout = root.appendingPathComponent("checkout", isDirectory: true)
    let modules = root.appendingPathComponent("workspace/node_modules", isDirectory: true)
    try makeDirectories(["checkout/src", "workspace/node_modules/lib"], under: root)
    try Data("export class Tokenizer {}\n".utf8).write(to: modules.appendingPathComponent("lib/index.d.ts"))
    try FileManager.default.createSymbolicLink(
        at: checkout.appendingPathComponent("node_modules"),
        withDestinationURL: modules
    )
    let linkedURI = checkout.appendingPathComponent("node_modules/lib/index.d.ts").absoluteString
    let toServer = Pipe()
    let fromServer = Pipe()
    let server = DependencyFakeServer(
        input: toServer.fileHandleForReading,
        output: fromServer.fileHandleForWriting,
        dependencyURI: linkedURI
    )
    server.start()
    let python = "/workspace/.venv/bin/python"
    let client = LSPClient(
        readHandle: fromServer.fileHandleForReading,
        writeHandle: toServer.fileHandleForWriting,
        configuration: ["python": ["pythonPath": python]]
    )
    let session = try LSPLanguageSession.start(
        client: client,
        restartClient: { throw ExactError.unavailable("no restart") },
        projectURL: checkout,
        snapshot: TreeSnapshot(files: ["src/main.ts": "export const x = 1\n"]),
        language: .pyright,
        requestTimeout: 5,
        closeGrace: 1,
        attribution: ExactAttribution(
            provider: "fake",
            toolVersion: "fake",
            configFingerprint: "",
            environmentFingerprint: "",
            environment: ExactAnalysisEnvironment(trustMode: .safe),
            generatedAt: Date(timeIntervalSince1970: 0)
        )
    )
    defer { session.close() }

    // Expanding a relation rooted at a dependency item: the item is not a
    // snapshot file, so it is not opened from the snapshot, and the callee
    // comes back as its real path.
    let range = ExactLocation(file: modules.appendingPathComponent("lib/index.d.ts").path,
                              byteOffset: 13, line: 1, column: 14)
    let item = ExactCallHierarchyItem(
        name: "Tokenizer", kind: 5, uri: linkedURI,
        range: range, selectionRange: range, data: nil
    )
    let relations = try #require(try session.outgoingCalls(item: item))
    #expect(relations.count == 1)
    let real = modules.appendingPathComponent("lib/index.d.ts").resolvingSymlinksInPath().path
    #expect(relations.first?.item.selectionRange.file == real)
    #expect(relations.first?.callSites.first?.file == real)
    #expect(server.openedURIs.isEmpty)

    let deadline = Date().addingTimeInterval(5)
    while server.configurationAnswer == nil, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.01)
    }
    let answer = try #require(server.configurationAnswer as? [Any])
    #expect((answer.first as? [String: String]) == ["pythonPath": python])
    #expect(answer.last is NSNull)
}
