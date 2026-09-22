import AppKit
import CodeInsightReaderCore
import CodeInsightReaderUI
import Testing
@testable import CodeInsightApp

@MainActor
@Test
func readerLigatureSettingsShowControlsAndPreserveUnavailableFontIntent() async throws {
    _ = NSApplication.shared
    ReaderSettingsWindowController.selfTestEnableAccessibility()
    var settings = ReaderSettings()
    settings.codeFont = .postScriptName("Cairn-Unavailable-Fixture-Font")
    settings.codeLigatures = .disabled
    var commits = [ReaderSettings]()
    let controller = ReaderSettingsWindowController(
        settings: settings, trustModel: TrustListModel(), onRevoke: { _ in },
        onClearCache: { .cleared }, onChange: { commits.append($0) }
    )
    defer { controller.close() }
    controller.showWindow(nil)
    try await Task.sleep(for: .milliseconds(200))
    let elements = controller.selfTestReaderAccessibilityElements
    for identifier in ["codeFont", "codeLigatures", "resolvedCodeFont", "refreshCodeFonts"] {
        #expect(elements.contains { $0.accessibilityIdentifier?() == identifier })
    }
    let revision = ReaderFontResolver.shared.fontEnvironmentRevision
    #expect(controller.selfTestPressReaderControl("refreshCodeFonts"))
    try await Task.sleep(for: .milliseconds(100))
    #expect(ReaderFontResolver.shared.fontEnvironmentRevision > revision)
    #expect(controller.currentSettings == settings)
    #expect(commits.isEmpty)
    settings.codeLigatures = .fontDefault
    controller.update(settings: settings)
    try await Task.sleep(for: .milliseconds(100))
    #expect(commits.isEmpty)
    let content = try #require(controller.window?.contentView)
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let preview = try #require(descendants(content).compactMap { $0 as? NSTextView }.first)
    #expect(preview.string.contains("!= !== -> => <= >= ::"))
    #expect(preview.textStorage?.attribute(.ligature, at: 0, effectiveRange: nil) == nil)
    #expect(controller.currentSettings.codeFont == .postScriptName("Cairn-Unavailable-Fixture-Font"))
}
