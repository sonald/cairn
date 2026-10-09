import Foundation

public enum CodeFontSelection: Hashable, Sendable {
    case systemMonospaced
    case postScriptName(String)

    fileprivate var validated: Self {
        if case let .postScriptName(name) = self,
           name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .systemMonospaced
        }
        return self
    }
}

public enum CodeLigatureMode: String, CaseIterable, Sendable {
    case fontDefault
    case enabled
    case disabled
}

public struct ReaderTypographyKey: Hashable, Sendable {
    public let codeFont: CodeFontSelection
    public let codeLigatures: CodeLigatureMode
    public let fontSize: Double
    public let functionNameDelta: Double
    public let typeNameDelta: Double
    public let functionDeclarationFontWeight: Double
    public let declarationEmphasisFontWeight: Double
    public let lineHeightMultiple: Double
    public let syntaxFormatting: Bool
    public let humanistComments: Bool

    public init(settings: ReaderSettings) {
        codeFont = settings.codeFont
        codeLigatures = settings.codeLigatures
        fontSize = settings.fontSize
        functionNameDelta = settings.functionNameDelta
        typeNameDelta = settings.typeNameDelta
        functionDeclarationFontWeight = settings.functionDeclarationFontWeight
        declarationEmphasisFontWeight = settings.declarationEmphasisFontWeight
        lineHeightMultiple = settings.lineHeightMultiple
        syntaxFormatting = settings.syntaxFormatting
        humanistComments = settings.humanistComments
    }
}

public struct ReaderSettings: Equatable, Sendable {
    /// A theme by id: the four built-ins keep their historical stored
    /// strings; base16 themes are `base16:<file name>`.
    public struct Theme: Hashable, Sendable {
        public let id: String

        public init(id: String) {
            self.id = id
        }

        /// Alias of `init(id:)` for the stored string.
        public init(rawValue: String) {
            self.init(id: rawValue)
        }

        public var rawValue: String { id }

        public static let auto = Theme(id: "Auto")
        public static let light = Theme(id: "Light")
        public static let dark = Theme(id: "Dark")
        public static let siClassic = Theme(id: "SI Classic")
        public static let builtIns: [Theme] = [.auto, .light, .dark, .siClassic]
    }

    public static let lineHeightRange = 1.0...2.0
    public static let fontSizeRange = 10.0...24.0
    public static let functionNameDeltaRange = 0.0...8.0
    public static let typeNameDeltaRange = 0.0...6.0
    /// Bumped when a default changes in a way stored settings should adopt once.
    static let defaultsRevision = 2
    public static let parameterReferenceAlphaRange = 0.0...1.0
    public static let declarationMarkerAlphaRange = 0.0...1.0
    public static let functionDeclarationFontWeightRange = -1.0...1.0
    public static let declarationEmphasisFontWeightRange = -1.0...1.0

    public var lineHeightMultiple: Double {
        didSet { lineHeightMultiple = lineHeightMultiple.clamped(to: Self.lineHeightRange) }
    }
    public var fontSize: Double {
        didSet { fontSize = fontSize.clamped(to: Self.fontSizeRange) }
    }
    public var functionNameDelta: Double {
        didSet {
            functionNameDelta = functionNameDelta.clamped(
                to: Self.functionNameDeltaRange
            )
        }
    }
    public var typeNameDelta: Double {
        didSet { typeNameDelta = typeNameDelta.clamped(to: Self.typeNameDeltaRange) }
    }
    public var parameterReferenceAlpha: Double {
        didSet {
            parameterReferenceAlpha = parameterReferenceAlpha.clamped(
                to: Self.parameterReferenceAlphaRange
            )
        }
    }
    public var declarationMarkerAlpha: Double {
        didSet {
            declarationMarkerAlpha = declarationMarkerAlpha.clamped(
                to: Self.declarationMarkerAlphaRange
            )
        }
    }
    public var functionDeclarationFontWeight: Double {
        didSet {
            functionDeclarationFontWeight = functionDeclarationFontWeight.clamped(
                to: Self.functionDeclarationFontWeightRange
            )
        }
    }
    public var declarationEmphasisFontWeight: Double {
        didSet {
            declarationEmphasisFontWeight = declarationEmphasisFontWeight.clamped(
                to: Self.declarationEmphasisFontWeightRange
            )
        }
    }
    public var codeFont: CodeFontSelection {
        didSet { codeFont = codeFont.validated }
    }
    public var codeLigatures: CodeLigatureMode
    public var theme: Theme
    /// Base16 themes color functions, properties and parameters like body
    /// text and types in blue; off follows the base16 conventions fully.
    public var quietSyntax: Bool
    public var syntaxFormatting: Bool
    public var humanistComments: Bool
    public var lineNumbers: Bool
    package var wrapLines: Bool
    /// Show the symbol documentation card when the pointer rests on a symbol.
    /// Keyboard and ⌥-click requests work either way.
    public var hoverDocs: Bool
    /// Name long blocks after their closing `}` (Rust, TypeScript).
    public var blockEndAnnotations: Bool
    /// Show the overview ruler beside the reader's scroller.
    public var overviewRuler: Bool
    public var showQuerySuggestions: Bool

    public init(
        lineHeightMultiple: Double = 1.3,
        fontSize: Double = 13,
        functionNameDelta: Double = 4.5,
        typeNameDelta: Double = 2,
        parameterReferenceAlpha: Double = 0.9,
        declarationMarkerAlpha: Double = 0.7,
        functionDeclarationFontWeight: Double = 0.23,
        declarationEmphasisFontWeight: Double = 0.23,
        theme: Theme = .auto,
        syntaxFormatting: Bool = true,
        humanistComments: Bool = true,
        lineNumbers: Bool = true,
        codeFont: CodeFontSelection = .systemMonospaced,
        codeLigatures: CodeLigatureMode = .fontDefault
    ) {
        self.lineHeightMultiple = lineHeightMultiple.clamped(to: Self.lineHeightRange)
        self.fontSize = fontSize.clamped(to: Self.fontSizeRange)
        self.functionNameDelta = functionNameDelta.clamped(
            to: Self.functionNameDeltaRange
        )
        self.typeNameDelta = typeNameDelta.clamped(to: Self.typeNameDeltaRange)
        self.parameterReferenceAlpha = parameterReferenceAlpha.clamped(
            to: Self.parameterReferenceAlphaRange
        )
        self.declarationMarkerAlpha = declarationMarkerAlpha.clamped(
            to: Self.declarationMarkerAlphaRange
        )
        self.functionDeclarationFontWeight = functionDeclarationFontWeight.clamped(
            to: Self.functionDeclarationFontWeightRange
        )
        self.declarationEmphasisFontWeight = declarationEmphasisFontWeight.clamped(
            to: Self.declarationEmphasisFontWeightRange
        )
        self.codeFont = codeFont.validated
        self.codeLigatures = codeLigatures
        self.theme = theme
        self.syntaxFormatting = syntaxFormatting
        self.humanistComments = humanistComments
        self.lineNumbers = lineNumbers
        wrapLines = false
        hoverDocs = true
        blockEndAnnotations = true
        overviewRuler = true
        showQuerySuggestions = true
        quietSyntax = true
    }

    public init(defaults: UserDefaults) {
        self.init(
            lineHeightMultiple: (defaults.object(forKey: Keys.lineHeightMultiple) as? NSNumber)?
                .doubleValue
                ?? 1.3,
            fontSize: (defaults.object(forKey: Keys.fontSize) as? NSNumber)?.doubleValue
                ?? 13,
            functionNameDelta: (defaults.object(forKey: Keys.functionNameDelta) as? NSNumber)?
                .doubleValue
                ?? 4.5,
            typeNameDelta: (defaults.object(forKey: Keys.typeNameDelta) as? NSNumber)?
                .doubleValue
                ?? 2,
            parameterReferenceAlpha:
                (defaults.object(forKey: Keys.parameterReferenceAlpha) as? NSNumber)?
                    .doubleValue
                    ?? 0.9,
            declarationMarkerAlpha:
                (defaults.object(forKey: Keys.declarationMarkerAlpha) as? NSNumber)?
                    .doubleValue
                    ?? 0.7,
            functionDeclarationFontWeight:
                (defaults.object(
                    forKey: Keys.functionDeclarationFontWeight
                ) as? NSNumber)?.doubleValue
                    ?? 0.23,
            declarationEmphasisFontWeight:
                (defaults.object(
                    forKey: Keys.declarationEmphasisFontWeight
                ) as? NSNumber)?.doubleValue
                    ?? 0.23,
            theme: defaults.string(forKey: Keys.theme).map(Theme.init(rawValue:))
                ?? .auto,
            syntaxFormatting: (defaults.object(forKey: Keys.syntaxFormatting) as? NSNumber)?
                .boolValue
                ?? true,
            humanistComments: (defaults.object(forKey: Keys.humanistComments) as? NSNumber)?
                .boolValue
                ?? true,
            lineNumbers: (defaults.object(forKey: Keys.lineNumbers) as? NSNumber)?
                .boolValue
                ?? true,
            codeFont: (defaults.object(forKey: Keys.codeFontKind) as? String) == "postScriptName"
                ? .postScriptName((defaults.object(forKey: Keys.codeFontPostScriptName) as? String) ?? "")
                : .systemMonospaced,
            codeLigatures: (defaults.object(forKey: Keys.codeLigatures) as? String)
                .flatMap(CodeLigatureMode.init(rawValue:)) ?? .fontDefault
        )
        wrapLines = (defaults.object(forKey: Keys.wrapLines) as? NSNumber)?
            .boolValue
            ?? false
        hoverDocs = (defaults.object(forKey: Keys.hoverDocs) as? NSNumber)?
            .boolValue
            ?? true
        blockEndAnnotations = (defaults.object(forKey: Keys.blockEndAnnotations) as? NSNumber)?
            .boolValue
            ?? true
        overviewRuler = (defaults.object(forKey: Keys.overviewRuler) as? NSNumber)?
            .boolValue
            ?? true
        showQuerySuggestions = (defaults.object(forKey: Keys.showQuerySuggestions) as? NSNumber)?
            .boolValue
            ?? true
        // Revision 2 (UI redesign): settings saved before it hold the old
        // defaults for every key; adopt the new ones once where unchanged.
        if defaults.integer(forKey: Keys.defaultsRevision) < 2 {
            if (defaults.object(forKey: Keys.functionNameDelta) as? NSNumber)?.doubleValue == 0 {
                functionNameDelta = 4.5
            }
            if (defaults.object(forKey: Keys.humanistComments) as? NSNumber)?.boolValue == false {
                humanistComments = true
            }
        }
    }

    public func save(to defaults: UserDefaults) {
        var validated = ReaderSettings(
            lineHeightMultiple: lineHeightMultiple,
            fontSize: fontSize,
            functionNameDelta: functionNameDelta,
            typeNameDelta: typeNameDelta,
            parameterReferenceAlpha: parameterReferenceAlpha,
            declarationMarkerAlpha: declarationMarkerAlpha,
            functionDeclarationFontWeight: functionDeclarationFontWeight,
            declarationEmphasisFontWeight: declarationEmphasisFontWeight,
            theme: theme,
            syntaxFormatting: syntaxFormatting,
            humanistComments: humanistComments,
            lineNumbers: lineNumbers,
            codeFont: codeFont,
            codeLigatures: codeLigatures
        )
        validated.wrapLines = wrapLines
        validated.hoverDocs = hoverDocs
        validated.blockEndAnnotations = blockEndAnnotations
        validated.overviewRuler = overviewRuler
        validated.showQuerySuggestions = showQuerySuggestions
        defaults.set(validated.lineHeightMultiple, forKey: Keys.lineHeightMultiple)
        defaults.set(validated.fontSize, forKey: Keys.fontSize)
        defaults.set(validated.functionNameDelta, forKey: Keys.functionNameDelta)
        defaults.set(validated.typeNameDelta, forKey: Keys.typeNameDelta)
        defaults.set(Self.defaultsRevision, forKey: Keys.defaultsRevision)
        defaults.set(
            validated.parameterReferenceAlpha,
            forKey: Keys.parameterReferenceAlpha
        )
        defaults.set(
            validated.declarationMarkerAlpha,
            forKey: Keys.declarationMarkerAlpha
        )
        defaults.set(
            validated.functionDeclarationFontWeight,
            forKey: Keys.functionDeclarationFontWeight
        )
        defaults.set(
            validated.declarationEmphasisFontWeight,
            forKey: Keys.declarationEmphasisFontWeight
        )
        switch validated.codeFont {
        case .systemMonospaced:
            defaults.set("systemMonospaced", forKey: Keys.codeFontKind)
            defaults.removeObject(forKey: Keys.codeFontPostScriptName)
        case let .postScriptName(name):
            defaults.set("postScriptName", forKey: Keys.codeFontKind)
            defaults.set(name, forKey: Keys.codeFontPostScriptName)
        }
        defaults.set(validated.codeLigatures.rawValue, forKey: Keys.codeLigatures)
        defaults.set(validated.theme.rawValue, forKey: Keys.theme)
        defaults.set(validated.syntaxFormatting, forKey: Keys.syntaxFormatting)
        defaults.set(validated.humanistComments, forKey: Keys.humanistComments)
        defaults.set(validated.lineNumbers, forKey: Keys.lineNumbers)
        defaults.set(validated.wrapLines, forKey: Keys.wrapLines)
        defaults.set(validated.hoverDocs, forKey: Keys.hoverDocs)
        defaults.set(validated.blockEndAnnotations, forKey: Keys.blockEndAnnotations)
        defaults.set(validated.overviewRuler, forKey: Keys.overviewRuler)
        defaults.set(validated.showQuerySuggestions, forKey: Keys.showQuerySuggestions)
    }

    private enum Keys {
        static let codeFontKind = "reader.codeFont.kind"
        static let codeFontPostScriptName = "reader.codeFont.postScriptName"
        static let codeLigatures = "reader.codeLigatures"
        static let lineHeightMultiple = "reader.lineHeightMultiple"
        static let fontSize = "reader.fontSize"
        static let functionNameDelta = "reader.functionNameDelta"
        static let typeNameDelta = "reader.typeNameDelta"
        static let defaultsRevision = "reader.defaultsRevision"
        static let parameterReferenceAlpha = "reader.parameterReferenceAlpha"
        static let declarationMarkerAlpha = "reader.declarationMarkerAlpha"
        static let functionDeclarationFontWeight =
            "reader.functionDeclarationFontWeight"
        static let declarationEmphasisFontWeight =
            "reader.declarationEmphasisFontWeight"
        static let theme = "reader.theme"
        static let syntaxFormatting = "reader.syntaxFormatting"
        static let humanistComments = "reader.humanistComments"
        static let lineNumbers = "reader.lineNumbers"
        static let wrapLines = "reader.wrapLines"
        static let hoverDocs = "reader.hoverDocs"
        static let blockEndAnnotations = "reader.blockEndAnnotations"
        static let overviewRuler = "reader.overviewRuler"
        static let showQuerySuggestions = "reader.showQuerySuggestions"
    }
}

public struct ReaderTheme: Equatable, Sendable {
    public let codeFont: CodeFontSelection
    public let codeLigatures: CodeLigatureMode
    public let selection: ReaderSettings.Theme
    public let lineHeightMultiple: Double
    public let fontSize: Double
    public let functionNameFontSize: Double
    public let typeNameFontSize: Double
    public let parameterReferenceAlpha: Double
    public let declarationMarkerAlpha: Double
    public let functionDeclarationFontWeight: Double
    public let declarationEmphasisFontWeight: Double
    public let syntaxFormatting: Bool
    public let humanistComments: Bool
    public let blockEndAnnotations: Bool
    /// The palettes used under a light and a dark system appearance; a fixed
    /// theme uses the same palette for both.
    private let lightPalette: ThemePalette
    private let darkPalette: ThemePalette
    /// The appearance the theme implies; nil when it follows the system.
    public let variant: ThemePalette.Variant?

    public init(settings: ReaderSettings) {
        codeFont = settings.codeFont
        codeLigatures = settings.codeLigatures
        selection = settings.theme
        lineHeightMultiple = settings.lineHeightMultiple
        fontSize = settings.fontSize
        functionNameFontSize = settings.fontSize + settings.functionNameDelta
        typeNameFontSize = settings.fontSize + settings.typeNameDelta
        parameterReferenceAlpha = settings.parameterReferenceAlpha
        declarationMarkerAlpha = settings.declarationMarkerAlpha
        functionDeclarationFontWeight = settings.functionDeclarationFontWeight
        declarationEmphasisFontWeight = settings.declarationEmphasisFontWeight
        syntaxFormatting = settings.syntaxFormatting
        humanistComments = settings.humanistComments
        blockEndAnnotations = settings.blockEndAnnotations
        if let fixed = ThemeCatalog.entry(for: settings.theme)?.palette(quiet: settings.quietSyntax) {
            lightPalette = fixed
            darkPalette = fixed
            variant = fixed.variant
        } else {
            // Auto, or an id the catalog no longer has.
            lightPalette = .light
            darkPalette = .dark
            variant = nil
        }
    }

    private func palette(isDark: Bool) -> ThemePalette {
        isDark ? darkPalette : lightPalette
    }

    /// Zero-based inclusion condition color for result markers and underlines.
    public func queryConditionRGB(index: Int, isDark: Bool) -> UInt32 {
        palette(isDark: isDark).queryConditions[max(0, index) % 4]
    }

    /// Number of colors a reader can assign to highlighted names.
    public static let highlightSlotCount: UInt8 = 6

    /// Background of highlighted-name slot `slot` (1...6). The amber family
    /// stays reserved for the click occurrence highlight.
    public func highlightRGB(slot: UInt8, isDark: Bool) -> UInt32 {
        palette(isDark: isDark).highlights[Self.slotIndex(slot)]
    }

    /// Overview-ruler mark of highlight slot `slot`: the fill's hue at a
    /// strength that stays visible as a 3pt mark.
    public func overviewHighlightRGB(slot: UInt8, isDark: Bool) -> UInt32 {
        palette(isDark: isDark).overviewHighlights[Self.slotIndex(slot)]
    }

    private static func slotIndex(_ slot: UInt8) -> Int {
        Int((max(slot, 1) - 1) % highlightSlotCount)
    }

    /// Overview-ruler mark of find matches and the clicked name's occurrences.
    public func overviewOccurrenceRGB(isDark: Bool) -> UInt32 {
        palette(isDark: isDark).overviewOccurrence
    }

    public func backgroundRGB(isDark: Bool) -> UInt32 {
        palette(isDark: isDark).background
    }

    public func foregroundRGB(isDark: Bool) -> UInt32 {
        palette(isDark: isDark).foreground
    }

    public func rgb(for kind: HighlightKind, isDark: Bool) -> UInt32 {
        palette(isDark: isDark).syntax(kind)
    }

    public func diffRGB(for kind: DiffCore.MarkerKind, isDark: Bool) -> UInt32 {
        palette(isDark: isDark).diff(kind)
    }

    public func lineNumberRGB(isDark: Bool) -> UInt32 {
        palette(isDark: isDark).lineNumber
    }

    public func currentLineRGB(isDark: Bool) -> UInt32 {
        palette(isDark: isDark).currentLine
    }

    public func occurrenceRGB(isDark: Bool) -> UInt32 {
        palette(isDark: isDark).occurrence
    }

    public func chromeRGB(isDark: Bool) -> UInt32 {
        palette(isDark: isDark).chrome
    }

    public func chromeHeaderRGB(isDark: Bool) -> UInt32 {
        palette(isDark: isDark).chromeHeader
    }

    public func chromeDividerRGB(isDark: Bool) -> UInt32 {
        palette(isDark: isDark).chromeDivider
    }

    public func chromeSelectionRGB(isDark: Bool) -> UInt32 {
        palette(isDark: isDark).chromeSelection
    }

    public func accentRGB(isDark: Bool) -> UInt32 {
        palette(isDark: isDark).accent
    }

    public func chromeSecondaryRGB(isDark: Bool) -> UInt32 {
        palette(isDark: isDark).chromeSecondary
    }

    public func chromeTertiaryRGB(isDark: Bool) -> UInt32 {
        palette(isDark: isDark).chromeTertiary
    }

    public func verifiedRGB(isDark: Bool) -> UInt32 {
        palette(isDark: isDark).verified
    }

    public func inferredRGB(isDark: Bool) -> UInt32 {
        palette(isDark: isDark).inferred
    }

    public func unresolvedRGB(isDark: Bool) -> UInt32 {
        palette(isDark: isDark).unresolved
    }

    public func unresolvedBorderRGB(isDark: Bool) -> UInt32 {
        palette(isDark: isDark).unresolvedBorder
    }

    public func warningRGB(isDark: Bool) -> UInt32 {
        palette(isDark: isDark).warning
    }

    public func warningBorderRGB(isDark: Bool) -> UInt32 {
        palette(isDark: isDark).warningBorder
    }

    public func warningFillAlpha(isDark: Bool) -> Double {
        palette(isDark: isDark).warningFillAlpha
    }

    public func chipBackgroundRGB(isDark: Bool) -> UInt32 {
        palette(isDark: isDark).chipBackground
    }

    public func chipForegroundRGB(isDark: Bool) -> UInt32 {
        palette(isDark: isDark).chipForeground
    }

    public func amberMarkRGB(isDark: Bool) -> UInt32 {
        palette(isDark: isDark).amberMark
    }

    public func amberSoftRGB(isDark: Bool) -> UInt32 {
        palette(isDark: isDark).amberSoft
    }

    public func histRGB(isDark: Bool) -> UInt32 {
        palette(isDark: isDark).hist
    }

    public func histSoftRGB(isDark: Bool) -> UInt32 {
        palette(isDark: isDark).histSoft
    }

    public func histReaderRGB(isDark: Bool) -> UInt32 {
        palette(isDark: isDark).histReader
    }

    public func mossSoftRGB(isDark: Bool) -> UInt32 {
        palette(isDark: isDark).mossSoft
    }

    public func slateSoftRGB(isDark: Bool) -> UInt32 {
        palette(isDark: isDark).slateSoft
    }

    public func rustSoftRGB(isDark: Bool) -> UInt32 {
        palette(isDark: isDark).rustSoft
    }

    public func primarySelectionFillAlpha(isDark: Bool) -> Double {
        palette(isDark: isDark).primarySelectionFillAlpha
    }

    public func verifiedFillAlpha(isDark: Bool) -> Double {
        palette(isDark: isDark).verifiedFillAlpha
    }

    public func inferredFillAlpha(isDark: Bool) -> Double {
        palette(isDark: isDark).inferredFillAlpha
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
