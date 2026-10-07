@preconcurrency import AppKit

@MainActor
final class ClickTextView: NSTextView, NSTextViewDelegate {
    private var projectionRestoreRanges: [NSValue]?

    /// Setting NSRange+affinity loses AppKit's reverse Shift-extension anchor.
    /// One native command establishes it; the public delegate supplies the full
    /// target range instead of requiring one command per selected character.
    func restoreProjectionRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity) {
        guard ranges.count == 1, affinity == .upstream,
              let range = ranges.first?.rangeValue, range.length > 0 else {
            setSelectedRanges(ranges, affinity: affinity, stillSelecting: false)
            return
        }
        let previousDelegate = delegate
        setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
        projectionRestoreRanges = ranges
        delegate = self
        defer {
            projectionRestoreRanges = nil
            delegate = previousDelegate
        }
        // Direct command, not a synthesized key event: selectionHandler remains
        // reserved for actual user gestures and must not erase latent ranges.
        super.moveLeftAndModifySelection(nil)
    }

    func textView(
        _ textView: NSTextView, willChangeSelectionFromCharacterRanges oldSelectedCharRanges: [NSValue],
        toCharacterRanges newSelectedCharRanges: [NSValue]
    ) -> [NSValue] {
        projectionRestoreRanges ?? newSelectedCharRanges
    }


    // Code is top-left aligned. AppKit's inferred origin can force full-document
    // layout during scrolling; all native drawing and hit-testing use this origin.
    override var textContainerOrigin: NSPoint {
        NSPoint(x: textContainerInset.width, y: textContainerInset.height)
    }

    var clickHandler: ((Int, NSEvent.ModifierFlags) -> Void)?
    /// Consumes a click on drawn chrome (block-end labels) before selection.
    var annotationClickHandler: ((NSPoint) -> Bool)?
    var sourceCopyHandler: (() -> String?)?
    var contextMenuHandler: ((Int) -> Void)?
    var selectionHandler: ((Int) -> Void)?
    var viewportChanged: (() -> Void)?
    var userScrollHandler: (() -> Void)?
    var layoutCompleted: (() -> Void)?
    var escapeHandler: (() -> Bool)?
    var backgroundHandler: ((NSRect) -> Void)?
    /// Narrow size-change hooks (reader-wrap design D3.7): fired from
    /// setFrameSize only when the width actually changes. The will-change
    /// call is the last point where the pre-resize geometry is still
    /// observable; AppKit's own resize notifications are strictly
    /// after-the-fact (see the S0 resize-timing probe).
    var widthWillChange: ((CGFloat) -> Void)?
    var widthDidChange: ((CGFloat) -> Void)?
    /// Pointer location in view coordinates, or `nil` when it left the text.
    var hoverHandler: ((NSPoint?) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?
    private var viewportBounds: NSRect?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        hoverHandler?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if event.trackingArea === hoverTrackingArea { hoverHandler?(nil) }
    }
    var viewportNeedsValidationAfterLayout = false

    override func setFrameSize(_ newSize: NSSize) {
        let oldWidth = bounds.width
        let widthChanged = abs(newSize.width - oldWidth) > 0.01
        if widthChanged { widthWillChange?(oldWidth) }
        super.setFrameSize(newSize)
        if widthChanged { widthDidChange?(newSize.width) }
    }

    override func layout() {
        super.layout()
        // A scroll can notify before TextKit has moved its viewport. Style once
        // after that move, not on every otherwise unchanged layout/display pass.
        if viewportNeedsValidationAfterLayout {
            viewportNeedsValidationAfterLayout = false
            layoutCompleted?()
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        NotificationCenter.default.removeObserver(
            self,
            name: NSView.boundsDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.removeObserver(self, name: NSScrollView.willStartLiveScrollNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSScrollView.didLiveScrollNotification, object: nil)
        guard let scrollView = enclosingScrollView else { return }
        let clipView = scrollView.contentView
        for name in [NSScrollView.willStartLiveScrollNotification, NSScrollView.didLiveScrollNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(userDidScroll(_:)), name: name, object: scrollView)
        }
        viewportBounds = clipView.bounds
        viewportNeedsValidationAfterLayout = true
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(viewportDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1,
           annotationClickHandler?(convert(event.locationInWindow, from: nil)) == true {
            return
        }
        let index = characterIndex(for: event)
        super.mouseDown(with: event)
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let selection = selectedRange()
        let selectedAttachment = selectedRanges.count == 1 && selection.length == 1
            && (selection.location == index || selection.location == index - 1)
            && selection.location < (textStorage?.length ?? 0)
            && textStorage?.attribute(.attachment, at: selection.location, effectiveRange: nil) != nil
        // Native drag/Shift-click/word selection owns its range and affinity.
        // Activating a token here would replace it and can also trigger navigation.
        if !modifiers.contains(.command), !selectedAttachment,
           selectedRanges.contains(where: { $0.rangeValue.length > 0 }) {
            selectionHandler?(selection.location)
            return
        }
        clickHandler?(index, modifiers)
    }

    override func showFindIndicator(for charRange: NSRange) {
        // An unattached/closed reader has no native geometry for the deferred effect.
        guard window?.isVisible == true else { return }
        super.showFindIndicator(for: charRange)
    }

    override func writeSelection(
        to pasteboard: NSPasteboard, types: [NSPasteboard.PasteboardType]
    ) -> Bool {
        guard let sourceCopyHandler else { return super.writeSelection(to: pasteboard, types: types) }
        guard types.contains(.string) || types.contains(where: { $0.rawValue == "NSStringPboardType" }),
              let source = sourceCopyHandler() else { return false }
        pasteboard.declareTypes([.string], owner: nil)
        return pasteboard.setString(source, forType: .string)
    }

    override func writeSelection(
        to pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType
    ) -> Bool {
        guard let sourceCopyHandler else { return super.writeSelection(to: pasteboard, type: type) }
        guard type == .string || type.rawValue == "NSStringPboardType",
              let source = sourceCopyHandler() else { return false }
        return pasteboard.setString(source, forType: .string)
    }

    override func copy(_ sender: Any?) {
        guard let sourceCopyHandler else { super.copy(sender); return }
        guard let source = sourceCopyHandler() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([source as NSString])
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuHandler?(characterIndex(for: event))
        return super.menu(for: event)
    }

    override func keyDown(with event: NSEvent) {
        super.keyDown(with: event)
        selectionHandler?(selectedRange().location)
    }

    override func cancelOperation(_ sender: Any?) {
        if escapeHandler?() != true {
            super.cancelOperation(sender)
        }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        backgroundHandler?(rect)
    }

    override func scrollWheel(with event: NSEvent) {
        userScrollHandler?()
        super.scrollWheel(with: event)
    }

    @objc private func userDidScroll(_ notification: Notification) {
        // Synchronous: a queued restore must not run between user input and cancellation.
        userScrollHandler?()
    }

    @objc private func viewportDidChange(_ notification: Notification) {
        guard let clipView = notification.object as? NSClipView,
              clipView.bounds != viewportBounds
        else { return }
        let moved = clipView.bounds.origin != viewportBounds?.origin
        viewportBounds = clipView.bounds
        viewportNeedsValidationAfterLayout = true
        if moved { viewportChanged?() }
    }
}

@MainActor
private extension NSTextView {
    func characterIndex(for event: NSEvent) -> Int {
        characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
    }
}
