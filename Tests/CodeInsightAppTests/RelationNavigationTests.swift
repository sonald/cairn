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
                .contains("Verified")
        )
        #expect(accessibility.value.contains("heuristic also matched"))
        #expect(
            fixture.controller.selfTestBadgeToolTip(titled: title)
                == "Verified by rust-analyzer"
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
        let verifiedRows = fixture.controller.selfTestVisibleEdgeFrames(
            inGroup: "Exact"
        )
        let verifiedFrame = try #require(verifiedRows.first)
        let disclosureFrame = fixture.controller.selfTestPossibleDisclosureFrame
        let badgeFrame = fixture.controller.selfTestBadgeFrame(titled: "first")
        let badgeLabelFrame = fixture.controller.selfTestBadgeLabelFrame(
            titled: "first"
        )
        let panelDoesNotOverlapControl =
            fixture.controller.selfTestResultsAndDirectionControlDoNotOverlap
        let layoutPassesAfterReads = fixture.controller.selfTestLayoutPasses
        #expect(contentBounds.size == contentSize)
        #expect(verifiedFrame.width > 0 && verifiedFrame.height > 0)
        #expect(verifiedFrame.height == 44)
        #expect(disclosureFrame.width > 0 && disclosureFrame.height > 0)
        #expect([verifiedFrame, disclosureFrame, badgeFrame].allSatisfy {
            $0.width > 0 && $0.height > 0 && visibleRect.contains($0)
        })
        #expect(verifiedFrame.contains(badgeFrame))
        #expect((6...10).contains(badgeFrame.width - badgeLabelFrame.width))
        #expect(abs(badgeLabelFrame.minY - badgeFrame.minY - 1) <= 0.5)
        #expect(abs(badgeFrame.maxY - badgeLabelFrame.maxY - 1) <= 0.5)
        #expect(fixture.controller.selfTestBadgeCornerRadius(titled: "first") == 4)
        #expect(verifiedFrame.maxX - badgeFrame.maxX >= 10)
        #expect(verifiedFrame.intersection(disclosureFrame).isEmpty)
        #expect(panelDoesNotOverlapControl)
        #expect(layoutPassesAfterReads == layoutPassesBeforeReads)
    }

    @MainActor
    @Test
    func relationPossibleMatchesAreCollapsedThenExpandInPlace() async throws {
        let fixture = try await makeRelationUXFixture(
            includesExactMatch: false,
            expandPossible: false
        )
        defer { fixture.close() }

        #expect(
            fixture.controller.selfTestPossibleDisclosureTitle
                == "Show 2 possible matches"
        )
        #expect(
            fixture.controller.selfTestPossibleDisclosureDisplayText
                == ["Show possible matches", "2"]
        )
        #expect(
            fixture.controller.selfTestVisibleEdgeTitles(inGroup: "Possible")
                .isEmpty
        )
        #expect(fixture.controller.selfTestExpandPossibleMatches())
        #expect(
            fixture.controller.selfTestVisibleEdgeTitles(inGroup: "Possible")
                == ["first", "second"]
        )
        let visibleText = fixture.controller.selfTestVisibleText()
            .joined(separator: "\n")
        #expect(!visibleText.contains("Probable"))
        #expect(!visibleText.split(separator: "\n").contains("Strong"))
        #expect(!visibleText.split(separator: "\n").contains("Possible"))
        #expect(relationEdges(in: fixture.model.root).allSatisfy {
            !$0.isExpandable && $0.children?.isEmpty == true
        })
    }

    @MainActor
    @Test
    func relationPossibleExpansionStartsExactValidationOnDemand() async throws {
        var definitionRequests = 0
        let fixture = try await makeRelationUXFixture(
            includesExactMatch: false,
            expandPossible: false,
            exactResolver: { file, offset, _, _ in
                definitionRequests += 1
                return relationUXExactEntry(file: file, byteOffset: offset)
            }
        )
        defer { fixture.close() }

        #expect(definitionRequests == 0)
        #expect(fixture.controller.selfTestExpandPossibleMatches())
        await pumpRunLoop()

        #expect(definitionRequests == 2)
    }

    @MainActor
    @Test
    func relationPossibleValidationFollowsTheVisibleViewportInBatches()
        async throws
    {
        var requestedOffsets: [UInt32] = []
        let fixture = try await makeRelationUXFixture(
            includesExactMatch: false,
            expandPossible: false,
            possibleMatchCount: 64,
            exactResolver: { file, offset, _, _ in
                requestedOffsets.append(offset)
                return relationUXExactEntry(file: file, byteOffset: offset)
            }
        )
        defer { fixture.close() }
        let possible = try #require(fixture.model.root?.children?.first {
            $0.kind == .group && $0.title == "Show 64 possible matches"
        }?.children)
        let firstBatchOffsets = Set(
            possible.prefix(RelationTreeModel.possibleValidationBatchSize)
                .compactMap { $0.target?.byteOffset }
        )

        #expect(requestedOffsets.isEmpty)
        #expect(fixture.controller.selfTestExpandPossibleMatches())
        for _ in 0..<100 {
            if requestedOffsets.count
                == RelationTreeModel.possibleValidationBatchSize
            {
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(
            requestedOffsets.count
                == RelationTreeModel.possibleValidationBatchSize
        )
        #expect(Set(requestedOffsets) == firstBatchOffsets)
        #expect(requestedOffsets.count < possible.count)

        #expect(
            fixture.controller.selfTestScrollPossibleMatchToVisible(
                at: possible.count - 1
            )
        )
        for _ in 0..<100 {
            if requestedOffsets.count == possible.count { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        print(
            "possible viewport requests first="
                + "\(RelationTreeModel.possibleValidationBatchSize)"
                + " afterScroll=\(requestedOffsets.count)"
        )
        #expect(requestedOffsets.count == possible.count)
        #expect(Set(requestedOffsets).count == possible.count)
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
        try #require(await relationTestWaitUntil("await gate.started") { await gate.started })
        let staleRoot = try #require(fixture.model.root)
        var treeChanges = 0
        fixture.controller.onTreeChange = { treeChanges += 1 }

        fixture.controller.setRoot(
            target: .engine(fixture.firstSymbol),
            direction: .calls
        )
        try #require(await relationTestWaitUntil("fixture.model.root?.title == \"first\" && fixture.controller.selfTestVisibleEdgeTitles( inGroup: \"Strong\" ) == [\"first\", \"second\"]") {
            fixture.model.root?.title == "first"
                && fixture.model.root?.children?.contains {
                    $0.kind == .loading
                } == false
                && fixture.controller.selfTestVisibleEdgeTitles(
                    inGroup: "Strong"
                ) == ["first", "second"]
        })
        await pumpRunLoop()
        let changesBeforeStaleReturn = treeChanges
        await gate.release()
        try #require(await relationTestWaitUntil("await gate.finished") { await gate.finished })
        await pumpRunLoop()
        try? await Task.sleep(for: .milliseconds(500))
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

    @MainActor
    @Test
    func relationIncrementalPublicationReloadsOnlyTheChangedNode() async throws {
        let heuristic = RelationLoadGate()
        let exact = RelationLoadGate()
        let fixture = try await makeRelationUXFixture(
            direction: .calls,
            blockedSubjectLoad: heuristic,
            blockedExactLoad: exact
        )
        defer { fixture.close() }
        try #require(await relationTestWaitUntil(
            "heuristic and root Exact relation loads have both started"
        ) {
            let heuristicStarted = await heuristic.started
            let exactStarted = await exact.started
            return heuristicStarted && exactStarted
        })
        await pumpRunLoop()
        let wholeReloadsBeforeBatch = fixture.controller.selfTestWholeTreeReloads
        let nodeReloadsBeforeBatch = fixture.controller.selfTestNodeReloads

        await exact.release()
        let exactPublished = await relationTestWaitUntil(
            "the exact-first relation batch is visible"
        ) {
            fixture.controller.selfTestVisibleEdgeTitles(inGroup: "Exact")
                == ["first"]
        }
        let wholeReloadsAfterBatch = fixture.controller.selfTestWholeTreeReloads
        let nodeReloadsAfterBatch = fixture.controller.selfTestNodeReloads
        let selectedFirstBatchRow = exactPublished
            && fixture.controller.selfTestSelectEdge(titled: "first")
        await heuristic.release()
        try #require(await relationTestWaitUntil(
            "the heuristic relation load has finished"
        ) {
            await heuristic.finished
        })
        try #require(await relationTestWaitUntil(
            "all relation batches have finished loading"
        ) {
            fixture.model.root?.children?.contains {
                $0.kind == .loading
            } == false
        })
        await pumpRunLoop()

        #expect(exactPublished)
        #expect(wholeReloadsAfterBatch == wholeReloadsBeforeBatch)
        #expect(nodeReloadsAfterBatch == nodeReloadsBeforeBatch + 1)
        #expect(selectedFirstBatchRow)
        #expect(fixture.controller.selfTestSelectedEdgeTitle == "first")
        #expect(fixture.controller.selfTestWholeTreeReloads == wholeReloadsAfterBatch)
    }
}

@MainActor
@Test
func siClassicThemesTheWholeWindowChrome() async throws {
    let fixture = try await makeRelationNavigationFixture()
    defer {
        fixture.controller.close()
        try? FileManager.default.removeItem(at: fixture.root)
    }
    var settings = ReaderSettings()
    settings.theme = .siClassic
    fixture.controller.applyReaderSettings(settings)
    let expected = try #require(
        ReaderTheme(settings: settings).chromeColor.usingColorSpace(.sRGB)
    )
    let windowColor = try #require(
        fixture.controller.window?.backgroundColor.usingColorSpace(.sRGB)
    )
    let statusColor = try #require(
        fixture.controller.selfTestStatusBarBackgroundColor?
            .usingColorSpace(.sRGB)
    )

    #expect(abs(windowColor.redComponent - expected.redComponent) < 0.001)
    #expect(abs(windowColor.greenComponent - expected.greenComponent) < 0.001)
    #expect(abs(windowColor.blueComponent - expected.blueComponent) < 0.001)
    #expect(fixture.controller.window?.titlebarAppearsTransparent == true)
    #expect(abs(statusColor.redComponent - expected.redComponent) < 0.001)
    #expect(abs(statusColor.greenComponent - expected.greenComponent) < 0.001)
    #expect(abs(statusColor.blueComponent - expected.blueComponent) < 0.001)
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
    try #require(await relationTestWaitUntil("fixture.controller.displayedReaderFile?.standardizedFileURL == main.standardizedFileURL") {
        fixture.controller.displayedReaderFile?.standardizedFileURL
            == main.standardizedFileURL
    })
    fixture.controller.openFileInNewTabForSelfTest(a)
    try #require(await relationTestWaitUntil("fixture.controller.displayedReaderFile?.standardizedFileURL == a.standardizedFileURL") {
        fixture.controller.displayedReaderFile?.standardizedFileURL
            == a.standardizedFileURL
    })
    fixture.controller.openFileInNewTabForSelfTest(b)
    try #require(await relationTestWaitUntil("fixture.controller.displayedReaderFile?.standardizedFileURL == b.standardizedFileURL") {
        fixture.controller.displayedReaderFile?.standardizedFileURL
            == b.standardizedFileURL
    })
    fixture.controller.openFileForSelfTest(main)
    try #require(await relationTestWaitUntil("fixture.controller.displayedReaderFile?.standardizedFileURL == main.standardizedFileURL") {
        fixture.controller.displayedReaderFile?.standardizedFileURL
            == main.standardizedFileURL
    })
    #expect(fixture.controller.selfTestTabCount == 3)

    fixture.controller.selfTestReaderRelation(
        offset: byteOffset(of: "target() {}", in: fixture.mainSource),
        direction: .references
    )
    try #require(await relationTestWaitUntil("reference rows are loaded") {
        referenceEdge(path: "a.rs", in: fixture.model) != nil
            && referenceEdge(path: "b.rs", in: fixture.model) != nil
    })
    #expect(fixture.controller.selfTestExpandPossibleRelations())
    try #require(await relationTestWaitUntil("reference rows are visible") {
        fixture.controller.selfTestVisibleRelationEdgeTitles(
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
        try #require(await relationTestWaitUntil("fixture.model.selectedFile?.standardizedFileURL == file.standardizedFileURL && fixture.model.selectedByteOffset == edge.target?.byteOffset && fixture.controller.displayedReaderFile?.standardizedFileURL == file.standar...") {
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
    try #require(await relationTestWaitUntil("fixture.controller.displayedReaderFile?.standardizedFileURL == main.standardizedFileURL") {
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
        try #require(await relationTestWaitUntil("fixture.model.relationTree.root?.title == rootTitle && relationEdge(titled: edgeTitle, in: fixture.model) != nil && fixture.controller.selfTestVisibleRelationEdgeTitles( inGroup: \"Strong\" ).contains(edgeTitle)") {
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
    try #require(await relationTestWaitUntil("fixture.controller.displayedReaderFile?.standardizedFileURL == main.standardizedFileURL") {
        fixture.controller.displayedReaderFile?.standardizedFileURL
            == main.standardizedFileURL
    })
    let offset = byteOffset(of: "value.close();", in: fixture.mainSource)
        + UInt32("value.".utf8.count)
    fixture.controller.selfTestReaderClick(offset: offset, commandClick: false)
    try #require(await relationTestWaitUntil("fixture.model.contextWindow.candidateCount == 2") {
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
        try #require(await relationTestWaitUntil("fixture.model.relationTree.generation > generation && fixture.model.relationTree.direction == direction") {
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
    try #require(await relationTestWaitUntil("fixture.controller.displayedReaderFile?.standardizedFileURL == main.standardizedFileURL") {
        fixture.controller.displayedReaderFile?.standardizedFileURL
            == main.standardizedFileURL
    })
    let ambiguousOffset = byteOffset(of: "value.close();", in: fixture.mainSource)
        + UInt32("value.".utf8.count)
    fixture.controller.selfTestReaderClick(
        offset: ambiguousOffset,
        commandClick: false
    )
    try #require(await relationTestWaitUntil("fixture.model.contextWindow.candidateCount == 2") {
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
    try #require(await relationTestWaitUntil("fixture.model.relationTree.root?.symbol == target") {
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
    try #require(await relationTestWaitUntil("fixture.controller.displayedReaderFile?.standardizedFileURL == main.standardizedFileURL") {
        fixture.controller.displayedReaderFile?.standardizedFileURL
            == main.standardizedFileURL
    })
    let pinnedOffset = byteOffset(of: "value.close();", in: fixture.mainSource)
        + UInt32("value.".utf8.count)
    fixture.controller.selfTestReaderClick(offset: pinnedOffset, commandClick: false)
    try #require(await relationTestWaitUntil("fixture.model.contextWindow.candidateCount == 2") {
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
    try #require(await relationTestWaitUntil("fixture.model.relationTree.root?.symbol == target") {
        fixture.model.relationTree.root?.symbol == target
    })
    #expect(fixture.model.relationTree.root?.symbol == target)
    #expect(fixture.model.relationTree.root?.symbol != pinned)

    fixture.controller.selfTestReaderRelation(
        offset: pinnedOffset,
        direction: .callers
    )
    try #require(await relationTestWaitUntil("fixture.model.relationTree.root?.symbol != target") {
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
    try #require(await relationTestWaitUntil("fixture.controller.displayedReaderFile?.standardizedFileURL == main.standardizedFileURL") {
        fixture.controller.displayedReaderFile?.standardizedFileURL
            == main.standardizedFileURL
    })
    fixture.controller.selfTestReaderClick(
        offset: byteOffset(of: "target();", in: fixture.mainSource),
        commandClick: false
    )
    try #require(await relationTestWaitUntil("fixture.model.contextWindow.selectedCandidate != nil") { fixture.model.contextWindow.selectedCandidate != nil })
    fixture.controller.selfTestSetContextPinned(true)
    let pinnedCandidate = try #require(fixture.model.contextWindow.selectedCandidate)
    let pinnedRequest = fixture.model.contextWindow.requestID

    fixture.controller.selfTestReaderRelation(
        offset: byteOffset(of: "target() {}", in: fixture.mainSource),
        direction: .references
    )
    try #require(await relationTestWaitUntil("a.rs reference is loaded") {
        referenceEdge(path: "a.rs", in: fixture.model) != nil
    })
    #expect(fixture.controller.selfTestExpandPossibleRelations())
    try #require(await relationTestWaitUntil("a.rs reference is visible") {
        fixture.controller.selfTestVisibleRelationEdgeTitles(
            inGroup: "References"
        ).contains { $0.hasPrefix("a.rs:") }
    })
    let edge = try #require(referenceEdge(path: "a.rs", in: fixture.model))
    #expect(fixture.controller.selfTestSelectRelationEdge(titled: edge.title))
    try #require(await relationTestWaitUntil("fixture.model.selectedFile?.standardizedFileURL == a.standardizedFileURL && fixture.model.selectedByteOffset == edge.target?.byteOffset") {
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
    try #require(await relationTestWaitUntil("fixture.controller.displayedReaderFile?.standardizedFileURL == main.standardizedFileURL") {
        fixture.controller.displayedReaderFile?.standardizedFileURL
            == main.standardizedFileURL
    })
    let beforeNavigation = fixture.model.navigationGeneration

    fixture.controller.selfTestReaderRelation(
        offset: byteOffset(of: "target() {}", in: fixture.mainSource),
        direction: .callers
    )
    try #require(await relationTestWaitUntil("fixture.model.relationTree.root?.title == \"target\" && fixture.model.relationTree.direction == .callers") {
        fixture.model.relationTree.root?.title == "target"
            && fixture.model.relationTree.direction == .callers
    })
    #expect(fixture.model.navigationGeneration == beforeNavigation)

    fixture.controller.selfTestChangeRelationDirection(.calls)
    try #require(await relationTestWaitUntil("fixture.model.relationTree.root?.title == \"target\" && fixture.model.relationTree.direction == .calls") {
        fixture.model.relationTree.root?.title == "target"
            && fixture.model.relationTree.direction == .calls
    })
    #expect(fixture.model.navigationGeneration == beforeNavigation)

    fixture.controller.selfTestReaderRelation(
        offset: byteOffset(of: "target() {}", in: fixture.mainSource),
        direction: .references
    )
    try #require(await relationTestWaitUntil("fixture.model.relationTree.root?.title == \"target\" && referenceEdge(path: \"a.rs\", in: fixture.model) != nil") {
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
    try #require(await relationTestWaitUntil("fixture.controller.displayedReaderFile?.standardizedFileURL == main.standardizedFileURL") {
        fixture.controller.displayedReaderFile?.standardizedFileURL
            == main.standardizedFileURL
    })
    fixture.controller.selfTestReaderRelation(
        offset: byteOffset(of: "target() {}", in: fixture.mainSource),
        direction: .references
    )
    try #require(await relationTestWaitUntil("a.rs reference is loaded") {
        referenceEdge(path: "a.rs", in: fixture.model) != nil
    })
    #expect(fixture.controller.selfTestExpandPossibleRelations())
    try #require(await relationTestWaitUntil("a.rs reference is visible") {
        fixture.controller.selfTestVisibleRelationEdgeTitles(
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
    try #require(await relationTestWaitUntil("fixture.model.selectedFile?.standardizedFileURL == a.standardizedFileURL && fixture.model.selectedByteOffset == edge.target?.byteOffset") {
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
    try #require(await relationTestWaitUntil("fixture.model.selectedFile?.standardizedFileURL == main.standardizedFileURL && fixture.controller.displayedReaderFile?.standardizedFileURL == main.standardizedFileURL") {
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
    guard await relationTestWaitUntil(
        "model.snapshotPhase == .fullReady and file tree matches project root",
        {
            model.snapshotPhase == .fullReady
                && model.fileTree?.root.standardizedFileURL == root.standardizedFileURL
        }
    ) else {
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
    relationEdges(in: model.relationTree.root)
        .first { $0.kind == .edge && $0.title == title }
}

@MainActor
private func referenceEdge(
    path: String,
    in model: AppModel
) -> RelationTreeModel.Node? {
    relationEdges(in: model.relationTree.root)
        .first { $0.kind == .edge && $0.target?.path == path }
}

@MainActor
private func relationEdges(
    in root: RelationTreeModel.Node?
) -> [RelationTreeModel.Node] {
    root?.children?.flatMap { child in
        child.kind == .edge
            ? [child]
            : (child.children ?? []).filter { $0.kind == .edge }
    } ?? []
}

private func byteOffset(of needle: String, in source: String) -> UInt32 {
    let range = source.range(of: needle)!
    return UInt32(source[..<range.lowerBound].utf8.count)
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
    blockedSubjectLoad: RelationLoadGate? = nil,
    blockedExactLoad: RelationLoadGate? = nil,
    expandPossible: Bool = true,
    possibleMatchCount: Int = 2,
    exactResolver: RelationTreeModel.ExactResolver? = nil
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
    let possibleNames = ["first", "second"] + (2..<possibleMatchCount).map {
        "possible\($0)"
    }
    let source = """
        fn subject() {}
        \(possibleNames.map { "fn \($0)() { subject(); }" }.joined(separator: "\n"))
        """
    try Data(source.utf8).write(to: root.appendingPathComponent("main.rs"))
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
    let possibleSymbols = try possibleNames.map { name in
        try #require(session.definitions(of: name, context: context).first?.0)
    }
    let first = possibleSymbols[0]
    let second = possibleSymbols[1]
    let firstLocation = try #require(relationLocation(for: first, in: session))
    let secondLocation = try #require(relationLocation(for: second, in: session))
    let fuzzyLocations = try zip(possibleNames, possibleSymbols).map {
        name, symbol in
        (name, try #require(relationLocation(for: symbol, in: session)))
    }
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
    let exactFirstGate =
        includesExactMatch
            && blockedSubjectLoad == nil
            && blockedExactLoad == nil
        ? RelationLoadGate()
        : nil
    let model = RelationTreeModel(
        loader: { _, _, symbol, loadDirection in
            if symbol == subject, let blockedSubjectLoad {
                await blockedSubjectLoad.wait(
                    "stale heuristic relation load release"
                )
                return .init(edges: [stale], isTruncated: false)
            }
            if symbol == subject, let exactFirstGate {
                await exactFirstGate.wait(
                    "heuristic relation load release"
                )
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
                        evidence: [],
                        exactQuery: exactResolver == nil
                            ? nil
                            : (location.path, location.byteOffset, location.line),
                        fuzzyTarget: exactResolver == nil
                            ? nil
                            : (location.path, location.byteOffset)
                    )
                },
                isTruncated: false
            )
        },
        exactResolver: exactResolver,
        exactRelationsResolver: { _, _, _, _, _, _ in
            if let blockedExactLoad {
                await blockedExactLoad.wait("root Exact relation release")
            }
            return includesExactMatch
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
    if let exactFirstGate {
        let exactPublished = await relationTestWaitUntil(
            "the exact-first fixture batch is visible"
        ) {
            controller.selfTestVisibleEdgeTitles(inGroup: "Exact") == ["first"]
        }
        await exactFirstGate.release()
        try #require(exactPublished)
    }
    if blockedSubjectLoad == nil && blockedExactLoad == nil {
        try #require(await relationTestWaitUntil(
            "the relation fixture has finished its initial load"
        ) {
            guard model.root?.children?.contains(where: {
                $0.kind == .loading
            }) == false else { return false }
            if includesExactMatch {
                return controller.selfTestVisibleEdgeTitles(inGroup: "Exact")
                    == ["first"]
            }
            if direction == .references {
                guard controller.selfTestPossibleDisclosureTitle
                    == "Show \(possibleMatchCount) possible matches"
                else { return false }
                if !expandPossible { return true }
                return controller.selfTestExpandPossibleMatches()
                    && controller.selfTestVisibleEdgeTitles(inGroup: "Possible")
                        == possibleNames
            }
            return controller.selfTestVisibleEdgeTitles(inGroup: "Strong")
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

private func relationUXExactEntry(
    file: String,
    byteOffset: UInt32
) -> ExactOverlay.Entry {
    ExactOverlay.Entry(
        location: ExactLocation(
            file: file,
            byteOffset: Int(byteOffset),
            line: 1,
            column: Int(byteOffset) + 1
        ),
        attribution: ExactAttribution(
            provider: "fake-exact",
            toolVersion: "fake-1",
            configFingerprint: "config",
            environmentFingerprint: "environment",
            trustMode: .safe,
            generatedAt: Date(timeIntervalSince1970: 0),
            coverage: .partial
        ),
        origin: .worktree
    )
}

private actor RelationLoadGate {
    private var isReleased = false
    private(set) var started = false
    private(set) var finished = false

    func wait(_ waitingFor: String = "relation load release") async {
        started = true
        let deadline = ContinuousClock.now + .seconds(120)
        while !isReleased,
              !Task.isCancelled,
              ContinuousClock.now < deadline
        {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if !isReleased, !Task.isCancelled {
            Issue.record("Timed out waiting for \(waitingFor)")
        }
        finished = true
    }

    func release() {
        isReleased = true
    }
}

@MainActor
private func relationTestWaitUntil(
    _ description: String,
    _ condition: @escaping @MainActor () async -> Bool,
) async -> Bool {
    // This wall-clock bound is only a hang fuse; performance has separate budget tests.
    let deadline = ContinuousClock.now + .seconds(120)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        do {
            try await Task.sleep(for: .milliseconds(10))
        } catch {
            Issue.record("Cancelled while waiting for: \(description)")
            return false
        }
    }
    if await condition() { return true }
    Issue.record("Hang fuse expired while waiting for: \(description)")
    return false
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
