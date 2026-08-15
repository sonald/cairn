import AppKit
import CodeInsightAppModel
import CodeInsightCore
import CodeInsightEngine
import CodeInsightReaderCore
import Foundation
import Testing
@testable import CodeInsightApp

@MainActor
private final class MainWindowIdentityFixture {
    let defaults: UserDefaults
    let store: RecentProjectsStore
    let controller: MainWindowController
    let model: AppModel
    private let suiteName: String

    init() {
        let suiteName = "MainWindowIdentityTests-\(UUID().uuidString)"
        self.suiteName = suiteName
        defaults = UserDefaults(suiteName: suiteName)!
        store = RecentProjectsStore(defaults: defaults)
        model = AppModel(indexService: MainWindowFailingIndexService(session: nil))
        controller = MainWindowController(
            model: model,
            settings: ReaderSettings(),
            offscreen: true,
            recentProjectsStore: store,
            recordsRecentProjects: true
        )
    }

    func close() {
        controller.close()
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private struct MainWindowFailingIndexService: IndexService {
    let session: EngineSession?

    func index(
        root: URL,
        language: LanguageID
    ) async throws -> EngineSession {
        if let session {
            return session
        }
        throw CocoaError(.featureUnsupported)
    }
}

@MainActor
@Test
func recentProjectClickForwardsStoredLanguage() {
    let fixture = MainWindowIdentityFixture()
    defer { fixture.close() }
    let root = URL(fileURLWithPath: "/projects/click", isDirectory: true)
    fixture.store.record(root.standardizedFileURL, language: .python)

    fixture.controller.openRecentProject(root)

    #expect(fixture.controller.pendingRecentProjectLanguage == .python)
    #expect(fixture.controller.lastOpenedProjectLanguage == .python)
}

@MainActor
@Test
func recentProjectStoresTypeScriptRawValueTwoAndForwards() {
    let fixture = MainWindowIdentityFixture()
    defer { fixture.close() }
    let root = URL(fileURLWithPath: "/projects/ts-recent", isDirectory: true)
    fixture.store.record(root.standardizedFileURL, language: .typescript)

    fixture.controller.openRecentProject(root)

    #expect(fixture.store.language(for: root.standardizedFileURL.path) == .typescript)
    #expect(fixture.controller.pendingRecentProjectLanguage == .typescript)
    #expect(fixture.controller.lastOpenedProjectLanguage == .typescript)
}

@MainActor
@Test
func recentProjectWithoutLanguageForwardedAsRust() {
    let fixture = MainWindowIdentityFixture()
    defer { fixture.close() }
    let root = URL(fileURLWithPath: "/projects/legacy", isDirectory: true)

    fixture.controller.openRecentProject(root)

    #expect(fixture.controller.pendingRecentProjectLanguage == .rust)
    #expect(fixture.controller.lastOpenedProjectLanguage == .rust)
}

@MainActor
@Test
func oldOpenProjectDelegatesToRustAndKeepsRustLastOpenedLanguage() {
    let fixture = MainWindowIdentityFixture()
    defer { fixture.close() }
    let root = URL(fileURLWithPath: "/projects/rust-open", isDirectory: true)

    fixture.controller.openProject(root: root)

    #expect(fixture.controller.pendingRecentProjectLanguage == .rust)
    #expect(fixture.controller.lastOpenedProjectLanguage == .rust)
    #expect(fixture.store.language(for: root.standardizedFileURL.path) == .rust)
}

@MainActor
@Test
func recentProjectClickForwardsStoredLanguageSet() async throws {
    let fixture = MainWindowIdentityFixture()
    defer { fixture.close() }
    let root = URL(fileURLWithPath: "/projects/mixed", isDirectory: true)
    fixture.store.record(
        root.standardizedFileURL,
        languages: [.typescript, .rust]
    )

    fixture.controller.openRecentProject(root)

    #expect(fixture.controller.pendingRecentProjectLanguage == .rust)
    #expect(fixture.controller.lastOpenedProjectLanguage == .rust)
    let indexingStarted: () -> Bool = {
        if case .indexing = fixture.model.projectState { return true }
        return false
    }
    try #require(await mainWindowWaitUntil(indexingStarted()))
    #expect(fixture.model.projectLanguages == [.rust, .typescript])
}

@MainActor
@Test
func retryForwardsCompleteLanguageSet() async throws {
    let fixture = MainWindowIdentityFixture()
    defer { fixture.close() }
    let root = URL(fileURLWithPath: "/projects/mixed-retry", isDirectory: true)
    fixture.controller.openProject(
        root: root,
        languages: [.typescript, .rust, .python]
    )

    fixture.controller.retryLastOpenedProject()

    #expect(fixture.controller.lastOpenedProjectLanguage == .rust)
    let indexingStarted: () -> Bool = {
        if case .indexing = fixture.model.projectState { return true }
        return false
    }
    try #require(await mainWindowWaitUntil(indexingStarted()))
    #expect(fixture.model.projectLanguages == [.rust, .python, .typescript])
}

@MainActor
@Test
func explicitOpenProjectForwardsLanguageAndRecordsPendingAsPython() {
    let fixture = MainWindowIdentityFixture()
    defer { fixture.close() }
    let root = URL(fileURLWithPath: "/projects/explicit", isDirectory: true)

    fixture.controller.openProject(root: root, language: .python)

    #expect(fixture.controller.pendingRecentProjectLanguage == .python)
    #expect(fixture.controller.lastOpenedProjectLanguage == .python)
    #expect(fixture.store.paths == [])
    guard case .indexing = fixture.model.projectState else {
        Issue.record("expected Python open to begin indexing")
        return
    }
    #expect(fixture.model.projectLanguage == .python)
    #expect(fixture.model.projectRoot == root.standardizedFileURL)
}

@MainActor
@Test
func unsupportedJavaScriptExplicitOpenDoesNotFallbackToRust() {
    let fixture = MainWindowIdentityFixture()
    defer { fixture.close() }
    let root = URL(fileURLWithPath: "/projects/unsupported", isDirectory: true)

    fixture.controller.openProject(root: root, language: .javascript)

    #expect(fixture.controller.pendingRecentProjectLanguage == .javascript)
    #expect(fixture.controller.lastOpenedProjectLanguage == .javascript)
    #expect(fixture.store.paths == [])
    guard case .empty = fixture.model.projectState else {
        Issue.record("unsupported open must stay empty, not fall back to Rust")
        return
    }
    #expect(fixture.model.projectLanguage == nil)
    #expect(fixture.model.projectRoot == nil)
}

@MainActor
@Test
func explicitTypeScriptOpenForwardsLanguageAndBeginsIndexing() {
    let fixture = MainWindowIdentityFixture()
    defer { fixture.close() }
    let root = URL(fileURLWithPath: "/projects/ts-open", isDirectory: true)

    fixture.controller.openProject(root: root, language: .typescript)

    #expect(fixture.controller.pendingRecentProjectLanguage == .typescript)
    #expect(fixture.controller.lastOpenedProjectLanguage == .typescript)
    #expect(fixture.store.paths == [])
    guard case .indexing = fixture.model.projectState else {
        Issue.record("expected TypeScript open to begin indexing")
        return
    }
    #expect(fixture.model.projectLanguage == .typescript)
    #expect(fixture.model.projectRoot == root.standardizedFileURL)
}

@MainActor
@Test
func pythonProfileDisplayHidesCargoFeatureAndEdition() async throws {
    _ = NSApplication.shared
    let root = try mainWindowTemporaryProject([
        "main.py": "def hello() -> int:\n    return 1\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try ProjectIndexer().index(root: root, language: .python)
    let model = AppModel(
        indexService: MainWindowFailingIndexService(session: session)
    )
    try model.openProject(root: root, language: .python)
    try #require(await mainWindowWaitUntil(
        model.snapshotPhase == .fullReady
    ))
    try #require(await mainWindowWaitUntil(
        model.exactCoordinator.trustMode != nil
    ))
    let controller = MainWindowController(
        model: model,
        settings: ReaderSettings(),
        offscreen: true
    )
    defer { controller.close() }

    #expect(controller.selfTestProfileTitle.contains("Python"))
    #expect(!controller.selfTestProfileTitle.localizedCaseInsensitiveContains(
        "features"
    ))
    #expect(
        controller.selfTestProfileTitle
            == "Python · \(session.analysisProfile.projectUnitName) · Safe"
    )
    let menuText = controller.selfTestProfileMenuTitles.joined(separator: " · ")
    #expect(!menuText.localizedCaseInsensitiveContains("features"))
    #expect(!menuText.localizedCaseInsensitiveContains("edition"))
    #expect(menuText.contains("Trust This Repository"))
}

@MainActor
@Test
func typescriptProfileAndFeatureSwitchMatchNonRustRules() async throws {
    _ = NSApplication.shared
    let root = try mainWindowTemporaryProject([
        "lib.ts": "export function f(): void {}\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }

    let rustSession = try ProjectIndexer().index(root: root)
    let typescriptSession = try ProjectIndexer().index(
        root: root,
        language: .typescript
    )
    let model = AppModel(
        indexService: MainWindowFailingIndexService(session: rustSession)
    )
    try model.openProject(root: root)
    try #require(await mainWindowWaitUntil(
        model.snapshotPhase == .fullReady
    ))
    try #require(await mainWindowWaitUntil(
        model.exactCoordinator.trustMode != nil
    ))

    #expect(model.transition(to: .indexing(
        root: root,
        startedAt: .now
    )))
    #expect(model.transition(to: .ready(
        typescriptSession,
        QueryContext(
            snapshotID: typescriptSession.snapshotID,
            analysisProfileID: typescriptSession.analysisProfile.id,
            generation: model.generation
        )
    )))

    let controller = MainWindowController(
        model: model,
        settings: ReaderSettings(),
        offscreen: true
    )
    defer { controller.close() }

    #expect(controller.selfTestProfileTitle.contains("TypeScript"))
    #expect(!controller.selfTestProfileTitle.localizedCaseInsensitiveContains(
        "features"
    ))
    #expect(
        controller.selfTestProfileTitle
            == "TypeScript · \(typescriptSession.analysisProfile.projectUnitName) · Safe"
    )
    let menuText = controller.selfTestProfileMenuTitles.joined(separator: " · ")
    #expect(!menuText.localizedCaseInsensitiveContains("features"))
    #expect(!menuText.localizedCaseInsensitiveContains("edition"))
    #expect(menuText.contains("Trust This Repository"))

    #expect(model.availableFeatureSelections == [.defaultFeatures])
    let generationBeforeSwitch = model.generation
    model.switchFeatureSelection(.allFeatures)
    #expect(model.generation == generationBeforeSwitch)
    guard case let .ready(session, _) = model.projectState else {
        Issue.record("expected ready TypeScript session")
        return
    }
    #expect(session.analysisProfile.id == typescriptSession.analysisProfile.id)
    #expect(session.analysisProfile.featureSelection == .defaultFeatures)
    #expect(model.currentFeatureSelection == .defaultFeatures)
}

@MainActor
@Test
func rustProfileTitleKeepsFeatureSelectionSegment() async throws {
    _ = NSApplication.shared
    let root = try mainWindowTemporaryProject([
        "src/lib.rs": "pub fn f() {}\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try ProjectIndexer().index(root: root)
    let model = AppModel(
        indexService: MainWindowFailingIndexService(session: session)
    )
    try model.openProject(root: root)
    try #require(await mainWindowWaitUntil(
        model.snapshotPhase == .fullReady
    ))
    try #require(await mainWindowWaitUntil(
        model.exactCoordinator.trustMode != nil
    ))
    let controller = MainWindowController(
        model: model,
        settings: ReaderSettings(),
        offscreen: true
    )
    defer { controller.close() }

    #expect(
        controller.selfTestProfileTitle
            == "Rust · \(session.analysisProfile.projectUnitName) · default · Safe"
    )
}

@MainActor
@Test
func projectSearchQueriesAllWorkspaceSessions() async throws {
    _ = NSApplication.shared
    let root = try mainWindowTemporaryGitProject([
        "z/a.rs": "fn a() { let needle = 1; }\n",
        "m/b.py": "needle = 1\n",
        "c.ts": "const needle = 1;\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(indexService: ProjectIndexService())
    try await model.openProject(root: root, languages: [.typescript, .rust, .python])
    try #require(await mainWindowWaitUntil(
        model.snapshotPhase == .fullReady
    ))
    try #require(await mainWindowWaitUntil(
        model.querySessions.count == 3
    ))
    let controller = MainWindowController(
        model: model,
        settings: ReaderSettings(),
        offscreen: true
    )
    defer { controller.close() }
    controller.showProjectSearch()
    controller.selfTestSetProjectSearchQuery("needle")

    try #require(await mainWindowWaitUntil(
        controller.selfTestProjectSearchOutlineState.map {
            $0.matchRows == 3 && $0.status.contains("3 matches in 3 files")
        } ?? false
    ))
    let state = try #require(controller.selfTestProjectSearchOutlineState)
    #expect(state.groupRows == 3)
    #expect(state.matchRows == 3)
    #expect(!state.searching)
}

@MainActor
@Test
func windowGrowthKeepsSidebarWidthAndGivesSpaceToReader() {
    _ = NSApplication.shared
    let fixture = MainWindowIdentityFixture()
    defer { fixture.close() }
    fixture.controller.applyPanelPreset(.reading)
    fixture.controller.window?.setContentSize(NSSize(width: 1_200, height: 800))
    fixture.controller.window?.contentView?.layoutSubtreeIfNeeded()
    let before = fixture.controller.selfTestUpperPaneWidths

    fixture.controller.window?.setContentSize(NSSize(width: 1_600, height: 800))
    fixture.controller.window?.contentView?.layoutSubtreeIfNeeded()
    let after = fixture.controller.selfTestUpperPaneWidths

    #expect(abs(after.sidebar - before.sidebar) <= 1)
    #expect(after.reader - before.reader >= 399)
    if let directory = ProcessInfo.processInfo.environment[
        "CODEINSIGHT_UI_CAPTURE_DIR"
    ], let view = fixture.controller.selfTestContentView {
        try? mainWindowCapturePNG(
            view,
            at: URL(fileURLWithPath: directory)
                .appendingPathComponent("window-resize.png")
        )
    }
}

@MainActor
private func mainWindowCapturePNG(_ view: NSView, at url: URL) throws {
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    else { throw CocoaError(.fileWriteUnknown) }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:])
    else { throw CocoaError(.fileWriteUnknown) }
    try data.write(to: url)
}

private func mainWindowTemporaryProject(
    _ files: [String: String]
) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MainWindowControllerTests-\(UUID().uuidString)")
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

private func mainWindowTemporaryGitProject(
    _ files: [String: String]
) throws -> URL {
    let root = try mainWindowTemporaryProject(files)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", root.path, "init", "-q"]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CocoaError(.fileWriteUnknown)
    }
    return root
}

@MainActor
private func mainWindowWaitUntil(
    _ condition: @autoclosure () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(30)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
