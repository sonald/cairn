import AppKit
import CodeInsightReaderCore

/// The AppKit appearance a resolved theme variant implies; nil (Auto)
/// follows the system.
@MainActor
func cairnAppearance(for variant: ThemePalette.Variant?) -> NSAppearance? {
    switch variant {
    case .dark: NSAppearance(named: .darkAqua)
    case .light: NSAppearance(named: .aqua)
    case nil: nil
    }
}
