import AppKit
import CodeInsightAppModel
import CodeInsightReaderCore
import Foundation
import Testing

@testable import CodeInsightApp

// §3.1/§3.2/§6.1 routing coverage: project identity normalization, window
// claim rules, and menu routing with real AppKit windows.

private func routingTemporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("MultiWindowRouting-\(UUID().uuidString)")
}

/// §3.2: trailing slashes, `.`, `..` and symlink aliases resolve to one
/// project identity; missing paths and plain files are rejected.
@MainActor
@Test
func projectIdentityNormalizesAliasesAndRejectsInvalidTargets() throws {
    let root = routingTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(
        at: project,
        withIntermediateDirectories: true
    )
    try Data("fn main() {}\n".utf8)
        .write(to: project.appendingPathComponent("main.rs"))
    let alias = root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(
        at: alias,
        withDestinationURL: project
    )

    func identity(_ url: URL) -> URL? {
        if case .success(let url) = AppDelegate.projectIdentity(for: url) {
            return url
        }
        return nil
    }

    let canonical = identity(project)
    #expect(canonical != nil)
    // Trailing slash, dot, and dot-dot forms all reach the same project.
    #expect(identity(URL(fileURLWithPath: project.path + "/")) == canonical)
    #expect(
        identity(project.appendingPathComponent(".").appendingPathComponent("."))
            == canonical
    )
    #expect(
        identity(
            project.appendingPathComponent("sub")
                .deletingLastPathComponent()
        ) == canonical
    )
    // A symlink alias is the same project request.
    #expect(identity(alias) == canonical)
    // Sibling directories are different projects — no name-based merging.
    let sibling = root.appendingPathComponent("project-copy", isDirectory: true)
    try FileManager.default.createDirectory(
        at: sibling,
        withIntermediateDirectories: true
    )
    #expect(identity(sibling) != canonical)

    // Failures are explicit.
    if case .failure = AppDelegate.projectIdentity(
        for: root.appendingPathComponent("missing")
    ) {
        #expect(true)
    } else {
        Issue.record("missing directory must fail identity resolution")
    }
    if case .failure = AppDelegate.projectIdentity(
        for: project.appendingPathComponent("main.rs")
    ) {
        #expect(true)
    } else {
        Issue.record("plain files must fail identity resolution")
    }
    if case .failure = AppDelegate.projectIdentity(
        for: URL(string: "https://example.com")!
    ) {
        #expect(true)
    } else {
        Issue.record("non-file URLs must fail identity resolution")
    }
    // A broken symlink is an explicit failure, not a silent identity.
    let broken = root.appendingPathComponent("broken")
    try FileManager.default.createSymbolicLink(
        at: broken,
        withDestinationURL: root.appendingPathComponent("gone")
    )
    if case .failure = AppDelegate.projectIdentity(for: broken) {
        #expect(true)
    } else {
        Issue.record("broken symlinks must fail identity resolution")
    }
}

/// §3.1: claiming a project retires a window from blank reuse; an
/// approved close retires it from routing entirely.
@MainActor
@Test
func windowClaimAndCloseRetireAWindowFromReuse() throws {
    let controller = MainWindowController(
        model: AppModel(),
        settings: ReaderSettings(),
        offscreen: true
    )
    defer { controller.close() }
    #expect(controller.projectURL == nil)
    #expect(controller.isUnclaimedForReuse)

    let root = routingTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("claimed", isDirectory: true)
    try FileManager.default.createDirectory(
        at: project,
        withIntermediateDirectories: true
    )
    controller.claimProject(project)

    #expect(controller.projectURL == project.standardizedFileURL)
    #expect(!controller.isUnclaimedForReuse)

    // Approved close: windowShouldClose runs the (sessionless) checkpoint
    // and approves; the window is then closing and never reusable.
    #expect(controller.windowShouldClose(controller.window!) == true)
    controller.windowWillClose(
        Notification(name: NSWindow.willCloseNotification, object: controller.window!)
    )
    #expect(controller.isClosing)
    #expect(!controller.isUnclaimedForReuse)
}

/// §6.1: menu routing follows the key window when it belongs to a project
/// window (main window or its panels), and global windows disable project
/// commands instead of falling back.
@MainActor
@Test
func menuRoutingResolvesProjectWindowsPanelsAndGlobalWindows() throws {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate(startedAt: .now)
    let controllerA = MainWindowController(
        model: AppModel(),
        settings: ReaderSettings(),
        offscreen: true
    )
    let controllerB = MainWindowController(
        model: AppModel(),
        settings: ReaderSettings(),
        offscreen: true
    )
    defer {
        controllerA.close()
        controllerB.close()
    }
    // Register through the same assembly path production windows use.
    delegate.registerProjectWindow(controllerA)
    delegate.registerProjectWindow(controllerB)
    // No key/main window: no target, and never the collection's first.
    #expect(
        delegate.projectCommandTarget(keyWindow: nil, mainWindow: nil) == nil
    )

    // The key main window of a project routes to its controller.
    #expect(
        delegate.projectCommandTarget(
            keyWindow: controllerA.window,
            mainWindow: controllerA.window
        ) === controllerA
    )
    #expect(
        delegate.projectCommandTarget(
            keyWindow: controllerB.window,
            mainWindow: controllerB.window
        ) === controllerB
    )

    // A tool panel owned by a project window still routes to its owner.
    controllerA.showBookmarks()
    let panelWindow = controllerA.selfTestBookmarkPanel?.window
    #expect(panelWindow != nil)
    #expect(
        delegate.projectCommandTarget(
            keyWindow: panelWindow,
            mainWindow: controllerB.window
        ) === controllerA
    )
    #expect(controllerA.panelKind(of: panelWindow) == "bookmarks")

    // A global settings window disables project commands — no fallback to
    // any project window.
    let settings = ReaderSettingsWindowController(
        settings: ReaderSettings(),
        exactCoordinator: ExactCoordinator(
            providerFactory: { _ in throw CocoaError(.featureUnsupported) },
            sandboxAvailable: { false }
        ),
        onRevoke: { _ in },
        onChange: { _ in }
    )
    defer { settings.close() }
    settings.showWindow(nil)
    #expect(
        delegate.projectCommandTarget(
            keyWindow: settings.window,
            mainWindow: controllerA.window
        ) == nil
    )
    // A key window with no project owner at all (e.g. an AppKit-managed
    // About panel behaves the same way) also disables project commands.
    let about = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    about.isReleasedWhenClosed = false
    about.orderFrontRegardless()
    #expect(
        delegate.projectCommandTarget(
            keyWindow: about,
            mainWindow: controllerB.window
        ) == nil
    )
    about.orderOut(nil)
    about.close()

    controllerA.closeBookmarks()
}
