@testable import CodeInsightAI
import Foundation
import Testing

/// The guide checker accepts a draft only when every anchor lands on real
/// lines, and tells the model which draft line to fix and how.
struct AIGuideTests {
    /// A 60-line `session.py` with an outline, beside a `client.py` of 10 lines.
    func file(outline: Bool = true) throws -> GuideFile {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ai-guide-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try String(repeating: "x\n", count: 60).write(to: root.appendingPathComponent("session.py"), atomically: true, encoding: .utf8)
        try String(repeating: "y\n", count: 10).write(to: root.appendingPathComponent("client.py"), atomically: true, encoding: .utf8)
        let snapshot = AISnapshot(root: root, revision: nil, id: nil, files: ["session.py", "client.py"], source: nil, sessions: [])
        let symbols = [
            GuideSymbol(name: "Session", kind: "class", start: 1, end: 60),
            GuideSymbol(name: "request", kind: "function", start: 10, end: 30),
            GuideSymbol(name: "renew", kind: "function", start: 32, end: 40),
            GuideSymbol(name: "close", kind: "function", start: 42, end: 50),
        ]
        return GuideFile(path: "session.py", lineCount: 60, symbols: outline ? symbols : nil, snapshot: snapshot)
    }

    @Test func aWellFormedDraftIsAcceptedWithItsBlocks() throws {
        let draft = """
        ---
        title: session.py: one connection
        ---
        Keeps one connection (`Session`) and retries once.

        ## Flows
        ```path send a request
        from: callers in client.py (`client.py:5`)
        `request` `L12-14` | sends it
        `Session.renew` | logs in again
        ```

        ```roles
        `close` `renew:33` | helper | cleanup and login
        ```

        ```sequence
        Caller -> Session: request `request:12`
        loop until it works
        Session --> Caller: 401 `L20`
        end
        ```

        ```ask
        Why only one retry?
        ```
        """
        let (parsed, errors) = GuideDraft.check(draft, in: try file())
        #expect(errors.isEmpty, "\(errors)")
        #expect(parsed.title == "session.py: one connection")
        guard case .path(let name, let from, let steps) = parsed.blocks[2] else { Issue.record("\(parsed.blocks)"); return }
        #expect(name == "send a request" && from.contains("client.py:5"))
        // Two spans, a symbol and its lines, become one anchor.
        #expect(steps.map(\.anchor) == ["request:12-14", "Session.renew"])
        #expect(parsed.blocks.contains(.ask(["Why only one retry?"])))
        let f = try file()
        #expect(f.resolve("Session.renew") == .target(GuideTarget(path: "session.py", start: 32, end: 40)))
        #expect(f.resolve("client.py:5") == .target(GuideTarget(path: "client.py", start: 5, end: 5)))
        #expect(f.resolve("x = 1") == .code)
    }

    @Test func eachProblemNamesItsDraftLineAndTheFix() throws {
        let draft = """
        Retries in `request:5-12` and `L61`.
        ```path one
        from: a timer
        `L12-14` | sends it
        `missing` | ???
        ```
        ```roles
        `close` | sidekick | cleanup
        ```
        ```calls
        ```
        ```sequence
        A -> B: go
        ## Next
        """
        let errors = GuideDraft.check(draft, in: try file()).errors
        func has(_ line: Int, _ text: String) -> Bool { errors.contains { $0.hasPrefix("L\(line):") && $0.contains(text) } }
        #expect(has(1, "5-12 is not inside request (10-30)"))
        #expect(has(1, "61-61 is not inside the file (1-60)"))
        // A bare line range in a flow step gets the symbol it runs in as the fix.
        #expect(has(4, "write `request:12-14`"))
        #expect(has(5, "missing is not a symbol"))
        #expect(has(8, "sidekick is not a role"))
        #expect(has(10, "is not a component"))
        #expect(has(12, "the block is not closed"))
        #expect(errors.allSatisfy { $0.contains(". Fix: ") }, "\(errors)")
    }

    @Test func withoutAnOutlineANamedRangeIsALabelAndABareNameIsRefused() throws {
        let f = try file(outline: false)
        let draft = """
        ```roles
        `handle:10-20` | main | the loop
        `handle` | helper | no lines
        ```
        """
        let errors = GuideDraft.check(draft, in: f).errors
        #expect(errors.count == 1 && errors[0].hasPrefix("L3:") && errors[0].contains("`handle:a-b`"), "\(errors)")
        #expect(f.resolve("handle:10-20") == .target(GuideTarget(path: "session.py", start: 10, end: 20)))
    }
}
