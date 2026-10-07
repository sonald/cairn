@preconcurrency import AppKit

@MainActor
final class ReaderRulerView: NSRulerView {
    private weak var reader: ReaderTextView?
    private var hoverTrackingArea: NSTrackingArea?

    init(scrollView: NSScrollView, reader: ReaderTextView) {
        self.reader = reader
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        ruleThickness = 7
        clientView = reader.view
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        // This ruler has no system markers. Bypass NSRulerView's edge hairline
        // and clip only Cairn's custom pass so line numbers stay visible.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        reader?.drawRuler(in: self, dirtyRect: dirtyRect)
        NSGraphicsContext.restoreGraphicsState()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func mouseEntered(with event: NSEvent) {
        reader?.updateFoldHover(at: convert(event.locationInWindow, from: nil), in: self)
    }

    override func mouseMoved(with event: NSEvent) {
        reader?.updateFoldHover(at: convert(event.locationInWindow, from: nil), in: self)
    }

    override func mouseExited(with event: NSEvent) {
        reader?.updateFoldHover(at: nil, in: self)
    }

    override func mouseDown(with event: NSEvent) {
        reader?.clickFoldHandle(
            at: convert(event.locationInWindow, from: nil),
            in: self,
            modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        )
    }
}
