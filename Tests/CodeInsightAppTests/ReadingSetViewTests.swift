import AppKit
import CodeInsightAppModel
import CodeInsightCore
import CodeInsightReaderCore
import Foundation
import Testing
@testable import CodeInsightApp

@MainActor
@Test
func readingSetRendersTheFivePrototypeSegmentsAsAReadOnlyContinuousFlow() {
    _ = NSApplication.shared
    let controller = ReaderViewController()
    var opened: Int?
    var expanded: Int?
    var inspected: Int?
    controller.onOpenReadingSetExcerpt = { opened = $0 }
    controller.onExpandReadingSetExcerpt = { expanded = $0 }
    controller.onViewReadingSetEvidence = { inspected = $0 }
    controller.loadViewIfNeeded()
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 980, height: 900),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.contentViewController = controller
    let excerpts = prototypeReadingSetExcerpts()
    controller.display(TabContent.readingSet(title: "spawn", excerpts: excerpts))
    window.contentView?.layoutSubtreeIfNeeded()
    let state = controller.selfTestReadingSetState

    #expect(state.visible)
    #expect(state.title == "Reading Set · spawn")
    #expect(state.subtitle == "5 excerpts · frozen at capture · tab lifetime")
    #expect(!state.emptyVisible)
    #expect(state.cardCount == 5)
    #expect(state.cardFrames.allSatisfy { $0.width > 650 && $0.height > 60 })
    #expect(zip(state.cardFrames, state.cardFrames.dropFirst()).allSatisfy {
        $1.minY >= $0.maxY
    })
    #expect(state.cardAccessibility.map(\.0) == [
        "DEFINITION, spawn, runtime/task/spawn.rs line 142",
        "VERIFIED CALLER, Runtime::block_on, runtime/runtime.rs line 347",
        "INFERRED CALLER, JoinSet::spawn_on, runtime/task/join_set.rs line 88",
        "TRAIT CONTRACT, Future, /rust/core/future/future.rs line 100",
        "TEST, spawn_panic_propagation, tests/task_panic.rs line 41",
    ])
    #expect(state.code.map(\.0) == excerpts.map(\.sourceText))
    #expect(state.code.allSatisfy { $0.1 && !$0.2 })
    #expect(state.codeGeometry[0].0.hasPrefix("142\n143\n144"))
    #expect(state.codeGeometry.allSatisfy { $0.1 && $0.2 })
    #expect(state.actions[0].map(\.0) == [
        "Open File", "Expand Context", "View Evidence",
    ])
    let actionAX = readingSetTestViews(in: controller.view).compactMap {
        ($0 as? NSButton)?.accessibilityLabel()
    }
    #expect(actionAX.contains("Open File"))
    #expect(actionAX.contains("Expand Context"))
    #expect(actionAX.contains("View Evidence"))
    #expect(state.actions[0].allSatisfy { !$0.1 && $0.2 })
    #expect(state.actions[3][0].1)
    #expect(state.actions[3][1...].allSatisfy { !$0.1 && $0.2 })
    #expect(controller.displayedFile == nil)
    #expect(!controller.canFocusCurrentScope)
    #expect(controller.currentReadingPosition() == nil)
    #expect(opened == nil && expanded == nil && inspected == nil)

}

@MainActor
@Test
func readingSetEmptyStateAndThemesDoNotFallBackToAFileReader() {
    _ = NSApplication.shared
    let controller = ReaderViewController()
    controller.loadViewIfNeeded()
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.contentViewController = controller
    controller.display(
        TabContent.readingSet(title: "empty", excerpts: []),
        readingSetSkippedReasons: [
            "recorded source is unreadable",
            "recorded source is unreadable",
            "relation evidence is unavailable",
        ]
    )

    for theme in ReaderSettings.Theme.allCases {
        var settings = ReaderSettings()
        settings.theme = theme
        controller.apply(settings: settings)
        window.contentView?.layoutSubtreeIfNeeded()
        let state = controller.selfTestReadingSetState
        #expect(state.visible)
        #expect(state.emptyVisible)
        #expect(state.cardCount == 0)
        #expect(state.subtitle == "0 excerpts · frozen at capture · tab lifetime"
            + " · skipped 3 · "
            + "recorded source is unreadable ×2; relation evidence is unavailable")
        let text = readingSetTestViews(in: controller.view).compactMap {
            ($0 as? NSTextField)?.stringValue
        }
        #expect(text.contains(
            "No excerpts could be frozen. Review the skipped reasons above."
        ))
    }
    #expect(controller.displayedFile == nil)
    #expect(controller.selfTestPlaceholderText != "Select a file to read")
}

@MainActor
@Test
func readingSetDisablesDriftedSourceActionsButKeepsFrozenEvidence() {
    _ = NSApplication.shared
    let controller = ReaderViewController()
    controller.onOpenReadingSetExcerpt = { _ in }
    controller.onExpandReadingSetExcerpt = { _ in }
    controller.onViewReadingSetEvidence = { _ in }
    controller.loadViewIfNeeded()
    let excerpts = prototypeReadingSetExcerpts()
    controller.display(
        .readingSet(title: "spawn", excerpts: excerpts),
        readingSetAvailability: excerpts.map { _ in (false, false) }
    )

    let actions = controller.selfTestReadingSetState.actions
    #expect(actions[0][0].2 == false)
    #expect(actions[0][1].2 == false)
    #expect(actions[0][2].2 == true)
    #expect(actions[3][0].1 == true)
    #expect(actions[3][1].2 == false)
    #expect(actions[3][2].2 == true)
}

@MainActor
@Test
func readingSetScrollPublishesItsNumericCheckpointOffset() async throws {
    _ = NSApplication.shared
    let controller = ReaderViewController()
    var observedOffset: Double?
    controller.onReadingSetScrollChange = { observedOffset = $0 }
    controller.loadViewIfNeeded()
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 760, height: 280),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentViewController = controller
    controller.display(.readingSet(
        title: "spawn",
        excerpts: prototypeReadingSetExcerpts()
    ))
    window.contentView?.layoutSubtreeIfNeeded()

    controller.setReadingSetScrollOffsetForSelfTest(80)
    try? await Task.sleep(for: .milliseconds(20))

    #expect(observedOffset == 80)
    #expect(controller.currentReadingSetScrollOffset == 80)
    let surface = try #require(readingSetTestViews(in: controller.view).compactMap { $0 as? ReadingSetView }.first)
    await settleReadingSet(window)
    let measured = surface.selfTestMeasurementCount
    let frozenSources = surface.selfTestTextViews.map(\.string)
    #expect(measured > 0)
    var settings = ReaderSettings()
    settings.fontSize = 22
    controller.apply(settings: settings)
    #expect(surface.selfTestLayoutPending)
    #expect(surface.selfTestMeasurementCount == measured)

    // Queue a real bounds notification before terminal teardown. Its async
    // publication must not escape after the final session checkpoint.
    surface.selfTestScrollView.contentView.scroll(to: NSPoint(x: 0, y: 85))
    let closedOffset = surface.scrollOffset
    observedOffset = -1
    controller.cancelDerivedDataSubscription()
    window.close()
    #expect(!surface.selfTestLayoutPending)
    // A retained closed host can receive a settings broadcast and native layout.
    settings.fontSize = 24
    controller.apply(settings: settings)
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.main.async { continuation.resume() }
    }
    await settleReadingSet(window)
    #expect(!surface.selfTestLayoutPending)
    #expect(surface.selfTestMeasurementCount == measured)
    #expect(surface.selfTestTextViews.map(\.string) == frozenSources)
    #expect(surface.scrollOffset == closedOffset)
    #expect(controller.currentReadingSetScrollOffset == closedOffset)
    #expect(observedOffset == -1)
}

private func prototypeReadingSetExcerpts() -> [ReadingSetExcerpt] {
    let specs: [(
        role: String,
        symbol: String,
        path: String,
        line: UInt32,
        badge: ReadingSetExcerpt.FrozenInspectorDisplay.Badge,
        kind: ReadingSetExcerpt.SourceKind,
        caveat: String?,
        source: String
    )] = [
        (
            "DEFINITION", "spawn", "runtime/task/spawn.rs", 142, .verified,
            .projectCommit, nil,
            "pub fn spawn<F>(future: F) -> JoinHandle<F::Output>\nwhere F: Future + Send + 'static,\n{\n    spawn_inner(future, SpawnMeta::new(None))\n}\n"
        ),
        (
            "VERIFIED CALLER", "Runtime::block_on", "runtime/runtime.rs", 347,
            .verified, .projectCommit, nil,
            "let handle = self.spawn(future);\nself.block_on(handle)\n"
        ),
        (
            "INFERRED CALLER", "JoinSet::spawn_on", "runtime/task/join_set.rs",
            88, .inferred, .worktreeCaptured, "name match only",
            "self.inner.spawn(future)\n"
        ),
        (
            "TRAIT CONTRACT", "Future", "/rust/core/future/future.rs", 100,
            .verified, .dependencyCaptured, nil,
            "pub trait Future {\n    type Output;\n    fn poll(self: Pin<&mut Self>) -> Poll<Self::Output>;\n}\n"
        ),
        (
            "TEST", "spawn_panic_propagation", "tests/task_panic.rs", 41,
            .verified, .projectCommit, nil,
            "#[tokio::test]\nasync fn spawn_panic_propagation() {\n    let h = spawn(async { panic!() });\n    assert!(h.await.is_err());\n}\n"
        ),
    ]
    let capturedAt = Date(timeIntervalSince1970: 1_786_200_000)
    return specs.map { spec in
        let bytes = Array(spec.source.utf8)
        let inspector = ReadingSetExcerpt.FrozenInspectorDisplay(
            nodeTitle: spec.symbol,
            badge: spec.badge,
            why: "Observed at navigation time.",
            sourceBody: "Frozen source evidence.",
            verificationTitle: "VERIFICATION",
            verificationBody: "Verification state captured with this excerpt.",
            correctionBody: "",
            availabilityBody: "rust-analyzer ready at capture",
            environmentBody: "default · Trusted at capture",
            auditRows: [
                .init(label: "Source", value: "worktree captured"),
                .init(label: "Content", value: "fixture"),
            ],
            accessibilityValue: "\(spec.badge.rawValue) \(spec.symbol)",
            capturedAt: capturedAt,
            formerCandidateAvailable: false
        )
        return ReadingSetExcerpt(
            role: spec.role,
            symbol: spec.symbol,
            path: spec.path,
            line: spec.line,
            column: 1,
            firstLine: spec.line,
            byteRange: ByteRange(lowerBound: 0, upperBound: UInt32(bytes.count)),
            sourceText: spec.source,
            contentID: .sha256(of: bytes),
            revision: spec.kind == .projectCommit ? "3a4f71c" : nil,
            capturedAt: capturedAt,
            sourceKind: spec.kind,
            inspector: inspector,
            caveat: spec.caveat
        )
    }
}

@MainActor
private func readingSetTestViews(in view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(readingSetTestViews(in:))
}

@MainActor
@Test
func readingSetWrapUsesActualRowsAndOneHeightConstraint() async throws {
    _ = NSApplication.shared
    let view = ReadingSetView()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 460),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = view
    defer { window.orderOut(nil) }
    var settings = ReaderSettings()
    settings.wrapLines = true
    view.apply(settings: settings)
    view.display(title: "Wrap", excerpts: wrapReadingSetExcerpts())
    await settleReadingSet(window)
    #expect(view.selfTestTextViews.allSatisfy { $0.textLayoutManager != nil })
    #expect(view.selfTestCodeGeometry[0].0 == "99999\n100000\n\n100001\n100002\n100003")
    #expect(view.selfTestGutterLabels[0] == ["99999", "100000", "100001", "100002", "100003"])
    let heights = view.selfTestCardFrames.map(\.height)
    #expect(view.selfTestTextViews.allSatisfy { $0.textContainer?.widthTracksTextView == true })
    for state in view.selfTestLayoutState {
        #expect(state.heightConstraints == 1)
        #expect(state.contentBottom <= state.documentHeight)
    }
    let counts = view.selfTestLayoutState.map(\.measurements)
    view.apply(settings: settings)
    await settleReadingSet(window)
    #expect(view.selfTestLayoutState.map(\.measurements) == counts)
    for style in [NSScroller.Style.legacy, .overlay] {
        view.selfTestCodeScrollViews.forEach { $0.scrollerStyle = style }
        settings.wrapLines = false
        view.apply(settings: settings)
        await settleReadingSet(window)
        #expect(zip(view.selfTestCardFrames, heights).allSatisfy { $0.height < $1 })
        for state in view.selfTestLayoutState {
        #expect(state.heightConstraints == 1)
        #expect(state.contentBottom <= state.documentHeight)
    }
        settings.wrapLines = true
        view.apply(settings: settings)
        window.setContentSize(NSSize(width: 440, height: 460))
        await settleReadingSet(window)
        #expect(zip(view.selfTestCardFrames, view.selfTestCardFrames.dropFirst()).allSatisfy { $0.maxY <= $1.minY })
    }
    for _ in 0..<100 {
        settings.wrapLines.toggle()
        view.apply(settings: settings)
        view.selfTestFlushLayout()
    }
    await settleReadingSet(window)
    #expect(view.selfTestLayoutState.allSatisfy { $0.heightConstraints == 1 })
    let finalCount = view.selfTestMeasurementCount
    view.apply(settings: settings)
    await settleReadingSet(window)
    #expect(view.selfTestMeasurementCount == finalCount)
}

@MainActor
@Test
func readingSetReflowPreservesThirdCardCharacterAndCompleteSelection() async throws {
    _ = NSApplication.shared
    let view = ReadingSetView()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 340),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = view
    defer { window.orderOut(nil) }
    view.display(title: "Anchor", excerpts: wrapReadingSetExcerpts())
    await settleReadingSet(window)
    let text = view.selfTestTextViews[2]
    let selections = [NSValue(range: NSRange(location: 4, length: 18)), NSValue(range: NSRange(location: 36, length: 12))]
    text.setSelectedRanges(selections, affinity: .upstream, stillSelecting: false)
    view.restoreScrollOffset(Double(view.selfTestCardFrames[2].minY + 45))
    await settleReadingSet(window)
    let before = try #require(view.selfTestViewportAnchor)
    var settings = ReaderSettings()
    settings.wrapLines = true
    settings.fontSize = 18
    view.apply(settings: settings)
    await settleReadingSet(window)
    let after = try #require(view.selfTestViewportAnchor)
    #expect(before.card == 2 && after.card == before.card)
    #expect(after.location == before.location)
    #expect(abs(after.offset - before.offset) <= 2)
    #expect(text.selectedRanges == selections)
    #expect(text.selectionAffinity == .upstream)
}

@MainActor
private func settleReadingSet(_ window: NSWindow) async {
    for _ in 0..<5 {
        window.contentView?.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(10))
        window.displayIfNeeded()
    }
}

private func wrapReadingSetExcerpts() -> [ReadingSetExcerpt] {
    let original = prototypeReadingSetExcerpts()[0]
    let source = "first\n" + String(repeating: "long 👩🏽‍💻 中文 fragment ", count: 100) + "\n…\n\nlast\n"
    let bytes = Array(source.utf8)
    return (0..<5).map { _ in
        ReadingSetExcerpt(role: original.role, symbol: original.symbol, path: original.path,
                          line: 99999, column: 1, firstLine: 99999,
                          byteRange: ByteRange(lowerBound: 0, upperBound: UInt32(bytes.count)),
                          sourceText: source, contentID: .sha256(of: bytes), revision: nil,
                          capturedAt: original.capturedAt, sourceKind: original.sourceKind,
                          inspector: original.inspector, caveat: original.caveat)
    }
}

@MainActor
@Test
func readingSetUsesASerifTitleCardsOnTheWellAndBadgeColoredRoles() throws {
    _ = NSApplication.shared
    let controller = ReaderViewController()
    controller.loadViewIfNeeded()
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 980, height: 900),
        styleMask: [.titled], backing: .buffered, defer: false
    )
    window.contentViewController = controller
    defer { window.orderOut(nil) }
    controller.apply(settings: ReaderSettings(theme: .light))
    controller.display(TabContent.readingSet(title: "spawn", excerpts: prototypeReadingSetExcerpts()))
    window.contentView?.layoutSubtreeIfNeeded()

    func rgb(_ value: Any?) -> UInt32? {
        let color: NSColor? = switch value {
        case let color as NSColor: color
        case let color as CGColor: NSColor(cgColor: color)
        default: nil
        }
        guard let srgb = color?.usingColorSpace(.sRGB) else { return nil }
        return UInt32((srgb.redComponent * 255).rounded()) << 16
            | UInt32((srgb.greenComponent * 255).rounded()) << 8
            | UInt32((srgb.blueComponent * 255).rounded())
    }
    let view = try #require(Mirror(reflecting: controller).children
        .first { $0.label == "readingSetView" }?.value as? ReadingSetView)
    #expect(view.window === window && !view.isHiddenOrHasHiddenAncestor)
    let style = view.selfTestStyle
    #expect(style.titleFont?.fontName.contains("NewYork") == true)
    #expect(rgb(style.pageFill) == 0xF3F1EB)
    #expect(style.cards.count == 5)
    #expect(style.cards.allSatisfy { rgb($0.fill) == 0xFBFAF6 })
    // Card 2 is a verified caller, card 3 an inferred one.
    #expect(rgb(style.cards[1].role) == 0x2B5849)
    #expect(rgb(style.cards[1].badgeFill) == 0xDCE7E0)
    #expect(rgb(style.cards[2].role) == 0x3A5873)
    #expect(rgb(style.cards[2].badgeFill) == 0xDFE6ED)
}
