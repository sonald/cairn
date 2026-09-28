import AppKit
import CodeInsightCore
import CodeInsightEngine
import CodeInsightReaderCore
import CodeInsightReaderUI
import Foundation
import Testing
@testable import CodeInsightApp
@testable import CodeInsightAppModel

@MainActor
private func welcomeRGB(_ value: Any?) -> UInt32? {
    let color: NSColor? = switch value {
    case let color as NSColor: color
    case let color as CGColor: NSColor(cgColor: color)
    default: nil
    }
    guard let srgb = color?.usingColorSpace(.sRGB) else { return nil }
    return UInt32((srgb.redComponent * 255).rounded()) << 16
        | UInt32((srgb.greenComponent * 255).rounded()) << 8
        | UInt32((srgb.blueComponent * 255).rounded())
}

@MainActor
private func mirrored<T>(_ name: String, of object: Any, as type: T.Type) -> T? {
    Mirror(reflecting: object).children.first { $0.label == name }?.value as? T
}

private struct WelcomeIndexService: IndexService {
    func index(root: URL, language: LanguageID) async throws -> EngineSession {
        throw CocoaError(.featureUnsupported)
    }
}

@MainActor
@Test
func welcomeUsesASerifWordmarkAndThemedTagline() {
    let view = EmptyStateView(
        recentPaths: ["/tmp/knuth-rs"], failed: false,
        onChooseProject: {}, onOpenRecent: { _ in }, onOpenDropped: { _ in }, onRetry: {}
    )
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
        styleMask: [.titled], backing: .buffered, defer: false
    )
    window.contentView = view
    defer { window.orderOut(nil) }
    view.apply(theme: ReaderTheme(settings: ReaderSettings(theme: .dark)))
    window.contentView?.layoutSubtreeIfNeeded()

    #expect(view.selfTestTitleVisibleInWindow)
    let font = view.selfTestTitleFont
    #expect(font?.fontName.contains("NewYork") == true || font?.familyName?.contains("New York") == true)
    #expect(welcomeRGB(view.selfTestTaglineColor) == 0x8CC6A9)
    #expect(welcomeRGB(view.layer?.backgroundColor) == 0x121614)
}

@MainActor
@Test
func welcomeFollowsTheWindowThemeOnCreationAndChange() throws {
    let suite = "WelcomeThemeTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let controller = MainWindowController(
        model: AppModel(indexService: WelcomeIndexService()),
        settings: ReaderSettings(theme: .dark),
        offscreen: true,
        recentProjectsStore: RecentProjectsStore(defaults: defaults),
        recordsRecentProjects: false
    )
    defer { controller.close() }
    controller.window?.contentView?.layoutSubtreeIfNeeded()

    let reader = try #require(mirrored("readerController", of: controller, as: ReaderViewController.self))
    let welcome = try #require(mirrored("emptyStateView", of: reader, as: EmptyStateView?.self) ?? nil)
    #expect(welcome.theme.selection == .dark)
    #expect(welcomeRGB(welcome.selfTestTaglineColor) == 0x8CC6A9)

    controller.applyReaderSettings(ReaderSettings(theme: .siClassic))
    #expect(welcome.theme.selection == .siClassic)
    #expect(welcomeRGB(welcome.selfTestTaglineColor) == 0x1D3A8F)
}

@MainActor
@Test
func welcomeSetsRecentsBesideTheActionsAndStacksThemWhenNarrow() {
    let view = EmptyStateView(
        recentPaths: ["/tmp/knuth-rs", "/tmp/rlm"], failed: false,
        onChooseProject: {}, onOpenRecent: { _ in }, onOpenDropped: { _ in }, onRetry: {}
    )
    view.updateRecentLanguages(["/tmp/knuth-rs": "RS"])
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700),
        styleMask: [.titled], backing: .buffered, defer: false
    )
    window.contentView = view
    defer { window.orderOut(nil) }
    window.contentView?.layoutSubtreeIfNeeded()
    #expect(view.selfTestColumnsAreSideBySide)
    var frames = view.selfTestRecentFrames
    #expect(frames.recents.minX >= frames.actions.maxX)
    #expect(frames.recents.width > 0 && frames.recents.height > 0)
    // Only a recorded language gets a label; the other keeps its folder icon.
    #expect(view.selfTestRecentLanguageLabels == ["RS"])

    window.setContentSize(NSSize(width: 700, height: 900))
    window.contentView?.layoutSubtreeIfNeeded()
    #expect(!view.selfTestColumnsAreSideBySide)
    frames = view.selfTestRecentFrames
    #expect(frames.recents.maxY <= frames.actions.minY + 1)
}

@MainActor
@Test
func welcomeShowsRecordedLanguagesFromTheRecentProjectsStore() throws {
    let suite = "WelcomeLanguageTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = RecentProjectsStore(defaults: defaults)
    store.record(URL(fileURLWithPath: "/tmp/cairn-welcome-py", isDirectory: true), language: .python)
    let controller = MainWindowController(
        model: AppModel(indexService: WelcomeIndexService()),
        settings: ReaderSettings(theme: .light),
        offscreen: true,
        recentProjectsStore: store,
        recordsRecentProjects: false
    )
    defer { controller.close() }
    controller.renderForSelfTest()
    controller.window?.contentView?.layoutSubtreeIfNeeded()
    let reader = try #require(mirrored("readerController", of: controller, as: ReaderViewController.self))
    let welcome = try #require(mirrored("emptyStateView", of: reader, as: EmptyStateView?.self) ?? nil)
    #expect(welcome.selfTestRecentLanguageLabels == ["PY"])
}
