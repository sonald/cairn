import CodeInsightCore
import Foundation

/// Documentation shown for one symbol: a location line, a signature code
/// block and a Markdown body. Both the syntactic fallback and the exact
/// language-server result produce this shape so the card can swap one for the
/// other in place.
public struct SymbolDoc: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case syntactic
        case exact
    }

    public enum Note: Hashable, Sendable {
        /// Only the syntactic layer answered; exact analysis is still preparing.
        case exactPending
        /// Exact analysis cannot answer; the associated text says why.
        case exactUnavailable(String)
        /// Exact analysis answered under a limitation (raw value of
        /// `ExactAnalysisLimitation`).
        case limitation(String)
        /// The symbol lives in a dependency whose source is not cached locally.
        case dependencySourceMissing
    }

    public var location: String?
    public var signature: String?
    public var signatureLanguage: String?
    public var markdown: String
    public var source: Source
    public var notes: [Note]

    public init(
        location: String? = nil,
        signature: String? = nil,
        signatureLanguage: String? = nil,
        markdown: String = "",
        source: Source,
        notes: [Note] = []
    ) {
        self.location = location
        self.signature = signature
        self.signatureLanguage = signatureLanguage
        self.markdown = markdown
        self.source = source
        self.notes = notes
    }

    public var isEmpty: Bool {
        signature == nil && markdown.isEmpty
    }
}

/// Builds the syntactic fallback for the declaration starting at `range`.
/// Runs on demand when a hover settles; nothing here is indexed.
public func syntacticSymbolDoc(
    forDeclarationAt range: ByteRange,
    in document: ReaderDocument,
    location: String? = nil
) -> SymbolDoc {
    switch document.languageMode.language {
    case .rust:
        return SymbolDoc(
            location: location,
            signature: rustSignature(at: range, in: document),
            signatureLanguage: "rust",
            markdown: linkingIntraDocReferences(
                hidingRustdocLines(rustDocComment(above: range, in: document))
            ),
            source: .syntactic
        )
    case .python:
        return pythonSymbolDoc(at: range, in: document, location: location)
    case .typescript:
        return typescriptSymbolDoc(at: range, in: document, location: location)
    case .javascript:
        return SymbolDoc(
            location: location,
            signature: firstLineSignature(at: range, in: document),
            signatureLanguage: languageHint(document.languageMode.language),
            source: .syntactic
        )
    }
}

/// Drops the lines rustdoc hides in Rust code examples (`# setup`, a lone
/// `#`) and unescapes `##`, as rustdoc renders them. Other fences are kept.
func hidingRustdocLines(_ markdown: String) -> String {
    var inRustFence = false
    var inOtherFence = false
    var output: [String] = []
    for line in markdown.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") {
            if inRustFence || inOtherFence {
                inRustFence = false
                inOtherFence = false
            } else {
                let info = trimmed.dropFirst(3).split(separator: ",").first
                    .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                let rustInfo = ["rust", "ignore", "no_run", "should_panic", "compile_fail", "test_harness"]
                if info.isEmpty || rustInfo.contains(info) || info.hasPrefix("edition") {
                    inRustFence = true
                } else {
                    inOtherFence = true
                }
            }
            output.append(line)
            continue
        }
        if inRustFence {
            if trimmed == "#" || trimmed.hasPrefix("# ") { continue }
            if trimmed.hasPrefix("##") {
                output.append(line.replacingOccurrences(of: "##", with: "#", options: [], range: line.range(of: "##")))
                continue
            }
        }
        output.append(line)
    }
    return output.joined(separator: "\n")
}

/// URL scheme for an intra-doc reference the card resolves in-app.
public let symbolLinkScheme = "cairn-symbol"

/// The identifier under `offset`, or `nil` when the pointer is over anything
/// that must not open a card: keywords, literals, comments, attributes,
/// punctuation or whitespace. Reads only the bytes around `offset` and one
/// binary search over the highlight spans.
public func hoverIdentifierRange(
    at offset: UInt32,
    in document: ReaderDocument
) -> ByteRange? {
    let bytes = document.bytes
    let position = Int(offset)
    guard position < bytes.count, isIdentifierByte(bytes[position]) else {
        return nil
    }
    var lower = position
    while lower > 0, isIdentifierByte(bytes[lower - 1]) { lower -= 1 }
    var upper = position + 1
    while upper < bytes.count, isIdentifierByte(bytes[upper]) { upper += 1 }
    guard !(0x30...0x39).contains(bytes[lower]) else { return nil }
    let range = ByteRange(lowerBound: UInt32(lower), upperBound: UInt32(upper))

    let spans = document.highlightSpans
    var low = 0
    var high = spans.count
    while low < high {
        let middle = (low + high) / 2
        if spans[middle].range.lowerBound <= range.lowerBound {
            low = middle + 1
        } else {
            high = middle
        }
    }
    // Spans starting at or before the identifier; a covering span is among
    // the nearest few because spans are sorted and rarely nest deeply.
    for span in spans[max(0, low - 8)..<low].reversed()
        where span.range.lowerBound <= range.lowerBound
            && span.range.upperBound >= range.upperBound
    {
        switch span.kind {
        case .keyword, .comment, .commentFigure, .string, .number, .attribute:
            return nil
        default:
            continue
        }
    }
    return range
}

/// The first segment of the Rust path that ends at `range` (`ureq` for the
/// `get` in `ureq::get`), or `nil` when the identifier is not path-qualified.
/// `crate`, `self`, `super` and `Self` are returned as written.
public func rustPathRoot(endingAt range: ByteRange, in document: ReaderDocument) -> String? {
    let bytes = document.bytes
    var start = Int(range.lowerBound)
    var root: Range<Int>?
    while start >= 2, bytes[start - 1] == 0x3A, bytes[start - 2] == 0x3A {
        var lower = start - 2
        while lower > 0, bytes[lower - 1] == 0x20 { lower -= 1 }
        let upper = lower
        while lower > 0, isIdentifierByte(bytes[lower - 1]) { lower -= 1 }
        guard lower < upper else { break }
        root = lower..<upper
        start = lower
    }
    return root.map { String(decoding: bytes[$0], as: UTF8.self) }
}

private func isIdentifierByte(_ byte: UInt8) -> Bool {
    byte == 0x5F || byte >= 0x80
        || (0x30...0x39).contains(byte)
        || (0x41...0x5A).contains(byte)
        || (0x61...0x7A).contains(byte)
}

private let intraDocReference = try! NSRegularExpression(
    pattern: #"\[(`?)([A-Za-z_][A-Za-z0-9_]*(?:::[A-Za-z_][A-Za-z0-9_]*)*)(\(\)|!)?\1\](?![\(\[:])"#
)

/// Turns rustdoc intra-doc references (``[`Oid`]``, `[Oid]`) into links the
/// card can resolve; fenced code is left untouched.
public func linkingIntraDocReferences(_ markdown: String) -> String {
    var inFence = false
    return markdown.components(separatedBy: "\n").map { line in
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            inFence.toggle()
            return line
        }
        guard !inFence else { return line }
        let range = NSRange(line.startIndex..., in: line)
        return intraDocReference.stringByReplacingMatches(
            in: line,
            range: range,
            withTemplate: "[$1$2$3$1](\(symbolLinkScheme):$2)"
        )
    }.joined(separator: "\n")
}

private func languageHint(_ language: LanguageID) -> String {
    switch language {
    case .rust: "rust"
    case .python: "python"
    case .typescript: "typescript"
    case .javascript: "javascript"
    }
}

// MARK: - Rust doc comments

/// R5.2 (P3): the byte range of the doc comment directly above a
/// declaration — `///` runs, `#[doc = "..."]`, or `/** ... */` blocks — using
/// the same recognition rules as the hover card's syntactic doc. `nil` when
/// no doc comment precedes the declaration.
public func docCommentRange(
    above range: ByteRange,
    in document: ReaderDocument
) -> ByteRange? {
    guard let start = document.lineTable.lineColumn(at: range.lowerBound) else {
        return nil
    }
    var index = Int(start.line) - 2
    var firstLine = Int(start.line) - 1
    var found = false
    while index >= 0 {
        let trimmed = sourceLine(index, in: document)
            .trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("///"), !trimmed.hasPrefix("////") {
            firstLine = index
            found = true
            index -= 1
        } else if trimmed.hasPrefix("#[doc") {
            firstLine = index
            found = true
            index -= 1
        } else if trimmed.hasPrefix("#["), trimmed.hasSuffix("]") {
            index -= 1
        } else if trimmed.hasSuffix("*/"),
                  let (_, opening) = docBlock(endingAt: index, in: document)
        {
            firstLine = opening
            found = true
            index = opening - 1
        } else {
            break
        }
    }
    guard found,
          let begin = document.lineTable.byteOffset(
            line: UInt32(firstLine + 1), column: 1
          )
    else { return nil }
    return ByteRange(lowerBound: begin, upperBound: range.lowerBound)
}

private func rustDocComment(
    above range: ByteRange,
    in document: ReaderDocument
) -> String {
    guard let start = document.lineTable.lineColumn(at: range.lowerBound) else {
        return ""
    }
    var index = Int(start.line) - 2
    // Collected bottom-up; each group is already in top-down order.
    var groups: [[String]] = []
    while index >= 0 {
        let trimmed = sourceLine(index, in: document)
            .trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("///"), !trimmed.hasPrefix("////") {
            groups.append([String(trimmed.dropFirst(3))])
            index -= 1
        } else if trimmed.hasPrefix("#[doc"), let text = docAttributeText(trimmed) {
            groups.append(text.components(separatedBy: "\n"))
            index -= 1
        } else if trimmed.hasPrefix("#["), trimmed.hasSuffix("]") {
            index -= 1
        } else if trimmed.hasSuffix("*/"),
                  let (block, opening) = docBlock(endingAt: index, in: document)
        {
            groups.append(block)
            index = opening - 1
        } else {
            break
        }
    }
    let lines = groups.reversed().flatMap { $0 }
    return normalizedDocLines(lines)
}

private func docAttributeText(_ attribute: String) -> String? {
    guard let open = attribute.firstIndex(of: "\""),
          let close = attribute.lastIndex(of: "\""),
          open < close
    else { return nil }
    var result = ""
    var escaped = false
    for character in attribute[attribute.index(after: open)..<close] {
        if escaped {
            switch character {
            case "n": result.append("\n")
            case "t": result.append("\t")
            default: result.append(character)
            }
            escaped = false
        } else if character == "\\" {
            escaped = true
        } else {
            result.append(character)
        }
    }
    return result
}

/// Returns the body lines of a `/** … */` block ending on `endLine`, and the
/// line the block opens on. Plain `/* */`, `/*** */` and `/**/` are not docs.
private func docBlock(
    endingAt endLine: Int,
    in document: ReaderDocument
) -> ([String], Int)? {
    var raw: [String] = []
    var line = endLine
    while line >= 0 {
        let text = sourceLine(line, in: document)
        raw.insert(text, at: 0)
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("/*") {
            guard trimmed.hasPrefix("/**"),
                  !trimmed.hasPrefix("/***"),
                  !trimmed.hasPrefix("/**/")
            else { return nil }
            break
        }
        if line == endLine, trimmed.contains("/*") { return nil }
        line -= 1
    }
    guard line >= 0 else { return nil }
    var joined = raw.joined(separator: "\n")
    joined = String(joined.drop { $0 == " " || $0 == "\t" }.dropFirst(3))
    if joined.hasSuffix("*/") { joined.removeLast(2) }
    let body = joined.components(separatedBy: "\n").map { line -> String in
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        guard trimmed.hasPrefix("*") else { return line }
        return String(trimmed.dropFirst())
    }
    return (body, line)
}

private func normalizedDocLines(_ lines: [String]) -> String {
    var lines = lines.map { line in
        String(line.reversed().drop { $0 == " " || $0 == "\t" || $0 == "\r" }.reversed())
    }
    while lines.first?.isEmpty == true { lines.removeFirst() }
    while lines.last?.isEmpty == true { lines.removeLast() }
    let indent = lines.filter { !$0.isEmpty }.map { line in
        line.prefix { $0 == " " }.count
    }.min() ?? 0
    return lines.map { $0.isEmpty ? $0 : String($0.dropFirst(indent)) }
        .joined(separator: "\n")
}

// MARK: - Declaration headers

private let maximumSignatureBytes = 4096
private let maximumInlineBodyLines = 12
private let maximumDocstringBytes = 16_384

/// Per-language rules for finding where a declaration header ends.
private struct HeaderScanConfiguration {
    /// Python def/class headers end at the first `:` outside brackets.
    var colonTerminates = false
    /// `'…'` strings are scanned (Python, TypeScript).
    var singleQuotes = false
    /// Triple-quoted `"""`/`'''` strings are scanned (Python).
    var tripleQuoted = false
    /// `` `…` `` template literals are scanned (TypeScript).
    var backticks = false
    /// Generic `<…>` nesting keeps a `{` from ending the header (Rust, TS).
    var angles = true

    static let rust = HeaderScanConfiguration()
    static let python = HeaderScanConfiguration(
        colonTerminates: true,
        singleQuotes: true,
        tripleQuoted: true,
        angles: false
    )
    static let typescript = HeaderScanConfiguration(
        singleQuotes: true,
        backticks: true
    )
}

/// Scans the declaration header starting at `lower`: the bytes up to the
/// terminating `;`, `{` or `:` at bracket depth zero, skipping strings.
/// Returns the terminator offset and, for brace-delimited bodies, where the
/// body opens. `nil` when no terminator appears within `limit`.
private func scanHeader(
    from lower: Int,
    in bytes: [UInt8],
    limit: Int,
    configuration: HeaderScanConfiguration
) -> (headerEnd: Int, bodyOpen: Int?)? {
    var depth = 0
    var angle = 0
    var index = lower
    while index < limit {
        let byte = bytes[index]
        if byte == 0x22
            || (configuration.singleQuotes && byte == 0x27)
            || (configuration.backticks && byte == 0x60)
        {
            guard let end = skipQuoted(
                from: index,
                in: bytes,
                limit: limit,
                tripleQuoted: configuration.tripleQuoted
            ) else { return nil }
            index = end
            continue
        }
        switch byte {
        case 0x28, 0x5B:
            depth += 1
        case 0x29, 0x5D:
            depth = max(0, depth - 1)
        case 0x3C where configuration.angles:
            angle += 1
        case 0x3E where configuration.angles:
            let previous = index > lower ? bytes[index - 1] : 0
            if previous != 0x2D, previous != 0x3D { angle = max(0, angle - 1) }
        case 0x3B where depth == 0:
            return (index, nil)
        case 0x3A where configuration.colonTerminates && depth == 0:
            return (index, nil)
        case 0x7B where !configuration.colonTerminates && depth == 0 && angle == 0:
            return (index, index)
        default:
            break
        }
        index += 1
    }
    return nil
}

/// Offset just past the quoted string opening at `index`, honouring `\`
/// escapes (and triple quotes when asked). `nil` when unterminated.
private func skipQuoted(
    from index: Int,
    in bytes: [UInt8],
    limit: Int,
    tripleQuoted: Bool
) -> Int? {
    let quote = bytes[index]
    let triple = tripleQuoted
        && index + 2 < limit
        && bytes[index + 1] == quote
        && bytes[index + 2] == quote
    var cursor = triple ? index + 3 : index + 1
    while cursor < limit {
        let byte = bytes[cursor]
        if byte == 0x5C {
            cursor += 2
            continue
        }
        if byte == quote {
            if !triple { return cursor + 1 }
            if cursor + 2 < limit,
               bytes[cursor + 1] == quote,
               bytes[cursor + 2] == quote
            {
                return cursor + 3
            }
        }
        cursor += 1
    }
    return nil
}

private func rustSignature(
    at range: ByteRange,
    in document: ReaderDocument
) -> String? {
    let bytes = document.bytes
    let lower = Int(range.lowerBound)
    let limit = min(
        bytes.count,
        Int(range.upperBound),
        lower + maximumSignatureBytes
    )
    guard lower < limit,
          let header = scanHeader(
              from: lower,
              in: bytes,
              limit: limit,
              configuration: .rust
          )
    else { return nil }

    let headerText = String(decoding: bytes[lower..<header.headerEnd], as: UTF8.self)
    var signature = headerText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !signature.isEmpty else { return nil }
    if let bodyOpen = header.bodyOpen, declaresAggregate(signature) {
        signature += " " + aggregateBody(from: bodyOpen, in: document)
    }
    return dedentContinuationLines(signature, declarationStart: range.lowerBound, in: document)
}

private func declaresAggregate(_ header: String) -> Bool {
    let words = header.split { !$0.isLetter && !$0.isNumber && $0 != "_" }
    return words.contains { $0 == "struct" || $0 == "enum" || $0 == "union" }
}

private func aggregateBody(from open: Int, in document: ReaderDocument) -> String {
    let bytes = document.bytes
    var depth = 0
    var index = open
    let limit = min(bytes.count, open + maximumSignatureBytes)
    while index < limit {
        if bytes[index] == 0x7B { depth += 1 }
        if bytes[index] == 0x7D {
            depth -= 1
            if depth == 0 { break }
        }
        index += 1
    }
    guard index < limit else { return "{ … }" }
    let body = String(decoding: bytes[open...index], as: UTF8.self)
    let lines = body.components(separatedBy: "\n").filter { line in
        !line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
    }
    guard lines.count <= maximumInlineBodyLines else { return "{ … }" }
    return lines.joined(separator: "\n")
}

private func dedentContinuationLines(
    _ signature: String,
    declarationStart: UInt32,
    in document: ReaderDocument
) -> String {
    guard let start = document.lineTable.lineColumn(at: declarationStart) else {
        return signature
    }
    let indent = sourceLine(Int(start.line) - 1, in: document)
        .prefix { $0 == " " || $0 == "\t" }.count
    guard indent > 0 else { return signature }
    return signature.components(separatedBy: "\n").enumerated().map { offset, line in
        guard offset > 0 else { return line }
        let leading = line.prefix { $0 == " " || $0 == "\t" }.count
        return String(line.dropFirst(min(indent, leading)))
    }.joined(separator: "\n")
}

// MARK: - Python declarations

private func pythonSymbolDoc(
    at range: ByteRange,
    in document: ReaderDocument,
    location: String?
) -> SymbolDoc {
    let header = pythonSignature(at: range, in: document)
    return SymbolDoc(
        location: location,
        signature: header?.signature,
        signatureLanguage: "python",
        markdown: header.map {
            markdownFromPythonDocstring(pythonDocstring(after: $0.bodyStart, in: document))
        } ?? "",
        source: .syntactic
    )
}

private func pythonSignature(
    at range: ByteRange,
    in document: ReaderDocument
) -> (signature: String, bodyStart: Int)? {
    let bytes = document.bytes
    // Facet ranges open on the decorated definition; the signature starts
    // after the `@decorator` lines.
    let lower = skipPythonDecorators(
        from: Int(range.lowerBound),
        in: bytes,
        limit: min(bytes.count, Int(range.upperBound))
    )
    let limit = min(bytes.count, lower + maximumSignatureBytes)
    guard let header = scanHeader(
        from: lower,
        in: bytes,
        limit: limit,
        configuration: .python
    ) else { return nil }
    let headerText = String(decoding: bytes[lower..<header.headerEnd], as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !headerText.isEmpty else { return nil }
    return (
        dedentContinuationLines(
            headerText,
            declarationStart: UInt32(lower),
            in: document
        ),
        header.headerEnd + 1
    )
}

/// Advances past whole `@decorator` lines so the signature opens at
/// `def`/`class`. Returns `start` when no decorator leads the declaration.
private func skipPythonDecorators(
    from start: Int,
    in bytes: [UInt8],
    limit: Int
) -> Int {
    var lineStart = start
    while lineStart < limit {
        var index = lineStart
        while index < limit, bytes[index] == 0x20 || bytes[index] == 0x09 {
            index += 1
        }
        guard index < limit, bytes[index] == 0x40 else { return lineStart }
        while index < limit, bytes[index] != 0x0A { index += 1 }
        lineStart = min(index + 1, limit)
    }
    return start
}

/// The docstring: the first statement of the body must be a triple-quoted
/// string (PEP 257). Anything else — including single-quoted strings — is
/// not treated as documentation.
private func pythonDocstring(
    after bodyStart: Int,
    in document: ReaderDocument
) -> String {
    let bytes = document.bytes
    let upper = min(bytes.count, bodyStart + maximumDocstringBytes)
    var index = bodyStart
    while index < upper {
        let byte = bytes[index]
        guard byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
        else { break }
        index += 1
    }
    guard index + 2 < upper,
          bytes[index] == 0x22 || bytes[index] == 0x27,
          bytes[index + 1] == bytes[index],
          bytes[index + 2] == bytes[index],
          let close = skipQuoted(
              from: index,
              in: bytes,
              limit: upper,
              tripleQuoted: true
          )
    else { return "" }
    let raw = unescapingStringLiterals(
        String(decoding: bytes[(index + 3)..<(close - 3)], as: UTF8.self)
    )
    return normalizedPythonDocstring(raw.components(separatedBy: "\n"))
}

/// A docstring is a string literal, so `\\` escapes read back as the
/// characters they name.
private func unescapingStringLiterals(_ text: String) -> String {
    var result = ""
    var escaped = false
    for character in text {
        if escaped {
            switch character {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "r": result.append("\r")
            default: result.append(character)
            }
            escaped = false
        } else if character == "\\" {
            escaped = true
        } else {
            result.append(character)
        }
    }
    if escaped { result.append("\\") }
    return result
}

/// PEP 257 trimming as `inspect.cleandoc` does it: the opening line shares
/// the triple quote, so only the continuation lines' common indent is
/// removed.
private func normalizedPythonDocstring(_ lines: [String]) -> String {
    var lines = lines.map { line in
        String(line.reversed().drop { $0 == " " || $0 == "\t" || $0 == "\r" }.reversed())
    }
    while lines.first?.isEmpty == true { lines.removeFirst() }
    while lines.last?.isEmpty == true { lines.removeLast() }
    guard !lines.isEmpty else { return "" }
    let indent = lines.dropFirst().filter { !$0.isEmpty }
        .map { $0.prefix { $0 == " " || $0 == "\t" }.count }
        .min() ?? 0
    var result = [lines[0].trimmingCharacters(in: .whitespaces)]
    for line in lines.dropFirst() {
        let leading = line.prefix { $0 == " " || $0 == "\t" }.count
        result.append(String(line.dropFirst(min(indent, leading))))
    }
    return result.joined(separator: "\n")
}

/// Docstrings are plain text, not Markdown: a line break before an indented
/// line (`Args:` entries, wrapped field descriptions) is meaningful. Like
/// pyright's conversion, such breaks become hard breaks and the indent is
/// kept as non-breaking spaces, so the syntactic card reads like the exact
/// one; wrapped prose at the same indent still reflows.
func markdownFromPythonDocstring(_ docstring: String) -> String {
    let lines = docstring.components(separatedBy: "\n")
    let indents = lines.map { line in
        line.prefix { $0 == " " || $0 == "\t" }
            .reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
    }
    var inFence = false
    var result: [String] = []
    for (index, line) in lines.enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") {
            inFence.toggle()
            result.append(line)
            continue
        }
        guard !inFence, !trimmed.isEmpty else {
            result.append(line)
            continue
        }
        var converted = String(repeating: "&nbsp;", count: indents[index]) + trimmed
        let next = index + 1 < lines.count ? lines[index + 1] : ""
        let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
        if !nextTrimmed.isEmpty,
           !nextTrimmed.hasPrefix("```"),
           indents[index] > 0 || indents[index + 1] > 0
        {
            converted += "  "
        }
        result.append(converted)
    }
    return result.joined(separator: "\n")
}

// MARK: - TypeScript declarations

private func typescriptSymbolDoc(
    at range: ByteRange,
    in document: ReaderDocument,
    location: String?
) -> SymbolDoc {
    return SymbolDoc(
        location: location,
        signature: typescriptSignature(at: range, in: document),
        signatureLanguage: "typescript",
        markdown: linkingTypeScriptDocReferences(
            markdownFromJSDoc(typeScriptDocComment(above: range, in: document))
        ),
        source: .syntactic
    )
}

private func typescriptSignature(
    at range: ByteRange,
    in document: ReaderDocument
) -> String? {
    let bytes = document.bytes
    let lower = Int(range.lowerBound)
    let limit = min(
        bytes.count,
        Int(range.upperBound),
        lower + maximumSignatureBytes
    )
    guard let header = scanHeader(
        from: lower,
        in: bytes,
        limit: limit,
        configuration: .typescript
    ) else { return nil }

    var signature = trimmingHangingTypeScriptOperators(
        String(decoding: bytes[lower..<header.headerEnd], as: UTF8.self)
    )
    guard !signature.isEmpty else { return nil }
    if let bodyOpen = header.bodyOpen, declaresTypeScriptAggregate(signature) {
        signature += " " + aggregateBody(from: bodyOpen, in: document)
    }
    return dedentContinuationLines(signature, declarationStart: range.lowerBound, in: document)
}

/// Drops the `=>` of arrow functions and the `=` of type aliases left
/// hanging when the header ends at their body's `{`.
private func trimmingHangingTypeScriptOperators(_ header: String) -> String {
    var trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasSuffix("=>") {
        trimmed.removeLast(2)
    } else if trimmed.hasSuffix("="), !trimmed.hasSuffix("==") {
        trimmed.removeLast()
    }
    return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func declaresTypeScriptAggregate(_ header: String) -> Bool {
    let words = header.split { !$0.isLetter && !$0.isNumber && $0 != "_" }
    return words.contains {
        $0 == "class" || $0 == "interface" || $0 == "enum"
    }
}

/// JSDoc blocks above the declaration; decorators may sit between the docs
/// and the declaration. Ordinary `//` comments end the search.
private func typeScriptDocComment(
    above range: ByteRange,
    in document: ReaderDocument
) -> String {
    guard let start = document.lineTable.lineColumn(at: range.lowerBound) else {
        return ""
    }
    var index = Int(start.line) - 2
    var groups: [[String]] = []
    while index >= 0 {
        let trimmed = sourceLine(index, in: document)
            .trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("*/"),
           let (block, opening) = docBlock(endingAt: index, in: document)
        {
            groups.append(block)
            index = opening - 1
        } else if trimmed.hasPrefix("@") {
            index -= 1
        } else {
            break
        }
    }
    let lines = groups.reversed().flatMap { $0 }
    return normalizedDocLines(lines)
}

private let jsDocLinkWithLabel = try! NSRegularExpression(
    pattern: #"\{@link\s+([A-Za-z_$][A-Za-z0-9_$#.]*)\s+([^}\s][^}]*)\}"#
)
private let jsDocLinkWithoutLabel = try! NSRegularExpression(
    pattern: #"\{@link\s+([A-Za-z_$][A-Za-z0-9_$#.]*)\}"#
)

/// JSDoc tags that name a parameter or member before their description.
private let jsDocNamedTags: Set<String> = [
    "param", "arg", "argument", "property", "prop", "template",
]

/// Renders JSDoc block tags as typescript-language-server does: the
/// description first, then each tag as its own paragraph —
/// `*@param* \`id\` — text`, `*@deprecated* — text`. Without this the raw
/// comment lines collapse into one Markdown paragraph.
func markdownFromJSDoc(_ comment: String) -> String {
    var description: [String] = []
    var tags: [(name: String, lines: [String])] = []
    var inFence = false
    for line in comment.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") { inFence.toggle() }
        if !inFence, trimmed.hasPrefix("@"),
           let name = trimmed.dropFirst().split(separator: " ", maxSplits: 1).first,
           name.allSatisfy({ $0.isLetter })
        {
            let rest = trimmed.dropFirst(name.count + 1)
                .trimmingCharacters(in: .whitespaces)
            tags.append((String(name), [rest]))
        } else if tags.isEmpty {
            description.append(line)
        } else {
            tags[tags.count - 1].lines.append(line)
        }
    }
    guard !tags.isEmpty else { return comment }
    var blocks: [String] = []
    let head = description.joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if !head.isEmpty { blocks.append(head) }
    for tag in tags {
        var first = tag.lines[0]
        var label = "*@\(tag.name)*"
        if jsDocNamedTags.contains(tag.name) {
            if first.hasPrefix("{"), let close = first.firstIndex(of: "}") {
                first = first[first.index(after: close)...]
                    .trimmingCharacters(in: .whitespaces)
            }
            let parts = first.split(separator: " ", maxSplits: 1)
            if let rawName = parts.first {
                // `[name]` and `[name=default]` mark optional parameters.
                let name = rawName.hasPrefix("[")
                    ? rawName.dropFirst().prefix { $0 != "]" && $0 != "=" }
                    : rawName
                label += " `\(name)`"
                first = parts.count > 1 ? String(parts[1]) : ""
                if first.hasPrefix("- ") { first.removeFirst(2) }
            }
        }
        let text = ([first] + tag.lines.dropFirst()).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            blocks.append(label)
        } else if first.isEmpty {
            blocks.append(label + "\n\n" + text)
        } else {
            blocks.append(label + " — " + text)
        }
    }
    return blocks.joined(separator: "\n\n")
}

/// Turns JSDoc `{@link Target}` and `{@link Target label}` into links the
/// card can resolve; fenced code is left untouched.
func linkingTypeScriptDocReferences(_ markdown: String) -> String {
    var inFence = false
    return markdown.components(separatedBy: "\n").map { line in
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            inFence.toggle()
            return line
        }
        guard !inFence else { return line }
        let range = NSRange(line.startIndex..., in: line)
        let labeled = jsDocLinkWithLabel.stringByReplacingMatches(
            in: line,
            range: range,
            withTemplate: "[$2](\(symbolLinkScheme):$1)"
        )
        return jsDocLinkWithoutLabel.stringByReplacingMatches(
            in: labeled,
            range: NSRange(labeled.startIndex..., in: labeled),
            withTemplate: "[$1](\(symbolLinkScheme):$1)"
        )
    }.joined(separator: "\n")
}

private func firstLineSignature(
    at range: ByteRange,
    in document: ReaderDocument
) -> String? {
    guard let start = document.lineTable.lineColumn(at: range.lowerBound) else {
        return nil
    }
    var line = sourceLine(Int(start.line) - 1, in: document)
        .trimmingCharacters(in: .whitespaces)
    while let last = line.last, last == "{" || last == ":" {
        line.removeLast()
        line = line.trimmingCharacters(in: .whitespaces)
    }
    return line.isEmpty ? nil : line
}

private func sourceLine(_ index: Int, in document: ReaderDocument) -> String {
    let starts = document.lineTable.lineStarts
    guard starts.indices.contains(index) else { return "" }
    let lower = Int(starts[index])
    var upper = index + 1 < starts.count
        ? Int(starts[index + 1])
        : document.bytes.count
    if upper > lower, document.bytes[upper - 1] == 0x0A { upper -= 1 }
    if upper > lower, document.bytes[upper - 1] == 0x0D { upper -= 1 }
    return String(decoding: document.bytes[lower..<upper], as: UTF8.self)
}
