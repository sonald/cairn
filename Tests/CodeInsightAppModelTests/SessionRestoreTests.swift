import CodeInsightCore
import CodeInsightEngine
import Foundation
import Testing
@testable import CodeInsightAppModel

@MainActor
@Test
func unsupportedSavedLanguageDoesNotMutateProjectState() async throws {
    let root = try sessionRestoreProject(["main.rs": "fn main() {}\n"])
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

private struct SessionRestoreIndexService: IndexService {
    func index(root: URL, language: LanguageID) async throws -> EngineSession {
        try await Task.detached {
            try ProjectIndexer().index(root: root, language: language)
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
