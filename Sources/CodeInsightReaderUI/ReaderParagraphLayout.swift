import AppKit
import CodeInsightCore

/// Code-paragraph indentation shared by the reader and frozen excerpts.
@MainActor
package final class ReaderParagraphLayout {
    private let storage = NSTextStorage()
    private let manager = NSLayoutManager()
    private let container = NSTextContainer(size: NSSize(
        width: CGFloat.greatestFiniteMagnitude,
        height: CGFloat.greatestFiniteMagnitude
    ))
    private var measuredFont: NSFont?
    private var measuredStyle: NSParagraphStyle?
    private var advances: [String: CGFloat] = [:]

    package init() {
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
    }

    package func reset() { advances.removeAll(keepingCapacity: false) }

    package static func maximumIndent(width: CGFloat, font: NSFont) -> CGFloat {
        let space = (" " as NSString).size(withAttributes: [.font: font]).width
        return min(24 * space, width * 0.25)
    }

    @discardableResult
    package func apply(
        to text: NSMutableAttributedString,
        wrap: Bool,
        width: CGFloat,
        font: NSFont,
        sourceLineAt: ((Int) -> String?)? = nil,
        in requestedRange: NSRange? = nil
    ) -> Int {
        guard !wrap || (width.isFinite && width > 0), text.length > 0 else { return 0 }
        let string = text.mutableString
        let requested = requestedRange ?? NSRange(location: 0, length: text.length)
        guard requested.location >= 0, requested.length >= 0,
              requested.location <= text.length,
              requested.length <= text.length - requested.location else { return 0 }
        let lower = max(0, requested.location - (requestedRange == nil ? 0 : 1))
        let upper = min(text.length, NSMaxRange(requested) + (requestedRange == nil ? 0 : 1))
        let target = string.paragraphRange(for: NSRange(location: lower, length: upper - lower))
        if !wrap {
            var updates = 0
            text.beginEditing()
            defer { text.endEditing() }
            text.enumerateAttribute(.paragraphStyle, in: target) { value, range, _ in
                guard let base = value as? NSParagraphStyle,
                      base.headIndent != 0 || base.firstLineHeadIndent != 0 else { return }
                let style = base.mutableCopy() as! NSMutableParagraphStyle
                style.headIndent = 0
                style.firstLineHeadIndent = 0
                ReaderWorkCounters.record(\.attributeUpdatedUTF16Units, range.length)
                text.addAttribute(.paragraphStyle, value: style, range: range)
                var offset = range.location
                while offset < NSMaxRange(range) {
                    ReaderWorkCounters.record(\.paragraphRecordsVisited)
                    updates += 1
                    offset = NSMaxRange(string.paragraphRange(for: NSRange(location: offset, length: 0)))
                }
            }
            return updates
        }
        let space = (" " as NSString).size(withAttributes: [.font: font]).width
        let limit = Self.maximumIndent(width: width, font: font)
        var offset = target.location
        var updates = 0
        text.beginEditing()
        defer { text.endEditing() }
        while offset < NSMaxRange(target) {
            ReaderWorkCounters.record(\.paragraphRecordsVisited)
            let range = string.paragraphRange(for: NSRange(location: offset, length: 0))
            let base = (text.attribute(.paragraphStyle, at: offset, effectiveRange: nil)
                as? NSParagraphStyle) ?? .default
            let line: String
            if let source = sourceLineAt?(offset) {
                line = source
            } else {
                var end = range.location
                while end < NSMaxRange(range), string.character(at: end) == 32 || string.character(at: end) == 9 {
                    end += 1
                }
                let prefix = string.substring(with: NSRange(location: range.location, length: end - range.location))
                let value = end < NSMaxRange(range) ? string.character(at: end) : 10
                let hasBody = value != 10 && value != 13 && value != 0x2028 && value != 0x2029
                line = prefix + (hasBody ? "x" : "")
            }
            let prefix = String(line.prefix { $0 == " " || $0 == "\t" })
            let hasBody = line.dropFirst(prefix.count).contains { !$0.isNewline }
            let indent: CGFloat
            if wrap, hasBody, !prefix.isEmpty {
                let advance = prefix.contains("\t")
                    ? prefixAdvance(prefix, font: font, style: base)
                    : CGFloat(prefix.count) * space
                indent = min(advance, limit)
            } else {
                indent = 0
            }
            if base.headIndent != indent || base.firstLineHeadIndent != 0 {
                let style = base.mutableCopy() as! NSMutableParagraphStyle
                style.firstLineHeadIndent = 0
                style.headIndent = indent
                ReaderWorkCounters.record(\.attributeUpdatedUTF16Units, range.length)
                text.addAttribute(.paragraphStyle, value: style, range: range)
                updates += 1
            }
            offset = NSMaxRange(range)
        }
        return updates
    }

    private func prefixAdvance(
        _ prefix: String, font: NSFont, style: NSParagraphStyle
    ) -> CGFloat {
        let measureStyle = style.mutableCopy() as! NSMutableParagraphStyle
        measureStyle.headIndent = 0
        measureStyle.firstLineHeadIndent = 0
        if measuredFont != font || measuredStyle != measureStyle {
            advances.removeAll(keepingCapacity: true)
            measuredFont = font
            measuredStyle = measureStyle.copy() as? NSParagraphStyle
        }
        if let cached = advances[prefix] { return cached }
        storage.setAttributedString(NSAttributedString(
            string: prefix + "x", attributes: [.font: font, .paragraphStyle: measureStyle]
        ))
        manager.ensureLayout(for: container)
        let glyph = manager.glyphIndexForCharacter(at: (prefix as NSString).length)
        let advance = manager.location(forGlyphAt: glyph).x
        advances[prefix] = advance
        return advance
    }
}
