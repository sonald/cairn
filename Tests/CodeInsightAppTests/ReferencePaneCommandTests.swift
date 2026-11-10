import AppKit
import CodeInsightAppModel
import CodeInsightCore
import CodeInsightReaderCore
import Foundation
import Testing
@testable import CodeInsightApp

@MainActor
private func referenceCommandWindow(
    _ files: [String: String]
) async throws -> (URL, AppModel, MainWindowController) {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ReferencePaneCommandTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for (path, contents) in files {
        try contents.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }
    let model = AppModel(indexService: ProjectIndexService())
    let controller = MainWindowController(model: model, settings: ReaderSettings(), offscreen: true)
    controller.openProject(root: root)
    try #require(await referenceCommandWaitUntil(model.snapshotPhase == .fullReady))
    return (root, model, controller)
}

@MainActor
private func referenceCommandWaitUntil(_ condition: @autoclosure () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(20)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// Caret commands read the pane that has the focus: with the reference pane
/// focused, the fold command folds there, not in the primary reader.
@MainActor
@Test(.timeLimit(.minutes(1)))
func foldCommandActsOnTheFocusedReferencePane() async throws {
    let (root, _, controller) = try await referenceCommandWindow([
        "main.rs": "// nothing to fold here\n",
        "other.rs": "fn other() {\n    let x = 1;\n}\n",
    ])
    defer {
        controller.close()
        try? FileManager.default.removeItem(at: root)
    }
    controller.openFileForSelfTest(root.appendingPathComponent("main.rs"))
    controller.openReference(root.appendingPathComponent("other.rs"), byteOffset: 0)
    try #require(controller.isReferenceActive)
    controller.selfTestFocusSecondaryReaderText()
    #expect(await referenceCommandWaitUntil(controller.canToggleFoldAtSelection))
    #expect(controller.toggleFoldAtSelection())
}

/// A Focus notice raised while render() navigates stays on the status bar
/// after that pass's own status refresh.
@MainActor
@Test(.timeLimit(.minutes(1)))
func focusNoticeRaisedDuringRenderStaysVisible() async throws {
    let source = "// top\nfn a() {\n    let x = 1;\n}\n"
    let (root, model, controller) = try await referenceCommandWindow(["main.rs": source])
    defer {
        controller.close()
        try? FileManager.default.removeItem(at: root)
    }
    controller.openFileForSelfTest(root.appendingPathComponent("main.rs"))
    let inside = UInt32(source.utf8.count - 8)
    controller.setReadingPositionForSelfTest(scrollByteOffset: 0, selectionByteOffset: inside)
    #expect(await referenceCommandWaitUntil(controller.toggleFocusCurrentScope()))
    let contentID = try #require(model.tabStrip.activeDocument?.contentID)
    // Navigates to the top comment, outside any scope: Focus ends.
    controller.openProjectSymbol(
        path: "main.rs", nameRange: ByteRange(lowerBound: 0, upperBound: 2),
        contentID: contentID, focusReader: false
    )
    #expect(controller.selfTestIndexStatusText.contains(localized("main.focus.ended.no.enclosing.scope")))
}

/// Jump to Type Definition reads the focused reference pane's caret, not the
/// primary tab's, and opens the type there.
@MainActor
@Test(.timeLimit(.minutes(1)))
func typeDefinitionCommandReadsTheFocusedReferenceCaret() async throws {
    let prefix = "pub struct S { pub n: u32 }\nfn f() {\n    let "
    let other = prefix + "s: S = S { n: 1 };\n    let _ = s;\n}\n"
    let (root, model, controller) = try await referenceCommandWindow([
        "main.rs": "// primary\n",
        "other.rs": other,
    ])
    defer {
        controller.close()
        try? FileManager.default.removeItem(at: root)
    }
    controller.openFileForSelfTest(root.appendingPathComponent("main.rs"))
    controller.openReference(root.appendingPathComponent("other.rs"), byteOffset: UInt32(prefix.utf8.count))
    try #require(controller.isReferenceActive)
    controller.selfTestFocusSecondaryReaderText()
    controller.jumpToTypeDefinitionAtCaret()
    let declaration = UInt32("pub struct ".utf8.count)
    #expect(await referenceCommandWaitUntil(model.referencePane?.byteOffset == declaration))
}
