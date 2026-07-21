import CodeInsightReaderCore
import Foundation
import Testing

@Test
func readerSettingsHaveValidatedDefaultsAndClampOutOfRangeValues() {
    #expect(ReaderSettings() == ReaderSettings(
        lineHeightMultiple: 1.25,
        fontSize: 13,
        functionNameDelta: 1,
        theme: .auto,
        humanistComments: false
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
func readerSettingsPersistRoundTripThroughInjectedUserDefaults() throws {
    let suite = "ReaderSettingsTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let expected = ReaderSettings(
        lineHeightMultiple: 1.6,
        fontSize: 17,
        functionNameDelta: 2,
        theme: .siClassic,
        humanistComments: true
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
        humanistComments: true
    ))

    #expect(theme.lineHeightMultiple == 1.5)
    #expect(theme.fontSize == 16)
    #expect(theme.functionNameFontSize == 18)
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
