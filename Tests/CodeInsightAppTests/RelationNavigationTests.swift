import AppKit
import CodeInsightCore
import CodeInsightEngine
import CodeInsightExact
import CodeInsightReaderCore
import Foundation
import Testing
@testable import CodeInsightApp
@testable import CodeInsightAppModel

@Suite(.serialized)
struct RelationUXTests {
    @MainActor
    @Test
    func relationReferenceRowsExposeProvenanceThroughAccessibility() async throws {
        let fixture = try await makeRelationUXFixture()
        defer { fixture.close() }
        let title = try #require(
            fixture.controller.selfTestVisibleEdgeTitles(inGroup: "Exact").first
        )
        let accessibility = try #require(
            fixture.controller.selfTestAccessibility(
                titled: title,
                inGroup: "Exact"
            )
        )

        #expect(
            [accessibility.label, accessibility.value]
                .joined(separator: " ")
                .contains("Exact · heuristic also matched")
        )
        #expect(accessibility.role != NSAccessibility.Role.textField.rawValue)
        #expect(accessibility.valueSettable == false)
    }

    @MainActor
    @Test
    func relationReferenceGeometryReadsDoNotForceLayout() async throws {
        let fixture = try await makeRelationUXFixture()
        defer { fixture.close() }
        let contentSize = NSSize(width: 1_600, height: 1_000)
        fixture.window.contentView?.setFrameSize(contentSize)
        fixture.controller.view.setFrameSize(contentSize)
        fixture.controller.view.layoutSubtreeIfNeeded()
        fixture.window.displayIfNeeded()
        await pumpRunLoop()
        let contentBounds = fixture.controller.view.bounds
        let layoutPassesBeforeReads = fixture.controller.selfTestLayoutPasses
        let visibleRect = fixture.controller.selfTestRelationsVisibleRect
        let exactFrame = fixture.controller.selfTestExactGroupFrame
        let referenceFrame = fixture.controller.selfTestReferenceGroupFrame
        let exactRows = fixture.controller.selfTestVisibleEdgeFrames(
            inGroup: "Exact"
        )
        let referenceRows = fixture.controller.selfTestVisibleEdgeFrames(
            inGroup: "References"
        )
        let groupsDoNotOverlap =
            fixture.controller.selfTestExactAndReferenceGroupsDoNotOverlap
        let panelDoesNotOverlapControl =
            fixture.controller.selfTestResultsAndDirectionControlDoNotOverlap
        let layoutPassesAfterReads = fixture.controller.selfTestLayoutPasses
        #expect(contentBounds.size == contentSize)
        #expect(exactFrame.width > 0 && exactFrame.height > 0)
        #expect(referenceFrame.width > 0 && referenceFrame.height > 0)
        #expect((exactRows + referenceRows).allSatisfy {
            $0.width > 0 && $0.height > 0 && visibleRect.contains($0)
        })
        #expect(groupsDoNotOverlap)
        #expect(panelDoesNotOverlapControl)
        #expect(layoutPassesAfterReads == layoutPassesBeforeReads)
    }

    @MainActor
    @Test
    func relationOutlineKeyboardPreservesReferenceConsumptionRules()
        async throws
    {
        let references = try await makeRelationUXFixture(
            includesExactMatch: false
        )
        defer { references.close() }
        var referenceSelections: [String] = []
        var referenceOpens: [(String, UInt32)] = []
        references.model.onSelect = { referenceSelections.append($0.title) }
        references.controller.onOpen = { referenceOpens.append(($0, $1)) }
        #expect(references.controller.selfTestSelectEdge(titled: "first"))
        referenceSelections.removeAll()
        referenceOpens.removeAll()
        let notificationsBeforeArrow =
            references.controller.selfTestAccessibilityNotificationCount

        #expect(references.controller.selfTestPressKey(125))
        #expect(references.controller.selfTestSelectedEdgeTitle == "second")
        #expect(referenceSelections == ["second"])
        #expect(referenceOpens.map(\.1) == [references.secondLocation.byteOffset])
        #expect(
            references.controller.selfTestLastAccessibilityNotification
                == NSAccessibility.Notification.selectedRowsChanged.rawValue
        )
        #expect(
            references.controller.selfTestAccessibilityNotificationCount
                == notificationsBeforeArrow + 1
        )

        referenceOpens.removeAll()
        #expect(references.controller.selfTestPressKey(36))
        #expect(referenceOpens.map(\.1) == [references.secondLocation.byteOffset])
        #expect(references.controller.selfTestPressKey(126))
        #expect(references.controller.selfTestSelectedEdgeTitle == "first")

        let symbols = try await makeRelationUXFixture(
            direction: .calls,
            includesExactMatch: false
        )
        defer { symbols.close() }
        var symbolSelections: [String] = []
        var symbolOpens: [(String, UInt32)] = []
        symbols.model.onSelect = { symbolSelections.append($0.title) }
        symbols.controller.onOpen = { symbolOpens.append(($0, $1)) }
        #expect(symbols.controller.selfTestSelectEdge(titled: "first"))
        symbolSelections.removeAll()
        symbolOpens.removeAll()

        #expect(symbols.controller.selfTestPressKey(125))
        #expect(symbols.controller.selfTestSelectedEdgeTitle == "second")
        #expect(symbolSelections == ["second"])
        #expect(symbolOpens.isEmpty)
        #expect(symbols.controller.selfTestPressKey(36))
        #expect(symbols.controller.selfTestPressKey(76))
        #expect(symbolOpens.map(\.1) == [
            symbols.secondLocation.byteOffset,
            symbols.secondLocation.byteOffset,
        ])
    }

    @MainActor
    @Test
    func relationViewDoesNotPublishRowsFromACancelledReferenceLoad()
        async throws
    {
        let gate = RelationLoadGate()
        let fixture = try await makeRelationUXFixture(
            includesExactMatch: false,
            blockedSubjectLoad: gate
        )
        defer { fixture.close() }
        try #require(await waitUntilAsync { await gate.started })
        let staleRoot = try #require(fixture.model.root)
        var treeChanges = 0
        fixture.controller.onTreeChange = { treeChanges += 1 }

        fixture.controller.setRoot(
            target: .engine(fixture.firstSymbol),
            direction: .calls
        )
        try #require(await waitUntil {
            fixture.model.root?.title == "first"
                && fixture.controller.selfTestVisibleEdgeTitles(
                    inGroup: "Strong"
                ) == ["first", "second"]
        })
        let changesBeforeStaleReturn = treeChanges
        await gate.release()
        try #require(await waitUntilAsync { await gate.finished })
        await pumpRunLoop()
        _ = await waitUntilAsync({
            treeChanges > changesBeforeStaleReturn
                || fixture.model.root?.title != "first"
        }, timeout: 0.5)
        _ = staleRoot.children

        #expect(fixture.model.root?.title == "first")
        #expect(
            fixture.controller.selfTestVisibleEdgeTitles(inGroup: "Strong")
                == ["first", "second"]
        )
        #expect(
            fixture.controller.selfTestVisibleEdgeTitles(
                inGroup: "References"
            ).contains("stale-reference") == false
        )
        #expect(treeChanges == changesBeforeStaleReturn)
    }
}

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
func rightClickRelationsUsePagedContextCandidateInAllDirections() async throws {
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
    let offset = byteOffset(of: "value.close();", in: fixture.mainSource)
        + UInt32("value.".utf8.count)
    fixture.controller.selfTestReaderClick(offset: offset, commandClick: false)
    try #require(await waitUntil {
        fixture.model.contextWindow.candidateCount == 2
    })
    let first = try #require(fixture.model.contextWindow.selectedCandidate?.symbol)
    fixture.model.contextWindow.selectNext()
    let selected = try #require(fixture.model.contextWindow.selectedCandidate?.symbol)
    #expect(selected != first)

    for direction in [
        RelationTreeModel.Direction.callers,
        .calls,
        .implementations,
        .references,
    ] {
        let generation = fixture.model.relationTree.generation
        fixture.controller.selfTestReaderRelation(offset: offset, direction: direction)
        try #require(await waitUntil {
            fixture.model.relationTree.generation > generation
                && fixture.model.relationTree.direction == direction
        })
        #expect(fixture.model.relationTree.root?.symbol == selected)
    }
}

@MainActor
@Test
func rightClickRelationReparsesAStaleContextSelection() async throws {
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
    let ambiguousOffset = byteOffset(of: "value.close();", in: fixture.mainSource)
        + UInt32("value.".utf8.count)
    fixture.controller.selfTestReaderClick(
        offset: ambiguousOffset,
        commandClick: false
    )
    try #require(await waitUntil {
        fixture.model.contextWindow.candidateCount == 2
    })
    fixture.model.contextWindow.selectNext()
    let stale = try #require(fixture.model.contextWindow.selectedCandidate?.symbol)
    guard case let .ready(session, context) = fixture.model.projectState else {
        Issue.record("project is not ready")
        return
    }
    let target = try #require(
        session.definitions(of: "target", context: context).first?.0
    )

    fixture.controller.selfTestReaderRelation(
        offset: byteOffset(of: "target() {}", in: fixture.mainSource),
        direction: .callers
    )
    try #require(await waitUntil {
        fixture.model.relationTree.root?.symbol == target
    })
    #expect(fixture.model.relationTree.root?.symbol == target)
    #expect(fixture.model.relationTree.root?.symbol != stale)
}

@MainActor
@Test
func pinnedRightClickReparsesNewTokenAndReusesDisplayedToken() async throws {
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
    let pinnedOffset = byteOffset(of: "value.close();", in: fixture.mainSource)
        + UInt32("value.".utf8.count)
    fixture.controller.selfTestReaderClick(offset: pinnedOffset, commandClick: false)
    try #require(await waitUntil {
        fixture.model.contextWindow.candidateCount == 2
    })
    fixture.model.contextWindow.selectNext()
    let pinned = try #require(fixture.model.contextWindow.selectedCandidate?.symbol)
    fixture.controller.selfTestSetContextPinned(true)
    guard case let .ready(session, context) = fixture.model.projectState else {
        Issue.record("project is not ready")
        return
    }
    let target = try #require(
        session.definitions(of: "target", context: context).first?.0
    )

    fixture.controller.selfTestReaderRelation(
        offset: byteOffset(of: "target() {}", in: fixture.mainSource),
        direction: .callers
    )
    try #require(await waitUntil {
        fixture.model.relationTree.root?.symbol == target
    })
    #expect(fixture.model.relationTree.root?.symbol == target)
    #expect(fixture.model.relationTree.root?.symbol != pinned)

    fixture.controller.selfTestReaderRelation(
        offset: pinnedOffset,
        direction: .callers
    )
    try #require(await waitUntil {
        fixture.model.relationTree.root?.symbol != target
    })
    #expect(fixture.model.relationTree.root?.symbol == pinned)
    #expect(fixture.model.contextWindow.mode == .pinned)
    #expect(fixture.model.contextWindow.selectedCandidate?.symbol == pinned)
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
        struct AlphaCloser;
        impl AlphaCloser { fn close(&self) {} }
        struct BetaCloser;
        impl BetaCloser { fn close(&self) {} }
        fn close_unknown<T>(value: T) { value.close(); }
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

@MainActor
private final class RelationUXFixture {
    private static var retainedUntilTestProcessExit: [RelationUXFixture] = []

    let root: URL
    let window: NSWindow
    let model: RelationTreeModel
    let controller: RelationWindowController
    let firstLocation: (path: String, byteOffset: UInt32, line: UInt32)
    let secondLocation: (path: String, byteOffset: UInt32, line: UInt32)
    let firstSymbol: SymbolOccurrenceID

    init(
        root: URL,
        window: NSWindow,
        model: RelationTreeModel,
        controller: RelationWindowController,
        firstLocation: (path: String, byteOffset: UInt32, line: UInt32),
        secondLocation: (path: String, byteOffset: UInt32, line: UInt32),
        firstSymbol: SymbolOccurrenceID
    ) {
        self.root = root
        self.window = window
        self.model = model
        self.controller = controller
        self.firstLocation = firstLocation
        self.secondLocation = secondLocation
        self.firstSymbol = firstSymbol
    }

    func close() {
        window.orderOut(nil)
        try? FileManager.default.removeItem(at: root)
        // AX notifications outlive the test turn; keep their AppKit elements valid.
        Self.retainedUntilTestProcessExit.append(self)
    }
}

@MainActor
private func makeRelationUXFixture(
    direction: RelationTreeModel.Direction = .references,
    includesExactMatch: Bool = true,
    blockedSubjectLoad: RelationLoadGate? = nil
) async throws -> RelationUXFixture {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "CodeInsightRelationUX-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    try Data("""
        fn subject() {}
        fn first() { subject(); }
        fn second() { subject(); }
        """.utf8).write(to: root.appendingPathComponent("main.rs"))
    let session = try await Task.detached {
        try ProjectIndexer().index(root: root)
    }.value
    let context = QueryContext(
        snapshotID: session.snapshotID,
        analysisProfileID: session.analysisProfile.id,
        generation: 1
    )
    let subject = try #require(
        session.definitions(of: "subject", context: context).first?.0
    )
    let first = try #require(
        session.definitions(of: "first", context: context).first?.0
    )
    let second = try #require(
        session.definitions(of: "second", context: context).first?.0
    )
    let firstLocation = try #require(relationLocation(for: first, in: session))
    let secondLocation = try #require(relationLocation(for: second, in: session))
    let fuzzyLocations = [
        ("first", firstLocation),
        ("second", secondLocation),
    ]
    let exact = ExactCoordinator.Relation(
        name: "first",
        location: ExactLocation(
            file: firstLocation.path,
            byteOffset: Int(firstLocation.byteOffset),
            line: Int(firstLocation.line),
            column: 1
        ),
        item: nil,
        callSites: []
    )
    let stale = RelationTreeModel.LoadedEdge(
        title: "stale-reference",
        certainty: .possible,
        dispatch: .direct,
        symbol: nil,
        path: firstLocation.path,
        byteOffset: firstLocation.byteOffset,
        line: firstLocation.line,
        evidence: []
    )
    let model = RelationTreeModel(
        loader: { _, _, symbol, loadDirection in
            if symbol == subject, let blockedSubjectLoad {
                await blockedSubjectLoad.wait()
                return .init(edges: [stale], isTruncated: false)
            }
            return .init(
                edges: fuzzyLocations.map { title, location in
                    RelationTreeModel.LoadedEdge(
                        title: title,
                        certainty: loadDirection == .references
                            ? .possible
                            : .strong,
                        dispatch: .direct,
                        symbol: nil,
                        path: location.path,
                        byteOffset: location.byteOffset,
                        line: location.line,
                        evidence: []
                    )
                },
                isTruncated: false
            )
        },
        exactRelationsResolver: { _, _, _, _, _ in
            includesExactMatch
                ? .relations([exact], origin: .worktree, coverage: .full)
                : .unsupported
        }
    )
    model.updateProjectState(.ready(session, context))
    let controller = RelationWindowController(model: model)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1_600, height: 1_000),
        styleMask: [.titled, .resizable],
        backing: .buffered,
        defer: false
    )
    let contentSize = NSSize(width: 1_600, height: 1_000)
    let contentView = NSView(frame: NSRect(origin: .zero, size: contentSize))
    window.contentView = contentView
    controller.view.frame = contentView.bounds
    controller.view.autoresizingMask = [.width, .height]
    contentView.addSubview(controller.view)
    window.setContentSize(contentSize)
    contentView.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    controller.setRoot(target: .engine(subject), direction: direction)
    if blockedSubjectLoad == nil {
        try #require(await waitUntil {
            if includesExactMatch {
                return controller.selfTestVisibleEdgeTitles(inGroup: "Exact")
                    == ["first"]
            }
            let group = direction == .references ? "References" : "Strong"
            return controller.selfTestVisibleEdgeTitles(inGroup: group)
                == ["first", "second"]
        })
    }
    return RelationUXFixture(
        root: root,
        window: window,
        model: model,
        controller: controller,
        firstLocation: firstLocation,
        secondLocation: secondLocation,
        firstSymbol: first
    )
}

private actor RelationLoadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false
    private(set) var finished = false

    func wait() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
        finished = true
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private func waitUntilAsync(
    _ condition: @escaping @MainActor () async -> Bool,
    timeout: TimeInterval = 5
) async -> Bool {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

private func relationLocation(
    for symbol: SymbolOccurrenceID,
    in session: EngineSession
) -> (path: String, byteOffset: UInt32, line: UInt32)? {
    guard let file = session.manifest.files.first(where: {
              $0.pathID == symbol.pathID
          }),
          let index = session.contentIndexes.first(where: {
              $0.key.contentID == file.contentID
          })?.value,
          index.symbols.indices.contains(Int(symbol.localIndex)),
          let coordinate = index.lineTable.lineColumn(
              at: index.symbols[Int(symbol.localIndex)].nameRange.lowerBound
          )
    else { return nil }
    return (
        session.paths.resolve(file.pathID),
        index.symbols[Int(symbol.localIndex)].nameRange.lowerBound,
        coordinate.line
    )
}
