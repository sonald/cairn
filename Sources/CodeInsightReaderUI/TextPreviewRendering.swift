@preconcurrency import AppKit
import CodeInsightReaderCore

/// Styles code-like text previews (configuration, templates, scripts) with
/// the reader's code font, line height and syntax palette.
@MainActor
package enum CodeTextPreviewStyler {
    package static func attributedString(
        _ text: String,
        format: TextFormat?,
        theme: ReaderTheme
    ) -> NSAttributedString {
        let resolver = ReaderFontResolver.shared
        let regular = resolver.resolve(theme: theme)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = theme.lineHeightMultiple
        let space = (" " as NSString).size(withAttributes: [.font: regular.font]).width
        paragraph.defaultTabInterval = space * 4
        paragraph.tabStops = []
        var base = regular.attributes
        base[.foregroundColor] = theme.foregroundColor
        base[.paragraphStyle] = paragraph
        let result = NSMutableAttributedString(string: text, attributes: base)
        guard let format else { return result }
        let emphasis = resolver.resolve(theme: theme, weight: .semibold).font
        apply(format.highlight(text), to: result, theme: theme, emphasisFont: emphasis)
        return result
    }

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
@MainActor
package final class MarkdownPreviewTextView: NSTextView {
    package static let readableWidth: CGFloat = 780
    package static let minimumInset: CGFloat = 28

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
}

/// Renders CommonMark/GFM (via Foundation's parser) into a native reading
/// layout: typographic hierarchy, highlighted fenced code, quote bars, real
/// tables, task lists, front matter and local images.
@MainActor
package struct MarkdownPreviewRenderer {
    package let theme: ReaderTheme
    package let baseURL: URL?

    package init(theme: ReaderTheme, baseURL: URL?) {
        self.theme = theme
        self.baseURL = baseURL
    }

    private var body: CGFloat { max(14, CGFloat(theme.fontSize) + 2) }

    /// Text blocks have no intrinsic width: without one, TextKit lays their
    /// content out one glyph per line.
    private static func fullWidthBlock() -> NSTextBlock {
        let block = NSTextBlock()
        block.setValue(100, type: .percentageValueType, for: .width)
        return block
    }

    package func render(_ source: String) -> NSAttributedString? {
        let (frontMatter, markdownSource) = Self.splitFrontMatter(source)
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
        while output.string.hasSuffix("\n") {
            output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1))
        }
        return output
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
            let scale: [CGFloat] = [1.9, 1.5, 1.25, 1.08, 1.0, 0.92]
            baseFont = NSFont.systemFont(ofSize: body * scale[min(max(level, 1), 6) - 1], weight: .semibold)
            if level >= 6 { color = theme.chromeSecondaryColor }
            style.lineHeightMultiple = 1.05
            style.paragraphSpacingBefore = output.length == 0 ? 0 : body * (level <= 2 ? 1.3 : 0.9)
            style.paragraphSpacing = body * (level <= 2 ? 0.7 : 0.45)
            if level <= 2 {
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
            appendInline(text, run: run, baseFont: baseFont, color: color, into: paragraph)
        }
        if taskState == true {
            paragraph.addAttribute(.foregroundColor, value: theme.chromeSecondaryColor,
                                   range: NSRange(location: 2, length: max(0, paragraph.length - 2)))
        }
        paragraph.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: paragraph.length))
        paragraph.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: style, .font: baseFont]))
        output.append(paragraph)
    }

    private func components(_ block: Block, matching predicate: (PresentationIntent.Kind) -> Bool) -> Int {
        block.components.reduce(0) { $0 + (predicate($1.kind) ? 1 : 0) }
    }

    private func appendInline(
        _ rawText: String,
        run: AttributedString.Runs.Run?,
        baseFont: NSFont,
        color: NSColor,
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
            if let attachment = imageAttachment(imageURL, width: nil) {
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

    /// Local images only: previews never reach the network.
    private func imageAttachment(_ url: URL, width requestedWidth: CGFloat?) -> NSTextAttachment? {
        let file = url.absoluteURL
        guard file.isFileURL,
              let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size < 20_000_000,
              let image = NSImage(contentsOf: file),
              image.size.width > 0, image.size.height > 0
        else { return nil }
        let maxWidth = min(requestedWidth ?? image.size.width, MarkdownPreviewTextView.readableWidth - 8)
        let scale = min(1, maxWidth / image.size.width)
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale)
        return attachment
    }
}
