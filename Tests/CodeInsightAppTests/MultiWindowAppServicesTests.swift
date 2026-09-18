import AppKit
import CodeInsightAppModel
import CodeInsightCore
import CodeInsightExact
import CodeInsightReaderCore
import Foundation
import Testing

@testable import CodeInsightApp

private func appServicesMakeGitProject(at project: URL) throws {
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try "fn alpha() {}\n".write(to: project.appendingPathComponent("lib.rs"), atomically: true, encoding: .utf8)
    for arguments in [
        ["init", "-q"], ["add", "lib.rs"],
        ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "fixture"],
    ] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = project
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
    }
}

@MainActor
private func appServicesEventually(_ condition: () -> Bool) async -> Bool {
    let deadline = Date(timeIntervalSinceNow: 10)
    while !condition(), Date() < deadline {
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

@MainActor
@Test(arguments: [false, true])
func appCacheClearResumesExactAfterSuccessOrFailure(retainedDirectory: Bool) async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AppServices-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("project")
    let cache = root.appendingPathComponent("cache")
    try appServicesMakeGitProject(at: project)
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    let registry = TrustRegistry(fileURL: root.appendingPathComponent("trust.json"))
    let materializer = Materializer(rootURL: cache)
    let coordinator = ExactCoordinator(
        providerFactory: { _ in throw CocoaError(.featureUnsupported) },
        sandboxAvailable: { false },
        trustRegistry: registry,
        materializer: materializer
    )
    let model = AppModel(
        sessionURL: root.appendingPathComponent("session.json"),
        exactCoordinator: coordinator
    )
    let delegate = AppDelegate(
        startedAt: .now,
        model: model,
        sharedTrustRegistry: registry,
        sharedMaterializer: materializer
    )
    let controller = MainWindowController(model: model, settings: ReaderSettings(), offscreen: true)
    delegate.registerProjectWindow(controller)
    defer { controller.window?.orderOut(nil); coordinator.shutdown() }
    try await model.openProject(root: project, languages: [.rust])
    if case .ready = model.projectState {} else {
        Issue.record("Git fixture did not reach ready: \(String(describing: model.projectFailureReason))")
        return
    }
    let expected = ExactCoordinator.Readiness.off("Safe exact disabled: sandbox-exec unavailable")
    #expect(await appServicesEventually { coordinator.readiness == expected })

    // A live reference outside these windows forces the real clear() failure.
    if retainedDirectory { materializer.retain(cache) }
    defer { if retainedDirectory { materializer.release(cache) } }
    let outcome = await delegate.clearMaterializedCacheAppLevel()
    if retainedDirectory {
        if case .failed = outcome {} else { Issue.record("clear must fail with a retained directory") }
    } else {
        #expect(outcome == .cleared)
    }
    #expect(!materializer.isUnderMaintenance)
    // This terminal state proves prepare ran again; simply clearing the
    // maintenance flag would leave readiness at off(cache maintenance).
    #expect(await appServicesEventually { coordinator.readiness == expected })
    await coordinator.shutdownAndWait()
}

@MainActor
@Test
func existingAppSettingsRefreshesSharedTrustOnEveryOpen() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AppSettings-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = TrustRegistry(fileURL: root.appendingPathComponent("trust.json"))
    let delegate = AppDelegate(startedAt: .now, sharedTrustRegistry: registry)
    try await registry.grant(root.appendingPathComponent("initial"), mode: .trusted)
    delegate.showSettings(nil)
    defer { delegate.settingsWindowController?.close() }
    let original = try #require(delegate.settingsWindowController)
    // Observe the first refresh before adding the later record.
    #expect(await appServicesEventually { delegate.trustListModel.repositories.count == 1 })
    original.close()
    try await registry.grant(root.appendingPathComponent("project"), mode: .trusted)
    delegate.showSettings(nil)
    #expect(delegate.settingsWindowController === original)
    #expect(await appServicesEventually { delegate.trustListModel.repositories.count == 2 })
}

@MainActor
@Test
func globalSettingsDisablesEveryTargetlessProjectMenu() throws {
    let delegate = AppDelegate(startedAt: .now)
    delegate.showSettings(nil)
    defer { delegate.settingsWindowController?.close() }
    #expect(delegate.projectCommandTarget() == nil)
    for action in [
        "showBookmarks:", "useFullReadingHeight:", "useStructureReadingHeight:",
        "useOverviewReadingHeight:", "applyPanelPreset:", "toggleRelations:",
        "previousContextCandidate:", "nextContextCandidate:",
    ] {
        let item = NSMenuItem(title: action, action: NSSelectorFromString(action), keyEquivalent: "")
        let enabled = delegate.validateMenuItem(item)
        #expect(!enabled, "\(action) must require a project target")
    }
    let globalItem = NSMenuItem(title: "Settings", action: NSSelectorFromString("showSettings:"), keyEquivalent: "")
    #expect(delegate.validateMenuItem(globalItem))
}

@MainActor
@Test
func appTrustGrantRefreshesExistingSettingsAndOtherWindows() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AppGrant-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("project")
    try appServicesMakeGitProject(at: project)
    let registry = TrustRegistry(fileURL: root.appendingPathComponent("trust.json"))
    let materializer = Materializer(rootURL: root.appendingPathComponent("cache"))
    let delegate = AppDelegate(
        startedAt: .now, sharedTrustRegistry: registry, sharedMaterializer: materializer
    )
    let coordinators = (0..<2).map { _ in
        ExactCoordinator(
            providerFactory: { _ in throw CocoaError(.featureUnsupported) },
            sandboxAvailable: { false },
            trustRegistry: registry,
            materializer: materializer
        )
    }
    let models = coordinators.map { AppModel(exactCoordinator: $0) }
    let windows = models.map { MainWindowController(model: $0, settings: ReaderSettings(), offscreen: true) }
    for window in windows { delegate.registerProjectWindow(window) }
    delegate.showSettings(nil)
    defer {
        delegate.settingsWindowController?.close()
        for window in windows { window.window?.orderOut(nil) }
        for coordinator in coordinators { coordinator.shutdown() }
    }
    try await models[0].openProject(root: project, languages: [.rust])
    if case .ready = models[0].projectState {} else {
        Issue.record("grant fixture must be loaded")
        return
    }
    try await delegate.grantCurrentRepositoryTrustAppLevel(models[0])
    let expected = await registry.trustedRepositories()
    #expect(expected.count == 1)
    #expect(delegate.trustListModel.repositories == expected)
    #expect(coordinators[1].trustedRepositories == expected)
    for coordinator in coordinators { await coordinator.shutdownAndWait() }
}

/// Exercise main's production assembly, including the first window. Building
/// two models by hand would miss an independently injected bootstrap model.
@MainActor
@Test
func productionFirstAndLaterWindowsShareBookmarksTrustAndCache() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ProductionServices-\(UUID().uuidString)")
    let suite = "ProductionServices-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
    let registry = TrustRegistry(fileURL: root.appendingPathComponent("trust.json"))
    let materializer = Materializer(rootURL: root.appendingPathComponent("cache"))
    let delegate = AppDelegate.production(
        startedAt: .now,
        sessionURL: root.appendingPathComponent("session.json"),
        recentProjectsStore: RecentProjectsStore(defaults: defaults),
        sharedTrustRegistry: registry,
        sharedMaterializer: materializer
    )
    delegate.selfTestLaunchOffscreen()
    #expect(NSApplication.shared.sendAction(NSSelectorFromString("newWindow:"), to: delegate, from: nil))
    let first = try #require(delegate.selfTestProjectWindow(0))
    let second = try #require(delegate.selfTestProjectWindow(1))
    defer { first.close(); second.close() }
    for (index, controller) in [first, second].enumerated() {
        let record = BookmarkRecord(
            id: UUID(), projectPath: root.appendingPathComponent("project-\(index)").path,
            snapshot: .worktree, path: "lib.rs",
            contentID: ContentID.sha256(of: Data("project-\(index)".utf8)),
            byteOffset: 0, line: 1, symbolName: nil, symbolKind: nil,
            note: "window-\(index)", updatedAt: .now
        )
        #expect(controller.model.bookmarkModel.toggle(record) == .added)
    }
    #expect(first.model.bookmarkModel.records.count == 2)
    #expect(second.model.bookmarkModel.records.count == 2)
    #expect(try BookmarkStore(fileURL: root.appendingPathComponent("bookmarks.json")).load().count == 2)
    for controller in [first, second] {
        #expect(controller.model.exactCoordinator.trustRegistry === registry)
    }
    materializer.beginMaintenance()
    defer { materializer.endMaintenance() }
    for controller in [first, second] {
        let coordinator = controller.model.exactCoordinator
        coordinator.prepare(projectURL: root, revision: nil, generation: 1)
        #expect(coordinator.readiness == .off("cache maintenance"))
        await coordinator.shutdownAndWait()
    }
}

@MainActor
@Test
func closedWindowIgnoresLateTrustSheetConfirmation() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LateTrustSheet-\(UUID().uuidString)")
    let suite = "LateTrustSheet-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
    let project = root.appendingPathComponent("project")
    try appServicesMakeGitProject(at: project)
    let registry = TrustRegistry(fileURL: root.appendingPathComponent("trust.json"))
    let coordinator = ExactCoordinator(
        providerFactory: { _ in throw CocoaError(.featureUnsupported) },
        sandboxAvailable: { false },
        trustRegistry: registry,
        materializer: Materializer(rootURL: root.appendingPathComponent("cache"))
    )
    let recent = RecentProjectsStore(defaults: defaults)
    let model = AppModel(
        sessionURL: root.appendingPathComponent("session.json"),
        recentProjectsStore: recent,
        exactCoordinator: coordinator
    )
    let delegate = AppDelegate(
        startedAt: .now, model: model, recentProjectsStore: recent,
        sharedTrustRegistry: registry
    )
    delegate.selfTestLaunchOffscreen()
    let controller = try #require(delegate.selfTestProjectWindow(0))
    let window = try #require(controller.window)
    defer { controller.close(); coordinator.shutdown() }
    delegate.selfTestEnqueueOpenRequest(root: project, languages: [.rust])
    try #require(await appServicesEventually {
        if case .ready = model.projectState { return !delegate.selfTestIsDrainingOpenRequests }
        return false
    })
    window.makeKeyAndOrderFront(nil)
    try #require(await appServicesEventually { delegate.projectCommandTarget() === controller })
    try #require(NSApplication.shared.sendAction(
        NSSelectorFromString("trustThisRepository:"), to: delegate, from: nil
    ))
    let sheet = try #require(window.attachedSheet)
    window.close()
    try #require(controller.isClosing)
    if sheet.sheetParent === window {
        window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
    }
    try #require(await appServicesEventually {
        delegate.selfTestProjectWindowCount == 0 && sheet.sheetParent == nil
    })
    await controller.teardownCompletion()
    await Task.yield()
    #expect(await registry.trustedRepositories().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("trust.json").path))
}
