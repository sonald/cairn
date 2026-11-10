@preconcurrency import AppKit
import CodeInsightReaderCore

/// Colors code-like excerpts with the reader's syntax palette.
@MainActor
package enum CodeTextPreviewStyler {
    /// Colors spans over an attributed string whose UTF-16 offsets start at
    /// `offset`; `emphasisFont` marks section headers.
    package static func apply(
        _ spans: [TextFormatSpan],
        to string: NSMutableAttributedString,
        offset: Int = 0,
        theme: ReaderTheme,
        emphasisFont: NSFont?
    ) {
        guard !spans.isEmpty else { return }
        var colors: [HighlightKind: NSColor] = [:]
        let characters = string.string as NSString
        let holeColor = theme.chromeHeaderColor
        var holeStart: Int?
        string.beginEditing()
        for span in spans {
            let range = NSRange(location: offset + span.range.lowerBound, length: span.range.count)
            guard NSMaxRange(range) <= string.length else { continue }
            // Template holes (`{{ }}`, `{% %}`) read as chips within prose.
            if span.kind == .macro, range.length > 0 {
                if characters.character(at: range.location) == 0x7B {
                    holeStart = range.location
                } else if let start = holeStart, characters.character(at: NSMaxRange(range) - 1) == 0x7D {
                    string.addAttribute(.backgroundColor, value: holeColor,
                                        range: NSRange(location: start, length: NSMaxRange(range) - start))
                    holeStart = nil
                }
            }
            let color = colors[span.kind] ?? theme.color(for: span.kind)
            colors[span.kind] = color
            string.addAttribute(.foregroundColor, value: color, range: range)
            if span.kind == .declarationTitle, let emphasisFont {
                string.addAttribute(.font, value: emphasisFont, range: range)
            }
        }
        string.endEditing()
    }
}

/// A TextKit 1 view (text blocks and tables need it) that centers a
/// readable column instead of stretching prose across wide windows.
///
/// Headings fold their section, up to the next heading of the same or a
/// higher level. The view keeps the whole rendered document and shows it
/// without folded sections; selection, copy and anchors map back to it.
/// (Hiding glyphs instead breaks text blocks: hidden line breaks no longer
/// break lines, so the next heading lands inside the folded block.)
@MainActor
package final class MarkdownPreviewTextView: NSTextView {
    package static let readableWidth: CGFloat = 780
    package static let minimumInset: CGFloat = 28

    /// The whole rendered document; the storage shows it minus `foldedSections`.
    package private(set) var document = NSAttributedString()
    /// Folded headings, by where their paragraph starts in `document`.
    package private(set) var foldedHeadings: Set<Int> = []
    /// Folded sections in `document`, sorted and disjoint.
    private var foldedSections: [NSRange] = []
    private var hoveredHeading: Int?
    private var hoverArea: NSTrackingArea?

    package convenience init() {
        self.init(usingTextLayoutManager: false)
    }

    override package func setFrameSize(_ newSize: NSSize) {
        let horizontal = max(Self.minimumInset, (newSize.width - Self.readableWidth) / 2)
        if abs(textContainerInset.width - horizontal) > 0.5 {
            textContainerInset = NSSize(width: horizontal, height: 28)
        }
        super.setFrameSize(newSize)
    }

    /// Shows a rendered document; a restyle of the same text keeps folds
    /// and selection.
    package func show(_ attributed: NSAttributedString) {
        let restyle = attributed.string == document.string
        let selection = restyle ? selectedRanges.map { documentRange(of: $0.rangeValue) } : []
        if !restyle { foldedHeadings = [] }
        document = attributed
        refold(selecting: selection)
    }

    /// The heading whose section holds the shown character `index`.
    package func heading(containing index: Int) -> Int? {
        let location = min(documentIndex(of: index, afterFold: false), document.length - 1)
        guard location >= 0 else { return nil }
        var found: Int?
        document.enumerateAttribute(.markdownHeadingLevel, in: NSRange(location: 0, length: location + 1),
                                    options: .reverse) { value, range, stop in
            // A caret at a fold point belongs to the folded heading, not to
            // a heading hidden inside its section.
            guard value != nil, !foldedSections.contains(where: { NSLocationInRange(range.location, $0) })
            else { return }
            found = paragraphStart(range.location)
            stop.pointee = true
        }
        return found
    }

    @discardableResult
    package func toggleHeadingFold(at start: Int) -> Bool {
        guard let section = sectionRange(ofHeadingAt: start), section.length > 0 else { return false }
        if foldedHeadings.remove(start) == nil { foldedHeadings.insert(start) }
        refold(selecting: selectedRanges.map { documentRange(of: $0.rangeValue) })
        return true
    }

    /// Unfolds what hides the heading `fragment` names and returns its shown
    /// range.
    package func revealAnchor(_ fragment: String) -> NSRange? {
        guard let range = MarkdownPreviewRenderer.anchorRange(for: fragment, in: document) else { return nil }
        let hiding = foldedHeadings.filter { sectionRange(ofHeadingAt: $0).map { NSLocationInRange(range.location, $0) } ?? false }
        if !hiding.isEmpty {
            foldedHeadings.subtract(hiding)
            refold(selecting: selectedRanges.map { documentRange(of: $0.rangeValue) })
        }
        return shownRange(of: range)
    }

    /// Copy takes folded sections inside the selection from the document.
    override package func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard !foldedSections.isEmpty else { return super.writeSelection(to: pboard, types: types) }
        let text = NSMutableAttributedString()
        for value in selectedRanges where value.rangeValue.length > 0 {
            if text.length > 0 { text.append(NSAttributedString(string: "\n")) }
            text.append(document.attributedSubstring(from: documentRange(of: value.rangeValue)))
        }
        guard text.length > 0 else { return false }
        pboard.clearContents()
        if let rtf = text.rtf(from: NSRange(location: 0, length: text.length)) {
            pboard.setData(rtf, forType: .rtf)
        }
        return pboard.setString(text.string, forType: .string)
    }

    private func refold(selecting selection: [NSRange]) {
        var merged: [NSRange] = []
        for range in foldedHeadings.compactMap(sectionRange(ofHeadingAt:)).sorted(by: { $0.location < $1.location }) {
            if let last = merged.last, range.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else {
                merged.append(range)
            }
        }
        foldedSections = merged
        let shown = NSMutableAttributedString(attributedString: document)
        for range in foldedSections.reversed() { shown.deleteCharacters(in: range) }
        textStorage?.setAttributedString(shown)
        let ranges = selection.map { NSValue(range: shownRange(of: $0)) }
        if !ranges.isEmpty { setSelectedRanges(ranges, affinity: .downstream, stillSelecting: false) }
        needsDisplay = true
    }

    /// Text after the heading's paragraph, up to the next heading of the
    /// same or a higher level.
    private func sectionRange(ofHeadingAt start: Int) -> NSRange? {
        guard start < document.length,
              let level = document.attribute(.markdownHeadingLevel, at: start, effectiveRange: nil) as? Int
        else { return nil }
        let body = NSMaxRange((document.string as NSString).paragraphRange(for: NSRange(location: start, length: 0)))
        var end = document.length
        document.enumerateAttribute(.markdownHeadingLevel,
                                    in: NSRange(location: body, length: document.length - body)) { value, range, stop in
            guard let next = value as? Int, next <= level else { return }
            end = paragraphStart(range.location)
            stop.pointee = true
        }
        return NSRange(location: body, length: end - body)
    }

    private func paragraphStart(_ index: Int) -> Int {
        (document.string as NSString).paragraphRange(for: NSRange(location: index, length: 0)).location
    }

    /// A document index shown at `index`; at a fold point, `afterFold`
    /// picks the end of the folded section rather than its start.
    private func documentIndex(of index: Int, afterFold: Bool) -> Int {
        var result = index
        for range in foldedSections {
            guard range.location < result || (afterFold && range.location == result) else { break }
            result += range.length
        }
        return result
    }

    private func documentRange(of range: NSRange) -> NSRange {
        let lower = documentIndex(of: range.location, afterFold: false)
        let upper = range.length == 0 ? lower : documentIndex(of: NSMaxRange(range), afterFold: true)
        return NSRange(location: lower, length: upper - lower)
    }

    /// Where a document index shows; folded text collapses to its fold point.
    private func shownIndex(of index: Int) -> Int {
        var removed = 0
        for range in foldedSections {
            if NSMaxRange(range) <= index {
                removed += range.length
            } else {
                if range.location < index { removed += index - range.location }
                break
            }
        }
        return index - removed
    }

    private func shownRange(of range: NSRange) -> NSRange {
        let lower = shownIndex(of: range.location)
        return NSRange(location: lower, length: shownIndex(of: NSMaxRange(range)) - lower)
    }

    // MARK: Fold chevrons in the left margin

    /// The heading whose first line holds `y`, with that line's rect.
    func headingLine(atY y: CGFloat) -> (start: Int, rect: NSRect)? {
        guard let layoutManager, let textContainer, layoutManager.numberOfGlyphs > 0 else { return nil }
        let point = NSPoint(x: 0, y: y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: point, in: textContainer)
        let line = layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        let index = documentIndex(of: layoutManager.characterIndexForGlyph(at: glyph), afterFold: true)
        guard line.minY <= point.y, point.y < line.maxY, index < document.length,
              document.attribute(.markdownHeadingLevel, at: index, effectiveRange: nil) != nil
        else { return nil }
        let start = paragraphStart(index)
        guard let rect = firstLineRect(ofHeadingAt: start), rect.minY == line.minY + textContainerOrigin.y
        else { return nil }
        return (start, rect)
    }

    func firstLineRect(ofHeadingAt start: Int) -> NSRect? {
        guard let layoutManager, let storage = textStorage,
              !foldedSections.contains(where: { NSLocationInRange(start, $0) }) else { return nil }
        let shown = shownIndex(of: start)
        guard shown < storage.length else { return nil }
        return layoutManager.lineFragmentUsedRect(
            forGlyphAt: layoutManager.glyphIndexForCharacter(at: shown), effectiveRange: nil
        ).offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    private func chevronRect(for line: NSRect) -> NSRect {
        NSRect(x: textContainerOrigin.x - 20, y: line.midY - 7, width: 14, height: 14)
    }

    /// Chevrons sit in the margin, under no text, so the background pass
    /// draws them.
    override package func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        var starts = foldedHeadings
        if let hoveredHeading { starts.insert(hoveredHeading) }
        for start in starts {
            guard let line = firstLineRect(ofHeadingAt: start) else { continue }
            let rect = chevronRect(for: line)
            guard rect.intersects(dirtyRect) else { continue }
            let collapsed = foldedHeadings.contains(start)
            let path = NSBezierPath()
            path.lineWidth = 1.4
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            if collapsed {
                path.move(to: NSPoint(x: rect.midX - 2, y: rect.midY - 3))
                path.line(to: NSPoint(x: rect.midX + 2, y: rect.midY))
                path.line(to: NSPoint(x: rect.midX - 2, y: rect.midY + 3))
            } else {
                path.move(to: NSPoint(x: rect.midX - 3, y: rect.midY - 2))
                path.line(to: NSPoint(x: rect.midX, y: rect.midY + 2))
                path.line(to: NSPoint(x: rect.midX + 3, y: rect.midY - 2))
            }
            (collapsed ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor).setStroke()
            path.stroke()
        }
    }

    override package func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override package func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let next = headingLine(atY: convert(event.locationInWindow, from: nil).y)?.start
        guard next != hoveredHeading else { return }
        hoveredHeading = next
        needsDisplay = true
    }

    override package func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard hoveredHeading != nil else { return }
        hoveredHeading = nil
        needsDisplay = true
    }

    override package func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if point.x < textContainerOrigin.x, let heading = headingLine(atY: point.y),
           chevronRect(for: heading.rect).insetBy(dx: -6, dy: -4).contains(point) {
            toggleHeadingFold(at: heading.start)
            return
        }
        super.mouseDown(with: event)
    }
}

package extension NSAttributedString.Key {
    /// A heading's GitHub-style id, for `#fragment` links.
    static let markdownAnchor = NSAttributedString.Key("CairnMarkdownAnchor")
    /// A heading's level, 1–6, over its text; folding reads sections from it.
    static let markdownHeadingLevel = NSAttributedString.Key("CairnMarkdownHeadingLevel")
}

/// Renders CommonMark/GFM (via Foundation's parser) into a native reading
/// layout: typographic hierarchy, highlighted fenced code, quote bars, real
/// tables, task lists, front matter and local images.
@MainActor
package struct MarkdownPreviewRenderer {
    package let theme: ReaderTheme
    package let baseURL: URL?
    private let bodyPointSize: CGFloat?
    private let compactHeadings: Bool

    /// `bodyPointSize` overrides the preview's reading size and
    /// `compactHeadings` keeps headings near body size without rules, for
    /// compact hosts such as the symbol documentation card, where rustdoc's
    /// `# Examples` is a section label rather than a page title.
    package init(
        theme: ReaderTheme,
        baseURL: URL?,
        bodyPointSize: CGFloat? = nil,
        compactHeadings: Bool = false
    ) {
        self.theme = theme
        self.baseURL = baseURL
        self.bodyPointSize = bodyPointSize
        self.compactHeadings = compactHeadings
    }

    private var body: CGFloat { bodyPointSize ?? max(14, CGFloat(theme.fontSize) + 2) }

    /// Text blocks have no intrinsic width: without one, TextKit lays their
    /// content out one glyph per line.
    private static func fullWidthBlock() -> NSTextBlock {
        let block = NSTextBlock()
        block.setValue(100, type: .percentageValueType, for: .width)
        return block
    }

    package func render(_ source: String) -> NSAttributedString? {
        let (frontMatter, rawMarkdown) = Self.splitFrontMatter(source)
        let markdownSource = Self.cjkFriendlyEmphasis(rawMarkdown)
        guard let markdown = try? AttributedString(
            markdown: markdownSource,
            options: .init(failurePolicy: .returnPartiallyParsedIfPossible),
            baseURL: baseURL
        ) else { return nil }
        let output = NSMutableAttributedString()
        if let frontMatter {
            appendCode(frontMatter, language: "yaml", quoteDepth: [], into: output, isLast: false)
        }
        let blocks = Self.blocks(of: markdown)
        var state = RenderState()
        for (index, block) in blocks.enumerated() {
            let next = index + 1 < blocks.count ? blocks[index + 1] : nil
            renderBlock(block, next: next, markdown: markdown, state: &state, into: output)
        }
        if markdownSource != rawMarkdown {
            let text = output.string as NSString
            var range = NSRange(location: text.length, length: 0)
            while true {
                range = text.range(of: Self.flankSentinel, options: .backwards,
                                   range: NSRange(location: 0, length: range.location))
                guard range.location != NSNotFound else { break }
                output.deleteCharacters(in: range)
            }
        }
        while output.string.hasSuffix("\n") {
            output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1))
        }
        return output
    }

    /// CommonMark only lets `**` close when it is not wedged between
    /// punctuation and a letter, so `**命令`code`**继续` and `**“引”**后`
    /// stay literal in Chinese prose. A punctuation sentinel on the CJK side
    /// makes such a run both-flanking; `render` removes it afterwards.
    private static let flankSentinel = "\u{2E31}"

    static func cjkFriendlyEmphasis(_ source: String) -> String {
        let scalars = Array(source.unicodeScalars)
        let sentinel = flankSentinel.unicodeScalars.first!
        guard scalars.contains("*"), !scalars.contains(sentinel) else { return source }
        func isCJK(_ c: Unicode.Scalar) -> Bool {
            switch c.value {
            case 0x1100...0x11FF, 0x3040...0x30FF, 0x3130...0x318F, 0x3400...0x4DBF,
                 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0x20000...0x3134F: true
            default: false
            }
        }
        func isPunctuation(_ c: Unicode.Scalar) -> Bool {
            switch c.properties.generalCategory {
            case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
                 .initialPunctuation, .finalPunctuation, .otherPunctuation,
                 .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol: true
            default: false
            }
        }
        var result = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if c == "\\" {
                result.append(contentsOf: scalars[i..<min(i + 2, scalars.count)])
                i += 2
                continue
            }
            guard c == "*" else { result.append(c); i += 1; continue }
            var end = i
            while end < scalars.count, scalars[end] == "*" { end += 1 }
            let before = i > 0 ? scalars[i - 1] : nil
            let after = end < scalars.count ? scalars[end] : nil
            if let before, let after, isCJK(before), isPunctuation(after) { result.append(sentinel) }
            result.append(contentsOf: scalars[i..<end])
            if let before, let after, isPunctuation(before), isCJK(after) { result.append(sentinel) }
            i = end
        }
        return String(result)
    }

    // MARK: Block model

    private struct Block {
        var intent: PresentationIntent?
        var runs: [AttributedString.Runs.Run]
        var components: [PresentationIntent.IntentType] { intent?.components ?? [] }
        var leaf: PresentationIntent.Kind? { components.first?.kind }
        var identity: Int? { components.first?.identity }
    }

    private struct RenderState {
        var seenListItems: Set<Int> = []
        var tables: [Int: NSTextTable] = [:]
        var quoteBlocks: [Int: NSTextBlock] = [:]
        var codeBlockCount = 0
        var anchorCounts: [String: Int] = [:]
    }

    private static func blocks(of markdown: AttributedString) -> [Block] {
        var result: [Block] = []
        for run in markdown.runs {
            let intent = run.presentationIntent
            let identity = intent?.components.first?.identity
            if let last = result.last, last.identity == identity, identity != nil {
                result[result.count - 1].runs.append(run)
            } else {
                result.append(Block(intent: intent, runs: [run]))
            }
        }
        return result
    }

    private static func splitFrontMatter(_ source: String) -> (String?, String) {
        guard source.hasPrefix("---\n") || source.hasPrefix("---\r\n") else { return (nil, source) }
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        for index in 1..<lines.count where lines[index].trimmingCharacters(in: .whitespaces) == "---"
            || lines[index].trimmingCharacters(in: .whitespaces) == "..."
        {
            guard index > 1 else { return (nil, source) }
            let matter = lines[1..<index].joined(separator: "\n")
            // Front matter is YAML mappings; anything else is a thematic break.
            guard matter.split(separator: "\n").contains(where: { $0.contains(":") }) else {
                return (nil, source)
            }
            return (matter, lines[(index + 1)...].joined(separator: "\n"))
        }
        return (nil, source)
    }

    // MARK: Rendering

    private func renderBlock(
        _ block: Block,
        next: Block?,
        markdown: AttributedString,
        state: inout RenderState,
        into output: NSMutableAttributedString
    ) {
        let components = block.components
        let quoteBlocks = quoteTextBlocks(for: components, state: &state)
        let isLastInContainer = next.map { !sharesContainer(block, $0) } ?? true

        guard let leaf = block.leaf else {
            renderHTMLBlock(block, markdown: markdown, quoteBlocks: quoteBlocks, into: output)
            return
        }
        switch leaf {
        case .codeBlock(let hint):
            var code = block.runs.map { String(markdown[$0.range].characters) }.joined()
            if code.hasSuffix("\n") { code.removeLast() }
            appendCode(code, language: hint ?? "", quoteDepth: quoteBlocks, into: output, isLast: isLastInContainer)
        case .thematicBreak:
            let rule = Self.fullWidthBlock()
            rule.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
            rule.setBorderColor(theme.chromeDividerColor, for: .maxY)
            rule.setWidth(body * 0.6, type: .absoluteValueType, for: .margin, edge: .maxY)
            rule.setWidth(body * 0.4, type: .absoluteValueType, for: .margin, edge: .minY)
            let style = paragraphStyle(blocks: quoteBlocks + [rule], spacing: 0)
            output.append(NSAttributedString(string: "\u{00A0}\n", attributes: [
                .font: NSFont.systemFont(ofSize: 2),
                .paragraphStyle: style,
            ]))
        case .tableCell(let column):
            renderTableCell(block, column: column, markdown: markdown, quoteBlocks: quoteBlocks,
                            state: &state, into: output)
        default:
            renderTextBlock(block, leaf: leaf, markdown: markdown, quoteBlocks: quoteBlocks,
                            isLast: isLastInContainer, state: &state, into: output)
        }
    }

    private func sharesContainer(_ a: Block, _ b: Block) -> Bool {
        let listA = a.components.first { if case .listItem = $0.kind { true } else { false } }
        let listB = b.components.first { if case .listItem = $0.kind { true } else { false } }
        guard listA != nil, listB != nil else { return false }
        let containerA = a.components.first {
            switch $0.kind { case .orderedList, .unorderedList: true; default: false }
        }
        let containerB = b.components.first {
            switch $0.kind { case .orderedList, .unorderedList: true; default: false }
        }
        return containerA?.identity == containerB?.identity
            || b.components.contains { $0.identity == containerA?.identity }
            || a.components.contains { $0.identity == containerB?.identity }
    }

    private func quoteTextBlocks(
        for components: [PresentationIntent.IntentType],
        state: inout RenderState
    ) -> [NSTextBlock] {
        // Outermost first: components are ordered leaf-first.
        components.reversed().compactMap { component in
            guard case .blockQuote = component.kind else { return nil }
            if let existing = state.quoteBlocks[component.identity] { return existing }
            let block = Self.fullWidthBlock()
            block.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
            block.setBorderColor(theme.chromeDividerColor, for: .minX)
            block.setWidth(14, type: .absoluteValueType, for: .padding, edge: .minX)
            block.setWidth(2, type: .absoluteValueType, for: .padding, edge: .minY)
            block.setWidth(2, type: .absoluteValueType, for: .padding, edge: .maxY)
            block.setWidth(body * 0.75, type: .absoluteValueType, for: .margin, edge: .maxY)
            state.quoteBlocks[component.identity] = block
            return block
        }
    }

    private func paragraphStyle(
        blocks: [NSTextBlock],
        spacing: CGFloat,
        before: CGFloat = 0
    ) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.textBlocks = blocks
        style.paragraphSpacing = spacing
        style.paragraphSpacingBefore = before
        return style
    }

    private func renderTextBlock(
        _ block: Block,
        leaf: PresentationIntent.Kind,
        markdown: AttributedString,
        quoteBlocks: [NSTextBlock],
        isLast: Bool,
        state: inout RenderState,
        into output: NSMutableAttributedString
    ) {
        let inQuote = !quoteBlocks.isEmpty
        var baseFont = NSFont.systemFont(ofSize: body)
        var color = inQuote ? theme.chromeSecondaryColor : theme.foregroundColor
        let style = paragraphStyle(blocks: quoteBlocks, spacing: body * 0.8)
        style.lineHeightMultiple = 1.18

        if case .header(let level) = leaf {
            let scale: [CGFloat] = compactHeadings
                ? [1.1, 1.05, 1.0, 1.0, 1.0, 0.92]
                : [1.9, 1.5, 1.25, 1.08, 1.0, 0.92]
            baseFont = NSFont.systemFont(ofSize: body * scale[min(max(level, 1), 6) - 1], weight: .semibold)
            if level >= 6 { color = theme.chromeSecondaryColor }
            style.lineHeightMultiple = 1.05
            if compactHeadings {
                style.paragraphSpacingBefore = output.length == 0 ? 0 : body * 0.5
                style.paragraphSpacing = body * 0.3
            } else {
                style.paragraphSpacingBefore = output.length == 0 ? 0 : body * (level <= 2 ? 1.3 : 0.9)
                style.paragraphSpacing = body * (level <= 2 ? 0.7 : 0.45)
            }
            if level <= 2, !compactHeadings {
                let rule = Self.fullWidthBlock()
                rule.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
                rule.setBorderColor(theme.chromeDividerColor, for: .maxY)
                rule.setWidth(body * 0.3, type: .absoluteValueType, for: .padding, edge: .maxY)
                style.textBlocks = quoteBlocks + [rule]
            }
        }

        // Lists: hanging indent with a tab after the marker.
        var marker: String?
        var taskState: Bool?
        let listDepth = components(block, matching: {
            switch $0 { case .orderedList, .unorderedList: true; default: false }
        })
        if listDepth > 0, let item = block.components.first(where: {
            if case .listItem = $0.kind { true } else { false }
        }) {
            let step: CGFloat = body * 1.5
            let indent = step * CGFloat(listDepth - 1)
            let markerWidth: CGFloat = body * 1.5
            style.firstLineHeadIndent = indent
            style.headIndent = indent + markerWidth
            style.tabStops = [NSTextTab(textAlignment: .left, location: indent + markerWidth)]
            style.paragraphSpacing = isLast ? body * 0.8 : body * 0.3
            if !state.seenListItems.contains(item.identity) {
                state.seenListItems.insert(item.identity)
                let ordered = block.components.first {
                    switch $0.kind { case .orderedList: true; case .unorderedList: true; default: false }
                }
                if case .orderedList = ordered?.kind, case .listItem(let ordinal) = item.kind {
                    marker = "\(ordinal)."
                } else {
                    marker = ["•", "◦", "▪︎"][(listDepth - 1) % 3]
                }
                if let first = block.runs.first {
                    let prefix = String(markdown[first.range].characters.prefix(4))
                    if prefix == "[ ] " { taskState = false }
                    if prefix == "[x] " || prefix == "[X] " { taskState = true }
                }
                if let taskState { marker = taskState ? "☑︎" : "☐" }
            } else {
                style.firstLineHeadIndent = indent + markerWidth
            }
        }

        let paragraph = NSMutableAttributedString()
        if let marker {
            let markerColor = listDepth > 0 && marker.first?.isNumber == true
                ? theme.chromeSecondaryColor : theme.chromeTertiaryColor
            paragraph.append(NSAttributedString(string: marker + "\t", attributes: [
                .font: marker.first?.isNumber == true
                    ? NSFont.monospacedDigitSystemFont(ofSize: body, weight: .regular)
                    : NSFont.systemFont(ofSize: body),
                .foregroundColor: taskState == nil ? markerColor : theme.accentColor,
            ]))
        }
        for (index, run) in block.runs.enumerated() {
            var text = String(markdown[run.range].characters)
            if index == 0, taskState != nil { text = String(text.dropFirst(4)) }
            appendInline(text, run: run, baseFont: baseFont, color: color,
                         quoteDepth: quoteBlocks.count, into: paragraph)
        }
        if taskState == true {
            paragraph.addAttribute(.foregroundColor, value: theme.chromeSecondaryColor,
                                   range: NSRange(location: 2, length: max(0, paragraph.length - 2)))
        }
        paragraph.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: paragraph.length))
        if case .header(let level) = leaf {
            paragraph.addAttribute(.markdownHeadingLevel, value: level, range: NSRange(location: 0, length: paragraph.length))
            var slug = Self.headingSlug(paragraph.string)
            let count = state.anchorCounts[slug, default: 0]
            state.anchorCounts[slug] = count + 1
            if count > 0 { slug += "-\(count)" }
            paragraph.addAttribute(.markdownAnchor, value: slug, range: NSRange(location: 0, length: paragraph.length))
        }
        paragraph.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: style, .font: baseFont]))
        output.append(paragraph)
    }

    /// GitHub's heading ids: lowercase, drop punctuation other than `-` and
    /// `_`, spaces become hyphens; repeats get `-1`, `-2` in `render`.
    static func headingSlug(_ text: String) -> String {
        var slug = String.UnicodeScalarView()
        for scalar in text.lowercased().unicodeScalars {
            if scalar == " " || scalar == "-" {
                slug.append("-")
            } else if scalar.properties.isAlphabetic || scalar.properties.numericType != nil
                || scalar.properties.generalCategory == .connectorPunctuation
                || scalar.properties.generalCategory == .nonspacingMark
                || scalar.properties.generalCategory == .spacingMark
            {
                slug.append(scalar)
            }
        }
        return String(slug)
    }

    /// The heading a `#fragment` link points at, matched as GitHub does,
    /// case-insensitively.
    package static func anchorRange(for fragment: String, in text: NSAttributedString) -> NSRange? {
        let target = (fragment.removingPercentEncoding ?? fragment).lowercased()
        var found: NSRange?
        text.enumerateAttribute(.markdownAnchor, in: NSRange(location: 0, length: text.length)) { value, range, stop in
            guard (value as? String)?.lowercased() == target else { return }
            found = range
            stop.pointee = true
        }
        return found
    }

    private func components(_ block: Block, matching predicate: (PresentationIntent.Kind) -> Bool) -> Int {
        block.components.reduce(0) { $0 + (predicate($1.kind) ? 1 : 0) }
    }

    private func appendInline(
        _ rawText: String,
        run: AttributedString.Runs.Run?,
        baseFont: NSFont,
        color: NSColor,
        quoteDepth: Int = 0,
        into paragraph: NSMutableAttributedString
    ) {
        let inline = run?.inlinePresentationIntent ?? []
        var text = rawText
        if inline.contains(.lineBreak) { text = "\u{2028}" }
        if inline.contains(.inlineHTML) {
            // Only line breaks survive from inline tags; other tags wrap text.
            let tag = text.lowercased().replacingOccurrences(of: " ", with: "")
            guard tag.hasPrefix("<br") else { return }
            text = "\u{2028}"
        }
        if let imageURL = run?.imageURL {
            // Each quote level indents by its 3 pt bar and 14 pt padding.
            if let attachment = imageAttachment(imageURL, width: nil, inset: CGFloat(quoteDepth) * 17) {
                paragraph.append(NSAttributedString(attachment: attachment))
                return
            }
            text = "🖼 " + text
        }
        var font = baseFont
        var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
        if inline.contains(.code) {
            font = ReaderFontResolver.shared.resolve(theme: theme, size: baseFont.pointSize * 0.88).font
            attributes[.backgroundColor] = theme.chromeHeaderColor
        }
        if inline.contains(.stronglyEmphasized) {
            font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        }
        if inline.contains(.emphasized) {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        if inline.contains(.strikethrough) {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attributes[.foregroundColor] = theme.chromeSecondaryColor
        }
        if run?.imageURL != nil {
            attributes[.foregroundColor] = theme.chromeSecondaryColor
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        if let link = run?.link {
            attributes[.link] = link
            attributes[.foregroundColor] = theme.accentColor
        }
        attributes[.font] = font
        paragraph.append(NSAttributedString(string: text, attributes: attributes))
    }

    private func appendCode(
        _ code: String,
        language: String,
        quoteDepth quoteBlocks: [NSTextBlock],
        into output: NSMutableAttributedString,
        isLast: Bool
    ) {
        let block = Self.fullWidthBlock()
        block.backgroundColor = theme.chromeColor
        block.setWidth(1, type: .absoluteValueType, for: .border)
        block.setBorderColor(theme.chromeDividerColor)
        block.setWidth(14, type: .absoluteValueType, for: .padding, edge: .minX)
        block.setWidth(14, type: .absoluteValueType, for: .padding, edge: .maxX)
        block.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minY)
        block.setWidth(10, type: .absoluteValueType, for: .padding, edge: .maxY)
        // TextKit paints a block's background under its margins too, so the
        // spacing lives on a transparent outer block.
        let spacing = Self.fullWidthBlock()
        spacing.setWidth(body * 0.9, type: .absoluteValueType, for: .margin, edge: .maxY)
        spacing.setWidth(2, type: .absoluteValueType, for: .margin, edge: .minY)
        let style = NSMutableParagraphStyle()
        style.textBlocks = quoteBlocks + [spacing, block]
        style.lineHeightMultiple = CGFloat(max(1.15, theme.lineHeightMultiple * 0.95))
        let resolved = ReaderFontResolver.shared.resolve(theme: theme, size: body * 0.86)
        let space = (" " as NSString).size(withAttributes: [.font: resolved.font]).width
        style.defaultTabInterval = space * 4
        style.tabStops = []
        var attributes = resolved.attributes
        attributes[.foregroundColor] = theme.foregroundColor
        attributes[.paragraphStyle] = style
        let start = output.length
        output.append(NSAttributedString(string: code + "\n", attributes: attributes))
        let spans = CodeSnippetHighlighter.spans(for: code, languageHint: language)
        let emphasis = ReaderFontResolver.shared.resolve(theme: theme, size: body * 0.86, weight: .semibold).font
        CodeTextPreviewStyler.apply(spans, to: output, offset: start, theme: theme, emphasisFont: emphasis)
    }

    private func renderTableCell(
        _ block: Block,
        column: Int,
        markdown: AttributedString,
        quoteBlocks: [NSTextBlock],
        state: inout RenderState,
        into output: NSMutableAttributedString
    ) {
        var tableIdentity = 0
        var columns: [PresentationIntent.TableColumn] = []
        var row = 0
        var header = false
        for component in block.components {
            switch component.kind {
            case .table(let tableColumns):
                tableIdentity = component.identity
                columns = tableColumns
            case .tableHeaderRow:
                header = true
            case .tableRow(let rowIndex):
                row = rowIndex
            default:
                break
            }
        }
        let table: NSTextTable
        if let existing = state.tables[tableIdentity] {
            table = existing
        } else {
            table = NSTextTable()
            table.setValue(100, type: .percentageValueType, for: .width)
            table.numberOfColumns = max(1, columns.count)
            table.layoutAlgorithm = .automaticLayoutAlgorithm
            table.collapsesBorders = true
            table.hidesEmptyCells = false
            table.setWidth(body * 0.9, type: .absoluteValueType, for: .margin, edge: .maxY)
            state.tables[tableIdentity] = table
        }
        let cell = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
        cell.setWidth(1, type: .absoluteValueType, for: .border)
        cell.setBorderColor(theme.chromeDividerColor)
        cell.setWidth(6, type: .absoluteValueType, for: .padding, edge: .minY)
        cell.setWidth(6, type: .absoluteValueType, for: .padding, edge: .maxY)
        cell.setWidth(12, type: .absoluteValueType, for: .padding, edge: .minX)
        cell.setWidth(12, type: .absoluteValueType, for: .padding, edge: .maxX)
        if header { cell.backgroundColor = theme.chromeColor }
        let style = paragraphStyle(blocks: quoteBlocks + [cell], spacing: 0)
        if column < columns.count {
            switch columns[column].alignment {
            case .center: style.alignment = .center
            case .right: style.alignment = .right
            default: style.alignment = .natural
            }
        }
        let baseFont = header
            ? NSFont.systemFont(ofSize: body * 0.93, weight: .semibold)
            : NSFont.systemFont(ofSize: body * 0.93)
        let paragraph = NSMutableAttributedString()
        for run in block.runs {
            appendInline(String(markdown[run.range].characters), run: run,
                         baseFont: baseFont, color: theme.foregroundColor, into: paragraph)
        }
        paragraph.append(NSAttributedString(string: "\n", attributes: [.font: baseFont]))
        paragraph.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: paragraph.length))
        output.append(paragraph)
    }

    // MARK: HTML blocks and images

    /// README-style HTML (centered logos, badges, headings) renders as its
    /// text and local images; scripts and remote resources never load.
    private func renderHTMLBlock(
        _ block: Block,
        markdown: AttributedString,
        quoteBlocks: [NSTextBlock],
        into output: NSMutableAttributedString
    ) {
        let html = block.runs.map { String(markdown[$0.range].characters) }.joined()
        let lower = html.lowercased()
        if lower.hasPrefix("<!--") { return }
        var headingLevel: Int?
        for level in 1...6 where lower.contains("<h\(level)") {
            headingLevel = level
            break
        }
        let style = paragraphStyle(blocks: quoteBlocks, spacing: body * 0.8)
        if lower.contains("align=\"center\"") || lower.contains("align=center") {
            style.alignment = .center
        }
        let font = headingLevel.map {
            NSFont.systemFont(ofSize: body * [1.9, 1.5, 1.25, 1.08, 1.0, 0.92][$0 - 1], weight: .semibold)
        } ?? NSFont.systemFont(ofSize: body)
        let paragraph = NSMutableAttributedString()
        var remainder = Substring(html)
        while let open = remainder.firstIndex(of: "<") {
            appendHTMLText(remainder[..<open], font: font, into: paragraph)
            guard let close = remainder[open...].firstIndex(of: ">") else {
                remainder = remainder[open...]
                break
            }
            let tag = remainder[open...close]
            let tagLower = tag.lowercased()
            if tagLower.hasPrefix("<img"), let src = Self.attribute("src", in: tag) {
                let width = Self.attribute("width", in: tag).flatMap { Double($0) }.map { CGFloat($0) }
                if let url = URL(string: src, relativeTo: baseURL),
                   let attachment = imageAttachment(url, width: width)
                {
                    paragraph.append(NSAttributedString(attachment: attachment))
                } else if let alt = Self.attribute("alt", in: tag), !alt.isEmpty {
                    paragraph.append(NSAttributedString(string: alt, attributes: [
                        .font: font, .foregroundColor: theme.chromeSecondaryColor,
                    ]))
                }
            } else if tagLower.hasPrefix("<br") || tagLower.hasPrefix("</p") || tagLower.hasPrefix("</div") {
                if paragraph.length > 0, !paragraph.string.hasSuffix("\u{2028}") {
                    paragraph.append(NSAttributedString(string: "\u{2028}", attributes: [.font: font]))
                }
            }
            remainder = remainder[remainder.index(after: close)...]
        }
        appendHTMLText(remainder, font: font, into: paragraph)
        while paragraph.string.hasSuffix("\u{2028}") {
            paragraph.deleteCharacters(in: NSRange(location: paragraph.length - 1, length: 1))
        }
        guard paragraph.length > 0 else { return }
        if let headingLevel {
            paragraph.addAttribute(.markdownHeadingLevel, value: headingLevel,
                                   range: NSRange(location: 0, length: paragraph.length))
        }
        paragraph.append(NSAttributedString(string: "\n", attributes: [.font: font]))
        paragraph.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: paragraph.length))
        output.append(paragraph)
    }

    private func appendHTMLText(_ text: Substring, font: NSFont, into paragraph: NSMutableAttributedString) {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !collapsed.isEmpty else {
            if !text.isEmpty, paragraph.length > 0, !paragraph.string.hasSuffix(" ") {
                paragraph.append(NSAttributedString(string: " ", attributes: [.font: font]))
            }
            return
        }
        let decoded = collapsed
            .replacingOccurrences(of: "&nbsp;", with: "\u{00A0}")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
        paragraph.append(NSAttributedString(string: decoded, attributes: [
            .font: font, .foregroundColor: theme.foregroundColor,
        ]))
    }

    private static func attribute(_ name: String, in tag: Substring) -> String? {
        let lower = tag.lowercased()
        guard let range = lower.range(of: name + "=") else { return nil }
        let offset = lower.distance(from: lower.startIndex, to: range.upperBound)
        var index = tag.index(tag.startIndex, offsetBy: offset)
        guard index < tag.endIndex else { return nil }
        let quote = tag[index]
        if quote == "\"" || quote == "'" {
            index = tag.index(after: index)
            guard let end = tag[index...].firstIndex(of: quote) else { return nil }
            return String(tag[index..<end])
        }
        let end = tag[index...].firstIndex(where: { $0 == " " || $0 == ">" || $0 == "/" }) ?? tag.endIndex
        return String(tag[index..<end])
    }

    /// Local images and base64 data URLs only: previews never reach the network.
    private func imageAttachment(_ url: URL, width requestedWidth: CGFloat?, inset: CGFloat = 0) -> NSTextAttachment? {
        let image: NSImage?
        if url.scheme == "data" {
            let string = url.absoluteString
            image = string.utf8.count < 27_000_000
                ? string.range(of: ";base64,")
                    .flatMap { Data(base64Encoded: String(string[$0.upperBound...])) }
                    .flatMap(NSImage.init(data:))
                : nil
        } else {
            let file = url.absoluteURL
            image = file.isFileURL
                && ((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? .max) < 20_000_000
                ? NSImage(contentsOf: file) : nil
        }
        guard let image, image.size.width > 0, image.size.height > 0 else { return nil }
        let maxWidth = min(requestedWidth ?? image.size.width, MarkdownPreviewTextView.readableWidth - 8 - inset)
        let scale = min(1, maxWidth / image.size.width)
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale)
        return attachment
    }
}
