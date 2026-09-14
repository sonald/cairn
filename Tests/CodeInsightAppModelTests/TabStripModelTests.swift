import CodeInsightAppModel
import CodeInsightCore
import CodeInsightReaderCore
import Foundation
import Testing

@Test
@MainActor
func tabStripFocusesDuplicatesAndPreservesAnchors() {
    let model = TabStripModel()
    let a = URL(fileURLWithPath: "/tmp/a.rs")
    let b = URL(fileURLWithPath: "/tmp/b.rs")
    let c = URL(fileURLWithPath: "/tmp/c.rs")

    model.open(a, inNewTab: false)
    #expect(model.activeTab?.isPreview == true)
    model.updateActiveAnchors(scrollByteOffset: 41, selectionByteOffset: 57)
    let document = ReaderDocument(bytes: Array("fn a() {}".utf8))
    model.setActiveDocument(document, for: a)
    model.open(a, inNewTab: true)
    #expect(model.tabs.count == 1)
    #expect(model.activeDocument === document)
    #expect(model.activeTab?.isPreview == false)

    model.open(b, inNewTab: false)
    #expect(model.tabs.compactMap(\.fileURL) == [a, b])
    model.activate(0)
    model.open(c, inNewTab: false)
    #expect(model.tabs.compactMap(\.fileURL) == [a, c])
    #expect(model.tabs.filter(\.isPreview).count == 1)
    #expect(model.activeTab?.fileURL == c)
    model.open(a, inNewTab: true)

    #expect(model.tabs.count == 2)
    #expect(model.activeIndex == 0)
    #expect(model.activeTab?.scrollByteOffset == 41)
    #expect(model.activeTab?.selectionByteOffset == 57)

    model.open(c, inNewTab: true, selectionByteOffset: 73)
    #expect(model.tabs.count == 2)
    #expect(model.activeTab?.selectionByteOffset == 73)
    model.open(b, inNewTab: false)
    #expect(model.tabs.compactMap(\.fileURL) == [a, c, b])
    let activeBeforeKeep = model.activeIndex
    model.keepOpen(0)
    #expect(model.activeIndex == activeBeforeKeep)
    model.keepOpen(2)
    #expect(model.tabs.allSatisfy { !$0.isPreview })
}

@Test
@MainActor
func tabStripEvictsTheLeastRecentlyUsedTabAtItsLimit() {
    let model = TabStripModel(maximumCount: 3)
    let files = (0..<4).map { URL(fileURLWithPath: "/tmp/\($0).rs") }

    model.open(files[0], inNewTab: false)
    model.open(files[1], inNewTab: true)
    model.open(files[2], inNewTab: true)
    model.activate(0)
    model.open(files[3], inNewTab: true)

    #expect(model.tabs.compactMap(\.fileURL) == [files[0], files[2], files[3]])
    #expect(model.activeTab?.fileURL == files[3])
}

@Test
@MainActor
func switchingTabsReleasesTheInactiveReaderDocument() {
    let model = TabStripModel()
    let file = URL(fileURLWithPath: "/tmp/a.rs")
    model.open(file, inNewTab: false)
    var document: ReaderDocument? = ReaderDocument(bytes: Array("fn a() {}".utf8))
    let probe = WeakDocumentProbe(document)
    model.setActiveDocument(document, for: file)
    document = nil

    model.open(URL(fileURLWithPath: "/tmp/b.rs"), inNewTab: true)

    #expect(model.activeDocument == nil)
    #expect(probe.document == nil)
}

@Test
@MainActor
func readingSetsShareFileTabLifecycleWithoutPretendingToBeFiles() {
    let model = TabStripModel(maximumCount: 3)
    let fileA = URL(fileURLWithPath: "/tmp/a.rs")
    let fileB = URL(fileURLWithPath: "/tmp/b.rs")
    model.open(fileA, inNewTab: true)
    model.updateActiveAnchors(scrollByteOffset: 10, selectionByteOffset: 12)
    model.openReadingSet(
        title: "spawn",
        excerpts: [readingSetExcerpt()],
        skippedReasons: ["recorded source is unreadable"]
    )
    model.updateActiveReadingSetScroll(144)
    model.open(fileB, inNewTab: false)

    #expect(model.tabs.count == 3)
    #expect(model.tabs[1].fileURL == nil)
    #expect(model.tabs[1].title == "spawn")
    #expect(model.tabs[1].isPreview == false)
    #expect(model.tabs[1].readingSetScrollOffset == 144)
    #expect(model.tabs[1].readingSetSkippedReasons == [
        "recorded source is unreadable",
    ])
    #expect(model.tabs[0].scrollByteOffset == 10)
    #expect(model.tabs[0].selectionByteOffset == 12)

    model.activate(1)
    #expect(model.activeDocument == nil)
    model.openReadingSet(
        title: "spawn",
        excerpts: [readingSetExcerpt()],
        skippedReasons: ["recorded source is unreadable"]
    )
    #expect(model.tabs.count == 3)
    #expect(model.tabs.compactMap(\.fileURL) == [fileA, fileB])
    #expect(model.tabs.filter { $0.fileURL == nil }.count == 1)
    #expect(model.activeIndex == 1)

    let fileC = URL(fileURLWithPath: "/tmp/c.rs")
    model.open(fileC, inNewTab: false)
    #expect(model.tabs.compactMap(\.fileURL) == [fileA, fileC])
    #expect(model.tabs[1].readingSetScrollOffset == 144)
    let fileD = URL(fileURLWithPath: "/tmp/d.rs")
    model.open(fileD, inNewTab: true)
    #expect(model.tabs.count == 3)
    #expect(model.tabs[0].title == "spawn")
    #expect(model.tabs.compactMap(\.fileURL) == [fileC, fileD])
}

@Test
@MainActor
func appModelClearsFileOnlyStateForAReadingSetAndRestoresItForAFile() {
    let model = AppModel()
    let file = URL(fileURLWithPath: "/tmp/a.rs")
    model.openInNewTab(file, selectionByteOffset: 7)
    model.openReadingSet(title: "spawn", excerpts: [readingSetExcerpt()])

    #expect(model.selectedFile == nil)
    #expect(model.selectedByteOffset == nil)
    #expect(model.tabStrip.activeDocument == nil)

    model.activateTab(0)
    #expect(model.selectedFile == file)
    #expect(model.selectedByteOffset == 7)
}

private func readingSetExcerpt() -> ReadingSetExcerpt {
    let capturedAt = Date(timeIntervalSince1970: 1_786_200_000)
    let source = "pub fn spawn() {}\n"
    let inspector = ReadingSetExcerpt.FrozenInspectorDisplay(
        nodeTitle: "spawn",
        badge: .verified,
        why: "rust-analyzer returned this target.",
        sourceBody: "Matched a declaration in the same file.",
        verificationTitle: "VERIFICATION",
        verificationBody: "Verified at capture.",
        correctionBody: "",
        availabilityBody: "rust-analyzer ready at capture",
        environmentBody: "default · Trusted at capture",
        auditRows: [
            .init(label: "Source", value: "worktree captured"),
        ],
        accessibilityValue: "Verified spawn at capture",
        capturedAt: capturedAt,
        formerCandidateAvailable: false
    )
    return ReadingSetExcerpt(
        role: "Definition",
        symbol: "spawn",
        path: "src/lib.rs",
        line: 1,
        column: 1,
        firstLine: 1,
        byteRange: ByteRange(lowerBound: 0, upperBound: UInt32(source.utf8.count)),
        sourceText: source,
        contentID: .sha256(of: Array(source.utf8)),
        revision: nil,
        capturedAt: capturedAt,
        sourceKind: .worktreeCaptured,
        inspector: inspector
    )
}

private final class WeakDocumentProbe {
    weak var document: ReaderDocument?

    init(_ document: ReaderDocument?) {
        self.document = document
    }
}
