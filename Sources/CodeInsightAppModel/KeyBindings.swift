import Foundation

/// One key combination: a modifier set plus the pressed key (K-R1.2).
///
/// The canonical string (K0a) sorts modifiers `control, option, shift,
/// command` and appends the key name, e.g. `control+command+j`. It is the
/// persistence and test format; display order is a presentation concern.
public struct KeyChord: Hashable, Codable, Sendable {
    public enum Modifier: String, Codable, CaseIterable, Sendable {
        case control, option, shift, command
    }

    public enum Key: Hashable, Sendable {
        /// Lowercased key equivalent: "j", "[", ",", "+", "1".
        case character(String)
        case special(Special)
    }

    public enum Special: String, Codable, Sendable {
        case left, right, up, down, `return`, escape, space, delete, tab
    }

    public let modifiers: Set<Modifier>
    public let key: Key

    public init(modifiers: Set<Modifier> = [], key: Key) {
        self.modifiers = modifiers
        if case let .character(character) = key {
            self.key = .character(character.lowercased())
        } else {
            self.key = key
        }
    }

    // MARK: Canonical string

    /// `control+command+j` — the canonical persistence form (K0a).
    public var canonicalString: String {
        let orderedModifiers = Modifier.allCases.filter { modifiers.contains($0) }
        return orderedModifiers.map(\.rawValue).joined(separator: "+")
            + (orderedModifiers.isEmpty ? "" : "+")
            + keyToken
    }

    public init?(canonicalString: String) {
        let components = canonicalString.components(separatedBy: "+")
        var remaining = components[...]
        var parsed: Set<Modifier> = []
        while let first = remaining.first, let modifier = Modifier(rawValue: first) {
            parsed.insert(modifier)
            remaining = remaining.dropFirst()
        }
        guard remaining.first != nil,
              remaining.count == 1 || remaining.allSatisfy({ $0.isEmpty })
        else { return nil }
        let keyText = remaining.joined(separator: "+")
        self.modifiers = parsed
        if let special = Special(rawValue: keyText) {
            self.key = .special(special)
        } else if keyText.count == 1 {
            self.key = .character(keyText)
        } else {
            return nil
        }
    }

    private var keyToken: String {
        switch key {
        case let .character(character): character
        case let .special(special): special.rawValue
        }
    }

    // MARK: Codable (single canonical string)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let chord = KeyChord(canonicalString: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Invalid key chord: \(raw)")
        }
        self = chord
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(canonicalString)
    }
}

/// A command binding: keyboard chord, reader mouse gesture, or a read-only
/// panel key that the settings page displays but cannot rebind (K-R1.2).
public enum KeyBinding: Hashable, Codable, Sendable {
    case keyboard(KeyChord)
    case click(Set<KeyChord.Modifier>)
    case fixed(KeyChord)

    /// The chord behind keyboard and fixed bindings; nil for click gestures.
    public var chord: KeyChord? {
        switch self {
        case let .keyboard(chord), let .fixed(chord): chord
        case .click: nil
        }
    }
}

/// Stable command identifier, e.g. `navigate.back` (K-R1.1).
public struct CommandID: Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

extension CommandID: Codable {
    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension CommandID {
    public static let appAbout = CommandID(rawValue: "app.about")
    public static let appSettings = CommandID(rawValue: "app.settings")
    public static let appQuit = CommandID(rawValue: "app.quit")

    public static let fileOpenProject = CommandID(rawValue: "file.openProject")
    public static let fileNewWindow = CommandID(rawValue: "file.newWindow")
    public static let fileQuickOpen = CommandID(rawValue: "file.quickOpen")
    public static let fileOpenPythonProject = CommandID(rawValue: "file.openPythonProject")
    public static let fileOpenTypeScriptProject = CommandID(rawValue: "file.openTypeScriptProject")
    public static let fileOpenInNewTab = CommandID(rawValue: "file.openInNewTab")
    public static let fileCloseTab = CommandID(rawValue: "file.closeTab")
    public static let fileCloseWindow = CommandID(rawValue: "file.closeWindow")
    public static let fileClearReadingSession = CommandID(rawValue: "file.clearReadingSession")
    public static let fileRefreshIndex = CommandID(rawValue: "file.refreshIndex")
    public static let fileTrustRepository = CommandID(rawValue: "file.trustRepository")

    public static let editCut = CommandID(rawValue: "edit.cut")
    public static let editCopy = CommandID(rawValue: "edit.copy")
    public static let editPaste = CommandID(rawValue: "edit.paste")
    public static let editSelectAll = CommandID(rawValue: "edit.selectAll")

    public static let findInFile = CommandID(rawValue: "find.inFile")
    public static let findNext = CommandID(rawValue: "find.next")
    public static let findPrevious = CommandID(rawValue: "find.previous")
    public static let findInProject = CommandID(rawValue: "find.inProject")
    public static let findToggleHighlight = CommandID(rawValue: "find.toggleHighlight")
    public static let findClearHighlights = CommandID(rawValue: "find.clearHighlights")

    public static let goCommandPalette = CommandID(rawValue: "go.commandPalette")
    public static let goOpenSymbol = CommandID(rawValue: "go.openSymbol")
    public static let goToLine = CommandID(rawValue: "go.toLine")
    public static let goBack = CommandID(rawValue: "go.back")
    public static let goForward = CommandID(rawValue: "go.forward")
    public static let goPreviousTab = CommandID(rawValue: "go.previousTab")
    public static let goNextTab = CommandID(rawValue: "go.nextTab")
    public static let goPreviousDiffHunk = CommandID(rawValue: "go.previousDiffHunk")
    public static let goNextDiffHunk = CommandID(rawValue: "go.nextDiffHunk")
    public static let navigateTypeDefinition = CommandID(rawValue: "navigate.typeDefinition")
    public static let goMatchingBracket = CommandID(rawValue: "go.matchingBracket")
    public static let goSelectInsideBrackets = CommandID(rawValue: "go.selectInsideBrackets")

    public static let viewPresetReading = CommandID(rawValue: "view.preset.reading")
    public static let viewPresetRelations = CommandID(rawValue: "view.preset.relations")
    public static let viewPresetCompare = CommandID(rawValue: "view.preset.compare")
    public static let viewPresetFocus = CommandID(rawValue: "view.preset.focus")
    public static let viewCloseComparison = CommandID(rawValue: "view.closeComparison")
    public static let viewToggleFold = CommandID(rawValue: "view.toggleFold")
    public static let viewReadingHeightFull = CommandID(rawValue: "view.readingHeight.full")
    public static let viewReadingHeightStructure = CommandID(rawValue: "view.readingHeight.structure")
    public static let viewReadingHeightOverview = CommandID(rawValue: "view.readingHeight.overview")
    public static let viewFocusCurrentScope = CommandID(rawValue: "view.focusCurrentScope")
    public static let viewToggleBookmark = CommandID(rawValue: "view.toggleBookmark")
    public static let viewShowBookmarks = CommandID(rawValue: "view.showBookmarks")
    public static let viewHideBookmarks = CommandID(rawValue: "view.hideBookmarks")
    public static let viewIncreaseFontSize = CommandID(rawValue: "view.increaseFontSize")
    public static let viewDecreaseFontSize = CommandID(rawValue: "view.decreaseFontSize")
    public static let viewWrapLines = CommandID(rawValue: "view.wrapLines")
    public static let viewShowReadingTrail = CommandID(rawValue: "view.showReadingTrail")

    public static let relationsToggle = CommandID(rawValue: "relations.toggle")
    public static let relationsShowCallers = CommandID(rawValue: "relations.showCallers")
    public static let relationsShowCalls = CommandID(rawValue: "relations.showCalls")
    public static let relationsShowImplementations = CommandID(rawValue: "relations.showImplementations")
    public static let relationsShowSymbolDocumentation =
        CommandID(rawValue: "relations.showSymbolDocumentation")
    public static let relationsShowResolutionInspector =
        CommandID(rawValue: "relations.showResolutionInspector")

    public static let lensPreviousCandidate = CommandID(rawValue: "lens.previousCandidate")
    public static let lensNextCandidate = CommandID(rawValue: "lens.nextCandidate")
    // K-R4 (P3): the tracking-mode commands carry no default chords.
    public static let lensTrackSymbol = CommandID(rawValue: "lens.trackSymbol")
    public static let lensTrackEnclosing = CommandID(rawValue: "lens.trackEnclosing")
    public static let lensTogglePin = CommandID(rawValue: "lens.togglePin")

    public static let readerGestureDefinition = CommandID(rawValue: "reader.gesture.definition")
    public static let readerGestureSymbolDoc = CommandID(rawValue: "reader.gesture.symbolDoc")
    public static let readerGestureTypeDefinition =
        CommandID(rawValue: "reader.gesture.typeDefinition")

    public static let panelMoveSelection = CommandID(rawValue: "panel.moveSelection")
    public static let panelOpenSelection = CommandID(rawValue: "panel.openSelection")
    public static let panelClosePanel = CommandID(rawValue: "panel.closePanel")
}

/// Settings-page section; case order is the display order (K1=A). Mirrors the
/// menu bar, plus the gesture and read-only panel sections from the prototype.
public enum CommandGroup: String, Codable, CaseIterable, Sendable {
    case application
    case file
    case edit
    case find
    case go
    case view
    case relations
    case lens
    case readerGestures
    case panels
}

public struct CommandDefinition: Sendable {
    public let id: CommandID
    public let group: CommandGroup
    /// Localization key; reuses the existing `app.menu.*` keys (K0a).
    public let titleKey: String
    public let defaults: [KeyBinding]

    public init(id: CommandID, group: CommandGroup, titleKey: String, defaults: [KeyBinding]) {
        self.id = id
        self.group = group
        self.titleKey = titleKey
        self.defaults = defaults
    }
}

/// K-R1.4: a scheme (only `default` today) plus the per-command defaults.
public struct KeyBindingScheme: Sendable {
    public let id: String
    public let commands: [CommandDefinition]

    public init(id: String, commands: [CommandDefinition]) {
        self.id = id
        self.commands = commands
    }
}

public extension KeyBindingScheme {
    /// Every shortcut in the current app, migrated verbatim from
    /// `makeMainMenu()` plus the monitored ⌥Z, reader gestures, and the
    /// read-only panel keys (K0a). Multi-binding commands list the visible
    /// item's binding first, hidden alternates after.
    static let `default`: KeyBindingScheme = {
        func def(
            _ id: CommandID, _ group: CommandGroup, _ titleKey: String, _ defaults: [KeyBinding]
        ) -> CommandDefinition {
            CommandDefinition(id: id, group: group, titleKey: titleKey, defaults: defaults)
        }
        func keyboard(_ modifiers: [KeyChord.Modifier], _ key: KeyChord.Key) -> KeyBinding {
            .keyboard(KeyChord(modifiers: Set(modifiers), key: key))
        }
        func fixed(_ modifiers: [KeyChord.Modifier], _ key: KeyChord.Key) -> KeyBinding {
            .fixed(KeyChord(modifiers: Set(modifiers), key: key))
        }
        let none: [KeyChord.Modifier] = []
        return KeyBindingScheme(id: "default", commands: [
            def(.appAbout, .application, "app.menu.about.cairn", []),
            def(.appSettings, .application, "app.menu.settings", [
                .keyboard(KeyChord(modifiers: [.command], key: .character(","))),
            ]),
            def(.appQuit, .application, "app.menu.quit.cairn", [keyboard([.command], .character("q"))]),

            def(.fileOpenProject, .file, "app.menu.open.project",
                [keyboard([.command], .character("o"))]),
            def(.fileNewWindow, .file, "app.menu.new.window",
                [keyboard([.command], .character("n"))]),
            def(.fileQuickOpen, .file, "app.menu.quick.open",
                [keyboard([.command], .character("p"))]),
            def(.fileOpenPythonProject, .file, "app.menu.open.python.project", []),
            def(.fileOpenTypeScriptProject, .file, "app.menu.open.typescript.project", []),
            def(.fileOpenInNewTab, .file, "app.menu.open.in.new.tab", [
                keyboard([.command, .shift], .special(.return)),
            ]),
            def(.fileCloseTab, .file, "app.menu.close.tab",
                [keyboard([.command], .character("w"))]),
            def(.fileCloseWindow, .file, "app.menu.close.window", [
                keyboard([.command, .shift], .character("w")),
            ]),
            def(.fileClearReadingSession, .file, "app.menu.clear.reading.session", []),
            def(.fileRefreshIndex, .file, "app.menu.refresh.index",
                [keyboard([.command], .character("r"))]),
            def(.fileTrustRepository, .file, "app.menu.trust.this.repository", []),

            def(.editCut, .edit, "app.menu.cut", [keyboard([.command], .character("x"))]),
            def(.editCopy, .edit, "app.menu.copy", [keyboard([.command], .character("c"))]),
            def(.editPaste, .edit, "app.menu.paste", [keyboard([.command], .character("v"))]),
            def(.editSelectAll, .edit, "app.menu.select.all",
                [keyboard([.command], .character("a"))]),

            def(.findInFile, .find, "app.menu.find.in.file",
                [keyboard([.command], .character("f"))]),
            def(.findNext, .find, "app.menu.find.next",
                [keyboard([.command], .character("g"))]),
            def(.findPrevious, .find, "app.menu.find.previous", [
                keyboard([.command, .shift], .character("g")),
            ]),
            def(.findInProject, .find, "app.menu.find.in.project", [
                keyboard([.command, .shift], .character("f")),
            ]),
            def(.findToggleHighlight, .find, "app.menu.toggle.highlight", [
                keyboard([.control, .command], .character("h")),
            ]),
            def(.findClearHighlights, .find, "app.menu.clear.highlights", [
                keyboard([.control, .option, .command], .character("h")),
            ]),

            def(.goCommandPalette, .go, "app.menu.command.palette", [
                keyboard([.command, .shift], .character("p")),
            ]),
            def(.goOpenSymbol, .go, "app.menu.open.symbol",
                [keyboard([.command], .character("t"))]),
            def(.goToLine, .go, "app.menu.go.to.line",
                [keyboard([.command], .character("l"))]),
            def(.goBack, .go, "app.menu.back", [
                keyboard([.control, .command], .special(.left)),
                keyboard([.command], .character("[")),
            ]),
            def(.goForward, .go, "app.menu.forward", [
                keyboard([.control, .command], .special(.right)),
                keyboard([.command], .character("]")),
            ]),
            def(.goPreviousTab, .go, "app.menu.previous.tab", [
                keyboard([.command, .shift], .character("[")),
            ]),
            def(.goNextTab, .go, "app.menu.next.tab", [
                keyboard([.command, .shift], .character("]")),
            ]),
            def(.goPreviousDiffHunk, .go, "app.menu.previous.diff.hunk", [
                keyboard([.option, .command], .special(.up)),
            ]),
            def(.goNextDiffHunk, .go, "app.menu.next.diff.hunk", [
                keyboard([.option, .command], .special(.down)),
            ]),
            // K-R4 (P1): 跳到类型定义 — menu ⌃⌘J and the ⌘⇧+click gesture.
            def(.navigateTypeDefinition, .go, "app.menu.type.definition", [
                keyboard([.control, .command], .character("j")),
            ]),
            def(.goMatchingBracket, .go, "app.menu.matching.bracket", [
                keyboard([.control, .command], .character("m")),
            ]),
            def(.goSelectInsideBrackets, .go, "app.menu.select.inside.brackets", [
                keyboard([.control, .shift, .command], .character("m")),
            ]),

            def(.viewPresetReading, .view, "app.menu.reading",
                [keyboard([.command], .character("1"))]),
            def(.viewPresetRelations, .view, "app.menu.relations",
                [keyboard([.command], .character("2"))]),
            def(.viewPresetCompare, .view, "app.menu.compare",
                [keyboard([.command], .character("3"))]),
            def(.viewPresetFocus, .view, "app.menu.focus",
                [keyboard([.command], .character("4"))]),
            def(.viewCloseComparison, .view, "app.menu.close.comparison", [
                keyboard([.control, .command], .character("w")),
            ]),
            def(.viewToggleFold, .view, "app.menu.toggle.fold", [
                keyboard([.control, .command], .character("[")),
            ]),
            def(.viewReadingHeightFull, .view, "app.menu.full", [
                keyboard([.option, .command], .character("0")),
            ]),
            def(.viewReadingHeightStructure, .view, "app.menu.structure", [
                keyboard([.option, .command], .character("1")),
            ]),
            def(.viewReadingHeightOverview, .view, "app.menu.overview", [
                keyboard([.option, .command], .character("2")),
            ]),
            def(.viewFocusCurrentScope, .view, "app.menu.focus.current.scope", [
                keyboard([.option, .command], .character("f")),
            ]),
            def(.viewToggleBookmark, .view, "app.menu.toggle.bookmark", [
                keyboard([.command, .shift], .character("m")),
            ]),
            def(.viewShowBookmarks, .view, "app.menu.show.bookmarks", [
                keyboard([.option, .command], .character("b")),
            ]),
            def(.viewHideBookmarks, .view, "app.menu.hide.bookmarks", []),
            def(.viewIncreaseFontSize, .view, "app.menu.increase.font.size", [
                keyboard([.command], .character("+")),
            ]),
            def(.viewDecreaseFontSize, .view, "app.menu.decrease.font.size", [
                keyboard([.command], .character("-")),
            ]),
            def(.viewWrapLines, .view, "app.menu.wrap.lines",
                [keyboard([.option], .character("z"))]),
            def(.viewShowReadingTrail, .view, "app.menu.show.reading.trail", [
                keyboard([.option, .command], .character("t")),
            ]),

            def(.relationsToggle, .relations, "app.menu.show.hide.relations", [
                keyboard([.control, .command], .character("r")),
            ]),
            def(.relationsShowCallers, .relations, "app.menu.show.callers", [
                keyboard([.command, .shift], .character("h")),
            ]),
            def(.relationsShowCalls, .relations, "app.menu.show.calls", []),
            def(.relationsShowImplementations, .relations, "app.menu.show.implementations", []),
            def(.relationsShowSymbolDocumentation, .relations, "app.menu.show.symbol.documentation", [
                keyboard([.control, .shift], .special(.space)),
            ]),
            def(.relationsShowResolutionInspector, .relations, "app.menu.show.resolution.inspector", [
                keyboard([.command], .character("i")),
            ]),

            def(.lensTrackSymbol, .lens, "lens.trackSymbol", []),
            def(.lensTrackEnclosing, .lens, "lens.trackEnclosing", []),
            def(.lensTogglePin, .lens, "lens.togglePin", []),
            def(.lensPreviousCandidate, .lens, "app.menu.previous.context.candidate", [
                keyboard([.option, .command], .special(.left)),
            ]),
            def(.lensNextCandidate, .lens, "app.menu.next.context.candidate", [
                keyboard([.option, .command], .special(.right)),
            ]),

            def(.readerGestureDefinition, .readerGestures, "keybinding.gesture.definition", [
                .click([.command]),
            ]),
            def(.readerGestureSymbolDoc, .readerGestures, "app.menu.show.symbol.documentation", [
                .click([.option]),
            ]),
            def(.readerGestureTypeDefinition, .readerGestures, "app.menu.type.definition", [
                .click([.command, .shift]),
            ]),

            def(.panelMoveSelection, .panels, "keybinding.panel.move", [
                fixed(none, .special(.up)),
                fixed(none, .special(.down)),
            ]),
            def(.panelOpenSelection, .panels, "keybinding.panel.open", [
                fixed(none, .special(.return)),
            ]),
            def(.panelClosePanel, .panels, "keybinding.panel.close", [
                fixed(none, .special(.escape)),
            ]),
        ])
    }()
}

/// K-R2.1–K-R2.4 validation result for a recorded binding.
public enum KeyBindingValidation: Equatable, Sendable {
    case ok
    /// No ⌘/⌃/⌥ modifier (K-R2.1) or a modifier-less click (K-R2.4).
    case needsModifier
    /// Occupies a locked system chord (K-R2.2).
    case locked
    /// The command already carries this exact binding.
    case duplicateOnSameCommand
    /// Another command already carries the binding.
    case conflict(with: CommandID)
}

/// Effective bindings for a scheme: defaults plus the override layer. The
/// model stays AppKit-free; NSEvent conversion lives in the App target.
public struct KeyBindingTable: Sendable {
    public var displayString: @Sendable (KeyBinding) -> String

    private let scheme: KeyBindingScheme
    public private(set) var overrides: [CommandID: [KeyBinding]]
    private let definitionsByID: [CommandID: CommandDefinition]

    public init(scheme: KeyBindingScheme, overrides: [CommandID: [KeyBinding]] = [:]) {
        self.scheme = scheme
        self.overrides = overrides
        self.definitionsByID = Dictionary(
            uniqueKeysWithValues: scheme.commands.map { ($0.id, $0) })
        self.displayString = Self.defaultDisplayString
    }

    public var schemeID: String { scheme.id }

    public var commands: [CommandDefinition] { scheme.commands }

    public func definition(for id: CommandID) -> CommandDefinition? {
        definitionsByID[id]
    }

    public func titleKey(for id: CommandID) -> String? {
        definitionsByID[id]?.titleKey
    }

    /// Effective bindings: the override when present, otherwise the defaults.
    public func bindings(for id: CommandID) -> [KeyBinding] {
        overrides[id] ?? definitionsByID[id]?.defaults ?? []
    }

    /// Commands whose effective bindings differ from the scheme defaults.
    public var modifiedCommands: [CommandID] {
        scheme.commands
            .filter { command in overrides[command.id] != nil }
            .map(\.id)
    }

    /// K-R1.4: an override is only kept while it differs from the defaults;
    /// setting bindings back to the default deletes the override.
    public mutating func setBindings(_ bindings: [KeyBinding], for id: CommandID) {
        if bindings.isEmpty, definitionsByID[id]?.defaults.isEmpty ?? true {
            overrides[id] = nil
        } else if bindings == definitionsByID[id]?.defaults {
            overrides[id] = nil
        } else {
            overrides[id] = bindings
        }
    }

    /// Drops one command's override (K-R2.3 "恢复").
    public mutating func reset(_ id: CommandID) {
        overrides[id] = nil
    }

    /// Restores every command to the scheme defaults.
    public mutating func resetAll() {
        overrides = [:]
    }

    /// K-R2.3 "替换": removes `binding` from `other` and adds it to `id` as
    /// one atomic step, so both commands end up in the override layer.
    public mutating func replace(
        _ binding: KeyBinding, for id: CommandID, takingFrom other: CommandID
    ) {
        var otherBindings = bindings(for: other).filter { $0 != binding }
        setBindings(otherBindings, for: other)
        var ownBindings = bindings(for: id)
        ownBindings.append(binding)
        setBindings(ownBindings, for: id)
    }

    /// Locked system chords (K-R2.2): occupying commands cannot be rebound
    /// and no other command may record them.
    public static let lockedKeyboardChords: Set<KeyChord> = [
        KeyChord(modifiers: [.command], key: .character("q")),
        KeyChord(modifiers: [.command], key: .character("w")),
        KeyChord(modifiers: [.command], key: .character("c")),
        KeyChord(modifiers: [.command], key: .character("v")),
        KeyChord(modifiers: [.command], key: .character("a")),
        KeyChord(modifiers: [.command], key: .character("x")),
        KeyChord(modifiers: [.command], key: .character(",")),
    ]

    public func isLocked(_ binding: KeyBinding) -> Bool {
        guard let chord = binding.chord, case .keyboard = binding else { return false }
        return Self.lockedKeyboardChords.contains(chord)
    }

    /// Recording validation (K-R2.1–K-R2.4). Keyboard chords need ⌘/⌃/⌥;
    /// click gestures need at least one modifier and conflict only among
    /// themselves.
    public func validate(_ binding: KeyBinding, for id: CommandID) -> KeyBindingValidation {
        switch binding {
        case let .keyboard(chord):
            if Self.lockedKeyboardChords.contains(chord) { return .locked }
            if !chord.modifiers.contains(.command)
                && !chord.modifiers.contains(.control)
                && !chord.modifiers.contains(.option)
            {
                return .needsModifier
            }
        case let .click(modifiers):
            if modifiers.isEmpty { return .needsModifier }
        case .fixed:
            // Fixed panel keys are read-only and never re-recorded.
            return .locked
        }
        if bindings(for: id).contains(binding) { return .duplicateOnSameCommand }
        if let other = commands(boundTo: binding).first(where: { $0 != id }) {
            return .conflict(with: other)
        }
        return .ok
    }

    /// Every command whose effective bindings contain `binding`, in scheme order.
    public func commands(boundTo binding: KeyBinding) -> [CommandID] {
        scheme.commands.filter { command in
            bindings(for: command.id).contains(binding)
        }.map(\.id)
    }

    /// Duplicated bindings across commands: keyboard chords among themselves
    /// and click gestures among themselves (K-R2.5). Fixed keys are per-panel
    /// and never conflict.
    public func conflicts() -> [(KeyBinding, [CommandID])] {
        var keyboard: [KeyChord: [CommandID]] = [:]
        var clicks: [Set<KeyChord.Modifier>: [CommandID]] = [:]
        for command in scheme.commands {
            for binding in bindings(for: command.id) {
                switch binding {
                case let .keyboard(chord): keyboard[chord, default: []].append(command.id)
                case let .click(modifiers): clicks[modifiers, default: []].append(command.id)
                case .fixed: break
                }
            }
        }
        func grouped<U: Hashable>(_ map: [U: [CommandID]], order: (U) -> String)
            -> [(U, [CommandID])]
        {
            map.filter { $0.value.count > 1 }
                .sorted { order($0.key) < order($1.key) }
        }
        return grouped(keyboard) { $0.canonicalString }.map { (KeyBinding.keyboard($0.0), $0.1) }
            + grouped(clicks) { $0.map(\.rawValue).sorted().joined(separator: "+") }
                .map { (KeyBinding.click($0.0), $0.1) }
    }

    private static func defaultDisplayString(_ binding: KeyBinding) -> String {
        switch binding {
        case let .keyboard(chord), let .fixed(chord):
            display(chord)
        case let .click(modifiers):
            displayModifiers(modifiers) + " + " + localized("keybinding.click.word")
        }
    }

    private static func display(_ chord: KeyChord) -> String {
        displayModifiers(chord.modifiers) + displayKey(chord.key)
    }

    private static func displayModifiers(_ modifiers: Set<KeyChord.Modifier>) -> String {
        // macOS display order (K-R2.6): ⌃⌥⇧⌘.
        [KeyChord.Modifier.control, .option, .shift, .command]
            .filter { modifiers.contains($0) }
            .map { modifier -> String in
                switch modifier {
                case .control: "⌃"
                case .option: "⌥"
                case .shift: "⇧"
                case .command: "⌘"
                }
            }
            .joined()
    }

    private static func displayKey(_ key: KeyChord.Key) -> String {
        switch key {
        case let .character(character):
            character.count == 1 && character.first?.isLetter == true
                ? character.uppercased() : character
        case let .special(special):
            switch special {
            case .left: "←"
            case .right: "→"
            case .up: "↑"
            case .down: "↓"
            case .return: "⏎"
            case .escape: "⎋"
            case .space: "␣"
            case .delete: "⌫"
            case .tab: "⇥"
            }
        }
    }
}

/// K-R1.4 persistence: the override layer as JSON
/// `[CommandID.rawValue: [canonical chord strings]]` in UserDefaults.
/// Unknown command IDs and unparseable strings are dropped individually so
/// one bad entry never discards the rest of the user's customizations.
public struct KeyBindingStore: Sendable {
    public static let overridesKey = "keyBindings.v1.overrides"

    private let defaults: @Sendable () -> UserDefaults

    public init(defaults: @autoclosure @escaping @Sendable () -> UserDefaults) {
        self.defaults = defaults
    }

    private var userDefaults: UserDefaults { defaults() }

    public func load() -> [CommandID: [KeyBinding]] {
        guard let raw = userDefaults.string(forKey: Self.overridesKey),
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return [:] }
        var result: [CommandID: [KeyBinding]] = [:]
        for (rawID, rawBindings) in decoded {
            let id = CommandID(rawValue: rawID)
            guard KeyBindingScheme.default.commands.contains(where: { $0.id == id }) else {
                continue
            }
            var bindings: [KeyBinding] = []
            for rawBinding in rawBindings {
                if let chord = KeyChord(canonicalString: rawBinding) {
                    bindings.append(.keyboard(chord))
                } else if let click = Self.parseClick(rawBinding) {
                    bindings.append(.click(click))
                }
                // Unparseable strings are dropped; the rest survive.
            }
            result[id] = bindings
        }
        return result
    }

    public func save(_ overrides: [CommandID: [KeyBinding]]) {
        let encoded: [String: [String]] = Dictionary(
            uniqueKeysWithValues: overrides.map { id, bindings in
                (
                    id.rawValue,
                    bindings.map { binding -> String in
                        switch binding {
                        case let .keyboard(chord), let .fixed(chord): chord.canonicalString
                        case let .click(modifiers):
                            modifiers.map(\.rawValue).sorted().joined(separator: "+") + "+click"
                        }
                    }
                )
            }
        )
        guard let data = try? JSONEncoder().encode(encoded),
              let raw = String(data: data, encoding: .utf8)
        else { return }
        userDefaults.set(raw, forKey: Self.overridesKey)
    }

    private static func parseClick(_ raw: String) -> Set<KeyChord.Modifier>? {
        guard raw.hasSuffix("+click") else { return nil }
        let parts = raw.dropLast("+click".count)
            .components(separatedBy: "+")
            .filter { !$0.isEmpty }
        var modifiers: Set<KeyChord.Modifier> = []
        for part in parts {
            guard let modifier = KeyChord.Modifier(rawValue: part) else { return nil }
            modifiers.insert(modifier)
        }
        return modifiers
    }
}
