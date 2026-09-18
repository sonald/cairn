import CodeInsightCore
import CodeInsightExact
import CodeInsightGit
import Foundation
import Testing

@testable import CodeInsightAppModel

// §8 acceptance coverage for the multi-window design: one process, several
// windows, shared persistence and Exact caches. Tests use isolated
// temporary stores — never the global singleton.

private func multiWindowBookmarkFileURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("MultiWindowSharing-\(UUID().uuidString)")
        .appendingPathComponent("bookmarks.json")
}

private func multiWindowRecord(
    id: UInt32,
    path: String,
    note: String = "",
    updatedAt: Date = Date(timeIntervalSince1970: 10)
) -> BookmarkRecord {
    BookmarkRecord(
        id: UUID(uuidString: String(
            format: "00000000-0000-4000-8000-%012x", id
        ))!,
        projectPath: "/tmp/project",
        snapshot: .worktree,
        path: path,
        contentID: ContentID.sha256(of: Data(path.utf8)),
        byteOffset: 0,
        line: 1,
        symbolName: nil,
        symbolKind: nil,
        note: note,
        updatedAt: updatedAt
    )
}

/// W10: two windows (BookmarkModels) over one shared store — interleaved
/// add/modify/delete never loses the other window's update.
@MainActor
@Test
func sharedBookmarkStoreInterleavesTwoWindowsWithoutLosingUpdates() throws {
    let fileURL = multiWindowBookmarkFileURL()
    defer {
        try? FileManager.default.removeItem(
            at: fileURL.deletingLastPathComponent()
        )
    }
    let shared = SharedBookmarkStore(fileURL: fileURL)
    let windowA = BookmarkModel(sharedStore: shared)
    let windowB = BookmarkModel(sharedStore: shared)

    let fromA = multiWindowRecord(id: 1, path: "src/a.rs")
    #expect(windowA.toggle(fromA) == .added)
    // B sees A's record without any reload.
    #expect(windowB.records == [fromA])

    // B adds its own record; A's record survives B's full-table commit.
    let fromB = multiWindowRecord(id: 2, path: "src/b.rs")
    #expect(windowB.toggle(fromB) == .added)
    #expect(windowA.records.count == 2)

    // A modifies its record; B's record survives.
    var modified = fromA
    modified = multiWindowRecord(id: 1, path: "src/a.rs", note: "note")
    #expect(windowA.update(modified) == true)
    #expect(windowB.records.first { $0.id == fromA.id }?.note == "note")
    #expect(windowB.records.contains { $0.id == fromB.id })

    // B deletes its record; A's modified record survives.
    #expect(windowB.delete(id: fromB.id) == true)
    #expect(windowA.records == [modified])

    // The global 32-record cap stays an application-wide cap.
    let filler = (0..<BookmarkStore.maximumRecordCount).map { index in
        multiWindowRecord(
            id: UInt32(100 + index),
            path: "src/filler-\(index).rs"
        )
    }
    for record in filler.dropLast() {
        #expect(windowA.toggle(record) == .added)
    }
    #expect(
        windowA.toggle(filler.last!) == .rejected,
        "the shared table enforces one global record cap"
    )
    #expect(
        windowB.records.count == BookmarkStore.maximumRecordCount
    )
    // Disk matches the latest shared table.
    #expect(try BookmarkStore(fileURL: fileURL).load().count
        == BookmarkStore.maximumRecordCount)
}

/// W10: a change from one window reaches the other window's observer.
@MainActor
@Test
func sharedBookmarkStoreNotifiesBothWindows() {
    let shared = SharedBookmarkStore()
    let windowA = BookmarkModel(sharedStore: shared)
    let windowB = BookmarkModel(sharedStore: shared)
    var notifiedA = 0
    var notifiedB = 0
    windowA.onSharedRecordsChanged = { notifiedA += 1 }
    windowB.onSharedRecordsChanged = { notifiedB += 1 }

    _ = windowA.toggle(multiWindowRecord(id: 1, path: "src/a.rs"))

    #expect(notifiedA >= 1)
    #expect(notifiedB >= 1)
    #expect(windowB.records.count == 1)
}

/// W11: a failed write keeps the newest shared table dirty; another
/// window's later modification retries from that table, and the final
/// successful write contains both windows' updates.
@MainActor
@Test
func sharedBookmarkStoreRetainsDirtyTableForRetryAcrossWindows() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MultiWindowSharing-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let blockedFile = directory.appendingPathComponent("bookmarks.json")
    // A plain file where a directory is expected: every write fails with
    // writeFailed while the in-memory table stays authoritative.
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    try Data().write(to: blockedFile)
    let blockedURL = blockedFile.appendingPathComponent("bookmarks.json")

    let shared = SharedBookmarkStore(fileURL: blockedURL)
    let windowA = BookmarkModel(sharedStore: shared)
    let windowB = BookmarkModel(sharedStore: shared)

    let fromA = multiWindowRecord(id: 1, path: "src/a.rs")
    #expect(windowA.toggle(fromA) == .added)
    #expect(windowA.isDirty)
    #expect(windowA.storageError == .writeFailed)

    // B's edit commits from the dirty table, not from stale disk.
    let fromB = multiWindowRecord(id: 2, path: "src/b.rs")
    #expect(windowB.toggle(fromB) == .added)
    #expect(windowB.isDirty)
    #expect(windowB.records.count == 2)

    // Repair the storage location: the ORIGINAL dirty store retries on
    // its original path, its dirty/error state clears, and both windows
    // observe the successful retry (review W11 correction).
    try FileManager.default.removeItem(at: blockedFile)
    var notifiedA = 0
    var notifiedB = 0
    windowA.onSharedRecordsChanged = { notifiedA += 1 }
    windowB.onSharedRecordsChanged = { notifiedB += 1 }
    let fromB2 = multiWindowRecord(id: 3, path: "src/b2.rs")
    #expect(windowB.toggle(fromB2) == .added)
    #expect(shared.isDirty == false)
    #expect(shared.storageError == nil)
    #expect(windowA.isDirty == false)
    #expect(notifiedA >= 1 && notifiedB >= 1)
    // The final disk state contains both windows' updates, retried from
    // the dirty table — including the post-repair edit. The store's own
    // path (inside the repaired directory) is the read-back target.
    let loaded = try BookmarkStore(fileURL: blockedURL).load()
    #expect(loaded.count == 3)
    #expect(
        Set(loaded.map(\.path))
            == ["src/a.rs", "src/b.rs", "src/b2.rs"]
    )
}

/// W13: two references to one materialized directory; one release keeps
/// the other's protection, and clear() refuses while referenced.
@Test
func materializerReferenceCountProtectsSharedDirectory() throws {
    let root = try multiWindowGitFixture(files: [
        "src/lib.rs": "pub fn target() {}\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let cacheRoot = root.appendingPathComponent("cache")
    let materializer = Materializer(rootURL: cacheRoot)
    let snapshot = try CommitSnapshot(repositoryURL: root)
    let profile = try ExactProfileKey(snapshot: snapshot)

    // Two windows prepare the same revision: two references.
    let first = try materializer.materializeAndRetain(
        snapshot,
        configFingerprint: profile.configFingerprint
    )
    let second = try materializer.materializeAndRetain(
        snapshot,
        configFingerprint: profile.configFingerprint
    )
    #expect(first.url == second.url)
    #expect(materializer.referenceCount(for: first.url) == 2)

    // Clearing while referenced is refused and the directory survives.
    #expect(throws: (any Error).self) {
        try materializer.clear()
    }
    #expect(FileManager.default.fileExists(atPath: first.url.path))

    // One window closes: the other's reference still protects the data.
    materializer.release(first.url)
    #expect(materializer.referenceCount(for: first.url) == 1)
    #expect(throws: (any Error).self) {
        try materializer.clear()
    }
    #expect(FileManager.default.fileExists(atPath: first.url.path))

    // The last release makes clearing possible.
    materializer.release(second.url)
    #expect(materializer.retainedDirectoryCount == 0)
    try materializer.clear()
    #expect(!FileManager.default.fileExists(atPath: cacheRoot.path))

    // Releases are idempotent.
    materializer.release(first.url)
    #expect(materializer.retainedDirectoryCount == 0)
}

/// W14: quota eviction only reclaims directories with zero references; a
/// released directory becomes collectable again.
@Test
func materializerQuotaEvictsOnlyUnreferencedDirectories() throws {
    let root = try multiWindowGitFixture(files: [
        "src/lib.rs": "pub fn one() {}\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let materializer = Materializer(
        rootURL: root.appendingPathComponent("cache"),
        quotaBytes: 1
    )
    let firstSnapshot = try CommitSnapshot(repositoryURL: root)
    let firstProfile = try ExactProfileKey(snapshot: firstSnapshot)
    let first = try materializer.materializeAndRetain(
        firstSnapshot,
        configFingerprint: firstProfile.configFingerprint
    )

    // A second revision materializes under a tiny quota. The referenced
    // first directory survives even though the total stays over quota.
    try multiWindowGit(root, "commit", "-q", "--allow-empty", "-m", "second")
    let secondSnapshot = try CommitSnapshot(repositoryURL: root)
    let secondProfile = try ExactProfileKey(snapshot: secondSnapshot)
    let second = try materializer.materializeAndRetain(
        secondSnapshot,
        configFingerprint: secondProfile.configFingerprint
    )
    #expect(second.url != first.url)
    #expect(FileManager.default.fileExists(atPath: first.url.path))
    #expect(FileManager.default.fileExists(atPath: second.url.path))

    // Releasing the old reference lets the next materialization reclaim it.
    materializer.release(first.url)
    try multiWindowGit(root, "commit", "-q", "--allow-empty", "-m", "third")
    let thirdSnapshot = try CommitSnapshot(repositoryURL: root)
    let thirdProfile = try ExactProfileKey(snapshot: thirdSnapshot)
    _ = try materializer.materialize(
        thirdSnapshot,
        configFingerprint: thirdProfile.configFingerprint
    )
    #expect(!FileManager.default.fileExists(atPath: first.url.path))
    #expect(FileManager.default.fileExists(atPath: second.url.path))
}

/// W12: one TrustRegistry shared by two coordinators — grants and revokes
/// are visible to both windows' coordinators.
@MainActor
@Test
func sharedTrustRegistryServesTwoCoordinators() async throws {
    let trustFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("MultiWindowTrust-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: trustFile) }
    let registry = TrustRegistry(fileURL: trustFile)
    let projectA = URL(fileURLWithPath: "/tmp/window-a", isDirectory: true)
    let projectB = URL(fileURLWithPath: "/tmp/window-b", isDirectory: true)

    let windowA = ExactCoordinator(
        providerFactory: { _ in throw CocoaError(.featureUnsupported) },
        sandboxAvailable: { false },
        trustRegistry: registry
    )
    let windowB = ExactCoordinator(
        providerFactory: { _ in throw CocoaError(.featureUnsupported) },
        sandboxAvailable: { false },
        trustRegistry: registry
    )
    defer {
        windowA.shutdown()
        windowB.shutdown()
    }

    try await windowA.grantTrust(projectA)
    // B's coordinator observes the grant through the same registry.
    await windowB.refreshTrust()
    #expect(windowB.trustedRepositories.map(\.path) == [projectA.path])
    #expect(windowB.isTrusted(projectA))

    try await windowB.revokeTrust(projectA)
    await windowA.refreshTrust()
    #expect(windowA.trustedRepositories.isEmpty)
    #expect(!windowA.isTrusted(projectA))
    #expect(await registry.query(projectA) == nil)
    _ = projectB
}

/// §7.1: explicit project teardown cancels the model's work, resets the
/// project state, and leaves Exact off.
@MainActor
@Test
func appModelCloseProjectResetsStateAndStopsExact() async throws {
    let fixture = try MultiWindowAppFixture()
    defer { fixture.remove() }
    let model = fixture.model

    try model.openProject(root: fixture.root)
    #expect(await testWaitUntil("ready") {
        if case .ready = model.projectState { return true }
        return false
    })
    #expect(model.exactCoordinator.readiness != .off("no project"))

    await model.closeProject()

    if case .empty = model.projectState {
        #expect(true)
    } else {
        Issue.record("project state should be empty after closeProject")
    }
    #expect(model.projectRoot == nil)
    #expect(model.tabStrip.tabs.isEmpty)
    #expect(model.navigationHistory.records.isEmpty)
    #expect(model.fileTree == nil)
    #expect(
        model.exactCoordinator.readiness
            == .off("application terminating")
            || model.exactCoordinator.readiness == .off("no project")
    )
    // Idempotent.
    await model.closeProject()
}

/// §7.1/§8.3: shutdownAndWait waits for the closed session and releases
/// the materialized directory reference.
@MainActor
@Test
func coordinatorShutdownAndWaitReleasesMaterializedDirectory() async throws {
    let root = try multiWindowGitFixture(files: [
        "src/lib.rs": "pub fn target() {}\n",
        "src/main.rs": "fn main() {}\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let materializer = Materializer(
        rootURL: root.appendingPathComponent("cache")
    )
    let providerState = ExactProviderState()
    let coordinator = ExactCoordinator(
        providerFactory: { _ in ExactTestProvider(state: providerState) },
        snapshotFactory: { root, revision in
            try CommitSnapshot(
                repositoryURL: root,
                revision: revision ?? "HEAD"
            )
        },
        sandboxAvailable: { true },
        trustRegistry: TrustRegistry(
            fileURL: root.appendingPathComponent("trust.json")
        ),
        materializer: materializer
    )

    try coordinator.prepare(
        projectURL: root,
        revision: "HEAD",
        analysisProfile: exactAnalysisProfile(),
        generation: 1
    )
    #expect(await testWaitUntil("ready") { coordinator.readiness == .ready })
    #expect(materializer.retainedDirectoryCount == 1)

    await coordinator.shutdownAndWait()

    #expect(materializer.retainedDirectoryCount == 0)
    #expect(
        materializer.referenceCount(
            for: materializer.rootURL
        ) == 0
    )
    // The materialized data itself is untouched — only the reference went.
    let foundMaterialized = await Task.detached {
        () -> Bool in
        guard let enumerator = FileManager.default.enumerator(
            at: materializer.rootURL,
            includingPropertiesForKeys: nil
        ) else { return false }
        return (enumerator.allObjects as? [URL])?.contains {
            $0.lastPathComponent == ".complete"
        } ?? false
    }.value
    #expect(foundMaterialized)
}

/// Review F4: prepares for a project under trust revocation are refused
/// at entry; after the revocation finishes they run again.
@MainActor
@Test
func suspendedPrepareIsRefusedUntilTheSuspensionLifts() async throws {
    let fixture = try MultiWindowAppFixture()
    defer { fixture.remove() }
    let state = ExactProviderState()
    let coordinator = ExactCoordinator(
        providerFactory: { _ in ExactTestProvider(state: state) },
        snapshotFactory: { root, _ in
            try WorktreeSnapshot(
                repositoryURL: root,
                languages: [.rust]
            )
        },
        sandboxAvailable: { true },
        trustRegistry: TrustRegistry(
            fileURL: fixture.root.appendingPathComponent("trust2.json")
        )
    )
    defer { coordinator.shutdown() }

    // The revoke guard: while suspended, prepare is refused outright.
    coordinator.suspendPrepares(for: fixture.root)
    #expect(coordinator.prepareIsSuspended(for: fixture.root))
    try coordinator.prepare(
        projectURL: fixture.root,
        revision: nil,
        generation: 1
    )
    #expect(coordinator.readiness == .off("trust revoking"))
    #expect(state.prepareCount == 0, "no provider may start while suspended")
    // A refused prepare must not lift the in-flight revocation guard.
    #expect(coordinator.prepareIsSuspended(for: fixture.root))

    coordinator.resumePrepares(for: fixture.root)
    #expect(!coordinator.prepareIsSuspended(for: fixture.root))
    try coordinator.prepare(
        projectURL: fixture.root,
        revision: nil,
        generation: 2
    )
    #expect(await testWaitUntil("ready") { coordinator.readiness == .ready })
    #expect(state.prepareCount == 1)

    // revokeTrust leaves no suspension behind (defer-cleaned).
    try await coordinator.revokeTrust(fixture.root)
    #expect(!coordinator.prepareIsSuspended(for: fixture.root))
}

/// Review F7: a quota-enforcement failure after the reference was taken
/// rolls the reference back, so the cache stays clearable.
@Test
func materializerQuotaFailureRollsBackTheNewReference() throws {
    let root = try multiWindowGitFixture(files: [
        "src/lib.rs": "pub fn one() {}\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let materializer = Materializer(
        rootURL: root.appendingPathComponent("cache"),
        quotaBytes: 1
    )
    // An old, unreadable entry makes quota scanning throw EACCES.
    let oldCommit = try CommitSnapshot(repositoryURL: root)
    let oldProfile = try ExactProfileKey(snapshot: oldCommit)
    _ = try materializer.materialize(
        oldCommit,
        configFingerprint: oldProfile.configFingerprint
    )
    let unreadable = materializer.rootURL
        .appendingPathComponent(oldCommit.commitOID.hex)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o000],
        ofItemAtPath: unreadable.path
    )
    defer {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: unreadable.path
        )
    }

    // A second revision triggers quota enforcement, which now throws.
    try multiWindowGit(root, "commit", "-q", "--allow-empty", "-m", "second")
    let secondSnapshot = try CommitSnapshot(repositoryURL: root)
    let secondProfile = try ExactProfileKey(snapshot: secondSnapshot)
    #expect(throws: (any Error).self) {
        _ = try materializer.materializeAndRetain(
            secondSnapshot,
            configFingerprint: secondProfile.configFingerprint
        )
    }
    #expect(
        materializer.retainedDirectoryCount == 0,
        "the failed materialization must roll its reference back"
    )

    // After permissions recover, the cache is clearable again.
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: unreadable.path
    )
    try materializer.clear()
    #expect(!FileManager.default.fileExists(
        atPath: materializer.rootURL.path
    ))
}

/// Review F8: maintenance mode halts prepares on every coordinator
/// sharing the materializer and lifts afterwards.
@MainActor
@Test
func cacheMaintenanceHaltsPreparesAcrossSharedCoordinators() async throws {
    let fixture = try MultiWindowAppFixture()
    defer { fixture.remove() }
    let sharedCacheRoot = fixture.root.appendingPathComponent("shared-cache")
    let materializer = Materializer(rootURL: sharedCacheRoot)
    let state = ExactProviderState()
    func makeCoordinator() -> ExactCoordinator {
        ExactCoordinator(
            providerFactory: { _ in ExactTestProvider(state: state) },
            snapshotFactory: { root, _ in
                try WorktreeSnapshot(
                    repositoryURL: root,
                    languages: [.rust]
                )
            },
            sandboxAvailable: { true },
            trustRegistry: TrustRegistry(
                fileURL: fixture.root.appendingPathComponent("trust3.json")
            ),
            materializer: materializer
        )
    }
    let windowA = makeCoordinator()
    let windowB = makeCoordinator()
    defer {
        windowA.shutdown()
        windowB.shutdown()
    }

    materializer.beginMaintenance()
    #expect(materializer.isUnderMaintenance)
    for (index, coordinator) in [windowA, windowB].enumerated() {
        try coordinator.prepare(
            projectURL: fixture.root,
            revision: nil,
            generation: UInt64(index + 1)
        )
    }
    #expect(windowA.readiness == .off("cache maintenance"))
    #expect(windowB.readiness == .off("cache maintenance"))
    #expect(state.prepareCount == 0, "no provider may start during maintenance")

    materializer.endMaintenance()
    #expect(!materializer.isUnderMaintenance)
    try windowA.prepare(projectURL: fixture.root, revision: nil, generation: 3)
    #expect(await testWaitUntil("ready") { windowA.readiness == .ready })
    #expect(state.prepareCount == 1)
}

/// W12: the real model revoke entry suspends prepares while provider close
/// is blocked, then restarts Safe analysis for the feature generation now shown.
@MainActor
@Test
func revocationBlocksNewProvidersAndRestartsCurrentGenerationSafely() async throws {
    let root = try multiWindowGitFixture(files: ["src/lib.rs": "pub fn target() {}\n"])
    defer { try? FileManager.default.removeItem(at: root) }
    let state = ExactProviderState()
    let closeGate = MultiWindowProviderGate()
    defer { closeGate.release() }
    let registry = TrustRegistry(fileURL: root.appendingPathComponent("trust.json"))
    let coordinator = ExactCoordinator(
        providerFactory: { _ in
            MultiWindowGatedProvider(state: state, closeGate: closeGate)
        },
        sandboxAvailable: { true },
        trustRegistry: registry
    )
    let model = AppModel(exactCoordinator: coordinator)
    try await coordinator.grantTrust(root)
    try model.openProject(root: root)
    try #require(await testWaitUntil("trusted provider ready") {
        coordinator.readiness == .ready && model.snapshotPhase == .fullReady
    })
    #expect(state.trustModes == ["trusted"])
    let previousGeneration = model.generation
    var revokeFinished = false
    let revoke = Task {
        try await model.revokeRepositoryTrust(root)
        revokeFinished = true
    }
    try #require(await testWaitUntil("provider close entered") { closeGate.entered })
    #expect(coordinator.prepareIsSuspended(for: root))
    #expect(!revokeFinished)
    #expect(await registry.query(root) == .trusted)
    model.switchFeatureSelection(.allFeatures)
    #expect(model.generation > previousGeneration)
    #expect(coordinator.readiness == .off("trust revoking"))
    #expect(state.prepareCount == 1, "no new provider started while close was blocked")
    closeGate.release()
    try #require(await testWaitUntil("revoke finished") { revokeFinished })
    try await revoke.value
    try #require(await testWaitUntil("Safe provider for current generation ready") {
        coordinator.readiness == .ready
    })
    #expect(await registry.query(root) == nil)
    #expect(!coordinator.prepareIsSuspended(for: root))
    #expect(state.trustModes == ["trusted", "safe"])
    #expect(state.featureSelections == [.defaultFeatures, .allFeatures])
    #expect(state.closedSessions == [1])
    let currentResult = await coordinator.definition(
        file: "src/lib.rs", byteOffset: 0, generation: model.generation
    )
    if case .completed = currentResult {
        #expect(state.definitionCount >= 1)
    } else {
        Issue.record("the Safe session must serve the current generation")
    }
    let staleResult = await coordinator.definition(
        file: "src/lib.rs", byteOffset: 0, generation: previousGeneration
    )
    #expect(staleResult == nil)
    await model.closeProject()
}

/// W07: closing while prepare is in provider code waits for its late
/// session to close before releasing the commit directory reference.
@MainActor
@Test
func shutdownWaitsForLatePrepareToCloseAndReleaseItsDirectory() async throws {
    let root = try multiWindowGitFixture(files: ["src/lib.rs": "pub fn target() {}\n"])
    defer { try? FileManager.default.removeItem(at: root) }
    let state = ExactProviderState()
    let prepareGate = MultiWindowProviderGate()
    let closeGate = MultiWindowProviderGate()
    defer { prepareGate.release(); closeGate.release() }
    let materializer = Materializer(rootURL: root.appendingPathComponent("cache"))
    let coordinator = ExactCoordinator(
        providerFactory: { _ in
            MultiWindowGatedProvider(state: state, prepareGate: prepareGate, closeGate: closeGate)
        },
        sandboxAvailable: { true },
        trustRegistry: TrustRegistry(fileURL: root.appendingPathComponent("trust.json")),
        materializer: materializer
    )
    coordinator.prepare(projectURL: root, revision: "HEAD", generation: 1)
    try #require(await testWaitUntil("provider prepare entered") { prepareGate.entered })
    #expect(materializer.retainedDirectoryCount == 1)
    var shutdownFinished = false
    let shutdown = Task {
        await coordinator.shutdownAndWait()
        shutdownFinished = true
    }
    try #require(await testWaitUntil("shutdown started") {
        coordinator.readiness == .off("application terminating")
    })
    #expect(!shutdownFinished)
    prepareGate.release()
    try #require(await testWaitUntil("late session close entered") { closeGate.entered })
    #expect(!shutdownFinished, "shutdown must await the late session close")
    #expect(materializer.retainedDirectoryCount == 1)
    #expect(state.closedSessions.isEmpty)
    closeGate.release()
    try #require(await testWaitUntil("shutdown finished") { shutdownFinished })
    await shutdown.value
    #expect(state.closedSessions == [1])
    #expect(materializer.retainedDirectoryCount == 0)
    #expect(coordinator.readiness == .off("application terminating"))
    try materializer.clear()
}

/// W15 coordinator/cache contract: both windows have retained the same
/// commit; maintenance blocks prepares while close is held, then clear and
/// subsequent prepares succeed. The AppDelegate entry is exercised by UI.
@MainActor
@Test
func sharedCacheClearWaitsForBothProvidersAndAllowsRestartAfterMaintenance() async throws {
    let root = try multiWindowGitFixture(files: ["src/lib.rs": "pub fn target() {}\n"])
    defer { try? FileManager.default.removeItem(at: root) }
    let materializer = Materializer(rootURL: root.appendingPathComponent("cache"))
    let states = [ExactProviderState(), ExactProviderState()]
    let gates = [MultiWindowProviderGate(), MultiWindowProviderGate()]
    defer { gates.forEach { $0.release() } }
    let coordinators = zip(states, gates).map { state, gate in
        ExactCoordinator(
            providerFactory: { _ in MultiWindowGatedProvider(state: state, closeGate: gate) },
            sandboxAvailable: { true },
            trustRegistry: TrustRegistry(fileURL: root.appendingPathComponent("trust.json")),
            materializer: materializer
        )
    }
    for coordinator in coordinators {
        coordinator.prepare(projectURL: root, revision: "HEAD", generation: 1)
    }
    try #require(await testWaitUntil("both providers ready") {
        coordinators.allSatisfy { $0.readiness == .ready }
    })
    let snapshot = try CommitSnapshot(repositoryURL: root)
    let profile = try ExactProfileKey(snapshot: snapshot)
    let directory = try materializer.materialize(snapshot, configFingerprint: profile.configFingerprint).url
    #expect(materializer.referenceCount(for: directory) == 2)
    materializer.beginMaintenance()
    defer { materializer.endMaintenance() }
    var stopped = [false, false]
    let stopTasks = coordinators.enumerated().map { index, coordinator in
        Task {
            await coordinator.stopAllWorkForCacheClear()
            stopped[index] = true
        }
    }
    try #require(await testWaitUntil("both provider closes entered") {
        gates.allSatisfy(\.entered)
    })
    for coordinator in coordinators {
        coordinator.prepare(projectURL: root, revision: "HEAD", generation: 2)
        #expect(coordinator.readiness == .off("cache maintenance"))
    }
    #expect(states.allSatisfy { $0.prepareCount == 1 })
    #expect(stopped == [false, false])
    #expect(throws: (any Error).self) { try materializer.clear() }
    gates[0].release()
    try #require(await testWaitUntil("first provider stopped") { stopped[0] })
    #expect(!stopped[1])
    #expect(materializer.referenceCount(for: directory) == 1)
    #expect(throws: (any Error).self) { try materializer.clear() }
    gates[1].release()
    try #require(await testWaitUntil("both providers stopped") { stopped.allSatisfy { $0 } })
    for task in stopTasks { await task.value }
    #expect(materializer.retainedDirectoryCount == 0)
    try await coordinators[0].clearMaterializedCache()
    #expect(!FileManager.default.fileExists(atPath: materializer.rootURL.path))
    materializer.endMaintenance()
    for coordinator in coordinators {
        coordinator.prepare(projectURL: root, revision: "HEAD", generation: 3)
    }
    try #require(await testWaitUntil("both providers restarted") {
        coordinators.allSatisfy { $0.readiness == .ready }
    })
    #expect(states.allSatisfy { $0.prepareCount == 2 })
    #expect(materializer.referenceCount(for: directory) == 2)
    for coordinator in coordinators { await coordinator.shutdownAndWait() }
    #expect(materializer.retainedDirectoryCount == 0)
}

// Synchronous provider calls need a condition rather than an actor gate.
// Every wait has a deadline so a failed assertion cannot strand a worker.
private final class MultiWindowProviderGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var didEnter = false
    private var released = false
    var entered: Bool {
        condition.lock()
        defer { condition.unlock() }
        return didEnter
    }
    func wait() {
        condition.lock()
        defer { condition.unlock() }
        didEnter = true
        let deadline = Date().addingTimeInterval(15)
        while !released {
            guard condition.wait(until: deadline) else {
                Issue.record("provider gate timed out before release")
                return
            }
        }
    }
    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class MultiWindowGatedProvider: ExactProvider, @unchecked Sendable {
    let capabilities: ExactCapabilities = [.definition]
    let language: LanguageID = .rust
    let toolVersion = "gated-test-1"
    let state: ExactProviderState
    let prepareGate: MultiWindowProviderGate?
    let closeGate: MultiWindowProviderGate?
    init(state: ExactProviderState, prepareGate: MultiWindowProviderGate? = nil,
         closeGate: MultiWindowProviderGate? = nil) {
        self.state = state
        self.prepareGate = prepareGate
        self.closeGate = closeGate
    }
    func prepare(snapshot: any Snapshot, profile: ExactProfileKey,
                 trustMode: TrustMode) throws -> any ExactSession {
        prepareGate?.wait()
        let session = try ExactTestProvider(state: state).prepare(
            snapshot: snapshot, profile: profile, trustMode: trustMode
        )
        return MultiWindowGatedSession(base: session, closeGate: closeGate)
    }
}

private final class MultiWindowGatedSession: ExactSession, @unchecked Sendable {
    let base: any ExactSession
    let closeGate: MultiWindowProviderGate?
    var negotiatedCapabilities: ExactCapabilities { base.negotiatedCapabilities }
    var readiness: ExactReadiness { base.readiness }
    var attribution: ExactAttribution { base.attribution }
    init(base: any ExactSession, closeGate: MultiWindowProviderGate?) {
        self.base = base
        self.closeGate = closeGate
    }
    func definition(file: String, byteOffset: Int) throws -> ExactDefinitionQueryResult {
        try base.definition(file: file, byteOffset: byteOffset)
    }
    func implementations(file: String, byteOffset: Int) throws -> [ExactLocation]? { nil }
    func references(file: String, byteOffset: Int, includeDeclaration: Bool) throws -> [ExactLocation]? { nil }
    func prepareCallHierarchy(file: String, byteOffset: Int) throws -> [ExactCallHierarchyItem]? { nil }
    func incomingCalls(item: ExactCallHierarchyItem) throws -> [ExactCallRelation]? { nil }
    func outgoingCalls(item: ExactCallHierarchyItem) throws -> [ExactCallRelation]? { nil }
    func cancel() { base.cancel() }
    func close() {
        closeGate?.wait()
        base.close()
    }
}

// MARK: - Fixtures

private func multiWindowTemporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("MultiWindowSharing-\(UUID().uuidString)")
}

private func multiWindowGitFixture(files: [String: String]) throws -> URL {
    var files = files
    // ExactProfileKey requires a Cargo manifest for Rust projects.
    files["Cargo.toml"] = files["Cargo.toml"]
        ?? "[package]\nname='multi-window-test'\nversion='0.1.0'\n"
    let root = multiWindowTemporaryDirectory()
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    for (path, contents) in files {
        let fileURL = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: fileURL)
    }
    try multiWindowGit(root, "init", "-q")
    try multiWindowGit(root, "config", "user.name", "CodeInsight Tests")
    try multiWindowGit(
        root, "config", "user.email", "tests@codeinsight.invalid"
    )
    try multiWindowGit(root, "add", "-A")
    try multiWindowGit(root, "commit", "-q", "-m", "fixture")
    return root
}

private func multiWindowGit(_ root: URL, _ arguments: String...) throws {
    let process = Process()
    process.currentDirectoryURL = root
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(
            domain: "MultiWindowGit", code: Int(process.terminationStatus)
        )
    }
}

private func exactAnalysisProfile() -> AnalysisProfile {
    AnalysisProfile(
        language: .rust,
        projectRoot: PathID(rawValue: 0),
        projectUnitName: "exact-test",
        configFingerprint: "analysis-config",
        environmentFingerprint: "analysis-environment",
        featureSelection: .defaultFeatures,
        featureNames: [],
        edition: nil,
        trustMode: .safe
    )
}

@MainActor
private struct MultiWindowAppFixture {
    let root: URL
    let model: AppModel

    init() throws {
        root = try multiWindowGitFixture(files: [
            "main.rs": "fn main() {}\n",
        ])
        model = AppModel(
            sessionURL: root.appendingPathComponent("session.json"),
            indexService: SessionRestoreIndexService()
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
