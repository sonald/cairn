import CodeInsightReaderCore
import Foundation
import Testing

@Test
func readerSettingsHaveValidatedDefaultsAndClampOutOfRangeValues() {
    #expect(ReaderSettings() == ReaderSettings(
        lineHeightMultiple: 1.25,
        fontSize: 13,
        functionNameDelta: 1,
        parameterReferenceAlpha: 0.72,
        declarationMarkerAlpha: 0.7,
        functionDeclarationFontWeight: 0.3,
        declarationEmphasisFontWeight: 0.3,
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
}

@Test
func readerVisualSettingsKeepLegacyDefaultsAndClampEveryBoundary() {
    let defaults = ReaderSettings()
    #expect(defaults.parameterReferenceAlpha == 0.72)
    #expect(defaults.declarationMarkerAlpha == 0.7)
    #expect(defaults.functionDeclarationFontWeight == 0.3)
    #expect(defaults.declarationEmphasisFontWeight == 0.3)

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
    #expect(missingKeys.parameterReferenceAlpha == 0.72)
    #expect(missingKeys.declarationMarkerAlpha == 0.7)
    #expect(missingKeys.functionDeclarationFontWeight == 0.3)
    #expect(missingKeys.declarationEmphasisFontWeight == 0.3)
    #expect(missingKeys.syntaxFormatting)
    #expect(missingKeys.lineNumbers)
    let expected = ReaderSettings(
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
    #expect(theme.backgroundRGB(isDark: false) == 0xF5F0E6)
    #expect(theme.backgroundRGB(isDark: true) == 0xF5F0E6)
    #expect(theme.foregroundRGB(isDark: false) == 0x1F2733)
    #expect(theme.rgb(for: .keyword, isDark: false) == 0x7A1F1F)
    #expect(theme.rgb(for: .functionName, isDark: false) == 0x163A5F)

    let light = ReaderTheme(settings: ReaderSettings(theme: .light))
    let dark = ReaderTheme(settings: ReaderSettings(theme: .dark))
    #expect(light.backgroundRGB(isDark: true) == 0xFFFFFF)
    #expect(dark.backgroundRGB(isDark: false) == 0x1E1E1E)
}

@Test
func readerThemeProvidesChromeSurfacesForEveryExplicitTheme() {
    let light = ReaderTheme(settings: ReaderSettings(theme: .light))
    #expect(light.chromeSelectionRGB(isDark: false) == 0xE7F0FF)
    #expect(light.chromeSecondaryRGB(isDark: false) == 0x5A6472)
    #expect(light.verifiedRGB(isDark: false) == 0x1A7F37)
    #expect(light.inferredRGB(isDark: false) == 0x175CD3)
    #expect(light.chipBackgroundRGB(isDark: false) == 0xEFF1F4)
    #expect(light.primarySelectionFillAlpha(isDark: false) == 0.13)

    let dark = ReaderTheme(settings: ReaderSettings(theme: .dark))
    #expect(dark.chromeRGB(isDark: true) == 0x252528)
    #expect(dark.chromeHeaderRGB(isDark: true) == 0x2C2C30)
    #expect(dark.chromeDividerRGB(isDark: true) == 0x34363B)
    #expect(dark.accentRGB(isDark: true) == 0x84ADFF)
    #expect(dark.verifiedRGB(isDark: true) == 0x4EC777)
    #expect(dark.inferredFillAlpha(isDark: true) == 0.18)
    #expect(dark.primarySelectionFillAlpha(isDark: true) == 0.20)

    let classic = ReaderTheme(settings: ReaderSettings(theme: .siClassic))
    #expect(classic.chromeRGB(isDark: false) == 0xEEE7D6)
    #expect(classic.chromeHeaderRGB(isDark: false) == 0xE7DEC9)
    #expect(classic.chromeSelectionRGB(isDark: false) == 0xE7DAB9)
    #expect(classic.accentRGB(isDark: false) == 0x163A5F)
    #expect(classic.chipForegroundRGB(isDark: false) == 0x6E6857)
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
