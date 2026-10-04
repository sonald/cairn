import AppKit
import CodeInsightCore
import CodeInsightEngine
import CodeInsightExact
import CodeInsightReaderCore
import CodeInsightReaderUI
import Foundation
import Testing
@testable import CodeInsightApp
@testable import CodeInsightAppModel

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
func welcomeMarksTrustedRecentsAndShowsWhenEachWasLastRead() async throws {
    let temp = FileManager.default.temporaryDirectory
        .appendingPathComponent("WelcomeStatus-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temp) }
    // The trusted project is opened through a symlink; the registry stores the real path.
    let trustedTarget = temp.appendingPathComponent("trusted-target", isDirectory: true)
    let trusted = temp.appendingPathComponent("trusted-repo", isDirectory: true)
    let read = temp.appendingPathComponent("read-repo", isDirectory: true)
    let fresh = temp.appendingPathComponent("fresh-repo", isDirectory: true)
    for url in [trustedTarget, read, fresh] {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    try FileManager.default.createSymbolicLink(at: trusted, withDestinationURL: trustedTarget)
    let suite = "WelcomeStatusTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = RecentProjectsStore(defaults: defaults)
    for url in [fresh, read, trusted] { store.record(url, language: .rust) }

    let registry = TrustRegistry(fileURL: temp.appendingPathComponent("trust.json"))
    try await registry.grant(trusted, mode: .trusted)
    let sessionURL = temp.appendingPathComponent("state/session.json")
    let sessionFile = sessionURL.deletingLastPathComponent()
        .appendingPathComponent("sessions", isDirectory: true)
        .appendingPathComponent(AppModel.sessionProjectKey(for: read) + ".json")
    try FileManager.default.createDirectory(
        at: sessionFile.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try Data("{}".utf8).write(to: sessionFile)
    let readAt = Date(timeIntervalSinceNow: -3 * 86_400)
    try FileManager.default.setAttributes([.modificationDate: readAt], ofItemAtPath: sessionFile.path)

    let controller = MainWindowController(
        model: AppModel(
            sessionURL: sessionURL,
            indexService: WelcomeIndexService(),
            exactCoordinator: ExactCoordinator(trustRegistry: registry)
        ),
        settings: ReaderSettings(theme: .light),
        offscreen: true,
        recentProjectsStore: store,
        recordsRecentProjects: false
    )
    defer { controller.close() }
    controller.renderForSelfTest()
    let reader = try #require(mirrored("readerController", of: controller, as: ReaderViewController.self))
    let welcome = try #require(mirrored("emptyStateView", of: reader, as: EmptyStateView?.self) ?? nil)
    let trustedLabel = CodeInsightApp.localized("main.trusted")
    // The registry is read asynchronously; the mark arrives on a later render.
    for _ in 0..<200 where welcome.selfTestRecentTitle(path: trusted.path)?.string.contains(trustedLabel) != true {
        try await Task.sleep(for: .milliseconds(10))
    }

    let trustedTitle = try #require(welcome.selfTestRecentTitle(path: trusted.path))
    #expect(trustedTitle.string.contains(trustedLabel))
    let markRange = (trustedTitle.string as NSString).range(of: trustedLabel)
    let markColor = trustedTitle.attribute(.foregroundColor, at: markRange.location, effectiveRange: nil) as? NSColor
    #expect(markColor?.usingColorSpace(.sRGB) == ReaderTheme(settings: ReaderSettings(theme: .light)).warningColor.usingColorSpace(.sRGB))

    let readTitle = try #require(welcome.selfTestRecentTitle(path: read.path)).string
    #expect(readTitle.contains(RelativeDateTimeFormatter().localizedString(for: readAt, relativeTo: Date())))
    #expect(!readTitle.contains(trustedLabel))

    let freshTitle = try #require(welcome.selfTestRecentTitle(path: fresh.path)).string
    #expect(!freshTitle.contains(trustedLabel))
    #expect(!freshTitle.contains(" · "))
}
