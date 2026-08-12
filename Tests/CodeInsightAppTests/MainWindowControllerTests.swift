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
func unsupportedExplicitOpenDoesNotFallbackToRust() {
    let fixture = MainWindowIdentityFixture()
    defer { fixture.close() }
    let root = URL(fileURLWithPath: "/projects/unsupported", isDirectory: true)

    fixture.controller.openProject(root: root, language: .typescript)

    #expect(fixture.controller.pendingRecentProjectLanguage == .typescript)
    #expect(fixture.controller.lastOpenedProjectLanguage == .typescript)
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
    let menuText = controller.selfTestProfileMenuTitles.joined(separator: " · ")
    #expect(!menuText.localizedCaseInsensitiveContains("features"))
    #expect(!menuText.localizedCaseInsensitiveContains("edition"))
    #expect(menuText.contains("Trust This Repository"))
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
