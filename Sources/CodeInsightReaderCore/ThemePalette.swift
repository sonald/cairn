/// Every color role a Cairn theme defines, as 0xRRGGBB values plus a few fill
/// alphas. The built-in palettes are hand-tuned literals.
public struct ThemePalette: Equatable, Sendable {
    public enum Variant: String, Sendable {
        case light
        case dark
    }

    public let variant: Variant

    let background: UInt32
    let foreground: UInt32
    let lineNumber: UInt32
    let currentLine: UInt32
    let occurrence: UInt32

    // Syntax. `comment` also colors comment figures; `macro` also colors attributes.
    let keyword: UInt32
    let comment: UInt32
    let string: UInt32
    let number: UInt32
    let functionName: UInt32
    let declarationTitle: UInt32
    let functionCall: UInt32
    let declarationEmphasis: UInt32
    let typeName: UInt32
    let property: UInt32
    let parameter: UInt32
    let macro: UInt32
    let enumMember: UInt32
    let localBinding: UInt32

    let diffAdded: UInt32
    let diffRemoved: UInt32
    let diffChanged: UInt32

    /// Six highlighted-name slot fills and their overview-ruler marks.
    let highlights: [UInt32]
    let overviewHighlights: [UInt32]
    let overviewOccurrence: UInt32
    /// Four project-search condition colors.
    let queryConditions: [UInt32]

    let chrome: UInt32
    let chromeHeader: UInt32
    let chromeDivider: UInt32
    let chromeSelection: UInt32
    let accent: UInt32
    let chromeSecondary: UInt32
    let chromeTertiary: UInt32
    let chipBackground: UInt32
    let chipForeground: UInt32

    let verified: UInt32
    let inferred: UInt32
    let unresolved: UInt32
    let unresolvedBorder: UInt32
    let warning: UInt32
    let warningBorder: UInt32
    let amberMark: UInt32
    let amberSoft: UInt32
    let hist: UInt32
    let histSoft: UInt32
    let histReader: UInt32
    let mossSoft: UInt32
    let slateSoft: UInt32
    let rustSoft: UInt32

    let warningFillAlpha: Double
    let primarySelectionFillAlpha: Double
    let verifiedFillAlpha: Double
    let inferredFillAlpha: Double

    func syntax(_ kind: HighlightKind) -> UInt32 {
        switch kind {
        case .keyword: keyword
        case .comment, .commentFigure: comment
        case .string: string
        case .number: number
        case .functionName: functionName
        case .declarationTitle: declarationTitle
        case .functionCall: functionCall
        case .declarationEmphasis: declarationEmphasis
        case .typeName: typeName
        case .property: property
        case .parameter: parameter
        case .macro, .attribute: macro
        case .enumMember: enumMember
        case .localBinding: localBinding
        }
    }

    func diff(_ kind: DiffCore.MarkerKind) -> UInt32 {
        switch kind {
        case .added: diffAdded
        case .removed: diffRemoved
        case .changed: diffChanged
        }
    }
}

extension ThemePalette {
    static let light = ThemePalette(
        variant: .light,
        background: 0xFBFAF6,
        foreground: 0x1B211F,
        lineNumber: 0x7E847F,
        currentLine: 0xF1EEE3,
        occurrence: 0xECE3C6,
        keyword: 0x8A3A28,
        comment: 0x5F665F,
        string: 0x4D7030,
        number: 0x8A5610,
        functionName: 0x111715,
        declarationTitle: 0x2D5D77,
        functionCall: 0x24443B,
        declarationEmphasis: 0x1B211F,
        typeName: 0x2D5D77,
        property: 0x38403C,
        parameter: 0x4B544F,
        macro: 0x6A5594,
        enumMember: 0x2D5D77,
        localBinding: 0x1B211F,
        diffAdded: 0x4E8A4A,
        diffRemoved: 0xB0513A,
        diffChanged: 0xC98A2E,
        highlights: [0xCDE6E4, 0xE3DAF0, 0xD8E8C8, 0xF2D6D9, 0xD3DEEF, 0xF4DCC2],
        overviewHighlights: [0x2E9C94, 0x8A6BC2, 0x5E9A3A, 0xC8505E, 0x3F74C4, 0xD9822B],
        overviewOccurrence: 0xC08A1E,
        queryConditions: [0x2F67B1, 0xA0457F, 0x2E8064, 0xA8661C],
        chrome: 0xF3F1EB,
        chromeHeader: 0xE7E3DA,
        chromeDivider: 0xD5D1C6,
        chromeSelection: 0xDCE7E0,
        accent: 0x2B5849,
        chromeSecondary: 0x5C645F,
        chromeTertiary: 0x6E756F,
        chipBackground: 0xE7E3DA,
        chipForeground: 0x5C645F,
        verified: 0x2B5849,
        inferred: 0x3A5873,
        unresolved: 0x9B3D27,
        unresolvedBorder: 0x9B3D27,
        warning: 0x8A5610,
        warningBorder: 0xC98A2E,
        amberMark: 0xC98A2E,
        amberSoft: 0xF3E5CA,
        hist: 0x7A5A2C,
        histSoft: 0xEFE4CC,
        histReader: 0xFAF5EA,
        mossSoft: 0xDCE7E0,
        slateSoft: 0xDFE6ED,
        rustSoft: 0xF4DFD7,
        warningFillAlpha: 0.10,
        primarySelectionFillAlpha: 0.13,
        verifiedFillAlpha: 0.12,
        inferredFillAlpha: 0.12
    )

    static let dark = ThemePalette(
        variant: .dark,
        background: 0x121614,
        foreground: 0xE7E5DD,
        lineNumber: 0x6F766F,
        currentLine: 0x191E1B,
        occurrence: 0x2E2F21,
        keyword: 0xE89C80,
        comment: 0x99A198,
        string: 0xAACB8C,
        number: 0xE6AE5A,
        functionName: 0xF4F2EA,
        declarationTitle: 0x93C4DE,
        functionCall: 0xCFE3D8,
        declarationEmphasis: 0xE7E5DD,
        typeName: 0x93C4DE,
        property: 0xC7C9C1,
        parameter: 0xB9BDB5,
        macro: 0xBCA9E8,
        enumMember: 0x93C4DE,
        localBinding: 0xE7E5DD,
        diffAdded: 0x79B873,
        diffRemoved: 0xE0826A,
        diffChanged: 0xE6AE5A,
        highlights: [0x1E3B3A, 0x352C47, 0x2A3A22, 0x45282C, 0x23324A, 0x45321D],
        overviewHighlights: [0x5FC4BC, 0xA890DA, 0x8CC46A, 0xE07C88, 0x7AA3E0, 0xE8A55C],
        overviewOccurrence: 0xE6BE5A,
        queryConditions: [0x7EA8E6, 0xDB8CC0, 0x6CC4A2, 0xE2A55E],
        chrome: 0x161A18,
        chromeHeader: 0x1D221F,
        chromeDivider: 0x2B312D,
        chromeSelection: 0x1D3A2F,
        accent: 0x8CC6A9,
        chromeSecondary: 0x9BA29B,
        chromeTertiary: 0x858C85,
        chipBackground: 0x1D221F,
        chipForeground: 0x9BA29B,
        verified: 0x8CC6A9,
        inferred: 0xA3BDD6,
        unresolved: 0xE8927A,
        unresolvedBorder: 0xE8927A,
        warning: 0xE6AE5A,
        warningBorder: 0x7A5A2C,
        amberMark: 0xE6AE5A,
        amberSoft: 0x3A2D18,
        hist: 0xD9B377,
        histSoft: 0x33291A,
        histReader: 0x17140F,
        mossSoft: 0x1D3A2F,
        slateSoft: 0x21303D,
        rustSoft: 0x3E241E,
        warningFillAlpha: 0.15,
        primarySelectionFillAlpha: 0.20,
        verifiedFillAlpha: 0.16,
        inferredFillAlpha: 0.18
    )

    static let siClassic = ThemePalette(
        variant: .light,
        background: 0xFFFFFF,
        foreground: 0x111111,
        lineNumber: 0x8A8A8A,
        currentLine: 0xFFFBE6,
        occurrence: 0xFFF1C2,
        keyword: 0x00008B,
        comment: 0x2E7D32,
        string: 0x8B1A1A,
        number: 0xA0522D,
        functionName: 0x000000,
        declarationTitle: 0x006A6A,
        functionCall: 0x1A1A1A,
        declarationEmphasis: 0x111111,
        typeName: 0x006A6A,
        property: 0x2E2E2E,
        parameter: 0x3A3A3A,
        macro: 0x7A1F7A,
        enumMember: 0x006A6A,
        localBinding: 0x111111,
        diffAdded: 0x2E7D32,
        diffRemoved: 0xA01E1E,
        diffChanged: 0xC9A227,
        highlights: [0xBFEFEF, 0xE6D5FF, 0xCFF5C4, 0xFFD3DC, 0xCCE0FF, 0xFFDDB3],
        overviewHighlights: [0x00A0A0, 0x8A4FE0, 0x3AAA2A, 0xE0406A, 0x2F6FE0, 0xF08A1A],
        overviewOccurrence: 0xE0A800,
        queryConditions: [0x1F4FB8, 0x9C2A7A, 0x1F7A52, 0xA35A00],
        chrome: 0xEFEFEA,
        chromeHeader: 0xE0E0DA,
        chromeDivider: 0xC9C9C1,
        chromeSelection: 0xFFF1C2,
        accent: 0x1D3A8F,
        chromeSecondary: 0x555555,
        chromeTertiary: 0x6B6B6B,
        chipBackground: 0xE0E0DA,
        chipForeground: 0x555555,
        verified: 0x1D3A8F,
        inferred: 0x4A4A7A,
        unresolved: 0xA01E1E,
        unresolvedBorder: 0xA01E1E,
        warning: 0x8A6100,
        warningBorder: 0xC9A227,
        amberMark: 0xC9A227,
        amberSoft: 0xFFF1C2,
        hist: 0x6E5320,
        histSoft: 0xEFE6CF,
        histReader: 0xFFFDF6,
        mossSoft: 0xDEE4F5,
        slateSoft: 0xE6E6F0,
        rustSoft: 0xF7DEDE,
        warningFillAlpha: 0.12,
        primarySelectionFillAlpha: 0.12,
        verifiedFillAlpha: 0.15,
        inferredFillAlpha: 0.13
    )
}
