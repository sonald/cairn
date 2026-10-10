import AppKit
import CodeInsightAppModel
import CodeInsightReaderCore
import CodeInsightReaderUI

@MainActor
final class EmptyStateView: NSView {
    private let titleLabel = NSTextField(labelWithString: "Cairn")
    private let taglineLabel = NSTextField(
        labelWithString: localized("welcome.tagline")
    )
    private let reasonLabel = NSTextField(
        wrappingLabelWithString: ""
    )
    private let markView = NSImageView()
    private let openButton = NSButton()
    private let chooseFolderButton = NSButton()
    private let recentStack = NSStackView()
    private let columns = NSStackView()
    private var recentPaths: [String] = []
    /// Short language labels (RS, PY, TS…) per recent path; empty when unknown.
    private var recentTrusted: Set<String> = []
    private var recentLastRead: [String: Date] = [:]
    private var isFailure = false
    private let dropHint = NSTextField(labelWithString: localized("welcome.dropHint"))
    private(set) var theme = ReaderTheme(settings: ReaderSettings())

    private let onChooseProject: () -> Void
    private let onOpenRecent: (URL) -> Void
    private let onOpenDropped: (URL) -> Void
    private let onRetry: () -> Void

    init(
        recentPaths: [String],
        failed: Bool,
        onChooseProject: @escaping () -> Void,
        onOpenRecent: @escaping (URL) -> Void,
        onOpenDropped: @escaping (URL) -> Void,
        onRetry: @escaping () -> Void
    ) {
        self.onChooseProject = onChooseProject
        self.onOpenRecent = onOpenRecent
        self.onOpenDropped = onOpenDropped
        self.onRetry = onRetry
        super.init(frame: .zero)

        registerForDraggedTypes([.fileURL])
        wantsLayer = true

        markView.image = cairnMarkImage(size: CGSize(width: 48, height: 48))
        markView.imageScaling = .scaleNone
        markView.setAccessibilityIdentifier("CairnMark")
        markView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = cairnSerifFont(ofSize: 34)
        titleLabel.alignment = .left
        taglineLabel.font = cairnItalicSerifFont(ofSize: 19)
        taglineLabel.alignment = .left
        // Short, bounded failure reason; selectable so it stays copyable.
        reasonLabel.font = .systemFont(ofSize: 13)
        reasonLabel.alignment = .left
        reasonLabel.isSelectable = true
        reasonLabel.setContentHuggingPriority(
            .defaultLow,
            for: .horizontal
        )
        reasonLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 460)
            .isActive = true
        reasonLabel.setAccessibilityLabel(localized("welcome.openFailure"))

        openButton.bezelStyle = .rounded
        openButton.target = self
        openButton.action = #selector(openOrRetry(_:))
        openButton.setAccessibilityLabel(localized("welcome.open"))

        chooseFolderButton.bezelStyle = .rounded
        chooseFolderButton.title = localized("welcome.otherFolder")
        chooseFolderButton.target = self
        chooseFolderButton.action = #selector(chooseFolder(_:))
        chooseFolderButton.setAccessibilityLabel(localized("welcome.otherFolderAX"))
        chooseFolderButton.isHidden = true

        dropHint.font = .systemFont(ofSize: 11.5)
        dropHint.alignment = .left

        recentStack.orientation = .vertical
        recentStack.alignment = .leading
        recentStack.spacing = 4

        let stack = NSStackView(views: [
            markView,
            titleLabel,
            taglineLabel,
            reasonLabel,
            openButton,
            chooseFolderButton,
            dropHint,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.setCustomSpacing(14, after: markView)
        stack.setCustomSpacing(2, after: titleLabel)
        stack.setCustomSpacing(18, after: taglineLabel)
        stack.setCustomSpacing(16, after: reasonLabel)
        stack.setCustomSpacing(8, after: openButton)
        stack.setCustomSpacing(24, after: chooseFolderButton)
        // Welcome reads as two columns: the wordmark and actions on the left,
        // recent projects on the right; narrow views stack them.
        columns.setViews([stack, recentStack], in: .leading)
        columns.orientation = .horizontal
        columns.alignment = .centerY
        columns.spacing = 72
        columns.translatesAutoresizingMaskIntoConstraints = false
        addSubview(columns)

        NSLayoutConstraint.activate([
            markView.widthAnchor.constraint(equalToConstant: 48),
            markView.heightAnchor.constraint(equalToConstant: 48),
            openButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            recentStack.widthAnchor.constraint(equalToConstant: 380),
            columns.centerXAnchor.constraint(equalTo: centerXAnchor),
            columns.centerYAnchor.constraint(equalTo: centerYAnchor),
            columns.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            columns.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            columns.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 24),
            columns.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -24),
        ])

        update(recentPaths: recentPaths, failed: failed, reason: nil)
        apply(theme: theme)
    }

    func apply(theme: ReaderTheme) {
        self.theme = theme
        layer?.backgroundColor = theme.backgroundColor.cgColor
        titleLabel.textColor = theme.foregroundColor
        taglineLabel.textColor = theme.accentColor
        reasonLabel.textColor = theme.chromeSecondaryColor
        dropHint.textColor = theme.chromeSecondaryColor
        rebuildRecents()
    }

    var selfTestTaglineColor: NSColor? { taglineLabel.textColor }
    var selfTestColumnsAreSideBySide: Bool { columns.orientation == .horizontal }
    var selfTestRecentFrames: (actions: NSRect, recents: NSRect) {
        (columns.arrangedSubviews.first.map { $0.convert($0.bounds, to: nil) } ?? .zero,
         recentStack.convert(recentStack.bounds, to: nil))
    }

    /// Trusted repositories and each project's last reading time, when known.
    func updateRecentStatus(trusted: Set<String>, lastRead: [String: Date]) {
        guard trusted != recentTrusted || lastRead != recentLastRead else { return }
        recentTrusted = trusted
        recentLastRead = lastRead
        rebuildRecents()
    }

    func selfTestRecentTitle(path: String) -> NSAttributedString? {
        recentStack.arrangedSubviews.compactMap { $0 as? NSButton }
            .first { $0.toolTip == path }?.attributedTitle
    }

    override func layout() {
        // Two columns need about 780pt; below that the recents move under the actions.
        let horizontal = bounds.width >= 820
        if (columns.orientation == .horizontal) != horizontal {
            columns.orientation = horizontal ? .horizontal : .vertical
            columns.alignment = horizontal ? .centerY : .leading
            columns.spacing = horizontal ? 72 : 32
        }
        super.layout()
    }
    var selfTestTitleFont: NSFont? { titleLabel.font }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        recentPaths: [String],
        failed: Bool,
        reason: String?
    ) {
        isFailure = failed
        titleLabel.stringValue = failed ? localized("welcome.failed") : "Cairn"
        openButton.title = failed ? localized("welcome.retry") : localized("welcome.openShortcut")
        // Fixed ⏎ keycap, registered as panel.openSelection in the key
        // binding table (K0a); the chord application goes through the
        // KeyBindings+AppKit adapter.
        openButton.applyKeyChord(KeyChord(modifiers: [], key: .special(.return)))
        let trimmedReason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        reasonLabel.stringValue = failed ? (trimmedReason ?? "") : ""
        reasonLabel.isHidden = !failed || trimmedReason == nil
        chooseFolderButton.isHidden = !failed

        let visiblePaths = Array(recentPaths.prefix(5))
        guard visiblePaths != self.recentPaths else { return }
        self.recentPaths = visiblePaths
        rebuildRecents()
    }

    var selfTestTextValues: [String] {
        [titleLabel.stringValue, taglineLabel.stringValue, reasonLabel.stringValue]
    }

    var selfTestButtonTitles: [String] {
        var titles = [openButton.title]
        if !chooseFolderButton.isHidden { titles.append(chooseFolderButton.title) }
        return titles
    }

    var selfTestFailureReason: String? {
        reasonLabel.isHidden ? nil : reasonLabel.stringValue
    }

    var selfTestReasonIsSelectable: Bool {
        !reasonLabel.isHidden && reasonLabel.isSelectable
    }

    var selfTestChooseFolderActionAvailable: Bool {
        !chooseFolderButton.isHidden && chooseFolderButton.action
            == #selector(chooseFolder(_:))
    }

    var selfTestAttachedToWindow: Bool { window != nil }
    var selfTestUnhidden: Bool { !isHiddenOrHasHiddenAncestor }
    var selfTestFrameVisibleInWindow: Bool { selfTestIsVisibleInWindow }
    var selfTestMarkVisibleInWindow: Bool {
        markView.selfTestIsVisibleInWindow
    }
    var selfTestMarkIs48Square: Bool {
        abs(markView.frame.width - 48) < 0.01
            && abs(markView.frame.height - 48) < 0.01
    }
    var selfTestMarkUsesCairnDrawing: Bool {
        markView.accessibilityIdentifier() == "CairnMark"
    }
    var selfTestTitleVisibleInWindow: Bool { titleLabel.selfTestIsVisibleInWindow }
    var selfTestButtonVisibleInWindow: Bool { openButton.selfTestIsVisibleInWindow }
    var selfTestOpenButtonIsVisibleDefaultAction: Bool {
        openButton.selfTestIsVisibleInWindow
            && openButton.keyEquivalent == "\r"
            && window?.defaultButtonCell === openButton.cell
    }

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
        onOpenDropped(root)
        return true
    }

    @objc private func openOrRetry(_ sender: Any?) {
        if isFailure {
            onRetry()
        } else {
            onChooseProject()
        }
    }

    @objc private func chooseFolder(_ sender: Any?) {
        onChooseProject()
    }

    @objc private func openRecent(_ sender: NSButton) {
        guard recentPaths.indices.contains(sender.tag) else { return }
        onOpenRecent(URL(
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

        let heading = NSTextField(labelWithString: localized("welcome.recent"))
        heading.font = .systemFont(ofSize: 10.5, weight: .semibold)
        heading.textColor = theme.chromeSecondaryColor
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
            button.attributedTitle = Self.recentTitle(
                path: path,
                trusted: recentTrusted.contains(path),
                lastRead: recentLastRead[path],
                theme: theme
            )
            button.hoverColor = theme.mossSoftColor
            button.toolTip = path
            button.setAccessibilityLabel(localizedFormat("welcome.openRecent", URL(fileURLWithPath: path).lastPathComponent))
            recentStack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: recentStack.widthAnchor).isActive = true
            button.heightAnchor.constraint(equalToConstant: 42).isActive = true

            Task { @MainActor [weak button] in
                let image = NSWorkspace.shared.icon(forFile: path)
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
        layer?.borderColor = highlighted ? theme.accentColor.cgColor : nil
        layer?.cornerRadius = 14
    }

    private static func recentTitle(
        path: String,
        trusted: Bool,
        lastRead: Date?,
        theme: ReaderTheme
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineSpacing = 1
        let title = NSMutableAttributedString(
            string: URL(fileURLWithPath: path).lastPathComponent,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: theme.foregroundColor,
                .paragraphStyle: paragraph,
            ]
        )
        // Safe is the default; only a trusted repository is worth a mark.
        if trusted {
            title.append(NSAttributedString(
                string: "  \(localized("main.trusted"))",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
                    .foregroundColor: theme.warningColor,
                    .paragraphStyle: paragraph,
                ]
            ))
        }
        let detailAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: theme.chromeSecondaryColor,
            .paragraphStyle: paragraph,
        ]
        title.append(NSAttributedString(
            string: "\n" + (path as NSString).abbreviatingWithTildeInPath,
            attributes: detailAttributes
        ))
        if let lastRead {
            title.append(NSAttributedString(
                string: " · " + RelativeDateTimeFormatter().localizedString(for: lastRead, relativeTo: Date()),
                attributes: detailAttributes.merging([.font: NSFont.systemFont(ofSize: 11)]) { $1 }
            ))
        }
        return title
    }
}

@MainActor
private final class HoverButton: NSButton {
    private var hoverTrackingArea: NSTrackingArea?
    var hoverColor: NSColor = .clear

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
        layer?.backgroundColor = hoverColor.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
    }
}

