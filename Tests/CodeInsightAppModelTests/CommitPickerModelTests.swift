import CodeInsightGit
import Foundation
import Testing
@testable import CodeInsightAppModel

private let pickerCommits = [
    CommitInfo(
        shortSHA: "a1b2c3d",
        fullSHA: "a1b2c3d000000000000000000000000000000000",
        summary: "Resolve Import Graph",
        authorName: "Ada",
        date: Date(timeIntervalSince1970: 1)
    ),
    CommitInfo(
        shortSHA: "d4e5f6a",
        fullSHA: "d4e5f6a000000000000000000000000000000000",
        summary: "Render commit picker",
        authorName: "Grace",
        date: Date(timeIntervalSince1970: 2)
    ),
]

@MainActor
@Test
func commitPickerMatchesSHAPrefix() {
    let model = CommitPickerModel(commits: pickerCommits)
    model.setQuery("A1B2")

    #expect(model.filteredCommits == [pickerCommits[0]])
}

@MainActor
@Test
func commitPickerMatchesSummarySubstring() {
    let model = CommitPickerModel(commits: pickerCommits)
    model.setQuery("commit pick")

    #expect(model.filteredCommits == [pickerCommits[1]])
}

@MainActor
@Test
func commitPickerSearchIsCaseInsensitive() {
    let model = CommitPickerModel(commits: pickerCommits)
    model.setQuery("IMPORT GRAPH")

    #expect(model.filteredCommits == [pickerCommits[0]])
}

@MainActor
@Test
func commitPickerTracksWorktreeAndCommit() {
    let model = CommitPickerModel(commits: pickerCommits)

    #expect(model.currentRevision == nil)
    #expect(model.currentCommit == nil)
    model.setCurrentRevision(pickerCommits[1].fullSHA)
    #expect(model.currentCommit == pickerCommits[1])
    model.setCurrentRevision(nil)
    #expect(model.currentCommit == nil)
}

@Test
func snapshotCoverageFormatsPartsUntilFullReady() {
    let coverage = SnapshotCoverage(filesIndexed: 120, filesTotal: 717)

    #expect(
        coverage.statusText(for: .cachedReady)
            == "Files 120/717 · resolving imports"
    )
    #expect(coverage.statusText(for: .fullReady) == nil)
}
