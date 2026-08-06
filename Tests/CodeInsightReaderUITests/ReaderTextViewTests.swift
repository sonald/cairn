import AppKit
import CodeInsightReaderCore
import Foundation
import Testing
@testable import CodeInsightReaderUI

@MainActor
@Test
func structAndTraitDeclarationNamesUsePrimaryTypography() throws {
    let source = "struct Widget;\ntrait Work {}\n"
    let bytes = Array(source.utf8)
    let highlighted = try RustHighlighter().highlight(bytes: bytes)
    let attributed = attributedSource(source)
    let theme = ReaderTheme(settings: ReaderSettings())

    ReaderTextView.applyTypography(
        highlighted.spans,
        map: ByteUTF16Map(validUTF8: bytes),
        to: attributed,
        theme: theme
    )

    let expected = NSFont.monospacedSystemFont(
        ofSize: theme.functionNameFontSize,
        weight: .semibold
    )
    for name in ["Widget", "Work"] {
        let location = (source as NSString).range(of: name).location
        let font = try #require(
            attributed.attribute(.font, at: location, effectiveRange: nil) as? NSFont
        )
        #expect(font.fontName == expected.fontName)
        #expect(font.pointSize == expected.pointSize)
    }
}

@MainActor
@Test
func humanistCommentsKeepASCIIFiguresMonospaced() throws {
    let source = "// +---+\n// | A |\n// +---+\n"
    let bytes = Array(source.utf8)
    let highlighted = try RustHighlighter().highlight(bytes: bytes)
    let attributed = attributedSource(source)
    let theme = ReaderTheme(settings: ReaderSettings(humanistComments: true))

    ReaderTextView.applyTypography(
        highlighted.spans,
        map: ByteUTF16Map(validUTF8: bytes),
        to: attributed,
        theme: theme
    )

    let location = (source as NSString).range(of: "+---+").location
    let font = try #require(
        attributed.attribute(.font, at: location, effectiveRange: nil) as? NSFont
    )
    let expected = NSFont.monospacedSystemFont(
        ofSize: theme.fontSize,
        weight: .regular
    )
    #expect(font.fontName == expected.fontName)
}

@MainActor
@Test
func secondaryDeclarationsAreSemiboldWithoutScaling() throws {
    let source = "mod area {}\nconst LIMIT: usize = 3;\nstatic FLAG: bool = true;\n"
    let bytes = Array(source.utf8)
    let highlighted = try RustHighlighter().highlight(bytes: bytes)
    let attributed = attributedSource(source)
    let theme = ReaderTheme(settings: ReaderSettings())

    ReaderTextView.applyTypography(
        highlighted.spans,
        map: ByteUTF16Map(validUTF8: bytes),
        to: attributed,
        theme: theme
    )

    let expected = NSFont.monospacedSystemFont(
        ofSize: theme.fontSize,
        weight: .semibold
    )
    for name in ["area", "LIMIT", "FLAG"] {
        let location = (source as NSString).range(of: name).location
        let font = try #require(
            attributed.attribute(.font, at: location, effectiveRange: nil) as? NSFont
        )
        #expect(font.fontName == expected.fontName)
        #expect(abs(Double(font.pointSize) - theme.fontSize) < 0.001)
    }
}

@MainActor
@Test
func disabledSyntaxFormattingLeavesOnlyTheBaseFontMetrics() throws {
    let source = "struct Widget;\nfn greet() { // prose\n}\n"
    let bytes = Array(source.utf8)
    let highlighted = try RustHighlighter().highlight(bytes: bytes)
    let theme = ReaderTheme(settings: ReaderSettings(
        fontSize: 15,
        functionNameDelta: 3,
        syntaxFormatting: false,
        humanistComments: true
    ))
    let attributed = attributedSource(source, fontSize: theme.fontSize)

    ReaderTextView.applyTypography(
        highlighted.spans,
        map: ByteUTF16Map(validUTF8: bytes),
        to: attributed,
        theme: theme
    )

    var families: Set<String> = []
    var pointSizes: Set<CGFloat> = []
    var kerns: [Double] = []
    attributed.enumerateAttributes(
        in: NSRange(location: 0, length: attributed.length)
    ) { attributes, _, _ in
        if let font = attributes[.font] as? NSFont {
            families.insert(font.familyName ?? font.fontName)
            pointSizes.insert(font.pointSize)
        }
        kerns.append((attributes[.kern] as? NSNumber)?.doubleValue ?? 0)
    }

    #expect(families.count == 1)
    #expect(pointSizes == [CGFloat(theme.fontSize)])
    #expect(kerns.allSatisfy { $0 == 0 })
}

@MainActor
@Test
func clearThenApplySettingsKeepsStorageEmpty() throws {
    let reader = ReaderTextView()
    reader.display(document: try highlightedDocument())
    reader.setDiffMarkers([1: .changed])

    reader.clear()
    reader.apply(settings: ReaderSettings(theme: .siClassic))

    #expect(reader.view.textStorage?.length == 0)
    #expect(reader.displayedBytes == nil)
    #expect(reader.diffMarkerCounts.isEmpty)
    #expect(reader.view.textLayoutManager?.renderingAttributesValidator == nil)
}

@MainActor
@Test
func everyThemeAppliesTypographyWithinStorageBounds() throws {
    let document = try highlightedDocument()
    let reader = ReaderTextView()
    reader.display(document: document)
    let functionSpan = try #require(document.highlightSpans.first {
        $0.kind == .functionName
    })
    let functionRange = try #require(document.byteUTF16Map.nsRange(
        byteLowerBound: Int(functionSpan.range.lowerBound),
        byteUpperBound: Int(functionSpan.range.upperBound)
    ))
    let commentSpan = try #require(document.highlightSpans.first {
        $0.kind == .comment
    })
    let commentRange = try #require(document.byteUTF16Map.nsRange(
        byteLowerBound: Int(commentSpan.range.lowerBound),
        byteUpperBound: Int(commentSpan.range.upperBound)
    ))

    for theme in ReaderSettings.Theme.allCases {
        for humanistComments in [false, true] {
            let settings = ReaderSettings(
                theme: theme,
                humanistComments: humanistComments
            )
            reader.apply(settings: settings)
            let storage = try #require(reader.view.textStorage)
            let font = try #require(
                storage.attribute(.font, at: functionRange.location, effectiveRange: nil)
                    as? NSFont
            )
            let commentFont = try #require(
                storage.attribute(.font, at: commentRange.location, effectiveRange: nil)
                    as? NSFont
            )
            let expectedCommentFont = humanistComments
                ? NSFont.systemFont(ofSize: settings.fontSize)
                : NSFont.monospacedSystemFont(
                    ofSize: settings.fontSize,
                    weight: .regular
                )
            var fontRanges: [NSRange] = []
            storage.enumerateAttribute(
                .font,
                in: NSRange(location: 0, length: storage.length)
            ) { value, range, _ in
                if value != nil { fontRanges.append(range) }
            }

            #expect(abs(
                Double(font.pointSize) - settings.fontSize - settings.functionNameDelta
            ) < 0.001)
            #expect(commentFont.fontName == expectedCommentFont.fontName)
            #expect(!fontRanges.isEmpty)
            #expect(fontRanges.allSatisfy { NSMaxRange($0) <= storage.length })
        }
    }
}

@MainActor
@Test
func mismatchedStorageSkipsTypography() throws {
    let reader = ReaderTextView()
    reader.display(document: try highlightedDocument())
    let storage = try #require(reader.view.textStorage)
    storage.setAttributedString(NSAttributedString(string: ""))

    reader.apply(settings: ReaderSettings(theme: .siClassic))

    #expect(storage.length == 0)
    #expect(reader.view.textLayoutManager?.renderingAttributesValidator == nil)
}

@MainActor
@Test
func activationKeepsSelectionSemanticsButUsesThePrototypePrimaryStyle() throws {
    let source = "fn greet() { greet(); }\n"
    let bytes = Array(source.utf8)
    let highlighted = try RustHighlighter().highlight(bytes: bytes)
    let reader = ReaderTextView()
    reader.display(document: ReaderDocument(
        bytes: bytes,
        highlightSpans: highlighted.spans,
        outlineFacets: highlighted.outlineFacets
    ))

    let byteOffset = UInt32(try #require(source.range(of: "greet"))
        .lowerBound.utf16Offset(in: source))
    #expect(reader.activate(atByteOffset: byteOffset) == 2)
    #expect(reader.primarySelectionRange?.length == 5)
    #expect(reader.view.selectedRange().length == 5)
    let selectedBackground = try #require(
        reader.view.selectedTextAttributes[.backgroundColor] as? NSColor
    )
    #expect(selectedBackground.alphaComponent == 0)

    reader.clearOccurrences()
    #expect(reader.primarySelectionRange == nil)
    #expect(reader.view.selectedRange().length == 0)
    let restoredBackground = try #require(
        reader.view.selectedTextAttributes[.backgroundColor] as? NSColor
    )
    #expect(restoredBackground.alphaComponent > 0)
}

private func highlightedDocument() throws -> ReaderDocument {
    let bytes = Array("fn greet() { // hi\n}\n".utf8)
    let highlighted = try RustHighlighter().highlight(bytes: bytes)
    return ReaderDocument(
        bytes: bytes,
        highlightSpans: highlighted.spans,
        outlineFacets: highlighted.outlineFacets
    )
}

private func attributedSource(
    _ source: String,
    fontSize: Double = 13
) -> NSMutableAttributedString {
    NSMutableAttributedString(
        string: source,
        attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
        ]
    )
}
