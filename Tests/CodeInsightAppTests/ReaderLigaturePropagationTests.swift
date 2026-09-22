import AppKit
import CodeInsightExact
import CodeInsightReaderCore
import CodeInsightReaderUI
import Testing
@testable import CodeInsightApp
@testable import CodeInsightAppModel

@MainActor
@Test(.timeLimit(.minutes(2)))
func readerFontsPropagateToComparisonContextAndNewWindowsWithoutChangingPlainText() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LigaturePropagation-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = "pub fn target() -> bool { 1 != 2 }\npub fn main() { target(); }\n"
    let plain = "Plain text != -> => must keep its own font.\n"
    try source.write(to: root.appendingPathComponent("main.rs"), atomically: true, encoding: .utf8)
    try plain.write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
    for arguments in [["init", "-q"], ["add", "main.rs", "notes.txt"],
                      ["-c", "user.name=Ligature Test", "-c", "user.email=ligature@example.invalid", "commit", "-qm", "fixture"]] {
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", root.path] + arguments
        try git.run()
        git.waitUntilExit()
        try #require(git.terminationStatus == 0)
    }
    let model = AppModel(sessionURL: root.appendingPathComponent("state/first.json"))
    let first = MainWindowController(model: model, settings: ReaderSettings(), offscreen: true)
    defer { first.close() }
    first.openProject(root: root)
    try #require(await waitForLigatureSurface { model.snapshotPhase == .fullReady })
    first.showWindow(nil)
    first.openFileForSelfTest(root.appendingPathComponent("main.rs"))
    try #require(await waitForLigatureSurface { first.selfTestLeftReaderBytes == Array(source.utf8) })
    model.selectCompareCommit("HEAD")
    first.applyPanelPreset(.compare)
    try #require(await waitForLigatureSurface { first.selfTestRightReaderBytes == Array(source.utf8) })
    model.contextWindow.tokenClicked(file: "main.rs", offset: UInt32("pub fn ".utf8.count))
    try #require(await waitForLigatureSurface { model.contextWindow.selectedCandidate != nil })
    model.contextWindow.setMode(.pinned)
    first.renderForSelfTest()
    let rootController = try #require(first.window?.contentViewController)
    let readers = ligatureControllers(rootController).compactMap { $0 as? ReaderViewController }
    let context = try #require(ligatureControllers(rootController).compactMap { $0 as? ContextWindowViewController }.first)
    #expect(readers.count == 2)
    try #require(await waitForLigatureSurface { ligatureTextViews(context.view).contains { $0.string.contains("pub fn target") } })
    let codeViews = readers.flatMap { ligatureTextViews($0.view) }.filter { $0.string == source }
        + ligatureTextViews(context.view).filter { $0.string.contains("pub fn target") }
    try #require(codeViews.count == 3)
    var settings = ReaderSettings()
    settings.codeFont = .postScriptName("Menlo-Regular")
    for mode in CodeLigatureMode.allCases {
        settings.codeLigatures = mode
        first.applyReaderSettings(settings)
        let resolved = ReaderFontResolver.shared.resolve(theme: ReaderTheme(settings: settings))
        for view in codeViews {
            #expect(view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont == resolved.font)
            #expect(view.textStorage?.attribute(.ligature, at: 0, effectiveRange: nil) as? Int
                == resolved.attributes[.ligature] as? Int)
        }
    }
    ReaderFontResolver.shared.refresh()
    first.applyReaderSettings(settings)
    #expect(codeViews.allSatisfy { ($0.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.fontName == "Menlo-Regular" })

    let secondModel = AppModel(sessionURL: root.appendingPathComponent("state/second.json"))
    let second = MainWindowController(model: secondModel, settings: settings, offscreen: true)
    defer { second.close() }
    second.openProject(root: root)
    try #require(await waitForLigatureSurface { secondModel.snapshotPhase == .fullReady })
    second.showWindow(nil)
    second.openFileForSelfTest(root.appendingPathComponent("main.rs"))
    try #require(await waitForLigatureSurface { second.selfTestLeftReaderBytes == Array(source.utf8) })
    #expect(second.selfTestLeftReaderFontName(at: 0) == "Menlo-Regular")
    let secondContent = try #require(second.window?.contentView)
    let secondText = try #require(ligatureTextViews(secondContent).first { $0.string == source })
    #expect(secondText.textStorage?.attribute(.ligature, at: 0, effectiveRange: nil) as? Int == 0)
    secondModel.selectCompareCommit("HEAD")
    second.applyPanelPreset(.compare)
    try #require(await waitForLigatureSurface { second.selfTestRightReaderBytes == Array(source.utf8) })
    secondModel.contextWindow.tokenClicked(file: "main.rs", offset: UInt32("pub fn ".utf8.count))
    try #require(await waitForLigatureSurface { secondModel.contextWindow.selectedCandidate != nil })
    second.renderForSelfTest()
    let secondRoot = try #require(second.window?.contentViewController)
    let secondContext = try #require(ligatureControllers(secondRoot).compactMap { $0 as? ContextWindowViewController }.first)
    try #require(await waitForLigatureSurface { ligatureTextViews(secondContext.view).contains { $0.string.contains("pub fn target") } })
    let newlyCreatedViews = ligatureControllers(secondRoot).compactMap { $0 as? ReaderViewController }
        .flatMap { ligatureTextViews($0.view) }.filter { $0.string == source }
        + ligatureTextViews(secondContext.view).filter { $0.string.contains("pub fn target") }
    #expect(newlyCreatedViews.count == 3)
    for view in newlyCreatedViews {
        #expect((view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.fontName == "Menlo-Regular")
        #expect(view.textStorage?.attribute(.ligature, at: 0, effectiveRange: nil) as? Int == 0)
    }

    first.closeComparison()
    first.openFileForSelfTest(root.appendingPathComponent("notes.txt"))
    try #require(await waitForLigatureSurface { first.selfTestReaderPreviewText == plain })
    let plainView = try #require(ligatureTextViews(rootController.view).first { $0.string == plain })
    let oldFont = try #require(plainView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
    let oldLigature = plainView.textStorage?.attribute(.ligature, at: 0, effectiveRange: nil) as? Int
    settings.codeFont = .postScriptName("Courier")
    settings.codeLigatures = .enabled
    first.applyReaderSettings(settings)
    #expect(plainView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont == oldFont)
    #expect(plainView.textStorage?.attribute(.ligature, at: 0, effectiveRange: nil) as? Int == oldLigature)
    #expect(plainView.string == plain)
}

@MainActor
private func ligatureControllers(_ controller: NSViewController) -> [NSViewController] {
    [controller] + controller.children.flatMap(ligatureControllers)
}

@MainActor
private func ligatureTextViews(_ view: NSView) -> [NSTextView] {
    (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(ligatureTextViews)
}

@MainActor
private func waitForLigatureSurface(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(30)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}


@MainActor
@Test(.timeLimit(.minutes(2)))
func appDelegateFontEnvironmentNotificationAutomaticallyRefreshesReaderAndSettings() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LigatureBroadcast-\(UUID().uuidString)")
    let project = root.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let suite = "LigatureBroadcast-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
    let source = "pub fn target() -> bool { 1 != 2 }\n"
    let file = project.appendingPathComponent("main.rs")
    try source.write(to: file, atomically: true, encoding: .utf8)
    let recent = RecentProjectsStore(defaults: defaults)
    let model = AppModel(sessionURL: root.appendingPathComponent("session.json"), recentProjectsStore: recent)
    let delegate = AppDelegate(
        startedAt: .now, model: model, recentProjectsStore: recent,
        windowSessionURL: root.appendingPathComponent("session.json"),
        sharedTrustRegistry: TrustRegistry(fileURL: root.appendingPathComponent("trust.json")),
        sharedMaterializer: Materializer(rootURL: root.appendingPathComponent("cache"))
    )
    let savedPreferences = ReaderSettings(defaults: .standard)
    delegate.selfTestLaunchOffscreen()
    let controller = try #require(delegate.selfTestProjectWindow(0))
    defer { delegate.settingsWindowController?.close(); controller.close() }
    controller.openProject(root: project)
    try #require(await waitForLigatureSurface { model.snapshotPhase == .fullReady })
    controller.openFileForSelfTest(file)
    try #require(await waitForLigatureSurface { controller.selfTestLeftReaderBytes == Array(source.utf8) })
    delegate.showSettings(nil)
    let settings = try #require(delegate.settingsWindowController)
    let readerContent = try #require(controller.window?.contentView)
    let reader = try #require(ligatureTextViews(readerContent).first { $0.string == source })
    let settingsContent = try #require(settings.window?.contentView)
    try #require(await waitForLigatureSurface {
        ligatureTextViews(settingsContent).contains { $0.string.contains("fn greet") }
    })
    let preview = try #require(ligatureTextViews(settingsContent).first { $0.string.contains("fn greet") })
    try await Task.sleep(for: .milliseconds(200))
    let storages = [try #require(reader.textStorage), try #require(preview.textStorage)]
    let (notifications, continuation) = AsyncStream<Int>.makeStream()
    let observers = storages.enumerated().map { index, storage in
        NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification,
                                               object: storage, queue: .main) { _ in
            continuation.yield(index)
        }
    }
    defer { observers.forEach(NotificationCenter.default.removeObserver) }
    // No manual apply: the real AppDelegate observer must refresh registered windows.
    ReaderFontResolver.shared.refresh()
    try await Task.sleep(for: .milliseconds(200))
    continuation.finish()
    var editedSurfaces = Set<Int>()
    for await index in notifications { editedSurfaces.insert(index) }
    #expect(editedSurfaces == [0, 1])
    #expect(reader.string == source)
    #expect(settings.currentSettings == savedPreferences)
    #expect(ReaderSettings(defaults: .standard) == savedPreferences)
}
