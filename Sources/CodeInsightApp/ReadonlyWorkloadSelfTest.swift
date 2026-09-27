import AppKit
import CodeInsightCore
import CodeInsightReaderCore
import CodeInsightReaderUI
import CryptoKit
import Darwin
import os

/// Explicit native workload capture; never treats missing native evidence as a pass.
@MainActor
func runReadonlyWorkloadSelfTest(arguments: [String]) -> Never {
    func option(_ name: String) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
    let output = URL(fileURLWithPath: option("--output") ?? "/tmp/readonly-workload.json")
    func finish(_ report: [String: Any], code: Int32) -> Never {
        do {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: output, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("readonly workload: \(error)\n".utf8))
            exit(1)
        }
        exit(code)
    }
    guard let path = option("--fixture") else {
        finish(["status": "fail", "reason": "--fixture PATH required"], code: 1)
    }
    guard CGSessionCopyCurrentDictionary() != nil else {
        finish(["status": "blocked", "reason": "No native WindowServer session"], code: 2)
    }
    let memorySamples = OSAllocatedUnfairLock(initialState: [UInt64]())
    let memoryTimer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "readonly.memory"))
    memoryTimer.schedule(deadline: .now(), repeating: .milliseconds(25))
    let sampleMemory: @Sendable () -> Void = {
        if let bytes = physicalFootprintBytes() { memorySamples.withLock { $0.append(bytes) } }
    }
    memoryTimer.setEventHandler(handler: sampleMemory)
    memoryTimer.resume()
    defer { memoryTimer.cancel() }
    ReaderWorkCounters.setEnabled(true)
    ReaderWorkCounters.reset()
    let preparationStart = ContinuousClock.now
    do {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        let language: LanguageID = url.pathExtension == "py" ? .python : ["ts", "tsx"].contains(url.pathExtension) ? .typescript : .rust
        let loader = DocumentLoader()
        let initial = try loader.load(file: url, languageMode: LanguageMode(language: language, variant: url.pathExtension == "tsx" ? "tsx" : nil)).document
        let pending = OSAllocatedUnfairLock(initialState: Optional<Result<ReaderDocument, RustHighlighterError>>.none)
        loader.loadSyntax(for: initial) { value in pending.withLock { $0 = value } }
        let deadline = Date(timeIntervalSinceNow: 30)
        while pending.withLock({ $0 == nil }), Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
        }
        guard let result = pending.withLock({ $0 }) else {
            finish(["status": "fail", "reason": "Syntax deadline exceeded"], code: 1)
        }
        let document = try result.get()
        let preparationDuration = preparationStart.duration(to: .now).components
        let preparationMs = Double(preparationDuration.seconds) * 1000 + Double(preparationDuration.attoseconds) / 1e15
        var settings = ReaderSettings()
        settings.wrapLines = true
        settings.fontSize = 13
        let reader = ReaderTextView(settings: settings)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1200, height: 760),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 1200, height: 760))
        scroll.hasVerticalScroller = true
        scroll.documentView = reader.view
        window.contentView = scroll
        reader.view.frame = scroll.contentView.bounds
        reader.installDiffGutter(in: scroll)
        window.makeKeyAndOrderFront(nil)
        func draw() {
            reader.view.textLayoutManager?.textViewportLayoutController.layoutViewport()
            let rect = reader.view.visibleRect.intersection(reader.view.bounds)
            if !rect.isEmpty, let bitmap = reader.view.bitmapImageRepForCachingDisplay(in: rect) {
                reader.view.cacheDisplay(in: rect, to: bitmap)
            }
            if let ruler = scroll.verticalRulerView,
               let bitmap = ruler.bitmapImageRepForCachingDisplay(in: ruler.bounds) {
                ruler.cacheDisplay(in: ruler.bounds, to: bitmap)
            }
            window.displayIfNeeded()
        }
        func counters() throws -> [String: Int] {
            try JSONDecoder().decode([String: Int].self, from: JSONEncoder().encode(ReaderWorkCounters.snapshot()))
        }
        var events: [[String: Any]] = []
        var screenshots: [String: String] = [:]
        let suite = option("--suite") ?? "all"
        let suites: [String: Set<String>] = [
            "identifiers": ["identifier-preparation", "hot-identifier"], "gutter": ["stable-scroll", "hover"],
            "projection": ["single-fold", "single-unfold", "overview", "full"],
            "reflow": ["color-only", "font-only", "color-font-wrap", "identical-settings", "syntax-arrival", "wrap-off-without-viewport"],
            "lifetime": ["a-b-a", "external-refresh", "multi-window-close", "close-reader"]
        ]
        func measure(_ name: String, _ operation: () throws -> Void) throws {
            guard suite == "all" || name == "cold-display" || name == "identifier-preparation" || suites[suite]?.contains(name) == true else { return }
            try JSONSerialization.data(withJSONObject: [
                "schemaVersion": 1, "status": "not_run", "pendingScenario": name,
                "fixture": path, "events": events
            ], options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
            let before = try counters()
            let drawBefore = reader.backgroundDrawCount
            let capturesBefore = reader.viewportGeometryCaptureCount
            let start = ContinuousClock.now
            try operation()
            draw()
            let duration = start.duration(to: .now).components
            let after = try counters()
            if (name == "stable-scroll" || name == "hover"), reader.usesPreparedDecorations,
               (after["decorationBuildCount"] != before["decorationBuildCount"]
                || after["drawGlobalRecordVisits"] != before["drawGlobalRecordVisits"]) {
                throw NSError(domain: "ReadonlyWorkload", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "Stable gutter interaction rebuilt or scanned document decorations"
                ])
            }
            if ["color-only", "font-only", "color-font-wrap", "identical-settings", "syntax-arrival"].contains(name),
               (after["projectionPlanBuildCount"] != before["projectionPlanBuildCount"]
                || after["fullTextReplacementCount"] != before["fullTextReplacementCount"]) {
                throw NSError(domain: "ReadonlyWorkload", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "A settings or unchanged-projection syntax update rebuilt characters"
                ])
            }
            if ["single-fold", "single-unfold", "overview", "full"].contains(name),
               reader.localProjectionUpdatesEnabled,
               after["fullTextReplacementCount"] != before["fullTextReplacementCount"] {
                throw NSError(domain: "ReadonlyWorkload", code: 6, userInfo: [
                    NSLocalizedDescriptionKey: "A local fold transition fell back to full character replacement: \(reader.projectionFallbackReason ?? "unknown")"
                ])
            }
            if ["font-only", "color-font-wrap"].contains(name),
               ProcessInfo.processInfo.environment["CAIRN_READONLY_REFLOW"] != "0",
               let cost = document.cost, ReaderReflowPolicy().requiresViewportOnlyLayout(for: cost) {
                guard after["applicationFullLayoutCount"] == before["applicationFullLayoutCount"],
                      reader.viewportGeometryCaptureCount == capturesBefore else {
                    throw NSError(domain: "ReadonlyWorkload", code: 8, userInfo: [
                        NSLocalizedDescriptionKey: "High-cost reflow performed a synchronous caret capture or full extent enumeration"
                    ])
                }
            }
            if name == "color-only" || name == "identical-settings" {
                guard after["applicationFullLayoutCount"] == before["applicationFullLayoutCount"],
                      reader.viewportGeometryCaptureCount == capturesBefore,
                      after["paragraphRecordsVisited"] == before["paragraphRecordsVisited"],
                      after["attributeUpdatedUTF16Units"] == before["attributeUpdatedUTF16Units"] else {
                    throw NSError(domain: "ReadonlyWorkload", code: 5, userInfo: [
                        NSLocalizedDescriptionKey: "Paint-only or identical settings performed layout/typography work"
                    ])
                }
            }
            let delta = after.map { ($0.key, $0.value - before[$0.key, default: 0]) }
            let drew = reader.backgroundDrawCount > drawBefore
            let drawRequired = name != "close-reader"
            events.append(["scenario": name, "status": !drawRequired || drew ? "pass" : "blocked",
                           "backgroundDrawBefore": drawBefore, "backgroundDrawAfter": reader.backgroundDrawCount,
                           "sourceByteCount": reader.displayedBytes?.count ?? 0,
                           "fontSize": settings.fontSize, "wrapLines": settings.wrapLines,
                           "viewportPt": [scroll.contentView.bounds.width, scroll.contentView.bounds.height],
                           "projectedUTF16Length": reader.view.textStorage?.length ?? 0,
                           "viewportGeometryCaptureDelta": reader.viewportGeometryCaptureCount - capturesBefore,
                           "lastViewportRestoreWasLimited": reader.lastViewportRestoreWasLimited,
                           "lastViewportRestoreLimitation": reader.lastViewportRestoreLimitation as Any? ?? NSNull(),
                           "lastViewportAnchorErrorPt": reader.lastViewportAnchorErrorPt as Any? ?? NSNull(),
                           "occurrenceCount": reader.occurrenceCount,
                           "selectedRanges": reader.view.selectedRanges.map { ["location": $0.rangeValue.location, "length": $0.rangeValue.length] },
                           "before": before, "after": after,
                           "delta": Dictionary(uniqueKeysWithValues: delta),
                           "operationAndDrawMs": Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15])
            if name == "cold-display" || name == "overview",
               let content = window.contentView,
               let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    let target = output.deletingPathExtension().appendingPathExtension("\(name).png")
                    try png.write(to: target)
                    screenshots[name] = target.path
                }
            }
        }
        func waitForIdentifiers() throws {
            let deadline = Date(timeIntervalSinceNow: 30)
            while reader.identifierPreparationState == .building, Date() < deadline {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
            }
            guard reader.identifierPreparationState == .ready else {
                throw NSError(domain: "ReadonlyWorkload", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Identifier preparation did not become ready: \(reader.identifierPreparationState)"
                ])
            }
        }
        try measure("cold-display") { reader.display(document: document, fileURL: url) }
        try measure("identifier-preparation") { try waitForIdentifiers() }
        let offset = String(decoding: data, as: UTF8.self).range(of: "repeated").map {
            UInt32(String(decoding: data, as: UTF8.self)[..<$0.lowerBound].utf8.count)
        } ?? 0
        if suite == "all" || suite == "identifiers" { _ = reader.activate(atByteOffset: offset) }
        try measure("hot-identifier") {
            let before = ReaderWorkCounters.snapshot()
            for _ in 0..<10 { _ = reader.activate(atByteOffset: offset) }
            let after = ReaderWorkCounters.snapshot()
            guard before.identifierBuildCount == after.identifierBuildCount,
                  before.identifierScannedBytes == after.identifierScannedBytes else {
                throw NSError(domain: "ReadonlyWorkload", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Prepared identifier interaction scanned or rebuilt source"
                ])
            }
        }
        try measure("stable-scroll") {
            for y in stride(from: 0, through: 200, by: 20) { scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); draw() }
        }
        if suite == "all" || suite == "gutter" { scroll.contentView.scroll(to: .zero); draw() }
        var hoverHits = 0
        try measure("hover") {
            if let ruler = scroll.verticalRulerView {
                for row in reader.lastRulerFirstRowRectsForTesting.values {
                    let point = NSPoint(x: reader.rulerThickness - 6,
                                        y: ruler.convert(NSPoint(x: 0, y: row.midY), from: reader.view).y)
                    reader.setFoldGutterHoverForTesting(point)
                    if reader.foldGutterIsHovered { hoverHits += 1 }
                    draw()
                }
            }
            reader.setFoldGutterHoverForTesting(nil)
        }
        if (suite == "all" || suite == "gutter"), hoverHits == 0 {
            events.append(["scenario": "hover-hit", "status": "not_run", "reason": "No visible fold handle was hit"])
        }
        if let fold = document.foldRegions.first(where: { $0.summary.hiddenLineCount >= 2 }),
           let position = document.lineTable.lineColumn(at: fold.headerRange.lowerBound) {
            for scenario in ["single-fold", "single-unfold"] {
                try measure(scenario) {
                    guard reader.toggleFold(atLine: Int(position.line)) else {
                        throw NSError(domain: "ReadonlyWorkload", code: 7, userInfo: [
                            NSLocalizedDescriptionKey: "The fixture's visible fold was not toggled"
                        ])
                    }
                }
            }
            try measure("overview") { _ = reader.setReadingHeightLevel(.overview) }
            try measure("full") { _ = reader.setReadingHeightLevel(.full) }
        } else if suite == "all" || suite == "projection" {
            events.append(["scenario": "fold-presets", "status": "not_run", "reason": "Fixture has no fold region with a visible handle"])
        }
        try measure("color-only") { settings.theme = .dark; reader.apply(settings: settings) }
        try measure("font-only") { settings.fontSize = 15; reader.apply(settings: settings) }
        try measure("color-font-wrap") {
            settings.theme = .light; settings.fontSize = 14; settings.wrapLines = false
            reader.apply(settings: settings)
        }
        try measure("identical-settings") { reader.apply(settings: settings) }
        if suite == "all" || suite == "reflow" {
            reader.display(document: ReaderDocument(bytes: document.bytes, languageMode: document.languageMode), fileURL: url)
        }
        try measure("syntax-arrival") { reader.updateSyntax(document: document) }
        if suite == "all" || suite == "lifetime" {
            let alternateURL = url.deletingLastPathComponent().appendingPathComponent("alternate.rs")
            let alternate = try DocumentLoader(source: { _ in Array("fn alternate() { let other = 2; }\n".utf8) })
                .load(file: alternateURL).document
            try measure("a-b-a") {
                reader.display(document: alternate, fileURL: alternateURL)
                reader.display(document: document, fileURL: url)
            }
            let refreshURL = FileManager.default.temporaryDirectory.appendingPathComponent("readonly-\(UUID().uuidString).\(url.pathExtension)")
            defer { try? FileManager.default.removeItem(at: refreshURL) }
            try data.write(to: refreshURL)
            let beforeRefresh = try loader.load(file: refreshURL, languageMode: LanguageMode(language: language, variant: url.pathExtension == "tsx" ? "tsx" : nil)).document
            reader.display(document: beforeRefresh, fileURL: refreshURL)
            var changed = data
            changed.append(Data("\n".utf8))
            try changed.write(to: refreshURL)
            let afterRefresh = try loader.load(file: refreshURL, languageMode: LanguageMode(language: language, variant: url.pathExtension == "tsx" ? "tsx" : nil)).document
            try measure("external-refresh") { reader.display(document: afterRefresh, fileURL: refreshURL) }
            guard reader.displayedBytes == Array(changed) else {
                finish(["status": "fail", "reason": "Refreshed source mismatch"], code: 1)
            }
            reader.display(document: document, fileURL: url)
            try measure("multi-window-close") {
                let second = ReaderTextView(settings: settings)
                let secondWindow = NSWindow(contentRect: NSRect(x: 160, y: 160, width: 600, height: 400),
                                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
                secondWindow.isReleasedWhenClosed = false
                secondWindow.contentView = second.view
                second.display(document: document, fileURL: url)
                secondWindow.makeKeyAndOrderFront(nil)
                secondWindow.displayIfNeeded()
                second.clear()
                secondWindow.close()
            }
        }
        var freshHadViewport: Bool?
        try measure("wrap-off-without-viewport") {
            var wrapped = settings
            wrapped.wrapLines = true
            let fresh = ReaderTextView(settings: wrapped)
            let unmountedScroll = NSScrollView(frame: .zero)
            unmountedScroll.documentView = fresh.view
            fresh.installDiffGutter(in: unmountedScroll)
            fresh.display(document: document)
            freshHadViewport = fresh.view.textLayoutManager?.textViewportLayoutController.viewportRange != nil
            var unwrapped = wrapped
            unwrapped.wrapLines = false
            fresh.apply(settings: unwrapped)
            fresh.clear()
        }
        if let freshHadViewport, let index = events.indices.last {
            events[index]["hadPreviousViewport"] = freshHadViewport
            if freshHadViewport {
                events[index]["status"] = "not_run"
                events[index]["reason"] = "TextKit created a viewport before wrap-off; the absent-viewport branch was not observed"
            }
        }
        let font = ReaderFontResolver.shared.resolve(selection: settings.codeFont, mode: settings.codeLigatures,
                                                     size: CGFloat(settings.fontSize)).actualPostScriptName
        try measure("close-reader") { reader.clear(); window.close() }
        let documentCost: [String: Any]
        if let cost = document.cost {
            documentCost = ["byteCount": cost.byteCount, "logicalLineCount": cost.logicalLineCount,
                            "maximumLineByteLengthIncludingTerminator": cost.maximumLineByteLength,
                            "highlightSpanCount": cost.highlightSpanCount, "foldRegionCount": cost.foldRegionCount]
        } else { documentCost = ["status": "unavailable"] }
        finish([
            "schemaVersion": 1, "status": events.contains { ($0["status"] as? String) == "blocked" } ? "blocked" : "pass",
            "captureOnly": true, "suite": option("--suite") ?? "all", "fixture": path,
            "preparationMs": preparationMs, "hoverHitCount": hoverHits,
            "sourceLineCount": document.lineTable.lineStarts.count, "documentCost": documentCost,
            "costAwareReflow": ProcessInfo.processInfo.environment["CAIRN_READONLY_REFLOW"] != "0",
            "foldCount": document.foldRegions.count, "outlineCount": document.outlineFacets.count,
            "topologyCompatibility": document.foldTopology?.usesCompatibilityRelations ?? false,
            "topologyCompatibilityRecordVisits": document.foldTopology?.compatibilityRecordVisits ?? 0,
            "foldAssociationRecordVisits": document.foldTopology?.associationRecordVisits ?? 0,
            "physicalMemorySamplesBytes": memorySamples.withLock { $0 },
            "peakPhysBytes": memorySamples.withLock { $0.max() } as Any? ?? NSNull(),
            "memorySampleIntervalMs": 25,
            "processorCount": ProcessInfo.processInfo.processorCount,
            "physicalMemoryBytes": ProcessInfo.processInfo.physicalMemory,
            "fixtureSHA256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            "codeSHA": option("--code-sha") ?? "unknown", "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "resolvedFontName": font, "windowPt": [1200, 760],
            "viewportPt": [scroll.contentView.bounds.width, scroll.contentView.bounds.height],
            "screenshots": screenshots, "events": events,
            "limitations": ["operationAndDrawMs is synchronous work, not first-paint or stable-layout latency",
                "Refresh, file switching and multi-window scenarios exercise Reader entry points; application watcher/session routing requires separate acceptance",
                "No timing budget enforced; baseline capture pass does not imply optimized-workload gates pass"]
        ], code: events.contains { ($0["status"] as? String) == "blocked" } ? 2 : 0)
    } catch {
        finish(["schemaVersion": 1, "status": "fail", "reason": String(describing: error)], code: 1)
    }
}
