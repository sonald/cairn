import AppKit
import CodeInsightReaderCore
import Foundation
import Testing

@testable import CodeInsightApp

/// Reader wrap v2 · S1 menu-level coverage (design D1.1, W01/W02/W03):
/// the Wrap Lines command is an application-level reading preference, so it
/// must stay usable when the Settings window is key (no project command
/// target), its checkmark and the persisted value must round-trip, and the
/// Settings form must reflect the same global state.
@MainActor
@Test
func wrapLinesMenuCommandIsGlobalRoundTripsAndSyncsSettings() throws {
    let delegate = AppDelegate(startedAt: .now)
    let defaults = UserDefaults.standard
    let original = defaults.object(forKey: "reader.wrapLines")
    defer {
        if let original {
            defaults.set(original, forKey: "reader.wrapLines")
        } else {
            defaults.removeObject(forKey: "reader.wrapLines")
        }
        delegate.settingsWindowController?.close()
    }

    // W02: with the Settings window as the only key window there is no
    // project command target, yet the wrap command must stay enabled.
    delegate.showSettings(nil)
    #expect(delegate.projectCommandTarget() == nil)

    let menu = delegate.makeMainMenu()
    // Top-level items carry their submenu's title (the app's own self-tests
    // resolve the View menu through the submenu list, not item(withTitle:)).
    let viewMenu = try #require(
        menu.items.compactMap(\.submenu).first { $0.title == "View" }
    )
    let item = try #require(viewMenu.item(withTitle: "Wrap Lines"))
    // Decision C1: ⌥Z, not ⌘Z (which belongs to undo).
    #expect(item.keyEquivalent == "z")
    #expect(item.keyEquivalentModifierMask == .option)
    #expect(item.target == nil || item.target === delegate)

    #expect(delegate.validateMenuItem(item))
    let initial = delegate.settingsWindowController?.currentSettings.wrapLines ?? false
    #expect(item.state == (initial ? .on : .off))

    // W01/W03: perform the action and verify every surface agrees — the
    // checkmark, the Settings form value, and the persisted default.
    delegate.perform(NSSelectorFromString("toggleWrapLines:"), with: nil)
    let toggled = !initial
    #expect(defaults.bool(forKey: "reader.wrapLines") == toggled)
    _ = delegate.validateMenuItem(item)
    #expect(item.state == (toggled ? .on : .off))
    #expect(delegate.settingsWindowController?.currentSettings.wrapLines == toggled)

    // Round-trip back so repeated runs are stable.
    delegate.perform(NSSelectorFromString("toggleWrapLines:"), with: nil)
    #expect(defaults.bool(forKey: "reader.wrapLines") == initial)
    _ = delegate.validateMenuItem(item)
    #expect(item.state == (initial ? .on : .off))

    // The persisted value survives a fresh settings instance (W03).
    let reloaded = ReaderSettings(defaults: defaults)
    #expect(reloaded.wrapLines == initial)
}

/// W02 companion: other project-scoped reading commands do require a target,
/// so the wrap command's independence is a deliberate exception, not a
/// validation leak.
@MainActor
@Test
func wrapLinesMenuCommandDoesNotEnableOtherProjectCommands() throws {
    let delegate = AppDelegate(startedAt: .now)
    delegate.showSettings(nil)
    defer { delegate.settingsWindowController?.close() }
    #expect(delegate.projectCommandTarget() == nil)
    for action in [
        "useFullReadingHeight:", "useStructureReadingHeight:",
        "useOverviewReadingHeight:", "toggleFold:",
    ] {
        let item = NSMenuItem(
            title: action,
            action: NSSelectorFromString(action),
            keyEquivalent: ""
        )
        #expect(!delegate.validateMenuItem(item), "\(action) must require a target")
    }
    let wrapItem = NSMenuItem(
        title: "Wrap Lines",
        action: NSSelectorFromString("toggleWrapLines:"),
        keyEquivalent: ""
    )
    #expect(delegate.validateMenuItem(wrapItem))
}
