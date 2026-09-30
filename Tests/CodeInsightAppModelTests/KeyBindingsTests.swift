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
