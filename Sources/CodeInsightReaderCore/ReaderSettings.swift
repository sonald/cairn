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
    public enum Theme: String, CaseIterable, Sendable {
        case auto = "Auto"
        case light = "Light"
        case dark = "Dark"
        case siClassic = "SI Classic"
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
    public var syntaxFormatting: Bool
    public var humanistComments: Bool
    public var lineNumbers: Bool
    package var wrapLines: Bool
    /// Show the symbol documentation card when the pointer rests on a symbol.
    /// Keyboard and ⌥-click requests work either way.
    public var hoverDocs: Bool
    /// Name long blocks after their closing `}` (Rust, TypeScript).
    public var blockEndAnnotations: Bool

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
            theme: defaults.string(forKey: Keys.theme).flatMap(Theme.init(rawValue:))
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
    }

    /// Number of colors a reader can assign to highlighted names.
    public static let highlightSlotCount: UInt8 = 6

    /// Background of highlighted-name slot `slot` (1...6). The amber family
    /// stays reserved for the click occurrence highlight.
    public func highlightRGB(slot: UInt8, isDark: Bool) -> UInt32 {
        let index = Int((max(slot, 1) - 1) % Self.highlightSlotCount)
        switch resolvedSelection(isDark: isDark) {
        case .dark:
            return [0x1E3B3A, 0x352C47, 0x2A3A22, 0x45282C, 0x23324A, 0x45321D][index]
        case .siClassic:
            return [0xBFEFEF, 0xE6D5FF, 0xCFF5C4, 0xFFD3DC, 0xCCE0FF, 0xFFDDB3][index]
        case .auto, .light:
            return [0xCDE6E4, 0xE3DAF0, 0xD8E8C8, 0xF2D6D9, 0xD3DEEF, 0xF4DCC2][index]
        }
    }

    public func backgroundRGB(isDark: Bool) -> UInt32 {
        switch resolvedSelection(isDark: isDark) {
        case .dark:
            0x121614
        case .siClassic:
            0xFFFFFF
        case .auto, .light:
            0xFBFAF6
        }
    }

    public func foregroundRGB(isDark: Bool) -> UInt32 {
        switch resolvedSelection(isDark: isDark) {
        case .dark:
            0xE7E5DD
        case .siClassic:
            0x111111
        case .auto, .light:
            0x1B211F
        }
    }

    public func rgb(for kind: HighlightKind, isDark: Bool) -> UInt32 {
        switch resolvedSelection(isDark: isDark) {
        case .dark:
            switch kind {
            case .keyword: 0xE89C80
            case .comment, .commentFigure: 0x99A198
            case .string: 0xAACB8C
            case .number: 0xE6AE5A
            case .functionName: 0xF4F2EA
            case .declarationTitle: 0x93C4DE
            case .functionCall: 0xCFE3D8
            case .declarationEmphasis: 0xE7E5DD
            case .typeName: 0x93C4DE
            case .property: 0xC7C9C1
            case .parameter: 0xB9BDB5
            case .macro, .attribute: 0xBCA9E8
            case .enumMember: 0x93C4DE
            case .localBinding: 0xE7E5DD
            }
        case .siClassic:
            switch kind {
            case .keyword: 0x00008B
            case .comment, .commentFigure: 0x2E7D32
            case .string: 0x8B1A1A
            case .number: 0xA0522D
            case .functionName: 0x000000
            case .declarationTitle: 0x006A6A
            case .functionCall: 0x1A1A1A
            case .declarationEmphasis: 0x111111
            case .typeName: 0x006A6A
            case .property: 0x2E2E2E
            case .parameter: 0x3A3A3A
            case .macro, .attribute: 0x7A1F7A
            case .enumMember: 0x006A6A
            case .localBinding: 0x111111
            }
        case .auto, .light:
            switch kind {
            case .keyword: 0x8A3A28
            case .comment, .commentFigure: 0x5F665F
            case .string: 0x4D7030
            case .number: 0x8A5610
            case .functionName: 0x111715
            case .declarationTitle: 0x2D5D77
            case .functionCall: 0x24443B
            case .declarationEmphasis: 0x1B211F
            case .typeName: 0x2D5D77
            case .property: 0x38403C
            case .parameter: 0x4B544F
            case .macro, .attribute: 0x6A5594
            case .enumMember: 0x2D5D77
            case .localBinding: 0x1B211F
            }
        }
    }

    public func diffRGB(for kind: DiffCore.MarkerKind, isDark: Bool) -> UInt32 {
        switch resolvedSelection(isDark: isDark) {
        case .dark:
            switch kind {
            case .added: 0x79B873
            case .removed: 0xE0826A
            case .changed: 0xE6AE5A
            }
        case .siClassic:
            switch kind {
            case .added: 0x2E7D32
            case .removed: 0xA01E1E
            case .changed: 0xC9A227
            }
        case .auto, .light:
            switch kind {
            case .added: 0x4E8A4A
            case .removed: 0xB0513A
            case .changed: 0xC98A2E
            }
        }
    }

    public func lineNumberRGB(isDark: Bool) -> UInt32 {
        switch resolvedSelection(isDark: isDark) {
        case .dark: 0x6F766F
        case .siClassic: 0x8A8A8A
        case .auto, .light: 0x7E847F
        }
    }

    public func currentLineRGB(isDark: Bool) -> UInt32 {
        switch resolvedSelection(isDark: isDark) {
        case .dark: 0x191E1B
        case .siClassic: 0xFFFBE6
        case .auto, .light: 0xF1EEE3
        }
    }

    public func occurrenceRGB(isDark: Bool) -> UInt32 {
        switch resolvedSelection(isDark: isDark) {
        case .dark: 0x2E2F21
        case .siClassic: 0xFFF1C2
        case .auto, .light: 0xECE3C6
        }
    }

    public func chromeRGB(isDark: Bool) -> UInt32 {
        switch resolvedSelection(isDark: isDark) {
        case .dark: 0x161A18
        case .siClassic: 0xEFEFEA
        case .auto, .light: 0xF3F1EB
        }
    }

    public func chromeHeaderRGB(isDark: Bool) -> UInt32 {
        switch resolvedSelection(isDark: isDark) {
        case .dark: 0x1D221F
        case .siClassic: 0xE0E0DA
        case .auto, .light: 0xE7E3DA
        }
    }

    public func chromeDividerRGB(isDark: Bool) -> UInt32 {
        switch resolvedSelection(isDark: isDark) {
        case .dark: 0x2B312D
        case .siClassic: 0xC9C9C1
        case .auto, .light: 0xD5D1C6
        }
    }

    public func chromeSelectionRGB(isDark: Bool) -> UInt32 {
        switch resolvedSelection(isDark: isDark) {
        case .dark: 0x1D3A2F
        case .siClassic: 0xFFF1C2
        case .auto, .light: 0xDCE7E0
        }
    }

    public func accentRGB(isDark: Bool) -> UInt32 {
        switch resolvedSelection(isDark: isDark) {
        case .dark: 0x8CC6A9
        case .siClassic: 0x1D3A8F
        case .auto, .light: 0x2B5849
        }
    }

    public func chromeSecondaryRGB(isDark: Bool) -> UInt32 {
        switch resolvedSelection(isDark: isDark) {
        case .dark: 0x9BA29B
        case .siClassic: 0x555555
        case .auto, .light: 0x5C645F
        }
    }

    public func chromeTertiaryRGB(isDark: Bool) -> UInt32 {
        switch resolvedSelection(isDark: isDark) {
        case .dark: 0x858C85
        case .siClassic: 0x6B6B6B
        case .auto, .light: 0x6E756F
        }
    }

    public func verifiedRGB(isDark: Bool) -> UInt32 {
        switch resolvedSelection(isDark: isDark) {
        case .dark: 0x8CC6A9
        case .siClassic: 0x1D3A8F
        case .auto, .light: 0x2B5849
        }
    }

    public func inferredRGB(isDark: Bool) -> UInt32 {
        switch resolvedSelection(isDark: isDark) {
        case .dark: 0xA3BDD6
        case .siClassic: 0x4A4A7A
        case .auto, .light: 0x3A5873
        }
    }

    public func unresolvedRGB(isDark: Bool) -> UInt32 {
        switch resolvedSelection(isDark: isDark) {
        case .dark: 0xE8927A
        case .siClassic: 0xA01E1E
        case .auto, .light: 0x9B3D27
        }
    }

    public func unresolvedBorderRGB(isDark: Bool) -> UInt32 {
        switch resolvedSelection(isDark: isDark) {
        case .dark: 0xE8927A
        case .siClassic: 0xA01E1E
        case .auto, .light: 0x9B3D27
        }
    }

    public func warningRGB(isDark: Bool) -> UInt32 {
        switch resolvedSelection(isDark: isDark) {
        case .dark: 0xE6AE5A
        case .siClassic: 0x8A6100
        case .auto, .light: 0x8A5610
        }
    }

    public func warningBorderRGB(isDark: Bool) -> UInt32 {
        switch resolvedSelection(isDark: isDark) {
        case .dark: 0x7A5A2C
        case .siClassic: 0xC9A227
        case .auto, .light: 0xC98A2E
        }
    }

    public func warningFillAlpha(isDark: Bool) -> Double {
        switch resolvedSelection(isDark: isDark) {
        case .dark: 0.15
        case .siClassic: 0.12
        case .auto, .light: 0.10
        }
    }

    public func chipBackgroundRGB(isDark: Bool) -> UInt32 {
        switch resolvedSelection(isDark: isDark) {
        case .dark: 0x1D221F
        case .siClassic: 0xE0E0DA
        case .auto, .light: 0xE7E3DA
        }
    }

    public func chipForegroundRGB(isDark: Bool) -> UInt32 {
        switch resolvedSelection(isDark: isDark) {
        case .dark: 0x9BA29B
        case .siClassic: 0x555555
        case .auto, .light: 0x5C645F
        }
    }

    public func amberMarkRGB(isDark: Bool) -> UInt32 {
        switch resolvedSelection(isDark: isDark) {
        case .dark: 0xE6AE5A
        case .siClassic: 0xC9A227
        case .auto, .light: 0xC98A2E
        }
    }

    public func amberSoftRGB(isDark: Bool) -> UInt32 {
        switch resolvedSelection(isDark: isDark) {
        case .dark: 0x3A2D18
        case .siClassic: 0xFFF1C2
        case .auto, .light: 0xF3E5CA
        }
    }

    public func histRGB(isDark: Bool) -> UInt32 {
        switch resolvedSelection(isDark: isDark) {
        case .dark: 0xD9B377
        case .siClassic: 0x6E5320
        case .auto, .light: 0x7A5A2C
        }
    }

    public func histSoftRGB(isDark: Bool) -> UInt32 {
        switch resolvedSelection(isDark: isDark) {
        case .dark: 0x33291A
        case .siClassic: 0xEFE6CF
        case .auto, .light: 0xEFE4CC
        }
    }

    public func histReaderRGB(isDark: Bool) -> UInt32 {
        switch resolvedSelection(isDark: isDark) {
        case .dark: 0x17140F
        case .siClassic: 0xFFFDF6
        case .auto, .light: 0xFAF5EA
        }
    }

    public func mossSoftRGB(isDark: Bool) -> UInt32 {
        switch resolvedSelection(isDark: isDark) {
        case .dark: 0x1D3A2F
        case .siClassic: 0xDEE4F5
        case .auto, .light: 0xDCE7E0
        }
    }

    public func slateSoftRGB(isDark: Bool) -> UInt32 {
        switch resolvedSelection(isDark: isDark) {
        case .dark: 0x21303D
        case .siClassic: 0xE6E6F0
        case .auto, .light: 0xDFE6ED
        }
    }

    public func rustSoftRGB(isDark: Bool) -> UInt32 {
        switch resolvedSelection(isDark: isDark) {
        case .dark: 0x3E241E
        case .siClassic: 0xF7DEDE
        case .auto, .light: 0xF4DFD7
        }
    }

    public func primarySelectionFillAlpha(isDark: Bool) -> Double {
        switch resolvedSelection(isDark: isDark) {
        case .dark: 0.20
        case .siClassic: 0.12
        case .auto, .light: 0.13
        }
    }

    public func verifiedFillAlpha(isDark: Bool) -> Double {
        switch resolvedSelection(isDark: isDark) {
        case .dark: 0.16
        case .siClassic: 0.15
        case .auto, .light: 0.12
        }
    }

    public func inferredFillAlpha(isDark: Bool) -> Double {
        switch resolvedSelection(isDark: isDark) {
        case .dark: 0.18
        case .siClassic: 0.13
        case .auto, .light: 0.12
        }
    }

    private func resolvedSelection(isDark: Bool) -> ReaderSettings.Theme {
        selection == .auto ? (isDark ? .dark : .light) : selection
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
