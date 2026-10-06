import AppKit
import CodeInsightExact
import CodeInsightReaderCore
import Foundation
import Testing
@testable import CodeInsightApp
@testable import CodeInsightAppModel

@MainActor
@Test
func existingSettingsWindowAcceptsFreshSettingsWithoutObservableState() async throws {
    _ = NSApplication.shared
    ReaderSettingsWindowController.selfTestEnableAccessibility()
    let coordinator = ExactCoordinator(
        providerFactory: { _ in throw CocoaError(.featureUnsupported) },
        sandboxAvailable: { false }
    )
    defer { coordinator.shutdown() }
    var updatedSettings = ReaderSettings(fontSize: 13)
    let controller = ReaderSettingsWindowController(
        settings: ReaderSettings(fontSize: 13),
        exactCoordinator: coordinator,
        onRevoke: { _ in },
        onChange: { updatedSettings = $0 }
    )
    defer { controller.close() }

    controller.window?.appearance = NSAppearance(named: .aqua)
    controller.showWindow(nil)
    try await Task.sleep(for: .milliseconds(200))
    let contentView = try #require(controller.window?.contentView)
    let preview = try #require(readerSettingsDescendants(contentView)
        .compactMap { $0 as? NSTextView }
        .first { $0.accessibilityLabel() == CodeInsightApp.localized("settings.preview.accessibility") })
    var changed = ReaderSettings(fontSize: 17)
    changed.wrapLines = true
    changed.theme = .dark
    controller.update(settings: changed)
    try await Task.sleep(for: .milliseconds(200))

    #expect(controller.currentSettings == changed)
    #expect(controller.selfTestReaderToggleCount == 7)
    let originalText = preview.string
    #expect(originalText.contains("fn greet(name: &str"))
    #expect(preview.textStorage?.attribute(.font, at: 0, effectiveRange: nil)
        as? NSFont == NSFont.monospacedSystemFont(ofSize: 17, weight: .regular))
    #expect(preview.textContainer?.widthTracksTextView == true)
    #expect(!preview.isEditable)

    #expect(controller.selfTestPressReaderControl("Restore Reader Defaults"))
    try await Task.sleep(for: .milliseconds(200))
    #expect(updatedSettings == ReaderSettings())
    #expect(preview.string == originalText)
    #expect(preview.textStorage?.attribute(.font, at: 0, effectiveRange: nil)
        as? NSFont == NSFont.monospacedSystemFont(
            ofSize: ReaderSettings().fontSize, weight: .regular
        ))
    #expect(preview.textContainer?.widthTracksTextView == ReaderSettings().wrapLines)
}

@MainActor
private func readerSettingsDescendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(readerSettingsDescendants)
}
