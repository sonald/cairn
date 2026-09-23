import AppKit
import CodeInsightExact
import CodeInsightReaderCore
import Foundation
import Testing
@testable import CodeInsightApp
@testable import CodeInsightAppModel

@MainActor
@Test
func readerVisualSettingControlsAreVisibleAndDoNotOverlap() throws {
    _ = NSApplication.shared
    ReaderSettingsWindowController.selfTestEnableAccessibility()
    let coordinator = ExactCoordinator(
        providerFactory: { _ in throw CocoaError(.featureUnsupported) },
        sandboxAvailable: { false }
    )
    defer { coordinator.shutdown() }
    var updatedSettings = ReaderSettings()
    let controller = ReaderSettingsWindowController(
        settings: ReaderSettings(),
        exactCoordinator: coordinator,
        onRevoke: { _ in },
        onChange: { updatedSettings = $0 }
    )
    defer { controller.close() }

    controller.showWindow(nil)
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
    _ = try #require(controller.window?.contentView)
    let initialSliders = controller.selfTestReaderAccessibilityElements.filter {
        $0.accessibilityRole?() == .slider
    }
    #expect(initialSliders.count == 1)
    #expect(initialSliders.first?.accessibilityLabel?() == CodeInsightApp.localized("settings.lineHeight"))
    #expect(controller.selfTestReaderToggleCount == 2)
    let lineHeight = try #require(initialSliders.first)
    _ = lineHeight.accessibilityPerformIncrement?()
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    #expect(updatedSettings.lineHeightMultiple > ReaderSettings().lineHeightMultiple)

    #expect(controller.selfTestPressReaderControl("Advanced typography"))
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
    let sliders = controller.selfTestReaderAccessibilityElements.filter {
        $0.accessibilityRole?() == .slider
            && $0.accessibilityLabel?() != CodeInsightApp.localized("settings.lineHeight")
    }
    #expect(Set(sliders.compactMap { $0.accessibilityLabel?() }) == [
        CodeInsightApp.localized("settings.parameterOpacity"), CodeInsightApp.localized("settings.gutterOpacity"),
        CodeInsightApp.localized("settings.functionWeight"), CodeInsightApp.localized("settings.constantWeight"),
    ])
    for slider in sliders {
        let value: Any? = slider.accessibilityValue?()
        #expect(value != nil)
        #expect(slider.isAccessibilityEnabled?() == true)
        _ = slider.accessibilityPerformIncrement?()
    }
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    #expect(updatedSettings.parameterReferenceAlpha > ReaderSettings().parameterReferenceAlpha)
    #expect(updatedSettings.declarationMarkerAlpha > ReaderSettings().declarationMarkerAlpha)
    #expect(updatedSettings.functionDeclarationFontWeight > ReaderSettings().functionDeclarationFontWeight)
    #expect(updatedSettings.declarationEmphasisFontWeight > ReaderSettings().declarationEmphasisFontWeight)

    #expect(controller.selfTestReaderToggleCount == 4)
}

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
    #expect(controller.selfTestReaderToggleCount == 2)
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
