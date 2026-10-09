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
    #expect(controller.selfTestReaderToggleCount == 8)
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

@MainActor
@Test
func settingsPreviewRecolorsWhenQuietSyntaxToggles() async throws {
    _ = NSApplication.shared
    ReaderSettingsWindowController.selfTestEnableAccessibility()
    let coordinator = ExactCoordinator(
        providerFactory: { _ in throw CocoaError(.featureUnsupported) },
        sandboxAvailable: { false }
    )
    defer { coordinator.shutdown() }
    var quiet = ReaderSettings(theme: ReaderSettings.Theme(rawValue: "base16:nord"))
    quiet.quietSyntax = true
    var changedTo: ReaderSettings?
    let controller = ReaderSettingsWindowController(
        settings: quiet,
        exactCoordinator: coordinator,
        onRevoke: { _ in },
        onChange: { changedTo = $0 }
    )
    defer { controller.close() }
    controller.showWindow(nil)
    try await Task.sleep(for: .milliseconds(300))
    let contentView = try #require(controller.window?.contentView)
    let preview = try #require(readerSettingsDescendants(contentView)
        .compactMap { $0 as? NSTextView }
        .first { $0.accessibilityLabel() == CodeInsightApp.localized("settings.preview.accessibility") })
    let greet = (preview.string as NSString).range(of: "greet")
    #expect(greet.location != NSNotFound)
    let quietColor = ReaderTheme(settings: quiet).color(for: .functionName)
    var full = quiet
    full.quietSyntax = false
    let fullColor = ReaderTheme(settings: full).color(for: .functionName)
    #expect(previewColors(preview, in: greet).contains { $0.isEquivalent(to: quietColor) })

    // Flip the toggle itself, as the user does: it is the first switch after
    // the theme pop-up (SwiftUI gives it no accessibility label).
    let elements = controller.selfTestReaderAccessibilityElements
    let popUp = try #require(elements.firstIndex { $0.accessibilityRole?() == .popUpButton })
    let toggle = try #require(elements[popUp...].first { $0.accessibilityRole?() == .checkBox })
    // AXPress on a SwiftUI switch reports false yet flips it; judge by the effect.
    _ = toggle.accessibilityPerformPress?()
    try await Task.sleep(for: .milliseconds(300))
    // What the app does with the change: hand the settings back to the window.
    if let changedTo { controller.update(settings: changedTo) }
    try await Task.sleep(for: .milliseconds(300))
    #expect(changedTo?.quietSyntax == false)
    #expect(previewColors(preview, in: greet).contains { $0.isEquivalent(to: fullColor) },
            "preview still shows \(previewColors(preview, in: greet).map(\.hexDescription))")
}

@MainActor
private func previewColors(_ textView: NSTextView, in range: NSRange) -> [NSColor] {
    guard let manager = textView.textLayoutManager, let content = manager.textContentManager else { return [] }
    var colors: [NSColor] = []
    manager.enumerateRenderingAttributes(from: content.documentRange.location, reverse: false) { _, attributes, textRange in
        let lower = content.offset(from: content.documentRange.location, to: textRange.location)
        let upper = content.offset(from: content.documentRange.location, to: textRange.endLocation)
        if NSIntersectionRange(range, NSRange(location: lower, length: upper - lower)).length > 0,
           let color = attributes[.foregroundColor] as? NSColor {
            colors.append(color)
        }
        return true
    }
    return colors
}

private extension NSColor {
    func isEquivalent(to other: NSColor) -> Bool {
        let appearance = NSAppearance(named: .aqua)!
        var mine = self, theirs = other
        appearance.performAsCurrentDrawingAppearance {
            mine = self.usingColorSpace(.sRGB) ?? self
            theirs = other.usingColorSpace(.sRGB) ?? other
        }
        return abs(mine.redComponent - theirs.redComponent) < 0.01
            && abs(mine.greenComponent - theirs.greenComponent) < 0.01
            && abs(mine.blueComponent - theirs.blueComponent) < 0.01
    }
    var hexDescription: String {
        var c = self
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { c = self.usingColorSpace(.sRGB) ?? self }
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}
