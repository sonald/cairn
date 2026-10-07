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
    func runProjectSelfTest(root: URL) {
        launch(offscreen: true)
        let projectStartedAt = ContinuousClock.now
        windowController?.openProject(root: root)
        let filesLoadingPlaceholderVisibleDuringIndexing =
            windowController?.selfTestFilesPlaceholderVisible == true
            && windowController?.selfTestFilesPlaceholderText == "Loading files…"
        let filesSpinnerVisibleDuringIndexing =
            windowController?.selfTestFilesLoadingIndicatorVisible == true
        var indexStatusVisibleDuringIndexing = false
        var indexStatusTextDuringIndexing = ""
        func recordIndexStatus() {
            guard let windowController,
                  windowController.selfTestIndexStatusVisible,
                  windowController.selfTestIndexStatusText.contains("Files")
            else { return }
            indexStatusVisibleDuringIndexing = true
            indexStatusTextDuringIndexing = windowController.selfTestIndexStatusText
        }
        recordIndexStatus()
        let deadline = Date(timeIntervalSinceNow: 30)
        while model.fileTree == nil, Date() < deadline {
            if case .failed = model.projectState { break }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
            recordIndexStatus()
        }
        let treeVisibleMS = milliseconds(since: projectStartedAt)
        let fileCount = model.fileTree?.fileCount ?? 0
        var ready = false
        var reused = 0
        var extracted = 0
        while Date() < deadline {
            switch model.projectState {
            case let .ready(session, _):
                ready = true
                reused = session.stats.reusedCount
                extracted = session.stats.extractedCount
            case .failed:
                Self.finishProjectSelfTest(
                    treeVisibleMS: treeVisibleMS,
                    indexReadyMS: milliseconds(since: projectStartedAt),
                    fileCount: fileCount,
                    reused: reused,
                    extracted: extracted,
                    ready: false,
                    emptyStateRemoved: false,
                    readerDocumentVisible: false
                )
            default:
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
                recordIndexStatus()
            }
            if ready { break }
        }
        let indexReadyMS = milliseconds(since: projectStartedAt)
        _ = waitUntil(timeout: 5) { !self.model.commitPicker.isLoading }
        windowController?.window?.contentView?.layoutSubtreeIfNeeded()
        let emptyStateRemoved = windowController?.selfTestEmptyStateExists == false
        let readerDocumentVisible = windowController?
            .selfTestReaderDocumentVisibleInWindow == true
        let statusBarVisibleAfterReady = waitUntil(timeout: 5) {
            self.windowController?.selfTestStatusBarVisible == true
        }
        let indexStatusHiddenAfterFullReady = waitUntil(timeout: 5) {
            self.windowController?.selfTestIndexStatusVisible == false
        }
        let filesPlaceholderHiddenAfterReady =
            windowController?.selfTestFilesPlaceholderVisible == false
            && windowController?.selfTestFilesContentVisible == true
        let outlinePlaceholderVisibleWithoutFile =
            windowController?.selfTestOutlinePlaceholderVisible == true
            && windowController?.selfTestOutlinePlaceholderText == "No file open"

        let loader = DocumentLoader()
        let outlineEmptyFile = rustFiles(in: model.fileTree?.children ?? []).first {
            guard let loaded = try? loader.load(file: $0) else { return false }
            return loaded.tier == .regular
                && loaded.document.outlineFacets.isEmpty
        }
        let outlineNoSymbolsPlaceholderVisible: Bool?
        if let outlineEmptyFile,
           windowController?.selectFileInSidebar(outlineEmptyFile) == true,
           waitUntil(timeout: 5, condition: {
               self.windowController?.displayedReaderFile?.standardizedFileURL
                   == outlineEmptyFile.standardizedFileURL
           })
        {
            outlineNoSymbolsPlaceholderVisible = waitUntil(timeout: 5) {
                self.windowController?.selfTestOutlinePlaceholderVisible == true
                    && self.windowController?.selfTestOutlinePlaceholderText
                        == "No symbols in this file"
            }
        } else {
            outlineNoSymbolsPlaceholderVisible = nil
        }
        let outlineFile = rustFiles(in: model.fileTree?.children ?? []).first {
            guard let loaded = try? loader.load(file: $0) else { return false }
            return !loaded.document.outlineFacets.isEmpty
        }
        let outlinePlaceholderHiddenWithContent: Bool
        if let outlineFile,
           windowController?.selectFileInSidebar(outlineFile) == true,
           waitUntil(timeout: 5, condition: {
               self.windowController?.displayedReaderFile?.standardizedFileURL
                   == outlineFile.standardizedFileURL
           })
        {
            outlinePlaceholderHiddenWithContent = waitUntil(timeout: 5) {
                self.windowController?.selfTestOutlinePlaceholderVisible == false
                    && self.windowController?.selfTestOutlineContentVisible == true
            }
        } else {
            outlinePlaceholderHiddenWithContent = false
        }
        let layout = windowController.map {
            enlargedWindowLayout(controller: $0, statusBarOccupancyHeight: 24)
        }
        let branchName = currentBranchName(repositoryURL: root)
        let commitTitle = windowController?.selfTestCommitButtonTitle ?? ""
        let commitTitleMatchesRepository: Bool
        if (try? GitRepository(url: root)) != nil {
            commitTitleMatchesRepository = branchName.map {
                commitTitle.hasPrefix("⎇ ") && commitTitle.contains($0)
            } == true
        } else {
            commitTitleMatchesRepository = commitTitle == "Working Tree"
                && !commitTitle.contains("⎇")
        }
        let commitPickerShowsCurrentBranch = commitTitleMatchesRepository
            && windowController?.selfTestCommitToolbarItemExistsAndVisible == true
        var projectChecks = layout?.checks ?? [:]
        projectChecks.merge([
            "filesLoadingPlaceholderVisibleDuringIndexing":
                filesLoadingPlaceholderVisibleDuringIndexing,
            "filesSpinnerVisibleDuringIndexing":
                filesSpinnerVisibleDuringIndexing,
            "filesPlaceholderHiddenAfterReady":
                filesPlaceholderHiddenAfterReady,
            "outlinePlaceholderVisibleWithoutFile":
                outlinePlaceholderVisibleWithoutFile,
            "outlinePlaceholderHiddenWithContent":
                outlinePlaceholderHiddenWithContent,
        ]) { _, new in new }
        if let outlineNoSymbolsPlaceholderVisible {
            projectChecks["outlineNoSymbolsPlaceholderVisible"] =
                outlineNoSymbolsPlaceholderVisible
        }
        model.flushPersistentIndexCache()
        Self.finishProjectSelfTest(
            treeVisibleMS: treeVisibleMS,
            indexReadyMS: indexReadyMS,
            fileCount: fileCount,
            reused: reused,
            extracted: extracted,
            ready: ready,
            emptyStateRemoved: emptyStateRemoved,
            readerDocumentVisible: readerDocumentVisible,
            branchName: branchName,
            commitTitle: commitTitle,
            commitPickerShowsCurrentBranch: commitPickerShowsCurrentBranch,
            indexStatusVisibleDuringIndexing: indexStatusVisibleDuringIndexing,
            indexStatusTextDuringIndexing: indexStatusTextDuringIndexing,
            statusBarVisibleAfterReady: statusBarVisibleAfterReady,
            indexStatusHiddenAfterFullReady: indexStatusHiddenAfterFullReady,
            layoutChecks: projectChecks,
            enlargedWindowGeometry: layout?.geometry ?? [:]
        )
    }

    func runHistorySelfTest(root: URL) -> Never {
        launch(offscreen: true)
        guard let windowController else {
            Self.finishHistorySelfTest(
                selectionSynchronized: false,
                switchEnteredHistory: false,
                navigationSequence: false,
                error: "window unavailable"
            )
        }

        windowController.openProject(root: root)
        guard waitUntil(timeout: 30, condition: {
            if case .failed = self.model.projectState { return true }
            if case .ready = self.model.projectState {
                return !self.model.commitPicker.isLoading
            }
            return false
        }),
        case .ready = model.projectState,
        model.commitPicker.errorMessage == nil
        else {
            Self.finishHistorySelfTest(
                selectionSynchronized: false,
                switchEnteredHistory: false,
                navigationSequence: false,
                error: "project or commit history unavailable"
            )
        }

        var selectionSynchronized = emitHistoryStep(
            "openProject",
            controller: windowController
        )
        guard let fileA = rustFiles(in: model.fileTree?.children ?? []).first,
              waitUntil(timeout: 5, condition: {
                  windowController.selectFileInSidebar(fileA)
              }),
              waitUntil(timeout: 5, condition: {
                  self.model.selectedFile == fileA
                      && windowController.displayedReaderFile == fileA
              })
        else {
            Self.finishHistorySelfTest(
                selectionSynchronized: false,
                switchEnteredHistory: false,
                navigationSequence: false,
                error: "could not open file A through the sidebar"
            )
        }
        selectionSynchronized = emitHistoryStep(
            "openA",
            controller: windowController
        ) && selectionSynchronized

        guard model.commitPicker.commits.indices.contains(1) else {
            Self.finishHistorySelfTest(
                selectionSynchronized: selectionSynchronized,
                switchEnteredHistory: false,
                navigationSequence: false,
                error: "HEAD~1 unavailable"
            )
        }
        let previousRevision = model.commitPicker.commits[1].fullSHA
        guard windowController.selectCommit(previousRevision),
              waitUntil(timeout: 30, condition: {
                  self.model.currentRevision == previousRevision
                      && self.model.snapshotPhase == .fullReady
              })
        else {
            Self.finishHistorySelfTest(
                selectionSynchronized: selectionSynchronized,
                switchEnteredHistory: false,
                navigationSequence: false,
                error: "commit switch did not complete"
            )
        }
        pumpRunLoop()
        let switchEnteredHistory = model.navigationHistory.canGoBack
        selectionSynchronized = emitHistoryStep(
            "switchHEAD~1",
            controller: windowController
        ) && selectionSynchronized

        guard let fileB = rustFiles(in: model.fileTree?.children ?? []).first(where: {
            $0.standardizedFileURL != fileA.standardizedFileURL
        }),
        windowController.selectFileInSidebar(fileB),
        waitUntil(timeout: 5, condition: {
            self.model.selectedFile == fileB
                && windowController.displayedReaderFile == fileB
        })
        else {
            Self.finishHistorySelfTest(
                selectionSynchronized: false,
                switchEnteredHistory: switchEnteredHistory,
                navigationSequence: false,
                error: "could not open file B through the sidebar"
            )
        }
        selectionSynchronized = emitHistoryStep(
            "openB",
            controller: windowController
        ) && selectionSynchronized

        var navigationSequence = historyStateMatches(
            revision: previousRevision,
            file: fileB,
            controller: windowController
        )
        navigationSequence = performHistoryNavigation(
            { windowController.goBack(nil) },
            revision: previousRevision,
            file: fileA
        ) && navigationSequence
        selectionSynchronized = emitHistoryStep(
            "back1",
            controller: windowController
        ) && selectionSynchronized
        navigationSequence = performHistoryNavigation(
            { windowController.goBack(nil) },
            revision: nil,
            file: fileA
        ) && navigationSequence
        selectionSynchronized = emitHistoryStep(
            "back2",
            controller: windowController
        ) && selectionSynchronized
        navigationSequence = performHistoryNavigation(
            { windowController.goForward(nil) },
            revision: previousRevision,
            file: fileA
        ) && navigationSequence
        selectionSynchronized = emitHistoryStep(
            "forward1",
            controller: windowController
        ) && selectionSynchronized
        navigationSequence = performHistoryNavigation(
            { windowController.goForward(nil) },
            revision: previousRevision,
            file: fileB
        ) && navigationSequence
        selectionSynchronized = emitHistoryStep(
            "forward2",
            controller: windowController
        ) && selectionSynchronized

        Self.finishHistorySelfTest(
            selectionSynchronized: selectionSynchronized,
            switchEnteredHistory: switchEnteredHistory,
            navigationSequence: navigationSequence,
            error: nil
        )
    }

    func runPinSelfTest(root: URL) -> Never {
        launch(offscreen: true)
        guard let windowController else {
            finishPinSelfTest(controller: nil, error: "window unavailable")
        }

        windowController.openProject(root: root)
        guard waitUntil(timeout: 30, condition: {
            if case .failed = self.model.projectState { return true }
            if case .ready = self.model.projectState { return true }
            return false
        }), case .ready = model.projectState
        else {
            finishPinSelfTest(
                controller: windowController,
                error: "project unavailable"
            )
        }

        let files = rustFiles(in: model.fileTree?.children ?? [])
        let fixture = root.standardizedFileURL.appendingPathComponent(
            "Tests/RustExtractorTests/Fixtures/alias_cross_file_negative",
            isDirectory: true
        )
        let expectedFiles = ["a.rs", "b.rs", "main.rs"].map {
            fixture.appendingPathComponent($0).standardizedFileURL
        }
        let fileA = expectedFiles[0]
        let fileB = expectedFiles[1]
        let mainFile = expectedFiles[2]
        guard expectedFiles.allSatisfy(files.contains),
              let aBytes = try? Data(contentsOf: fileA),
              let bBytes = try? Data(contentsOf: fileB),
              let mainBytes = try? Data(contentsOf: mainFile),
              let realRange = aBytes.range(of: Data("real".utf8)),
              let localCallRange = bBytes.range(of: Data("y();".utf8)),
              let callerRange = bBytes.range(of: Data("call_local".utf8)),
              let mainCallRange = mainBytes.range(of: Data("y();".utf8)),
              let realOffset = UInt32(exactly: realRange.lowerBound),
              let localCallOffset = UInt32(exactly: localCallRange.lowerBound),
              let callerOffset = UInt32(exactly: callerRange.lowerBound),
              let mainCallOffset = UInt32(exactly: mainCallRange.lowerBound)
        else {
            finishPinSelfTest(
                controller: windowController,
                error: "expected a.rs, b.rs, and main.rs fixture symbols"
            )
        }

        guard waitUntil(timeout: 5, condition: {
                  windowController.selectFileInSidebar(fileB)
              }),
              waitUntil(timeout: 5, condition: {
                  windowController.displayedReaderFile?.standardizedFileURL
                      == fileB.standardizedFileURL
              })
        else {
            finishPinSelfTest(
                controller: windowController,
                error: "could not open b.rs"
            )
        }
        windowController.selfTestReaderClick(
            offset: localCallOffset,
            commandClick: false
        )
        guard waitUntil(timeout: 5, condition: {
                  self.pinContextSummary != nil
                      && !windowController.selfTestContextPlaceholderVisible
                      && windowController.selfTestContextReaderVisible
              }),
              let initialContext = pinContextSummary
        else {
            finishPinSelfTest(
                controller: windowController,
                error: "initial context did not load"
            )
        }
        let contextPlaceholderHiddenWithContent =
            !windowController.selfTestContextPlaceholderVisible
            && windowController.selfTestContextReaderVisible
        emitPinStep(
            "contextLoaded",
            controller: windowController,
            extra: [
                "contextPlaceholderHiddenWithContent":
                    contextPlaceholderHiddenWithContent,
            ]
        )

        let relationBeforeFollow = pinRelationRootSummary
        windowController.selfTestReaderRelation(
            offset: callerOffset,
            direction: .callers
        )
        let followRelationSet = waitUntil(timeout: 5, condition: {
            self.pinRelationRootSummary != relationBeforeFollow
                && self.pinRelationRootSummary != nil
        })
        pumpRunLoop()
        windowController.applyPanelPreset(.relations)
        let relationsPlaceholderHiddenWithRoot = waitUntil(timeout: 5, condition: {
            !windowController.selfTestRelationsPlaceholderVisible
                && windowController.selfTestRelationsTreeVisible
        })
        windowController.applyPanelPreset(.reading)
        pumpRunLoop()
        let followRelationPreservedContext = pinContextSummary == initialContext
        emitPinStep(
            "followShowCallers",
            controller: windowController,
            extra: [
                "relationRootSet": followRelationSet,
                "contextPreserved": followRelationPreservedContext,
                "relationsPlaceholderHiddenWithRoot":
                    relationsPlaceholderHiddenWithRoot,
            ]
        )

        guard windowController.selectFileInSidebar(mainFile),
              waitUntil(timeout: 5, condition: {
                  windowController.displayedReaderFile?.standardizedFileURL
                      == mainFile.standardizedFileURL
              })
        else {
            finishPinSelfTest(
                controller: windowController,
                error: "could not open main.rs"
            )
        }
        windowController.selfTestSetContextPinned(true)
        let pinnedContext = pinContextSummary
        let readerBeforeCommandClick = windowController.displayedReaderFile
        windowController.selfTestReaderClick(
            offset: mainCallOffset,
            commandClick: true
        )
        let commandClickNavigated = waitUntil(timeout: 5, condition: {
            windowController.displayedReaderFile?.standardizedFileURL
                == fileA.standardizedFileURL
        }) && readerBeforeCommandClick?.standardizedFileURL
            != windowController.displayedReaderFile?.standardizedFileURL
        pumpRunLoop()
        let commandClickPreservedContext = pinContextSummary == pinnedContext
        emitPinStep(
            "pinnedCommandClick",
            controller: windowController,
            extra: [
                "readerChanged": commandClickNavigated,
                "contextPreserved": commandClickPreservedContext,
            ]
        )

        let relationBeforePinned = pinRelationRootSummary
        windowController.selfTestReaderRelation(
            offset: realOffset,
            direction: .callers
        )
        let pinnedRelationChanged = waitUntil(timeout: 5, condition: {
            self.pinRelationRootSummary != relationBeforePinned
                && self.pinRelationRootSummary != nil
        })
        pumpRunLoop()
        let pinnedRelationPreservedContext = pinContextSummary == pinnedContext
        emitPinStep(
            "pinnedShowCallers",
            controller: windowController,
            extra: [
                "relationRootChanged": pinnedRelationChanged,
                "contextPreserved": pinnedRelationPreservedContext,
            ]
        )

        windowController.selfTestSetContextPinned(false)
        windowController.selfTestReaderClick(offset: realOffset, commandClick: false)
        let followUpdatedContext = waitUntil(timeout: 5, condition: {
            self.pinContextSummary != nil && self.pinContextSummary != pinnedContext
        })
        pumpRunLoop()
        emitPinStep(
            "followClick",
            controller: windowController,
            extra: ["contextChanged": followUpdatedContext]
        )

        finishPinSelfTest(
            controller: windowController,
            checks: [
                "initialContextLoaded": true,
                "contextPlaceholderHiddenWithContent":
                    contextPlaceholderHiddenWithContent,
                "relationsPlaceholderHiddenWithRoot":
                    relationsPlaceholderHiddenWithRoot,
                "followRelationSet": followRelationSet,
                "followRelationPreservedContext": followRelationPreservedContext,
                "commandClickNavigated": commandClickNavigated,
                "commandClickPreservedContext": commandClickPreservedContext,
                "pinnedRelationChanged": pinnedRelationChanged,
                "pinnedRelationPreservedContext": pinnedRelationPreservedContext,
                "followUpdatedContext": followUpdatedContext,
            ]
        )
    }

    private func performHistoryNavigation(
        _ action: () -> Void,
        revision: String?,
        file: URL
    ) -> Bool {
        guard let windowController else { return false }
        let cursor = model.navigationHistory.cursor
        action()
        pumpRunLoop()
        guard waitUntil(timeout: 30, condition: {
            self.model.navigationHistory.cursor != cursor
                && self.model.currentRevision == revision
                && self.model.selectedFile == file
                && self.model.snapshotPhase == .fullReady
        }) else { return false }
        pumpRunLoop()
        return historyStateMatches(
            revision: revision,
            file: file,
            controller: windowController
        )
    }

    private func historyStateMatches(
        revision: String?,
        file: URL,
        controller: MainWindowController
    ) -> Bool {
        model.currentRevision == revision
            && controller.displayedReaderFile?.standardizedFileURL
                == file.standardizedFileURL
    }

    @discardableResult
    private func emitHistoryStep(
        _ step: String,
        controller: MainWindowController
    ) -> Bool {
        let readerFile = controller.displayedReaderFile
        let treeFile = controller.selectedSidebarFile
        Self.writeJSON([
            "step": step,
            "snapshotShort": model.currentRevision.map { String($0.prefix(7)) }
                ?? "worktree",
            "readerFile": (readerFile?.lastPathComponent as Any?) ?? NSNull(),
            "treeSelectedFile": (treeFile?.lastPathComponent as Any?) ?? NSNull(),
            "canGoBack": model.navigationHistory.canGoBack,
            "canGoForward": model.navigationHistory.canGoForward,
            "historyCount": model.navigationHistory.records.count,
            "readerHasReadingPosition": controller.readerHasReadingPosition,
        ])
        return readerFile?.standardizedFileURL == treeFile?.standardizedFileURL
    }

    private var pinContextSummary: String? {
        model.contextWindow.displayedCandidate.map { "\($0.path):\($0.line)" }
    }

    private var pinRelationRootSummary: String? {
        guard let root = model.relationTree.root else { return nil }
        if let target = root.target {
            return "\(root.title) \(target.path):\(root.line ?? 0)"
        }
        return root.title
    }

    private func emitPinStep(
        _ step: String,
        controller: MainWindowController?,
        extra: [String: Any] = [:]
    ) {
        var object: [String: Any] = [
            "step": step,
            "readerFile": (controller?.displayedReaderFile?.lastPathComponent as Any?)
                ?? NSNull(),
            "contextSummary": (pinContextSummary as Any?) ?? NSNull(),
            "relationRootSummary": (pinRelationRootSummary as Any?) ?? NSNull(),
            "pinned": model.contextWindow.mode == .pinned,
        ]
        for (key, value) in extra { object[key] = value }
        Self.writeJSON(object)
    }

    private func finishPinSelfTest(
        controller: MainWindowController?,
        checks: [String: Bool] = [:],
        error: String? = nil
    ) -> Never {
        let passed = error == nil
            && !checks.isEmpty
            && checks.values.allSatisfy { $0 }
        var summary: [String: Any] = checks
        summary["passed"] = passed
        if let error { summary["error"] = error }
        emitPinStep("summary", controller: controller, extra: summary)
        Self.exitSelfTest(channel: "pin", status: passed ? 0 : 1)
    }

    /// Reading-session acceptance, first process: builds a real reading
    /// scene (tabs, preview-free strip, semantic trail with a sibling
    /// branch, back/forward state, reading position) against the real
    /// project-open entry, checkpoints it, and records expectations for
    /// the restart process. All state goes through the env-provided
    /// isolated session URL and defaults suite.
    func runSessionSelfTest(root: URL) -> Never {
        let channel = "session"
        launch(offscreen: false)
        guard let controller = windowController,
              let window = controller.window
        else {
            Self.writeJSON(["channel": channel, "passed": false, "error": "window unavailable"])
            Self.exitSelfTest(channel: channel, status: 1)
        }
        window.setContentSize(NSSize(width: 1_200, height: 800))
        window.orderFrontRegardless()
        controller.openProject(root: root)
        guard waitUntil(timeout: 90, condition: {
            if case .ready = self.model.projectState { return true }
            return false
        }), model.projectRoot?.standardizedFileURL == root.standardizedFileURL
        else {
            Self.writeJSON(["channel": channel, "passed": false, "error": "project not ready"])
            Self.exitSelfTest(channel: channel, status: 1)
        }
        let main = root.appendingPathComponent("main.rs")
        let other = root.appendingPathComponent("other.rs")
        let third = root.appendingPathComponent("third.rs")
        controller.openFileInNewTabForSelfTest(main)
        controller.openFileInNewTabForSelfTest(other)
        controller.openFileInNewTabForSelfTest(third)
        guard waitUntil(timeout: 15, condition: {
            self.model.tabStrip.tabs.count == 3
        }) else {
            Self.writeJSON(["channel": channel, "passed": false, "error": "tabs unavailable"])
            Self.exitSelfTest(channel: channel, status: 1)
        }
        // Trail with a sibling branch: main → other, back to main, main →
        // third. Explicit semantic requests so the shared pipeline records
        // both history and trail.
        func jump(_ file: URL, offset: UInt32) -> JumpRecord {
            JumpRecord(
                path: file.lastPathComponent,
                contentID: nil,
                byteOffset: offset,
                line: 1,
                column: offset + 1,
                symbolAnchor: nil,
                snapshotID: model.currentSnapshotID,
                revision: model.currentRevision
            )
        }
        func semantic(_ file: URL, offset: UInt32, leaving: JumpRecord?) {
            model.navigate(
                NavigationRequest(
                    destination: SourceDestination(file: file, byteOffset: offset),
                    cause: .relation,
                    policy: .explicitSemantic
                ),
                leaving: leaving
            )
        }
        semantic(other, offset: 0, leaving: jump(main, offset: 0))
        model.goBack(from: jump(other, offset: 0))
        guard waitUntil(timeout: 10, condition: {
            self.model.readingTrail.edges.count == 1
                && self.model.navigationHistory.canGoForward
                // Wait for the back's replay to publish before the next
                // navigation, so the two never race for the active tab.
                && self.model.activeNavigationRequest?.destination.file
                    .standardizedFileURL == main.standardizedFileURL
        }) else {
            Self.writeJSON([
                "channel": channel,
                "passed": false,
                "error": "back unavailable",
            ] as [String: Any])
            Self.exitSelfTest(channel: channel, status: 1)
        }
        semantic(third, offset: 0, leaving: jump(main, offset: 0))
        guard waitUntil(timeout: 15, condition: {
            controller.displayedReaderFile?.standardizedFileURL
                == third.standardizedFileURL
                && self.model.tabStrip.activeDocument != nil
        }) else {
            Self.writeJSON([
                "channel": channel,
                "passed": false,
                "error": "reader unavailable",
                "displayed": controller.displayedReaderFile?.path ?? "",
                "activeTab": controller.selfTestActiveTabFile?.path ?? "",
                "activeDocument": self.model.tabStrip.activeDocument == nil,
                "lastRequest": self.model.activeNavigationRequest?.destination.file
                    .lastPathComponent ?? "",
                "tabs": self.model.tabStrip.tabs.map {
                    $0.fileURL?.lastPathComponent ?? ""
                },
                "activeIndex": self.model.tabStrip.activeIndex ?? -1,
                "trailEdges": self.model.readingTrail.edges.count,
            ] as [String: Any])
            Self.exitSelfTest(channel: channel, status: 1)
        }
        // Choose a real line in the middle of the fixture, far from the
        // top of the viewport. Do not checkpoint here: normal termination
        // must capture the final Reader position before debounce fires.
        let bytes = (try? Data(contentsOf: third)).map(Array.init) ?? []
        let lineStart = bytes.indices.first { $0 > bytes.count / 2 && bytes[$0 - 1] == 10 } ?? 0
        let selection = UInt32(min(lineStart + 4, max(0, bytes.count - 1)))
        controller.setReadingPositionForSelfTest(
            scrollByteOffset: UInt32(lineStart), selectionByteOffset: selection
        )
        guard waitUntil(timeout: 10, condition: {
            controller.selfTestReaderCaretByteOffset == selection
                && controller.selfTestReadingByteOffset != nil
        }) else { Self.exitSelfTest(channel: channel, status: 1) }

        let tabs = model.tabStrip.tabs
        let expectations: [String: Any] = [
            "root": root.standardizedFileURL.path,
            "tabPaths": tabs.map { $0.fileURL?.lastPathComponent ?? "" },
            "activeIndex": model.tabStrip.activeIndex ?? -1,
            "scrollAnchor": controller.selfTestReadingByteOffset ?? UInt32.max,
            "selectionAnchor": controller.selfTestReaderCaretByteOffset ?? UInt32.max,
            "trailNodeIDs": model.readingTrail.orderedNodes().map { $0.id.rawValue.uuidString },
            "trailEdges": model.readingTrail.edges.map { [$0.from.rawValue.uuidString, $0.to.rawValue.uuidString] },
            "trailActiveID": model.readingTrail.activeNodeID?.rawValue.uuidString ?? "",
            "historyCursor": model.navigationHistory.cursor,
            "historyRecords": model.navigationHistory.records.count,
            "canGoBack": model.navigationHistory.canGoBack,
            "canGoForward": model.navigationHistory.canGoForward,
        ]
        writeSessionSelfTestExpectations(expectations)
        guard tabs.count == 3, model.readingTrail.edges.count == 2 else {
            Self.exitSelfTest(channel: channel, status: 1)
        }
        Self.writeJSON(["channel": channel, "passed": true, "expectations": expectations])
        NSApplication.shared.terminate(nil)
        fatalError("Session self-test termination was cancelled")
    }

    /// Multi-window acceptance (§3.1/§3.2/§7.1): two isolated projects in
    /// two windows with two models; duplicate and alias requests activate
    /// instead of duplicating; closing one window keeps the other working.
    /// Runs entirely offscreen against an isolated session store wired by
    /// the `--self-test-multiwindow` entry point.
    func runMultiWindowSelfTest() -> Never {
        let channel = "multiwindow"

        func fail(_ error: String) -> Never {
            Self.writeJSON([
                "channel": channel, "passed": false, "error": error,
            ] as [String: Any])
            Self.exitSelfTest(channel: channel, status: 1)
        }

        func makeProject(_ files: [String: String]) -> URL? {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "CodeInsightMultiWindow-\(UUID().uuidString)",
                    isDirectory: true
                )
            do {
                try FileManager.default.createDirectory(
                    at: root,
                    withIntermediateDirectories: true
                )
                for (path, contents) in files {
                    let file = root.appendingPathComponent(path)
                    try FileManager.default.createDirectory(
                        at: file.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try contents.write(
                        to: file,
                        atomically: true,
                        encoding: .utf8
                    )
                }
                for arguments in [
                    ["init", "-q"],
                    ["config", "user.name", "CodeInsight Tests"],
                    ["config", "user.email", "tests@codeinsight.invalid"],
                    ["add", "-A"],
                    ["commit", "-q", "-m", "fixture"],
                ] {
                    let process = Process()
                    process.currentDirectoryURL = root
                    process.executableURL = URL(
                        fileURLWithPath: "/usr/bin/git"
                    )
                    process.arguments = arguments
                    try process.run()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else { return nil }
                }
                return root
            } catch {
                try? FileManager.default.removeItem(at: root)
                return nil
            }
        }

        guard let projectA = makeProject([
            "src/lib.rs": "pub fn alpha() {}\n",
            "src/main.rs": "fn main() { crate::alpha(); }\n",
        ]) else { return fail("project A fixture unavailable") }
        guard let projectB = makeProject([
            "src/lib.rs": "pub fn beta() {}\n",
        ]) else { return fail("project B fixture unavailable") }

        launch(offscreen: true)
        // Pre-record language preferences so the open pipeline never shows
        // the modal language picker inside the self-test.
        recentProjectsStore.record(projectA, language: .rust)
        recentProjectsStore.record(projectB, language: .rust)

        enqueueOpenRequest(
            root: projectA,
            languages: nil,
            sourceWindow: nil
        )
        guard waitUntil(timeout: 60, condition: {
            self.projectWindows.first?.model.projectState
                .isReadyForMultiWindowSelfTest == true
        }) else { return fail("project A never became ready") }

        // A second request plus an alias of the first, submitted together:
        // the alias activates A's window; B gets a new one (§3.1).
        let alias = URL(
            fileURLWithPath: projectA.path + "/.",
            isDirectory: true
        )
        enqueueOpenRequest(root: alias, languages: nil, sourceWindow: nil)
        enqueueOpenRequest(
            root: projectB,
            languages: nil,
            sourceWindow: nil
        )
        guard waitUntil(timeout: 60, condition: {
            self.projectWindows.count == 2
                && self.projectWindows.last?.model.projectState
                    .isReadyForMultiWindowSelfTest == true
        }) else { return fail("project B never became ready in a new window") }

        guard projectWindows.count == 2 else {
            return fail("alias request duplicated a window")
        }
        let windowA = projectWindows[0]
        let windowB = projectWindows[1]
        guard windowA.model !== windowB.model,
              windowA.projectURL?.standardizedFileURL
                == projectA.standardizedFileURL,
              windowB.projectURL?.standardizedFileURL
                == projectB.standardizedFileURL
        else { return fail("window claiming or model isolation broken") }
        guard windowA.window?.title == "\(projectA.lastPathComponent) — Cairn",
              windowB.window?.title == "\(projectB.lastPathComponent) — Cairn"
        else { return fail("window titles not project-scoped") }

        // Reading state is per-window: tabs opened in A never appear in B.
        windowA.openFileInNewTabForSelfTest(
            projectA.appendingPathComponent("src/main.rs")
        )
        guard waitUntil(timeout: 15, condition: {
            windowA.model.tabStrip.tabs.count == 1
        }) else { return fail("tab never opened in A") }
        guard windowB.model.tabStrip.tabs.isEmpty else {
            return fail("A's tab leaked into B's model")
        }
        // A later alias-only request activates A's window without
        // resetting it and without creating a window (§3.1).
        guard windowA.model.projectRoot?.standardizedFileURL
            == projectA.standardizedFileURL
        else { return fail("alias activation reset A") }
        enqueueOpenRequest(root: alias, languages: nil, sourceWindow: nil)
        guard waitUntil(timeout: 15, condition: {
            self.activeWindowOrder.last === windowA
        }) else { return fail("alias request did not activate A's window") }
        guard projectWindows.count == 2 else {
            return fail("alias request duplicated a window")
        }

        // Closing B (approved close through AppKit) removes it from the
        // collection and leaves A working (§7.1).
        windowB.window?.performClose(nil)
        // Immediately re-request B while its teardown is still running:
        // the pipeline must wait for the old session writer to finish
        // instead of racing a second model for the same project (review
        // F2). Exactly one B window exists afterwards.
        enqueueOpenRequest(root: projectB, languages: nil, sourceWindow: nil)
        // The old B window keeps its ready state until its asynchronous
        // teardown runs, so the reopened B is identified by NOT closing.
        guard waitUntil(timeout: 30, condition: {
            self.projectWindows.count == 2
                && self.projectWindows.last?.isClosing == false
                && self.projectWindows.last?.model.projectState
                    .isReadyForMultiWindowSelfTest == true
                && self.projectWindows.last?.projectURL?.standardizedFileURL
                    == projectB.standardizedFileURL
                && self.projectWindows.first === windowA
        }) else { return fail("immediate reopen of B did not serialize with its close") }
        guard projectWindows.filter({
            $0.projectURL?.standardizedFileURL == projectB.standardizedFileURL
        }).count == 1
        else { return fail("reopened B produced duplicate windows") }
        guard waitUntil(timeout: 15, condition: {
            self.projectWindows.count == 2
        }) else { return fail("closing B did not retire its window") }
        guard projectWindows.first === windowA,
              windowA.model.projectState.isReadyForMultiWindowSelfTest,
              windowA.model.tabStrip.tabs.count == 1,
              projectWindows[1].isClosing == false
        else { return fail("A disturbed by B's close") }

        // Cancel a first open (review F1): the claim is released, the
        // auto-created blank window goes away, and the repeat request
        // loads the project.
        guard let projectC = makeProject([
            "src/lib.rs": "pub fn gamma() {}\n",
        ]) else { return fail("project C fixture unavailable") }
        languagePickerOverride = { _ in nil }
        enqueueOpenRequest(root: projectC, languages: nil, sourceWindow: nil)
        guard waitUntil(timeout: 15, condition: {
            !self.isDrainingOpenRequests && self.pendingOpenURLs.isEmpty
        }) else { return fail("cancelled open never finished draining") }
        // The auto-created window closes with an asynchronous teardown;
        // wait for the collection to settle back to A + B.
        guard waitUntil(timeout: 15, condition: {
            self.projectWindows.count == 2
                && self.projectWindows.allSatisfy({
                    $0.projectURL?.standardizedFileURL
                        != projectC.standardizedFileURL
                })
        }) else { return fail("cancelled request left a claimed window behind") }
        languagePickerOverride = { _ in [.rust] }
        enqueueOpenRequest(root: projectC, languages: nil, sourceWindow: nil)
        guard waitUntil(timeout: 60, condition: {
            self.projectWindows.count == 3
                && self.projectWindows.last?.model.projectState
                    .isReadyForMultiWindowSelfTest == true
        }) else { return fail("repeat request after cancel did not load C") }
        guard let windowC = projectWindows.last,
              windowC.projectURL?.standardizedFileURL
                == projectC.standardizedFileURL
        else { return fail("C loaded into the wrong window") }

        // Projects left per-project snapshots behind (§7.3).
        windowA.checkpointSessionSynchronously()
        let sessionsDirectory = (windowSessionURL ?? AppModel.defaultSessionURL)
            .deletingLastPathComponent()
            .appendingPathComponent("sessions", isDirectory: true)
        let persisted = (try? FileManager.default.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: nil
        ))?.count ?? 0
        guard persisted >= 2 else {
            return fail("per-project snapshots missing on disk")
        }

        try? FileManager.default.removeItem(at: projectA)
        try? FileManager.default.removeItem(at: projectB)
        try? FileManager.default.removeItem(at: projectC)
        Self.writeJSON([
            "channel": channel,
            "passed": true,
            "windows": projectWindows.count,
            "persistedSnapshots": persisted,
            "titleA": windowA.window?.title ?? "",
        ] as [String: Any])
        Self.exitSelfTest(channel: channel, status: 0)
    }


    /// Reading-session acceptance, second process: relaunches the same
    /// build against the isolated store; the normal launch path (pointer
    // → per-project snapshot → restoreSession) must rebuild the scene the
    /// first process recorded.
    func runSessionSelfTestRestart() -> Never {
        let channel = "session-restart"
        launch(offscreen: false)
        guard let controller = windowController else {
            Self.writeJSON(["channel": channel, "passed": false, "error": "window unavailable"])
            Self.exitSelfTest(channel: channel, status: 1)
        }
        guard let expected = readSessionSelfTestExpectations() else {
            Self.writeJSON([
                "channel": channel,
                "passed": false,
                "error": "expectations unavailable",
            ])
            Self.exitSelfTest(channel: channel, status: 1)
        }
        let rootPath = expected["root"] as? String ?? ""
        let restored = waitUntil(timeout: 120, condition: {
            self.model.projectRoot?.standardizedFileURL.path == rootPath
                && self.model.snapshotPhase == .fullReady
                && self.model.tabStrip.tabs.count == (expected["tabPaths"] as? [String])?.count
        })
        let expectedPaths = expected["tabPaths"] as? [String] ?? []
        let expectedActive = expected["activeIndex"] as? Int ?? -1
        let readerReady = restored && waitUntil(timeout: 15, condition: {
            expectedPaths.indices.contains(expectedActive)
                && controller.displayedReaderFile?.lastPathComponent == expectedPaths[expectedActive]
                && Int(controller.selfTestReadingByteOffset ?? .max) == (expected["scrollAnchor"] as? Int ?? -1)
                && Int(controller.selfTestReaderCaretByteOffset ?? .max) == (expected["selectionAnchor"] as? Int ?? -1)
        })
        guard readerReady else {
            Self.writeJSON([
                "channel": channel,
                "passed": false,
                "error": "Reader restoration did not complete",
                "tabs": self.model.tabStrip.tabs.count,
            ])
            Self.exitSelfTest(channel: channel, status: 1)
        }
        let tabPaths = model.tabStrip.tabs.map {
            $0.fileURL?.lastPathComponent ?? ""
        }
        let activeIndex = model.tabStrip.activeIndex ?? -1
        let trailNodes = model.readingTrail.orderedNodes().map { $0.id.rawValue.uuidString }
        let trailEdges = model.readingTrail.edges.map { [$0.from.rawValue.uuidString, $0.to.rawValue.uuidString] }
        let historyCursor = model.navigationHistory.cursor
        let historyRecords = model.navigationHistory.records.count
        var checks: [String: Bool] = [
            "tabOrder": tabPaths == (expected["tabPaths"] as? [String] ?? []),
            "activeTab": activeIndex == (expected["activeIndex"] as? Int ?? -1),
            "scrollAnchor": Int(controller.selfTestReadingByteOffset ?? .max)
                == (expected["scrollAnchor"] as? Int ?? -1),
            "selectionAnchor": Int(
                controller.selfTestReaderCaretByteOffset ?? .max
            ) == (expected["selectionAnchor"] as? Int ?? -1),
            "trailNodes": trailNodes == (expected["trailNodeIDs"] as? [String] ?? []),
            "trailEdges": trailEdges == (expected["trailEdges"] as? [[String]] ?? []),
            "trailActive": model.readingTrail.activeNodeID?.rawValue.uuidString == (expected["trailActiveID"] as? String),
            "historyCursor": historyCursor == (expected["historyCursor"] as? Int ?? -1),
            "historyRecords": historyRecords == (expected["historyRecords"] as? Int ?? -1),
            "canGoBack": model.navigationHistory.canGoBack
                == (expected["canGoBack"] as? Bool ?? false),
            "canGoForward": model.navigationHistory.canGoForward
                == (expected["canGoForward"] as? Bool ?? false),
            "readerDisplaysActiveTab": {
                guard tabPaths.indices.contains(activeIndex) else { return false }
                return controller.displayedReaderFile?.lastPathComponent
                    == tabPaths[activeIndex]
            }(),
        ]
        controller.goBack(nil)
        checks["backAfterRestart"] = waitUntil(timeout: 10) {
            controller.displayedReaderFile?.lastPathComponent == "main.rs"
        }
        controller.goForward(nil)
        checks["forwardAfterRestart"] = waitUntil(timeout: 10) {
            controller.displayedReaderFile?.lastPathComponent == "third.rs"
        }
        let passed = checks.values.allSatisfy { $0 }
        let output: [String: Any] = [
            "channel": channel,
            "passed": passed,
            "processRestart": true,
            "checks": checks,
            "tabPaths": tabPaths,
            "trailEdges": trailEdges,
            "historyCursor": historyCursor,
        ]
        if let data = try? JSONSerialization.data(
            withJSONObject: output,
            options: [.sortedKeys]
        ) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
        }
        Darwin.exit(passed ? 0 : 1)
    }

    private func writeSessionSelfTestExpectations(_ value: [String: Any]) {
        guard let path = ProcessInfo.processInfo.environment[
            "CAIRN_SESSION_SELFTEST_EXPECTATIONS"
        ] else { return }
        if let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys]
        ) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    private func readSessionSelfTestExpectations() -> [String: Any]? {
        guard let path = ProcessInfo.processInfo.environment[
            "CAIRN_SESSION_SELFTEST_EXPECTATIONS"
        ],
            let data = try? Data(contentsOf: URL(fileURLWithPath: path))
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    func runBookmarkSelfTest(root: URL) -> Never {
        let channel = "bookmarks"
        let languages = bookmarkSelfTestLanguages()
        let languageFiles = bookmarkSelfTestFiles(in: root, languages: languages)
        launch(offscreen: false)
        guard let controller = windowController,
              let window = controller.window,
              let file = languageFiles.first?.file
        else {
            Self.writeJSON(["channel": channel, "passed": false, "error": "fixture unavailable"])
            Self.exitSelfTest(channel: channel, status: 1)
        }
        window.setContentSize(NSSize(width: 1_200, height: 800))
        window.setFrameOrigin(NSPoint(x: 80, y: 80))
        window.orderFrontRegardless()
        NSApplication.shared.activate(ignoringOtherApps: true)
        controller.openProject(root: root, languages: languages)
        guard waitUntil(timeout: 60, condition: {
            if case .ready = self.model.projectState { return true }
            return false
        }) else {
            Self.writeJSON(["channel": channel, "passed": false, "error": "project not ready"])
            Self.exitSelfTest(channel: channel, status: 1)
        }
        controller.openFileForSelfTest(file)
        guard waitUntil(timeout: 15, condition: {
            controller.displayedReaderFile?.standardizedFileURL == file
                && self.model.tabStrip.activeDocument != nil
        }) else {
            Self.writeJSON(["channel": channel, "passed": false, "error": "reader unavailable"])
            Self.exitSelfTest(channel: channel, status: 1)
        }
        controller.setReadingPositionForSelfTest(scrollByteOffset: 0, selectionByteOffset: 0)
        pumpRunLoop()
        let viewMenu = NSApplication.shared.mainMenu?.items.compactMap(\.submenu)
            .first { $0.title == "View" }
        guard let toggle = viewMenu?.item(withTitle: "Toggle Bookmark"),
              let show = viewMenu?.item(withTitle: "Show Bookmarks")
        else {
            Self.writeJSON(["channel": channel, "passed": false, "error": "menu unavailable"])
            Self.exitSelfTest(channel: channel, status: 1)
        }
        let toggleEnabled = validateMenuItem(toggle)
        let toggled = toggleEnabled && performMenuShortcut(
            characters: "m", modifiers: [.command, .shift], window: window
        )
        guard waitUntil(timeout: 5, condition: {
            self.model.bookmarkModel.records.count == 1
        }), let record = self.model.bookmarkModel.records.first else {
            Self.writeJSON(["channel": channel, "passed": false, "error": "bookmark toggle failed"])
            Self.exitSelfTest(channel: channel, status: 1)
        }
        let gutterMarker = controller.selfTestBookmarkMarkerLines.contains(Int(record.line))
            && !(controller.selfTestBookmarkMarkerAccessibilityLabel ?? "").isEmpty
        let gutterLines = controller.selfTestBookmarkMarkerLines
        let gutterAccessibilityLabel = controller.selfTestBookmarkMarkerAccessibilityLabel ?? ""
        let openedPanel = performMenuShortcut(
            characters: "b", modifiers: [.command, .option], window: window
        )
        let panelShortcutIsUnique = show.keyEquivalent == "b"
            && show.keyEquivalentModifierMask == [.command, .option]
        guard waitUntil(timeout: 5, condition: {
            controller.selfTestBookmarkPanel?.selfTestState.visible == true
        }), let panel = controller.selfTestBookmarkPanel else {
            Self.writeJSON(["channel": channel, "passed": false, "error": "panel unavailable"])
            Self.exitSelfTest(channel: channel, status: 1)
        }
        let shown = panel.selfTestState
        panel.selfTestSetFilter("no-bookmark-match")
        let filteredOut = panel.selfTestState.rows == 0
        panel.selfTestSetFilter(record.path)
        let filteredIn = panel.selfTestState.rows == 1
            && panel.selfTestState.rowIDs == [record.id.uuidString]
        let statusToolTip = panel.selfTestFirstRowToolTip
        let noteText = "* _ [ ] # > | \\ ` { } ( ) + - . !\nnext"
        let noteSelected = panel.selfTestSelectFirstRow()
        let noteUpdatedAt = BookmarkModel(store: BookmarkStore(
            fileURL: bookmarkSelfTestSessionURL().deletingLastPathComponent()
                .appendingPathComponent("bookmarks.json")
        )).records.first(where: { $0.id == record.id })?.updatedAt ?? record.updatedAt
        panel.selfTestTypeNote(noteText)
        let reloadedNote = BookmarkModel(store: BookmarkStore(
            fileURL: bookmarkSelfTestSessionURL().deletingLastPathComponent()
                .appendingPathComponent("bookmarks.json")
        )).records.first(where: { $0.id == record.id })
        let noteWriteThrough = reloadedNote?.note == noteText
            && reloadedNote?.updatedAt == noteUpdatedAt
        panel.selfTestFinalizeNote()
        let finalizedNote = BookmarkModel(store: BookmarkStore(
            fileURL: bookmarkSelfTestSessionURL().deletingLastPathComponent()
                .appendingPathComponent("bookmarks.json")
        )).records.first(where: { $0.id == record.id })
        let noteFinalized = (finalizedNote?.updatedAt ?? noteUpdatedAt) > noteUpdatedAt
        let noteRestart = finalizedNote?.note == noteText
        let bookmarksURL = bookmarkSelfTestSessionURL().deletingLastPathComponent()
            .appendingPathComponent("bookmarks.json")
        let rawBookmarksBefore = try? Data(contentsOf: bookmarksURL)
        panel.selfTestPressCopyMarkdown()
        let copiedMarkdown = panel.selfTestLastCopiedMarkdown
        let pasteboardReadback = NSPasteboard.general.string(forType: .string) == copiedMarkdown
        panel.selfTestPressExportMarkdown()
        let markdownPath = ProcessInfo.processInfo.environment[
            "CAIRN_BOOKMARK_MARKDOWN_EXPORT_PATH"
        ] ?? ""
        let exportedMarkdown = try? String(contentsOfFile: markdownPath, encoding: .utf8)
        let rawBookmarksAfter = try? Data(contentsOf: bookmarksURL)
        let rawBookmarksUnchanged = rawBookmarksBefore == rawBookmarksAfter
        let normalAX = panel.selfTestAXTree()
        let panelGeometry = panel.selfTestGeometry
        let historyBefore = self.model.navigationHistory.records.count
        let rowOpen = panel.selfTestPressFirstOpen()
        let openedExact = waitUntil(timeout: 5, condition: {
            self.model.navigationHistory.records.count == historyBefore + 1
                && self.model.tabStrip.activeDocument?.contentID == record.contentID
        })
        let contentIDExactAtOpen = self.model.tabStrip.activeDocument?.contentID == record.contentID
        let returned = openedExact
            && performMenuShortcut(characters: "[", modifiers: [.command], window: window)
            && waitUntil(timeout: 5, condition: {
                self.model.navigationHistory.canGoForward
            })
        let gitHEAD = bookmarkSelfTestGitHEAD(in: root)
        var gitChecks: [String: Bool] = [:]
        let gitSkip = gitHEAD == nil ? "commit checks require a repository with HEAD" : ""
        if let gitHEAD {
            self.model.switchToCommit(gitHEAD)
            let commitReady = waitUntil(timeout: 60, condition: {
                self.model.snapshotPhase == .fullReady && self.model.currentRevision == gitHEAD
            })
            controller.openFileForSelfTest(file)
            let commitReader = waitUntil(timeout: 15, condition: {
                controller.displayedReaderFile?.standardizedFileURL == file
                    && self.model.tabStrip.activeDocument != nil
            })
            controller.setReadingPositionForSelfTest(scrollByteOffset: 0, selectionByteOffset: 0)
            let commitToggle = commitReady && commitReader && performMenuShortcut(
                characters: "m", modifiers: [.command, .shift], window: window
            )
            let commitRecord = self.model.bookmarkModel.records.last { candidate in
                if case let .commit(fullOID) = candidate.snapshot { return fullOID == gitHEAD }
                return false
            }
            let commitCaptured = commitRecord.map { candidate in
                if case let .commit(fullOID) = candidate.snapshot {
                    return fullOID.count == 40 || fullOID.count == 64
                }
                return false
            } ?? false
            self.model.switchToWorktree()
            let worktreeReady = waitUntil(timeout: 60, condition: {
                self.model.snapshotPhase == .fullReady && self.model.currentRevision == nil
            })
            panel.refresh()
            let commitNotEvaluated = commitRecord.map {
                panel.selfTestRowToolTip(id: $0.id) == "Not evaluated"
            } ?? false
            let historyBeforeCommitOpen = self.model.navigationHistory.records.count
            let commitOpen = commitRecord.map { panel.selfTestPressOpen(id: $0.id) } ?? false
            let commitExact = commitOpen && waitUntil(timeout: 60, condition: {
                self.model.currentRevision == gitHEAD
                    && self.model.tabStrip.activeDocument?.contentID == commitRecord?.contentID
                    && self.model.navigationHistory.records.count == historyBeforeCommitOpen + 1
            })
            let commitBack = commitExact
                && performMenuShortcut(characters: "[", modifiers: [.command], window: window)
                && waitUntil(timeout: 60, condition: { self.model.currentRevision == nil })
            let worktreeFullAfterCommitBack = commitBack && waitUntil(timeout: 60, condition: {
                self.model.snapshotPhase == .fullReady && self.model.currentRevision == nil
            })
            let missing = BookmarkRecord(
                id: UUID(), projectPath: root.standardizedFileURL.path,
                snapshot: .commit(fullOID: String(repeating: "a", count: 40)),
                path: record.path, contentID: record.contentID, byteOffset: record.byteOffset,
                line: record.line, symbolName: nil, symbolKind: nil, note: "", updatedAt: .now
            )
            let missingAdded = self.model.bookmarkModel.toggle(missing) == .added
            panel.refresh()
            let missingHistory = self.model.navigationHistory.records.count
            let missingRevision = self.model.currentRevision
            let missingOpen = missingAdded && panel.selfTestPressOpen(id: missing.id)
            let missingAttempt = missingOpen && waitUntil(timeout: 15, condition: {
                self.model.bookmarkModel.lastAttemptMessage?.id == missing.id
                    && self.model.bookmarkModel.lastAttemptMessage?.message == "Bookmark revision is unavailable."
            })
            gitChecks = [
                "switchToCommit": commitReady,
                "commitCaptureFullOID": commitToggle && commitCaptured,
                "commitNotEvaluated": worktreeReady && commitNotEvaluated,
                "commitOpenExact": commitExact,
                "commitGoBack": worktreeFullAfterCommitBack,
                "missingObjectAttempt": missingAttempt,
                "missingObjectNoWorkspaceMutation": missingAttempt
                    && self.model.currentRevision == missingRevision
                    && self.model.navigationHistory.records.count == missingHistory,
            ]
        }
        let drift = BookmarkRecord(
            id: UUID(), projectPath: root.standardizedFileURL.path, snapshot: .worktree,
            path: record.path, contentID: ContentID.sha256(of: Data("bookmark drift\n".utf8)),
            byteOffset: 0, line: 999, symbolName: nil, symbolKind: nil,
            note: "drift note", updatedAt: .now
        )
        let driftAdded = self.model.currentRevision == nil
            && self.model.bookmarkModel.toggle(drift) == .added
        panel.refresh()
        let driftBefore = self.model.bookmarkModel.records.first { $0.id == drift.id }
        let expectedDriftTarget = self.model.explicitBookmarkLineOpen(drift, line: drift.line)
        let driftLineOpen = driftAdded && panel.selfTestPressOpenLine(id: drift.id)
        let driftLineOpened = driftLineOpen && waitUntil(timeout: 15, condition: {
            self.model.selectedByteOffset == expectedDriftTarget?.byteOffset
        })
        let driftReanchored = driftLineOpened && panel.selfTestPressReanchor(id: drift.id)
        let driftAfter = self.model.bookmarkModel.records.first { $0.id == drift.id }
        let driftExact = driftAfter.map { self.model.bookmarkStatus(for: $0) == .exactContent } ?? false
        let modelReloadURL = bookmarkSelfTestSessionURL().deletingLastPathComponent()
            .appendingPathComponent("bookmarks.json")
        self.model.bookmarkModel = BookmarkModel(store: BookmarkStore(fileURL: modelReloadURL))
        panel.refresh()
        let modelReload = self.model.bookmarkModel.records.contains(where: { $0.id == record.id })
            && self.model.bookmarkModel.records.first(where: { $0.id == drift.id })?.note == "drift note"
        var languageChecks: [String: Bool] = [:]
        if gitHEAD != nil {
            panel.selfTestSetFilter("")
            for item in languageFiles {
                controller.openFileForSelfTest(item.file)
                let readerReady = waitUntil(timeout: 15, condition: {
                    controller.displayedReaderFile?.standardizedFileURL == item.file
                })
                let existing = self.model.bookmarkModel.records.last { candidate in
                    candidate.projectPath == root.standardizedFileURL.path && candidate.snapshot == .worktree
                        && candidate.path == item.file.path.replacingOccurrences(
                            of: root.standardizedFileURL.path + "/", with: ""
                        )
                }
                controller.setReadingPositionForSelfTest(scrollByteOffset: 1, selectionByteOffset: 1)
                let languageToggle = existing != nil || (readerReady && performMenuShortcut(
                    characters: "m", modifiers: [.command, .shift], window: window
                ))
                let languageRecord = existing ?? self.model.bookmarkModel.records.last { candidate in
                    candidate.projectPath == root.standardizedFileURL.path && candidate.snapshot == .worktree
                        && candidate.path == item.file.path.replacingOccurrences(
                            of: root.standardizedFileURL.path + "/", with: ""
                        )
                }
                panel.refresh()
                let languageOpen = languageRecord.map { panel.selfTestPressOpen(id: $0.id) } ?? false
                let languageExact = languageOpen && waitUntil(timeout: 15, condition: {
                    self.model.tabStrip.activeDocument?.contentID == languageRecord?.contentID
                })
                languageChecks[bookmarkSelfTestLanguageName(item.language)] = languageToggle && languageExact
            }
        }
        let allLanguagesPresent = languageFiles.count == languages.count
        _ = self.model.compare.beginLoading(revision: "bookmark-self-test")
        let compareDisabled = !validateMenuItem(toggle)
            && toggle.accessibilityHelp() == "Compare views cannot be bookmarked."
        self.model.compare.clear()
        let themeCaptures = ReaderSettings.Theme.allCases.filter {
            [.light, .dark, .siClassic].contains($0)
        }.map { theme in
            var settings = self.readerSettings
            settings.theme = theme
            controller.applyReaderSettings(settings)
            panel.window?.orderFrontRegardless()
            let capture = self.bookmarkSelfTestCapture(
                window: window,
                panelWindow: panel.window,
                label: theme.rawValue
            )
            return (
                capture.pass && !controller.selfTestBookmarkMarkerLines.isEmpty,
                capture.json
            )
        }

        self.model.openReadingSet(title: "Bookmark unsupported", excerpts: [])
        pumpRunLoop()
        let readingSetDisabled = !validateMenuItem(toggle)
            && toggle.accessibilityHelp() == "Reading Sets cannot be bookmarked."

        let corruptBytes = Data([0x7B, 0xFF, 0x00])
        let corruptURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CodeInsightBookmarkCorrupt-\(UUID().uuidString).json"
        )
        try? corruptBytes.write(to: corruptURL)
        self.model.bookmarkModel = BookmarkModel(store: BookmarkStore(fileURL: corruptURL))
        panel.refresh()
        let corrupt = panel.selfTestState
        let errorAX = panel.selfTestAXTree()
        let exportPressed = panel.selfTestPressExport()
        let rawExportURL = ProcessInfo.processInfo.environment[
            "CAIRN_BOOKMARK_RAW_EXPORT_PATH"
        ].map(URL.init(fileURLWithPath:))
        let exported = rawExportURL.flatMap { try? Data(contentsOf: $0) } == corruptBytes
        let checks: [String: Bool] = [
            "toggleEnabled": toggleEnabled,
            "toggleShortcut": toggled,
            "panelShortcut": openedPanel,
            "panelShortcutUnique": panelShortcutIsUnique,
            "panelAX": shown.accessibilityLabel == "Bookmarks",
            "panelGeometry": panelGeometry.content.width >= 500
                && panelGeometry.content.height >= 400
                && panelGeometry.table.height > 200
                && panelGeometry.row.height > 0
                && panelGeometry.copyVisible
                && panelGeometry.markdownExportVisible
                && !panelGeometry.copy.intersects(panelGeometry.markdownExport)
                && panelGeometry.content.contains(panelGeometry.copy)
                && panelGeometry.content.contains(panelGeometry.markdownExport),
            "normalAX": axContains(normalAX, "Filter bookmarks")
                && axContains(normalAX, "Bookmarks")
                && axContains(normalAX, "Open bookmark")
                && axContains(normalAX, "Delete bookmark"),
            "noteWriteThrough": noteSelected && noteWriteThrough,
            "noteRestart": noteRestart && noteFinalized,
            "copyMarkdown": copiedMarkdown.contains("### Note")
                && copiedMarkdown.contains(
                    "\\* \\_ \\[ \\] \\# \\> \\| \\\\ \\` \\{ \\} \\( \\) \\+ \\- \\. \\!\nnext"
                ),
            "markdownExport": exportedMarkdown == copiedMarkdown,
            "exportZeroMutation": rawBookmarksUnchanged,
            "errorAX": axContains(errorAX, "Bookmark storage error")
                && axContains(errorAX, "Export Raw Copy…"),
            "statusToolTip": statusToolTip == "Exact content",
            "filter": filteredOut && filteredIn,
            "rowOpen": rowOpen && openedExact,
            "contentIDExactAtOpen": contentIDExactAtOpen,
            "goBack": returned,
            "gitMatrix": gitHEAD == nil || gitChecks.values.allSatisfy { $0 },
            "driftLineOpen": driftLineOpen && driftLineOpened,
            "driftReanchor": driftReanchored
                && driftBefore?.id == driftAfter?.id
                && driftBefore?.note == driftAfter?.note
                && driftBefore?.contentID != driftAfter?.contentID
                && driftBefore?.line != driftAfter?.line
                && driftExact,
            "modelReload": modelReload,
            "mixedLanguageCoverage": gitHEAD == nil || (
                allLanguagesPresent && languageChecks.count == languages.count
                    && languageChecks.values.allSatisfy { $0 }
            ),
            "gutterMarker": gutterMarker,
            "readingSetDisabled": readingSetDisabled,
            "compareDisabled": compareDisabled,
            "themeCaptures": themeCaptures.allSatisfy { $0.0 },
            "corruptExport": corrupt.exportVisible && corrupt.exportEnabled
                && corrupt.exportAccessibilityLabel == "Export Raw Copy…"
                && exportPressed && exported,
        ]
        Self.writeJSON([
            "channel": channel,
            "passed": checks.values.allSatisfy { $0 },
            "checks": checks,
            "menu": [
                "toggleEnabled": toggleEnabled,
                "toggleHelp": toggle.accessibilityHelp() ?? "",
                "panelShortcut": "⌘⌥B",
                "readingSetDisabled": readingSetDisabled,
                "compareDisabled": compareDisabled,
            ],
            "panel": [
                "rows": shown.rows,
                "rowIDs": shown.rowIDs,
                "accessibilityLabel": shown.accessibilityLabel,
                "statusToolTip": statusToolTip ?? "",
            ],
            "matrix": [
                "gitApplicable": gitHEAD != nil,
                "commitApplicable": gitHEAD != nil,
                "gitSkip": gitSkip,
                "modelReload": modelReload,
                "secondProcessReload": "not run",
                "processRestart": "run --self-test-bookmarks-restart after this process exits",
                "languages": languages.map(bookmarkSelfTestLanguageName),
                "languageFiles": languageFiles.map {
                    ["language": bookmarkSelfTestLanguageName($0.language), "path": $0.file.path]
                },
                "languageChecks": languageChecks,
                "gitChecks": gitChecks,
                "nonGit": [
                    "worktreeOnly": gitHEAD == nil,
                    "commitApplicable": false,
                    "missingObjectApplicable": false,
                ],
                "drift": [
                    "lineOpen": driftLineOpen && driftLineOpened,
                    "reanchor": driftReanchored && driftExact,
                ],
            ],
            "axTreeNormal": normalAX,
            "axTreeError": errorAX,
            "panelGeometry": [
                "content": NSStringFromRect(panelGeometry.content),
                "table": NSStringFromRect(panelGeometry.table),
                "row": NSStringFromRect(panelGeometry.row),
                "copy": NSStringFromRect(panelGeometry.copy),
                "markdownExport": NSStringFromRect(panelGeometry.markdownExport),
                "copyVisible": panelGeometry.copyVisible,
                "markdownExportVisible": panelGeometry.markdownExportVisible,
            ],
            "copy": ["length": copiedMarkdown.count, "pasteboardReadback": pasteboardReadback],
            "markdownPath": markdownPath,
            "markdownLength": copiedMarkdown.count,
            "pasteboardReadback": pasteboardReadback,
            "rawBookmarks": [
                "beforeLength": rawBookmarksBefore?.count ?? -1,
                "afterLength": rawBookmarksAfter?.count ?? -1,
                "unchanged": rawBookmarksUnchanged,
            ],
            "captures": themeCaptures.map { $0.1 },
            "historyCount": self.model.navigationHistory.records.count,
            "contentIDExactAtOpen": contentIDExactAtOpen,
            "rawExportByteIdentical": exported,
            "gutter": [
                "lines": gutterLines,
                "accessibilityLabel": gutterAccessibilityLabel,
            ],
            "sessionURL": bookmarkSelfTestSessionURL().path,
            "bookmarksURL": bookmarksURL.path,
        ])
        try? FileManager.default.removeItem(at: corruptURL)
        Self.exitSelfTest(channel: channel, status: checks.values.allSatisfy { $0 } ? 0 : 1)
    }

    private func performMenuShortcut(
        characters: String,
        modifiers: NSEvent.ModifierFlags,
        window: NSWindow
    ) -> Bool {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: 0
        ) else { return false }
        return NSApplication.shared.mainMenu?.performKeyEquivalent(with: event) == true
    }

    private func bookmarkSelfTestCapture(
        window: NSWindow,
        panelWindow: NSWindow?,
        label: String
    ) -> (pass: Bool, json: [String: Any]) {
        window.displayIfNeeded()
        panelWindow?.displayIfNeeded()
        pumpRunLoop()
        let directory = ProcessInfo.processInfo.environment[
            "CAIRN_BOOKMARK_CAPTURE_DIR"
        ] ?? "/tmp/cairn-bookmark-captures"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = "\(directory)/\(label).png"
        let panelPNG = "\(directory)/\(label)-panel.png"
        guard let panelWindow,
              let main = cachedPNG(of: window.contentView, path: path),
              let panelPath = cachedPNG(
                of: panelWindow.contentView,
                path: panelPNG
              )
        else { return (false, ["theme": label, "error": "AppKit capture failed"]) }
        return (main.visiblePixels && panelPath.visiblePixels, [
            "theme": label, "png": main.path, "width": main.width,
            "height": main.height, "visiblePixels": main.visiblePixels,
            "panelPNG": panelPath.path,
            "panelWidth": panelPath.width, "panelHeight": panelPath.height,
            "panelVisiblePixels": panelPath.visiblePixels,
            "capture": "AppKit cache",
            "panelCapture": "AppKit cache",
        ])
    }

    func runOpenSelfTest(file: URL) {
        let textView = ReaderTextView()
        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: 1024, height: 768)
        )
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.documentView = textView.view
        textView.view.frame = scrollView.contentView.bounds
        let window = NSWindow(
            contentRect: scrollView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        let openedAt = ContinuousClock.now
        let state = OpenSelfTestState(
            openedAt: openedAt,
            textView: textView,
            window: window
        )

        do {
            let loader = DocumentLoader()
            let loaded = try loader.load(file: file)
            state.tier = loaded.tier
            state.textView.display(document: loaded.document, fileURL: file)
            state.textView.view.textLayoutManager?
                .textViewportLayoutController.layoutViewport()
            guard
                let fragment = state.textView.view.textLayoutManager?
                    .textLayoutFragment(for: .zero),
                !fragment.textLineFragments.isEmpty
            else { Self.exitSelfTest(channel: "open", status: 1) }
            state.firstVisibleMS = milliseconds(since: openedAt)
            state.firstVisibleOutlineFacets = loaded.document.outlineFacets.count
            if loaded.tier == .regular {
                state.syntaxVisibleMS = state.firstVisibleMS
                state.outlineFacets = loaded.document.outlineFacets.count
            } else {
                loader.loadSyntax(for: loaded.document) { result in
                    Task { @MainActor in
                        switch result {
                        case let .success(document):
                            state.textView.updateSyntax(document: document)
                            try? await Task.sleep(for: .milliseconds(10))
                            state.textView.view.textLayoutManager?
                                .textViewportLayoutController.layoutViewport()
                            state.window.displayIfNeeded()
                            state.syntaxVisibleMS = milliseconds(since: state.openedAt)
                            state.outlineFacets = document.outlineFacets.count
                        case .failure:
                            state.failed = true
                        }
                    }
                }
            }
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            Self.exitSelfTest(channel: "open", status: 1)
        }

        let deadline = Date(timeIntervalSinceNow: 30)
        while state.syntaxVisibleMS == nil, !state.failed, Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        guard
            let tier = state.tier,
            let firstVisibleMS = state.firstVisibleMS,
            let syntaxVisibleMS = state.syntaxVisibleMS,
            let firstVisibleOutlineFacets = state.firstVisibleOutlineFacets,
            let outlineFacets = state.outlineFacets,
            !state.failed
        else { Self.exitSelfTest(channel: "open", status: 1) }
        Self.finishOpenSelfTest(
            tier: tier,
            firstVisibleMS: firstVisibleMS,
            syntaxVisibleMS: syntaxVisibleMS,
            styledFragments: state.textView.renderingCoordinator.styledFragmentCount,
            firstVisibleOutlineFacets: firstVisibleOutlineFacets,
            outlineFacets: outlineFacets
        )
    }

    private static func finishProjectSelfTest(
        treeVisibleMS: Double,
        indexReadyMS: Double,
        fileCount: Int,
        reused: Int,
        extracted: Int,
        ready: Bool,
        emptyStateRemoved: Bool,
        readerDocumentVisible: Bool,
        branchName: String? = nil,
        commitTitle: String = "",
        commitPickerShowsCurrentBranch: Bool = false,
        indexStatusVisibleDuringIndexing: Bool = false,
        indexStatusTextDuringIndexing: String = "",
        statusBarVisibleAfterReady: Bool = false,
        indexStatusHiddenAfterFullReady: Bool = false,
        layoutChecks: [String: Bool] = [:],
        enlargedWindowGeometry: [String: Double] = [:]
    ) -> Never {
        do {
            let projectIndexReadyWithinBudget =
                indexReadyMS < SelfTestBudgets.projectIndexReadyMS
            let projectTreeVisibleWithinBudget =
                treeVisibleMS < SelfTestBudgets.projectTreeVisibleMS
            var object: [String: Any] = [
                "treeVisibleMS": treeVisibleMS,
                "indexReadyMS": indexReadyMS,
                "fileCount": fileCount,
                "reused": reused,
                "extracted": extracted,
                "projectIndexReadyWithinBudget":
                    projectIndexReadyWithinBudget,
                "projectTreeVisibleWithinBudget":
                    projectTreeVisibleWithinBudget,
                "emptyStateRemoved": emptyStateRemoved,
                "readerDocumentVisible": readerDocumentVisible,
                "branchName": branchName ?? "",
                "commitTitle": commitTitle,
                "commitPickerShowsCurrentBranch": commitPickerShowsCurrentBranch,
                "indexStatusVisibleDuringIndexing":
                    indexStatusVisibleDuringIndexing,
                "indexStatusTextDuringIndexing":
                    indexStatusTextDuringIndexing,
                "statusBarVisibleAfterReady": statusBarVisibleAfterReady,
                "indexStatusHiddenAfterFullReady":
                    indexStatusHiddenAfterFullReady,
                "enlargedWindowGeometry": enlargedWindowGeometry,
            ]
            object.merge(layoutChecks) { _, new in new }
            let data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
            exitSelfTest(
                channel: "project",
                status: ready
                    && emptyStateRemoved
                    && readerDocumentVisible
                    && commitPickerShowsCurrentBranch
                    && indexStatusVisibleDuringIndexing
                    && statusBarVisibleAfterReady
                    && indexStatusHiddenAfterFullReady
                    && layoutChecks.values.allSatisfy { $0 }
                    ? 0 : 1
            )
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exitSelfTest(channel: "project", status: 1)
        }
    }

    private static func finishHistorySelfTest(
        selectionSynchronized: Bool,
        switchEnteredHistory: Bool,
        navigationSequence: Bool,
        error: String?
    ) -> Never {
        let passed = selectionSynchronized
            && switchEnteredHistory
            && navigationSequence
            && error == nil
        var summary: [String: Any] = [
            "step": "summary",
            "selectionSynchronized": selectionSynchronized,
            "switchEnteredHistory": switchEnteredHistory,
            "navigationSequence": navigationSequence,
            "passed": passed,
        ]
        if let error { summary["error"] = error }
        writeJSON(summary)
        exitSelfTest(channel: "history", status: passed ? 0 : 1)
    }

    private static func finishOpenSelfTest(
        tier: FileTier,
        firstVisibleMS: Double,
        syntaxVisibleMS: Double,
        styledFragments: Int,
        firstVisibleOutlineFacets: Int,
        outlineFacets: Int
    ) -> Never {
        do {
            let firstVisibleWithinBudget = tier == .regular
                ? firstVisibleMS < SelfTestBudgets.regularFirstVisibleMS
                : firstVisibleMS < SelfTestBudgets.hugeFirstVisibleMS
            let data = try JSONSerialization.data(
                withJSONObject: [
                    "tier": tier.rawValue,
                    "firstVisibleMS": firstVisibleMS,
                    "firstVisibleWithinBudget": firstVisibleWithinBudget,
                    "syntaxVisibleMS": syntaxVisibleMS,
                    "styledFragments": styledFragments,
                    "firstVisibleOutlineFacets": firstVisibleOutlineFacets,
                    "outlineFacets": outlineFacets,
                ],
                options: [.sortedKeys]
            )
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
            let passed = tier == .regular
                ? styledFragments > 0
                : tier != .huge
                    || (
                        firstVisibleOutlineFacets == 0
                            && styledFragments < SelfTestBudgets.hugeStyledFragments
                    )
            exitSelfTest(channel: "open", status: passed ? 0 : 1)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exitSelfTest(channel: "open", status: 1)
        }
    }
}

@MainActor
private final class OpenSelfTestState {
    let openedAt: ContinuousClock.Instant
    let textView: ReaderTextView
    let window: NSWindow
    var tier: FileTier?
    var firstVisibleMS: Double?
    var syntaxVisibleMS: Double?
    var firstVisibleOutlineFacets: Int?
    var outlineFacets: Int?
    var failed = false

    init(
        openedAt: ContinuousClock.Instant,
        textView: ReaderTextView,
        window: NSWindow
    ) {
        self.openedAt = openedAt
        self.textView = textView
        self.window = window
    }
}

extension ProjectState {
    /// Ready check shared by the multi-window self-test.
    var isReadyForMultiWindowSelfTest: Bool {
        if case .ready = self { return true }
        return false
    }
}

private func bookmarkSelfTestLanguages() -> [LanguageID] {
    let raw = ProcessInfo.processInfo.environment["CAIRN_BOOKMARK_LANGUAGES"] ?? "rust"
    let languages = raw.split(separator: ",").compactMap { part -> LanguageID? in
        switch part.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "rust": .rust
        case "python": .python
        case "typescript", "ts": .typescript
        default: nil
        }
    }
    return languages.isEmpty ? [.rust] : Array(Set(languages)).sorted { $0.rawValue < $1.rawValue }
}

private func bookmarkSelfTestFiles(
    in root: URL,
    languages: [LanguageID]
) -> [(language: LanguageID, file: URL)] {
    let files = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    )
    let regular = files?.compactMap { $0 as? URL }.filter {
        (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    } ?? []
    return languages.compactMap { language in
        guard let file = regular.first(where: { LanguageMode.classify(
            path: $0.path, language: language
        ) != nil }) else { return nil }
        return (language, file.standardizedFileURL)
    }
}

private func bookmarkSelfTestGitHEAD(in root: URL) -> String? {
    func output(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch { return nil }
        guard process.terminationStatus == 0 else { return nil }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard output(["rev-parse", "--show-toplevel"]).map({
        URL(fileURLWithPath: $0).standardizedFileURL == root.standardizedFileURL
    }) == true,
    let value = output(["rev-parse", "--verify", "HEAD"]),
    (value.count == 40 || value.count == 64),
    value.allSatisfy(\.isHexDigit)
    else { return nil }
    return value
}

@MainActor
func runBookmarkSelfTestRestart(sessionURL: URL) -> Never {
    let bookmarksURL = sessionURL.standardizedFileURL.deletingLastPathComponent()
        .appendingPathComponent("bookmarks.json")
    let model = BookmarkModel(store: BookmarkStore(fileURL: bookmarksURL))
    let checks: [String: Bool] = [
        "loaded": model.storageError == nil,
        "records": !model.records.isEmpty,
        "note": model.records.contains { !$0.note.isEmpty },
    ]
    let output: [String: Any] = [
        "channel": "bookmarks-restart",
        "passed": checks.values.allSatisfy { $0 },
        "processRestart": true,
        "checks": checks,
        "records": model.records.map { [
            "id": $0.id.uuidString,
            "note": $0.note,
            "path": $0.path,
        ] },
        "bookmarksURL": bookmarksURL.path,
    ]
    if let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
    Darwin.exit(checks.values.allSatisfy { $0 } ? 0 : 1)
}

private func bookmarkSelfTestLanguageName(_ language: LanguageID) -> String {
    switch language {
    case .rust: "rust"
    case .python: "python"
    case .typescript: "typescript"
    case .javascript: "javascript"
    }
}

private func axContains(_ tree: [[String: String]], _ label: String) -> Bool {
    tree.contains { $0["label"] == label }
}

@MainActor
private func bookmarkSelfTestSessionURL() -> URL {
    ProcessInfo.processInfo.environment["CAIRN_BOOKMARK_SESSION_URL"]
        .map(URL.init(fileURLWithPath:)) ?? AppModel.defaultSessionURL
}
