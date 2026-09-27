import AppKit
import CodeInsightAppModel
import CodeInsightCore
import CodeInsightReaderCore
import CodeInsightReaderUI
import Foundation
import Testing
@testable import CodeInsightApp

@MainActor
private func trailRGB(_ color: NSColor?) -> UInt32? {
    guard let color, let srgb = color.usingColorSpace(.sRGB) else { return nil }
    return UInt32((srgb.redComponent * 255).rounded()) << 16
        | UInt32((srgb.greenComponent * 255).rounded()) << 8
        | UInt32((srgb.blueComponent * 255).rounded())
}

@MainActor
private func trailRGB(_ color: CGColor?) -> UInt32? {
    trailRGB(color.flatMap { NSColor(cgColor: $0) })
}

@MainActor
@Test
func readingTrailMarksCurrentHistoryAndDetailTypography() throws {
    _ = NSApplication.shared
    let trail = ReadingTrail()
    let worktree = SnapshotID(rawValue: UUID())
    let commit = SnapshotID(rawValue: UUID())
    let root = JumpRecord(
        path: "src/main.rs", contentID: nil, byteOffset: 4, line: 1, column: 5,
        symbolAnchor: "main", snapshotID: worktree
    )
    let historical = JumpRecord(
        path: "src/lib.rs", contentID: nil, byteOffset: 12, line: 3, column: 2,
        symbolAnchor: "run", snapshotID: commit, revision: "1234567890abcdef"
    )
    _ = trail.recordNavigation(from: root, to: historical, cause: .search)

    let view = ReadingTrailView(frame: NSRect(x: 0, y: 0, width: 900, height: 32))
    view.apply(settings: ReaderSettings(theme: .light))
    view.display(trail: trail, store: ResolutionExplanationStore())

    // The historical destination is the current node: amber, not moss.
    let current = try #require(view.selfTestRowStyle(path: "src/lib.rs"))
    #expect(current.current)
    #expect(trailRGB(current.gutter) == 0xC98A2E)
    #expect(trailRGB(current.snapshotFill) == 0xEFE4CC)

    let origin = try #require(view.selfTestRowStyle(path: "src/main.rs"))
    #expect(!origin.current)
    #expect(trailRGB(origin.gutter) == 0x2B5849)
    #expect(trailRGB(origin.snapshotFill) != 0xEFE4CC)

    #expect(view.selectNode(path: "src/lib.rs"))
    let titleFont = try #require(view.selfTestDetailTitleFont)
    #expect(titleFont.fontName.contains("NewYork") || titleFont.familyName?.contains("New York") == true)
    #expect(trailRGB(view.selfTestDetailColor(of: "commit 1234567")) == 0x7A5A2C)
    // Styling must not change the text other code reads.
    #expect(view.detailValue.contains("commit 1234567"))
    #expect(view.detailValue.hasPrefix("run\nsrc/lib.rs:3:2\n"))
}

@MainActor
@Test
func readingTrailKeepsSequentialReadingOnOneLaneAndIndentsOnlyBranches() throws {
    _ = NSApplication.shared
    let trail = ReadingTrail()
    func jump(_ path: String) -> JumpRecord {
        JumpRecord(path: path, contentID: nil, byteOffset: 0, line: 1, column: 1,
                   symbolAnchor: nil, snapshotID: nil)
    }
    let root = jump("root.rs"), a = jump("a.rs"), b = jump("b.rs"),
        c = jump("c.rs"), d = jump("d.rs"), e = jump("e.rs")
    // A long linear read: root → a → b → c → d.
    let aID = trail.recordNavigation(from: root, to: a, cause: .relation)
    _ = trail.recordNavigation(from: a, to: b, cause: .relation)
    _ = trail.recordNavigation(from: b, to: c, cause: .relation)
    _ = trail.recordNavigation(from: c, to: d, cause: .relation)

    let view = ReadingTrailView(frame: NSRect(x: 0, y: 0, width: 900, height: 32))
    view.apply(settings: ReaderSettings(theme: .light))
    view.display(trail: trail, store: ResolutionExplanationStore())
    let linear = view.selfTestRowLanes
    #expect(linear.map(\.path) == ["root.rs", "a.rs", "b.rs", "c.rs", "d.rs"])
    #expect(linear.allSatisfy { $0.depth == 0 && !$0.branchStart })
    #expect(linear.dropLast().allSatisfy { $0.below == [0] })
    #expect(linear.dropFirst().allSatisfy { $0.above == [0] })

    // Go back to a and read e: a side branch that must not shift the main path.
    trail.restore(aID)
    _ = trail.recordNavigation(from: a, to: e, cause: .relation)
    view.display(trail: trail, store: ResolutionExplanationStore())
    let branched = view.selfTestRowLanes
    let rowE = try #require(branched.first { $0.path == "e.rs" })
    // Visiting order is kept: the detour follows the first route.
    #expect(branched.map(\.path) == ["root.rs", "a.rs", "b.rs", "c.rs", "d.rs", "e.rs"])
    #expect(rowE.depth == 1 && rowE.branchStart)
    #expect(branched.filter { $0.path != "e.rs" }.allSatisfy { $0.depth == 0 && !$0.branchStart })
    // a's lane stays open down to where the branch leaves it.
    #expect(branched.dropFirst().dropLast().allSatisfy { $0.below.contains(0) })
    #expect(rowE.above.contains(0))
}
