import CodeInsightCore
import CodeInsightEngine
@testable import CodeInsightEngine
import CodeInsightGit
import Foundation
import Testing
@testable import CodeInsightAppModel

@MainActor
@Test
func unsupportedSavedJavaScriptDoesNotMutateProjectState() async throws {
    let root = try sessionRestoreProject(["main.rs": "fn main() {}\n"])
    defer { try? FileManager.default.removeItem(at: root) }
    let snapshot = SessionCodec.Snapshot(
        projectRoot: root.path,
        language: .javascript,
        revision: nil,
        activeTabOrdinal: nil,
        panelPreset: PanelPresetModel.reading.rawValue,
        tabs: []
    )
    let model = AppModel(indexService: SessionRestoreIndexService())
    let originalGeneration = model.generation

    #expect(await model.restoreSession(snapshot) == false)
    guard case .empty = model.projectState else {
        Issue.record("unsupported restore changed project state")
        return
    }
    #expect(model.projectRoot == nil)
    #expect(model.projectLanguage == nil)
    #expect(model.generation == originalGeneration)
}

@MainActor
@Test
func savedPythonSessionRestoresWithPythonLanguageAndTree() async throws {
    let root = try sessionRestoreProject([
        "main.py": "def hello():\n    return 1\n",
        "ignored.rs": "fn main() {}",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let snapshot = SessionCodec.Snapshot(
        projectRoot: root.path,
        language: .python,
        revision: nil,
        activeTabOrdinal: nil,
        panelPreset: PanelPresetModel.reading.rawValue,
        tabs: []
    )
    let model = AppModel(indexService: SessionRestoreIndexService())

    #expect(await model.restoreSession(snapshot))

    #expect(model.snapshotPhase == .fullReady)
    #expect(model.projectLanguage == .python)
    #expect(model.fileTree?.children.map(\.name) == ["main.py"])
    #expect(model.fileTree?.fileCount == 1)
    guard case let .ready(session, _) = model.projectState else {
        Issue.record("expected ready Python session after restore")
        return
    }
    #expect(session.analysisProfile.language == .python)
    #expect(session.manifest.files.map {
        session.paths.resolve($0.pathID)
    } == ["main.py"])
}

@MainActor
@Test
func savedTypeScriptSessionRestoresWithTypeScriptLanguageAndTsTsxTree() async throws {
    let root = try sessionRestoreProject([
        "src/a.ts": "export const a = 1\n",
        "src/b.tsx": "export const b = <div />\n",
        "ignored.js": "export const js = 1\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let snapshot = SessionCodec.Snapshot(
        projectRoot: root.path,
        language: .typescript,
        revision: nil,
        activeTabOrdinal: nil,
        panelPreset: PanelPresetModel.reading.rawValue,
        tabs: []
    )
    let model = AppModel(indexService: SessionRestoreIndexService())

    #expect(await model.restoreSession(snapshot))

    #expect(model.snapshotPhase == .fullReady)
    #expect(model.projectLanguage == .typescript)
    #expect(model.fileTree?.fileCount == 2)
    guard case let .ready(session, _) = model.projectState else {
        Issue.record("expected ready TypeScript session after restore")
        return
    }
    #expect(session.analysisProfile.language == .typescript)
    #expect(session.manifest.files.map {
        session.paths.resolve($0.pathID)
    }.sorted() == ["src/a.ts", "src/b.tsx"])
}

@MainActor
@Test
func sessionRestoreMapsOldOrdinalsAndResolvesBothPathKindsAndAnchors() async throws {
    let root = try sessionRestoreProject([
        "main.rs": "fn first() {}\nfn target() {}\n",
    ])
    let dependency = FileManager.default.temporaryDirectory.appendingPathComponent(
        "CodeInsightSessionDependency-\(UUID().uuidString).rs"
    )
    try Data("pub fn dependency() {}\n".utf8).write(to: dependency)
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: dependency)
    }
    let source = Array(try Data(contentsOf: root.appendingPathComponent("main.rs")))
    let dependencySource = Array(try Data(contentsOf: dependency))
    let currentContentID = ContentID.sha256(of: source)
    let staleContentID = ContentID.sha256(of: Array("stale".utf8))
    let exactScroll = SessionCodec.Anchor(
        byteOffset: 3,
        line: 1,
        column: 4,
        symbolAnchor: "first"
    )
    let lineSelection = SessionCodec.Anchor(
        byteOffset: 9_999,
        line: 2,
        column: 4,
        symbolAnchor: "target"
    )
    let snapshot = SessionCodec.Snapshot(
        projectRoot: root.path,
        language: .rust,
        revision: nil,
        activeTabOrdinal: 2,
        panelPreset: PanelPresetModel.relations.rawValue,
        tabs: [
            .file(.init(
                path: "missing.rs",
                anchorContentID: staleContentID,
                scrollAnchor: exactScroll,
                selectionAnchor: lineSelection
            )),
            .readingSet(.init(
                title: "frozen target",
                excerpts: [],
                scrollOffset: 42,
                skippedReasons: ["recorded source is unreadable"]
            )),
            .file(.init(
                path: "main.rs",
                anchorContentID: currentContentID,
                scrollAnchor: exactScroll,
                selectionAnchor: lineSelection
            )),
            .file(.init(
                path: dependency.path,
                anchorContentID: ContentID.sha256(of: dependencySource),
                scrollAnchor: .init(
                    byteOffset: 4,
                    line: 1,
                    column: 5,
                    symbolAnchor: "dependency"
                ),
                selectionAnchor: nil
            )),
        ]
    )
    let model = AppModel(indexService: SessionRestoreIndexService())

    #expect(await model.restoreSession(snapshot))

    #expect(model.tabStrip.tabs.count == 3)
    #expect(model.tabStrip.activeIndex == 1)
    guard case .readingSet(let title, let excerpts) = model.tabStrip.tabs[0].content
    else {
        Issue.record("expected the old ordinal 1 Reading Set to map to new index 0")
        return
    }
    #expect(title == "frozen target")
    #expect(excerpts.isEmpty)
    #expect(model.tabStrip.tabs[0].readingSetScrollOffset == 42)
    #expect(model.tabStrip.tabs[0].readingSetSkippedReasons
        == ["recorded source is unreadable"])

    let projectTab = model.tabStrip.tabs[1]
    #expect(projectTab.fileURL?.standardizedFileURL
        == root.appendingPathComponent("main.rs").standardizedFileURL)
    #expect(projectTab.anchorContentID == currentContentID)
    #expect(projectTab.scrollAnchor?.byteOffset == exactScroll.byteOffset)
    #expect(projectTab.selectionAnchor?.byteOffset
        == LineTable(bytes: source).byteOffset(line: 2, column: 4))
    #expect(projectTab.selectionAnchor?.byteOffset != lineSelection.byteOffset)
    #expect(model.replayNotice?.contains("selection restored by line and column")
        == true)

    let dependencyTab = model.tabStrip.tabs[2]
    #expect(dependencyTab.fileURL?.standardizedFileURL
        == dependency.standardizedFileURL)
    #expect(dependencyTab.anchorContentID == ContentID.sha256(of: dependencySource))
    #expect(dependencyTab.scrollAnchor?.byteOffset == 4)
}

@MainActor
@Test
func sessionRestoreFallsBackToFirstSuccessfulEntryWhenSavedActiveIsMissing() async throws {
    let root = try sessionRestoreProject(["main.rs": "fn main() {}\n"])
    defer { try? FileManager.default.removeItem(at: root) }
    let snapshot = SessionCodec.Snapshot(
        projectRoot: root.path,
        language: .rust,
        revision: nil,
        activeTabOrdinal: 0,
        panelPreset: PanelPresetModel.reading.rawValue,
        tabs: [
            .file(.init(
                path: "missing.rs",
                anchorContentID: nil,
                scrollAnchor: nil,
                selectionAnchor: nil
            )),
            .readingSet(.init(
                title: "first surviving entry",
                excerpts: [],
                scrollOffset: 18
            )),
            .file(.init(
                path: "main.rs",
                anchorContentID: nil,
                scrollAnchor: nil,
                selectionAnchor: nil
            )),
        ]
    )
    let model = AppModel(indexService: SessionRestoreIndexService())

    #expect(await model.restoreSession(snapshot))

    #expect(model.tabStrip.activeIndex == 0)
    guard case .readingSet(let title, _) = model.tabStrip.activeTab?.content else {
        Issue.record("expected the first successful entry")
        return
    }
    #expect(title == "first surviving entry")
}

@MainActor
@Test
func invalidOrMissingRootSessionIsDeletedAndReportedOnlyOnce() throws {
    let stateRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
        "CodeInsightInvalidSession-\(UUID().uuidString)",
        isDirectory: true
    )
    let sessionURL = stateRoot.appendingPathComponent("session.json")
    try FileManager.default.createDirectory(
        at: stateRoot,
        withIntermediateDirectories: true
    )
    defer {
        try? FileManager.default.removeItem(at: stateRoot)
        #expect(!FileManager.default.fileExists(atPath: sessionURL.path))
    }
    let model = AppModel(
        sessionURL: sessionURL,
        indexService: SessionRestoreIndexService()
    )

    try Data("{\"schemaVersion\":99}".utf8).write(to: sessionURL)
    let invalid = model.loadSessionSnapshot()
    #expect(invalid.snapshot == nil)
    #expect(invalid.discarded)
    #expect(!FileManager.default.fileExists(atPath: sessionURL.path))
    #expect(!model.loadSessionSnapshot().discarded)

    let missingRoot = SessionCodec.Snapshot(
        projectRoot: stateRoot.appendingPathComponent("gone").path,
        language: .rust,
        revision: nil,
        activeTabOrdinal: nil,
        panelPreset: PanelPresetModel.reading.rawValue,
        tabs: []
    )
    try SessionCodec.encode(
        missingRoot,
        maximumTabCount: model.tabStrip.maximumCount,
        dependencyAllowed: exactLocationIsInDependency
    ).write(to: sessionURL)
    let missing = model.loadSessionSnapshot()
    #expect(missing.snapshot == nil)
    #expect(missing.discarded)
    #expect(!FileManager.default.fileExists(atPath: sessionURL.path))
}

@MainActor
@Test
func missingSavedRevisionRestoresTabsAgainstTheCurrentWorktree() async throws {
    let root = try sessionRestoreProject(["main.rs": "fn current() {}\n"])
    defer { try? FileManager.default.removeItem(at: root) }
    let snapshot = SessionCodec.Snapshot(
        projectRoot: root.path,
        language: .rust,
        revision: "revision-that-does-not-exist",
        activeTabOrdinal: 0,
        panelPreset: PanelPresetModel.reading.rawValue,
        tabs: [
            .file(.init(
                path: "main.rs",
                anchorContentID: nil,
                scrollAnchor: .init(
                    byteOffset: 0,
                    line: 1,
                    column: 1,
                    symbolAnchor: "current"
                ),
                selectionAnchor: nil
            )),
        ]
    )
    let model = AppModel(indexService: SessionRestoreIndexService())

    #expect(await model.restoreSession(snapshot))

    #expect(model.currentRevision == nil)
    #expect(model.projectLanguage == .rust)
    #expect(model.tabStrip.tabs.count == 1)
    #expect(model.replayNotice?.contains("saved revision unavailable") == true)
    #expect(model.replayNotice?.contains("unverified byte offset") == true)
}

@MainActor
@Test
func openingAnotherProjectCancelsTheOlderAutomaticRestore() async throws {
    let restoredRoot = try sessionRestoreProject(["restored.rs": "fn old() {}\n"])
    let manualRoot = try sessionRestoreProject(["manual.rs": "fn new() {}\n"])
    defer {
        try? FileManager.default.removeItem(at: restoredRoot)
        try? FileManager.default.removeItem(at: manualRoot)
    }
    let service = GatedSessionRestoreIndexService(blockedRoot: restoredRoot)
    let model = AppModel(indexService: service)
    let snapshot = SessionCodec.Snapshot(
        projectRoot: restoredRoot.path,
        language: .rust,
        revision: nil,
        activeTabOrdinal: 0,
        panelPreset: PanelPresetModel.reading.rawValue,
        tabs: [
            .file(.init(
                path: "restored.rs",
                anchorContentID: nil,
                scrollAnchor: nil,
                selectionAnchor: nil
            )),
        ]
    )

    let restoreTask = Task { await model.restoreSession(snapshot) }
    #expect(await testWaitUntil("restore indexing reached its gate") {
        await service.hasStartedBlockedIndex()
    })
    model.openProject(root: manualRoot)
    #expect(await testWaitUntil("manual project installed") {
        model.snapshotPhase == .fullReady
            && model.fileTree?.root.standardizedFileURL
                == manualRoot.standardizedFileURL
    })

    #expect(await restoreTask.value == false)
    #expect(model.fileTree?.root.standardizedFileURL
        == manualRoot.standardizedFileURL)
    #expect(model.tabStrip.tabs.isEmpty)
}

@MainActor
@Test
func mixedFullReadyCheckpointSavesLanguagesRevisionAndActiveCrossLanguageTabs() async throws {
    let root = try sessionRestoreGitProject([
        "main.rs": "fn rustFn() {}\n",
        "lib.py": "def py_fn():\n    pass\n",
        "app.ts": "export function tsFn() {}\n",
        "Cargo.toml": "[package]\nname = \"mixed\"\n",
        "pyproject.toml": "[project]\nname = \"mixed\"\n",
        "tsconfig.json": "{}",
    ])
    try sessionRestoreGit(root, "add", ".")
    try sessionRestoreGit(
        root,
        "-c", "user.name=CodeInsight",
        "-c", "user.email=codeinsight@example.com",
        "commit", "-m", "mixed save", "-q"
    )
    let revision = try sessionRestoreCurrentHEAD(root)
    let sessionURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodeInsightMixedCheckpoint-\(UUID().uuidString)")
        .appendingPathComponent("session.json")
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(
            at: sessionURL.deletingLastPathComponent()
        )
    }
    let model = AppModel(
        sessionURL: sessionURL,
        indexService: SessionRestoreIndexService()
    )
    try await model.openProject(
        root: root,
        languages: [.typescript, .rust, .python]
    )
    try #require(await testWaitUntil("mixed fullReady") {
        model.snapshotPhase == .fullReady
            && model.querySessions.count == 3
    })
    let rustFile = root.appendingPathComponent("main.rs")
    model.switchToCommit(revision)
    try #require(await testWaitUntil("mixed fullReady at saved revision") {
        model.snapshotPhase == .fullReady && model.currentRevision == revision
    })
    model.openInNewTab(rustFile)
    model.navigate(to: root.appendingPathComponent("lib.py"))
    model.openInNewTab(rustFile)
    model.openInNewTab(root.appendingPathComponent("app.ts"))
    try model.writeSessionCheckpoint(panelPreset: .reading)

    let snapshot = try #require(model.loadSessionSnapshot().snapshot)
    #expect(snapshot.languages == [.rust, .python, .typescript])
    #expect(snapshot.revision == revision)
    #expect(snapshot.activeTabOrdinal == model.tabStrip.activeIndex)
    let fileTabs = snapshot.tabs.compactMap { tab -> String? in
        guard case .file(let file) = tab else { return nil }
        return file.path
    }
    #expect(fileTabs.contains("main.rs"))
    #expect(fileTabs.contains("lib.py"))
    #expect(fileTabs.contains("app.ts"))
}

@MainActor
@Test
func mixedRestoreOpensFullSetAndRestoresEachTabByMode() async throws {
    let root = try sessionRestoreGitProject([
        "main.rs": "pub fn checkpoint() {}\n",
        "lib.py": "def checkpoint():\n    pass\n",
        "app.ts": "export function checkpoint() {}\n",
        "Cargo.toml": "[package]\nname = \"mixed\"\n",
        "pyproject.toml": "[project]\nname = \"mixed\"\n",
        "tsconfig.json": "{}",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let snapshot = SessionCodec.Snapshot(
        projectRoot: root.path,
        languages: [.typescript, .rust, .python],
        revision: nil,
        activeTabOrdinal: 1,
        panelPreset: PanelPresetModel.reading.rawValue,
        tabs: [
            .file(.init(
                path: "app.ts",
                anchorContentID: nil,
                scrollAnchor: nil,
                selectionAnchor: nil
            )),
            .file(.init(
                path: "lib.py",
                anchorContentID: nil,
                scrollAnchor: nil,
                selectionAnchor: nil
            )),
            .file(.init(
                path: "main.rs",
                anchorContentID: nil,
                scrollAnchor: nil,
                selectionAnchor: nil
            )),
        ]
    )
    let model = AppModel(indexService: SessionRestoreIndexService())

    #expect(await model.restoreSession(snapshot))

    #expect(model.projectLanguages == [.rust, .python, .typescript])
    #expect(model.querySessions.map { $0.0.analysisProfile.language }
        == [.rust, .python, .typescript])
    #expect(model.tabStrip.activeIndex == 1)
    #expect(model.tabStrip.activeTab?.fileURL?.path == root
        .appendingPathComponent("lib.py").path)
    let titles = model.tabStrip.tabs.compactMap { tab in
        tab.fileURL?.lastPathComponent
    }
    #expect(titles == ["app.ts", "lib.py", "main.rs"])
    let modes: [LanguageID] = model.tabStrip.tabs.compactMap { tab in
        tab.fileURL.flatMap { model.languageMode(for: $0)?.language }
    }
    #expect(modes == [.typescript, .python, .rust])
}

@MainActor
@Test
func mixedRestoreSkipsOnlyExtensionlessDependencyAndKeepsOtherTabs() async throws {
    let root = try sessionRestoreGitProject([
        "main.rs": "fn rustFn() {}\n",
        "lib.py": "def pythonFn():\n    pass\n",
    ])
    let dependency = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodeInsightMixedDependency-\(UUID().uuidString)")
    try "dependency".write(to: dependency, atomically: true, encoding: .utf8)
    let pythonDependency = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "CodeInsightMixedDependency-\(UUID().uuidString).py"
        )
    try "def external():\n    pass\n"
        .write(to: pythonDependency, atomically: true, encoding: .utf8)
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: dependency)
        try? FileManager.default.removeItem(at: pythonDependency)
    }
    let snapshot = SessionCodec.Snapshot(
        projectRoot: root.path,
        languages: [.rust, .python],
        revision: nil,
        activeTabOrdinal: 1,
        panelPreset: PanelPresetModel.reading.rawValue,
        tabs: [
            .file(.init(
                path: "main.rs",
                anchorContentID: nil,
                scrollAnchor: nil,
                selectionAnchor: nil
            )),
            .file(.init(
                path: pythonDependency.path,
                anchorContentID: nil,
                scrollAnchor: nil,
                selectionAnchor: nil
            )),
            .file(.init(
                path: dependency.path,
                anchorContentID: nil,
                scrollAnchor: nil,
                selectionAnchor: nil
            )),
            .file(.init(
                path: "lib.py",
                anchorContentID: nil,
                scrollAnchor: nil,
                selectionAnchor: nil
            )),
        ]
    )
    let model = AppModel(indexService: SessionRestoreIndexService())

    #expect(await model.restoreSession(snapshot))

    #expect(model.projectLanguages == [.rust, .python])
    #expect(model.tabStrip.tabs.count == 3)
    let paths = model.tabStrip.tabs.compactMap { $0.fileURL?.path }
    #expect(paths.contains(root.appendingPathComponent("main.rs").path))
    #expect(paths.contains(root.appendingPathComponent("lib.py").path))
    #expect(paths.contains(pythonDependency.path))
    #expect(!paths.contains(dependency.path))
    #expect(model.tabStrip.activeIndex == 1)
    #expect(model.tabStrip.activeTab?.fileURL?.path
        == pythonDependency.path)
}

private struct SessionRestoreIndexService: IndexService {
    func index(root: URL, language: LanguageID) async throws -> EngineSession {
        try await Task.detached {
            try ProjectIndexer().index(root: root, language: language)
        }.value
    }

    func captureSnapshot(
        root: URL,
        revision: String?,
        languages: [LanguageID]
    ) async throws -> any Snapshot {
        try await Task.detached {
            if let revision {
                return try CommitSnapshot(
                    repositoryURL: root,
                    revision: revision
                ) as any Snapshot
            }
            return try WorktreeSnapshot(
                repositoryURL: root,
                languages: LanguageMode.normalize(languages: languages)
            ) as any Snapshot
        }.value
    }

    func prepareSnapshots(
        _ snapshot: any Snapshot,
        root: URL,
        languages: [LanguageID]
    ) async throws -> [ProjectIndexer.PreparedSnapshot] {
        try await Task.detached {
            let normalized = try LanguageMode.normalize(languages: languages)
            let store = ProjectIndexStore()
            return try normalized.map { language in
                try ProjectIndexer().prepareSnapshot(
                    snapshot,
                    into: store,
                    language: language,
                    discoverUnitRoot: true
                )
            }
        }.value
    }

    func completeSnapshot(
        _ prepared: ProjectIndexer.PreparedSnapshot
    ) async throws -> EngineSession {
        try await Task.detached {
            try ProjectIndexer().completeSnapshot(prepared)
        }.value
    }
}

private actor GatedSessionRestoreIndexService: IndexService {
    private let blockedRoot: URL
    private var blockedIndexStarted = false

    init(blockedRoot: URL) {
        self.blockedRoot = blockedRoot.standardizedFileURL
    }

    func index(root: URL, language: LanguageID) async throws -> EngineSession {
        if root.standardizedFileURL == blockedRoot {
            blockedIndexStarted = true
            while true {
                try Task.checkCancellation()
                await Task.yield()
            }
        }
        return try await Task.detached {
            try ProjectIndexer().index(root: root, language: language)
        }.value
    }

    func hasStartedBlockedIndex() -> Bool { blockedIndexStarted }
}

private func sessionRestoreProject(_ files: [String: String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "CodeInsightSessionRestore-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for (path, contents) in files {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: file, atomically: true, encoding: .utf8)
    }
    return root
}

private func sessionRestoreGitProject(
    _ files: [String: String]
) throws -> URL {
    let root = try sessionRestoreProject(files)
    try sessionRestoreGit(root, "init", "-q")
    return root
}

private func sessionRestoreGit(
    _ root: URL,
    _ arguments: String...
) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", root.path] + arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CocoaError(.fileWriteUnknown)
    }
}

private func sessionRestoreCurrentHEAD(_ root: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", root.path, "rev-parse", "HEAD"]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0,
          let data = try pipe.fileHandleForReading.readToEnd()
    else {
        throw CocoaError(.fileWriteUnknown)
    }
    return String(decoding: data, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
