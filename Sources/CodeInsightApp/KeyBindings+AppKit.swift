import AppKit
import CodeInsightAppModel

extension KeyChord.Modifier {
    var eventFlags: NSEvent.ModifierFlags {
        switch self {
        case .control: .control
        case .option: .option
        case .shift: .shift
        case .command: .command
        }
    }
}

extension Set where Element == KeyChord.Modifier {
    init(_ flags: NSEvent.ModifierFlags) {
        let relevant = flags.intersection([.command, .option, .control, .shift])
        self = Set(KeyChord.Modifier.allCases.filter { relevant.contains($0.eventFlags) })
    }

    var eventFlags: NSEvent.ModifierFlags {
        reduce(into: []) { $0.insert($1.eventFlags) }
    }
}

extension KeyChord {
    /// Reads back the chord an `NSMenuItem` carries — the inverse of
    /// `applyKeyChord`. Used by the menu wiring tests (K0a).
    init?(keyEquivalent: String, modifierMask: NSEvent.ModifierFlags) {
        guard !keyEquivalent.isEmpty else { return nil }
        if let special = Self.special(forEquivalent: keyEquivalent) {
            self.init(
                modifiers: Set<KeyChord.Modifier>(modifierMask),
                key: .special(special)
            )
        } else if keyEquivalent.count == 1 {
            self.init(
                modifiers: Set<KeyChord.Modifier>(modifierMask),
                key: .character(keyEquivalent)
            )
        } else {
            return nil
        }
    }

    /// The `NSMenuItem.keyEquivalent` character for this chord: function-key
    /// Unicode scalars for arrows, `"\r"` for return, `" "` for space.
    var keyEquivalent: String {
        switch key {
        case let .character(character): character
        case let .special(special):
            switch special {
            case .left: String(UnicodeScalar(NSLeftArrowFunctionKey)!)
            case .right: String(UnicodeScalar(NSRightArrowFunctionKey)!)
            case .up: String(UnicodeScalar(NSUpArrowFunctionKey)!)
            case .down: String(UnicodeScalar(NSDownArrowFunctionKey)!)
            case .return: "\r"
            case .escape: "\u{1B}"
            case .space: " "
            case .delete: "\u{7F}"
            case .tab: "\t"
            }
        }
    }

    var keyEquivalentModifierMask: NSEvent.ModifierFlags {
        modifiers.eventFlags
    }

    /// Builds the chord typed into an event; nil when the event carries no
    /// recognizable key. Used by the option-only key monitor.
    init?(event: NSEvent) {
        guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else {
            return nil
        }
        if let special = Self.special(forEquivalent: characters) {
            self.init(modifiers: Set<KeyChord.Modifier>(event.modifierFlags), key: .special(special))
        } else if characters.count == 1 {
            self.init(modifiers: Set<KeyChord.Modifier>(event.modifierFlags), key: .character(characters))
        } else {
            return nil
        }
    }

    /// Key-monitor matcher (K0a): compares `charactersIgnoringModifiers` so
    /// ⌥Z matches even though Option alters the typed character (Ω).
    func matches(_ event: NSEvent) -> Bool {
        let relevant = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard relevant == modifiers.eventFlags else { return false }
        guard let characters = event.charactersIgnoringModifiers else { return false }
        switch key {
        case let .character(character):
            return characters.lowercased() == character.lowercased()
        case .special:
            return characters == keyEquivalent
        }
    }

    private static func special(forEquivalent equivalent: String) -> KeyChord.Special? {
        switch equivalent {
        case String(UnicodeScalar(NSLeftArrowFunctionKey)!): .left
        case String(UnicodeScalar(NSRightArrowFunctionKey)!): .right
        case String(UnicodeScalar(NSUpArrowFunctionKey)!): .up
        case String(UnicodeScalar(NSDownArrowFunctionKey)!): .down
        case "\r": .return
        case "\u{1B}": .escape
        case " ": .space
        case "\u{7F}": .delete
        case "\t": .tab
        default: nil
        }
    }
}

extension NSMenuItem {
    /// Applies a chord from the key binding table. The only place outside the
    /// initializer that may write key-equivalent state (CI gate K0a).
    func applyKeyChord(_ chord: KeyChord) {
        keyEquivalent = chord.keyEquivalent
        keyEquivalentModifierMask = chord.keyEquivalentModifierMask
    }
}

extension NSButton {
    /// Applies a chord from the key binding table, e.g. the fixed ⏎ on the
    /// welcome screen's open button.
    func applyKeyChord(_ chord: KeyChord) {
        keyEquivalent = chord.keyEquivalent
        keyEquivalentModifierMask = chord.keyEquivalentModifierMask
    }
}
