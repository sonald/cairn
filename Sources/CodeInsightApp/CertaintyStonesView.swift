import AppKit
import CodeInsightAppModel
import CodeInsightCore
import CodeInsightReaderCore
import CodeInsightReaderUI

/// The stacked-stone mark that states how certain a resolution is: one stone
/// per certainty level above unresolved, drawn bottom to top.
@MainActor
final class CertaintyStonesView: NSView {
    enum StoneState: Equatable {
        case filled
        case outlined
        case dashed
    }

    /// Stone rects in a 16×16 unit box, bottom stone first (y grows downward).
    static let unitStones: [CGRect] = [
        CGRect(x: 2, y: 12, width: 12, height: 3),
        CGRect(x: 3.5, y: 8.5, width: 9, height: 3),
        CGRect(x: 5, y: 5, width: 6, height: 3),
        CGRect(x: 6.5, y: 1.5, width: 3, height: 3),
    ]

    private(set) var certainty: Certainty
    private(set) var theme: ReaderTheme
    let size: CGFloat

    init(certainty: Certainty, theme: ReaderTheme, size: CGFloat = 16) {
        self.certainty = certainty
        self.theme = theme
        self.size = size
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        updateAccessibility()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: size, height: size)
    }

    func update(certainty: Certainty, theme: ReaderTheme) {
        guard certainty != self.certainty || theme != self.theme else { return }
        self.certainty = certainty
        self.theme = theme
        updateAccessibility()
        needsDisplay = true
    }

    /// What each stone will look like, bottom stone first.
    var stoneStates: [StoneState] {
        let level = certainty.rawValue
        return Self.unitStones.indices.map { index in
            if level == 0 { return .dashed }
            return index < level ? .filled : .outlined
        }
    }

    /// Stone rects scaled to this view's size, bottom stone first.
    var stoneRects: [CGRect] {
        let scale = size / 16
        return Self.unitStones.map {
            CGRect(x: $0.minX * scale, y: $0.minY * scale,
                   width: $0.width * scale, height: $0.height * scale)
        }
    }

    var fillColor: NSColor {
        switch certainty {
        case .exact, .strong: theme.verifiedColor
        case .probable, .possible: theme.inferredColor
        case .unresolved: theme.unresolvedColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let scale = size / 16
        let radius = 1.3 * scale
        for (rect, state) in zip(stoneRects, stoneStates) {
            switch state {
            case .filled:
                fillColor.setFill()
                NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            case .outlined:
                theme.chromeDividerColor.setStroke()
                let path = NSBezierPath(
                    roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                    xRadius: max(radius - 0.3, 0.5), yRadius: max(radius - 0.3, 0.5)
                )
                path.lineWidth = 1
                path.stroke()
            case .dashed:
                theme.unresolvedColor.setStroke()
                let path = NSBezierPath(
                    roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                    xRadius: max(radius - 0.3, 0.5), yRadius: max(radius - 0.3, 0.5)
                )
                path.lineWidth = 1
                path.setLineDash([1.6 * scale, 1.2 * scale], count: 2, phase: 0)
                path.stroke()
            }
        }
    }

    private func updateAccessibility() {
        setAccessibilityLabel(resolutionCertaintyLabel(certainty))
    }
}
