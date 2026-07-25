import Foundation

public struct ReaderSettings: Equatable, Sendable {
    public enum Theme: String, CaseIterable, Sendable {
        case auto = "Auto"
        case light = "Light"
        case dark = "Dark"
        case siClassic = "SI Classic"
    }

    public static let lineHeightRange = 1.0...2.0
    public static let fontSizeRange = 10.0...24.0
    public static let functionNameDeltaRange = 0.0...4.0

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
    public var theme: Theme
    public var syntaxFormatting: Bool
    public var humanistComments: Bool
    public var lineNumbers: Bool

    public init(
        lineHeightMultiple: Double = 1.25,
        fontSize: Double = 13,
        functionNameDelta: Double = 1,
        theme: Theme = .auto,
        syntaxFormatting: Bool = true,
        humanistComments: Bool = false,
        lineNumbers: Bool = true
    ) {
        self.lineHeightMultiple = lineHeightMultiple.clamped(to: Self.lineHeightRange)
        self.fontSize = fontSize.clamped(to: Self.fontSizeRange)
        self.functionNameDelta = functionNameDelta.clamped(
            to: Self.functionNameDeltaRange
        )
        self.theme = theme
        self.syntaxFormatting = syntaxFormatting
        self.humanistComments = humanistComments
        self.lineNumbers = lineNumbers
    }

    public init(defaults: UserDefaults) {
        self.init(
            lineHeightMultiple: (defaults.object(forKey: Keys.lineHeightMultiple) as? NSNumber)?
                .doubleValue
                ?? 1.25,
            fontSize: (defaults.object(forKey: Keys.fontSize) as? NSNumber)?.doubleValue
                ?? 13,
            functionNameDelta: (defaults.object(forKey: Keys.functionNameDelta) as? NSNumber)?
                .doubleValue
                ?? 1,
            theme: defaults.string(forKey: Keys.theme).flatMap(Theme.init(rawValue:))
                ?? .auto,
            syntaxFormatting: (defaults.object(forKey: Keys.syntaxFormatting) as? NSNumber)?
                .boolValue
                ?? true,
            humanistComments: (defaults.object(forKey: Keys.humanistComments) as? NSNumber)?
                .boolValue
                ?? false,
            lineNumbers: (defaults.object(forKey: Keys.lineNumbers) as? NSNumber)?
                .boolValue
                ?? true
        )
    }

    public func save(to defaults: UserDefaults) {
        let validated = ReaderSettings(
            lineHeightMultiple: lineHeightMultiple,
            fontSize: fontSize,
            functionNameDelta: functionNameDelta,
            theme: theme,
            syntaxFormatting: syntaxFormatting,
            humanistComments: humanistComments,
            lineNumbers: lineNumbers
        )
        defaults.set(validated.lineHeightMultiple, forKey: Keys.lineHeightMultiple)
        defaults.set(validated.fontSize, forKey: Keys.fontSize)
        defaults.set(validated.functionNameDelta, forKey: Keys.functionNameDelta)
        defaults.set(validated.theme.rawValue, forKey: Keys.theme)
        defaults.set(validated.syntaxFormatting, forKey: Keys.syntaxFormatting)
        defaults.set(validated.humanistComments, forKey: Keys.humanistComments)
        defaults.set(validated.lineNumbers, forKey: Keys.lineNumbers)
    }

    private enum Keys {
        static let lineHeightMultiple = "reader.lineHeightMultiple"
        static let fontSize = "reader.fontSize"
        static let functionNameDelta = "reader.functionNameDelta"
        static let theme = "reader.theme"
        static let syntaxFormatting = "reader.syntaxFormatting"
        static let humanistComments = "reader.humanistComments"
        static let lineNumbers = "reader.lineNumbers"
    }
}

public struct ReaderTheme: Equatable, Sendable {
    public let selection: ReaderSettings.Theme
    public let lineHeightMultiple: Double
    public let fontSize: Double
    public let functionNameFontSize: Double
    public let syntaxFormatting: Bool
    public let humanistComments: Bool

    public init(settings: ReaderSettings) {
        selection = settings.theme
        lineHeightMultiple = settings.lineHeightMultiple
        fontSize = settings.fontSize
        functionNameFontSize = settings.fontSize + settings.functionNameDelta
        syntaxFormatting = settings.syntaxFormatting
        humanistComments = settings.humanistComments
    }

    public func backgroundRGB(isDark: Bool) -> UInt32 {
        switch resolvedSelection(isDark: isDark) {
        case .dark:
            0x1E1E1E
        case .siClassic:
            0xF5F0E6
        case .auto, .light:
            0xFFFFFF
        }
    }

    public func foregroundRGB(isDark: Bool) -> UInt32 {
        switch resolvedSelection(isDark: isDark) {
        case .dark:
            0xD4D4D4
        case .siClassic:
            0x1F2733
        case .auto, .light:
            0x1F2328
        }
    }

    public func rgb(for kind: HighlightKind, isDark: Bool) -> UInt32 {
        switch resolvedSelection(isDark: isDark) {
        case .dark:
            switch kind {
            case .keyword: 0xE879F9
            case .comment, .commentFigure: 0xA3E635
            case .string: 0xFDA29B
            case .number: 0xC4B5FD
            case .functionName, .declarationTitle, .declarationEmphasis: 0x84ADFF
            case .typeName: 0x67E8F9
            }
        case .siClassic:
            switch kind {
            case .keyword: 0x7A1F1F
            case .comment, .commentFigure: 0x526B45
            case .string: 0x8A3C2E
            case .number: 0x6E3B6F
            case .functionName, .declarationTitle, .declarationEmphasis: 0x163A5F
            case .typeName: 0x245B78
            }
        case .auto, .light:
            switch kind {
            case .keyword: 0x9C36B5
            case .comment, .commentFigure: 0x4D7C0F
            case .string: 0xB42318
            case .number: 0x7F56D9
            case .functionName, .declarationTitle, .declarationEmphasis: 0x175CD3
            case .typeName: 0x087E8B
            }
        }
    }

    public func diffRGB(for kind: DiffCore.MarkerKind, isDark: Bool) -> UInt32 {
        switch resolvedSelection(isDark: isDark) {
        case .dark:
            switch kind {
            case .added: 0x3FB950
            case .removed: 0xF85149
            case .changed: 0xD29922
            }
        case .siClassic:
            switch kind {
            case .added: 0x3F6B42
            case .removed: 0x9A3B32
            case .changed: 0xA66A1F
            }
        case .auto, .light:
            switch kind {
            case .added: 0x1A7F37
            case .removed: 0xCF222E
            case .changed: 0xBF8700
            }
        }
    }

    public func lineNumberRGB(isDark: Bool) -> UInt32 {
        switch resolvedSelection(isDark: isDark) {
        case .dark: 0x858585
        case .siClassic: 0x8B8272
        case .auto, .light: 0x8C959F
        }
    }

    public func currentLineRGB(isDark: Bool) -> UInt32 {
        switch resolvedSelection(isDark: isDark) {
        case .dark: 0x2A2D2E
        case .siClassic: 0xEDE6D8
        case .auto, .light: 0xF3F6FA
        }
    }

    public func occurrenceRGB(isDark: Bool) -> UInt32 {
        switch resolvedSelection(isDark: isDark) {
        case .dark: 0x4A4424
        case .siClassic: 0xE2D3A6
        case .auto, .light: 0xFFF1A8
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
