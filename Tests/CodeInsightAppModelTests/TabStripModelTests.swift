import CodeInsightAppModel
import CodeInsightReaderCore
import Foundation
import Testing

@Test
@MainActor
func tabStripFocusesDuplicatesAndPreservesAnchors() {
    let model = TabStripModel()
    let a = URL(fileURLWithPath: "/tmp/a.rs")
    let b = URL(fileURLWithPath: "/tmp/b.rs")

    model.open(a, inNewTab: false)
    model.updateActiveAnchors(scrollByteOffset: 41, selectionByteOffset: 57)
    model.open(b, inNewTab: true)
    model.open(a, inNewTab: true)

    #expect(model.tabs.count == 2)
    #expect(model.activeIndex == 0)
    #expect(model.activeTab?.scrollByteOffset == 41)
    #expect(model.activeTab?.selectionByteOffset == 57)
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

    #expect(model.tabs.map(\.fileURL) == [files[0], files[2], files[3]])
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

private final class WeakDocumentProbe {
    weak var document: ReaderDocument?

    init(_ document: ReaderDocument?) {
        self.document = document
    }
}
