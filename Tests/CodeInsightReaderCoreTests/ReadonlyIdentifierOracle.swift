// Frozen from f5e116d6477fe20ed9bd83b08b82f4a0512594a7 (S0).
// Test-only reference: do not delegate to optimized production queries.
import CodeInsightCore
import CodeInsightReaderCore
import Foundation

struct ReadonlyIdentifierOracle {
    let bytes: [UInt8]
    let languageMode: LanguageMode
    let highlightSpans: [HighlightSpan]

    init(_ document: ReaderDocument) {
        bytes = document.bytes
        languageMode = document.languageMode
        highlightSpans = document.highlightSpans
    }
    private static let rustKeywords: Set<String> = [
        "as", "async", "await", "break", "const", "continue", "crate", "else",
        "enum", "extern", "fn", "for", "if", "impl", "in", "let", "loop",
        "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self",
        "static", "struct", "super", "trait", "type", "unsafe", "use", "where", "while",
    ]
    private static let pythonKeywords: Set<String> = [
    "and", "as", "assert", "async", "await", "break", "case", "class",
    "continue", "def", "del", "elif", "else", "except", "False", "finally",
    "for", "from", "global", "if", "import", "in", "is", "lambda", "None",
    "nonlocal", "not", "or", "pass", "raise", "return", "True", "try",
    "while", "with", "yield",
]
    private static let typeScriptKeywords: Set<String> = [
    "abstract", "as", "async", "await", "break", "case", "catch", "class",
    "const", "continue", "debugger", "default", "delete", "do", "else", "enum",
    "export", "extends", "finally", "for", "from", "function", "get", "if",
    "implements", "import", "in", "instanceof", "interface", "keyof", "let",
    "module", "namespace", "new", "of", "private", "protected", "public",
    "readonly", "return", "satisfies", "set", "static", "super", "switch",
    "throw", "type", "typeof", "var", "void", "while", "with", "yield",
]
    func occurrences(at byteOffset: UInt32) -> [CodeInsightCore.ByteRange] {
        switch languageMode.language {
        case .rust, .python, .typescript:
            break
        case .javascript:
            return []
        }
        guard byteOffset < bytes.count,
              let source = String(bytes: bytes, encoding: .utf8),
              let selectedIndex = source.utf8.index(
                  source.utf8.startIndex,
                  offsetBy: Int(byteOffset),
                  limitedBy: source.utf8.endIndex
              )?.samePosition(in: source.unicodeScalars),
              selectedIndex < source.unicodeScalars.endIndex,
              isIdentifierContinue(source.unicodeScalars[selectedIndex])
        else { return [] }

        let scalars = source.unicodeScalars
        var lower = selectedIndex
        while lower > scalars.startIndex {
            let previous = scalars.index(before: lower)
            guard isIdentifierContinue(scalars[previous]) else { break }
            lower = previous
        }
        guard isIdentifierStart(scalars[lower]) else { return [] }

        var upper = selectedIndex
        while upper < scalars.endIndex,
              isIdentifierContinue(scalars[upper])
        {
            upper = scalars.index(after: upper)
        }
        let selected = String(scalars[lower..<upper])
        switch languageMode.language {
        case .rust:
            guard !Self.rustKeywords.contains(selected) else { return [] }
        case .python:
            guard !Self.pythonKeywords.contains(selected) else { return [] }
        case .typescript:
            guard !Self.typeScriptKeywords.contains(selected) else { return [] }
        case .javascript:
            return []
        }

        var spanIndex = 0
        var result: [CodeInsightCore.ByteRange] = []
        var index = scalars.startIndex
        var bytePosition: UInt32 = 0
        while index < scalars.endIndex {
            let scalar = scalars[index]
            guard isIdentifierStart(scalar) else {
                bytePosition += UInt32(scalar.utf8.count)
                index = scalars.index(after: index)
                continue
            }

            let tokenStart = index
            let lowerByte = bytePosition
            while index < scalars.endIndex,
                  isIdentifierContinue(scalars[index])
            {
                bytePosition += UInt32(scalars[index].utf8.count)
                index = scalars.index(after: index)
            }
            guard String(scalars[tokenStart..<index]) == selected else { continue }
            let range = CodeInsightCore.ByteRange(
                lowerBound: lowerByte,
                upperBound: bytePosition
            )
            while highlightSpans.indices.contains(spanIndex),
                  highlightSpans[spanIndex].range.upperBound <= range.lowerBound
            {
                spanIndex += 1
            }
            var probe = spanIndex
            var excluded = false
            while highlightSpans.indices.contains(probe),
                  highlightSpans[probe].range.lowerBound < range.upperBound
            {
                if Self.excludesOccurrences(highlightSpans[probe].kind),
                   highlightSpans[probe].range.overlaps(range)
                {
                    excluded = true
                    break
                }
                probe += 1
            }
            if !excluded {
                result.append(range)
            }
        }
        return result
    }

    private func isIdentifierStart(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "_"
            || (languageMode.language == .typescript && scalar == "$")
            || scalar.properties.isXIDStart
    }

    private func isIdentifierContinue(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "_"
            || (languageMode.language == .typescript && scalar == "$")
            || scalar.properties.isXIDContinue
    }

    private static func excludesOccurrences(_ kind: HighlightKind) -> Bool {
        switch kind {
        case .keyword, .comment, .commentFigure, .string, .number:
            true
        case .functionName, .typeName, .declarationTitle, .declarationEmphasis,
             .functionCall, .property, .macro, .attribute, .parameter, .localBinding, .enumMember:
            false
        }
    }
}
