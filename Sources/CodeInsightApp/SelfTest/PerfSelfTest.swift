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
    func runRelationTimingSelfTest(
        root: URL,
        file: URL,
        relativeFile: String,
        offset: UInt32,
        provider: String
    ) -> Never {
        launch(offscreen: true)
        guard let controller = windowController else {
            Self.writeJSON([
                "step": "summary",
                "passed": false,
                "error": "window unavailable",
            ])
            Self.exitSelfTest(channel: "relation-timing", status: 1)
        }

        func finish(_ result: [String: Any], status: Int32) -> Never {
            controller.close()
            model.exactCoordinator.shutdown()
            if let relationTimingTemporaryRoot {
                try? FileManager.default.removeItem(at: relationTimingTemporaryRoot)
            }
            Self.writeJSON(result)
            Self.exitSelfTest(channel: "relation-timing", status: status)
        }

        controller.window?.setContentSize(
            NSSize(width: 1_600, height: 1_000)
        )
        pumpRunLoop()
        controller.openProject(root: root)
        guard waitUntil(timeout: 120, condition: {
                  if case .failed = self.model.projectState { return true }
                  if case .ready = self.model.projectState {
                      return self.model.snapshotPhase == .fullReady
                  }
                  return false
              }),
              case .ready = model.projectState,
              model.snapshotPhase == .fullReady
        else {
            finish([
                "step": "summary",
                "passed": false,
                "error": "project index did not reach fullReady",
            ], status: 1)
        }

        if provider == "real" {
            Task { try? await model.grantCurrentRepositoryTrust() }
            guard waitUntil(timeout: 120, condition: {
                      self.model.exactCoordinator.readiness == .ready
                          && self.model.exactCoordinator.trustMode == .trusted
                  })
            else {
                finish([
                    "step": "summary",
                    "passed": false,
                    "error": "rust-analyzer did not become ready in Trusted mode",
                ], status: 1)
            }
        }

        guard waitUntil(timeout: 30, condition: {
                  controller.selectFileInSidebar(file)
              }),
              waitUntil(timeout: 30, condition: {
                  controller.displayedReaderFile?.standardizedFileURL
                      == file.standardizedFileURL
              })
        else {
            finish([
                "step": "summary",
                "passed": false,
                "error": "target file unavailable",
            ], status: 1)
        }

        let contextStartedAt = ContinuousClock.now
        controller.selfTestReaderClick(offset: offset, commandClick: false)
        let contextVisible = waitUntil(timeout: 120, condition: {
            controller.selfTestContextCandidateCount >= 1
        })
        let contextFirstActionableMS = contextVisible
            ? milliseconds(since: contextStartedAt)
            : 0
        let contextExactVisible = contextVisible && waitUntil(timeout: 120, condition: {
            controller.selfTestContextProvenance?.contains("Exact") == true
        })
        let contextExactMS = contextExactVisible
            ? milliseconds(since: contextStartedAt)
            : 0

        exactSelfTestProviderState?.delayNextRelation(by: 0.25)
        let cold = measureRelationTiming(
            model: model,
            controller: controller,
            offset: offset,
            direction: .callers,
            timeout: 120
        )
        let coldSelectable =
            !cold.relationFirstActionableTitle.isEmpty
            && controller.selfTestSelectRelationEdge(
                titled: cold.relationFirstActionableTitle
            )
            && controller.selfTestSelectedRelationEdgeTitle
                == cold.relationFirstActionableTitle
        controller.selfTestDeselectRelation()

        exactSelfTestProviderState?.delayNextRelation(by: 0.25)
        let warm = measureRelationTiming(
            model: model,
            controller: controller,
            offset: offset,
            direction: .callers,
            timeout: 120
        )
        let warmSelectable =
            !warm.relationFirstActionableTitle.isEmpty
            && controller.selfTestSelectRelationEdge(
                titled: warm.relationFirstActionableTitle
            )
            && controller.selfTestSelectedRelationEdgeTitle
                == warm.relationFirstActionableTitle
        let fieldsValid = [cold, warm].allSatisfy {
            $0.relationFirstActionableMS > 0
                && $0.relationAllResultsMS >= $0.relationFirstActionableMS
                && ["heuristic", "exact"].contains(
                    $0.relationFirstActionableKind
                )
                && $0.relationCandidateEdgeCount > 0
        }
        let passed = fieldsValid && coldSelectable && warmSelectable
        finish([
            "step": "summary",
            "variant": provider == "real" ? "rust-analyzer" : "fake",
            "measurementScope": provider == "real"
                ? "real rust-analyzer"
                : "instrumentation-only; not real rust-analyzer",
            "projectRoot": root.path,
            "file": relativeFile,
            "utf8ByteOffset": Int(offset),
            "indexHot": true,
            "cold": [
                "relationFirstActionableMS":
                    cold.relationFirstActionableMS,
                "relationAllResultsMS":
                    cold.relationAllResultsMS,
                "relationFirstActionableKind":
                    cold.relationFirstActionableKind,
                "relationFirstActionableTitle":
                    cold.relationFirstActionableTitle,
                "relationCandidateEdgeCount":
                    cold.relationCandidateEdgeCount,
            ],
            "warm": [
                "relationFirstActionableMS":
                    warm.relationFirstActionableMS,
                "relationAllResultsMS":
                    warm.relationAllResultsMS,
                "relationFirstActionableKind":
                    warm.relationFirstActionableKind,
                "relationFirstActionableTitle":
                    warm.relationFirstActionableTitle,
                "relationCandidateEdgeCount":
                    warm.relationCandidateEdgeCount,
            ],
            "coldFirstActionableSelectable": coldSelectable,
            "warmFirstActionableSelectable": warmSelectable,
            "contextFirstActionableMS": contextFirstActionableMS,
            "contextExactMS": contextExactMS,
            "contextExactVisible": contextExactVisible,
            "passed": passed,
        ], status: passed ? 0 : 1)
    }

    func runSwitchSelfTest(root: URL) -> Never {
        model.openProject(root: root)
        let openDeadline = Date(timeIntervalSinceNow: 30)
        while Date() < openDeadline {
            if case .ready = model.projectState { break }
            if case .failed = model.projectState {
                Self.finishSwitchSelfTest(state: nil, reused: 0, extracted: 0, ready: false)
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
        }
        guard case .ready = model.projectState else {
            Self.finishSwitchSelfTest(state: nil, reused: 0, extracted: 0, ready: false)
        }

        let state = SwitchSelfTestState(startedAt: .now)
        model.switchToCommit("HEAD~1")
        let deadline = Date(timeIntervalSinceNow: 30)
        while Date() < deadline {
            state.record(model.snapshotPhase)
            if model.snapshotPhase == .fullReady,
               case let .ready(session, _) = model.projectState
            {
                Self.finishSwitchSelfTest(
                    state: state,
                    reused: session.stats.reusedCount,
                    extracted: session.stats.extractedCount,
                    ready: true
                )
            }
            if case .failed = model.projectState {
                Self.finishSwitchSelfTest(
                    state: state,
                    reused: 0,
                    extracted: 0,
                    ready: false
                )
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
        }
        Self.finishSwitchSelfTest(
            state: state,
            reused: 0,
            extracted: 0,
            ready: false
        )
    }

    private static func finishSwitchSelfTest(
        state: SwitchSelfTestState?,
        reused: Int,
        extracted: Int,
        ready: Bool
    ) -> Never {
        do {
            let firstPaintMS = state?.firstPaintMS ?? -1
            let cachedReadyMS = state?.cachedReadyMS ?? -1
            let fullReadyMS = state?.fullReadyMS ?? -1
            let data = try JSONSerialization.data(
                withJSONObject: [
                    "firstPaintMS": firstPaintMS,
                    "cachedReadyMS": cachedReadyMS,
                    "fullReadyMS": fullReadyMS,
                    "firstPaintWithinBudget":
                        firstPaintMS >= 0
                            && firstPaintMS < SelfTestBudgets.snapshotFirstPaintMS,
                    "reused": reused,
                    "extracted": extracted,
                ],
                options: [.sortedKeys]
            )
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
            exitSelfTest(
                channel: "switch",
                status: firstPaintMS >= 0
                    && cachedReadyMS >= firstPaintMS
                    && fullReadyMS >= cachedReadyMS
                    && ready
                    ? 0 : 1
            )
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exitSelfTest(channel: "switch", status: 1)
        }
    }
}

private final class PerfResolutionCollector: @unchecked Sendable {
    struct Sample: Sendable {
        let milliseconds: Double
        let candidates: Int
        let accepted: Int
    }

    private let samples = OSAllocatedUnfairLock(initialState: [Sample]())

    func record(milliseconds: Double, candidates: Int, accepted: Int) {
        let sample = Sample(
            milliseconds: milliseconds,
            candidates: candidates,
            accepted: accepted
        )
        samples.withLock { $0.append(sample) }
    }

    func snapshot() -> [Sample] {
        samples.withLock { $0 }
    }
}

struct WrapPerformanceRequest {
    let fixture: URL
    let wrapOn: Bool
    let scenario: String
    let output: URL
    let codeSHA: String
    let warmupCount: Int
    let sampleCount: Int
    let fontPostScriptName: String?
    let ligatureMode: CodeLigatureMode
}

@MainActor
private final class SwitchSelfTestState {
    let startedAt: ContinuousClock.Instant
    var firstPaintMS: Double?
    var cachedReadyMS: Double?
    var fullReadyMS: Double?

    init(startedAt: ContinuousClock.Instant) {
        self.startedAt = startedAt
    }

    func record(_ phase: SnapshotPhase?) {
        guard let phase else { return }
        let elapsed = milliseconds(since: startedAt)
        // Equal timestamps mark monotonic phases coalesced into one poll.
        if firstPaintMS == nil { firstPaintMS = elapsed }
        guard phase != .firstPaint else { return }
        if cachedReadyMS == nil { cachedReadyMS = elapsed }
        guard phase == .fullReady else { return }
        if fullReadyMS == nil { fullReadyMS = elapsed }
    }
}

@MainActor
func runFoldPerformance(
    mode: String,
    fixture: URL,
    output: URL
) -> Never {
    func write(_ object: [String: Any], status: Int32) -> Never {
        do {
            let data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
            try data.write(to: output, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            Darwin.exit(1)
        }
        Darwin.exit(status)
    }

    let collector = PerfResolutionCollector()
    let loader = DocumentLoader(
        source: { file in Array(try Data(contentsOf: file, options: .mappedIfSafe)) },
        foldResolutionObserver: { milliseconds, candidates, accepted in
            collector.record(
                milliseconds: milliseconds,
                candidates: candidates,
                accepted: accepted
            )
        }
    )
    let initial: ReaderDocument
    do {
        initial = try loader.load(file: fixture).document
    } catch {
        write([
            "schemaVersion": 1,
            "mode": mode,
            "status": "error",
            "error": "fixture load failed: \(error)",
        ], status: 1)
    }

    let peakBytes = OSAllocatedUnfairLock(
        initialState: physicalFootprintBytes() ?? 0
    )
    let samplerQueue = DispatchQueue(label: "com.codeinsight.fold-perf-sampler")
    let sampler = DispatchSource.makeTimerSource(queue: samplerQueue)
    sampler.schedule(
        deadline: .now(),
        repeating: .milliseconds(25),
        leeway: .milliseconds(2)
    )
    let sampleMemory: @Sendable () -> Void = {
        guard let bytes = physicalFootprintBytes() else { return }
        peakBytes.withLock { $0 = max($0, bytes) }
    }
    sampler.setEventHandler(handler: sampleMemory)
    sampler.resume()

    func stopSampler() -> UInt64 {
        sampler.cancel()
        samplerQueue.sync {}
        return peakBytes.withLock { $0 }
    }

    let reader = ReaderTextView()
    var settings = ReaderSettings()
    settings.fontSize = 13
    settings.wrapLines = false
    settings.lineNumbers = true
    settings.theme = .siClassic
    reader.apply(settings: settings)

    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 1440, height: 900))
    window.contentView = host
    let scrollView = NSScrollView(
        frame: NSRect(x: 100, y: 60, width: 1220, height: 780)
    )
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true
    scrollView.documentView = reader.view
    host.addSubview(scrollView)
    reader.view.frame = scrollView.contentView.bounds
    reader.display(document: initial, fileURL: fixture)

    func fitViewport() {
        for _ in 0..<4 {
            scrollView.tile()
            let size = scrollView.contentView.bounds.size
            let delta = NSSize(width: 1200 - size.width, height: 760 - size.height)
            guard abs(delta.width) > 0.01 || abs(delta.height) > 0.01 else {
                break
            }
            scrollView.setFrameSize(NSSize(
                width: scrollView.frame.width + delta.width,
                height: scrollView.frame.height + delta.height
            ))
        }
        scrollView.tile()
    }
    fitViewport()
    window.displayIfNeeded()

    let syntaxResult = OSAllocatedUnfairLock(
        initialState: Optional<Result<ReaderDocument, ReaderSyntaxError>>.none
    )
    loader.loadSyntax(for: initial) { result in
        syntaxResult.withLock { $0 = result }
    }
    guard waitUntil(timeout: 10, condition: {
        syntaxResult.withLock { $0 != nil }
    }), let result = syntaxResult.withLock({ $0 })
    else {
        let peak = stopSampler()
        write([
            "schemaVersion": 1,
            "mode": mode,
            "status": "timeout",
            "samplePeriodMs": 25,
            "peakPhysBytes": peak,
        ], status: 1)
    }
    let document: ReaderDocument
    switch result {
    case .success(let loaded):
        document = loaded
    case .failure(let error):
        let peak = stopSampler()
        write([
            "schemaVersion": 1,
            "mode": mode,
            "status": "error",
            "error": "syntax load failed: \(error)",
            "samplePeriodMs": 25,
            "peakPhysBytes": peak,
        ], status: 1)
    }

    reader.updateSyntax(document: document)
    fitViewport()
    reader.view.textLayoutManager?.textViewportLayoutController.layoutViewport()
    window.displayIfNeeded()
    pumpRunLoop()

    var foldLatencyMS: Double?
    let observedCounts: (logical: Int, rendered: Int)
    if mode == "fold" {
        let started = ContinuousClock.now
        guard let counts = reader.applyFoldPerformanceOverview() else {
            let peak = stopSampler()
            write([
                "schemaVersion": 1,
                "mode": mode,
                "status": "error",
                "error": "overview projection failed",
                "samplePeriodMs": 25,
                "peakPhysBytes": peak,
            ], status: 1)
        }
        observedCounts = counts
        fitViewport()
        reader.view.textLayoutManager?.textViewportLayoutController.layoutViewport()
        window.displayIfNeeded()
        foldLatencyMS = milliseconds(since: started)
        pumpRunLoop()
        pumpRunLoop()
    } else {
        observedCounts = reader.foldPerformanceCounts
        pumpRunLoop()
        pumpRunLoop()
    }

    guard waitUntil(timeout: 10, condition: {
        guard let fragment = reader.view.textLayoutManager?
            .textLayoutFragment(for: .zero)
        else { return false }
        return !fragment.textLineFragments.isEmpty
    }) else {
        let peak = stopSampler()
        write([
            "schemaVersion": 1,
            "mode": mode,
            "status": "timeout",
            "samplePeriodMs": 25,
            "peakPhysBytes": peak,
        ], status: 1)
    }

    let peak = stopSampler()
    let samples = collector.snapshot()
    guard samples.count == 1, let resolution = samples.first else {
        write([
            "schemaVersion": 1,
            "mode": mode,
            "status": "error",
            "error": "expected exactly one resolution sample, got \(samples.count)",
            "samplePeriodMs": 25,
            "peakPhysBytes": peak,
        ], status: 1)
    }
    let storage = reader.view.textStorage
    let resolvedFont: NSFont? = storage.flatMap { storage in
        guard storage.length > 0 else { return nil }
        return storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    }
    let viewport = scrollView.contentView.bounds.size
    let windowSize = window.contentView?.bounds.size ?? .zero
    let effective = reader.foldPerformanceEffectiveSettings
    let themeName = switch effective.theme {
    case .siClassic: "SI Classic"
    case .dark: "Dark"
    case .light: "Light"
    case .auto: "Auto"
    }
    let wrapLines = reader.view.textContainer?.widthTracksTextView == true
    let fixtureSHA = document.contentID.bytes
        .map { String(format: "%02x", $0) }
        .joined()
    var object: [String: Any] = [
        "schemaVersion": 1,
        "mode": mode,
        "fixtureSHA256": fixtureSHA,
        "samplePeriodMs": 25,
        "perfConfig": [
            "wrapLines": wrapLines,
            "resolvedFontName": resolvedFont?.fontName ?? "",
            "resolvedFontSizePt": resolvedFont?.pointSize ?? 0,
            "windowPt": [windowSize.width, windowSize.height],
            "viewportPt": [viewport.width, viewport.height],
            "lineNumbers": effective.lineNumbers,
            "theme": themeName,
        ],
        "observed": [
            "candidateCount": resolution.candidates,
            "acceptedFoldCount": resolution.accepted,
            "logicalFoldCount": observedCounts.logical,
            "renderedFoldCount": observedCounts.rendered,
        ],
        "status": "ok",
        "resolutionMs": resolution.milliseconds,
        "peakPhysBytes": peak,
    ]
    if let foldLatencyMS { object["foldLatencyMs"] = foldLatencyMS }
    let configurationIsExact = abs(viewport.width - 1200) < 0.01
        && abs(viewport.height - 760) < 0.01
        && abs(windowSize.width - 1440) < 0.01
        && abs(windowSize.height - 900) < 0.01
        && resolvedFont != nil
        && abs((resolvedFont?.pointSize ?? 0) - 13) < 0.01
        && !wrapLines
        && effective.lineNumbers
        && effective.theme == .siClassic
    if !configurationIsExact {
        object["status"] = "error"
        object["error"] = "effective performance configuration mismatch"
    }
    withExtendedLifetime((reader, window, scrollView)) {}
    write(object, status: configurationIsExact ? 0 : 1)
}

/// Soft-wrap performance mode (§7.4.1/§7.4.2). Unlike the fold runner, this
/// entry must not hard-code `wrapLines = false`: the requested wrap state is
/// a parameter, and the effective configuration (width tracking, scroller
/// visibility) is verified against the request instead of echoing it back.
@MainActor
func runWrapPerformance(_ request: WrapPerformanceRequest) -> Never {
    func write(_ object: [String: Any], status: Int32) -> Never {
        do {
            let data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
            try data.write(to: request.output, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            Darwin.exit(1)
        }
        Darwin.exit(status)
    }

    var fixtureBytes: [UInt8] = []
    do {
        fixtureBytes = Array(try Data(
            contentsOf: request.fixture,
            options: .mappedIfSafe
        ))
    } catch {
        write([
            "schemaVersion": 1,
            "codeSHA": request.codeSHA,
            "scenario": request.scenario,
            "status": "error",
            "error": "fixture read failed: \(error)",
        ], status: 1)
    }

    let peakBytes = OSAllocatedUnfairLock(
        initialState: physicalFootprintBytes() ?? 0
    )
    let samplerQueue = DispatchQueue(label: "com.codeinsight.wrap-perf-sampler")
    let sampler = DispatchSource.makeTimerSource(queue: samplerQueue)
    sampler.schedule(
        deadline: .now(),
        repeating: .milliseconds(25),
        leeway: .milliseconds(2)
    )
    let sampleMemory: @Sendable () -> Void = {
        guard let bytes = physicalFootprintBytes() else { return }
        peakBytes.withLock { $0 = max($0, bytes) }
    }
    sampler.setEventHandler(handler: sampleMemory)
    sampler.resume()

    // Main-thread stall probe: a 5ms heartbeat on a background queue whose
    // main-queue continuations record how late they actually ran. The maximum
    // lateness over the window approximates the longest contiguous stall.
    let stallWindow = OSAllocatedUnfairLock(initialState: (
        generation: UInt64(0), max: 0.0, ignoredPreWindowSamples: 0
    ))
    let stallQueue = DispatchQueue(label: "com.codeinsight.wrap-perf-stall")
    let stallTimer = DispatchSource.makeTimerSource(queue: stallQueue)
    stallTimer.schedule(
        deadline: .now(),
        repeating: .milliseconds(5),
        leeway: .milliseconds(1)
    )
    // Explicit @Sendable typing keeps this handler nonisolated: it runs on the
    // probe queue, only its main-queue continuation touches main state.
    let heartbeat: @Sendable () -> Void = {
        let sample = stallWindow.withLock {
            (generation: $0.generation, scheduled: ContinuousClock.now)
        }
        DispatchQueue.main.async {
            let lateness = milliseconds(since: sample.scheduled)
            stallWindow.withLock {
                guard $0.generation == sample.generation else {
                    $0.ignoredPreWindowSamples += 1
                    return
                }
                $0.max = max($0.max, lateness)
            }
        }
    }
    stallTimer.setEventHandler(handler: heartbeat)
    stallTimer.resume()

    func stopProbes() -> (peak: UInt64, longestStallMs: Double, ignoredPreWindowSamples: Int) {
        sampler.cancel()
        stallTimer.cancel()
        samplerQueue.sync {}
        stallQueue.sync {}
        let stall = stallWindow.withLock { $0 }
        return (peakBytes.withLock { $0 }, stall.max, stall.ignoredPreWindowSamples)
    }

    // Stall samples during fixture load and initial setup would swamp the
    // per-scenario budget; the measurement window starts clean (§7.4.2).
    func resetStallProbe() {
        stallWindow.withLock {
            $0.generation &+= 1
            $0.max = 0
            $0.ignoredPreWindowSamples = 0
        }
    }

    let reader = ReaderTextView()
    var baseSettings = ReaderSettings()
    baseSettings.fontSize = 13
    baseSettings.lineNumbers = true
    baseSettings.theme = .siClassic
    if let name = request.fontPostScriptName {
        guard NSFont(name: name, size: 13) != nil else {
            write(["status": "blocked", "error": "Requested font unavailable: \(name)"], status: 2)
        }
        baseSettings.codeFont = .postScriptName(name)
    }
    baseSettings.codeLigatures = request.ligatureMode

    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 1440, height: 900))
    window.contentView = host
    let scrollView = NSScrollView(
        frame: NSRect(x: 100, y: 60, width: 1220, height: 780)
    )
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true
    // Overlay + autohide scrollers never consume content-view space, so the
    // clip geometry stays exactly 1200x760 across wrap toggles (legacy
    // scrollers appearing and disappearing would drift it by a knob width
    // and break the configuration check).
    scrollView.scrollerStyle = .overlay
    scrollView.autohidesScrollers = true
    scrollView.documentView = reader.view
    host.addSubview(scrollView)
    reader.view.frame = scrollView.contentView.bounds

    func fitViewport() {
        for _ in 0..<4 {
            scrollView.tile()
            let size = scrollView.contentView.bounds.size
            let delta = NSSize(width: 1200 - size.width, height: 760 - size.height)
            guard abs(delta.width) > 0.01 || abs(delta.height) > 0.01 else {
                break
            }
            scrollView.setFrameSize(NSSize(
                width: scrollView.frame.width + delta.width,
                height: scrollView.frame.height + delta.height
            ))
        }
        scrollView.tile()
    }

    func layoutLooksComplete() -> Bool {
        guard let manager = reader.view.textLayoutManager else { return false }
        guard manager.textViewportLayoutController.viewportRange != nil
        else { return false }
        guard let fragment = manager.textLayoutFragment(for: .zero)
        else { return false }
        return !fragment.textLineFragments.isEmpty
    }

    // Offscreen windows never order front, so displayIfNeeded performs no
    // drawing. cacheDisplay runs the real draw callbacks (including the
    // reader's background pass) into a bitmap: that counter is the honest
    // "frame actually rendered" signal (§7.4.2).
    guard let drawBitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 1200 * 2,
        pixelsHigh: 760 * 2,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        write([
            "schemaVersion": 1,
            "codeSHA": request.codeSHA,
            "scenario": request.scenario,
            "status": "error",
            "error": "draw bitmap allocation failed",
        ], status: 1)
    }

    func measureFirstFrame(
        since start: ContinuousClock.Instant,
        timeout: TimeInterval
    ) -> Double? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        let baselineDraws = reader.backgroundDrawCount
        while Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.004))
            reader.view.textLayoutManager?.textViewportLayoutController
                .layoutViewport()
            window.displayIfNeeded()
            // Render the VISIBLE region, exactly what a real first frame
            // paints; rendering the full document bounds would charge
            // off-screen layout to the first-frame metric.
            var drawRect = reader.view.visibleRect.intersection(reader.view.bounds)
            if drawRect.isEmpty { drawRect = reader.view.bounds }
            reader.view.cacheDisplay(in: drawRect, to: drawBitmap)
            if reader.backgroundDrawCount > baselineDraws, layoutLooksComplete() {
                return milliseconds(since: start)
            }
        }
        return nil
    }

    // Settled = geometry stops moving for three consecutive 16ms pumps. This
    // is an observed quiet period, not a fixed sleep, and each geometry
    // adjustment during the window is counted (the pre-S1 stand-in for
    // restorePassCount diagnostics).
    func measureSettled(timeout: TimeInterval) -> (ms: Double, adjustments: Int)? {
        let started = ContinuousClock.now
        let deadline = Date(timeIntervalSinceNow: timeout)
        var lastSignature: (height: CGFloat, originY: CGFloat)?
        var stablePumps = 0
        var adjustments = 0
        while Date() < deadline {
            // 5ms pumps keep the quiet-period floor small while still letting
            // main-queue follow-ups (deferred validation, TextKit height
            // corrections) land and register as signature changes.
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
            reader.view.textLayoutManager?.textViewportLayoutController
                .layoutViewport()
            window.displayIfNeeded()
            let signature = (
                height: reader.view.frame.height,
                originY: reader.view.enclosingScrollView?.contentView.bounds.minY ?? 0
            )
            if let lastSignature,
               lastSignature.height == signature.height,
               lastSignature.originY == signature.originY
            {
                stablePumps += 1
                if stablePumps >= 3 {
                    return (milliseconds(since: started), adjustments)
                }
            } else {
                stablePumps = 0
                if lastSignature != nil { adjustments += 1 }
                lastSignature = signature
            }
        }
        return nil
    }

    if request.scenario == "reading-set" {
        // F5 is a bundle of frozen excerpts, not a source file. Preserve the
        // omission marker literally, as the production excerpt model does.
        let chunks = String(decoding: fixtureBytes, as: UTF8.self)
            .components(separatedBy: "### card ").dropFirst()
        let capturedAt = Date(timeIntervalSince1970: 0)
        let excerpts = chunks.enumerated().compactMap { index, chunk -> ReadingSetExcerpt? in
            guard let newline = chunk.firstIndex(of: "\n") else { return nil }
            let source = String(chunk[chunk.index(after: newline)...])
            let bytes = Array(source.utf8)
            let symbol = "F5 card \(index)"
            let inspector = ReadingSetExcerpt.FrozenInspectorDisplay(
                nodeTitle: symbol, badge: .verified, why: "F5 fixture",
                sourceBody: "Frozen source", verificationTitle: "VERIFICATION",
                verificationBody: "Fixture", correctionBody: "",
                availabilityBody: "Captured", environmentBody: "Performance fixture",
                auditRows: [], accessibilityValue: symbol, capturedAt: capturedAt,
                formerCandidateAvailable: false
            )
            return ReadingSetExcerpt(
                role: "DEFINITION", symbol: symbol, path: "f5.rs", line: 1,
                column: 1, firstLine: 1,
                byteRange: ByteRange(lowerBound: 0, upperBound: UInt32(bytes.count)),
                sourceText: source, contentID: .sha256(of: bytes), revision: nil,
                capturedAt: capturedAt, sourceKind: .worktreeCaptured,
                inspector: inspector, caveat: nil
            )
        }
        guard excerpts.count == 31, excerpts.last?.sourceText.contains("\n…\n") == true else {
            _ = stopProbes()
            write(["status": "error", "error": "F5 requires 30 cards and one omission card"], status: 1)
        }
        scrollView.removeFromSuperview()
        let readingSet = ReadingSetView(frame: NSRect(x: 100, y: 60, width: 1200, height: 760))
        readingSet.translatesAutoresizingMaskIntoConstraints = true
        host.addSubview(readingSet)
        func applyWrap(_ enabled: Bool) {
            var settings = baseSettings
            settings.wrapLines = enabled
            readingSet.apply(settings: settings)
        }
        applyWrap(!request.wrapOn)
        readingSet.display(title: "F5", excerpts: excerpts)
        let codeViews = readingSet.selfTestCodeViews
        func geometryValid(wrap: Bool) -> Bool {
            guard codeViews.count == 31, !readingSet.selfTestLayoutPending else { return false }
            let validText = codeViews.allSatisfy { view in
                guard view.textLayoutManager != nil, let container = view.textContainer else { return false }
                return container.widthTracksTextView == wrap
                    && view.isHorizontallyResizable == !wrap
                    && view.string.utf16.count > 0
            }
            return validText
                && readingSet.selfTestCodeScrollViews.allSatisfy { $0.hasHorizontalScroller == !wrap }
                && readingSet.selfTestLayoutState.allSatisfy {
                    $0.heightConstraints == 1 && $0.contentBottom > 0
                        && $0.contentBottom <= $0.documentHeight + 0.5
                }
        }
        // cacheDisplay invokes the real AppKit drawing callbacks offscreen.
        // Stability includes every card, outer scroll position, and measurement
        // count; elapsed time always starts BEFORE the settings action.
        func settle(since started: ContinuousClock.Instant, wrap: Bool) -> (first: Double, settled: Double)? {
            let deadline = Date(timeIntervalSinceNow: 10)
            let baselineDraws = readingSet.selfTestDrawCount
            var firstFrame: Double?
            var previous: [CGFloat] = []
            var stable = 0
            while Date() < deadline {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
                host.layoutSubtreeIfNeeded()
                readingSet.cacheDisplay(in: readingSet.bounds, to: drawBitmap)
                guard readingSet.selfTestDrawCount > baselineDraws, geometryValid(wrap: wrap) else { stable = 0; continue }
                if firstFrame == nil { firstFrame = milliseconds(since: started) }
                let signature = readingSet.selfTestCardFrames.flatMap {
                    [$0.minY, $0.width, $0.height]
                } + [CGFloat(readingSet.scrollOffset), CGFloat(readingSet.selfTestMeasurementCount)]
                stable = signature == previous ? stable + 1 : 0
                previous = signature
                if stable >= 3, let firstFrame {
                    return (firstFrame, milliseconds(since: started))
                }
            }
            return nil
        }
        var samples: [[String: Any]] = []
        var failure: String?
        var lastAnchorError: CGFloat = 0
        if settle(since: .now, wrap: !request.wrapOn) == nil {
            failure = "initial Reading Set layout timed out"
        }
        // Anchor a middle card, so the test exercises outer restoration rather
        // than trivially preserving zero. Keep a nonempty selection in every card.
        let anchorIndex = 12
        let anchorOffset: CGFloat = 8
        if failure == nil {
            readingSet.restoreScrollOffset(Double(readingSet.selfTestCardFrames[anchorIndex].minY + anchorOffset))
            for view in codeViews { view.setSelectedRange(NSRange(location: 3, length: 8)) }
            _ = settle(since: .now, wrap: !request.wrapOn)
            resetStallProbe()
            for cycle in 0..<(request.warmupCount + request.sampleCount) {
                let countBefore = readingSet.selfTestMeasurementCount
                let started = ContinuousClock.now
                applyWrap(request.wrapOn)
                guard let timing = settle(since: started, wrap: request.wrapOn) else {
                    failure = "Reading Set toggle layout or drawing timed out"; break
                }
                let frames = readingSet.selfTestCardFrames
                lastAnchorError = abs(CGFloat(readingSet.scrollOffset) - frames[anchorIndex].minY - anchorOffset)
                let selectionOK = codeViews.allSatisfy { $0.selectedRange() == NSRange(location: 3, length: 8) }
                let measureCount = readingSet.selfTestMeasurementCount - countBefore
                let heightOK = zip(frames, frames.dropFirst()).allSatisfy { $1.minY >= $0.maxY }
                samples.append([
                    "cycle": cycle, "warmup": cycle < request.warmupCount,
                    "toggleFirstFrameMs": timing.first, "toggleSettledMs": timing.settled,
                    "cardMeasureCount": measureCount, "anchorErrorPt": lastAnchorError,
                    "selectionPreserved": selectionOK, "cardHeightsValid": heightOK,
                    "effectiveWrap": codeViews.allSatisfy { $0.textContainer?.widthTracksTextView == true },
                    "textContainerWidthsPt": codeViews.map { $0.textContainer?.size.width ?? 0 },
                ])
                if !selectionOK || !heightOK || lastAnchorError > 1 || measureCount != 31 {
                    failure = "selection, anchor, card height or single-measure invariant failed"; break
                }
                applyWrap(!request.wrapOn)
                guard settle(since: .now, wrap: !request.wrapOn) != nil else {
                    failure = "Reading Set return toggle timed out"; break
                }
            }
        }
        let probes = stopProbes()
        let measured = samples.filter { !($0["warmup"] as? Bool ?? true) }
        func summary(_ key: String) -> [String: Double] {
            let values = measured.compactMap { $0[key] as? Double }.sorted()
            guard !values.isEmpty else { return [:] }
            return ["p50": values[Int(ceil(Double(values.count) * 0.5)) - 1],
                    "p95": values[Int(ceil(Double(values.count) * 0.95)) - 1], "max": values.last!]
        }
        let font = codeViews.first?.font
        var object: [String: Any] = [
            "schemaVersion": 2, "codeSHA": request.codeSHA,
            "fixtureSHA256": ContentID.sha256(of: fixtureBytes).bytes.map { String(format: "%02x", $0) }.joined(),
            "scenario": request.scenario, "requestedWrap": request.wrapOn,
            "status": failure == nil ? "ok" : "error", "samplePeriodMs": 25,
            "warmupCount": request.warmupCount, "sampleCount": measured.count,
            "peakPhysBytes": probes.peak, "samples": samples,
            "summary": ["toggleFirstFrameMs": summary("toggleFirstFrameMs"), "toggleSettledMs": summary("toggleSettledMs")],
            "perfConfig": ["cardCount": readingSet.selfTestCardCount,
                           "ligatureMode": request.ligatureMode.rawValue,
                           "measuredWrapLines": samples.last?["effectiveWrap"] ?? NSNull(),
                           "cardScrollerStyles": readingSet.selfTestCodeScrollViews.map { $0.scrollerStyle == .legacy ? "legacy" : "overlay" },
                           "textContainerWidthsPt": samples.last?["textContainerWidthsPt"] ?? [],
                           "lineHeightMultiple": baseSettings.lineHeightMultiple,
                           "resolvedFontName": font?.fontName ?? "", "resolvedFontSizePt": font?.pointSize ?? 0,
                           "windowPt": [host.bounds.width, host.bounds.height],
                           "viewportPt": [readingSet.bounds.width, readingSet.bounds.height],
                           "backingScale": window.backingScaleFactor, "lineNumbers": true,
                           "theme": "SI Classic", "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
                           "machineModel": sysctlString("hw.model") ?? ""],
            "observed": ["cardMeasureCount": readingSet.selfTestMeasurementCount,
                         "drawPassCount": readingSet.selfTestDrawCount,
                         "anchorErrorPt": lastAnchorError, "longestMainThreadStallMs": probes.longestStallMs,
                         "ignoredPreWindowSamples": probes.ignoredPreWindowSamples],
        ]
        if let failure { object["error"] = failure }
        write(object, status: failure == nil ? 0 : 1)
    }

    let loader = DocumentLoader(
        source: { file in Array(try Data(contentsOf: file, options: .mappedIfSafe)) }
    )
    let initialDocument: ReaderDocument
    do {
        initialDocument = try loader.load(file: request.fixture).document
    } catch {
        let probes = stopProbes()
        write([
            "schemaVersion": 1,
            "codeSHA": request.codeSHA,
            "scenario": request.scenario,
            "status": "error",
            "error": "fixture load failed: \(error)",
            "peakPhysBytes": probes.peak,
        ], status: 1)
    }
    let syntaxResult = OSAllocatedUnfairLock(
        initialState: Optional<Result<ReaderDocument, ReaderSyntaxError>>.none
    )
    loader.loadSyntax(for: initialDocument) { result in
        syntaxResult.withLock { $0 = result }
    }
    guard waitUntil(timeout: 30, condition: {
        syntaxResult.withLock { $0 != nil }
    }), let result = syntaxResult.withLock({ $0 })
    else {
        let probes = stopProbes()
        write([
            "schemaVersion": 1,
            "codeSHA": request.codeSHA,
            "scenario": request.scenario,
            "status": "timeout",
            "error": "syntax load timed out",
            "samplePeriodMs": 25,
            "peakPhysBytes": probes.peak,
        ], status: 1)
    }
    let document: ReaderDocument
    switch result {
    case .success(let loaded):
        document = loaded
    case .failure(let error):
        let probes = stopProbes()
        write([
            "schemaVersion": 1,
            "codeSHA": request.codeSHA,
            "scenario": request.scenario,
            "status": "error",
            "error": "syntax load failed: \(error)",
            "peakPhysBytes": probes.peak,
        ], status: 1)
    }

    func settingsFor(wrap: Bool) -> ReaderSettings {
        var settings = baseSettings
        settings.wrapLines = wrap
        return settings
    }

    var samples: [[String: Any]] = []
    var timedOut = false
    // Wrap-state bits captured while the requested configuration was actually
    // installed: the toggle scenario leaves the opposite state behind for the
    // next cycle, so reading end state would misreport the measured run.
    var measuredWrapState: (
        widthTracking: Bool,
        horizontalScroller: Bool,
        horizontallyResizable: Bool,
        viewportSize: NSSize
    )?
    func captureWrapState() {
        // The machine's legacy scroll-bar preference can be re-delivered
        // mid-run (long fixtures), resetting scrollers styled before it;
        // re-pin per cycle so the measured geometry stays overlay-stable.
        scrollView.scrollerStyle = .overlay
        measuredWrapState = (
            widthTracking: reader.view.textContainer?.widthTracksTextView == true,
            horizontalScroller: scrollView.hasHorizontalScroller,
            horizontallyResizable: reader.view.isHorizontallyResizable,
            viewportSize: scrollView.contentView.bounds.size
        )
    }
    let measurementStart = {
        // The machine's real scroll-bar preference (often legacy "Always")
        // is only delivered once the runloop runs during fixture/syntax
        // loading, and that notification resets scrollers that were styled
        // before it arrived. Re-pin the overlay style here so the clip
        // geometry is stable across the whole measurement window.
        scrollView.scrollerStyle = .overlay
        window.displayIfNeeded()
        fitViewport()
        // Stall samples during fixture load and initial setup would swamp
        // the per-scenario budget; the window starts clean (§7.4.2).
        resetStallProbe()
    }

    switch request.scenario {
    case "initial":
        reader.apply(settings: settingsFor(wrap: request.wrapOn))
        _ = measurementStart()
        for cycle in 0..<(request.warmupCount + request.sampleCount) {
            // The timed action is the full re-display: projection build,
            // storage install, layout, and first render.
            let started = ContinuousClock.now
            reader.display(document: document, fileURL: request.fixture)
            guard let firstFrame = measureFirstFrame(
                since: started,
                timeout: 10
            ), let settled = measureSettled(timeout: 10)
            else {
                timedOut = true
                break
            }
            captureWrapState()
            samples.append([
                "cycle": cycle,
                "warmup": cycle < request.warmupCount,
                "firstFrameMs": firstFrame,
                "settledMs": settled.ms,
                "settleAdjustments": settled.adjustments,
            ])
        }
    case "toggle":
        reader.apply(settings: settingsFor(wrap: !request.wrapOn))
        reader.display(document: document, fileURL: request.fixture)
        _ = measurementStart()
        guard measureFirstFrame(
            since: ContinuousClock.now,
            timeout: 10
        ) != nil, measureSettled(timeout: 10) != nil
        else {
            timedOut = true
            break
        }
        for cycle in 0..<(request.warmupCount + request.sampleCount) {
            // Timed half: the settings apply that flips to the requested
            // wrap state, through the first rendered frame.
            let started = ContinuousClock.now
            reader.apply(settings: settingsFor(wrap: request.wrapOn))
            guard let firstFrame = measureFirstFrame(
                since: started,
                timeout: 10
            ), let settled = measureSettled(timeout: 10)
            else {
                timedOut = true
                break
            }
            captureWrapState()
            samples.append([
                "cycle": cycle,
                "warmup": cycle < request.warmupCount,
                "toggleFirstFrameMs": firstFrame,
                "toggleSettledMs": milliseconds(since: started),
                "settleQuietPeriodMs": settled.ms,
                "settleAdjustments": settled.adjustments,
            ])
            // Untimed half: return to the opposite state for the next cycle.
            reader.apply(settings: settingsFor(wrap: !request.wrapOn))
            if measureFirstFrame(since: ContinuousClock.now, timeout: 10) == nil
                || measureSettled(timeout: 10) == nil
            {
                timedOut = true
                break
            }
        }
    case "resize":
        reader.apply(settings: settingsFor(wrap: request.wrapOn))
        reader.display(document: document, fileURL: request.fixture)
        _ = measurementStart()
        guard measureFirstFrame(
            since: ContinuousClock.now,
            timeout: 10
        ) != nil, measureSettled(timeout: 10) != nil
        else {
            timedOut = true
            break
        }
        let baseWidth = scrollView.frame.width
        for cycle in 0..<(request.warmupCount + request.sampleCount) {
            var steps: [[String: Any]] = []
            for targetWidth in [baseWidth - 340, baseWidth] {
                let started = ContinuousClock.now
                scrollView.setFrameSize(NSSize(
                    width: targetWidth,
                    height: scrollView.frame.height
                ))
                scrollView.tile()
                guard let firstFrame = measureFirstFrame(
                    since: started,
                    timeout: 10
                ), let settled = measureSettled(timeout: 10)
                else {
                    timedOut = true
                    break
                }
                steps.append([
                    "widthPt": targetWidth,
                    "stepMs": milliseconds(since: started),
                    "firstFrameMs": firstFrame,
                    "settledMs": settled.ms,
                    "settleAdjustments": settled.adjustments,
                ])
            }
            samples.append([
                "cycle": cycle,
                "warmup": cycle < request.warmupCount,
                "steps": steps,
                "rawResizeRequests": steps.count,
            ])
            captureWrapState()
            if timedOut { break }
        }
    default:
        let probes = stopProbes()
        write([
            "schemaVersion": 1,
            "codeSHA": request.codeSHA,
            "scenario": request.scenario,
            "status": "error",
            "error": "unexpected scenario \(request.scenario)",
            "peakPhysBytes": probes.peak,
        ], status: 1)
    }

    let probes = stopProbes()
    if timedOut {
        write([
            "schemaVersion": 1,
            "codeSHA": request.codeSHA,
            "fixtureSHA256": document.contentID.bytes
                .map { String(format: "%02x", $0) }.joined(),
            "scenario": request.scenario,
            "requestedWrap": request.wrapOn,
            "status": "timeout",
            "error": "layout or draw did not settle within the 10s budget",
            "samplePeriodMs": 25,
            "peakPhysBytes": probes.peak,
        ], status: 1)
    }

    func summarize(_ values: [Double]) -> [String: Double] {
        let sorted = values.sorted()
        func percentile(_ p: Double) -> Double {
            let rank = Int(ceil(p / 100 * Double(sorted.count))) - 1
            return sorted[min(max(rank, 0), sorted.count - 1)]
        }
        return [
            "p50": percentile(50),
            "p95": percentile(95),
            "max": sorted.last ?? 0,
        ]
    }

    let measured = samples.filter { !($0["warmup"] as? Bool ?? true) }
    var summary: [String: Any] = [:]
    switch request.scenario {
    case "initial":
        let firstFrame = measured.compactMap {
            $0["firstFrameMs"] as? Double
        }
        let settled = measured.compactMap { $0["settledMs"] as? Double }
        if !firstFrame.isEmpty { summary["firstFrameMs"] = summarize(firstFrame) }
        if !settled.isEmpty { summary["settledMs"] = summarize(settled) }
    case "toggle":
        let firstFrame = measured.compactMap {
            $0["toggleFirstFrameMs"] as? Double
        }
        let settled = measured.compactMap { $0["toggleSettledMs"] as? Double }
        if !firstFrame.isEmpty {
            summary["toggleFirstFrameMs"] = summarize(firstFrame)
        }
        if !settled.isEmpty { summary["toggleSettledMs"] = summarize(settled) }
    case "resize":
        let stepMs = measured.flatMap { sample in
            (sample["steps"] as? [[String: Any]])?.compactMap {
                $0["stepMs"] as? Double
            } ?? []
        }
        if !stepMs.isEmpty { summary["resizeStepMs"] = summarize(stepMs) }
    default:
        break
    }

    let storage = reader.view.textStorage
    let resolvedFont: NSFont? = storage.flatMap { storage in
        guard storage.length > 0 else { return nil }
        return storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    }
    let viewport = scrollView.contentView.bounds.size
    let windowSize = window.contentView?.bounds.size ?? .zero
    let wrapState = measuredWrapState ?? (
        widthTracking: reader.view.textContainer?.widthTracksTextView == true,
        horizontalScroller: scrollView.hasHorizontalScroller,
        horizontallyResizable: reader.view.isHorizontallyResizable,
        viewportSize: scrollView.contentView.bounds.size
    )
    let lineHeight = reader.view.textLayoutManager?
        .textLayoutFragment(for: .zero)?.layoutFragmentFrame.height ?? 0
    let lineStarts = document.lineTable.lineStarts
    var maxLineUTF8Bytes = 0
    for index in lineStarts.indices.dropLast() {
        let length = Int(lineStarts[index + 1] - lineStarts[index])
        maxLineUTF8Bytes = max(maxLineUTF8Bytes, length)
    }

    var object: [String: Any] = [
        "schemaVersion": 2,
        "codeSHA": request.codeSHA,
        "fixtureSHA256": document.contentID.bytes
            .map { String(format: "%02x", $0) }.joined(),
        "scenario": request.scenario,
        "requestedWrap": request.wrapOn,
        "samplePeriodMs": 25,
        "warmupCount": request.warmupCount,
        "sampleCount": measured.count,
        "perfConfig": [
            "wrapLines": wrapState.widthTracking,
            "widthTracksTextView": wrapState.widthTracking,
            "horizontalScroller": wrapState.horizontalScroller,
            "ligatureMode": request.ligatureMode.rawValue,
            "requestedFont": request.fontPostScriptName ?? "systemMonospaced",
            "resolvedFontName": resolvedFont?.fontName ?? "",
            "resolvedFontSizePt": resolvedFont?.pointSize ?? 0,
            "windowPt": [windowSize.width, windowSize.height],
            "viewportPt": [wrapState.viewportSize.width, wrapState.viewportSize.height],
            "lineNumbers": reader.foldPerformanceEffectiveSettings.lineNumbers,
            "theme": "SI Classic",
            "gutterThicknessPt": reader.rulerThickness,
            "renderedFoldCount": reader.foldPerformanceCounts.rendered,
            "scrollerStyle": NSScroller.preferredScrollerStyle == .legacy
                ? "legacy" : "overlay",
            "scrollViewScrollerStyle": scrollView.scrollerStyle == .legacy
                ? "legacy" : "overlay",
            "scrollViewAutohidesScrollers": scrollView.autohidesScrollers,
            "backingScale": window.backingScaleFactor,
            "lineHeightPt": lineHeight,
            "logicalLineCount": lineStarts.count,
            "maxLineUTF8Bytes": maxLineUTF8Bytes,
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "machineModel": sysctlString("hw.model") ?? "",
        ],
        "observed": [
            "reflowCount": reader.projectionInstallCount,
            "drawPassCount": reader.backgroundDrawCount,
            "paragraphUpdateCount": reader.paragraphUpdateCount,
            "restorePassCount": reader.viewportRestorePassCount,
            "viewportRestoreLimited": reader.lastViewportRestoreWasLimited,
            "anchorErrorPt": reader.lastViewportAnchorErrorPt ?? NSNull(),
            "mergedResizeRequests": reader.mergedWidthReflowCount,
            "rawResizeRequests": samples.reduce(0) {
                $0 + ($1["rawResizeRequests"] as? Int ?? 0)
            } + reader.widthReflowNotificationCount,
            "longestMainThreadStallMs": probes.longestStallMs,
            "ignoredPreWindowSamples": probes.ignoredPreWindowSamples,
        ],
        "samples": samples,
        "summary": summary,
        "status": "ok",
        "peakPhysBytes": probes.peak,
    ]

    // Independent configuration validation for wrap scenarios (§7.4.1): the
    // observed layout must match the request, not echo it.
    let configurationIsExact = wrapState.widthTracking == request.wrapOn
        && wrapState.horizontalScroller == !request.wrapOn
        && wrapState.horizontallyResizable == !request.wrapOn
        && abs(wrapState.viewportSize.width - 1200) < 0.01
        && abs(wrapState.viewportSize.height - 760) < 0.01
        && abs(windowSize.width - 1440) < 0.01
        && abs(windowSize.height - 900) < 0.01
        && resolvedFont != nil
        && abs((resolvedFont?.pointSize ?? 0) - 13) < 0.01
        && reader.foldPerformanceEffectiveSettings.lineNumbers
        && reader.foldPerformanceEffectiveSettings.theme == .siClassic
    if !configurationIsExact {
        object["status"] = "error"
        object["error"] = "effective wrap configuration does not match request"
    }
    withExtendedLifetime((reader, window, scrollView, drawBitmap)) {}
    write(object, status: configurationIsExact ? 0 : 1)
}

private func sysctlString(_ name: String) -> String? {
    var length = 0
    guard sysctlbyname(name, nil, &length, nil, 0) == 0, length > 0
    else { return nil }
    var buffer = [CChar](repeating: 0, count: length)
    guard sysctlbyname(name, &buffer, &length, nil, 0) == 0
    else { return nil }
    return String(cString: buffer)
}
