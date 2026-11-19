import Foundation
import Testing
@testable import CodeInsightGit

@Test
func workingTreeBlameAttributesCommittedLinesAndMarksEditsAndUntrackedFilesUncommitted() throws {
    let fixture = try GitFixture()
    defer { fixture.remove() }
    let file = fixture.root.appendingPathComponent("main.rs")
    try Data("one\ntwo\nthree\nfour\nfive\n".utf8).write(to: file)
    try fixture.git("add", "main.rs")
    try fixture.commit("A: five lines")
    try Data("one\ntwo\nTHREE\nfour\nfive\n".utf8).write(to: file)
    try fixture.git("add", "main.rs")
    try fixture.commit("B: line three")
    let shas = try fixture.git("rev-parse", "HEAD~1", "HEAD").split(separator: "\n").map(String.init)

    let hunks = try GitBlame.blame(
        repositoryURL: fixture.root,
        path: "main.rs",
        revision: nil,
        workingTreeBytes: Array("one\ntwo\nTHREE\nfour\nFIVE\n".utf8)
    )
    #expect(hunks.map(\.lines) == [1...2, 3...3, 4...4, 5...5])
    #expect(hunks.map(\.commit?.fullSHA) == [shas[0], shas[1], shas[0], nil])
    let b = try #require(hunks[1].commit)
    #expect(b.summary == "B: line three")
    let author = try fixture.git("log", "-1", "--format=%an%n%at", "HEAD").split(separator: "\n")
    #expect(b.authorName == String(author[0]))
    #expect(b.date == Date(timeIntervalSince1970: TimeInterval(String(author[1]))!))
    #expect(b.shortSHA == String(shas[1].prefix(7)))

    // The commit revision ignores working-tree bytes and blames that commit.
    let atA = try GitBlame.blame(
        repositoryURL: fixture.root, path: "main.rs", revision: "HEAD~1", workingTreeBytes: [0x0A]
    )
    #expect(atA == [BlameHunk(lines: 1...5, commit: hunks[0].commit)])

    let untracked = try GitBlame.blame(
        repositoryURL: fixture.root, path: "new.rs", revision: nil, workingTreeBytes: Array("a\nb".utf8)
    )
    #expect(untracked == [BlameHunk(lines: 1...2, commit: nil)])
}
