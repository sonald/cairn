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
    func mainWindowChromeStaysCompactWhenContentNarrows() {
        let controller = MainWindowController(
            model: AppModel(),
            settings: ReaderSettings(),
            offscreen: true
        )
        defer { controller.close() }

        #expect(controller.selfTestExactStatusAllowsHorizontalCompression)
        let rows = controller.selfTestSidebarRowGeometry
        #expect(rows.height <= 20)
        #expect(rows.spacing.height == 0)
    }

    @MainActor
    @Test
    func relationsFreezePublishedLocationsIntoAReadingSetInProducerOrder() async throws {
        let fixture = try await makeRelationUXFixture()
        defer { fixture.close() }
        var captured: (String, [ReadingSetExcerpt], [String])?
        fixture.controller.onOpenReadingSet = { captured = ($0, $1, $2) }
        let button = fixture.controller.selfTestReadingSetButtonState

        #expect(button.0 == "Reading Set")
        #expect(button.1)
        #expect(button.2 == "Open as Reading Set")
        fixture.controller.selfTestOpenAsReadingSet()
        let result = try #require(captured)
        #expect(result.0 == "subject")
        #expect(result.1.map(\.symbol).first == "first")
        #expect(result.1.allSatisfy { !$0.sourceText.isEmpty })
        #expect(result.1.allSatisfy {
            $0.contentID.algorithm == 1 && $0.contentID.bytes.count == 32
        })
        #expect(result.1.first?.inspector.auditRows.map(\.label) == [
            "Source", "Content", "Captured at",
        ])
        #expect(result.1.first?.inspector.availabilityBody.contains("at capture") == true)
        #expect(result.2.isEmpty)

        let display = try #require(result.1.first?.inspector)
        fixture.controller.showFrozenInspector(display)
        #expect(fixture.controller.selfTestInspectorIsFrozen)
        #expect(fixture.controller.selfTestInspectorText.contains("AT CAPTURE"))
        #expect(fixture.controller.selfTestInspectorText.contains(display.nodeTitle))
        #expect(fixture.controller.selfTestInspectorText.contains(display.availabilityBody))
        #expect(fixture.controller.selfTestInspectorText.contains(display.environmentBody))
        #expect(!fixture.controller.selfTestInspectorText.contains {
            $0.localizedCaseInsensitiveContains("snapshot")
        })
        #expect(fixture.controller.selfTestInspectorAccessibility.0
            == "Resolution Inspector for \(display.nodeTitle), at capture")

        fixture.model.updateProjectState(.empty)
        await pumpRunLoop()
        #expect(fixture.controller.selfTestInspectorIsFrozen)
        #expect(fixture.controller.selfTestInspectorVisible)
        #expect(fixture.controller.selfTestInspectorText.contains("AT CAPTURE"))
    }

    @MainActor
    @Test
    func relationsReportTheFiftyExcerptCapWithoutReorderingSeeds() async throws {
        let fixture = try await makeRelationUXFixture(
            includesExactMatch: false,
            possibleMatchCount: 55
        )
        defer { fixture.close() }
        var captured: (String, [ReadingSetExcerpt], [String])?
        fixture.controller.onOpenReadingSet = { captured = ($0, $1, $2) }

        fixture.controller.selfTestOpenAsReadingSet()

        let result = try #require(captured)
        #expect(result.1.count == 50)
        #expect(result.1.prefix(3).map(\.symbol) == [
            "first", "second", "possible2",
        ])
        #expect(result.2 == Array(
            repeating: "display cap (50 excerpts)",
            count: 5
        ))
    }

    @MainActor
    @Test
    func relationsOpenAnEmptyReadingSetWithEverySourceSkipReason() async throws {
        let fixture = try await makeRelationUXFixture(
            capturedSourceAvailable: false
        )
        defer { fixture.close() }
        var captured: (String, [ReadingSetExcerpt], [String])?
        fixture.controller.onOpenReadingSet = { captured = ($0, $1, $2) }

        fixture.controller.selfTestOpenAsReadingSet()

        let result = try #require(captured)
        #expect(result.1.isEmpty)
        #expect(!result.2.isEmpty)
        #expect(result.2.allSatisfy {
            $0 == "recorded source is unreadable"
        })
    }

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
                == "Verified by exact provider"
        )
        #expect(accessibility.role != NSAccessibility.Role.textField.rawValue)
        #expect(accessibility.valueSettable == false)
    }

    @MainActor
    @Test
    func selectingRelationKeepsInspectorClosedUntilRequested() async throws {
        let fixture = try await makeRelationUXFixture()
        defer { fixture.close() }

        #expect(fixture.controller.selfTestSelectEdge(titled: "first"))
        #expect(!fixture.controller.selfTestInspectorVisible)
        #expect(fixture.controller.selfTestPressInspectorShortcut())
        #expect(fixture.controller.selfTestInspectorVisible)
    }

    @MainActor
    @Test
    func resolutionInspectorMatchesProgressiveDisclosureAndAX() async throws {
        let fixture = try await makeRelationUXFixture()
        defer { fixture.close() }
        var opens = 0
        fixture.controller.onOpen = { _ in opens += 1 }

        #expect(fixture.controller.selfTestClickBadge(titled: "first"))
        await pumpRunLoop()
        let text = fixture.controller.selfTestInspectorText
        let accessibility = fixture.controller.selfTestInspectorAccessibility
        #expect(fixture.controller.selfTestInspectorVisible)
        #expect(fixture.controller.selfTestInspectorButtonTitle == "Inspector")
        #expect(opens == 0)
        #expect(text.contains("SOURCE"))
        #expect(text.contains("VERIFICATION"))
        #expect(text.contains("VERIFICATION AVAILABILITY"))
        #expect(text.contains { $0.contains("Candidate generation was complete") })
        #expect(text.contains { $0.contains("The exact provider returned this target") })
        #expect(text.contains { $0.contains("Safe") })
        #expect(!fixture.controller.selfTestInspectorAuditVisible)
        #expect(text.contains("Show full audit"))
        #expect(accessibility.0 == "Resolution Inspector for first")
        #expect(accessibility.1.contains("Verified"))
        #expect(accessibility.2 == NSAccessibility.Role.group.rawValue)
        #expect(accessibility.3 == false)
        let listFrame = fixture.controller.selfTestRelationListFrame
        let inspectorFrame = fixture.controller.selfTestInspectorFrame
        #expect(listFrame.width > 0 && inspectorFrame.width > 0)
        #expect(listFrame.intersection(inspectorFrame).isEmpty)
        if let directory = ProcessInfo.processInfo.environment[
            "CODEINSIGHT_M10_CAPTURE_DIR"
        ] {
            for (name, selection) in [
                ("light", ReaderSettings.Theme.light),
                ("dark", ReaderSettings.Theme.dark),
                ("si-classic", ReaderSettings.Theme.siClassic),
            ] {
                var settings = ReaderSettings()
                settings.theme = selection
                fixture.controller.apply(settings: settings)
                fixture.controller.view.layoutSubtreeIfNeeded()
                try capturePNG(
                    fixture.controller.view,
                    at: URL(fileURLWithPath: directory)
                        .appendingPathComponent(
                            "resolution-inspector-\(name).png"
                        )
                )
            }
        }

        fixture.controller.selfTestToggleInspectorAudit()
        #expect(fixture.controller.selfTestInspectorAuditVisible)
        #expect(fixture.controller.selfTestInspectorText.contains("Hide full audit"))
        #expect(fixture.controller.selfTestInspectorText.contains("Source"))
        #expect(fixture.controller.selfTestInspectorText.contains("Content"))
        #expect(fixture.controller.selfTestInspectorText.contains("Captured at"))
        #expect(!fixture.controller.selfTestInspectorText.contains("Snapshot"))
        let openListWidth = fixture.controller.selfTestRelationListFrame.width
        fixture.controller.selfTestCloseInspector()
        #expect(!fixture.controller.selfTestInspectorVisible)
        #expect(fixture.controller.selfTestRelationListFrame.width > openListWidth * 1.8)
        #expect(fixture.controller.selfTestPressInspectorShortcut())
        #expect(fixture.controller.selfTestInspectorVisible)
        #expect(abs(
            fixture.controller.selfTestRelationListFrame.width - openListWidth
        ) <= 1)
        #expect(opens == 0)
    }

    @MainActor
    @Test
    func correctedCandidateOnlyNavigatesThroughExplicitInspectorAction()
        async throws
    {
        let fixture = try await makeRelationUXFixture(
            includesExactMatch: false,
            expandPossible: false,
            exactResolver: { _, _, _, _ in
                .completed([
                    relationUXExactEntry(file: "main.rs", byteOffset: 3),
                ])
            }
        )
        defer { fixture.close() }
        #expect(fixture.controller.selfTestExpandPossibleMatches())
        try #require(await relationTestWaitUntil(
            "corrected candidates are published"
        ) {
            fixture.controller.selfTestCorrectedDisclosureDisplayText
                == ["Show corrected candidates", "2"]
        })
        #expect((fixture.model.root?.children ?? []).filter {
            $0.kind == .group && $0.title.hasPrefix("Show ")
        }.count <= 2)
        var opens: [String] = []
        fixture.controller.onOpen = { opens.append($0.title) }

        #expect(fixture.controller.selfTestSelectCorrectedCandidate(titled: "first"))
        #expect(opens.isEmpty)
        #expect(fixture.controller.selfTestInspectorText.contains(
            "VERIFICATION CONFLICT"
        ))
        #expect(fixture.controller.selfTestInspectorText.contains(
            "Open former candidate"
        ))
        fixture.controller.selfTestOpenSelection()
        fixture.controller.selfTestOpenSelection()
        #expect(opens.isEmpty)
        fixture.controller.selfTestOpenFormerCandidate()
        #expect(opens == ["first"])

        let provider = try #require(fixture.model.root?.children?.first {
            $0.kind == .edge && $0.badge == "Verified"
        })
        #expect(provider.modifiers.contains("corrected 2"))
        #expect(fixture.controller.selfTestClickBadge(titled: provider.title))
        #expect(fixture.controller.selfTestInspectorText.contains {
            $0.contains("replaced earlier source candidates: first, second")
        })
    }

    @MainActor
    @Test
    func ambiguityTrapInspectorSeparatesCandidateAndResultSetCompleteness()
        async throws
    {
        let exactGate = RelationLoadGate()
        let fixture = try await makeRelationUXFixture(
            direction: .calls,
            includesExactMatch: false,
            blockedExactLoad: exactGate,
            expandPossible: false,
            sourceResultIsTruncated: true,
            usesMethodNameOnlyEvidence: true
        )
        defer {
            Task { await exactGate.release() }
            fixture.close()
        }
        try #require(await relationTestWaitUntil("trap candidate is visible") {
            fixture.controller.selfTestPossibleDisclosureTitle
                == "Show 2 possible matches"
        })
        #expect(fixture.controller.selfTestExpandPossibleMatches())
        #expect(fixture.controller.selfTestClickBadge(titled: "first"))
        let text = fixture.controller.selfTestInspectorText.joined(separator: " ")
        let accessibility = try #require(
            fixture.controller.selfTestAccessibility(
                titled: "first",
                inGroup: "Possible"
            )
        )
        #expect(accessibility.value.contains("Inferred"))
        #expect(!accessibility.value.contains("Verified"))
        #expect(accessibility.value.contains("name match only"))
        #expect(text.contains("Matched by method name only"))
        #expect(text.contains("Candidate generation was complete"))
        #expect(text.contains("source relation result set was truncated"))
        #expect(text.contains("Exact verification is in progress"))
        #expect(!text.localizedCaseInsensitiveContains("unique target"))
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
                return .completed([
                    relationUXExactEntry(file: file, byteOffset: offset),
                ])
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
    func relationCorrectedCandidatesUseTheirOwnWarningDisclosure() async throws {
        let fixture = try await makeRelationUXFixture(
            includesExactMatch: false,
            expandPossible: false,
            exactResolver: { _, _, _, _ in
                .completed([
                    relationUXExactEntry(file: "main.rs", byteOffset: 3),
                ])
            }
        )
        defer { fixture.close() }

        #expect(fixture.controller.selfTestExpandPossibleMatches())
        for _ in 0..<100 {
            if fixture.controller.selfTestCorrectedDisclosureDisplayText
                == ["Show corrected candidates", "2"]
            {
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(fixture.controller.selfTestCorrectedDisclosureDisplayText
            == ["Show corrected candidates", "2"])
        #expect(fixture.controller.selfTestPossibleDisclosureTitle == nil)
        #expect(relationEdges(in: fixture.model.root).filter {
            $0.badge == "Verified"
        }.count == 1)
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
                return .completed([
                    relationUXExactEntry(file: file, byteOffset: offset),
                ])
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

        for _ in 0..<100 {
            let count = fixture.model.root?.children?.first {
                $0.kind == .group
                    && $0.title.hasSuffix("possible matches")
            }?.children?.count
            if count == possible.count - requestedOffsets.count { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let remainingPossible = try #require(fixture.model.root?.children?.first {
            $0.kind == .group
                && $0.title.hasSuffix("possible matches")
        }?.children)
        #expect(remainingPossible.count == possible.count - requestedOffsets.count)
        #expect(fixture.controller.selfTestExpandPossibleMatches())
        await pumpRunLoop()
        #expect(fixture.controller.selfTestScrollPossibleMatchToVisible(
            at: remainingPossible.count - 1
        ))
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
        references.controller.onOpen = {
            if let target = $0.target {
                referenceOpens.append((target.path, target.byteOffset))
            }
        }
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
        symbols.controller.onOpen = {
            if let target = $0.target {
                symbolOpens.append((target.path, target.byteOffset))
            }
        }
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
func sessionCheckpointCapturesTwoAnchorsAndSynchronizesCloseAndLRU() async throws {
    let stateRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
        "CodeInsightSessionCheckpoint-\(UUID().uuidString)",
        isDirectory: true
    )
    let sessionURL = stateRoot.appendingPathComponent("session.json")
    let fixture = try await makeRelationNavigationFixture(sessionURL: sessionURL)
    defer {
        fixture.controller.close()
        try? FileManager.default.removeItem(at: fixture.root)
        try? FileManager.default.removeItem(at: stateRoot)
        #expect(!FileManager.default.fileExists(atPath: sessionURL.path))
    }
    let main = fixture.root.appendingPathComponent("main.rs")
    let selection = byteOffset(of: "target();", in: fixture.mainSource)
    fixture.controller.openFileForSelfTest(main)
    try #require(await relationTestWaitUntil(
        "the main document is loaded",
        {
            fixture.controller.displayedReaderFile?.standardizedFileURL
                == main.standardizedFileURL
                && fixture.model.tabStrip.activeDocument != nil
        }
    ))
    fixture.controller.setReadingPositionForSelfTest(
        scrollByteOffset: 0,
        selectionByteOffset: selection
    )
    await pumpRunLoop()
    fixture.controller.checkpointSessionSynchronously()

    var snapshot = try SessionCodec.decode(
        Data(contentsOf: sessionURL),
        maximumTabCount: fixture.model.tabStrip.maximumCount,
        dependencyAllowed: { _ in false }
    )
    #expect(snapshot.projectRoot == fixture.root.path)
    #expect(snapshot.revision == nil)
    #expect(snapshot.activeTabOrdinal == 0)
    #expect(snapshot.panelPreset == PanelPresetModel.reading.rawValue)
    let fileTab: SessionCodec.FileTab? = if case .file(let tab) = snapshot.tabs.first {
        tab
    } else {
        nil
    }
    #expect(fileTab?.path == "main.rs")
    #expect(fileTab?.anchorContentID == ContentID.sha256(of: Array(fixture.mainSource.utf8)))
    #expect(fileTab?.scrollAnchor?.byteOffset == 0)
    #expect(fileTab?.selectionAnchor?.byteOffset == selection)
    #expect(fileTab?.selectionAnchor?.byteOffset != fileTab?.scrollAnchor?.byteOffset)

    fixture.model.openReadingSet(
        title: "frozen target",
        excerpts: [],
        skippedReasons: ["recorded source is unreadable"]
    )
    fixture.model.tabStrip.updateActiveReadingSetScroll(37)
    try fixture.model.writeSessionCheckpoint(panelPreset: .reading)
    snapshot = try SessionCodec.decode(
        Data(contentsOf: sessionURL),
        maximumTabCount: fixture.model.tabStrip.maximumCount,
        dependencyAllowed: { _ in false }
    )
    let readingSet: SessionCodec.ReadingSetTab? = if case .readingSet(let tab) = snapshot.tabs.last {
        tab
    } else {
        nil
    }
    #expect(readingSet?.title == "frozen target")
    #expect(readingSet?.scrollOffset == 37)
    #expect(readingSet?.skippedReasons == ["recorded source is unreadable"])

    fixture.controller.closeActiveTab()
    snapshot = try SessionCodec.decode(
        Data(contentsOf: sessionURL),
        maximumTabCount: fixture.model.tabStrip.maximumCount,
        dependencyAllowed: { _ in false }
    )
    #expect(snapshot.tabs.count == 1)
    #expect(snapshot.activeTabOrdinal == 0)

    fixture.controller.closeActiveTab()
    for index in 0...fixture.model.tabStrip.maximumCount {
        fixture.controller.openFileInNewTabForSelfTest(
            fixture.root.appendingPathComponent("generated\(index).rs")
        )
    }
    snapshot = try SessionCodec.decode(
        Data(contentsOf: sessionURL),
        maximumTabCount: fixture.model.tabStrip.maximumCount,
        dependencyAllowed: { _ in false }
    )
    #expect(snapshot.tabs.count == fixture.model.tabStrip.maximumCount)
    #expect(snapshot.activeTabOrdinal == fixture.model.tabStrip.maximumCount - 1)
    #expect(snapshot.tabs.compactMap { tab -> String? in
        guard case .file(let file) = tab else { return nil }
        return file.path
    } == (1...fixture.model.tabStrip.maximumCount).map { "generated\($0).rs" })
}

@MainActor
@Test
func sessionRestoreAppliesPanelAndDistinctViewportAndSelectionAnchors() async throws {
    let fixture = try await makeRelationNavigationFixture()
    defer {
        fixture.controller.close()
        try? FileManager.default.removeItem(at: fixture.root)
    }
    let selection = byteOffset(of: "target();", in: fixture.mainSource)
    let snapshot = SessionCodec.Snapshot(
        projectRoot: fixture.root.path,
        language: .rust,
        revision: nil,
        activeTabOrdinal: 0,
        panelPreset: PanelPresetModel.relations.rawValue,
        tabs: [
            .file(.init(
                path: "main.rs",
                anchorContentID: ContentID.sha256(
                    of: Array(fixture.mainSource.utf8)
                ),
                scrollAnchor: .init(
                    byteOffset: 0,
                    line: 1,
                    column: 1,
                    symbolAnchor: "target"
                ),
                selectionAnchor: .init(
                    byteOffset: selection,
                    line: 3,
                    column: 27,
                    symbolAnchor: "target"
                )
            )),
        ]
    )

    fixture.controller.restoreSession(snapshot)
    try #require(await relationTestWaitUntil(
        "session tab and document are restored",
        {
            fixture.model.snapshotPhase == .fullReady
                && fixture.controller.displayedReaderFile?.standardizedFileURL
                    == fixture.root.appendingPathComponent("main.rs")
                        .standardizedFileURL
                && fixture.controller.selfTestActiveTabSelectionByteOffset
                    == selection
                && fixture.controller.selfTestReadingByteOffset == 0
        }
    ))

    #expect(fixture.controller.selfTestPanelPreset == .relations)
    #expect(fixture.controller.selfTestTabCount == 1)
    #expect(fixture.controller.selfTestActiveTabIndex == 0)
    #expect(fixture.controller.selfTestReadingByteOffset == 0)
    #expect(fixture.controller.selfTestActiveTabSelectionByteOffset == selection)
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
    let explanation = try #require(
        fixture.model.activeNavigationRequest?.explanation
    )
    #expect(fixture.model.readingTrail.edges.last?.currentExplanationID
        == explanation.explanationID)
    let recordedEdge = try #require(fixture.model.readingTrail.edges.last)
    #expect(recordedEdge.frozenInspectorDisplay?.nodeTitle == edge.title)
    let recordedDestination = try #require(
        fixture.model.readingTrail.nodes[recordedEdge.to]
    )
    #expect(recordedDestination.jump.contentID != nil)
    #expect(recordedDestination.jump.line > 0)
    #expect(recordedDestination.jump.column > 0)
    #expect(fixture.model.resolutionExplanations.value(
        for: explanation.explanationID
    ) != nil)
    #expect(fixture.controller.canShowResolutionInspector)
    fixture.controller.selfTestCloseResolutionInspector()
    #expect(!fixture.controller.selfTestResolutionInspectorVisible)
    fixture.controller.showResolutionInspector()
    #expect(fixture.controller.selfTestResolutionInspectorVisible)
    fixture.controller.showWindow(nil)
    fixture.controller.window?.displayIfNeeded()
    #expect(fixture.controller.selfTestTrailBarVisible)
    #expect(fixture.controller.selfTestTrailBreadcrumbTitles.count == 2)
    #expect(fixture.controller.selfTestTrailBreadcrumbText.contains("relation"))
    #expect(fixture.controller.selfTestTrailBarAccessibility.label
        == "Reading Trail")
    #expect(fixture.controller.selfTestTrailBarAccessibility.role
        == NSAccessibility.Role.group.rawValue)
    let trailFrame = fixture.controller.selfTestTrailBarFrameInContentView
    let contentFrame = fixture.controller.selfTestContentSplitFrameInContentView
    #expect(trailFrame.width > 0 && trailFrame.height >= 28)
    #expect(trailFrame.intersection(contentFrame).isEmpty)
    fixture.controller.selfTestShowTrailPopover()
    #expect(fixture.controller.selfTestTrailPopoverVisible)
    #expect(Set(fixture.controller.selfTestTrailPopoverPaths) == [
        "main.rs", "a.rs",
    ])
    #expect(fixture.controller.selfTestTrailDetailText.contains("AT NAVIGATION"))
    #expect(fixture.controller.selfTestTrailDetailText.contains("CURRENT"))
    fixture.controller.selfTestCloseTrailPopover()

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
@Test
func trailOpensObservedNavigationAsReadingSetWithoutReadingDriftedWorktree()
    async throws
{
    let fixture = try await makeRelationNavigationFixture()
    defer {
        fixture.controller.close()
        try? FileManager.default.removeItem(at: fixture.root)
    }
    let main = fixture.root.appendingPathComponent("main.rs")
    let a = fixture.root.appendingPathComponent("a.rs")
    fixture.controller.openFileForSelfTest(main)
    try #require(await relationTestWaitUntil("main is displayed") {
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
    let edge = try #require(referenceEdge(path: "a.rs", in: fixture.model))
    #expect(fixture.controller.selfTestSelectRelationEdge(titled: edge.title))
    try #require(await relationTestWaitUntil("a.rs is selected") {
        fixture.model.selectedFile?.standardizedFileURL == a.standardizedFileURL
    })

    try "fn drifted() {}\n".write(to: a, atomically: true, encoding: .utf8)
    fixture.model.resolutionExplanations.removeAll()
    fixture.controller.selfTestShowTrailPopover()
    #expect(fixture.controller.selfTestSelectTrailNode(path: "a.rs"))
    let button = fixture.controller.selfTestTrailReadingSetButtonState
    #expect(button.title == "Open as Reading Set")
    #expect(button.enabled)
    #expect(button.label == "Open Trail as Reading Set")
    fixture.controller.selfTestOpenSelectedTrailAsReadingSet()

    guard case .readingSet(let title, let excerpts) =
            fixture.model.tabStrip.activeTab?.content
    else {
        Issue.record("Expected the Trail Reading Set tab")
        return
    }
    #expect(title == edge.title)
    #expect(excerpts.count == 1)
    #expect(excerpts[0].role == "REFERENCE")
    #expect(excerpts[0].path == "a.rs")
    #expect(excerpts[0].sourceText.contains("target"))
    #expect(!excerpts[0].sourceText.contains("drifted"))
    #expect(excerpts[0].inspector.nodeTitle == edge.title)
    #expect(fixture.controller.selfTestPanelPreset == .reading)
    #expect(fixture.controller.selfTestPanelCollapses == (true, true, true, true))

    fixture.controller.selectPreviousTab()
    #expect(fixture.controller.selfTestPanelCollapses == (false, false, true, true))
}

@MainActor
@Test
func semanticTrailKeepsBranchesVisibleAndRestorable() async throws {
    let fixture = try await makeRelationNavigationFixture()
    defer {
        fixture.controller.close()
        try? FileManager.default.removeItem(at: fixture.root)
    }
    let main = fixture.root.appendingPathComponent("main.rs")
    let a = fixture.root.appendingPathComponent("a.rs")
    let b = fixture.root.appendingPathComponent("b.rs")
    fixture.controller.showWindow(nil)
    fixture.controller.window?.displayIfNeeded()
    fixture.controller.openFileForSelfTest(main)
    try #require(await relationTestWaitUntil("main is displayed") {
        fixture.controller.displayedReaderFile?.standardizedFileURL
            == main.standardizedFileURL
    })
    fixture.controller.selfTestReaderRelation(
        offset: byteOffset(of: "target() {}", in: fixture.mainSource),
        direction: .references
    )
    try #require(await relationTestWaitUntil("reference edges are loaded") {
        referenceEdge(path: "a.rs", in: fixture.model) != nil
            && referenceEdge(path: "b.rs", in: fixture.model) != nil
    })
    #expect(fixture.controller.selfTestExpandPossibleRelations())
    let aEdge = try #require(referenceEdge(path: "a.rs", in: fixture.model))
    let bEdge = try #require(referenceEdge(path: "b.rs", in: fixture.model))
    #expect(fixture.controller.selfTestSelectRelationEdge(titled: aEdge.title))
    try #require(await relationTestWaitUntil("a is selected") {
        fixture.model.selectedFile?.standardizedFileURL == a.standardizedFileURL
    })
    fixture.controller.goBack(nil)
    try #require(await relationTestWaitUntil("back restores main") {
        fixture.model.selectedFile?.standardizedFileURL == main.standardizedFileURL
    })
    #expect(fixture.controller.selfTestSelectRelationEdge(titled: bEdge.title))
    try #require(await relationTestWaitUntil("b is selected") {
        fixture.model.selectedFile?.standardizedFileURL == b.standardizedFileURL
    })

    #expect(fixture.model.readingTrail.nodes.count == 3)
    #expect(fixture.model.readingTrail.edges.count == 2)
    #expect(fixture.controller.selfTestTrailBranchCount == 1)
    #expect(fixture.controller.selfTestTrailBreadcrumbTitles.last?.contains("b.rs") == true)
    fixture.controller.selfTestShowTrailPopover()
    #expect(
        fixture.controller.selfTestTrailPopoverContentView?.bounds.width ?? 0
            >= 790
    )
    #expect(fixture.controller.selfTestTrailPopoverPaths == [
        "main.rs", "a.rs", "b.rs",
    ])
    #expect(fixture.controller.selfTestSelectTrailNode(path: "a.rs"))
    #expect(fixture.controller.selfTestTrailDetailText.contains("a.rs"))
    if let directory = ProcessInfo.processInfo.environment[
        "CODEINSIGHT_M10_CAPTURE_DIR"
    ] {
        for (name, selection) in [
            ("light", ReaderSettings.Theme.light),
            ("dark", ReaderSettings.Theme.dark),
            ("si-classic", ReaderSettings.Theme.siClassic),
        ] {
            var settings = ReaderSettings()
            settings.theme = selection
            fixture.controller.applyReaderSettings(settings)
            fixture.controller.selfTestTrailPopoverContentView?
                .layoutSubtreeIfNeeded()
            if let view = fixture.controller.selfTestTrailPopoverContentView {
                try capturePNG(
                    view,
                    at: URL(fileURLWithPath: directory)
                        .appendingPathComponent("semantic-trail-\(name).png")
                )
            }
        }
    }
    fixture.controller.selfTestRestoreSelectedTrailNode()
    try #require(await relationTestWaitUntil("trail restore opens a") {
        fixture.model.selectedFile?.standardizedFileURL == a.standardizedFileURL
            && fixture.model.readingTrail.activeNodeID
                == fixture.controller.selfTestSelectedTrailNodeID
    })
    #expect(fixture.model.readingTrail.edges.count == 2)
}

@MainActor
@Test
func semanticTrailShowsSnapshotBoundaryAndNavigationCause() throws {
    _ = NSApplication.shared
    let trail = ReadingTrail()
    let store = ResolutionExplanationStore()
    let worktree = SnapshotID(rawValue: UUID())
    let commit = SnapshotID(rawValue: UUID())
    let root = JumpRecord(
        path: "src/main.rs",
        contentID: nil,
        byteOffset: 4,
        line: 1,
        column: 5,
        symbolAnchor: "main",
        snapshotID: worktree
    )
    let destination = JumpRecord(
        path: "src/lib.rs",
        contentID: nil,
        byteOffset: 12,
        line: 3,
        column: 2,
        symbolAnchor: "run",
        snapshotID: commit,
        revision: "1234567890abcdef"
    )
    _ = trail.recordNavigation(
        from: root,
        to: destination,
        cause: .search
    )
    let view = ReadingTrailView(frame: NSRect(x: 0, y: 0, width: 900, height: 32))
    view.display(trail: trail, store: store)

    #expect(view.snapshotBoundaryCount == 1)
    #expect(view.breadcrumbText == "main · search → run")
    #expect(view.selectNode(path: "src/lib.rs"))
    #expect(view.detailValue.contains("commit 1234567"))
    #expect(view.detailValue.contains("search"))
}

@MainActor
private func makeRelationNavigationFixture(
    sessionURL: URL? = nil
) async throws -> (
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
    let indexService = RelationTestIndexService()
    let exactCoordinator = ExactCoordinator(
        providerFactory: { _ in throw CocoaError(.featureUnsupported) },
        sandboxAvailable: { false }
    )
    let model = if let sessionURL {
        AppModel(
            sessionURL: sessionURL,
            indexService: indexService,
            exactCoordinator: exactCoordinator
        )
    } else {
        AppModel(
            indexService: indexService,
            exactCoordinator: exactCoordinator
        )
    }
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
    func index(root: URL, language: LanguageID) async throws -> EngineSession {
        try await Task.detached {
            try ProjectIndexer().index(root: root, language: language)
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
    exactResolver: RelationTreeModel.ExactResolver? = nil,
    sourceResultIsTruncated: Bool = false,
    usesMethodNameOnlyEvidence: Bool = false,
    capturedSourceAvailable: Bool = true
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
        (
            name,
            symbol,
            try #require(relationLocation(for: symbol, in: session))
        )
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
    let methodNameEvidence: [ResolutionEvidence] = usesMethodNameOnlyEvidence
        ? [.methodNameOnly(nameID: session.names.intern("first"))]
        : []
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
                edges: fuzzyLocations.map { title, symbol, location in
                    RelationTreeModel.LoadedEdge(
                        title: title,
                        certainty: loadDirection == .references
                            || usesMethodNameOnlyEvidence
                            ? .possible
                            : .strong,
                        dispatch: .direct,
                        symbol: nil,
                        path: location.path,
                        byteOffset: location.byteOffset,
                        line: location.line,
                        evidence: methodNameEvidence,
                        candidate: CandidateObservation(
                            target: .occurrence(symbol),
                            certainty: loadDirection == .references
                                || usesMethodNameOnlyEvidence
                                ? .possible
                                : .strong,
                            dispatch: .direct,
                            provenance: .fuzzyResolver,
                            completeness: .complete,
                            evidence: methodNameEvidence
                        ),
                        exactQuery: exactResolver == nil
                            ? nil
                            : (location.path, location.byteOffset, location.line),
                        fuzzyTarget: exactResolver == nil
                            ? nil
                            : (location.path, location.byteOffset)
                    )
                },
                isTruncated: sourceResultIsTruncated
            )
        },
        exactResolver: exactResolver,
        exactRelationsResolver: { _, _, _, _, _, _ in
            if let blockedExactLoad {
                await blockedExactLoad.wait("root Exact relation release")
            }
            return includesExactMatch
                ? .relations(
                    [exact],
                    origin: .worktree,
                    attribution: relationUXExactAttribution()
                )
                : .unsupported
        }
    )
    model.updateProjectState(.ready(session, context))
    let controller = RelationWindowController(
        model: model,
        verificationReadiness: { .ready },
        capturedSource: { path in
            guard capturedSourceAvailable else { return nil }
            guard let source = session.capturedSource(atManifestPath: path)
            else { return nil }
            return (
                source.contentID,
                source.bytes,
                ReadingSetExcerpt.SourceKind.worktreeCaptured,
                nil
            )
        },
        languageMode: { _ in LanguageMode(language: .rust) }
    )
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
        attribution: relationUXExactAttribution(
            limitations: [.buildScriptsDisabled, .procMacrosDisabled]
        ),
        origin: .worktree
    )
}

private func relationUXExactAttribution(
    limitations: Set<ExactAnalysisLimitation> = []
) -> ExactAttribution {
    ExactAttribution(
        provider: "fake-exact",
        toolVersion: "fake-1",
        configFingerprint: "config",
        environmentFingerprint: "environment",
        environment: ExactAnalysisEnvironment(
            trustMode: .safe,
            limitations: limitations
        ),
        generatedAt: Date(timeIntervalSince1970: 0)
    )
}

@MainActor
private func capturePNG(_ view: NSView, at url: URL) throws {
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    else {
        throw CocoaError(.fileWriteUnknown)
    }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:])
    else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: url)
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
