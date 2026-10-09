import CodeInsightReaderCore
import Foundation
import Testing

private let goldenURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Fixtures/theme-golden.json")

/// Every public color and alpha role of `theme`, keyed by role name.
private func roles(_ theme: ReaderTheme, isDark: Bool) -> [String: Double] {
    var out: [String: Double] = [:]
    func put(_ name: String, _ value: UInt32) { out[name] = Double(value) }
    for raw in UInt8(0)...15 {
        let kind = HighlightKind(rawValue: raw)!
        put("syntax.\(kind)", theme.rgb(for: kind, isDark: isDark))
    }
    for kind in [DiffCore.MarkerKind.added, .removed, .changed] {
        put("diff.\(kind)", theme.diffRGB(for: kind, isDark: isDark))
    }
    for slot in UInt8(1)...ReaderTheme.highlightSlotCount {
        put("highlight.\(slot)", theme.highlightRGB(slot: slot, isDark: isDark))
        put("overviewHighlight.\(slot)", theme.overviewHighlightRGB(slot: slot, isDark: isDark))
    }
    for index in 0..<4 {
        put("queryCondition.\(index)", theme.queryConditionRGB(index: index, isDark: isDark))
    }
    put("overviewOccurrence", theme.overviewOccurrenceRGB(isDark: isDark))
    put("background", theme.backgroundRGB(isDark: isDark))
    put("foreground", theme.foregroundRGB(isDark: isDark))
    put("lineNumber", theme.lineNumberRGB(isDark: isDark))
    put("currentLine", theme.currentLineRGB(isDark: isDark))
    put("occurrence", theme.occurrenceRGB(isDark: isDark))
    put("chrome", theme.chromeRGB(isDark: isDark))
    put("chromeHeader", theme.chromeHeaderRGB(isDark: isDark))
    put("chromeDivider", theme.chromeDividerRGB(isDark: isDark))
    put("chromeSelection", theme.chromeSelectionRGB(isDark: isDark))
    put("accent", theme.accentRGB(isDark: isDark))
    put("chromeSecondary", theme.chromeSecondaryRGB(isDark: isDark))
    put("chromeTertiary", theme.chromeTertiaryRGB(isDark: isDark))
    put("verified", theme.verifiedRGB(isDark: isDark))
    put("inferred", theme.inferredRGB(isDark: isDark))
    put("unresolved", theme.unresolvedRGB(isDark: isDark))
    put("unresolvedBorder", theme.unresolvedBorderRGB(isDark: isDark))
    put("warning", theme.warningRGB(isDark: isDark))
    put("warningBorder", theme.warningBorderRGB(isDark: isDark))
    put("chipBackground", theme.chipBackgroundRGB(isDark: isDark))
    put("chipForeground", theme.chipForegroundRGB(isDark: isDark))
    put("amberMark", theme.amberMarkRGB(isDark: isDark))
    put("amberSoft", theme.amberSoftRGB(isDark: isDark))
    put("hist", theme.histRGB(isDark: isDark))
    put("histSoft", theme.histSoftRGB(isDark: isDark))
    put("histReader", theme.histReaderRGB(isDark: isDark))
    put("mossSoft", theme.mossSoftRGB(isDark: isDark))
    put("slateSoft", theme.slateSoftRGB(isDark: isDark))
    put("rustSoft", theme.rustSoftRGB(isDark: isDark))
    out["warningFillAlpha"] = theme.warningFillAlpha(isDark: isDark)
    out["primarySelectionFillAlpha"] = theme.primarySelectionFillAlpha(isDark: isDark)
    out["verifiedFillAlpha"] = theme.verifiedFillAlpha(isDark: isDark)
    out["inferredFillAlpha"] = theme.inferredFillAlpha(isDark: isDark)
    return out
}

private func currentRoles() -> [String: [String: Double]] {
    var out: [String: [String: Double]] = [:]
    let builtIns: [ReaderSettings.Theme] = [.auto, .light, .dark, .siClassic]
    for selection in builtIns {
        let theme = ReaderTheme(settings: ReaderSettings(theme: selection))
        for isDark in [false, true] {
            out["\(selection.rawValue) isDark=\(isDark)"] = roles(theme, isDark: isDark)
        }
    }
    return out
}

/// Built-in palettes recorded before the move to `ThemePalette`; every role
/// must keep its value. Compared per role, so key order does not matter.
@Test
func builtInThemesKeepTheirRecordedPalettes() throws {
    let golden = try JSONDecoder().decode(
        [String: [String: Double]].self,
        from: Data(contentsOf: goldenURL)
    )
    let current = currentRoles()
    #expect(Set(current.keys) == Set(golden.keys))
    for (key, expected) in golden {
        let actual = current[key] ?? [:]
        #expect(Set(actual.keys) == Set(expected.keys), "\(key)")
        for (role, value) in expected {
            #expect(actual[role] == value, "\(key) \(role)")
        }
    }
}
