import AppKit
import CodeInsightReaderCore
import CodeInsightReaderUI
import Foundation
import Testing
@testable import CodeInsightApp
@testable import CodeInsightAppModel

@MainActor
private func allSubviews(of view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap(allSubviews(of:))
}

@MainActor
private func srgb(_ color: CGColor?) -> UInt32? {
    guard let color, let converted = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else { return nil }
    return UInt32((converted.redComponent * 255).rounded()) << 16
        | UInt32((converted.greenComponent * 255).rounded()) << 8
        | UInt32((converted.blueComponent * 255).rounded())
}

@MainActor
@Test
func resolutionInspectorShowsSerifNarrativeAndAnInsetCorrectionBlock() throws {
    _ = NSApplication.shared
    let controller = RelationWindowController(
        model: RelationTreeModel(), languageMode: { _ in nil }
    )
    controller.apply(settings: ReaderSettings(theme: .light))
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false
    )
    window.contentViewController = controller
    defer { window.orderOut(nil) }

    let display = ReadingSetExcerpt.FrozenInspectorDisplay(
        nodeTitle: "AgentStepActor::on_stop", badge: .inferred,
        why: "Matched by method name only.",
        sourceBody: "Candidate generation was complete.",
        verificationTitle: "VERIFICATION",
        verificationBody: "The exact provider returned a different target.",
        correctionBody: "This target replaced earlier source candidates: mpsc::Sender::send.",
        availabilityBody: "Exact provider was ready at capture.",
        environmentBody: "Safe at capture.",
        auditRows: [.init(label: "Content", value: "73b28e")],
        accessibilityValue: "Inferred AgentStepActor::on_stop, at capture",
        capturedAt: Date(timeIntervalSince1970: 1_786_200_000),
        formerCandidateAvailable: false
    )
    controller.showFrozenInspector(display)
    window.contentView?.layoutSubtreeIfNeeded()
    window.displayIfNeeded()

    let views = allSubviews(of: controller.view)
    let why = try #require(views.compactMap { $0 as? NSTextField }
        .first { $0.stringValue == display.why })
    #expect(why.window === window && !why.isHiddenOrHasHiddenAncestor)
    let whyFont = try #require(why.font)
    #expect(whyFont.fontName.contains("NewYork") || whyFont.familyName?.contains("New York") == true)

    let correction = try #require(views.compactMap { $0 as? NSTextField }
        .first { $0.stringValue == display.correctionBody })
    let block = try #require(correction.superview as? NSStackView)
    #expect(!block.isHiddenOrHasHiddenAncestor)
    #expect(srgb(block.layer?.backgroundColor) == 0xF4DFD7)
    let blockFrame = block.convert(block.bounds, to: nil)
    let textFrame = correction.convert(correction.bounds, to: nil)
    #expect(textFrame.width > 0 && textFrame.height > 0)
    // NSTextField keeps a 2pt cell margin inside the 12pt stack inset.
    #expect(textFrame.minX >= blockFrame.minX + 9)
    #expect(textFrame.maxX <= blockFrame.maxX - 9)
    #expect(blockFrame.insetBy(dx: 9, dy: 9).contains(textFrame))
}
