import AppKit
import CodeInsightCore
import CodeInsightReaderCore
@testable import CodeInsightReaderUI
import Foundation
import Testing

// The hover card rendering for Python and TypeScript docs: the same card the
// Rust acceptance drove with real mouse hovers, exercised here against the
// real AppKit hierarchy without screen capture permission (same approach as
// the ruler-bleed regression).

@MainActor
@Test
func symbolDocCardShowsTypeScriptHoverDocAndResolvesJSDocLinks() throws {
    _ = NSApplication.shared
    let doc = SymbolDoc(
        location: "store.ts:6",
        signature: "export function loadStore(id: number): Promise<Store>",
        signatureLanguage: "typescript",
        markdown: """
        Loads the store.

        See [Store](cairn-symbol:Store) and [the query method](cairn-symbol:Store#query).
        """,
        source: .exact
    )
    let card = SymbolDocCard()
    let parent = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    parent.contentView = NSView()
    card.show(
        doc,
        notes: [],
        anchor: NSRect(x: 200, y: 300, width: 80, height: 16),
        in: parent,
        theme: ReaderTheme(settings: ReaderSettings(theme: .dark))
    )
    withExtendedLifetime(parent) {
        #expect(card.isShown)
        let text = card.textContent
        #expect(text.contains("loadStore(id: number): Promise<Store>"))
        #expect(text.contains("Loads the store."))
        #expect(card.links.contains(URL(string: "cairn-symbol:Store")!))
        #expect(card.links.contains(URL(string: "cairn-symbol:Store#query")!))
    }
    card.hide()
}

@MainActor
@Test
func symbolDocCardWrapsLongSignaturesBetweenTokens() throws {
    _ = NSApplication.shared
    // typescript-language-server answers overloaded dependency functions
    // with one long line (sampled 2026-09-30 from @types/node).
    let signature = "readFileSync(path: PathOrFileDescriptor, options?: "
        + "ReadFileSyncOptionsWithBufferEncoding | null | undefined): Buffer "
        + "(+3 overloads)"
    let doc = SymbolDoc(
        signature: signature,
        signatureLanguage: "typescript",
        markdown: "Returns the contents of the `path`.",
        source: .exact
    )
    let card = SymbolDocCard()
    let parent = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    parent.contentView = NSView()
    card.show(
        doc,
        notes: [],
        anchor: NSRect(x: 200, y: 300, width: 80, height: 16),
        in: parent,
        theme: ReaderTheme(settings: ReaderSettings())
    )
    withExtendedLifetime(parent) {
        let signatureLines = card.renderedLines.prefix { !$0.contains("Returns the contents") }
        #expect(signatureLines.count > 1, "the signature should need wrapping: \(signatureLines)")
        // Every soft wrap falls between tokens: no line ends in the middle
        // of an identifier that the next line continues.
        for (line, next) in zip(signatureLines, signatureLines.dropFirst()) {
            let splitsWord = line.last.map { $0.isLetter || $0.isNumber } == true
                && next.first.map { $0.isLetter || $0.isNumber } == true
            #expect(!splitsWord, "wrapped inside a word: \(line.debugDescription) | \(next.debugDescription)")
        }
        #expect(signatureLines.joined() == signature + "\n")
    }
    card.hide()
}
