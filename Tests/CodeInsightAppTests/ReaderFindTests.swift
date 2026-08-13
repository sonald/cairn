import AppKit
import CodeInsightCore
import Foundation
import Testing
@testable import CodeInsightApp

@MainActor
@Suite(.serialized)
struct ReaderFindTests {
    @Test
    func readerFindContracts() async throws {
        let fixture = makeFindFixture("Alpha alpha alpha beta\n")
        defer { fixture.window.close() }

        #expect(fixture.controller.selfTestActivate(at: 6) == 2)
        #expect(fixture.controller.showFindBar())
        fixture.controller.selfTestSetFind("beta")
        #expect(await waitForFind { fixture.controller.selfTestFindState.count == 1 })
        #expect(fixture.controller.closeFindBar())
        #expect(fixture.controller.selfTestOccurrenceCount == 2)

        #expect(fixture.controller.showFindBar())
        fixture.controller.selfTestSetFind("alpha")
        #expect(await waitForFind { fixture.controller.selfTestFindState.count == 3 })
        var state = fixture.controller.selfTestFindState
        #expect(state.status == "1 / 3")
        #expect(state.selectedIndex == 0)
        #expect(state.previousEnabled && state.nextEnabled)
        #expect(state.barFrame.height == 31)
        #expect(state.fieldFrame.maxX <= state.caseFrame.minX)
        #expect(state.caseFrame.maxX <= state.closeFrame.minX)

        fixture.controller.selfTestNavigateFind(by: 1)
        fixture.controller.selfTestNavigateFind(by: 1)
        fixture.controller.selfTestNavigateFind(by: 1)
        state = fixture.controller.selfTestFindState
        #expect(state.selectedIndex == 0)
        #expect(state.status == "1 / 3 · wrapped")

        fixture.controller.selfTestNavigateFind(by: 1)
        fixture.controller.selfTestSetFind("alpha", caseSensitive: true)
        #expect(await waitForFind { fixture.controller.selfTestFindState.count == 2 })
        state = fixture.controller.selfTestFindState
        #expect(state.selectedIndex == 0)
        #expect(state.status == "1 / 2")

        fixture.controller.selfTestSetFind("alpha\nbeta")
        state = fixture.controller.selfTestFindState
        #expect(state.count == 0)
        #expect(state.status == "Line breaks are not supported")
        #expect(!state.previousEnabled && !state.nextEnabled)

        let firstFile = URL(fileURLWithPath: "/reader-find-first.rs")
        let secondFile = URL(fileURLWithPath: "/reader-find-second.rs")
        fixture.controller.display(
            firstFile,
            source: { _ in Array(String(repeating: "old ", count: 2_000).utf8) }
        )
        let cancellationsBeforeFile =
            fixture.controller.findCancelledWorkerCountForTesting
        fixture.controller.selfTestSetFind("old", delay: .milliseconds(250))
        #expect(await waitUntil { fixture.controller.selfTestFindWorkerActive })
        fixture.controller.display(
            secondFile,
            source: { _ in Array("new new\n".utf8) }
        )
        #expect(await waitForFind {
            fixture.controller.selfTestFindState.status == "0 matches"
        })
        #expect(fixture.controller.selfTestFindState.count == 0)
        #expect(
            fixture.controller.findCancelledWorkerCountForTesting
                > cancellationsBeforeFile
        )

        let snapshotFile = URL(fileURLWithPath: "/reader-find-snapshot.rs")
        let firstSnapshot = SnapshotID(rawValue: UUID())
        let secondSnapshot = SnapshotID(rawValue: UUID())
        fixture.controller.display(
            snapshotFile,
            snapshotID: firstSnapshot,
            source: { _ in Array(String(repeating: "old ", count: 2_000).utf8) }
        )
        let cancellationsBeforeSnapshot =
            fixture.controller.findCancelledWorkerCountForTesting
        fixture.controller.selfTestSetFind("old", delay: .milliseconds(250))
        #expect(await waitUntil { fixture.controller.selfTestFindWorkerActive })
        fixture.controller.display(
            snapshotFile,
            snapshotID: secondSnapshot,
            source: { _ in Array("old\n".utf8) }
        )
        #expect(await waitForFind { fixture.controller.selfTestFindState.count == 1 })
        #expect(fixture.controller.selfTestFindState.status == "1 / 1")
        #expect(
            fixture.controller.findCancelledWorkerCountForTesting
                > cancellationsBeforeSnapshot
        )

        let cancellationsBeforeClose =
            fixture.controller.findCancelledWorkerCountForTesting
        fixture.controller.selfTestSetFind("old", delay: .milliseconds(250))
        #expect(await waitUntil { fixture.controller.selfTestFindWorkerActive })
        #expect(fixture.controller.closeFindBar())
        try await Task.sleep(for: .milliseconds(300))
        #expect(!fixture.controller.selfTestFindState.visible)
        #expect(fixture.controller.selfTestFindState.count == 0)
        #expect(
            fixture.controller.findCancelledWorkerCountForTesting
                > cancellationsBeforeClose
        )
    }
}

@MainActor
private func makeFindFixture(
    _ source: String
) -> (controller: ReaderViewController, window: NSWindow) {
    _ = NSApplication.shared
    let controller = ReaderViewController()
    let bytes = Array(source.utf8)
    controller.display(
        URL(fileURLWithPath: "/reader-find.rs"),
        source: { _ in bytes }
    )
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentViewController = controller
    window.contentView?.layoutSubtreeIfNeeded()
    return (controller, window)
}

@MainActor
private func waitForFind(
    _ condition: @escaping @MainActor () -> Bool
) async -> Bool {
    await waitUntil(timeout: .seconds(2), condition)
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(1),
    _ condition: @escaping @MainActor () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
