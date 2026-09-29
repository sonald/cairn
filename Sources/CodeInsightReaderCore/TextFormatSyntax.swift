import CodeInsightCore
import Foundation

/// A highlighted run in UTF-16 offsets, ready for text-view attribute ranges.
public struct TextFormatSpan: Equatable, Sendable {
    public let range: Range<Int>
    public let kind: HighlightKind

    public init(range: Range<Int>, kind: HighlightKind) {
        self.range = range
        self.kind = kind
    }
}

/// Configuration, template and script formats that are read as text previews
/// rather than through the indexed source reader. Highlighting is lexical:
/// it colors structure (keys, sections, strings, template holes) and never
/// drives navigation.
public enum TextFormat: Equatable, Hashable, Sendable {
    case toml
    case yaml
    case json
    case ini
    case shell
    case dockerfile
    case makefile
    case diff
    case markup
    /// Jinja-family templates, lexed over the host format named by the inner
    /// extension (`values.yaml.j2`); `nil` hosts use markup-style tags.
    indirect case jinja(host: TextFormat?)

    public var displayName: String {
        switch self {
        case .toml: "TOML"
        case .yaml: "YAML"
        case .json: "JSON"
        case .ini: "INI"
        case .shell: "Shell"
        case .dockerfile: "Dockerfile"
        case .makefile: "Makefile"
        case .diff: "Diff"
        case .markup: "XML"
        case .jinja: "Jinja"
        }
    }

    /// Files beyond this size render monospaced but unhighlighted: attribute
    /// application, not lexing, dominates at that scale.
    public static let highlightUTF16Limit = 1_500_000

    public static func detect(fileName: String, firstLine: String? = nil) -> TextFormat? {
        let lower = fileName.lowercased()
        if let format = exactNames[lower] { return format }
        if lower.hasPrefix(".env") || lower.hasSuffix(".env") { return .ini }
        if lower.hasPrefix("dockerfile") || lower.hasSuffix(".dockerfile")
            || lower.hasPrefix("containerfile")
        {
            return .dockerfile
        }
        let parts = lower.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count >= 2, let last = parts.last {
            if templateExtensions.contains(String(last)) {
                let host = parts.count >= 3
                    ? extensionFormats[String(parts[parts.count - 2])]
                    : nil
                return .jinja(host: host.flatMap { $0 == .markup ? nil : $0 })
            }
            if let format = extensionFormats[String(last)] { return format }
        }
        if let firstLine, firstLine.hasPrefix("#!") {
            let interpreter = firstLine.split(whereSeparator: { $0 == "/" || $0 == " " })
            if interpreter.contains(where: { shellInterpreters.contains(String($0)) }) {
                return .shell
            }
        }
        return nil
    }

    /// Fenced-code language hints (` ```yaml `) for the lexical formats.
    public static func fromLanguageHint(_ hint: String) -> TextFormat? {
        let hint = hint.lowercased().split(separator: " ").first.map(String.init) ?? ""
        switch hint {
        case "toml": return .toml
        case "yaml", "yml": return .yaml
        case "json", "jsonc", "json5", "jsonl": return .json
        case "ini", "cfg", "conf", "properties", "env", "dotenv", "editorconfig", "gitconfig":
            return .ini
        case "sh", "bash", "zsh", "shell", "console", "shellsession", "ksh":
            return .shell
        case "dockerfile", "docker", "containerfile": return .dockerfile
        case "make", "makefile", "mk": return .makefile
        case "diff", "patch": return .diff
        case "xml", "html", "svg", "plist", "xhtml": return .markup
        case "jinja", "jinja2", "j2", "django", "twig", "nunjucks", "njk", "tera", "liquid":
            return .jinja(host: nil)
        default: return nil
        }
    }

    public func highlight(_ text: String) -> [TextFormatSpan] {
        let units = Array(text.utf16)
        guard units.count <= Self.highlightUTF16Limit else { return [] }
        return highlight(units: units)
    }

    func highlight(units: [UInt16]) -> [TextFormatSpan] {
        var lexer = TextLexer(units)
        switch self {
        case .toml: lexer.toml()
        case .yaml: lexer.yaml()
        case .json: lexer.json()
        case .ini: lexer.ini()
        case .shell: lexer.shell(0, units.count, dockerfile: false)
        case .dockerfile: lexer.shell(0, units.count, dockerfile: true)
        case .makefile: lexer.makefile()
        case .diff: lexer.diff()
        case .markup: lexer.markup()
        case .jinja(let host):
            return Self.jinja(units: units, host: host)
        }
        return lexer.spans
    }

    /// Lexes the host with every template region masked by placeholder
    /// letters (newlines kept, so line-based hosts stay aligned), then lays the
    /// template spans over host spans clipped around those regions.
    private static func jinja(units: [UInt16], host: TextFormat?) -> [TextFormatSpan] {
        var template = TextLexer(units)
        let regions = template.jinjaRegions()
        var masked = units
        for region in regions {
            for index in region where masked[index] != TextLexer.newline {
                masked[index] = TextLexer.x
            }
        }
        let hostSpans = (host ?? .markup).highlight(units: masked)
        var result: [TextFormatSpan] = []
        result.reserveCapacity(hostSpans.count + template.spans.count)
        var regionIndex = 0
        for span in hostSpans {
            var lower = span.range.lowerBound
            while regionIndex < regions.count, regions[regionIndex].upperBound <= lower {
                regionIndex += 1
            }
            var probe = regionIndex
            while lower < span.range.upperBound {
                guard probe < regions.count, regions[probe].lowerBound < span.range.upperBound else {
                    result.append(TextFormatSpan(range: lower..<span.range.upperBound, kind: span.kind))
                    break
                }
                let region = regions[probe]
                if region.lowerBound > lower {
                    result.append(TextFormatSpan(range: lower..<region.lowerBound, kind: span.kind))
                }
                lower = max(lower, region.upperBound)
                probe += 1
            }
        }
        result += template.spans
        result.sort { $0.range.lowerBound < $1.range.lowerBound }
        return result
    }

    private static let shellInterpreters: Set<String> = ["sh", "bash", "zsh", "ksh", "dash"]
    private static let templateExtensions: Set<String> = [
        "j2", "jinja", "jinja2", "njk", "twig", "tera", "liquid", "tpl", "gotmpl",
    ]
    private static let extensionFormats: [String: TextFormat] = [
        "toml": .toml,
        "yaml": .yaml, "yml": .yaml,
        "json": .json, "jsonc": .json, "json5": .json, "jsonl": .json,
        "geojson": .json, "webmanifest": .json, "code-workspace": .json,
        "ini": .ini, "cfg": .ini, "properties": .ini, "env": .ini,
        "sh": .shell, "bash": .shell, "zsh": .shell, "ksh": .shell,
        "mk": .makefile, "mak": .makefile,
        "diff": .diff, "patch": .diff,
        "xml": .markup, "plist": .markup, "xsd": .markup, "xsl": .markup,
        "xslt": .markup, "svg": .markup, "html": .markup, "htm": .markup,
    ]
    private static let exactNames: [String: TextFormat] = [
        "cargo.lock": .toml, "pipfile": .toml, "poetry.lock": .toml, "uv.lock": .toml,
        ".editorconfig": .ini, ".gitconfig": .ini, ".gitmodules": .ini, ".npmrc": .ini,
        ".flake8": .ini, ".pylintrc": .ini, ".coveragerc": .ini,
        ".bashrc": .shell, ".bash_profile": .shell, ".zshrc": .shell, ".zprofile": .shell,
        ".zshenv": .shell, ".profile": .shell, ".envrc": .shell,
        "makefile": .makefile, "gnumakefile": .makefile, "justfile": .makefile,
        ".clang-format": .yaml, ".clang-tidy": .yaml,
    ]
}

// MARK: - Lexer

/// Operates on UTF-16 code units: every delimiter these formats use is
/// ASCII, so offsets map directly onto NSString ranges.
struct TextLexer {
    static let newline: UInt16 = 0x0A
    static let x: UInt16 = 0x78

    let s: [UInt16]
    let n: Int
    var spans: [TextFormatSpan] = []

    init(_ units: [UInt16]) {
        s = units
        n = units.count
    }

    mutating func emit(_ start: Int, _ end: Int, _ kind: HighlightKind) {
        if end > start { spans.append(TextFormatSpan(range: start..<end, kind: kind)) }
    }

    // MARK: Character classes

    static func isSpace(_ c: UInt16) -> Bool { c == 0x20 || c == 0x09 || c == 0x0D }
    static func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }
    static func isAlpha(_ c: UInt16) -> Bool { (c | 0x20) >= 0x61 && (c | 0x20) <= 0x7A }
    static func isWord(_ c: UInt16) -> Bool { isAlpha(c) || isDigit(c) || c == 0x5F }
    static func isBareKey(_ c: UInt16) -> Bool { isWord(c) || c == 0x2D }

    func char(_ i: Int) -> UInt16 { i < n ? s[i] : 0 }
    func lineEnd(_ i: Int) -> Int {
        var j = i
        while j < n, s[j] != Self.newline { j += 1 }
        return j
    }
    func skipSpaces(_ i: Int, _ end: Int) -> Int {
        var j = i
        while j < end, Self.isSpace(s[j]) { j += 1 }
        return j
    }
    func trimEnd(_ start: Int, _ end: Int) -> Int {
        var j = end
        while j > start, Self.isSpace(s[j - 1]) { j -= 1 }
        return j
    }
    func word(_ start: Int, _ end: Int) -> String {
        String(utf16CodeUnits: Array(s[start..<end]), count: end - start)
    }
    func matches(_ i: Int, _ literal: String) -> Bool {
        var j = i
        for unit in literal.utf16 {
            guard j < n, s[j] == unit else { return false }
            j += 1
        }
        return true
    }

    /// Scans a quoted string starting at `i`; returns the index past the
    /// closing quote (or `limit` when unterminated).
    func quoted(_ i: Int, limit: Int, escapes: Bool = true) -> Int {
        let quote = s[i]
        var j = i + 1
        while j < limit {
            let c = s[j]
            if escapes, c == 0x5C { j += 2; continue }
            if c == quote { return j + 1 }
            j += 1
        }
        return limit
    }

    /// A scalar token such as `-1_000.5e3`, `0x1F`, `1979-05-27T07:32:00Z`.
    func isNumberLike(_ start: Int, _ end: Int) -> Bool {
        guard start < end else { return false }
        var j = start
        if s[j] == 0x2B || s[j] == 0x2D { j += 1 }
        guard j < end else { return false }
        if matches(j, ".inf") || matches(j, ".Inf") || matches(j, ".nan") || matches(j, ".NaN")
            || matches(j, "inf") || matches(j, "nan")
        {
            return end - j <= 4
        }
        guard Self.isDigit(s[j]) || (s[j] == 0x2E && j + 1 < end && Self.isDigit(s[j + 1]))
        else { return false }
        if s[j] == 0x30, j + 1 < end, [0x78, 0x6F, 0x62].contains(s[j + 1] | 0x20) {
            return s[(j + 2)..<end].allSatisfy { Self.isWord($0) }
        }
        for c in s[j..<end] {
            guard Self.isDigit(c) || c == 0x5F || c == 0x2E || c == 0x2D || c == 0x2B
                || c == 0x3A || c == 0x65 || c == 0x45 || c == 0x54 || c == 0x5A || c == 0x20
            else { return false }
        }
        return true
    }

    // MARK: TOML

    mutating func toml() {
        var i = 0
        var stack: [UInt16] = []
        var expectKey = true
        var lineStart = true
        while i < n {
            let c = s[i]
            if c == Self.newline {
                i += 1
                lineStart = true
                if stack.isEmpty { expectKey = true }
                continue
            }
            if Self.isSpace(c) { i += 1; continue }
            if c == 0x23 {
                let end = lineEnd(i)
                emit(i, end, .comment)
                i = end
                continue
            }
            if lineStart, stack.isEmpty, c == 0x5B {
                var end = i
                while end < n, s[end] != Self.newline, s[end] != 0x23 { end += 1 }
                end = trimEnd(i, end)
                emit(i, end, .declarationTitle)
                i = end
                lineStart = false
                expectKey = false
                continue
            }
            lineStart = false
            if expectKey, Self.isBareKey(c) || c == 0x22 || c == 0x27 {
                var j = i
                var last = i
                while j < n {
                    let k = s[j]
                    if k == 0x22 || k == 0x27 {
                        j = quoted(j, limit: lineEnd(j), escapes: k == 0x22)
                        last = j
                    } else if Self.isBareKey(k) {
                        j += 1
                        last = j
                    } else if k == 0x2E || Self.isSpace(k) {
                        j += 1
                    } else {
                        break
                    }
                }
                emit(i, last, .property)
                i = last
                expectKey = false
                continue
            }
            expectKey = false
            switch c {
            case 0x22, 0x27:
                let triple = i + 2 < n && s[i + 1] == c && s[i + 2] == c
                var end: Int
                if triple {
                    end = i + 3
                    while end < n {
                        if c == 0x22, s[end] == 0x5C { end += 2; continue }
                        if s[end] == c, end + 2 < n, s[end + 1] == c, s[end + 2] == c {
                            end += 3
                            while end < n, s[end] == c { end += 1 }
                            break
                        }
                        end += 1
                    }
                    end = min(end, n)
                } else {
                    end = quoted(i, limit: lineEnd(i), escapes: c == 0x22)
                }
                emit(i, end, .string)
                i = end
            case 0x5B:
                stack.append(c)
                i += 1
            case 0x7B:
                stack.append(c)
                expectKey = true
                i += 1
            case 0x5D, 0x7D:
                if !stack.isEmpty { stack.removeLast() }
                i += 1
            case 0x2C:
                if stack.last == 0x7B { expectKey = true }
                i += 1
            default:
                if Self.isDigit(c) || c == 0x2B || c == 0x2D {
                    var j = i + 1
                    while j < n, Self.isWord(s[j]) || s[j] == 0x2E || s[j] == 0x3A
                        || s[j] == 0x2B || s[j] == 0x2D
                    {
                        j += 1
                    }
                    // Local date-times may separate date and time with a space.
                    if j + 2 < n, s[j] == 0x20, Self.isDigit(s[j + 1]), Self.isDigit(s[j + 2]),
                       j + 3 < n, s[j + 3] == 0x3A
                    {
                        j += 1
                        while j < n, Self.isWord(s[j]) || s[j] == 0x2E || s[j] == 0x3A
                            || s[j] == 0x2B || s[j] == 0x2D
                        {
                            j += 1
                        }
                    }
                    emit(i, j, .number)
                    i = j
                } else if Self.isAlpha(c) {
                    var j = i
                    while j < n, Self.isBareKey(s[j]) { j += 1 }
                    switch word(i, j) {
                    case "true", "false": emit(i, j, .keyword)
                    case "inf", "nan": emit(i, j, .number)
                    default: break
                    }
                    i = j
                } else {
                    i += 1
                }
            }
        }
    }

    // MARK: YAML

    mutating func yaml() {
        var i = 0
        var blockParentIndent: Int?
        while i < n {
            let ls = i
            let le = lineEnd(i)
            i = le + 1
            let p0 = skipSpaces(ls, le)
            let indent = p0 - ls
            if let parent = blockParentIndent {
                if p0 == le { continue }
                if indent > parent {
                    emit(p0, trimEnd(p0, le), .string)
                    continue
                }
                blockParentIndent = nil
            }
            guard p0 < le else { continue }
            var p = p0
            if indent == 0, matches(p, "---") || matches(p, "..."),
               p + 3 == le || Self.isSpace(char(p + 3))
            {
                emit(p, p + 3, .keyword)
                p = skipSpaces(p + 3, le)
                if p < le { blockParentIndent = yamlValue(p, le, parentIndent: -1) }
                continue
            }
            if indent == 0, s[p] == 0x25 {
                emit(p, trimEnd(p, le), .attribute)
                continue
            }
            if s[p] == 0x23 {
                emit(p, trimEnd(p, le), .comment)
                continue
            }
            var parentIndent = indent
            var sawDash = false
            while p < le, s[p] == 0x2D, p + 1 == le || Self.isSpace(s[p + 1]) {
                parentIndent = p - ls
                sawDash = true
                p = skipSpaces(p + 1, le)
            }
            if p < le, let colon = yamlKeyColon(p, le) {
                let keyEnd = trimEnd(p, colon)
                emit(p, keyEnd, indent == 0 && !sawDash ? .declarationTitle : .property)
                blockParentIndent = yamlValue(colon + 1, le, parentIndent: p - ls)
            } else if p < le {
                blockParentIndent = yamlValue(p, le, parentIndent: parentIndent)
            }
        }
    }

    /// The colon ending a block-mapping key on this line, if any.
    func yamlKeyColon(_ p: Int, _ le: Int) -> Int? {
        var j = p
        let first = s[p]
        if first == 0x22 || first == 0x27 {
            j = quoted(p, limit: le, escapes: first == 0x22)
            j = skipSpaces(j, le)
            return j < le && s[j] == 0x3A && (j + 1 == le || Self.isSpace(s[j + 1])) ? j : nil
        }
        // Indicators that cannot begin a plain key.
        if [0x5B, 0x7B, 0x26, 0x2A, 0x21, 0x7C, 0x3E, 0x40, 0x60, 0x23].contains(first) {
            return nil
        }
        while j < le {
            let c = s[j]
            if c == 0x3A, j + 1 == le || Self.isSpace(s[j + 1]) { return j }
            if c == 0x23, j > p, Self.isSpace(s[j - 1]) { return nil }
            j += 1
        }
        return nil
    }

    /// Returns the parent indent when the value opens a block scalar.
    mutating func yamlValue(_ start: Int, _ le: Int, parentIndent: Int) -> Int? {
        var p = skipSpaces(start, le)
        while p < le {
            let c = s[p]
            switch c {
            case 0x23:
                emit(p, trimEnd(p, le), .comment)
                return nil
            case 0x26, 0x2A:
                var j = p + 1
                while j < le, !Self.isSpace(s[j]), s[j] != 0x2C, s[j] != 0x5D, s[j] != 0x7D { j += 1 }
                emit(p, j, .attribute)
                p = skipSpaces(j, le)
            case 0x21:
                var j = p + 1
                while j < le, !Self.isSpace(s[j]) { j += 1 }
                emit(p, j, .attribute)
                p = skipSpaces(j, le)
            case 0x7C, 0x3E:
                var j = p + 1
                while j < le, s[j] == 0x2D || s[j] == 0x2B || Self.isDigit(s[j]) { j += 1 }
                let rest = skipSpaces(j, le)
                guard rest == le || s[rest] == 0x23 else {
                    yamlPlain(p, le)
                    return nil
                }
                emit(p, j, .keyword)
                if rest < le { emit(rest, trimEnd(rest, le), .comment) }
                return parentIndent
            case 0x22, 0x27:
                let end = quoted(p, limit: le, escapes: c == 0x22)
                emit(p, end, .string)
                p = skipSpaces(end, le)
                if p < le, s[p] != 0x23 { p += 1 }
            case 0x5B, 0x7B:
                yamlFlow(p, le)
                return nil
            default:
                yamlPlain(p, le)
                return nil
            }
        }
        return nil
    }

    mutating func yamlPlain(_ p: Int, _ le: Int) {
        var end = p
        while end < le {
            if s[end] == 0x23, end > p, Self.isSpace(s[end - 1]) { break }
            end += 1
        }
        let valueEnd = trimEnd(p, end)
        yamlScalar(p, valueEnd)
        if end < le { emit(end, trimEnd(end, le), .comment) }
    }

    mutating func yamlScalar(_ start: Int, _ end: Int) {
        guard start < end else { return }
        switch word(start, end) {
        case "true", "false", "True", "False", "TRUE", "FALSE", "yes", "no", "Yes", "No",
             "on", "off", "On", "Off", "null", "Null", "NULL", "~":
            emit(start, end, .keyword)
        default:
            emit(start, end, isNumberLike(start, end) ? .number : .string)
        }
    }

    mutating func yamlFlow(_ start: Int, _ le: Int) {
        var p = start
        while p < le {
            let c = s[p]
            if Self.isSpace(c) || c == 0x5B || c == 0x5D || c == 0x7B || c == 0x7D || c == 0x2C {
                p += 1
                continue
            }
            if c == 0x23, p > start, Self.isSpace(s[p - 1]) {
                emit(p, trimEnd(p, le), .comment)
                return
            }
            if c == 0x22 || c == 0x27 {
                let end = quoted(p, limit: le, escapes: c == 0x22)
                let after = skipSpaces(end, le)
                emit(p, end, after < le && s[after] == 0x3A ? .property : .string)
                p = end
                continue
            }
            var end = p
            while end < le, ![0x2C, 0x5B, 0x5D, 0x7B, 0x7D].contains(s[end]) {
                if s[end] == 0x3A, end + 1 == le || Self.isSpace(s[end + 1]) { break }
                end += 1
            }
            let tokenEnd = trimEnd(p, end)
            if end < le, s[end] == 0x3A {
                emit(p, tokenEnd, .property)
                p = end + 1
            } else {
                yamlScalar(p, tokenEnd)
                p = max(end, p + 1)
            }
        }
    }

    // MARK: JSON

    mutating func json() {
        var i = 0
        while i < n {
            let c = s[i]
            if c == 0x22 || c == 0x27 {
                let end = quoted(i, limit: lineEnd(i))
                var after = end
                while after < n, Self.isSpace(s[after]) || s[after] == Self.newline { after += 1 }
                emit(i, end, after < n && s[after] == 0x3A ? .property : .string)
                i = end
            } else if c == 0x2F, char(i + 1) == 0x2F {
                let end = lineEnd(i)
                emit(i, end, .comment)
                i = end
            } else if c == 0x2F, char(i + 1) == 0x2A {
                var end = i + 2
                while end < n, !(s[end] == 0x2A && char(end + 1) == 0x2F) { end += 1 }
                end = min(n, end + 2)
                emit(i, end, .comment)
                i = end
            } else if Self.isDigit(c) || c == 0x2D {
                var end = i + 1
                while end < n, Self.isWord(s[end]) || s[end] == 0x2E || s[end] == 0x2B || s[end] == 0x2D {
                    end += 1
                }
                emit(i, end, .number)
                i = end
            } else if Self.isAlpha(c) {
                var end = i
                while end < n, Self.isWord(s[end]) { end += 1 }
                switch word(i, end) {
                case "true", "false", "null": emit(i, end, .keyword)
                default:
                    // JSON5 unquoted keys.
                    let after = skipSpaces(end, n)
                    if after < n, s[after] == 0x3A { emit(i, end, .property) }
                }
                i = end
            } else {
                i += 1
            }
        }
    }

    // MARK: INI / .env / properties

    mutating func ini() {
        var i = 0
        var continuing = false
        while i < n {
            let ls = i
            let le = lineEnd(i)
            i = le + 1
            let p = skipSpaces(ls, le)
            guard p < le else { continuing = false; continue }
            let c = s[p]
            if c == 0x3B || c == 0x23 {
                emit(p, trimEnd(p, le), .comment)
                continue
            }
            if c == 0x5B {
                emit(p, trimEnd(p, le), .declarationTitle)
                continuing = false
                continue
            }
            if continuing, p > ls {
                iniValue(p, le)
                continue
            }
            var key = p
            if matches(p, "export "), p + 7 < le {
                emit(p, p + 6, .keyword)
                key = skipSpaces(p + 7, le)
            }
            var sep = key
            while sep < le, s[sep] != 0x3D, s[sep] != 0x3A { sep += 1 }
            guard sep < le else {
                emit(key, trimEnd(key, le), .property)
                continuing = false
                continue
            }
            emit(key, trimEnd(key, sep), .property)
            let value = skipSpaces(sep + 1, le)
            continuing = value == le
            iniValue(value, le)
        }
    }

    mutating func iniValue(_ start: Int, _ le: Int) {
        guard start < le else { return }
        var end = le
        var j = start
        while j < le {
            if s[j] == 0x22 || s[j] == 0x27 {
                j = quoted(j, limit: le)
                continue
            }
            if (s[j] == 0x23 || s[j] == 0x3B), j > start, Self.isSpace(s[j - 1]) {
                end = j
                break
            }
            j += 1
        }
        let valueEnd = trimEnd(start, end)
        switch word(start, valueEnd).lowercased() {
        case "true", "false", "yes", "no", "on", "off", "none", "null":
            emit(start, valueEnd, .keyword)
        default:
            if isNumberLike(start, valueEnd) {
                emit(start, valueEnd, .number)
            } else {
                emitInterpolated(start, valueEnd, base: .string)
            }
        }
        if end < le { emit(end, trimEnd(end, le), .comment) }
    }

    /// Emits `base` over the range with `${VAR}` / `$VAR` holes as parameters.
    mutating func emitInterpolated(_ start: Int, _ end: Int, base: HighlightKind) {
        var run = start
        var j = start
        while j < end {
            if s[j] == 0x24, j + 1 < end, s[j + 1] == 0x7B || Self.isAlpha(s[j + 1]) || s[j + 1] == 0x5F {
                var k = j + 1
                if s[k] == 0x7B {
                    while k < end, s[k] != 0x7D { k += 1 }
                    k = min(end, k + 1)
                } else {
                    while k < end, Self.isWord(s[k]) { k += 1 }
                }
                emit(run, j, base)
                emit(j, k, .parameter)
                run = k
                j = k
            } else {
                j += 1
            }
        }
        emit(run, end, base)
    }

    // MARK: Shell / Dockerfile

    private static let shellKeywords: Set<String> = [
        "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case",
        "esac", "function", "select", "return", "local", "export", "readonly", "declare",
        "typeset", "unset", "shift", "exit", "break", "continue", "source", "set", "trap",
        "eval", "exec", "time", "!", "[[", "]]",
    ]
    private static let dockerInstructions: Set<String> = [
        "FROM", "RUN", "CMD", "LABEL", "MAINTAINER", "EXPOSE", "ENV", "ADD", "COPY",
        "ENTRYPOINT", "VOLUME", "USER", "WORKDIR", "ARG", "ONBUILD", "STOPSIGNAL",
        "HEALTHCHECK", "SHELL",
    ]

    mutating func shell(_ start: Int, _ end: Int, dockerfile: Bool) {
        var i = start
        var command = true
        var lineStart = true
        var expectIn = 0
        var heredocs: [(delimiter: String, stripTabs: Bool)] = []
        while i < end {
            let c = s[i]
            if c == Self.newline {
                i += 1
                let continued = i >= 2 && s[i - 2] == 0x5C
                lineStart = !continued
                if !continued { command = true }
                for heredoc in heredocs {
                    let bodyStart = i
                    var matched = false
                    while i < end {
                        let le = min(lineEnd(i), end)
                        let content = heredoc.stripTabs ? skipSpaces(i, le) : i
                        if word(content, trimEnd(content, le)) == heredoc.delimiter {
                            emit(bodyStart, i, .string)
                            emit(content, trimEnd(content, le), .keyword)
                            i = min(end, le + 1)
                            matched = true
                            break
                        }
                        i = le + 1
                    }
                    if !matched { emit(bodyStart, end, .string); i = end }
                }
                heredocs.removeAll()
                continue
            }
            if Self.isSpace(c) { i += 1; continue }
            let atWordStart = i == start || Self.isSpace(s[i - 1]) || s[i - 1] == Self.newline
                || [0x3B, 0x7C, 0x26, 0x28, 0x29, 0x7B, 0x7D, 0x60].contains(s[i - 1])
            if c == 0x23, atWordStart {
                let le = min(lineEnd(i), end)
                emit(i, le, .comment)
                i = le
                continue
            }
            if dockerfile, lineStart, Self.isAlpha(c) {
                var j = i
                while j < end, Self.isAlpha(s[j]) { j += 1 }
                if Self.dockerInstructions.contains(word(i, j).uppercased()) {
                    emit(i, j, .keyword)
                    // RUN takes a command; ARG/ENV take assignments.
                    command = ["RUN", "ARG", "ENV"].contains(word(i, j).uppercased())
                    i = j
                    lineStart = false
                    continue
                }
            }
            lineStart = false
            switch c {
            case 0x27:
                let close = quoted(i, limit: end, escapes: false)
                emit(i, close, .string)
                i = close
                command = false
            case 0x22:
                var j = i + 1
                var run = i
                while j < end, s[j] != 0x22 {
                    if s[j] == 0x5C { j += 2; continue }
                    if s[j] == 0x24, j + 1 < end, s[j + 1] != 0x28 {
                        let varEnd = shellVariableEnd(j, end)
                        if varEnd > j + 1 {
                            emit(run, j, .string)
                            emit(j, varEnd, .parameter)
                            run = varEnd
                            j = varEnd
                            continue
                        }
                    }
                    j += 1
                }
                j = min(end, j + 1)
                emit(run, j, .string)
                i = j
                command = false
            case 0x24:
                if char(i + 1) == 0x27 {
                    let close = quoted(i + 1, limit: end)
                    emit(i, close, .string)
                    i = close
                } else if char(i + 1) == 0x28 {
                    i += 2
                    command = true
                } else {
                    let varEnd = shellVariableEnd(i, end)
                    emit(i, varEnd, .parameter)
                    i = max(varEnd, i + 1)
                }
            case 0x3C where char(i + 1) == 0x3C && char(i + 2) != 0x3C:
                var j = i + 2
                var strip = false
                if char(j) == 0x2D { strip = true; j += 1 }
                j = skipSpaces(j, end)
                var delimiterStart = j
                var delimiterEnd = j
                if char(j) == 0x27 || char(j) == 0x22 {
                    let close = quoted(j, limit: end, escapes: false)
                    delimiterStart = j + 1
                    delimiterEnd = close - 1
                    j = close
                } else {
                    while j < end, Self.isWord(s[j]) || s[j] == 0x2D { j += 1 }
                    delimiterEnd = j
                }
                if delimiterEnd > delimiterStart {
                    emit(i, j, .keyword)
                    heredocs.append((word(delimiterStart, delimiterEnd), strip))
                }
                i = max(j, i + 2)
            case 0x3B, 0x7C, 0x26, 0x28, 0x7B, 0x60:
                command = true
                i += 1
            default:
                guard Self.isWord(c) || c == 0x5B || c == 0x5D || c == 0x21 || c == 0x2D
                    || c == 0x2E || c == 0x2F
                else {
                    i += 1
                    continue
                }
                var j = i
                while j < end, Self.isWord(s[j]) || s[j] == 0x2D || s[j] == 0x2E || s[j] == 0x2F
                    || s[j] == 0x5B || s[j] == 0x5D || s[j] == 0x21 || s[j] == 0x3A || s[j] == 0x2B
                    || s[j] == 0x40 || s[j] == 0x25 || s[j] == 0x2C
                {
                    j += 1
                }
                if j < end, s[j] == 0x3D, command, s[i..<j].allSatisfy(Self.isWord) {
                    emit(i, j, .property)
                    i = j + 1
                    continue
                }
                let token = word(i, j)
                if dockerfile, token == "AS" || token == "as" {
                    emit(i, j, .keyword)
                    i = j
                    continue
                }
                if expectIn > 0 {
                    expectIn -= 1
                    if expectIn == 0, token == "in" {
                        emit(i, j, .keyword)
                        i = j
                        command = false
                        continue
                    }
                }
                if command, Self.shellKeywords.contains(token) {
                    emit(i, j, .keyword)
                    if token == "for" || token == "select" || token == "case" { expectIn = 2 }
                    if token == "function" {
                        let name = skipSpaces(j, end)
                        var nameEnd = name
                        while nameEnd < end, Self.isWord(s[nameEnd]) || s[nameEnd] == 0x2D { nameEnd += 1 }
                        emit(name, nameEnd, .functionName)
                        i = nameEnd
                        command = false
                        continue
                    }
                    // Declarations keep command position so `export NAME=` reads as an assignment.
                    command = !["unset", "return", "exit", "shift", "source", "for", "select", "case"]
                        .contains(token)
                    i = j
                    continue
                }
                let after = skipSpaces(j, end)
                if command, after + 1 < end, s[after] == 0x28, s[after + 1] == 0x29 {
                    emit(i, j, .functionName)
                } else if s[i..<j].allSatisfy(Self.isDigit) {
                    emit(i, j, .number)
                }
                command = false
                i = j
            }
        }
    }

    func shellVariableEnd(_ i: Int, _ end: Int) -> Int {
        var j = i + 1
        guard j < end else { return j }
        if s[j] == 0x7B {
            var depth = 0
            while j < end {
                if s[j] == 0x7B { depth += 1 }
                if s[j] == 0x7D { depth -= 1; if depth == 0 { return j + 1 } }
                if s[j] == Self.newline { return j }
                j += 1
            }
            return end
        }
        if [0x40, 0x2A, 0x23, 0x3F, 0x24, 0x21, 0x2D].contains(s[j]) || Self.isDigit(s[j]) {
            return j + 1
        }
        while j < end, Self.isWord(s[j]) { j += 1 }
        return j
    }

    // MARK: Makefile

    private static let makeDirectives: Set<String> = [
        "include", "-include", "sinclude", "ifeq", "ifneq", "ifdef", "ifndef", "else", "endif",
        "define", "endef", "export", "unexport", "override", "private", "vpath",
    ]

    mutating func makefile() {
        var i = 0
        while i < n {
            let ls = i
            let le = lineEnd(i)
            i = le + 1
            guard ls < le else { continue }
            if s[ls] == 0x09 {
                shell(ls + 1, le, dockerfile: false)
                makeVariables(ls, le)
                continue
            }
            let p = skipSpaces(ls, le)
            guard p < le else { continue }
            if s[p] == 0x23 {
                emit(p, trimEnd(p, le), .comment)
                continue
            }
            var w = p
            while w < le, !Self.isSpace(s[w]), s[w] != 0x3A, s[w] != 0x3D { w += 1 }
            if Self.makeDirectives.contains(word(p, w)) {
                emit(p, w, .keyword)
                makeVariables(w, le)
                continue
            }
            var j = p
            while j < le, s[j] != 0x3A, s[j] != 0x3D, s[j] != 0x23 { j += 1 }
            if j < le, s[j] == 0x3D
                || (s[j] == 0x3A && char(j + 1) == 0x3D)
                || (j > p && [0x3F, 0x2B, 0x21].contains(s[j - 1]) && s[j] == 0x3D)
            {
                var keyEnd = trimEnd(p, j)
                if keyEnd > p, [0x3F, 0x2B, 0x21, 0x3A].contains(s[keyEnd - 1]) { keyEnd -= 1 }
                emit(p, trimEnd(p, keyEnd), .property)
                makeVariables(j, le)
            } else if j < le, s[j] == 0x3A {
                emit(p, trimEnd(p, j), s[p] == 0x2E ? .keyword : .functionName)
                makeVariables(j, le)
                var comment = j
                while comment < le, s[comment] != 0x23 { comment += 1 }
                if comment < le { emit(comment, trimEnd(comment, le), .comment) }
            } else {
                makeVariables(p, le)
            }
        }
        spans.sort { $0.range.lowerBound < $1.range.lowerBound }
    }

    mutating func makeVariables(_ start: Int, _ end: Int) {
        var j = start
        while j < end {
            guard s[j] == 0x24, j + 1 < end else { j += 1; continue }
            let open = s[j + 1]
            if open == 0x28 || open == 0x7B {
                let close: UInt16 = open == 0x28 ? 0x29 : 0x7D
                var k = j + 2
                var depth = 1
                while k < end {
                    if s[k] == open { depth += 1 }
                    if s[k] == close { depth -= 1; if depth == 0 { break } }
                    k += 1
                }
                k = min(end, k + 1)
                spans.removeAll { $0.range.overlaps(j..<k) }
                emit(j, k, .parameter)
                j = k
            } else if [0x40, 0x3C, 0x5E, 0x2A, 0x3F, 0x25, 0x2B].contains(open) {
                emit(j, j + 2, .parameter)
                j += 2
            } else {
                j += 2
            }
        }
    }

    // MARK: Diff

    mutating func diff() {
        var i = 0
        while i < n {
            let ls = i
            let le = lineEnd(i)
            i = le + 1
            guard ls < le else { continue }
            let end = trimEnd(ls, le)
            if matches(ls, "+++") || matches(ls, "---") || matches(ls, "diff ")
                || matches(ls, "index ")
            {
                emit(ls, end, .declarationTitle)
            } else if matches(ls, "@@") {
                emit(ls, end, .attribute)
            } else if s[ls] == 0x2B {
                emit(ls, end, .string)
            } else if s[ls] == 0x2D {
                emit(ls, end, .keyword)
            }
        }
    }

    // MARK: Markup

    mutating func markup() {
        var i = 0
        while i < n {
            guard s[i] == 0x3C else {
                if s[i] == 0x26 {
                    var j = i + 1
                    while j < n, j - i < 12, Self.isWord(s[j]) || s[j] == 0x23 { j += 1 }
                    if j < n, s[j] == 0x3B, j > i + 1 {
                        emit(i, j + 1, .number)
                        i = j + 1
                        continue
                    }
                }
                i += 1
                continue
            }
            if matches(i, "<!--") {
                var j = i + 4
                while j < n, !matches(j, "-->") { j += 1 }
                j = min(n, j + 3)
                emit(i, j, .comment)
                i = j
                continue
            }
            if char(i + 1) == 0x21 || char(i + 1) == 0x3F {
                var j = i + 2
                while j < n, s[j] != 0x3E { j += 1 }
                j = min(n, j + 1)
                emit(i, j, char(i + 1) == 0x3F ? .attribute : .keyword)
                i = j
                continue
            }
            var j = i + 1
            if char(j) == 0x2F { j += 1 }
            guard j < n, Self.isAlpha(s[j]) || s[j] == 0x5F else {
                i += 1
                continue
            }
            while j < n, Self.isWord(s[j]) || s[j] == 0x2D || s[j] == 0x3A || s[j] == 0x2E { j += 1 }
            emit(i, j, .typeName)
            while j < n, s[j] != 0x3E, s[j] != 0x3C {
                let c = s[j]
                if c == 0x22 || c == 0x27 {
                    let close = quoted(j, limit: n, escapes: false)
                    emit(j, close, .string)
                    j = close
                } else if Self.isAlpha(c) || c == 0x5F || c == 0x40 || c == 0x3A {
                    var k = j
                    while k < n, Self.isWord(s[k]) || s[k] == 0x2D || s[k] == 0x3A
                        || s[k] == 0x2E || s[k] == 0x40
                    {
                        k += 1
                    }
                    emit(j, k, .property)
                    j = k
                } else if c == 0x2F, char(j + 1) == 0x3E {
                    break
                } else {
                    j += 1
                }
            }
            if j < n, s[j] == 0x2F { emit(j, j + 2, .typeName); j += 2 }
            else if j < n, s[j] == 0x3E { emit(j, j + 1, .typeName); j += 1 }
            i = j
        }
    }

    // MARK: Jinja

    private static let jinjaKeywords: Set<String> = [
        "if", "elif", "else", "endif", "for", "endfor", "in", "not", "and", "or", "is",
        "block", "endblock", "extends", "include", "import", "from", "as", "set", "endset",
        "macro", "endmacro", "call", "endcall", "filter", "endfilter", "with", "endwith",
        "raw", "endraw", "autoescape", "endautoescape", "recursive", "without", "context",
        "ignore", "missing", "scoped", "true", "false", "none", "True", "False", "None",
        "do", "break", "continue", "trans", "endtrans", "pluralize",
        // Go templates share the delimiters (Helm, Hugo).
        "define", "end", "range", "template", "nil",
    ]

    /// Emits template spans and returns every `{{ }}`, `{% %}`, `{# #}` region.
    mutating func jinjaRegions() -> [Range<Int>] {
        var regions: [Range<Int>] = []
        var i = 0
        var inRaw = false
        while i + 1 < n {
            guard s[i] == 0x7B else { i += 1; continue }
            let kind = s[i + 1]
            let close: UInt16
            switch kind {
            case 0x7B: close = 0x7D
            case 0x25: close = 0x25
            case 0x23: close = 0x23
            default: i += 1; continue
            }
            var j = i + 2
            var closeAt = -1
            while j + 1 < n {
                if kind != 0x23, s[j] == 0x22 || s[j] == 0x27 {
                    j = quoted(j, limit: n)
                    continue
                }
                if s[j] == close, s[j + 1] == 0x7D { closeAt = j; break }
                j += 1
            }
            guard closeAt >= 0 else { i += 2; continue }
            let end = closeAt + 2
            let tag = inner(i + 2, closeAt)
            if inRaw {
                if kind == 0x25, word(tag.lowerBound, tag.upperBound).hasPrefix("endraw") {
                    inRaw = false
                } else {
                    i += 2
                    continue
                }
            }
            regions.append(i..<end)
            if kind == 0x23 {
                emit(i, end, .comment)
            } else {
                var open = i + 2
                if open < closeAt, s[open] == 0x2D || s[open] == 0x2B || s[open] == 0x7E { open += 1 }
                var shut = closeAt
                if shut > open, s[shut - 1] == 0x2D || s[shut - 1] == 0x2B || s[shut - 1] == 0x7E { shut -= 1 }
                emit(i, open, .macro)
                jinjaExpression(open, shut)
                emit(shut, end, .macro)
                if kind == 0x25, word(tag.lowerBound, tag.upperBound).hasPrefix("raw") { inRaw = true }
            }
            i = end
        }
        return regions
    }

    private func inner(_ start: Int, _ end: Int) -> Range<Int> {
        var a = start
        while a < end, Self.isSpace(s[a]) || s[a] == 0x2D || s[a] == 0x2B || s[a] == Self.newline { a += 1 }
        var b = end
        while b > a, Self.isSpace(s[b - 1]) || s[b - 1] == 0x2D || s[b - 1] == Self.newline { b -= 1 }
        return a..<b
    }

    mutating func jinjaExpression(_ start: Int, _ end: Int) {
        var j = start
        var afterPipe = false
        var afterDot = false
        while j < end {
            let c = s[j]
            if c == 0x22 || c == 0x27 || c == 0x60 {
                let close = min(end, quoted(j, limit: end))
                emit(j, close, .string)
                j = close
                afterPipe = false
                afterDot = false
            } else if Self.isDigit(c) {
                var k = j
                while k < end, Self.isWord(s[k]) || s[k] == 0x2E { k += 1 }
                emit(j, k, .number)
                j = k
            } else if Self.isAlpha(c) || c == 0x5F || c == 0x24 {
                var k = j + 1
                while k < end, Self.isWord(s[k]) { k += 1 }
                let token = word(j, k)
                let next = skipSpaces(k, end)
                if afterPipe || (next < end && s[next] == 0x28) {
                    emit(j, k, .functionCall)
                } else if afterDot {
                    emit(j, k, .property)
                } else if Self.jinjaKeywords.contains(token) {
                    emit(j, k, .keyword)
                } else {
                    emit(j, k, .parameter)
                }
                afterPipe = false
                afterDot = false
                j = k
            } else {
                if c == 0x7C { afterPipe = true }
                if c == 0x2E { afterDot = true }
                j += 1
            }
        }
    }
}

/// Highlights short code excerpts (Markdown fences) by language hint, using
/// the source reader's tree-sitter passes where one exists and the lexical
/// formats otherwise.
public enum CodeSnippetHighlighter {
    public static let snippetUTF16Limit = 200_000

    public static func spans(for text: String, languageHint: String) -> [TextFormatSpan] {
        guard text.utf16.count <= snippetUTF16Limit else { return [] }
        let hint = languageHint.lowercased().split(separator: " ").first.map(String.init) ?? ""
        if let format = TextFormat.fromLanguageHint(hint) {
            return format.highlight(text)
        }
        let mode: LanguageMode
        switch hint {
        case "rust", "rs": mode = LanguageMode(language: .rust)
        case "python", "py", "python3", "pycon": mode = LanguageMode(language: .python)
        case "typescript", "ts", "mts", "cts": mode = LanguageMode(language: .typescript)
        case "tsx", "jsx", "javascript", "js", "mjs", "cjs":
            mode = LanguageMode(language: .typescript, variant: "tsx")
        default: return []
        }
        let bytes = Array(text.utf8)
        guard let highlighted = try? DocumentLoader.highlightWithFolds(
            bytes: bytes,
            languageMode: mode,
            resolutionObserver: nil
        ) else { return [] }
        let map = ByteUTF16Map(validUTF8: bytes)
        return highlighted.spans.compactMap { span in
            guard let range = map.nsRange(
                byteLowerBound: Int(span.range.lowerBound),
                byteUpperBound: Int(span.range.upperBound)
            ), range.length > 0 else { return nil }
            return TextFormatSpan(range: range.location..<(range.location + range.length), kind: span.kind)
        }
    }
}
