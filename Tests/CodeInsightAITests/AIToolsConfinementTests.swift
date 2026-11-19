@testable import CodeInsightAI
import Foundation
import Testing

/// Tools read only files in the snapshot's file list, inside its root.
struct AIToolsConfinementTests {
    @Test func readsOutsideTheSnapshotAreRefused() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ai-confine-\(UUID().uuidString)")
        let root = base.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "secret\n".write(to: base.appendingPathComponent("outside.txt"), atomically: true, encoding: .utf8)
        try "inside\n".write(to: root.appendingPathComponent("inside.txt"), atomically: true, encoding: .utf8)
        // A symlink listed as a snapshot file (the tree skips them; a worktree
        // can gain one after the snapshot was taken).
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link.txt"), withDestinationURL: base.appendingPathComponent("outside.txt"))
        let snapshot = AISnapshot(root: root, revision: nil, id: nil, files: ["inside.txt", "link.txt"], source: nil, sessions: [])

        #expect(try AITools.readFile("inside.txt", from: nil, to: nil, step: 1, in: snapshot).output.contains("inside"))
        for path in ["../outside.txt", AITools.normalized("/etc/passwd"), "link.txt", AITools.normalized("./../outside.txt")] {
            #expect(throws: AIToolError.self, "\(path)") {
                try AITools.readFile(path, from: nil, to: nil, step: 1, in: snapshot)
            }
        }
        #expect(AITools.listFiles(under: "..", in: snapshot).1 == 0)
    }
}
