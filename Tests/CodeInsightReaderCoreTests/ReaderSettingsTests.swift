import CodeInsightReaderCore
import Foundation
import Testing

@Test
func readerSettingsHaveValidatedDefaultsAndClampOutOfRangeValues() {
    #expect(ReaderSettings() == ReaderSettings(
        lineHeightMultiple: 1.3,
        fontSize: 13,
        functionNameDelta: 4.5,
        typeNameDelta: 2,
        parameterReferenceAlpha: 0.9,
        declarationMarkerAlpha: 0.7,
        functionDeclarationFontWeight: 0.23,
        declarationEmphasisFontWeight: 0.23,
        theme: .auto,
        syntaxFormatting: true,
        humanistComments: true,
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
        functionNameDelta: 12,
        typeNameDelta: 9
    )
    #expect(high.lineHeightMultiple == 2)
    #expect(high.fontSize == 24)
    #expect(high.functionNameDelta == 8)
    #expect(high.typeNameDelta == 6)

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
func readerThemePaletteMeetsRequiredContrastRatios() {
    let entries = ThemeCatalog.entries.filter { $0.source != .user }
    #expect(entries.filter { $0.source == .bundled }.count == 10)
    for entry in entries {
        for quiet in [true, false] {
            var settings = ReaderSettings(theme: entry.theme)
            settings.quietSyntax = quiet
            let theme = ReaderTheme(settings: settings)
            let selection = "\(entry.theme.id) quiet=\(quiet)"
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
                let background = theme.backgroundRGB(isDark: isDark)
                let syntaxKinds: [HighlightKind] = [
                    .comment, .keyword, .string, .number, .functionName, .typeName, .property, .macro,
                ]
                let syntaxChecks = syntaxKinds.map {
                    ("\($0)/background", theme.rgb(for: $0, isDark: isDark), background, 3.0)
                }
                let slotChecks = (UInt8(1)...ReaderTheme.highlightSlotCount).map {
                    ("highlight\($0)/background", theme.highlightRGB(slot: $0, isDark: isDark), background, 1.15)
                }
                for (name, foreground, background, minimum) in checks + syntaxChecks + slotChecks {
                    let ratio = contrastRatio(foreground, background)
                    #expect(
                        ratio >= minimum,
                        "\(selection) isDark=\(isDark) \(name) ratio=\(ratio), minimum=\(minimum)"
                    )
                }
            }
        }
    }

    // Spot values the base16 mapping prototype produced (2026-10-09):
    // contrast alone would not catch a reversed blend or the wrong toning target.
    func mapped(_ id: String, quiet: Bool = true) -> ReaderTheme {
        var settings = ReaderSettings(theme: .init(id: id))
        settings.quietSyntax = quiet
        return ReaderTheme(settings: settings)
    }
    #expect(mapped("base16:catppuccin-latte").warningRGB(isDark: false) == 0x715E56)
    #expect(mapped("base16:catppuccin-latte").rgb(for: .functionName, isDark: false) == 0xB97B74)
    #expect(mapped("base16:solarized-light").chromeSecondaryRGB(isDark: false) == 0x576C73)
    // Nord tones toward base06, not its cyan base07.
    #expect(mapped("base16:nord").inferredRGB(isDark: true) == 0x9FB8CF)
    #expect(mapped("base16:dracula").unresolvedRGB(isDark: true) == 0xFF7676)
    #expect(mapped("base16:nord", quiet: false).rgb(for: .property, isDark: true) == 0xBF616A)
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

@Test
func readerSettingsAdoptRedesignDefaultsOnceWhereOldDefaultsWereStored() throws {
    let suite = "ReaderSettingsTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    // What every save before the redesign wrote: the old defaults, no revision.
    defaults.set(0.0, forKey: "reader.functionNameDelta")
    defaults.set(false, forKey: "reader.humanistComments")
    defaults.set(15.0, forKey: "reader.fontSize")
    let migrated = ReaderSettings(defaults: defaults)
    #expect(migrated.functionNameDelta == 4.5)
    #expect(migrated.humanistComments)
    #expect(migrated.typeNameDelta == 2)
    #expect(migrated.fontSize == 15)

    // A value the user changed away from the old default is kept.
    defaults.set(2.0, forKey: "reader.functionNameDelta")
    #expect(ReaderSettings(defaults: defaults).functionNameDelta == 2)

    // After one save the revision is recorded; a later explicit 0 / off sticks.
    var chosen = migrated
    chosen.functionNameDelta = 0
    chosen.humanistComments = false
    chosen.typeNameDelta = 5
    chosen.save(to: defaults)
    let reloaded = ReaderSettings(defaults: defaults)
    #expect(reloaded.functionNameDelta == 0)
    #expect(!reloaded.humanistComments)
    #expect(reloaded.typeNameDelta == 5)
    #expect(ReaderTheme(settings: reloaded).typeNameFontSize == 15 + 5)
}

@Test
func readerSettingsValidateStoredThemeIdsAndTheAutoPair() throws {
    let suite = "ReaderSettingsTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let fresh = ReaderSettings(defaults: defaults)
    #expect(fresh.quietSyntax)
    #expect(fresh.autoLightTheme == .light)
    #expect(fresh.autoDarkTheme == .dark)

    var chosen = fresh
    chosen.theme = .init(id: "base16:nord")
    chosen.autoLightTheme = .init(id: "base16:catppuccin-latte")
    chosen.autoDarkTheme = .init(id: "base16:catppuccin-mocha")
    chosen.quietSyntax = false
    chosen.save(to: defaults)
    #expect(ReaderSettings(defaults: defaults) == chosen)

    // A deleted theme file: the stored id is unknown, so Auto, saved back as Auto.
    defaults.set("base16:deleted", forKey: "reader.theme")
    // Slots: an unknown id, and a dark theme stored in the light slot.
    defaults.set("base16:also-deleted", forKey: "reader.theme.dark")
    defaults.set("base16:nord", forKey: "reader.theme.light")
    let reloaded = ReaderSettings(defaults: defaults)
    #expect(reloaded.theme == .auto)
    #expect(reloaded.autoLightTheme == .light)
    #expect(reloaded.autoDarkTheme == .dark)
    reloaded.save(to: defaults)
    #expect(defaults.string(forKey: "reader.theme") == "Auto")

    // Auto resolves through the pair: Latte under light, Mocha under dark.
    var auto = ReaderSettings()
    auto.autoLightTheme = .init(id: "base16:catppuccin-latte")
    auto.autoDarkTheme = .init(id: "base16:catppuccin-mocha")
    let theme = ReaderTheme(settings: auto)
    #expect(theme.variant == nil)
    #expect(theme.backgroundRGB(isDark: false) == 0xEFF1F5)
    #expect(theme.backgroundRGB(isDark: true) == 0x1E1E2E)
}
