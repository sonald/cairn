import AppKit
import CodeInsightCore
import CodeInsightEngine
import CodeInsightExact
import CodeInsightReaderCore
import Foundation
import Testing
@testable import CodeInsightApp
@testable import CodeInsightAppModel

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
func bookmarkCommandReportsTheEligibilityReasonOutsideThePrimaryReader() {
    let fixture = MainWindowIdentityFixture()
    defer { fixture.close() }

    #expect(!fixture.controller.canToggleBookmark)
    #expect(fixture.controller.bookmarkCommandAccessibilityHelp
        == "Bookmarks require a current project file in the primary reader.")
}

@MainActor
@Test
func readingHeightIsOnlyEnabledForAReadyFile() throws {
    _ = NSApplication.shared
    let controller = ReaderViewController()
    controller.loadViewIfNeeded()
    let root = try mainWindowTemporaryProject([
        "main.rs": "fn main() {}\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("main.rs")

    controller.showEmptyState(
        recentPaths: [],
        failed: false,
        onChooseProject: {},
        onOpenRecent: { _ in },
        onOpenDropped: { _ in },
        onRetry: {}
    )
    #expect(!controller.selfTestReadingHeightHeader.enabled)
    #expect(!controller.selfTestReadingHeightHeader.hidden)

    controller.removeEmptyState(placeholder: "Indexing project…")
    #expect(!controller.selfTestReadingHeightHeader.enabled)

    controller.display(file)
    #expect(controller.selfTestReadingHeightHeader.enabled)
    #expect(!controller.selfTestReadingHeightHeader.hidden)

    controller.display(.readingSet(title: "set", excerpts: []))
    #expect(!controller.selfTestReadingHeightHeader.enabled)
    #expect(controller.selfTestReadingHeightHeader.hidden)

    controller.display(file)
    #expect(controller.selfTestReadingHeightHeader.enabled)
    #expect(!controller.selfTestReadingHeightHeader.hidden)

    controller.display(root.appendingPathComponent("missing.rs"))
    #expect(!controller.selfTestReadingHeightHeader.enabled)
    #expect(!controller.selfTestReadingHeightHeader.hidden)
}

@MainActor
@Test
func bookmarkPanelExportsTheOriginalCorruptBytes() throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "CodeInsightBookmarkPanel-\(UUID().uuidString)", isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let input = directory.appendingPathComponent("bookmarks.json")
    let output = directory.appendingPathComponent("raw-copy.json")
    let bytes = Data([0x7B, 0xFF, 0x00])
    try bytes.write(to: input)
    let model = AppModel()
    model.bookmarkModel = BookmarkModel(store: BookmarkStore(fileURL: input))
    let panel = BookmarkPanel(appModel: model, onOpen: { _ in }, onLineOpen: { _, _ in })

    #expect(panel.exportRawCopy(to: output))
    #expect(try Data(contentsOf: output) == bytes)
}

@MainActor
@Test
func bookmarkPanelClearsInvalidFilteredAndDeletedSelectionsBeforeEditingANote() async throws {
    _ = NSApplication.shared
    let root = try mainWindowTemporaryProject([
        "src/main.rs": "fn main() {}\n",
        "src/other.rs": "fn other() {}\n",
    ])
    let sessionURL = root.appendingPathComponent("session.json")
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(sessionURL: sessionURL)
    try await model.openProject(root: root, languages: [.rust])
    let record = BookmarkRecord(
        id: UUID(), projectPath: root.standardizedFileURL.path, snapshot: .worktree,
        path: "src/main.rs",
        contentID: ContentID.sha256(of: Data("fn main() {}\n".utf8)),
        byteOffset: 0, line: 1, symbolName: nil, symbolKind: nil, note: "", updatedAt: .now
    )
    let other = BookmarkRecord(
        id: UUID(), projectPath: root.standardizedFileURL.path, snapshot: .worktree,
        path: "src/other.rs",
        contentID: ContentID.sha256(of: Data("fn other() {}\n".utf8)),
        byteOffset: 0, line: 1, symbolName: nil, symbolKind: nil, note: "",
        updatedAt: Date(timeIntervalSince1970: 1)
    )
    #expect(model.bookmarkModel.toggle(record) == .added)
    #expect(model.bookmarkModel.toggle(other) == .added)
    let panel = BookmarkPanel(appModel: model, onOpen: { _ in }, onLineOpen: { _, _ in })
    defer { panel.closePanel() }
    panel.show(relativeTo: nil)
    #expect(panel.selfTestSelectFirstRow())

    panel.selfTestClearSelection()
    panel.selfTestTypeNote("must not attach to a stale row")

    #expect(model.bookmarkModel.records.first(where: { $0.id == record.id })?.note.isEmpty == true)

    #expect(panel.selfTestSelectFirstRow())
    panel.selfTestSetFilter("no-bookmark-match")
    panel.selfTestTypeNote("must not attach after filtering")
    #expect(model.bookmarkModel.records.first(where: { $0.id == record.id })?.note.isEmpty == true)

    panel.selfTestSetFilter(record.path)
    #expect(panel.selfTestSelectFirstRow())
    #expect(model.bookmarkModel.delete(id: record.id))
    panel.refresh()
    panel.selfTestTypeNote("must not attach after deletion")
    #expect(model.bookmarkModel.records.first(where: { $0.id == other.id })?.note.isEmpty == true)
}

@MainActor
@Test
func bookmarkPanelSelfTestActionsTargetRowsByUUIDAndExposeTheirStatus() {
    _ = NSApplication.shared
    let root = try! mainWindowTemporaryProject(["src/main.rs": "fn main() {}\n"])
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel()
    model.openProject(root: root)
    let record = BookmarkRecord(
        id: UUID(), projectPath: root.path, snapshot: .commit(fullOID: String(repeating: "a", count: 40)),
        path: "src/main.rs", contentID: ContentID.sha256(of: Data("old\n".utf8)),
        byteOffset: 0, line: 1, symbolName: nil, symbolKind: nil, note: "", updatedAt: .now
    )
    #expect(model.bookmarkModel.toggle(record) == .added)
    var opened: UUID?
    var openedLine: UUID?
    let panel = BookmarkPanel(
        appModel: model,
        onOpen: { opened = $0.id },
        onLineOpen: { record, _ in openedLine = record.id }
    )
    defer { panel.closePanel() }
    panel.show(relativeTo: nil)

    #expect(panel.selfTestRowToolTip(id: record.id) == "Not evaluated")
    #expect(panel.selfTestPressOpen(id: record.id))
    #expect(opened == record.id)
    #expect(openedLine == nil)
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
    try #require(await mainWindowWaitUntil(
        fixture.model.projectLanguages == [.rust, .typescript]
    ))
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
    try #require(await mainWindowWaitUntil(
        fixture.model.projectLanguages == [.rust, .python, .typescript]
    ))
    #expect(fixture.model.projectLanguages == [.rust, .python, .typescript])
}

@MainActor
@Test
func mixedOpenFailureDoesNotRecordRecentPath() async throws {
    let fixture = MainWindowIdentityFixture()
    defer { fixture.close() }
    let root = URL(
        fileURLWithPath: "/projects/mixed-failure",
        isDirectory: true
    )

    fixture.controller.openProject(
        root: root,
        languages: [.typescript, .rust, .python]
    )
    try #require(await mainWindowWaitUntil(
        mainWindowProjectStateFailed(fixture.model)
    ))
    #expect(fixture.store.paths == [])
    #expect(fixture.controller.pendingRecentProjectLanguage == .rust)
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
    model.openProject(root: root)
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
    model.openProject(root: root)
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
@Test
func bookmarkVisualGateRejectsUniformBitmapsAndAcceptsVisibleChange() {
    let context = CGContext(
        data: nil,
        width: 16,
        height: 16,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(NSColor.black.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
    let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)

    #expect(!bookmarkBitmapHasVisiblePixels(bitmap))

    context.setFillColor(NSColor.white.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
    let whiteBitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
    #expect(!bookmarkBitmapHasVisiblePixels(whiteBitmap))

    context.setFillColor(NSColor.black.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 8, height: 16))
    #expect(bookmarkBitmapHasVisiblePixels(
        NSBitmapImageRep(cgImage: context.makeImage()!)
    ))
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
private func mainWindowProjectStateFailed(_ model: AppModel) -> Bool {
    if case .failed = model.projectState { return true }
    return false
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

@MainActor
@Test
func emptyStateFailureShowsReasonAndRecoveryActions() {
    _ = NSApplication.shared
    let controller = ReaderViewController()
    controller.loadViewIfNeeded()
    let longReason = String(
        repeating: "provider stderr line; ", count: 40
    )

    controller.showEmptyState(
        recentPaths: [],
        failed: true,
        failureReason: AppModel.failureSummary(
            CocoaError(.fileReadNoSuchFile)
        ),
        onChooseProject: {},
        onOpenRecent: { _ in },
        onOpenDropped: { _ in },
        onRetry: {}
    )
    #expect(controller.selfTestEmptyStateTexts.contains("Couldn't open this folder."))
    #expect(controller.selfTestEmptyStateButtonTitles.contains("Try Again"))
    #expect(
        controller.selfTestEmptyStateButtonTitles.contains("Open Another Folder…"),
        "failure state must offer choosing a different folder"
    )
    #expect(controller.selfTestEmptyStateFailureReason?.isEmpty == false)
    #expect(controller.selfTestEmptyStateReasonIsSelectable)
    #expect(controller.selfTestEmptyStateChooseFolderActionAvailable)

    // A provider-sized reason stays bounded and does not grow without limit.
    let bounded = AppModel.failureSummary(
        LSPError.processExited(1, longReason)
    )
    #expect(bounded.count <= 281)
    controller.showEmptyState(
        recentPaths: [],
        failed: true,
        failureReason: bounded,
        onChooseProject: {},
        onOpenRecent: { _ in },
        onOpenDropped: { _ in },
        onRetry: {}
    )
    #expect(controller.selfTestEmptyStateFailureReason == bounded)

    // The default empty state carries no reason and no second button.
    controller.showEmptyState(
        recentPaths: [],
        failed: false,
        onChooseProject: {},
        onOpenRecent: { _ in },
        onOpenDropped: { _ in },
        onRetry: {}
    )
    #expect(controller.selfTestEmptyStateFailureReason == nil)
    #expect(!controller.selfTestEmptyStateButtonTitles.contains("Open Another Folder…"))
}

@MainActor
private final class ContextExactBadgeGate {
    private var continuation:
        CheckedContinuation<ExactCoordinator.DefinitionResult?, Never>?

    func resolve(
        file: String,
        offset: UInt32,
        generation: UInt64,
        batch: ExactRequestBatch
    ) async -> ExactCoordinator.DefinitionResult? {
        await withCheckedContinuation { continuation = $0 }
    }

    func complete(with entry: ExactOverlay.Entry?) {
        continuation?.resume(
            returning: .completed(entry.map { [$0] } ?? [])
        )
        continuation = nil
    }
}

@MainActor
@Test
func contextHeaderLongProvenanceStaysShortAndDoesNotWidenTheWindow() async throws {
    _ = NSApplication.shared
    let source = "pub fn target() -> i32 { 42 }\npub fn main() { target(); }\n"
    let root = try mainWindowTemporaryProject(["main.rs": source])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try ProjectIndexer().index(root: root)
    let context = QueryContext(
        snapshotID: session.snapshotID,
        analysisProfileID: session.analysisProfile.id,
        generation: 1
    )
    let gate = ContextExactBadgeGate()
    let contextModel = ContextWindowModel(
        { session, file, offset, context in
            try session.resolve(file: file, offset: offset, context: context)
        },
        exactResolver: gate.resolve
    )
    contextModel.updateProjectState(.ready(session, context), root: root)
    let controller = ContextWindowViewController(model: contextModel)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 300),
        styleMask: [.titled, .resizable],
        backing: .buffered,
        defer: false
    )
    window.minSize = NSSize(width: 900, height: 300)
    let content = NSView()
    controller.view.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(controller.view)
    NSLayoutConstraint.activate([
        controller.view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
        controller.view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        controller.view.topAnchor.constraint(equalTo: content.topAnchor),
        controller.view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
    ])
    window.contentView = content
    window.setContentSize(NSSize(width: 900, height: 300))
    let frameBefore = window.frame

    contextModel.tokenClicked(
        file: "main.rs",
        offset: UInt32(source[..<source.range(of: "target();")!.lowerBound].utf8.count)
    )
    #expect(await mainWindowWaitUntil(contextModel.candidateCount >= 1))
    try await Task.sleep(for: .milliseconds(150))
    content.layoutSubtreeIfNeeded()
    #expect(controller.selfTestProvenance?.contains("·") == true)
    let fuzzyFrame = window.frame


    let longEnvironment = ExactAnalysisEnvironment(
        trustMode: .safe,
        limitations: [
            .buildScriptsDisabled, .procMacrosDisabled, .dependenciesUnavailableOffline,
        ]
    )
    let longAttribution = ExactAttribution(
        provider: "extremely-long-provider-name-for-window-widening-probe",
        toolVersion: "999.999.99999999+longbuildmetadata.abcdefghijk",
        configFingerprint: "config",
        environmentFingerprint: "environment",
        featureSelection: .defaultFeatures,
        environment: longEnvironment,
        generatedAt: Date(timeIntervalSince1970: 0)
    )
    let definitionOffset = UInt32(
        source[..<source.range(of: "target")!.lowerBound].utf8.count
    )
    gate.complete(with: ExactOverlay.Entry(
        location: ExactLocation(
            file: root.appendingPathComponent("main.rs").path,
            byteOffset: Int(definitionOffset),
            line: 1,
            column: Int(definitionOffset) + 1
        ),
        attribution: longAttribution,
        origin: .worktree
    ))
    #expect(
        await mainWindowWaitUntil(
            contextModel.selectedCandidate?.certainty == .exact
        )
    )
    try await Task.sleep(for: .milliseconds(150))
    content.layoutSubtreeIfNeeded()
    // The badge line stays short and the window keeps its frame; the full
    // provenance remains reachable through the tooltip and AX value.
    let badge = controller.selfTestProvenance ?? ""
    #expect(badge.count <= 40, "header badge must stay short, got: \(badge)")
    #expect(
        controller.selfTestProvenanceTooltip?.contains(
            "extremely-long-provider-name"
        ) == true,
        "full provenance must remain available via tooltip/AX"
    )
    #expect(
        abs(window.frame.width - frameBefore.width) < 0.5
            && abs(window.frame.height - frameBefore.height) < 0.5,
        "publishing long provenance must not move the window frame"
    )
    #expect(
        content.fittingSize.width <= 900.5,
        "content must fit within the fixed width, got \(content.fittingSize.width)"
    )
    _ = fuzzyFrame
}

@MainActor
@Test
func toolbarKeepsSymbolsVisibleAheadOfSecondaryChrome() {
    let controller = MainWindowController(
        model: AppModel(),
        settings: ReaderSettings(),
        offscreen: true
    )
    defer { controller.close() }
    controller.showWindow(nil)
    guard let toolbar = controller.window?.toolbar else {
        Issue.record("window has no toolbar")
        return
    }
    let symbols = toolbar.items.first {
        $0.itemIdentifier.rawValue.contains("Symbols")
    }
    #expect(symbols?.visibilityPriority == .high, "Symbols must outrank secondary chrome")
    let project = toolbar.items.first { $0.itemIdentifier.rawValue.contains("Project") }
    let commit = toolbar.items.first { $0.itemIdentifier.rawValue.contains("Commit") }
    #expect(project?.visibilityPriority == .low, "project name compresses first")
    #expect(commit?.visibilityPriority == .low, "version compresses first")
    // The profile item appears only with an active analysis profile; when
    // present it must sit below Symbols.
    if let profile = toolbar.items.first(where: {
        $0.itemIdentifier.rawValue.contains("Profile")
    }) {
        #expect(profile.visibilityPriority == .standard)
    }
}
