import Foundation

/// A project-relative path pattern: `*` (within one path component), `**`
/// (any number of components), `?`, and `{a,b}` alternatives. A trailing `/`
/// matches only what lies below a directory. A pattern containing `/` is
/// anchored at the project root; one without matches any component at any
/// depth, as in `.gitignore`. A matched directory covers everything below it.
package struct PathGlob: Sendable {
    package let pattern: String
    private let expression: NSRegularExpression

    /// nil for an empty or whitespace-only pattern.
    package init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        pattern = text
        if text.hasPrefix("./") { text.removeFirst(2) }
        var anchored = false
        if text.hasPrefix("/") {
            anchored = true
            text.removeFirst()
        }
        let directoryOnly = text.hasSuffix("/")
        while text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty else { return nil }
        anchored = anchored || text.contains("/")
        let body = Self.translate(Substring(text))
        let prefix = anchored ? "" : "(?:.*/)?"
        let suffix = directoryOnly ? "/.*" : "(?:/.*)?"
        guard let expression = try? NSRegularExpression(pattern: "^" + prefix + body + suffix + "$") else {
            return nil
        }
        self.expression = expression
    }

    /// Comma-separated patterns; commas inside `{…}` stay part of a pattern,
    /// and blanks are ignored.
    package static func list(_ text: String) -> [PathGlob] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        for character in text {
            switch character {
            case "{": depth += 1
            case "}": depth = max(0, depth - 1)
            case "," where depth == 0:
                parts.append(current)
                current = ""
                continue
            default: break
            }
            current.append(character)
        }
        parts.append(current)
        return parts.compactMap(PathGlob.init)
    }

    package func matches(_ path: String) -> Bool {
        let range = NSRange(path.startIndex..., in: path)
        return expression.firstMatch(in: path, range: range) != nil
    }

    private static func translate(_ glob: Substring) -> String {
        var result = ""
        var index = glob.startIndex
        while index < glob.endIndex {
            let character = glob[index]
            let next = glob.index(after: index)
            switch character {
            case "*" where next < glob.endIndex && glob[next] == "*":
                let afterStars = glob.index(after: next)
                if afterStars < glob.endIndex, glob[afterStars] == "/" {
                    result += "(?:.*/)?"
                    index = glob.index(after: afterStars)
                } else {
                    result += ".*"
                    index = afterStars
                }
                continue
            case "*":
                result += "[^/]*"
            case "?":
                result += "[^/]"
            case "{":
                if let close = glob[next...].firstIndex(of: "}") {
                    let alternatives = glob[next..<close].split(separator: ",", omittingEmptySubsequences: false)
                    result += "(?:" + alternatives.map { translate($0) }.joined(separator: "|") + ")"
                    index = glob.index(after: close)
                    continue
                }
                result += NSRegularExpression.escapedPattern(for: "{")
            default:
                result += NSRegularExpression.escapedPattern(for: String(character))
            }
            index = next
        }
        return result
    }
}
