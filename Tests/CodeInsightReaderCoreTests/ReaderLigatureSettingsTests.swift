import CodeInsightReaderCore
import Foundation
import Testing

@Test
func readerLigatureSettingsDefaultAndRoundTrip() throws {
    let suite = "ReaderLigatureSettingsTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let original = ReaderSettings(defaults: defaults)
    #expect(original.codeFont == .systemMonospaced)
    #expect(original.codeLigatures == .fontDefault)

    for mode in CodeLigatureMode.allCases {
        for font in [CodeFontSelection.systemMonospaced, .postScriptName("MissingFont-Regular")] {
            let settings = ReaderSettings(fontSize: 17, codeFont: font, codeLigatures: mode)
            settings.save(to: defaults)
            #expect(ReaderSettings(defaults: defaults) == settings)
        }
    }
    ReaderSettings().save(to: defaults)
    #expect(defaults.string(forKey: "reader.codeFont.kind") == "systemMonospaced")
    #expect(defaults.object(forKey: "reader.codeFont.postScriptName") == nil)
}

@Test
func readerLigatureSettingsRejectMalformedStoredValues() throws {
    let suite = "ReaderLigatureSettingsTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("unknown", forKey: "reader.codeLigatures")
    defaults.set("unknown", forKey: "reader.codeFont.kind")
    defaults.set("ExistingButIgnored-Regular", forKey: "reader.codeFont.postScriptName")
    #expect(ReaderSettings(defaults: defaults).codeLigatures == .fontDefault)
    #expect(ReaderSettings(defaults: defaults).codeFont == .systemMonospaced)

    defaults.set("postScriptName", forKey: "reader.codeFont.kind")
    for invalidName in ["", " \n\t"] {
        defaults.set(invalidName, forKey: "reader.codeFont.postScriptName")
        #expect(ReaderSettings(defaults: defaults).codeFont == .systemMonospaced)
    }
    defaults.removeObject(forKey: "reader.codeFont.postScriptName")
    #expect(ReaderSettings(defaults: defaults).codeFont == .systemMonospaced)
    defaults.set(42, forKey: "reader.codeFont.postScriptName")
    #expect(ReaderSettings(defaults: defaults).codeFont == .systemMonospaced)
    defaults.set(42, forKey: "reader.codeFont.kind")
    defaults.set(42, forKey: "reader.codeLigatures")
    #expect(ReaderSettings(defaults: defaults).codeFont == .systemMonospaced)
    #expect(ReaderSettings(defaults: defaults).codeLigatures == .fontDefault)
}

@Test
func readerLigatureSettingsNormalizeEmptyRequestsAndRetainMissingFonts() {
    #expect(ReaderSettings(codeFont: .postScriptName("")).codeFont == .systemMonospaced)
    var settings = ReaderSettings(codeFont: .postScriptName("Unavailable-Regular"))
    #expect(settings.codeFont == .postScriptName("Unavailable-Regular"))
    settings.codeFont = .postScriptName(" \t")
    #expect(settings.codeFont == .systemMonospaced)
}

@Test
func readerLigatureSettingsInvalidateThemeAndTypography() {
    let initial = ReaderSettings()
    let key = ReaderTypographyKey(settings: initial)
    let theme = ReaderTheme(settings: initial)
    var variants: [ReaderSettings] = []
    var changed = initial
    changed.codeFont = .postScriptName("FiraCode-Regular")
    variants.append(changed)
    for mode in [CodeLigatureMode.enabled, .disabled] {
        changed = initial
        changed.codeLigatures = mode
        variants.append(changed)
    }
    for settings in variants {
        #expect(settings != initial)
        #expect(ReaderTheme(settings: settings) != theme)
        #expect(ReaderTypographyKey(settings: settings) != key)
        #expect(ReaderTheme(settings: settings).codeFont == settings.codeFont)
        #expect(ReaderTheme(settings: settings).codeLigatures == settings.codeLigatures)
    }
    #expect(Set(variants.map { ReaderTypographyKey(settings: $0) }).count == variants.count)
    for field in [\ReaderSettings.fontSize, \.functionNameDelta,
                  \.functionDeclarationFontWeight, \.declarationEmphasisFontWeight,
                  \.lineHeightMultiple] {
        changed = initial
        changed[keyPath: field] += 0.1
        #expect(ReaderTypographyKey(settings: changed) != key)
    }
    for field in [\ReaderSettings.syntaxFormatting, \.humanistComments] {
        changed = initial
        changed[keyPath: field].toggle()
        #expect(ReaderTypographyKey(settings: changed) != key)
    }
    changed = initial
    changed.theme = .dark
    changed.lineNumbers.toggle()
    changed.wrapLines.toggle()
    changed.parameterReferenceAlpha = 0.5
    changed.declarationMarkerAlpha = 0.5
    #expect(ReaderTypographyKey(settings: changed) == key)
}
