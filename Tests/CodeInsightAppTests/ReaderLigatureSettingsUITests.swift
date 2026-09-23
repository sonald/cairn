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

    // Variable-font faces can share a displayName. The actual native picker
    // must still distinguish the selected PostScript identities.
    let available = (NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? [])
        .filter { NSFont(name: $0, size: 13) != nil }
    let groups = Dictionary(grouping: available) { NSFont(name: $0, size: 13)?.displayName ?? $0 }
    let names = groups.values.first(where: { $0.count > 1 })?.sorted().prefix(2)
        ?? ["Menlo-Regular", "Menlo-Bold"].prefix(2)
    var labels: [String] = []
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    for name in names {
        settings.codeFont = .postScriptName(name)
        controller.update(settings: settings)
        try await Task.sleep(for: .milliseconds(100))
        let picker = try #require(controller.selfTestReaderAccessibilityElements.first {
            $0.accessibilityIdentifier?() == "codeFont"
        })
        let value: Any? = picker.accessibilityValue?()
        let label = try #require(value as? String)
        let displayName = NSFont(name: name, size: 13)?.displayName ?? name
        let expected = (groups[displayName]?.count ?? 0) > 1 ? name : displayName
        #expect(label == expected)
        #expect(controller.currentSettings.codeFont == .postScriptName(name))
        labels.append(label)
        let operatorRange = (preview.string as NSString).range(of: "!==")
        try #require(operatorRange.location != NSNotFound)
        preview.setSelectedRange(NSRange(location: operatorRange.location + 1, length: 2))
        pasteboard.declareTypes([.string], owner: nil)
        #expect(preview.writeSelection(to: pasteboard, type: .string))
        #expect(pasteboard.string(forType: .string) == "==")
    }
    #expect(Set(labels).count == 2)
    #expect(commits.isEmpty)

}
