import AppKit

/// Typeset gutter line numbers keyed by line. The gutter redraws every visible
/// row on each scroll, and string drawing would re-typeset each number. Color
/// comes from the context, so theme and appearance changes keep entries.
@MainActor
final class LineNumberLabels {
    private var fontSize: CGFloat = 0
    private var baselineOffset: CGFloat = 0
    private var lines: [Int: CTLine] = [:]

    /// Draws `line` exactly where right-aligned `NSString.draw(in:)` would.
    func draw(_ line: Int, font: NSFont, color: NSColor, rightAlignedIn rect: NSRect, flipped: Bool) {
        let label = self.label(line, font: font)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let width = CGFloat(CTLineGetTypographicBounds(label, nil, nil, nil))
        context.saveGState()
        defer { context.restoreGState() }
        color.setFill()
        // String drawing puts the first baseline the line height minus the
        // rounded descent below the box top; CoreText does the pixel snapping.
        context.textMatrix = flipped ? CGAffineTransform(scaleX: 1, y: -1) : .identity
        context.textPosition = CGPoint(
            x: rect.maxX - width,
            y: flipped ? rect.minY + baselineOffset : rect.maxY - baselineOffset
        )
        CTLineDraw(label, context)
    }

    private func label(_ line: Int, font: NSFont) -> CTLine {
        if fontSize != font.pointSize {
            fontSize = font.pointSize
            baselineOffset = NSLayoutManager().defaultLineHeight(for: font) - (-font.descender).rounded()
            lines.removeAll()
        }
        if let cached = lines[line] { return cached }
        if lines.count >= 4_096 { lines.removeAll(keepingCapacity: true) }
        let label = CTLineCreateWithAttributedString(NSAttributedString(
            string: String(line),
            attributes: [
                .font: font,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ]
        ))
        lines[line] = label
        return label
    }
}
