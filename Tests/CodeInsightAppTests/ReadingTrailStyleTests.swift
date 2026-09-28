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

@MainActor
@Test
func readingTrailPinsBranchBadgeToTrailingEdge() throws {
    _ = NSApplication.shared
    let trail = ReadingTrail()
    let root = JumpRecord(path: "src/main.rs", contentID: nil, byteOffset: 0, line: 1,
                          column: 1, symbolAnchor: "main", snapshotID: nil)
    let next = JumpRecord(path: "src/lib.rs", contentID: nil, byteOffset: 0, line: 1,
                          column: 1, symbolAnchor: "run", snapshotID: nil)
    _ = trail.recordNavigation(from: root, to: next, cause: .search)

    // Hosted in a window like the main window's content stack: the ambiguity
    // only shows once the layout engine owns the bar.
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 120),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    let host = NSView()
    window.contentView = host
    let view = ReadingTrailView()
    host.addSubview(view)
    NSLayoutConstraint.activate([
        view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
        view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        view.topAnchor.constraint(equalTo: host.topAnchor),
        view.heightAnchor.constraint(equalToConstant: 26),
    ])

    func expectTrailingBadge(width: CGFloat, _ state: Comment) {
        host.layoutSubtreeIfNeeded()
        let layout = view.selfTestBarLayout
        #expect(!layout.ambiguous, state)
        // Badge at the far right (10 pt inset); the gap absorbs the slack.
        #expect(abs(layout.badge.maxX - (width - 10)) < 0.5, state)
        #expect(layout.breadcrumb.maxX + 10 <= layout.badge.minX + 0.5, state)
    }
    expectTrailingBadge(width: 900, "empty hint")
    view.display(trail: trail, store: ResolutionExplanationStore())
    expectTrailingBadge(width: 900, "short trail")
    window.setContentSize(NSSize(width: 1300, height: 120))
    expectTrailingBadge(width: 1300, "widened window")
}

@MainActor
@Test
func readingTrailTruncatesOlderCrumbsBeforeArrowsAndActiveCrumb() throws {
    _ = NSApplication.shared
    let trail = ReadingTrail()
    var previous = JumpRecord(path: "src/main.rs", contentID: nil, byteOffset: 0, line: 1,
                              column: 1, symbolAnchor: "main", snapshotID: nil)
    for index in 0..<6 {
        let next = JumpRecord(
            path: "src/module_\(index)/file.rs", contentID: nil, byteOffset: 0, line: 1,
            column: 1, symbolAnchor: "a_rather_long_function_name_\(index)", snapshotID: nil
        )
        _ = trail.recordNavigation(from: previous, to: next, cause: .relation)
        previous = next
    }

    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 120),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    let host = NSView()
    window.contentView = host
    let view = ReadingTrailView()
    host.addSubview(view)
    NSLayoutConstraint.activate([
        view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
        view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        view.topAnchor.constraint(equalTo: host.topAnchor),
        view.heightAnchor.constraint(equalToConstant: 26),
    ])
    view.display(trail: trail, store: ResolutionExplanationStore())

    // Frames carry 4 pt of alignment insets over the content width.
    func content(_ crumb: (text: String, width: CGFloat, natural: CGFloat, ambiguous: Bool)) -> CGFloat {
        crumb.width - 4
    }
    func isFull(_ crumb: (text: String, width: CGFloat, natural: CGFloat, ambiguous: Bool)) -> Bool {
        content(crumb) >= crumb.natural - 0.5
    }
    func lay(width: CGFloat) -> [(text: String, width: CGFloat, natural: CGFloat, ambiguous: Bool)] {
        window.setContentSize(NSSize(width: width, height: 120))
        host.layoutSubtreeIfNeeded()
        let layout = view.selfTestBarLayout
        let crumbs = view.selfTestCrumbs
        #expect(!layout.ambiguous)
        #expect(abs(layout.badge.maxX - (width - 10)) < 0.5)
        #expect(crumbs.allSatisfy { !$0.ambiguous })
        // "…", then four crumbs joined by three arrows; the last is active.
        #expect(crumbs.count == 8)
        #expect(crumbs.last?.text.hasSuffix("_5") == true)
        return crumbs
    }

    // Moderately short: only older crumbs give way, oldest first, and none
    // below its stub. A crumb shrinks only once every older one is a stub.
    let moderate = lay(width: 800)
    let arrows = moderate.filter { $0.text.hasPrefix("─") }
    #expect(arrows.count == 3 && arrows.allSatisfy(isFull))
    #expect(moderate.last.map(isFull) == true)
    let older = moderate.dropLast().filter { !$0.text.hasPrefix("─") }
    let stubs = older.map { min($0.natural, 32) }
    #expect(zip(older, stubs).allSatisfy { content($0) >= $1 - 0.5 })
    #expect(!older.allSatisfy(isFull))
    for index in older.indices.dropFirst() where !isFull(older[index]) {
        #expect(older[..<index].indices.allSatisfy { content(older[$0]) <= stubs[$0] + 0.5 })
    }

    // Narrower: with every older crumb at its stub, arrows give way next and
    // the active crumb still reads in full.
    let narrow = lay(width: 600)
    let narrowOlder = narrow.dropLast().filter { !$0.text.hasPrefix("─") }
    #expect(narrowOlder.allSatisfy { content($0) <= min($0.natural, 32) + 0.5 })
    #expect(narrow.last.map(isFull) == true)
}
