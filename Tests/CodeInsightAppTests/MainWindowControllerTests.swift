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
    let visible = NSScreen.main!.visibleFrame
    let owner = NSWindow(
        contentRect: NSRect(x: visible.maxX - 180, y: visible.maxY - 160, width: 800, height: 600),
        styleMask: [.titled], backing: .buffered, defer: false
    )
    owner.isReleasedWhenClosed = false
    defer { owner.close() }
    panel.show(relativeTo: owner)
    let ownerScreen = try #require(owner.screen)
    #expect(ownerScreen.visibleFrame.contains(panel.window!.frame))

    func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }
    let content = panel.window!.contentView!
    let views = descendants(of: content)
    let table = views.compactMap { $0 as? NSTableView }.first!
    let scroll = table.enclosingScrollView!
    let note = try #require(views.compactMap { $0 as? NSTextView }.first {
        $0.accessibilityLabel() == "Bookmark note"
    })
    #expect(!note.isEditable)
    #expect(panel.selfTestSelectFirstRow())
    #expect(note.isEditable)
    #expect(note.string == record.note)

    for width in [560.0, 820.0] {
        panel.window!.setContentSize(NSSize(width: width, height: 460))
        for style in [NSScroller.Style.legacy, .overlay] {
            scroll.scrollerStyle = style
            content.layoutSubtreeIfNeeded()
            table.layoutSubtreeIfNeeded()
            #expect(abs(scroll.frame.minX - 12) < 1)
            #expect(abs(content.bounds.maxX - scroll.frame.maxX - 12) < 1)
            #expect(abs(table.tableColumns[0].width - scroll.contentSize.width) < 1)
            #expect(scroll.contentInsets.top == 0 && scroll.contentInsets.bottom == 0)
            for row in 0..<2 {
                let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true)!
                cell.layoutSubtreeIfNeeded()
                let labels = descendants(of: cell).compactMap { $0 as? NSTextField }
                let buttons = descendants(of: cell).compactMap { $0 as? NSButton }
                #expect(buttons.count == (row == 0 ? 2 : 4))
                for label in labels where !label.isHidden {
                    let labelFrame = label.superview!.convert(
                        label.alignmentRect(forFrame: label.frame), to: cell
                    )
                    #expect(labelFrame.minY >= 0 && labelFrame.maxY <= cell.bounds.maxY)
                }
                #expect(labels.contains { $0.toolTip?.contains(record.path) == true })
                #expect(labels.contains { $0.toolTip == record.note })
            }
        }
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
func projectSearchPanelFitsVisibleOwnerAndLeavesAnUnclippedEmptyState() throws {
    _ = NSApplication.shared
    let screen = try #require(NSScreen.main)
    let visible = screen.visibleFrame
    let owner = NSWindow(
        contentRect: NSRect(x: visible.minX - 120, y: visible.minY + 40, width: 700, height: 540),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false
    )
    owner.isReleasedWhenClosed = false
    let panel = SearchPanel(appModel: AppModel(), onOpen: { _, _, _ in })
    defer { panel.close(); owner.close() }
    panel.show(relativeTo: owner)
    let window = try #require(panel.window)
    #expect(visible.contains(window.frame))
    let ownerVisible = owner.convertToScreen(owner.contentLayoutRect)
        .intersection(visible.insetBy(dx: 12, dy: 12))
    #expect(abs(window.frame.midX - ownerVisible.midX) < 0.01)
    #expect(window.frame.width < 720)
    let scroll = try #require(panel.outlineViewForTesting.enclosingScrollView)
    #expect(scroll.isHidden)
    #expect(scroll.frame.minX > 0)
    #expect(scroll.frame.maxX < window.contentView!.bounds.maxX)
    #expect(scroll.frame.height > 100)
    let priorFrame = window.frame
    owner.setFrameOrigin(NSPoint(x: visible.minX + 80, y: visible.minY + 80))
    NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: owner)
    #expect(window.frame != priorFrame)
    #expect(visible.contains(window.frame))
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

@MainActor
@Test
func emptyWindowRetiresPanelsWithoutAnObjectOfOperation() async {
    let fixture = MainWindowIdentityFixture()
    defer { fixture.close() }
    fixture.controller.showWindow(nil)
    fixture.controller.renderForSelfTest()

    // Preset sizing is deferred until the first layout. It must not reopen
    // Context after the welcome surface has retired it.
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }

    #expect(fixture.controller.selfTestSidebarPaneCollapsed)
    #expect(fixture.controller.selfTestContextPaneCollapsed)
    #expect(fixture.controller.selfTestRelationsPaneCollapsed)
    #expect(!fixture.controller.selfTestTrailBarVisible,
            "an empty trail bar has no object of operation")
    #expect(fixture.controller.selfTestEmptyStateExists)
    #expect(fixture.controller.selfTestEmptyStateOpenButtonIsVisibleDefaultAction)
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
        model.contextWindow.selectedCandidate != nil
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
    func findUpperSplit(_ view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView, split.isVertical, split.arrangedSubviews.count == 3 { return split }
        return view.subviews.lazy.compactMap(findUpperSplit).first
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
                let requestedFrame = window.frame
                first.renderForSelfTest()
                await settleWindow()
                // Resizing must reveal the existing selection without a new activation.
                try expectActiveTabVisible()
                let geometry = first.selfTestTabGeometry
                #expect(abs(geometry.contentFrame.width - width) <= 1)
                #expect(abs(window.frame.width - requestedFrame.width) <= 1)
                #expect(abs(window.frame.height - requestedFrame.height) <= 1)
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
    let upper = try #require(first.window?.contentView.flatMap(findUpperSplit))
    upper.setPosition(250, ofDividerAt: 0)
    upper.setPosition(upper.bounds.width - 700, ofDividerAt: 1)
    first.renderForSelfTest()
    let width = first.selfTestRelationsPaneWidth
    let relationsFraction = width / upper.bounds.width
    #expect(width > 628, "A wide window must permit the inspector's side-by-side mode")
    first.toggleRelations()
    first.toggleRelations()
    #expect(abs(first.selfTestRelationsPaneWidth - width) <= 2)
    first.model.contextWindow.tokenClicked(file: "main.rs", offset: UInt32("pub fn ".utf8.count))
    try #require(await mainWindowWaitUntil(first.model.contextWindow.selectedCandidate != nil))
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
    first.model.openReadingSet(title: "Saved path", excerpts: [])
    first.renderForSelfTest()
    await expectSourceWindowFrame("Reading Set")
    first.openFileForSelfTest(root.appendingPathComponent("README.md"))
    try #require(await mainWindowWaitUntil(first.displayedReaderFile?.lastPathComponent == "README.md"))
    first.renderForSelfTest()
    await expectSourceWindowFrame("README")
    #expect(!first.selfTestSidebarPaneCollapsed, "README keeps the file tree after a Reading Set")
    #expect(first.selfTestRelationsPaneCollapsed)
    first.openFileForSelfTest(root.appendingPathComponent("main.rs"))
    try #require(await mainWindowWaitUntil(first.displayedReaderFile?.lastPathComponent == "main.rs"))
    await expectSourceWindowFrame("source restored")
    #expect(!first.selfTestContextPaneCollapsed)
    window.zoom(nil)
    await settleWindow()
    first.toggleContext(nil)
    first.openFileForSelfTest(root.appendingPathComponent("README.md"))
    await settleWindow()
    first.checkpointSessionSynchronously()
    first.close()
    let second = try await makeController()
    defer { second.close() }
    #expect(!second.selfTestRelationsPaneCollapsed)
    let secondUpper = try #require(second.window?.contentView.flatMap(findUpperSplit))
    #expect(abs(second.selfTestRelationsPaneWidth / secondUpper.bounds.width - relationsFraction) <= 0.02)
    second.toggleContext(nil)
    #expect(!second.selfTestContextPaneCollapsed)
    second.toggleContext(nil)
    #expect(second.selfTestContextPaneCollapsed)
    second.window?.setContentSize(NSSize(width: 900, height: 600))
    second.renderForSelfTest()
    #expect(second.selfTestSidebarPaneCollapsed)
    second.checkpointSessionSynchronously()
    second.close()
    let third = try await makeController()
    defer { third.close() }
    third.toggleRelations()
    #expect(!third.selfTestSidebarPaneCollapsed, "Temporary narrow-window collapse is not a saved preference")
}

@MainActor
@Test
func productPolishOutlineUsesNativeHierarchyAndPreservesCollapsedBranches() throws {
    _ = NSApplication.shared
    let source = "pub struct Example { pub value: u32 }\nimpl Example { fn run(&self) {} }\n"
    let file = URL(fileURLWithPath: "/Example.rs")
    let document = try DocumentLoader(source: { _ in Array(source.utf8) }).load(file: file).document
    let defaults = UserDefaults.standard
    let name = "SidebarPolish.\(UUID().uuidString)"
    defer {
        defaults.dictionaryRepresentation().keys.filter { $0.contains(name) }
            .forEach { defaults.removeObject(forKey: $0) }
    }
    // A former automatic layout must not become the user's divider preference.
    defaults.set(["0, 0, 300, 534, NO, NO", "0, 535, 300, 25, NO, NO"],
                 forKey: "NSSplitView Subview Frames \(name)")
    func makeSidebar() -> (SidebarViewController, NSWindow) {
        let sidebar = SidebarViewController()
        sidebar.setSplitAutosaveName(name)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: 300, height: 560),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = sidebar
        window.setContentSize(NSSize(width: 300, height: 560))
        window.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        return (sidebar, window)
    }
    let (sidebar, window) = makeSidebar()
    defer { window.close() }
    sidebar.setSelectedFile(file)
    sidebar.setOutline(document.outlineFacets, file: file)
    func outlines(_ view: NSView) -> [NSOutlineView] {
        (view as? NSOutlineView).map { [$0] } ?? view.subviews.flatMap(outlines)
    }
    let outline = try #require(outlines(sidebar.view).first { $0.accessibilityLabel() == "Outline" })
    let row = try #require((0..<outline.numberOfRows).first { index in
        (outline.item(atRow: index) as? NSNumber)?.intValue == 0
    })
    let item = try #require(outline.item(atRow: row))
    #expect(outline.isExpandable(item))
    let expandedCount = outline.numberOfRows
    outline.collapseItem(item)
    #expect(outline.numberOfRows < expandedCount)
    sidebar.setOutline([], file: URL(fileURLWithPath: "/Other.rs"))
    sidebar.setOutline(document.outlineFacets, file: file)
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

    let files = try #require(outlines(sidebar.view).first { $0.accessibilityLabel() == "Files" })
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

    for height in [640.0, 420.0, 560.0] {
        window.setContentSize(NSSize(width: 300, height: height))
        sidebar.display(nil)
        sidebar.setProjectState(.empty)
        sidebar.setSelectedFile(nil)
        sidebar.setOutline([])
        window.contentView?.layoutSubtreeIfNeeded()
        sidebar.display(tree())
        sidebar.setSelectedFile(firstFile)
        sidebar.setOutline(document.outlineFacets, file: file)
        #expect(sidebar.synchronizeFileSelection(to: firstFile))
        window.contentView?.layoutSubtreeIfNeeded()
        let geometry = sidebar.selfTestGeometry
        #expect(geometry.filesPaneHeight >= 100 && geometry.outlinePaneHeight >= 100)
        #expect(defaults.object(forKey: "\(name).fraction") == nil,
                "Loading and automatic resizing must not write a user divider preference")
    }
    let split = try #require(sidebar.view.subviews.first { $0 is NSSplitView } as? NSSplitView)
    split.setPosition((split.bounds.height - split.dividerThickness) * 0.63, ofDividerAt: 0)
    let fraction = defaults.double(forKey: "\(name).fraction")
    #expect(abs(fraction - 0.63) < 0.005)
    func buttons(_ view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
    }
    func click(_ label: String, in target: SidebarViewController) throws {
        let button = try #require(buttons(target.view).first { $0.accessibilityLabel() == label })
        button.performClick(nil)
        target.view.window?.contentView?.layoutSubtreeIfNeeded()
        target.view.window?.displayIfNeeded()
    }
    try click("Collapse Files", in: sidebar)
    #expect(abs(sidebar.selfTestGeometry.filesPaneHeight - 25) < 1)
    window.setContentSize(NSSize(width: 300, height: 620))
    sidebar.display(tree())
    sidebar.setProjectState(.empty)
    window.contentView?.layoutSubtreeIfNeeded()
    #expect(abs(sidebar.selfTestGeometry.filesPaneHeight - 25) < 1)
    #expect(!sidebar.selfTestFilesContentVisible)
    try click("Collapse Outline", in: sidebar)
    #expect(abs(sidebar.selfTestGeometry.filesPaneHeight - 25) < 1)
    #expect(abs(sidebar.selfTestGeometry.outlinePaneHeight - 25) < 1)
    #expect(abs(split.frame.height - 50 - split.dividerThickness) < 1)
    #expect(abs(defaults.double(forKey: "\(name).fraction") - fraction) < 0.005)

    let (restored, restoredWindow) = makeSidebar()
    defer { restoredWindow.close() }
    #expect(abs(restored.selfTestGeometry.filesPaneHeight - 25) < 1)
    #expect(abs(restored.selfTestGeometry.outlinePaneHeight - 25) < 1)
    try click("Expand Files", in: restored)
    #expect(abs(restored.selfTestGeometry.outlinePaneHeight - 25) < 1)
    try click("Expand Outline", in: restored)
    let restoredGeometry = restored.selfTestGeometry
    #expect(abs(restoredGeometry.filesPaneHeight /
        (restoredGeometry.filesPaneHeight + restoredGeometry.outlinePaneHeight) - fraction) < 0.005)
    try click("Expand Outline", in: sidebar)
    #expect(abs(sidebar.selfTestGeometry.filesPaneHeight - 25) < 1)
    try click("Expand Files", in: sidebar)
    let expanded = sidebar.selfTestGeometry
    #expect(abs(expanded.filesPaneHeight / (expanded.filesPaneHeight + expanded.outlinePaneHeight) - fraction) < 0.005)
    sidebar.setOutlineHidden(true)
    try click("Collapse Files", in: sidebar)
    #expect(abs(split.frame.height - 25) < 1)
    sidebar.setOutlineHidden(false)
    window.contentView?.layoutSubtreeIfNeeded()
    #expect(abs(sidebar.selfTestGeometry.filesPaneHeight - 25) < 1)
    try click("Expand Files", in: sidebar)
    #expect(sidebar.selfTestDividerPersistsAcrossRebuild())
}
