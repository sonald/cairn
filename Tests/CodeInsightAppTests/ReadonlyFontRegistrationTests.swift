import AppKit
import CodeInsightExact
import CodeInsightReaderCore
import CodeInsightReaderUI
import CoreText
import CryptoKit
import Foundation
import Testing
@testable import CodeInsightApp
@testable import CodeInsightAppModel

/// Core Text process registration is global to this test process. Run this suite
/// alone with --no-parallel; no persistent/session font registration is used.
@Suite(.serialized)
@MainActor
struct ReadonlyFontRegistrationTests {
    @Test(.timeLimit(.minutes(2)))
    func readonlyFontProcessReplacementChangesRealFontWithoutChangingReaderSource() async throws {
        _ = NSApplication.shared
        let name = "CairnReadonlyV06Synthetic-Regular"
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/readonly/fonts", isDirectory: true)
        let a = fixtures.appendingPathComponent("CairnReadonlyV06-A.ttf")
        let b = fixtures.appendingPathComponent("CairnReadonlyV06-B.ttf")
        try #require(NSFont(name: name, size: 13) == nil, "Fixture font already registered; use an isolated test process")
        let originalArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = originalArguments
        arguments["reader.codeFont.kind"] = "postScriptName"
        arguments["reader.codeFont.postScriptName"] = name
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain) }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReadonlyFontRegistration-\(UUID().uuidString)")
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = "pub fn value() -> usize { 42 }\n"
        let file = project.appendingPathComponent("main.rs")
        try source.write(to: file, atomically: true, encoding: .utf8)
        let suite = "ReadonlyFontRegistration-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recent = RecentProjectsStore(defaults: defaults)
        let model = AppModel(sessionURL: root.appendingPathComponent("session.json"), recentProjectsStore: recent)
        let delegate = AppDelegate(startedAt: .now, model: model, recentProjectsStore: recent,
                                   windowSessionURL: root.appendingPathComponent("session.json"),
                                   sharedTrustRegistry: TrustRegistry(fileURL: root.appendingPathComponent("trust.json")),
                                   sharedMaterializer: Materializer(rootURL: root.appendingPathComponent("cache")))
        var registeredA = false, registeredB = false
        defer {
            // Any unsuccessful cleanup is reported; process scope never survives exit.
            if registeredB { readonlyFontCleanup(b) }
            if registeredA { readonlyFontCleanup(a) }
        }
        var evidence: [String: Any] = ["status": "started", "scope": "process", "postScriptName": name]
        let initialRevision = ReaderFontResolver.shared.fontEnvironmentRevision
        let registrationA = readonlyRegisterFont(a)
        evidence["registerA"] = registrationA.message
        registeredA = registrationA.success
        if !registeredA {
            evidence["status"] = "blocked-registration-A"
            try readonlyWriteFontEvidence(evidence, name: "process-registration")
        }
        try #require(registeredA, "BLOCKED: \(registrationA.message)")
        // The real Core Text local notification must reach AppDelegate; never call refresh().
        try #require(await readonlyFontWait { ReaderFontResolver.shared.fontEnvironmentRevision > initialRevision },
                     "Core Text registration did not automatically refresh AppDelegate")
        delegate.selfTestLaunchOffscreen()
        let controller = try #require(delegate.selfTestProjectWindow(0))
        defer { controller.close() }
        controller.openProject(root: project)
        try #require(await readonlyFontWait { model.snapshotPhase == .fullReady })
        controller.openFileForSelfTest(file)
        try #require(await readonlyFontWait { controller.selfTestLeftReaderBytes == Array(source.utf8) })
        let content = try #require(controller.window?.contentView)
        let view = try #require(readonlyFontTextViews(content).first { $0.string == source })
        let rootController = try #require(controller.window?.contentViewController)
        let reader = try #require(readonlyFontReaders(rootController).first { view.isDescendant(of: $0.view) })
        if ProcessInfo.processInfo.environment["CAIRN_READONLY_SURFACE_EVIDENCE_DIR"] != nil {
            controller.window?.center()
            controller.window?.makeKeyAndOrderFront(nil)
        }
        let before = try #require(readonlyFontFacts(view))
        #expect(before.name == name)
        #expect(before.url == a.resolvingSymlinksInPath().path)
        let selection = (source as NSString).range(of: "value")
        view.setSelectedRanges([NSValue(range: selection)], affinity: .upstream, stillSelecting: false)
        let selectedRanges = view.selectedRanges
        let affinity = view.selectionAffinity
        try readonlyCaptureSurfaceEvidence("font-registration-before", textView: view,
            expectedSource: source, drawCount: { reader.selfTestReaderDrawCount })
        evidence["before"] = ["name": before.name, "url": before.url,
                              "hmtxSHA256": before.table, "advance": before.advance]
        let unregisterA = readonlyUnregisterFont(a)
        evidence["unregisterA"] = unregisterA.message
        if !unregisterA.success {
            evidence["status"] = "blocked-unregister-A"
            try readonlyWriteFontEvidence(evidence, name: "process-registration")
        }
        // InUse (202), for example, is a real limitation, never a passing replacement.
        try #require(unregisterA.success, "BLOCKED: \(unregisterA.message)")
        registeredA = false
        let replacementRevision = ReaderFontResolver.shared.fontEnvironmentRevision
        let registrationB = readonlyRegisterFont(b)
        evidence["registerB"] = registrationB.message
        registeredB = registrationB.success
        if !registeredB {
            evidence["status"] = "blocked-registration-B"
            try readonlyWriteFontEvidence(evidence, name: "process-registration")
        }
        try #require(registeredB, "BLOCKED: \(registrationB.message)")
        try #require(await readonlyFontWait {
            guard ReaderFontResolver.shared.fontEnvironmentRevision > replacementRevision,
                  let current = readonlyFontFacts(view) else { return false }
            return current.name == name && current.table != before.table && current.url != before.url
        }, "Same-name registration did not update the actual Reader font; revision alone is insufficient")
        view.textLayoutManager?.textViewportLayoutController.layoutViewport()
        controller.window?.displayIfNeeded()
        let after = try #require(readonlyFontFacts(view))
        #expect(after.name == before.name)
        #expect(after.url == b.resolvingSymlinksInPath().path)
        #expect(after.table != before.table)
        #expect(after.advance > before.advance)
        #expect(view.string == source)
        #expect(view.selectedRanges == selectedRanges)
        #expect(view.selectionAffinity == affinity)
        try readonlyCaptureSurfaceEvidence("font-registration-after", textView: view,
            expectedSource: source, drawCount: { reader.selfTestReaderDrawCount })
        evidence["after"] = ["name": after.name, "url": after.url, "hmtxSHA256": after.table, "advance": after.advance]
        evidence["status"] = "replacement-observed"
        evidence["sourceUnchanged"] = view.string == source
        evidence["selectionUnchanged"] = view.selectedRanges == selectedRanges && view.selectionAffinity == affinity
        try readonlyWriteFontEvidence(evidence, name: "process-registration")
    }

    @Test(.timeLimit(.minutes(1)))
    func readonlyFontDistributedNotificationRoutesToAppDelegateWithoutInstallingFonts() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReadonlyFontRouting-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let delegate = AppDelegate(startedAt: .now, windowSessionURL: root.appendingPathComponent("session.json"),
                                   sharedTrustRegistry: TrustRegistry(fileURL: root.appendingPathComponent("trust.json")),
                                   sharedMaterializer: Materializer(rootURL: root.appendingPathComponent("cache")))
        let before = ReaderFontResolver.shared.fontEnvironmentRevision
        // Controlled distributed-center routing only, NOT a simulated font-replacement PASS.
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(kCTFontManagerRegisteredFontsChangedNotification as String),
            object: "CairnReadonlyFontRouting-\(UUID().uuidString)", userInfo: nil, deliverImmediately: true)
        try #require(await readonlyFontWait { ReaderFontResolver.shared.fontEnvironmentRevision > before },
                     "Distributed Core Text notification did not reach the existing AppDelegate handler")
        withExtendedLifetime(delegate) {}
        try readonlyWriteFontEvidence(["status": "routing-observed", "scope": "distributed-notification-only",
                                       "actualSystemFontInstallation": false], name: "distributed-routing")
    }
}

private func readonlyRegisterFont(_ url: URL) -> (success: Bool, message: String) {
    var error: Unmanaged<CFError>?
    let result = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
    return (result, error.map { String(describing: $0.takeRetainedValue()) } ?? "registered")
}

private func readonlyUnregisterFont(_ url: URL) -> (success: Bool, message: String) {
    var error: Unmanaged<CFError>?
    let result = CTFontManagerUnregisterFontsForURL(url as CFURL, .process, &error)
    return (result, error.map { String(describing: $0.takeRetainedValue()) } ?? "unregistered")
}

private func readonlyFontCleanup(_ url: URL) {
    let result = readonlyUnregisterFont(url)
    if !result.success { print("FONT_REGISTRATION_CLEANUP: \(result.message); scope ends with this process") }
}

@MainActor
private func readonlyFontFacts(_ view: NSTextView) -> (name: String, url: String, table: String, advance: Double)? {
    guard let storage = view.textStorage, storage.length > 0,
          let font = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont,
          let url = CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL,
          let table = CTFontCopyTable(font, CTFontTableTag(0x686D7478), CTFontTableOptions(rawValue: 0)) else { return nil }
    var character: UniChar = 77
    var glyph: CGGlyph = 0
    guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1) else { return nil }
    var advance = CGSize.zero
    CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
    let tableDigest = SHA256.hash(data: table as Data).map { String(format: "%02x", $0) }.joined()
    return (font.fontName, url.resolvingSymlinksInPath().path, tableDigest, Double(advance.width))
}

@MainActor
private func readonlyFontTextViews(_ view: NSView) -> [NSTextView] {
    (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(readonlyFontTextViews)
}

@MainActor
private func readonlyFontReaders(_ controller: NSViewController) -> [ReaderViewController] {
    (controller as? ReaderViewController).map { [$0] }
        ?? controller.children.flatMap(readonlyFontReaders)
}

@MainActor
private func readonlyFontWait(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(15)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        readonlyFontRunLoopTurn()
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@MainActor
private func readonlyFontRunLoopTurn() {
    // Distributed/Core Text notifications may require the native run loop, not just a queued Task.
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
}

private func readonlyWriteFontEvidence(_ value: [String: Any], name: String) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    print("FONT_REGISTRATION_EVIDENCE \(name): \(String(decoding: data, as: UTF8.self))")
    if let path = ProcessInfo.processInfo.environment["CAIRN_READONLY_FONT_EVIDENCE_DIR"] {
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name + ".json"), options: .atomic)
    }
}
