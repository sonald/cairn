import CodeInsightCore
import Foundation

/// A faint label drawn after a long block's closing `}` naming the block it ends.
package struct BlockEndAnnotation: Equatable, Sendable {
    /// Byte offset of the closing `}`.
    package let closingBrace: UInt32
    /// Start of the block header; activating the label navigates here.
    package let headerOffset: UInt32
    /// Short form drawn after the brace, at most `maximumLabelLength` characters.
    package let label: String
    /// Whole header on one line, for the hover tooltip.
    package let header: String
}

package enum BlockEndAnnotations {
    /// Blocks must span at least this many lines from header to `}`.
    package static let minimumLines = 12
    package static let maximumLabelLength = 40

    /// Annotations sorted by closing brace. Only brace languages qualify.
    package static func compute(for document: ReaderDocument) -> [BlockEndAnnotation] {
        let language = document.languageMode.language
        guard language == .rust || language == .typescript else { return [] }
        let bytes = document.bytes
        var result: [BlockEndAnnotation] = []
        for region in document.foldRegions {
            switch region.kind {
            case .container, .declaration, .block: break
            default: continue
            }
            let brace = region.bodyRange.upperBound
            guard Int(brace) < bytes.count, bytes[Int(brace)] == UInt8(ascii: "}"),
                  region.headerRange.upperBound > region.headerRange.lowerBound,
                  let headerLine = document.lineTable.lineColumn(at: region.headerRange.lowerBound)?.line,
                  let braceLine = document.lineTable.lineColumn(at: brace)?.line,
                  Int(braceLine) - Int(headerLine) >= minimumLines,
                  braceStartsLine(brace, line: Int(braceLine), in: document),
                  !lineOpensBlock(after: brace, in: bytes)
            else { continue }
            // The header ends with the opening `{`; drop it before labelling.
            let headerBytes = bytes[Int(region.headerRange.lowerBound)..<Int(region.headerRange.upperBound - 1)]
            let header = normalizedHeader(String(decoding: headerBytes, as: UTF8.self))
            guard let label = label(forHeader: header, language: language) else { continue }
            result.append(BlockEndAnnotation(
                closingBrace: brace,
                headerOffset: region.headerRange.lowerBound,
                label: label,
                header: header
            ))
        }
        return result.sorted { $0.closingBrace < $1.closingBrace }
    }

    /// The short label for an already normalized header, or nil for a bare block.
    package static func label(forHeader header: String, language: LanguageID) -> String? {
        guard !header.isEmpty else { return nil }
        if language == .rust, let name = word(after: "fn", in: header) {
            return truncated("fn " + name)
        }
        if language == .typescript {
            if let name = word(after: "function", in: header) { return truncated(name + "()") }
            if let name = typeScriptMethodName(header) { return truncated(name + "()") }
        }
        var text = Substring(header)
        for prefix in ["export default ", "export ", "pub "] where text.hasPrefix(prefix) {
            text = text.dropFirst(prefix.count)
        }
        if text.hasPrefix("pub("), let close = text.firstIndex(of: ")") {
            text = text[text.index(after: close)...].drop { $0 == " " }
        }
        return text.isEmpty ? nil : truncated(String(text))
    }

    /// One line: leading attribute/decorator/comment lines dropped, runs of
    /// whitespace collapsed to one space.
    static func normalizedHeader(_ raw: String) -> String {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .drop { line in
                line.isEmpty || line.hasPrefix("#[") || line.hasPrefix("@")
                    || line.hasPrefix("//") || line.hasPrefix("/*") || line.hasPrefix("*")
            }
        return lines.joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func truncated(_ text: String) -> String {
        guard text.count > maximumLabelLength else { return text }
        return String(text.prefix(maximumLabelLength - 1)) + "…"
    }

    /// The identifier that follows the standalone word `keyword`.
    private static func word(after keyword: String, in header: String) -> String? {
        let tokens = header.split(whereSeparator: { !isIdentifierCharacter($0) })
        guard let index = tokens.firstIndex(where: { $0 == keyword }),
              tokens.indices.contains(index + 1)
        else { return nil }
        // Only a declaration spelling counts; `fn(i32)` pointer types do not.
        let next = tokens[index + 1]
        guard header.contains(keyword + " " + next) || header.contains(keyword + "* " + next)
        else { return nil }
        return String(next)
    }

    private static let typeScriptModifiers: Set<Substring> = [
        "public", "private", "protected", "static", "async", "readonly",
        "get", "set", "override", "abstract", "declare",
    ]
    private static let typeScriptNonMethods: Set<Substring> = [
        "if", "for", "while", "switch", "catch", "with", "function", "return",
    ]

    /// `async acquire(): Promise<T>` → `acquire`; control statements never match.
    private static func typeScriptMethodName(_ header: String) -> String? {
        var rest = Substring(header)
        while let space = rest.firstIndex(of: " "),
              typeScriptModifiers.contains(rest[..<space]) {
            rest = rest[rest.index(after: space)...]
        }
        if rest.hasPrefix("*") { rest = rest.dropFirst().drop { $0 == " " } }
        let name = rest.prefix(while: isIdentifierCharacter)
        guard !name.isEmpty, !typeScriptNonMethods.contains(name) else { return nil }
        var after = rest[name.endIndex...].drop { $0 == " " }
        if after.hasPrefix("<") {
            var depth = 0
            var index = after.startIndex
            while index < after.endIndex {
                if after[index] == "<" { depth += 1 }
                if after[index] == ">" { depth -= 1; if depth == 0 { break } }
                index = after.index(after: index)
            }
            guard index < after.endIndex else { return nil }
            after = after[after.index(after: index)...].drop { $0 == " " }
        }
        return after.hasPrefix("(") ? String(name) : nil
    }

    private static func isIdentifierCharacter(_ character: Character) -> Bool {
        character == "_" || character == "$" || character.isLetter || character.isNumber
    }

    private static func braceStartsLine(_ brace: UInt32, line: Int, in document: ReaderDocument) -> Bool {
        let starts = document.lineTable.lineStarts
        guard line > 0, starts.indices.contains(line - 1) else { return false }
        var offset = Int(starts[line - 1])
        while offset < Int(brace) {
            let byte = document.bytes[offset]
            guard byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") else { return false }
            offset += 1
        }
        return true
    }

    /// `} else {` and `} catch (e) {` open the next block on the same line.
    private static func lineOpensBlock(after brace: UInt32, in bytes: [UInt8]) -> Bool {
        var offset = Int(brace) + 1
        while offset < bytes.count, bytes[offset] != UInt8(ascii: "\n") {
            if bytes[offset] == UInt8(ascii: "{") { return true }
            offset += 1
        }
        return false
    }
}
