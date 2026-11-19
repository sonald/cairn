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

    /// A function or type's display lines; `shade` alternates between neighbours.
    struct Scope {
        let lines: Range<Int>
        let shade: Int
    }

    struct Age {
        let lines: Range<Int>
        let age: OverviewChangeAge
    }

    var marks: [Mark] = []
    var scopes: [Scope] = []
    var ages: [Age] = []
    var lineCount = 1

    var isEmpty: Bool { marks.isEmpty && scopes.isEmpty && ages.isEmpty }
}

/// How recently a stretch of lines last changed. Older lines are not shown.
public enum OverviewChangeAge: Sendable {
    case uncommitted, week, month, halfYear, year
}

/// A narrow strip beside the reader's scroller with the whole file's marks.
/// Positions are proportional to display lines, not to TextKit's estimated
/// document height, which drifts until distant text is laid out; the strip
/// draws its own viewport band so marks, clicks and band always agree.
@MainActor
final class OverviewRulerView: NSView {
    static let width: CGFloat = 12

    private weak var reader: ReaderTextView?
    private var observedClipView: NSClipView?
    /// Marks merged per pixel row, rebuilt when content or height changes.
    private var rows: [(row: Int, kind: OverviewContent.Kind, hollow: Bool)] = []
    private var rowsKey: (generation: Int, height: Int)?
    private var markRows: [Int: [OverviewContent.Mark]] = [:]
    private lazy var preview = OverviewPreviewView()
    private var pendingPreview: DispatchWorkItem?
    private var hoverPoint: NSPoint?

    init(reader: ReaderTextView) {
        self.reader = reader
        super.init(frame: .zero)
        wantsLayer = true
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
        hidePreview()
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
    }

    /// With nothing to show the strip draws nothing and lets clicks reach
    /// the scroller beneath it; it fades in once a mark or band appears.
    private var isEmpty = true

    override func hitTest(_ point: NSPoint) -> NSView? {
        isEmpty ? nil : super.hitTest(point)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let reader else { return }
        let (content, generation) = reader.overviewContent()
        rebuildRowsIfNeeded(content, generation: generation)
        if content.isEmpty != isEmpty {
            isEmpty = content.isEmpty
            if isEmpty { hidePreview() }
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.15
            layer?.add(fade, forKey: "overviewFade")
        }
        if isEmpty { return }
        let theme = reader.overviewTheme
        theme.backgroundColor.setFill()
        bounds.fill()
        theme.chromeDividerColor.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
        let lineCount = content.lineCount
        func band(_ lines: Range<Int>, x: CGFloat, width: CGFloat) -> NSRect {
            let top = y(forLine: lines.lowerBound, lineCount: lineCount)
            return NSRect(x: x, y: top, width: width, height: max(1, y(forLine: lines.upperBound, lineCount: lineCount) - top))
        }
        for scope in content.scopes {
            theme.foregroundColor.withAlphaComponent(scope.shade == 0 ? 0.04 : 0.08).setFill()
            band(scope.lines, x: 1, width: bounds.width - 1).fill(using: .sourceOver)
        }
        if let current = reader.overviewCurrentScope() {
            theme.foregroundColor.withAlphaComponent(0.08).setFill()
            band(current, x: 1, width: bounds.width - 1).fill(using: .sourceOver)
            theme.accentColor.setFill()
            band(current, x: 0, width: 2).fill()
        }
        // ponytail: fixed age column at the right edge; it shares x with the
        // third highlight column, which draws over it.
        for age in content.ages {
            Self.color(for: age.age, theme: theme).setFill()
            band(age.lines, x: bounds.width - 3, width: 3).fill(using: .sourceOver)
        }
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

    private static func color(for age: OverviewChangeAge, theme: ReaderTheme) -> NSColor {
        switch age {
        case .uncommitted: theme.color(for: DiffCore.MarkerKind.changed)
        case .week: theme.accentColor.withAlphaComponent(0.85)
        case .month: theme.accentColor.withAlphaComponent(0.6)
        case .halfYear: theme.accentColor.withAlphaComponent(0.4)
        case .year: theme.accentColor.withAlphaComponent(0.22)
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
        hidePreview()
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

    // MARK: Hover preview

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        guard !isEmpty else { return }
        hoverPoint = convert(event.locationInWindow, from: nil)
        if preview.superview != nil {
            showPreview()
        } else if pendingPreview == nil {
            let work = DispatchWorkItem { [weak self] in
                self?.pendingPreview = nil
                self?.showPreview()
            }
            pendingPreview = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    override func mouseExited(with event: NSEvent) {
        hidePreview()
    }

    private func hidePreview() {
        pendingPreview?.cancel()
        pendingPreview = nil
        hoverPoint = nil
        preview.removeFromSuperview()
    }

    private func showPreview() {
        guard let reader, let point = hoverPoint, let host = superview, !isEmpty, bounds.height > 0 else { return }
        let lineCount = reader.overviewContent().content.lineCount
        let line = min(lineCount - 1, max(0, Int(point.y / bounds.height * CGFloat(lineCount))))
        var labels: [String] = []
        for mark in nearestMarks(to: point) where !labels.contains(mark.label) {
            labels.append(mark.label)
            if labels.count == 3 { break }
        }
        guard let content = reader.overviewPreview(atDisplayLine: line, marks: labels) else { return }
        let width = min(480, max(260, host.bounds.width * 0.6))
        preview.update(title: content.title, code: content.code, theme: reader.overviewTheme, width: width)
        let size = preview.frame.size
        let top = min(max(0, point.y - size.height / 2), max(0, bounds.height - size.height))
        let local = NSRect(x: -6 - size.width, y: top, width: size.width, height: size.height)
        preview.frame = convert(local, to: host)
        if preview.superview == nil { host.addSubview(preview, positioned: .above, relativeTo: self) }
    }

    private func nearestMarks(to point: NSPoint) -> [OverviewContent.Mark] {
        let row = Int(point.y)
        for distance in 0...3 {
            for candidate in [row - distance, row + distance] {
                if let marks = markRows[candidate] { return marks }
            }
        }
        return []
    }
}

/// The code card beside the ruler while the pointer rests on it. It never
/// takes clicks, so the ruler keeps handling them.
@MainActor
private final class OverviewPreviewView: NSView {
    private let titleField = NSTextField(labelWithString: "")
    private let codeField = NSTextField(labelWithString: "")
    private static let padding: CGFloat = 10

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        shadow = NSShadow()
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        titleField.font = .systemFont(ofSize: 11, weight: .medium)
        titleField.lineBreakMode = .byTruncatingTail
        codeField.maximumNumberOfLines = 0
        [titleField, codeField].forEach(addSubview)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(title: String, code: NSAttributedString, theme: ReaderTheme, width: CGFloat) {
        layer?.backgroundColor = theme.backgroundColor.cgColor
        layer?.borderColor = theme.chromeDividerColor.cgColor
        titleField.stringValue = title
        titleField.textColor = theme.foregroundColor.withAlphaComponent(0.7)
        codeField.attributedStringValue = code
        let inner = width - Self.padding * 2
        let titleHeight = ceil(titleField.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: inner, height: 100)).height ?? 14)
        let codeHeight = ceil(codeField.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: inner, height: 10_000)).height ?? 0)
        titleField.frame = NSRect(x: Self.padding, y: 7, width: inner, height: titleHeight)
        codeField.frame = NSRect(x: Self.padding, y: 7 + titleHeight + 6, width: inner, height: codeHeight)
        setFrameSize(NSSize(width: width, height: 7 + titleHeight + 6 + codeHeight + 8))
    }
}

private struct OverviewRowKey: Hashable {
    let row: Int
    let kind: OverviewContent.Kind
}
