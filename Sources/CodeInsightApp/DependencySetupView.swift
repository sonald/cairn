import AppKit
import CodeInsightAppModel
import CodeInsightExact

/// The top of the Exact status popover when dependencies are missing:
/// what is missing, the command that installs them, and the one action
/// Cairn offers for it.
final class DependencySetupView: NSView {
    var onFetch: () -> Void = {}
    var onCancel: () -> Void = {}

    private let note = NSTextField(wrappingLabelWithString: "")
    private let directoryLabel = NSTextField(labelWithString: "")
    private let commandLabel = NSTextField(labelWithString: "")
    private let actionButton = NSButton()
    private let cancelButton = NSButton()
    private let spinner = NSProgressIndicator()
    private let failure = NSTextField(wrappingLabelWithString: "")
    private var setup: DependencySetup?
    private var fetch: AppModel.DependencyFetch?

    init() {
        super.init(frame: .zero)
        let icon = NSImageView(image: NSImage(
            systemSymbolName: "shippingbox",
            accessibilityDescription: nil
        ) ?? NSImage())
        icon.contentTintColor = .systemOrange
        let title = NSTextField(labelWithString: localized("main.deps.title"))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let header = NSStackView(views: [icon, title])
        header.spacing = 6

        let summary = NSTextField(wrappingLabelWithString: localized("main.deps.summary"))
        summary.font = .systemFont(ofSize: 11)
        summary.textColor = .secondaryLabelColor

        directoryLabel.font = .systemFont(ofSize: 10)
        directoryLabel.textColor = .tertiaryLabelColor
        directoryLabel.lineBreakMode = .byTruncatingHead
        commandLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        commandLabel.isSelectable = true
        commandLabel.lineBreakMode = .byTruncatingTail
        let copy = NSButton(
            image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: localized("main.deps.copy"))
                ?? NSImage(),
            target: self,
            action: #selector(copyCommand(_:))
        )
        copy.isBordered = false
        copy.toolTip = localized("main.deps.copy")
        let commandRow = NSStackView(views: [commandLabel, copy])
        commandRow.spacing = 6
        commandLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let card = NSStackView(views: [directoryLabel, commandRow])
        card.orientation = .vertical
        card.alignment = .leading
        card.spacing = 2
        card.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 6)
        card.wantsLayer = true
        card.layer?.cornerRadius = 6
        card.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.12).cgColor

        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        failure.font = .systemFont(ofSize: 11)
        failure.textColor = .systemRed
        failure.isSelectable = true

        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .small
        actionButton.target = self
        actionButton.action = #selector(performAction(_:))
        actionButton.keyEquivalent = "\r"
        cancelButton.title = localized("main.deps.cancel")
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .small
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let actions = NSStackView(views: [actionButton, spinner, cancelButton])
        actions.spacing = 8

        let stack = NSStackView(views: [header, summary, card, note, failure, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.widthAnchor.constraint(equalTo: stack.widthAnchor),
            summary.widthAnchor.constraint(equalTo: stack.widthAnchor),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor),
            failure.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(setup: DependencySetup, fetch: AppModel.DependencyFetch?) {
        self.setup = setup
        self.fetch = fetch
        directoryLabel.stringValue = (setup.directory.path as NSString).abbreviatingWithTildeInPath
        commandLabel.stringValue = "$ " + setup.command
        commandLabel.toolTip = setup.command
        let running = fetch == .running
        let fetchedHere = fetch == .finished(setup.directory)
        failure.stringValue = if case let .failed(reason) = fetch { reason } else { "" }
        failure.isHidden = failure.stringValue.isEmpty
        if !setup.runsInApp {
            note.stringValue = localized(setup.command.hasPrefix("cargo")
                ? "main.deps.note.unlocked" : "main.deps.note.terminal")
            actionButton.title = localized("main.deps.open.terminal")
        } else if fetchedHere {
            note.stringValue = localized("main.deps.note.remaining")
        } else {
            note.stringValue = localized("main.deps.note.fetch")
            actionButton.title = localized(running ? "main.deps.fetching"
                : fetch == nil ? "main.deps.fetch" : "main.deps.retry")
        }
        actionButton.isHidden = setup.runsInApp && fetchedHere
        actionButton.isEnabled = !running
        cancelButton.isHidden = !running
        if running { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    @objc private func copyCommand(_ sender: Any?) {
        guard let setup else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(setup.command, forType: .string)
    }

    @objc private func performAction(_ sender: Any?) {
        guard let setup else { return }
        if setup.runsInApp {
            onFetch()
            return
        }
        // The command is on the clipboard; Terminal opens in its directory.
        copyCommand(nil)
        guard let terminal = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.Terminal"
        ) else { return }
        NSWorkspace.shared.open(
            [setup.directory],
            withApplicationAt: terminal,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    @objc private func cancel(_ sender: Any?) {
        onCancel()
    }
}
