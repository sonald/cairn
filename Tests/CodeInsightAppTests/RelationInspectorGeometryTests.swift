import AppKit
import Foundation
import Testing
@testable import CodeInsightApp
@testable import CodeInsightAppModel

@MainActor
@Test
func relationInspectorDividerPreservesGeometryAndFrozenEvidenceAcrossLayouts() throws {
    _ = NSApplication.shared
    let controller = RelationWindowController(
        model: RelationTreeModel(), languageMode: { _ in nil }
    )
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false
    )
    window.contentViewController = controller
    defer { window.orderOut(nil) }

    func layout() {
        window.contentView?.layoutSubtreeIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }
    func resize(to width: CGFloat) {
        window.setContentSize(NSSize(width: width, height: 620))
        controller.view.needsLayout = true
        layout()
    }
    resize(to: 900)
    let display = ReadingSetExcerpt.FrozenInspectorDisplay(
        nodeTitle: "load_archive", badge: .verified,
        why: "The provider confirmed this target at capture.",
        sourceBody: Array(repeating:
            "Captured source: archive.rs:42, content 73b28e; evidence belongs to this recorded revision.",
            count: 8
        ).joined(separator: "\n"),
        verificationTitle: "VERIFICATION",
        verificationBody: "The captured provider result refers to this definition.",
        correctionBody: "", availabilityBody: "Provider ready at capture",
        environmentBody: "Trusted workspace at capture",
        auditRows: [.init(label: "Content", value: "73b28e")],
        accessibilityValue: "Verified load_archive, at capture",
        capturedAt: Date(timeIntervalSince1970: 1_786_200_000),
        formerCandidateAvailable: false
    )
    controller.showFrozenInspector(display)
    layout()
    let split = try #require(inspectorGeometryViews(in: controller.view)
        .compactMap { $0 as? NSSplitView }
        .first { $0.isVertical && $0.subviews.count == 2 })
    let close = try #require(inspectorGeometryViews(in: controller.view)
        .compactMap { $0 as? NSButton }
        .first { $0.accessibilityLabel() == CodeInsightApp.localized("relation.inspector.close") })

    #expect(controller.selfTestInspectorIsFrozen)
    #expect(controller.selfTestInspectorText.contains(CodeInsightApp.localized("relation.capture")))
    #expect(controller.selfTestInspectorText.contains(display.sourceBody))
    let capturedText = controller.selfTestInspectorText

    split.setPosition(350, ofDividerAt: 0)
    layout()
    let firstList = controller.selfTestRelationListFrame
    let firstInspector = controller.selfTestInspectorFrame
    #expect(abs(firstList.width - 350) <= 2)
    #expect(firstList.width >= 280 && firstInspector.width >= 300)
    #expect(firstList.intersection(firstInspector).isEmpty)

    split.setPosition(500, ofDividerAt: 0)
    layout()
    #expect(controller.selfTestRelationListFrame.width > firstList.width + 140)
    #expect(controller.selfTestInspectorFrame.width < firstInspector.width - 140)
    #expect(controller.selfTestInspectorFrame.width >= 300)

    split.setPosition(350, ofDividerAt: 0)
    layout()
    #expect(abs(controller.selfTestRelationListFrame.width - firstList.width) <= 2)
    #expect(abs(controller.selfTestInspectorFrame.width - firstInspector.width) <= 2)
    let fraction = controller.selfTestRelationListFrame.width
        / (split.bounds.width - split.dividerThickness)

    resize(to: 610)
    #expect(!controller.selfTestListPaneHidden)
    #expect(controller.selfTestRelationListFrame.width >= 279)
    #expect(controller.selfTestInspectorFrame.width >= 299)
    #expect(controller.selfTestRelationListFrame.intersection(
        controller.selfTestInspectorFrame
    ).isEmpty)
    resize(to: 400)
    #expect(controller.selfTestListPaneHidden)
    #expect(abs(controller.selfTestInspectorFrame.width - split.bounds.width) <= 2)
    #expect(controller.selfTestInspectorText == capturedText)
    let sourceLabel = try #require(inspectorGeometryViews(in: controller.view)
        .compactMap { $0 as? NSTextField }.first { $0.stringValue == display.sourceBody })
    let inspectorScroll = try #require(sourceLabel.enclosingScrollView)
    let document = try #require(inspectorScroll.documentView)
    #expect(document.frame.width <= inspectorScroll.contentView.bounds.width + 1)
    #expect(sourceLabel.bounds.width <= inspectorScroll.contentView.bounds.width - 20)
    let measuredHeight = try #require(sourceLabel.cell).cellSize(forBounds: NSRect(
        x: 0, y: 0, width: sourceLabel.bounds.width, height: 10_000
    )).height
    #expect(sourceLabel.bounds.height >= measuredHeight - 1)
    close.performClick(nil)
    layout()
    #expect(!controller.selfTestInspectorVisible)
    #expect(!controller.selfTestListPaneHidden)
    #expect(abs(controller.selfTestRelationListFrame.width - split.bounds.width) <= 2)
    controller.showFrozenInspector(display)
    layout()
    #expect(controller.selfTestListPaneHidden)

    resize(to: 610)
    #expect(controller.selfTestListPaneHidden)
    #expect(abs(controller.selfTestInspectorFrame.width - split.bounds.width) <= 2)
    resize(to: 900)
    #expect(!controller.selfTestListPaneHidden)
    #expect(controller.selfTestInspectorVisible)
    #expect(abs(controller.selfTestRelationListFrame.width
        / (split.bounds.width - split.dividerThickness) - fraction) <= 0.005)
    #expect(controller.selfTestInspectorText == capturedText)

    close.performClick(nil)
    layout()
    #expect(!controller.selfTestInspectorVisible)
    #expect(abs(controller.selfTestRelationListFrame.width - split.bounds.width) <= 2)
    controller.showFrozenInspector(display)
    layout()
    #expect(controller.selfTestInspectorIsFrozen)
    #expect(!controller.selfTestListPaneHidden)
    #expect(abs(controller.selfTestRelationListFrame.width
        / (split.bounds.width - split.dividerThickness) - fraction) <= 0.005)
    #expect(controller.selfTestInspectorText == capturedText)
    #expect(controller.selfTestRelationListFrame.intersection(
        controller.selfTestInspectorFrame
    ).isEmpty)
}

@MainActor
private func inspectorGeometryViews(in view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(inspectorGeometryViews(in:))
}

@MainActor
@Test
func frozenInspectorClosesWhenProjectContextChanges() async {
    _ = NSApplication.shared
    let model = RelationTreeModel()
    let controller = RelationWindowController(model: model, languageMode: { _ in nil })
    controller.loadViewIfNeeded()
    controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 620)
    let display = ReadingSetExcerpt.FrozenInspectorDisplay(
        nodeTitle: "old_project_symbol", badge: .verified, why: "Captured evidence",
        sourceBody: "Project A", verificationTitle: "VERIFICATION",
        verificationBody: "Captured result", correctionBody: "",
        availabilityBody: "", environmentBody: "", auditRows: [],
        accessibilityValue: "Project A evidence", capturedAt: Date(),
        formerCandidateAvailable: true
    )
    var oldProjectActionCalls = 0
    for state: ProjectState in [
        .indexing(root: URL(fileURLWithPath: "/tmp/project-b"), startedAt: .now),
        .empty,
    ] {
        controller.showFrozenInspector(display) { oldProjectActionCalls += 1 }
        #expect(controller.selfTestInspectorIsFrozen)
        model.updateProjectState(state)
        // Drain the observation callback queued on the main actor.
        for _ in 0..<10 { await Task.yield() }
        controller.view.layoutSubtreeIfNeeded()
        #expect(!controller.selfTestInspectorIsFrozen)
        #expect(!controller.selfTestInspectorVisible)
        controller.selfTestOpenFormerCandidate()
        #expect(oldProjectActionCalls == 0)
    }
}
