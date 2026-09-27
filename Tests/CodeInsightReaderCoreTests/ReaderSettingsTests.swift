import CodeInsightReaderCore
import Foundation
import Testing

@Test
func readerSettingsHaveValidatedDefaultsAndClampOutOfRangeValues() {
    #expect(ReaderSettings() == ReaderSettings(
        lineHeightMultiple: 1.3,
        fontSize: 13,
        functionNameDelta: 0,
        parameterReferenceAlpha: 0.9,
        declarationMarkerAlpha: 0.7,
        functionDeclarationFontWeight: 0.23,
        declarationEmphasisFontWeight: 0.23,
        theme: .auto,
        syntaxFormatting: true,
        humanistComments: false,
        lineNumbers: true
    ))

    let low = ReaderSettings(
        lineHeightMultiple: 0,
        fontSize: 5,
        functionNameDelta: -2
    )
    #expect(low.lineHeightMultiple == 1)
    #expect(low.fontSize == 10)
    #expect(low.functionNameDelta == 0)

    let high = ReaderSettings(
        lineHeightMultiple: 3,
        fontSize: 30,
        functionNameDelta: 8
    )
    #expect(high.lineHeightMultiple == 2)
    #expect(high.fontSize == 24)
    #expect(high.functionNameDelta == 4)

    var mutated = ReaderSettings()
    mutated.lineHeightMultiple = 9
    mutated.fontSize = 1
    mutated.functionNameDelta = -1
    #expect(mutated.lineHeightMultiple == 2)
    #expect(mutated.fontSize == 10)
    #expect(mutated.functionNameDelta == 0)
    #expect(!mutated.wrapLines)
}

@Test
func readerVisualSettingsKeepReadableDefaultsAndClampEveryBoundary() {
    let defaults = ReaderSettings()
    #expect(defaults.parameterReferenceAlpha == 0.9)
    #expect(defaults.declarationMarkerAlpha == 0.7)
    #expect(defaults.functionDeclarationFontWeight == 0.23)
    #expect(defaults.declarationEmphasisFontWeight == 0.23)

    let low = ReaderSettings(
        parameterReferenceAlpha: -1,
        declarationMarkerAlpha: -1,
        functionDeclarationFontWeight: -2,
        declarationEmphasisFontWeight: -2
    )
    #expect(low.parameterReferenceAlpha == 0)
    #expect(low.declarationMarkerAlpha == 0)
    #expect(low.functionDeclarationFontWeight == -1)
    #expect(low.declarationEmphasisFontWeight == -1)

    let high = ReaderSettings(
        parameterReferenceAlpha: 2,
        declarationMarkerAlpha: 2,
        functionDeclarationFontWeight: 2,
        declarationEmphasisFontWeight: 2
    )
    #expect(high.parameterReferenceAlpha == 1)
    #expect(high.declarationMarkerAlpha == 1)
    #expect(high.functionDeclarationFontWeight == 1)
    #expect(high.declarationEmphasisFontWeight == 1)

    var mutated = ReaderSettings()
    mutated.parameterReferenceAlpha = -1
    mutated.declarationMarkerAlpha = 2
    mutated.functionDeclarationFontWeight = -2
    mutated.declarationEmphasisFontWeight = 2
    #expect(mutated.parameterReferenceAlpha == 0)
    #expect(mutated.declarationMarkerAlpha == 1)
    #expect(mutated.functionDeclarationFontWeight == -1)
    #expect(mutated.declarationEmphasisFontWeight == 1)
}

@Test
func readerSettingsPersistRoundTripThroughInjectedUserDefaults() throws {
    let suite = "ReaderSettingsTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let missingKeys = ReaderSettings(defaults: defaults)
    #expect(missingKeys.parameterReferenceAlpha == 0.9)
    #expect(missingKeys.declarationMarkerAlpha == 0.7)
    #expect(missingKeys.functionDeclarationFontWeight == 0.23)
    #expect(missingKeys.declarationEmphasisFontWeight == 0.23)
    #expect(missingKeys.syntaxFormatting)
    #expect(missingKeys.lineNumbers)
    #expect(!missingKeys.wrapLines)
    var expected = ReaderSettings(
        lineHeightMultiple: 1.6,
        fontSize: 17,
        functionNameDelta: 2,
        parameterReferenceAlpha: 0.41,
        declarationMarkerAlpha: 0.62,
        functionDeclarationFontWeight: 0,
        declarationEmphasisFontWeight: 0.4,
        theme: .siClassic,
        syntaxFormatting: false,
        humanistComments: true,
        lineNumbers: false
    )
    expected.wrapLines = true

    expected.save(to: defaults)

    #expect(ReaderSettings(defaults: defaults) == expected)
}

@Test
func readerThemeDerivesSIClassicPaletteAndTypographyFromSettings() {
    let theme = ReaderTheme(settings: ReaderSettings(
        lineHeightMultiple: 1.5,
        fontSize: 16,
        functionNameDelta: 2,
        theme: .siClassic,
        syntaxFormatting: false,
        humanistComments: true,
        lineNumbers: false
    ))

    #expect(theme.lineHeightMultiple == 1.5)
    #expect(theme.fontSize == 16)
    #expect(theme.functionNameFontSize == 18)
    #expect(!theme.syntaxFormatting)
    #expect(theme.humanistComments)
    #expect(theme.backgroundRGB(isDark: false) == 0xFFFFFF)
    #expect(theme.backgroundRGB(isDark: true) == 0xFFFFFF)
    #expect(theme.foregroundRGB(isDark: false) == 0x111111)
    #expect(theme.rgb(for: .keyword, isDark: false) == 0x00008B)
    #expect(theme.rgb(for: .functionName, isDark: false) == 0x000000)

    let light = ReaderTheme(settings: ReaderSettings(theme: .light))
    let dark = ReaderTheme(settings: ReaderSettings(theme: .dark))
    #expect(light.backgroundRGB(isDark: true) == 0xFBFAF6)
    #expect(dark.backgroundRGB(isDark: false) == 0x121614)
}

@Test
func readerThemeProvidesChromeSurfacesForEveryExplicitTheme() {
    let light = ReaderTheme(settings: ReaderSettings(theme: .light))
    #expect(light.chromeSelectionRGB(isDark: false) == 0xDCE7E0)
    #expect(light.chromeSecondaryRGB(isDark: false) == 0x5C645F)
    #expect(light.verifiedRGB(isDark: false) == 0x2B5849)
    #expect(light.inferredRGB(isDark: false) == 0x3A5873)
    #expect(light.unresolvedRGB(isDark: false) == 0x9B3D27)
    #expect(light.unresolvedBorderRGB(isDark: false) == 0x9B3D27)
    #expect(light.warningRGB(isDark: false) == 0x8A5610)
    #expect(light.warningBorderRGB(isDark: false) == 0xC98A2E)
    #expect(light.warningFillAlpha(isDark: false) == 0.10)
    #expect(light.chipBackgroundRGB(isDark: false) == 0xE7E3DA)
    #expect(light.amberMarkRGB(isDark: false) == 0xC98A2E)
    #expect(light.amberSoftRGB(isDark: false) == 0xF3E5CA)
    #expect(light.histRGB(isDark: false) == 0x7A5A2C)
    #expect(light.histSoftRGB(isDark: false) == 0xEFE4CC)
    #expect(light.histReaderRGB(isDark: false) == 0xFAF5EA)
    #expect(light.mossSoftRGB(isDark: false) == 0xDCE7E0)
    #expect(light.slateSoftRGB(isDark: false) == 0xDFE6ED)
    #expect(light.rustSoftRGB(isDark: false) == 0xF4DFD7)
    #expect(light.primarySelectionFillAlpha(isDark: false) == 0.13)

    let dark = ReaderTheme(settings: ReaderSettings(theme: .dark))
    #expect(dark.chromeRGB(isDark: true) == 0x161A18)
    #expect(dark.chromeHeaderRGB(isDark: true) == 0x1D221F)
    #expect(dark.chromeDividerRGB(isDark: true) == 0x2B312D)
    #expect(dark.accentRGB(isDark: true) == 0x8CC6A9)
    #expect(dark.verifiedRGB(isDark: true) == 0x8CC6A9)
    #expect(dark.inferredFillAlpha(isDark: true) == 0.18)
    #expect(dark.unresolvedRGB(isDark: true) == 0xE8927A)
    #expect(dark.unresolvedBorderRGB(isDark: true) == 0xE8927A)
    #expect(dark.warningRGB(isDark: true) == 0xE6AE5A)
    #expect(dark.warningBorderRGB(isDark: true) == 0x7A5A2C)
    #expect(dark.histReaderRGB(isDark: true) == 0x17140F)
    #expect(dark.warningFillAlpha(isDark: true) == 0.15)
    #expect(dark.primarySelectionFillAlpha(isDark: true) == 0.20)

    let classic = ReaderTheme(settings: ReaderSettings(theme: .siClassic))
    #expect(classic.chromeRGB(isDark: false) == 0xEFEFEA)
    #expect(classic.chromeHeaderRGB(isDark: false) == 0xE0E0DA)
    #expect(classic.chromeSelectionRGB(isDark: false) == 0xFFF1C2)
    #expect(classic.accentRGB(isDark: false) == 0x1D3A8F)
    #expect(classic.chipForegroundRGB(isDark: false) == 0x555555)
    #expect(classic.unresolvedRGB(isDark: false) == 0xA01E1E)
    #expect(classic.unresolvedBorderRGB(isDark: false) == 0xA01E1E)
    #expect(classic.warningRGB(isDark: false) == 0x8A6100)
    #expect(classic.warningBorderRGB(isDark: false) == 0xC9A227)
    #expect(classic.rustSoftRGB(isDark: false) == 0xF7DEDE)
    #expect(classic.warningFillAlpha(isDark: false) == 0.12)
    #expect(classic.verifiedFillAlpha(isDark: false) == 0.15)
    #expect(classic.primarySelectionFillAlpha(isDark: false) == 0.12)
}

@Test
func readerThemeProvidesDistinctDiffColorsForEveryTheme() {
    for selection in ReaderSettings.Theme.allCases {
        let theme = ReaderTheme(settings: ReaderSettings(theme: selection))
        let isDark = selection == .dark
        let colors = Set([
            theme.diffRGB(for: .added, isDark: isDark),
            theme.diffRGB(for: .removed, isDark: isDark),
            theme.diffRGB(for: .changed, isDark: isDark),
        ])
        #expect(colors.count == 3)
        #expect(theme.lineNumberRGB(isDark: isDark) != theme.foregroundRGB(isDark: isDark))
        #expect(theme.currentLineRGB(isDark: isDark) != theme.backgroundRGB(isDark: isDark))
        #expect(theme.occurrenceRGB(isDark: isDark) != theme.backgroundRGB(isDark: isDark))
    }
}

@Test
func readerThemePaletteMeetsRequiredContrastRatios() {
    for selection in ReaderSettings.Theme.allCases {
        let theme = ReaderTheme(settings: ReaderSettings(theme: selection))
        for isDark in [false, true] {
            let checks: [(String, UInt32, UInt32, Double)] = [
                ("foreground/background", theme.foregroundRGB(isDark: isDark), theme.backgroundRGB(isDark: isDark), 4.5),
                ("chromeSecondary/chrome", theme.chromeSecondaryRGB(isDark: isDark), theme.chromeRGB(isDark: isDark), 4.5),
                ("verified/chrome", theme.verifiedRGB(isDark: isDark), theme.chromeRGB(isDark: isDark), 4.5),
                ("verified/mossSoft", theme.verifiedRGB(isDark: isDark), theme.mossSoftRGB(isDark: isDark), 4.5),
                ("inferred/chrome", theme.inferredRGB(isDark: isDark), theme.chromeRGB(isDark: isDark), 4.5),
                ("inferred/slateSoft", theme.inferredRGB(isDark: isDark), theme.slateSoftRGB(isDark: isDark), 4.5),
                ("unresolved/chrome", theme.unresolvedRGB(isDark: isDark), theme.chromeRGB(isDark: isDark), 4.5),
                ("unresolved/rustSoft", theme.unresolvedRGB(isDark: isDark), theme.rustSoftRGB(isDark: isDark), 4.5),
                ("warning/chrome", theme.warningRGB(isDark: isDark), theme.chromeRGB(isDark: isDark), 4.5),
                ("warning/amberSoft", theme.warningRGB(isDark: isDark), theme.amberSoftRGB(isDark: isDark), 4.5),
                ("hist/histSoft", theme.histRGB(isDark: isDark), theme.histSoftRGB(isDark: isDark), 4.5),
                ("lineNumber/background", theme.lineNumberRGB(isDark: isDark), theme.backgroundRGB(isDark: isDark), 3.0),
                ("chromeTertiary/chrome", theme.chromeTertiaryRGB(isDark: isDark), theme.chromeRGB(isDark: isDark), 3.0),
            ]
            for (name, foreground, background, minimum) in checks {
                let ratio = contrastRatio(foreground, background)
                #expect(
                    ratio >= minimum,
                    "\(selection.rawValue) isDark=\(isDark) \(name) ratio=\(ratio), minimum=\(minimum)"
                )
            }
        }
    }
}

private func contrastRatio(_ first: UInt32, _ second: UInt32) -> Double {
    let lighter = max(relativeLuminance(first), relativeLuminance(second))
    let darker = min(relativeLuminance(first), relativeLuminance(second))
    return (lighter + 0.05) / (darker + 0.05)
}

private func relativeLuminance(_ rgb: UInt32) -> Double {
    let red = linearComponent(Double((rgb >> 16) & 0xff) / 255)
    let green = linearComponent(Double((rgb >> 8) & 0xff) / 255)
    let blue = linearComponent(Double(rgb & 0xff) / 255)
    return 0.2126 * red + 0.7152 * green + 0.0722 * blue
}

private func linearComponent(_ value: Double) -> Double {
    value <= 0.04045
        ? value / 12.92
        : pow((value + 0.055) / 1.055, 2.4)
}
