import AppKit
import CodeInsightReaderCore
import CodeInsightReaderUI

/// One badge view for every tag style in the redesign: provenance, dispatch,
/// capture and snapshot markers. Callers supply already-localized text.
@MainActor
final class CairnBadgeView: NSView {
    enum Style: CaseIterable, Equatable {
        case verified
        case inferred
        case unresolved
        case corrected
        case dispatch
        case dependency
        case captured
        case commit
        case limited
    }

    struct Colors {
        let text: NSColor
        let fill: NSColor
        let border: NSColor?
    }

    static let height: CGFloat = 17
    static let horizontalPadding: CGFloat = 6
    static let cornerRadius: CGFloat = 4

    private let label = NSTextField(labelWithString: "")
    private(set) var style: Style
    private(set) var theme: ReaderTheme

    init(style: Style, text: String, theme: ReaderTheme) {
        self.style = style
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byClipping
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalPadding),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalPadding),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        apply(text: text)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var text: String { label.stringValue }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: ceil(label.intrinsicContentSize.width) + Self.horizontalPadding * 2,
            height: Self.height
        )
    }

    func update(style: Style, text: String, theme: ReaderTheme) {
        self.style = style
        self.theme = theme
        apply(text: text)
    }

    static func colors(for style: Style, theme: ReaderTheme) -> Colors {
        switch style {
        case .verified:
            Colors(text: theme.verifiedColor, fill: theme.mossSoftColor, border: nil)
        case .inferred:
            Colors(text: theme.inferredColor, fill: theme.slateSoftColor, border: nil)
        case .unresolved:
            Colors(text: theme.unresolvedColor, fill: .clear, border: theme.unresolvedBorderColor)
        case .corrected:
            Colors(text: theme.unresolvedColor, fill: theme.rustSoftColor, border: nil)
        case .dispatch:
            Colors(text: theme.chromeSecondaryColor, fill: .clear, border: theme.chromeDividerColor)
        case .dependency, .captured:
            Colors(text: theme.chipForegroundColor, fill: theme.chipBackgroundColor, border: nil)
        case .commit:
            Colors(text: theme.histColor, fill: theme.histSoftColor, border: nil)
        case .limited:
            Colors(text: theme.warningColor, fill: theme.amberSoftColor, border: nil)
        }
    }

    var colors: Colors { Self.colors(for: style, theme: theme) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func apply(text: String) {
        label.stringValue = text
        label.font = style == .dispatch
            ? .monospacedSystemFont(ofSize: 10, weight: .medium)
            : .systemFont(ofSize: 10.5, weight: .semibold)
        setAccessibilityLabel(text)
        applyColors()
        invalidateIntrinsicContentSize()
    }

    private func applyColors() {
        let colors = colors
        label.textColor = colors.text
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = colors.fill.cgColor
            layer?.borderColor = colors.border?.cgColor
        }
        layer?.borderWidth = colors.border == nil ? 0 : 1
    }
}
