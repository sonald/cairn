import AppKit
import CodeInsightCore
import CodeInsightReaderCore
import CodeInsightReaderUI
import CoreText
import CryptoKit
import Darwin
import os

/// Release-only acceptance is invoked explicitly; this does not change saved Reader preferences.
@MainActor
func runLigatureSelfTest(arguments: [String]) -> Never {
    func option(_ name: String) -> String? {
        guard let i = arguments.firstIndex(of: name), arguments.indices.contains(i + 1) else { return nil }
        return arguments[i + 1]
    }
    let output = URL(fileURLWithPath: option("--json-out") ?? "/tmp/reader-ligatures.json")
    func write(_ value: [String: Any]) {
        do {
            try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
                .write(to: output, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("ligatures: \(error)\n".utf8))
            exit(1)
        }
    }
    func stop(_ reason: String, status: String = "failed", details: [String: Any] = [:]) -> Never {
        write(["status": status, "reason": reason, "details": details])
        exit(status == "blocked" ? 2 : 1)
    }
    guard let path = option("--fixture"), let requested = option("--font-postscript") else {
        stop("Required: --fixture PATH --font-postscript NAME [--mode enabled|disabled|fontDefault] [--json-out PATH]")
    }
    guard let mode = CodeLigatureMode(rawValue: option("--mode") ?? "enabled") else { stop("Unknown mode") }
    let sampleCount = max(30, Int(option("--samples") ?? "30") ?? 30)
    let warmup = 5
    let fixture = URL(fileURLWithPath: path)
    let bytes: Data
    do { bytes = try Data(contentsOf: fixture) } catch { stop("Fixture read failed: \(error)") }
    guard let source = String(data: bytes, encoding: .utf8) else { stop("Fixture is not UTF-8") }
    let selection: CodeFontSelection = requested == "system" ? .systemMonospaced : .postScriptName(requested)
    if requested != "system", NSFont(name: requested, size: 13) == nil { stop("Missing requested font \(requested)", status: "blocked") }
    let loader = DocumentLoader(source: { _ in Array(bytes) })
    let initial: ReaderDocument
    do { initial = try loader.load(file: fixture).document } catch { stop("Document load failed: \(error)") }
    let syntax = OSAllocatedUnfairLock(initialState: Optional<Result<ReaderDocument, RustHighlighterError>>.none)
    loader.loadSyntax(for: initial) { result in syntax.withLock { $0 = result } }
    let deadline = Date(timeIntervalSinceNow: 30)
    while syntax.withLock({ $0 == nil }), Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005)) }
    guard let result = syntax.withLock({ $0 }) else { stop("Syntax loading timed out") }
    let document: ReaderDocument
    switch result { case .success(let value): document = value; case .failure(let error): stop("Syntax failed: \(error)") }

    var settings = ReaderSettings()
    settings.codeFont = selection
    settings.codeLigatures = mode
    settings.fontSize = 13
    settings.wrapLines = true
    settings.humanistComments = false
    let reader = ReaderTextView(settings: settings)
    let window = NSWindow(contentRect: NSRect(x: 120, y: 100, width: 1200, height: 760), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "Cairn Ligature Acceptance — \(requested)"
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 1200, height: 760))
    scroll.autoresizingMask = [.width, .height]
    scroll.hasVerticalScroller = true
    scroll.scrollerStyle = .overlay
    scroll.documentView = reader.view
    window.contentView = scroll
    reader.view.frame = scroll.contentView.bounds
    reader.installDiffGutter(in: scroll)
    reader.display(document: document, fileURL: fixture)
    window.makeFirstResponder(reader.view)
    guard var bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2400, pixelsHigh: 1520,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { stop("Bitmap allocation failed") }
    func elapsed(_ start: ContinuousClock.Instant) -> Double {
        let d = start.duration(to: .now).components
        return Double(d.seconds) * 1000 + Double(d.attoseconds) / 1e15
    }
    func draw() {
        reader.view.textLayoutManager?.textViewportLayoutController.layoutViewport()
        let rect = reader.view.visibleRect.intersection(reader.view.bounds)
        guard !rect.isEmpty else { return }
        // Keep a fixed 2x pixel density for both modes. The drawable document can
        // be shorter than the viewport, so size the reusable bitmap to this rect.
        let pixelWidth = max(1, Int(ceil(rect.width * 2)))
        let pixelHeight = max(1, Int(ceil(rect.height * 2)))
        if bitmap.pixelsWide != pixelWidth || bitmap.pixelsHigh != pixelHeight {
            guard let resized = NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: pixelWidth, pixelsHigh: pixelHeight, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            else { stop("Render bitmap allocation failed") }
            bitmap = resized
        }
        bitmap.size = rect.size
        reader.view.cacheDisplay(in: rect, to: bitmap)
    }
    func actualFragmentAttributes() -> [NSAttributedString.Key: Any]? {
        guard let manager = reader.view.textLayoutManager,
              let location = manager.textViewportLayoutController.viewportRange?.location,
              let fragment = manager.textLayoutFragment(for: location),
              let line = fragment.textLineFragments.first, line.attributedString.length > 0 else { return nil }
        // Use the visible text location; view coordinates include the gutter/inset and
        // cannot be passed directly to the layout manager's container-coordinate API.
        return line.attributedString.attributes(at: 0, effectiveRange: nil)
    }
    func actualFragmentFont() -> NSFont? { actualFragmentAttributes()?[.font] as? NSFont }
    func effectiveFeatures(_ font: NSFont) -> [[String: Any]] {
        CTFontCopyFeatureSettings(font) as? [[String: Any]] ?? []
    }
    func normalizedFeatures(_ values: [[String: Any]]) -> [String] {
        values.map { value in
            let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            return data.flatMap { String(data: $0, encoding: .utf8) } ?? String(describing: value)
        }.sorted()
    }
    var lastFrameDiagnostics: [String: Any] = [:]
    func fragmentMatches() -> Bool {
        let expected = ReaderFontResolver.shared.resolve(selection: selection, mode: settings.codeLigatures, size: 13)
        let attributes = actualFragmentAttributes()
        let actual = attributes?[.font] as? NSFont
        let expectedFeatures = effectiveFeatures(expected.font)
        let actualFeatures = actual.map(effectiveFeatures) ?? []
        lastFrameDiagnostics = [
            "expectedFont": expected.actualPostScriptName, "actualFont": actual?.fontName ?? "missing",
            "requestedFeatures": expected.featureRequests, "expectedEffectiveFeatures": expectedFeatures,
            "actualEffectiveFeatures": actualFeatures, "backgroundDrawCount": reader.backgroundDrawCount,
            "visibleRect": NSStringFromRect(reader.view.visibleRect),
            "viewportPresent": reader.view.textLayoutManager?.textViewportLayoutController.viewportRange != nil,
            "expectedLigatureAttribute": expected.attributes[.ligature] as? Int ?? -1,
            "actualLigatureAttribute": attributes?[.ligature] as? Int ?? -1,
        ]
        // Core Text discards unsupported requests and may normalize tags to AAT selectors.
        // Compare the resolved fonts' effective settings, not the original request list.
        return actual?.fontName == expected.actualPostScriptName
            && actual?.pointSize == expected.font.pointSize
            && normalizedFeatures(actualFeatures) == normalizedFeatures(expectedFeatures)
            && (attributes?[.ligature] as? Int) == (expected.attributes[.ligature] as? Int)
    }
    func frame() -> Double? {
        let start = ContinuousClock.now
        let before = reader.backgroundDrawCount
        let until = Date(timeIntervalSinceNow: 2)
        repeat {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.004))
            draw()
            if reader.backgroundDrawCount > before, fragmentMatches(), reader.displayedBytes == Array(bytes) { return elapsed(start) }
        } while Date() < until
        return nil
    }
    guard frame() != nil else { stop("No correctly rendered initial Reader frame", details: lastFrameDiagnostics) }
    let memorySamples = OSAllocatedUnfairLock(initialState: [ligatureFootprint()])
    let stalls = OSAllocatedUnfairLock(initialState: [Double]())
    let queue = DispatchQueue(label: "cairn.ligatures.probes")
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now(), repeating: .milliseconds(5))
    let heartbeat: @Sendable () -> Void = {
        let start = ContinuousClock.now
        let memory = ligatureFootprint()
        memorySamples.withLock { $0.append(memory) }
        DispatchQueue.main.async {
            let duration = start.duration(to: .now).components
            let ms = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
            stalls.withLock { $0.append(ms) }
        }
    }
    timer.setEventHandler(handler: heartbeat)
    timer.resume()
    var checks: [String: Bool] = [:]
    var details: [[String: Any]] = []
    let displayed = reader.view.string
    checks["sourceAndDisplayEqual"] = displayed == source && reader.displayedBytes == Array(bytes)
    let projectionBaseline = reader.projectionInstallCount
    let attributeBaseline = reader.typographyAttributeUpdateCount
    let paragraphBaseline = reader.paragraphUpdateCount
    reader.apply(settings: settings)
    checks["idempotentApply"] = reader.projectionInstallCount == projectionBaseline
        && reader.typographyAttributeUpdateCount == attributeBaseline && reader.paragraphUpdateCount == paragraphBaseline

    // Exercise NSTextView's native selection commands and production copy override.
    let pasteboard = NSPasteboard.general
    let savedPasteboard = pasteboard.pasteboardItems?.map { item in
        item.types.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in item.data(forType: type).map { (type, $0) } }
    } ?? []
    for token in ["!=", "!==", "👩🏽‍💻", "e\u{301}"] {
        let tokenRange = (displayed as NSString).range(of: token)
        guard tokenRange.location != NSNotFound else { continue }
        let range = token == "!=" || token == "!==" ? NSRange(location: tokenRange.location + 1, length: 1) : tokenRange
        reader.view.setSelectedRange(NSRange(location: range.location, length: 0))
        reader.view.moveRightAndModifySelection(nil)
        let native = reader.view.selectedRange()
        reader.view.copy(nil)
        let expected = (displayed as NSString).substring(with: range)
        let copied = pasteboard.string(forType: .string) ?? ""
        checks["keyboardCopy:\(token)"] = native == range && copied == expected
        var geometry: [[CGFloat]] = []
        if let manager = reader.view.textLayoutManager, let content = manager.textContentManager,
           let start = content.location(content.documentRange.location, offsetBy: range.location),
           let end = content.location(start, offsetBy: range.length),
           let textRange = NSTextRange(location: start, end: end) {
            manager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, rect, _, _ in
                geometry.append([rect.minX, rect.minY, rect.width, rect.height])
                return true
            }
        }
        checks["nativeGeometry:\(token)"] = !geometry.isEmpty
        details.append(["textKitSegments": geometry, "token": token, "selectedLocation": native.location, "selectedLength": native.length, "copied": copied, "expected": expected])
        if let start = reader.byteOffset(forCharacterIndex: range.location),
           let end = reader.byteOffset(forCharacterIndex: NSMaxRange(range)) {
            reader.setFindMatches([CodeInsightCore.ByteRange(lowerBound: start, upperBound: end)], selectedIndex: 0)
            checks["find:\(token)"] = reader.revealFindMatch(at: 0) && reader.view.selectedRange() == range
        }
    }
    reader.clearFindMatches(restoringSymbolAt: nil)
    var directionalSelections: [[String: Any]] = []
    let operatorRange = (displayed as NSString).range(of: "!=")
    if operatorRange.location != NSNotFound {
        for reverse in [false, true] {
            for (beforeMode, afterMode) in [(CodeLigatureMode.enabled, CodeLigatureMode.disabled),
                                            (.disabled, .fontDefault), (.fontDefault, .enabled)] {
                settings.codeLigatures = beforeMode
                reader.apply(settings: settings)
                let setupRendered = frame() != nil
                // Only position the initial caret programmatically. Native Shift-arrow
                // commands establish and then extend the directional selection anchor.
                let caret = reverse ? NSMaxRange(operatorRange) : operatorRange.location
                reader.view.setSelectedRange(NSRange(location: caret, length: 0))
                if reverse { reader.view.moveLeftAndModifySelection(nil) }
                else { reader.view.moveRightAndModifySelection(nil) }
                let before = reader.view.selectedRange()
                let affinityBefore = reader.view.selectionAffinity.rawValue
                let expectedBefore = NSRange(location: operatorRange.location + (reverse ? 1 : 0), length: 1)
                settings.codeLigatures = afterMode
                reader.apply(settings: settings)
                let switchedRendered = frame() != nil
                let after = reader.view.selectedRange()
                let affinityAfter = reader.view.selectionAffinity.rawValue
                if reverse { reader.view.moveLeftAndModifySelection(nil) }
                else { reader.view.moveRightAndModifySelection(nil) }
                let extended = reader.view.selectedRange()
                reader.view.copy(nil)
                let copied = pasteboard.string(forType: .string) ?? ""
                let direction = reverse ? "reverse" : "forward"
                let name = "directionalSelection:\(direction):\(beforeMode.rawValue)->\(afterMode.rawValue)"
                checks[name] = setupRendered && switchedRendered && before == expectedBefore
                    && after == before && affinityBefore == affinityAfter
                    && extended == operatorRange && copied == "!="
                directionalSelections.append([
                    "direction": direction, "beforeMode": beforeMode.rawValue, "afterMode": afterMode.rawValue,
                    "before": [before.location, before.length], "after": [after.location, after.length],
                    "extended": [extended.location, extended.length], "expectedExtended": [operatorRange.location, operatorRange.length],
                    "affinityBefore": affinityBefore, "affinityAfter": affinityAfter, "copiedSource": copied,
                    "sourceByteStart": reader.byteOffset(forCharacterIndex: extended.location).map(Int.init) ?? -1,
                    "sourceByteEnd": reader.byteOffset(forCharacterIndex: NSMaxRange(extended)).map(Int.init) ?? -1,
                ])
            }
        }
    }
    pasteboard.clearContents()
    let restoredItems = savedPasteboard.map { entries in
        let item = NSPasteboardItem()
        for (type, data) in entries { item.setData(data, forType: type) }
        return item
    }
    pasteboard.writeObjects(restoredItems)
    reader.clearFindMatches(restoringSymbolAt: nil)
    reader.view.setSelectedRange(NSRange(location: 1, length: min(3, max(0, displayed.utf16.count - 1))))
    let savedSelection = reader.view.selectedRanges
    var applyTimes: [Double] = []
    var typographyTimes: [Double] = []
    var resolutionTimes: [Double] = []
    var firstFrames: [Double] = []
    var settledTimes: [Double] = []
    for i in 0..<(sampleCount + warmup) {
        settings.codeLigatures = i.isMultiple(of: 2) ? .disabled : .enabled
        let resolutionBefore = ReaderFontResolver.shared.fontResolutionMilliseconds
        let typographyBefore = reader.typographyAttributeUpdateMilliseconds
        let start = ContinuousClock.now
        reader.apply(settings: settings)
        let applyMs = elapsed(start)
        let typographyMs = reader.typographyAttributeUpdateMilliseconds - typographyBefore
        let resolutionMs = ReaderFontResolver.shared.fontResolutionMilliseconds - resolutionBefore
        if i >= warmup {
            applyTimes.append(applyMs)
            typographyTimes.append(typographyMs)
            resolutionTimes.append(resolutionMs)
        }
        guard frame() != nil else { stop("Incorrect Reader frame after typography switch \(i)") }
        let first = elapsed(start)
        var last: [CGFloat] = []
        var stable = 0
        let until = Date(timeIntervalSinceNow: 2)
        while stable < 3, Date() < until {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
            draw()
            let signature = [reader.view.frame.height, scroll.contentView.bounds.minY]
            stable = signature == last ? stable + 1 : 0
            last = signature
        }
        if i >= warmup { firstFrames.append(first); settledTimes.append(elapsed(start)) }
        checks["selectionPreserved"] = (checks["selectionPreserved"] ?? true) && reader.view.selectedRanges == savedSelection
    }
    checks["projectionReuse"] = reader.projectionInstallCount == projectionBaseline
    checks["sourceUnchangedAfterSwitches"] = reader.view.string == displayed && reader.displayedBytes == Array(bytes)
    func percentile(_ values: [Double], _ p: Double) -> Double {
        values.sorted()[min(values.count - 1, Int(ceil(Double(values.count) * p)) - 1)]
    }
    var scrolling: [String: [Double]] = [:]
    for scrollMode in [CodeLigatureMode.disabled, .enabled] {
        settings.codeLigatures = scrollMode
        reader.apply(settings: settings)
        guard frame() != nil else { stop("Scroll setup frame failed") }
        var times: [Double] = []
        for i in 0..<(sampleCount + warmup) {
            let start = ContinuousClock.now
            let maxY = max(0, reader.view.frame.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: -scroll.contentView.contentInsets.left, y: min(maxY, CGFloat(i % 15) * 32)))
            scroll.reflectScrolledClipView(scroll.contentView)
            draw()
            if i >= warmup { times.append(elapsed(start)) }
        }
        scrolling[scrollMode.rawValue] = times
    }
    let memoryBeforeStress = ligatureFootprint()
    var stressMemory: [UInt64] = []
    for i in 0..<100 {
        settings.codeLigatures = i.isMultiple(of: 2) ? .enabled : .disabled
        reader.apply(settings: settings)
        if i.isMultiple(of: 10) {
            _ = frame()
            stressMemory.append(ligatureFootprint())
        }
    }
    guard frame() != nil else { stop("No final stress frame") }
    let memoryAfterStress = ligatureFootprint()
    var quietMemory: [UInt64] = []
    for _ in 0..<10 {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        quietMemory.append(ligatureFootprint())
    }
    var readerReleased: [() -> Bool] = []
    var textViewReleased: [() -> Bool] = []
    for _ in 0..<10 {
        autoreleasepool {
            let ephemeral = ReaderTextView(settings: settings)
            let closedWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                        styleMask: [.borderless], backing: .buffered, defer: false)
            closedWindow.isReleasedWhenClosed = false
            closedWindow.contentView = ephemeral.view
            ephemeral.display(document: document, fileURL: fixture)
            var closingSettings = settings
            for i in 0..<10 {
                closingSettings.codeLigatures = i.isMultiple(of: 2) ? .enabled : .disabled
                ephemeral.apply(settings: closingSettings)
            }
            readerReleased.append { [weak ephemeral] in ephemeral == nil }
            textViewReleased.append { [weak textView = ephemeral.view] in textView == nil }
            closedWindow.contentView = nil
            closedWindow.close()
        }
    }
    // AppKit releases its transient layout references on later run-loop turns;
    // poll a fixed deadline instead of interpreting a 50 ms sample as a leak.
    let releaseStart = ContinuousClock.now
    let releaseDeadline = Date(timeIntervalSinceNow: 2)
    var releaseSamples: [[String: Any]] = []
    repeat {
        autoreleasepool { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01)) }
        let readersAlive = readerReleased.filter { !$0() }.count
        let textViewsAlive = textViewReleased.filter { !$0() }.count
        releaseSamples.append(["elapsedMs": elapsed(releaseStart), "readersAlive": readersAlive,
                               "textViewsAlive": textViewsAlive])
        if readersAlive == 0 && textViewsAlive == 0 { break }
    } while Date() < releaseDeadline
    checks["closedReaderReleased"] = readerReleased.allSatisfy { $0() }
    checks["closedTextViewReleased"] = textViewReleased.allSatisfy { $0() }
    timer.cancel()
    queue.sync {}
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    checks["boundedFontCache"] = ReaderFontResolver.shared.cacheCount <= ReaderFontResolver.shared.cacheLimit
    settings.codeLigatures = mode
    reader.apply(settings: settings)
    scroll.contentView.scroll(to: NSPoint(x: -scroll.contentView.contentInsets.left,
                                        y: -scroll.contentView.contentInsets.top))
    guard frame() != nil else { stop("Final requested mode failed to render") }
    checks["projectionReuseAfterStress"] = reader.projectionInstallCount == projectionBaseline
    checks["sourceUnchangedAfterStress"] = reader.view.string == displayed && reader.displayedBytes == Array(bytes)
    let screenshot = output.deletingPathExtension().appendingPathExtension("png")
    // Capture the complete viewport (including gutter) separately from timed draws.
    guard let viewportBitmap = scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds)
    else { stop("Viewport screenshot allocation failed") }
    scroll.cacheDisplay(in: scroll.bounds, to: viewportBitmap)
    guard let png = viewportBitmap.representation(using: .png, properties: [:])
    else { stop("Viewport screenshot encoding failed") }
    do { try png.write(to: screenshot) } catch { stop("Viewport screenshot write failed: \(error)") }
    let n03 = percentile(firstFrames, 0.95) <= 300 && percentile(settledTimes, 0.95) <= 1000
    let offP95 = percentile(scrolling["disabled"]!, 0.95)
    let onP95 = percentile(scrolling["enabled"]!, 0.95)
    let n04 = onP95 <= max(offP95 * 1.2, offP95 + 2)
    let scrollBudgetApplies = reader.view.frame.height > scroll.contentView.bounds.height
    let regularBudgetApplies = (1500...2500).contains(document.lineTable.lineStarts.count)
    let passed = checks.values.allSatisfy { $0 } && (!regularBudgetApplies || n03) && (!scrollBudgetApplies || n04)
    #if DEBUG
    let build = "debug"
    #else
    let build = "release"
    #endif
    let actual = ReaderFontResolver.shared.resolve(selection: selection, mode: mode, size: 13)
    let ctFont = CTFontCreateWithName(actual.font.fontName as CFString, 13, nil)
    let fontURL = CTFontCopyAttribute(ctFont, kCTFontURLAttribute) as? URL
    let fontData = fontURL.flatMap { try? Data(contentsOf: $0) }
    let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
    write(["schemaVersion": 1, "status": passed ? "passed" : "failed", "scope": "Reader native offscreen rendering and keyboard/find/copy; mouse and other surfaces require separate acceptance",
           "build": build, "os": ProcessInfo.processInfo.operatingSystemVersionString, "requestedFont": requested,
           "actualFragmentFont": actualFragmentFont()?.fontName ?? "missing", "mode": mode.rawValue,
           "fixture": path, "fixtureSHA256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
           "sourceLineCount": document.lineTable.lineStarts.count,
           "maxSourceLineBytes": lines.map { $0.utf8.count }.max() ?? 0,
           "fontVersion": CTFontCopyName(ctFont, kCTFontVersionNameKey) as String? ?? "unknown",
           "fontPath": fontURL?.path ?? "unavailable",
           "fontSHA256": fontData.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "unavailable",
           "requestedFeatures": actual.featureRequests,
           "effectiveFeatures": effectiveFeatures(actual.font),
           "actualFragmentEffectiveFeatures": actualFragmentFont().map(effectiveFeatures) ?? [],
           "sourceBytes": bytes.count, "utf16Units": source.utf16.count, "backingScaleFactor": window.backingScaleFactor,
           "samples": sampleCount, "warmup": warmup, "checks": checks, "selectionCases": details, "directionalSelectionCases": directionalSelections,
           "applyMs": applyTimes, "typographyTransactionMs": typographyTimes,
           "fontResolutionMs": resolutionTimes,
           "fontResolutionCount": ReaderFontResolver.shared.fontResolutionCount,
           "fontResolutionCumulativeMs": ReaderFontResolver.shared.fontResolutionMilliseconds,
           "firstCorrectFrameMs": firstFrames, "settledMs": settledTimes,
           "firstCorrectFrameP95Ms": percentile(firstFrames, 0.95), "settledP95Ms": percentile(settledTimes, 0.95), "N03": n03, "N03RegularFixtureBudgetApplies": regularBudgetApplies,
           "renderPixelScale": 2, "renderBitmapPixels": [bitmap.pixelsWide, bitmap.pixelsHigh],
           "renderBitmapPoints": [bitmap.size.width, bitmap.size.height],
           "scrollFrameMeasurement": "synchronous native cacheDisplay wall time at fixed 2x density, not display vsync intervals", "scrollFrameMs": scrolling,
           "scrollOffP95Ms": offP95, "scrollOnP95Ms": onP95, "N04": n04, "N04ScrollableFixtureBudgetApplies": scrollBudgetApplies,
           "physicalBytesBeforeStress": memoryBeforeStress, "physicalBytesAfterStress": memoryAfterStress,
           "closedWindowCount": 10, "closedWindowTypographySwitchCount": 100,
           "releaseDeadlineMs": 2000, "releaseSamples": releaseSamples,
           "stressPhysicalBytesEvery10": stressMemory, "quietPhysicalBytes50ms": quietMemory,
           "peakPhysicalBytes": memorySamples.withLock { $0.max() ?? 0 },
           "mainThreadHeartbeatMaxDelayMs": stalls.withLock { $0.max() ?? 0 },
           "projectionInstallDelta": reader.projectionInstallCount - projectionBaseline,
           "typographyAttributeUpdates": reader.typographyAttributeUpdateCount - attributeBaseline,
           "fontCacheCount": ReaderFontResolver.shared.cacheCount, "fontCacheLimit": ReaderFontResolver.shared.cacheLimit,
           "fontCacheHits": ReaderFontResolver.shared.fontCacheHitCount, "screenshot": screenshot.path,
           "largeFileViewportDegraded": document.lineTable.lineStarts.count > 8000])
    if arguments.contains("--interactive") {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.run()
    }
    exit(passed ? 0 : 1)
}

private nonisolated func ligatureFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return status == KERN_SUCCESS ? info.phys_footprint : 0
}
