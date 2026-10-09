import Foundation

/// One selectable theme. Auto has no palette of its own.
public struct ThemeEntry: Sendable {
    public enum Source: Sendable {
        case builtIn
        case bundled
        case user
    }

    public let theme: ReaderSettings.Theme
    /// The scheme's own name; built-in names are localized by the UI.
    public let name: String
    public let source: Source
    let quietPalette: ThemePalette?
    let fullPalette: ThemePalette?

    /// nil for Auto, which follows the system appearance.
    public var variant: ThemePalette.Variant? { fullPalette?.variant }

    func palette(quiet: Bool) -> ThemePalette? {
        quiet ? quietPalette : fullPalette
    }
}

/// Process-wide registry of selectable themes, built-ins first.
public enum ThemeCatalog {
    private final class Store: @unchecked Sendable {
        let lock = NSLock()
        var entries: [ThemeEntry]

        init(entries: [ThemeEntry]) {
            self.entries = entries
        }
    }

    private static let store = Store(entries: builtInEntries)

    private static var builtInEntries: [ThemeEntry] {
        func builtIn(_ theme: ReaderSettings.Theme, _ palette: ThemePalette?) -> ThemeEntry {
            ThemeEntry(
                theme: theme,
                name: theme.id,
                source: .builtIn,
                quietPalette: palette,
                fullPalette: palette
            )
        }
        return [
            builtIn(.auto, nil),
            builtIn(.light, .light),
            builtIn(.dark, .dark),
            builtIn(.siClassic, .siClassic),
        ]
    }

    public static var entries: [ThemeEntry] {
        store.lock.withLock { store.entries }
    }

    public static func entry(for theme: ReaderSettings.Theme) -> ThemeEntry? {
        store.lock.withLock { store.entries.first { $0.theme == theme } }
    }
}
