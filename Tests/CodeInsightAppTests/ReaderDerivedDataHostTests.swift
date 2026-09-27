import AppKit
import CodeInsightAppModel
import CodeInsightCore
import CodeInsightEngine
import CodeInsightReaderCore
import Foundation
import Testing
@testable import CodeInsightApp

@MainActor
@Test(.timeLimit(.minutes(1)))
func readonlyReaderHostsSharePreparationAndCancelIndependently() async throws {
    _ = NSApplication.shared
    let store = ReaderDerivedDataStore(builder: { document in
        try await Task.sleep(for: .milliseconds(100))
        return try IdentifierIndex(document: document)
    })
    let primary = ReaderViewController(derivedDataStore: store)
    let secondary = ReaderViewController(showsCompareControls: true, derivedDataStore: store)
    let source = Array("fn sample(value: i32) -> i32 { value + value }\n".utf8)
    let file = URL(fileURLWithPath: "/readonly-host.rs")
    primary.display(file, source: { _ in source })
    secondary.display(file, source: { _ in source })
    #expect(primary.identifierPreparationNotice != nil)
    #expect(secondary.identifierPreparationNotice != nil)
    for _ in 0..<500 {
        if await store.statistics.subscriptionCount == 2 { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(await store.statistics.subscriptionCount == 2)
    primary.cancelDerivedDataSubscription()
    for _ in 0..<500 {
        if secondary.identifierPreparationNotice == nil { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(secondary.identifierPreparationNotice == nil)
    #expect(await store.statistics.buildCount == 1)
    #expect(await store.statistics.subscriptionCount == 1)
    secondary.cancelDerivedDataSubscription()
    for _ in 0..<500 {
        if await store.statistics.subscriptionCount == 0 { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(await store.statistics.subscriptionCount == 0)
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func readonlySettingsPreviewStaysUnsubscribedAfterCloseAndResumesOnReopen() async throws {
    _ = NSApplication.shared
    let store = ReaderDerivedDataStore()
    let controller = ReaderSettingsWindowController(
        settings: ReaderSettings(),
        derivedDataStore: store,
        trustModel: TrustListModel(),
        onRevoke: { _ in },
        onClearCache: { .cleared },
        onChange: { _ in }
    )
    let window = try #require(controller.window)
    window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
    defer { controller.close() }
    controller.showWindow(nil)
    for _ in 0..<500 {
        controller.selfTestLayoutReaderPreviews()
        if await store.statistics.subscriptionCount == 1 { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(await store.statistics.subscriptionCount == 1)
    controller.close()
    for _ in 0..<100 {
        // AppKit can relayout a retained closed window; it must not restart work.
        controller.selfTestLayoutReaderPreviews()
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(await store.statistics.subscriptionCount == 0)

    // Queue a display, then close before the main queue executes that display.
    controller.showWindow(nil)
    controller.selfTestLayoutReaderPreviews()
    controller.close()
    for _ in 0..<100 {
        controller.selfTestLayoutReaderPreviews()
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(await store.statistics.subscriptionCount == 0)

    controller.showWindow(nil)
    for _ in 0..<500 {
        controller.selfTestLayoutReaderPreviews()
        if await store.statistics.subscriptionCount == 1 { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(await store.statistics.subscriptionCount == 1)
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func readonlyReaderHostDiscardsSyntaxArrivalAfterTeardown() async throws {
    _ = NSApplication.shared
    let store = ReaderDerivedDataStore()
    let controller = ReaderViewController(derivedDataStore: store)
    let bytes = Array((String(repeating: "// deferred syntax\n", count: 10_001)
        + "fn sample(value: i32) -> i32 { value }\n").utf8)
    controller.display(URL(fileURLWithPath: "/readonly-delayed.rs"), source: { _ in bytes })
    #expect(controller.selfTestSyntaxLoadPending)
    controller.cancelDerivedDataSubscription()
    for _ in 0..<500 { try await Task.sleep(for: .milliseconds(2)) }
    #expect(await store.statistics.subscriptionCount == 0)
    #expect(controller.displayedBytes == bytes)
    #expect(controller.identifierPreparationNotice == nil)
    #expect(await store.statistics.buildCount == 0)
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func readonlyContextIgnoresQueuedModelObservationAfterTeardown() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("readonly-context-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = "pub fn target() -> i32 { 42 }\npub fn main() { target(); }\n"
    try source.write(to: root.appendingPathComponent("main.rs"), atomically: true, encoding: .utf8)
    let session = try ProjectIndexer().index(root: root)
    let query = QueryContext(snapshotID: session.snapshotID, analysisProfileID: session.analysisProfile.id, generation: 1)
    let model = ContextWindowModel()
    model.updateProjectState(.ready(session, query), root: root)
    let store = ReaderDerivedDataStore()
    let controller = ContextWindowViewController(model: model, derivedDataStore: store)
    controller.loadViewIfNeeded()
    let offset = try #require(source.range(of: "target();"))
    let candidate = await model.explicitJump(file: "main.rs", offset: UInt32(source[..<offset.lowerBound].utf8.count))
    #expect(candidate != nil)
    for _ in 0..<500 {
        if await store.statistics.subscriptionCount == 1 { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(await store.statistics.subscriptionCount == 1)
    model.setMode(.pinned)
    controller.cancelDerivedDataSubscription()
    for _ in 0..<100 { try await Task.sleep(for: .milliseconds(2)) }
    #expect(await store.statistics.subscriptionCount == 0)
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func readonlyMainWindowShowsPreparationWithoutReplacingFocusNotice() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("readonly-status-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("main.rs")
    try "// repeated identifier, no enclosing declaration\n".write(to: file, atomically: true, encoding: .utf8)
    let (release, continuation) = AsyncStream<Void>.makeStream()
    defer { continuation.finish() }
    let store = ReaderDerivedDataStore(builder: { document in
        for await _ in release { break }
        try Task.checkCancellation()
        return try IdentifierIndex(document: document)
    })
    let model = AppModel(indexService: ProjectIndexService())
    let controller = MainWindowController(model: model, settings: ReaderSettings(), offscreen: true,
                                          derivedDataStore: store)
    let window = try #require(controller.window)
    defer { controller.close() }
    window.setFrameOrigin(NSPoint(x: 120, y: 120))
    controller.showWindow(nil)
    controller.openProject(root: root)
    try #require(await readonlyStatusWaitUntil { model.snapshotPhase == .fullReady })
    controller.openFileForSelfTest(file)
    controller.renderForSelfTest()
    let content = try #require(window.contentView)
    func labels(in view: NSView) -> [NSTextField] {
        ((view as? NSTextField).map { [$0] } ?? [])
            + view.subviews.flatMap { labels(in: $0) }
    }
    let building = localized("reader.identifiers.preparing")
    try #require(await readonlyStatusWaitUntil {
        labels(in: content).contains { $0.stringValue == building && !$0.isHiddenOrHasHiddenAncestor }
    })
    content.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    let label = try #require(labels(in: content).first { $0.stringValue == building && !$0.isHiddenOrHasHiddenAncestor })
    #expect(window.isVisible)
    #expect(label.window === window)
    #expect(label.bounds.width > 0 && label.bounds.height > 0)
    #expect(controller.selfTestStatusBarVisible)
    let labelFrame = label.convert(label.bounds, to: content)
    #expect(controller.selfTestStatusBarFrameInContentView.intersects(labelFrame))
    #expect(content.bounds.contains(labelFrame))

    // This genuine Focus failure uses its existing status channel while preparation is blocked.
    #expect(!controller.toggleFocusCurrentScope())
    let focusNotice = localized("main.no.enclosing.scope.to.focus")
    #expect(controller.selfTestIndexStatusText.contains(focusNotice))
    #expect(!label.isHiddenOrHasHiddenAncestor)
    content.layoutSubtreeIfNeeded()
    let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
    content.cacheDisplay(in: content.bounds, to: bitmap)
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    let evidence = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/readonly/s1-status", isDirectory: true)
    try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
    try png.write(to: evidence.appendingPathComponent("identifier-building-with-focus-notice.png"), options: .atomic)

    continuation.finish()
    try #require(await readonlyStatusWaitUntil { label.isHidden && label.stringValue.isEmpty })
    // Focus notices are intentionally transient across normal model renders.
    // A new Focus action still uses its own visible channel after preparation ends.
    #expect(!controller.toggleFocusCurrentScope())
    #expect(controller.selfTestIndexStatusText.contains(focusNotice))
    #expect(controller.selfTestIndexStatusVisible)
    #expect(await store.statistics.buildCount == 1)
}

@MainActor
private func readonlyStatusWaitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !condition(), ContinuousClock.now < deadline {
        // Advance actual main-queue work; the builder is released by the explicit gate, never a sleep.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
    return condition()
}
