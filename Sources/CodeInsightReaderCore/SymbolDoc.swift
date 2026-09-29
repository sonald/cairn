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
    guard document.languageMode.language == .rust else {
        return SymbolDoc(
            location: location,
            signature: firstLineSignature(at: range, in: document),
            signatureLanguage: languageHint(document.languageMode.language),
            source: .syntactic
        )
    }
    return SymbolDoc(
        location: location,
        signature: rustSignature(at: range, in: document),
        signatureLanguage: "rust",
        markdown: linkingIntraDocReferences(
            hidingRustdocLines(rustDocComment(above: range, in: document))
        ),
        source: .syntactic
    )
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
        String(line.reversed().drop { $0 == " " || $0 == "\t" }.reversed())
    }
    while lines.first?.isEmpty == true { lines.removeFirst() }
    while lines.last?.isEmpty == true { lines.removeLast() }
    let indent = lines.filter { !$0.isEmpty }.map { line in
        line.prefix { $0 == " " }.count
    }.min() ?? 0
    return lines.map { $0.isEmpty ? $0 : String($0.dropFirst(indent)) }
        .joined(separator: "\n")
}

// MARK: - Rust signatures

private let maximumSignatureBytes = 4096
private let maximumInlineBodyLines = 12

private func rustSignature(
    at range: ByteRange,
    in document: ReaderDocument
) -> String? {
    let bytes = document.bytes
    let lower = Int(range.lowerBound)
    let upper = min(bytes.count, Int(range.upperBound), lower + maximumSignatureBytes)
    guard lower < upper else { return nil }

    var depth = 0
    var angle = 0
    var inString = false
    var index = lower
    var headerEnd = upper
    var bodyOpen: Int?
    while index < upper {
        let byte = bytes[index]
        if inString {
            if byte == 0x5C { index += 2; continue }
            if byte == 0x22 { inString = false }
            index += 1
            continue
        }
        switch byte {
        case 0x22: inString = true
        case 0x28, 0x5B: depth += 1
        case 0x29, 0x5D: depth = max(0, depth - 1)
        case 0x3C: angle += 1
        case 0x3E:
            let previous = index > lower ? bytes[index - 1] : 0
            if previous != 0x2D, previous != 0x3D { angle = max(0, angle - 1) }
        case 0x3B where depth == 0:
            headerEnd = index
            index = upper
            continue
        case 0x7B where depth == 0 && angle == 0:
            headerEnd = index
            bodyOpen = index
            index = upper
            continue
        default:
            break
        }
        index += 1
    }

    let header = String(decoding: bytes[lower..<headerEnd], as: UTF8.self)
    var signature = header.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !signature.isEmpty else { return nil }
    if let bodyOpen, declaresAggregate(signature) {
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
