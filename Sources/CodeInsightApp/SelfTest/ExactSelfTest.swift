import AppKit
import CodeInsightAppModel
import CodeInsightCore
import CodeInsightEngine
import CodeInsightExact
import CodeInsightGit
import CodeInsightReaderCore
import CodeInsightReaderUI
import CoreText
import Darwin
import os
import PDFKit
import SwiftUI
import WebKit

extension AppDelegate {
    func runExactSelfTest(root: URL) -> Never {
        launch(offscreen: true)
        let projectRoot = exactSelfTestFixtureRoot(root: root)
        guard let windowController,
              let target = exactSelfTestTarget(root: projectRoot),
              let localReferenceDeclarationOffset =
                  target.localReferenceDeclarationOffset,
              let localReferenceUseOffset = target.localReferenceUseOffset
        else {
            finishExactSelfTest(
                controller: windowController,
                checks: [:],
                realProvider: "not-run",
                error: "exact self-test target unavailable"
            )
        }
        windowController.window?.setContentSize(
            NSSize(width: 1_600, height: 1_000)
        )
        pumpRunLoop()

        windowController.openProject(root: projectRoot)
        guard waitUntil(timeout: 30, condition: {
            if case .failed = self.model.projectState { return true }
            if case .ready = self.model.projectState { return true }
            return false
        }), case .ready = model.projectState else {
            finishExactSelfTest(
                controller: windowController,
                checks: [:],
                realProvider: "not-run",
                error: "project unavailable"
            )
        }
        let initialStatusSafe = waitUntil(timeout: 5, condition: {
            model.exactCoordinator.readiness == .ready
                && windowController.selfTestExactStatusVisible
                && windowController.selfTestExactStatusText.contains("Safe")
        })
        let initialProfileTitle =
            "Rust · \(projectRoot.lastPathComponent) · default · Safe"
        let initialProfileVisible = waitUntil(timeout: 5, condition: {
            windowController.selfTestProfileToolbarItemExistsAndVisible
                && windowController.selfTestProfileTitle == initialProfileTitle
        })
        let initialProfileTitleSafe =
            windowController.selfTestProfileTitle == initialProfileTitle
        emitExactStep(
            "initial-status",
            variant: "fake",
            controller: windowController,
            extra: [
                "profileVisible": initialProfileVisible,
                "profileTitle": windowController.selfTestProfileTitle,
            ]
        )
        let relationTimingFileVisible = waitUntil(timeout: 5, condition: {
            windowController.selectFileInSidebar(target.relationFile)
        }) && waitUntil(timeout: 5, condition: {
            windowController.displayedReaderFile?.standardizedFileURL
                == target.relationFile.standardizedFileURL
        })
        let relationSessionCountBefore =
            exactSelfTestProviderState?.trustModes.count ?? 0
        var relationColdTiming = (
            relationFirstActionableMS: 0.0,
            relationAllResultsMS: 0.0,
            relationFirstActionableKind: "",
            relationFirstActionableTitle: "",
            relationCandidateEdgeCount: 0
        )
        var relationWarmTiming = relationColdTiming
        if relationTimingFileVisible {
            exactSelfTestProviderState?.delayNextRelation(by: 0.25)
            relationColdTiming = measureRelationTiming(
                model: model,
                controller: windowController,
                offset: target.relationCallOffset,
                direction: .callers,
                timeout: 5
            )
            exactSelfTestProviderState?.delayNextRelation(by: 0.25)
            relationWarmTiming = measureRelationTiming(
                model: model,
                controller: windowController,
                offset: target.relationCallOffset,
                direction: .callers,
                timeout: 5
            )
        }
        let relationSessionCountAfter =
            exactSelfTestProviderState?.trustModes.count ?? 0
        let relationColdFirstActionableSelectable =
            !relationColdTiming.relationFirstActionableTitle.isEmpty
            && windowController.selfTestSelectRelationEdge(
                titled: relationColdTiming.relationFirstActionableTitle
            )
            && windowController.selfTestSelectedRelationEdgeTitle
                == relationColdTiming.relationFirstActionableTitle
        let relationWarmFirstActionableSelectable =
            !relationWarmTiming.relationFirstActionableTitle.isEmpty
            && windowController.selfTestSelectRelationEdge(
                titled: relationWarmTiming.relationFirstActionableTitle
            )
            && windowController.selfTestSelectedRelationEdgeTitle
                == relationWarmTiming.relationFirstActionableTitle
        windowController.selfTestDeselectRelation()
        let relationColdTimingFieldsValid =
            relationColdTiming.relationFirstActionableMS > 0
            && relationColdTiming.relationAllResultsMS
                >= relationColdTiming.relationFirstActionableMS
            && ["heuristic", "exact"].contains(
                relationColdTiming.relationFirstActionableKind
            )
        let relationWarmTimingFieldsValid =
            relationWarmTiming.relationFirstActionableMS > 0
            && relationWarmTiming.relationAllResultsMS
                >= relationWarmTiming.relationFirstActionableMS
            && ["heuristic", "exact"].contains(
                relationWarmTiming.relationFirstActionableKind
            )
        let relationTimingSameSession =
            relationSessionCountBefore > 0
            && relationSessionCountAfter == relationSessionCountBefore
        emitExactStep(
            "relation-timing",
            variant: "delayed-exact-fake",
            controller: windowController,
            extra: [
                "measurementScope": "instrumentation-only; not real rust-analyzer",
                "thresholdBasis":
                    "structural-only; real threshold pending host measurement",
                "cold": [
                    "relationFirstActionableMS":
                        relationColdTiming.relationFirstActionableMS,
                    "relationAllResultsMS":
                        relationColdTiming.relationAllResultsMS,
                    "relationFirstActionableKind":
                        relationColdTiming.relationFirstActionableKind,
                    "relationFirstActionableTitle":
                        relationColdTiming.relationFirstActionableTitle,
                    "relationCandidateEdgeCount":
                        relationColdTiming.relationCandidateEdgeCount,
                ],
                "warm": [
                    "relationFirstActionableMS":
                        relationWarmTiming.relationFirstActionableMS,
                    "relationAllResultsMS":
                        relationWarmTiming.relationAllResultsMS,
                    "relationFirstActionableKind":
                        relationWarmTiming.relationFirstActionableKind,
                    "relationFirstActionableTitle":
                        relationWarmTiming.relationFirstActionableTitle,
                    "relationCandidateEdgeCount":
                        relationWarmTiming.relationCandidateEdgeCount,
                ],
                "sameSession": relationTimingSameSession,
                "coldFirstActionableSelectable":
                    relationColdFirstActionableSelectable,
                "warmFirstActionableSelectable":
                    relationWarmFirstActionableSelectable,
            ]
        )
        guard waitUntil(timeout: 5, condition: {
                  windowController.selectFileInSidebar(target.file)
              }),
              waitUntil(timeout: 5, condition: {
                  windowController.displayedReaderFile?.standardizedFileURL
                      == target.file.standardizedFileURL
              })
        else {
            finishExactSelfTest(
                controller: windowController,
                checks: [:],
                realProvider: "not-run",
                error: "could not open exact self-test file"
                    + " (treeContainsTarget="
                    + "\(model.fileTree?.selectionPath(for: target.file) != nil))"
            )
        }

        let clickedAt = ContinuousClock.now
        windowController.selfTestReaderClick(
            offset: target.clickOffset,
            commandClick: false
        )
        let fuzzyVisible = waitUntil(timeout: 5, condition: {
            windowController.selfTestContextCandidateCount >= 1
                && windowController.selfTestContextProvenance?.contains("Exact") == false
        })
        let fuzzyFirstAnswerMS = milliseconds(since: clickedAt)
        let fuzzyCount = windowController.selfTestContextCandidateCount
        emitExactStep(
            "fuzzy",
            variant: "fake",
            controller: windowController,
            extra: ["fuzzyFirstAnswerMS": fuzzyFirstAnswerMS]
        )

        let exactVisible = waitUntil(timeout: 5, condition: {
            windowController.selfTestContextProvenance?.contains("Exact") == true
        })
        let exactUpgradeMS = milliseconds(since: clickedAt)
        let fuzzyRetained = windowController.selfTestContextCandidateCount >= fuzzyCount
        emitExactStep(
            "exact",
            variant: "fake",
            controller: windowController,
            extra: ["exactUpgradeMS": exactUpgradeMS]
        )
        var exactSummary = windowController.selfTestContextSummary
        var exactCount = windowController.selfTestContextCandidateCount

        let featureProbeFileVisible = waitUntil(timeout: 5, condition: {
            windowController.selectFileInSidebar(target.relationFile)
        }) && waitUntil(timeout: 5, condition: {
            windowController.displayedReaderFile?.standardizedFileURL
                == target.relationFile.standardizedFileURL
        })
        if featureProbeFileVisible,
           let signatureTraitOffset = target.signatureTraitOffset
        {
            windowController.selfTestReaderRelation(
                offset: signatureTraitOffset,
                direction: .calls
            )
        }
        let featureRelationActiveBeforeSwitch = waitUntil(timeout: 5, condition: {
            model.relationTree.root?.title == "Backend"
                && model.relationTree.root?.children?.contains {
                    $0.kind == .loading
                } == false
        })
        exactSelfTestProviderState?.blockNextDefinition()
        exactSelfTestProviderState?.blockNextRelation()
        let oldGeneration = model.generation
        if featureProbeFileVisible,
           let signatureTraitOffset = target.signatureTraitOffset
        {
            windowController.selfTestReaderRelation(
                offset: signatureTraitOffset,
                direction: .calls
            )
        }
        if featureProbeFileVisible {
            windowController.selfTestReaderClick(
                offset: target.relationCallOffset,
                commandClick: false
            )
        }
        let oldGenerationRequestInFlight = waitUntil(timeout: 5, condition: {
            exactSelfTestProviderState?.definitionIsBlocked == true
                && exactSelfTestProviderState?.relationIsBlocked == true
                && windowController.selfTestContextCandidateCount >= 1
                && windowController.selfTestContextProvenance?
                    .contains("Exact") == false
        })
        let menuActionTriggered =
            windowController.selfTestSwitchFeatureSelection(.allFeatures)
        let reprofiledAt = ContinuousClock.now
        let featurePrepared = menuActionTriggered
            && waitUntil(timeout: 5, condition: {
                model.currentFeatureSelection == .allFeatures
                    && model.generation == oldGeneration + 1
                    && model.exactCoordinator.readiness == .ready
                    && exactSelfTestProviderState?.featureSelections.last
                        == .allFeatures
            })
        let contextVisibleDuringSwitch =
            windowController.selfTestContextCandidateCount >= 1
        exactSelfTestProviderState?.releaseBlockedDefinition()
        exactSelfTestProviderState?.releaseBlockedRelation()
        let oldGenerationResultReturned = waitUntil(timeout: 5, condition: {
            exactSelfTestProviderState?.blockedDefinitionReturned == true
        })
        let oldGenerationRelationResultReturned = waitUntil(
            timeout: 5,
            condition: {
                exactSelfTestProviderState?.blockedRelationReturned == true
            }
        )
        let featureRelationRestoredAfterSwitch = waitUntil(timeout: 5, condition: {
            model.relationTree.root?.title == "Backend"
                && model.relationTree.root?.children?.isEmpty == false
                && model.relationTree.root?.children?.contains {
                    $0.kind == .loading
                } == false
        })
        if featureProbeFileVisible {
            windowController.selfTestReaderClick(
                offset: target.relationCallOffset,
                commandClick: false
            )
        }
        let fuzzyAfterSwitch = waitUntil(timeout: 5, condition: {
            windowController.selfTestContextCandidateCount >= 1
                && windowController.selfTestContextProvenance?
                    .contains("Exact") == false
        })
        let switchedExactVisible = waitUntil(timeout: 5, condition: {
            windowController.selfTestContextProvenance?
                .contains("features: all") == true
        })
        let oldGenerationResultDiscarded = oldGenerationResultReturned
            && oldGenerationRelationResultReturned
            && model.generation == oldGeneration + 1
            && switchedExactVisible
        let contextReadyMS = milliseconds(since: reprofiledAt)
        let reprofileExtracted = if case let .ready(session, _) = model.projectState {
            session.stats.extractedCount
        } else {
            -1
        }
        if switchedExactVisible {
            exactSummary = windowController.selfTestContextSummary
            exactCount = windowController.selfTestContextCandidateCount
        }
        let switchedProfileTitle =
            "Rust · \(projectRoot.lastPathComponent) · all · Safe"
        let profileButtonVisibleWithGeometry = waitUntil(timeout: 5, condition: {
            windowController.selfTestProfileButtonVisibleWithGeometry
                && windowController.selfTestProfileTitle == switchedProfileTitle
        })
        emitExactStep(
            "feature-switch",
            variant: "fake",
            controller: windowController,
            extra: [
                "menuActionTriggered": menuActionTriggered,
                "featurePrepared": featurePrepared,
                "fakePrepareFeatures": exactSelfTestProviderState?
                    .featureSelections.map(\.rawValue) ?? [],
                "contextVisibleDuringSwitch": contextVisibleDuringSwitch,
                "fuzzyAfterSwitch": fuzzyAfterSwitch,
                "oldGenerationRequestInFlight": oldGenerationRequestInFlight,
                "oldGenerationResultReturned": oldGenerationResultReturned,
                "oldGenerationRelationResultReturned":
                    oldGenerationRelationResultReturned,
                "oldGenerationResultDiscarded": oldGenerationResultDiscarded,
                "relationActiveBeforeSwitch": featureRelationActiveBeforeSwitch,
                "relationRestoredAfterSwitch":
                    featureRelationRestoredAfterSwitch,
                "switchedExactVisible": switchedExactVisible,
                "contextReadyMS": contextReadyMS,
                "extracted": reprofileExtracted,
                "profileButtonVisibleWithGeometry":
                    profileButtonVisibleWithGeometry,
                "profileButtonFrame": NSStringFromRect(
                    windowController.selfTestProfileButtonFrame
                ),
                "profileContainerBounds": NSStringFromRect(
                    windowController.selfTestProfileContainerBounds
                ),
                "profileTitle": windowController.selfTestProfileTitle,
            ]
        )

        let relationFileVisible = waitUntil(timeout: 5, condition: {
            windowController.selectFileInSidebar(target.relationFile)
        }) && waitUntil(timeout: 5, condition: {
            windowController.displayedReaderFile?.standardizedFileURL
                == target.relationFile.standardizedFileURL
        })
        if relationFileVisible && waitUntil(timeout: 10, condition: {
            windowController.selfTestIdentifierPreparationState == .ready
        }) {
            _ = windowController.selfTestActivateReading(
                at: localReferenceDeclarationOffset
            )
            pumpRunLoop()
            windowController.selfTestReaderRelation(
                offset: localReferenceDeclarationOffset,
                direction: .references
            )
        }
        let localReferencesVisible = waitUntil(timeout: 5, condition: {
            model.relationTree.direction == .references
                && windowController.selfTestReferenceGroupTitle == nil
                && windowController.selfTestVisibleRelationEdgeTitles(
                    inGroup: "References"
                ).count == 1
        })
        let localReferenceCountHonest =
            windowController.selfTestVisibleRelationEdgeTitles(
                inGroup: "References"
            ).count == 1
        let localReferenceGroupVisibleWithGeometry =
            windowController.selfTestReferenceGroupVisibleWithGeometry
        let localReferenceGroupFrame =
            windowController.selfTestReferenceGroupFrame
        let localReferenceVisibleRect =
            windowController.selfTestRelationsVisibleRect
        let localReferenceIntersection =
            localReferenceVisibleRect.intersection(localReferenceGroupFrame)
        let referenceSegmentVisibleWithGeometry =
            windowController.selfTestReferenceSegmentVisibleWithGeometry
        let referenceSegmentDoesNotOverlapOtherDirections =
            windowController.selfTestReferenceSegmentDoesNotOverlapOtherDirections
        let localReferenceOriginOffset = windowController.selfTestReadingByteOffset
        let historyCountBeforeLocalReferenceOpen =
            model.navigationHistory.records.count
        let localReferenceTitle = windowController.selfTestVisibleRelationEdgeTitles(
            inGroup: "References"
        ).first
        let localReferenceSelected = localReferenceTitle.map {
            windowController.selfTestSelectRelationEdge(titled: $0)
        } == true
        let localReferenceOpenedAtCorrectOffset = waitUntil(timeout: 5, condition: {
            model.selectedByteOffset == localReferenceUseOffset
        })
        let localReferenceOpenedOffset = model.selectedByteOffset
        let localReferenceHistoryRecorded =
            model.navigationHistory.records.count
                > historyCountBeforeLocalReferenceOpen
        if localReferenceOpenedAtCorrectOffset {
            windowController.goBack(nil)
        }
        let localReferenceHistoryBack = localReferenceOriginOffset.map { origin in
            waitUntil(timeout: 5, condition: {
                model.selectedByteOffset == origin
                    && windowController.displayedReaderFile?.standardizedFileURL
                        == target.relationFile.standardizedFileURL
            })
        } ?? false
        if relationFileVisible {
            windowController.selfTestReaderClick(
                offset: target.relationCallOffset,
                commandClick: false
            )
        }
        let localReferenceContextRestored = waitUntil(timeout: 5, condition: {
            windowController.selfTestContextProvenance?.contains("Exact") == true
        })
        if localReferenceContextRestored {
            exactSummary = windowController.selfTestContextSummary
            exactCount = windowController.selfTestContextCandidateCount
        }
        emitExactStep(
            "local-references",
            variant: "reader-index",
            controller: windowController,
            extra: [
                "direction": "\(model.relationTree.direction)",
                "groupTitle": windowController.selfTestReferenceGroupTitle ?? "",
                "groupFrame": NSStringFromRect(
                    localReferenceGroupFrame
                ),
                "visibleRect": NSStringFromRect(
                    localReferenceVisibleRect
                ),
                "intersection": NSStringFromRect(localReferenceIntersection),
                "treeVisible": windowController.selfTestRelationsTreeVisible,
                "segmentFrames":
                    windowController.selfTestDirectionSegmentFrames.map(
                        NSStringFromRect
                    ),
                "groupVisibleWithGeometry":
                    localReferenceGroupVisibleWithGeometry,
                "referenceSegmentVisibleWithGeometry":
                    referenceSegmentVisibleWithGeometry,
                "referenceSegmentDoesNotOverlapOtherDirections":
                    referenceSegmentDoesNotOverlapOtherDirections,
                "selected": localReferenceSelected,
                "openedOffset": localReferenceOpenedOffset.map { $0 as Any }
                    ?? NSNull(),
                "returnedOffset": model.selectedByteOffset.map { $0 as Any }
                    ?? NSNull(),
                "expectedUseOffset": localReferenceUseOffset,
                "historyRecorded": localReferenceHistoryRecorded,
                "historyBack": localReferenceHistoryBack,
                "contextRestored": localReferenceContextRestored,
                "originOffset": localReferenceOriginOffset.map { $0 as Any }
                    ?? NSNull(),
            ]
        )
        if relationFileVisible,
           let definitionOffset = UInt32(exactly: target.definition.byteOffset)
        {
            windowController.selfTestReaderRelation(
                offset: definitionOffset,
                direction: .references
            )
        }
        func projectReferenceRows() -> [RelationTreeModel.Node] {
            model.relationTree.root?.children?
                .flatMap { node in
                    node.kind == .edge ? [node] : node.children ?? []
                }
                .filter { $0.kind == .edge } ?? []
        }
        let exactReferencesVisible = waitUntil(timeout: 5, condition: {
            model.relationTree.direction == .references
                && model.relationTree.root?.children?.contains {
                    $0.kind == .loading
                } == false
                && exactRelationEdges(in: model).contains {
                    $0.title.hasPrefix("main.rs:")
                }
        })
        _ = windowController.selfTestExpandPossibleRelations()
        let projectReferenceNodes = projectReferenceRows()
        let exactReferenceNodes = exactRelationEdges(in: model)
        let fuzzyReferenceNodes = projectReferenceNodes.filter {
            $0.badge != "Verified"
        }
        let exactReferenceTitles = exactReferenceNodes.map(\.title)
        let fuzzyReferenceTitles = fuzzyReferenceNodes.map(\.title)
        let exactReferenceRowCount = exactReferenceNodes.count
        let fuzzyReferenceRowCount = fuzzyReferenceNodes.count
        let possibleReferenceDisclosure = model.relationTree.root?.children?
            .first {
                $0.kind == .group && $0.candidateGroup == .possible
            }
        let possibleReferenceCountHonest = possibleReferenceDisclosure.map {
            let count = $0.children?.count ?? 0
            return $0.title == "Show \(count) possible \(count == 1 ? "match" : "matches")"
        } ?? true
        let noCertaintyNamedReferenceGroups =
            model.relationTree.root?.children?.allSatisfy {
                $0.kind != .group
                    || !["Exact", "Strong", "Probable", "Possible"]
                        .contains($0.title)
            } == true
        let mixedReferencePresentationHonest =
            exactReferenceRowCount > 0
            && fuzzyReferenceRowCount > 0
            && exactReferenceRowCount + fuzzyReferenceRowCount
                == projectReferenceNodes.count
            && exactReferenceNodes.allSatisfy { $0.badge == "Verified" }
            && fuzzyReferenceNodes.allSatisfy { $0.badge != "Verified" }
            && possibleReferenceCountHonest
            && noCertaintyNamedReferenceGroups
        let projectReferenceTitles = projectReferenceNodes.map(\.title)
        let projectReferencesVisible = exactReferencesVisible
            && !projectReferenceTitles.isEmpty
        let projectReferencesCrossFile = projectReferenceTitles.contains {
            $0.hasPrefix("main.rs:")
        }
        let exactReferencesHeuristicProvenanceRetained =
            exactReferenceNodes.contains {
                $0.subtitle?.contains("heuristic also matched") == true
            }
        let exactReferencesDeclarationExcluded =
            !projectReferenceNodes.contains {
                    $0.target?.path == target.definition.file
                        && $0.target?.byteOffset
                            == UInt32(target.definition.byteOffset)
                }
        let projectReferenceNode = projectReferenceNodes.first {
            $0.kind == .edge
                && $0.title.hasPrefix("main.rs:")
                && $0.symbol == nil
                && $0.target != nil
        }
        let exactReferenceAXNode = exactReferenceNodes.first {
            $0.subtitle?.contains("heuristic also matched") == true
        }
        let projectReferenceAccessibility = exactReferenceAXNode.flatMap {
            windowController.selfTestRelationAccessibility(
                titled: $0.title,
                inGroup: ""
            )
        }
        let projectReferenceAXProvenanceReachable =
            projectReferenceAccessibility.map {
                [$0.label, $0.value].joined(separator: " ")
                    .contains("Verified")
                    && [$0.label, $0.value].joined(separator: " ")
                        .contains("heuristic also matched")
            } == true
        let projectReferenceAXReadOnly =
            projectReferenceAccessibility.map {
                $0.role != NSAccessibility.Role.textField.rawValue
                    && !$0.valueSettable
            } == true
        let relationLayoutPassesBeforeGeometryRead =
            windowController.selfTestRelationLayoutPasses
        let projectReferenceEdgeFrames =
            windowController.selfTestVisibleRelationEdgeFrames(
                inGroup: ""
            )
        let projectReferenceVisibleRect =
            windowController.selfTestRelationsVisibleRect
        let projectReferenceRowsVisibleWithGeometry =
            !projectReferenceEdgeFrames.isEmpty
            && projectReferenceEdgeFrames.allSatisfy {
                guard $0.width > 0, $0.height > 0 else { return false }
                let intersection = projectReferenceVisibleRect.intersection($0)
                return intersection.width > 0
                    && intersection.height >= $0.height - 0.5
            }
        let projectReferenceGroupsDoNotOverlap =
            possibleReferenceDisclosure == nil
                || windowController.selfTestExactAndReferenceGroupsDoNotOverlap
        let projectReferenceResultsAndControlsDoNotOverlap =
            windowController
                .selfTestRelationResultsAndDirectionControlDoNotOverlap
        let relationGeometryReadDidNotForceLayout =
            relationLayoutPassesBeforeGeometryRead
                == windowController.selfTestRelationLayoutPasses
        emitExactStep(
            "project-references",
            variant: "exact+fuzzy",
            controller: windowController,
            extra: [
                "direction": "\(model.relationTree.direction)",
                "groupTitle": windowController.selfTestReferenceGroupTitle ?? "",
                "edgeCount": projectReferenceTitles.count,
                "edgeTitles": projectReferenceTitles,
                "exactEdgeTitles": exactReferenceTitles,
                "fuzzyEdgeTitles": fuzzyReferenceTitles,
                "exactRowCount": exactReferenceRowCount,
                "fuzzyRowCount": fuzzyReferenceRowCount,
                "possibleDisclosure":
                    possibleReferenceDisclosure?.title ?? "",
                "mixedPresentationHonest":
                    mixedReferencePresentationHonest,
                "exactVisible": exactReferencesVisible,
                "heuristicProvenanceRetained":
                    exactReferencesHeuristicProvenanceRetained,
                "declarationExcluded": exactReferencesDeclarationExcluded,
                "crossFile": projectReferencesCrossFile,
                "axLabel": projectReferenceAccessibility?.label ?? "",
                "axValue": projectReferenceAccessibility?.value ?? "",
                "axRole": projectReferenceAccessibility?.role ?? "",
                "axValueSettable":
                    projectReferenceAccessibility?.valueSettable ?? true,
                "axProvenanceReachable":
                    projectReferenceAXProvenanceReachable,
                "axReadOnly": projectReferenceAXReadOnly,
                "rowsVisibleWithGeometry":
                    projectReferenceRowsVisibleWithGeometry,
                "edgeFrames": projectReferenceEdgeFrames.map(
                    NSStringFromRect
                ),
                "visibleRect": NSStringFromRect(
                    projectReferenceVisibleRect
                ),
                "groupsDoNotOverlap":
                    projectReferenceGroupsDoNotOverlap,
                "resultsAndControlsDoNotOverlap":
                    projectReferenceResultsAndControlsDoNotOverlap,
                "geometryReadDidNotForceLayout":
                    relationGeometryReadDidNotForceLayout,
            ]
        )
        let referenceNavigationRoot = model.relationTree.root
        let referenceNavigationTreeGeneration = model.relationTree.generation
        let referenceNavigationGeneration = model.navigationGeneration
        let originalRelationOnSelect = model.relationTree.onSelect
        var referenceSelectionCount = 0
        model.relationTree.onSelect = { node in
            referenceSelectionCount += 1
            originalRelationOnSelect(node)
        }
        let referenceSingleClickSelected = projectReferenceNode.map {
            windowController.selfTestSelectRelationEdge(titled: $0.title)
        } == true
        let referenceSingleClickNavigated = projectReferenceNode?.target.map { target in
            waitUntil(timeout: 5, condition: {
                windowController.displayedReaderFile?.standardizedFileURL
                    == projectRoot.appendingPathComponent(target.path)
                        .standardizedFileURL
                    && model.selectedByteOffset == target.byteOffset
            })
        } ?? false
        pumpRunLoop()
        let referenceSingleClickExactlyOnce =
            model.navigationGeneration == referenceNavigationGeneration + 1
        let referenceSingleClickNoFeedback = referenceSelectionCount == 1
        let referenceSingleClickNoReroot =
            model.relationTree.root === referenceNavigationRoot
            && model.relationTree.generation == referenceNavigationTreeGeneration
            && projectReferenceNode?.symbol == nil
        let navigationAfterReferenceSingleClick = model.navigationGeneration
        if referenceSingleClickSelected {
            windowController.selfTestOpenRelationSelection()
        }
        pumpRunLoop()
        let referenceDoubleClickDidNotNavigateTwice =
            model.navigationGeneration == navigationAfterReferenceSingleClick
        model.relationTree.onSelect = originalRelationOnSelect
        if referenceSingleClickNavigated {
            windowController.goBack(nil)
        }
        let referenceSingleClickHistoryBack = referenceSingleClickNavigated
            && waitUntil(timeout: 5, condition: {
                windowController.displayedReaderFile?.standardizedFileURL
                    == target.relationFile.standardizedFileURL
            })
        var referenceKeyboardDownMovedSelection = false
        var referenceKeyboardUpMovedSelection = false
        var referenceKeyboardSelectionNavigated = false
        var referenceKeyboardAXNotificationCorrect = false
        var referenceKeyboardEnterOpened = false
        var referenceKeyboardKeypadEnterOpened = false
        var referenceKeyboardRestoredRelationFile = false
        if projectReferenceTitles.count >= 2 {
            let firstTitle = projectReferenceTitles[0]
            let secondTitle = projectReferenceTitles[1]
            let selectedFirst =
                windowController.selfTestSelectRelationEdge(titled: firstTitle)
            let navigationBeforeDown = model.navigationGeneration
            let notificationsBeforeDown =
                windowController.selfTestRelationAccessibilityNotificationCount
            referenceKeyboardDownMovedSelection =
                selectedFirst
                && windowController.selfTestPressRelationKey(125)
                && windowController.selfTestSelectedRelationEdgeTitle
                    == secondTitle
            referenceKeyboardSelectionNavigated =
                referenceKeyboardDownMovedSelection
                && waitUntil(timeout: 5, condition: {
                    model.navigationGeneration > navigationBeforeDown
                })
            referenceKeyboardAXNotificationCorrect =
                windowController.selfTestLastRelationAccessibilityNotification
                    == NSAccessibility.Notification.selectedRowsChanged.rawValue
                && windowController
                    .selfTestRelationAccessibilityNotificationCount
                    == notificationsBeforeDown + 1
            referenceKeyboardUpMovedSelection =
                windowController.selfTestPressRelationKey(126)
                && windowController.selfTestSelectedRelationEdgeTitle
                    == firstTitle
            let openCountBeforeEnter =
                windowController.selfTestRelationOpenCount
            referenceKeyboardEnterOpened =
                windowController.selfTestPressRelationKey(36)
                && windowController.selfTestRelationOpenCount
                    == openCountBeforeEnter + 1
            let openCountBeforeKeypadEnter =
                windowController.selfTestRelationOpenCount
            referenceKeyboardKeypadEnterOpened =
                windowController.selfTestPressRelationKey(76)
                && windowController.selfTestRelationOpenCount
                    == openCountBeforeKeypadEnter + 1
            referenceKeyboardRestoredRelationFile =
                windowController.selectFileInSidebar(target.relationFile)
                && waitUntil(timeout: 5, condition: {
                    windowController.displayedReaderFile?.standardizedFileURL
                        == target.relationFile.standardizedFileURL
                })
        }
        emitExactStep(
            "reference-single-click-navigation",
            variant: "fuzzy-two-stage",
            controller: windowController,
            extra: [
                "selected": referenceSingleClickSelected,
                "navigated": referenceSingleClickNavigated,
                "navigationExactlyOnce": referenceSingleClickExactlyOnce,
                "selectionCount": referenceSelectionCount,
                "noFeedback": referenceSingleClickNoFeedback,
                "noReroot": referenceSingleClickNoReroot,
                "doubleClickDidNotNavigateTwice":
                    referenceDoubleClickDidNotNavigateTwice,
                "historyBack": referenceSingleClickHistoryBack,
                "keyboardDownMovedSelection":
                    referenceKeyboardDownMovedSelection,
                "keyboardUpMovedSelection":
                    referenceKeyboardUpMovedSelection,
                "keyboardSelectionNavigated":
                    referenceKeyboardSelectionNavigated,
                "keyboardAXNotificationCorrect":
                    referenceKeyboardAXNotificationCorrect,
                "keyboardEnterOpened": referenceKeyboardEnterOpened,
                "keyboardKeypadEnterOpened":
                    referenceKeyboardKeypadEnterOpened,
                "keyboardRestoredRelationFile":
                    referenceKeyboardRestoredRelationFile,
            ]
        )
        if relationFileVisible {
            windowController.selfTestReaderRelation(
                offset: target.relationCallOffset,
                direction: .callers
            )
        }
        let verifiedRowsVisible = waitUntil(timeout: 5, condition: {
            model.relationTree.direction == .callers
                && model.relationTree.root?.title == "answer"
                && exactRelationEdges(in: model).contains {
                    $0.title == "exact_dependency_caller"
                }
        })
        let contextAndRelationsReadyMS = milliseconds(since: reprofiledAt)
        let verifiedRowCount = windowController.selfTestExactGroupRowCount
        let verifiedBadgesHonest =
            verifiedRowCount > 0
            && exactRelationEdges(in: model).allSatisfy {
                $0.badge == "Verified"
            }
        let exactStatusVisible = windowController.selfTestExactStatusText
            .contains("Exact:")
            && windowController.selfTestExactStatusVisible
        let exactCaller = exactRelationEdges(in: model).first {
            $0.title == "exact_dependency_caller"
        }
        let exactCallerVisible = exactCaller != nil
        let exactCallerCallSitesHonest =
            exactCaller?.subtitle?.contains("2 call sites") == true
        let exactCallerIsOneLevel = exactCallerVisible
            && exactCaller?.isExpandable == false
            && exactCaller?.children?.isEmpty == true
            && !windowController.selfTestExpandRelationEdge(
                titled: "exact_dependency_caller"
            )
        let verifiedBadgeVisibleWithGeometry =
            windowController.selfTestExactGroupVisibleWithGeometry
        let verifiedAndInferredRowsDoNotOverlap =
            windowController.selfTestExactAndHeuristicGroupsDoNotOverlap
        // metric-only：physicalFootprint 是进程级净指标，而本通道在同一进程里可能
        // 已经跑过真实 rust-analyzer 变体（RA 子进程 + 真实索引会把 footprint 抬到
        // ~150MB）。用 100MB 空载预算去守这个场景不可归因——沿用 M5 对巨档
        // footprint 的同一裁决：只报数，不设布尔门。
        // 空载内存预算由 --self-test / --self-test-reading 的独立进程守。
        let exactRelationsFootprintMB = physicalFootprintBytes().map {
            Double($0) / 1_048_576
        }
        emitExactStep(
            "relations",
            variant: "fake",
            controller: windowController,
            extra: [
                "contextAndRelationsReadyMS": contextAndRelationsReadyMS,
                "extracted": reprofileExtracted,
                "exactCallerVisible": exactCallerVisible,
                "exactCallerCallSitesHonest": exactCallerCallSitesHonest,
                "exactCallerIsOneLevel": exactCallerIsOneLevel,
                "verifiedRowFrame": NSStringFromRect(
                    windowController.selfTestExactGroupFrame
                ),
                "inferredRowFrame": NSStringFromRect(
                    windowController.selfTestHeuristicGroupFrame
                ),
                "relationsVisibleRect": NSStringFromRect(
                    windowController.selfTestRelationsVisibleRect
                ),
                "footprintMB": exactRelationsFootprintMB.map { $0 as Any }
                    ?? NSNull(),
            ]
        )

        if relationFileVisible, let signatureTraitOffset = target.signatureTraitOffset {
            // S2a's async offset commits can leave the reader on the last
            // edge target; this step resolves from the relation file.
            _ = windowController.selectFileInSidebar(target.relationFile)
            _ = waitUntil(timeout: 5, condition: {
                windowController.displayedReaderFile?.standardizedFileURL
                    == target.relationFile.standardizedFileURL
            })
            windowController.selfTestReaderRelation(
                offset: signatureTraitOffset,
                direction: .implementations
            )
        }
        let exactImplementationsVisible = waitUntil(timeout: 5, condition: {
            model.relationTree.direction == .implementations
                && windowController.selfTestExactGroupRowCount > 0
        })
        emitExactStep(
            "relation-exact-implementations",
            variant: "fake",
            controller: windowController
        )
        windowController.selfTestReaderRelation(
            offset: target.relationCallOffset,
            direction: .callers
        )
        let exactCallersRestored = waitUntil(timeout: 5, condition: {
            model.relationTree.root?.title == "answer"
                && model.relationTree.direction == .callers
                && windowController.selfTestExactGroupRowCount > 0
                && windowController.selfTestVisibleRelationEdgeTitles(inGroup: "")
                    .contains("relation_root")
        })

        let selectedFirstFollowCaller =
            windowController.selfTestSelectRelationEdge(titled: "relation_root")
        let firstFollowSummary = selectedFirstFollowCaller
            && waitUntil(timeout: 5, condition: {
                windowController.selfTestContextSummary != exactSummary
            })
            ? windowController.selfTestContextSummary
            : nil
        _ = windowController.selfTestExpandPossibleRelations()
        let secondFollowCallerReady = waitUntil(timeout: 5, condition: {
            windowController.selfTestVisibleRelationEdgeTitles(inGroup: "")
                .contains("main")
        })
        let selectedSecondFollowCaller =
            secondFollowCallerReady
            && windowController.selfTestSelectRelationEdge(titled: "main")
        let relationRowsUpdateFollowContext = firstFollowSummary != nil
            && selectedSecondFollowCaller
            && waitUntil(timeout: 5, condition: {
                let summary = windowController.selfTestContextSummary
                return summary != nil && summary != firstFollowSummary
            })
        let secondFollowSummary = relationRowsUpdateFollowContext
            ? windowController.selfTestContextSummary
            : nil
        // S2a made offset navigations commit after their content-identity
        // validation task, so the reader can legitimately sit on the last
        // opened edge target here. This step's intent is clicking the call
        // in the relation file — re-establish it first.
        _ = windowController.selectFileInSidebar(target.relationFile)
        _ = waitUntil(timeout: 5, condition: {
            windowController.displayedReaderFile?.standardizedFileURL
                == target.relationFile.standardizedFileURL
        })
        windowController.selfTestReaderClick(
            offset: target.relationCallOffset,
            commandClick: false
        )
        let relationFollowContextRestored = waitUntil(timeout: 5, condition: {
            windowController.selfTestContextSummary == exactSummary
        })
        emitExactStep(
            "relation-follow-context",
            variant: "fake",
            controller: windowController,
            extra: [
                "selectedFirst": selectedFirstFollowCaller,
                "firstSummary": firstFollowSummary ?? "",
                "selectedSecond": selectedSecondFollowCaller,
                "secondSummary": secondFollowSummary ?? "",
                "updatedTwice": relationRowsUpdateFollowContext,
                "restored": relationFollowContextRestored,
            ]
        )

        windowController.selfTestSetContextPinned(true)
        let pinnedStable = waitUntil(timeout: 5, condition: {
            windowController.selfTestContextPinned
                && windowController.selfTestContextSummary == exactSummary
                && windowController.selfTestContextCandidateCount == exactCount
        })
        emitExactStep(
            "pinnedExact",
            variant: "fake",
            controller: windowController
        )

        let selectedForDirection = windowController.selfTestSelectRelationEdge(
            titled: "relation_root"
        )
        let directionGeneration = model.relationTree.generation
        if selectedForDirection {
            windowController.selfTestChangeRelationDirection(.calls)
        }
        let selectedEdgeDrivesRoot = waitUntil(timeout: 5, condition: {
            model.relationTree.root?.title == "relation_root"
                && model.relationTree.direction == .calls
        })
        let directionGenerationIncremented =
            model.relationTree.generation > directionGeneration
        emitExactStep(
            "relation-direction-root",
            variant: "fake",
            controller: windowController,
            extra: [
                "selectedEdge": selectedForDirection,
                "rootTitle": model.relationTree.root?.title ?? "",
                "generationIncremented": directionGenerationIncremented,
            ]
        )

        windowController.selfTestReaderRelation(
            offset: target.relationCallOffset,
            direction: .callers
        )
        let deselectRootReady = waitUntil(timeout: 5, condition: {
            model.relationTree.root?.title == "answer"
                && model.relationTree.direction == .callers
                && windowController.selfTestExactGroupRowCount > 0
        })
        let selectedForDeselect = deselectRootReady
            && windowController.selfTestSelectRelationEdge(titled: "relation_root")
        let contextBeforeDeselect = (
            summary: windowController.selfTestContextSummary,
            provenance: windowController.selfTestContextProvenance,
            candidateCount: windowController.selfTestContextCandidateCount,
            pinned: windowController.selfTestContextPinned
        )
        windowController.selfTestDeselectRelation()
        let deselectPreservedContext =
            windowController.selfTestContextSummary == contextBeforeDeselect.summary
            && windowController.selfTestContextProvenance
                == contextBeforeDeselect.provenance
            && windowController.selfTestContextCandidateCount
                == contextBeforeDeselect.candidateCount
            && windowController.selfTestContextPinned == contextBeforeDeselect.pinned
        if selectedForDeselect {
            windowController.selfTestChangeRelationDirection(.calls)
        }
        let deselectedRootPreserved = waitUntil(timeout: 5, condition: {
            model.relationTree.root?.title == "answer"
                && model.relationTree.direction == .calls
        })
        emitExactStep(
            "relation-deselect-root",
            variant: "fake",
            controller: windowController,
            extra: [
                "selectedEdge": selectedForDeselect,
                "rootTitle": model.relationTree.root?.title ?? "",
                "contextPreserved": deselectPreservedContext,
            ]
        )

        windowController.selfTestReaderRelation(
            offset: target.relationCallOffset,
            direction: .callers
        )
        let answerCallersReady = waitUntil(timeout: 5, condition: {
            model.relationTree.root?.title == "answer"
                && model.relationTree.direction == .callers
                && windowController.selfTestExactGroupRowCount > 0
        })
        _ = windowController.selfTestExpandPossibleRelations()
        let selectedForOpen = answerCallersReady
            && windowController.selfTestSelectRelationEdge(titled: "main")
        let openGeneration = model.relationTree.generation
        if selectedForOpen {
            windowController.selfTestOpenRelationSelection()
        }
        let doubleClickNavigatesAndSetsRoot = waitUntil(timeout: 5, condition: {
            windowController.displayedReaderFile?.standardizedFileURL
                == target.file.standardizedFileURL
                && model.relationTree.root?.title == "main"
                && model.relationTree.generation > openGeneration
        })
        emitExactStep(
            "relation-double-click",
            variant: "fake",
            controller: windowController,
            extra: [
                "selectedEdge": selectedForOpen,
                "rootTitle": model.relationTree.root?.title ?? "",
                "navigated": windowController.displayedReaderFile?.standardizedFileURL
                    == target.file.standardizedFileURL,
            ]
        )

        let signatureTraitFileVisible = target.signatureTraitOffset != nil
            && waitUntil(timeout: 5, condition: {
                windowController.selectFileInSidebar(target.relationFile)
            }) && waitUntil(timeout: 5, condition: {
                windowController.displayedReaderFile?.standardizedFileURL
                    == target.relationFile.standardizedFileURL
            })
        if signatureTraitFileVisible, let signatureTraitOffset =
            target.signatureTraitOffset
        {
            windowController.selfTestReaderRelation(
                offset: signatureTraitOffset,
                direction: .calls
            )
        }
        let externalGroupVisible = waitUntil(timeout: 5, condition: {
            model.relationTree.root?.title == "Backend"
                && windowController.selfTestExternalGroupTitle == nil
        })
        let externalGroupHeaderHonest =
            windowController.selfTestExternalGroupTitle == nil
        emitExactStep(
            "relation-empty-external",
            variant: "fake",
            controller: windowController,
            extra: [
                "externalGroupTitle":
                    windowController.selfTestExternalGroupTitle ?? "",
                "rootTitle": model.relationTree.root?.title ?? "",
            ]
        )

        let externalDemotionFileVisible = target.externalRootOffset != nil
            && waitUntil(timeout: 5, condition: {
                windowController.selectFileInSidebar(target.relationFile)
            }) && waitUntil(timeout: 5, condition: {
                windowController.displayedReaderFile?.standardizedFileURL
                    == target.relationFile.standardizedFileURL
            })
        var checksAfterFirstBatch: [String: Bool]
        if externalDemotionFileVisible,
           let externalRootOffset = target.externalRootOffset
        {
            exactSelfTestProviderState?.blockNextRelation()
            let definitionRequestsBefore =
                exactSelfTestProviderState?.definitionRequestCount ?? -1
            let nodeReloadsBefore =
                windowController.selfTestRelationNodeReloads
            windowController.selfTestReaderRelation(
                offset: externalRootOffset,
                direction: .calls
            )
            let heuristicPublishedWhileExactBlocked = waitUntil(
                timeout: 5,
                condition: {
                    exactSelfTestProviderState?.relationIsBlocked == true
                        && model.relationTree.root?.title == "dependency_call"
                        && windowController
                            .selfTestPossibleRelationDisclosureTitle
                            == "Show 1 possible match"
                }
            )
            let firstBatchUsedNodeReload =
                windowController.selfTestRelationNodeReloads > nodeReloadsBefore
            exactSelfTestProviderState?.releaseBlockedRelation()
            let bothRelationQueriesFinished = waitUntil(
                timeout: 5,
                condition: {
                    model.relationTree.root?.children?.contains {
                        $0.kind == .loading
                    } == false
                }
            )
            let defaultDefinitionPromotionRequests =
                (exactSelfTestProviderState?.definitionRequestCount ?? -1)
                    - definitionRequestsBefore
            let defaultDefinitionPromotionSkipped =
                defaultDefinitionPromotionRequests == 0
            let possibleRowRetained =
                windowController.selfTestPossibleRelationDisclosureTitle
                    == "Show 1 possible match"
            let possibleExpanded =
                windowController.selfTestExpandPossibleRelations()
            let onDemandDefinitionValidation = waitUntil(
                timeout: 5,
                condition: {
                    (exactSelfTestProviderState?.definitionRequestCount ?? -1)
                        - definitionRequestsBefore == 1
                }
            )
            let expandedDefinitionValidationRequests =
                (exactSelfTestProviderState?.definitionRequestCount ?? -1)
                    - definitionRequestsBefore
            emitExactStep(
                "relation-first-batch",
                variant: "blocked-root-exact-fake",
                controller: windowController,
                extra: [
                    "heuristicPublishedWhileExactBlocked":
                        heuristicPublishedWhileExactBlocked,
                    "firstBatchUsedNodeReload": firstBatchUsedNodeReload,
                    "bothQueriesFinished": bothRelationQueriesFinished,
                    "defaultDefinitionPromotionRequests":
                        defaultDefinitionPromotionRequests,
                    "possibleRowRetained": possibleRowRetained,
                    "possibleExpanded": possibleExpanded,
                    "expandedDefinitionValidationRequests":
                        expandedDefinitionValidationRequests,
                ]
            )
            checksAfterFirstBatch = [
                "heuristicPublishedWhileExactBlocked":
                    heuristicPublishedWhileExactBlocked,
                "firstBatchUsedNodeReload": firstBatchUsedNodeReload,
                "bothRelationQueriesFinished": bothRelationQueriesFinished,
                "defaultDefinitionPromotionSkipped":
                    defaultDefinitionPromotionSkipped,
                "possibleRowRetainedWithoutPromotion": possibleRowRetained,
                "possibleExpandedForValidation": possibleExpanded,
                "expandedDefinitionValidationOnDemand":
                    onDemandDefinitionValidation,
            ]
        } else {
            checksAfterFirstBatch = [
                "heuristicPublishedWhileExactBlocked": false,
                "firstBatchUsedNodeReload": false,
                "bothRelationQueriesFinished": false,
                "defaultDefinitionPromotionSkipped": false,
                "possibleRowRetainedWithoutPromotion": false,
                "possibleExpandedForValidation": false,
                "expandedDefinitionValidationOnDemand": false,
            ]
        }
        let relationFileRestoredAfterDependency =
            windowController.selectFileInSidebar(target.relationFile)
            && waitUntil(
                timeout: 5,
                condition: {
                    windowController.displayedReaderFile?.standardizedFileURL
                        == target.relationFile.standardizedFileURL
                }
            )

        func receiverRelationCheck(
            offset: UInt32?,
            rootTitle: String,
            edgeTitle: String,
            expectedGroup: String,
            expectedSubtitle: String,
            absentGroups: [String]
        ) -> (present: Bool, absent: Bool, subtitleHonest: Bool, subtitle: String) {
            guard relationFileVisible, let offset else {
                return (false, false, false, "")
            }
            windowController.selfTestReaderRelation(
                offset: offset,
                direction: .calls
            )
            if expectedGroup == "Possible" {
                _ = waitUntil(timeout: 5, condition: {
                    windowController.selfTestPossibleRelationDisclosureTitle != nil
                })
                _ = windowController.selfTestExpandPossibleRelations()
            }
            let present = waitUntil(timeout: 5, condition: {
                if expectedGroup == "Possible" {
                    _ = windowController.selfTestExpandPossibleRelations()
                }
                return model.relationTree.root?.title == rootTitle
                    && windowController.selfTestVisibleRelationEdgeTitles(
                        inGroup: expectedGroup
                    ).contains(edgeTitle)
            })
            let absent = absentGroups.allSatisfy {
                !windowController.selfTestVisibleRelationEdgeTitles(
                    inGroup: $0
                ).contains(edgeTitle)
            }
            let subtitle =
                windowController.selfTestVisibleRelationEdgeSubtitle(
                    titled: edgeTitle,
                    inGroup: expectedGroup
                ) ?? ""
            return (present, absent, subtitle == expectedSubtitle, subtitle)
        }

        let typedReceiver = receiverRelationCheck(
            offset: target.typedReceiverRootOffset,
            rootTitle: "typed_receiver_call",
            edgeTitle: "typed_edge",
            expectedGroup: "Strong",
            expectedSubtitle: "direct",
            absentGroups: ["Possible"]
        )
        let inferredReceiver = receiverRelationCheck(
            offset: target.inferredReceiverRootOffset,
            rootTitle: "inferred_receiver_call",
            edgeTitle: "inferred_edge",
            expectedGroup: "Possible",
            expectedSubtitle: "direct",
            absentGroups: ["Strong"]
        )
        let traitObjectReceiver = receiverRelationCheck(
            offset: target.traitObjectReceiverRootOffset,
            rootTitle: "trait_object_receiver_call",
            edgeTitle: "trait_object_edge",
            expectedGroup: "Possible",
            expectedSubtitle: "dynamic · name match only",
            absentGroups: ["Strong"]
        )
        emitExactStep(
            "relation-receiver-types",
            variant: "fake",
            controller: windowController,
            extra: [
                "typedStrong": typedReceiver.present,
                "typedPossible": !typedReceiver.absent,
                "typedSubtitle": typedReceiver.subtitle,
                "inferredProbable": inferredReceiver.present,
                "inferredPossible": !inferredReceiver.absent,
                "inferredSubtitle": inferredReceiver.subtitle,
                "traitObjectPossible": traitObjectReceiver.present,
                "traitObjectSubtitle": traitObjectReceiver.subtitle,
            ]
        )

        let fullZeroTitle = runExactZeroCoverageVariant(
            root: projectRoot,
            limitations: []
        )
        let partialZeroTitle = runExactZeroCoverageVariant(
            root: projectRoot,
            limitations: [.buildScriptsDisabled, .procMacrosDisabled]
        )
        let offlineZeroTitle = runExactZeroCoverageVariant(
            root: projectRoot,
            limitations: [.dependenciesUnavailableOffline]
        )
        let exactZeroFullCopyHonest =
            fullZeroTitle == "No verified references"
        let exactZeroPartialCopyHonest =
            partialZeroTitle
                == "Analysis limited: build scripts disabled; proc macros disabled"
        let exactZeroOfflineCopyHonest =
            offlineZeroTitle == "Analysis limited: dependencies unavailable offline"
        let exactZeroCoverageCopyDistinct =
            Set([fullZeroTitle, partialZeroTitle, offlineZeroTitle]).count == 3
        emitExactStep(
            "relation-zero-coverage",
            variant: "fake",
            controller: windowController,
            extra: [
                "full": fullZeroTitle ?? "",
                "partial": partialZeroTitle ?? "",
                "offline": offlineZeroTitle ?? "",
            ]
        )

        let trustRevoke = runTrustRevokeExactVariant()
        let real = runRealExactVariant(root: root)
        let realOffline = runRealOfflineCoverageVariant(root: root)
        let historical = runHistoricalExactVariant()
        var checks = [
            "fuzzyVisible": fuzzyVisible,
            "exactVisible": exactVisible,
            "fuzzyRetained": fuzzyRetained,
            "pinnedTargetStable": pinnedStable,
            "verifiedRowsVisible": verifiedRowsVisible,
            "verifiedBadgesHonest": verifiedBadgesHonest,
            "exactCallerVisible": exactCallerVisible,
            "exactCallerCallSitesHonest": exactCallerCallSitesHonest,
            "exactCallerIsOneLevel": exactCallerIsOneLevel,
            "exactImplementationsVisible": exactImplementationsVisible,
            "exactCallersRestored": exactCallersRestored,
            "verifiedBadgeVisibleWithGeometry":
                verifiedBadgeVisibleWithGeometry,
            "verifiedAndInferredRowsDoNotOverlap":
                verifiedAndInferredRowsDoNotOverlap,
            "localReferencesVisible": localReferencesVisible,
            "localReferenceCountHonest": localReferenceCountHonest,
            "localReferenceGroupVisibleWithGeometry":
                localReferenceGroupVisibleWithGeometry,
            "referenceSegmentVisibleWithGeometry":
                referenceSegmentVisibleWithGeometry,
            "referenceSegmentDoesNotOverlapOtherDirections":
                referenceSegmentDoesNotOverlapOtherDirections,
            "localReferenceSelected": localReferenceSelected,
            "localReferenceOpenedAtCorrectOffset":
                localReferenceOpenedAtCorrectOffset,
            "localReferenceHistoryRecorded": localReferenceHistoryRecorded,
            "localReferenceHistoryBack": localReferenceHistoryBack,
            "localReferenceContextRestored": localReferenceContextRestored,
            "projectReferencesVisible": projectReferencesVisible,
            "projectReferencesCrossFile": projectReferencesCrossFile,
            "exactReferencesVisible": exactReferencesVisible,
            "exactReferencesHeuristicProvenanceRetained":
                exactReferencesHeuristicProvenanceRetained,
            "projectReferenceAXProvenanceReachable":
                projectReferenceAXProvenanceReachable,
            "projectReferenceAXReadOnly": projectReferenceAXReadOnly,
            "projectReferenceRowsVisibleWithGeometry":
                projectReferenceRowsVisibleWithGeometry,
            "projectReferenceGroupsDoNotOverlap":
                projectReferenceGroupsDoNotOverlap,
            "projectReferenceResultsAndControlsDoNotOverlap":
                projectReferenceResultsAndControlsDoNotOverlap,
            "relationGeometryReadDidNotForceLayout":
                relationGeometryReadDidNotForceLayout,
            "exactReferencesDeclarationExcluded":
                exactReferencesDeclarationExcluded,
            "mixedReferencePresentationHonest":
                mixedReferencePresentationHonest,
            "exactZeroFullCopyHonest": exactZeroFullCopyHonest,
            "exactZeroPartialCopyHonest": exactZeroPartialCopyHonest,
            "exactZeroOfflineCopyHonest": exactZeroOfflineCopyHonest,
            "exactZeroCoverageCopyDistinct": exactZeroCoverageCopyDistinct,
            "referenceSingleClickSelected": referenceSingleClickSelected,
            "referenceSingleClickNavigated": referenceSingleClickNavigated,
            "referenceSingleClickExactlyOnce": referenceSingleClickExactlyOnce,
            "referenceSingleClickNoFeedback": referenceSingleClickNoFeedback,
            "referenceSingleClickNoReroot": referenceSingleClickNoReroot,
            "referenceDoubleClickDidNotNavigateTwice":
                referenceDoubleClickDidNotNavigateTwice,
            "referenceSingleClickHistoryBack": referenceSingleClickHistoryBack,
            "referenceKeyboardDownMovedSelection":
                referenceKeyboardDownMovedSelection,
            "referenceKeyboardUpMovedSelection":
                referenceKeyboardUpMovedSelection,
            "referenceKeyboardSelectionNavigated":
                referenceKeyboardSelectionNavigated,
            "referenceKeyboardAXNotificationCorrect":
                referenceKeyboardAXNotificationCorrect,
            "referenceKeyboardEnterOpened": referenceKeyboardEnterOpened,
            "referenceKeyboardKeypadEnterOpened":
                referenceKeyboardKeypadEnterOpened,
            "referenceKeyboardRestoredRelationFile":
                referenceKeyboardRestoredRelationFile,

            "exactStatusVisible": exactStatusVisible,
            "initialStatusSafeBeforeClick": initialStatusSafe,
            "initialProfileVisible": initialProfileVisible,
            "initialProfileTitleSafe": initialProfileTitleSafe,
            "relationTimingFileVisible": relationTimingFileVisible,
            "relationColdTimingFieldsValid": relationColdTimingFieldsValid,
            "relationWarmTimingFieldsValid": relationWarmTimingFieldsValid,
            "relationTimingSameSession": relationTimingSameSession,
            "relationColdFirstActionableSelectable":
                relationColdFirstActionableSelectable,
            "relationWarmFirstActionableSelectable":
                relationWarmFirstActionableSelectable,
            "relationColdHeuristicFirst":
                relationColdTiming.relationFirstActionableKind == "heuristic",
            "relationWarmHeuristicFirst":
                relationWarmTiming.relationFirstActionableKind == "heuristic",
            "featureProbeFileVisible": featureProbeFileVisible,
            "featureMenuActionTriggered": menuActionTriggered,
            "featurePrepared": featurePrepared,
            "featureContextClearedDuringSwitch": !contextVisibleDuringSwitch,
            "featureFuzzyAfterSwitch": fuzzyAfterSwitch,
            "featureOldGenerationRequestInFlight":
                oldGenerationRequestInFlight,
            "featureOldGenerationResultReturned":
                oldGenerationResultReturned,
            "featureOldGenerationRelationResultReturned":
                oldGenerationRelationResultReturned,
            "featureOldGenerationResultDiscarded":
                oldGenerationResultDiscarded,
            "featureRelationActiveBeforeSwitch":
                featureRelationActiveBeforeSwitch,
            "featureRelationRestoredAfterSwitch":
                featureRelationRestoredAfterSwitch,
            "featureSwitchedExactVisible": switchedExactVisible,
            "featureProfileButtonVisibleWithGeometry":
                profileButtonVisibleWithGeometry,
            "relationFileVisible": relationFileVisible,
            "selectedFirstFollowCaller": selectedFirstFollowCaller,
            "selectedSecondFollowCaller": selectedSecondFollowCaller,
            "relationRowsUpdateFollowContext": relationRowsUpdateFollowContext,
            "relationFollowContextRestored": relationFollowContextRestored,
            "selectedForDirection": selectedForDirection,
            "selectedEdgeDrivesRoot": selectedEdgeDrivesRoot,
            "directionGenerationIncremented": directionGenerationIncremented,
            "deselectRootReady": deselectRootReady,
            "selectedForDeselect": selectedForDeselect,
            "deselectedRootPreserved": deselectedRootPreserved,
            "deselectPreservedContext": deselectPreservedContext,
            "answerCallersReady": answerCallersReady,
            "selectedForOpen": selectedForOpen,
            "doubleClickNavigatesAndSetsRoot": doubleClickNavigatesAndSetsRoot,
            "signatureTraitFileVisible": signatureTraitFileVisible,
            "externalGroupVisible": externalGroupVisible,
            "externalGroupHeaderHonest": externalGroupHeaderHonest,
            "externalDemotionFileVisible": externalDemotionFileVisible,
            "relationFileRestoredAfterDependency":
                relationFileRestoredAfterDependency,
            "typedReceiverStrong": typedReceiver.present,
            "typedReceiverAbsentFromPossible": typedReceiver.absent,
            "typedReceiverNameMatchNoteAbsent": typedReceiver.subtitleHonest,
            "inferredReceiverProbable": inferredReceiver.present,
            "inferredReceiverAbsentFromPossible": inferredReceiver.absent,
            "inferredReceiverNameMatchNoteAbsent":
                inferredReceiver.subtitleHonest,
            "traitObjectStaysPossible": traitObjectReceiver.present,
            "traitObjectAbsentFromStrongAndProbable":
                traitObjectReceiver.absent,
            "traitObjectSubtitleHonest": traitObjectReceiver.subtitleHonest,
            "realProviderPassedOrSkipped": real.passed,
            "realOfflineCoveragePassedOrSkipped": realOffline.passed,
            "historicalExactVisible": historical.exactVisible,
            "historicalInitialStatusSafe": historical.initialStatusSafe,
            "providerRootIsMaterialized": historical.providerRootIsMaterialized,
            "uiPathIsRepoRelative": historical.uiPathIsRepoRelative,
            "historicalProvenanceAttributed": historical.provenanceAttributed,
        ]
        for (key, value) in checksAfterFirstBatch { checks[key] = value }
        for (key, value) in trustRevoke { checks[key] = value }
        for (key, value) in real.reachedChecks { checks[key] = value }
        finishExactSelfTest(
            controller: windowController,
            checks: checks,
            realProvider: real.status,
            realOfflineCoverage: realOffline.status,
            error: nil
        )
    }

    private func runExactZeroCoverageVariant(
        root: URL,
        limitations: Set<ExactAnalysisLimitation>
    ) -> String? {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CodeInsightExactZeroCoverageSelfTest-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: cache) }
        let coordinator = ExactCoordinator(
            providerFactory: { _ in
                InProcessExactProvider(
                    location: nil,
                    capabilities: [.references],
                    referenceLocations: [],
                    limitations: limitations
                )
            },
            snapshotFactory: { root, _ in
                try ExactSelfTestDirectorySnapshot(root: root)
            },
            sandboxAvailable: { true },
            trustRegistry: TrustRegistry(
                fileURL: cache.appendingPathComponent("trust.json")
            )
        )
        defer { coordinator.shutdown() }
        let variant = AppModel(
            indexService: ExactSelfTestIndexService(),
            exactCoordinator: coordinator
        )
        variant.openProject(root: root)
        guard waitUntil(timeout: 5, condition: {
            guard case .ready = variant.projectState else { return false }
            return coordinator.readiness == .ready
                && coordinator.analysisEnvironment?.limitations == limitations
        }), case let .ready(session, context) = variant.projectState,
        let symbol = try? session.definitions(
            of: "answer",
            context: context
        ).first?.0
        else { return nil }

        variant.relationTree.setRoot(
            target: .engine(symbol),
            direction: .references
        )
        guard waitUntil(timeout: 5, condition: {
            variant.relationTree.root?.children?.contains {
                $0.kind == .loading
            } == false
        }) else { return nil }
        return variant.relationTree.root?.children?.first {
            $0.kind == .truncated
                && ($0.title.hasPrefix("Verified ")
                    || $0.title.hasPrefix("No verified ")
                    || $0.title.hasPrefix("Analysis limited:"))
        }?.title
    }

    private func runTrustRevokeExactVariant() -> [String: Bool] {
        guard let fixture = try? makeHistoricalExactSelfTestRepository() else {
            emitExactStep(
                "trust-revoke",
                variant: "fake",
                controller: nil,
                extra: ["reason": "fixture unavailable"]
            )
            return ["trustRevokeFixtureReady": false]
        }
        defer { try? FileManager.default.removeItem(at: fixture) }
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CodeInsightExactTrustRevokeSelfTest-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: cache) }
        let trustFile = cache.appendingPathComponent("trust.json")
        let providerState = ExactSelfTestProviderState()
        let coordinator = ExactCoordinator(
            providerFactory: { _ in
                InProcessExactProvider(location: nil, state: providerState)
            },
            snapshotFactory: { root, _ in
                try ExactSelfTestDirectorySnapshot(root: root)
            },
            sandboxAvailable: { true },
            trustRegistry: TrustRegistry(fileURL: trustFile)
        )
        let trustModel = AppModel(
            indexService: ExactSelfTestIndexService(),
            exactCoordinator: coordinator
        )
        let controller = MainWindowController(
            model: trustModel,
            settings: readerSettings,
            offscreen: true
        )
        controller.showWindow(nil)
        defer { controller.close() }
        controller.openProject(root: fixture)
        guard waitUntil(timeout: 30, condition: {
            if case .failed = trustModel.projectState { return true }
            return coordinator.readiness == .ready
                && providerState.trustModes == ["safe"]
        }), case .ready = trustModel.projectState else {
            emitExactStep(
                "trust-revoke",
                variant: "fake",
                controller: controller,
                extra: ["reason": "safe session unavailable"]
            )
            return ["trustRevokeSafeSessionReady": false]
        }
        let initialStatusSafe = waitUntil(timeout: 5, condition: {
            controller.selfTestExactStatusVisible
                && controller.selfTestExactStatusText.contains("Safe")
        })
        let unit = trustModel.activeAnalysisProfileDisplay?
            .projectUnitName ?? fixture.lastPathComponent
        let safeProfileTitle = "Rust · \(unit) · default · Safe"
        let initialProfileVisible = waitUntil(timeout: 5, condition: {
            controller.selfTestProfileToolbarItemExistsAndVisible
                && controller.selfTestProfileTitle == safeProfileTitle
        })
        let initialProfileTitleSafe =
            controller.selfTestProfileTitle == safeProfileTitle

        Task { try? await trustModel.grantCurrentRepositoryTrust() }
        let trustedReady = waitUntil(timeout: 5, condition: {
            coordinator.readiness == .ready
                && coordinator.trustedRepositories.count == 1
                && providerState.trustModes == ["safe", "trusted"]
        })
        let trustedStatusVisible = trustedReady && waitUntil(timeout: 5, condition: {
            controller.selfTestExactStatusVisible
                && controller.selfTestExactStatusText.contains("Trusted")
        })
        let trustedProfileTitle =
            "Rust · \(unit) · default · Trusted"
        let trustedProfileVisible = trustedReady && waitUntil(timeout: 5, condition: {
            controller.selfTestProfileToolbarItemExistsAndVisible
                && controller.selfTestProfileTitle == trustedProfileTitle
        })
        emitExactStep(
            "trusted-status",
            variant: "fake",
            controller: controller,
            extra: ["profileTitle": controller.selfTestProfileTitle]
        )

        let settingsTrustModel = TrustListModel()
        settingsTrustModel.replace(coordinator.trustedRepositories)
        let settingsController = ReaderSettingsWindowController(
            settings: readerSettings,
            trustModel: settingsTrustModel,
            keyBindingsModel: KeyBindingSettingsModel(table: keyBindingTable) { [weak self] table in
                self?.applyKeyBindings(table)
            },
            onRevoke: { repositoryURL in
                try? await trustModel.revokeRepositoryTrust(repositoryURL)
                await settingsTrustModel.refresh(from: coordinator.trustRegistry)
            },
            onClearCache: {
                do {
                    try await coordinator.clearMaterializedCache()
                    return .cleared
                } catch {
                    return .failed(error.localizedDescription)
                }
            },
            onChange: { _ in }
        )
        settingsController.window?.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        settingsController.showWindow(nil)
        defer { settingsController.close() }

        let trustView = NSHostingView(rootView: TrustSettingsView(
            trustModel: settingsTrustModel,
            onRevoke: { repositoryURL in
                try? await trustModel.revokeRepositoryTrust(repositoryURL)
                await settingsTrustModel.refresh(from: coordinator.trustRegistry)
            }
        ))
        let layoutWindow = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 560, height: 360),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        layoutWindow.contentView = trustView
        layoutWindow.orderFront(nil)
        defer { layoutWindow.close() }
        trustView.layoutSubtreeIfNeeded()
        settingsController.window?.displayIfNeeded()
        layoutWindow.displayIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        let listRowCount = selfTestListRowCount(in: trustView)

        Task { try? await trustModel.revokeRepositoryTrust(fixture) }
        let rebuiltSafe = waitUntil(timeout: 5, condition: {
            coordinator.readiness == .ready
                && providerState.trustModes == ["safe", "trusted", "safe"]
        })
        trustView.layoutSubtreeIfNeeded()
        settingsController.window?.displayIfNeeded()
        layoutWindow.displayIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))

        let trustedRepositoriesEmpty = coordinator.trustedRepositories.isEmpty
        let trustJSONEmpty = (
            (try? JSONSerialization.jsonObject(with: Data(contentsOf: trustFile)))
                as? [String: Any]
        )?.isEmpty == true
        let trustedSessionClosed = providerState.closedSessions.contains(2)
        let statusIsSafe = rebuiltSafe && waitUntil(timeout: 5, condition: {
            controller.selfTestExactStatusVisible
                && controller.selfTestExactStatusText.contains("Safe")
        })
        let safeProfileRestored = rebuiltSafe && waitUntil(timeout: 5, condition: {
            controller.selfTestProfileToolbarItemExistsAndVisible
                && controller.selfTestProfileTitle == safeProfileTitle
        })
        let checks = [
            "trustInitialStatusSafe": initialStatusSafe,
            "trustInitialProfileVisible": initialProfileVisible,
            "trustInitialProfileTitleSafe": initialProfileTitleSafe,
            "trustRevokeTrustedReady": trustedReady,
            "trustStatusTrusted": trustedStatusVisible,
            "trustProfileTitleTrusted": trustedProfileVisible,
            "trustRevokeListRowLaidOut": listRowCount == 1,
            "trustRevokeRepositoriesEmpty": trustedRepositoriesEmpty,
            "trustRevokeJSONEmpty": trustJSONEmpty,
            "trustRevokePreparedSafe": rebuiltSafe,
            "trustRevokeClosedTrustedSession": trustedSessionClosed,
            "trustRevokeStatusIsSafe": statusIsSafe,
            "trustRevokeProfileTitleIsSafe": safeProfileRestored,
        ]
        emitExactStep(
            "trust-revoke",
            variant: "fake",
            controller: controller,
            extra: checks
        )
        return checks
    }

    private func runHistoricalExactVariant() -> (
        providerRootIsMaterialized: Bool,
        uiPathIsRepoRelative: Bool,
        exactVisible: Bool,
        initialStatusSafe: Bool,
        provenanceAttributed: Bool
    ) {
        let fixture: URL
        do {
            fixture = try makeHistoricalExactSelfTestRepository()
        } catch {
            emitExactStep(
                "failed",
                variant: "historical-fake",
                controller: nil,
                extra: ["reason": error.localizedDescription]
            )
            return (false, false, false, false, false)
        }
        defer { try? FileManager.default.removeItem(at: fixture) }

        let snapshot: CommitSnapshot
        let target: ExactSelfTestTarget
        do {
            snapshot = try CommitSnapshot(
                repositoryURL: fixture,
                revision: "HEAD~1"
            )
            guard let found = exactSelfTestTarget(root: fixture) else {
                throw ExactSelfTestError.fixture("target unavailable")
            }
            target = found
        } catch {
            emitExactStep(
                "failed",
                variant: "historical-fake",
                controller: nil,
                extra: ["reason": error.localizedDescription]
            )
            return (false, false, false, false, false)
        }

        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CodeInsightExactHistorySelfTest-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: cache) }
        let materializer = Materializer(
            rootURL: cache.appendingPathComponent("materialized")
        )
        let providerState = ExactSelfTestProviderState()
        let coordinator = ExactCoordinator(
            providerFactory: { root in
                providerState.root = root
                return InProcessExactProvider(location: ExactLocation(
                    file: root.appendingPathComponent("src/lib.rs").path,
                    byteOffset: 7,
                    line: 1,
                    column: 8
                ))
            },
            trustRegistry: TrustRegistry(
                fileURL: cache.appendingPathComponent("trust.json")
            ),
            materializer: materializer
        )
        let historyModel = AppModel(
            indexService: ProjectIndexService(),
            exactCoordinator: coordinator
        )
        let controller = MainWindowController(
            model: historyModel,
            settings: readerSettings,
            offscreen: true
        )
        controller.showWindow(nil)
        defer { controller.close() }
        controller.openProject(root: fixture)
        guard waitUntil(timeout: 30, condition: {
            if case .failed = historyModel.projectState { return true }
            if case .ready = historyModel.projectState {
                return !historyModel.commitPicker.isLoading
            }
            return false
        }), case .ready = historyModel.projectState,
        controller.selectCommit(snapshot.commitOID.hex),
        waitUntil(timeout: 30, condition: {
            historyModel.currentRevision == snapshot.commitOID.hex
                && historyModel.snapshotPhase == .fullReady
                && coordinator.readiness == .ready
        }),
        controller.selectFileInSidebar(target.file),
        waitUntil(timeout: 5, condition: {
            controller.displayedReaderFile?.standardizedFileURL
                == target.file.standardizedFileURL
        }) else {
            emitExactStep(
                "failed",
                variant: "historical-fake",
                controller: controller,
                extra: ["reason": "HEAD~1 switch or file open failed"]
            )
            return (false, false, false, false, false)
        }

        let initialStatusSafe = waitUntil(timeout: 5, condition: {
            controller.selfTestExactStatusText.contains("Safe")
        })
        controller.selfTestReaderClick(
            offset: target.clickOffset,
            commandClick: false
        )
        let exactVisible = waitUntil(timeout: 5, condition: {
            controller.selfTestContextProvenance?.contains("Exact") == true
        })
        let providerRoot = providerState.root
        let providerRootIsMaterialized = providerRoot?.path.contains(
            "/materialized/\(snapshot.commitOID.hex)/"
        ) == true
        let uiPath = historyModel.contextWindow.displayedCandidate?.path
        let uiPathIsRepoRelative = uiPath == "src/lib.rs"
            && uiPath?.hasPrefix("/") == false
        let provenance = controller.selfTestContextProvenance
        let provenanceAttributed = provenance?.contains(
            String(snapshot.commitOID.hex.prefix(7))
        ) == true && provenance?.contains("materialized") == true
        emitExactStep(
            "historicalExact",
            variant: "historical-fake",
            controller: controller,
            extra: [
                "revision": snapshot.commitOID.hex,
                "providerRoot": (providerRoot?.path as Any?) ?? NSNull(),
                "providerRootIsMaterialized": providerRootIsMaterialized,
                "uiPath": (uiPath as Any?) ?? NSNull(),
                "uiPathIsRepoRelative": uiPathIsRepoRelative,
                "provenanceAttributed": provenanceAttributed,
            ]
        )
        return (
            providerRootIsMaterialized,
            uiPathIsRepoRelative,
            exactVisible,
            initialStatusSafe,
            provenanceAttributed
        )
    }

    private func runRealExactVariant(
        root: URL
    ) -> (status: String, passed: Bool, reachedChecks: [String: Bool]) {
        let unreached: [String: Any] = [
            "textDocumentImplementationReached": false,
            "callHierarchyIncomingCallsReached": false,
            "callHierarchyOutgoingCallsReached": false,
        ]
        guard let executable = RustAnalyzerProvider.findExecutable() else {
            emitExactStep(
                "skipped",
                variant: "rust-analyzer",
                controller: nil,
                extra: unreached.merging(
                    ["reason": "rust-analyzer not installed"]
                ) { _, new in new }
            )
            return ("skipped:not-installed", true, [:])
        }

        let fixtureRoot = exactSelfTestFixtureRoot(root: root)
        guard let target = exactSelfTestTarget(root: fixtureRoot) else {
            emitExactStep(
                "skipped",
                variant: "rust-analyzer",
                controller: nil,
                extra: unreached.merging(
                    ["reason": "real-provider fixture unavailable"]
                ) { _, new in new }
            )
            return ("skipped:fixture-unavailable", true, [:])
        }
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CodeInsightExactRealSelfTest-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: cache) }

        let coordinator = ExactCoordinator(
            providerFactory: { projectURL in
                try RustAnalyzerProvider(
                    projectURL: projectURL,
                    executableURL: executable,
                    cacheURL: cache,
                    requestTimeout: 30,
                    closeGrace: 0.5
                )
            },
            snapshotFactory: { root, _ in
                try ExactSelfTestDirectorySnapshot(root: root)
            },
            trustRegistry: TrustRegistry(fileURL: FileManager.default
                .temporaryDirectory
                .appendingPathComponent("CodeInsightExactRealSelfTest-trust.json"))
        )
        let realModel = AppModel(
            indexService: ExactSelfTestIndexService(),
            exactCoordinator: coordinator
        )
        let controller = MainWindowController(
            model: realModel,
            settings: readerSettings,
            offscreen: true
        )
        controller.showWindow(nil)
        defer { controller.close() }
        controller.openProject(root: fixtureRoot)
        guard waitUntil(timeout: 30, condition: {
            if case .failed = realModel.projectState { return true }
            if case .ready = realModel.projectState { return true }
            return false
        }), case .ready = realModel.projectState,
        waitUntil(timeout: 5, condition: {
            controller.selectFileInSidebar(target.file)
        }),
        waitUntil(timeout: 5, condition: {
            controller.displayedReaderFile?.standardizedFileURL
                == target.file.standardizedFileURL
        }) else {
            emitExactStep(
                "failed",
                variant: "rust-analyzer",
                controller: controller,
                extra: ["reason": "project or file unavailable"]
            )
            return ("failed:project", false, [:])
        }

        if case .off(let reason) = coordinator.readiness {
            emitExactStep(
                "skipped",
                variant: "rust-analyzer",
                controller: controller,
                extra: unreached.merging(["reason": reason]) { _, new in new }
            )
            return ("skipped:sandbox-unavailable", true, [:])
        }
        let initialStatusSafe = waitUntil(timeout: 5, condition: {
            coordinator.readiness == .ready
                && controller.selfTestExactStatusText.contains("Safe")
        })
        emitExactStep(
            "initial-status",
            variant: "rust-analyzer",
            controller: controller
        )
        if !initialStatusSafe, case .off(let reason) = coordinator.readiness {
            emitExactStep(
                "skipped",
                variant: "rust-analyzer",
                controller: controller,
                extra: unreached.merging(["reason": reason]) { _, new in new }
            )
            return ("skipped:sandbox-unavailable", true, [:])
        }
        guard initialStatusSafe else {
            return ("failed:initial-status", false, [:])
        }

        guard let definitionOffset = UInt32(exactly: target.definition.byteOffset)
        else {
            return ("failed:fixture", false, [:])
        }
        let realRelationTimingFileVisible =
            controller.selectFileInSidebar(target.relationFile)
            && waitUntil(timeout: 5, condition: {
                controller.displayedReaderFile?.standardizedFileURL
                    == target.relationFile.standardizedFileURL
            })
        var realRelationColdTiming = (
            relationFirstActionableMS: 0.0,
            relationAllResultsMS: 0.0,
            relationFirstActionableKind: "",
            relationFirstActionableTitle: "",
            relationCandidateEdgeCount: 0
        )
        var realRelationWarmTiming = realRelationColdTiming
        if realRelationTimingFileVisible {
            realRelationColdTiming = measureRelationTiming(
                model: realModel,
                controller: controller,
                offset: definitionOffset,
                direction: .callers,
                timeout: 45
            )
            realRelationWarmTiming = measureRelationTiming(
                model: realModel,
                controller: controller,
                offset: definitionOffset,
                direction: .callers,
                timeout: 45
            )
        }
        let realRelationColdSelectable =
            !realRelationColdTiming.relationFirstActionableTitle.isEmpty
            && controller.selfTestSelectRelationEdge(
                titled: realRelationColdTiming.relationFirstActionableTitle
            )
            && controller.selfTestSelectedRelationEdgeTitle
                == realRelationColdTiming.relationFirstActionableTitle
        let realRelationWarmSelectable =
            !realRelationWarmTiming.relationFirstActionableTitle.isEmpty
            && controller.selfTestSelectRelationEdge(
                titled: realRelationWarmTiming.relationFirstActionableTitle
            )
            && controller.selfTestSelectedRelationEdgeTitle
                == realRelationWarmTiming.relationFirstActionableTitle
        controller.selfTestDeselectRelation()
        let realRelationColdTimingFieldsValid =
            realRelationColdTiming.relationFirstActionableMS > 0
            && realRelationColdTiming.relationAllResultsMS
                >= realRelationColdTiming.relationFirstActionableMS
            && ["heuristic", "exact"].contains(
                realRelationColdTiming.relationFirstActionableKind
            )
        let realRelationWarmTimingFieldsValid =
            realRelationWarmTiming.relationFirstActionableMS > 0
            && realRelationWarmTiming.relationAllResultsMS
                >= realRelationWarmTiming.relationFirstActionableMS
            && ["heuristic", "exact"].contains(
                realRelationWarmTiming.relationFirstActionableKind
            )
        var reachedChecks = [
            "realRelationTimingFileVisible": realRelationTimingFileVisible,
            "realRelationColdTimingFieldsValid":
                realRelationColdTimingFieldsValid,
            "realRelationWarmTimingFieldsValid":
                realRelationWarmTimingFieldsValid,
            "realRelationColdFirstActionableSelectable":
                realRelationColdSelectable,
            "realRelationWarmFirstActionableSelectable":
                realRelationWarmSelectable,
        ]
        emitExactStep(
            "relation-timing",
            variant: "rust-analyzer",
            controller: controller,
            extra: [
                "measurementScope": "real rust-analyzer",
                "thresholdBasis":
                    "structural-only; threshold pending host measurement",
                "cold": [
                    "relationFirstActionableMS":
                        realRelationColdTiming.relationFirstActionableMS,
                    "relationAllResultsMS":
                        realRelationColdTiming.relationAllResultsMS,
                    "relationFirstActionableKind":
                        realRelationColdTiming.relationFirstActionableKind,
                    "relationFirstActionableTitle":
                        realRelationColdTiming.relationFirstActionableTitle,
                    "relationCandidateEdgeCount":
                        realRelationColdTiming.relationCandidateEdgeCount,
                ],
                "warm": [
                    "relationFirstActionableMS":
                        realRelationWarmTiming.relationFirstActionableMS,
                    "relationAllResultsMS":
                        realRelationWarmTiming.relationAllResultsMS,
                    "relationFirstActionableKind":
                        realRelationWarmTiming.relationFirstActionableKind,
                    "relationFirstActionableTitle":
                        realRelationWarmTiming.relationFirstActionableTitle,
                    "relationCandidateEdgeCount":
                        realRelationWarmTiming.relationCandidateEdgeCount,
                ],
                "coldHeuristicFirstObserved":
                    realRelationColdTiming.relationFirstActionableKind
                        == "heuristic",
                "warmHeuristicFirstObserved":
                    realRelationWarmTiming.relationFirstActionableKind
                        == "heuristic",
            ]
        )
        guard reachedChecks.values.allSatisfy({ $0 }),
              controller.selectFileInSidebar(target.file),
              waitUntil(timeout: 5, condition: {
                  controller.displayedReaderFile?.standardizedFileURL
                      == target.file.standardizedFileURL
              })
        else {
            return ("failed:relation-timing", false, reachedChecks)
        }

        let contextStartedAt = ContinuousClock.now
        controller.selfTestReaderClick(offset: target.clickOffset, commandClick: false)
        let contextVisible = waitUntil(timeout: 5, condition: {
            controller.selfTestContextCandidateCount >= 1
        })
        let contextFirstActionableMS = contextVisible
            ? milliseconds(since: contextStartedAt)
            : 0
        let fuzzyVisible = contextVisible
            && controller.selfTestContextProvenance?.contains("Exact") == false
        let fuzzyCount = controller.selfTestContextCandidateCount
        emitExactStep(
            "fuzzy",
            variant: "rust-analyzer",
            controller: controller,
            extra: ["fuzzyVisibleBeforeExact": fuzzyVisible]
        )
        guard contextVisible else { return ("failed:context", false, [:]) }

        let finished = waitUntil(timeout: 45, condition: {
            if controller.selfTestContextProvenance?.contains("Exact") == true {
                return true
            }
            switch coordinator.readiness {
            case .off, .unavailable:
                return true
            case .preparing, .ready:
                return false
            }
        })
        if case .off(let reason) = coordinator.readiness {
            emitExactStep(
                "skipped",
                variant: "rust-analyzer",
                controller: controller,
                extra: unreached.merging(["reason": reason]) { _, new in new }
            )
            return ("skipped:sandbox-unavailable", true, [:])
        }
        if case .unavailable(let reason) = coordinator.readiness {
            emitExactStep(
                "failed",
                variant: "rust-analyzer",
                controller: controller,
                extra: ["reason": reason]
            )
            return ("failed:unavailable", false, [:])
        }
        let exactVisible = finished
            && controller.selfTestContextProvenance?.contains("Exact") == true
        let contextExactMS = exactVisible
            ? milliseconds(since: contextStartedAt)
            : 0
        let fuzzyRetained = controller.selfTestContextCandidateCount >= fuzzyCount
        emitExactStep(
            "exact",
            variant: "rust-analyzer",
            controller: controller,
            extra: [
                "contextFirstActionableMS": contextFirstActionableMS,
                "contextExactMS": contextExactMS,
            ]
        )
        guard exactVisible && fuzzyRetained,
              let signatureTraitOffset = target.signatureTraitOffset,
              let relationRootOffset = target.relationRootOffset,
              controller.selectFileInSidebar(target.relationFile),
              waitUntil(timeout: 5, condition: {
                  controller.displayedReaderFile?.standardizedFileURL
                      == target.relationFile.standardizedFileURL
              })
        else {
            return ("failed:exact", false, [:])
        }

        func exactEdges() -> [(symbol: String, file: String)] {
            exactRelationEdges(in: realModel).compactMap {
                guard let file = $0.target?.path
                else { return nil }
                return ($0.title, file)
            }
        }

        controller.selfTestReaderRelation(
            offset: signatureTraitOffset,
            direction: .implementations
        )
        let implementationReached = waitUntil(timeout: 45, condition: {
            realModel.relationTree.direction == .implementations
                && realModel.relationTree.root?.title == "Backend"
                && exactEdges().contains {
                    $0 == ("ExactFixtureBackend", "src/lib.rs")
                }
        })
        emitExactStep(
            implementationReached ? "real-implementations" : "failed",
            variant: "rust-analyzer",
            controller: controller,
            extra: [
                "textDocumentImplementationReached": implementationReached,
                "exactEdges": exactEdges().map {
                    ["symbol": $0.symbol, "file": $0.file]
                },
            ]
        )
        reachedChecks["textDocumentImplementationReached"] =
            implementationReached
        guard implementationReached else {
            return ("failed:implementations", false, reachedChecks)
        }

        controller.selfTestReaderRelation(
            offset: definitionOffset,
            direction: .callers
        )
        let incomingCallsReached = waitUntil(timeout: 45, condition: {
            realModel.relationTree.direction == .callers
                && realModel.relationTree.root?.title == "answer"
                && exactEdges().contains {
                    $0 == ("relation_root", "src/lib.rs")
                }
                && exactEdges().contains {
                    $0 == ("main", "src/main.rs")
                }
        })
        emitExactStep(
            incomingCallsReached ? "real-incoming-calls" : "failed",
            variant: "rust-analyzer",
            controller: controller,
            extra: [
                "callHierarchyIncomingCallsReached": incomingCallsReached,
                "exactEdges": exactEdges().map {
                    ["symbol": $0.symbol, "file": $0.file]
                },
            ]
        )
        reachedChecks["callHierarchyIncomingCallsReached"] =
            incomingCallsReached
        guard incomingCallsReached else {
            return ("failed:incoming-calls", false, reachedChecks)
        }

        controller.selfTestReaderRelation(
            offset: relationRootOffset,
            direction: .calls
        )
        let outgoingCallsReached = waitUntil(timeout: 45, condition: {
            realModel.relationTree.direction == .calls
                && realModel.relationTree.root?.title == "relation_root"
                && exactEdges().contains {
                    $0 == ("answer", "src/lib.rs")
                }
        })
        emitExactStep(
            outgoingCallsReached ? "real-outgoing-calls" : "failed",
            variant: "rust-analyzer",
            controller: controller,
            extra: [
                "callHierarchyOutgoingCallsReached": outgoingCallsReached,
                "exactEdges": exactEdges().map {
                    ["symbol": $0.symbol, "file": $0.file]
                },
            ]
        )
        reachedChecks["callHierarchyOutgoingCallsReached"] =
            outgoingCallsReached
        guard outgoingCallsReached else {
            return ("failed:outgoing-calls", false, reachedChecks)
        }

        controller.selfTestReaderRelation(
            offset: definitionOffset,
            direction: .references
        )
        let exactReferencesVisible = waitUntil(timeout: 45, condition: {
            realModel.relationTree.direction == .references
                && exactEdges().contains { $0.symbol.hasPrefix("main.rs:") }
        })
        emitExactStep(
            exactReferencesVisible ? "real-references" : "failed",
            variant: "rust-analyzer",
            controller: controller,
            extra: [
                "textDocumentReferencesReached": exactReferencesVisible,
            ]
        )
        return exactReferencesVisible
            ? ("passed", true, reachedChecks)
            : ("failed:references", false, reachedChecks)
    }

    private func runRealOfflineCoverageVariant(
        root: URL
    ) -> (status: String, passed: Bool) {
        guard let executable = RustAnalyzerProvider.findExecutable() else {
            emitExactStep(
                "skipped",
                variant: "rust-analyzer-offline",
                controller: nil,
                extra: ["reason": "rust-analyzer not installed"]
            )
            return ("skipped:not-installed", true)
        }
        let fixture: URL
        do {
            fixture = try makeOfflineExactSelfTestFixture(
                source: exactSelfTestFixtureRoot(root: root)
            )
        } catch {
            emitExactStep(
                "failed",
                variant: "rust-analyzer-offline",
                controller: nil,
                extra: ["reason": error.localizedDescription]
            )
            return ("failed:fixture", false)
        }
        defer { try? FileManager.default.removeItem(at: fixture) }
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CodeInsightExactOfflineSelfTest-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: cache) }
        let observedDiagnostic = OSAllocatedUnfairLock(initialState: "")
        let coordinator = ExactCoordinator(
            providerFactory: { projectURL in
                try RustAnalyzerProvider(
                    projectURL: projectURL,
                    executableURL: executable,
                    cacheURL: cache,
                    requestTimeout: 30,
                    closeGrace: 0.5,
                    diagnosticObserver: { diagnostic in
                        observedDiagnostic.withLock { $0 = diagnostic }
                    }
                )
            },
            snapshotFactory: { root, _ in
                try ExactSelfTestDirectorySnapshot(root: root)
            },
            trustRegistry: TrustRegistry(
                fileURL: cache.appendingPathComponent("trust.json")
            )
        )
        let model = AppModel(
            indexService: ExactSelfTestIndexService(),
            exactCoordinator: coordinator
        )
        let controller = MainWindowController(
            model: model,
            settings: readerSettings,
            offscreen: true
        )
        controller.showWindow(nil)
        defer { controller.close() }
        controller.openProject(root: fixture)
        let prepared = waitUntil(timeout: 45, condition: {
            switch coordinator.readiness {
            case .ready, .off, .unavailable:
                return true
            case .preparing:
                return false
            }
        })
        if case .off(let reason) = coordinator.readiness {
            emitExactStep(
                "skipped",
                variant: "rust-analyzer-offline",
                controller: controller,
                extra: ["reason": reason]
            )
            return ("skipped:sandbox-unavailable", true)
        }
        if case .unavailable(let reason) = coordinator.readiness {
            emitExactStep(
                "failed",
                variant: "rust-analyzer-offline",
                controller: controller,
                extra: ["reason": reason]
            )
            return ("failed:unavailable", false)
        }
        guard prepared else {
            emitExactStep(
                "failed",
                variant: "rust-analyzer-offline",
                controller: controller,
                extra: ["reason": "provider-readiness-timeout"]
            )
            return ("failed:readiness-timeout", false)
        }
        let coverageObserved = waitUntil(timeout: 15, condition: {
            coordinator.analysisEnvironment?.limitations.contains(
                .dependenciesUnavailableOffline
            ) == true
        })
        guard coverageObserved else {
            let diagnostic = observedDiagnostic.withLock { $0.lowercased() }
            let offlineDiagnosticArrived =
                (diagnostic.contains("--offline")
                    || diagnostic.contains("offline mode")
                    || diagnostic.contains("cargo_net_offline"))
                && (diagnostic.contains("failed")
                    || diagnostic.contains("no matching package")
                    || diagnostic.contains("not found"))
            emitExactStep(
                offlineDiagnosticArrived ? "failed" : "skipped",
                variant: "rust-analyzer-offline",
                controller: controller,
                extra: [
                    "diagnosticsObserved": offlineDiagnosticArrived,
                    "noDefinitionRequest": true,
                    "reason": offlineDiagnosticArrived
                        ? "offline-diagnostics-without-coverage"
                        : "diagnostics-timeout",
                ]
            )
            return offlineDiagnosticArrived
                ? ("failed:coverage", false)
                : ("skipped:diagnostics-timeout", true)
        }
        let passed = waitUntil(timeout: 5, condition: {
            let status = controller.selfTestExactStatusText
            return status.contains("deps unavailable (offline)")
                && status.contains("Safe")
        })
        emitExactStep(
            passed ? "offline-coverage" : "failed",
            variant: "rust-analyzer-offline",
            controller: controller,
            extra: ["noDefinitionRequest": true]
        )
        return (passed ? "passed" : "failed:coverage", passed)
    }

    private func emitExactStep(
        _ step: String,
        variant: String,
        controller: MainWindowController?,
        extra: [String: Any] = [:]
    ) {
        var object: [String: Any] = [
            "step": step,
            "variant": variant,
            "readerFile": (controller?.displayedReaderFile?.lastPathComponent as Any?)
                ?? NSNull(),
            "contextSummary": (controller?.selfTestContextSummary as Any?)
                ?? NSNull(),
            "contextProvenance": (controller?.selfTestContextProvenance as Any?)
                ?? NSNull(),
            "candidateCount": controller?.selfTestContextCandidateCount ?? 0,
            "pinned": controller?.selfTestContextPinned ?? false,
            "exactGroupRowCount": controller?.selfTestExactGroupRowCount ?? 0,
            "exactGroupTitle": (controller?.selfTestExactGroupTitle as Any?)
                ?? NSNull(),
            "exactStatusText": controller?.selfTestExactStatusText
                ?? "Exact: unavailable",
        ]
        for (key, value) in extra { object[key] = value }
        Self.writeJSON(object)
    }

    private func finishExactSelfTest(
        controller: MainWindowController?,
        checks: [String: Bool],
        realProvider: String,
        realOfflineCoverage: String = "not-run",
        error: String?
    ) -> Never {
        let passed = error == nil
            && !checks.isEmpty
            && checks.values.allSatisfy { $0 }
        var summary: [String: Any] = checks
        summary["passed"] = passed
        summary["realProvider"] = realProvider
        summary["realOfflineCoverage"] = realOfflineCoverage
        if let error { summary["error"] = error }
        emitExactStep(
            "summary",
            variant: "all",
            controller: controller,
            extra: summary
        )
        Self.exitSelfTest(channel: "exact", status: passed ? 0 : 1)
    }
}

struct ExactSelfTestTarget {
    let file: URL
    let clickOffset: UInt32
    let definition: ExactLocation
    let referenceLocations: [ExactLocation]
    let dependencyFile: URL
    let dependencyBytes: [UInt8]
    let dependencyDefinition: ExactLocation
    let relationFile: URL
    let relationCallOffset: UInt32
    let relationRootOffset: UInt32?
    let localReferenceDeclarationOffset: UInt32?
    let localReferenceUseOffset: UInt32?
    let signatureTraitOffset: UInt32?
    let externalRootOffset: UInt32?
    let externalCallOffset: UInt32?
    let typedReceiverRootOffset: UInt32?
    let inferredReceiverRootOffset: UInt32?
    let traitObjectReceiverRootOffset: UInt32?
}

struct ExactSelfTestIndexService: IndexService {
    func index(root: URL, language: LanguageID) async throws -> EngineSession {
        try await Task.detached(priority: .userInitiated) {
            try ProjectIndexer().index(root: root, language: language)
        }.value
    }
}

struct ExactSelfTestDirectorySnapshot: Snapshot {
    let snapshotID = SnapshotID(rawValue: UUID())
    let objectFormat = GitObjectFormat.sha1
    let sourceKind = SourceKind.untracked
    let configurationPaths = ["Cargo.toml"]
    private let root: URL
    private let files = ["src/lib.rs", "src/main.rs"]

    init(root: URL) throws {
        self.root = root.standardizedFileURL
        for file in files {
            _ = try Data(contentsOf: self.root.appendingPathComponent(file))
        }
        _ = try Data(
            contentsOf: root.appendingPathComponent("Cargo.toml"),
            options: .mappedIfSafe
        )
    }

    func listFiles() -> [(path: String, contentID: ContentID, fileMode: FileMode)] {
        files.compactMap { path in
            guard let bytes = try? readBytes(path: path) else { return nil }
            return (path, ContentID.sha256(of: bytes), .regular)
        }
    }

    func readBytes(path: String) throws -> [UInt8] {
        if path == "Cargo.toml" {
            return [UInt8](try Data(
                contentsOf: root.appendingPathComponent(path),
                options: .mappedIfSafe
            ))
        }
        guard files.contains(path) else { throw GitError.missingPath(path) }
        return [UInt8](try Data(
            contentsOf: root.appendingPathComponent(path),
            options: .mappedIfSafe
        ))
    }

}

final class InProcessExactProvider: ExactProvider, @unchecked Sendable {
    let language: LanguageID = .rust
    let capabilities: ExactCapabilities
    let toolVersion = "in-process-fake-1"
    private let negotiatedCapabilities: ExactCapabilities
    private let location: ExactLocation?
    private let implementationLocations: [ExactLocation]?
    private let referenceLocations: [ExactLocation]?
    private let callHierarchyItems: [ExactCallHierarchyItem]?
    private let incomingRelations: [ExactCallRelation]?
    private let outgoingRelations: [ExactCallRelation]?
    private let externalFile: String?
    private let externalOffset: Int?
    private let externalLocation: ExactLocation?
    private let state: ExactSelfTestProviderState?
    private let limitations: Set<ExactAnalysisLimitation>?

    init(
        location: ExactLocation?,
        capabilities: ExactCapabilities = [.definition],
        negotiatedCapabilities: ExactCapabilities? = nil,
        implementationLocations: [ExactLocation]? = nil,
        referenceLocations: [ExactLocation]? = nil,
        callHierarchyItems: [ExactCallHierarchyItem]? = nil,
        incomingRelations: [ExactCallRelation]? = nil,
        outgoingRelations: [ExactCallRelation]? = nil,
        externalFile: String? = nil,
        externalOffset: Int? = nil,
        externalLocation: ExactLocation? = nil,
        state: ExactSelfTestProviderState? = nil,
        limitations: Set<ExactAnalysisLimitation>? = nil
    ) {
        self.location = location
        self.capabilities = capabilities
        self.negotiatedCapabilities = negotiatedCapabilities ?? capabilities
        self.implementationLocations = implementationLocations
        self.referenceLocations = referenceLocations
        self.callHierarchyItems = callHierarchyItems
        self.incomingRelations = incomingRelations
        self.outgoingRelations = outgoingRelations
        self.externalFile = externalFile
        self.externalOffset = externalOffset
        self.externalLocation = externalLocation
        self.state = state
        self.limitations = limitations
    }

    func prepare(
        snapshot: any Snapshot,
        profile: ExactProfileKey,
        trustMode: TrustMode
    ) throws -> any ExactSession {
        let ordinal = state?.recordPrepare(
            trustMode: trustMode,
            featureSelection: profile.featureSelection
        )
        return InProcessExactSession(
            negotiatedCapabilities: negotiatedCapabilities,
            location: location,
            implementationLocations: implementationLocations,
            referenceLocations: referenceLocations,
            callHierarchyItems: callHierarchyItems,
            incomingRelations: incomingRelations,
            outgoingRelations: outgoingRelations,
            externalFile: externalFile,
            externalOffset: externalOffset,
            externalLocation: externalLocation,
            attribution: ExactAttribution(
                provider: "fake-exact",
                toolVersion: toolVersion,
                configFingerprint: profile.configFingerprint,
                environmentFingerprint: profile.environmentFingerprint,
                featureSelection: profile.featureSelection,
                environment: ExactAnalysisEnvironment(
                    trustMode: trustMode,
                    limitations: limitations ?? (trustMode == .safe
                        ? [.buildScriptsDisabled, .procMacrosDisabled]
                        : [])
                ),
                generatedAt: Date(timeIntervalSince1970: 0)
            ),
            ordinal: ordinal,
            state: state
        )
    }
}

private final class InProcessExactSession: ExactSession, @unchecked Sendable {
    let negotiatedCapabilities: ExactCapabilities
    let readiness: ExactReadiness = .ready
    let attribution: ExactAttribution
    private let location: ExactLocation?
    private let implementationLocations: [ExactLocation]?
    private let referenceLocations: [ExactLocation]?
    private let callHierarchyItems: [ExactCallHierarchyItem]?
    private let incomingRelations: [ExactCallRelation]?
    private let outgoingRelations: [ExactCallRelation]?
    private let externalFile: String?
    private let externalOffset: Int?
    private let externalLocation: ExactLocation?
    private let ordinal: Int?
    private let state: ExactSelfTestProviderState?

    init(
        negotiatedCapabilities: ExactCapabilities,
        location: ExactLocation?,
        implementationLocations: [ExactLocation]?,
        referenceLocations: [ExactLocation]?,
        callHierarchyItems: [ExactCallHierarchyItem]?,
        incomingRelations: [ExactCallRelation]?,
        outgoingRelations: [ExactCallRelation]?,
        externalFile: String?,
        externalOffset: Int?,
        externalLocation: ExactLocation?,
        attribution: ExactAttribution,
        ordinal: Int?,
        state: ExactSelfTestProviderState?
    ) {
        self.negotiatedCapabilities = negotiatedCapabilities
        self.location = location
        self.implementationLocations = implementationLocations
        self.referenceLocations = referenceLocations
        self.callHierarchyItems = callHierarchyItems
        self.incomingRelations = incomingRelations
        self.outgoingRelations = outgoingRelations
        self.externalFile = externalFile
        self.externalOffset = externalOffset
        self.externalLocation = externalLocation
        self.attribution = attribution
        self.ordinal = ordinal
        self.state = state
    }

    func definition(
        file: String,
        byteOffset: Int
    ) throws -> ExactDefinitionQueryResult {
        guard negotiatedCapabilities.contains(.definition) else {
            return .unavailable("definition unsupported")
        }
        state?.recordDefinitionRequest()
        let wasBlocked = state?.waitIfDefinitionIsBlocked() == true
        defer {
            if wasBlocked { state?.recordBlockedDefinitionReturned() }
        }
        Thread.sleep(forTimeInterval: 0.25)
        if file == externalFile, byteOffset == externalOffset {
            return .completed(externalLocation.map {
                [ExactTarget(location: $0)]
            } ?? [])
        }
        return .completed(location.map { [ExactTarget(location: $0)] } ?? [])
    }

    func implementations(
        file: String,
        byteOffset: Int
    ) throws -> [ExactLocation]? {
        guard negotiatedCapabilities.contains(.implementations) else {
            return nil
        }
        return implementationLocations
    }

    func references(
        file: String,
        byteOffset: Int,
        includeDeclaration: Bool
    ) throws -> [ExactLocation]? {
        guard negotiatedCapabilities.contains(.references) else {
            return nil
        }
        return referenceLocations
    }

    func prepareCallHierarchy(
        file: String,
        byteOffset: Int
    ) throws -> [ExactCallHierarchyItem]? {
        guard negotiatedCapabilities.contains(.callHierarchy) else {
            return nil
        }
        return callHierarchyItems
    }

    func incomingCalls(
        item: ExactCallHierarchyItem
    ) throws -> [ExactCallRelation]? {
        guard negotiatedCapabilities.contains(.callHierarchy) else {
            return nil
        }
        state?.waitForNextRelationDelay()
        let wasBlocked = state?.waitIfRelationIsBlocked() == true
        defer {
            if wasBlocked { state?.recordBlockedRelationReturned() }
        }
        return incomingRelations
    }

    func outgoingCalls(
        item: ExactCallHierarchyItem
    ) throws -> [ExactCallRelation]? {
        guard negotiatedCapabilities.contains(.callHierarchy) else {
            return nil
        }
        state?.waitForNextRelationDelay()
        let wasBlocked = state?.waitIfRelationIsBlocked() == true
        defer {
            if wasBlocked { state?.recordBlockedRelationReturned() }
        }
        return outgoingRelations
    }

    func cancel() {}
    func close() {
        if let ordinal { state?.recordClose(ordinal: ordinal) }
    }
}

final class ExactSelfTestProviderState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRoot: URL?
    private var storedTrustModes: [String] = []
    private var storedFeatureSelections: [FeatureSelection] = []
    private var storedClosedSessions: Set<Int> = []
    private var storedDefinitionRequestCount = 0
    private var nextRelationDelay: TimeInterval = 0
    private let definitionCondition = NSCondition()
    private var shouldBlockNextDefinition = false
    private var blockedDefinition = false
    private var didReturnBlockedDefinition = false
    private let relationCondition = NSCondition()
    private var shouldBlockNextRelation = false
    private var blockedRelation = false
    private var didReturnBlockedRelation = false

    var root: URL? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedRoot
        }
        set {
            lock.lock()
            storedRoot = newValue
            lock.unlock()
        }
    }

    var trustModes: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedTrustModes
    }

    var closedSessions: Set<Int> {
        lock.lock()
        defer { lock.unlock() }
        return storedClosedSessions
    }

    var featureSelections: [FeatureSelection] {
        lock.lock()
        defer { lock.unlock() }
        return storedFeatureSelections
    }

    var definitionRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedDefinitionRequestCount
    }

    func recordDefinitionRequest() {
        lock.lock()
        storedDefinitionRequestCount += 1
        lock.unlock()
    }

    func delayNextRelation(by delay: TimeInterval) {
        lock.lock()
        nextRelationDelay = min(max(delay, 0), 1)
        lock.unlock()
    }

    func waitForNextRelationDelay() {
        lock.lock()
        let delay = nextRelationDelay
        nextRelationDelay = 0
        lock.unlock()
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
    }

    var definitionIsBlocked: Bool {
        definitionCondition.lock()
        defer { definitionCondition.unlock() }
        return blockedDefinition
    }

    var blockedDefinitionReturned: Bool {
        definitionCondition.lock()
        defer { definitionCondition.unlock() }
        return didReturnBlockedDefinition
    }

    var relationIsBlocked: Bool {
        relationCondition.lock()
        defer { relationCondition.unlock() }
        return blockedRelation
    }

    var blockedRelationReturned: Bool {
        relationCondition.lock()
        defer { relationCondition.unlock() }
        return didReturnBlockedRelation
    }

    func recordPrepare(
        trustMode: TrustMode,
        featureSelection: FeatureSelection
    ) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let mode = switch trustMode {
        case .safe: "safe"
        case .trusted: "trusted"
        }
        storedTrustModes.append(mode)
        storedFeatureSelections.append(featureSelection)
        return storedTrustModes.count
    }

    func blockNextDefinition() {
        definitionCondition.lock()
        shouldBlockNextDefinition = true
        blockedDefinition = false
        didReturnBlockedDefinition = false
        definitionCondition.unlock()
    }

    func waitIfDefinitionIsBlocked() -> Bool {
        definitionCondition.lock()
        guard shouldBlockNextDefinition else {
            definitionCondition.unlock()
            return false
        }
        shouldBlockNextDefinition = false
        blockedDefinition = true
        definitionCondition.broadcast()
        while blockedDefinition { definitionCondition.wait() }
        definitionCondition.unlock()
        return true
    }

    func releaseBlockedDefinition() {
        definitionCondition.lock()
        shouldBlockNextDefinition = false
        blockedDefinition = false
        definitionCondition.broadcast()
        definitionCondition.unlock()
    }

    func recordBlockedDefinitionReturned() {
        definitionCondition.lock()
        didReturnBlockedDefinition = true
        definitionCondition.broadcast()
        definitionCondition.unlock()
    }

    func blockNextRelation() {
        relationCondition.lock()
        shouldBlockNextRelation = true
        blockedRelation = false
        didReturnBlockedRelation = false
        relationCondition.unlock()
    }

    func waitIfRelationIsBlocked() -> Bool {
        relationCondition.lock()
        guard shouldBlockNextRelation else {
            relationCondition.unlock()
            return false
        }
        shouldBlockNextRelation = false
        blockedRelation = true
        relationCondition.broadcast()
        while blockedRelation { relationCondition.wait() }
        relationCondition.unlock()
        return true
    }

    func releaseBlockedRelation() {
        relationCondition.lock()
        shouldBlockNextRelation = false
        blockedRelation = false
        relationCondition.broadcast()
        relationCondition.unlock()
    }

    func recordBlockedRelationReturned() {
        relationCondition.lock()
        didReturnBlockedRelation = true
        relationCondition.broadcast()
        relationCondition.unlock()
    }

    func recordClose(ordinal: Int) {
        lock.lock()
        storedClosedSessions.insert(ordinal)
        lock.unlock()
    }
}

func exactSelfTestTarget(root: URL) -> ExactSelfTestTarget? {
    let root = root.standardizedFileURL
    let path = "src/main.rs"
    let definitionPath = "src/lib.rs"
    let file = root.appendingPathComponent(path)
    let relationFile = root.appendingPathComponent(definitionPath)
    let dependencyFile = root.deletingLastPathComponent()
        .appendingPathComponent(
            "fake-registry/registry/src/"
                + "index.crates.io-1949cf8c6b5b557f/"
                + "dependency-fixture-1.2.3/src/lib.rs"
        )
    guard let source = try? String(contentsOf: file, encoding: .utf8),
          let click = source.range(of: "answer();", options: .backwards),
          let definitionSource = try? String(
              contentsOf: relationFile,
              encoding: .utf8
          ),
          let definition = definitionSource.range(of: "answer"),
          let relationCall = definitionSource.range(
              of: "answer()",
              options: .backwards
          ),
          let clickOffset = UInt32(exactly: source[..<click.lowerBound].utf8.count),
          let definitionOffset = UInt32(exactly: definitionSource[
              ..<definition.lowerBound
          ].utf8.count),
          let relationCallOffset = UInt32(exactly: definitionSource[
              ..<relationCall.lowerBound
          ].utf8.count),
          let clickCoordinate = LineTable(bytes: Array(source.utf8))
              .lineColumn(at: clickOffset),
          let coordinate = LineTable(bytes: Array(definitionSource.utf8))
              .lineColumn(at: definitionOffset),
          let relationCallCoordinate = LineTable(
              bytes: Array(definitionSource.utf8)
          ).lineColumn(at: relationCallOffset)
    else { return nil }
    let relationRootOffset = definitionSource.range(
        of: "pub fn relation_root"
    ).flatMap {
        definitionSource[$0].range(of: "relation_root")
    }.flatMap {
        UInt32(exactly: definitionSource[..<$0.lowerBound].utf8.count)
    }
    let localReferenceDeclarationOffset = definitionSource.range(
        of: "receiver = InferredReceiver::new()"
    ).flatMap {
        UInt32(exactly: definitionSource[..<$0.lowerBound].utf8.count)
    }
    let localReferenceUseOffset = definitionSource.range(
        of: "receiver.inferred_edge()"
    ).flatMap {
        UInt32(exactly: definitionSource[..<$0.lowerBound].utf8.count)
    }
    let dependencyBytes: [UInt8]
    let dependencyDefinition: ExactLocation
    let resolvedDependencyFile: URL
    if let bytes = try? [UInt8](Data(contentsOf: dependencyFile)),
       let dependencySource = String(bytes: bytes, encoding: .utf8),
       let dependencyRange = dependencySource.range(of: "dependency_target"),
       let dependencyOffset = UInt32(exactly: dependencySource[
           ..<dependencyRange.lowerBound
       ].utf8.count),
       let dependencyCoordinate = LineTable(bytes: bytes)
           .lineColumn(at: dependencyOffset)
    {
        dependencyBytes = bytes
        resolvedDependencyFile = dependencyFile
        dependencyDefinition = ExactLocation(
            file: dependencyFile.path,
            byteOffset: Int(dependencyOffset),
            line: Int(dependencyCoordinate.line),
            column: Int(dependencyCoordinate.column)
        )
    } else {
        dependencyBytes = Array(definitionSource.utf8)
        resolvedDependencyFile = relationFile
        dependencyDefinition = ExactLocation(
            file: definitionPath,
            byteOffset: Int(definitionOffset),
            line: Int(coordinate.line),
            column: Int(coordinate.column)
        )
    }
    let signatureTraitOffset = definitionSource.range(
        of: "pub trait Backend"
    ).flatMap {
        definitionSource[$0].range(of: "Backend")
    }.flatMap {
        UInt32(exactly: definitionSource[..<$0.lowerBound].utf8.count)
    }
    let externalRootOffset = definitionSource.range(of: "dependency_call").flatMap {
        UInt32(exactly: definitionSource[..<$0.lowerBound].utf8.count)
    }
    let externalCallOffset = definitionSource.range(
        of: "values.len()",
        options: .backwards
    ).flatMap {
        UInt32(exactly: definitionSource[..<$0.lowerBound].utf8.count)
    }
    let typedReceiverRootOffset = definitionSource.range(
        of: "typed_receiver_call"
    ).flatMap {
        UInt32(exactly: definitionSource[..<$0.lowerBound].utf8.count)
    }
    let inferredReceiverRootOffset = definitionSource.range(
        of: "inferred_receiver_call"
    ).flatMap {
        UInt32(exactly: definitionSource[..<$0.lowerBound].utf8.count)
    }
    let traitObjectReceiverRootOffset = definitionSource.range(
        of: "trait_object_receiver_call"
    ).flatMap {
        UInt32(exactly: definitionSource[..<$0.lowerBound].utf8.count)
    }
    return ExactSelfTestTarget(
        file: file,
        clickOffset: clickOffset,
        definition: ExactLocation(
            file: definitionPath,
            byteOffset: Int(definitionOffset),
            line: Int(coordinate.line),
            column: Int(coordinate.column)
        ),
        referenceLocations: [
            ExactLocation(
                file: path,
                byteOffset: Int(clickOffset),
                line: Int(clickCoordinate.line),
                column: Int(clickCoordinate.column)
            ),
            ExactLocation(
                file: definitionPath,
                byteOffset: Int(relationCallOffset),
                line: Int(relationCallCoordinate.line),
                column: Int(relationCallCoordinate.column)
            ),
        ],
        dependencyFile: resolvedDependencyFile,
        dependencyBytes: dependencyBytes,
        dependencyDefinition: dependencyDefinition,
        relationFile: relationFile,
        relationCallOffset: relationCallOffset,
        relationRootOffset: relationRootOffset,
        localReferenceDeclarationOffset: localReferenceDeclarationOffset,
        localReferenceUseOffset: localReferenceUseOffset,
        signatureTraitOffset: signatureTraitOffset,
        externalRootOffset: externalRootOffset,
        externalCallOffset: externalCallOffset,
        typedReceiverRootOffset: typedReceiverRootOffset,
        inferredReceiverRootOffset: inferredReceiverRootOffset,
        traitObjectReceiverRootOffset: traitObjectReceiverRootOffset
    )
}

func exactSelfTestFixtureRoot(root: URL) -> URL {
    root.standardizedFileURL.appendingPathComponent(
        "Tests/CodeInsightExactTests/Fixtures/exact_fixture",
        isDirectory: true
    )
}

private func makeOfflineExactSelfTestFixture(source: URL) throws -> URL {
    let destination = FileManager.default.temporaryDirectory.appendingPathComponent(
        "CodeInsightExactOfflineFixture-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.copyItem(at: source, to: destination)
    let manifestURL = destination.appendingPathComponent("Cargo.toml")
    var manifest = try String(contentsOf: manifestURL, encoding: .utf8)
    manifest += """

        [dependencies]
        codeinsight-definitely-missing-offline-dependency = "99.99.99"
        """
    try manifest.write(to: manifestURL, atomically: true, encoding: .utf8)
    return destination
}

private func makeHistoricalExactSelfTestRepository() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "CodeInsightExactHistoryFixture-\(UUID().uuidString)",
        isDirectory: true
    )
    do {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("src"),
            withIntermediateDirectories: true
        )
        try Data(
            "[package]\nname='history'\nversion='0.1.0'\nedition='2021'\n".utf8
        ).write(to: root.appendingPathComponent("Cargo.toml"))
        try Data(
            "use history::answer;\nfn main() { let _ = answer(); }\n".utf8
        ).write(to: root.appendingPathComponent("src/main.rs"))
        try Data("pub fn answer() -> u8 { 1 }\n".utf8)
            .write(to: root.appendingPathComponent("src/lib.rs"))
        try exactSelfTestGit(root, "init", "-q")
        try exactSelfTestGit(root, "config", "user.name", "CodeInsight Tests")
        try exactSelfTestGit(
            root,
            "config",
            "user.email",
            "tests@codeinsight.invalid"
        )
        try exactSelfTestGit(root, "add", "-A")
        try exactSelfTestGit(root, "commit", "-q", "-m", "definition line 1")
        try Data("// moved\n// again\npub fn answer() -> u8 { 2 }\n".utf8)
            .write(to: root.appendingPathComponent("src/lib.rs"))
        try exactSelfTestGit(root, "add", "-A")
        try exactSelfTestGit(root, "commit", "-q", "-m", "definition line 3")
        return root
    } catch {
        try? FileManager.default.removeItem(at: root)
        throw error
    }
}

@MainActor
private func selfTestListRowCount(in view: NSView) -> Int {
    max(
        (view as? NSTableView)?.numberOfRows ?? 0,
        view.subviews.map(selfTestListRowCount(in:)).max() ?? 0
    )
}
