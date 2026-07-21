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
    public var humanistComments: Bool

    public init(
        lineHeightMultiple: Double = 1.25,
        fontSize: Double = 13,
        functionNameDelta: Double = 1,
        theme: Theme = .auto,
        humanistComments: Bool = false
    ) {
        self.lineHeightMultiple = lineHeightMultiple.clamped(to: Self.lineHeightRange)
        self.fontSize = fontSize.clamped(to: Self.fontSizeRange)
        self.functionNameDelta = functionNameDelta.clamped(
            to: Self.functionNameDeltaRange
        )
        self.theme = theme
        self.humanistComments = humanistComments
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
            humanistComments: (defaults.object(forKey: Keys.humanistComments) as? NSNumber)?
                .boolValue
                ?? false
        )
    }

    public func save(to defaults: UserDefaults) {
        let validated = ReaderSettings(
            lineHeightMultiple: lineHeightMultiple,
            fontSize: fontSize,
            functionNameDelta: functionNameDelta,
            theme: theme,
            humanistComments: humanistComments
        )
        defaults.set(validated.lineHeightMultiple, forKey: Keys.lineHeightMultiple)
        defaults.set(validated.fontSize, forKey: Keys.fontSize)
        defaults.set(validated.functionNameDelta, forKey: Keys.functionNameDelta)
        defaults.set(validated.theme.rawValue, forKey: Keys.theme)
        defaults.set(validated.humanistComments, forKey: Keys.humanistComments)
    }

    private enum Keys {
        static let lineHeightMultiple = "reader.lineHeightMultiple"
        static let fontSize = "reader.fontSize"
        static let functionNameDelta = "reader.functionNameDelta"
        static let theme = "reader.theme"
        static let humanistComments = "reader.humanistComments"
    }
}

public struct ReaderTheme: Equatable, Sendable {
    public let selection: ReaderSettings.Theme
    public let lineHeightMultiple: Double
    public let fontSize: Double
    public let functionNameFontSize: Double
    public let humanistComments: Bool

    public init(settings: ReaderSettings) {
        selection = settings.theme
        lineHeightMultiple = settings.lineHeightMultiple
        fontSize = settings.fontSize
        functionNameFontSize = settings.fontSize + settings.functionNameDelta
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
            case .comment: 0xA3E635
            case .string: 0xFDA29B
            case .number: 0xC4B5FD
            case .functionName: 0x84ADFF
            case .typeName: 0x67E8F9
            }
        case .siClassic:
            switch kind {
            case .keyword: 0x7A1F1F
            case .comment: 0x526B45
            case .string: 0x8A3C2E
            case .number: 0x6E3B6F
            case .functionName: 0x163A5F
            case .typeName: 0x245B78
            }
        case .auto, .light:
            switch kind {
            case .keyword: 0x9C36B5
            case .comment: 0x4D7C0F
            case .string: 0xB42318
            case .number: 0x7F56D9
            case .functionName: 0x175CD3
            case .typeName: 0x087E8B
            }
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
