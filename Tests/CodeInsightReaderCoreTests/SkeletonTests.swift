import CodeInsightCore
import CodeInsightReaderCore
import Foundation
import Testing

/// The skeleton is a derived text whose every line maps back to source
/// lines; these tests hold the mapping invariants on real and mutated input.
@Suite struct SkeletonTests {
    @Test func everyLineMapsInsideTheFileAndGutterNumbersStrictlyIncrease() throws {
        for (label, bytes, language, variant) in try inputs() {
            let lines = try #require(distillSkeleton(bytes: bytes, language: language, variant: variant), "\(label)")
            #expect(!lines.isEmpty, "\(label)")
            let issues = mappingIssues(lines, bytes: bytes)
            #expect(issues.isEmpty, "\(label): \(issues.prefix(5))")
        }
    }

    @Test func linesUseOnlyIdentifiersOfTheirOwnSourceLines() throws {
        for (label, bytes, language, variant) in try inputs() {
            let lines = try #require(distillSkeleton(bytes: bytes, language: language, variant: variant), "\(label)")
            let issues = identifierIssues(lines, bytes: bytes)
            #expect(issues.isEmpty, "\(label): \(issues.prefix(5))")
        }
    }

    @Test func distillingTheSameBytesTwiceGivesTheSameSkeleton() throws {
        let all = try inputs()
        let first = all.map { distillSkeleton(bytes: $0.bytes, language: $0.language, variant: $0.variant) }
        // Other files in between must not leave anything behind.
        let second = all.reversed().map {
            distillSkeleton(bytes: $0.bytes, language: $0.language, variant: $0.variant)
        }.reversed()
        for (index, (a, b)) in zip(first, second).enumerated() {
            #expect(a == b, "\(all[index].label)")
        }
    }

    @Test func lineEndingsAndIndentationDoNotChangeTheSkeleton() throws {
        let rust = try mainRs()
        let expected = try #require(distillSkeleton(bytes: rust, language: .rust))
        #expect(distillSkeleton(bytes: crlf(rust), language: .rust) == expected)
        #expect(distillSkeleton(bytes: unindented(rust), language: .rust) == expected)

        let python = Array(pythonSample.utf8)
        let expectedPython = try #require(distillSkeleton(bytes: python, language: .python))
        #expect(distillSkeleton(bytes: crlf(python), language: .python) == expectedPython)

        let typeScript = Array(typeScriptSample.utf8)
        let expectedTypeScript = try #require(distillSkeleton(bytes: typeScript, language: .typescript))
        #expect(distillSkeleton(bytes: crlf(typeScript), language: .typescript) == expectedTypeScript)

        let go = Array(goSample.utf8)
        let expectedGo = try #require(distillSkeleton(bytes: go, language: .go))
        #expect(distillSkeleton(bytes: crlf(go), language: .go) == expectedGo)
        #expect(distillSkeleton(bytes: unindented(go), language: .go) == expectedGo)
    }

    @Test func brokenSourceNeverCrashesAndKeepsTheInvariants() throws {
        var generator = SplitMix64(seed: 0x5EED_2026_1121)
        var distilled = 0
        for (label, bytes, language, variant) in [("main.rs", try mainRs(), LanguageID.rust, nil),
                                                  ("sample.rs", Array(rustSample.utf8), .rust, nil),
                                                  ("sample.py", Array(pythonSample.utf8), .python, nil),
                                                  ("sample.ts", Array(typeScriptSample.utf8), .typescript, nil),
                                                  ("sample.tsx", Array(tsxSample.utf8), .typescript, "tsx"),
                                                  ("sample.go", Array(goSample.utf8), .go, nil)] {
            for index in 0..<60 {
                let mutated = mutate(bytes, &generator)
                let name = "\(label) mutation \(index) (\(mutated.kind))"
                guard let lines = distillSkeleton(bytes: mutated.bytes, language: language, variant: variant)
                else { continue }
                distilled += 1
                let issues = mappingIssues(lines, bytes: mutated.bytes) + identifierIssues(lines, bytes: mutated.bytes)
                #expect(issues.isEmpty, "\(name): \(issues.prefix(5))")
                #expect(distillSkeleton(bytes: mutated.bytes, language: language, variant: variant) == lines, "\(name)")
            }
        }
        // Parsing recovers from errors, so most mutations still distil.
        #expect(distilled > 250)
        // Thousands of nested blocks: the walk must not exhaust the stack.
        let depth = 3000
        let nested = "fn main() {\n" + String(repeating: "if a {\n", count: depth) + "step();\n"
            + String(repeating: "}\n", count: depth + 1) + "fn step() {}\n"
        let deep = try #require(distillSkeleton(bytes: Array(nested.utf8), language: .rust))
        #expect(mappingIssues(deep, bytes: Array(nested.utf8)).isEmpty)
        // A long `+` chain nests one binary node per term. The reader distils
        // off the main thread, and test bodies also run on small stacks.
        let terms = Array(repeating: "a", count: 5000).joined(separator: " + ")
        for (source, language) in [("fn main() {\n    let x = \(terms);\n    step(x);\n}\nfn step(_: u8) {}\n", LanguageID.rust),
                                   ("def main():\n    x = \(terms)\n    step(x)\n\ndef step(x):\n    pass\n", .python),
                                   ("function main() {\n    const x = \(terms);\n    step(x);\n}\nfunction step(x) {}\n", .typescript),
                                   ("func main() {\n\tx := \(terms)\n\tstep(x)\n}\nfunc step(x int) {}\n", .go)] {
            let chain = try #require(distillSkeleton(bytes: Array(source.utf8), language: language))
            #expect(mappingIssues(chain, bytes: Array(source.utf8)).isEmpty, "\(language)")
        }
        for empty in [[], Array("\n".utf8), Array("\r\n\r\n".utf8)] as [[UInt8]] {
            #expect(distillSkeleton(bytes: empty, language: .rust) == [])
            #expect(distillSkeleton(bytes: empty, language: .python) == [])
            #expect(distillSkeleton(bytes: empty, language: .typescript) == [])
            #expect(distillSkeleton(bytes: empty, language: .go) == [])
        }
    }

    @Test func landingFollowsSourcePositionAndLeavingThenReenteringNeverDrifts() throws {
        var maps = try inputs().map { input in
            SkeletonLineMap(try #require(distillSkeleton(bytes: input.bytes, language: input.language, variant: input.variant)))
        }
        // Generated maps add what real skeletons rarely have: overlaps,
        // gaps, blank runs at either end, no rows at all. Starts always grow.
        var generator = SplitMix64(seed: 0x5EED_2026_1122)
        for _ in 0..<300 {
            var lower = 0
            maps.append(SkeletonLineMap((0..<generator.next(12)).map { _ in
                guard generator.next(5) != 0 else { return SkeletonLine(text: "", sourceLines: nil) }
                lower += 1 + generator.next(4)
                return SkeletonLine(text: "x", sourceLines: lower...(lower + generator.next(6)))
            }))
        }
        for (index, map) in maps.enumerated() {
            let mapped = map.ranges.compactMap { $0 }
            let starts = mapped.map(\.lowerBound)
            for line in 0...((mapped.map(\.upperBound).max() ?? 0) + 2) {
                guard let row = map.row(forSourceLine: line) else {
                    #expect(mapped.isEmpty, "map \(index) line \(line)")
                    continue
                }
                let range = try #require(map.ranges[row])
                let containing = mapped.filter { $0.contains(line) }
                if let start = containing.map(\.lowerBound).max() {
                    #expect(range.lowerBound == start, "map \(index) line \(line)")
                } else if let next = starts.filter({ $0 > line }).min() {
                    #expect(range.lowerBound == next, "map \(index) line \(line)")
                } else {
                    #expect(range.lowerBound == starts.max(), "map \(index) line \(line)")
                }
            }
            for row in map.ranges.indices {
                let line = map.sourceLine(ofRow: row)
                if let range = map.ranges[row] {
                    #expect(map.label(ofRow: row) == range.lowerBound && line == range.lowerBound)
                    // Leaving from a row, then entering again, lands on a row
                    // with the same source line: persisted positions never creep.
                    let back = try #require(map.row(forSourceLine: range.lowerBound))
                    #expect(map.sourceLine(ofRow: back) == range.lowerBound, "map \(index) row \(row)")
                } else {
                    #expect(map.label(ofRow: row) == nil)
                    let after = map.ranges[row...].compactMap { $0?.lowerBound }.first
                    let before = map.ranges[..<row].compactMap { $0?.lowerBound }.last
                    #expect(line == (after ?? before), "map \(index) row \(row)")
                }
            }
        }
    }

    @Test func overviewDocumentHasOneLinePerSkeletonRowAndNoFolds() throws {
        for (label, bytes, language, variant) in try inputs() {
            let lines = try #require(distillSkeleton(bytes: bytes, language: language, variant: variant))
            let source = ReaderDocument(
                bytes: bytes, languageMode: LanguageMode(language: language, variant: variant),
                lineTable: LineTable(bytes: bytes), byteUTF16Map: ByteUTF16Map(validUTF8: bytes),
                highlightSpans: [], outlineFacets: [], foldRegions: []
            )
            let overview = try #require(SkeletonOverview(source: source), "\(label)")
            #expect(overview.document.lineTable.lineStarts.count == lines.count, "\(label)")
            #expect(String(decoding: overview.document.bytes, as: UTF8.self) == lines.map(\.text).joined(separator: "\n"))
            #expect(overview.document.foldRegions.isEmpty && overview.document.outlineFacets.isEmpty)
            #expect(!overview.document.highlightSpans.isEmpty, "\(label)")
            #expect(overview.map == SkeletonLineMap(lines))
        }
    }

    @Test func mainRsReadsInSourceOrderWithHelpersAsSignatures() throws {
        let bytes = try mainRs()
        let lines = try #require(distillSkeleton(bytes: bytes, language: .rust))
        // main.rs changes; find the expected source lines in its text.
        let source = sourceLines(bytes)
        let adapterKind = try #require(source.firstIndex { $0.hasPrefix("fn adapter_kind(") }) + 1
        let adapterKindEnd = try #require(source[adapterKind...].firstIndex { $0 == "}" }) + 1
        let mainHeader = try #require(source.firstIndex { $0.hasPrefix("async fn main(") }) + 1
        let texts = lines.map(\.text)
        let signatures = texts.filter { $0.hasPrefix("fn ") && $0.hasSuffix(" {") }
            .map { String($0.dropFirst(3).prefix { $0 != "(" }) }
        #expect(signatures == ["endpoint", "client", "run_round", "stream_round", "trim", "list_models", "handle", "main"])

        let helpers = lines.filter { $0.text.hasPrefix("fn ") && $0.text.hasSuffix(" { … }") }
        #expect(helpers.map { String($0.text.dropFirst(3).prefix { $0 != "(" }) }
            == ["adapter_kind", "send", "too_long", "drop_unanswered_calls"])
        // Type rows run together; a distilled function stands apart from them.
        let firstFunction = try #require(lines.firstIndex { $0.text.hasPrefix("fn endpoint(") })
        #expect(lines[firstFunction - 1].sourceLines == nil)
        #expect(lines[..<(firstFunction - 1)].allSatisfy { $0.sourceLines != nil })
        // A helper's one row stands for its whole function.
        #expect(helpers.first?.text == "fn adapter_kind(config) -> AdapterKind { … }")
        #expect(helpers.first?.sourceLines == adapterKind...adapterKindEnd)

        for line in [
            "    let request = serde_json::from_str(line)?;",
            "        ListModels { conversation, config } => { spawn(list_models(out, conversation, config)); return; }",
            "    if let Some(entry) = map.get_mut(id) { entry.round = Some(task); }",
            "        let conversation = map.get(id)?;",
        ] {
            #expect(texts.contains(line), "\(line)")
        }
        // The signature maps to its header line only, not the attribute or body.
        let main = try #require(lines.first { $0.text == "fn main() {" })
        #expect(main.sourceLines == mainHeader...mainHeader)
    }

    @Test func pythonMethodsAndFunctionsSharingANameStayApart() throws {
        let lines = try #require(distillSkeleton(bytes: Array(pythonSample.utf8), language: .python))
        let defs = lines.map(\.text).filter { $0.hasPrefix("def ") }
        #expect(defs == [
            "def __init__(self, width=70, *, tabsize=8): …",
            "def fill(self, text):",
            "def wrap(self, text):",
            "def _note(self): …",
            "def _split(self, text):",
            "def _expand(self, chunks):",
            "def fill(text, width=70): …",
            "def 宽度(文本, 列=\"中文 é 😀\"):",
            "def run(text, wrap=str.split): …",
        ])
        // The class row stands where the class starts, its methods after it.
        let classRow = try #require(lines.firstIndex { $0.text == "class Wrapper(object):" })
        #expect(lines[classRow + 1].text == "def __init__(self, width=70, *, tabsize=8): …")
        #expect(lines.contains { $0.text == "    return \"\\n\".join(self.wrap(text))" && $0.sourceLines == 13...13 })
    }

    @Test func typeScriptReadsAsSignaturesAndKeyStatementsWithoutTypes() throws {
        let bytes = Array(typeScriptSample.utf8)
        let lines = try #require(distillSkeleton(bytes: bytes, language: .typescript))
        let texts = lines.map(\.text)
        #expect(texts.filter { !$0.isEmpty && !$0.hasPrefix(" ") && $0 != "}" } == [
            "enum Mode { Fast, Slow, \"中文\" }",
            "interface Options { width, label, render }",
            "type Pair = { left, right }",
            "type Name",
            "const 宽度 = (文本, 列 = 2): number => 文本.length * 列",
            "function main(path, ...rest): Promise<void> {",
            "function lines(path): string[] { … }",
            "class Engine extends Base implements Runner",
            "constructor(options) { … }",
            "feed(line, limit): Promise<void> {",
            "static get size(): number { … }",
            "measure = (line): number => {",
            "finish<T>(): T { … }",
        ])
        for line in [
            "    const first = lines(path)[0];",
            "    return engine.finish();",
            "    lines(`${path}…`);",
            "    const tail = lines(path);",
            "    const later = () => { lines(path); };",
            "    const width = this.measure(line);",
            "    if (this.ready()) { this.total = this.parse(line).length; }",
            "        case Mode.Slow: { this.flush(); break; }",
            "    } catch (error) {",
            "    return 宽度(line, this.options.width) + \"😀\".length;",
        ] {
            #expect(texts.contains(line), "\(line)")
        }
        // A case's own line maps to that source line; its statements follow it.
        let source = sourceLines(bytes)
        let fast = try #require(source.firstIndex { $0.contains("case Mode.Fast:") }) + 1
        let caseRow = try #require(lines.firstIndex { $0.text == "        case Mode.Fast:" })
        #expect(lines[caseRow].sourceLines == fast...fast)
        #expect(lines[caseRow + 1].text == "            this.total += width;")

        let tsx = try #require(distillSkeleton(bytes: Array(tsxSample.utf8), language: .typescript, variant: "tsx"))
        let tsxTexts = tsx.map(\.text)
        for line in [
            "function List({ title, items }): JSX.Element {",
            "    const toggle = () => { track(\"toggle\"); };",
            "const Row = ({ label }) => <li className=\"row\">{label}</li>",
            "handle = (event) => {",
            "    this.save(event);",
        ] {
            #expect(tsxTexts.contains(line), "\(line)")
        }
        // The JSX return is one line, cut at a word boundary.
        let jsx = try #require(tsxTexts.first { $0.hasPrefix("    return (<section") })
        #expect(jsx.count <= 4 + 120 && jsx.hasSuffix("…"))
    }

    @Test func goReadsMethodsByNameAndKeepsTheSuccessPath() throws {
        let bytes = Array(goSample.utf8)
        let lines = try #require(distillSkeleton(bytes: bytes, language: .go))
        let texts = lines.map(\.text)
        #expect(texts.filter { !$0.isEmpty && !$0.hasPrefix(" ") && $0 != "}" } == [
            "type Mode",
            "type Options struct { Width, Height, Label, Base, 宽度 }",
            "type Runner interface { Run, Stringer, Close }",
            "Pair struct { Left, Right }",
            "Name",
            "type Engine struct { options, total, out }",
            "func main() {",
            "func init() {",
            "func NewEngine(options) (*Engine[string], error) { … }",
            "func Feed(line) error {",
            "func loop() {",
            "func measure(line) (int, error) { … }",
            "func check(n) error { … }",
            "func flush() { … }",
            "func Close() error { … }",
            "func lines(path, rest) []string { … }",
            "func register(name, options) { … }",
            "func Reload() []string {",
            "func load() ([]string, error) { … }",
            "func ExampleConfig() *Options { … }",
        ])
        for line in [
            "    e := NewEngine(Options{Width: 80})",
            "    go e.loop()",
            "    defer e.Close()",
            "    register(`engine…`, Options{})",
            "    n := e.measure(line)",
            "    e.check(n)",
            "    e.out <- line",
            "                e.Feed(line)",
            // A check that does not return keeps its error.
            "    data, err := e.load()",
            "    if err != nil { data = lines(\"fallback\") }",
        ] {
            #expect(texts.contains(line), "\(line)")
        }
        // Exits on an error go; so do returns of only an error.
        #expect(texts.filter { $0.contains("err != nil") } == ["    if err != nil { data = lines(\"fallback\") }"])
        #expect(!texts.contains { $0.contains("errors.New") || $0.contains("errNegative") })
        // A returning error check is never asked about, so no score brings it back.
        let questions = try #require(SkeletonQuestions(bytes: bytes, language: .go))
        let allKept = try #require(distillSkeleton(
            bytes: bytes, language: .go, scores: Dictionary(uniqueKeysWithValues: questions.questions.map { ($0.id, 1.0) })
        ))
        #expect(allKept.map(\.text).filter { $0.contains("err != nil") } == ["    if err != nil { data = lines(\"fallback\") }"])
        #expect(!questions.questions.contains { $0.instructions.contains("`if err != nil") })
        // A case's own line maps to that source line.
        let source = sourceLines(bytes)
        let fast = try #require(source.firstIndex { $0.contains("case \"fast\":") }) + 1
        let caseRow = try #require(lines.first { $0.text == "        case \"fast\": e.total += n" })
        #expect(caseRow.sourceLines == fast...(fast + 1))
    }
}

/// Scores from a service only choose among what the rules already offer:
/// these hold the rule-based invariants under any scores, and tie the
/// questions to the choices the distiller makes.
@Suite struct SkeletonScoreTests {
    @Test func anyScoresKeepTheMappingInvariantsAndUnaskedIdsChangeNothing() throws {
        var generator = SplitMix64(seed: 0x5EED_2026_1123)
        for (label, bytes, language, variant) in try inputs() {
            let questions = try #require(SkeletonQuestions(bytes: bytes, language: language, variant: variant), "\(label)")
            for round in 0..<12 {
                var scores = randomScores(questions, &generator)
                let lines = try #require(distillSkeleton(bytes: bytes, language: language, variant: variant, scores: scores))
                let issues = mappingIssues(lines, bytes: bytes) + identifierIssues(lines, bytes: bytes)
                #expect(issues.isEmpty, "\(label) round \(round): \(issues.prefix(5))")
                #expect(distillSkeleton(bytes: bytes, language: language, variant: variant, scores: scores) == lines)
                for _ in 0..<20 { scores["s\(generator.next(bytes.count))x"] = 1; scores["f\(generator.next(99))?"] = 0 }
                #expect(distillSkeleton(bytes: bytes, language: language, variant: variant, scores: scores) == lines, "\(label)")
            }
        }
    }

    @Test func allZeroScoresKeepOnlyTheEntriesWithTheirRuleStatements() throws {
        for (label, bytes, language, variant) in try inputs() {
            let questions = try #require(SkeletonQuestions(bytes: bytes, language: language, variant: variant))
            let zero = Dictionary(questions.questions.map { ($0.id, 0.0) }) { first, _ in first }
            let ruled = mainSections(try #require(distillSkeleton(bytes: bytes, language: language, variant: variant)))
            let zeroed = mainSections(try #require(distillSkeleton(bytes: bytes, language: language, variant: variant, scores: zero)))
            let candidates = Set(questions.questions.filter { $0.id.hasPrefix("f") }.map(\.lines.lowerBound))
            #expect(!zeroed.isEmpty, "\(label)")
            #expect(zeroed == ruled.filter { !candidates.contains($0.key) }, "\(label)")
        }
    }

    /// "Lines" are row first lines, the gutter numbers: keeping one more
    /// statement can split a joined row, so row text is not monotone.
    @Test func raisingAScoreNeverDropsARowOfAFunctionStillOnTheMainLine() throws {
        var generator = SplitMix64(seed: 0x5EED_2026_1124)
        for (label, bytes, language, variant) in try inputs() {
            let questions = try #require(SkeletonQuestions(bytes: bytes, language: language, variant: variant))
            let zero = Dictionary(questions.questions.map { ($0.id, 0.0) }) { first, _ in first }
            // Each question raised alone from the rules, then random raises from random scores.
            for round in 0..<(questions.questions.count + 40) {
                let single = round < questions.questions.count
                var scores = single ? zero : randomScores(questions, &generator)
                let before = mainSections(try #require(distillSkeleton(bytes: bytes, language: language, variant: variant, scores: scores)))
                let raised = questions.questions[single ? round : generator.next(questions.questions.count)].id
                scores[raised] = max(scores[raised] ?? 0, 0.5 + Double(generator.next(51)) / 100)
                let after = mainSections(try #require(distillSkeleton(bytes: bytes, language: language, variant: variant, scores: scores)))
                for (start, rows) in before {
                    guard let raisedRows = after[start] else { continue }
                    let lost = Set(rows.compactMap { $0.sourceLines?.lowerBound })
                        .subtracting(raisedRows.compactMap { $0.sourceLines?.lowerBound })
                    #expect(lost.isEmpty, "\(label) round \(round) raising \(raised): function at \(start) lost \(lost.sorted())")
                }
            }
        }
    }

    @Test func everyQuestionIsAChoiceTheDistillerMakes() throws {
        var generator = SplitMix64(seed: 0x5EED_2026_1125)
        for (label, bytes, language, variant) in try inputs() {
            let questions = try #require(SkeletonQuestions(bytes: bytes, language: language, variant: variant))
            let ones = Dictionary(questions.questions.map { ($0.id, 1.0) }) { first, _ in first }
            let kept = try #require(distillSkeleton(bytes: bytes, language: language, variant: variant, scores: ones))
            for _ in 0..<40 {
                let question = questions.questions[generator.next(questions.questions.count)]
                var scores = ones
                scores[question.id] = 0
                #expect(distillSkeleton(bytes: bytes, language: language, variant: variant, scores: scores) != kept,
                        "\(label): \(question.id) changes nothing")
            }
        }
    }

    @Test func questionsAreUniqueStableAndPointIntoTheState() throws {
        for (label, bytes, language, variant) in try inputs() {
            let first = try #require(SkeletonQuestions(bytes: bytes, language: language, variant: variant))
            let second = try #require(SkeletonQuestions(bytes: bytes, language: language, variant: variant))
            #expect(first.questions == second.questions && first.state == second.state
                && first.requestBody == second.requestBody, "\(label)")
            #expect(Set(first.questions.map(\.id)).count == first.questions.count, "\(label)")
            let lineCount = sourceLines(bytes).count - (bytes.last == 0x0A ? 1 : 0)
            let stateLines = Set(first.state.split(separator: "\n").compactMap { Int($0.prefix { $0 != " " }) })
            for question in first.questions {
                #expect(question.lines.lowerBound >= 1 && question.lines.upperBound <= lineCount, "\(label) \(question.id)")
                #expect(stateLines.contains(question.lines.lowerBound), "\(label) \(question.id)")
                let span = "\(question.lines.lowerBound)-\(question.lines.upperBound)"
                let shaped = question.id.hasPrefix("f")
                    ? question.instructions.hasPrefix("Is the function `")
                        && question.instructions.hasSuffix("` (lines \(span)) part of this file's main logic, as opposed to a small helper, accessor, conversion or formatting utility?")
                    : question.instructions.hasPrefix("Look only at the statement on lines \(span), which starts `")
                        && question.instructions.contains("`. Is it part of the main work of `")
                        && question.instructions.hasSuffix("`: it calls a function of this file, changes state, produces the result, or decides the main control flow? Logging, error reporting, early exits on failure, value conversion and setup of minor values are not main work.")
                #expect(shaped, "\(label): \(question.instructions)")
            }
            let body = try #require(JSONSerialization.jsonObject(with: first.requestBody) as? [String: Any])
            #expect(body["model"] as? String == "jev-latest" && body["state"] as? String == first.state)
            let asked = try #require(body["questions"] as? [String: [String: String]])
            #expect(asked.count == first.questions.count)
            for question in first.questions {
                #expect(asked[question.id] == ["type": "noul", "instructions": question.instructions])
            }
        }
    }

    @Test func stateLeavesOutCommentsAndDocstringsButKeepsCode() throws {
        let rust = Array(#"""
        //! SENTINEL inner doc
        /// SENTINEL outer doc
        fn main() {
            // SENTINEL line comment
            let url = "https://example.com/#x"; // SENTINEL trailing
            step(url /* SENTINEL inline */, 2);
            /* SENTINEL
               block */
            log(url);
        }
        fn step(_: &str, _: u8) {}
        fn log(_: &str) {}
        """#.utf8)
        let python = Array(pythonSample.utf8) + Array(#"""

        def main():
            '''SENTINEL docstring'''
            note = "# not a comment"  # SENTINEL trailing
            # SENTINEL line
            wrap = fill(note)
            print(wrap)
        """#.utf8)
        let typeScript = Array(#"""
        /** SENTINEL jsdoc */
        export function main(): void {
            // SENTINEL line comment
            const url = "https://example.com/#x"; // SENTINEL trailing
            step(url /* SENTINEL inline */, 2);
            log(url);
        }
        function step(url: string, n: number) {}
        function log(url: string) {}
        """#.utf8)
        let go = Array(#"""
        // SENTINEL package doc
        package main

        func main() {
            // SENTINEL line comment
            url := "https://example.com/#x" // SENTINEL trailing
            step(url /* SENTINEL inline */, 2)
            log(url)
        }
        func step(url string, n int) {}
        func log(url string)         {}
        """#.utf8)
        for (bytes, language) in [(rust, LanguageID.rust), (python, .python), (typeScript, .typescript), (go, .go)] {
            let questions = try #require(SkeletonQuestions(bytes: bytes, language: language))
            let state = questions.state
            for phrase in ["SENTINEL", "Module docstring", "A wrapper.", "Fill the text", "Remember that wrapping ran",
                           "Empty parts are dropped", "split first", "empty parts carry nothing", "here is the parameter"] {
                #expect(!state.contains(phrase), "\(language): \(phrase)")
            }
            for code in ["\"https://example.com/#x\"", "step(url", "\"# not a comment\"", "wrap = fill(note)"]
            where String(decoding: bytes, as: UTF8.self).contains(code) {
                #expect(state.contains(code), "\(language): \(code)")
            }
            for question in questions.questions { #expect(!question.instructions.contains("SENTINEL")) }
            let source = sourceLines(bytes)
            var previous = 0
            for line in state.split(separator: "\n") {
                let number = try #require(Int(line.prefix { $0 != " " }))
                #expect(number > previous)
                previous = number
                #expect(!line.dropFirst(String(number).count + 1).trimmingCharacters(in: .whitespaces).isEmpty)
                #expect(source[number - 1].hasPrefix(line.dropFirst(String(number).count + 1).prefix(4)))
            }
        }
    }

    @Test func aRequestOverTheSizeLimitIsNeverBuilt() throws {
        var source = "fn main() {\n"
        for index in 0..<4000 { source += "    let value_\(index) = compute_\(index % 7)(\(index));\n" }
        source += "    finish();\n}\nfn finish() {}\n"
        for index in 0..<7 { source += "fn compute_\(index)(n: u32) -> u32 { n }\n" }
        #expect(source.utf8.count > SkeletonQuestions.maxRequestBytes / 2)
        #expect(SkeletonQuestions(bytes: Array(source.utf8), language: .rust) == nil)
        for (label, bytes, language, variant) in try inputs() {
            let questions = try #require(SkeletonQuestions(bytes: bytes, language: language, variant: variant), "\(label)")
            #expect(questions.requestBody.count <= SkeletonQuestions.maxRequestBytes)
        }
    }
}

/// Random scores for every question: some below, some above 0.5, some missing.
private func randomScores(_ questions: SkeletonQuestions, _ generator: inout SplitMix64) -> [String: Double] {
    var scores: [String: Double] = [:]
    for question in questions.questions where generator.next(5) != 0 {
        scores[question.id] = Double(generator.next(101)) / 100
    }
    return scores
}

/// Main-line function sections, by their signature line. Types and helpers are sections without indented rows.
private func mainSections(_ lines: [SkeletonLine]) -> [Int: [SkeletonLine]] {
    var sections: [Int: [SkeletonLine]] = [:]
    var current: [SkeletonLine] = []
    for line in lines + [SkeletonLine(text: "", sourceLines: nil)] {
        guard line.sourceLines == nil else { current.append(line); continue }
        if let start = current.first?.sourceLines?.lowerBound, current.contains(where: { $0.text.hasPrefix(" ") }) {
            sections[start] = current
        }
        current = []
    }
    return sections
}

// MARK: - Invariants

/// Non-blank lines map inside the file; blank lines only separate blocks;
/// the first source lines strictly increase over the whole skeleton.
private func mappingIssues(_ lines: [SkeletonLine], bytes: [UInt8]) -> [String] {
    // The empty line after a final line break is not a source line.
    let lineCount = sourceLines(bytes).count - (bytes.last == 0x0A ? 1 : 0)
    var issues: [String] = []
    var previous: Int?
    for (index, line) in lines.enumerated() {
        guard let range = line.sourceLines else {
            if !line.text.isEmpty { issues.append("#\(index) has text but no source lines") }
            if index == 0 || index == lines.count - 1 || lines[index - 1].sourceLines == nil {
                issues.append("#\(index) is a stray blank line")
            }
            continue
        }
        if line.text.trimmingCharacters(in: .whitespaces).isEmpty { issues.append("#\(index) is empty but mapped") }
        if line.text.contains(where: \.isNewline) { issues.append("#\(index) holds a line break: \(line.text.debugDescription)") }
        if range.lowerBound < 1 || range.upperBound > lineCount {
            issues.append("#\(index) \(range) is outside 1...\(lineCount)")
        }
        if let previous, range.lowerBound <= previous {
            issues.append("#\(index) \(range) does not start after line \(previous): \(line.text)")
        }
        previous = range.lowerBound
    }
    return issues
}

/// Every identifier on a line appears in the text of its mapped source
/// lines: the rules only delete, join and re-punctuate.
private func identifierIssues(_ lines: [SkeletonLine], bytes: [UInt8]) -> [String] {
    let source = sourceLines(bytes)
    var issues: [String] = []
    for (index, line) in lines.enumerated() {
        guard let range = line.sourceLines, range.lowerBound >= 1, range.upperBound <= source.count else { continue }
        let available = Set(identifiers(in: source[(range.lowerBound - 1)..<range.upperBound].joined(separator: "\n")))
        for word in identifiers(in: line.text) where !available.contains(word) {
            issues.append("#\(index) \(range) adds `\(word)`: \(line.text)")
        }
    }
    return issues
}

private func identifiers(in text: String) -> [String] {
    var words: [String] = []
    var current = ""
    for scalar in text.unicodeScalars {
        if scalar == "_" || scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
            current.unicodeScalars.append(scalar)
        } else if !current.isEmpty {
            words.append(current)
            current = ""
        }
    }
    if !current.isEmpty { words.append(current) }
    return words.filter { !($0.unicodeScalars.first?.properties.numericType != nil) }
}

private func sourceLines(_ bytes: [UInt8]) -> [String] {
    bytes.split(separator: 0x0A, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
}

// MARK: - Inputs

private func inputs() throws -> [(label: String, bytes: [UInt8], language: LanguageID, variant: String?)] {
    let rust = try mainRs()
    let python = Array(pythonSample.utf8)
    let typeScript = Array(typeScriptSample.utf8)
    let go = Array(goSample.utf8)
    return [
        ("main.rs", rust, .rust, nil),
        ("main.rs crlf", crlf(rust), .rust, nil),
        ("main.rs unindented", unindented(rust), .rust, nil),
        ("sample.rs", Array(rustSample.utf8), .rust, nil),
        ("sample.py", python, .python, nil),
        ("sample.py crlf", crlf(python), .python, nil),
        ("sample.ts", typeScript, .typescript, nil),
        ("sample.ts crlf", crlf(typeScript), .typescript, nil),
        ("sample.tsx", Array(tsxSample.utf8), .typescript, "tsx"),
        ("sample.go", go, .go, nil),
        ("sample.go crlf", crlf(go), .go, nil),
    ]
}

private func mainRs() throws -> [UInt8] {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    return Array(try Data(contentsOf: root.appendingPathComponent("Helpers/cairn-ai/src/main.rs")))
}

private func crlf(_ bytes: [UInt8]) -> [UInt8] {
    bytes.flatMap { $0 == 0x0A ? [0x0D, 0x0A] : [$0] }
}

private func unindented(_ bytes: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    var lineStart = true
    for byte in bytes {
        if lineStart, byte == 0x20 || byte == 0x09 { continue }
        lineStart = byte == 0x0A
        out.append(byte)
    }
    return out
}

/// Reproducible: the same seed gives the same mutations.
private struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next(_ bound: Int) -> Int {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Int((z ^ (z >> 31)) % UInt64(max(bound, 1)))
    }
}

private let fragments = [
    "{", "}", "(", ")", "[", "fn ", "def ", ":", "\n", "\"", "'", "#", "//", "/*", "=> ", "else ",
    "变量", "\"中文 é 😀\"", "\r\n", "\t", "match x {", "if a:", "    ", "é", "self.", "return ", "?;",
    "`", "=> {", "case 1:", "this.", "<div>", ": string", "await ",
]

private func mutate(_ bytes: [UInt8], _ generator: inout SplitMix64) -> (kind: String, bytes: [UInt8]) {
    var out = bytes
    let at = generator.next(out.count + 1)
    switch generator.next(5) {
    case 0:
        return ("truncate at \(at)", Array(out[..<at]))
    case 1:
        let length = generator.next(200)
        out.removeSubrange(at..<min(out.count, at + length))
        return ("delete \(length) at \(at)", out)
    case 2:
        let fragment = fragments[generator.next(fragments.count)]
        out.insert(contentsOf: Array(fragment.utf8), at: at)
        return ("insert \(fragment.debugDescription) at \(at)", out)
    case 3:
        var lines = out.split(separator: 0x0A, omittingEmptySubsequences: false)
        let a = generator.next(lines.count)
        let b = generator.next(lines.count)
        lines.swapAt(a, b)
        return ("swap lines \(a + 1) and \(b + 1)", Array(lines.joined(separator: [0x0A])))
    default:
        var lines = out.split(separator: 0x0A, omittingEmptySubsequences: false)
        let a = generator.next(lines.count)
        let length = min(lines.count - a, generator.next(12))
        lines.insert(contentsOf: lines[a..<(a + length)], at: a)
        return ("duplicate lines \(a + 1)+\(length)", Array(lines.joined(separator: [0x0A])))
    }
}

/// Methods, generics, lifetimes, a test module, an unformatted line and a
/// multi-byte name.
private let rustSample = #"""
enum Kind { A, B(u8), C { x: i32 } }
struct Pair<'a>(&'a str, u8);

impl Engine {
    pub(crate) async fn run<'a, T: Clone>(&mut self, items: &'a [T], config: Config) -> std::io::Result<Vec<T>> {
        self.total = items.iter().map(|x: &T| x.len()).filter(|n| *n > 0).sum::<usize>();
        let cb = move || { self.step(total) };
        self.state = State { config: config.clone(), total: total, kind: Kind::A };
        let out = items.iter().cloned().collect::<Vec<_>>();
        if out.is_empty() { return Err(std::io::Error::other("empty")); }
        for item in &out { Self::check(item); }
        let 名前 = loop { if self.ready() { break "名前 é"; } };
        let _ = self.helper().await;
        Ok(out)
    }

    fn step(&self, n: usize) -> usize { n + 1 }
    fn check<T>(item: &T) {}
    fn ready(&self) -> bool { true }
    async fn helper(&self) {}
}
fn unformatted(a:u8)->u8{let b=a;if b>1{log(b);}else{return b;}crate::util::go(b);b}
mod util { pub fn go(_: u8) {} }

#[cfg(test)]
mod tests {
    #[test]
    fn it_works() { super::unformatted(1); }
}
"""#

/// A free function and a method share the name `fill`; a test function,
/// docstrings, comments, branches, a multi-line string and non-ASCII names.
private let pythonSample = #"""
"""Module docstring."""
import re

class Wrapper(object):
    """A wrapper."""

    def __init__(self, width=70, *, tabsize: int = 8):
        self.width = width
        self.tabsize = tabsize

    def fill(self, text):
        """Fill the text."""
        return "\n".join(self.wrap(text))

    def wrap(self, text):
        chunks = self._split(text)  # split first
        if self.width <= 0:
            raise ValueError("bad width")
        elif self.tabsize:
            self._expand(chunks)
        else:
            pass
        self._note()
        return chunks

    def _note(self):
        """Remember that wrapping ran.

        Only the docstring makes this method long:
        its body is two lines of code, which is
        what the size rule counts, so it stays
        a helper however much prose sits above.

        """
        self.notes = getattr(self, "notes", 0)
        self.notes += 1

    def _split(self, text):
        """Split on whitespace.

        Empty parts are dropped.
        """
        parts = []
        text = text.strip()
        separator = r"\s+"
        for part in re.split(separator, text):
            # empty parts carry nothing
            if not part:
                continue
            parts.append(part)
        else:
            parts.append("")
        return parts

    def _expand(self, chunks):
        """Count the chunks.

        Then write them out.
        """
        chunks = list(chunks)
        try:
            self.count = len(chunks)
        except (TypeError, ValueError):
            pass
        finally:
            self.done = True
        with open("x") as handle:
            handle.write("""first
second""")


def fill(text, width=70):
    w = Wrapper(width=width)
    return w.fill(text)


def 宽度(文本, 列="中文 é 😀"):
    结果 = []
    while 文本:
        结果.append(fill(文本[:列]))
        文本 = 文本[列:]
    return 结果


def run(text, wrap=str.split):
    # `wrap` here is the parameter, not the method of that name.
    return wrap(text)


def test_fill():
    assert fill("a b") == "a b"
"""#

/// Exports, a class with methods, a field arrow and `this` calls, arrow
/// constants, a switch, try/catch, a template string, types to strip, a
/// `.ts`-only type assertion and non-ASCII names.
private let typeScriptSample = #"""
import { readFile } from "node:fs/promises";

/** A sentinel enum. */
export enum Mode { Fast, Slow = 2, "中文" }

export interface Options {
    width: number;
    label?: string;
    render(text: string): string;
}

type Pair = { left: number; right: number };
type Name = string | number;

const 宽度 = (文本: string, 列 = 2): number => 文本.length * 列;

export function main(path: string, ...rest: string[]): Promise<void> {
    const engine = new Engine({ width: 80 } as Options);
    const first = <string>lines(path)[0];
    lines(`${path}
.bak`);
    const tail = lines(path)!.slice() as string[];
    const later = async () => { await lines(path); };
    for (const line of lines(path)) {
        engine.feed(line!);
    }
    return engine.finish<string>();
}

function lines(path: string): string[] {
    return readFile(path).toString().split("\n");
}

export class Engine extends Base<Options> implements Runner {
    private readonly total: number = 0;
    static count = 0;

    constructor(private options: Options) {
        super();
    }

    public async feed(line: string, limit?: number): Promise<void> {
        const width = this.measure(line) satisfies number;
        if (await this.ready()) { this.total = (await this.parse(line)).length; }
        switch (this.mode) {
            case Mode.Fast:
                this.total += width;
                break;
            case Mode.Slow: {
                await this.flush();
                break;
            }
            default:
                log(`odd ${line}`);
        }
        try {
            this.state = await this.parse(line);
        } catch (error: unknown) {
            this.state = undefined;
        } finally {
            this.done = true;
        }
    }

    static get size(): number {
        return Engine.count;
    }

    private measure = (line: string): number => {
        return 宽度(line, this.options.width) + "😀".length;
    };

    finish<T>(): T {
        const report = `total ${this.total}
lines ${Engine.count}`;
        this.write(report);
        return report as unknown as T;
    }
}
"""#

/// JSX, a default-exported class component and an expression-bodied arrow.
private let tsxSample = #"""
import React, { useState } from "react";

type Props = { title: string; items: string[] };

export function List({ title, items }: Props): JSX.Element {
    const [open, setOpen] = useState<boolean>(false);
    const toggle = () => {
        setOpen(!open);
        track("toggle");
    };
    return (
        <section onClick={toggle}>
            <h1>{title} 标题 😀</h1>
            {open && items.map((item) => <Row key={item} label={format(item)} />)}
        </section>
    );
}

const Row = ({ label }: { label: string }) => <li className="row">{label}</li>;

function format(item: string): string {
    return `${item.trim()} ✓`;
}

function track(name: string) {
    window.dispatchEvent(new CustomEvent(name));
}

export default class Panel extends React.Component<Props> {
    render() {
        return <List title={this.props.title} items={this.props.items} />;
    }

    handle = async (event: Event) => {
        await this.save(event);
        this.setState({ saved: true });
    };

    save(event: Event): Promise<void> {
        return send(event.type);
    }
}
"""#

/// Methods on a generic receiver, receiver calls, struct and interface
/// types (grouped too), switches, `if err != nil` exits, a goroutine,
/// test-shaped functions and non-ASCII text.
private let goSample = #"""
// Package engine is a sample.
package engine

import (
	"errors"
	"fmt"
	"testing"
)

// Mode is a kind.
type Mode int

type Options struct {
	Width, Height int
	Label         string `json:"label"`
	*Base
	宽度 int
}

type Runner interface {
	Run(line string) error
	fmt.Stringer
	Close()
}

type (
	Pair[T any] struct{ Left, Right T }
	Name        = string
)

type Engine[T any] struct {
	options Options
	total   int
	out     chan string
}

func main() {
	e, err := NewEngine(Options{Width: 80})
	if err != nil {
		fmt.Println("bad", err)
		return
	}
	go e.loop()
	defer e.Close()
	for _, line := range lines("x") {
		e.Feed(line)
	}
}

func init() {
	register(`engine
二`, &Options{})
}

func NewEngine(options Options) (*Engine[string], error) {
	if options.Width <= 0 {
		return nil, errors.New("bad width")
	}
	return &Engine[string]{options: options, out: make(chan string)}, nil
}

func (e *Engine[T]) Feed(line string) error {
	n, err := e.measure(line)
	if err != nil {
		return fmt.Errorf("measure: %w", err)
	}
	if err := e.check(n); err != nil {
		return err
	}
	if n > 99 {
		return errors.New("too long")
	}
	if n < 0 {
		return errNegative
	}
	switch e.options.Label {
	case "fast":
		e.total += n
	case "slow", "慢":
		e.flush()
		fallthrough
	default:
		fmt.Println("odd", line)
	}
	e.out <- line
	return nil
}

func (e *Engine[T]) loop() {
	for {
		select {
		case line, ok := <-e.out:
			if !ok {
				return
			}
			e.Feed(line)
		default:
			break
		}
	}
}

func (e Engine[T]) measure(line string) (int, error) {
	switch v := any(line).(type) {
	case string:
		return len(v), nil
	default:
		return 0, errors.New("中文 é 😀")
	}
}

func (e *Engine[T]) check(n int) error { return nil }
func (e *Engine[T]) flush()            { e.total = 0 }
func (e *Engine[T]) Close() error      { close(e.out); return nil }

func lines(path string, rest ...string) []string {
	return []string{path + "😀"}
}

func register(name string, options *Options) {}

func (e *Engine[T]) Reload() []string {
	data, err := e.load()
	if err != nil {
		data = lines("fallback")
	}
	return data
}

func (e *Engine[T]) load() ([]string, error) { return nil, nil }

func ExampleConfig() *Options { return &Options{} }

func TestFeed(t *testing.T) {
	e, _ := NewEngine(Options{Width: 1})
	e.Feed("a")
}

func BenchmarkFeed(b *testing.B) {}

func Example() {}
"""#
