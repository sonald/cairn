@preconcurrency import AppKit
import CodeInsightReaderCore

private func readerDynamicColor(
    value: @escaping @Sendable (Bool) -> UInt32,
    alpha: @escaping @Sendable (Bool) -> CGFloat
) -> NSColor {
    NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let rgb = value(isDark)
        return NSColor(
            red: CGFloat((rgb >> 16) & 0xff) / 255,
            green: CGFloat((rgb >> 8) & 0xff) / 255,
            blue: CGFloat(rgb & 0xff) / 255,
            alpha: alpha(isDark)
        )
    }
}

@MainActor
public extension ReaderTheme {
    func color(for kind: HighlightKind) -> NSColor {
        dynamicColor { isDark in rgb(for: kind, isDark: isDark) }
    }

    func color(for kind: DiffCore.MarkerKind) -> NSColor {
        dynamicColor { isDark in diffRGB(for: kind, isDark: isDark) }
    }

    var backgroundColor: NSColor {
        dynamicColor(backgroundRGB(isDark:))
    }

    var foregroundColor: NSColor {
        dynamicColor(foregroundRGB(isDark:))
    }

    var lineNumberColor: NSColor {
        dynamicColor(lineNumberRGB(isDark:))
    }

    var currentLineColor: NSColor {
        dynamicColor(currentLineRGB(isDark:))
    }

    var occurrenceColor: NSColor {
        dynamicColor(occurrenceRGB(isDark:))
    }

    func highlightColor(slot: UInt8) -> NSColor {
        dynamicColor { isDark in highlightRGB(slot: slot, isDark: isDark) }
    }

    /// Project-search condition color; drawn as an underline, never a fill.
    func queryConditionColor(index: Int) -> NSColor {
        dynamicColor { isDark in queryConditionRGB(index: index, isDark: isDark) }
    }

    func overviewHighlightColor(slot: UInt8) -> NSColor {
        dynamicColor { isDark in overviewHighlightRGB(slot: slot, isDark: isDark) }
    }

    var overviewOccurrenceColor: NSColor {
        dynamicColor(overviewOccurrenceRGB(isDark:))
    }

    var chromeColor: NSColor {
        dynamicColor(chromeRGB(isDark:))
    }

    var chromeHeaderColor: NSColor {
        dynamicColor(chromeHeaderRGB(isDark:))
    }

    var chromeDividerColor: NSColor {
        dynamicColor(chromeDividerRGB(isDark:))
    }

    var chromeSelectionColor: NSColor {
        // Custom rows keep their normal foreground, so use the matching
        // subdued theme fill rather than AppKit's white-text selection fill.
        dynamicColor(chromeSelectionRGB(isDark:))
    }

    var accentColor: NSColor {
        dynamicColor(accentRGB(isDark:))
    }

    var chromeSecondaryColor: NSColor {
        dynamicColor(chromeSecondaryRGB(isDark:))
    }

    var chromeTertiaryColor: NSColor {
        dynamicColor(chromeTertiaryRGB(isDark:))
    }

    var verifiedColor: NSColor {
        dynamicColor(verifiedRGB(isDark:))
    }

    var verifiedBackgroundColor: NSColor {
        dynamicColor(
            verifiedRGB(isDark:),
            alpha: { CGFloat(verifiedFillAlpha(isDark: $0)) }
        )
    }

    var inferredColor: NSColor {
        dynamicColor(inferredRGB(isDark:))
    }

    var inferredBackgroundColor: NSColor {
        dynamicColor(
            inferredRGB(isDark:),
            alpha: { CGFloat(inferredFillAlpha(isDark: $0)) }
        )
    }

    var unresolvedColor: NSColor {
        dynamicColor(unresolvedRGB(isDark:))
    }

    var unresolvedBorderColor: NSColor {
        dynamicColor(unresolvedBorderRGB(isDark:))
    }

    var warningColor: NSColor {
        dynamicColor(warningRGB(isDark:))
    }

    var warningBackgroundColor: NSColor {
        dynamicColor(
            warningRGB(isDark:),
            alpha: { CGFloat(warningFillAlpha(isDark: $0)) }
        )
    }

    var warningBorderColor: NSColor {
        dynamicColor(warningBorderRGB(isDark:))
    }

    var chipBackgroundColor: NSColor {
        dynamicColor(chipBackgroundRGB(isDark:))
    }

    var chipForegroundColor: NSColor {
        dynamicColor(chipForegroundRGB(isDark:))
    }

    var primarySelectionFillColor: NSColor {
        dynamicColor(
            accentRGB(isDark:),
            alpha: { CGFloat(primarySelectionFillAlpha(isDark: $0)) }
        )
    }

    private func dynamicColor(
        _ value: @escaping @Sendable (Bool) -> UInt32
    ) -> NSColor {
        dynamicColor(value, alpha: { _ in 1 })
    }

    private func dynamicColor(
        _ value: @escaping @Sendable (Bool) -> UInt32,
        alpha: @escaping @Sendable (Bool) -> CGFloat
    ) -> NSColor {
        readerDynamicColor(value: value, alpha: alpha)
    }
}
