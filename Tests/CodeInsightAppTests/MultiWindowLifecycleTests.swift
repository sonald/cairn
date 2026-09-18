import AppKit
import CodeInsightAppModel
import CodeInsightCore
import CodeInsightEngine
import CodeInsightExact
import CodeInsightReaderCore
import Foundation
import Testing

@testable import CodeInsightApp

// Review 2026-09-17 F1–F8: behavior tests that can fail. Each test drives
// the production AppDelegate/MainWindowController lifecycle with isolated
// storage and scripted decision points.

// MARK: - Local fixtures

private struct LifecycleIndexService: IndexService {
    func index(root: URL, language: LanguageID) async throws -> EngineSession {
        try await Task.detached {
            try ProjectIndexer().index(root: root, language: language)
        }.value
    }
}

private func lifecycleTemporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("MultiWindowLifecycle-\(UUID().uuidString)")
}

private func lifecycleMakeProject(_ files: [String: String]) throws -> URL {
    let root = lifecycleTemporaryDirectory()
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
        try contents.write(to: file, atomically: true, encoding: .utf8)
    }
    return root
}

@MainActor
private func lifecycleWaitUntil(
    timeout: TimeInterval = 30,
    _ condition: @autoclosure () -> Bool
) async -> Bool {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

@MainActor
private func lifecycleProjectIsReady(_ model: AppModel) -> Bool {
    if case .ready = model.projectState { return true }
    return false
}

/// Isolated AppDelegate with temp storage for every shared service.
@MainActor
private func lifecycleAppDelegate(
    sessionURL: URL,
    defaults: UserDefaults
) -> AppDelegate {
    let storageRoot = sessionURL.deletingLastPathComponent()
    let store = RecentProjectsStore(defaults: defaults)
    return AppDelegate(
        startedAt: .now,
        model: AppModel(
            sessionURL: sessionURL,
            recentProjectsStore: store,
            indexService: LifecycleIndexService()
        ),
        recentProjectsStore: store,
        windowSessionURL: sessionURL,
        sharedTrustRegistry: TrustRegistry(
            fileURL: storageRoot.appendingPathComponent("trust.json")
        ),
        sharedMaterializer: Materializer(
            rootURL: storageRoot.appendingPathComponent("materialized")
        )
    )
}

// MARK: - F1: cancelled first open releases the claim; a repeat loads

@MainActor
@Test
func cancelledFirstOpenReleasesClaimAndRepeatRequestLoads() async throws {
    let storageRoot = lifecycleTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: storageRoot) }
    let project = try lifecycleMakeProject([
        "src/lib.rs": "pub fn alpha() {}\n",
    ])
    defer { try? FileManager.default.removeItem(at: project) }
    let defaults = UserDefaults(
        suiteName: "MWLifecycle-\(UUID().uuidString)"
    )!
    let delegate = lifecycleAppDelegate(
        sessionURL: storageRoot.appendingPathComponent("session.json"),
        defaults: defaults
    )

    // The window the launch created is a user-created blank window: it
    // must survive a cancelled request unclaimed (§3.3).
    delegate.selfTestLaunchOffscreen()
    guard let blank = delegate.selfTestProjectWindow(0) else {
        Issue.record("launch window missing")
        return
    }
    delegate.languagePickerOverride = { _ in nil }

    delegate.selfTestEnqueueOpenRequest(root: project, languages: nil)
    #expect(
        await lifecycleWaitUntil(delegate.selfTestIsDrainingOpenRequests == false)
    )
    await Task.yield()
    await Task.yield()

    #expect(delegate.selfTestProjectWindowCount == 1)
    #expect(blank.isUnclaimedForReuse, "cancelled request must release the claim")
    #expect(blank.projectURL == nil)

    // The repeat request starts over instead of activating a zombie claim.
    delegate.languagePickerOverride = { _ in [.rust] }
    delegate.selfTestEnqueueOpenRequest(root: project, languages: nil)
    #expect(
        await lifecycleWaitUntil(
            lifecycleProjectIsReady(blank.model)
                && blank.projectURL?.standardizedFileURL
                    == project.standardizedFileURL
        ),
        "repeat request after cancel must load the project"
    )
    #expect(delegate.selfTestProjectWindowCount == 1)
}

@MainActor
@Test
func cancelledProjectWindowUsesNextProjectsFrameAutosave() async throws {
    let storageRoot = lifecycleTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: storageRoot) }
    let projectA = try lifecycleMakeProject(["src/a.rs": "fn a() {}\n"])
    let projectB = try lifecycleMakeProject(["src/b.rs": "fn b() {}\n"])
    defer {
        try? FileManager.default.removeItem(at: projectA)
        try? FileManager.default.removeItem(at: projectB)
    }
    let defaults = UserDefaults(suiteName: "MWLifecycle-\(UUID().uuidString)")!
    let delegate = lifecycleAppDelegate(
        sessionURL: storageRoot.appendingPathComponent("session.json"),
        defaults: defaults
    )
    delegate.selfTestLaunchOffscreen()
    let blank = try #require(delegate.selfTestProjectWindow(0))
    let window = try #require(blank.window)
    delegate.languagePickerOverride = { _ in nil }
    delegate.selfTestEnqueueOpenRequest(root: projectA, languages: nil)
    #expect(await lifecycleWaitUntil(!delegate.selfTestIsDrainingOpenRequests))
    #expect(blank.isUnclaimedForReuse)
    #expect(window.frameAutosaveName.isEmpty,
            "cancelled project must stop owning this window's saved frame")

    delegate.selfTestEnqueueOpenRequest(root: projectB, languages: [.rust])
    #expect(await lifecycleWaitUntil(lifecycleProjectIsReady(blank.model)))
    #expect(delegate.selfTestProjectWindowCount == 1)
    #expect(delegate.selfTestProjectWindow(0) === blank)
    #expect(window.frameAutosaveName == NSWindow.FrameAutosaveName(
        "CodeInsightMainWindow-" + AppModel.sessionProjectKey(for: projectB)
    ), "reused window must save its frame under project B")
}

/// F5: an explicit language choice survives a missing session and beats
/// both the Recents record and the probe preselection.
@MainActor
@Test
func explicitLanguageChoiceBeatsRecentsAndProbeOnFirstOpen() async throws {
    let storageRoot = lifecycleTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: storageRoot) }
    let project = try lifecycleMakeProject([
        "src/lib.rs": "pub fn alpha() {}\n",
        "app.py": "def f():\n    pass\n",
    ])
    defer { try? FileManager.default.removeItem(at: project) }
    let defaults = UserDefaults(
        suiteName: "MWLifecycle-\(UUID().uuidString)"
    )!
    let store = RecentProjectsStore(defaults: defaults)
    // A stale Recents preference and a picker that would pick Rust must
    // both lose against the explicit Python request.
    store.record(project, language: .rust)
    let delegate = lifecycleAppDelegate(
        sessionURL: storageRoot.appendingPathComponent("session.json"),
        defaults: defaults
    )
    delegate.languagePickerOverride = { _ in
        Issue.record("picker must not run when an explicit language is given")
        return [.rust]
    }
    delegate.selfTestLaunchOffscreen()
    guard let window = delegate.selfTestProjectWindow(0) else {
        Issue.record("launch window missing")
        return
    }

    delegate.selfTestEnqueueOpenRequest(root: project, languages: [.python])
    #expect(
        await lifecycleWaitUntil(lifecycleProjectIsReady(window.model))
    )
    #expect(window.model.projectLanguages == [.python])
    #expect(
        window.lastOpenedProjectLanguage == .python,
        "explicit language must not be replaced by Recents or the probe"
    )
}

// MARK: - F2: closing keeps the claim until teardown finishes

@MainActor
@Test
func closedWindowReleasesClaimOnlyAfterTeardownFinishes() async throws {
    let storageRoot = lifecycleTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: storageRoot) }
    let project = try lifecycleMakeProject([
        "src/lib.rs": "pub fn alpha() {}\n",
    ])
    defer { try? FileManager.default.removeItem(at: project) }
    let defaults = UserDefaults(
        suiteName: "MWLifecycle-\(UUID().uuidString)"
    )!
    let delegate = lifecycleAppDelegate(
        sessionURL: storageRoot.appendingPathComponent("session.json"),
        defaults: defaults
    )
    let store = RecentProjectsStore(defaults: defaults)
    store.record(project, language: .rust)
    delegate.selfTestLaunchOffscreen()
    guard let window = delegate.selfTestProjectWindow(0) else {
        Issue.record("launch window missing")
        return
    }
    delegate.selfTestEnqueueOpenRequest(root: project, languages: nil)
    #expect(await lifecycleWaitUntil(lifecycleProjectIsReady(window.model)))

    window.window?.performClose(nil)

    // Immediately after the close: the controller is marked closing and
    // still claims its project so a repeat request can find and wait for
    // it (§4.1); it is NOT yet dropped from the collection.
    #expect(window.isClosing)
    #expect(window.projectURL != nil, "claim must survive until teardown ends")
    #expect(
        await lifecycleWaitUntil(delegate.selfTestProjectWindowCount == 0),
        "controller leaves the collection only after teardown finished"
    )
    #expect(window.projectURL == nil)
}

// MARK: - W05: a pending destructive sheet stays with its closing owner

@MainActor
@Test(arguments: [false, true])
func closingWindowWithPendingClearSessionSheetPreservesBothSessions(
    deletingBookmark: Bool
) async throws {
    let storageRoot = lifecycleTemporaryDirectory()
    let projectA = try lifecycleMakeProject(["src/a.rs": "fn a() {}\n"])
    let projectB = try lifecycleMakeProject(["src/b.rs": "fn b() {}\n"])
    defer {
        for root in [storageRoot, projectA, projectB] {
            try? FileManager.default.removeItem(at: root)
        }
    }
    let defaults = UserDefaults(suiteName: "MWLifecycle-\(UUID().uuidString)")!
    let delegate = lifecycleAppDelegate(
        sessionURL: storageRoot.appendingPathComponent("session.json"),
        defaults: defaults
    )
    delegate.selfTestLaunchOffscreen()
    let controllerA = try #require(delegate.selfTestProjectWindow(0))
    delegate.selfTestEnqueueOpenRequest(root: projectA, languages: [.rust])
    try #require(await lifecycleWaitUntil(controllerA.model.snapshotPhase == .fullReady))
    delegate.selfTestEnqueueOpenRequest(root: projectB, languages: [.rust])
    try #require(await lifecycleWaitUntil(delegate.selfTestProjectWindowCount == 2))
    let controllerB = try #require(delegate.selfTestProjectWindow(1))
    try #require(await lifecycleWaitUntil(controllerB.model.snapshotPhase == .fullReady))
    defer { controllerB.window?.close() }
    controllerA.openFileForSelfTest(projectA.appendingPathComponent("src/a.rs"))
    controllerB.openFileForSelfTest(projectB.appendingPathComponent("src/b.rs"))
    try #require(await lifecycleWaitUntil(
        controllerA.model.selectedFile != nil && controllerB.model.selectedFile != nil
    ))
    var bookmarkID: UUID?
    if deletingBookmark {
        controllerA.setReadingPositionForSelfTest(
            scrollByteOffset: 0, selectionByteOffset: 0
        )
        try #require(await lifecycleWaitUntil(controllerA.canToggleBookmark))
        let record = try #require(controllerA.model.captureCurrentBookmark())
        try #require(controllerA.model.bookmarkModel.toggle(record) == .added)
        try #require(controllerA.model.bookmarkModel.updateNote(
            id: record.id, text: "Keep this note when its owner closes"
        ))
        bookmarkID = record.id
    }
    try controllerA.checkpointSessionSynchronouslyReportingFailure()
    try controllerB.checkpointSessionSynchronouslyReportingFailure()
    let savedA = storageRoot.appendingPathComponent("sessions")
        .appendingPathComponent(AppModel.sessionProjectKey(for: projectA) + ".json")
    let savedB = storageRoot.appendingPathComponent("sessions")
        .appendingPathComponent(AppModel.sessionProjectKey(for: projectB) + ".json")
    let beforeB = try Data(contentsOf: savedB)
    let selectedB = controllerB.model.selectedFile
    let tabsB = controllerB.model.tabStrip.tabs.map(\.fileURL)
    let windowA = try #require(controllerA.window)
    if deletingBookmark {
        controllerA.toggleBookmark()
    } else {
        controllerA.confirmClearReadingSession()
    }
    let sheet = try #require(windowA.attachedSheet)

    // Close the actual parent while its real NSAlert is pending. Some
    // AppKit versions end it on close; otherwise deliver the late response
    // through AppKit itself, without substituting the production callback.
    windowA.close()
    try #require(controllerA.isClosing)
    let afterCloseA = try Data(contentsOf: savedA)
    controllerB.window?.makeKeyAndOrderFront(nil)
    if sheet.sheetParent === windowA {
        windowA.endSheet(sheet, returnCode: .alertFirstButtonReturn)
    }
    try #require(await lifecycleWaitUntil(
        delegate.selfTestProjectWindowCount == 1 && sheet.sheetParent == nil
    ))
    await controllerA.teardownCompletion()
    await Task.yield()

    #expect(try Data(contentsOf: savedA) == afterCloseA)
    #expect(try Data(contentsOf: savedB) == beforeB)
    #expect(controllerB.model.selectedFile == selectedB)
    #expect(controllerB.model.tabStrip.tabs.map(\.fileURL) == tabsB)
    #expect(lifecycleProjectIsReady(controllerB.model))
    #expect(delegate.selfTestProjectWindow(0) === controllerB)
    #expect(controllerA.projectURL == nil && controllerA.model.projectRoot == nil)
    #expect(!windowA.isVisible)
    if let bookmarkID {
        #expect(controllerA.model.bookmarkModel.records.first {
            $0.id == bookmarkID
        }?.note == "Keep this note when its owner closes")
    }
}

// MARK: - F3: quit saves remaining windows when one fails

@MainActor
@Test
func quitSavesRemainingWindowsWhenOneWindowFails() async throws {
    let storageRoot = lifecycleTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: storageRoot) }
    let projectA = try lifecycleMakeProject(["src/a.rs": "fn a() {}\n"])
    let projectB = try lifecycleMakeProject(["src/b.rs": "fn b() {}\n"])
    defer {
        try? FileManager.default.removeItem(at: projectA)
        try? FileManager.default.removeItem(at: projectB)
    }
    let defaults = UserDefaults(
        suiteName: "MWLifecycle-\(UUID().uuidString)"
    )!
    let store = RecentProjectsStore(defaults: defaults)
    store.record(projectA, language: .rust)
    store.record(projectB, language: .rust)
    let delegate = lifecycleAppDelegate(
        sessionURL: storageRoot.appendingPathComponent("session.json"),
        defaults: defaults
    )
    delegate.selfTestLaunchOffscreen()
    guard let windowA = delegate.selfTestProjectWindow(0) else {
        Issue.record("launch window missing")
        return
    }
    delegate.selfTestEnqueueOpenRequest(root: projectA, languages: nil)
    #expect(await lifecycleWaitUntil(lifecycleProjectIsReady(windowA.model)))
    delegate.selfTestEnqueueOpenRequest(root: projectB, languages: nil)
    #expect(await lifecycleWaitUntil(delegate.selfTestProjectWindowCount == 2))
    guard let windowB = delegate.selfTestProjectWindow(1) else {
        Issue.record("second window missing")
        return
    }
    #expect(await lifecycleWaitUntil(lifecycleProjectIsReady(windowB.model)))

    // Make A's session writes fail: a directory where its session file
    // belongs — every atomic write to that path throws. B keeps a
    // writable store.
    let sessionsDirectory = storageRoot.appendingPathComponent("sessions")
    let blockedA = sessionsDirectory.appendingPathComponent(
        AppModel.sessionProjectKey(for: projectA) + ".json"
    )
    if !FileManager.default.fileExists(atPath: blockedA.path) {
        try windowA.checkpointSessionSynchronouslyReportingFailure()
    }
    if FileManager.default.fileExists(atPath: blockedA.path) {
        try FileManager.default.removeItem(at: blockedA)
    }
    try FileManager.default.createDirectory(
        at: blockedA,
        withIntermediateDirectories: false
    )

    // Scripted quit: skip A's failing save. B must still receive its
    // final save (review F3).
    let decisions = LockedDecisions()
    decisions.script = [.skipWindow]
    let proceed = delegate.finalizeQuitSaves { controller, _ in
        decisions.record(controller)
        return decisions.next()
    }
    #expect(proceed)
    #expect(decisions.failedControllers.count == 1)

    // B's final snapshot exists on disk with its project root; A's old
    // data (removed to place the blocker) is not silently rewritten.
    let keyB = AppModel.sessionProjectKey(for: projectB)
    let savedB = sessionsDirectory.appendingPathComponent("\(keyB).json")
    let payload = try Data(contentsOf: savedB)
    let snapshot = try JSONDecoder().decode(
        SessionSnapshotProbe.self, from: payload
    )
    #expect(snapshot.projectRoot == projectB.path)
    var isDirectory: ObjCBool = false
    #expect(
        FileManager.default.fileExists(atPath: blockedA.path, isDirectory: &isDirectory)
            && isDirectory.boolValue,
        "the blocking directory for A is untouched — nothing overwrote it"
    )

    // Cancelling the quit returns false and no window is destroyed.
    decisions.script = [.cancelQuit]
    #expect(!delegate.finalizeQuitSaves { _, _ in decisions.next() })
    #expect(delegate.selfTestProjectWindowCount == 2)
    #expect(!windowA.isClosing && !windowB.isClosing)
}

/// Minimal decode probe: only the fields the assertion needs.
private struct SessionSnapshotProbe: Decodable {
    let projectRoot: String
}

@MainActor
private final class LockedDecisions {
    var script: [AppDelegate.QuitSaveFailureDecision] = []
    private var index = 0
    private(set) var failedControllers: [MainWindowController] = []

    func record(_ controller: MainWindowController) {
        failedControllers.append(controller)
    }

    func next() -> AppDelegate.QuitSaveFailureDecision {
        defer { index += 1 }
        return script.indices.contains(index) ? script[index] : .cancelQuit
    }
}
