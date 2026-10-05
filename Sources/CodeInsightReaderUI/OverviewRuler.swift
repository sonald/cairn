@preconcurrency import AppKit
import CodeInsightReaderCore

/// What the overview ruler shows: marks placed by display line, so a fold
/// gathers the marks it hides onto its own line (drawn hollow).
struct OverviewContent {
    enum Kind: Hashable {
        case diff(DiffCore.MarkerKind)
        case occurrence
        case highlight(UInt8)
        case bookmark
    }

    struct Mark {
        let kind: Kind
        let line: Int
        let folded: Bool
        let byteOffset: UInt32
        let label: String
    }

    var marks: [Mark] = []
    var lineCount = 1
}

/// A narrow strip beside the reader's scroller with the whole file's marks.
/// Positions are proportional to display lines, not to TextKit's estimated
/// document height, which drifts until distant text is laid out; the strip
/// draws its own viewport band so marks, clicks and band always agree.
@MainActor
final class OverviewRulerView: NSView, NSViewToolTipOwner {
    static let width: CGFloat = 12

    private weak var reader: ReaderTextView?
    private var observedClipView: NSClipView?
    /// Marks merged per pixel row, rebuilt when content or height changes.
    private var rows: [(row: Int, kind: OverviewContent.Kind, hollow: Bool)] = []
    private var rowsKey: (generation: Int, height: Int)?
    private var markRows: [Int: [OverviewContent.Mark]] = [:]

    init(reader: ReaderTextView) {
        self.reader = reader
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observedClipView {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: observedClipView)
        }
        observedClipView = window == nil ? nil : reader?.view.enclosingScrollView?.contentView
        guard let observedClipView else { return }
        NotificationCenter.default.addObserver(
            self, selector: #selector(viewportDidScroll(_:)),
            name: NSView.boundsDidChangeNotification, object: observedClipView
        )
    }

    @objc private func viewportDidScroll(_ notification: Notification) {
        needsDisplay = true
    }

    private func y(forLine line: Int, lineCount: Int) -> CGFloat {
        CGFloat(line) / CGFloat(max(1, lineCount)) * bounds.height
    }

    private func rebuildRowsIfNeeded(_ content: OverviewContent, generation: Int) {
        let height = Int(bounds.height.rounded())
        if let rowsKey, rowsKey.generation == generation, rowsKey.height == height { return }
        rowsKey = (generation, height)
        var hollowByRow: [OverviewRowKey: Bool] = [:]
        var marksByRow: [Int: [OverviewContent.Mark]] = [:]
        for mark in content.marks {
            let row = Int(y(forLine: mark.line, lineCount: content.lineCount))
            let key = OverviewRowKey(row: row, kind: mark.kind)
            hollowByRow[key] = (hollowByRow[key] ?? true) && mark.folded
            marksByRow[row, default: []].append(mark)
        }
        rows = hollowByRow.map { ($0.key.row, $0.key.kind, $0.value) }
        markRows = marksByRow
        removeAllToolTips()
        for row in marksByRow.keys {
            addToolTip(NSRect(x: 0, y: CGFloat(row) - 1, width: bounds.width, height: 4), owner: self, userData: nil)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let reader else { return }
        let theme = reader.overviewTheme
        theme.backgroundColor.setFill()
        bounds.fill()
        theme.chromeDividerColor.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
        let (content, generation) = reader.overviewContent()
        rebuildRowsIfNeeded(content, generation: generation)
        let viewport = reader.overviewViewport()
        if let visible = viewport.lines {
            let top = y(forLine: visible.lowerBound, lineCount: content.lineCount)
            let bottom = y(forLine: visible.upperBound, lineCount: content.lineCount)
            theme.foregroundColor.withAlphaComponent(0.1).setFill()
            NSRect(x: 1, y: top, width: bounds.width - 1, height: max(6, bottom - top)).fill(using: .sourceOver)
        }
        // Wider kinds first so narrow columns stay visible on top of them.
        for entry in rows.sorted(by: { Self.layer($0.kind) < Self.layer($1.kind) }) {
            let rect = Self.rect(for: entry.kind, row: entry.row, width: bounds.width)
            let color = Self.color(for: entry.kind, theme: theme)
            if entry.hollow {
                color.setStroke()
                let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
                path.lineWidth = 1
                path.stroke()
            } else {
                color.setFill()
                rect.fill()
            }
        }
        if let caret = viewport.caret {
            theme.foregroundColor.withAlphaComponent(0.7).setFill()
            NSRect(x: 1, y: y(forLine: caret, lineCount: content.lineCount), width: bounds.width - 1, height: 1).fill(using: .sourceOver)
        }
    }

    private static func layer(_ kind: OverviewContent.Kind) -> Int {
        switch kind {
        case .diff: 0
        case .occurrence: 1
        case .highlight: 2
        case .bookmark: 3
        }
    }

    private static func rect(for kind: OverviewContent.Kind, row: Int, width: CGFloat) -> NSRect {
        let y = CGFloat(row)
        switch kind {
        case .diff: return NSRect(x: 1, y: y, width: width - 1, height: 2)
        case .occurrence: return NSRect(x: 1.5, y: y, width: 3, height: 3)
        case .highlight(let slot):
            // Six slots share three columns, in pairs (1/4, 2/5, 3/6).
            let column = CGFloat((Int(max(1, slot)) - 1) % 3)
            return NSRect(x: 5 + column * 2.4, y: y, width: 2.2, height: 3)
        case .bookmark: return NSRect(x: 3, y: y - 1, width: 6, height: 5)
        }
    }

    private static func color(for kind: OverviewContent.Kind, theme: ReaderTheme) -> NSColor {
        switch kind {
        case .diff(let marker): theme.color(for: marker)
        case .occurrence: theme.overviewOccurrenceColor
        case .highlight(let slot): theme.overviewHighlightColor(slot: slot)
        case .bookmark: theme.accentColor
        }
    }

    // MARK: Interaction

    private func nearestMark(to point: NSPoint) -> OverviewContent.Mark? {
        let row = Int(point.y)
        for distance in 0...3 {
            for candidate in [row - distance, row + distance] {
                if let marks = markRows[candidate] {
                    return marks.min { Self.layer($0.kind) > Self.layer($1.kind) }
                }
            }
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let mark = nearestMark(to: point) {
            reader?.reveal(byteOffset: mark.byteOffset)
        } else {
            scroll(to: point)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        scroll(to: convert(event.locationInWindow, from: nil))
    }

    private func scroll(to point: NSPoint) {
        guard let reader, bounds.height > 0 else { return }
        let lineCount = reader.overviewContent().content.lineCount
        let fraction = min(max(point.y / bounds.height, 0), 1)
        reader.scrollToOverviewLine(min(lineCount - 1, Int(fraction * CGFloat(lineCount))))
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let reader, let marks = (0...3).lazy.compactMap({ self.markRows[Int(point.y) - $0] ?? self.markRows[Int(point.y) + $0] }).first,
              let first = marks.first
        else { return "" }
        var labels: [String] = []
        for mark in marks where !labels.contains(mark.label) {
            labels.append(mark.label)
            if labels.count == 3 { break }
        }
        var text = labels.joined(separator: " · ")
        if first.folded { text = localizedFormat("reader.overview.folded", text) }
        return localizedFormat("reader.overview.line", reader.overviewSourceLine(ofByte: first.byteOffset), text)
    }
}

private struct OverviewRowKey: Hashable {
    let row: Int
    let kind: OverviewContent.Kind
}
