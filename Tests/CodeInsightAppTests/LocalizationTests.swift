import AppKit
import Foundation
import Testing
@testable import CodeInsightApp

@MainActor
@Test
func localizationResourcesResolveBothLanguagesWithoutChangingMenuCommands() throws {
    let entries = [
        ("welcome.open", "Open Project", "打开项目"),
        ("settings.title", "Settings", "设置"),
        ("relation.callers", "Callers", "调用方"),
        ("app.menu.open.project", "Open Project…", "打开项目…"),
        ("app.menu.settings", "Settings…", "设置…"),
        ("app.menu.wrap.lines", "Wrap Lines", "自动换行"),
    ]
    for language in ["en", "zh-Hans"] {
        let resources = try #require(Bundle.module.resourceURL)
        let path = resources.appendingPathComponent("\(language).lproj").path
        let bundle = try #require(Bundle(path: path))
        for (key, english, chinese) in entries {
            #expect(NSLocalizedString(key, bundle: bundle, comment: "")
                == (language == "en" ? english : chinese))
        }
        // Exercise Foundation's real stringsdict selection and formatting, not
        // a hand-written singular/plural selector or the source plist alone.
        for count: Int64 in [0, 1, 2] {
            let bookmarkFormat = NSLocalizedString(
                "panel.bookmark.count", bundle: bundle, comment: ""
            )
            let bookmarkCount = String(
                format: bookmarkFormat, locale: Locale(identifier: language), arguments: [count]
            )
            let expectedBookmarks = language == "en"
                ? "\(count) \(count == 1 ? "bookmark" : "bookmarks")" : "\(count) 个书签"
            #expect(bookmarkCount == expectedBookmarks)
            let indexingFormat = NSLocalizedString(
                "main.indexing.files", bundle: bundle, comment: ""
            )
            let indexingCount = String(
                format: indexingFormat, locale: Locale(identifier: language), arguments: [count]
            )
            let expectedIndexing = language == "en"
                ? "Indexing \(count) \(count == 1 ? "file" : "files")…" : "正在索引 \(count) 个文件…"
            #expect(indexingCount == expectedIndexing)
        }
    }

    // Region language must not select a different plural rule from the UI.
    let expectedOne = Bundle.module.preferredLocalizations.first == "zh-Hans"
        ? "1 处匹配" : "1 match"
    #expect(localizedFormat("panel.search.matches", 1) == expectedOne)

    _ = NSApplication.shared
    let delegate = AppDelegate(startedAt: .now)
    func descendants(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in [item] + (item.submenu.map(descendants) ?? []) }
    }
    let items = descendants(delegate.makeMainMenu())
    let commands: [(String, String, String, NSEvent.ModifierFlags)] = [
        ("openProject:", "app.menu.open.project", "o", .command),
        ("showSettings:", "app.menu.settings", ",", .command),
        ("findInProject:", "app.menu.find.in.project", "f", [.command, .shift]),
        ("showCallers:", "app.menu.show.callers", "h", [.command, .shift]),
        ("toggleWrapLines:", "app.menu.wrap.lines", "z", .option),
    ]
    for (selector, key, shortcut, modifiers) in commands {
        let matches = items.filter { $0.action == NSSelectorFromString(selector) }
        #expect(matches.count == 1)
        let item = try #require(matches.first)
        #expect(item.title == localized(key))
        #expect(item.keyEquivalent == shortcut)
        #expect(item.keyEquivalentModifierMask == modifiers)
        #expect(item.target === delegate)
    }
}
