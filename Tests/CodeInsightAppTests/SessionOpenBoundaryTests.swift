import AppKit
import CodeInsightCore
import CodeInsightReaderCore
import Foundation
import Testing
@testable import CodeInsightApp
@testable import CodeInsightAppModel

@MainActor
@Test
func sessionLanguageReopenCapturesPendingTabsBeforeLoadingSnapshot() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("SessionBoundary-\(UUID())")
    let state = FileManager.default.temporaryDirectory.appendingPathComponent("SessionBoundaryState-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "fn main() {}".write(to: root.appendingPathComponent("main.rs"), atomically: true, encoding: .utf8)
    try "def main(): pass".write(to: root.appendingPathComponent("main.py"), atomically: true, encoding: .utf8)
    defer { for path in [root, state] { try? FileManager.default.removeItem(at: path) } }
    let model = AppModel(sessionURL: state.appendingPathComponent("session.json"))
    try model.openProject(root: root, language: .rust)
    try #require(await sessionBoundaryWait { model.snapshotPhase == .fullReady })
    model.openInNewTab(root.appendingPathComponent("main.rs"))
    try model.writeSessionCheckpoint(panelPreset: .reading)
    let controller = MainWindowController(model: model, settings: ReaderSettings(), offscreen: true)
    defer { controller.close() }
    // The new tab has not reached the debounced checkpoint yet.
    model.openInNewTab(root.appendingPathComponent("main.py"))
    controller.openProject(root: root, language: .python)
    try #require(await sessionBoundaryWait {
        model.projectLanguages == [.python] && model.snapshotPhase == .fullReady && !model.isRestoringSession
    })
    #expect(model.tabStrip.tabs.compactMap { $0.fileURL?.lastPathComponent } == ["main.rs", "main.py"])
    #expect(model.tabStrip.activeTab?.fileURL?.lastPathComponent == "main.py")
}

@MainActor
private func sessionBoundaryWait(_ predicate: () -> Bool) async -> Bool {
    for _ in 0..<500 {
        if predicate() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return false
}

@MainActor
@Test
func sessionReopenRetriesAfterSavedFileBecomesReadable() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("SessionRetry-\(UUID())")
    let state = root.appendingPathComponent("state")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("main.rs")
    try "fn main() {}".write(to: file, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = AppModel(sessionURL: state.appendingPathComponent("session.json"))
    try writer.openProject(root: root, language: .rust)
    try #require(await sessionBoundaryWait { writer.snapshotPhase == .fullReady })
    writer.openInNewTab(file)
    try writer.writeSessionCheckpoint(panelPreset: .reading)
    let snapshot = state.appendingPathComponent("sessions")
        .appendingPathComponent(AppModel.sessionProjectKey(for: root) + ".json")
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: snapshot.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshot.path) }
    let model = AppModel(sessionURL: state.appendingPathComponent("session.json"))
    let controller = MainWindowController(model: model, settings: ReaderSettings(), offscreen: true)
    defer { controller.close() }
    controller.openRecentProject(root)
    try #require(await sessionBoundaryWait { model.snapshotPhase == .fullReady })
    #expect(model.sessionLoadNotice != nil)
    #expect(model.tabStrip.tabs.isEmpty)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshot.path)
    controller.openRecentProject(root)
    let deadline = ContinuousClock.now + .seconds(2)
    while model.tabStrip.tabs.isEmpty && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.tabStrip.activeTab?.fileURL == file)
    #expect(model.sessionLoadNotice == nil)
}
