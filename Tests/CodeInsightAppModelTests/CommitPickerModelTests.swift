import CodeInsightGit
import Foundation
import Testing
@testable import CodeInsightAppModel

private func commit(_ sha: String, _ summary: String, branches: [String] = [], tags: [String] = []) -> CommitInfo {
    CommitInfo(
        shortSHA: String(sha.prefix(7)), fullSHA: sha, summary: summary,
        authorName: "T", date: Date(timeIntervalSince1970: 0),
        branchNames: branches, tagNames: tags
    )
}

@MainActor
@Test
func commitPickerFilterMatchesShaPrefixSummaryBranchAndTagCaseInsensitively() {
    let release = commit("aaaa111", "Release build", tags: ["V1.2.0"])
    let feature = commit("bbbb222", "Toolbar polish", branches: ["Feature/Toolbar"])
    let other = commit("cccc333", "Unrelated")
    let picker = CommitPickerModel(commits: [release, feature, other])

    picker.setQuery("v1.2")
    #expect(picker.filteredCommits == [release])
    picker.setQuery("feature/TOOL")
    #expect(picker.filteredCommits == [feature])
    picker.setQuery("BBBB")
    #expect(picker.filteredCommits == [feature])
    picker.setQuery(" unrelated ")
    #expect(picker.filteredCommits == [other])
    picker.setQuery("")
    #expect(picker.filteredCommits.count == 3)
}

@MainActor
@Test
func commitPickerResolvesUnloadedRevisionsAndDropsStaleResults() async {
    let deep = commit("dddd444", "Deep history")
    let gate = AsyncGate()
    let picker = CommitPickerModel(commits: [commit("aaaa111", "Loaded")]) { revision in
        if revision == "slow" {
            await gate.wait()
            return deep
        }
        return revision == "HEAD~600" ? deep : nil
    }

    // Loaded matches never trigger a resolution.
    picker.setQuery("Loaded")
    #expect(picker.resolvedCommit == nil)

    picker.setQuery("HEAD~600")
    #expect(await testWaitUntil("resolved") { picker.resolvedCommit == deep })
    #expect(picker.filteredCommits.isEmpty)

    picker.setQuery("nonsense")
    #expect(picker.resolvedCommit == nil)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(picker.resolvedCommit == nil)

    // A slow answer for an older query must not land on a newer one.
    picker.setQuery("slow")
    picker.setQuery("other")
    await gate.open()
    try? await Task.sleep(for: .milliseconds(50))
    #expect(picker.resolvedCommit == nil)
    #expect(picker.query == "other")
}

@MainActor
@Test
func commitPickerLoadsFurtherPagesFromARepository() async throws {
    let fixture = try PickerGitFixture()
    defer { fixture.remove() }
    for index in 1...5 {
        try Data("v\(index)\n".utf8).write(to: fixture.root.appendingPathComponent("a.rs"))
        try fixture.git("add", "a.rs")
        try fixture.commit("c\(index)")
    }
    try fixture.git("tag", "early", "HEAD~4")
    let picker = CommitPickerModel(pageSize: 2)
    picker.load(repositoryURL: fixture.root)
    #expect(await testWaitUntil("first page") { !picker.isLoading })
    #expect(picker.commits.map(\.summary) == ["c5", "c4"])
    #expect(picker.hasMore)

    // The tag lives on an unloaded commit: no filter hit, but a direct hit.
    picker.setQuery("early")
    #expect(picker.filteredCommits.isEmpty)
    #expect(await testWaitUntil("tag resolved") { picker.resolvedCommit?.summary == "c1" })
    #expect(picker.resolvedCommit?.tagNames == ["early"])
    picker.setQuery("")

    picker.loadMore()
    #expect(picker.isLoadingMore)
    #expect(await testWaitUntil("second page") { !picker.isLoadingMore })
    #expect(picker.commits.map(\.summary) == ["c5", "c4", "c3", "c2"])
    #expect(picker.hasMore)
    picker.loadMore()
    #expect(await testWaitUntil("last page") { !picker.isLoadingMore })
    #expect(picker.commits.map(\.summary) == ["c5", "c4", "c3", "c2", "c1"])
    #expect(!picker.hasMore)
    #expect(picker.loadMoreError == nil)
    picker.loadMore()
    #expect(!picker.isLoadingMore)

    // Once loaded, the tag is a plain filter hit.
    picker.setQuery("EARLY")
    #expect(picker.filteredCommits.map(\.summary) == ["c1"])
}

@MainActor
@Test
func commitPickerKeepsAResolvedCurrentCommitVisible() async {
    let deep = commit("dddd444", "Deep history")
    let loaded = commit("aaaa111", "Loaded")
    let picker = CommitPickerModel(commits: [loaded]) { $0 == "deep" ? deep : nil }
    picker.setQuery("deep")
    #expect(await testWaitUntil("resolved") { picker.resolvedCommit == deep })

    picker.setCurrentRevision(deep.fullSHA)
    #expect(picker.currentCommit == deep)
    picker.setQuery("")
    #expect(picker.filteredCommits == [deep, loaded])
    picker.setCurrentRevision(loaded.fullSHA)
    #expect(picker.currentCommit == loaded)
    #expect(picker.filteredCommits == [loaded])
}

private actor AsyncGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private final class PickerGitFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CodeInsightCommitPickerTests-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git("init", "-q")
    }

    func commit(_ message: String) throws {
        try git("-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-q", "-m", message)
    }

    @discardableResult
    func git(_ arguments: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = root
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "PickerGitFixture", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: text])
        }
        return text
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
