import AppKit
import CodeInsightAppModel
import Foundation
import Testing
@testable import CodeInsightApp

@MainActor
@Test
func readerContextMenuRoutesEveryRelationFromTheClickedByteOffset() throws {
    let source = "fn café() {\n    snapshot();\n}\n"
    let fixture = try makeReaderFixture(source: source)
    defer { fixture.cleanup() }
    let event = try rightClick(in: fixture.window, textView: fixture.textView)
    let expectedOffset = byteOffset(
        in: source,
        utf16Offset: fixture.textView.characterIndexForInsertion(
            at: fixture.textView.convert(event.locationInWindow, from: nil)
        )
    )
    var received: (UInt32, RelationTreeModel.Direction)?
    fixture.controller.onShowRelation = { received = ($0, $1) }

    for (title, direction) in [
        ("Show Callers", RelationTreeModel.Direction.callers),
        ("Show Calls", .calls),
        ("Show Implementations", .implementations),
        ("Show References", .references),
    ] {
        received = nil
        let menu = try #require(fixture.textView.menu(for: event))
        let item = try #require(menu.item(withTitle: title))
        let action = try #require(item.action)

        #expect(NSApplication.shared.sendAction(action, to: item.target, from: item))
        let result = try #require(received)
        #expect(result.0 == expectedOffset)
        #expect(result.1 == direction)
    }
}

@MainActor
@Test
func readerContextMenuStaysReadOnly() throws {
    let fixture = try makeReaderFixture(source: "fn snapshot() {}\n")
    defer { fixture.cleanup() }
    fixture.textView.setSelectedRange(NSRange(location: 3, length: 8))
    let event = try rightClick(in: fixture.window, textView: fixture.textView)
    let menu = try #require(fixture.textView.menu(for: event))
    let items = menuItems(in: menu)
    let forbiddenTitles = Set([
        "Cut", "Paste", "Paste and Match Style", "Delete",
        "Insert", "Substitutions", "Transformations",
        "Spelling and Grammar", "Font", "Text", "Writing Tools",
    ])
    let forbiddenActions = Set([
        "cut:", "paste:", "delete:", "insertText:",
        "insertNewline:", "insertTab:", "changeFont:",
    ])

    #expect(fixture.textView.isSelectable)
    #expect(!fixture.textView.isEditable)
    #expect(!fixture.textView.isRichText)
    #expect(items.allSatisfy { !forbiddenTitles.contains($0.title) })
    #expect(items.allSatisfy {
        guard let action = $0.action else { return true }
        return !forbiddenActions.contains(NSStringFromSelector(action))
    })
}

@MainActor
@Test
func readerContextMenuUsesTheDocumentSelectedByTheCurrentTab() throws {
    let sourceA = "fn active_tab() {\n    snapshot();\n}\n"
    let sourceB = "fn 😀😀😀inactive_tab() {\n    snapshot();\n}\n"
    let fixtureA = try makeReaderFixture(source: sourceA)
    defer { fixtureA.cleanup() }
    let fileB = try temporarySource(sourceB)
    defer { try? FileManager.default.removeItem(at: fileB) }
    let tabs = TabStripModel()
    tabs.open(fixtureA.file, inNewTab: false)
    tabs.open(fileB, inNewTab: true)
    fixtureA.controller.display(fileB)
    fixtureA.controller.configureTabs(
        tabs,
        onActivate: { index in
            tabs.activate(index)
            fixtureA.controller.display(tabs.activeTab?.fileURL)
        },
        onClose: { _ in }
    )
    tabs.activate(0)
    fixtureA.controller.display(tabs.activeTab?.fileURL)
    #expect(tabs.activeIndex == 0)

    let event = try rightClick(in: fixtureA.window, textView: fixtureA.textView)
    let characterIndex = fixtureA.textView.characterIndexForInsertion(
        at: fixtureA.textView.convert(event.locationInWindow, from: nil)
    )
    let expectedA = byteOffset(in: sourceA, utf16Offset: characterIndex)
    let wrongB = byteOffset(in: sourceB, utf16Offset: characterIndex)
    var received: UInt32?
    fixtureA.controller.onShowRelation = { offset, _ in received = offset }
    let menu = try #require(fixtureA.textView.menu(for: event))
    let item = try #require(menu.item(withTitle: "Show References"))
    let action = try #require(item.action)

    #expect(NSApplication.shared.sendAction(action, to: item.target, from: item))
    #expect(expectedA != wrongB)
    #expect(received == expectedA)
}

@MainActor
private func makeReaderFixture(
    source: String
) throws -> (
    controller: ReaderViewController,
    window: NSWindow,
    textView: NSTextView,
    file: URL,
    cleanup: () -> Void
) {
    _ = NSApplication.shared
    let file = try temporarySource(source)
    let controller = ReaderViewController()
    controller.loadViewIfNeeded()
    controller.display(file)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.contentViewController = controller
    window.contentView?.layoutSubtreeIfNeeded()
    let textView = try #require(findTextView(in: controller.view))
    return (
        controller,
        window,
        textView,
        file,
        { try? FileManager.default.removeItem(at: file) }
    )
}

private func temporarySource(_ source: String) throws -> URL {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(
        "CodeInsightM7Menu-\(UUID().uuidString).rs"
    )
    try Data(source.utf8).write(to: file)
    return file
}

@MainActor
private func rightClick(
    in window: NSWindow,
    textView: NSTextView
) throws -> NSEvent {
    try mouseEvent(
        type: .rightMouseDown,
        point: textView.convert(NSPoint(x: 110, y: 20), to: nil),
        window: window
    )
}

@MainActor
private func mouseEvent(
    type: NSEvent.EventType,
    point: NSPoint,
    window: NSWindow
) throws -> NSEvent {
    try #require(NSEvent.mouseEvent(
        with: type,
        location: point,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 1,
        clickCount: 1,
        pressure: 1
    ))
}

private func byteOffset(in source: String, utf16Offset: Int) -> UInt32 {
    let utf16 = source.utf16
    let clamped = min(max(utf16Offset, 0), utf16.count)
    let utf16Index = utf16.index(utf16.startIndex, offsetBy: clamped)
    let stringIndex = String.Index(utf16Index, within: source) ?? source.endIndex
    return UInt32(source[..<stringIndex].utf8.count)
}

private func menuItems(in menu: NSMenu) -> [NSMenuItem] {
    menu.items + menu.items.flatMap {
        $0.submenu.map(menuItems(in:)) ?? []
    }
}

@MainActor
private func findTextView(in view: NSView) -> NSTextView? {
    if let textView = view as? NSTextView { return textView }
    return view.subviews.lazy.compactMap(findTextView(in:)).first
}
