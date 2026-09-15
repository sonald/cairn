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
    #expect(model.fileTree?.children.map(\.name) == ["ignored.rs", "main.py"])
    #expect(model.fileTree?.fileCount == 2)
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
func savedReadmeSessionRestoresAsActiveNonSourceTabWithoutDocument() async throws {
    let root = try sessionRestoreProject([
        "main.rs": "fn main() {}\n",
        "README.md": "# Read me\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let snapshot = SessionCodec.Snapshot(
        projectRoot: root.path,
        language: .rust,
        revision: nil,
        activeTabOrdinal: 0,
        panelPreset: PanelPresetModel.reading.rawValue,
        tabs: [
            .file(.init(
                path: "README.md",
                anchorContentID: nil,
                scrollAnchor: nil,
                selectionAnchor: nil
            )),
        ]
    )
    let model = AppModel(indexService: SessionRestoreIndexService())

    #expect(await model.restoreSession(snapshot))
    #expect(model.tabStrip.activeTab?.fileURL?.lastPathComponent == "README.md")
    #expect(model.tabStrip.activeDocument == nil)
    #expect(model.languageMode(for: root.appendingPathComponent("README.md")) == nil)
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
    #expect(model.fileTree?.fileCount == 3)
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
    #expect(model.replayNotice?.contains(
        "selection restored by unique symbol anchor"
    ) == true)

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
func sessionLoadProblemsAreClassifiedAndPreserveOrQuarantineData() throws {
    let stateRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
        "CodeInsightInvalidSession-\(UUID().uuidString)",
        isDirectory: true
    )
    let sessionURL = stateRoot.appendingPathComponent("session.json")
    try FileManager.default.createDirectory(
        at: stateRoot,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let root = try sessionRestoreProject(["main.rs": "fn main() {}\n"])
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(
        sessionURL: sessionURL,
        indexService: SessionRestoreIndexService()
    )

    // Legacy data written by a future schema stays untouched.
    try Data("{\"schemaVersion\":99}".utf8).write(to: sessionURL)
    let future = model.loadLegacySessionSnapshot()
    #expect(future.snapshot == nil)
    #expect(future.problem == .unsupportedSchemaVersion(99))
    #expect(FileManager.default.fileExists(atPath: sessionURL.path))

    // Corrupt legacy data is quarantined once, not deleted.
    try Data("not json".utf8).write(to: sessionURL)
    let corruptLegacy = model.loadLegacySessionSnapshot()
    #expect(corruptLegacy.snapshot == nil)
    #expect(corruptLegacy.problem == .corruptFile)
    #expect(!FileManager.default.fileExists(atPath: sessionURL.path))
    #expect(FileManager.default.fileExists(atPath: sessionURL.path + ".corrupt"))

    // A saved project whose directory vanished is kept for later, not
    // deleted, and reports an explicit problem.
    let missingRoot = SessionCodec.Snapshot(
        projectRoot: stateRoot.appendingPathComponent("gone").path,
        language: .rust,
        revision: nil,
        activeTabOrdinal: nil,
        panelPreset: PanelPresetModel.reading.rawValue,
        tabs: []
    )
    let perProjectURL = stateRoot.appendingPathComponent("sessions")
        .appendingPathComponent(
            AppModel.sessionProjectKey(
                for: URL(
                    fileURLWithPath: missingRoot.projectRoot,
                    isDirectory: true
                )
            ) + ".json"
        )
    try FileManager.default.createDirectory(
        at: perProjectURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try SessionCodec.encode(
        missingRoot,
        maximumTabCount: model.tabStrip.maximumCount,
        dependencyAllowed: exactLocationIsInDependency
    ).write(to: perProjectURL)
    let missing = model.loadSessionSnapshot(
        forProject: URL(
            fileURLWithPath: missingRoot.projectRoot,
            isDirectory: true
        )
    )
    #expect(missing.snapshot == nil)
    #expect(missing.problem == .projectUnavailable)
    #expect(FileManager.default.fileExists(atPath: perProjectURL.path))

    // Corrupt per-project data is quarantined once and reports only once.
    try Data("not json either".utf8).write(to: perProjectURL)
    let corruptProject = model.loadSessionSnapshot(
        forProject: URL(
            fileURLWithPath: missingRoot.projectRoot,
            isDirectory: true
        )
    )
    #expect(corruptProject.snapshot == nil)
    #expect(corruptProject.problem == .corruptFile)
    #expect(!FileManager.default.fileExists(atPath: perProjectURL.path))
    #expect(FileManager.default.fileExists(
        atPath: perProjectURL.path + ".corrupt"
    ))
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

    let snapshot = try #require(model.loadSessionSnapshot(forProject: root).snapshot)
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

@MainActor
@Test
func midRestoreCheckpointWriteLeavesLastValidSnapshotIntact() async throws {
    let root = try sessionRestoreProject(["main.rs": "fn saved() {}\n"])
    // A large regular-tier dependency file keeps the restore loop busy in
    // its second tab while the workspace is already fully installed.
    let slowDependency = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "CodeInsightSlowDependency-\(UUID().uuidString).rs"
        )
    let slowLine = "pub fn slow() { let a = 1; } "
        + String(repeating: "x", count: 1_400) + "\n"
    try String(repeating: slowLine, count: 3_000)
        .write(to: slowDependency, atomically: true, encoding: .utf8)
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: slowDependency)
    }
    let stateRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "CodeInsightMidRestoreSession-\(UUID().uuidString)",
            isDirectory: true
        )
    let sessionURL = stateRoot.appendingPathComponent("session.json")
    try FileManager.default.createDirectory(
        at: stateRoot,
        withIntermediateDirectories: true
    )
    let model = AppModel(
        sessionURL: sessionURL,
        indexService: SessionRestoreIndexService()
    )
    let oldSnapshot = SessionCodec.Snapshot(
        projectRoot: root.path,
        language: .rust,
        revision: nil,
        activeTabOrdinal: nil,
        panelPreset: PanelPresetModel.reading.rawValue,
        tabs: []
    )
    let oldBytes = try SessionCodec.encode(
        oldSnapshot,
        maximumTabCount: model.tabStrip.maximumCount,
        dependencyAllowed: exactLocationIsInDependency
    )
    // The last valid snapshot lives at this project's per-project path.
    let perProjectURL = stateRoot.appendingPathComponent("sessions")
        .appendingPathComponent(
            AppModel.sessionProjectKey(for: root) + ".json"
        )
    try FileManager.default.createDirectory(
        at: perProjectURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try oldBytes.write(to: perProjectURL, options: .atomic)
    defer { try? FileManager.default.removeItem(at: stateRoot) }

    let restoring = SessionCodec.Snapshot(
        projectRoot: root.path,
        language: .rust,
        revision: nil,
        activeTabOrdinal: 0,
        panelPreset: PanelPresetModel.reading.rawValue,
        tabs: [
            .file(.init(
                path: "main.rs",
                anchorContentID: nil,
                scrollAnchor: nil,
                selectionAnchor: nil
            )),
            .file(.init(
                path: slowDependency.path,
                anchorContentID: nil,
                scrollAnchor: nil,
                selectionAnchor: nil
            )),
        ]
    )
    let restoreTask = Task { await model.restoreSession(restoring) }
    // Once the first tab is installed the restore is between tabs; a
    // synchronous save attempt there (e.g. quit or project switch) must
    // not overwrite the last valid snapshot with the partial tab strip.
    var bytesAfterMidRestoreWrite: Data?
    #expect(await testWaitUntil("first restored tab installed") {
        model.tabStrip.tabs.count == 1
    })
    try? model.writeSessionCheckpoint(panelPreset: .reading)
    bytesAfterMidRestoreWrite = try Data(contentsOf: perProjectURL)

    #expect(await restoreTask.value == true)
    #expect(bytesAfterMidRestoreWrite == oldBytes)
    // The completed restore commits its own first full snapshot.
    let committed = try #require(
        model.loadSessionSnapshot(forProject: root).snapshot
    )
    #expect(committed.tabs.count == 2)
    #expect(committed.tabs.compactMap { tab -> String? in
        guard case .file(let file) = tab else { return nil }
        return file.path
    } == ["main.rs", slowDependency.path])
}

@MainActor
@Test
func syncSaveDuringBlockedRestoreIndexingKeepsDiskSnapshotIntact() async throws {
    let root = try sessionRestoreProject(["main.rs": "fn saved() {}\n"])
    defer { try? FileManager.default.removeItem(at: root) }
    let stateRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "CodeInsightBlockedRestoreSession-\(UUID().uuidString)",
            isDirectory: true
        )
    let sessionURL = stateRoot.appendingPathComponent("session.json")
    try FileManager.default.createDirectory(
        at: stateRoot,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let gatedService = GatedSessionRestoreIndexService(blockedRoot: root)
    let model = AppModel(
        sessionURL: sessionURL,
        indexService: gatedService
    )
    let oldSnapshot = SessionCodec.Snapshot(
        projectRoot: root.path,
        language: .rust,
        revision: nil,
        activeTabOrdinal: nil,
        panelPreset: PanelPresetModel.reading.rawValue,
        tabs: []
    )
    let oldBytes = try SessionCodec.encode(
        oldSnapshot,
        maximumTabCount: model.tabStrip.maximumCount,
        dependencyAllowed: exactLocationIsInDependency
    )
    let perProjectURL = stateRoot.appendingPathComponent("sessions")
        .appendingPathComponent(
            AppModel.sessionProjectKey(for: root) + ".json"
        )
    try FileManager.default.createDirectory(
        at: perProjectURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try oldBytes.write(to: perProjectURL, options: .atomic)

    let restoreTask = Task {
        await model.restoreSession(SessionCodec.Snapshot(
            projectRoot: root.path,
            language: .rust,
            revision: nil,
            activeTabOrdinal: 0,
            panelPreset: PanelPresetModel.reading.rawValue,
            tabs: [
                .file(.init(
                    path: "main.rs",
                    anchorContentID: nil,
                    scrollAnchor: nil,
                    selectionAnchor: nil
                )),
            ]
        ))
    }
    #expect(await testWaitUntil("blocked restore indexing started") {
        await gatedService.hasStartedBlockedIndex()
    })
    try? model.writeSessionCheckpoint(panelPreset: .reading)
    #expect(try Data(contentsOf: perProjectURL) == oldBytes)

    // Interrupt the blocked restore with a real project open; the restore
    // must end without ever having replaced the on-disk snapshot.
    let otherRoot = try sessionRestoreProject(["other.rs": "fn other() {}\n"])
    defer { try? FileManager.default.removeItem(at: otherRoot) }
    model.openProject(root: otherRoot)
    #expect(await restoreTask.value == false)
    #expect(try Data(contentsOf: perProjectURL) == oldBytes)
}

@MainActor
@Test
func sessionCheckpointWriteFailureSurfacesNoticeAndSuccessClearsIt() async throws {
    let root = try sessionRestoreProject(["main.rs": "fn saved() {}\n"])
    defer { try? FileManager.default.removeItem(at: root) }
    // A regular file where the session store directory should live makes
    // every write fail without touching any previous data.
    let blocker = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "CodeInsightSessionWriteBlocker-\(UUID().uuidString)"
        )
    try Data().write(to: blocker)
    let sessionURL = blocker.appendingPathComponent("session.json")
    let perProjectURL = blocker.appendingPathComponent("sessions")
        .appendingPathComponent(
            AppModel.sessionProjectKey(for: root) + ".json"
        )
    defer { try? FileManager.default.removeItem(at: blocker) }
    let model = AppModel(
        sessionURL: sessionURL,
        indexService: SessionRestoreIndexService()
    )
    try model.openProject(root: root, language: .rust)
    try #require(await testWaitUntil("project installed") {
        model.snapshotPhase == .fullReady
    })

    #expect(throws: Error.self) {
        try model.writeSessionCheckpoint(panelPreset: .reading)
    }
    #expect(model.sessionSaveNotice?.hasPrefix("Reading session not saved:") == true)
    #expect(!FileManager.default.fileExists(atPath: perProjectURL.path))

    try FileManager.default.removeItem(at: blocker)
    try model.writeSessionCheckpoint(panelPreset: .reading)
    #expect(model.sessionSaveNotice == nil)
    #expect(FileManager.default.fileExists(atPath: perProjectURL.path))
}

@MainActor
@Test
func continuouslyRescheduledCheckpointCommitsWithinDirtyDeadline() async throws {
    let root = try sessionRestoreProject(["main.rs": "fn saved() {}\n"])
    defer { try? FileManager.default.removeItem(at: root) }
    let stateRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "CodeInsightDirtyDeadlineSession-\(UUID().uuidString)",
            isDirectory: true
        )
    let sessionURL = stateRoot.appendingPathComponent("session.json")
    let perProjectURL = stateRoot.appendingPathComponent("sessions")
        .appendingPathComponent(
            AppModel.sessionProjectKey(for: root) + ".json"
        )
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let model = AppModel(
        sessionURL: sessionURL,
        indexService: SessionRestoreIndexService()
    )
    try model.openProject(root: root, language: .rust)
    try #require(await testWaitUntil("project installed") {
        model.snapshotPhase == .fullReady
    })

    // Reschedule faster than the 250 ms debounce window for longer than
    // the 2 s dirty deadline: the checkpoint must still be committed.
    let startedAt = ContinuousClock.now
    while ContinuousClock.now < startedAt + .seconds(3) {
        model.scheduleSessionCheckpoint(panelPreset: .reading)
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(FileManager.default.fileExists(atPath: perProjectURL.path))
}

@MainActor
@Test
func perProjectSnapshotsRestoreIndependentlyAcrossProjectSwitches() async throws {
    let rootA = try sessionRestoreProject([
        "a.rs": "fn alpha() {}\n",
        "b.rs": "fn beta() {}\n",
    ])
    let rootB = try sessionRestoreProject([
        "c.rs": "fn gamma() {}\n",
    ])
    defer {
        try? FileManager.default.removeItem(at: rootA)
        try? FileManager.default.removeItem(at: rootB)
    }
    let stateRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "CodeInsightPerProjectSessions-\(UUID().uuidString)",
            isDirectory: true
        )
    let sessionURL = stateRoot.appendingPathComponent("session.json")
    let pointerSuite = "CodeInsightPerProject-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: pointerSuite)!
    defer {
        try? FileManager.default.removeItem(at: stateRoot)
        defaults.removePersistentDomain(forName: pointerSuite)
    }
    let store = RecentProjectsStore(defaults: defaults)
    let model = AppModel(
        sessionURL: sessionURL,
        recentProjectsStore: store,
        indexService: SessionRestoreIndexService()
    )

    func loadFor(_ root: URL) -> SessionCodec.Snapshot? {
        model.loadSessionSnapshot(forProject: root).snapshot
    }

    // Project A: open two tabs and save.
    try model.openProject(root: rootA, language: .rust)
    try #require(await testWaitUntil("A installed") {
        model.snapshotPhase == .fullReady
    })
    model.openInNewTab(rootA.appendingPathComponent("a.rs"))
    model.openInNewTab(rootA.appendingPathComponent("b.rs"))
    try model.writeSessionCheckpoint(panelPreset: .reading)
    #expect(store.lastSessionProjectPath == rootA.path)
    let savedA = try #require(loadFor(rootA))
    #expect(savedA.tabs.count == 2)

    // Switch to project B: one tab, saved separately.
    model.openProject(root: rootB)
    try #require(await testWaitUntil("B installed") {
        model.snapshotPhase == .fullReady
            && model.fileTree?.root.standardizedFileURL
                == rootB.standardizedFileURL
    })
    model.openInNewTab(rootB.appendingPathComponent("c.rs"))
    try model.writeSessionCheckpoint(panelPreset: .reading)
    #expect(store.lastSessionProjectPath == rootB.path)
    #expect(loadFor(rootB)?.tabs.count == 1)

    // Both snapshots survived the switch and restore independently.
    let reloadedA = try #require(loadFor(rootA))
    #expect(reloadedA.projectRoot == rootA.path)
    #expect(reloadedA.tabs.compactMap { tab -> String? in
        guard case .file(let file) = tab else { return nil }
        return file.path
    } == ["a.rs", "b.rs"])
    #expect(await model.restoreSession(reloadedA) == true)
    #expect(model.tabStrip.tabs.count == 2)
    #expect(model.tabStrip.tabs.compactMap(\.fileURL?.lastPathComponent)
        == ["a.rs", "b.rs"])
    try model.writeSessionCheckpoint(panelPreset: .reading)
    #expect(store.lastSessionProjectPath == rootA.path)
}

@MainActor
@Test
func legacyV1SessionMigratesToPerProjectStoreOnce() async throws {
    let root = try sessionRestoreProject(["main.rs": "fn main() {}\n"])
    defer { try? FileManager.default.removeItem(at: root) }
    let stateRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "CodeInsightLegacyMigration-\(UUID().uuidString)",
            isDirectory: true
        )
    let sessionURL = stateRoot.appendingPathComponent("session.json")
    try FileManager.default.createDirectory(
        at: stateRoot,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let pointerSuite = "CodeInsightLegacyMigration-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: pointerSuite)!
    defer { defaults.removePersistentDomain(forName: pointerSuite) }
    let store = RecentProjectsStore(defaults: defaults)
    let model = AppModel(
        sessionURL: sessionURL,
        recentProjectsStore: store,
        indexService: SessionRestoreIndexService()
    )

    // Hand-written v1 payload: single language field, one file tab.
    try """
    {"schemaVersion":1,"projectRoot":\(encodeJSONString(root.path)),
     "language":0,"revision":null,"activeTabOrdinal":0,
     "panelPreset":"reading","tabs":[{"kind":"file","path":"main.rs",
     "anchorContentID":null,"scrollAnchor":null,"selectionAnchor":null}]}
    """.data(using: .utf8)!.write(to: sessionURL, options: .atomic)

    let legacy = model.loadLegacySessionSnapshot()
    let snapshot = try #require(legacy.snapshot)
    #expect(snapshot.language == .rust)
    #expect(snapshot.tabs.count == 1)
    #expect(store.lastSessionProjectPath == nil)

    // Restoring and checkpointing writes the per-project file, updates
    // the pointer, and retires the legacy file exactly once.
    #expect(await model.restoreSession(snapshot))
    try model.writeSessionCheckpoint(panelPreset: .reading)
    #expect(store.lastSessionProjectPath == root.path)
    let perProjectURL = stateRoot.appendingPathComponent("sessions")
        .appendingPathComponent(
            AppModel.sessionProjectKey(for: root) + ".json"
        )
    #expect(FileManager.default.fileExists(atPath: perProjectURL.path))
    #expect(!FileManager.default.fileExists(atPath: sessionURL.path))
    #expect(FileManager.default.fileExists(
        atPath: sessionURL.path + ".migrated"
    ))
    #expect(model.loadLegacySessionSnapshot().snapshot == nil)

    // The migrated data round-trips through the per-project store.
    let migrated = try #require(
        model.loadSessionSnapshot(forProject: root).snapshot
    )
    #expect(migrated.tabs.count == 1)
}

@MainActor
@Test
func futureVersionPerProjectSnapshotIsPreservedAndNotOverwritten() async throws {
    let root = try sessionRestoreProject(["main.rs": "fn main() {}\n"])
    defer { try? FileManager.default.removeItem(at: root) }
    let stateRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "CodeInsightFutureSchema-\(UUID().uuidString)",
            isDirectory: true
        )
    let sessionURL = stateRoot.appendingPathComponent("session.json")
    defer { try? FileManager.default.removeItem(at: stateRoot) }
    let model = AppModel(
        sessionURL: sessionURL,
        indexService: SessionRestoreIndexService()
    )
    let perProjectURL = stateRoot.appendingPathComponent("sessions")
        .appendingPathComponent(
            AppModel.sessionProjectKey(for: root) + ".json"
        )
    try FileManager.default.createDirectory(
        at: perProjectURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let futureBytes = Data("{\"schemaVersion\":99}".utf8)
    try futureBytes.write(to: perProjectURL, options: .atomic)

    let blocked = model.loadSessionSnapshot(forProject: root)
    #expect(blocked.snapshot == nil)
    #expect(blocked.problem == .unsupportedSchemaVersion(99))

    // Opening and saving the project must not touch the newer file.
    try model.openProject(root: root, language: .rust)
    try #require(await testWaitUntil("project installed") {
        model.snapshotPhase == .fullReady
    })
    model.openInNewTab(root.appendingPathComponent("main.rs"))
    try model.writeSessionCheckpoint(panelPreset: .reading)
    #expect(try Data(contentsOf: perProjectURL) == futureBytes)
    #expect(model.loadSessionSnapshot(forProject: root).snapshot == nil)
}

@MainActor
@Test
func clearingTheCurrentProjectSessionDropsStateAndWritesEmptySnapshot() async throws {
    let root = try sessionRestoreProject([
        "main.rs": "fn main() {}\n",
        "other.rs": "fn other() {}\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let stateRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "CodeInsightClearSession-\(UUID().uuidString)",
            isDirectory: true
        )
    let sessionURL = stateRoot.appendingPathComponent("session.json")
    let pointerSuite = "CodeInsightClearSession-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: pointerSuite)!
    defer {
        try? FileManager.default.removeItem(at: stateRoot)
        defaults.removePersistentDomain(forName: pointerSuite)
    }
    let store = RecentProjectsStore(defaults: defaults)
    let model = AppModel(
        sessionURL: sessionURL,
        recentProjectsStore: store,
        indexService: SessionRestoreIndexService()
    )
    try model.openProject(root: root, language: .rust)
    try #require(await testWaitUntil("project installed") {
        model.snapshotPhase == .fullReady
    })
    model.openInNewTab(root.appendingPathComponent("main.rs"))
    model.openInNewTab(root.appendingPathComponent("other.rs"))
    model.navigationHistory.push(JumpRecord(
        path: "main.rs",
        contentID: nil,
        byteOffset: 0,
        line: 1,
        column: 1,
        symbolAnchor: nil,
        snapshotID: nil
    ))
    model.readingTrail.recordNavigation(
        from: nil,
        to: JumpRecord(
            path: "other.rs",
            contentID: nil,
            byteOffset: 0,
            line: 1,
            column: 1,
            symbolAnchor: nil,
            snapshotID: nil
        )
    )
    try model.writeSessionCheckpoint(panelPreset: .reading)
    #expect(model.loadSessionSnapshot(forProject: root).snapshot?.tabs.count == 2)

    try model.clearSessionForCurrentProject(panelPreset: .reading)

    #expect(model.tabStrip.tabs.isEmpty)
    #expect(model.navigationHistory.records.isEmpty)
    #expect(model.readingTrail.nodes.isEmpty)
    #expect(model.selectedFile == nil)
    // The cleared state is committed as an empty snapshot, so a later
    // exit cannot resurrect the old tabs.
    let cleared = try #require(
        model.loadSessionSnapshot(forProject: root).snapshot
    )
    #expect(cleared.tabs.isEmpty)
    #expect(cleared.projectRoot == root.path)
    #expect(store.lastSessionProjectPath == root.path)
}

@MainActor
@Test
func sessionRestoreReinstatesPreviewFlagAndLRUEvictionOrder() async throws {
    let root = try sessionRestoreProject([
        "a.rs": "fn a() {}\n",
        "b.rs": "fn b() {}\n",
        "c.rs": "fn c() {}\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let snapshot = SessionCodec.Snapshot(
        projectRoot: root.path,
        language: .rust,
        revision: nil,
        activeTabOrdinal: 1,
        panelPreset: PanelPresetModel.reading.rawValue,
        tabs: [
            .file(.init(
                path: "a.rs",
                anchorContentID: nil,
                scrollAnchor: nil,
                selectionAnchor: nil,
                isPreview: true,
                activationRank: 0
            )),
            .file(.init(
                path: "b.rs",
                anchorContentID: nil,
                scrollAnchor: nil,
                selectionAnchor: nil,
                activationRank: 2
            )),
            .file(.init(
                path: "c.rs",
                anchorContentID: nil,
                scrollAnchor: nil,
                selectionAnchor: nil,
                activationRank: 1
            )),
        ]
    )
    let model = AppModel(indexService: SessionRestoreIndexService())

    #expect(await model.restoreSession(snapshot))

    #expect(model.tabStrip.tabs.count == 3)
    #expect(model.tabStrip.activeIndex == 1)
    #expect(model.tabStrip.tabs[0].isPreview == true)
    #expect(model.tabStrip.activeTab?.fileURL?.lastPathComponent == "b.rs")
    // The relative activation order was rebuilt: the active tab is the
    // freshest and a is the next eviction candidate.
    #expect(model.tabStrip.tabs[0].lastActivated
        < model.tabStrip.tabs[2].lastActivated)
    #expect(model.tabStrip.tabs[2].lastActivated
        < model.tabStrip.tabs[1].lastActivated)
}

@MainActor
@Test
func sessionRestoreReportsWhenTheSavedActiveTabIsUnavailable() async throws {
    let root = try sessionRestoreProject(["main.rs": "fn main() {}\n"])
    defer { try? FileManager.default.removeItem(at: root) }
    let snapshot = SessionCodec.Snapshot(
        projectRoot: root.path,
        language: .rust,
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
                path: "missing.rs",
                anchorContentID: nil,
                scrollAnchor: nil,
                selectionAnchor: nil
            )),
        ]
    )
    let model = AppModel(indexService: SessionRestoreIndexService())

    #expect(await model.restoreSession(snapshot))

    #expect(model.tabStrip.tabs.count == 1)
    #expect(model.tabStrip.activeIndex == 0)
    #expect(model.replayNotice?.contains(
        "saved active tab unavailable; activated the first restored tab"
    ) == true)
}

private func encodeJSONString(_ value: String) -> String {
    let array = String(
        decoding: (try? JSONEncoder().encode([value])) ?? Data(),
        as: UTF8.self
    )
    return String(array.dropFirst().dropLast())
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
