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
func bookmarkCommandReportsTheEligibilityReasonOutsideThePrimaryReader() async throws {
    _ = NSApplication.shared
    let sourceA = "// 中文😀\nfn first() { let needle = 1; }\nfn second() { let needle = 2; }\n"
    let sourceB = "// another file with a different prefix\nfn remote() { let beacon = 1; beacon; }\n"
    let root = try mainWindowTemporaryGitProject(["a.rs": sourceA, "b.rs": sourceB])
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(sessionURL: root.appendingPathComponent("state/session.json"))
    let controller = MainWindowController(model: model, settings: ReaderSettings(), offscreen: true)
    defer { controller.close() }
    #expect(!controller.canToggleBookmark)
    #expect(controller.bookmarkCommandAccessibilityHelp
        == "Bookmarks require a current project file in the primary reader.")
    controller.openProject(root: root)
    try #require(await mainWindowWaitUntil(model.snapshotPhase == .fullReady))
    let fileA = root.appendingPathComponent("a.rs").standardizedFileURL
    let fileB = root.appendingPathComponent("b.rs").standardizedFileURL
    controller.openFileInNewTabForSelfTest(fileA)
    try #require(await mainWindowWaitUntil(controller.selfTestLeftReaderBytes == Array(sourceA.utf8)))
    controller.showWindow(nil)
    let window = try #require(controller.window)
    func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
    let content = try #require(window.contentView)
    let views = descendants(content)
    let reader = try #require(views.compactMap { $0 as? NSTextView }.first {
        !$0.isFieldEditor && $0.string == sourceA
    })
    func key(_ code: UInt16, _ characters: String, in target: NSTextView) throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
        ))
        target.keyDown(with: event)
    }
    func findByKeyboard(_ query: String, in source: String) async throws -> UInt32 {
        let generation = model.navigationGeneration
        let history = model.navigationHistory.records.count
        let trailNodes = model.readingTrail.nodes.count
        let trailEdges = model.readingTrail.edges.count
        #expect(controller.showFindBar())
        window.contentView?.layoutSubtreeIfNeeded()
        let field = try #require(descendants(content)
            .compactMap { $0 as? NSSearchField }.first {
                $0.accessibilityLabel() == "Find in file"
            })
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText(query, replacementRange: editor.selectedRange())
        let first = (source as NSString).range(of: query)
        try #require(await mainWindowWaitUntil(reader.selectedRange() == first))
        try key(36, "\r", in: editor)
        let last = (source as NSString).range(of: query, options: .backwards)
        try #require(await mainWindowWaitUntil(reader.selectedRange() == last))
        try key(53, "\u{1b}", in: editor)
        #expect(field.isHiddenOrHasHiddenAncestor)
        #expect(window.firstResponder === reader)
        #expect(model.navigationGeneration == generation)
        #expect(model.navigationHistory.records.count == history)
        #expect(model.readingTrail.nodes.count == trailNodes)
        #expect(model.readingTrail.edges.count == trailEdges)
        let start = try #require(source.range(of: query, options: .backwards)?.lowerBound)
        return UInt32(source[..<start].utf8.count)
    }
    func capture(at offset: UInt32, file: URL, source: String) throws {
        #expect(controller.canToggleBookmark)
        let bookmark = try #require(model.captureCurrentBookmark())
        #expect(bookmark.path == file.lastPathComponent)
        #expect(bookmark.byteOffset == offset)
        #expect(bookmark.contentID == ContentID.sha256(of: Array(source.utf8)))
        #expect(bookmark.snapshot == .worktree)
        #expect(model.tabStrip.activeTab?.selectionByteOffset == offset)
    }

    #expect(model.selectedByteOffset == nil)
    let foundA = try await findByKeyboard("needle", in: sourceA)
    try capture(at: foundA, file: fileA, source: sourceA)
    controller.toggleBookmark()
    #expect(model.bookmarkModel.records.contains { $0.path == "a.rs" && $0.byteOffset == foundA })

    let oldNavigationOffset = UInt32(sourceA[..<sourceA.range(of: "first")!.lowerBound].utf8.count)
    controller.selfTestNavigate(to: fileA, byteOffset: oldNavigationOffset)
    let selectedA = try await findByKeyboard("needle", in: sourceA)
    #expect(model.selectedByteOffset == oldNavigationOffset)
    try capture(at: selectedA, file: fileA, source: sourceA)
    let generation = model.navigationGeneration
    let history = model.navigationHistory.records.count
    let trailNodes = model.readingTrail.nodes.count
    let trailEdges = model.readingTrail.edges.count
    try key(124, "\u{f703}", in: reader)
    let caretA = selectedA + UInt32("needle".utf8.count)
    #expect(reader.selectedRange() == NSRange(
        location: (sourceA as NSString).range(of: "needle", options: .backwards).upperBound,
        length: 0
    ))
    try capture(at: caretA, file: fileA, source: sourceA)
    #expect(model.navigationGeneration == generation)
    #expect(model.navigationHistory.records.count == history)
    #expect(model.readingTrail.nodes.count == trailNodes)
    #expect(model.readingTrail.edges.count == trailEdges)

    controller.openFileInNewTabForSelfTest(fileB)
    try #require(await mainWindowWaitUntil(reader.string == sourceB))
    let caretB = try await findByKeyboard("beacon", in: sourceB)
    try capture(at: caretB, file: fileB, source: sourceB)
    for (file, source, offset, move) in [
        (fileA, sourceA, caretA, { controller.selectPreviousTab() }),
        (fileB, sourceB, caretB, { controller.selectNextTab() }),
    ] {
        move()
        try #require(await mainWindowWaitUntil(
            controller.displayedReaderFile == file && reader.string == source
        ))
        let nativeOffset = try #require(model.tabStrip.activeDocument?.byteUTF16Map.utf16Offset(
            forByte: Int(offset)
        ))
        try #require(await mainWindowWaitUntil(reader.selectedRange().location == nativeOffset))
        try capture(at: offset, file: file, source: source)
        #expect(model.tabStrip.activeTab?.selectionAnchor?.byteOffset == offset)
    }
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
func bookmarkPanelSelfTestActionsTargetRowsByUUIDAndExposeTheirStatus() async throws {
    _ = NSApplication.shared
    let path = String(repeating: "long-directory/", count: 18) + "main.rs"
    let root = try mainWindowTemporaryGitProject([path: "fn main() {}\n"])
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel()
    try await model.openProject(root: root, languages: [.rust])
    try #require(await mainWindowWaitUntil(
        model.snapshotPhase == .fullReady && model.querySessions.count == 1
    ))
    let record = BookmarkRecord(
        id: UUID(), projectPath: root.path, snapshot: .commit(fullOID: String(repeating: "a", count: 40)),
        path: path,
        contentID: ContentID.sha256(of: Data("old\n".utf8)),
        byteOffset: 0, line: 1, symbolName: nil, symbolKind: nil,
        note: String(repeating: "A long note with multiple lines\n", count: 8), updatedAt: .now
    )
    #expect(model.bookmarkModel.toggle(record) == .added)
    let drifted = BookmarkRecord(
        id: UUID(), projectPath: root.path, snapshot: .worktree,
        path: path, contentID: record.contentID, byteOffset: 0, line: 1,
        symbolName: nil, symbolKind: nil, note: record.note,
        updatedAt: Date(timeIntervalSince1970: 1)
    )
    #expect(model.bookmarkModel.toggle(drifted) == .added)
    #expect(model.bookmarkStatus(for: drifted) == .drifted)
    var opened: UUID?
    var openedLine: UUID?
    let panel = BookmarkPanel(
        appModel: model,
        onOpen: { opened = $0.id },
        onLineOpen: { record, _ in openedLine = record.id }
    )
    defer { panel.closePanel() }
    panel.show(relativeTo: nil)

    func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }
    let content = panel.window!.contentView!
    let views = descendants(of: content)
    let table = views.compactMap { $0 as? NSTableView }.first!
    let note = try #require(views.compactMap { $0 as? NSTextView }.first {
        $0.accessibilityLabel() == "Bookmark note"
    })
    #expect(!note.isEditable)
    #expect(panel.selfTestSelectFirstRow())
    #expect(note.isEditable)
    #expect(note.string == record.note)

    for row in 0..<2 {
        let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true)!
        let labels = descendants(of: cell).compactMap { $0 as? NSTextField }
        let buttons = descendants(of: cell).compactMap { $0 as? NSButton }
        #expect(buttons.count == (row == 0 ? 2 : 4))
        #expect(labels.contains { $0.toolTip?.contains(record.path) == true })
        #expect(labels.contains { $0.toolTip == record.note })
    }
    panel.selfTestSetFilter("no-bookmark-match")
    #expect(!note.isEditable)
    #expect(views.compactMap { $0 as? NSTextField }.contains {
        !$0.isHidden && $0.stringValue.hasPrefix("No bookmarks found")
    })
    panel.selfTestSetFilter("")

    #expect(panel.selfTestRowToolTip(id: record.id) == "Not evaluated")
    #expect(panel.selfTestPressOpen(id: record.id))
    #expect(opened == record.id)
    #expect(openedLine == nil)
}

@MainActor
@Test
func commitPickerMarksOnlyCompletelyMaterializedCommits() async throws {
    _ = NSApplication.shared
    let root = try mainWindowTemporaryGitProject(["src/main.rs": "fn main() {}\n"])
    defer { try? FileManager.default.removeItem(at: root) }
    func git(_ arguments: String...) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path, "-c", "user.name=T", "-c", "user.email=t@t"] + arguments
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    _ = try git("add", "-A")
    _ = try git("commit", "-q", "-m", "first")
    let first = try git("rev-parse", "HEAD")
    try "fn main() { }\n".write(to: root.appendingPathComponent("src/main.rs"), atomically: true, encoding: .utf8)
    _ = try git("commit", "-q", "-am", "second")
    let second = try git("rev-parse", "HEAD")

    // `first` is complete; `second` only has a staging directory without the marker.
    let cache = root.appendingPathComponent(".cache-materialized", isDirectory: true)
    let complete = cache.appendingPathComponent(first).appendingPathComponent("config")
    try FileManager.default.createDirectory(at: complete, withIntermediateDirectories: true)
    try Data().write(to: complete.appendingPathComponent(".complete"))
    try FileManager.default.createDirectory(
        at: cache.appendingPathComponent(second).appendingPathComponent("config"),
        withIntermediateDirectories: true
    )

    let model = AppModel(exactCoordinator: ExactCoordinator(materializer: Materializer(rootURL: cache)))
    model.commitPicker.load(repositoryURL: root)
    try #require(await mainWindowWaitUntil(model.commitPicker.commits.count == 2))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.orderFront(nil)
    let picker = CommitPickerPopover(appModel: model, selectedRevision: { nil }, onChoose: { _ in })
    picker.show(relativeTo: window.contentView!)

    let materialized = CodeInsightApp.localized("panel.commit.materialized")
    #expect(picker.selfTestVisibleBadges(forCommit: first).contains(materialized))
    #expect(!picker.selfTestVisibleBadges(forCommit: second).contains(materialized))
    #expect(picker.selfTestMaterializedNote?.contains("2 GB") == true)
    model.commitPicker.setQuery(String(second.prefix(12)))
    #expect(await mainWindowWaitUntil(picker.selfTestMaterializedNote == nil))

    // Let the popover finish closing before its anchor window goes away.
    picker.selfTestClose()
    _ = await mainWindowWaitUntil(!picker.selfTestGeometry.shown)
    window.close()
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

/// Offscreen captures have no window background behind the reader; the
/// path bar must paint its own chrome so its text stays readable there.

@MainActor
private func mainWindowCapturePNG(_ view: NSView, at url: URL) throws {
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    else { throw CocoaError(.fileWriteUnknown) }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:])
    else { throw CocoaError(.fileWriteUnknown) }
    try data.write(to: url)
}

@MainActor
@Test
func recentOpenWithSavedSnapshotRestoresTabsInsteadOfOpeningFresh() async throws {
    _ = NSApplication.shared
    let root = try mainWindowTemporaryProject([
        "main.rs": "fn main() {}\n",
        "other.rs": "fn other() {}\n",
    ])
    let stateRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "MainWindowRecentRestore-\(UUID().uuidString)",
            isDirectory: true
        )
    let suiteName = "MainWindowRecentRestore-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: stateRoot)
        defaults.removePersistentDomain(forName: suiteName)
    }
    let store = RecentProjectsStore(defaults: defaults)
    let model = AppModel(
        sessionURL: stateRoot.appendingPathComponent("session.json"),
        recentProjectsStore: store,
        indexService: MainWindowWorkingIndexService()
    )
    // §7.3: the model reports checkpoint writes; the app layer owns the
    // launch pointer. Tests wire the same rule the AppDelegate applies.
    model.onSessionCheckpointWritten = { store.lastSessionProjectPath = $0 }
    let controller = MainWindowController(
        model: model,
        settings: ReaderSettings(),
        offscreen: true,
        recentProjectsStore: store,
        recordsRecentProjects: true
    )
    defer { controller.close() }

    // Open, build up a tab strip, and save the reading session.
    controller.openProject(root: root, language: .rust)
    try #require(await mainWindowWaitUntil(model.snapshotPhase == .fullReady))
    controller.openFileInNewTabForSelfTest(root.appendingPathComponent("main.rs"))
    controller.openFileInNewTabForSelfTest(root.appendingPathComponent("other.rs"))
    try #require(await mainWindowWaitUntil(model.tabStrip.tabs.count == 2))
    controller.checkpointSessionSynchronously()
    try #require(store.lastSessionProjectPath == root.path)

    // Reopening the project with a saved snapshot restores the tabs
    // instead of opening a fresh empty workspace.
    controller.openRecentProject(root, forcingReopen: true)
    try #require(await mainWindowWaitUntil(
        model.snapshotPhase == .fullReady
            && model.tabStrip.tabs.count == 2
    ))
    #expect(model.tabStrip.tabs.compactMap(\.fileURL?.lastPathComponent)
        .sorted() == ["main.rs", "other.rs"])
}

@MainActor
@Test
func reopeningTheProjectBeingReadFocusesWithoutResetting() async throws {
    _ = NSApplication.shared
    let root = try mainWindowTemporaryProject([
        "main.rs": "fn main() {}\n",
        "other.rs": "fn other() {}\n",
    ])
    let stateRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "MainWindowSameProjectFocus-\(UUID().uuidString)",
            isDirectory: true
        )
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: stateRoot)
    }
    let model = AppModel(
        sessionURL: stateRoot.appendingPathComponent("session.json"),
        indexService: MainWindowWorkingIndexService()
    )
    let controller = MainWindowController(
        model: model,
        settings: ReaderSettings(),
        offscreen: true,
        recentProjectsStore: RecentProjectsStore(defaults: UserDefaults(
            suiteName: "MainWindowSameProjectFocus-\(UUID().uuidString)"
        )!),
        recordsRecentProjects: false
    )
    defer { controller.close() }

    controller.openProject(root: root, language: .rust)
    try #require(await mainWindowWaitUntil(model.snapshotPhase == .fullReady))
    controller.openFileInNewTabForSelfTest(root.appendingPathComponent("main.rs"))
    controller.openFileInNewTabForSelfTest(root.appendingPathComponent("other.rs"))
    try #require(await mainWindowWaitUntil(model.tabStrip.tabs.count == 2))
    let generationBefore = model.generation

    // Re-selecting the project that is already being read neither resets
    // the workspace nor disturbs the tab strip.
    controller.openRecentProject(root)
    #expect(model.generation == generationBefore)
    #expect(model.tabStrip.tabs.count == 2)
}

private struct MainWindowWorkingIndexService: IndexService {
    func index(root: URL, language: LanguageID) async throws -> EngineSession {
        try await Task.detached {
            try ProjectIndexer().index(root: root, language: language)
        }.value
    }
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
func lensListsEveryCandidateBesideTheExcerptAndClickingSelectsIt() async throws {
    _ = NSApplication.shared
    let main = "mod a;\nmod b;\nfn main() { target(); }\n"
    let root = try mainWindowTemporaryProject([
        "main.rs": main,
        "a.rs": "pub fn target() -> i32 { 1 }\n",
        "b.rs": "pub fn target() -> i32 { 2 }\n",
        "one.rs": "pub fn only() {}\nfn call() { only(); }\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try ProjectIndexer().index(root: root)
    let context = QueryContext(
        snapshotID: session.snapshotID,
        analysisProfileID: session.analysisProfile.id,
        generation: 1
    )
    let contextModel = ContextWindowModel { session, file, offset, context in
        try session.resolve(file: file, offset: offset, context: context)
    }
    contextModel.updateProjectState(.ready(session, context), root: root)
    let controller = ContextWindowViewController(model: contextModel)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 300),
        styleMask: [.titled], backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentView = controller.view

    contextModel.tokenClicked(
        file: "main.rs",
        offset: UInt32(main[..<main.range(of: "target();")!.lowerBound].utf8.count)
    )
    #expect(await mainWindowWaitUntil(contextModel.candidateCount >= 2))
    try await Task.sleep(for: .milliseconds(100))
    let list = controller.selfTestCandidateList
    #expect(list.visible)
    #expect(list.rows.count == contextModel.candidateCount)
    #expect(list.rows.contains { $0.hasPrefix("target") && $0.contains("a.rs:1") })
    #expect(list.rows.contains { $0.hasPrefix("target") && $0.contains("b.rs:1") })
    #expect(list.selected == contextModel.selectedIndex)
    #expect(list.excerptLeading >= 240)
    // The selected row uses the theme's selection color, not the system accent.
    #expect(controller.selfTestCandidateSelectionColor?.usingColorSpace(.sRGB)
        == ReaderTheme(settings: ReaderSettings()).chromeSelectionColor.usingColorSpace(.sRGB))

    let other = (contextModel.selectedIndex ?? 0) == 0 ? 1 : 0
    controller.selfTestClickCandidate(other)
    #expect(contextModel.selectedIndex == other)
    #expect(await mainWindowWaitUntil(controller.selfTestCandidateList.selected == other))

    let one = "pub fn only() {}\nfn call() { only(); }\n"
    contextModel.tokenClicked(
        file: "one.rs",
        offset: UInt32(one[..<one.range(of: "only();")!.lowerBound].utf8.count)
    )
    #expect(await mainWindowWaitUntil(
        contextModel.candidateCount == 1 && !controller.selfTestCandidateList.visible
    ))
    #expect(controller.selfTestCandidateList.excerptLeading == 0)
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
            contextModel.displayedCandidate?.certainty == .exact
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

/// R5.1: switching the lens to the enclosing mode — from its control or
/// the menu command — shows the scope at the current caret at once,
/// without waiting for another caret move.
@MainActor
@Test
func lensSwitchToEnclosingShowsTheCurrentCaretsScope() async throws {
    _ = NSApplication.shared
    let source = "pub fn target() {}\npub fn main() {\n    target();\n}\n"
    let root = try mainWindowTemporaryProject(["src/main.rs": source])
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(indexService: ProjectIndexService())
    let controller = MainWindowController(
        model: model,
        settings: ReaderSettings(),
        offscreen: true
    )
    defer { controller.close() }
    controller.openProject(root: root)
    #expect(await mainWindowWaitUntil(model.snapshotPhase == .fullReady))
    controller.showWindow(nil)
    let main = root.appendingPathComponent("src/main.rs")
    controller.openFileForSelfTest(main)
    #expect(await mainWindowWaitUntil(
        controller.displayedReaderFile?.standardizedFileURL == main.standardizedFileURL
    ))

    let insideMain = UInt32(source.utf8.count - "target();\n}\n".utf8.count)
    controller.selfTestFollowCaret(offset: insideMain)
    #expect(await mainWindowWaitUntil(model.contextWindow.displayedCandidate != nil))

    controller.selfTestChooseLensTracking(.enclosing)
    #expect(model.contextWindow.activeEnclosingScope?.name == "main")

    controller.selfTestChooseLensTracking(.symbol)
    #expect(await mainWindowWaitUntil(model.contextWindow.displayedCandidate != nil))

    // The menu command path replays the caret too.
    controller.setLensTracking(.enclosing)
    #expect(model.contextWindow.activeEnclosingScope?.name == "main")
}

@MainActor
@Test
func nonSourceSurfacesRetireSourcePanelsAndRestoreThemOnReturn() async throws {
    _ = NSApplication.shared
    let root = try mainWindowTemporaryProject([
        "src/main.rs": "pub fn target() {}\npub fn main() { target(); }\n",
        "README.md": "# Notes\n\n- one\n- two\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(indexService: ProjectIndexService())
    let controller = MainWindowController(
        model: model,
        settings: ReaderSettings(),
        offscreen: true
    )
    defer { controller.close() }
    controller.openProject(root: root)
    #expect(await mainWindowWaitUntil(model.snapshotPhase == .fullReady))
    controller.showWindow(nil)
    controller.renderForSelfTest()

    let main = root.appendingPathComponent("src/main.rs")
    let readme = root.appendingPathComponent("README.md")
    controller.applyPanelPreset(.relations)
    controller.openFileForSelfTest(main)
    #expect(await mainWindowWaitUntil(
        controller.displayedReaderFile?.standardizedFileURL
            == main.standardizedFileURL
    ))
    controller.renderForSelfTest()
    #expect(!controller.selfTestRelationsPaneCollapsed)
    #expect(controller.selfTestContextPaneCollapsed, "No empty definition pane before a symbol is followed")
    #expect(!controller.selfTestOutlineHidden)
    // Pin the Context preview on the definition before leaving the source.
    let targetOffset = UInt32(
        "pub fn ".utf8.count
    )
    model.contextWindow.tokenClicked(
        file: "src/main.rs",
        offset: targetOffset
    )
    #expect(await mainWindowWaitUntil(
        model.contextWindow.displayedCandidate != nil
    ))
    model.contextWindow.setMode(.pinned)

    // Non-source surface: file tree stays, source panels retire.
    controller.openFileForSelfTest(readme)
    #expect(await mainWindowWaitUntil(
        controller.displayedReaderFile?.standardizedFileURL
            == readme.standardizedFileURL
    ))
    controller.renderForSelfTest()
    #expect(!controller.selfTestSidebarPaneCollapsed, "file tree stays")
    #expect(controller.selfTestOutlineHidden)
    #expect(controller.selfTestContextPaneCollapsed)
    #expect(controller.selfTestRelationsPaneCollapsed)
    #expect(model.contextWindow.mode == .pinned, "pin survives the detour")

    // Back on source: the user's relations layout and outline return.
    controller.openFileForSelfTest(main)
    #expect(await mainWindowWaitUntil(
        controller.displayedReaderFile?.standardizedFileURL
            == main.standardizedFileURL
    ))
    controller.renderForSelfTest()
    #expect(!controller.selfTestRelationsPaneCollapsed)
    #expect(!controller.selfTestContextPaneCollapsed)
    #expect(!controller.selfTestOutlineHidden)
    #expect(model.contextWindow.mode == .pinned)
    #expect(controller.selfTestTrailBarVisible == !model.readingTrail.nodes.isEmpty)
}

@MainActor
@Test
func contextCandidateChangesPreserveTheReadersVisibleSourceAnchor() async throws {
    _ = NSApplication.shared
    let repeatedLine = "    target(); // " + String(repeating: "wrapping description ", count: 12) + "\n"
    let prefix = "pub fn target() {}\npub fn main() {\n"
        + String(repeating: repeatedLine, count: 150)
    let source = prefix + "    target(); // anchor\n    \n"
        + String(repeating: repeatedLine, count: 250) + "}\n"
    let target = prefix.utf16.count + 4
    let empty = prefix.utf16.count + "    target(); // anchor\n".utf16.count + 2
    let root = try mainWindowTemporaryProject(["main.rs": source])
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "ContextViewportTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(indexService: ProjectIndexService())
    var settings = ReaderSettings()
    settings.wrapLines = true
    let controller = MainWindowController(
        model: model, settings: settings, offscreen: true,
        recentProjectsStore: RecentProjectsStore(defaults: defaults),
        recordsRecentProjects: false
    )
    defer { controller.close() }
    controller.openProject(root: root)
    try #require(await mainWindowWaitUntil(model.snapshotPhase == .fullReady))
    controller.openFileForSelfTest(root.appendingPathComponent("main.rs"))
    try #require(await mainWindowWaitUntil(controller.selfTestLeftReaderBytes == Array(source.utf8)))
    controller.showWindow(nil)
    let window = try #require(controller.window)
    window.setContentSize(NSSize(width: 1200, height: 850))
    controller.renderForSelfTest()
    func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
    let content = try #require(window.contentView)
    let reader = try #require(descendants(content).compactMap { $0 as? NSTextView }.first {
        !$0.isFieldEditor && $0.string == source
    })
    let scroll = try #require(reader.enclosingScrollView)
    func settle() async throws {
        for _ in 0..<12 {
            try await Task.sleep(for: .milliseconds(20))
            content.layoutSubtreeIfNeeded()
            reader.textLayoutManager?.textViewportLayoutController.layoutViewport()
        }
    }
    func sourceRect(_ location: Int) -> NSRect {
        let screen = reader.firstRect(forCharacterRange: NSRange(location: location, length: 1), actualRange: nil)
        return reader.convert(window.convertFromScreen(screen), from: nil)
    }
    try await settle()
    await controller.selfTestWaitForIdentifierPreparation()
    try #require(controller.selfTestContextPaneCollapsed)
    let firstTarget = "pub fn ".utf16.count
    let lastTarget = (source as NSString).range(of: "target();", options: .backwards).location
    for destination in [lastTarget, firstTarget, target, target - repeatedLine.utf16.count, lastTarget, target] {
        controller.selfTestNavigate(
            to: root.appendingPathComponent("main.rs"), byteOffset: UInt32(destination)
        )
        try await settle()
        #expect(controller.selfTestPrimarySelectionRange?.length == "target".utf16.count)
        #expect(scroll.contentView.bounds.contains(sourceRect(destination)),
                "App navigation must leave destination \(destination) visible after primary selection activation")
        let centeredY = min(max(-scroll.contentView.contentInsets.top,
            sourceRect(destination).midY - scroll.contentView.bounds.height / 2),
            max(0, reader.frame.height - scroll.contentView.bounds.height + scroll.contentView.contentInsets.bottom))
        #expect(abs(scroll.contentView.bounds.minY - centeredY) <= 2,
                "Navigation must center destination \(destination), clamped at the document edges")
    }
    reader.scrollRangeToVisible(NSRange(location: target, length: 6))
    try await settle()
    scroll.contentView.scroll(to: NSPoint(
        x: scroll.contentView.bounds.minX, y: sourceRect(target).minY - 90
    ))
    scroll.reflectScrolledClipView(scroll.contentView)
    try await settle()
    // Context opens in a side zone: the first opening narrows the reader and
    // its width reflow (the reader's own rule) re-places the text. After
    // that, candidate changes must not move the source at all.
    var anchorY: CGFloat?
    let expandedWidth = scroll.contentView.bounds.width
    let generation = model.navigationGeneration
    try #require(scroll.contentView.bounds.contains(sourceRect(target)))
    // Drive activation, caret/selection callbacks and Context lookup through
    // the window controller.
    window.makeFirstResponder(reader)
    for hasCandidate in [true, false, true, false] {
        let clicked = hasCandidate ? target : empty
        _ = controller.selfTestActivateReading(at: UInt32(clicked))
        controller.selfTestReaderClick(offset: UInt32(clicked), commandClick: false)
        try #require(await mainWindowWaitUntil(
            model.contextWindow.candidateCount > 0
        ))
        try await settle()
        // R4.3 (T4): a click on no symbol KEEPS the previous lens content —
        // the pane stays open and the open-pane reader width persists; the
        // pre-T4 contract cleared the pane on empty clicks.
        #expect(controller.selfTestContextPaneCollapsed == false)
        #expect(model.navigationGeneration == generation)
        if hasCandidate {
            #expect(scroll.contentView.bounds.width < expandedWidth - 50,
                    "Opening Context must actually exercise a Reader width change")
        } else {
            #expect(scroll.contentView.bounds.width < expandedWidth - 50,
                    "Keeping Context on an empty click must keep the reader width")
        }
        let actualY = sourceRect(target).minY - scroll.contentView.bounds.minY
        if let anchorY {
            #expect(abs(actualY - anchorY) <= 2,
                    "Context candidate=\(hasCandidate), source anchor moved from \(anchorY) to \(actualY), clip=\(scroll.contentView.bounds)")
        }
        anchorY = anchorY ?? actualY
        #expect(scroll.contentView.bounds.contains(sourceRect(clicked)),
                "Changing Context must keep the clicked source character visible")
    }
}

@MainActor
@Test
func languagePreselectionMatchesContentAndStoredPreference() throws {
    var roots: [URL] = []
    defer {
        for root in roots { try? FileManager.default.removeItem(at: root) }
    }
    func makeProject(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodeInsightPreselect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
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

    let rust = try makeProject(["src/lib.rs": "fn a() {}\n"])
    roots.append(rust)
    #expect(
        AppDelegate.preselectedLanguages(for: rust, storedLanguage: nil)
            .languages == [.rust]
    )
    let python = try makeProject(["app/main.py": "def f():\n    pass\n"])
    roots.append(python)
    #expect(
        AppDelegate.preselectedLanguages(for: python, storedLanguage: nil)
            .languages == [.python]
    )
    let tsx = try makeProject(["ui/row.tsx": "export const A = 1\n"])
    roots.append(tsx)
    #expect(
        AppDelegate.preselectedLanguages(for: tsx, storedLanguage: nil)
            .languages == [.typescript]
    )
    let mixed = try makeProject([
        "src/lib.rs": "fn a() {}\n",
        "app/main.py": "pass\n",
        "ui/row.tsx": "export const A = 1\n",
    ])
    roots.append(mixed)
    #expect(
        AppDelegate.preselectedLanguages(for: mixed, storedLanguage: nil)
            .languages == [.rust, .python, .typescript]
    )
    // Plain JS/JSX does not select TypeScript.
    let jsOnly = try makeProject(["app.js": "console.log(1)\n"])
    roots.append(jsOnly)
    #expect(
        AppDelegate.preselectedLanguages(for: jsOnly, storedLanguage: nil)
            .languages == []
    )
    // Skipped directories are not probed.
    let vendored = try makeProject([
        "node_modules/pkg/index.js": "x\n",
        "dist/bundle.js": "x\n",
    ])
    roots.append(vendored)
    #expect(
        AppDelegate.preselectedLanguages(for: vendored, storedLanguage: nil)
            .languages == []
    )
    // A stored preference wins over content, and the fallback never
    // masquerades as one.
    #expect(
        AppDelegate.preselectedLanguages(
            for: rust,
            storedLanguage: .python
        ).languages == [.python]
    )
    // Huge trees terminate deterministically.
    var many: [String: String] = [:]
    for index in 0..<6000 {
        many["deep/dir\(index)/file\(index).txt"] = "x"
    }
    let huge = try makeProject(many)
    roots.append(huge)
    let result = AppDelegate.preselectedLanguages(
        for: huge,
        storedLanguage: nil
    )
    #expect(result.probeCapped)
    #expect(result.languages.isEmpty)
}

@MainActor
@Test
func recentsRecordOnlyLookupNeverFallsBackToRust() {
    let store = RecentProjectsStore()
    let path = "/tmp/codeinsight-unrecorded-\(UUID().uuidString)"
    #expect(store.storedLanguagesIfRecorded(for: path) == nil)
    #expect(store.languages(for: path) == [.rust])
}

@MainActor
@Test
func productPolishRestoresUserPanelWidthsAcrossWindowRebuild() async throws {
    _ = NSApplication.shared
    let longPaths = (1...6).map { "modules/component_\($0)_with_a_long_readable_name.rs" }
    var files = [
        "main.rs": "pub fn main() {}\n", "README.md": "# Layout notes\n",
    ]
    for path in longPaths { files[path] = "pub fn component() {}\n" }
    let root = try mainWindowTemporaryProject(files)
    let suite = "CairnPanelLayoutTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
    func makeController() async throws -> MainWindowController {
        let model = AppModel(indexService: ProjectIndexService())
        let controller = MainWindowController(model: model, settings: ReaderSettings(), offscreen: true,
                                              layoutDefaults: defaults)
        controller.window?.setContentSize(NSSize(width: 1600, height: 900))
        controller.openProject(root: root)
        try #require(await mainWindowWaitUntil(model.snapshotPhase == .fullReady))
        controller.openFileForSelfTest(root.appendingPathComponent("main.rs"))
        controller.renderForSelfTest()
        return controller
    }
    let first = try await makeController()
    defer { first.close() }
    let window = try #require(first.window)
    first.showWindow(nil)
    func settleWindow() async {
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
    }
    await settleWindow()
    #expect(window.isVisible)
    for path in longPaths {
        first.model.openInNewTab(root.appendingPathComponent(path))
        first.renderForSelfTest()
    }
    first.model.openInNewTab(root.appendingPathComponent("main.rs"))
    first.renderForSelfTest()
    await settleWindow()
    #expect(first.model.tabStrip.tabs.count == 7)
    func findTabScroll(_ view: NSView) -> NSScrollView? {
        if view.accessibilityLabel() == "Open files" {
            return view.subviews.compactMap { $0 as? NSScrollView }.first
        }
        return view.subviews.lazy.compactMap(findTabScroll).first
    }
    let tabScroll = try #require(window.contentView.flatMap(findTabScroll))
    func expectActiveTabVisible() throws {
        let tabs = try #require(tabScroll.documentView as? NSStackView)
        let active = try #require(first.model.tabStrip.activeIndex)
        let row = try #require(tabs.arrangedSubviews[active] as? NSStackView)
        let visible = tabScroll.contentView.documentVisibleRect.insetBy(dx: -1, dy: -1)
        #expect(row.frame.height > 20)
        #expect(visible.contains(row.frame), "The whole active tab must fit inside the clip view")
        for button in row.arrangedSubviews {
            let frame = button.convert(button.bounds, to: tabs)
            #expect(visible.contains(frame), "Tab title and close button must not be clipped")
            if let scroller = tabScroll.horizontalScroller, !scroller.isHidden {
                #expect(!scroller.convert(scroller.bounds, to: tabs).intersects(frame),
                        "A horizontal scroller must not cover the tab's controls")
            }
        }
    }
    let beforeGrowth = first.selfTestUpperPaneWidths
    first.window?.setContentSize(NSSize(width: 2000, height: 900))
    first.renderForSelfTest()
    #expect(abs(first.selfTestUpperPaneWidths.sidebar - beforeGrowth.sidebar) <= 2,
            "The file sidebar must not absorb the window's extra width")
    #expect(first.selfTestUpperPaneWidths.reader >= beforeGrowth.reader + 380)
    for theme in [ReaderSettings.Theme.light, .dark] {
        first.applyReaderSettings(ReaderSettings(theme: theme))
        for style in [NSScroller.Style.legacy, .overlay] {
            tabScroll.scrollerStyle = style
            window.setContentSize(NSSize(width: 2000, height: 900))
            first.model.activateTab(6)
            first.renderForSelfTest()
            await settleWindow()
            try expectActiveTabVisible()
            for width in [900.0, 1280.0, 1600.0] {
                window.setContentSize(NSSize(width: width, height: 900))
                first.renderForSelfTest()
                await settleWindow()
                // Resizing must reveal the existing selection without a new activation.
                try expectActiveTabVisible()
                let geometry = first.selfTestTabGeometry
                #expect(abs(geometry.contentFrame.width - width) <= 1)
                #expect((tabScroll.documentView?.frame.width ?? 0) > tabScroll.contentSize.width,
                        "Long tabs overflow inside their scroll view, not the window")
                #expect(first.selfTestUpperPaneWidths.reader >= 480)
                #expect(!geometry.stripHidden && geometry.stripFrame.width > 0)
                #expect(geometry.headerFrame.insetBy(dx: -1, dy: -1).contains(geometry.stripFrame))
                #expect(geometry.headerFrame.insetBy(dx: -1, dy: -1).contains(geometry.controlFrame))
                #expect(!geometry.stripFrame.intersects(geometry.controlFrame))
                #expect(first.window?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
                    == (theme == .dark ? .darkAqua : .aqua))
                if width == 900 {
                    tabScroll.contentView.scroll(to: NSPoint(x: 100, y: tabScroll.contentView.bounds.origin.y))
                    tabScroll.reflectScrolledClipView(tabScroll.contentView)
                    let afterScroll = tabScroll.contentView.bounds.origin.x
                    #expect(abs(afterScroll - 100) <= 1, "The native clip view must support horizontal scrolling")
                    first.renderForSelfTest()
                    await settleWindow()
                    #expect(abs(tabScroll.contentView.bounds.origin.x - afterScroll) <= 1,
                            "Rendering at the same size must not snap horizontal scrolling back to the active tab")
                }
                for index in [0, 6] {
                    first.model.activateTab(index)
                    first.renderForSelfTest()
                    await settleWindow()
                    try expectActiveTabVisible()
                }
                print("POLISH_WINDOW_MATRIX theme=\(theme.rawValue) style=\(style.rawValue) width=\(width) reader=\(first.selfTestUpperPaneWidths.reader) sidebar=\(first.selfTestUpperPaneWidths.sidebar)")
            }
        }
    }
    first.applyReaderSettings(ReaderSettings())
    first.window?.setContentSize(NSSize(width: 1600, height: 900))
    first.renderForSelfTest()
    #expect(first.selfTestContextPaneCollapsed)
    first.toggleRelations()
    // Dragging the zone dividers records the widths the next window uses.
    let outer = first.selfTestOuterSplit
    outer.setPosition(250, ofDividerAt: 0)
    outer.layoutSubtreeIfNeeded()
    outer.setPosition(outer.bounds.width - 700 - outer.dividerThickness, ofDividerAt: 1)
    first.dividerDragEnded()
    first.renderForSelfTest()
    let width = first.selfTestRelationsPaneWidth
    #expect(width > 628, "A wide window must permit the inspector's side-by-side mode")
    first.toggleRelations()
    first.toggleRelations()
    #expect(abs(first.selfTestRelationsPaneWidth - width) <= 1, "Reopening keeps the dragged width")
    #expect(abs((first.selfTestZoneWidths[.left] ?? 0) - 250) <= 1)
    first.model.contextWindow.tokenClicked(file: "main.rs", offset: UInt32("pub fn ".utf8.count))
    try #require(await mainWindowWaitUntil(first.model.contextWindow.displayedCandidate != nil))
    first.model.contextWindow.setMode(.pinned)
    first.renderForSelfTest()
    window.center()
    window.zoom(nil)
    await settleWindow()
    #expect(!first.selfTestContextPaneCollapsed)
    let sourceFrame = window.frame
    func expectSourceWindowFrame(_ surface: String) async {
        await settleWindow()
        print("POLISH_SURFACE_FRAME surface=\(surface) before=\(sourceFrame.size) after=\(window.frame.size)")
        #expect(abs(window.frame.width - sourceFrame.width) <= 1,
                "\(surface) must keep the user's window width")
        #expect(abs(window.frame.height - sourceFrame.height) <= 1,
                "\(surface) must keep the user's window height")
    }
    let storedBeforeOverrides = defaults.data(forKey: "Cairn.panelLayout.v2")
    first.model.openReadingSet(title: "Saved path", excerpts: [])
    first.renderForSelfTest()
    await expectSourceWindowFrame("Reading Set")
    #expect(first.selfTestShownPanels.values.flatMap { $0 }.isEmpty, "A Reading Set hides every panel")
    first.checkpointSessionSynchronously()
    first.openFileForSelfTest(root.appendingPathComponent("README.md"))
    try #require(await mainWindowWaitUntil(first.displayedReaderFile?.lastPathComponent == "README.md"))
    first.renderForSelfTest()
    await expectSourceWindowFrame("README")
    #expect(!first.selfTestSidebarPaneCollapsed, "README keeps the file tree after a Reading Set")
    #expect(first.selfTestRelationsPaneCollapsed)
    first.checkpointSessionSynchronously()
    #expect(defaults.data(forKey: "Cairn.panelLayout.v2") == storedBeforeOverrides,
            "Temporary overrides are never written back")
    first.openFileForSelfTest(root.appendingPathComponent("main.rs"))
    try #require(await mainWindowWaitUntil(first.displayedReaderFile?.lastPathComponent == "main.rs"))
    await expectSourceWindowFrame("source restored")
    #expect(!first.selfTestContextPaneCollapsed)
    #expect(!first.selfTestRelationsPaneCollapsed)
    #expect(abs(first.selfTestRelationsPaneWidth - width) <= 1, "The override detour keeps the width")
    window.zoom(nil)
    await settleWindow()
    first.toggleContext(nil)
    #expect(first.selfTestContextPaneCollapsed, "Closed Context stays closed despite its content")
    first.checkpointSessionSynchronously()
    first.close()
    let saved = PanelLayout.decode(try #require(defaults.data(forKey: "Cairn.panelLayout.v2")))
    #expect(!saved.hidden.contains(.relations))
    #expect(saved.hidden.contains(.context))
    #expect(abs(saved.width(of: .left) - 250) <= 1)
    #expect(abs(saved.width(of: .right) - 700) <= 1)
    let second = try await makeController()
    defer { second.close() }
    #expect(!second.selfTestRelationsPaneCollapsed)
    #expect(abs((second.selfTestZoneWidths[.right] ?? 0) - 700) <= 1)
    #expect(second.selfTestContextPaneCollapsed)
    second.toggleContext(nil)
    #expect(!second.selfTestContextPaneCollapsed, "Opening Context shows it before it has content")
    second.toggleContext(nil)
    #expect(second.selfTestContextPaneCollapsed)
    // A narrow window squeezes the zones; it never grows and the squeeze
    // is not saved.
    second.window?.setContentSize(NSSize(width: 900, height: 600))
    second.renderForSelfTest()
    #expect(abs((second.window?.contentLayoutRect.width ?? 0) - 900) <= 1)
    #expect(second.selfTestReaderGroupWidth >= 320)
    second.checkpointSessionSynchronously()
    second.close()
    let third = try await makeController()
    defer { third.close() }
    #expect(abs((third.selfTestZoneWidths[.left] ?? 0) - 250) <= 1)
    #expect(abs((third.selfTestZoneWidths[.right] ?? 0) - 700) <= 1)
}

@MainActor
@Test
func productPolishOutlineUsesNativeHierarchyAndPreservesCollapsedBranches() throws {
    _ = NSApplication.shared
    let source = "pub struct Example { pub value: u32 }\nimpl Example { fn run(&self) {} }\n"
    let file = URL(fileURLWithPath: "/Example.rs")
    let document = try DocumentLoader(source: { _ in Array(source.utf8) }).load(file: file).document
    // The files and outline bodies are separate panels now; stack them in
    // a plain window to exercise the shared data source.
    func makeSidebar() -> (SidebarViewController, NSWindow) {
        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()
        let stack = NSStackView(views: [sidebar.filesController.view, sidebar.outlineController.view])
        stack.orientation = .vertical
        stack.distribution = .fillEqually
        let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: 300, height: 560),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = stack
        window.setContentSize(NSSize(width: 300, height: 560))
        window.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        return (sidebar, window)
    }
    let (sidebar, window) = makeSidebar()
    defer { window.close() }
    sidebar.setSelectedFile(file)
    sidebar.setOutline(document.outlineFacets.map(OutlineNode.init(facet:)), file: file)
    func outlines(_ view: NSView) -> [NSOutlineView] {
        (view as? NSOutlineView).map { [$0] } ?? view.subviews.flatMap(outlines)
    }
    let outline = try #require(outlines(sidebar.outlineController.view).first { $0.accessibilityLabel() == "Outline" })
    let row = try #require((0..<outline.numberOfRows).first { index in
        (outline.item(atRow: index) as? NSNumber)?.intValue == 0
    })
    let item = try #require(outline.item(atRow: row))
    #expect(outline.isExpandable(item))
    let expandedCount = outline.numberOfRows
    outline.collapseItem(item)
    #expect(outline.numberOfRows < expandedCount)
    sidebar.setOutline([], file: URL(fileURLWithPath: "/Other.rs"))
    sidebar.setOutline(document.outlineFacets.map(OutlineNode.init(facet:)), file: file)
    #expect(!outline.isItemExpanded(outline.item(atRow: 0)))
    var opened: UInt32?
    sidebar.onOpenOutline = { opened = $0 }
    outline.selectRowIndexes([0], byExtendingSelection: false)
    #expect(opened == document.outlineFacets[0].nameRange.lowerBound)
    opened = nil
    outline.sendAction(outline.action, to: outline.target)
    #expect(opened == document.outlineFacets[0].nameRange.lowerBound, "Clicking the already selected declaration still navigates")
    let cell = try #require(outline.view(atColumn: 0, row: 0, makeIfNecessary: true))
    #expect(cell.accessibilityLabel() == "Struct Example")
    #expect(cell.accessibilityChildren()?.isEmpty == true)

    let files = try #require(outlines(sidebar.filesController.view).first { $0.accessibilityLabel() == "Files" })
    let root = URL(fileURLWithPath: "/sidebar-tree")
    let firstFile = root.appendingPathComponent("src/deep/one.rs")
    let nextFile = root.appendingPathComponent("src/two.rs")
    var openedFiles: [URL] = []
    sidebar.onOpenFile = { openedFiles.append($0) }
    func tree() -> FileTreeModel {
        FileTreeModel(root: root, snapshotPaths: ["src/deep/one.rs", "src/two.rs", "README.md"])
    }
    sidebar.display(tree())
    #expect(sidebar.synchronizeFileSelection(to: firstFile))
    sidebar.display(tree())
    #expect(sidebar.selectedFile == firstFile)
    #expect(openedFiles.isEmpty, "Replacing FileTreeNode objects cannot open a file")
    let directory = try #require(files.item(atRow: 0) as? FileTreeNode)
    #expect(files.isItemExpanded(directory))
    files.collapseItem(directory)
    #expect(sidebar.synchronizeFileSelection(to: firstFile))
    #expect(!files.isItemExpanded(directory), "Background render preserves a user's collapsed folder")
    sidebar.display(tree())
    #expect(sidebar.synchronizeFileSelection(to: firstFile))
    #expect(!files.isItemExpanded(files.item(atRow: 0)))
    #expect(openedFiles.isEmpty)
    #expect(sidebar.synchronizeFileSelection(to: nextFile))
    #expect(files.isItemExpanded(files.item(atRow: 0)), "Changing files still reveals the new location")
}

/// K0a: reader click gestures resolve through the key binding table instead
/// of hardcoded modifier checks. Empty modifiers stay the plain click, and
/// modifier combinations no gesture is bound to do nothing.

// MARK: Native acceptance evidence — lens type follow and shortcut settings

/// Native acceptance for the lens type-follow work: the real window is
/// driven through its self-test hooks and drawn
/// through AppKit (`cacheDisplay`), so the evidence is rendered pixels, not
/// view-model booleans. With CAIRN_LENS_EVIDENCE_DIR set, each surface is also
/// written as a PNG for the acceptance record.
@MainActor
private func renderEvidence(_ name: String, view: NSView) throws {
    view.window?.contentView?.layoutSubtreeIfNeeded()
    let rect = view.bounds
    try #require(!rect.isEmpty)
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: rect))
    view.cacheDisplay(in: rect, to: bitmap)
    var colors = Set<[CGFloat]>()
    for y in stride(from: 0, to: bitmap.pixelsHigh, by: max(1, bitmap.pixelsHigh / 60)) {
        for x in stride(from: 0, to: bitmap.pixelsWide, by: max(1, bitmap.pixelsWide / 80)) {
            if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                colors.insert([color.redComponent, color.greenComponent, color.blueComponent])
            }
        }
    }
    if let directory = ProcessInfo.processInfo.environment["CAIRN_LENS_EVIDENCE_DIR"] {
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try png.write(to: output.appendingPathComponent(name + ".png"), options: .atomic)
    }
    // A blank (single-color) surface is not evidence of anything.
    try #require(colors.count > 8, "\(name) rendered \(colors.count) colors")
}

private let lensTypes = """
    /// A shared object header.
    pub struct Inner {
        pub id: u64,
    }

    /// A parsed record.
    pub struct Outer {
        pub count: u32,
        pub inner: Inner,
    }

    """

private let lensMain = """
    mod types;
    use types::{Inner, Outer};

    /// A parsed object header.
    pub struct S {
        pub n: u32,
    }

    impl S {
        /// Sums this header with a boxed copy.
        pub fn use_it(&self, ps: &S, o: &Outer) -> u32 {
            let local: Box<S> = Box::new(S { n: 1 });
            fn helper(x: u32) -> u32 {
                x + 1
            }
            self.n + ps.n + local.n + o.count + o.inner.id as u32 + helper(1)
        }
    }

    fn main() {}

    """

/// R1/R7/R5/R6 in the real window: the one-hop label for a parameter, a
/// cross-file field, the enclosing-function mode on a nested function, and
/// the pin.
@MainActor
@Test
func lensTypeFollowSurfacesRenderInTheNativeWindow() async throws {
    _ = NSApplication.shared
    let root = try mainWindowTemporaryProject([
        "src/main.rs": lensMain,
        "src/types.rs": lensTypes,
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(indexService: ProjectIndexService())
    let controller = MainWindowController(
        model: model,
        settings: ReaderSettings(),
        offscreen: true
    )
    defer { controller.close() }
    controller.openProject(root: root)
    #expect(await mainWindowWaitUntil(model.snapshotPhase == .fullReady))
    controller.showWindow(nil)
    let main = root.appendingPathComponent("src/main.rs")
    controller.openFileForSelfTest(main)
    #expect(await mainWindowWaitUntil(
        controller.displayedReaderFile?.standardizedFileURL == main.standardizedFileURL
    ))
    let content = try #require(controller.window?.contentView)
    func offset(of needle: String, plus delta: Int = 0) -> UInt32 {
        let range = lensMain.range(of: needle)!
        return UInt32(lensMain.utf8.distance(from: lensMain.startIndex, to: range.lowerBound) + delta)
    }

    // 1. `ps` in `ps.n`: the lens shows `ps: &S → S`.
    controller.selfTestReaderClick(offset: offset(of: "ps.n"), commandClick: false)
    #expect(await mainWindowWaitUntil(controller.selfTestTypeHop?.target == "S"))
    #expect(controller.selfTestTypeHop?.via == "ps: &S")
    #expect(controller.selfTestTypeHop?.showing == "type")
    controller.renderForSelfTest()
    #expect(!controller.selfTestContextPaneCollapsed)
    // The label must reach the screen, not just the model. The lens renders
    // on its own observation pass, so wait for it rather than racing it.
    #expect(await mainWindowWaitUntil(controller.selfTestRenderedTypeHop?.target == "S"))
    let rendered = try #require(controller.selfTestRenderedTypeHop)
    #expect(rendered.via == "ps: &S")
    #expect(rendered.target == "S")
    #expect(rendered.viaWidth > 20 && rendered.targetWidth > 5)
    controller.renderForSelfTest()
    try renderEvidence("01-lens-parameter-type-hop", view: content)

    // 2. `o.inner` — a field declared in types.rs hops to `Inner`.
    controller.selfTestReaderClick(offset: offset(of: "o.inner", plus: 2), commandClick: false)
    #expect(await mainWindowWaitUntil(controller.selfTestTypeHop?.target == "Inner"))
    #expect(controller.selfTestTypeHop?.via.hasPrefix("inner") == true)
    controller.renderForSelfTest()
    try renderEvidence("02-lens-cross-file-field", view: content)

    // 3. Enclosing mode on the nested `helper` shows `helper`, not `use_it`.
    controller.selfTestFollowCaret(offset: offset(of: "x + 1"))
    controller.selfTestChooseLensTracking(.enclosing)
    #expect(controller.selfTestContextEnclosingTitle?.contains("helper") == true)
    controller.renderForSelfTest()
    #expect(!controller.selfTestContextPaneCollapsed, "the enclosing mode must stay on screen")
    try renderEvidence("03-lens-enclosing-nested-function", view: content)

    // 4. The pin: amber header, the scope stays while the caret moves.
    controller.selfTestSetContextPinned(true)
    controller.selfTestFollowCaret(offset: offset(of: "fn main"))
    try await Task.sleep(for: .milliseconds(100))
    #expect(controller.selfTestContextPinned)
    #expect(controller.selfTestContextEnclosingTitle?.contains("helper") == true)
    controller.renderForSelfTest()
    try renderEvidence("04-lens-pinned", view: content)
}

@MainActor
@Test
func movedPanelsSurviveWindowRebuildAndPresetsOnlyChangeVisibility() async throws {
    _ = NSApplication.shared
    let root = try mainWindowTemporaryProject(["main.rs": "pub fn main() {}\n"])
    let suite = "CairnPanelMoveTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
    func makeController() async throws -> MainWindowController {
        let model = AppModel(indexService: ProjectIndexService())
        let controller = MainWindowController(model: model, settings: ReaderSettings(), offscreen: true,
                                              layoutDefaults: defaults)
        controller.window?.setContentSize(NSSize(width: 1600, height: 900))
        controller.openProject(root: root)
        try #require(await mainWindowWaitUntil(model.snapshotPhase == .fullReady))
        controller.openFileForSelfTest(root.appendingPathComponent("main.rs"))
        controller.renderForSelfTest()
        return controller
    }
    let first = try await makeController()
    // Default: files and outline on the left, the right zone collapsed.
    #expect(first.selfTestShownPanels[.left] == [.files, .outline])
    #expect(first.selfTestShownPanels[.right] == [])
    #expect(first.selfTestZoneWidths[.right] == 0)
    #expect(abs((first.selfTestZoneWidths[.left] ?? 0) - 240) <= 1)
    first.toggleRelations()
    #expect(first.selfTestShownPanels[.right] == [.relations])
    first.movePanel(.relations, to: .left)
    #expect(first.selfTestShownPanels[.left] == [.files, .outline, .relations])
    #expect(first.selfTestZoneWidths[.right] == 0, "An emptied zone collapses")
    #expect((first.selfTestZoneWidths[.left] ?? 0) >= 299, "Relations raises the zone to its 300pt minimum")
    first.dropPanel(.relations, in: .left, beforeShownIndex: 0)
    #expect(first.selfTestShownPanels[.left] == [.relations, .files, .outline])
    first.shiftPanel(.files, by: 1)
    #expect(first.selfTestShownPanels[.left] == [.relations, .outline, .files])
    let split = first.selfTestZoneSplit(.left)
    split.setPosition((split.bounds.height - 2 * split.dividerThickness) * 0.5, ofDividerAt: 0)
    first.dividerDragEnded()
    first.renderForSelfTest()
    let heights = first.selfTestPanelHeights
    first.close()

    let second = try await makeController()
    defer { second.close() }
    #expect(second.selfTestShownPanels[.left] == [.relations, .outline, .files])
    for (panel, height) in heights {
        #expect(abs((second.selfTestPanelHeights[panel] ?? 0) - height) <= 1, "\(panel) height survives")
    }
    let placement = second.panelLayout.zones
    for preset in PanelPresetModel.allCases {
        second.applyPanelPreset(preset)
        #expect(second.panelLayout.zones == placement, "\(preset) keeps placement")
        #expect(Set(PanelID.allCases).subtracting(second.panelLayout.hidden) == preset.visiblePanels)
    }
    #expect(second.selfTestShownPanels.values.flatMap { $0 }.isEmpty, "Focus hides every panel")
    second.applyPanelPreset(.relations)
    #expect(second.selfTestShownPanels[.left] == [.relations, .outline, .files])
    second.restoreDefaultPanelLayout()
    #expect(second.panelLayout == .standard)
    #expect(second.selfTestShownPanels[.left] == [.files, .outline])
    #expect(PanelLayout.decode(defaults.data(forKey: "Cairn.panelLayout.v2")) == .standard)
}

/// The docs panel's first explicit show un-hides it and keeps the 40% a
/// never-sized panel gets; after × the next explicit show brings it back.
@MainActor
@Test
func firstDocsPanelShowUnhidesItAndRecordsItsHeight() async throws {
    _ = NSApplication.shared
    let root = try mainWindowTemporaryProject(["main.rs": "pub fn main() {}\n"])
    let suite = "CairnDocsPanelTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
    let model = AppModel(indexService: ProjectIndexService())
    let controller = MainWindowController(model: model, settings: ReaderSettings(), offscreen: true,
                                          layoutDefaults: defaults)
    defer { controller.close() }
    controller.window?.setContentSize(NSSize(width: 1600, height: 900))
    controller.openProject(root: root)
    try #require(await mainWindowWaitUntil(model.snapshotPhase == .fullReady))
    controller.openFileForSelfTest(root.appendingPathComponent("main.rs"))
    controller.renderForSelfTest()
    #expect(controller.panelLayout.hidden.contains(.docs))
    #expect(controller.panelLayout.heights[.docs] == 0)
    controller.toggleRelations()
    controller.revealDocsPanel()
    #expect(controller.selfTestShownPanels[.right] == [.relations, .docs])
    let shown = controller.selfTestPanelHeights
    let share = (shown[.docs] ?? 0) / ((shown[.docs] ?? 0) + (shown[.relations] ?? 0))
    #expect(abs(share - 0.4) < 0.03, "First show gives docs 40% of its zone, got \(share)")
    let recorded = try #require(controller.panelLayout.heights[.docs])
    #expect(recorded > 0)
    let saved = PanelLayout.decode(defaults.data(forKey: "Cairn.panelLayout.v2"))
    #expect(!saved.hidden.contains(.docs))
    #expect(saved.heights[.docs] == recorded)
    controller.setPanelVisible(.docs, false)
    #expect(controller.selfTestShownPanels[.right] == [.relations])
    controller.revealDocsPanel()
    #expect(controller.selfTestShownPanels[.right] == [.relations, .docs])
    #expect(controller.panelLayout.heights[.docs] == recorded, "Only the first show records a height")
}

/// Layout passes after an ordinary click (a stale mouse-up as the current
/// event) must not be recorded as a divider drag. The dequeued event changes
/// process-wide AppKit state, so ci.sh runs this test in its own process.
@MainActor
@Test
func panelChangesAfterAClickDoNotRecordGeometry() async throws {
    _ = NSApplication.shared
    let root = try mainWindowTemporaryProject(["main.rs": "pub fn main() {}\n"])
    let suite = "CairnPanelClickTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
    let model = AppModel(indexService: ProjectIndexService())
    let controller = MainWindowController(model: model, settings: ReaderSettings(), offscreen: true,
                                          layoutDefaults: defaults)
    defer { controller.close() }
    controller.window?.setContentSize(NSSize(width: 1600, height: 900))
    controller.openProject(root: root)
    try #require(await mainWindowWaitUntil(model.snapshotPhase == .fullReady))
    controller.openFileForSelfTest(root.appendingPathComponent("main.rs"))
    controller.renderForSelfTest()
    let window = try #require(controller.window)
    let click = try #require(NSEvent.mouseEvent(
        with: .leftMouseUp, location: NSPoint(x: 600, y: 400), modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0
    ))
    NSApp.postEvent(click, atStart: true)
    let current = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true)
    try #require(current != nil && NSApp.currentEvent?.type == .leftMouseUp)
    let before = controller.panelLayout
    controller.toggleRelations()
    controller.movePanel(.relations, to: .left)
    controller.renderForSelfTest()
    controller.movePanel(.relations, to: .right)
    controller.renderForSelfTest()
    #expect(controller.panelLayout.heights == before.heights)
    #expect(controller.panelLayout.zoneWidths == before.zoneWidths)
}
