import AppKit
import CodeInsightCore
import CodeInsightEngine
import CodeInsightReaderCore
import Foundation
import Testing
@testable import CodeInsightApp
@testable import CodeInsightAppModel

@MainActor
private func panelStateWaitUntil(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<300 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

@MainActor
@Test
func searchPanelKeepsCollapsedFileGroupsCollapsedAcrossRenders() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "CodeInsightSearchCollapse-\(UUID().uuidString)", isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "fn needle() {}\n".write(to: root.appendingPathComponent("a.rs"), atomically: true, encoding: .utf8)
    try "fn f() { needle(); }\n".write(to: root.appendingPathComponent("b.rs"), atomically: true, encoding: .utf8)
    let model = AppModel(indexService: ProjectIndexService())
    await model.openProject(root: root).value
    #expect(await panelStateWaitUntil { model.snapshotPhase == .fullReady })
    let panel = SearchPanel(appModel: model, onOpen: { _, _, _, _ in }, onReturnToReader: {})
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentView = panel.view
    panel.refreshProjectState()
    panel.selfTestSetQuery("needle")
    let search = model.projectSearch
    #expect(await panelStateWaitUntil { !search.isSearching && search.totalMatches == 2 && search.groups.count == 2 })
    panel.apply(settings: ReaderSettings())
    let outline = panel.outlineViewForTesting
    let groups = search.groups
    #expect(outline.isItemExpanded(groups[0]) && outline.isItemExpanded(groups[1]))

    outline.collapseItem(groups[1])
    // A selection change re-renders the results through the model observer.
    search.select(0)
    try await Task.sleep(for: .milliseconds(150))
    panel.apply(settings: ReaderSettings())
    #expect(outline.isItemExpanded(groups[0]))
    #expect(!outline.isItemExpanded(groups[1]))

    // Stepping into a collapsed file reveals the selected result.
    panel.moveResult(by: 1)
    #expect(search.selectedIndex == 1)
    #expect(outline.isItemExpanded(groups[1]))
    #expect(outline.selectedRow == outline.row(forItem: groups[1].matches[0]))
}

@MainActor
@Test
func contextWindowSegmentFollowsTrackingChangedOutsideTheControl() async throws {
    _ = NSApplication.shared
    let model = ContextWindowModel()
    let controller = ContextWindowViewController(model: model)
    #expect(controller.selfTestTracking == "symbol")
    // The menu command and session restore change the model directly.
    model.setTracking(.enclosing)
    #expect(await panelStateWaitUntil { controller.selfTestTracking == "enclosing" })
    model.setTracking(.symbol)
    #expect(await panelStateWaitUntil { controller.selfTestTracking == "symbol" })
}

@MainActor
@Test
func bookmarkPanelShowsASheetWhenAnExportCannotBeWritten() throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "CodeInsightBookmarkExportFailure-\(UUID().uuidString)", isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let input = directory.appendingPathComponent("bookmarks.json")
    try Data([0x7B, 0xFF, 0x00]).write(to: input)
    let model = AppModel()
    model.bookmarkModel = BookmarkModel(store: BookmarkStore(fileURL: input))
    let panel = BookmarkPanel(appModel: model, onOpen: { _ in }, onLineOpen: { _, _ in })
    defer { panel.closePanel() }
    panel.show(relativeTo: nil)
    let window = try #require(panel.window)

    let unwritable = directory.appendingPathComponent("missing/raw-copy.json")
    #expect(!panel.exportRawCopy(to: unwritable))
    let sheet = try #require(window.attachedSheet)
    #expect(sheet.contentView?.subviews.isEmpty == false)
    window.endSheet(sheet)
}
