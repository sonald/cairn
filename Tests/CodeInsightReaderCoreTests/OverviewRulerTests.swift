@preconcurrency import AppKit
import CodeInsightCore
import CodeInsightReaderCore
import Foundation
import Testing
@testable import CodeInsightReaderUI

/// Marks a fold hides gather on the fold's own display line, drawn hollow;
/// going to one opens the fold so the mark is back on its own line.
@MainActor @Test
func overviewMarksInsideAFoldSitOnItsLineUntilRevealed() async throws {
    _ = NSApplication.shared
    let body = (0..<12).map { "    let v\($0) = target + \($0);" }.joined(separator: "\n")
    let source = "fn first(target: i32) {\n\(body)\n}\n\nfn second(target: i32) -> i32 {\n    target\n}\n"
    let document = try DocumentLoader(source: { _ in Array(source.utf8) })
        .load(file: URL(fileURLWithPath: "/overview.rs")).document
    let reader = ReaderTextView()
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
    scroll.documentView = reader.view
    reader.view.frame = scroll.contentView.bounds
    let window = NSWindow(contentRect: scroll.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentView = scroll
    reader.display(document: document)
    reader.configureGutter(in: scroll, lineNumbers: true)
    await reader.waitForIdentifierPreparation()
    reader.setHighlightedNames(["target": 1])

    let open = reader.overviewContent().content
    #expect(open.lineCount == 19)
    #expect(open.marks.count == 15 && open.marks.allSatisfy { !$0.folded })

    #expect(reader.toggleFold(atLine: 1))
    let folded = reader.overviewContent().content
    #expect(folded.lineCount == 6, "the fold folds its 13 line breaks into the header line")
    let hidden = folded.marks.filter(\.folded)
    #expect(hidden.count == 12 && hidden.allSatisfy { $0.line == 0 })
    #expect(folded.marks.filter { !$0.folded }.map(\.line) == [0, 2, 3], "parameters and the open function keep their lines")

    reader.reveal(byteOffset: try #require(hidden.last).byteOffset)
    let reopened = reader.overviewContent().content
    #expect(reopened.lineCount == 19)
    #expect(reopened.marks.allSatisfy { !$0.folded })
}
