import AppKit
import CodeInsightCore
import CodeInsightEngine
import CodeInsightReaderCore
import Foundation
import Testing
@testable import CodeInsightApp
@testable import CodeInsightAppModel

@MainActor
@Suite(.serialized)
struct PaletteTests {
    @Test
    func dismissRestoresOwnerResponderBeforeOpening() {
        _ = NSApplication.shared
        let owner = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        let field = NSTextField()
        owner.contentView = field
        owner.makeFirstResponder(field)
        let responder = owner.firstResponder
        let panel = PalettePanel(appModel: AppModel(), settings: ReaderSettings(), onOpen: { _, _, _ in })
        defer { panel.close(); owner.close() }
        let item = NSMenuItem(title: "Check", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        panel.prepareForTesting(prefill: ">", owner: owner, commands: [
            PalettePanel.Row(title: "Check", detail: "", shortcut: "", identity: "check", payload: .command(item))
        ])
        var invoked = false
        panel.sendActionForTesting = { [weak panel] _, _, _ in
            invoked = true
            #expect(owner.isVisible)
            #expect(owner.firstResponder === responder)
            #expect(panel?.window?.isVisible == false)
        }
        panel.openSelectionForTesting()
        #expect(invoked)
    }

    @Test
    func lineModeRejectsInvalidValuesAndClampsPastEnd() {
        let file = URL(fileURLWithPath: "/palette.rs")
        let document = ReaderDocument(bytes: Array("one\ntwo\nthree\n".utf8))

        #expect(PalettePanel.lineRows(
            query: "", document: document, file: file
        ).message == "Type a line number")
        #expect(PalettePanel.lineRows(
            query: "nope", document: document, file: file
        ).message == "Enter a positive line number")
        #expect(PalettePanel.lineRows(
            query: "0", document: document, file: file
        ).rows.isEmpty)

        let clamped = PalettePanel.lineRows(
            query: "99", document: document, file: file
        )
        #expect(clamped.rows.first?.title == "Go to line 4")
        #expect(clamped.rows.first?.detail == "Line 99 is past the end · using 4")
        guard case let .location(_, offset, _) = clamped.rows.first?.payload else {
            Issue.record("expected clamped line location")
            return
        }
        #expect(offset == document.lineTable.lineStarts.last)
    }

    @Test
    func commandModeUpdatesDynamicMenusAndSkipsInvalidLeaves() {
        let app = NSApplication.shared
        let previousMenu = app.mainMenu
        defer { app.mainMenu = previousMenu }
        let target = PaletteCommandTarget()
        let root = NSMenu()
        let viewItem = NSMenuItem()
        let view = NSMenu(title: "View")
        let foldingItem = NSMenuItem(title: "Folding", action: nil, keyEquivalent: "")
        let folding = NSMenu(title: "Folding")
        let overview = NSMenuItem(
            title: "Overview",
            action: #selector(PaletteCommandTarget.executeCommand(_:)),
            keyEquivalent: "2"
        )
        overview.keyEquivalentModifierMask = [.command, .option]
        overview.target = target
        folding.addItem(overview)
        let hidden = NSMenuItem(
            title: "Hidden Backup",
            action: #selector(PaletteCommandTarget.executeCommand(_:)),
            keyEquivalent: ""
        )
        hidden.target = target
        hidden.isHidden = true
        folding.addItem(hidden)
        folding.addItem(NSMenuItem(title: "No Action", action: nil, keyEquivalent: ""))
        folding.addItem(NSMenuItem(
            title: "Cut",
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        ))
        foldingItem.submenu = folding
        view.addItem(foldingItem)
        viewItem.submenu = view
        root.addItem(viewItem)

        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recent = NSMenu(title: "Open Recent")
        let recentDelegate = PaletteRecentMenuDelegate(target: target)
        recent.delegate = recentDelegate
        recentItem.submenu = recent
        let fileItem = NSMenuItem()
        let file = NSMenu(title: "File")
        file.addItem(recentItem)
        fileItem.submenu = file
        root.addItem(fileItem)
        app.mainMenu = root

        let rows = PalettePanel.commandRows(in: root)
        #expect(rows.contains { $0.title == "View ▸ Folding ▸ Overview" && $0.shortcut == "⌥⌘2" })
        #expect(rows.contains { $0.title == "File ▸ Open Recent ▸ Recent Project" })
        #expect(!rows.contains { $0.title.contains("Hidden Backup") })
        #expect(!rows.contains { $0.title.contains("No Action") })
        #expect(!rows.contains { $0.title.hasSuffix("Cut") })

        // Display language must not affect command lookup or its action target.
        view.title = "视图"
        foldingItem.title = "折叠"
        overview.title = "概览"
        let translated = PalettePanel.filterCommandRows(
            PalettePanel.commandRows(in: root), query: "概览"
        )
        #expect(translated.count == 1)
        guard case let .command(item) = translated.first?.payload else {
            Issue.record("expected translated command")
            return
        }
        #expect(item === overview)
        let didSend = app.sendAction(item.action!, to: item.target, from: item)
        #expect(didSend)
        #expect(target.invocationCount == 1)
    }

    @Test
    func paletteCapsResultsPreservesSelectionAndOrdersCommandExecution() {
        _ = NSApplication.shared
        var commands: [PalettePanel.Row] = []
        for index in 0..<25 {
            let item = NSMenuItem(
                title: String(format: "Item %02d", index),
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: ""
            )
            item.target = NSApp
            let title = String(format: "Go ▸ Item %02d", index)
            commands.append(PalettePanel.Row(
                title: title,
                detail: "",
                shortcut: "",
                identity: "command:\(title)",
                payload: .command(item)
            ))
        }

        let panel = PalettePanel(
            appModel: AppModel(),
            settings: ReaderSettings(),
            onOpen: { _, _, _ in }
        )
        var sentActionCount = 0
        var sentTargetMatches = false
        var sentTitle = ""
        var executionOrder: [String] = []
        panel.restoreFocusForTesting = {
            executionOrder.append("restore")
        }
        panel.sendActionForTesting = { _, sentTarget, sender in
            executionOrder.append("send")
            sentActionCount += 1
            sentTargetMatches = sentTarget === NSApp
            sentTitle = sender.title
        }
        panel.revalidateForTesting = { item in
            executionOrder.append("validate")
            item.isEnabled = true
        }
        defer {
            panel.close()
        }

        panel.prepareForTesting(
            prefill: ">",
            owner: nil,
            commands: commands
        )
        #expect(panel.rowsForTesting.count == 20)
        #expect(panel.footerForTesting == "5 more results")
        #expect(panel.originalResponderForTesting == nil)
        let manyFrame = panel.window!.frame
        let inputTop = panel.inputFrameForTesting.maxY + manyFrame.minY
        let table = panel.tableViewForTesting
        let scroll = table.enclosingScrollView!
        #expect(scroll.hasVerticalScroller)
        #expect(scroll.documentVisibleRect.height < table.rect(ofRow: 19).maxY)
        // Always-visible system scrollers must not take space from one result.
        scroll.scrollerStyle = .legacy
        panel.setQueryForTesting("> Item 05")
        #expect(panel.rowsForTesting.map(\.title) == ["Go ▸ Item 05"])
        #expect(panel.window!.frame.maxY == manyFrame.maxY)
        #expect(panel.inputFrameForTesting.maxY + panel.window!.frame.minY == inputTop)
        #expect(scroll.hasVerticalScroller == false)
        #expect(scroll.documentVisibleRect.contains(table.rect(ofRow: 0)))
        #expect(table.rect(ofRow: 0).height >= 30)
        #expect(table.rect(ofRow: 0).width == scroll.contentSize.width)
        panel.setQueryForTesting("> unavailable-command")
        #expect(panel.rowsForTesting.isEmpty)
        #expect(panel.emptyMessageForTesting == "No commands found")
        #expect(panel.selectedIndexForTesting == nil)
        #expect(scroll.isHidden)
        #expect(scroll.hasVerticalScroller == false)
        #expect(panel.window!.frame.maxY == manyFrame.maxY)
        panel.setQueryForTesting("> Item 05")
        panel.setQueryForTesting("> Item")
        #expect(panel.selectedIndexForTesting == 5)
        panel.setQueryForTesting("> Item 12")
        #expect(panel.selectedIndexForTesting == 0)

        panel.openSelectionForTesting()
        #expect(sentActionCount == 1)
        #expect(sentTargetMatches)
        #expect(sentTitle == "Item 12")
        #expect(executionOrder == ["restore", "validate", "send"])
    }

    @Test
    func placementTracksOwnerContentAndKeepsAllResultStatesOnScreen() {
        let screen = NSRect(x: 0, y: 0, width: 2400, height: 1400)
        let owner = NSRect(x: 200, y: 200, width: 1200, height: 900)
        let many = PalettePanel.frame(relativeTo: owner, visibleFrame: screen, height: 325)
        let single = PalettePanel.frame(relativeTo: owner, visibleFrame: screen, height: 115)
        let empty = PalettePanel.frame(relativeTo: owner, visibleFrame: screen, height: 133)
        #expect(many.width == 600)
        #expect(many.midX == owner.midX)
        #expect(many.maxY == owner.maxY - owner.height * 0.15)
        #expect(many.maxY == single.maxY && single.maxY == empty.maxY)

        let movedOwner = owner.offsetBy(dx: 180, dy: -90)
        let moved = PalettePanel.frame(relativeTo: movedOwner, visibleFrame: screen, height: 325)
        #expect(moved == many.offsetBy(dx: 180, dy: -90))
        for (width, expected) in [(480.0, 432.0), (1000.0, 560.0), (1800.0, 760.0)] {
            let resized = PalettePanel.frame(
                relativeTo: NSRect(x: 200, y: 200, width: width, height: 900),
                visibleFrame: screen,
                height: 325
            )
            #expect(abs(resized.width - CGFloat(expected)) < 0.01)
        }
        // A secondary display can have a negative origin; a partly offscreen
        // owner uses its visible content area for placement.
        let secondary = NSRect(x: -1440, y: 200, width: 1440, height: 900)
        let clippedOwner = NSRect(x: -1700, y: 100, width: 1000, height: 1200)
        let clipped = PalettePanel.frame(relativeTo: clippedOwner, visibleFrame: secondary, height: 325)
        #expect(secondary.contains(clipped))
        #expect(clipped.midX == clippedOwner.intersection(secondary).midX)
        let small = NSRect(x: 0, y: 0, width: 800, height: 300)
        #expect(small.contains(PalettePanel.frame(relativeTo: small, visibleFrame: small, height: 325)))
    }

    @Test
    func projectSymbolModeForwardsFullWorkspaceSessions() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaletteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "fn shared() {}\n".write(
            to: root.appendingPathComponent("main.rs"),
            atomically: true,
            encoding: .utf8
        )
        try "def shared():\n    pass\n".write(
            to: root.appendingPathComponent("lib.py"),
            atomically: true,
            encoding: .utf8
        )
        try "export function shared() {}\n".write(
            to: root.appendingPathComponent("app.ts"),
            atomically: true,
            encoding: .utf8
        )
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", root.path, "init", "-q"]
        try git.run()
        git.waitUntilExit()
        guard git.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: root)
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let model = AppModel(indexService: ProjectIndexService())
        try await model.openProject(root: root, languages: [.rust, .python, .typescript])
        #expect(await waitUntil {
            model.querySessions.count == 3
        })

        let panel = PalettePanel(
            appModel: model,
            settings: ReaderSettings(),
            onOpen: { _, _, _ in }
        )
        defer { panel.close() }
        panel.show(prefill: "#shared", relativeTo: nil)
        #expect(await waitUntil {
            panel.rowsForTesting.count == 3
                && panel.rowsForTesting.allSatisfy { $0.title == "shared" }
        })
    }

}

@MainActor
@objc(PaletteCommandTarget)
final class PaletteCommandTarget: NSObject, NSMenuItemValidation {
    private weak var owner: NSWindow?
    private weak var expected: NSResponder?
    var invocationCount = 0
    var validationResponderMatches: [Bool] = []

    init(owner: NSWindow? = nil, expected: NSResponder? = nil) {
        self.owner = owner
        self.expected = expected
    }

    @objc dynamic func executeCommand(_ sender: Any?) {
        invocationCount += 1
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let owner, let expected {
            validationResponderMatches.append(owner.firstResponder === expected)
        }
        return true
    }
}

@MainActor
final class PaletteRecentMenuDelegate: NSObject, NSMenuDelegate {
    private let target: PaletteCommandTarget

    init(target: PaletteCommandTarget) {
        self.target = target
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.item(withTitle: "Recent Project") == nil else { return }
        let item = NSMenuItem(
            title: "Recent Project",
            action: #selector(PaletteCommandTarget.executeCommand(_:)),
            keyEquivalent: ""
        )
        item.target = target
        menu.addItem(item)
    }
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(3),
    _ condition: @escaping @MainActor () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}


@MainActor
@Test
func seekPreviewShowsLinesAroundALocationAndHidesOtherwise() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SeekPreview-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("lib.rs")
    let long = String(repeating: "x", count: 300)
    let source = (1...20).map { $0 == 10 ? "\(long) line 10" : "line \($0)" }
        .joined(separator: "\n") + "\n"
    try source.write(to: file, atomically: true, encoding: .utf8)
    let offset = UInt32(source[..<source.range(of: long)!.lowerBound].utf8.count)

    let panel = PalettePanel(appModel: AppModel(), settings: ReaderSettings(theme: .light), onOpen: { _, _, _ in })
    defer { panel.close() }
    let item = NSMenuItem(title: "x", action: #selector(NSText.selectAll(_:)), keyEquivalent: "")
    let rows = [
        PalettePanel.Row(title: "target", detail: "lib.rs:10", shortcut: "", identity: "a",
                         payload: .location(file, offset, expectedContentID: nil)),
        PalettePanel.Row(title: "command", detail: "", shortcut: "", identity: "b", payload: .command(item)),
        PalettePanel.Row(title: "stale", detail: "lib.rs:10", shortcut: "", identity: "c",
                         payload: .location(file, offset, expectedContentID: ContentID.sha256(of: Data("old".utf8)))),
    ]
    panel.prepareForTesting(prefill: ">", owner: nil, commands: rows)
    let table = panel.tableViewForTesting
    table.selectRowIndexes([0], byExtendingSelection: false)

    let preview = panel.selfTestPreview
    #expect(preview.visible)
    #expect(preview.target?.hasSuffix("line 10") == true)
    #expect(preview.text.contains("line 9\n") && preview.text.contains("line 20"))
    #expect(!preview.text.contains("line 8\n"))
    // The target line sits near the top, visible even in a two-row panel.
    #expect(preview.targetVisible)
    // Code keeps its lines: the long target line does not wrap.
    #expect(preview.targetHeight > 0 && preview.targetHeight < 20)

    table.selectRowIndexes([1], byExtendingSelection: false)
    #expect(!panel.selfTestPreview.visible)
    // An indexed location whose file changed since indexing gets no preview.
    table.selectRowIndexes([2], byExtendingSelection: false)
    #expect(!panel.selfTestPreview.visible)
}
