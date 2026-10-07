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
    func runProjectorSelfTest() -> Never {
        let checks = ReaderTextView.projectorSelfTestChecks()
        let passed = !checks.isEmpty && checks.values.allSatisfy { $0 }
        do {
            var object: [String: Any] = checks
            object["channel"] = "projector"
            object["passed"] = passed
            let data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            Self.exitSelfTest(channel: "projector", status: 1)
        }
        Self.exitSelfTest(channel: "projector", status: passed ? 0 : 1)
    }

    func runFoldSelfTest() -> Never {
        let checks = ReaderTextView.foldSelfTestChecks()
        let passed = !checks.isEmpty && checks.values.allSatisfy { $0 }
        do {
            var object: [String: Any] = checks
            object["channel"] = "fold"
            object["passed"] = passed
            let data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            Self.exitSelfTest(channel: "fold", status: 1)
        }
        Self.exitSelfTest(channel: "fold", status: passed ? 0 : 1)
    }

    func runTabsSelfTest() -> Never {
        let root: URL
        do {
            root = try makeTabsSelfTestRepository()
        } catch {
            Self.finishTabsSelfTest(
                checks: [:],
                geometry: [:],
                error: error.localizedDescription
            )
        }

        func finish(
            checks: [String: Bool],
            geometry: [String: Double],
            error: String? = nil
        ) -> Never {
            try? FileManager.default.removeItem(at: root)
            Self.finishTabsSelfTest(
                checks: checks,
                geometry: geometry,
                error: error
            )
        }

        // Exclude the titled-window WindowServer cache from the tab footprint measurement.
        launch(offscreen: true, measuresIdleFootprint: true)
        guard let controller = windowController else {
            finish(checks: [:], geometry: [:], error: "window unavailable")
        }
        let contentSize = NSSize(width: 1_600, height: 1_000)
        controller.window?.setContentSize(contentSize)
        controller.window?.contentView?.setFrameSize(contentSize)
        pumpRunLoop()

        controller.openProject(root: root)
        guard waitUntil(timeout: 30, condition: {
            if case .failed = self.model.projectState { return true }
            if case .ready = self.model.projectState {
                return !self.model.commitPicker.isLoading
            }
            return false
        }),
        case .ready = model.projectState,
        model.commitPicker.errorMessage == nil,
        model.commitPicker.commits.indices.contains(1)
        else {
            finish(
                checks: [:],
                geometry: [:],
                error: "project or HEAD~1 unavailable"
            )
        }

        let fileA = root.appendingPathComponent("src/a.rs").standardizedFileURL
        let fileB = root.appendingPathComponent("src/b.rs").standardizedFileURL
        let menus = NSApplication.shared.mainMenu?.items.compactMap(\.submenu)
        let fileMenu = menus?.first { $0.title == "File" }
        let goMenu = menus?.first { $0.title == "Go" }
        let openInNewTabItem = fileMenu?.item(withTitle: "Open in New Tab")
        let closeTabItem = fileMenu?.item(withTitle: "Close Tab")
        let previousTabItem = goMenu?.item(withTitle: "Previous Tab")
        let nextTabItem = goMenu?.item(withTitle: "Next Tab")
        let menuChecks = [
            "sidebarHasOpenInNewTab":
                controller.selfTestFileContextMenuHasOpenInNewTab,
            "commandShiftReturnOpensNewTab":
                openInNewTabItem?.keyEquivalent == "\r"
                && openInNewTabItem?.keyEquivalentModifierMask
                    == [.command, .shift]
                && openInNewTabItem?.action
                    == #selector(openSelectedFileInNewTab(_:))
                && openInNewTabItem?.target === self,
            "commandWClosesTab":
                closeTabItem?.keyEquivalent == "w"
                && closeTabItem?.keyEquivalentModifierMask == .command
                && closeTabItem?.action == #selector(closeActiveTab(_:))
                && closeTabItem?.target === self,
            "commandShiftBracketSwitchesTabs":
                previousTabItem?.keyEquivalent == "["
                && previousTabItem?.keyEquivalentModifierMask
                    == [.command, .shift]
                && previousTabItem?.action == #selector(selectPreviousTab(_:))
                && previousTabItem?.target === self
                && nextTabItem?.keyEquivalent == "]"
                && nextTabItem?.keyEquivalentModifierMask
                    == [.command, .shift]
                && nextTabItem?.action == #selector(selectNextTab(_:))
                && nextTabItem?.target === self,
        ]
        guard let bytesA = try? [UInt8](Data(contentsOf: fileA)),
              let bytesB = try? [UInt8](Data(contentsOf: fileB)),
              let scrollTarget = Data(bytesA).range(
                  of: Data("let anchor_180".utf8)
              )?.lowerBound,
              let scrollByteOffset = UInt32(exactly: scrollTarget),
              let selectionByteOffset = UInt32(exactly: scrollTarget + 4),
              waitUntil(timeout: 5, condition: {
                  controller.selectFileInSidebar(fileA)
              }),
              waitUntil(timeout: 5, condition: {
                  controller.displayedReaderFile?.standardizedFileURL == fileA
                      && controller.selfTestLeftReaderBytes == bytesA
              })
        else {
            finish(
                checks: [:],
                geometry: [:],
                error: "could not open tab fixture A"
            )
        }

        controller.setReadingPositionForSelfTest(
            scrollByteOffset: scrollByteOffset,
            selectionByteOffset: selectionByteOffset
        )
        pumpRunLoop()
        guard let recordedScroll = controller.selfTestReadingByteOffset else {
            finish(
                checks: [:],
                geometry: [:],
                error: "could not record A reading position"
            )
        }
        let oneTabGeometry = Self.tabGeometryChecks(
            controller.selfTestTabGeometry,
            prefix: "oneTab",
            expectsVisibleStrip: true
        )
        let openedA = controller.selfTestTabCount == 1
            && controller.selfTestActiveTabIndex == 0
            && controller.selfTestLeftReaderBytes == bytesA
        Self.writeJSON([
            "step": "openA",
            "tabs": controller.selfTestTabCount,
            "active": controller.selfTestActiveTabIndex ?? -1,
            "stripHidden": controller.selfTestTabGeometry.stripHidden,
            "recordedScroll": recordedScroll,
        ])

        controller.openFileInNewTabForSelfTest(fileB)
        guard waitUntil(timeout: 5, condition: {
            controller.displayedReaderFile?.standardizedFileURL == fileB
                && controller.selfTestLeftReaderBytes == bytesB
        }) else {
            finish(
                checks: oneTabGeometry,
                geometry: [:],
                error: "could not open tab fixture B"
            )
        }
        pumpRunLoop()
        let twoTabGeometry = Self.tabGeometryChecks(
            controller.selfTestTabGeometry,
            prefix: "twoTabs",
            expectsVisibleStrip: true
        )
        let openedB = controller.selfTestTabCount == 2
            && controller.selfTestActiveTabIndex == 1
            && controller.selfTestActiveTabFile?.standardizedFileURL == fileB
            && controller.selfTestLeftReaderBytes == bytesB
        let dualTabFootprintMB = physicalFootprintBytes().map {
            Double($0) / 1_048_576
        } ?? -1
        let dualTabFootprintUnderBudget = dualTabFootprintMB >= 0
            && dualTabFootprintMB < SelfTestBudgets.idleFootprintMB
        Self.writeJSON([
            "step": "openB",
            "tabs": controller.selfTestTabCount,
            "active": controller.selfTestActiveTabIndex ?? -1,
            "bytesEqual": controller.selfTestLeftReaderBytes == bytesB,
            "footprintMB": dualTabFootprintMB,
            "footprintUnderBudget": dualTabFootprintUnderBudget,
            "geometry": Self.tabGeometryJSON(controller.selfTestTabGeometry),
        ])

        let previousTabActionSent = previousTabItem.flatMap { item in
            item.action.map {
                NSApplication.shared.sendAction(
                    $0,
                    to: item.target,
                    from: item
                )
            }
        } ?? false
        let restoredA = previousTabActionSent
            && waitUntil(timeout: 5, condition: {
                controller.displayedReaderFile?.standardizedFileURL == fileA
                    && controller.selfTestLeftReaderBytes == bytesA
            })
        pumpRunLoop()
        let restoredScroll = controller.selfTestReadingByteOffset
        let scrollRestored = restoredScroll.map {
            abs(Int64($0) - Int64(recordedScroll)) <= 4
        } == true
        let selectionRestored =
            controller.selfTestActiveTabSelectionByteOffset == selectionByteOffset
        Self.writeJSON([
            "step": "switchA",
            "bytesEqual": controller.selfTestLeftReaderBytes == bytesA,
            "recordedScroll": recordedScroll,
            "restoredScroll": restoredScroll.map(Int.init) ?? -1,
            "scrollRestored": scrollRestored,
            "selectionRestored": selectionRestored,
        ])

        let nextTabActionSent = nextTabItem.flatMap { item in
            item.action.map {
                NSApplication.shared.sendAction(
                    $0,
                    to: item.target,
                    from: item
                )
            }
        } ?? false
        let selectedBByCommand = nextTabActionSent
            && waitUntil(timeout: 5, condition: {
                controller.displayedReaderFile?.standardizedFileURL == fileB
                    && controller.selfTestLeftReaderBytes == bytesB
            })
        let closeTabActionSent = closeTabItem.flatMap { item in
            item.action.map {
                NSApplication.shared.sendAction(
                    $0,
                    to: item.target,
                    from: item
                )
            }
        } ?? false
        let closedBByCommand = closeTabActionSent
            && waitUntil(timeout: 5, condition: {
                controller.selfTestTabCount == 1
                    && controller.displayedReaderFile?
                        .standardizedFileURL == fileA
                    && controller.selfTestLeftReaderBytes == bytesA
            })
        pumpRunLoop()
        let closedB = selectedBByCommand
            && closedBByCommand
            && controller.selfTestTabCount == 1
            && controller.selfTestActiveTabIndex == 0
            && controller.displayedReaderFile?.standardizedFileURL == fileA
            && controller.selfTestLeftReaderBytes == bytesA
        let hiddenAfterCloseGeometry = Self.tabGeometryChecks(
            controller.selfTestTabGeometry,
            prefix: "oneTabAfterClose",
            expectsVisibleStrip: true
        )
        Self.writeJSON([
            "step": "closeB",
            "tabs": controller.selfTestTabCount,
            "active": controller.selfTestActiveTabIndex ?? -1,
            "readerStillA": controller.displayedReaderFile?
                .standardizedFileURL == fileA,
            "stripHidden": controller.selfTestTabGeometry.stripHidden,
            "geometry": Self.tabGeometryJSON(controller.selfTestTabGeometry),
        ])

        controller.openFileInNewTabForSelfTest(fileB)
        controller.selectPreviousTab()
        let previousRevision = model.commitPicker.commits[1].fullSHA
        guard controller.selectCommit(previousRevision),
              waitUntil(timeout: 30, condition: {
                  self.model.currentRevision == previousRevision
                      && self.model.snapshotPhase == .fullReady
              })
        else {
            var checks = oneTabGeometry
            checks.merge(twoTabGeometry) { _, new in new }
            checks.merge(hiddenAfterCloseGeometry) { _, new in new }
            finish(
                checks: checks,
                geometry: Self.tabGeometryJSON(controller.selfTestTabGeometry),
                error: "snapshot switch did not complete"
            )
        }
        controller.selectNextTab()
        let missingFilePlaceholder = waitUntil(timeout: 5, condition: {
            controller.displayedReaderFile?.standardizedFileURL == fileB
                && controller.selfTestLeftReaderBytes == nil
                && controller.selfTestReaderPlaceholderVisible
                && controller.selfTestReaderPlaceholderText
                    == "Could not open b.rs"
        })
        Self.writeJSON([
            "step": "missingSnapshotFile",
            "revision": previousRevision,
            "file": controller.displayedReaderFile?.path ?? "",
            "placeholder": controller.selfTestReaderPlaceholderText ?? "",
            "bytesAreNil": controller.selfTestLeftReaderBytes == nil,
            "honestPlaceholder": missingFilePlaceholder,
        ])

        var checks = oneTabGeometry
        checks.merge(twoTabGeometry) { _, new in new }
        checks.merge(hiddenAfterCloseGeometry) { _, new in new }
        checks.merge(menuChecks) { _, new in new }
        checks.merge([
            "oneTabOpened": openedA,
            "openedBInNewTab": openedB,
            "switchedBackToA": restoredA,
            "aBytesRestored": restoredA,
            "scrollRestored": scrollRestored,
            "selectionAnchorRestored": selectionRestored,
            "closedBWhileReaderStayedOnA": closedB,
            "missingSnapshotFileShowsHonestPlaceholder":
                missingFilePlaceholder,
        ]) { _, new in new }
        finish(
            checks: checks,
            geometry: Self.tabGeometryJSON(controller.selfTestTabGeometry)
        )
    }

    func runSearchSelfTest() -> Never {
        let root: URL
        do {
            root = try makeSearchSelfTestDirectory()
        } catch {
            Self.writeJSON([
                "error": error.localizedDescription,
                "selfTest": "search",
            ])
            Self.exitSelfTest(channel: "search", status: 1)
        }

        func finish(
            state: (
                totalRows: Int,
                groupRows: Int,
                matchRows: Int,
                truncationRows: Int,
                truncationVisible: Bool,
                truncationDiagnostic: [String: String]?,
                status: String,
                searching: Bool
            )?,
            error: String? = nil
        ) -> Never {
            try? FileManager.default.removeItem(at: root)
            let checks = [
                "matchRowsCappedAt2000": state?.matchRows == 2_000,
                "statusContainsTrueTotal": state?.status.contains(localizedFormat("panel.search.matches", Int64(2_001))) == true,
                "truncationRowExists": state?.truncationRows == 1,
                "truncationRowVisible": state?.truncationVisible == true,
            ]
            Self.writeJSON([
                "checks": checks,
                "error": error as Any,
                "groupRows": state?.groupRows as Any,
                "matchRows": state?.matchRows as Any,
                "searching": state?.searching as Any,
                "selfTest": "search",
                "status": state?.status as Any,
                "totalRows": state?.totalRows as Any,
                "truncationRows": state?.truncationRows as Any,
                "truncationDiagnostic": state?.truncationDiagnostic as Any,
            ])
            Self.exitSelfTest(
                channel: "search",
                status: error == nil && checks.values.allSatisfy { $0 } ? 0 : 1
            )
        }

        launch(offscreen: true)
        guard let controller = windowController else {
            finish(state: nil, error: "window unavailable")
        }
        let contentSize = NSSize(width: 1_600, height: 1_000)
        controller.window?.setContentSize(contentSize)
        controller.window?.contentView?.setFrameSize(contentSize)
        pumpRunLoop()

        controller.openProject(root: root)
        guard waitUntil(timeout: 30, condition: {
            if case .failed = self.model.projectState { return true }
            if case .ready = self.model.projectState { return true }
            return false
        }), case .ready = model.projectState else {
            finish(state: nil, error: "fixture indexing failed")
        }

        controller.showProjectSearch()
        controller.selfTestSetProjectSearchQuery("zzqqmarker")
        guard waitUntil(timeout: 30, condition: {
            guard let state = controller.selfTestProjectSearchOutlineState else {
                return false
            }
            return !state.searching && state.status.contains(localizedFormat("panel.search.matches", Int64(2_001)))
        }) else {
            finish(
                state: controller.selfTestProjectSearchOutlineState,
                error: "search did not finish"
            )
        }

        controller.selfTestRevealProjectSearchTruncationRow()
        pumpRunLoop()
        finish(state: controller.selfTestProjectSearchOutlineState)
    }

    func runReadingSelfTest() -> Never {
        let root: URL
        do {
            root = try makeReadingSelfTestDirectory()
        } catch {
            Self.finishReadingSelfTest(
                checks: [:],
                metrics: [:],
                error: error.localizedDescription
            )
        }

        func finish(
            checks: [String: Bool],
            metrics: [String: Double],
            error: String? = nil
        ) -> Never {
            try? FileManager.default.removeItem(at: root)
            Self.finishReadingSelfTest(
                checks: checks,
                metrics: metrics,
                error: error
            )
        }

        launch(offscreen: true, measuresIdleFootprint: true)
        guard let controller = windowController else {
            finish(checks: [:], metrics: [:], error: "window unavailable")
        }
        // The design's 100 MB budget is for an idle app, before a project
        // or the enlarged reading viewport is loaded. Report loaded memory
        // separately instead of comparing it with the idle budget.
        let readingIdleFootprintMB = physicalFootprintBytes().map {
            Double($0) / 1_048_576
        } ?? -1
        let contentSize = NSSize(width: 1_600, height: 1_000)
        controller.window?.setContentSize(contentSize)
        controller.window?.contentView?.setFrameSize(contentSize)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.window?.displayIfNeeded()
        controller.openProject(root: root)
        guard waitUntil(timeout: 10, condition: {
            if case .failed = self.model.projectState { return true }
            if case .ready = self.model.projectState { return true }
            return false
        }), case .ready = model.projectState
        else {
            finish(checks: [:], metrics: [:], error: "fixture project unavailable")
        }

        let regular = root.appendingPathComponent("regular.rs")
        guard let regularBytes = try? [UInt8](Data(contentsOf: regular)),
              let alphaOffset = Data(regularBytes).range(
                  of: Data("alpha".utf8)
              )?.lowerBound,
              let betaOffset = Data(regularBytes).range(
                  of: Data("beta".utf8)
              )?.lowerBound
        else {
            finish(checks: [:], metrics: [:], error: "regular fixture unavailable")
        }
        controller.openFileForSelfTest(regular)
        guard waitUntil(timeout: 5, condition: {
            controller.selfTestLeftReaderBytes == regularBytes
        }) else {
            finish(checks: [:], metrics: [:], error: "regular reader did not open")
        }
        pumpRunLoop()

        let geometryOn = controller.selfTestReadingGeometry
        guard waitUntil(timeout: 10, condition: {
            controller.selfTestIdentifierPreparationState == .ready
        }) else {
            finish(checks: [:], metrics: [:], error: "regular identifier preparation did not finish")
        }
        let alphaCount = controller.selfTestActivateReading(
            at: UInt32(alphaOffset)
        )
        let betaCount = controller.selfTestActivateReading(
            at: UInt32(betaOffset)
        )
        let currentLine = controller.selfTestCurrentLineNumber
        let currentLineState = controller.selfTestVisibleCurrentLineNumbers
        let visibleLineNumbers = controller.selfTestVisibleLineNumbers
        let regularFootprintMB = physicalFootprintBytes().map {
            Double($0) / 1_048_576
        } ?? -1
        let blankCount = controller.selfTestActivateReading(at: 2)

        var disabledSettings = readerSettings
        disabledSettings.lineNumbers = false
        controller.applyReaderSettings(disabledSettings)
        pumpRunLoop()
        let geometryOff = controller.selfTestReadingGeometry

        let tolerance: CGFloat = 1
        let rulerInsideWindow = geometryOn.windowContentFrame
            .insetBy(dx: -tolerance, dy: -tolerance)
            .contains(geometryOn.rulerFrame)
        let rulerInClip = geometryOn.clipFrame.intersection(geometryOn.rulerFrame)
        let occupiedRulerWidth = rulerInClip.isNull ? 0 : rulerInClip.width
        let rulerWidthEquation = abs(
            geometryOn.contentFrame.width
                - (
                    geometryOn.clipFrame.width
                        - occupiedRulerWidth
                )
        ) <= tolerance
        let disabledWidthEquation = abs(
            geometryOff.contentFrame.width
                - geometryOff.clipFrame.width
        ) <= tolerance
        let disabledWidthGainEquation =
            abs(geometryOff.clipFrame.width - geometryOn.clipFrame.width) <= tolerance
            && abs(geometryOff.contentFrame.width
                - geometryOn.contentFrame.width
                - occupiedRulerWidth) <= tolerance
        let legacySettings = ReaderSettings()
        controller.applyReaderSettings(legacySettings)
        let legacyFunctionFontName = controller.selfTestLeftReaderFontName(
            at: UInt32(alphaOffset)
        )
        var changedVisualSettings = legacySettings
        changedVisualSettings.functionDeclarationFontWeight =
            Double(NSFont.Weight.regular.rawValue)
        controller.applyReaderSettings(changedVisualSettings)
        pumpRunLoop()
        let changedFunctionFontName = controller.selfTestLeftReaderFontName(
            at: UInt32(alphaOffset)
        )
        let visualSettingAppliedImmediately =
            legacyFunctionFontName
                == NSFont.monospacedSystemFont(
                    ofSize: legacySettings.fontSize
                        + legacySettings.functionNameDelta,
                    weight: NSFont.Weight(rawValue: legacySettings.functionDeclarationFontWeight)
                ).fontName
            && changedFunctionFontName
                == NSFont.monospacedSystemFont(
                    ofSize: legacySettings.fontSize
                        + legacySettings.functionNameDelta,
                    weight: .regular
                ).fontName
            && changedFunctionFontName != legacyFunctionFontName

        let originalReaderSettings = readerSettings
        var commandSettings = legacySettings
        commandSettings.fontSize = 12
        commitReaderSettings(commandSettings)
        showSettings(nil)
        settingsWindowController?.window?.setFrameOrigin(
            NSPoint(x: -20_000, y: -20_000)
        )
        pumpRunLoop()
        let viewMenu = NSApplication.shared.mainMenu?.items
            .compactMap(\.submenu).first { $0.title == "View" }
        let increaseFontItem = viewMenu?.item(withTitle: "Increase Font Size")
        let decreaseFontItem = viewMenu?.item(withTitle: "Decrease Font Size")
        let fontMenuUsesExactKeyEquivalents =
            increaseFontItem?.keyEquivalent == "+"
            && increaseFontItem?.keyEquivalentModifierMask == .command
            && decreaseFontItem?.keyEquivalent == "-"
            && decreaseFontItem?.keyEquivalentModifierMask == .command
        increaseReaderFontSize(nil)
        let firstIncrease = readerSettings.fontSize
        increaseReaderFontSize(nil)
        pumpRunLoop()
        let secondIncrease = readerSettings.fontSize
        let fontChangesByOnePoint = firstIncrease == 13 && secondIncrease == 14
        let fileReaderFontUpdatesImmediately =
            controller.selfTestLeftReaderFontSize(at: 0) == 14
        let openSettingsWindowUpdatesImmediately =
            settingsWindowController?.currentSettings.fontSize == 14
        let defaultsRoundTripAfterMenuChange =
            ReaderSettings(defaults: .standard) == readerSettings
        while readerSettings.fontSize < ReaderSettings.fontSizeRange.upperBound {
            increaseReaderFontSize(nil)
        }
        let upperBoundDisablesIncrease = increaseFontItem.map {
            readerSettings.fontSize == 24 && !validateMenuItem($0)
        } ?? false
        increaseReaderFontSize(nil)
        let upperBoundClamps = readerSettings.fontSize == 24
        while readerSettings.fontSize > ReaderSettings.fontSizeRange.lowerBound {
            decreaseReaderFontSize(nil)
        }
        let lowerBoundDisablesDecrease = decreaseFontItem.map {
            readerSettings.fontSize == 10 && !validateMenuItem($0)
        } ?? false
        decreaseReaderFontSize(nil)
        let lowerBoundClamps = readerSettings.fontSize == 10
        settingsWindowController?.close()
        commitReaderSettings(originalReaderSettings)

        ReaderSettingsWindowController.selfTestEnableAccessibility()
        let settingsController = ReaderSettingsWindowController(
            settings: legacySettings,
            exactCoordinator: model.exactCoordinator,
            onRevoke: { _ in },
            onChange: { _ in }
        )
        settingsController.window?.setFrameOrigin(
            NSPoint(x: -20_000, y: -20_000)
        )
        settingsController.showWindow(nil)
        pumpRunLoop()
        _ = settingsController.selfTestPressReaderControl("Advanced typography")
        pumpRunLoop()
        let settingsGeometry = settingsController.selfTestVisualControlGeometry
        settingsController.close()
        let visualControlsVisible = settingsGeometry.frames.count == 4
            && settingsGeometry.frames.allSatisfy {
                $0.width > 0 && $0.height > 0
                    && settingsGeometry.visibleFrame.contains($0)
            }
        let visualControlsDoNotOverlap = settingsGeometry.frames.indices.allSatisfy {
            index in
            settingsGeometry.frames.indices.allSatisfy {
                $0 == index
                    || !settingsGeometry.frames[index]
                        .intersects(settingsGeometry.frames[$0])
            }
                && settingsGeometry.existingFrames.allSatisfy {
                    !settingsGeometry.frames[index].intersects($0)
                }
        }
        var checks: [String: Bool] = [
            "rulerExistsByDefault":
                geometryOn.hasRuler && geometryOn.rulerThickness > 0,
            "rulerInsideWindowContent": rulerInsideWindow,
            "readerWidthEqualsContainerMinusRuler": rulerWidthEquation,
            "firstGlyphGapIsReadableWithRuler":
                geometryOn.firstGlyphGap.map { (8...12).contains($0) } ?? false,
            "firstGlyphGapIsReadableWithoutRuler":
                geometryOff.firstGlyphGap.map { (8...12).contains($0) } ?? false,
            "disabledRulerRestoresFullWidth":
                !geometryOff.hasRuler
                && geometryOff.rulerThickness == 0
                && disabledWidthEquation,
            "disabledRulerExpandsReaderByRulerWidth":
                disabledWidthGainEquation,
            "visibleLineNumbersMatchFixture":
                visibleLineNumbers.contains(1)
                && visibleLineNumbers.allSatisfy { (1...3).contains($0) },
            "alphaOccurrenceCountMatches": alphaCount == 3,
            "switchingToBetaReplacesOccurrences": betaCount == 2,
            "currentLineIsExclusive":
                currentLine == 2 && currentLineState == [2],
            "blankClickClearsOccurrences":
                blankCount == 0 && controller.selfTestOccurrenceCount == 0,
            "readerVisualSettingAppliedImmediately":
                visualSettingAppliedImmediately,
            "fontMenuUsesExactKeyEquivalents":
                fontMenuUsesExactKeyEquivalents,
            "fontMenuChangesByOnePoint": fontChangesByOnePoint,
            "fontMenuUpperBoundDisabledAndClamped":
                upperBoundDisablesIncrease && upperBoundClamps,
            "fontMenuLowerBoundDisabledAndClamped":
                lowerBoundDisablesDecrease && lowerBoundClamps,
            "fontMenuPersistsUserDefaults": defaultsRoundTripAfterMenuChange,
            "fontMenuUpdatesFileReaderImmediately":
                fileReaderFontUpdatesImmediately,
            "fontMenuUpdatesOpenSettingsImmediately":
                openSettingsWindowUpdatesImmediately,
            "readerVisualControlsVisibleWithGeometry":
                visualControlsVisible,
            "readerVisualControlsDoNotOverlap":
                visualControlsDoNotOverlap,
        ]
        Self.writeJSON([
            "step": "regular",
            "alphaOccurrences": alphaCount,
            "betaOccurrences": betaCount,
            "currentLine": currentLine ?? -1,
            "visibleLineNumbers": visibleLineNumbers,
            "footprintMB": regularFootprintMB,
            "idleFootprintMB": readingIdleFootprintMB,
            "idleFootprintUnderBudget":
                readingIdleFootprintMB >= 0
                    && readingIdleFootprintMB < SelfTestBudgets.idleFootprintMB,
            "rulerWidth": Double(geometryOn.rulerFrame.width),
            "rulerMinX": Double(geometryOn.rulerFrame.minX),
            "rulerMaxX": Double(geometryOn.rulerFrame.maxX),
            "readerWidth": Double(geometryOn.contentFrame.width),
            "readerMinX": Double(geometryOn.contentFrame.minX),
            "readerMaxX": Double(geometryOn.contentFrame.maxX),
            "firstGlyphGapWithRuler": Double(geometryOn.firstGlyphGap ?? -1),
            "firstGlyphGapWithoutRuler": Double(geometryOff.firstGlyphGap ?? -1),
            "readerWidthWithoutRuler": Double(geometryOff.contentFrame.width),
            "containerWidth": Double(geometryOn.scrollFrame.width),
            "containerMinX": Double(geometryOn.scrollFrame.minX),
            "containerMaxX": Double(geometryOn.scrollFrame.maxX),
            "availableContentWidth":
                Double(
                    geometryOn.clipFrame.width
                        - occupiedRulerWidth
                ),
            "availableContentMinX":
                Double(geometryOn.contentFrame.minX),
            "availableContentMaxX":
                Double(geometryOn.clipFrame.maxX),
        ])

        let referenceFixture = root.appendingPathComponent(
            "target/m6_reference_density.rs"
        )
        let referenceProjectFixture = root.appendingPathComponent(
            "m6_reference_density.rs"
        )
        do {
            try FileManager.default.copyItem(
                at: referenceFixture,
                to: referenceProjectFixture
            )
        } catch {
            finish(
                checks: checks,
                metrics: [:],
                error: "M6 reference scale copy failed: \(error)"
            )
        }
        // Opening the same project now focuses its existing reading session.
        // The fixture added above needs an explicit index refresh instead.
        let beforeReferenceRefresh = model.generation
        controller.refreshProjectIndex(nil)
        guard waitUntil(timeout: 30, condition: {
            if case .failed = self.model.projectState { return true }
            if !self.model.isRefreshingIndex
                && self.model.generation > beforeReferenceRefresh
                && self.model.fileTree != nil
                && self.model.snapshotPhase == .fullReady
            {
                return true
            }
            return false
        }) && model.fileTree != nil
            && model.snapshotPhase == .fullReady
        else {
            finish(
                checks: checks,
                metrics: [:],
                error: "reference fixture project unavailable"
            )
        }
        controller.openFileForSelfTest(regular)
        guard waitUntil(timeout: 5, condition: {
            controller.selfTestLeftReaderBytes == regularBytes
        }) else {
            finish(
                checks: checks,
                metrics: [:],
                error: "reference reader did not reopen"
            )
        }
        let referenceUsesFixture = root.appendingPathComponent(
            "a_reference_use.rs"
        )
        guard let referenceBytes = try? [UInt8](Data(contentsOf: referenceFixture)),
              let referenceProjectBytes = try? [UInt8](
                  Data(contentsOf: referenceProjectFixture)
              ),
              let referenceUsesBytes = try? [UInt8](
                  Data(contentsOf: referenceUsesFixture)
              )
        else {
            finish(
                checks: checks,
                metrics: [:],
                error: "M6 reference scale bytes unavailable"
            )
        }
        guard case let .ready(referenceSession, referenceContext) =
                model.projectState
        else {
            finish(
                checks: checks,
                metrics: [:],
                error: "M6 reference scale session unavailable"
            )
        }
        let regularPathID = referenceSession.manifest.files.first {
            URL(
                fileURLWithPath: referenceSession.paths.resolve($0.pathID)
            ).lastPathComponent == regular.lastPathComponent
        }?.pathID
        guard let referenceSymbol = (try? referenceSession.definitions(
            of: "p0",
            context: referenceContext
        ))?.first(where: { $0.0.pathID == regularPathID })?.0
        else {
            finish(
                checks: checks,
                metrics: [:],
                error: "regular p0 definition unavailable; files="
                    + referenceSession.manifest.files.map {
                        referenceSession.paths.resolve($0.pathID)
                    }.joined(separator: ",")
            )
        }
        guard let referenceFile = referenceSession.manifest.files.first(where: {
                  $0.pathID == referenceSymbol.pathID
              }),
              let referenceIndex = referenceSession.contentIndexes.first(where: {
                  $0.key.contentID == referenceFile.contentID
              })?.value,
              referenceIndex.symbols.indices.contains(
                  Int(referenceSymbol.localIndex)
              )
        else {
            finish(
                checks: checks,
                metrics: [:],
                error: "regular p0 content index unavailable"
            )
        }
        let referenceCandidateNeedle = Data("p0".utf8)
        var referenceCandidateCount = 0
        for candidateBytes in [referenceProjectBytes, referenceUsesBytes] {
            let bytes = Data(candidateBytes)
            var offset = 0
            while offset < bytes.count,
                  let range = bytes.range(
                      of: referenceCandidateNeedle,
                      in: offset..<bytes.count
                  )
            {
                referenceCandidateCount += 1
                offset = range.upperBound
            }
        }
        let referenceDeclarationRange =
            referenceIndex.symbols[Int(referenceSymbol.localIndex)].nameRange
        let referenceScaleBaselineFootprintMB = physicalFootprintBytes().map {
            Double($0) / 1_048_576
        } ?? -1
        var referenceProbe: (
            verifiedCount: Int,
            firstBatchMS: Double,
            totalMS: Double,
            isTruncated: Bool,
            error: String?
        )?
        let referenceProbeStartedAt = ContinuousClock.now
        Task { @MainActor in
            do {
                let stream = try referenceSession.searchReferences(
                    ContentSearchQuery(
                        pattern: "p0",
                        caseSensitive: true
                    ),
                    excludingPathID: referenceSymbol.pathID,
                    excludingRange: referenceDeclarationRange,
                    context: referenceContext
                )
                var verifiedCount = 0
                var firstBatchMS: Double?
                var isTruncated = false
                for try await batch in stream {
                    let count = batch.matchesByPath.values.reduce(0) {
                        $0 + $1.count
                    }
                    if firstBatchMS == nil, count > 0 {
                        firstBatchMS = milliseconds(
                            since: referenceProbeStartedAt
                        )
                    }
                    verifiedCount += count
                    isTruncated =
                        isTruncated || batch.completeness == .truncated
                }
                referenceProbe = (
                    verifiedCount,
                    firstBatchMS ?? -1,
                    milliseconds(since: referenceProbeStartedAt),
                    isTruncated,
                    nil
                )
            } catch {
                referenceProbe = (
                    0,
                    -1,
                    milliseconds(since: referenceProbeStartedAt),
                    false,
                    error.localizedDescription
                )
            }
        }
        guard waitUntil(timeout: 10, condition: { referenceProbe != nil }),
              let referenceProbe,
              referenceProbe.error == nil
        else {
            finish(
                checks: checks,
                metrics: [:],
                error: referenceProbe?.error ?? "reference scale probe timed out"
            )
        }
        let referenceResultStartedAt = ContinuousClock.now
        controller.selfTestReaderRelation(
            offset: referenceDeclarationRange.lowerBound,
            direction: .references
        )
        let referenceDisclosureReady = waitUntil(timeout: 10, condition: {
            controller.selfTestPossibleRelationDisclosureTitle
                == "Show \(referenceProbe.verifiedCount) possible matches"
        })
        let referencePossibleDefaultCollapsed =
            referenceDisclosureReady
            && controller.selfTestVisibleRelationEdgeTitles(
                inGroup: "References"
            ).isEmpty
        let referenceResultVisible =
            referencePossibleDefaultCollapsed
            && controller.selfTestExpandPossibleRelations()
            && waitUntil(timeout: 10, condition: {
                controller.selfTestVisibleRelationEdgeTitles(
                    inGroup: "References"
                ).count == referenceProbe.verifiedCount
            })
        let referenceResultTotalMS = milliseconds(
            since: referenceResultStartedAt
        )
        let referenceVisibleRowCount = controller
            .selfTestVisibleRelationEdgeTitles(inGroup: "References").count
        let referenceFooter = model.relationTree.root?.children?.first {
            $0.kind == .truncated
                && $0.title.hasSuffix("verified references · partial")
        }?.title
        let referenceResultVisibleWithGeometry =
            controller.selfTestReferenceGroupVisibleWithGeometry
        let referenceScaleAfterFootprintMB = physicalFootprintBytes().map {
            Double($0) / 1_048_576
        } ?? -1
        let referenceScaleDeltaFootprintMB =
            referenceScaleAfterFootprintMB
                - referenceScaleBaselineFootprintMB
        let referenceOriginOffset = controller.selfTestReadingByteOffset
        let historyCountBeforeReferenceOpen =
            model.navigationHistory.records.count
        let referenceFirstTitle = controller.selfTestVisibleRelationEdgeTitles(
            inGroup: "References"
        ).first
        let referenceSelected = referenceFirstTitle.map {
            controller.selfTestSelectRelationEdge(titled: $0)
        } == true
        let referenceOpenedCrossFile = referenceSelected
            && waitUntil(timeout: 5, condition: {
                controller.displayedReaderFile?.standardizedFileURL
                    == referenceUsesFixture.standardizedFileURL
            })
        let referenceHistoryRecorded =
            model.navigationHistory.records.count
                > historyCountBeforeReferenceOpen
        if referenceOpenedCrossFile {
            controller.goBack(nil)
        }
        let referenceHistoryBack = referenceOriginOffset.map { origin in
            waitUntil(timeout: 5, condition: {
                controller.displayedReaderFile?.standardizedFileURL
                    == regular.standardizedFileURL
                    && model.selectedByteOffset == origin
            })
        } ?? false
        checks.merge([
            "largeReferenceCandidateCountMeasured":
                referenceCandidateCount == 18_001,
            "largeReferenceVerifiedCountMeasured":
                referenceProbe.verifiedCount == 201,
            "largeReferenceFirstBatchMeasured":
                referenceProbe.firstBatchMS >= 0
                    && referenceProbe.firstBatchMS <= referenceProbe.totalMS,
            "largeReferenceTotalMeasured":
                referenceProbe.totalMS >= 0,
            "largeReferenceRowsVisible":
                referenceResultVisible
                    && referenceVisibleRowCount == referenceProbe.verifiedCount,
            "largeReferencePossibleDefaultCollapsed":
                referencePossibleDefaultCollapsed,
            "largeReferenceServicePartialHonest":
                referenceProbe.isTruncated
                    && referenceFooter
                        == "\(referenceProbe.verifiedCount) "
                            + "verified references · partial"
                    && referenceFooter?.contains("18001") == false,
            "largeReferenceResultVisibleWithGeometry":
                referenceResultVisibleWithGeometry,
            "largeReferenceHistoryRecorded":
                referenceHistoryRecorded,
            "largeReferenceHistoryBack":
                referenceHistoryBack,
        ]) { _, new in new }
        Self.writeJSON([
            "step": "reference-scale",
            "candidateCount": referenceCandidateCount,
            "verifiedCount": referenceProbe.verifiedCount,
            "firstBatchMS": referenceProbe.firstBatchMS,
            "serviceTotalMS": referenceProbe.totalMS,
            "resultTotalMS": referenceResultTotalMS,
            "visibleRowCount": referenceVisibleRowCount,
            "possibleDefaultCollapsed": referencePossibleDefaultCollapsed,
            "serviceTruncated": referenceProbe.isTruncated,
            "footer": referenceFooter ?? "",
            "historyRecorded": referenceHistoryRecorded,
            "historyBack": referenceHistoryBack,
            "baselineFootprintMB": referenceScaleBaselineFootprintMB,
            "afterFootprintMB": referenceScaleAfterFootprintMB,
            "deltaFootprintMB": referenceScaleDeltaFootprintMB,
            "footprintUnderBudget":
                referenceScaleBaselineFootprintMB >= 0
                    && referenceScaleAfterFootprintMB >= 0
                    && referenceScaleDeltaFootprintMB
                        < SelfTestBudgets.largeReferenceDeltaFootprintMB,
        ])

        controller.applyReaderSettings(readerSettings)
        let huge = root.appendingPathComponent("target/huge.rs")
        guard let hugeBytes = try? [UInt8](Data(contentsOf: huge)),
              let needleOffset = Data(hugeBytes).range(
                  of: Data("needle".utf8)
              )?.lowerBound
        else {
            finish(checks: checks, metrics: [:], error: "huge fixture unavailable")
        }
        let hugeOpenedAt = ContinuousClock.now
        controller.openFileForSelfTest(huge)
        guard waitUntil(timeout: 10, condition: {
            controller.selfTestLeftReaderBytes?.count == hugeBytes.count
        }) else {
            finish(checks: checks, metrics: [:], error: "huge reader did not open")
        }
        pumpRunLoop()
        let hugeFirstVisibleMS = milliseconds(since: hugeOpenedAt)
        let hugeBaselineFootprintMB = physicalFootprintBytes().map {
            Double($0) / 1_048_576
        } ?? -1
        guard waitUntil(timeout: 30, condition: {
            controller.selfTestIdentifierPreparationState == .ready
        }) else {
            finish(checks: checks, metrics: [:], error: "huge identifier preparation did not finish")
        }
        let hugeOccurrenceCount = controller.selfTestActivateReading(
            at: UInt32(needleOffset)
        )
        let styledFragments = controller.selfTestStyledFragmentCount
        let hugeVisibleLines = controller.selfTestVisibleLineNumbers.count
        let hugeFootprintMB = physicalFootprintBytes().map {
            Double($0) / 1_048_576
        } ?? -1
        let hugeIncrementalFootprintMB =
            hugeFootprintMB - hugeBaselineFootprintMB
        let hugeLineCount = 100_000
        let expectedHugeOccurrences = 200
        checks.merge([
            "hugeOccurrenceCountMatches":
                hugeOccurrenceCount == expectedHugeOccurrences,
            "styledFragmentsTrackViewport":
                styledFragments > 0
                && styledFragments < SelfTestBudgets.hugeStyledFragments,
            "rulerLinesTrackViewport":
                hugeVisibleLines > 0
                && hugeVisibleLines < SelfTestBudgets.hugeStyledFragments,
            "styledFragmentsDoNotTrackFile":
                styledFragments * 100 < hugeLineCount,
        ]) { _, new in new }
        // phys_footprint is a process-wide net metric. TextKit rendering-cache
        // reclamation can dominate this interval, so it cannot gate S7 cost.
        // The >100 MB absolute baseline predates S7 and is an M7 candidate.
        var metrics = [
            "idleFootprintMB": readingIdleFootprintMB,
            "regularFootprintMB": regularFootprintMB,
            "referenceCandidateCount": Double(referenceCandidateCount),
            "referenceVerifiedCount": Double(referenceProbe.verifiedCount),
            "referenceFirstBatchMS": referenceProbe.firstBatchMS,
            "referenceServiceTotalMS": referenceProbe.totalMS,
            "referenceResultTotalMS": referenceResultTotalMS,
            "referenceVisibleRowCount": Double(referenceVisibleRowCount),
            "referenceScaleBaselineFootprintMB":
                referenceScaleBaselineFootprintMB,
            "referenceScaleAfterFootprintMB":
                referenceScaleAfterFootprintMB,
            "referenceScaleDeltaFootprintMB":
                referenceScaleDeltaFootprintMB,
            "hugeBaselineFootprintMB": hugeBaselineFootprintMB,
            "hugeAfterFootprintMB": hugeFootprintMB,
            "hugeDeltaFootprintMB": hugeIncrementalFootprintMB,
            "hugeLineCount": Double(hugeLineCount),
            "hugeOccurrenceCount": Double(hugeOccurrenceCount),
            "styledFragmentCount": Double(styledFragments),
            "visibleLineCount": Double(hugeVisibleLines),
            "firstVisibleMS": hugeFirstVisibleMS,
        ]
        Self.writeJSON([
            "step": "huge",
            "totalLines": hugeLineCount,
            "occurrences": hugeOccurrenceCount,
            "styledFragments": styledFragments,
            "visibleLines": hugeVisibleLines,
            "firstVisibleMS": hugeFirstVisibleMS,
            "baselineFootprintMB": hugeBaselineFootprintMB,
            "afterFootprintMB": hugeFootprintMB,
            "deltaFootprintMB": hugeIncrementalFootprintMB,
            // Keep the established keys for downstream readers.
            "incrementalFootprintMB": hugeIncrementalFootprintMB,
            "footprintMB": hugeFootprintMB,
            "memoryAssessment":
                "metric-only: TextKit cache reclamation makes the S7 delta "
                + "non-attributable; >100 MB absolute baseline predates S7 "
                + "and is an M7 candidate after attributable measurement",
        ])

        controller.openFileForSelfTest(referenceFixture)
        guard waitUntil(timeout: 30, condition: {
            controller.selfTestLeftReaderBytes?.count == referenceBytes.count
                && controller.selfTestReferenceAttributeRunCount > 0
        }) else {
            finish(
                checks: checks,
                metrics: metrics,
                error: "M6 reference styling did not render"
            )
        }
        pumpRunLoop()
        let referenceRuns = controller.selfTestReferenceAttributeRunCount
        let referenceFragments =
            controller.selfTestReferenceStyledFragmentCount
        let referenceScanned = controller.selfTestReferenceScannedCount

        var syntaxOffSettings = readerSettings
        syntaxOffSettings.syntaxFormatting = false
        controller.applyReaderSettings(syntaxOffSettings)
        pumpRunLoop()
        let referenceRunsWhenOff =
            controller.selfTestReferenceAttributeRunCount
        let referenceFragmentsWhenOff =
            controller.selfTestReferenceStyledFragmentCount
        checks.merge([
            "referenceRunsTrackViewport":
                referenceRuns > 0 && referenceRuns < 350,
            "referenceFragmentsTrackViewport":
                referenceFragments > 0 && referenceFragments < 350,
            "referenceRunsDoNotTrackFile":
                referenceRuns * 100 < 35_000,
            // 工作量门：输出计数会被 fragment 交集过滤，即使 viewport 门控失效
            // 也仍是 51。必须另测"实际扫描到多少候选"才能抓住门控回退。
            "referenceLookupIsViewportGated":
                referenceScanned > 0 && referenceScanned * 50 < 35_000,
            "syntaxFormattingOffSuppressesReferenceRuns":
                referenceRunsWhenOff == 0
                    && referenceFragmentsWhenOff == 0,
        ]) { _, new in new }
        metrics["referenceAttributeRunCount"] = Double(referenceRuns)
        metrics["referenceStyledFragmentCount"] = Double(referenceFragments)
        metrics["referenceScannedCount"] = Double(referenceScanned)
        Self.writeJSON([
            "step": "references",
            "totalReferences": 35_000,
            "referenceAttributeRuns": referenceRuns,
            "referenceStyledFragments": referenceFragments,
            "referenceScannedCount": referenceScanned,
            "referenceAttributeRunsWhenOff": referenceRunsWhenOff,
            "referenceStyledFragmentsWhenOff": referenceFragmentsWhenOff,
        ])
        controller.selfTestNavigate(to: regular, byteOffset: UInt32(alphaOffset))
        pumpRunLoop()
        let primarySelectionRange = controller.selfTestPrimarySelectionRange
        let explicitOutlineRow = controller.selfTestSelectedOutlineRow
        controller.selfTestEmitOutlineFollow(at: UInt32(betaOffset))
        pumpRunLoop()
        let programmaticFollowIsBlocked = explicitOutlineRow >= 0
            && controller.selfTestSelectedOutlineRow == explicitOutlineRow
        controller.selfTestPostLiveScroll()
        pumpRunLoop()
        controller.selfTestEmitOutlineFollow(at: UInt32(betaOffset))
        pumpRunLoop()
        checks.merge([
            "navigationSetsNativePrimarySelection":
                primarySelectionRange?.length == "alpha".utf16.count,
            "programmaticNavigationBlocksViewportFollow":
                programmaticFollowIsBlocked,
            "didLiveScrollResumesViewportFollow":
                controller.selfTestSelectedOutlineRow >= 0
                && controller.selfTestSelectedOutlineRow != explicitOutlineRow,
        ]) { _, new in new }
        finish(checks: checks, metrics: metrics)
    }

    // Pixel-level acceptance for the gutter-aligned vertical line that used to
    // bleed from the reader ruler into the tab strip (macOS 14+ clipsToBounds
    // default change). Opens a real on-screen window, opens one and two tabs,
    // captures the window at native (Retina) resolution, and scans the header
    // band around x == ruler.maxX for a stray vertical line.
    func runGutterLineSelfTest(root: URL) -> Never {
        let channel = "gutterLine"
        launch(offscreen: true)
        guard let controller = windowController,
              let window = controller.window
        else {
            Self.writeJSON(["channel": channel, "error": "window unavailable"])
            Self.exitSelfTest(channel: channel, status: 1)
        }
        controller.applyReaderSettings(ReaderSettings(theme: .light))
        window.setContentSize(NSSize(width: 1_200, height: 800))
        window.setFrameOrigin(NSPoint(x: 80, y: 80))
        window.orderFrontRegardless()
        pumpRunLoop()

        controller.openProject(root: root)
        guard waitUntil(timeout: 60, condition: {
            if case .ready = self.model.projectState { return true }
            return false
        }) else {
            Self.writeJSON(["channel": channel, "error": "project not ready"])
            Self.exitSelfTest(channel: channel, status: 1)
        }

        let fileA = root.appendingPathComponent("tokio/src/lib.rs")
            .standardizedFileURL
        let fileB = root.appendingPathComponent("tokio/src/blocking.rs")
            .standardizedFileURL

        controller.openFileForSelfTest(fileA)
        guard waitUntil(timeout: 15, condition: {
            controller.displayedReaderFile?.standardizedFileURL == fileA
        }) else {
            Self.writeJSON(["channel": channel, "error": "could not open lib.rs"])
            Self.exitSelfTest(channel: channel, status: 1)
        }
        let oneTab = gutterLineScan(
            controller: controller,
            window: window,
            label: "oneTab"
        )

        controller.openFileInNewTabForSelfTest(fileB)
        guard waitUntil(timeout: 15, condition: {
            controller.displayedReaderFile?.standardizedFileURL == fileB
        }) else {
            Self.writeJSON(
                ["channel": channel, "error": "could not open blocking.rs"]
            )
            Self.exitSelfTest(channel: channel, status: 1)
        }
        let twoTabs = gutterLineScan(
            controller: controller,
            window: window,
            label: "twoTabs"
        )

        Self.writeJSON([
            "channel": channel,
            "oneTab": oneTab.json,
            "twoTabs": twoTabs.json,
        ])
        Self.exitSelfTest(
            channel: channel,
            status: oneTab.pass && twoTabs.pass ? 0 : 1
        )
    }

    private func gutterLineScan(
        controller: MainWindowController,
        window: NSWindow,
        label: String
    ) -> (pass: Bool, json: [String: Any]) {
        window.displayIfNeeded()
        for _ in 0..<12 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let reading = controller.selfTestReadingGeometry
        let tabs = controller.selfTestTabGeometry
        guard let contentView = window.contentView,
              let bitmap = cachedBitmap(of: contentView)
        else { return (false, ["error": "window cache failed"]) }
        let frame = contentView.bounds
        let scale = Double(bitmap.pixelsWide) / Double(frame.width)
        let captureDirectory = ProcessInfo.processInfo.environment[
            "CAIRN_GUTTER_CAPTURE_DIR"
        ] ?? "/tmp/cairn-gutter-line"
        try? FileManager.default.createDirectory(
            atPath: captureDirectory,
            withIntermediateDirectories: true
        )
        let pngPath = "\(captureDirectory)/\(label).png"
        try? bitmap.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: pngPath))

        // Window points (bottom-left origin) → image pixels (top-left origin).
        func pixelX(_ x: CGFloat) -> Int { Int((Double(x) * scale).rounded()) }
        func pixelY(_ y: CGFloat) -> Int {
            Int(((Double(frame.height) - Double(y)) * scale).rounded())
        }

        let gutter = contentView.convert(reading.rulerFrame, from: nil)
        let header = contentView.convert(tabs.headerFrame, from: nil)
        let gutterX = gutter.maxX
        let rowStart = max(0, pixelY(header.maxY - 3))
        let rowEnd = min(bitmap.pixelsHigh, pixelY(header.minY + 3))
        let columnStart = max(0, pixelX(gutterX - 8))
        let columnEnd = min(bitmap.pixelsWide, pixelX(gutterX + 8))
        guard rowEnd > rowStart, columnEnd > columnStart else {
            return (false, ["error": "empty scan region", "png": pngPath])
        }

        var brightnessByColumn: [Int: [Double]] = [:]
        var allSamples: [Double] = []
        for px in columnStart..<columnEnd {
            var column: [Double] = []
            for py in rowStart..<rowEnd {
                guard let color = bitmap.colorAt(x: px, y: py)?
                    .usingColorSpace(.sRGB) else { continue }
                let value = Double(color.brightnessComponent)
                column.append(value)
                allSamples.append(value)
            }
            brightnessByColumn[px] = column
        }
        let background = allSamples.sorted()[allSamples.count / 2]
        func coverage(_ px: Int) -> Double {
            guard let column = brightnessByColumn[px], !column.isEmpty else {
                return 0
            }
            let deviant = column.filter { abs($0 - background) > 0.06 }.count
            return Double(deviant) / Double(column.count)
        }
        let lineColumns = (columnStart..<columnEnd).filter { coverage($0) >= 0.7 }
        let lineNumberRGB = ReaderTheme(settings: ReaderSettings(theme: .light))
            .lineNumberRGB(isDark: false)
        let target = (
            red: CGFloat((lineNumberRGB >> 16) & 0xFF) / 255,
            green: CGFloat((lineNumberRGB >> 8) & 0xFF) / 255,
            blue: CGFloat(lineNumberRGB & 0xFF) / 255
        )
        let numberColumnStart = max(0, pixelX(gutter.minX))
        let numberColumnEnd = min(
            bitmap.pixelsWide,
            pixelX(gutter.minX + min(34, reading.rulerThickness))
        )
        let rulerRowStart = max(0, pixelY(gutter.maxY))
        let rulerRowEnd = min(bitmap.pixelsHigh, pixelY(gutter.minY))
        var lineNumberPixelCount = 0
        for px in numberColumnStart..<numberColumnEnd {
            for py in rulerRowStart..<rulerRowEnd {
                guard let color = bitmap.colorAt(x: px, y: py)?
                    .usingColorSpace(.sRGB),
                      abs(color.redComponent - target.red) < 0.12,
                      abs(color.greenComponent - target.green) < 0.12,
                      abs(color.blueComponent - target.blue) < 0.12
                else { continue }
                lineNumberPixelCount += 1
            }
        }
        let lineNumbersVisible = lineNumberPixelCount >= 4
        let json: [String: Any] = [
            "png": pngPath,
            "gutterWindowX": Double(gutterX),
            "rulerThickness": Double(reading.rulerThickness),
            "headerBandWindowY": [Double(header.minY), Double(header.maxY)],
            "scanColumnsPx": [columnStart, columnEnd],
            "scanRowsPx": [rowStart, rowEnd],
            "lineColumnsPx": lineColumns,
            "lineDetected": !lineColumns.isEmpty,
            "lineNumberPixelCount": lineNumberPixelCount,
            "lineNumbersVisible": lineNumbersVisible,
        ]
        return (lineColumns.isEmpty && lineNumbersVisible, json)
    }

    private static func tabGeometryChecks(
        _ geometry: (
            stripFrame: NSRect,
            headerFrame: NSRect,
            controlFrame: NSRect,
            scopeFrame: NSRect,
            readerFrame: NSRect,
            containerFrame: NSRect,
            contentFrame: NSRect,
            stripHidden: Bool,
            scopeHidden: Bool,
            stripHiddenOrHasHiddenAncestor: Bool
        ),
        prefix: String,
        expectsVisibleStrip: Bool
    ) -> [String: Bool] {
        let tolerance: CGFloat = 1
        let contentBounds = geometry.contentFrame.insetBy(
            dx: -tolerance,
            dy: -tolerance
        )
        if expectsVisibleStrip {
            return [
                "\(prefix)StripVisible":
                    !geometry.stripHidden
                    && !geometry.stripHiddenOrHasHiddenAncestor
                    && geometry.stripFrame.width > 0
                    && geometry.stripFrame.height > 0,
                "\(prefix)StripInsideWindowContent":
                    contentBounds.contains(geometry.stripFrame),
                "\(prefix)StripInsideHeader":
                    geometry.headerFrame.insetBy(
                        dx: -tolerance,
                        dy: -tolerance
                    ).contains(geometry.stripFrame),
                "\(prefix)StripSharesReadingHeightRow":
                    abs(geometry.stripFrame.midY - geometry.controlFrame.midY)
                        <= tolerance,
                "\(prefix)StripStopsBeforeReadingHeight":
                    geometry.stripFrame.maxX
                        <= geometry.controlFrame.minX - 10 + tolerance,
                "\(prefix)ReadingHeightRightAligned":
                    abs(
                        geometry.controlFrame.maxX
                            - (geometry.headerFrame.maxX - 13)
                    ) <= tolerance,
                "\(prefix)ReaderFillsContainerHeight":
                    abs(
                        geometry.readerFrame.height
                            - geometry.containerFrame.height
                    ) <= tolerance,
                "\(prefix)ReaderFillsContainerWidth":
                    abs(
                        geometry.readerFrame.width
                            - geometry.containerFrame.width
                    ) <= tolerance,
            ]
        }
        return [
            "\(prefix)StripHidden":
                geometry.stripHidden
                && geometry.stripHiddenOrHasHiddenAncestor,
            "\(prefix)ReaderRestoresFullHeight":
                abs(
                    geometry.readerFrame.height
                        - geometry.containerFrame.height
                ) <= tolerance,
            "\(prefix)ReaderRestoresFullWidth":
                abs(
                    geometry.readerFrame.width
                        - geometry.containerFrame.width
                ) <= tolerance,
            "\(prefix)ReaderRestoresContainerTop":
                abs(
                    geometry.readerFrame.maxY
                        - geometry.containerFrame.maxY
                ) <= tolerance,
            "\(prefix)ReaderRestoresContainerBottom":
                abs(
                    geometry.readerFrame.minY
                        - geometry.containerFrame.minY
                ) <= tolerance,
        ]
    }

    private static func tabGeometryJSON(
        _ geometry: (
            stripFrame: NSRect,
            headerFrame: NSRect,
            controlFrame: NSRect,
            scopeFrame: NSRect,
            readerFrame: NSRect,
            containerFrame: NSRect,
            contentFrame: NSRect,
            stripHidden: Bool,
            scopeHidden: Bool,
            stripHiddenOrHasHiddenAncestor: Bool
        )
    ) -> [String: Double] {
        [
            "stripMinY": geometry.stripFrame.minY,
            "stripMaxY": geometry.stripFrame.maxY,
            "stripWidth": geometry.stripFrame.width,
            "stripHeight": geometry.stripFrame.height,
            "headerMinY": geometry.headerFrame.minY,
            "headerMaxY": geometry.headerFrame.maxY,
            "controlMinX": geometry.controlFrame.minX,
            "controlMaxX": geometry.controlFrame.maxX,
            "scopeHeight": geometry.scopeHidden ? 0 : geometry.scopeFrame.height,
            "readerMinY": geometry.readerFrame.minY,
            "readerMaxY": geometry.readerFrame.maxY,
            "readerWidth": geometry.readerFrame.width,
            "readerHeight": geometry.readerFrame.height,
            "containerWidth": geometry.containerFrame.width,
            "containerHeight": geometry.containerFrame.height,
            "contentWidth": geometry.contentFrame.width,
            "contentHeight": geometry.contentFrame.height,
        ]
    }

    private static func finishTabsSelfTest(
        checks: [String: Bool],
        geometry: [String: Double],
        error: String?
    ) -> Never {
        let passed = error == nil
            && !checks.isEmpty
            && checks.values.allSatisfy { $0 }
        var summary: [String: Any] = checks
        summary["step"] = "summary"
        summary["geometry"] = geometry
        summary["passed"] = passed
        if let error { summary["error"] = error }
        writeJSON(summary)
        exitSelfTest(channel: "tabs", status: passed ? 0 : 1)
    }

    private static func finishReadingSelfTest(
        checks: [String: Bool],
        metrics: [String: Double],
        error: String?
    ) -> Never {
        let passed = error == nil
            && !checks.isEmpty
            && checks.values.allSatisfy { $0 }
        var summary: [String: Any] = checks
        summary["step"] = "summary"
        summary["metrics"] = metrics
        summary["passed"] = passed
        if let error { summary["error"] = error }
        writeJSON(summary)
        exitSelfTest(channel: "reading", status: passed ? 0 : 1)
    }
}

private func makeTabsSelfTestRepository() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "CodeInsightTabsFixture-\(UUID().uuidString)",
        isDirectory: true
    )
    do {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("src"),
            withIntermediateDirectories: true
        )
        try Data(
            "[package]\nname='tabs'\nversion='0.1.0'\nedition='2021'\n".utf8
        ).write(to: root.appendingPathComponent("Cargo.toml"))
        let lines = (0..<240).map {
            String(format: "    let anchor_%03d = %d;", $0, $0)
        }
        let sourceA = (["pub fn a() {"] + lines + ["}"]).joined(separator: "\n")
        try Data(sourceA.utf8).write(
            to: root.appendingPathComponent("src/a.rs")
        )
        try exactSelfTestGit(root, "init", "-q")
        try exactSelfTestGit(root, "config", "user.name", "CodeInsight Tests")
        try exactSelfTestGit(
            root,
            "config",
            "user.email",
            "tests@codeinsight.invalid"
        )
        try exactSelfTestGit(root, "add", "-A")
        try exactSelfTestGit(root, "commit", "-q", "-m", "A only")
        try Data("pub fn b() -> &'static str { \"tab B\" }\n".utf8).write(
            to: root.appendingPathComponent("src/b.rs")
        )
        try exactSelfTestGit(root, "add", "-A")
        try exactSelfTestGit(root, "commit", "-q", "-m", "add B")
        return root
    } catch {
        try? FileManager.default.removeItem(at: root)
        throw error
    }
}

private func makeSearchSelfTestDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodeInsightSearchSelfTest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    var nextMatch = 0
    for fileIndex in 0..<11 {
        let matchCount = fileIndex < 10 ? 182 : 181
        var source = ""
        for _ in 0..<matchCount {
            source += "fn item_\(nextMatch)() { let zzqqmarker = \(nextMatch); }\n"
            nextMatch += 1
        }
        try Data(source.utf8).write(
            to: root.appendingPathComponent("fixture_\(fileIndex).rs")
        )
    }
    precondition(nextMatch == 2_001)
    return root
}

private func makeReadingSelfTestDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "CodeInsightReadingFixture-\(UUID().uuidString)",
        isDirectory: true
    )
    do {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try Data("""
            [package]
            name = "reading-self-test"
            version = "0.1.0"
            edition = "2021"
            """.utf8).write(to: root.appendingPathComponent("Cargo.toml"))
        try Data("""
            fn alpha() {}
            fn beta() { alpha(); }
            fn gamma() { alpha(); beta(); } fn p0() {}
            """.utf8).write(to: root.appendingPathComponent("regular.rs"))
        let huge = String(repeating: "needle\n", count: 200)
            + String(repeating: "\n", count: 99_799)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("target"),
            withIntermediateDirectories: true
        )
        try Data(huge.utf8).write(
            to: root.appendingPathComponent("target/huge.rs")
        )
        let referenceFixture = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath
        ).appendingPathComponent("Tests/Fixtures/m6_reference_density.rust")
        try FileManager.default.copyItem(
            at: referenceFixture,
            to: root.appendingPathComponent("target/m6_reference_density.rs")
        )
        try Data("fn use_reference() { p0(); }\n".utf8).write(
            to: root.appendingPathComponent("a_reference_use.rs")
        )
        return root
    } catch {
        try? FileManager.default.removeItem(at: root)
        throw error
    }
}
