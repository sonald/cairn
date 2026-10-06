import Foundation

/// A conjunction of alternative groups, evaluated within files, functions, or nearby lines.
public struct ProjectSearchQuery: Equatable, Sendable, Codable {
    public struct Term: Equatable, Sendable, Codable {
        public enum Kind: String, Sendable, Codable { case word, phrase, regex }
        public var text: String
        public var kind: Kind
        public init(text: String, kind: Kind = .word) {
            self.text = text
            self.kind = kind
        }
        public var serialized: String {
            switch kind {
            case .word: text
            case .phrase: ProjectSearchQuery.quoted(text)
            case .regex: "/" + text.replacingOccurrences(of: "/", with: "\\/") + "/"
            }
        }
    }

    public enum Area: String, CaseIterable, Sendable, Codable { case code, comment, string }

    public struct ParseError: LocalizedError, Equatable, Sendable {
        public enum Reason: String, Sendable {
            case unfinishedQuote, unfinishedRegex, missingValue, unexpectedToken
            case missingAlternative, excludedAlternative, qualifierAlternative
            case invalidArea, invalidNear, invalidSame, invalidRegex, excludedScope, duplicateScope
            case missingPositiveTerm, emptyTerm, unsupportedGrouping
        }
        public let reason: Reason
        /// Offsets in UTF-16, matching the text editor's selection coordinates.
        public let range: Range<Int>
        public init(reason: Reason, range: Range<Int>) {
            self.reason = reason
            self.range = range
        }
        public var localizationKey: String { "search.query.error." + reason.rawValue }
        public var errorDescription: String? {
            switch reason {
            case .unfinishedQuote: "Close the quoted phrase."
            case .unfinishedRegex: "Close the regular expression with /."
            case .missingValue: "Enter a value after the colon."
            case .unexpectedToken: "This token is not supported here."
            case .missingAlternative: "Enter a term on both sides of OR."
            case .excludedAlternative: "OR cannot join excluded terms."
            case .qualifierAlternative: "OR joins search terms, not filters."
            case .invalidArea: "Use code, comment, or string."
            case .invalidNear: "Enter a nonnegative line distance."
            case .invalidSame: "Only same:fn is supported."
            case .invalidRegex: "The regular expression is invalid."
            case .excludedScope: "A proximity or function scope cannot be excluded."
            case .duplicateScope: "Use only one proximity or function scope."
            case .missingPositiveTerm: "Add at least one included search term."
            case .emptyTerm: "A search term cannot be empty."
            case .unsupportedGrouping: "Parenthesized groups are not supported."
            }
        }
    }

    public var includes: [[Term]]
    public var excludes: [Term]
    public var includeGlobs: [String]
    public var excludeGlobs: [String]
    public var includedAreas: Set<Area>
    public var excludedAreas: Set<Area>
    public var near: Int?
    public var sameFunction: Bool

    public init(includes: [[Term]] = [], excludes: [Term] = [],
                includeGlobs: [String] = [], excludeGlobs: [String] = [],
                includedAreas: Set<Area> = [], excludedAreas: Set<Area> = [],
                near: Int? = nil, sameFunction: Bool = false) {
        self.includes = includes
        self.excludes = excludes.map(Self.exclusionTerm)
        self.includeGlobs = includeGlobs
        self.excludeGlobs = excludeGlobs
        self.includedAreas = includedAreas
        self.excludedAreas = excludedAreas
        self.near = near
        self.sameFunction = sameFunction
    }

    // A leading '-' only negates letters, numbers, _, quotes and regexes.
    // Punctuation exclusions made by condition controls therefore need a phrase.
    private static func exclusionTerm(_ term: Term) -> Term {
        guard term.kind == .word, let first = term.text.first,
              !(first.isLetter || first.isNumber || first == "_") else { return term }
        return Term(text: term.text, kind: .phrase)
    }

    public var isEmpty: Bool { self == Self() }
    public var groupsMatchesByLine: Bool {
        includes.count != 1 || includes[0].count != 1 || near != nil || sameFunction
    }
    public var isSimpleWord: Bool {
        includes.count == 1 && includes[0].count == 1 && includes[0][0].kind == .word
            && excludes.isEmpty && includeGlobs.isEmpty && excludeGlobs.isEmpty
            && includedAreas.isEmpty && excludedAreas.isEmpty && near == nil && !sameFunction
    }

    public var serialized: String {
        var parts = includes.map { $0.map(\.serialized).joined(separator: " OR ") }
        parts += excludes.map { "-" + Self.exclusionTerm($0).serialized }
        parts += includeGlobs.map { "path:" + Self.quoted($0) }
        parts += excludeGlobs.map { "-path:" + Self.quoted($0) }
        parts += Area.allCases.filter { includedAreas.contains($0) }.map { "in:" + $0.rawValue }
        parts += Area.allCases.filter { excludedAreas.contains($0) }.map { "-in:" + $0.rawValue }
        if let near { parts.append("near:\(near)") }
        if sameFunction { parts.append("same:fn") }
        return parts.joined(separator: " ")
    }

    /// Used when a selection or a paste into an empty field should stay one literal phrase.
    public static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    public static func parse(_ text: String, isRegex: Bool = false) throws -> Self {
        let characters = Array(text)
        var offsets = [0]
        for character in characters { offsets.append(offsets.last! + String(character).utf16.count) }
        var cursor = 0
        var result = Self()
        var previousWasPositive = false
        var expectingAlternative = false
        var orStart = 0
        func parseError(_ reason: ParseError.Reason, _ start: Int, _ end: Int? = nil) -> ParseError {
            ParseError(reason: reason, range: offsets[start]..<offsets[end ?? cursor])
        }
        func readDelimited(_ delimiter: Character, start: Int) throws -> String {
            cursor += 1
            var value = ""
            while cursor < characters.count {
                let character = characters[cursor]
                cursor += 1
                if character == delimiter { return value }
                if character == "\\", cursor < characters.count {
                    let next = characters[cursor]
                    if next == delimiter || (delimiter == "\"" && next == "\\") {
                        value.append(next)
                        cursor += 1
                        continue
                    }
                    // A regex escape belongs to the regex engine. Consume it as a pair
                    // so an escaped backslash cannot accidentally escape the closing slash.
                    if delimiter == "/" {
                        value.append(character)
                        value.append(next)
                        cursor += 1
                        continue
                    }
                }
                value.append(character)
            }
            throw parseError(delimiter == "\"" ? .unfinishedQuote : .unfinishedRegex, start)
        }
        while cursor < characters.count {
            if characters[cursor].isWhitespace { cursor += 1; continue }
            let start = cursor
            var excluded = false
            if characters[cursor] == "-", cursor + 1 < characters.count {
                let next = characters[cursor + 1]
                if next.isLetter || next.isNumber || next == "_" || next == "\"" || next == "/" {
                    excluded = true
                    cursor += 1
                }
            }
            var qualifier: String?
            for known in ["path", "in", "near", "same"] {
                let prefix = Array(known + ":")
                if characters[cursor...].starts(with: prefix) {
                    qualifier = known
                    cursor += prefix.count
                    break
                }
            }
            let valueStart = cursor
            if cursor == characters.count || characters[cursor].isWhitespace {
                throw parseError(.missingValue, start)
            }
            let kind: Term.Kind
            let value: String
            if characters[cursor] == "\"" {
                kind = .phrase
                value = try readDelimited("\"", start: valueStart)
            } else if characters[cursor] == "/" && qualifier == nil {
                kind = .regex
                value = try readDelimited("/", start: valueStart)
            } else {
                kind = .word
                while cursor < characters.count && !characters[cursor].isWhitespace { cursor += 1 }
                value = String(characters[valueStart..<cursor])
            }
            guard cursor == characters.count || characters[cursor].isWhitespace else {
                throw parseError(.unexpectedToken, cursor, cursor + 1)
            }
            guard !value.isEmpty else { throw parseError(.emptyTerm, start) }
            if qualifier == nil && kind == .word && value == "OR" && !excluded {
                guard previousWasPositive && !expectingAlternative else {
                    throw parseError(previousWasPositive ? .missingAlternative : .excludedAlternative, start)
                }
                expectingAlternative = true
                orStart = start
                continue
            }
            if expectingAlternative && (excluded || qualifier != nil) {
                throw parseError(excluded ? .excludedAlternative : .qualifierAlternative, start)
            }
            if let qualifier {
                switch qualifier {
                case "path":
                    if excluded { result.excludeGlobs.append(value) } else { result.includeGlobs.append(value) }
                case "in":
                    guard let area = Area(rawValue: value) else { throw parseError(.invalidArea, valueStart) }
                    if excluded { result.excludedAreas.insert(area) } else { result.includedAreas.insert(area) }
                case "near":
                    guard !excluded else { throw parseError(.excludedScope, start) }
                    guard value.allSatisfy(\.isNumber), let distance = Int(value), distance >= 0 else {
                        throw parseError(.invalidNear, valueStart)
                    }
                    guard result.near == nil else { throw parseError(.duplicateScope, start) }
                    result.near = distance
                default:
                    guard !excluded else { throw parseError(.excludedScope, start) }
                    guard value == "fn" else { throw parseError(.invalidSame, valueStart) }
                    guard !result.sameFunction else { throw parseError(.duplicateScope, start) }
                    result.sameFunction = true
                }
                previousWasPositive = false
            } else {
                if kind == .word && (value == "(" || value == ")" || (!isRegex &&
                    (value.hasPrefix("(") || (value.hasSuffix(")") && !value.contains("("))))) {
                    throw parseError(.unsupportedGrouping, start)
                }
                if kind == .regex || (kind == .word && isRegex) {
                    do { _ = try NSRegularExpression(pattern: value) }
                    catch { throw parseError(.invalidRegex, valueStart) }
                }
                let term = Term(text: value, kind: kind)
                if excluded { result.excludes.append(term) }
                else if expectingAlternative { result.includes[result.includes.count - 1].append(term) }
                else { result.includes.append([term]) }
                previousWasPositive = !excluded
                expectingAlternative = false
            }
        }
        if expectingAlternative { throw parseError(.missingAlternative, orStart) }
        if result.includes.isEmpty && !result.isEmpty { throw parseError(.missingPositiveTerm, 0) }
        return result
    }
}
