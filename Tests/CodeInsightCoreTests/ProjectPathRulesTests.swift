import Testing
@testable import CodeInsightCore

@Test
func projectPathRulesApplyDefaultsThenLastMatchingRuleWins() {
    let none = ProjectPathRules()
    #expect(none.verdict(for: "src/lib.rs", isDirectory: false) == .included)
    #expect(none.verdict(for: "target/debug/x.rs", isDirectory: false) == .skippedByDefault(directory: "target"))
    #expect(none.verdict(for: "target", isDirectory: true) == .skippedByDefault(directory: "target"))
    #expect(none.verdict(for: "src/build.rs", isDirectory: false) == .included, "a file name is not a directory")
    #expect(none.verdict(for: "target/x.rs", isDirectory: false, appliesDefaults: false) == .included)

    let rules = ProjectPathRules(lines: ["vendor/", "!vendor/keep/", "*.pb.rs", "!build/", "# comment", "  "])
    #expect(rules.verdict(for: "vendor", isDirectory: true) == .excludedByRule("vendor/"))
    #expect(rules.verdict(for: "vendor/keep/a.rs", isDirectory: false) == .included)
    #expect(rules.verdict(for: "src/api.pb.rs", isDirectory: false) == .excludedByRule("*.pb.rs"))
    #expect(rules.verdict(for: "build", isDirectory: true) == .included)
    #expect(rules.verdict(for: "build/target/y.rs", isDirectory: false) == .included,
            "the last matching rule wins over built-in skips, nested ones included")
    #expect(rules.verdict(for: "src/target/y.rs", isDirectory: false) == .skippedByDefault(directory: "target"))
    #expect(rules.lines.count == 6, "comments and blanks are kept as typed")

    let flipped = ProjectPathRules(lines: ["!vendor/", "vendor/"])
    #expect(flipped.verdict(for: "vendor/a.rs", isDirectory: false).isExcluded)
    let restored = ProjectPathRules(lines: ["vendor/", "!vendor/"])
    #expect(!restored.verdict(for: "vendor/a.rs", isDirectory: false).isExcluded)
}

@Test
func gitDirectoryStaysSkippedWhateverTheRulesSay() {
    let rules = ProjectPathRules(lines: ["!**", "!.git/"])
    #expect(rules.verdict(for: ".git", isDirectory: true) == .alwaysSkipped)
    #expect(rules.verdict(for: "sub/.git/config", isDirectory: false) == .alwaysSkipped)
    #expect(rules.verdict(for: "node_modules/x.ts", isDirectory: false) == .included)
}
