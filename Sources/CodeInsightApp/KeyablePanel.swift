import AppKit

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
