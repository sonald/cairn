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
private func panelRGB(_ value: Any?) -> UInt32? {
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
private func stored<T>(_ name: String, of object: Any, as type: T.Type) -> T? {
    Mirror(reflecting: object).children.first { $0.label == name }?.value as? T
}

private struct PanelThemeIndexService: IndexService {
    func index(root: URL, language: LanguageID) async throws -> EngineSession {
        throw CocoaError(.featureUnsupported)
    }
}

@MainActor
@Test
func projectSearchHighlightsHitsAndLeadsGroupsWithTheFileName() throws {
    let panel = SearchPanel(appModel: AppModel(indexService: PanelThemeIndexService())) { _, _, _ in }
    panel.apply(settings: ReaderSettings(theme: .dark))
    let match = SearchMatch(
        pathID: PathID(rawValue: 1),
        byteRange: ByteRange(lowerBound: 13, upperBound: 16),
        line: 75,
        column: 5,
        lineText: "        self.ask(build_msg)",
        lineTextRange: ByteRange(lowerBound: 0, upperBound: 27)
    )
    let styled = panel.selfTestStyledMatch(match)
    let hit = (styled.string as NSString).range(of: "ask")
    #expect(hit.location != NSNotFound)
    #expect(panelRGB(styled.attribute(.backgroundColor, at: hit.location, effectiveRange: nil)) == 0x2E2F21)
    #expect(panelRGB(styled.attribute(.foregroundColor, at: hit.location, effectiveRange: nil)) == 0xE7E5DD)
    #expect(styled.attribute(.backgroundColor, at: hit.location - 1, effectiveRange: nil) == nil)
    // One row per match: indentation dropped, tail truncated instead of wrapping.
    #expect(styled.string == "   75  self.ask(build_msg)")
    let style = styled.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
    #expect(style?.lineBreakMode == .byTruncatingTail)
    let long = SearchMatch(
        pathID: PathID(rawValue: 2),
        byteRange: ByteRange(lowerBound: 4, upperBound: 8),
        line: 21,
        column: 5,
        lineText: "    REPL = \"\"\"" + String(repeating: "context you can access interactively ", count: 12),
        lineTextRange: ByteRange(lowerBound: 0, upperBound: 4 + 8 + 12 * 38)
    )
    let label = NSTextField(labelWithAttributedString: panel.selfTestStyledMatch(long))
    let height = try #require(label.cell).cellSize(forBounds: NSRect(x: 0, y: 0, width: 300, height: 1_000)).height
    #expect(height < 20)

    let group = panel.selfTestStyledGroup(path: "crates/knuth-agent/src/actor.rs", count: 2)
    #expect(group.string == "actor.rs  crates/knuth-agent/src  2")
    let nameFont = group.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    #expect(nameFont?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    #expect(panelRGB(group.attribute(.foregroundColor, at: 0, effectiveRange: nil)) == 0xE7E5DD)
    #expect(panelRGB(group.attribute(.foregroundColor, at: group.length - 1, effectiveRange: nil)) == 0x9BA29B)
}

@MainActor
@Test
func bookmarkStatusesUseSemanticThemeColors() {
    let panel = BookmarkPanel(
        appModel: AppModel(indexService: PanelThemeIndexService()),
        onOpen: { _ in },
        onLineOpen: { _, _ in }
    )
    panel.apply(settings: ReaderSettings(theme: .light))
    #expect(panelRGB(panel.statusColor(.exactContent)) == 0x2B5849)
    #expect(panelRGB(panel.statusColor(.drifted)) == 0x8A5610)
    #expect(panelRGB(panel.statusColor(.fileAbsent)) == 0x9B3D27)
    #expect(panelRGB(panel.statusColor(.revisionUnavailable)) == 0x9B3D27)
    #expect(panelRGB(panel.statusColor(.notEvaluated)) == 0x5C645F)
    #expect(panel.window?.appearance?.name == .aqua)
    #expect(panelRGB(panel.window?.backgroundColor) == 0xF3F1EB)
}

@MainActor
@Test
func mainWindowThemesSearchBookmarksAndCommitPickerOnCreationAndChange() throws {
    let suite = "PanelThemeTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let controller = MainWindowController(
        model: AppModel(indexService: PanelThemeIndexService()),
        settings: ReaderSettings(theme: .dark),
        offscreen: true,
        recentProjectsStore: RecentProjectsStore(defaults: defaults),
        recordsRecentProjects: false
    )
    defer { controller.close() }

    controller.showProjectSearch()
    controller.showBookmarks()
    _ = controller.selectCompareCommit("0000000")
    let search = try #require(stored("searchPanel", of: controller, as: SearchPanel?.self) ?? nil)
    let bookmarks = try #require(stored("bookmarkPanel", of: controller, as: BookmarkPanel?.self) ?? nil)
    let picker = try #require(stored("compareCommitPickerPopover", of: controller, as: CommitPickerPopover?.self) ?? nil)
    // Created after the window already uses Dark: each panel starts dark.
    #expect(search.selfTestTheme.selection == .dark)
    #expect(search.window?.appearance?.name == .darkAqua)
    #expect(panelRGB(bookmarks.window?.backgroundColor) == 0x161A18)
    #expect(picker.selfTestTheme.selection == .dark)

    controller.applyReaderSettings(ReaderSettings(theme: .siClassic))
    #expect(search.selfTestTheme.selection == .siClassic)
    #expect(panelRGB(search.window?.backgroundColor) == 0xEFEFEA)
    #expect(panelRGB(bookmarks.window?.backgroundColor) == 0xEFEFEA)
    #expect(picker.selfTestTheme.selection == .siClassic)
}
