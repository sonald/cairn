import AppKit
import CodeInsightAppModel
import CodeInsightReaderCore
import CodeInsightReaderUI

/// Pasteboard type carried by a panel title-bar drag (`PanelID` raw value).
let panelPasteboardType = NSPasteboard.PasteboardType("dev.cairn.panel")

/// A movable panel: a title bar (title, accessories, ⋯ menu, ×) above the
/// hosted view. The title bar is the drag source; the panel's own view is
/// never rebuilt while it moves between zones.
@MainActor
final class PanelChromeView: NSView, NSDraggingSource {
    let id: PanelID
    weak var host: MainWindowController?
    private let header = NSView()
    private let titleLabel: NSTextField
    private let moreButton = NSButton()
    private let closeButton = NSButton()
    private let divider = NSView()
    private var accessories: [NSButton] = []
    private var pendingDrag: NSEvent?
    static let headerHeight: CGFloat = 26

    /// Minimum height inside a zone, enforced at the zone's dividers.
    var minimumHeight: CGFloat {
        switch id {
        case .context: 120
        case .search: 240
        default: 80
        }
    }

    /// The zone keeps at least the widest minimum of its panels (soft).
    var minimumWidth: CGFloat { id == .relations || id == .search ? 300 : 180 }

    init(id: PanelID, title: String, content: NSView, accessories: [NSButton] = []) {
        self.id = id
        titleLabel = NSTextField(labelWithString: title)
        self.accessories = accessories
        super.init(frame: .zero)
        wantsLayer = true
        header.wantsLayer = true
        divider.wantsLayer = true
        titleLabel.font = .systemFont(ofSize: 11.5, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for (button, symbol, help, action) in [
            (moreButton, "ellipsis", localized("panel.options"), #selector(showOptions(_:))),
            (closeButton, "xmark", localized("panel.close"), #selector(closePanel(_:))),
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
            button.isBordered = false
            button.controlSize = .small
            button.target = self
            button.action = action
            button.toolTip = help
            button.setAccessibilityLabel(help)
            button.widthAnchor.constraint(equalToConstant: 20).isActive = true
        }
        let stack = NSStackView(views: [titleLabel] + accessories + [moreButton, closeButton])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.setCustomSpacing(8, after: titleLabel)
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 6)
        stack.setHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for view in [header, stack, divider, content] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        header.addSubview(stack)
        addSubview(header)
        addSubview(divider)
        addSubview(content)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: Self.headerHeight),
            stack.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            stack.topAnchor.constraint(equalTo: header.topAnchor),
            stack.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            divider.topAnchor.constraint(equalTo: header.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
            content.topAnchor.constraint(equalTo: divider.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func apply(theme: ReaderTheme) {
        layer?.backgroundColor = theme.chromeColor.cgColor
        header.layer?.backgroundColor = theme.chromeHeaderColor.cgColor
        divider.layer?.backgroundColor = theme.chromeDividerColor.cgColor
        titleLabel.textColor = theme.foregroundColor
        for button in [moreButton, closeButton] + accessories {
            button.contentTintColor = theme.chromeSecondaryColor
        }
    }

    // MARK: Title-bar menu

    @objc private func showOptions(_ sender: NSButton) {
        guard let host else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let zone = host.panelLayout.zone(of: id).zone
        for (title, action, enabled) in [
            (localized("panel.move.left"), #selector(panelMoveLeft(_:)), zone != .left),
            (localized("panel.move.right"), #selector(panelMoveRight(_:)), zone != .right),
            (localized("panel.move.up"), #selector(panelMoveUp(_:)), host.canShiftPanel(id, by: -1)),
            (localized("panel.move.down"), #selector(panelMoveDown(_:)), host.canShiftPanel(id, by: 1)),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let close = NSMenuItem(title: localized("panel.close"), action: #selector(closePanel(_:)), keyEquivalent: "")
        close.target = self
        menu.addItem(close)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc private func panelMoveLeft(_ sender: Any?) { host?.movePanel(id, to: .left) }
    @objc private func panelMoveRight(_ sender: Any?) { host?.movePanel(id, to: .right) }
    @objc private func panelMoveUp(_ sender: Any?) { host?.shiftPanel(id, by: -1) }
    @objc private func panelMoveDown(_ sender: Any?) { host?.shiftPanel(id, by: 1) }
    @objc private func closePanel(_ sender: Any?) { host?.setPanelVisible(id, false) }

    // MARK: Dragging source

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard header.frame.contains(point) else { return super.mouseDown(with: event) }
        pendingDrag = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pendingDrag else { return super.mouseDragged(with: event) }
        let a = start.locationInWindow, b = event.locationInWindow
        guard hypot(b.x - a.x, b.y - a.y) >= 3 else { return }
        pendingDrag = nil
        let item = NSPasteboardItem()
        item.setString(id.rawValue, forType: panelPasteboardType)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        // Only the title bar travels with the pointer, at its own frame.
        let image = NSImage(size: header.bounds.size)
        if let rep = header.bitmapImageRepForCachingDisplay(in: header.bounds) {
            header.cacheDisplay(in: header.bounds, to: rep)
            image.addRepresentation(rep)
        }
        dragItem.setDraggingFrame(header.frame, contents: image)
        beginDraggingSession(with: [dragItem], event: start, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if pendingDrag == nil { super.mouseUp(with: event) }
        pendingDrag = nil
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        host?.panelDragBegan()
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        host?.panelDragEnded()
    }
}

/// One side zone: panels stacked in a vertical split view, and the drop
/// target for panel drags. Drop positions are computed in the split view's
/// own (flipped) coordinates: the upper half of a panel drops before it.
@MainActor
final class PanelZoneView: NSView, NSSplitViewDelegate {
    let zone: PanelZone
    weak var host: MainWindowController?
    let split = DividerTrackingSplitView()
    private let indicator = NSView()
    private let dropLabel = NSTextField(labelWithString: localized("panel.drop.here"))
    private var dropIndex = 0
    private var minimumWidthConstraint: NSLayoutConstraint?
    private(set) var panels: [PanelChromeView] = []

    init(zone: PanelZone) {
        self.zone = zone
        super.init(frame: .zero)
        wantsLayer = true
        split.isVertical = false
        split.dividerStyle = .thin
        split.delegate = self
        split.onDividerDragEnded = { [weak self] in self?.host?.dividerDragEnded() }
        split.translatesAutoresizingMaskIntoConstraints = false
        addSubview(split)
        indicator.wantsLayer = true
        indicator.isHidden = true
        addSubview(indicator)
        dropLabel.alignment = .center
        dropLabel.font = .systemFont(ofSize: 11)
        dropLabel.isHidden = true
        dropLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dropLabel)
        // Soft: a narrow window squeezes the zone rather than growing.
        let minimum = widthAnchor.constraint(greaterThanOrEqualToConstant: 0)
        minimum.priority = .init(rawValue: 495)
        minimumWidthConstraint = minimum
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: topAnchor),
            split.bottomAnchor.constraint(equalTo: bottomAnchor),
            split.leadingAnchor.constraint(equalTo: leadingAnchor),
            split.trailingAnchor.constraint(equalTo: trailingAnchor),
            dropLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            dropLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            dropLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -8),
            minimum,
        ])
        registerForDraggedTypes([panelPasteboardType])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func apply(theme: ReaderTheme) {
        layer?.backgroundColor = theme.chromeColor.cgColor
        indicator.layer?.backgroundColor = theme.accentColor.cgColor
        dropLabel.textColor = theme.chromeSecondaryColor
    }

    /// Replaces the stacked panels; callers skip zones whose list is unchanged.
    func setPanels(_ next: [PanelChromeView]) {
        for view in panels where view.superview === split {
            split.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        panels = next
        next.forEach(split.addArrangedSubview)
        for index in next.indices { split.setHoldingPriority(.init(rawValue: 250), forSubviewAt: index) }
        dropLabel.isHidden = !next.isEmpty
        minimumWidthConstraint?.constant = next.map(\.minimumWidth).max() ?? 0
        split.adjustSubviews()
    }

    var measuredHeights: [Double] { panels.map { Double($0.frame.height) } }

    /// Sets panel heights from shares summing to 1, raising panels below
    /// their minimum when the zone is tall enough for all minimums.
    func applyHeights(_ fractions: [Double]) {
        guard panels.count > 1, fractions.count == panels.count else { return }
        layoutSubtreeIfNeeded()
        let available = split.bounds.height - split.dividerThickness * CGFloat(panels.count - 1)
        guard available > 0 else { return }
        var heights = fractions.map { CGFloat($0) * available }
        let minimums = panels.map(\.minimumHeight)
        if minimums.reduce(0, +) <= available {
            let deficit = zip(heights, minimums).map { max(0, $1 - $0) }.reduce(0, +)
            heights = zip(heights, minimums).map { max($0, $1) }
            let slack = zip(heights, minimums).map { $0 - $1 }
            let total = slack.reduce(0, +)
            if deficit > 0, total > 0 {
                heights = zip(heights, slack).map { $0 - deficit * $1 / total }
            }
        }
        var position: CGFloat = 0
        for index in 0..<(panels.count - 1) {
            position += heights[index]
            split.setPosition(position, ofDividerAt: index)
            position += split.dividerThickness
        }
    }

    // MARK: NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        guard panels.indices.contains(dividerIndex) else { return proposedMinimumPosition }
        let panel = panels[dividerIndex]
        return max(proposedMinimumPosition, panel.frame.minY + panel.minimumHeight)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        guard panels.indices.contains(dividerIndex + 1) else { return proposedMaximumPosition }
        let panel = panels[dividerIndex + 1]
        return min(proposedMaximumPosition, panel.frame.maxY - panel.minimumHeight - splitView.dividerThickness)
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }

    // MARK: Drop target

    private func dragIsOurs(_ sender: NSDraggingInfo) -> Bool {
        (sender.draggingSource as? PanelChromeView)?.window === window
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard dragIsOurs(sender) else { return [] }
        let point = split.convert(sender.draggingLocation, from: nil)
        let views = split.arrangedSubviews
        dropIndex = views.firstIndex { point.y < $0.frame.midY } ?? views.count
        let y = dropIndex < views.count ? views[dropIndex].frame.minY : (views.last?.frame.maxY ?? split.bounds.midY)
        indicator.frame = split.convert(NSRect(x: 4, y: y - 1, width: max(split.bounds.width - 8, 0), height: 2), to: self)
        indicator.isHidden = false
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { indicator.isHidden = true }

    override func draggingEnded(_ sender: NSDraggingInfo) { indicator.isHidden = true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        indicator.isHidden = true
        guard dragIsOurs(sender),
              let raw = sender.draggingPasteboard.string(forType: panelPasteboardType),
              let id = PanelID(rawValue: raw)
        else { return false }
        host?.dropPanel(id, in: zone, beforeShownIndex: dropIndex)
        return true
    }
}

/// A split view that reports when the user finishes dragging a divider.
/// NSSplitView tracks a divider drag synchronously inside `mouseDown`, and
/// only divider clicks reach it (its panes take their own), so returning from
/// `super` ends the drag. Layout passes, window resizes and `setPosition`
/// never come through here; their resize notifications look the same as a
/// drag's, which is why they cannot identify one.
@MainActor
final class DividerTrackingSplitView: NSSplitView {
    var onDividerDragEnded: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        onDividerDragEnded?()
    }
}

/// The panel's name in its title bar and in View → Panels.
func panelTitle(_ id: PanelID) -> String {
    switch id {
    case .files: localized("main.files")
    case .outline: localized("main.outline")
    case .relations: localized("app.menu.relations")
    case .context: localized("main.context")
    case .search: localized("panel.query.results")
    case .docs: localized("panel.docs")
    }
}
