import AppKit
import CodeInsightCore
import CodeInsightReaderCore
import Foundation
import Testing
@testable import CodeInsightApp
@testable import CodeInsightAppModel

@MainActor
@Suite(.serialized)
struct PaletteTests {
    @Test
    func parsesAllFiveModesAndTheirQueries() {
        #expect(PalettePanel.Mode.parse("main").mode == .file)
        #expect(PalettePanel.Mode.parse("main").query == "main")
        #expect(PalettePanel.Mode.parse("> fold").mode == .command)
        #expect(PalettePanel.Mode.parse("> fold").query == "fold")
        #expect(PalettePanel.Mode.parse("@spawn").mode == .currentSymbol)
        #expect(PalettePanel.Mode.parse("#spawn").mode == .projectSymbol)
        #expect(PalettePanel.Mode.parse(":449").mode == .line)
    }

    @Test
    func fileModeUsesTabsThenStableTreeOrderAndDisambiguatesNames() {
        let root = URL(fileURLWithPath: "/palette-project", isDirectory: true)
        let tree = FileTreeModel(root: root, snapshotPaths: [
            "main.rs", "src/main.rs", "tests/main.rs", "alpha.rs",
            "deep/nested/alpha.rs", "deep/nested/unique.rs", "beta.rs",
        ])
        let testsMain = root.appendingPathComponent("tests/main.rs")
        let srcMain = root.appendingPathComponent("src/main.rs")
        let rows = PalettePanel.fileRows(
            query: "",
            tree: tree,
            tabs: [testsMain, testsMain.standardizedFileURL, srcMain]
        )

        #expect(rows.prefix(2).map(\.identity) == [
            "file:\(testsMain.path)", "file:\(srcMain.path)",
        ])
        #expect(rows.first { $0.identity == "file:\(root.appendingPathComponent("main.rs").path)" }?.detail == "./")
        #expect(rows.first { $0.identity == "file:\(srcMain.path)" }?.detail == "src/")
        #expect(rows.first { $0.identity == "file:\(testsMain.path)" }?.detail == "tests/")
        #expect(rows.first {
            $0.identity == "file:\(root.appendingPathComponent("deep/nested/unique.rs").path)"
        }?.detail == "deep/nested/")

        let alpha = PalettePanel.fileRows(query: "ALP", tree: tree, tabs: [])
        #expect(alpha.map(\.identity) == [
            "file:\(root.appendingPathComponent("alpha.rs").path)",
            "file:\(root.appendingPathComponent("deep/nested/alpha.rs").path)",
        ])
        #expect(PalettePanel.fileRows(query: "nested", tree: tree, tabs: []).isEmpty)
    }

    @Test
    func currentSymbolModeRanksPrefixThenKindNameAndRange() {
        let file = URL(fileURLWithPath: "/palette.rs")
        let document = ReaderDocument(
            bytes: Array(String(repeating: "x", count: 100).utf8),
            outlineFacets: [
                facet("xspawn", .method, 50),
                facet("SpawnZ", .fn, 30),
                facet("spawnA", .struct, 20),
                facet("spawnA", .struct, 10),
            ]
        )

        let rows = PalettePanel.currentSymbolRows(
            query: "SP",
            document: document,
            file: file
        )
        #expect(rows.map(\.title) == ["spawnA", "spawnA", "SpawnZ", "xspawn"])
        #expect(rows.map(\.identity) == [
            "current:struct:10", "current:struct:20",
            "current:fn:30", "current:method:50",
        ])
        #expect(PalettePanel.currentSymbolRows(
            query: "",
            document: document,
            file: file
        ).isEmpty)
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
        guard case let .location(_, offset) = clamped.rows.first?.payload else {
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
            action: #selector(PaletteCommandTarget.perform(_:)),
            keyEquivalent: "2"
        )
        overview.keyEquivalentModifierMask = [.command, .option]
        overview.target = target
        folding.addItem(overview)
        let hidden = NSMenuItem(
            title: "Hidden Backup",
            action: #selector(PaletteCommandTarget.perform(_:)),
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
            onOpen: { _, _ in }
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
        #expect(panel.footerForTesting == "… 还有 5 条")
        #expect(panel.originalResponderForTesting == nil)
        #expect(panel.window?.frame.width == 380)
        #expect(panel.window?.frame.height == 258)

        panel.setQueryForTesting("> Item 05")
        #expect(panel.rowsForTesting.map(\.title) == ["Go ▸ Item 05"])
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
    func projectSymbolModeReusesIndexedSymbolResults() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaletteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = (0..<55).map { "fn target_symbol_\($0)() {}" }
            .joined(separator: "\n")
        try Data(source.utf8)
            .write(to: root.appendingPathComponent("main.rs"))
        defer { try? FileManager.default.removeItem(at: root) }

        let model = AppModel()
        model.openProject(root: root)
        #expect(await waitUntil { if case .ready = model.projectState { true } else { false } })

        let panel = PalettePanel(
            appModel: model,
            settings: ReaderSettings(),
            onOpen: { _, _ in }
        )
        defer { panel.close() }
        panel.show(prefill: "#target_symbol_", relativeTo: nil)
        #expect(panel.inputSelectionForTesting == NSRange(location: 15, length: 0))
        #expect(await waitUntil {
            panel.rowsForTesting.count == 20
                && panel.footerForTesting == "… 还有 35 条"
                && panel.rowsForTesting.allSatisfy {
                    $0.title.hasPrefix("target_symbol_")
                }
        })
    }
}

private func facet(
    _ name: String,
    _ kind: OutlineKind,
    _ offset: UInt32
) -> OutlineFacet {
    OutlineFacet(
        kind: kind,
        name: name,
        range: ByteRange(lowerBound: offset, upperBound: offset + 5),
        nameRange: ByteRange(lowerBound: offset, upperBound: offset + 2),
        depth: 0
    )
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

    @objc dynamic func perform(_ sender: Any?) {
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
            action: #selector(PaletteCommandTarget.perform(_:)),
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
