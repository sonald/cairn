import Testing
@testable import CodeInsightEngine

struct ProjectSearchQueryTests {
    @Test func alternativesBindMoreTightlyThanConjunctionAndQualifiersStayLiteral() throws {
        let query = try ProjectSearchQuery.parse("lock OR mutex await -test path:src/ -path:\"test fixtures/\" in:code -in:comment near:5 same:fn")
        #expect(query.includes.map { $0.map(\.text) } == [["lock", "mutex"], ["await"]])
        #expect(query.excludes.map(\.text) == ["test"])
        #expect(query.includeGlobs == ["src/"])
        #expect(query.excludeGlobs == ["test fixtures/"])
        #expect(query.includedAreas == [.code])
        #expect(query.excludedAreas == [.comment])
        #expect(query.near == 5)
        #expect(query.sameFunction)
        let punctuation = try ProjectSearchQuery.parse("std::sync http:// -> -= or")
        #expect(punctuation.includes.map { $0[0].text } == ["std::sync", "http://", "->", "-=", "or"])
        #expect(punctuation.excludes.isEmpty)
    }

    @Test func delimitersPreserveRegexEscapesAndLiteralPhrases() throws {
        let query = try ProjectSearchQuery.parse(#""fn spawn(\"x\")" /a\s+b\/c/ -"test case""#)
        #expect(query.includes == [[.init(text: "fn spawn(\"x\")", kind: .phrase)], [.init(text: #"a\s+b/c"#, kind: .regex)]])
        #expect(query.excludes == [.init(text: "test case", kind: .phrase)])
        #expect(try ProjectSearchQuery.parse(query.serialized) == query)
        #expect(try ProjectSearchQuery.parse(" \n\t ").isEmpty)
        #expect(try ProjectSearchQuery.parse("word").isSimpleWord)
    }

    @Test func invalidSyntaxReportsReasonAndUTF16Position() throws {
        let cases: [(String, ProjectSearchQuery.ParseError.Reason)] = [
            ("/[/", .invalidRegex), ("-a OR b", .excludedAlternative), ("a OR -b", .excludedAlternative),
            ("a OR path:src/", .qualifierAlternative), ("a OR", .missingAlternative),
            ("a OR OR b", .missingAlternative), ("a near:-1", .invalidNear),
            ("a same:f", .invalidSame), ("a in:unknown", .invalidArea),
            ("a path:", .missingValue), ("a -near:2", .excludedScope),
            ("a near:2 near:3", .duplicateScope), ("path:src/", .missingPositiveTerm),
            ("-a", .missingPositiveTerm), ("\"\"", .emptyTerm),
            ("a \"b", .unfinishedQuote), ("a /b", .unfinishedRegex),
            ("a ( b", .unsupportedGrouping), ("\"a\"b", .unexpectedToken)
        ]
        for (text, reason) in cases {
            do {
                _ = try ProjectSearchQuery.parse(text)
                Issue.record("Accepted invalid syntax: \(text)")
            } catch let error as ProjectSearchQuery.ParseError {
                #expect(error.reason == reason)
                #expect(error.range.lowerBound >= 0 && error.range.upperBound <= text.utf16.count)
                #expect(!error.range.isEmpty)
            }
        }
        #expect(throws: ProjectSearchQuery.ParseError.self) {
            try ProjectSearchQuery.parse("[", isRegex: true)
        }
        #expect(try ProjectSearchQuery.parse("\"[\"", isRegex: true).includes[0][0].kind == .phrase)
        do {
            _ = try ProjectSearchQuery.parse("😀 a same:f")
            Issue.record("Accepted invalid scope")
        } catch let error as ProjectSearchQuery.ParseError {
            #expect(error.range == 10..<11)
        }
    }

    @Test func queryGroupingIsRejectedWithoutChangingCodeOrRegexParentheses() throws {
        for text in ["(a OR b)", "a OR b)", "((a OR b))", "😀 (a OR b)"] {
            do {
                _ = try ProjectSearchQuery.parse(text)
                Issue.record("Accepted unsupported group: \(text)")
            } catch let error as ProjectSearchQuery.ParseError {
                #expect(error.reason == .unsupportedGrouping)
            }
        }
        #expect(try ProjectSearchQuery.parse("foo()").includes == [[.init(text: "foo()")]])
        #expect(try ProjectSearchQuery.parse("foo(bar)").includes == [[.init(text: "foo(bar)")]])
        #expect(try ProjectSearchQuery.parse(#""(a OR b)""#).includes == [[.init(text: "(a OR b)", kind: .phrase)]])
        #expect(try ProjectSearchQuery.parse("/(a|b)/").includes == [[.init(text: "(a|b)", kind: .regex)]])
        #expect(try ProjectSearchQuery.parse("(a|b)", isRegex: true).includes == [[.init(text: "(a|b)")]])
    }

    @Test func generatedQueriesRoundTripWithFixedSeed() throws {
        var seed: UInt64 = 0xC41_2026
        func pick(_ count: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 32) % UInt64(count))
        }
        let words = ["lock", "await", "std::sync", "http://", "->", "-=", "café", "变量", "emoji😀"]
        let phrases = ["fn spawn(", "a \"quote\"", "a\\b", "OR", "path:src/", "two\nlines"]
        let regexes = [#"a\s+b"#, "a/b", "[a-z]+", #"a\\b"#, "a b", "(foo|bar)"]
        func term() -> ProjectSearchQuery.Term {
            switch pick(3) {
            case 0: .init(text: words[pick(words.count)])
            case 1: .init(text: phrases[pick(phrases.count)], kind: .phrase)
            default: .init(text: regexes[pick(regexes.count)], kind: .regex)
            }
        }
        for _ in 0..<300 {
            let includes = (0..<(1 + pick(4))).map { _ in (0..<(1 + pick(3))).map { _ in term() } }
            let excludes = (0..<pick(3)).map { _ in term() }
            let query = ProjectSearchQuery(
                includes: includes, excludes: excludes,
                includeGlobs: pick(2) == 0 ? [] : ["src/**", "path with spaces/\"name\""],
                excludeGlobs: pick(2) == 0 ? [] : ["tests/", "a\\b"],
                includedAreas: Set(ProjectSearchQuery.Area.allCases.filter { _ in pick(2) == 0 }),
                excludedAreas: Set(ProjectSearchQuery.Area.allCases.filter { _ in pick(2) == 0 }),
                near: pick(2) == 0 ? nil : pick(30), sameFunction: pick(2) == 0)
            let parsed = try ProjectSearchQuery.parse(query.serialized)
            #expect(parsed == query)
            #expect(parsed.serialized == query.serialized)
        }
    }
}
