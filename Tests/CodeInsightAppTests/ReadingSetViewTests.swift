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
    #expect(state.subtitle == "5 段 · frozen at capture")
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
    #expect(state.actions[0].map(\.0) == ["打开完整文件", "扩大上下文", "查看证据"])
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
        #expect(state.subtitle == "0 段 · frozen at capture · skipped 3 · "
            + "recorded source is unreadable ×2; relation evidence is unavailable")
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
