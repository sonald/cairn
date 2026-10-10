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

// MARK: K0b — overrides, validation, replace, store

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
func clickGestureRequiresModifierAndChecksConflicts() {
    let table = KeyBindingTable(scheme: .default)
    // K-R2.4: a modifier-less click stays the plain click.
    #expect(table.validate(.click([]), for: .readerGestureDefinition) == .needsModifier)
    // Conflicts are checked among gestures only. (⌘⇧+click is lawfully
    // taken by reader.gesture.typeDefinition since P1, so ⌘⌥ is the free
    // combination here.)
    #expect(
        table.validate(.click([.command, .option]), for: .readerGestureSymbolDoc) == .ok
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
func replaceMovesBindingAtomically() throws {
    let suiteName = "KeyBindingOwnershipTests-\(UUID().uuidString)"
    nonisolated(unsafe) let suite = try #require(UserDefaults(suiteName: suiteName))
    defer { suite.removePersistentDomain(forName: suiteName) }
    let store = KeyBindingStore(defaults: suite)
    let defaults = KeyBindingTable(scheme: .default)
    var table = defaults
    let binding = KeyBinding.keyboard(
        KeyChord(modifiers: [.command, .shift], key: .character("f"))
    )

    table.replace(binding, for: .findInFile, takingFrom: .findInProject)
    #expect(table.commands(boundTo: binding) == [.findInFile])
    store.save(table.overrides)
    var restored = KeyBindingTable(scheme: .default, overrides: store.load())
    #expect(restored.commands(boundTo: binding) == [.findInFile])
    #expect(restored.overrides[.findInProject] == [],
            "an explicit empty override must survive reload without restoring the old owner")

    for command in [CommandID.findInFile, .findInProject] {
        restored.setBindings(defaults.bindings(for: command), for: command)
    }
    store.save(restored.overrides)
    #expect(store.load().isEmpty, "restoring defaults removes persisted differences")
    #expect(KeyBindingTable(scheme: .default, overrides: store.load())
        .commands(boundTo: binding) == [.findInProject])
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
         "file.openPythonProject":["command+shift+y"],
         "view.wrapLines":["not a chord","option+z"],
         "reader.gesture.definition":["command+shift+click"]}
        """,
        forKey: KeyBindingStore.overridesKey
    )

    let loaded = store.load()
    // Unknown command IDs, including ones a release removed, are dropped
    // entirely.
    #expect(loaded[CommandID(rawValue: "unknown.command")] == nil)
    #expect(loaded[CommandID(rawValue: "file.openPythonProject")] == nil)
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
