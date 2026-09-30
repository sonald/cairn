import AppKit
import CodeInsightAppModel
import Foundation
import Testing

@testable import CodeInsightApp

/// K0a menu wiring: every menu key equivalent comes from the key binding
/// table, and the migration left the menu byte-identical to the pre-table
/// menu (snapshot of 2026-09-30).
@MainActor
private func menuSnapshot(
    _ items: [NSMenuItem],
    matches expected: [(titleKey: String, key: String, mask: NSEvent.ModifierFlags)],
    context: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let visible = items.filter { !$0.isSeparatorItem }
    #expect(
        visible.count == expected.count,
        "\(context): \(visible.count) items, expected \(expected.count)",
        sourceLocation: sourceLocation
    )
    for (index, pair) in zip(visible, expected).enumerated() {
        #expect(
            pair.0.title == localized(pair.1.titleKey),
            "\(context)[\(index)] title \(pair.0.title) != \(pair.1.titleKey)",
            sourceLocation: sourceLocation
        )
        #expect(
            pair.0.keyEquivalent == pair.1.key,
            "\(context)[\(index)] key \(pair.0.keyEquivalent) != \(pair.1.key)",
            sourceLocation: sourceLocation
        )
        #expect(
            pair.0.keyEquivalentModifierMask == pair.1.mask,
            "\(context)[\(index)] mask \(pair.0.keyEquivalentModifierMask) != \(pair.1.mask)",
            sourceLocation: sourceLocation
        )
    }
}

@MainActor
@Test
func mainMenuShortcutsUnchangedByMigration() throws {
    let delegate = AppDelegate(startedAt: .now)
    let menu = delegate.makeMainMenu()
    #expect(menu.items.count == 8)
    let submenus = menu.items.compactMap(\.submenu)
    #expect(submenus.count == 8)

    // Cairn
    menuSnapshot(
        submenus[0].items,
        matches: [
            ("app.menu.about.cairn", "", .command),
            ("app.menu.settings", ",", .command),
            ("app.menu.quit.cairn", "q", .command),
        ],
        context: "app"
    )

    // File
    menuSnapshot(
        submenus[1].items,
        matches: [
            ("app.menu.open.project", "o", .command),
            ("app.menu.new.window", "n", .command),
            ("app.menu.open.python.project", "", .command),
            ("app.menu.open.typescript.project", "", .command),
            ("app.menu.quick.open", "p", .command),
            ("app.menu.open.recent", "", .command),
            ("app.menu.open.in.new.tab", "\r", [.command, .shift]),
            ("app.menu.close.tab", "w", .command),
            ("app.menu.close.window", "w", [.command, .shift]),
            ("app.menu.clear.reading.session", "", .command),
            ("app.menu.refresh.index", "r", .command),
            ("app.menu.trust.this.repository", "", .command),
        ],
        context: "file"
    )

    // Edit
    menuSnapshot(
        submenus[2].items,
        matches: [
            ("app.menu.cut", "x", .command),
            ("app.menu.copy", "c", .command),
            ("app.menu.paste", "v", .command),
            ("app.menu.select.all", "a", .command),
        ],
        context: "edit"
    )

    // Find
    menuSnapshot(
        submenus[3].items,
        matches: [
            ("app.menu.find.in.file", "f", .command),
            ("app.menu.find.next", "g", .command),
            ("app.menu.find.previous", "g", [.command, .shift]),
            ("app.menu.find.in.project", "f", [.command, .shift]),
        ],
        context: "find"
    )

    // Go — includes both hidden alternates in their migrated positions.
    menuSnapshot(
        submenus[4].items,
        matches: [
            ("app.menu.command.palette", "p", [.command, .shift]),
            ("app.menu.open.symbol", "t", .command),
            ("app.menu.go.to.line", "l", .command),
            ("app.menu.back", "\u{F702}", [.command, .control]),
            ("app.menu.forward", "\u{F703}", [.command, .control]),
            ("app.menu.back", "[", .command),
            ("app.menu.forward", "]", .command),
            ("app.menu.previous.tab", "[", [.command, .shift]),
            ("app.menu.next.tab", "]", [.command, .shift]),
            ("app.menu.previous.context.candidate", "\u{F702}", [.command, .option]),
            ("app.menu.next.context.candidate", "\u{F703}", [.command, .option]),
            ("app.menu.previous.diff.hunk", "\u{F700}", [.command, .option]),
            ("app.menu.next.diff.hunk", "\u{F701}", [.command, .option]),
        ],
        context: "go"
    )

    // View — the preset and folding submenus carry their own shortcuts.
    let viewItems = submenus[5].items.filter { !$0.isSeparatorItem }
    #expect(viewItems.count == 10)
    let presetItems = try #require(viewItems[0].submenu?.items.filter { !$0.isSeparatorItem })
    menuSnapshot(
        presetItems,
        matches: [
            ("app.menu.reading", "1", .command),
            ("app.menu.relations", "2", .command),
            ("app.menu.compare", "3", .command),
            ("app.menu.focus", "4", .command),
        ],
        context: "preset"
    )
    let foldingItems = try #require(viewItems[2].submenu?.items.filter { !$0.isSeparatorItem })
    menuSnapshot(
        foldingItems,
        matches: [
            ("app.menu.toggle.fold", "[", [.command, .control]),
            ("app.menu.full", "0", [.command, .option]),
            ("app.menu.structure", "1", [.command, .option]),
            ("app.menu.overview", "2", [.command, .option]),
            ("app.menu.focus.current.scope", "f", [.command, .option]),
        ],
        context: "folding"
    )
    menuSnapshot(
        [viewItems[1]] + Array(viewItems[3...]),
        matches: [
            ("app.menu.close.comparison", "w", [.command, .control]),
            ("app.menu.toggle.bookmark", "m", [.command, .shift]),
            ("app.menu.show.bookmarks", "b", [.command, .option]),
            ("app.menu.hide.bookmarks", "", .command),
            ("app.menu.increase.font.size", "+", .command),
            ("app.menu.decrease.font.size", "-", .command),
            ("app.menu.wrap.lines", "z", .option),
            ("app.menu.show.reading.trail", "t", [.command, .option]),
        ],
        context: "view-rest"
    )

    // Relations
    menuSnapshot(
        submenus[6].items,
        matches: [
            ("app.menu.show.hide.relations", "r", [.command, .control]),
            ("app.menu.show.callers", "h", [.command, .shift]),
            ("app.menu.show.calls", "", .command),
            ("app.menu.show.implementations", "", .command),
            ("app.menu.show.symbol.documentation", " ", [.control, .shift]),            ("app.menu.show.resolution.inspector", "i", .command),
        ],
        context: "relations"
    )
}

@MainActor
@Test
func mainMenuKeyEquivalentsMatchKeyBindingTable() throws {
    let delegate = AppDelegate(startedAt: .now)
    let menu = delegate.makeMainMenu()
    let table = delegate.keyBindingTable

    func descendants(_ m: NSMenu) -> [NSMenuItem] {
        m.items.flatMap { [$0] + ($0.submenu.map(descendants) ?? []) }
    }
    let items = descendants(menu).filter { !$0.isSeparatorItem }

    // Forward: every menu item with a key equivalent resolves to a command
    // and keyboard binding in the table.
    for item in items where !item.keyEquivalent.isEmpty {
        let chord = KeyChord(
            keyEquivalent: item.keyEquivalent,
            modifierMask: item.keyEquivalentModifierMask
        )
        let bound = chord.map { table.commands(boundTo: .keyboard($0)) } ?? []
        #expect(
            !bound.isEmpty,
            "menu item \(item.title) (\(item.keyEquivalent), \(item.keyEquivalentModifierMask)) has no table command"
        )
    }

    // Reverse: every keyboard binding in the table appears in the menu.
    for command in table.commands {
        for binding in table.bindings(for: command.id) {
            guard case let .keyboard(chord) = binding else { continue }
            let found = items.contains {
                $0.keyEquivalent == chord.keyEquivalent
                    && $0.keyEquivalentModifierMask == chord.keyEquivalentModifierMask
            }
            #expect(
                found,
                "table binding \(command.id.rawValue) = \(chord.canonicalString) is missing from the menu"
            )
        }
    }
}

@MainActor
@Test
func backAndForwardKeepHiddenAlternateShortcuts() throws {
    let delegate = AppDelegate(startedAt: .now)
    let menu = delegate.makeMainMenu()
    let goMenu = try #require(
        menu.items.compactMap(\.submenu).first {
            $0.title == localized("app.menu.go")
        }
    )
    let items = goMenu.items.filter { !$0.isSeparatorItem }

    for (visibleTitle, visibleKey, alternateKey) in [
        (localized("app.menu.back"), "\u{F702}", "["),
        (localized("app.menu.forward"), "\u{F703}", "]"),
    ] {
        let both = items.filter { $0.title == visibleTitle }
        #expect(both.count == 2)
        let visible = try #require(both.first { !$0.isHidden })
        let alternate = try #require(both.first { $0.isHidden })
        #expect(visible.keyEquivalent == visibleKey)
        #expect(visible.keyEquivalentModifierMask == [.command, .control])
        #expect(alternate.keyEquivalent == alternateKey)
        #expect(alternate.keyEquivalentModifierMask == .command)
        // The hidden item still activates its key equivalent (⌘[ / ⌘]).
        #expect(alternate.allowsKeyEquivalentWhenHidden)
    }
}

@MainActor
@Test
func optionOnlyBindingDispatchesThroughMonitor() throws {
    let delegate = AppDelegate(startedAt: .now)
    let defaults = UserDefaults.standard
    let original = defaults.object(forKey: "reader.wrapLines")
    defer {
        if let original {
            defaults.set(original, forKey: "reader.wrapLines")
        } else {
            defaults.removeObject(forKey: "reader.wrapLines")
        }
    }
    func event(_ modifiers: NSEvent.ModifierFlags, character: String) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "Ω", charactersIgnoringModifiers: character,
            isARepeat: false, keyCode: 6
        ))
    }

    // ⌥Z (an option-only table binding) toggles wrap through the monitor.
    let initial = defaults.bool(forKey: "reader.wrapLines")
    #expect(delegate.handleMonitoredKeyEquivalent(try event(.option, character: "z")))
    #expect(defaults.bool(forKey: "reader.wrapLines") == !initial)

    // Another option-only binding in the table dispatches its command too —
    // the monitor iterates the table, it does not hardcode ⌥Z.
    var overrides: [CommandID: [KeyBinding]] = [:]
    overrides[.viewHideBookmarks] = [
        .keyboard(KeyChord(modifiers: [.option], key: .character("x")))
    ]
    delegate.keyBindingTable = KeyBindingTable(scheme: .default, overrides: overrides)
    #expect(delegate.handleMonitoredKeyEquivalent(try event(.option, character: "x")))
    // Unbound option-only chords still fall through.
    #expect(!delegate.handleMonitoredKeyEquivalent(try event(.option, character: "y")))
    // ⌥⇧Z no longer matches the ⌥Z chord (⇧ alone is not a valid recording).
    #expect(!delegate.handleMonitoredKeyEquivalent(try event([.option, .shift], character: "z")))
}
