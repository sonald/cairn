@preconcurrency import AppKit
import CodeInsightReaderCore

private func readerThemePaletteColor(
    _ value: @escaping @Sendable (Bool) -> UInt32
) -> NSColor {
    NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let rgb = value(isDark)
        return NSColor(
            red: CGFloat((rgb >> 16) & 0xff) / 255,
            green: CGFloat((rgb >> 8) & 0xff) / 255,
            blue: CGFloat(rgb & 0xff) / 255,
            alpha: 1
        )
    }
}

@MainActor
public extension ReaderTheme {
    var amberMarkColor: NSColor {
        readerThemePaletteColor(amberMarkRGB(isDark:))
    }

    var amberSoftColor: NSColor {
        readerThemePaletteColor(amberSoftRGB(isDark:))
    }

    var histColor: NSColor {
        readerThemePaletteColor(histRGB(isDark:))
    }

    var histSoftColor: NSColor {
        readerThemePaletteColor(histSoftRGB(isDark:))
    }

    var histReaderColor: NSColor {
        readerThemePaletteColor(histReaderRGB(isDark:))
    }

    var mossSoftColor: NSColor {
        readerThemePaletteColor(mossSoftRGB(isDark:))
    }

    var slateSoftColor: NSColor {
        readerThemePaletteColor(slateSoftRGB(isDark:))
    }

    var rustSoftColor: NSColor {
        readerThemePaletteColor(rustSoftRGB(isDark:))
    }
}
