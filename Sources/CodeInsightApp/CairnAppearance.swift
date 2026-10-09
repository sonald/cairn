import AppKit
import CodeInsightReaderCore

/// The AppKit appearance a Cairn theme implies; Auto follows the system.
@MainActor
func cairnAppearance(for theme: ReaderSettings.Theme) -> NSAppearance? {
    switch ReaderTheme(settings: ReaderSettings(theme: theme)).variant {
    case .dark: NSAppearance(named: .darkAqua)
    case .light: NSAppearance(named: .aqua)
    case nil: nil
    }
}
