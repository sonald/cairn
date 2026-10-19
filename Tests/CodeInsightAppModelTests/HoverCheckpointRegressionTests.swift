import CodeInsightCore
import CodeInsightReaderCore
import Foundation
import Testing
@testable import CodeInsightAppModel

@MainActor
@Test
func featureSwitchDoesNotReuseHoverDocumentationFromPreviousQueryContext() async throws {
    let root = try regressionProject()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(indexService: ControlledSnapshotIndexService(
        worktreeSnapshot: TestSnapshot(label: "open", files: [
            "main.rs": "fn main() {}\n",
            "other.rs": "fn other() {}\n",
        ]),
        snapshots: [:]
    ))
    await model.openProject(root: root).value
    try #require(model.snapshotPhase == .fullReady)

    var calls = 0
    model.symbolHover.attach(syntactic: { _ in
        calls += 1
        return SymbolDoc(markdown: "version \(calls)", source: .syntactic)
    }, exact: nil)
    let token = SymbolHoverModel.Token(
        file: "main.rs",
        contentID: ContentID.sha256(of: Array("fn main() {}\n".utf8)),
        range: ByteRange(lowerBound: 3, upperBound: 7)
    )
    model.symbolHover.showNow(token)
    try #require(await testWaitUntil("first hover") { calls == 1 })

    model.switchFeatureSelection(.allFeatures)
    model.symbolHover.showNow(token)
    try #require(await testWaitUntil("hover after feature switch") { calls == 2 })
    guard case let .showing(_, doc) = model.symbolHover.phase else {
        Issue.record("expected refreshed hover documentation")
        return
    }
    #expect(doc.markdown == "version 2")
}

@MainActor
@Test
func completedFeatureSwitchAndFailedRefreshCanWriteSessionCheckpoints() async throws {
    let root = try regressionProject()
    let stateRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
        "CodeInsightCheckpointRegression-\(UUID().uuidString)",
        isDirectory: true
    )
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: stateRoot)
    }
    let service = ControlledSnapshotIndexService(
        worktreeSnapshot: TestSnapshot(label: "open", files: [
            "main.rs": "fn main() {}\n",
            "other.rs": "fn other() {}\n",
        ]),
        snapshots: [:],
        failedCapture: ["refresh"]
    )
    let model = AppModel(
        sessionURL: stateRoot.appendingPathComponent("session.json"),
        indexService: service
    )
    await model.openProject(root: root).value
    try #require(model.snapshotPhase == .fullReady)
    model.openInNewTab(root.appendingPathComponent("main.rs"))

    model.switchFeatureSelection(.allFeatures)
    try model.writeSessionCheckpoint(panelPreset: .reading)
    let switched = try #require(model.loadSessionSnapshot(forProject: root).snapshot)
    #expect(switched.tabs.count == 1)
    #expect(model.lastInstalledWorkspace.generation == model.generation)

    await service.setWorktreeSnapshot(TestSnapshot(
        label: "refresh",
        files: [
            "main.rs": "fn main() {}\n",
            "other.rs": "fn other() {}\n",
        ]
    ))
    model.refreshIndex(leaving: nil)
    try #require(await testWaitUntil("refresh failed and restored") {
        model.indexRefreshNotice != nil && !model.isRefreshingIndex
    })
    model.openInNewTab(root.appendingPathComponent("other.rs"))
    try model.writeSessionCheckpoint(panelPreset: .reading)
    let restored = try #require(model.loadSessionSnapshot(forProject: root).snapshot)
    #expect(restored.tabs.count == 2)
    #expect(model.lastInstalledWorkspace.generation == model.generation)
}

private func regressionProject() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "CodeInsightHoverCheckpoint-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("fn main() {}\n".utf8).write(to: root.appendingPathComponent("main.rs"))
    try Data("fn other() {}\n".utf8).write(to: root.appendingPathComponent("other.rs"))
    return root
}
