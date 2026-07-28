import AppKit
import CodeInsightAppModel
import CodeInsightEngine
import CodeInsightExact
import CodeInsightReaderCore
import Foundation
import Testing
@testable import CodeInsightApp

@MainActor
@Test
func relationReferenceSingleClicksNavigateEachLocationOnce() async throws {
    let fixture = try await makeRelationNavigationFixture()
    defer {
        fixture.controller.close()
        try? FileManager.default.removeItem(at: fixture.root)
    }
    let main = fixture.root.appendingPathComponent("main.rs")
    let a = fixture.root.appendingPathComponent("a.rs")
    let b = fixture.root.appendingPathComponent("b.rs")
    fixture.controller.openFileForSelfTest(main)
    try #require(await waitUntil {
        fixture.controller.displayedReaderFile?.standardizedFileURL
            == main.standardizedFileURL
    })
    fixture.controller.openFileInNewTabForSelfTest(a)
    try #require(await waitUntil {
        fixture.controller.displayedReaderFile?.standardizedFileURL
            == a.standardizedFileURL
    })
    fixture.controller.openFileInNewTabForSelfTest(b)
    try #require(await waitUntil {
        fixture.controller.displayedReaderFile?.standardizedFileURL
            == b.standardizedFileURL
    })
    fixture.controller.openFileForSelfTest(main)
    try #require(await waitUntil {
        fixture.controller.displayedReaderFile?.standardizedFileURL
            == main.standardizedFileURL
    })
    #expect(fixture.controller.selfTestTabCount == 3)

    fixture.controller.selfTestReaderRelation(
        offset: byteOffset(of: "target() {}", in: fixture.mainSource),
        direction: .references
    )
    try #require(await waitUntil {
        referenceEdge(path: "a.rs", in: fixture.model) != nil
            && referenceEdge(path: "b.rs", in: fixture.model) != nil
            && fixture.controller.selfTestVisibleRelationEdgeTitles(
                inGroup: "References"
            ).count >= 2
    })
    let first = try #require(referenceEdge(path: "a.rs", in: fixture.model))
    let second = try #require(referenceEdge(path: "b.rs", in: fixture.model))
    let originalOnSelect = fixture.model.relationTree.onSelect
    var selectionCount = 0
    fixture.model.relationTree.onSelect = { node in
        selectionCount += 1
        originalOnSelect(node)
    }
    defer { fixture.model.relationTree.onSelect = originalOnSelect }

    for (index, edge, file, bytes) in [
        (0, first, a, Array(fixture.aSource.utf8)),
        (1, second, b, Array(fixture.bSource.utf8)),
    ] {
        let beforeNavigation = fixture.model.navigationGeneration
        #expect(fixture.controller.selfTestSelectRelationEdge(titled: edge.title))
        try #require(await waitUntil {
            fixture.model.selectedFile?.standardizedFileURL == file.standardizedFileURL
                && fixture.model.selectedByteOffset == edge.target?.byteOffset
                && fixture.controller.displayedReaderFile?.standardizedFileURL
                    == file.standardizedFileURL
                && fixture.controller.selfTestLeftReaderBytes == bytes
        })
        await pumpRunLoop()
        #expect(fixture.model.navigationGeneration == beforeNavigation + 1)
        #expect(selectionCount == index + 1)
        #expect(fixture.controller.selfTestTabCount == 3)
        #expect(
            fixture.controller.selfTestActiveTabFile?.standardizedFileURL
                == file.standardizedFileURL
        )
    }
}

@MainActor
@Test
func relationSymbolSingleClicksDoNotNavigate() async throws {
    let fixture = try await makeRelationNavigationFixture()
    defer {
        fixture.controller.close()
        try? FileManager.default.removeItem(at: fixture.root)
    }
    let main = fixture.root.appendingPathComponent("main.rs")
    fixture.controller.openFileForSelfTest(main)
    try #require(await waitUntil {
        fixture.controller.displayedReaderFile?.standardizedFileURL
            == main.standardizedFileURL
    })

    for (offset, direction, rootTitle, edgeTitle) in [
        (
            byteOffset(of: "target() {}", in: fixture.mainSource),
            RelationTreeModel.Direction.callers,
            "target",
            "caller_one"
        ),
        (
            byteOffset(of: "call_root() {", in: fixture.mainSource),
            .calls,
            "call_root",
            "first"
        ),
        (
            byteOffset(of: "Render {", in: fixture.mainSource),
            .implementations,
            "Render",
            "Widget"
        ),
    ] {
        fixture.controller.selfTestReaderRelation(offset: offset, direction: direction)
        try #require(await waitUntil {
            fixture.model.relationTree.root?.title == rootTitle
                && relationEdge(titled: edgeTitle, in: fixture.model) != nil
                && fixture.controller.selfTestVisibleRelationEdgeTitles(
                    inGroup: "Strong"
                ).contains(edgeTitle)
        })
        let beforeNavigation = fixture.model.navigationGeneration
        #expect(fixture.controller.selfTestSelectRelationEdge(titled: edgeTitle))
        await pumpRunLoop()
        #expect(fixture.model.navigationGeneration == beforeNavigation)
        #expect(fixture.model.selectedFile?.standardizedFileURL == main.standardizedFileURL)
    }
}

@MainActor
@Test
func relationReferenceSingleClickNavigatesWhileContextIsPinned() async throws {
    let fixture = try await makeRelationNavigationFixture()
    defer {
        fixture.controller.close()
        try? FileManager.default.removeItem(at: fixture.root)
    }
    let main = fixture.root.appendingPathComponent("main.rs")
    let a = fixture.root.appendingPathComponent("a.rs")
    fixture.controller.openFileForSelfTest(main)
    try #require(await waitUntil {
        fixture.controller.displayedReaderFile?.standardizedFileURL
            == main.standardizedFileURL
    })
    fixture.controller.selfTestReaderClick(
        offset: byteOffset(of: "target();", in: fixture.mainSource),
        commandClick: false
    )
    try #require(await waitUntil { fixture.model.contextWindow.selectedCandidate != nil })
    fixture.controller.selfTestSetContextPinned(true)
    let pinnedCandidate = try #require(fixture.model.contextWindow.selectedCandidate)
    let pinnedRequest = fixture.model.contextWindow.requestID

    fixture.controller.selfTestReaderRelation(
        offset: byteOffset(of: "target() {}", in: fixture.mainSource),
        direction: .references
    )
    try #require(await waitUntil {
        referenceEdge(path: "a.rs", in: fixture.model) != nil
            && fixture.controller.selfTestVisibleRelationEdgeTitles(
                inGroup: "References"
            ).contains { $0.hasPrefix("a.rs:") }
    })
    let edge = try #require(referenceEdge(path: "a.rs", in: fixture.model))
    #expect(fixture.controller.selfTestSelectRelationEdge(titled: edge.title))
    try #require(await waitUntil {
        fixture.model.selectedFile?.standardizedFileURL == a.standardizedFileURL
            && fixture.model.selectedByteOffset == edge.target?.byteOffset
    })
    await pumpRunLoop()

    #expect(fixture.model.contextWindow.mode == .pinned)
    #expect(fixture.model.contextWindow.requestID == pinnedRequest)
    #expect(fixture.model.contextWindow.selectedCandidate?.symbol == pinnedCandidate.symbol)
    #expect(fixture.model.contextWindow.selectedCandidate?.path == pinnedCandidate.path)
    #expect(
        fixture.model.contextWindow.selectedCandidate?.targetByteOffset
            == pinnedCandidate.targetByteOffset
    )
}

@MainActor
@Test
func relationProgrammaticRootDirectionAndReloadChangesDoNotNavigate() async throws {
    let fixture = try await makeRelationNavigationFixture()
    defer {
        fixture.controller.close()
        try? FileManager.default.removeItem(at: fixture.root)
    }
    let main = fixture.root.appendingPathComponent("main.rs")
    fixture.controller.openFileForSelfTest(main)
    try #require(await waitUntil {
        fixture.controller.displayedReaderFile?.standardizedFileURL
            == main.standardizedFileURL
    })
    let beforeNavigation = fixture.model.navigationGeneration

    fixture.controller.selfTestReaderRelation(
        offset: byteOffset(of: "target() {}", in: fixture.mainSource),
        direction: .callers
    )
    try #require(await waitUntil {
        fixture.model.relationTree.root?.title == "target"
            && fixture.model.relationTree.direction == .callers
    })
    #expect(fixture.model.navigationGeneration == beforeNavigation)

    fixture.controller.selfTestChangeRelationDirection(.calls)
    try #require(await waitUntil {
        fixture.model.relationTree.root?.title == "target"
            && fixture.model.relationTree.direction == .calls
    })
    #expect(fixture.model.navigationGeneration == beforeNavigation)

    fixture.controller.selfTestReaderRelation(
        offset: byteOffset(of: "target() {}", in: fixture.mainSource),
        direction: .references
    )
    try #require(await waitUntil {
        fixture.model.relationTree.root?.title == "target"
            && referenceEdge(path: "a.rs", in: fixture.model) != nil
    })
    await pumpRunLoop()
    #expect(fixture.model.navigationGeneration == beforeNavigation)
    #expect(fixture.model.selectedFile?.standardizedFileURL == main.standardizedFileURL)
}

@MainActor
@Test
func relationReferenceDoubleClickDoesNotNavigateTwiceAndHistoryReturns() async throws {
    let fixture = try await makeRelationNavigationFixture()
    defer {
        fixture.controller.close()
        try? FileManager.default.removeItem(at: fixture.root)
    }
    let main = fixture.root.appendingPathComponent("main.rs")
    let a = fixture.root.appendingPathComponent("a.rs")
    fixture.controller.openFileForSelfTest(main)
    try #require(await waitUntil {
        fixture.controller.displayedReaderFile?.standardizedFileURL
            == main.standardizedFileURL
    })
    fixture.controller.selfTestReaderRelation(
        offset: byteOffset(of: "target() {}", in: fixture.mainSource),
        direction: .references
    )
    try #require(await waitUntil {
        referenceEdge(path: "a.rs", in: fixture.model) != nil
            && fixture.controller.selfTestVisibleRelationEdgeTitles(
                inGroup: "References"
            ).contains { $0.hasPrefix("a.rs:") }
    })
    let edge = try #require(referenceEdge(path: "a.rs", in: fixture.model))
    let relationRoot = try #require(fixture.model.relationTree.root)
    let relationGeneration = fixture.model.relationTree.generation
    let navigationBeforeClick = fixture.model.navigationGeneration
    let historyBeforeClick = fixture.model.navigationHistory.records.count
    #expect(edge.symbol == nil)

    #expect(fixture.controller.selfTestSelectRelationEdge(titled: edge.title))
    try #require(await waitUntil {
        fixture.model.selectedFile?.standardizedFileURL == a.standardizedFileURL
            && fixture.model.selectedByteOffset == edge.target?.byteOffset
    })
    let navigationAfterSingleClick = fixture.model.navigationGeneration
    let historyAfterSingleClick = fixture.model.navigationHistory.records.count
    #expect(navigationAfterSingleClick == navigationBeforeClick + 1)
    #expect(historyAfterSingleClick == historyBeforeClick + 1)
    #expect(fixture.model.relationTree.root === relationRoot)
    #expect(fixture.model.relationTree.generation == relationGeneration)

    fixture.controller.selfTestOpenRelationSelection()
    await pumpRunLoop()
    #expect(fixture.model.navigationGeneration == navigationAfterSingleClick)
    #expect(fixture.model.navigationHistory.records.count == historyAfterSingleClick)
    #expect(fixture.model.relationTree.root === relationRoot)
    #expect(fixture.model.relationTree.generation == relationGeneration)

    fixture.controller.goBack(nil)
    try #require(await waitUntil {
        fixture.model.selectedFile?.standardizedFileURL == main.standardizedFileURL
            && fixture.controller.displayedReaderFile?.standardizedFileURL
                == main.standardizedFileURL
    })
}

@MainActor
private func makeRelationNavigationFixture() async throws -> (
    root: URL,
    mainSource: String,
    aSource: String,
    bSource: String,
    model: AppModel,
    controller: MainWindowController
) {
    _ = NSApplication.shared
    let mainSource = """
        fn target() {}
        fn caller_one() { target(); }
        fn caller_two() { target(); }
        fn first() {}
        fn second() {}
        fn call_root() { first(); second(); }
        trait Render {}
        struct Widget;
        impl Render for Widget {}
        """
    let aSource = "fn ca() { target(); }\n"
    let bSource = "fn cb() { target(); }\n"
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "CodeInsightRelationNavigation-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for (path, source) in [
        ("main.rs", mainSource),
        ("a.rs", aSource),
        ("b.rs", bSource),
    ] {
        try Data(source.utf8).write(to: root.appendingPathComponent(path))
    }
    let model = AppModel(
        indexService: RelationTestIndexService(),
        exactCoordinator: ExactCoordinator(
            providerFactory: { _ in throw CocoaError(.featureUnsupported) },
            sandboxAvailable: { false }
        )
    )
    let controller = MainWindowController(
        model: model,
        settings: ReaderSettings(),
        offscreen: true
    )
    controller.openProject(root: root)
    guard await waitUntil({
        model.snapshotPhase == .fullReady
            && model.fileTree?.root.standardizedFileURL == root.standardizedFileURL
    }, timeout: 10) else {
        controller.close()
        try? FileManager.default.removeItem(at: root)
        let details = "state=\(model.projectState), "
            + "phase=\(String(describing: model.snapshotPhase)), "
            + "tree=\(String(describing: model.fileTree?.root.path))"
        Issue.record("project did not reach fullReady: \(details)")
        throw CocoaError(.coderReadCorrupt)
    }
    return (root, mainSource, aSource, bSource, model, controller)
}

@MainActor
private func relationEdge(
    titled title: String,
    in model: AppModel
) -> RelationTreeModel.Node? {
    model.relationTree.root?.children?
        .flatMap { $0.children ?? [] }
        .first { $0.kind == .edge && $0.title == title }
}

@MainActor
private func referenceEdge(
    path: String,
    in model: AppModel
) -> RelationTreeModel.Node? {
    model.relationTree.root?.children?
        .flatMap { $0.children ?? [] }
        .first { $0.kind == .edge && $0.target?.path == path }
}

private func byteOffset(of needle: String, in source: String) -> UInt32 {
    let range = source.range(of: needle)!
    return UInt32(source[..<range.lowerBound].utf8.count)
}

@MainActor
private func waitUntil(
    _ condition: () -> Bool,
    timeout: TimeInterval = 5
) async -> Bool {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@MainActor
private func pumpRunLoop() async {
    try? await Task.sleep(for: .milliseconds(50))
}

private struct RelationTestIndexService: IndexService {
    func index(root: URL) async throws -> EngineSession {
        try await Task.detached {
            try ProjectIndexer().index(root: root)
        }.value
    }
}
