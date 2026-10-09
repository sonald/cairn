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
        /// Built-in and bundled entries; never change after launch.
        let fixed: [ThemeEntry]
        var user: [ThemeEntry] = []

        init(fixed: [ThemeEntry]) {
            self.fixed = fixed
        }
    }

    // ponytail: bundled schemes load on first use, so every caller (tests,
    // self-tests, the app) sees them without a startup step.
    private static let store = Store(fixed: builtInEntries + bundledEntries)

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

    private static var bundledEntries: [ThemeEntry] {
        guard let folder = Bundle.module.url(forResource: "Themes", withExtension: nil) else {
            return []
        }
        return entries(in: folder, source: .bundled)
    }

    /// Built-in, bundled, then user themes.
    public static var entries: [ThemeEntry] {
        store.lock.withLock { store.fixed + store.user }
    }

    public static func entry(for theme: ReaderSettings.Theme) -> ThemeEntry? {
        entries.first { $0.theme == theme }
    }

    /// Replaces the user themes with the base16 files now in `folder`. A
    /// missing folder means no user themes.
    public static func reloadUserThemes(in folder: URL) {
        let fixedIDs = Set(store.fixed.map(\.theme))
        let found = entries(in: folder, source: .user).filter { entry in
            guard fixedIDs.contains(entry.theme) else { return true }
            logSkipped(entry.theme.id, "the id is already taken by a bundled theme")
            return false
        }
        store.lock.withLock { store.user = found }
    }

    /// Every readable base16 `.yaml` in `folder`, sorted by name; other files
    /// are skipped with one log line each.
    static func entries(in folder: URL, source: ThemeEntry.Source) -> [ThemeEntry] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil
        )) ?? []
        return files
            .filter { $0.pathExtension == "yaml" }
            .compactMap { file -> ThemeEntry? in
                let id = "base16:" + file.deletingPathExtension().lastPathComponent
                do {
                    let scheme = try Base16Scheme.load(contentsOf: file)
                    return ThemeEntry(
                        theme: ReaderSettings.Theme(id: id),
                        name: scheme.name.isEmpty ? id : scheme.name,
                        source: source,
                        quietPalette: ThemePalette(scheme: scheme, quiet: true),
                        fullPalette: ThemePalette(scheme: scheme, quiet: false)
                    )
                } catch {
                    logSkipped(file.path, "\(error)")
                    return nil
                }
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func logSkipped(_ what: String, _ reason: String) {
        FileHandle.standardError.write(Data("CodeInsightReaderCore: skipped theme \(what): \(reason)\n".utf8))
    }
}
