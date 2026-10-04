import AppKit
import CodeInsightCore

/// Sheet for the open project's exclusion rules: built-in skips shown
/// read-only, the user's rules edited one per line.
@MainActor
final class ExclusionRulesSheet: NSWindowController {
    private let editor = NSTextView()
    private let onSave: ([String]) -> Void

    init(rules: ProjectPathRules, onSave: @escaping ([String]) -> Void) {
        self.onSave = onSave
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = localized("rules.title")
        window.minSize = NSSize(width: 420, height: 320)
        super.init(window: window)
        configure(lines: rules.lines)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configure(lines: [String]) {
        let title = NSTextField(labelWithString: localized("rules.title"))
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let explanation = NSTextField(wrappingLabelWithString: localized("rules.explain"))
        explanation.font = .systemFont(ofSize: 12)
        explanation.textColor = .secondaryLabelColor
        let defaults = NSTextField(wrappingLabelWithString: localizedFormat(
            "rules.defaults",
            (ProjectPathRules.alwaysSkippedDirectories + ProjectPathRules.defaultSkippedDirectories)
                .map { $0 + "/" }.joined(separator: "  ")
        ))
        defaults.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        defaults.textColor = .secondaryLabelColor

        editor.string = lines.joined(separator: "\n")
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.allowsUndo = true
        editor.setAccessibilityLabel(localized("rules.title"))
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        let scroll = NSScrollView()
        scroll.documentView = editor
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let cancel = NSButton(title: localized("rules.cancel"), target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: localized("rules.save"), target: self, action: #selector(save(_:)))
        save.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, save])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [title, explanation, defaults, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            defaults.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
        ])
        window?.contentView = content
        window?.initialFirstResponder = editor
    }

    @objc private func cancel(_ sender: Any?) {
        close(returning: .cancel)
    }

    @objc private func save(_ sender: Any?) {
        let lines = editor.string.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let trimmed = Array(lines.reversed().drop { $0.isEmpty }.reversed())
        close(returning: .OK)
        onSave(trimmed)
    }

    private func close(returning response: NSApplication.ModalResponse) {
        guard let window else { return }
        if let parent = window.sheetParent {
            parent.endSheet(window, returnCode: response)
        } else {
            window.orderOut(nil)
        }
    }
}
