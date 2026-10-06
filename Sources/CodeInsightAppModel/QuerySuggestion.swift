import CodeInsightCore
import CodeInsightEngine
import Foundation

/// A complete replacement query, with a short explanation for the suggestion bubble.
public struct QuerySuggestion: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let explanation: String
    public let query: String
}

extension SearchPanelModel {
    public var suggestions: [QuerySuggestion] {
        guard suggestionsEnabled, syntaxError == nil,
              dismissedSuggestionRequest != requestID,
              !isSearching, !isStale
        else { return [] }
        return Self.suggestions(
            text: query, parsed: parsedQuery, total: totalMatches,
            truncated: isTruncated || displayTruncationMessage != nil,
            testDirectory: groups.filter { $0.path.split(separator: "/").contains("tests") }
                .max { $0.matches.count < $1.matches.count }
                .flatMap { group in
                    let parts = group.path.split(separator: "/")
                    return parts.firstIndex(of: "tests").map { parts[...$0].joined(separator: "/") + "/" }
                },
            learned: Set(defaults.stringArray(forKey: "query.learnedSyntax") ?? [])
        )
    }

    public func setSuggestionsEnabled(_ enabled: Bool) { suggestionsEnabled = enabled }
    public func dismissSuggestions() { dismissedSuggestionRequest = requestID }
    public func applySuggestion(_ suggestion: QuerySuggestion) { setQuery(suggestion.query) }

    func learnSyntax(_ query: ProjectSearchQuery) {
        var learned = Set(defaults.stringArray(forKey: "query.learnedSyntax") ?? [])
        if query.sameFunction { learned.insert("same") }
        if query.near != nil { learned.insert("near") }
        if !query.includeGlobs.isEmpty || !query.excludeGlobs.isEmpty { learned.insert("path") }
        if !query.includedAreas.isEmpty || !query.excludedAreas.isEmpty { learned.insert("in") }
        if !query.excludes.isEmpty { learned.insert("exclude") }
        if query.includes.contains(where: { $0.count > 1 }) { learned.insert("or") }
        defaults.set(learned.sorted(), forKey: "query.learnedSyntax")
    }

    static func suggestions(text: String, parsed: ProjectSearchQuery?, total: Int, truncated: Bool,
                            testDirectory: String?, learned: Set<String>) -> [QuerySuggestion] {
        var result: [QuerySuggestion] = []
        func add(_ id: String, _ query: String, _ note: String, feature: String? = nil) {
            guard feature.map({ !learned.contains($0) }) ?? true else { return }
            result.append(QuerySuggestion(id: id, title: query, explanation: localized("model.query.suggest." + note), query: query))
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add("example.same", "lock await same:fn", "same", feature: "same")
            add("example.path", "unwrap -path:tests/", "path", feature: "path")
            add("example.in", "TODO in:comment", "comment", feature: "in")
            add("example.or", "lock OR acquire", "or", feature: "or")
            return Array(result.prefix(3))
        }
        guard let parsed else { return [] }
        if total == 0 {
            if parsed.sameFunction {
                var next = parsed; next.sameFunction = false; next.near = 10
                add("relax.same", next.serialized, "near", feature: "near")
            }
            if let near = parsed.near {
                var next = parsed; next.near = min(333, near) * 3
                add("relax.near", next.serialized, "distance")
            }
            if !parsed.includedAreas.isEmpty || !parsed.excludedAreas.isEmpty {
                var next = parsed; next.includedAreas = []; next.excludedAreas = []
                add("relax.in", next.serialized, "area")
            }
            if !parsed.excludes.isEmpty {
                var next = parsed; next.excludes.removeLast()
                add("relax.exclude", next.serialized, "exclude")
            }
            if parsed.includes.count >= 2 {
                var next = parsed; let last = next.includes.removeLast(); next.includes[next.includes.count - 1] += last
                add("relax.or", next.serialized, "or", feature: "or")
            }
        } else if truncated {
            if parsed.includes.count >= 2, !parsed.sameFunction, parsed.near == nil {
                add("narrow.same", text + " same:fn", "same", feature: "same")
            }
            if parsed.includedAreas.isEmpty, parsed.excludedAreas.isEmpty {
                add("narrow.in", text + " in:code", "code", feature: "in")
            }
            if let testDirectory, parsed.includeGlobs.isEmpty, parsed.excludeGlobs.isEmpty {
                add("narrow.path", text + " -path:" + testDirectory, "path", feature: "path")
            }
        }
        return Array(result.prefix(3))
    }
}
