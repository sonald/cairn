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
    #expect(initialSliders.first?.accessibilityLabel?() == "Line height")
    #expect(controller.selfTestReaderToggleCount == 2)
    let lineHeight = try #require(initialSliders.first)
    #expect(lineHeight.accessibilityPerformIncrement?() == true)
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    #expect(updatedSettings.lineHeightMultiple > ReaderSettings().lineHeightMultiple)

    #expect(controller.selfTestPressReaderControl("Advanced typography"))
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
    let sliders = controller.selfTestReaderAccessibilityElements.filter {
        $0.accessibilityRole?() == .slider
            && $0.accessibilityLabel?() != "Line height"
    }
    #expect(Set(sliders.compactMap { $0.accessibilityLabel?() }) == [
        "Parameter use opacity", "Gutter marker opacity",
        "Function and type weight", "Constant and module weight",
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

    let geometry = controller.selfTestVisualControlGeometry
    #expect(controller.selfTestReaderToggleCount == 4)
    #expect(geometry.frames.count == 4)
    #expect(geometry.frames.allSatisfy {
        $0.width > 0 && $0.height > 0 && geometry.visibleFrame.contains($0)
    })
    #expect(!geometry.existingFrames.isEmpty)
    for index in geometry.frames.indices {
        for other in geometry.frames.indices where other > index {
            #expect(!geometry.frames[index].intersects(geometry.frames[other]))
        }
        #expect(geometry.existingFrames.allSatisfy {
            !geometry.frames[index].intersects($0)
        })
    }
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
        .first { $0.accessibilityLabel() == "Reader settings preview" })
    try expectReaderPreviewIsVisibleAndColored(preview, settings: updatedSettings)

    var changed = ReaderSettings(fontSize: 17)
    changed.wrapLines = true
    changed.theme = .dark
    controller.update(settings: changed)
    try await Task.sleep(for: .milliseconds(200))

    #expect(controller.currentSettings == changed)
    #expect(controller.selfTestReaderToggleCount == 2)
    try expectReaderPreviewIsVisibleAndColored(preview, settings: changed)
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
    try expectReaderPreviewIsVisibleAndColored(preview, settings: ReaderSettings())
}

@MainActor
private func expectReaderPreviewIsVisibleAndColored(
    _ preview: NSTextView,
    settings: ReaderSettings
) throws {
    let window = try #require(preview.window)
    let scroll = try #require(preview.enclosingScrollView)
    window.displayIfNeeded()
    #expect(abs(scroll.contentView.bounds.minX + scroll.contentView.contentInsets.left) < 0.5)
    if scroll.hasHorizontalScroller {
        #expect(abs(scroll.horizontalScroller?.doubleValue ?? 0) < 0.001)
    }
    #expect(abs(scroll.contentView.bounds.minY + scroll.contentView.contentInsets.top) < 0.5)

    let bitmap = try #require(scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds))
    scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
    let theme = ReaderTheme(settings: settings)
    let isDark = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    let colors = try [HighlightKind.keyword, .comment].map {
        let rgb = theme.rgb(for: $0, isDark: isDark)
        let color = try #require(NSColor(
            srgbRed: CGFloat((rgb >> 16) & 255) / 255,
            green: CGFloat((rgb >> 8) & 255) / 255,
            blue: CGFloat(rgb & 255) / 255,
            alpha: 1
        ).usingColorSpace(bitmap.colorSpace))
        return (color.redComponent, color.greenComponent, color.blueComponent)
    }
    var pixelCounts = [0, 0]
    for y in 0..<bitmap.pixelsHigh {
        for x in 0..<bitmap.pixelsWide {
            guard let pixel = bitmap.colorAt(x: x, y: y) else { continue }
            for index in colors.indices {
                let color = colors[index]
                if abs(pixel.redComponent - color.0) < 0.04,
                   abs(pixel.greenComponent - color.1) < 0.04,
                   abs(pixel.blueComponent - color.2) < 0.04 {
                    pixelCounts[index] += 1
                }
            }
        }
    }
    #expect(pixelCounts.allSatisfy { $0 >= 4 }, "Actual keyword/comment pixels: \(pixelCounts)")

    let ruler = try #require(scroll.verticalRulerView)
    let gutter = ruler.convert(ruler.bounds, to: scroll)
    let glyph = scroll.convert(window.convertFromScreen(preview.firstRect(
        forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil
    )), from: nil)
    let gap = glyph.minX - gutter.maxX
    #expect((8...12).contains(gap), "First preview glyph gap: \(gap)")
    print("SETTINGS_PREVIEW size=\(settings.fontSize) wrap=\(settings.wrapLines) "
        + "theme=\(settings.theme.rawValue) origin=\(scroll.contentView.bounds.origin) "
        + "gap=\(gap) keyword/comment pixels=\(pixelCounts)")
}

@MainActor
private func readerSettingsDescendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(readerSettingsDescendants)
}
