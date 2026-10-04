import AppKit
import CodeInsightAppModel
import Foundation
import Testing

@testable import CodeInsightApp

// MARK: K0b — overrides applied everywhere, palette sync, recording swallow


/// K-R3.6/K-R3.7: an override commit rebuilds the main menu and refreshes
/// every window's toolbar menu-form keycaps — not just the active window.
@Suite(.serialized)
    @MainActor
    struct KeyBindingOverrideTests {
        @Test
        func overrideRebuildsMenusInEveryWindow() throws {
        let delegate = AppDelegate(startedAt: .now)
        NSApplication.shared.delegate = delegate
        defer { NSApplication.shared.delegate = nil }
        NSApplication.shared.mainMenu = delegate.makeMainMenu()
        defer { NSApplication.shared.mainMenu = nil }
        let originalOverrides = UserDefaults.standard.object(
            forKey: KeyBindingStore.overridesKey)
        defer {
            if let originalOverrides {
                UserDefaults.standard.set(
                    originalOverrides, forKey: KeyBindingStore.overridesKey)
            } else {
                UserDefaults.standard.removeObject(forKey: KeyBindingStore.overridesKey)
            }
        }
        #expect(NSApplication.shared.sendAction(
            NSSelectorFromString("newWindow:"), to: delegate, from: nil
        ))
        #expect(NSApplication.shared.sendAction(
            NSSelectorFromString("newWindow:"), to: delegate, from: nil
        ))
        let first = try #require(delegate.selfTestProjectWindow(0))
        let second = try #require(delegate.selfTestProjectWindow(1))
        defer { first.close(); second.close() }

        // The live toolbar menu-form items carry ⌘P before the override.
        let itemsBefore = [first, second].map {
            $0.selfTestToolbarMenuFormItem(identifier: "Symbols")
        }
        #expect(itemsBefore.allSatisfy { $0?.keyEquivalent == "p" })

        var table = delegate.keyBindingTable
        table.setBindings(
            [.keyboard(KeyChord(modifiers: [.command], key: .character("b")))],
            for: .fileQuickOpen
        )
        delegate.applyKeyBindings(table)

        // The rebuilt main menu carries the new chord.
        func descendants(_ m: NSMenu) -> [NSMenuItem] {
            m.items.flatMap { [$0] + ($0.submenu.map(descendants) ?? []) }
        }
        let mainMenu = try #require(NSApp.mainMenu)
        let quickOpenItems = descendants(mainMenu)
            .filter { $0.action == NSSelectorFromString("quickOpen:") }
        #expect(quickOpenItems.count == 1)
        #expect(quickOpenItems.first?.keyEquivalent == "b")

        // Every window's toolbar reference was updated in place.
        let itemsAfter = [first, second].map {
            $0.selfTestToolbarMenuFormItem(identifier: "Symbols")
        }
        #expect(itemsAfter.allSatisfy { $0?.keyEquivalent == "b" })
    }

    /// The command palette reads the live main menu, so an override shows up in
    /// the palette's shortcut column without extra wiring. New Window stays
    /// enabled without a project, so the palette lists it in this test.
    @Test
    func commandPaletteShowsOverriddenShortcut() throws {
        let delegate = AppDelegate(startedAt: .now)
        NSApplication.shared.delegate = delegate
        defer { NSApplication.shared.delegate = nil }
        NSApplication.shared.mainMenu = delegate.makeMainMenu()
        defer { NSApplication.shared.mainMenu = nil }
        let originalOverrides = UserDefaults.standard.object(
            forKey: KeyBindingStore.overridesKey
        )
        defer {
            if let originalOverrides {
                UserDefaults.standard.set(
                    originalOverrides, forKey: KeyBindingStore.overridesKey)
            } else {
                UserDefaults.standard.removeObject(forKey: KeyBindingStore.overridesKey)
            }
        }

        func newRow() -> PalettePanel.Row? {
            PalettePanel.commandRows(in: NSApp.mainMenu)
                .first { $0.title.hasSuffix(localized("app.menu.new.window")) }
        }
        let before = try #require(newRow())
        #expect(before.shortcut == "⌘N")

        var table = delegate.keyBindingTable
        table.setBindings(
            [.keyboard(KeyChord(modifiers: [.command], key: .character("b")))],
            for: .fileNewWindow
        )
        delegate.applyKeyBindings(table)

        let after = try #require(newRow())
        #expect(after.shortcut == "⌘B")
    }

    /// While a recorder is active it swallows key events before menu dispatch:
    /// a ⌘R probe command does not fire, the chord is captured, and the model
    /// surfaces the conflict against Refresh Index.
        @Test
        func recorderSwallowsMenuKeyEquivalentsWhileRecording() throws {
        // NSApp the global is only populated after NSApplication.shared runs.
        _ = NSApplication.shared
        final class Probe: NSObject {
            var hit = false
            @objc func fire(_ sender: Any?) { hit = true }
        }
        let probe = Probe()
        let probeItem = NSMenuItem(
            title: "probe", action: #selector(Probe.fire(_:)), keyEquivalent: "r"
        )
        probeItem.target = probe
        let probeMenu = NSMenu()
        probeMenu.addItem(probeItem)
        let probeRoot = NSMenuItem()
        probeRoot.submenu = probeMenu
        let menu = NSMenu()
        menu.addItem(probeRoot)
        NSApp.mainMenu = menu
        defer { NSApp.mainMenu = nil }

        let delegate = AppDelegate(startedAt: .now)
        let model = KeyBindingSettingsModel(table: delegate.keyBindingTable) { _ in }
        model.beginRecording(command: .findInFile, slot: nil)
        defer { model.endRecording() }

        func commandR() throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: 0, windowNumber: 0, context: nil, characters: "r",
                charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 15
            ))
        }

        // Recording: ⌘R is swallowed and captured; the conflict surfaces.
        NSApp.sendEvent(try commandR())
        #expect(!probe.hit)
        #expect(model.pendingConflict?.command == .findInFile)
        #expect(
            model.pendingConflict?.binding
                == .keyboard(KeyChord(modifiers: [.command], key: .character("r")))
        )
        #expect(model.pendingConflict?.other == .fileRefreshIndex)
        #expect(model.rowError == nil)

        // Control: without an active recorder the same event reaches the menu.
        model.cancelConflict()
        NSApp.sendEvent(try commandR())
        #expect(probe.hit)
    }
        /// K-R3.3: a recording belongs to the settings window. A key pressed in
        /// another window (Settings closed or left mid-recording) ends the
        /// recording and reaches its menu; it is never captured as a binding.
        /// Leaving the shortcuts tab ends the recording too.
        @Test
        func recorderEndsInsteadOfCapturingKeysFromAnotherWindow() throws {
        _ = NSApplication.shared
        final class Probe: NSObject {
            var hit = false
            @objc func fire(_ sender: Any?) { hit = true }
        }
        let probe = Probe()
        let probeItem = NSMenuItem(
            title: "probe", action: #selector(Probe.fire(_:)), keyEquivalent: "u"
        )
        probeItem.target = probe
        let probeMenu = NSMenu()
        probeMenu.addItem(probeItem)
        let probeRoot = NSMenuItem()
        probeRoot.submenu = probeMenu
        let menu = NSMenu()
        menu.addItem(probeRoot)
        NSApp.mainMenu = menu
        defer { NSApp.mainMenu = nil }

        func window() -> NSWindow {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            return window
        }
        let settingsWindow = window()
        let mainWindow = window()
        defer { settingsWindow.close(); mainWindow.close() }

        let delegate = AppDelegate(startedAt: .now)
        let before = delegate.keyBindingTable
        let model = KeyBindingSettingsModel(table: before) { _ in
            Issue.record("a key from another window must not commit a binding")
        }
        model.beginRecording(command: .findInFile, slot: nil, in: settingsWindow)
        defer { model.endRecording() }

        let commandU = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: mainWindow.windowNumber, context: nil,
            characters: "u", charactersIgnoringModifiers: "u",
            isARepeat: false, keyCode: 32
        ))
        NSApp.sendEvent(commandU)
        #expect(probe.hit, "the key reaches the other window's menu")
        #expect(model.recording == nil)
        #expect(model.pendingConflict == nil)

        // Switching away from the shortcuts tab ends a recording as well.
        model.selectedTab = .keybindings
        model.beginRecording(command: .findInFile, slot: nil, in: settingsWindow)
        model.selectedTab = .reader
        #expect(model.recording == nil)

        // "按键搜索" is one-shot: after it captures a chord, keys flow again.
        let search = model.makeKeySearchSession(in: settingsWindow)
        search.start()
        defer { search.stop() }
        let commandBracket = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: settingsWindow.windowNumber, context: nil,
            characters: "[", charactersIgnoringModifiers: "[",
            isARepeat: false, keyCode: 33
        ))
        NSApp.sendEvent(commandBracket)
        #expect(model.keySearchChord == KeyChord(modifiers: [.command], key: .character("[")))
        probe.hit = false
        let settingsCommandU = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: settingsWindow.windowNumber, context: nil,
            characters: "u", charactersIgnoringModifiers: "u",
            isARepeat: false, keyCode: 32
        ))
        NSApp.sendEvent(settingsCommandU)
        #expect(probe.hit, "the finished key search no longer swallows keys")
        #expect(model.keySearchChord == KeyChord(modifiers: [.command], key: .character("[")))
    }

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
}
