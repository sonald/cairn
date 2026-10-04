import AppKit
import CodeInsightAppModel
import CodeInsightReaderCore
import CodeInsightReaderUI

/// Status-bar strip listing highlighted names: color number, name, count in
/// the focused file, and a remove button. Hidden while nothing is highlighted.
@MainActor
final class HighlightChipsView: NSStackView {
    struct Item: Equatable {
        let name: String
        let slot: UInt8
        /// nil while the focused reader is still preparing identifiers.
        let count: Int?
    }

    var onReveal: ((String, Bool) -> Void)?
    var onRemove: ((String) -> Void)?
    var onClearAll: (() -> Void)?

    private var items: [Item] = []
    private var theme = ReaderTheme(settings: ReaderSettings())

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 6
        isHidden = true
        setHuggingPriority(.defaultHigh, for: .horizontal)
        setAccessibilityLabel(localized("main.highlight.strip"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func display(_ items: [Item], theme: ReaderTheme) {
        guard items != self.items || theme != self.theme else { return }
        self.items = items
        self.theme = theme
        rebuild()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rebuild()
    }

    private func rebuild() {
        isHidden = items.isEmpty
        // Layer colors are CGColors: resolve the dynamic theme colors now.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            setViews(items.map(chip(for:)) + (items.isEmpty ? [] : [clearButton()]), in: .leading)
        }
    }

    private func chip(for item: Item) -> NSView {
        let swatch = NSTextField(labelWithString: String(item.slot))
        swatch.font = .monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        swatch.alignment = .center
        swatch.textColor = theme.foregroundColor
        swatch.wantsLayer = true
        swatch.layer?.backgroundColor = theme.highlightColor(slot: item.slot).cgColor
        swatch.layer?.cornerRadius = 3
        swatch.translatesAutoresizingMaskIntoConstraints = false

        let name = NSButton(title: item.name, target: self, action: #selector(reveal(_:)))
        name.isBordered = false
        name.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        name.contentTintColor = theme.foregroundColor
        name.identifier = NSUserInterfaceItemIdentifier(item.name)
        name.toolTip = localized("main.highlight.next.help")
        name.setAccessibilityLabel(localizedFormat("main.highlight.chip.ax", item.name, Int64(item.slot)))

        let count = NSTextField(labelWithString: item.count.map(String.init) ?? "–")
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.textColor = theme.chromeTertiaryColor

        let remove = NSButton(title: "×", target: self, action: #selector(remove(_:)))
        remove.isBordered = false
        remove.font = .systemFont(ofSize: 12)
        remove.contentTintColor = theme.chromeTertiaryColor
        remove.identifier = NSUserInterfaceItemIdentifier(item.name)
        remove.toolTip = localized("main.highlight.remove")
        remove.setAccessibilityLabel(localizedFormat("main.highlight.remove.ax", item.name))

        let stack = NSStackView(views: [swatch, name, count, remove])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 5, bottom: 0, right: 2)
        stack.wantsLayer = true
        stack.layer?.cornerRadius = 9
        stack.layer?.borderWidth = 1
        stack.layer?.borderColor = theme.chromeDividerColor.cgColor
        stack.layer?.backgroundColor = theme.backgroundColor.cgColor
        stack.toolTip = localized("main.highlight.lexical.help")
        NSLayoutConstraint.activate([
            swatch.widthAnchor.constraint(equalToConstant: 14),
            swatch.heightAnchor.constraint(equalToConstant: 12),
            stack.heightAnchor.constraint(equalToConstant: 18),
        ])
        return stack
    }

    private func clearButton() -> NSView {
        let button = NSButton(title: localized("main.highlight.clear"), target: self, action: #selector(clearAll(_:)))
        button.isBordered = false
        button.font = .systemFont(ofSize: 11)
        button.contentTintColor = theme.accentColor
        return button
    }

    @objc private func reveal(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue else { return }
        let backwards = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
        onReveal?(name, backwards)
    }

    @objc private func remove(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue else { return }
        onRemove?(name)
    }

    @objc private func clearAll(_ sender: Any?) {
        onClearAll?()
    }
}
