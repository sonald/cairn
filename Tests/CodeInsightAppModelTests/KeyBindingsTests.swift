import Foundation
import Testing
@testable import CodeInsightAppModel

/// K0a: the central key binding table — canonical strings, display order,
/// and a conflict-free default scheme (K-R2.5, K-R2.6).
@Test
func defaultKeyBindingSchemeHasNoConflicts() {
    let table = KeyBindingTable(scheme: .default)
    #expect(table.conflicts().isEmpty)
    // The checker itself must be able to see a conflict: two commands bound
    // to the same keyboard chord show up grouped with both command IDs.
    let duplicated = KeyBindingScheme(
        id: "conflict-sample",
        commands: [
            CommandDefinition(
                id: .findInFile, group: .find, titleKey: "app.menu.find.in.file",
                defaults: [.keyboard(KeyChord(modifiers: [.command], key: .character("f")))]
            ),
            CommandDefinition(
                id: .viewIncreaseFontSize, group: .view, titleKey: "app.menu.increase.font.size",
                defaults: [.keyboard(KeyChord(modifiers: [.command], key: .character("f")))]
            ),
        ]
    )
    let conflicts = KeyBindingTable(scheme: duplicated).conflicts()
    #expect(conflicts.count == 1)
    #expect(Set(conflicts.first?.1 ?? []) == Set([CommandID.findInFile, .viewIncreaseFontSize]))
}

@Test
func keyChordCanonicalStringRoundTripsAndSortsModifiers() throws {
    // Modifier order in the canonical string is fixed regardless of the
    // order the modifiers were typed or stored in (control, option, shift,
    // command — so ⌘⇧F is "shift+command+f").
    let typedShiftFirst = KeyChord(canonicalString: "shift+command+f")
    let typedCommandFirst = KeyChord(canonicalString: "command+shift+f")
    #expect(typedShiftFirst == typedCommandFirst)
    #expect(typedCommandFirst?.canonicalString == "shift+command+f")

    // Codable round-trips through the canonical string.
    let chord = KeyChord(
        modifiers: [.command, .shift, .control, .option],
        key: .special(.left)
    )
    let data = try JSONEncoder().encode(chord)
    let decoded = try JSONDecoder().decode(KeyChord.self, from: data)
    #expect(decoded == chord)
    #expect(decoded.canonicalString == "control+option+shift+command+left")

    // A literal "+" key survives the join/split round trip.
    let plus = KeyChord(canonicalString: "command++")
    #expect(plus == KeyChord(modifiers: [.command], key: .character("+")))
    #expect(plus?.canonicalString == "command++")

    // Garbage does not parse.
    #expect(KeyChord(canonicalString: "") == nil)
    #expect(KeyChord(canonicalString: "command+notakey+extra") == nil)
}

@Test
func keyChordDisplayUsesMacModifierOrder() {
    let table = KeyBindingTable(scheme: .default)
    let all = KeyChord(
        modifiers: [.command, .shift, .option, .control],
        key: .character("j")
    )
    // K-R2.6: display order ⌃⌥⇧⌘ regardless of storage order.
    #expect(table.displayString(.keyboard(all)) == "⌃⌥⇧⌘J")
    #expect(table.displayString(.keyboard(KeyChord(modifiers: [.command], key: .character(",")))) == "⌘,")
    #expect(
        table.displayString(
            .keyboard(KeyChord(modifiers: [.control, .command], key: .special(.left)))
        ) == "⌃⌘←"
    )
    // Click gestures show the modifier cap row followed by the click word.
    let click = table.displayString(.click([.command, .shift]))
    #expect(click.hasPrefix("⇧⌘ + "))
}

// MARK: K0b — overrides, validation, replace, store

@Test
func overridesStoreOnlyDifferencesFromDefaults() {
    var table = KeyBindingTable(scheme: .default)
    let defaults = KeyBindingTable(scheme: .default)
    #expect(table.overrides.isEmpty)

    // Changing Quick Open to ⌘B keeps an override for exactly that command.
    table.setBindings(
        [.keyboard(KeyChord(modifiers: [.command], key: .character("b")))],
        for: .fileQuickOpen
    )
    #expect(table.overrides[.fileQuickOpen] != nil)
    #expect(table.modifiedCommands == [.fileQuickOpen])

    // Setting the default back deletes the override (K-R1.4).
    table.setBindings(defaults.bindings(for: .fileQuickOpen), for: .fileQuickOpen)
    #expect(table.overrides[.fileQuickOpen] == nil)
    #expect(table.modifiedCommands.isEmpty)

    // reset() and resetAll() restore the scheme defaults.
    table.setBindings(
        [.keyboard(KeyChord(modifiers: [.command], key: .character("b")))],
        for: .fileQuickOpen
    )
    table.reset(.fileQuickOpen)
    #expect(table.overrides.isEmpty)
    table.setBindings(
        [.keyboard(KeyChord(modifiers: [.command], key: .character("b")))],
        for: .fileQuickOpen
    )
    table.resetAll()
    #expect(table.overrides.isEmpty)
    #expect(table.bindings(for: .fileQuickOpen) == defaults.bindings(for: .fileQuickOpen))
}

@Test
func validationRejectsLockedAndModifierlessChords() {
    let table = KeyBindingTable(scheme: .default)
    // K-R2.2: locked system chords are rejected wherever they are recorded.
    #expect(
        table.validate(
            .keyboard(KeyChord(modifiers: [.command], key: .character("q"))),
            for: .fileOpenProject
        ) == .locked
    )
    #expect(
        table.validate(
            .keyboard(KeyChord(modifiers: [.command], key: .character(","))),
            for: .fileOpenProject
        ) == .locked
    )
    // K-R2.1: shift-only and modifier-less chords need ⌘/⌃/⌥.
    #expect(
        table.validate(
            .keyboard(KeyChord(modifiers: [.shift], key: .character("j"))),
            for: .fileOpenProject
        ) == .needsModifier
    )
    #expect(
        table.validate(.keyboard(KeyChord(key: .character("j"))), for: .fileOpenProject)
            == .needsModifier
    )
    // An option-only chord is legal where it is free.
    let free = KeyBindingTable(
        scheme: KeyBindingScheme(
            id: "free",
            commands: [
                CommandDefinition(
                    id: .fileOpenProject, group: .file, titleKey: "app.menu.open.project",
                    defaults: [.keyboard(KeyChord(modifiers: [.command], key: .character("o")))]
                )
            ]
        )
    )
    #expect(
        free.validate(
            .keyboard(KeyChord(modifiers: [.option], key: .character("z"))),
            for: .fileOpenProject
        ) == .ok
    )
    // K-R2.3: conflicts name the occupying command; re-recording a command's
    // own binding reports the duplicate instead.
    #expect(
        table.validate(
            .keyboard(KeyChord(modifiers: [.option], key: .character("z"))),
            for: .fileOpenProject
        ) == .conflict(with: .viewWrapLines)
    )
    #expect(
        table.validate(
            .keyboard(KeyChord(modifiers: [.command], key: .character("o"))),
            for: .fileOpenProject
        ) == .duplicateOnSameCommand
    )
}

@Test
func replaceMovesBindingAtomically() {
    var table = KeyBindingTable(scheme: .default)
    let shiftCommandF = KeyChord(modifiers: [.command, .shift], key: .character("f"))
    table.replace(.keyboard(shiftCommandF), for: .findInFile, takingFrom: .findInProject)
    // The new command gained the binding, the old one lost it, and both end
    // up in the override layer (the loser as an explicit "not set").
    #expect(table.bindings(for: .findInFile).contains(.keyboard(shiftCommandF)))
    #expect(!table.bindings(for: .findInProject).contains(.keyboard(shiftCommandF)))
    #expect(table.overrides[.findInFile] != nil)
    #expect(table.overrides[.findInProject] == [])
    #expect(table.modifiedCommands.sorted { $0.rawValue < $1.rawValue }
        == [.findInFile, .findInProject].sorted { $0.rawValue < $1.rawValue })
}

@Test
func clickGestureRequiresModifierAndChecksConflicts() {
    let table = KeyBindingTable(scheme: .default)
    // K-R2.4: a modifier-less click stays the plain click.
    #expect(table.validate(.click([]), for: .readerGestureDefinition) == .needsModifier)
    // Conflicts are checked among gestures only.
    #expect(
        table.validate(.click([.command, .shift]), for: .readerGestureSymbolDoc) == .ok
    )
    var redefined = table
    redefined.setBindings([.click([.command, .shift])], for: .readerGestureDefinition)
    #expect(
        redefined.validate(.click([.command, .shift]), for: .readerGestureSymbolDoc)
            == .conflict(with: .readerGestureDefinition)
    )
    // Keyboard chords do not conflict with click gestures.
    #expect(
        table.validate(
            .keyboard(KeyChord(modifiers: [.command, .shift], key: .character("k"))),
            for: .readerGestureSymbolDoc
        ) == .ok
    )
}

@Test
func keyBindingStoreDropsUnknownCommandsAndKeepsTheRest() throws {
    let suiteName = "KeyBindingStoreTests-\(UUID().uuidString)"
    nonisolated(unsafe) let suite = try #require(UserDefaults(suiteName: suiteName))
    defer { suite.removePersistentDomain(forName: suiteName) }
    let store = KeyBindingStore(defaults: suite)
    suite.set(
        """
        {"file.quickOpen":["command+b"],
         "unknown.command":["command+z"],
         "view.wrapLines":["not a chord","option+z"],
         "reader.gesture.definition":["command+shift+click"]}
        """,
        forKey: KeyBindingStore.overridesKey
    )

    let loaded = store.load()
    // Unknown command IDs are dropped entirely.
    #expect(loaded[CommandID(rawValue: "unknown.command")] == nil)
    // Unparseable strings are dropped; the rest of the command's bindings
    // survive.
    #expect(
        loaded[.viewWrapLines]
            == [.keyboard(KeyChord(modifiers: [.option], key: .character("z")))]
    )
    #expect(
        loaded[.fileQuickOpen]
            == [.keyboard(KeyChord(modifiers: [.command], key: .character("b")))]
    )
    #expect(loaded[.readerGestureDefinition] == [.click([.command, .shift])])

    // Save/load round-trips the effective overrides.
    store.save(loaded)
    let reloaded = KeyBindingStore(defaults: suite).load()
    #expect(reloaded == loaded)
}
