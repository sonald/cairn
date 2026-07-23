import AppKit
import CodeInsightAppModel

@MainActor
final class EmptyStateView: NSView {
    private let titleLabel = NSTextField(labelWithString: "Cairn")
    private let taglineLabel = NSTextField(
        labelWithString: "Read code without touching it."
    )
    private let openButton = NSButton()
    private let recentStack = NSStackView()
    private var recentPaths: [String] = []
    private var isFailure = false

    private let onChooseProject: () -> Void
    private let onOpenProject: (URL) -> Void
    private let onRetry: () -> Void

    init(
        recentPaths: [String],
        failed: Bool,
        onChooseProject: @escaping () -> Void,
        onOpenProject: @escaping (URL) -> Void,
        onRetry: @escaping () -> Void
    ) {
        self.onChooseProject = onChooseProject
        self.onOpenProject = onOpenProject
        self.onRetry = onRetry
        super.init(frame: .zero)

        registerForDraggedTypes([.fileURL])
        wantsLayer = true

        let symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 48,
            weight: .regular
        ).applying(.init(hierarchicalColor: .secondaryLabelColor))
        let symbol = NSImage(
            systemSymbolName: "square.stack.3d.up",
            accessibilityDescription: "Cairn"
        )?.withSymbolConfiguration(symbolConfiguration)
        let symbolView = NSImageView(image: symbol ?? NSImage())
        symbolView.contentTintColor = .secondaryLabelColor
        symbolView.imageScaling = .scaleProportionallyDown
        symbolView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 28, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        taglineLabel.font = .systemFont(ofSize: 13)
        taglineLabel.textColor = .secondaryLabelColor
        taglineLabel.alignment = .center

        openButton.bezelStyle = .rounded
        openButton.target = self
        openButton.action = #selector(openOrRetry(_:))
        openButton.setAccessibilityLabel("Open Project")

        let dropHint = NSTextField(labelWithString: "or drop a folder here")
        dropHint.font = .systemFont(ofSize: 11)
        dropHint.textColor = .secondaryLabelColor
        dropHint.alignment = .center

        recentStack.orientation = .vertical
        recentStack.alignment = .leading
        recentStack.spacing = 4

        let stack = NSStackView(views: [
            symbolView,
            titleLabel,
            taglineLabel,
            openButton,
            dropHint,
            recentStack,
        ])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 0
        stack.setCustomSpacing(12, after: symbolView)
        stack.setCustomSpacing(4, after: titleLabel)
        stack.setCustomSpacing(24, after: taglineLabel)
        stack.setCustomSpacing(8, after: openButton)
        stack.setCustomSpacing(32, after: dropHint)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            symbolView.widthAnchor.constraint(equalToConstant: 48),
            symbolView.heightAnchor.constraint(equalToConstant: 48),
            openButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            recentStack.widthAnchor.constraint(equalToConstant: 440),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -24),
        ])

        update(recentPaths: recentPaths, failed: failed)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(recentPaths: [String], failed: Bool) {
        isFailure = failed
        titleLabel.stringValue = failed ? "Couldn't open this folder." : "Cairn"
        openButton.title = failed ? "Try Again" : "Open Project…"
        openButton.keyEquivalent = failed ? "\r" : "o"
        openButton.keyEquivalentModifierMask = failed ? [] : .command

        let visiblePaths = Array(recentPaths.prefix(5))
        guard visiblePaths != self.recentPaths else { return }
        self.recentPaths = visiblePaths
        rebuildRecents()
    }

    var selfTestTextValues: [String] {
        [titleLabel.stringValue, taglineLabel.stringValue]
    }

    var selfTestButtonTitles: [String] {
        [openButton.title]
    }

    var selfTestAttachedToWindow: Bool { window != nil }
    var selfTestUnhidden: Bool { !isHiddenOrHasHiddenAncestor }
    var selfTestFrameVisibleInWindow: Bool { selfTestIsVisibleInWindow }
    var selfTestTitleVisibleInWindow: Bool { titleLabel.selfTestIsVisibleInWindow }
    var selfTestButtonVisibleInWindow: Bool { openButton.selfTestIsVisibleInWindow }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateDropHighlight(for: sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateDropHighlight(for: sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        setDropHighlighted(false)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = draggedURLs(from: sender)
        guard isAcceptedProjectDrop(urls), let root = urls.first else {
            setDropHighlighted(false)
            return false
        }
        setDropHighlighted(false)
        onOpenProject(root)
        return true
    }

    @objc private func openOrRetry(_ sender: Any?) {
        if isFailure {
            onRetry()
        } else {
            onChooseProject()
        }
    }

    @objc private func openRecent(_ sender: NSButton) {
        guard recentPaths.indices.contains(sender.tag) else { return }
        onOpenProject(URL(
            fileURLWithPath: recentPaths[sender.tag],
            isDirectory: true
        ))
    }

    private func rebuildRecents() {
        recentStack.arrangedSubviews.forEach {
            recentStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        recentStack.isHidden = recentPaths.isEmpty
        guard !recentPaths.isEmpty else { return }

        let heading = NSTextField(labelWithString: "RECENT")
        heading.font = .systemFont(ofSize: 11, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        recentStack.addArrangedSubview(heading)

        for (index, path) in recentPaths.enumerated() {
            let button = HoverButton(
                title: "",
                target: self,
                action: #selector(openRecent(_:))
            )
            button.tag = index
            button.isBordered = false
            button.imagePosition = .imageLeading
            button.imageScaling = .scaleProportionallyDown
            button.alignment = .left
            button.attributedTitle = Self.recentTitle(path: path)
            button.toolTip = path
            button.setAccessibilityLabel("Open \(URL(fileURLWithPath: path).lastPathComponent)")
            recentStack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: recentStack.widthAnchor).isActive = true
            button.heightAnchor.constraint(equalToConstant: 42).isActive = true

            Task { @MainActor [weak button] in
                let image = await Task.detached(priority: .utility) {
                    NSWorkspace.shared.icon(forFile: path)
                }.value
                image.size = NSSize(width: 28, height: 28)
                button?.image = image
            }
        }
    }

    private func updateDropHighlight(
        for sender: any NSDraggingInfo
    ) -> NSDragOperation {
        let accepted = isAcceptedProjectDrop(draggedURLs(from: sender))
        setDropHighlighted(accepted)
        return accepted ? .copy : []
    }

    private func draggedURLs(from sender: any NSDraggingInfo) -> [URL] {
        let objects = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [NSURL] ?? []
        return objects.map { $0 as URL }
    }

    private func setDropHighlighted(_ highlighted: Bool) {
        layer?.borderWidth = highlighted ? 2 : 0
        layer?.borderColor = highlighted ? NSColor.controlAccentColor.cgColor : nil
        layer?.cornerRadius = 14
    }

    private static func recentTitle(path: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineSpacing = 1
        let title = NSMutableAttributedString(
            string: "\(URL(fileURLWithPath: path).lastPathComponent)\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
        )
        title.append(NSAttributedString(
            string: (path as NSString).abbreviatingWithTildeInPath,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.tertiaryLabelColor,
                .paragraphStyle: paragraph,
            ]
        ))
        return title
    }
}

@MainActor
private final class HoverButton: NSButton {
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(area)
        hoverTrackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor.controlAccentColor
            .withAlphaComponent(0.10).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
    }
}

private extension NSView {
    var selfTestIsVisibleInWindow: Bool {
        guard let window, let contentView = window.contentView,
              !isHiddenOrHasHiddenAncestor,
              bounds.width > 0, bounds.height > 0
        else { return false }
        let frameInWindow = convert(bounds, to: nil)
        let contentFrameInWindow = contentView.convert(contentView.bounds, to: nil)
        let visibleFrame = frameInWindow.intersection(contentFrameInWindow)
        return visibleFrame.width > 0 && visibleFrame.height > 0
    }
}
