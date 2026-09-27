import AppKit
import CodeInsightReaderCore

/// The AppKit appearance a Cairn theme implies; Auto follows the system.
@MainActor
func cairnAppearance(for theme: ReaderSettings.Theme) -> NSAppearance? {
    switch theme {
    case .dark: NSAppearance(named: .darkAqua)
    case .light, .siClassic: NSAppearance(named: .aqua)
    case .auto: nil
    }
}
