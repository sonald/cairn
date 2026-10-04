/// Which project paths take part in reading, indexing and search.
///
/// Built-in skipped directories apply first (worktree only), then the user's
/// rules in order; the last matching rule wins. A rule starting with `!`
/// includes what it matches, so `!build/` brings a skipped directory back.
/// As with `.gitignore`, a file cannot be re-included while a parent
/// directory stays excluded: the walk never descends into that directory.
/// Rules are the user's own and live in application data, never in the
/// repository being read.
public struct ProjectPathRules: Equatable, Sendable {
    /// Directories skipped by default in a worktree; a `!` rule can restore them.
    public static let defaultSkippedDirectories = [
        "target", "node_modules", ".build", "venv", ".venv", "__pycache__", "dist", "build",
    ]
    /// Never part of a project, whatever the rules say.
    public static let alwaysSkippedDirectories = [".git"]

    public enum Verdict: Equatable, Sendable {
        case included
        case skippedByDefault(directory: String)
        case excludedByRule(String)
        case alwaysSkipped

        public var isExcluded: Bool { self != .included }
    }

    /// Rules as the user typed them, one per line; blanks and `#` comments are kept.
    public let lines: [String]
    private let rules: [(include: Bool, glob: PathGlob, line: String)]

    public init(lines: [String] = []) {
        self.lines = lines
        rules = lines.compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            let include = line.hasPrefix("!")
            guard let glob = PathGlob(include ? String(line.dropFirst()) : line) else { return nil }
            return (include, glob, line)
        }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.lines == rhs.lines }

    /// Whether any rule exists; without one the built-in behavior is unchanged.
    public var isEmpty: Bool { rules.isEmpty }

    /// The verdict for a project-relative `path`. Directory verdicts decide
    /// whether a walk descends; `appliesDefaults` is false for commit
    /// snapshots, whose tracked files are never hidden by built-in skips.
    public func verdict(for path: String, isDirectory: Bool, appliesDefaults: Bool = true) -> Verdict {
        let components = path.split(separator: "/").map(String.init)
        // A file's own name never counts as a skipped directory.
        let directories = isDirectory ? components : Array(components.dropLast())
        if directories.contains(where: Self.alwaysSkippedDirectories.contains) { return .alwaysSkipped }
        var verdict = Verdict.included
        if appliesDefaults, let skipped = directories.first(where: Self.defaultSkippedDirectories.contains) {
            verdict = .skippedByDefault(directory: skipped)
        }
        for rule in rules where isDirectory ? rule.glob.matchesDirectory(path) : rule.glob.matches(path) {
            verdict = rule.include ? .included : .excludedByRule(rule.line)
        }
        return verdict
    }
}
