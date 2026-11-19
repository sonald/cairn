@testable import CodeInsightAI
import Foundation
import Testing

/// `history` against a real repository: lines grouped by the commit that
/// last changed them, messages without trailers that name people, and only
/// the hunk that added the lines asked about.
struct AIToolsHistoryTests {
    @Test func historyGroupsLinesByCommitAndShowsTheChangeThatMadeThem() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ai-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ arguments: String..., date: String? = nil) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.currentDirectoryURL = root
            var environment = ["HOME": root.path, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
            if let date { environment["GIT_AUTHOR_DATE"] = date; environment["GIT_COMMITTER_DATE"] = date }
            process.environment = environment
            process.arguments = ["-c", "user.name=Dev", "-c", "user.email=dev@example.com"] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0, "git \(arguments)")
        }
        let file = root.appendingPathComponent("a.rs")
        try git("init", "-q")
        try "fn one() {}\nfn two() {}\nfn four() {}\n".write(to: file, atomically: true, encoding: .utf8)
        try git("add", "a.rs")
        try git("commit", "-q", "-m", "Add a", date: "2026-01-01T00:00:00Z")
        try "fn one() {}\nfn two() -> i32 { 2 }\nfn four() {}\n".write(to: file, atomically: true, encoding: .utf8)
        try git("commit", "-q", "-am", "Make two return\n\nCallers need the value.\n\nSigned-off-by: Dev <dev@example.com>",
                date: "2026-02-01T00:00:00Z")
        try "fn one() {}\nfn two() -> i32 { 2 }\nfn three() {}\nfn four() {}\n".write(to: file, atomically: true, encoding: .utf8)
        let snapshot = AISnapshot(root: root, revision: nil, id: nil, files: ["a.rs"], source: nil, sessions: [])

        let output = try await AITools.history("a.rs", from: 1, to: 3, step: 1, in: snapshot).output
        #expect(output.contains("2 commits, 1 uncommitted lines (3)"), "\(output)")
        let newest = try #require(output.range(of: "2026-02-01"))
        let older = try #require(output.range(of: "2026-01-01"))
        #expect(newest.lowerBound < older.lowerBound, "newest first")
        #expect(output.contains("Callers need the value."))
        #expect(!output.contains("dev@example.com") && !output.contains("Dev"), "no people in what is sent")
        #expect(output.contains("-fn two() {}") && output.contains("+fn two() -> i32 { 2 }"))
        #expect(output.contains("(the file was added in this commit)"))
        // Line 4 (fn four) was not asked about; it shows only as diff context.
        #expect(output.contains("a.rs lines 1–3: 2 commits"))
    }

    @Test func historyOutsideGitAndMisspeltParametersSayWhatIsWrong() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ai-nogit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "x\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let snapshot = AISnapshot(root: root, revision: nil, id: nil, files: ["a.txt"], source: nil, sessions: [])

        let history = await AITools.run(AIToolCall(callID: "1", name: "history", arguments: Data(#"{"path":"a.txt"}"#.utf8)),
                                        step: 1, in: snapshot)
        #expect(history.output.contains("not a Git repository"))
        #expect(history.step.count == nil)

        let read = await AITools.run(AIToolCall(callID: "2", name: "read", arguments: Data(#"{"path":"a.txt","lines":"1-3"}"#.utf8)),
                                     step: 2, in: snapshot)
        #expect(read.output.hasPrefix(#"error: unknown parameter "lines"; read takes path (required), start_line, end_line"#))
    }
}

extension AIToolsHistoryTests {
    /// A `}` or a blank line in the asked range must not pull in every hunk
    /// of the commit that also adds a `}` elsewhere.
    @Test func historyShowsOnlyTheHunkThatAddedTheAskedLines() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ai-hunks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ arguments: String...) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.currentDirectoryURL = root
            process.environment = ["HOME": root.path, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
            process.arguments = ["-c", "user.name=Dev", "-c", "user.email=dev@example.com"] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0, "git \(arguments)")
        }
        let file = root.appendingPathComponent("a.rs")
        let padding = (1...12).map { "fn pad\($0)() {}" }.joined(separator: "\n")
        try git("init", "-q")
        try "fn a() {}\n\(padding)\n".write(to: file, atomically: true, encoding: .utf8)
        try git("add", "a.rs")
        try git("commit", "-q", "-m", "Start")
        try "fn a() {\n    1\n}\n\n\(padding)\nfn far_away() {\n}\n".write(to: file, atomically: true, encoding: .utf8)
        try git("commit", "-q", "-am", "Grow a")
        let snapshot = AISnapshot(root: root, revision: nil, id: nil, files: ["a.rs"], source: nil, sessions: [])

        let output = try await AITools.history("a.rs", from: 1, to: 4, step: 1, in: snapshot).output
        #expect(output.contains("+fn a() {"), "\(output)")
        #expect(!output.contains("far_away"), "\(output)")
    }
}
