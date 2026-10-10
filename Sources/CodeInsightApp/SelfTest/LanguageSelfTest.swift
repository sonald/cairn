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
    func runNonSourceSelfTest(root: URL) -> Never {
        launch(offscreen: true)

        func finish(
            passed: Bool,
            checks: [String: Bool],
            projectReadyMS: Double,
            treePaths: [String],
            files: [[String: Any]],
            captures: [[String: Any]],
            contentSizes: [String: Any],
            history: [String: Any],
            error: String? = nil
        ) -> Never {
            var object: [String: Any] = [
                "channel": "non-source",
                "passed": passed,
                "checks": checks,
                "projectReadyMS": projectReadyMS,
                "physicalFootprintBytes": Int(physicalFootprintBytes() ?? 0),
                "treeCount": treePaths.count,
                "treePaths": treePaths,
                "files": files,
                "captures": captures,
                "contentSizes": contentSizes,
                "history": history,
            ]
            if let error { object["error"] = error }
            Self.writeJSON(object)
            Self.exitSelfTest(channel: "non-source", status: passed ? 0 : 1)
        }

        guard let controller = windowController,
              let window = controller.window
        else {
            finish(
                passed: false,
                checks: ["windowCreated": false],
                projectReadyMS: 0,
                treePaths: [],
                files: [],
                captures: [],
                contentSizes: [:],
                history: [:],
                error: "window was not created"
            )
        }
        controller.prepareTitledWindowForSelfTest()
        window.setFrameOrigin(NSPoint(x: 80, y: 80))
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let openedContentSize = window.contentView?.bounds.size ?? .zero
        var contentSizes: [String: Any] = [
            "beforePreview": [
                "width": openedContentSize.width,
                "height": openedContentSize.height,
            ],
        ]

        func allViews(in view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap { allViews(in: $0) }
        }
        func visible(_ view: NSView?) -> Bool {
            guard let view else { return false }
            view.layoutSubtreeIfNeeded()
            guard let contentView = window.contentView else { return false }
            let frame = view.convert(view.bounds, to: contentView)
            return view.window === window
                && !view.isHiddenOrHasHiddenAncestor
                && frame.width > 0
                && frame.height > 0
                && !frame.intersection(contentView.bounds).isEmpty
        }
        func labeled(_ label: String) -> NSView? {
            guard let contentView = window.contentView else { return nil }
            return allViews(in: contentView).first {
                $0.accessibilityLabel() == label
            }
        }
        func relativePath(_ file: URL) -> String? {
            let file = file.standardizedFileURL
            let root = root.standardizedFileURL
            guard file.pathComponents.starts(with: root.pathComponents),
                  file.pathComponents.count > root.pathComponents.count
            else { return nil }
            return file.pathComponents.dropFirst(root.pathComponents.count)
                .joined(separator: "/")
        }
        func select(_ file: URL) -> Bool {
            guard controller.selectFileInSidebar(file) else { return false }
            return waitUntil(timeout: 5) {
                controller.displayedReaderFile?.standardizedFileURL
                    == file.standardizedFileURL
            }
        }
        func sourceControlsAreLocked() -> Bool {
            let height = controller.selfTestReadingHeightHeader
            return !controller.canFindInFile
                && !controller.canFocusCurrentScope
                && !controller.canToggleFoldAtSelection
                && !controller.readerHasReadingPosition
                && height.hidden
                && !height.enabled
        }
        func capture(_ name: String) -> [String: Any] {
            let directory = ProcessInfo.processInfo.environment[
                "CAIRN_NON_SOURCE_CAPTURE_DIR"
            ] ?? "/tmp/cairn-non-source-captures"
            try? FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true
            )
            let path = URL(fileURLWithPath: directory)
                .appendingPathComponent("\(name).png").path
            guard let result = cachedPNG(of: window.contentView, path: path)
            else {
                return [
                    "name": name,
                    "path": path,
                    "width": 0,
                    "height": 0,
                    "visiblePixels": false,
                ]
            }
            return [
                "name": name,
                "path": result.path,
                "width": result.width,
                "height": result.height,
                "visiblePixels": result.visiblePixels,
            ]
        }
        func writeSnapshotImage(
            _ image: NSImage,
            name: String,
            captureMethod: String
        ) -> [String: Any] {
            let directory = ProcessInfo.processInfo.environment[
                "CAIRN_NON_SOURCE_CAPTURE_DIR"
            ] ?? "/tmp/cairn-non-source-captures"
            try? FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true
            )
            let path = URL(fileURLWithPath: directory)
                .appendingPathComponent("\(name).png").path
            try? FileManager.default.removeItem(atPath: path)
            guard let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let data = bitmap.representation(using: .png, properties: [:]),
                  (try? data.write(to: URL(fileURLWithPath: path))) != nil
            else {
                return [
                    "name": name,
                    "path": path,
                    "width": 0,
                    "height": 0,
                    "visiblePixels": false,
                    "captureMethod": captureMethod,
                ]
            }
            return [
                "name": name,
                "path": path,
                "width": bitmap.pixelsWide,
                "height": bitmap.pixelsHigh,
                "visiblePixels": bookmarkBitmapHasVisiblePixels(bitmap),
                "captureMethod": captureMethod,
            ]
        }
        func captureWebView(_ webView: WKWebView) -> [String: Any] {
            let directory = ProcessInfo.processInfo.environment[
                "CAIRN_NON_SOURCE_CAPTURE_DIR"
            ] ?? "/tmp/cairn-non-source-captures"
            try? FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true
            )
            let path = URL(fileURLWithPath: directory)
                .appendingPathComponent("dark-html.png").path
            try? FileManager.default.removeItem(atPath: path)
            var snapshot: NSImage?
            var snapshotError: String?
            var snapshotErrorDomain: String?
            var snapshotErrorCode: Int?
            var completed = false
            webView.layoutSubtreeIfNeeded()
            webView.displayIfNeeded()
            for _ in 0..<4 { pumpRunLoop() }
            let configuration = WKSnapshotConfiguration()
            configuration.rect = webView.bounds
            configuration.afterScreenUpdates = true
            webView.takeSnapshot(with: configuration) { image, error in
                snapshot = image
                snapshotError = error?.localizedDescription
                if let error {
                    let error = error as NSError
                    snapshotErrorDomain = error.domain
                    snapshotErrorCode = error.code
                }
                completed = true
            }
            let deadline = Date(timeIntervalSinceNow: 5)
            while !completed, Date() < deadline {
                pumpRunLoop()
            }
            guard let snapshot else {
                return [
                    "name": "dark-html",
                    "path": path,
                    "width": 0,
                    "height": 0,
                    "visiblePixels": false,
                    "error": snapshotError ?? "snapshot timed out",
                    "errorDomain": snapshotErrorDomain ?? "",
                    "errorCode": snapshotErrorCode ?? 0,
                    "captureMethod": "none",
                    "webViewInWindow": webView.window != nil,
                    "webViewHidden": webView.isHiddenOrHasHiddenAncestor,
                    "webViewFrameWidth": webView.frame.width,
                    "webViewFrameHeight": webView.frame.height,
                    "webViewURL": webView.url?.absoluteString ?? "",
                    "webViewLoading": webView.isLoading,
                    "webViewProgress": webView.estimatedProgress,
                ]
            }
            return writeSnapshotImage(
                snapshot,
                name: "dark-html",
                captureMethod: "WKWebView.takeSnapshot"
            )
        }
        func previewContentSizeIsStable() -> Bool {
            guard let contentView = window.contentView else { return false }
            let size = contentView.bounds.size
            return abs(size.width - openedContentSize.width) <= 1
                && abs(size.height - openedContentSize.height) <= 1
        }
        func recordContentSize(_ name: String) {
            let size = window.contentView?.bounds.size ?? .zero
            contentSizes[name] = [
                "width": size.width,
                "height": size.height,
                "stable": previewContentSizeIsStable(),
            ]
        }

        let projectStartedAt = ContinuousClock.now
        controller.openProject(root: root)
        let projectIsReady: () -> Bool = {
            if case .ready = self.model.projectState { return true }
            return false
        }
        let ready = waitUntil(timeout: 30) {
            model.snapshotPhase == .fullReady
                && model.fileTree != nil
                && projectIsReady()
        }
        let projectReadyMS = milliseconds(since: projectStartedAt)
        guard ready, let tree = model.fileTree else {
            finish(
                passed: false,
                checks: ["projectReady": false],
                projectReadyMS: projectReadyMS,
                treePaths: [],
                files: [],
                captures: [],
                contentSizes: [:],
                history: [:],
                error: "project did not reach fullReady"
            )
        }
        var treePaths: [String] = []
        func collect(_ nodes: [FileTreeNode]) {
            for node in nodes {
                if node.isDirectory {
                    collect(node.children)
                } else if let path = relativePath(node.url) {
                    treePaths.append(path)
                }
            }
        }
        collect(tree.children)
        treePaths.sort()
        let requiredPaths = [
            "main.rs", "README.md", "page.html", "image.png",
            "paper.pdf", "notes.txt",
        ]
        var checks: [String: Bool] = [
            "projectReady": true,
            "treeContainsRequiredFiles": requiredPaths.allSatisfy {
                treePaths.contains($0)
            },
        ]
        var files: [[String: Any]] = []
        var captures: [[String: Any]] = []
        var history: [String: Any] = [:]

        let readme = root.appendingPathComponent("README.md")
        let guide = root.appendingPathComponent("docs/guide.md")

        let markdownSelected = select(readme)
        let markdownState = controller.selfTestReaderPreviewKind == "Markdown"
        let markdownView = labeled("Markdown preview")
        recordContentSize("markdown")
        checks["markdownPreview"] = markdownSelected
            && markdownState
            && visible(markdownView)
            && controller.selfTestReaderPreviewText?.contains("guide") == true
            && sourceControlsAreLocked()
            && previewContentSizeIsStable()
        files.append([
            "path": "README.md",
            "kind": controller.selfTestReaderPreviewKind ?? "",
            "accessibilityLabel": markdownView?.accessibilityLabel() ?? "",
            "frameWidth": markdownView?.frame.width ?? 0,
            "frameHeight": markdownView?.frame.height ?? 0,
            "visible": visible(markdownView),
        ])
        var light = ReaderSettings()
        light.theme = .light
        controller.applyReaderSettings(light)
        pumpRunLoop()
        let lightCapture = capture("light-markdown")
        captures.append(lightCapture)
        checks["captureLightMarkdown"] = lightCapture["visiblePixels"] as? Bool == true

        let historyBeforeLink = model.navigationHistory.records.count
        let linkActivated = controller.selfTestActivatePreviewLink(at: 0)
        let guideSelected = waitUntil(timeout: 5) {
            controller.displayedReaderFile?.standardizedFileURL
                == guide.standardizedFileURL
        }
        history["beforeMarkdownLink"] = historyBeforeLink
        history["afterMarkdownLink"] = model.navigationHistory.records.count
        history["markdownLinkActivated"] = linkActivated
        let historyAfterLink = model.navigationHistory.records.count
        controller.goBack(nil)
        let back = waitUntil(timeout: 5) {
            controller.displayedReaderFile?.standardizedFileURL
                == readme.standardizedFileURL
        }
        controller.goForward(nil)
        let forward = waitUntil(timeout: 5) {
            controller.displayedReaderFile?.standardizedFileURL
                == guide.standardizedFileURL
        }
        history["afterBack"] = model.navigationHistory.records.count
        history["afterForward"] = model.navigationHistory.records.count
        history["trailEdges"] = model.readingTrail.edges.count
        checks["markdownLinkHistory"] = linkActivated
            && guideSelected
            && back
            && forward
            && historyAfterLink == historyBeforeLink + 1
            && model.readingTrail.edges.isEmpty

        let page = root.appendingPathComponent("page.html")
        let htmlSelected = select(page)
        pumpRunLoop()
        let htmlWebView = labeled("HTML preview") as? WKWebView
            ?? window.contentView.flatMap { content in
                allViews(in: content).compactMap { $0 as? WKWebView }.first
            }
        let htmlLoaded = waitUntil(timeout: 5) {
            controller.selfTestReaderHTMLFinished
                && htmlWebView != nil
                && htmlWebView?.isLoading == false
        }
        let htmlKind = controller.selfTestReaderPreviewKind
        recordContentSize("html")
        let htmlWebViewHasNonPersistentDataStore =
            htmlWebView?.configuration.websiteDataStore.isPersistent == false
        let htmlWebViewHasJavaScriptDisabled =
            htmlWebView?.configuration.defaultWebpagePreferences
                .allowsContentJavaScript == false
        checks["htmlPreview"] = htmlSelected
            && htmlKind == "HTML"
            && htmlLoaded
            && visible(htmlWebView)
            && htmlWebViewHasNonPersistentDataStore
            && htmlWebViewHasJavaScriptDisabled
            && htmlWebView?.accessibilityLabel() == "HTML preview"
            && sourceControlsAreLocked()
            && previewContentSizeIsStable()
        let htmlWidth = htmlWebView?.frame.width ?? 0
        let htmlHeight = htmlWebView?.frame.height ?? 0
        files.append([
            "path": "page.html",
            "kind": htmlKind ?? "",
            "accessibilityLabel": htmlWebView?.accessibilityLabel() ?? "",
            "frameWidth": htmlWidth,
            "frameHeight": htmlHeight,
            "visible": visible(htmlWebView),
            "loaded": htmlLoaded,
            "didFinish": controller.selfTestReaderHTMLFinished,
            "loadError": controller.selfTestReaderHTMLLoadError ?? "",
            "javaScriptEnabled": !htmlWebViewHasJavaScriptDisabled,
            "dataStorePersistent": !htmlWebViewHasNonPersistentDataStore,
        ])
        var dark = ReaderSettings()
        dark.theme = .dark
        controller.applyReaderSettings(dark)
        let htmlReloaded = waitUntil(timeout: 5) {
            controller.selfTestReaderHTMLFinished
                && htmlWebView != nil
                && htmlWebView?.isLoading == false
        }
        pumpRunLoop()
        let darkCapture: [String: Any] = if htmlReloaded,
                                            let htmlWebView
        {
            captureWebView(htmlWebView)
        } else {
            [
                "name": "dark-html",
                "path": "",
                "width": 0,
                "height": 0,
                "visiblePixels": false,
                "error": controller.selfTestReaderHTMLLoadError
                    ?? "HTML did not finish loading",
            ]
        }
        captures.append(darkCapture)
        checks["captureDarkHTML"] = htmlReloaded
            && darkCapture["visiblePixels"] as? Bool == true

        let image = root.appendingPathComponent("image.png")
        let imageSelected = select(image)
        let imageView = labeled("Image preview") as? NSImageView
        let imageKind = controller.selfTestReaderPreviewKind
        recordContentSize("image")
        checks["imagePreview"] = imageSelected
            && imageKind == "Image"
            && imageView?.image != nil
            && visible(imageView)
            && sourceControlsAreLocked()
            && previewContentSizeIsStable()
        files.append([
            "path": "image.png",
            "kind": imageKind ?? "",
            "accessibilityLabel": imageView?.accessibilityLabel() ?? "",
            "frameWidth": imageView?.frame.width ?? 0,
            "frameHeight": imageView?.frame.height ?? 0,
            "visible": visible(imageView),
            "hasImage": imageView?.image != nil,
        ])
        var siClassic = ReaderSettings()
        siClassic.theme = .siClassic
        controller.applyReaderSettings(siClassic)
        pumpRunLoop()
        let imageCapture = capture("si-image")
        captures.append(imageCapture)
        checks["captureSIImage"] = imageCapture["visiblePixels"] as? Bool == true

        let pdf = root.appendingPathComponent("paper.pdf")
        let pdfSelected = select(pdf)
        let pdfView = labeled("PDF preview") as? PDFView
        let pdfKind = controller.selfTestReaderPreviewKind
        recordContentSize("pdf")
        checks["pdfPreview"] = pdfSelected
            && pdfKind == "PDF"
            && (pdfView?.document?.pageCount ?? 0) > 0
            && visible(pdfView)
            && sourceControlsAreLocked()
            && previewContentSizeIsStable()
        files.append([
            "path": "paper.pdf",
            "kind": pdfKind ?? "",
            "accessibilityLabel": pdfView?.accessibilityLabel() ?? "",
            "frameWidth": pdfView?.frame.width ?? 0,
            "frameHeight": pdfView?.frame.height ?? 0,
            "visible": visible(pdfView),
            "pageCount": pdfView?.document?.pageCount ?? 0,
        ])
        let pdfCapture: [String: Any]
        if let pdfView,
           let page = pdfView.currentPage ?? pdfView.document?.page(at: 0)
        {
            let targetSize = NSSize(
                width: max(1, pdfView.bounds.width),
                height: max(1, pdfView.bounds.height)
            )
            pdfCapture = writeSnapshotImage(
                page.thumbnail(of: targetSize, for: .mediaBox),
                name: "si-pdf",
                captureMethod: "PDFPage.thumbnail"
            )
        } else {
            pdfCapture = [
                "name": "si-pdf",
                "path": "",
                "width": 0,
                "height": 0,
                "visiblePixels": false,
                "captureMethod": "PDFPage.thumbnail",
            ]
        }
        captures.append(pdfCapture)
        checks["captureSIPDF"] = pdfCapture["visiblePixels"] as? Bool == true

        let notes = root.appendingPathComponent("notes.txt")
        let notesSelected = select(notes)
        let notesKind = controller.selfTestReaderPreviewKind
        let notesPreviewText = controller.selfTestReaderPreviewText
        recordContentSize("plainText")
        let notesText = (try? Data(contentsOf: notes))
            .flatMap { String(data: $0, encoding: .utf8) }
        checks["plainTextPreview"] = notesSelected
            && notesKind == "Plain text"
            && notesPreviewText == notesText
            && sourceControlsAreLocked()
            && previewContentSizeIsStable()
        files.append([
            "path": "notes.txt",
            "kind": notesKind ?? "",
            "accessibilityLabel": "Plain text preview",
            "frameWidth": 0,
            "frameHeight": 0,
            "visible": visible(labeled("Plain text preview")),
        ])

        let main = root.appendingPathComponent("main.rs")
        let sourceSelected = select(main)
        let sourceHeight = controller.selfTestReadingHeightHeader
        checks["sourceSurfaceRestored"] = sourceSelected
            && controller.selfTestReaderPreviewKind == nil
            && controller.selfTestLeftReaderBytes != nil
            && controller.canFindInFile
            && sourceHeight.enabled
            && !sourceHeight.hidden
        history["sourceRestored"] = checks["sourceSurfaceRestored"] == true
        history["treeCount"] = treePaths.count
        let passed = checks.values.allSatisfy { $0 }
        finish(
            passed: passed,
            checks: checks,
            projectReadyMS: projectReadyMS,
            treePaths: treePaths,
            files: files,
            captures: captures,
            contentSizes: contentSizes,
            history: history
        )
    }

    func runDiffSelfTest(root: URL) -> Never {
        launch(offscreen: true)
        guard let controller = windowController else {
            finishDiffSelfTest(error: "window unavailable")
        }
        let contentSize = NSSize(width: 1_600, height: 1_000)
        controller.window?.setContentSize(contentSize)
        controller.window?.contentView?.setFrameSize(contentSize)
        controller.window?.appearance = NSAppearance(named: .darkAqua)
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
            finishDiffSelfTest(error: "project or HEAD~1 unavailable")
        }
        emitDiffStep("openProject", controller: controller)

        controller.selfTestShowCommitPicker(compare: false)
        pumpRunLoop()
        let versionPickerGeometry = controller.selfTestCommitPickerGeometry(
            compare: false
        )
        controller.selfTestCloseCommitPicker(compare: false)
        let versionPickerGeometryValid =
            versionPickerGeometry?.shown == true
            && (versionPickerGeometry?.contentHeight ?? 0) >= 202
            && (versionPickerGeometry?.viewportHeight ?? 0) >= 116
            && versionPickerGeometry?.visibleCommitRows == 2
            && versionPickerGeometry?.commitRowFrames.allSatisfy {
                $0.width > 0 && $0.height > 0
            } == true
        emitDiffStep("darkVersionPickerGeometry", controller: controller, extra: [
            "contentHeight": versionPickerGeometry?.contentHeight ?? 0,
            "viewportHeight": versionPickerGeometry?.viewportHeight ?? 0,
            "commitRowFrames": versionPickerGeometry?.commitRowFrames.map(
                NSStringFromRect
            ) ?? [],
            "visibleCommitRows": versionPickerGeometry?.visibleCommitRows ?? 0,
            "valid": versionPickerGeometryValid,
        ])

        var selectedRevision: String?
        var selectedTarget: DiffSelfTestTarget?
        for commit in model.commitPicker.commits.dropFirst() {
            guard let snapshot = try? CommitSnapshot(
                repositoryURL: root,
                revision: commit.fullSHA
            ), let target = diffSelfTestTarget(root: root, snapshot: snapshot) else {
                continue
            }
            selectedRevision = commit.fullSHA
            selectedTarget = target
            break
        }
        guard let revision = selectedRevision, let target = selectedTarget else {
            finishDiffSelfTest(error: "no earlier commit has a multi-line source diff")
        }

        controller.openFileForSelfTest(target.file)
        guard waitUntil(timeout: 5, condition: {
            self.model.selectedFile == target.file
                && controller.displayedReaderFile == target.file
        }) else {
            finishDiffSelfTest(error: "left reader did not open target file")
        }
        emitDiffStep("openFile", controller: controller, extra: [
            "file": target.path,
            "worktreeByteCount": target.worktreeBytes.count,
        ])

        controller.applyPanelPreset(.compare)
        pumpRunLoop()
        controller.selfTestShowCommitPicker(compare: true)
        pumpRunLoop()
        let comparePickerGeometry = controller.selfTestCommitPickerGeometry(
            compare: true
        )
        controller.selfTestCloseCommitPicker(compare: true)
        let comparePickerGeometryValid =
            comparePickerGeometry?.shown == true
            && (comparePickerGeometry?.contentHeight ?? 0) >= 202
            && (comparePickerGeometry?.viewportHeight ?? 0) >= 116
            && comparePickerGeometry?.visibleCommitRows == 2
            && comparePickerGeometry?.commitRowFrames.allSatisfy {
                $0.width > 0 && $0.height > 0
            } == true
        emitDiffStep("darkComparePickerGeometry", controller: controller, extra: [
            "contentHeight": comparePickerGeometry?.contentHeight ?? 0,
            "viewportHeight": comparePickerGeometry?.viewportHeight ?? 0,
            "commitRowFrames": comparePickerGeometry?.commitRowFrames.map(
                NSStringFromRect
            ) ?? [],
            "visibleCommitRows": comparePickerGeometry?.visibleCommitRows ?? 0,
            "valid": comparePickerGeometryValid,
        ])
        guard controller.selectCompareCommit(revision),
              waitUntil(timeout: 30, condition: {
                  self.model.compare.rightRevision == revision
                      && self.model.compare.diff != nil
                      && controller.selfTestRightReaderBytes != nil
              })
        else {
            finishDiffSelfTest(error: "right CommitPicker selection did not finish")
        }
        pumpRunLoop()

        let rightReaderMatchesCommitBlob = controller.selfTestRightReaderBytes
            == target.commitBytes
        let rightReaderDiffersFromWorktree = controller.selfTestRightReaderBytes
            != target.worktreeBytes
        emitDiffStep("selectHEAD~1", controller: controller, extra: [
            "revision": revision,
            "rightReaderByteCount": controller.selfTestRightReaderBytes?.count ?? 0,
            "commitBlobByteCount": target.commitBytes.count,
            "rightReaderMatchesCommitBlob": rightReaderMatchesCommitBlob,
            "rightReaderDiffersFromWorktree": rightReaderDiffersFromWorktree,
        ])

        let actualGutterCounts = controller.selfTestGutterCounts
        let expectedGutterCounts = target.expected.gutterCounts
        let gutterCountsMatch = actualGutterCounts == expectedGutterCounts
        let gutterCoexistsWithLineNumbers =
            controller.selfTestGutterCoexistsWithLineNumbers
        var diffComputeMS = Double.greatestFiniteMagnitude
        for _ in 0 ..< 5 {
            let diffClock = ContinuousClock.now
            _ = DiffCore().compare(left: target.worktreeBytes, right: target.commitBytes)
            diffComputeMS = min(diffComputeMS, milliseconds(since: diffClock))
        }
        emitDiffStep("gutter", controller: controller, extra: [
            "gutterCounts": Self.jsonGutterCounts(actualGutterCounts),
            "expectedGutterCounts": Self.jsonGutterCounts(expectedGutterCounts),
            "gutterCountsMatch": gutterCountsMatch,
            "gutterCoexistsWithLineNumbers": gutterCoexistsWithLineNumbers,
            "diffComputeMS": diffComputeMS,
            "leftLineCount": target.expected.leftLineCount,
            "rightLineCount": target.expected.rightLineCount,
        ])

        let navigation = controller.selfTestNavigateNextDiffHunk()
        pumpRunLoop()
        let hunkNavMoved = navigation.before != nil
            && navigation.after != nil
            && navigation.before != navigation.after
            && model.compare.selectedHunkIndex == 0
        emitDiffStep("nextHunk", controller: controller, extra: [
            "beforeLine": (navigation.before as Any?) ?? NSNull(),
            "afterLine": (navigation.after as Any?) ?? NSNull(),
            "selectedHunkIndex": (model.compare.selectedHunkIndex as Any?) ?? NSNull(),
            "hunkNavMoved": hunkNavMoved,
        ])

        func comparisonCloseButton(in view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.accessibilityLabel() == "Close Comparison" {
                return button
            }
            return view.subviews.lazy.compactMap(comparisonCloseButton).first
        }
        let closeHeaderButton = controller.window?.contentView.flatMap(comparisonCloseButton)
        let closeHeaderAvailable = closeHeaderButton?.isEnabled == true
            && closeHeaderButton?.action != nil
            && closeHeaderButton?.target != nil
        controller.applyPanelPreset(.reading)
        pumpRunLoop()
        let readingPresetCollapsedRight = controller.selfTestSecondaryReaderCollapsed
        let readingPresetPreservedComparison = model.compare.rightRevision == revision
            && model.compare.diff != nil
        emitDiffStep("readingPreset", controller: controller, extra: [
            "rightReaderCollapsed": readingPresetCollapsedRight,
            "comparisonPreserved": readingPresetPreservedComparison,
        ])

        let leftReaderBytesBeforeClear = controller.selfTestLeftReaderBytes
        let closeItem = NSApp.mainMenu?.items.compactMap(\.submenu)
            .first { $0.title == "View" }?.item(withTitle: "Close Comparison")
        let closeActionDispatched: Bool
        if let closeItem, let action = closeItem.action, validateMenuItem(closeItem) {
            closeActionDispatched = NSApp.sendAction(action, to: closeItem.target, from: closeItem)
        } else {
            closeActionDispatched = false
        }
        pumpRunLoop()
        let closeClearedState = model.compare.rightRevision == nil
            && model.compare.rightSnapshotID == nil && model.compare.diff == nil
        let closeCollapsedRight = controller.selfTestSecondaryReaderCollapsed
        let closeClearedMarkers = controller.selfTestGutterCounts.isEmpty
        let closeDisabledAfterClosing = closeItem.map { !validateMenuItem($0) } ?? false
        emitDiffStep("closeComparison", controller: controller, extra: [
            "actionDispatched": closeActionDispatched,
            "stateCleared": closeClearedState,
            "markersCleared": closeClearedMarkers,
        ])
        var siClassicSettings = readerSettings
        siClassicSettings.theme = .siClassic
        controller.applyReaderSettings(siClassicSettings)
        pumpRunLoop()
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.window?.displayIfNeeded()
        let themeSwitchPreservedLeftReader = controller.selfTestLeftReaderBytes
            == leftReaderBytesBeforeClear
        let themeSwitchClearedRightReader = controller.selfTestRightReaderBytes == nil
        emitDiffStep("clearCompareAndApplySIClassic", controller: controller, extra: [
            "themeSwitchPreservedLeftReader": themeSwitchPreservedLeftReader,
            "themeSwitchClearedRightReader": themeSwitchClearedRightReader,
        ])

        finishDiffSelfTest(
            controller: controller,
            checks: [
                "darkVersionPickerGeometryValid": versionPickerGeometryValid,
                "darkComparePickerGeometryValid": comparePickerGeometryValid,
                "rightReaderMatchesCommitBlob": rightReaderMatchesCommitBlob,
                "rightReaderDiffersFromWorktree": rightReaderDiffersFromWorktree,
                "gutterCountsMatch": gutterCountsMatch,
                "gutterCoexistsWithLineNumbers":
                    gutterCoexistsWithLineNumbers,
                "hunkNavMoved": hunkNavMoved,
                "readingPresetCollapsedRight": readingPresetCollapsedRight,
                "readingPresetPreservedComparison": readingPresetPreservedComparison,
                "closeComparisonHeaderAvailable": closeHeaderAvailable,
                "closeComparisonMenuActionDispatched": closeActionDispatched,
                "closeComparisonClearedState": closeClearedState,
                "closeComparisonCollapsedRight": closeCollapsedRight,
                "closeComparisonClearedMarkers": closeClearedMarkers,
                "closeComparisonDisabledAfterClosing": closeDisabledAfterClosing,
                "themeSwitchPreservedLeftReader": themeSwitchPreservedLeftReader,
                "themeSwitchClearedRightReader": themeSwitchClearedRightReader,
            ],
            gutterCounts: actualGutterCounts
        )
    }

    private func diffSelfTestTarget(
        root: URL,
        snapshot: CommitSnapshot
    ) -> DiffSelfTestTarget? {
        let candidates = snapshot.listFiles().map(\.path).filter {
            URL(fileURLWithPath: $0).pathExtension == "rs"
        }.sorted()
        for path in candidates {
            let file = root.appendingPathComponent(path).standardizedFileURL
            guard let worktree = try? Array(Data(contentsOf: file)),
                  let committed = try? snapshot.readBytes(path: path),
                  worktree != committed
            else { continue }
            let expected = DiffCore().compare(left: worktree, right: committed)
            guard !expected.truncated,
                  !expected.hunks.isEmpty,
                  max(expected.leftLineCount, expected.rightLineCount) > 1
            else { continue }
            return DiffSelfTestTarget(
                file: file,
                path: path,
                worktreeBytes: worktree,
                commitBytes: committed,
                expected: expected
            )
        }
        return nil
    }

    private func emitDiffStep(
        _ step: String,
        controller: MainWindowController?,
        extra: [String: Any] = [:]
    ) {
        var object: [String: Any] = [
            "step": step,
            "leftRevision": model.currentRevision ?? "worktree",
            "rightRevision": (model.compare.rightRevision as Any?) ?? NSNull(),
            "file": (model.selectedFile?.path as Any?) ?? NSNull(),
            "hunkCount": model.compare.diff?.hunks.count ?? 0,
            "rightReaderCollapsed": controller?.selfTestSecondaryReaderCollapsed ?? true,
        ]
        for (key, value) in extra { object[key] = value }
        Self.writeJSON(object)
    }

    private func finishDiffSelfTest(
        controller: MainWindowController? = nil,
        checks: [String: Bool] = [:],
        gutterCounts: [DiffCore.MarkerKind: Int] = [:],
        error: String? = nil
    ) -> Never {
        let passed = error == nil
            && !checks.isEmpty
            && checks.values.allSatisfy { $0 }
        var summary: [String: Any] = checks
        summary["step"] = "summary"
        summary["passed"] = passed
        summary["gutterCounts"] = Self.jsonGutterCounts(gutterCounts)
        summary["rightReaderCollapsed"] = controller?.selfTestSecondaryReaderCollapsed
            ?? true
        if let error { summary["error"] = error }
        Self.writeJSON(summary)
        Self.exitSelfTest(channel: "diff", status: passed ? 0 : 1)
    }

    private static func jsonGutterCounts(
        _ counts: [DiffCore.MarkerKind: Int]
    ) -> [String: Int] {
        [
            "added": counts[.added] ?? 0,
            "removed": counts[.removed] ?? 0,
            "changed": counts[.changed] ?? 0,
        ]
    }

    private var exactRelationEdgeCount: Int {
        exactRelationEdges(in: model).count
    }

    private func exactRelationEdgeCount(in model: AppModel) -> Int {
        exactRelationEdges(in: model).count
    }

    private func finishPythonSelfTest(
        coldFileCount: Int,
        coldReused: Int,
        coldExtracted: Int,
        hotFileCount: Int,
        hotReused: Int,
        hotExtracted: Int,
        checks: [String: Bool],
        startedAt: ContinuousClock.Instant
    ) -> Never {
        let passed = checks.values.allSatisfy { $0 }
        Self.writeJSON([
            "step": "summary",
            "channel": "python",
            "passed": passed,
            "cold": [
                "fileCount": coldFileCount,
                "reused": coldReused,
                "extracted": coldExtracted,
            ],
            "hot": [
                "fileCount": hotFileCount,
                "reused": hotReused,
                "extracted": hotExtracted,
            ],
            "checks": checks,
            "elapsedMS": milliseconds(since: startedAt),
        ])
        Self.exitSelfTest(channel: "python", status: passed ? 0 : 1)
    }

    private func finishPythonSelfTest(
        error: String,
        startedAt: ContinuousClock.Instant
    ) -> Never {
        Self.writeJSON([
            "step": "summary",
            "channel": "python",
            "passed": false,
            "error": error,
            "elapsedMS": milliseconds(since: startedAt),
        ])
        Self.exitSelfTest(channel: "python", status: 1)
    }

    func runPythonSelfTest(root inputRoot: URL) async -> Never {
        launch(offscreen: true, measuresIdleFootprint: false)
        let startedAt = ContinuousClock.now
        let root = inputRoot.standardizedFileURL
        let relativeMemoryFile = "src/mcp/shared/memory.py"
        let memoryFile = root.appendingPathComponent(relativeMemoryFile)
            .standardizedFileURL
        let compareRelativeFile = "src/mcp/server/fastmcp/server.py"
        let compareFile = root.appendingPathComponent(compareRelativeFile)
            .standardizedFileURL
        let hierarchyRelativeFile = "src/mcp/cli/cli.py"
        let hierarchyFile = root.appendingPathComponent(hierarchyRelativeFile)
            .standardizedFileURL
        let pythonModel = self.model
        let pythonRecentStore = self.recentProjectsStore

        func pythonReady() -> Bool {
            if case let .ready(session, _) = pythonModel.projectState {
                return session.analysisProfile.language == .python
            }
            return false
        }
        func finish(_ error: String) -> Never {
            finishPythonSelfTest(error: error, startedAt: startedAt)
        }
        func pythonWait(
            timeout: TimeInterval,
            _ condition: @escaping () -> Bool
        ) async -> Bool {
            let deadline = Date(timeIntervalSinceNow: timeout)
            while Date() < deadline {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return condition()
        }

        guard let controller = windowController else {
            finish("window unavailable")
        }
        guard previousCommitRevision(root: root) != nil else {
            finish("HEAD~1 unavailable")
        }

        controller.openProject(root: root)
        guard await pythonWait(timeout: 120, {
            if case .failed = pythonModel.projectState { return true }
            if case .ready = pythonModel.projectState {
                return pythonModel.fileTree != nil
                    && !pythonModel.commitPicker.isLoading
                    && pythonModel.snapshotPhase == .fullReady
                    && pythonReady()
            }
            return false
        }), case let .ready(session, context) = pythonModel.projectState,
              pythonModel.snapshotPhase == .fullReady,
              pythonModel.fileTree != nil,
              session.analysisProfile.language == .python,
              let previousRevision = pythonModel.commitPicker.commits
                .dropFirst().first?.fullSHA
        else {
            finish("python project or HEAD~1 commit unavailable")
        }
        let coldSession = session
        let coldContext = context
        let fileCount = pythonModel.fileTree?.fileCount ?? 0
        let coldStats = coldSession.stats
        let sourceFiles = coldSession.manifest.files.filter { $0.detectedLanguage == .python }
        let semanticIndexOnlyPython = coldSession.manifest.files.allSatisfy { file in
            let mode = LanguageMode.classify(
                path: coldSession.paths.resolve(file.pathID), language: .python
            )
            return file.detectedLanguage == mode?.language
                && coldSession.content(at: file.pathID)?.0.languageMode == mode
        } && coldSession.contentIndexes.keys.allSatisfy { $0.languageMode.language == .python }
        let treeFiles = pythonFiles(in: pythonModel.fileTree?.children ?? [])
        let snapshotFiles = coldSession.manifest.files.filter {
            $0.fileMode == .regular || $0.fileMode == .lfsPointer
        }.map { root.appendingPathComponent(coldSession.paths.resolve($0.pathID)).standardizedFileURL }
        let treeMatchesSnapshot = Set(treeFiles) == Set(snapshotFiles)
        guard treeMatchesSnapshot, sourceFiles.count == 204, semanticIndexOnlyPython else {
            finish("Python workspace/index mismatch: tree=\(treeFiles.count) snapshot=\(snapshotFiles.count) sources=\(sourceFiles.count) semanticIndexOnlyPython=\(semanticIndexOnlyPython)")
        }
        let configPath = "pyproject.toml"
        let configFile = root.appendingPathComponent(configPath).standardizedFileURL
        guard let config = coldSession.manifest.files.first(where: {
                  coldSession.paths.resolve($0.pathID) == configPath
              }), config.detectedLanguage == nil,
              let configBytes = try? Array(Data(contentsOf: configFile)),
              ContentID.sha256(of: configBytes) == config.contentID,
              controller.selectFileInSidebar(configFile),
              await pythonWait(timeout: 30, {
                  controller.displayedReaderFile?.standardizedFileURL == configFile
                      && controller.selfTestReaderPreviewKind == "Plain text"
                      && controller.selfTestReaderPreviewText == String(decoding: configBytes, as: UTF8.self)
                      && pythonModel.tabStrip.activeDocument == nil
              })
        else { finish("Python configuration preview did not match the worktree snapshot") }
        Self.writeJSON([
            "step": "cold-open",
            "language": "python",
            "projectUnit": coldSession.analysisProfile.projectUnitName,
            "fileCount": fileCount,
            "sourceFileCount": sourceFiles.count,
            "treeMatchesSnapshot": treeMatchesSnapshot,
            "configurationPreview": configPath,
            "reused": coldStats.reusedCount,
            "extracted": coldStats.extractedCount,
            "snapshotPhase": pythonModel.snapshotPhase?.rawValue as Any,
            "elapsedMS": milliseconds(since: startedAt),
        ])

        guard await pythonWait(timeout: 90, {
            pythonModel.exactCoordinator.readiness == .ready
        }), let attribution = pythonModel.exactCoordinator.attribution
        else {
            finish("Pyright missing/unready: \(pythonModel.exactCoordinator.readiness)")
        }

        do {
            let contentHits = try await contentSearchHits(
                session: coldSession,
                context: coldContext,
                query: ContentSearchQuery(
                    pattern: "create_client_server_memory_streams",
                    caseSensitive: true
                )
            )
            let symbolHits = try coldSession.searchSymbols(
                query: "create_client_server_memory_streams",
                limit: 20,
                boost: SearchBoost(),
                context: coldContext
            )
            guard contentHits.contains(where: { $0.hasSuffix(relativeMemoryFile) }),
                  symbolHits.contains(where: { $0.path.hasSuffix(relativeMemoryFile) })
            else {
                finish("search did not hit memory.py")
            }
            Self.writeJSON([
                "step": "search",
                "contentHit": relativeMemoryFile,
                "symbolHit": relativeMemoryFile,
                "elapsedMS": milliseconds(since: startedAt),
            ])
        } catch {
            finish("search failed: \(error)")
        }

        guard controller.selectFileInSidebar(memoryFile),
              await pythonWait(timeout: 30, {
                  controller.displayedReaderFile?.standardizedFileURL
                      == memoryFile.standardizedFileURL
                      && pythonModel.tabStrip.activeDocument != nil
                      && controller.selfTestStyledFragmentCount > 0
              })
        else {
            finish("could not open memory.py in reader")
        }
        let readerBytes = controller.selfTestLeftReaderBytes ?? []
        let activeDocument = pythonModel.tabStrip.activeDocument
        let outlineCount = activeDocument?.outlineFacets.count ?? 0
        let bindingCount = activeDocument?.localBindings.count ?? 0
        let localReferenceCount = activeDocument?.referencesByBinding
            .compactMap(\.count).reduce(0, +) ?? 0
        let styledFragments = controller.selfTestStyledFragmentCount
        let foldRegions = activeDocument?.foldRegions.count ?? 0
        guard !readerBytes.isEmpty,
              outlineCount > 0,
              bindingCount > 0,
              localReferenceCount > 0,
              styledFragments > 0,
              foldRegions > 0
        else {
            finish("Reader/outline/local reference unavailable")
        }
        let needleOffsets = utf8Offsets(
            of: "create_client_server_memory_streams",
            in: readerBytes
        )
        guard let callOffset = needleOffsets.dropFirst().first
            .flatMap(UInt32.init)
        else {
            finish("call-site offset unavailable")
        }
        let fuzzy = await pythonModel.contextWindow.resolvedCandidate(
            file: relativeMemoryFile,
            offset: callOffset
        )
        guard let fuzzySymbol = fuzzy?.symbol else {
            finish("fuzzy context had no Python symbol")
        }
        controller.selfTestReaderRelation(
            offset: callOffset,
            direction: .references
        )
        let localRelationLoaded = await pythonWait(timeout: 30) {
            guard let root = pythonModel.relationTree.root,
                  !(root.children?.contains { $0.kind == .loading } ?? true)
            else { return false }
            return !self.relationEdgeNodes(in: root).isEmpty
        }
        guard localRelationLoaded else {
            finish("local relation tree did not load")
        }
        Self.writeJSON([
            "step": "reader-context",
            "outlineFacets": outlineCount,
            "localBindings": bindingCount,
            "localReferences": localReferenceCount,
            "styledFragments": styledFragments,
            "foldRegions": foldRegions,
            "fuzzySymbol": fuzzySymbol.localIndex,
            "localRelationLoaded": localRelationLoaded,
            "elapsedMS": milliseconds(since: startedAt),
        ])

        guard case let .completed(definitions) =
            await pythonModel.exactCoordinator.definition(
                file: relativeMemoryFile,
                byteOffset: callOffset,
                generation: coldContext.generation
            ),
            !definitions.isEmpty
        else {
            finish("Pyright definition unavailable")
        }

        await pythonModel.relationTree.setRoot(
            target: .engine(fuzzySymbol),
            direction: .references
        )?.value
        let referenceCount = exactRelationEdgeCount(in: pythonModel)

        guard let hierarchyBytes = try? Array(Data(contentsOf: hierarchyFile)),
              let hierarchyDeclOffset = utf8Offsets(
                  of: "def _parse_file_path",
                  in: hierarchyBytes
              ).first,
              let hierarchyOffset = utf8Offsets(
                  of: "_parse_file_path",
                  in: Array(hierarchyBytes.dropFirst(hierarchyDeclOffset))
              ).first.map({ hierarchyDeclOffset + $0 }).flatMap(UInt32.init),
              let hierarchyCandidate = await pythonModel.contextWindow
                .resolvedCandidate(
                    file: hierarchyRelativeFile,
                    offset: hierarchyOffset
                ),
              let hierarchySymbol = hierarchyCandidate.symbol
        else {
            finish("hierarchy symbol unavailable")
        }
        await pythonModel.relationTree.setRoot(
            target: .engine(hierarchySymbol),
            direction: .callers
        )?.value
        let callerCount = exactRelationEdgeCount(in: pythonModel)
        await pythonModel.relationTree.setRoot(
            target: .engine(hierarchySymbol),
            direction: .calls
        )?.value
        let callCount = exactRelationEdgeCount(in: pythonModel)
        let exactReferences = referenceCount > 0
        let callHierarchyExact = callerCount > 0 || callCount > 0
        Self.writeJSON([
            "step": "real-python-hierarchy-counts",
            "hierarchyFile": hierarchyRelativeFile,
            "hierarchyOffset": hierarchyOffset,
            "referenceCount": referenceCount,
            "callerCount": callerCount,
            "callCount": callCount,
            "elapsedMS": milliseconds(since: startedAt),
        ])
        guard callHierarchyExact else {
            finish("Pyright call hierarchy unavailable")
        }
        pythonModel.contextWindow.tokenClicked(
            file: hierarchyRelativeFile,
            offset: hierarchyOffset
        )
        let contextSymbolReady = await pythonWait(timeout: 5) {
            if pythonModel.contextWindow.symbolCandidate?.symbol
                == hierarchySymbol
            {
                return true
            }
            return false
        }
        guard contextSymbolReady else {
            finish("implementations context symbol unavailable")
        }
        // S5/D3: the global relation commands resolve from the Reader's
        // selection, so place it on the hierarchy symbol first.
        controller.selfTestNavigate(to: hierarchyFile, byteOffset: hierarchyOffset)
        controller.showRelations(direction: .implementations)
        let implementationsUnsupported = await pythonWait(timeout: 5) {
            if controller.selfTestVisibleRelationText.contains(where: {
                $0.contains("Verified unavailable: server does not support implementations")
            }) {
                return true
            }
            return false
        }
        guard implementationsUnsupported else {
            finish("implementations must be unsupported")
        }
        guard let hierarchyDocument = pythonModel.tabStrip.activeDocument,
              let hierarchyBinding = hierarchyDocument.localBinding(at: hierarchyOffset),
              hierarchyBinding.binding.kind == .letBinding,
              !hierarchyBinding.references.isEmpty,
              let hierarchyManifestFile = coldSession.manifest.files.first(where: {
                  coldSession.paths.resolve($0.pathID) == hierarchyRelativeFile
                      && $0.contentID == hierarchyDocument.contentID
              })
        else { finish("hierarchy Reader binding or snapshot identity unavailable") }
        controller.showRelations(direction: .references)
        let localReferencesAfterUnsupported = await pythonWait(timeout: 5) {
            guard pythonModel.exactCoordinator.readiness == .ready,
                  pythonModel.relationTree.direction == .references,
                  let root = pythonModel.relationTree.root,
                  root.kind == .root, root.symbol == nil, root.subtitle == "Local",
                  let target = root.target,
                  target.path == coldSession.paths.resolve(hierarchyManifestFile.pathID),
                  target.byteOffset == hierarchyBinding.binding.declarationRange.lowerBound,
                  hierarchyDocument.localBinding(at: target.byteOffset)?.bindingIndex
                    == hierarchyBinding.bindingIndex,
                  let edges = root.children,
                  edges.count == hierarchyBinding.references.count,
                  edges.allSatisfy({ $0.kind == .edge })
            else { return false }
            return zip(edges, hierarchyBinding.references).allSatisfy { edge, range in
                edge.target?.path == target.path
                    && edge.target?.byteOffset == range.lowerBound
                    && edge.line == hierarchyDocument.lineTable.lineColumn(at: range.lowerBound)?.line
            } && !controller.selfTestVisibleRelationText.contains {
                $0.contains("server does not support implementations")
            }
        }
        let referencesVisibleAfterUnsupported =
            controller.selfTestVisibleRelationText
        let coordinatorReadinessAfterUnsupported =
            pythonModel.exactCoordinator.readiness
        guard localReferencesAfterUnsupported else {
            Self.writeJSON([
                "step": "references-after-unsupported-diagnostic",
                "visible": referencesVisibleAfterUnsupported,
                "readiness": String(describing: coordinatorReadinessAfterUnsupported),
                "expectedBindingIndex": hierarchyBinding.bindingIndex,
                "expectedPath": hierarchyRelativeFile,
                "expectedReferenceOffsets": hierarchyBinding.references.map(\.lowerBound),
                "elapsedMS": milliseconds(since: startedAt),
            ])
            finish("local references after unsupported implementations did not match Reader binding")
        }
        await pythonModel.relationTree.setRoot(
            target: .engine(hierarchySymbol),
            direction: .references
        )?.value
        let exactReferencesAfterUnsupportedCount = exactRelationEdgeCount(in: pythonModel)
        let exactReferencesAfterUnsupported = pythonModel.exactCoordinator.readiness == .ready
            && pythonModel.relationTree.direction == .references
            && pythonModel.relationTree.root?.symbol == hierarchySymbol
            && exactReferencesAfterUnsupportedCount > 0
        guard exactReferencesAfterUnsupported else {
            finish("Pyright references after unsupported implementations unavailable")
        }
        Self.writeJSON([
            "step": "real-python-exact",
            "provider": attribution.provider,
            "toolVersion": attribution.toolVersion,
            "definitionTargets": definitions.count,
            "references": referenceCount,
            "localReferencesAfterUnsupported": hierarchyBinding.references.count,
            "exactReferencesAfterUnsupported": exactReferencesAfterUnsupportedCount,
            "callers": callerCount,
            "calls": callCount,
            "implementations": "unsupported",
            "elapsedMS": milliseconds(since: startedAt),
        ])

        guard let worktreeBytes = try? Array(Data(contentsOf: compareFile)),
              let commitSnapshot = try? CommitSnapshot(
                  repositoryURL: root,
                  revision: previousRevision
              ),
              let commitBytes = try? commitSnapshot.readBytes(
                  path: compareRelativeFile
              ),
              worktreeBytes != commitBytes
        else {
            finish("compare fixture or HEAD~1 diff unavailable")
        }
        controller.openFileForSelfTest(compareFile)
        guard await pythonWait(timeout: 30, {
            pythonModel.selectedFile?.standardizedFileURL
                == compareFile.standardizedFileURL
                && controller.displayedReaderFile?.standardizedFileURL
                    == compareFile.standardizedFileURL
        }) else {
            finish("compare main reader did not open")
        }
        controller.applyPanelPreset(.compare)
        guard controller.selectCompareCommit(previousRevision) else {
            finish("compare commit picker did not select")
        }
        guard await pythonWait(timeout: 60, {
            pythonModel.compare.diff != nil
                && pythonModel.compare.diff?.hunks.isEmpty == false
                && pythonModel.compare.diff?.truncated == false
                && pythonModel.compare.rightRevision == previousRevision
                && controller.selfTestRightReaderBytes != nil
        }) else {
            finish("compare HEAD~1 did not finish")
        }
        let rightBytes = controller.selfTestRightReaderBytes ?? []
        let rightReaderMatchesCommit = rightBytes == commitBytes
        let rightReaderDiffersFromWorktree = rightBytes != worktreeBytes
        guard rightReaderMatchesCommit, rightReaderDiffersFromWorktree else {
            finish("compare right reader mismatch")
        }
        Self.writeJSON([
            "step": "compare",
            "diffHunks": pythonModel.compare.diff?.hunks.count ?? 0,
            "truncated": pythonModel.compare.diff?.truncated ?? true,
            "rightReaderMatchesCommit": rightReaderMatchesCommit,
            "rightReaderDiffersFromWorktree": rightReaderDiffersFromWorktree,
            "elapsedMS": milliseconds(since: startedAt),
        ])

        pythonModel.switchToCommit(previousRevision)
        guard await pythonWait(timeout: 120, {
            pythonModel.snapshotPhase == .fullReady
                && pythonModel.currentRevision != nil
                && pythonModel.exactCoordinator.readiness == .ready
                && pythonReady()
        }) else {
            finish("switchToCommit did not finish Python")
        }
        let commitStats = if case let .ready(s, _) = pythonModel.projectState {
            s.stats
        } else {
            coldStats
        }
        guard let source = pythonModel.documentSource,
              let expectedConfigBytes = try? commitSnapshot.readBytes(path: configPath),
              let actualConfigBytes = try? source(configFile),
              actualConfigBytes == expectedConfigBytes,
              pythonModel.fileTree?.selectionPath(for: configFile) != nil,
              controller.selectFileInSidebar(configFile),
              await pythonWait(timeout: 30, {
                  controller.displayedReaderFile?.standardizedFileURL == configFile
                      && controller.selfTestReaderPreviewKind == "Plain text"
                      && controller.selfTestReaderPreviewText == String(decoding: expectedConfigBytes, as: UTF8.self)
                      && pythonModel.tabStrip.activeDocument == nil
              })
        else { finish("Python configuration preview did not match HEAD~1") }
        pythonModel.switchToWorktree()
        guard await pythonWait(timeout: 120, {
            pythonModel.currentRevision == nil
                && pythonModel.snapshotPhase == .fullReady
                && pythonModel.exactCoordinator.readiness == .ready
                && pythonReady()
        }) else {
            finish("switchToWorktree did not finish Python")
        }
        let worktreeStats = if case let .ready(s, _) = pythonModel.projectState {
            s.stats
        } else {
            coldStats
        }
        Self.writeJSON([
            "step": "switch",
            "commitReused": commitStats.reusedCount,
            "commitExtracted": commitStats.extractedCount,
            "worktreeReused": worktreeStats.reusedCount,
            "worktreeExtracted": worktreeStats.extractedCount,
            "elapsedMS": milliseconds(since: startedAt),
        ])

        controller.checkpointSessionSynchronously()
        guard let session = pythonModel.loadSessionSnapshot(
            forProject: root
        ).snapshot,
              session.language == .python
        else {
            finish("session checkpoint language not Python")
        }
        controller.openProject(root: root, forcingReopen: true)
        guard await pythonWait(timeout: 120, {
            pythonModel.snapshotPhase == .fullReady
                && pythonReady()
        }) else {
            finish("recent reopen did not finish Python")
        }
        let hotStats = if case let .ready(s, _) = pythonModel.projectState {
            s.stats
        } else {
            coldStats
        }
        guard hotStats.reusedCount > 0 else {
            finish("recent reopen did not reuse cache")
        }
        Self.writeJSON([
            "step": "hot-recent",
            "fileCount": pythonModel.fileTree?.fileCount ?? 0,
            "reused": hotStats.reusedCount,
            "extracted": hotStats.extractedCount,
            "elapsedMS": milliseconds(since: startedAt),
        ])

        let generationBeforeRestore = pythonModel.generation
        controller.restoreSession(session)
        guard await pythonWait(timeout: 120, {
            pythonModel.generation != generationBeforeRestore
                && pythonModel.snapshotPhase == .fullReady
                && pythonModel.exactCoordinator.readiness == .ready
                && pythonReady()
        }) else {
            finish("session restore did not finish Python")
        }
        pythonRecentStore.clear()

        let checks = [
            "treeMatchesSnapshot": treeMatchesSnapshot,
            "sourceFileCountMatchesCorpus": sourceFiles.count == 204,
            "semanticIndexOnlyPython": semanticIndexOnlyPython,
            "configurationPreviewMatchesWorktree": true,
            "configurationPreviewMatchesCommit": true,
            "contentSearchMemory": true,
            "symbolSearchMemory": true,
            "readerOutlineReady": outlineCount > 0,
            "localReferencesReady": localReferenceCount > 0,
            "styledFragmentsReady": styledFragments > 0,
            "foldRegionsReady": foldRegions > 0,
            "fuzzyContextSymbol": true,
            "localRelationLoaded": localRelationLoaded,
            "exactDefinition": true,
            "exactReferences": exactReferences,
            "exactCallHierarchy": callHierarchyExact,
            "implementationsUnsupported": implementationsUnsupported,
            "localReferencesAfterUnsupported": localReferencesAfterUnsupported,
            "exactReferencesAfterUnsupported": exactReferencesAfterUnsupported,
            "compareHunksNonempty": true,
            "compareRightDiffers": rightReaderDiffersFromWorktree,
            "switchToCommitPython": true,
            "switchToWorktreePython": true,
            "recentReopenPython": true,
            "sessionRestorePython": true,
        ]
        finishPythonSelfTest(
            coldFileCount: fileCount,
            coldReused: coldStats.reusedCount,
            coldExtracted: coldStats.extractedCount,
            hotFileCount: pythonModel.fileTree?.fileCount ?? 0,
            hotReused: hotStats.reusedCount,
            hotExtracted: hotStats.extractedCount,
            checks: checks,
            startedAt: startedAt
        )
    }

    func runTypeScriptSelfTest(root inputRoot: URL) async -> Never {
        launch(offscreen: true, measuresIdleFootprint: false)
        let startedAt = ContinuousClock.now
        let root = inputRoot.standardizedFileURL
        let tsxFile = root.appendingPathComponent(
            "components/search-results-image.tsx"
        ).standardizedFileURL
        let tsFile = root.appendingPathComponent("lib/utils/index.ts")
            .standardizedFileURL
        let tsRelative = "lib/utils/index.ts"
        let tsxRelative = "components/search-results-image.tsx"
        let tsModel = self.model
        let tsRecentStore = self.recentProjectsStore

        func tsReady() -> Bool {
            if case let .ready(session, _) = tsModel.projectState {
                return session.analysisProfile.language == .typescript
            }
            return false
        }
        func finish(_ error: String) -> Never {
            finishTypeScriptSelfTest(
                error: error,
                startedAt: startedAt
            )
        }
        func tsWait(
            timeout: TimeInterval,
            _ condition: @escaping () -> Bool
        ) async -> Bool {
            let deadline = Date(timeIntervalSinceNow: timeout)
            while Date() < deadline {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return condition()
        }

        guard let controller = windowController else {
            finish("window unavailable")
        }
        guard previousCommitRevision(root: root) != nil else {
            finish("HEAD~1 unavailable")
        }

        controller.openProject(root: root)
        guard await tsWait(timeout: 180, {
            if case .failed = tsModel.projectState { return true }
            if case .ready = tsModel.projectState {
                return tsModel.fileTree != nil
                    && !tsModel.commitPicker.isLoading
                    && tsModel.snapshotPhase == .fullReady
                    && tsReady()
            }
            return false
        }), case let .ready(session, context) = tsModel.projectState,
              tsModel.snapshotPhase == .fullReady,
              tsModel.fileTree != nil,
              session.analysisProfile.language == .typescript,
              let previousRevision = tsModel.commitPicker.commits
                .dropFirst().first?.fullSHA
        else {
            finish("typescript project or HEAD~1 commit unavailable")
        }
        let coldSession = session
        let coldContext = context
        let coldStats = coldSession.stats
        let sourceFiles = coldSession.manifest.files.filter { $0.detectedLanguage == .typescript }
        let manifestFiles = sourceFiles.map {
            coldSession.paths.resolve($0.pathID)
        }.sorted()
        let semanticIndexOnlyTypeScript = coldSession.manifest.files.allSatisfy { file in
            let mode = LanguageMode.classify(
                path: coldSession.paths.resolve(file.pathID), language: .typescript
            )
            return file.detectedLanguage == mode?.language
                && coldSession.content(at: file.pathID)?.0.languageMode == mode
        } && coldSession.contentIndexes.keys.allSatisfy { $0.languageMode.language == .typescript }
        let treeFiles = pythonFiles(in: tsModel.fileTree?.children ?? [])
        let snapshotFiles = coldSession.manifest.files.filter {
            $0.fileMode == .regular || $0.fileMode == .lfsPointer
        }.map { root.appendingPathComponent(coldSession.paths.resolve($0.pathID)).standardizedFileURL }
        let treeMatchesSnapshot = Set(treeFiles) == Set(snapshotFiles)
        let tsCount = manifestFiles.filter { $0.hasSuffix(".ts") }.count
        let tsxCount = manifestFiles.filter { $0.hasSuffix(".tsx") }.count
        let manifestHasTsAndTsx = manifestFiles.contains(tsRelative)
            && manifestFiles.contains(tsxRelative)
        guard treeMatchesSnapshot, tsCount == 2, tsxCount == 51,
              manifestHasTsAndTsx, semanticIndexOnlyTypeScript
        else {
            finish("TypeScript workspace/index mismatch: tree=\(treeFiles.count) snapshot=\(snapshotFiles.count) ts=\(tsCount) tsx=\(tsxCount) semanticIndexOnlyTypeScript=\(semanticIndexOnlyTypeScript)")
        }
        let configPath = "package.json"
        let configFile = root.appendingPathComponent(configPath).standardizedFileURL
        guard let config = coldSession.manifest.files.first(where: {
                  coldSession.paths.resolve($0.pathID) == configPath
              }), config.detectedLanguage == nil,
              let configBytes = try? Array(Data(contentsOf: configFile)),
              ContentID.sha256(of: configBytes) == config.contentID,
              controller.selectFileInSidebar(configFile),
              await tsWait(timeout: 30, {
                  controller.displayedReaderFile?.standardizedFileURL == configFile
                      && controller.selfTestReaderPreviewKind == "Plain text"
                      && controller.selfTestReaderPreviewText == String(decoding: configBytes, as: UTF8.self)
                      && tsModel.tabStrip.activeDocument == nil
              })
        else { finish("TypeScript configuration preview did not match the worktree snapshot") }
        let profileUnit = coldSession.analysisProfile.projectUnitName
        Self.writeJSON([
            "step": "cold-open",
            "language": "typescript",
            "projectUnit": profileUnit,
            "tsCount": tsCount,
            "tsxCount": tsxCount,
            "fileCount": treeFiles.count,
            "sourceFileCount": sourceFiles.count,
            "treeMatchesSnapshot": treeMatchesSnapshot,
            "configurationPreview": configPath,
            "reused": coldStats.reusedCount,
            "extracted": coldStats.extractedCount,
            "snapshotPhase": tsModel.snapshotPhase?.rawValue as Any,
            "elapsedMS": milliseconds(since: startedAt),
        ])

        guard await tsWait(timeout: 90, {
            tsModel.exactCoordinator.readiness == .ready
        }), let attribution = tsModel.exactCoordinator.attribution
        else {
            finish("TypeScript provider missing/unready: "
                + "\(tsModel.exactCoordinator.readiness)")
        }

        var searchHitTSX = false
        do {
            let contentHits = try await contentSearchHits(
                session: coldSession,
                context: coldContext,
                query: ContentSearchQuery(
                    pattern: "SearchResultsImageSection",
                    caseSensitive: true
                )
            )
            let symbolHits = try coldSession.searchSymbols(
                query: "SearchResultsImageSection",
                limit: 20,
                boost: SearchBoost(),
                context: coldContext
            )
            guard contentHits.contains(where: {
                $0.hasSuffix(tsxRelative)
            }), symbolHits.contains(where: {
                $0.path.hasSuffix(tsxRelative)
            })
            else {
                finish("search did not hit search-results-image.tsx")
            }
            searchHitTSX = true
            Self.writeJSON([
                "step": "search",
                "contentHit": tsxRelative,
                "symbolHit": tsxRelative,
                "elapsedMS": milliseconds(since: startedAt),
            ])
        } catch {
            finish("search failed: \(error)")
        }

        for (label, file, mode) in [
            ("ts", tsFile, LanguageMode(language: .typescript)),
            ("tsx", tsxFile, LanguageMode(language: .typescript, variant: "tsx")),
        ] {
            guard controller.selectFileInSidebar(file),
                  await tsWait(timeout: 30, {
                      controller.displayedReaderFile?.standardizedFileURL
                          == file.standardizedFileURL
                          && tsModel.tabStrip.activeDocument != nil
                          && controller.selfTestStyledFragmentCount > 0
                  }),
                  let activeDocument = tsModel.tabStrip.activeDocument,
                  !activeDocument.outlineFacets.isEmpty,
                  !activeDocument.foldRegions.isEmpty,
                  activeDocument.languageMode == mode
            else {
                finish("Reader/outline/fold/mode unavailable for " + label)
            }
        }

        let activeDocument = tsModel.tabStrip.activeDocument
        let tsxModeExplicit = activeDocument?.languageMode.variant == "tsx"
        let outlineCount = activeDocument?.outlineFacets.count ?? 0
        let bindingCount = activeDocument?.localBindings.count ?? 0
        let localReferenceCount = activeDocument?.referencesByBinding
            .compactMap(\.count).reduce(0, +) ?? 0
        let foldRegions = activeDocument?.foldRegions.count ?? 0
        let styledFragments = controller.selfTestStyledFragmentCount
        guard tsxModeExplicit, outlineCount > 0, bindingCount > 0,
              localReferenceCount > 0, foldRegions > 0,
              styledFragments > 0
        else {
            finish("TSX Reader/outline/local reference unavailable")
        }
        let profileTitle = controller.selfTestProfileTitle
        let profileMenu = controller.selfTestProfileMenuTitles
        let profileMenuText = profileMenu.joined(separator: " ")
        let profileHasNoCargo = profileTitle.localizedCaseInsensitiveContains(
            "TypeScript"
        )
            && profileTitle.localizedCaseInsensitiveContains("tsconfig")
            && !profileTitle.localizedCaseInsensitiveContains("features")
            && !profileMenuText.localizedCaseInsensitiveContains(
                "features"
            )
            && !profileMenuText.localizedCaseInsensitiveContains(
                "edition"
            )
            && profileMenuText.contains("Trust This Repository")
        let tsxSource = (try? String(
            contentsOf: tsxFile,
            encoding: .utf8
        )) ?? ""
        let relativeFile = "components/chat.tsx"
        let relativeSource = (try? String(
            contentsOf: root.appendingPathComponent(relativeFile),
            encoding: .utf8
        )) ?? ""
        let relativeImportOffset: UInt32
        if let range = relativeSource.range(of: "import { ChatPanel }"),
           let tokenStart = relativeSource.range(
               of: "ChatPanel",
               range: range.lowerBound..<relativeSource.endIndex
           )?.lowerBound,
           let offset = UInt32(exactly: relativeSource.utf8.distance(
               from: relativeSource.utf8.startIndex,
               to: tokenStart
        ))
        {
            relativeImportOffset = offset
        } else {
            finish("relative import ChatPanel token offset unavailable")
        }
        let relativeResolutions = (try? coldSession.resolve(
            file: coldSession.paths.intern(relativeFile),
            offset: relativeImportOffset,
            context: coldContext
        )) ?? []
        let relativeCandidate = relativeResolutions.first
        let relativeTarget = relativeCandidate.map {
            coldSession.paths.resolve($0.target.pathID)
        }
        let fuzzyRelativeResolved =
            relativeTarget == "components/chat-panel.tsx"
            && relativeCandidate?.certainty == .probable
            && relativeCandidate?.completeness == .partial
        guard fuzzyRelativeResolved else {
            finish(
                "fuzzy-relative did not match frozen import binding contract: "
                    + "target=\(relativeTarget as Any)"
                    + " certainty=\(String(describing: relativeCandidate?.certainty))"
                    + " completeness=\(String(describing: relativeCandidate?.completeness))"
            )
        }
        Self.writeJSON([
            "step": "fuzzy-relative",
            "file": relativeFile,
            "offset": Int(relativeImportOffset),
            "resolved": fuzzyRelativeResolved,
            "target": relativeTarget as Any,
            "certainty": relativeResolutions.map { $0.certainty.rawValue },
            "elapsedMS": milliseconds(since: startedAt),
        ])

        let aliasImportOffset: UInt32
        if let range = tsxSource.range(of: "Card"),
           let offset = UInt32(exactly: tsxSource.utf8.distance(
               from: tsxSource.utf8.startIndex,
               to: range.lowerBound
           ))
        {
            aliasImportOffset = offset
        } else {
            finish("alias import offset unavailable")
        }
        let aliasResolutions = (try? coldSession.resolve(
            file: coldSession.paths.intern(tsxRelative),
            offset: aliasImportOffset,
            context: coldContext
        )) ?? []
        let fuzzyAliasUnresolved = aliasResolutions.isEmpty
            || aliasResolutions.allSatisfy {
                $0.certainty == .unresolved
            }
        let exactCardDefinitions = await tsModel.exactCoordinator.definition(
            file: tsxRelative,
            byteOffset: aliasImportOffset,
            generation: coldContext.generation
        )
        let exactCardResolved = if case .completed(let entries) =
            exactCardDefinitions
        {
            !entries.isEmpty && entries.contains {
                $0.location.file.hasSuffix("components/ui/card.tsx")
            }
        } else {
            false
        }
        let attributionMatches = attribution.provider
            == "typescript-language-server"
        Self.writeJSON([
            "step": "alias",
            "file": tsxRelative,
            "offset": Int(aliasImportOffset),
            "fuzzyUnresolved": fuzzyAliasUnresolved,
            "exactCardResolved": exactCardResolved,
            "provider": attribution.provider,
            "elapsedMS": milliseconds(since: startedAt),
        ])
        guard fuzzyAliasUnresolved, exactCardResolved, attributionMatches else {
            finish("alias fuzzy should stay unresolved, exact Card must resolve, provider must be typescript-language-server")
        }

        guard let sectionSymbol = (
            try? coldSession.searchSymbols(
                query: "SearchResultsImageSection",
                limit: 20,
                boost: SearchBoost(),
                context: coldContext
            ).first(where: {
                $0.path.hasSuffix("components/search-results-image.tsx")
            })?.occurrence
        ) else {
            finish("SearchResultsImageSection symbol unavailable")
        }
        await tsModel.relationTree.setRoot(
            target: .engine(sectionSymbol),
            direction: .references
        )?.value
        var exactReferences = false
        let refsDeadline = Date(timeIntervalSinceNow: 60)
        while Date() < refsDeadline {
            if let root = tsModel.relationTree.root,
               !(root.children?.contains { $0.kind == .loading } ?? true)
            {
                exactReferences = !exactRelationEdges(in: tsModel).isEmpty
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        if exactReferences == false {
            exactReferences = !exactRelationEdges(in: tsModel).isEmpty
        }
        guard exactReferences else {
            finish("TypeScript references unavailable")
        }
        Self.writeJSON([
            "step": "real-typescript-exact",
            "provider": attribution.provider,
            "toolVersion": attribution.toolVersion,
            "definitionTargets": exactCardDefinitions.map {
                if case .completed(let entries) = $0 {
                    return entries.count
                }
                return 0
            } ?? 0,
            "exactReferences": exactReferences,
            "elapsedMS": milliseconds(since: startedAt),
        ])

        let compareFile = tsxFile
        guard let worktreeBytes = try? Array(Data(contentsOf: compareFile)),
              let commitSnapshot = try? CommitSnapshot(
                  repositoryURL: root,
                  revision: previousRevision
              ),
              let commitBytes = try? commitSnapshot.readBytes(
                  path: tsxRelative
              ),
              worktreeBytes != commitBytes
        else {
            finish("compare fixture or HEAD~1 diff unavailable")
        }
        controller.openFileForSelfTest(compareFile)
        guard await tsWait(timeout: 30, {
            tsModel.selectedFile?.standardizedFileURL
                == compareFile.standardizedFileURL
                && controller.displayedReaderFile?.standardizedFileURL
                    == compareFile.standardizedFileURL
        }) else {
            finish("compare main reader did not open")
        }
        controller.applyPanelPreset(.compare)
        guard controller.selectCompareCommit(previousRevision) else {
            finish("compare commit picker did not select")
        }
        guard await tsWait(timeout: 60, {
            tsModel.compare.diff != nil
                && tsModel.compare.diff?.hunks.isEmpty == false
                && tsModel.compare.diff?.truncated == false
                && tsModel.compare.rightRevision == previousRevision
                && controller.selfTestRightReaderBytes != nil
        }) else {
            finish("compare HEAD~1 did not finish")
        }
        let rightBytes = controller.selfTestRightReaderBytes ?? []
        let compareRightMatchesCommit = rightBytes == commitBytes
        let compareRightDiffersFromWorktree = rightBytes != worktreeBytes
        let compareHunksNonempty =
            (tsModel.compare.diff?.hunks.isEmpty == false)
        guard compareRightMatchesCommit, compareRightDiffersFromWorktree else {
            finish("compare right reader mismatch")
        }
        Self.writeJSON([
            "step": "compare",
            "diffHunks": tsModel.compare.diff?.hunks.count ?? 0,
            "truncated": tsModel.compare.diff?.truncated ?? true,
            "rightReaderMatchesCommit": compareRightMatchesCommit,
            "rightReaderDiffersFromWorktree": compareRightDiffersFromWorktree,
            "elapsedMS": milliseconds(since: startedAt),
        ])

        var switchToCommitTypeScript = false
        tsModel.switchToCommit(previousRevision)
        guard await tsWait(timeout: 180, {
            tsModel.snapshotPhase == .fullReady
                && tsModel.currentRevision != nil
                && tsModel.exactCoordinator.readiness == .ready
                && tsReady()
        }) else {
            finish("switchToCommit did not finish TypeScript")
        }
        switchToCommitTypeScript = true
        let commitStats = if case let .ready(s, _) = tsModel.projectState {
            s.stats
        } else {
            coldStats
        }
        guard let source = tsModel.documentSource,
              let expectedConfigBytes = try? commitSnapshot.readBytes(path: configPath),
              let actualConfigBytes = try? source(configFile),
              actualConfigBytes == expectedConfigBytes,
              tsModel.fileTree?.selectionPath(for: configFile) != nil,
              controller.selectFileInSidebar(configFile),
              await tsWait(timeout: 30, {
                  controller.displayedReaderFile?.standardizedFileURL == configFile
                      && controller.selfTestReaderPreviewKind == "Plain text"
                      && controller.selfTestReaderPreviewText == String(decoding: expectedConfigBytes, as: UTF8.self)
                      && tsModel.tabStrip.activeDocument == nil
              })
        else { finish("TypeScript configuration preview did not match HEAD~1") }
        var switchToWorktreeTypeScript = false
        tsModel.switchToWorktree()
        guard await tsWait(timeout: 180, {
            tsModel.currentRevision == nil
                && tsModel.snapshotPhase == .fullReady
                && tsModel.exactCoordinator.readiness == .ready
                && tsReady()
        }) else {
            finish("switchToWorktree did not finish TypeScript")
        }
        switchToWorktreeTypeScript = true
        let worktreeStats = if case let .ready(s, _) = tsModel.projectState {
            s.stats
        } else {
            coldStats
        }
        Self.writeJSON([
            "step": "switch",
            "commitReused": commitStats.reusedCount,
            "commitExtracted": commitStats.extractedCount,
            "worktreeReused": worktreeStats.reusedCount,
            "worktreeExtracted": worktreeStats.extractedCount,
            "elapsedMS": milliseconds(since: startedAt),
        ])

        var retryReopenTypeScript = false
        controller.retryLastOpenedProject()
        guard await tsWait(timeout: 180, {
            tsModel.snapshotPhase == .fullReady
                && tsModel.exactCoordinator.readiness == .ready
                && tsReady()
        }) else {
            finish("retry reopen did not finish TypeScript")
        }
        let retryStats = if case let .ready(s, _) = tsModel.projectState {
            s.stats
        } else {
            coldStats
        }
        retryReopenTypeScript = true
        Self.writeJSON([
            "step": "retry-reopen",
            "fileCount": tsModel.fileTree?.fileCount ?? 0,
            "reused": retryStats.reusedCount,
            "extracted": retryStats.extractedCount,
            "elapsedMS": milliseconds(since: startedAt),
        ])

        controller.checkpointSessionSynchronously()
        guard let persisted = tsModel.loadSessionSnapshot(
            forProject: root
        ).snapshot,
              persisted.language == .typescript
        else {
            finish("session checkpoint language not TypeScript")
        }
        var recentReopenTypeScript = false
        controller.openProject(root: root, forcingReopen: true)
        guard await tsWait(timeout: 180, {
            tsModel.snapshotPhase == .fullReady
                && tsModel.exactCoordinator.readiness == .ready
                && tsReady()
        }) else {
            finish("recent reopen did not finish TypeScript")
        }
        recentReopenTypeScript = true
        let hotStats = if case let .ready(s, _) = tsModel.projectState {
            s.stats
        } else {
            coldStats
        }
        guard hotStats.reusedCount > 0 else {
            finish("recent reopen did not reuse cache")
        }
        Self.writeJSON([
            "step": "hot-recent",
            "fileCount": tsModel.fileTree?.fileCount ?? 0,
            "reused": hotStats.reusedCount,
            "extracted": hotStats.extractedCount,
            "elapsedMS": milliseconds(since: startedAt),
        ])

        let generationBeforeRestore = tsModel.generation
        var sessionRestoreTypeScript = false
        controller.restoreSession(persisted)
        guard await tsWait(timeout: 180, {
            tsModel.generation != generationBeforeRestore
                && tsModel.snapshotPhase == .fullReady
                && tsModel.exactCoordinator.readiness == .ready
                && tsReady()
        }) else {
            finish("session restore did not finish TypeScript")
        }
        sessionRestoreTypeScript = true
        tsRecentStore.clear()

        let checks = [
            "treeMatchesSnapshot": treeMatchesSnapshot,
            "treeHasTsAndTsx": tsCount == 2 && tsxCount == 51,
            "manifestHasTsAndTsx": manifestHasTsAndTsx,
            "semanticIndexOnlyTypeScript": semanticIndexOnlyTypeScript,
            "configurationPreviewMatchesWorktree": true,
            "configurationPreviewMatchesCommit": true,
            "searchHitTSX": searchHitTSX,
            "profileUnitTSConfig": profileUnit == "tsconfig.json",
            "profileHasNoCargo": profileHasNoCargo,
            "coldReusedZero": coldStats.reusedCount == 0,
            "coldExtractedPositive": coldStats.extractedCount > 0,
            "tsxReaderExplicitMode": tsxModeExplicit,
            "readerOutlineReady": outlineCount > 0,
            "localReferencesReady": localReferenceCount > 0,
            "styledFragmentsReady": styledFragments > 0,
            "foldRegionsReady": foldRegions > 0,
            "fuzzyRelativeResolved": fuzzyRelativeResolved,
            "fuzzyAliasUnresolved": fuzzyAliasUnresolved,
            "exactCardDefinition": exactCardResolved,
            "exactReferences": exactReferences,
            "providerMatchesTypeScriptLanguageServer": attributionMatches,
            "compareHunksNonempty": compareHunksNonempty,
            "compareRightMatchesCommit": compareRightMatchesCommit,
            "compareRightDiffers": compareRightDiffersFromWorktree,
            "switchToCommitTypeScript": switchToCommitTypeScript,
            "switchToWorktreeTypeScript": switchToWorktreeTypeScript,
            "retryReopenTypeScript": retryReopenTypeScript,
            "recentReopenTypeScript": recentReopenTypeScript,
            "hotReusedPositive": hotStats.reusedCount > 0,
            "sessionRestoreTypeScript": sessionRestoreTypeScript,
        ]
        finishTypeScriptSelfTest(
            coldFileCount: treeFiles.count,
            coldReused: coldStats.reusedCount,
            coldExtracted: coldStats.extractedCount,
            hotFileCount: tsModel.fileTree?.fileCount ?? 0,
            hotReused: hotStats.reusedCount,
            hotExtracted: hotStats.extractedCount,
            checks: checks,
            startedAt: startedAt
        )
    }

    func runMixedSelfTest(root inputRoot: URL) async -> Never {
        let startedAt = ContinuousClock.now
        let root = inputRoot.standardizedFileURL
        func finish(_ error: String) -> Never {
            Self.writeJSON([
                "step": "summary",
                "channel": "mixed",
                "passed": false,
                "error": error,
                "elapsedMS": milliseconds(since: startedAt),
            ])
            Self.exitSelfTest(channel: "mixed", status: 1)
        }
        func git(_ arguments: [String]) throws -> String {
            let process = Process()
            let standardOutput = Pipe()
            let standardError = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root.path] + arguments
            process.standardOutput = standardOutput
            process.standardError = standardError
            try process.run()
            process.waitUntilExit()
            let data = standardOutput.fileHandleForReading.readDataToEndOfFile()
            let errorData = standardError.fileHandleForReading
                .readDataToEndOfFile()
            guard process.terminationStatus == 0
            else {
                throw CocoaError(.fileReadUnknown, userInfo: [
                    NSLocalizedFailureReasonErrorKey:
                        "git \(arguments.joined(separator: " ")) failed ("
                        + "\(process.terminationStatus)): "
                        + String(decoding: errorData, as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        + " "
                        + String(decoding: data, as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                ])
            }
            return String(decoding: data, as: UTF8.self)
        }

        let fixedCommit = "457b66e72da1967c2432131a7ff8adc4341eb337"
        let expectedConfigHashes: [String: String] = [
            "pyproject.toml":
                "0c48694c3cc9668d7e062a03e98ab41d53a5b68a7500bd977da826e5f01273e6",
            "uv.lock":
                "562ebad06578ceca1bbcd1888942fcb8bf001340dbd63ce6c4d5737c144dbe4c",
            "crates/qrcode2txt/Cargo.toml":
                "e0079b229039a8a02b440878c4235f6ac05a0c5e6db71b6cf61fcf28eee947a2",
            "tools/model-files-web/tsconfig.json":
                "770b4140bbb581e2dfd9ea9946ffc9c75a1d86ba7d2db5f77c83e37cbdf9d808",
            "tools/model-files-web/package.json":
                "798565f0dc3bcb30375457bd8e003d7c30b14679f0e79bc6a1c50ddd0d63eb6c",
            "tools/model-files-web/package-lock.json":
                "8373619bda0840fb24893976201504404cd0fde71f61621057b529dfc1719d31",
        ]
        do {
            let head = try git(["rev-parse", "HEAD"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard head == fixedCommit else {
                finish("mixed HEAD \(head) != fixed \(fixedCommit)")
            }
            let status = try git([
                "status",
                "--porcelain=v1",
                "--untracked-files=all",
                "--ignored=matching",
            ])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard status.isEmpty else {
                finish("mixed git worktree is not clean")
            }
            let listed = try git(["ls-files"])
                .split(separator: "\n").map(String.init)
            let rustFiles = listed.filter { $0.hasSuffix(".rs") }
            let pythonFiles = listed.filter {
                $0.hasSuffix(".py") && !$0.hasSuffix(".pyi")
            }
            let dtsFiles = listed.filter { $0.hasSuffix(".d.ts") }
            let tsFiles = listed.filter {
                $0.hasSuffix(".ts")
                    && !$0.hasSuffix(".d.ts")
                    && !$0.hasSuffix(".mts")
                    && !$0.hasSuffix(".cts")
            }
            let tsxFiles = listed.filter { $0.hasSuffix(".tsx") }
            let jsFiles = listed.filter {
                $0.hasSuffix(".js") || $0.hasSuffix(".jsx")
            }
            guard rustFiles.count == 11,
                  pythonFiles.count == 8,
                  tsFiles.count == 22,
                  tsxFiles.count == 4,
                  dtsFiles.count == 1,
                  jsFiles.isEmpty
            else {
                finish("preflight counts rust=\(rustFiles.count) "
                    + "python=\(pythonFiles.count) ts=\(tsFiles.count) "
                    + "tsx=\(tsxFiles.count) dts=\(dtsFiles.count) "
                    + "js=\(jsFiles.count) mismatch")
            }
            for (path, hash) in expectedConfigHashes {
                guard listed.contains(path),
                      let data = try? Data(contentsOf: root.appendingPathComponent(path)),
                      ContentID.sha256(of: data).bytes
                        .map({ String(format: "%02x", $0) }).joined() == hash
                else {
                    finish("preflight config hash mismatch \(path)")
                }
            }
        } catch {
            finish("mixed git preflight failed: \(error)")
        }

        launch(offscreen: true, measuresIdleFootprint: false)
        guard let controller = windowController else {
            finish("window unavailable")
        }
        controller.openProject(root: root)

        var sawFirstPaint = false
        let deadline = Date(timeIntervalSinceNow: 30)
        while Date() < deadline {
            if model.snapshotPhase == .firstPaint {
                sawFirstPaint = true
            }
            if model.snapshotPhase == .fullReady,
               model.querySessions.count == 3
            {
                break
            }
            if case .failed = model.projectState {
                finish("mixed project failed during cold open")
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard sawFirstPaint,
              model.snapshotPhase == .fullReady,
              model.projectLanguages == [.rust, .python, .typescript],
              model.querySessions.count == 3,
              model.fileTree?.root.standardizedFileURL == root
        else {
            finish("mixed cold open did not reach firstPaint/fullReady")
        }

        let sessions = model.querySessions
        var sessionOutputs: [[String: Any]] = []
        var rustCount = 0
        var pythonCount = 0
        var tsCount = 0
        var tsxCount = 0
        var dtsCount = 0
        var snapshotIDs = Set<SnapshotID>()

        for (session, _) in sessions {
            let paths = session.manifest.files.map {
                session.paths.resolve($0.pathID)
            }
            let language = session.analysisProfile.language
            let languagePaths = paths.filter {
                LanguageMode.classify(
                    path: $0,
                    language: language
                ) != nil
            }
            snapshotIDs.insert(session.snapshotID)
            for path in languagePaths {
                if path.hasSuffix(".rs") {
                    rustCount += 1
                } else if path.hasSuffix(".py"), !path.hasSuffix(".pyi") {
                    pythonCount += 1
                } else if path.hasSuffix(".d.ts") {
                    dtsCount += 1
                } else if path.hasSuffix(".tsx") {
                    tsxCount += 1
                } else if path.hasSuffix(".ts") {
                    tsCount += 1
                }
            }
            sessionOutputs.append([
                "language": session.analysisProfile.language.rawValue,
                "files": languagePaths.count,
                "extracted": session.stats.extractedCount,
                "reused": session.stats.reusedCount,
                "profileRoot": session.paths.resolve(
                    session.analysisProfile.projectRoot
                ),
            ])
        }
        guard sessions.contains(where: {
            $0.0.analysisProfile.language == .rust
                && $0.0.paths.resolve($0.0.analysisProfile.projectRoot)
                    == "crates/qrcode2txt"
        }), sessions.contains(where: {
            $0.0.analysisProfile.language == .python
                && $0.0.paths.resolve($0.0.analysisProfile.projectRoot) == "."
        }), sessions.contains(where: {
            $0.0.analysisProfile.language == .typescript
                && $0.0.paths.resolve($0.0.analysisProfile.projectRoot)
                    == "tools/model-files-web"
        }) else {
            finish("mixed profile roots do not match fixed corpus")
        }
        guard snapshotIDs.count == 1 else {
            finish("mixed sessions do not share one snapshot")
        }
        guard rustCount == 11,
              pythonCount == 8,
              tsCount == 22,
              tsxCount == 4,
              dtsCount == 0
        else {
            finish("mixed counts rust=\(rustCount) python=\(pythonCount) "
                + "ts=\(tsCount) tsx=\(tsxCount) d.ts=\(dtsCount) mismatch")
        }

        Self.writeJSON([
            "step": "MIXED_SELF_TEST_COLD",
            "channel": "mixed",
            "passed": true,
            "commit": fixedCommit,
            "languages": [0, 1, 2],
            "root": root.path,
            "sessionSnapshot": snapshotIDs.first!.rawValue.uuidString,
            "treeFileCount": model.fileTree?.fileCount as Any,
            "counts": [
                "rust": rustCount,
                "python": pythonCount,
                "ts": tsCount,
                "tsx": tsxCount,
                "dts": dtsCount,
            ],
            "sessions": sessionOutputs,
            "elapsedMS": milliseconds(since: startedAt),
        ])

        var searchContentPaths: [String: [String]] = [:]
        var searchSymbolPaths: [String: [String]] = [:]
        var contentLanguageCounts: [String: Int] = [:]
        var symbolLanguageCounts: [String: Int] = [:]
        for (session, context) in sessions {
            let language = session.analysisProfile.language
            let languageKey = String(describing: language)
            do {
                let contentHits = try await contentSearchHits(
                    session: session,
                    context: context,
                    query: ContentSearchQuery(
                        pattern: "main",
                        caseSensitive: false
                    )
                )
                let contentLanguagePaths = contentHits.filter {
                    LanguageMode.classify(path: $0, language: language) != nil
                }
                contentLanguageCounts[languageKey, default: 0] +=
                    contentLanguagePaths.count
                searchContentPaths[languageKey] =
                    (searchContentPaths[languageKey] ?? [])
                        + contentLanguagePaths
            } catch {
                finish("mixed content search failed for \(languageKey): \(error)")
            }
            do {
                let symbolHits = try session.searchSymbols(
                    query: "main",
                    limit: 50,
                    boost: SearchBoost(),
                    context: context
                )
                let languageSymbols = symbolHits.map(\.path)
                symbolLanguageCounts[languageKey, default: 0] +=
                    languageSymbols.count
                searchSymbolPaths[languageKey] =
                    (searchSymbolPaths[languageKey] ?? [])
                    + languageSymbols
            } catch {
                finish("mixed symbol search failed for \(languageKey): \(error)")
            }
        }
        guard contentLanguageCounts.values.filter({ $0 > 0 }).count >= 2,
              symbolLanguageCounts.values.filter({ $0 > 0 }).count >= 2
        else {
            finish("mixed search did not cover at least two languages")
        }
        Self.writeJSON([
            "step": "MIXED_SELF_TEST_SEARCH",
            "channel": "mixed",
            "passed": true,
            "languageContentMatches": contentLanguageCounts,
            "languageSymbolMatches": symbolLanguageCounts,
            "contentPaths": searchContentPaths.mapValues {
                Array(Set($0)).sorted()
            },
            "symbolPaths": searchSymbolPaths.mapValues {
                Array(Set($0)).sorted()
            },
            "elapsedMS": milliseconds(since: startedAt),
        ])

        let readerCases: [
            (LanguageID, String, LanguageMode, String?, Bool, Int)
        ] = [
            (.rust,
                "crates/qrcode2txt/src/lib.rs",
                LanguageMode(language: .rust),
                "from_results",
                false,
                1),
            (.python,
                "src/tools/analysis/analysis.py",
                LanguageMode(language: .python),
                "get_top_tokens",
                false,
                1),
            (.typescript,
                "tools/model-files-web/src/core/tokenizer.ts",
                LanguageMode(language: .typescript),
                "isRecord",
                false,
                1),
            (.typescript,
                "tools/model-files-web/src/App.tsx",
                LanguageMode(language: .typescript, variant: "tsx"),
                "loadRepository",
                true,
                0),
        ]
        var readerOutputs: [[String: Any]] = []
        for item in readerCases {
            let language = item.0
            let path = item.1
            let mode = item.2
            let needle = item.3
            let allowNoRelation = item.4
            let needleIndex = item.5
            let file = root.appendingPathComponent(path)
                .standardizedFileURL
            controller.openFileForSelfTest(file)
            let readerDeadline = Date(timeIntervalSinceNow: 60)
            var readerReady = false
            while Date() < readerDeadline {
                if case let .ready(session, _) = model.projectState,
                   session.analysisProfile.language == language,
                   controller.displayedReaderFile?.standardizedFileURL
                    == file.standardizedFileURL,
                   let document = model.tabStrip.activeDocument,
                   document.languageMode == mode,
                   controller.selfTestStyledFragmentCount > 0,
                   !document.outlineFacets.isEmpty,
                   !document.foldRegions.isEmpty
                {
                    readerReady = true
                    break
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
            guard readerReady else {
                finish("mixed reader did not ready \(path)")
            }
            guard let document = model.tabStrip.activeDocument else {
                finish("mixed reader document unavailable \(path)")
            }
            var output: [String: Any] = [
                "path": path,
                "mode": mode.variant ?? "base",
                "styled": controller.selfTestStyledFragmentCount,
                "outline": document.outlineFacets.count,
                "folds": document.foldRegions.count,
                "activeLanguage": String(describing: language),
            ]
            var relationCount = 0
            var contextResolved = false
            let previousRelationRoot = model.relationTree.root
            if let needle,
               let bytes = controller.selfTestLeftReaderBytes
            {
                let offsets = utf8Offsets(of: needle, in: bytes)
                    .dropFirst(needleIndex)
                if let offset = offsets.first.map(UInt32.init) {
                    let candidate = await model.contextWindow.resolvedCandidate(
                        file: path,
                        offset: offset
                    )
                    contextResolved = candidate != nil
                    if candidate != nil {
                        controller.selfTestReaderRelation(
                            offset: offset,
                            direction: .references
                        )
                        let relationDeadline = Date(timeIntervalSinceNow: 60)
                        var capturedRoot: RelationTreeModel.Node?
                        while Date() < relationDeadline {
                            if let root = model.relationTree.root,
                               root !== previousRelationRoot,
                               !(root.children?.contains {
                                   $0.kind == .loading
                               } ?? true)
                            {
                                capturedRoot = root
                                break
                            }
                            try? await Task.sleep(for: .milliseconds(10))
                        }
                        let edges = capturedRoot.map {
                            relationEdgeNodes(in: $0)
                        } ?? []
                        let foreign = edges.filter { edge in
                            guard let target = edge.target else { return true }
                            let mode = LanguageMode.classify(
                                path: target.path,
                                languages: [language]
                            )
                            return mode?.language != language
                        }
                        guard foreign.isEmpty && !edges.isEmpty else {
                            finish("mixed relation foreign for \(path)")
                        }
                        relationCount = edges.count
                    }
                }
            }
            if !contextResolved && !allowNoRelation {
                finish("mixed context did not resolve \(path)")
            }
            output["context"] = contextResolved
            output["relationEdges"] = relationCount
            readerOutputs.append(output)
        }
        Self.writeJSON([
            "step": "MIXED_SELF_TEST_READER",
            "channel": "mixed",
            "passed": true,
            "readers": readerOutputs,
            "elapsedMS": milliseconds(since: startedAt),
        ])

        let exactCases: [
            (LanguageID, String, String, Int, String)
        ] = [
            (
                .rust,
                "crates/qrcode2txt/src/lib.rs",
                "from_results",
                1,
                "rust-analyzer"
            ),
            (
                .python,
                "src/tools/analysis/analysis.py",
                "get_top_tokens",
                1,
                "pyright"
            ),
            (
                .typescript,
                "tools/model-files-web/src/core/tokenizer.ts",
                "inspectTokenizerStructure",
                0,
                "typescript-language-server"
            ),
        ]
        var exactOutputs: [[String: Any]] = []
        for item in exactCases {
            let language = item.0
            let path = item.1
            let needle = item.2
            let needleIndex = item.3
            let provider = item.4
            let file = root.appendingPathComponent(path).standardizedFileURL
            controller.openFileForSelfTest(file)
            let exactReadyStarted = ContinuousClock.now
            let exactReadyDeadline = Date(timeIntervalSinceNow: 30)
            while Date() < exactReadyDeadline {
                if model.exactCoordinator.readiness == .ready,
                   model.exactCoordinator.attribution?.provider == provider,
                   case let .ready(session, _) = model.projectState,
                   session.analysisProfile.language == language,
                   controller.displayedReaderFile?.standardizedFileURL == file
                {
                    break
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard model.exactCoordinator.readiness == .ready,
                  let attribution = model.exactCoordinator.attribution,
                  attribution.provider == provider,
                  case let .ready(session, context) = model.projectState,
                  session.analysisProfile.language == language,
                  controller.displayedReaderFile?.standardizedFileURL == file,
                  controller.selfTestLeftReaderBytes != nil
            else {
                finish("mixed exact \(provider) not ready for \(path): "
                    + "\(String(describing: model.exactCoordinator.readiness))"
                    + " attribution=\(String(describing: model.exactCoordinator.attribution?.provider))"
                )
            }
            let readyMS = milliseconds(since: exactReadyStarted)
            guard let bytes = try? Data(contentsOf: file) else {
                finish("mixed exact file missing \(path)")
            }
            let offsets = utf8Offsets(of: needle, in: Array(bytes))
                .dropFirst(needleIndex)
            guard let offset = offsets.first.map(UInt32.init) else {
                finish("mixed exact needle unavailable \(path)")
            }
            guard case let .completed(definitions) =
                await model.exactCoordinator.definition(
                    file: path,
                    byteOffset: offset,
                    generation: context.generation
                ),
                  !definitions.isEmpty
            else {
                finish("mixed exact definition failed for \(path)")
            }
            let previousExactRelationRoot = model.relationTree.root
            controller.selfTestReaderRelation(
                offset: offset,
                direction: .references
            )
            let exactRelationDeadline = Date(timeIntervalSinceNow: 30)
            var exactEdges: [RelationTreeModel.Node] = []
            while Date() < exactRelationDeadline {
                if let root = model.relationTree.root,
                   root !== previousExactRelationRoot,
                   !(root.children?.contains { $0.kind == .loading } ?? true)
                {
                    exactEdges = exactRelationEdges(in: model)
                    if !exactEdges.isEmpty { break }
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard !exactEdges.isEmpty else {
                finish("mixed exact references empty for \(path)")
            }
            exactOutputs.append([
                "provider": attribution.provider,
                "toolVersion": attribution.toolVersion,
                "definitionCount": definitions.count,
                "verifiedReferenceCount": exactEdges.count,
                "readyMS": readyMS,
                "profileRoot": session.paths.resolve(
                    session.analysisProfile.projectRoot
                ),
            ])
        }
        Self.writeJSON([
            "step": "MIXED_SELF_TEST_EXACT",
            "channel": "mixed",
            "passed": true,
            "exact": exactOutputs,
            "elapsedMS": milliseconds(since: startedAt),
        ])

        let fixedHistoricalCommit = "6cc5b52f9f1bef28b27133155bbb858b2891c829"
        let fixedCompareFile = "crates/qrcode2txt/tests/qrcode_monkey_fixtures.rs"
        let coldSnapshotID = snapshotIDs.first!.rawValue.uuidString
        let coldProfileRoots = sessions.map {
            $0.0.paths.resolve($0.0.analysisProfile.projectRoot)
        }.sorted()
        var coldByLanguage: [String: [String: Any]] = [:]
        for (session, _) in sessions {
            let activeFiles = session.manifest.files.map {
                session.paths.resolve($0.pathID)
            }.filter {
                LanguageMode.classify(
                    path: $0,
                    language: session.analysisProfile.language
                ) != nil
            }
            coldByLanguage[String(describing: session.analysisProfile.language)] = [
                "files": activeFiles.count,
                "extracted": session.stats.extractedCount,
                "reused": session.stats.reusedCount,
            ]
        }

        let commitSwitchStarted = ContinuousClock.now
        model.switchToCommit(fixedHistoricalCommit)
        let overrideDeadline = Date(timeIntervalSinceNow: 30)
        while Date() < overrideDeadline {
            if model.currentRevision == fixedHistoricalCommit,
               model.snapshotPhase == .fullReady,
               model.querySessions.count == 3
            {
                break
            }
            if case .failed = model.projectState {
                finish("mixed snapshot commit failed")
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard model.currentRevision == fixedHistoricalCommit,
              model.snapshotPhase == .fullReady,
              model.querySessions.count == 3,
              model.projectLanguages == [.rust, .python, .typescript]
        else {
            finish("mixed snapshot commit did not reach fullReady")
        }
        let commitSwitchMS = milliseconds(since: commitSwitchStarted)
        let historicalSessions = model.querySessions
        var historicalRust = 0, historicalPython = 0, historicalTS = 0
        for (session, _) in historicalSessions {
            let paths = session.manifest.files.map {
                session.paths.resolve($0.pathID)
            }
            if session.analysisProfile.language == .rust {
                historicalRust = paths.filter { $0.hasSuffix(".rs") }.count
            } else if session.analysisProfile.language == .python {
                historicalPython = paths.filter {
                    $0.hasSuffix(".py") && !$0.hasSuffix(".pyi")
                }.count
            } else if session.analysisProfile.language == .typescript {
                historicalTS = paths.filter { $0.hasSuffix(".ts") || $0.hasSuffix(".tsx") }.count
            }
        }
        let historicalSnapshotID = model.currentSnapshotID!.rawValue.uuidString
        let historicalProfileRoots = historicalSessions.map {
            $0.0.paths.resolve($0.0.analysisProfile.projectRoot)
        }.sorted()
        var historicalRootByLanguage: [LanguageID: String] = [:]
        for (session, _) in historicalSessions {
            historicalRootByLanguage[session.analysisProfile.language] =
                session.paths.resolve(session.analysisProfile.projectRoot)
        }
        guard Set(historicalSessions.map { $0.0.analysisProfile.language })
                == Set([.rust, .python, .typescript]),
              historicalRootByLanguage[.rust] == "crates/qrcode2txt",
              historicalRootByLanguage[.python] == ".",
              historicalRootByLanguage[.typescript] == ".",
              historicalRust == 11,
              historicalPython == 9,
              historicalTS == 0,
              historicalSessions.contains(where: {
                  $0.0.analysisProfile.language == .typescript
              })
        else {
            finish("historical snapshot language/profile/counts mismatch "
                + "rust=\(historicalRust) python=\(historicalPython) "
                + "ts=\(historicalTS) roots=\(historicalProfileRoots)")
        }
        Self.writeJSON([
            "step": "MIXED_SELF_TEST_SNAPSHOT",
            "channel": "mixed",
            "coldSnapshot": coldSnapshotID,
            "commitSnapshot": historicalSnapshotID,
            "commit": fixedHistoricalCommit,
            "switchMS": commitSwitchMS,
            "languages": historicalSessions.map { String(describing: $0.0.analysisProfile.language) },
            "counts": [
                "rust": historicalRust,
                "python": historicalPython,
                "ts": historicalTS,
            ],
            "elapsedMS": milliseconds(since: startedAt),
        ])

        let worktreeSwitchStarted = ContinuousClock.now
        model.switchToWorktree()
        let worktreeDeadline = Date(timeIntervalSinceNow: 30)
        while Date() < worktreeDeadline {
            if model.currentRevision == nil,
               model.snapshotPhase == .fullReady,
               model.querySessions.count == 3,
               model.exactCoordinator.readiness == .ready
            {
                break
            }
            if case .failed = model.projectState {
                finish("worktree switch failed")
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard model.currentRevision == nil,
              model.snapshotPhase == .fullReady,
              model.querySessions.count == 3,
              model.exactCoordinator.readiness == .ready
        else {
            finish("worktree switch did not reach ready")
        }
        let worktreeSwitchMS = milliseconds(since: worktreeSwitchStarted)
        let worktreeSnapshotID = model.currentSnapshotID!.rawValue.uuidString
        let worktreeProfileRoots = model.querySessions.map {
            $0.0.paths.resolve($0.0.analysisProfile.projectRoot)
        }.sorted()
        guard Set(worktreeProfileRoots) == Set(coldProfileRoots) else {
            finish("worktree profile roots did not restore to cold")
        }
        Self.writeJSON([
            "step": "MIXED_SELF_TEST_WORKTREE",
            "channel": "mixed",
            "worktreeSnapshot": worktreeSnapshotID,
            "ready": String(describing: model.exactCoordinator.readiness),
            "switchMS": worktreeSwitchMS,
            "elapsedMS": milliseconds(since: startedAt),
        ])

        let compareFile = root.appendingPathComponent(fixedCompareFile)
        controller.openFileForSelfTest(compareFile)
        let compareDeadline = Date(timeIntervalSinceNow: 30)
        while Date() < compareDeadline {
            if controller.displayedReaderFile?.standardizedFileURL
                == compareFile.standardizedFileURL,
               model.tabStrip.activeDocument != nil
            {
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard controller.displayedReaderFile?.standardizedFileURL
            == compareFile.standardizedFileURL
        else {
            finish("compare file did not open")
        }
        controller.applyPanelPreset(.compare)
        let comparePicked = controller.selectCompareCommit(fixedHistoricalCommit)
        let compareWaitDeadline = Date(timeIntervalSinceNow: 30)
        while Date() < compareWaitDeadline {
            if model.compare.diff != nil,
               controller.selfTestRightReaderBytes != nil
            {
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard comparePicked,
              model.compare.diff != nil,
              controller.selfTestRightReaderBytes != nil
        else {
            finish("compare picker/diff did not complete")
        }
        guard let diff = model.compare.diff,
              diff.hunks.isEmpty == false,
              diff.truncated == false,
              diff.leftLineCount == 62,
              diff.rightLineCount == 45,
              diff.changeCount == 17,
              let commitSnapshot = try? CommitSnapshot(
                  repositoryURL: root,
                  revision: fixedHistoricalCommit
              ),
              let commitBytes = try? commitSnapshot.readBytes(path: fixedCompareFile),
              controller.selfTestRightReaderBytes == commitBytes,
              controller.selfTestRightReaderBytes
                != (try? Data(contentsOf: compareFile)).map(Array.init)
        else {
            finish("compare fixed Rust hunk mismatch")
        }
        Self.writeJSON([
            "step": "MIXED_SELF_TEST_COMPARE",
            "channel": "mixed",
            "revision": fixedHistoricalCommit,
            "leftLineCount": diff.leftLineCount,
            "rightLineCount": diff.rightLineCount,
            "changeCount": diff.changeCount,
            "truncated": diff.truncated,
            "hunkCount": diff.hunks.count,
            "elapsedMS": milliseconds(since: startedAt),
        ])

        let checkpointTsxFile = root.appendingPathComponent(
            "tools/model-files-web/src/App.tsx"
        ).standardizedFileURL
        controller.openFileForSelfTest(checkpointTsxFile)
        let tsxReadyDeadline = Date(timeIntervalSinceNow: 30)
        while Date() < tsxReadyDeadline {
            if model.tabStrip.activeDocument?.languageMode
                == LanguageMode(language: .typescript, variant: "tsx"),
               controller.displayedReaderFile?.standardizedFileURL
                == checkpointTsxFile
            {
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard model.tabStrip.activeDocument?.languageMode
            == LanguageMode(language: .typescript, variant: "tsx"),
              controller.displayedReaderFile?.standardizedFileURL == checkpointTsxFile
        else {
            finish("checkpoint TSX reader was not active")
        }
        controller.checkpointSessionSynchronously()
        guard let savedSnapshot = model.loadSessionSnapshot(
            forProject: root
        ).snapshot else {
            finish("checkpoint did not persist session")
        }
        guard savedSnapshot.languages == [.rust, .python, .typescript],
              savedSnapshot.revision == nil
        else {
            finish("checkpoint languages/revision mismatch")
        }
        let recentStore = recentProjectsStore
        model.exactCoordinator.shutdown()
        controller.openProject(root: root, forcingReopen: true)
        let reopenDeadline = Date(timeIntervalSinceNow: 30)
        var reopenOK = false
        while Date() < reopenDeadline {
            if model.snapshotPhase == .fullReady,
               model.querySessions.count == 3,
               model.exactCoordinator.readiness == .ready
            {
                reopenOK = true
                break
            }
            if case .failed = model.projectState { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard reopenOK else {
            finish("hot recent reopen did not reach fullReady")
        }
        let hotSessions = model.querySessions
        var hotByLanguage: [String: [String: Any]] = [:]
        var hotReused = 0
        for (session, _) in hotSessions {
            let key = String(describing: session.analysisProfile.language)
            let activePaths = session.manifest.files.map {
                session.paths.resolve($0.pathID)
            }.filter {
                LanguageMode.classify(
                    path: $0,
                    language: session.analysisProfile.language
                ) != nil
            }
            hotByLanguage[key] = [
                "files": activePaths.count,
                "extracted": session.stats.extractedCount,
                "reused": session.stats.reusedCount,
            ]
            hotReused += session.stats.reusedCount
        }
        guard hotReused > 0 else {
            finish("hot reopen did not reuse cache")
        }
        let generationBeforeRestore = model.generation
        controller.restoreSession(savedSnapshot)
        let restoreDeadline = Date(timeIntervalSinceNow: 30)
        while Date() < restoreDeadline {
            if model.generation != generationBeforeRestore,
               model.snapshotPhase == .fullReady,
               model.querySessions.count == 3,
               model.exactCoordinator.readiness == .ready,
               controller.displayedReaderFile?.standardizedFileURL == checkpointTsxFile,
               model.tabStrip.activeDocument?.languageMode
                == LanguageMode(language: .typescript, variant: "tsx"),
               model.exactCoordinator.attribution?.provider
                == "typescript-language-server"
            {
                break
            }
            if case .failed = model.projectState { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard model.generation != generationBeforeRestore,
              model.snapshotPhase == .fullReady,
              model.querySessions.count == 3,
              model.projectLanguages == [.rust, .python, .typescript],
              model.exactCoordinator.readiness == .ready,
              controller.displayedReaderFile?.standardizedFileURL
                == checkpointTsxFile,
              model.tabStrip.activeDocument?.languageMode
                == LanguageMode(language: .typescript, variant: "tsx"),
              model.exactCoordinator.attribution?.provider
                == "typescript-language-server"
        else {
            finish("checkpoint restore did not reach mixed fullReady")
        }
        recentStore.clear()
        Self.writeJSON([
            "step": "MIXED_SELF_TEST_HOT",
            "channel": "mixed",
            "savedLanguages": savedSnapshot.languages.map { String(describing: $0) },
            "hotReused": hotReused,
            "restoreGeneration": model.generation,
            "restoreTSX": true,
            "elapsedMS": milliseconds(since: startedAt),
        ])

        do {
            let head = try git(["rev-parse", "HEAD"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let status = try git([
                "status",
                "--porcelain=v1",
                "--untracked-files=all",
                "--ignored=matching",
            ])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard head == fixedCommit, status.isEmpty else {
                finish("post journey repo HEAD/status changed")
            }
        } catch {
            finish("post journey git check failed")
        }
        let checks: [String: Bool] = [
            "cold": true,
            "search": true,
            "reader": true,
            "exact": true,
            "snapshot": true,
            "compare": true,
            "hot": true,
            "restore": true,
            "cleanHead": true,
        ]
        Self.writeJSON([
            "step": "MIXED_SELF_TEST_SUMMARY",
            "channel": "mixed",
            "passed": true,
            "checks": checks,
            "coldSnapshot": coldSnapshotID,
            "commitSnapshot": historicalSnapshotID,
            "worktreeSnapshot": worktreeSnapshotID,
            "profileRoots": coldProfileRoots,
            "coldStats": coldByLanguage,
            "hotStats": hotByLanguage,
            "providerVersions": exactOutputs.map {
                [
                    "provider": $0["provider"]!,
                    "toolVersion": $0["toolVersion"]!,
                    "readyMS": $0["readyMS"]!,
                ]
            },
            "commitSwitchMS": commitSwitchMS,
            "worktreeSwitchMS": worktreeSwitchMS,
            "elapsedMS": milliseconds(since: startedAt),
        ])
        model.exactCoordinator.shutdown()
        Self.exitSelfTest(channel: "mixed", status: 0)
    }

    private func finishTypeScriptSelfTest(
        coldFileCount: Int,
        coldReused: Int,
        coldExtracted: Int,
        hotFileCount: Int,
        hotReused: Int,
        hotExtracted: Int,
        checks: [String: Bool],
        startedAt: ContinuousClock.Instant
    ) -> Never {
        let passed = checks.values.allSatisfy { $0 }
        Self.writeJSON([
            "step": "summary",
            "channel": "typescript",
            "passed": passed,
            "cold": [
                "fileCount": coldFileCount,
                "reused": coldReused,
                "extracted": coldExtracted,
            ],
            "hot": [
                "fileCount": hotFileCount,
                "reused": hotReused,
                "extracted": hotExtracted,
            ],
            "checks": checks,
            "elapsedMS": milliseconds(since: startedAt),
        ])
        Self.exitSelfTest(channel: "typescript", status: passed ? 0 : 1)
    }

    private func finishTypeScriptSelfTest(
        error: String,
        startedAt: ContinuousClock.Instant
    ) -> Never {
        Self.writeJSON([
            "step": "summary",
            "channel": "typescript",
            "passed": false,
            "error": error,
            "elapsedMS": milliseconds(since: startedAt),
        ])
        Self.exitSelfTest(channel: "typescript", status: 1)
    }
}

private struct DiffSelfTestTarget {
    let file: URL
    let path: String
    let worktreeBytes: [UInt8]
    let commitBytes: [UInt8]
    let expected: DiffCore.Result
}

private func pythonFiles(in nodes: [FileTreeNode]) -> [URL] {
    nodes.flatMap { node in
        node.isDirectory ? pythonFiles(in: node.children) : [node.url]
    }
}

private func utf8Offsets(
    of needle: String,
    in bytes: [UInt8]
) -> [Int] {
    guard !needle.isEmpty else { return [] }
    let data = Data(bytes)
    let pattern = Data(needle.utf8)
    var result: [Int] = []
    var start = data.startIndex
    while start < data.endIndex,
          let range = data.range(of: pattern, in: start ..< data.endIndex)
    {
        result.append(range.lowerBound)
        start = range.upperBound
    }
    return result
}

@MainActor
private func contentSearchHits(
    session: EngineSession,
    context: QueryContext,
    query: ContentSearchQuery
) async throws -> [String] {
    var paths: [String] = []
    for try await batch in try session.search(query, context: context) {
        for pathID in batch.matchesByPath.keys {
            paths.append(session.paths.resolve(pathID))
        }
    }
    return paths
}

private func previousCommitRevision(root: URL) -> String? {
    guard (try? CommitSnapshot(
        repositoryURL: root,
        revision: "HEAD~1"
    )) != nil else { return nil }
    return "HEAD~1"
}
