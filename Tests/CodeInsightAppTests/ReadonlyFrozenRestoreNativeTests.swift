import AppKit
import CodeInsightAppModel
import CodeInsightCore
import CodeInsightExact
import CodeInsightReaderCore
import Foundation
import Testing
@testable import CodeInsightApp

@MainActor
@Test(.timeLimit(.minutes(2)))
func readonlyFrozenReadingSetRestoresAndDrawsCapturedSourceAfterWindowClose() async throws {
    _ = NSApplication.shared
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("readonly-frozen-restore-\(UUID().uuidString)")
    let project = temporary.appendingPathComponent("project")
    let session = temporary.appendingPathComponent("state/session.json")
    let suite = "dev.cairn.readonly-frozen-restore.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let recents = RecentProjectsStore(defaults: defaults)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: temporary)
    }
    let source = "pub fn captured() -> bool {\n    let 中文 = 1 != 2;\n    中文\n}\n"
    let file = project.appendingPathComponent("main.rs")
    try source.write(to: file, atomically: true, encoding: .utf8)
    let sourceBytes = Array(source.utf8)
    let contentID = ContentID.sha256(of: sourceBytes)
    let inspector = ReadingSetExcerpt.FrozenInspectorDisplay(
        nodeTitle: "captured", badge: .verified, why: "captured native restore fixture", sourceBody: "main.rs",
        verificationTitle: "captured", verificationBody: "captured before source drift", correctionBody: "",
        availabilityBody: "", environmentBody: "isolated native test", auditRows: [], accessibilityValue: "captured",
        capturedAt: Date(timeIntervalSince1970: 0), formerCandidateAvailable: false)
    let excerpt = ReadingSetExcerpt(role: "DEFINITION", symbol: "captured", path: "main.rs",
        line: 1, column: 1, firstLine: 1, byteRange: .init(lowerBound: 0, upperBound: UInt32(sourceBytes.count)),
        sourceText: source, contentID: contentID, revision: nil, capturedAt: Date(timeIntervalSince1970: 0),
        sourceKind: .worktreeCaptured, inspector: inspector, caveat: nil)
    func model() -> AppModel {
        AppModel(sessionURL: session, recentProjectsStore: recents,
            exactCoordinator: ExactCoordinator(providerFactory: { _ in throw CocoaError(.featureUnsupported) },
                                               sandboxAvailable: { false }))
    }
    let originalModel = model()
    let original = MainWindowController(model: originalModel, settings: ReaderSettings(), offscreen: true,
        recentProjectsStore: recents, layoutDefaults: defaults)
    defer { original.close() }
    original.openProject(root: project, language: .rust)
    try #require(await readonlyHostWait { originalModel.snapshotPhase == .fullReady })
    originalModel.tabStrip.openReadingSet(title: "Frozen native restore", excerpts: [excerpt])
    original.renderForSelfTest()
    let originalRoot = try #require(original.window?.contentViewController)
    try #require(await readonlyHostWait {
        original.window?.contentView?.layoutSubtreeIfNeeded()
        return readonlyHostReaders(originalRoot).contains { readonlyHostHasLayout($0, source: source) }
    })
    let originalHost = try #require(readonlyHostReaders(originalRoot).first { $0.selfTestReadingSetTextViews.first?.string == source })
    try readonlyAssertFrozenDraw(originalHost, source: source, name: "frozen-before-close", contentID: contentID)
    try originalModel.writeSessionCheckpoint(panelPreset: .reading)
    original.close()
    try "pub fn changed_after_capture() {}\n".write(to: file, atomically: true, encoding: .utf8)

    // A genuinely new model/controller loads only the isolated session. It must
    // render the persisted captured bytes, not re-read the changed worktree.
    let restoredModel = model()
    let restored = MainWindowController(model: restoredModel, settings: ReaderSettings(), offscreen: true,
        recentProjectsStore: recents, layoutDefaults: defaults)
    defer { restored.close() }
    restored.openProject(root: project, language: .rust)
    try #require(await readonlyHostWait {
        guard restoredModel.snapshotPhase == .fullReady, !restoredModel.isRestoringSession,
              case .readingSet = restoredModel.tabStrip.activeTab?.content else { return false }
        return true
    })
    guard case .readingSet(let title, let excerpts) = restoredModel.tabStrip.activeTab?.content else {
        Issue.record("Restored active tab was not the persisted Reading Set")
        return
    }
    #expect(title == "Frozen native restore")
    #expect(excerpts.count == 1)
    #expect(excerpts.first?.sourceText == source)
    #expect(excerpts.first?.contentID == contentID)
    #expect(excerpts.first?.byteRange == excerpt.byteRange)
    #expect(original.window !== restored.window)
    restored.renderForSelfTest()
    let restoredRoot = try #require(restored.window?.contentViewController)
    try #require(await readonlyHostWait {
        restored.window?.contentView?.layoutSubtreeIfNeeded()
        return readonlyHostReaders(restoredRoot).contains { readonlyHostHasLayout($0, source: source) }
    })
    let restoredHost = try #require(readonlyHostReaders(restoredRoot).first { $0.selfTestReadingSetTextViews.first?.string == source })
    try readonlyAssertFrozenDraw(restoredHost, source: source, name: "frozen-after-restore", contentID: contentID)
}

@MainActor
private func readonlyHostReaders(_ controller: NSViewController) -> [ReaderViewController] {
    (controller as? ReaderViewController).map { [$0] } ?? controller.children.flatMap(readonlyHostReaders)
}

@MainActor
private func readonlyHostHasLayout(_ host: ReaderViewController, source: String) -> Bool {
    guard let text = host.selfTestReadingSetTextViews.first, text.string == source,
          let surface = host.selfTestReadingSetSurface as? ReadingSetView else { return false }
    return !surface.selfTestLayoutPending && surface.selfTestMeasurementCount > 0
        && !text.visibleRect.intersection(text.bounds).isEmpty
}

@MainActor
private func readonlyHostWait(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(30)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@MainActor
private func readonlyAssertFrozenDraw(_ host: ReaderViewController, source: String, name: String, contentID: ContentID) throws {
    let text = try #require(host.selfTestReadingSetTextViews.first)
    #expect(text.string == source)
    #expect(!text.isEditable)
    #expect(text.textLayoutManager != nil)
    let selection = (source as NSString).range(of: "中文")
    text.setSelectedRange(selection)
    let board = NSPasteboard(name: .init("readonly-frozen-copy-\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    try #require(text.writeSelection(to: board, types: text.writablePasteboardTypes))
    #expect(board.string(forType: .string) == "中文")
    let surface = host.selfTestReadingSetSurface
    surface.layoutSubtreeIfNeeded()
    let visible = surface.visibleRect.intersection(surface.bounds)
    try #require(!visible.isEmpty)
    let before = host.selfTestReadingSetDrawCount
    let bitmap = try #require(surface.bitmapImageRepForCachingDisplay(in: visible))
    surface.cacheDisplay(in: visible, to: bitmap)
    #expect(host.selfTestReadingSetDrawCount > before)
    try #require(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
    try readonlyCaptureSurfaceEvidence(name, textView: text, expectedSource: source,
        provenance: ["sourceScope": "restored-frozen-excerpt", "path": "main.rs",
            "capturedContentID": contentID.bytes.map { String(format: "%02x", $0) }.joined()],
        drawView: surface, drawCount: { host.selfTestReadingSetDrawCount })
}
