import CodeInsightCore
import CodeInsightExact
import CodeInsightGit
import Darwin
import Foundation
import os
import Testing
@testable import CodeInsightAppModel
@testable import CodeInsightEngine

/// Placeholders of this test process live in a scratch folder, never in the
/// user's Application Support.
private let isolatedRemotesRoot: Void = {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodeInsightTestRemotes-\(UUID().uuidString)", isDirectory: true)
    setenv("CODEINSIGHT_REMOTES_ROOT", root.path, 1)
    atexit {
        guard let path = getenv("CODEINSIGHT_REMOTES_ROOT") else { return }
        try? FileManager.default.removeItem(atPath: String(cString: path))
    }
}()

/// The ssh stand-in of the Engine tests: the remote command goes to a local
/// login shell, so the same remote scripts run against a temporary folder.
private let sshLikePrefix = ["/bin/sh", "-c", "exec /bin/zsh -c \"$*\"", "ssh"]

private final class MadeTransports: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<[SSHTransport]>(initialState: [])
    func add(_ transport: SSHTransport) { lock.withLock { $0.append(transport) } }
    var all: [SSHTransport] { lock.withLock { $0 } }
}

private func remoteService(_ made: MadeTransports, cacheBytes: Int = 1 << 24) -> ProjectIndexService {
    ProjectIndexService(sourceBytes: SourceByteCache(budgetBytes: cacheBytes)) { origin in
        let transport = try SSHTransport(remotePath: origin.path, commandPrefix: sshLikePrefix)
        made.add(transport)
        return transport
    }
}

private func write(_ text: String, to path: String, under root: URL) throws {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

/// Open → index → read current remote content → lose the link → reconnect
/// → recapture only what changed → reopen from the saved session. Exact and
/// history stay off, the way they are for a folder that is no repository.
@MainActor
@Test
func remoteProjectOpensReadsReconnectsAndRestores() async throws {
    _ = isolatedIndexCacheRoot
    _ = isolatedRemotesRoot
    let remote = FileManager.default.temporaryDirectory
        .appendingPathComponent("remote-project-\(UUID().uuidString)", isDirectory: true)
    let sessionURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("remote-session-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("session.json")
    defer {
        try? FileManager.default.removeItem(at: remote)
        try? FileManager.default.removeItem(at: sessionURL.deletingLastPathComponent())
    }
    try write("pub fn main() {}\n", to: "src/main.rs", under: remote)
    try write("pub fn helper() {}\n", to: "src/lib.rs", under: remote)
    try write("[package]\nname = \"remote\"\n", to: "Cargo.toml", under: remote)
    try write("notes\n", to: "notes.txt", under: remote)

    let origin = try #require(RemoteOrigin(host: "test-host", path: remote.path + "/"))
    let root = try origin.placeholder()
    #expect(RemoteOrigin(placeholder: root) == origin)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["remote.json"])

    let made = MadeTransports()
    let model = AppModel(
        sessionURL: sessionURL,
        indexService: remoteService(made),
        exactCoordinator: ExactCoordinator(checkoutStore: CheckoutStore(
            parentURL: sessionURL.deletingLastPathComponent().appendingPathComponent("checkouts")
        ))
    )
    await model.openProject(root: root).value
    try #require(await testWaitUntil("remote fullReady") { model.snapshotPhase == .fullReady })
    guard case .ready = model.projectState else {
        Issue.record("remote project did not index: \(model.projectState) \(model.projectFailureReason ?? "")")
        return
    }
    #expect(model.remoteOrigin == origin)
    #expect(model.fileTree?.fileCount == 4)
    #expect(!model.canTrustCurrentRepository)
    let transport = try #require(made.all.first)
    #expect(made.all.count == 1)
    #expect(Set(transport.lastCapturedPaths) == ["src/main.rs", "src/lib.rs", "Cargo.toml"])
    #expect(transport.lastHashedPaths == ["notes.txt"])

    // Exact never starts: the status names why.
    #expect(model.exactCoordinator.readiness == .unavailable(localized("model.exact.remote")))
    // History falls into the not-a-repository branch.
    try #require(await testWaitUntil("commit list settled") { !model.commitPicker.isLoading })
    #expect(model.commitPicker.commits.isEmpty)
    #expect(model.commitPicker.errorMessage != nil)

    // Opening a file reads the remote folder as it is now.
    let main = root.appendingPathComponent("src/main.rs")
    let source = try #require(model.documentSource)
    try write("pub fn main() { changed(); }\n", to: "src/main.rs", under: remote)
    #expect(try source(main) == Array("pub fn main() { changed(); }\n".utf8))
    #expect(throws: CocoaError.self) { try source(root.appendingPathComponent("missing.rs")) }

    // Over a lost link a source reads as captured; a file never fetched
    // reads as lost, never as an empty or missing file.
    let pid = try #require(transport.loopProcessIdentifier)
    kill(-pid, SIGKILL)
    #expect(try source(main) == Array("pub fn main() {}\n".utf8))
    #expect {
        try source(root.appendingPathComponent("notes.txt"))
    } throws: { error in
        (error as? SSHTransport.Failure)?.isConnectionLoss == true
    }
    try #require(await testWaitUntil("disconnect shown") { model.remoteDisconnectedNotice != nil })
    #expect(model.remoteDisconnectedNotice?.contains(origin.displayName) == true)

    // Reconnect is Refresh Index: it connects again and recaptures only the
    // file that changed.
    model.refreshIndex(leaving: nil)
    try #require(await testWaitUntil("refreshed") {
        !model.isRefreshingIndex && model.snapshotPhase == .fullReady
    })
    #expect(model.indexRefreshNotice == nil)
    #expect(model.remoteDisconnectedNotice == nil)
    #expect(made.all.count == 1)
    #expect(transport.lastCapturedPaths == ["src/main.rs"])
    #expect(transport.lastHashedPaths.isEmpty)
    #expect(try model.readCapturedProjectSource(at: "src/main.rs")?.bytes
        == Array("pub fn main() { changed(); }\n".utf8))

    // The session is saved under the placeholder and reopens the remote.
    model.openInNewTab(main)
    try model.writeSessionCheckpoint(panelPreset: .reading)
    let snapshot = try #require(model.loadSessionSnapshot(forProject: root).snapshot)
    #expect(snapshot.projectRoot == root.path)
    await model.closeProject()
    #expect(model.remoteOrigin == nil)
    #expect(await testWaitUntil("connection closed") { !transport.isConnected })

    let reopened = AppModel(
        sessionURL: sessionURL,
        indexService: remoteService(made),
        exactCoordinator: ExactCoordinator(checkoutStore: CheckoutStore(
            parentURL: sessionURL.deletingLastPathComponent().appendingPathComponent("checkouts")
        ))
    )
    #expect(await reopened.restoreSession(snapshot))
    #expect(reopened.remoteOrigin == origin)
    #expect(reopened.tabStrip.tabs.compactMap(\.fileURL).map(\.standardizedFileURL) == [main.standardizedFileURL])
    #expect(try reopened.documentSource?(main) == Array("pub fn main() { changed(); }\n".utf8))
    await reopened.closeProject()
}

/// With no source left in the byte cache, a search after the link is lost
/// reads every file as truncated (never "no matches") and the window shows
/// the disconnect.
@MainActor
@Test
func searchOverALostLinkReportsTruncatedFilesAndTheDisconnect() async throws {
    _ = isolatedIndexCacheRoot
    _ = isolatedRemotesRoot
    let remote = FileManager.default.temporaryDirectory
        .appendingPathComponent("remote-search-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: remote) }
    try write("pub fn alpha() {}\n", to: "src/a.rs", under: remote)
    try write("pub fn beta() {}\n", to: "src/b.rs", under: remote)
    let origin = try #require(RemoteOrigin(host: "test-host", path: remote.path))
    let made = MadeTransports()
    let model = AppModel(indexService: remoteService(made, cacheBytes: 0))
    await model.openProject(root: try origin.placeholder()).value
    try #require(await testWaitUntil("remote fullReady") { model.snapshotPhase == .fullReady })
    let transport = try #require(made.all.first)
    kill(-(try #require(transport.loopProcessIdentifier)), SIGKILL)

    model.projectSearch.setQuery("fn")
    try #require(await testWaitUntil("search settled") {
        model.projectSearch.isTruncated && !model.projectSearch.isSearching
    })
    #expect(model.projectSearch.totalMatches == 0)
    #expect(model.projectSearch.groups.map(\.path) == ["src/a.rs", "src/b.rs"])
    #expect(model.projectSearch.groups.filter { !$0.isTruncated }.isEmpty)
    try #require(await testWaitUntil("disconnect shown") { model.remoteDisconnectedNotice != nil })
    await model.closeProject()
}

/// Only a folder directly under the placeholder parent, named by the digest
/// of the record it holds, is a remote project; the input is `host:/path`.
@Test
func remoteOriginParsesTargetsAndRecognizesOnlyItsPlaceholders() throws {
    #expect(RemoteOrigin(parsing: " bots:/home/me/./work// ")?.displayName == "bots:/home/me/work")
    #expect(RemoteOrigin(parsing: "user@bots:/") == RemoteOrigin(host: "user@bots", path: "/"))
    for bad in ["bots", "bots:work", "-oProxyCommand=x:/a", "two words:/a", "bots:/a/../b", ":/a"] {
        #expect(RemoteOrigin(parsing: bad) == nil, "\(bad)")
    }

    let parent = FileManager.default.temporaryDirectory
        .appendingPathComponent("remotes-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: parent) }
    let origin = try #require(RemoteOrigin(parsing: "bots:/srv/a"))
    let placeholder = try origin.placeholder(in: parent)
    #expect(try origin.placeholder(in: parent) == placeholder)
    #expect(RemoteOrigin(placeholder: placeholder, parent: parent) == origin)
    #expect(RemoteOrigin(placeholder: placeholder, parent: parent.appendingPathComponent("x")) == nil)

    // The same record anywhere else, or under another name, is just a folder.
    let elsewhere = FileManager.default.temporaryDirectory
        .appendingPathComponent(placeholder.lastPathComponent, isDirectory: true)
    let renamed = parent.appendingPathComponent(String(repeating: "0", count: 64), isDirectory: true)
    for copy in [elsewhere, renamed] {
        try FileManager.default.copyItem(at: placeholder, to: copy)
        #expect(RemoteOrigin(placeholder: copy, parent: parent) == nil)
    }
    try FileManager.default.removeItem(at: elsewhere)
}
