import CodeInsightCore
import CodeInsightEngine
import CodeInsightExact
import CodeInsightGit
import CodeInsightReaderCore
import Foundation
import Observation

public enum ProjectState: Sendable {
    case empty
    case indexing(root: URL, startedAt: ContinuousClock.Instant)
    case ready(EngineSession, QueryContext)
    case failed
}

public enum SnapshotPhase: Int, Sendable {
    case firstPaint
    case cachedReady
    case fullReady
}

public struct SnapshotCoverage: Equatable, Sendable {
    public let filesIndexed: Int
    public let filesTotal: Int
    /// Reserved for a real module-import reachability count.
    public let importsResolved: Int?

    public init(filesIndexed: Int, filesTotal: Int, importsResolved: Int? = nil) {
        self.filesIndexed = filesIndexed
        self.filesTotal = filesTotal
        self.importsResolved = importsResolved
    }

    public func statusText(for phase: SnapshotPhase?) -> String? {
        guard let phase, phase != .fullReady else { return nil }
        let files = "Files \(filesIndexed)/\(filesTotal)"
        guard let importsResolved else {
            return files
        }
        return "\(files) · Imports resolved \(importsResolved)"
    }
}

public protocol IndexService: Sendable {
    func index(root: URL, language: LanguageID) async throws -> EngineSession
    func captureSnapshot(
        root: URL,
        revision: String?,
        language: LanguageID
    ) async throws -> any Snapshot
    func captureSnapshot(
        root: URL,
        revision: String?,
        languages: [LanguageID]
    ) async throws -> any Snapshot
    func prepareSnapshot(
        _ snapshot: any Snapshot,
        language: LanguageID
    ) async throws -> ProjectIndexer.PreparedSnapshot
    func prepareSnapshots(
        _ snapshot: any Snapshot,
        root: URL,
        languages: [LanguageID]
    ) async throws -> [ProjectIndexer.PreparedSnapshot]
    func completeSnapshot(
        _ prepared: ProjectIndexer.PreparedSnapshot
    ) async throws -> EngineSession
    func flushPersistentIndexCache()
}

public extension IndexService {
    func index(root: URL) async throws -> EngineSession {
        try await index(root: root, language: .rust)
    }

    func captureSnapshot(
        root: URL,
        revision: String?,
        language: LanguageID
    ) async throws -> any Snapshot {
        throw CocoaError(.featureUnsupported)
    }

    func captureSnapshot(
        root: URL,
        revision: String?,
        languages: [LanguageID]
    ) async throws -> any Snapshot {
        let normalized = try LanguageMode.normalize(languages: languages)
        guard normalized.count == 1 else {
            throw CocoaError(.featureUnsupported)
        }
        return try await captureSnapshot(
            root: root,
            revision: revision,
            language: normalized[0]
        )
    }

    func prepareSnapshot(
        _ snapshot: any Snapshot,
        language: LanguageID
    ) async throws -> ProjectIndexer.PreparedSnapshot {
        throw CocoaError(.featureUnsupported)
    }

    func prepareSnapshots(
        _ snapshot: any Snapshot,
        root: URL,
        languages: [LanguageID]
    ) async throws -> [ProjectIndexer.PreparedSnapshot] {
        let normalized = try LanguageMode.normalize(languages: languages)
        guard normalized.count == 1 else {
            throw CocoaError(.featureUnsupported)
        }
        return [
            try await prepareSnapshot(snapshot, language: normalized[0]),
        ]
    }

    func captureSnapshot(root: URL, revision: String?) async throws -> any Snapshot {
        try await captureSnapshot(
            root: root,
            revision: revision,
            language: .rust
        )
    }

    func prepareSnapshot(
        _ snapshot: any Snapshot
    ) async throws -> ProjectIndexer.PreparedSnapshot {
        try await prepareSnapshot(snapshot, language: .rust)
    }

    func completeSnapshot(
        _ prepared: ProjectIndexer.PreparedSnapshot
    ) async throws -> EngineSession {
        throw CocoaError(.featureUnsupported)
    }

    func flushPersistentIndexCache() {}
}

public final class ProjectIndexService: IndexService, @unchecked Sendable {
    private let store = ProjectIndexStore()
    private let lock = NSLock()
    private var indexer = ProjectIndexer()

    public init() {}

    public static func loadCommitHistory(root: URL) async throws -> [CommitInfo] {
        try await detachedValue {
            try CommitLog(repositoryURL: root).commits
        }
    }

    public func index(
        root: URL,
        language: LanguageID
    ) async throws -> EngineSession {
        try validateProductSupport(language)
        let store = store
        let indexer = ProjectIndexer(persistingProjectAt: root)
        lock.withLock { self.indexer = indexer }
        return try await detachedValue {
            let snapshot: WorktreeSnapshot
            do {
                snapshot = try WorktreeSnapshot(
                    repositoryURL: root,
                    language: language
                )
            } catch {
                return try indexer.index(root: root, language: language)
            }
            return try indexer.indexSnapshot(
                snapshot,
                into: store,
                language: language
            )
        }
    }

    public func captureSnapshot(
        root: URL,
        revision: String?,
        language: LanguageID
    ) async throws -> any Snapshot {
        try validateProductSupport(language)
        return try await detachedValue {
            try Task.checkCancellation()
            let snapshot: any Snapshot = if let revision {
                try CommitSnapshot(repositoryURL: root, revision: revision)
            } else {
                try WorktreeSnapshot(repositoryURL: root, language: language)
            }
            try Task.checkCancellation()
            return snapshot
        }
    }

    public func prepareSnapshot(
        _ snapshot: any Snapshot,
        language: LanguageID
    ) async throws -> ProjectIndexer.PreparedSnapshot {
        let store = store
        let indexer: ProjectIndexer = lock.withLock { self.indexer }
        return try await detachedValue {
            try indexer.prepareSnapshot(
                snapshot,
                into: store,
                language: language
            )
        }
    }

    public func captureSnapshot(
        root: URL,
        revision: String?,
        languages: [LanguageID]
    ) async throws -> any Snapshot {
        let normalized = try LanguageMode.normalize(languages: languages)
        return try await detachedValue {
            try Task.checkCancellation()
            let snapshot: any Snapshot = if let revision {
                try CommitSnapshot(repositoryURL: root, revision: revision)
            } else {
                try WorktreeSnapshot(repositoryURL: root, languages: normalized)
            }
            try Task.checkCancellation()
            return snapshot
        }
    }

    public func prepareSnapshots(
        _ snapshot: any Snapshot,
        root: URL,
        languages: [LanguageID]
    ) async throws -> [ProjectIndexer.PreparedSnapshot] {
        let normalized = try LanguageMode.normalize(languages: languages)
        if normalized.count == 1 {
            return [
                try await prepareSnapshot(
                    snapshot,
                    language: normalized[0]
                ),
            ]
        }
        let expectedSnapshotID = snapshot.snapshotID
        let store = store
        let indexer = ProjectIndexer()
        let expectedProfiles = try await detachedValue {
            if normalized.count > 1 {
                _ = try GitRepository(url: root)
            }
            return try indexer.validatedProfiles(
                snapshot: snapshot,
                languages: normalized,
                store: store
            )
        }
        guard expectedProfiles.map(\.language) == normalized else {
            throw CocoaError(.coderInvalidValue, userInfo: [
                NSLocalizedFailureReasonErrorKey:
                    "mixed profile languages did not match requested set",
            ])
        }
        guard snapshot.snapshotID == expectedSnapshotID else {
            throw CocoaError(.coderInvalidValue, userInfo: [
                NSLocalizedFailureReasonErrorKey:
                    "snapshot identity changed before persistence",
            ])
        }
        let persistent = ProjectIndexer(persistingProjectAt: root)
        lock.withLock { self.indexer = persistent }
        let prepared = try await detachedValue {
            try normalized.map { language in
                try persistent.prepareSnapshot(
                    snapshot,
                    into: store,
                    language: language,
                    discoverUnitRoot: true
                )
            }
        }
        for index in prepared.indices {
            let prepared = prepared[index]
            let language = normalized[index]
            let expected = expectedProfiles[index]
            guard prepared.cachedSession.analysisProfile.language == language,
                  prepared.cachedSession.analysisProfile.projectRoot == expected.projectRoot,
                  prepared.cachedSession.analysisProfile.id == expected.id,
                  prepared.cachedSession.snapshotID == expectedSnapshotID
            else {
                throw CocoaError(.coderInvalidValue, userInfo: [
                    NSLocalizedFailureReasonErrorKey:
                        "mixed prepared profile identity mismatch",
                ])
            }
        }
        return prepared
    }

    public func completeSnapshot(
        _ prepared: ProjectIndexer.PreparedSnapshot
    ) async throws -> EngineSession {
        try await detachedValue {
            try ProjectIndexer().completeSnapshot(prepared)
        }
    }

    public func flushPersistentIndexCache() {
        let indexer: ProjectIndexer = lock.withLock { self.indexer }
        indexer.flushPersistentWrites()
    }
}

private func detachedValue<Value: Sendable>(
    _ operation: @escaping @Sendable () throws -> Value
) async throws -> Value {
    let task = Task.detached(priority: .userInitiated, operation: operation)
    return try await withTaskCancellationHandler {
        try await task.value
    } onCancel: {
        task.cancel()
    }
}

public final class FileTreeNode: Sendable {
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let children: [FileTreeNode]

    fileprivate init(url: URL, isDirectory: Bool, children: [FileTreeNode] = []) {
        self.url = url
        name = url.lastPathComponent
        self.isDirectory = isDirectory
        self.children = children
    }
}

public struct FileTreeModel: Sendable {
    public let root: URL
    public let children: [FileTreeNode]
    public let fileCount: Int

    public init(root: URL) throws {
        try self.init(root: root, language: .rust)
    }

    public init(root: URL, language: LanguageID) throws {
        self.root = root.standardizedFileURL
        _ = language
        children = try Self.children(in: self.root)
        fileCount = Self.fileCount(in: children)
    }

    public init(root: URL, snapshotPaths: [String]) {
        self.init(root: root, snapshotPaths: snapshotPaths, language: .rust)
    }

    public init(
        root: URL,
        snapshotPaths: [String],
        language: LanguageID
    ) {
        self.root = root.standardizedFileURL
        _ = language
        let paths = snapshotPaths.map { $0.split(separator: "/").map(String.init) }
        children = Self.children(from: paths, under: self.root)
        fileCount = Self.fileCount(in: children)
    }

    public init(
        root: URL,
        snapshotPaths: [String],
        languages: [LanguageID]
    ) {
        self.root = root.standardizedFileURL
        _ = languages
        let paths = snapshotPaths.map { $0.split(separator: "/").map(String.init) }
        children = Self.children(from: paths, under: self.root)
        fileCount = Self.fileCount(in: children)
    }

    public func selectionPath(for selectedFile: URL?) -> [FileTreeNode]? {
        guard let selectedFile else { return nil }
        return Self.selectionPath(
            for: selectedFile.standardizedFileURL,
            in: children
        )
    }

    private static func children(in directory: URL) throws -> [FileTreeNode] {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
        ]
        var nodes: [FileTreeNode] = []
        for url in try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys)
        ) {
            let values = try url.resourceValues(forKeys: keys)
            if values.isDirectory == true {
                guard values.isSymbolicLink != true,
                      !ProjectIndexer.skippedDirectories.contains(url.lastPathComponent)
                else { continue }
                let children = try children(in: url)
                if !children.isEmpty {
                    nodes.append(FileTreeNode(
                        url: url,
                        isDirectory: true,
                        children: children
                    ))
                }
            } else if values.isRegularFile == true,
                      url.lastPathComponent != ".DS_Store"
            {
                nodes.append(FileTreeNode(url: url, isDirectory: false))
            }
        }
        return nodes.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name < $1.name
        }
    }

    private static func children(
        from paths: [[String]],
        under directory: URL
    ) -> [FileTreeNode] {
        // ponytail: rescans each directory group; replace with a trie only if
        // very large Rust manifests make first paint miss its budget.
        var nodes: [FileTreeNode] = []
        for name in Set(paths.compactMap(\.first)) {
            let matching = paths.filter { $0.first == name }
            let tails = matching.map { Array($0.dropFirst()) }
            let url = directory.appendingPathComponent(name)
            if tails.contains(where: \.isEmpty) {
                nodes.append(FileTreeNode(url: url, isDirectory: false))
            } else {
                nodes.append(FileTreeNode(
                    url: url,
                    isDirectory: true,
                    children: children(from: tails, under: url)
                ))
            }
        }
        return nodes.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name < $1.name
        }
    }

    private static func fileCount(in nodes: [FileTreeNode]) -> Int {
        nodes.reduce(0) { count, node in
            count + (node.isDirectory ? fileCount(in: node.children) : 1)
        }
    }

    private static func selectionPath(
        for selectedFile: URL,
        in nodes: [FileTreeNode]
    ) -> [FileTreeNode]? {
        for node in nodes {
            if node.url.standardizedFileURL == selectedFile { return [node] }
            if let descendants = selectionPath(for: selectedFile, in: node.children) {
                return [node] + descendants
            }
        }
        return nil
    }
}

@MainActor
@Observable
public final class AppModel {
    package enum ReplayFallbackKind: Equatable, Sendable {
        case exact
        case byteUnverified
        case line
        case symbol
        case fileHead
    }

    private enum SnapshotDestination {
        case worktree
        case commit(revision: String, fullOID: String?)
    }

    public private(set) var projectState: ProjectState = .empty
    public private(set) var generation: UInt64 = 0
    package private(set) var projectLanguages: [LanguageID] = []
    package var projectLanguage: LanguageID? {
        projectLanguages.count == 1 ? projectLanguages.first : nil
    }
    private var workspaceSessions: [AnalysisProfileID: EngineSession] = [:]
    public private(set) var snapshotPhase: SnapshotPhase?
    public private(set) var coverage = SnapshotCoverage(filesIndexed: 0, filesTotal: 0)
    public var currentRevision: String? { commitPicker.currentRevision }
    public private(set) var currentSnapshotID: SnapshotID?
    public private(set) var fileTree: FileTreeModel?
    public private(set) var selectedFile: URL?
    public private(set) var selectedByteOffset: UInt32?
    public private(set) var navigationGeneration: UInt64 = 0
    public private(set) var activeNavigationRequest: NavigationRequest?
    public private(set) var replayNotice: String?
    /// Set when an index-derived navigation was rejected because the target
    /// content no longer matches the indexed bytes. Cleared when a semantic
    /// navigation verifies again or the workspace republishes a snapshot.
    public private(set) var staleIndexNotice: String?
    /// True while a Refresh Index capture is in flight.
    public private(set) var isRefreshingIndex = false
    /// Set when Refresh Index failed and the previous index was restored.
    public private(set) var indexRefreshNotice: String?
    @ObservationIgnored public private(set) var documentSource: DocumentLoader.ContentSource?
    public let contextWindow: ContextWindowModel
    public let exactCoordinator: ExactCoordinator
    public let commitPicker: CommitPickerModel
    public let compare: CompareModel
    public let relationTree = RelationTreeModel()
    public let navigationHistory = NavigationHistory()
    public let readingTrail = ReadingTrail()
    public let resolutionExplanations = ResolutionExplanationStore()
    public let tabStrip = TabStripModel()
    package var bookmarkModel = BookmarkModel()

    public var canTrustCurrentRepository: Bool {
        guard case .ready = projectState, let projectRoot else { return false }
        return !exactCoordinator.isTrusted(projectRoot)
    }

    public var activeAnalysisProfileDisplay: (
        language: LanguageID,
        projectUnitName: String,
        featureSelection: FeatureSelection,
        edition: String?
    )? {
        guard case let .ready(session, _) = projectState else { return nil }
        let profile = session.analysisProfile
        return (
            profile.language,
            profile.projectUnitName,
            profile.featureSelection,
            profile.edition
        )
    }

    package var querySessions: [(EngineSession, QueryContext)] {
        guard case .ready = projectState,
              snapshotPhase == .fullReady || snapshotPhase == .cachedReady,
              workspaceSessions.count == projectLanguages.count
        else {
            return []
        }
        return querySessionTuples()
    }

    public var currentFeatureSelection: FeatureSelection? {
        activeAnalysisProfileDisplay?.featureSelection
    }

    public var availableFeatureSelections: [FeatureSelection] {
        guard activeAnalysisProfileDisplay?.language == .rust else {
            return [.defaultFeatures]
        }
        return FeatureSelection.allCases
    }

    private let indexService: any IndexService
    private let navigationSink: @MainActor (URL, UInt32?) -> Void
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    @ObservationIgnored private var compareSnapshotTask: Task<Void, Never>?
    @ObservationIgnored private var replayTask: Task<Void, Never>?
    @ObservationIgnored private var semanticValidationTask: Task<Void, Never>?
    @ObservationIgnored private var sessionCheckpointTask: Task<Void, Never>?
    @ObservationIgnored private var sessionURL: URL?
    package private(set) var projectRoot: URL?
    private var lastInstalledProjectRoot: URL?
    private var lastInstalledRevision: String?
    private var lastInstalledGeneration: UInt64?
    package var lastInstalledWorkspace: (
        projectRoot: URL?,
        revision: String?,
        generation: UInt64?
    ) {
        (lastInstalledProjectRoot, lastInstalledRevision, lastInstalledGeneration)
    }
    @ObservationIgnored private var snapshotDestinations: [
        SnapshotID: SnapshotDestination
    ] = [:]
    @ObservationIgnored private var pendingReplay: (
        record: NavigationRecord,
        replayedAgainstCurrentWorktree: Bool,
        opensInNewTab: Bool
    )?
    package var hasPendingReplay: Bool { pendingReplay != nil }

    public init(
        indexService: any IndexService = ProjectIndexService(),
        contextWindow: ContextWindowModel = ContextWindowModel(),
        exactCoordinator: ExactCoordinator = ExactCoordinator(),
        commitPicker: CommitPickerModel = CommitPickerModel(),
        compare: CompareModel = CompareModel(),
        navigationSink: @MainActor @escaping (URL, UInt32?) -> Void = { _, _ in }
    ) {
        self.indexService = indexService
        self.contextWindow = contextWindow
        self.exactCoordinator = exactCoordinator
        self.commitPicker = commitPicker
        self.compare = compare
        self.navigationSink = navigationSink
        contextWindow.attachExactCoordinator(exactCoordinator)
        contextWindow.onStaleIndexContent = { [weak self] _ in
            self?.markStaleIndexContent()
        }
        relationTree.attachExactCoordinator(exactCoordinator)
        relationTree.onContextsReset = { [weak self] in
            self?.contextWindow.cancelExactUpgrade()
            self?.retainTrailExplanations()
        }
        relationTree.onExplanationChange = { [weak self] node in
            self?.refreshExplanation(for: node)
        }
        relationTree.onSelect = { [weak self] node in
            guard let self,
                  contextWindow.mode != .pinned,
                  let target = node.queryTarget ?? node.target
            else { return }
            Task { [weak self] in
                _ = await self?.contextWindow.explicitJump(
                    file: target.path,
                    offset: target.byteOffset
                )
            }
        }
    }

    package convenience init(
        sessionURL: URL,
        indexService: any IndexService = ProjectIndexService(),
        contextWindow: ContextWindowModel = ContextWindowModel(),
        exactCoordinator: ExactCoordinator = ExactCoordinator(),
        commitPicker: CommitPickerModel = CommitPickerModel(),
        compare: CompareModel = CompareModel(),
        navigationSink: @MainActor @escaping (URL, UInt32?) -> Void = { _, _ in }
    ) {
        self.init(
            indexService: indexService,
            contextWindow: contextWindow,
            exactCoordinator: exactCoordinator,
            commitPicker: commitPicker,
            compare: compare,
            navigationSink: navigationSink
        )
        self.sessionURL = sessionURL.standardizedFileURL
        self.bookmarkModel = BookmarkModel(store: BookmarkStore(
            fileURL: sessionURL.standardizedFileURL
                .deletingLastPathComponent()
                .appendingPathComponent("bookmarks.json")
        ))
    }

    package static var defaultSessionURL: URL {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "dev.cairn.Cairn"
        return FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
            .appendingPathComponent("Cairn", isDirectory: true)
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("session.json")
    }

    package func scheduleSessionCheckpoint(panelPreset: PanelPresetModel) {
        guard sessionURL != nil, !isRefreshingIndex else { return }
        sessionCheckpointTask?.cancel()
        let checkpointGeneration = lastInstalledGeneration
        let checkpointLanguages = projectLanguages
        sessionCheckpointTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled,
                  let self,
                  lastInstalledGeneration == checkpointGeneration,
                  projectLanguages == checkpointLanguages
            else { return }
            try? writeSessionCheckpointNow(
                panelPreset: panelPreset,
                allowsPendingTopology: false
            )
            sessionCheckpointTask = nil
        }
    }

    package func cancelPendingSessionCheckpoint() {
        sessionCheckpointTask?.cancel()
        sessionCheckpointTask = nil
    }

    package func loadSessionSnapshot() -> (
        snapshot: SessionCodec.Snapshot?,
        discarded: Bool
    ) {
        guard let sessionURL,
              FileManager.default.fileExists(atPath: sessionURL.path)
        else { return (nil, false) }
        do {
            let snapshot = try SessionCodec.decode(
                Data(contentsOf: sessionURL),
                maximumTabCount: tabStrip.maximumCount,
                dependencyAllowed: exactLocationIsInDependency
            )
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: snapshot.projectRoot,
                isDirectory: &isDirectory
            ), isDirectory.boolValue else {
                throw CocoaError(.fileNoSuchFile)
            }
            return (snapshot, false)
        } catch {
            try? FileManager.default.removeItem(at: sessionURL)
            return (nil, true)
        }
    }

    package func writeSessionCheckpoint(
        panelPreset: PanelPresetModel,
        allowsPendingTopology: Bool = false
    ) throws {
        cancelPendingSessionCheckpoint()
        try writeSessionCheckpointNow(
            panelPreset: panelPreset,
            allowsPendingTopology: allowsPendingTopology
        )
    }

    private func writeSessionCheckpointNow(
        panelPreset: PanelPresetModel,
        allowsPendingTopology: Bool
    ) throws {
        guard let sessionURL,
              let snapshot = makeSessionSnapshot(
                  panelPreset: panelPreset,
                  allowsPendingTopology: allowsPendingTopology
              )
        else { return }
        let data = try SessionCodec.encode(
            snapshot,
            maximumTabCount: tabStrip.maximumCount,
            dependencyAllowed: exactLocationIsInDependency
        )
        try FileManager.default.createDirectory(
            at: sessionURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: sessionURL, options: .atomic)
    }

    private func makeSessionSnapshot(
        panelPreset: PanelPresetModel,
        allowsPendingTopology: Bool
    ) -> SessionCodec.Snapshot? {
        guard let root = projectRoot,
              lastInstalledProjectRoot?.standardizedFileURL
                == root.standardizedFileURL,
              allowsPendingTopology || lastInstalledGeneration == generation
        else { return nil }
        let languages = projectLanguages
        guard !languages.isEmpty else { return nil }
        var entries: [SessionCodec.Tab] = []
        entries.reserveCapacity(tabStrip.tabs.count)
        for tab in tabStrip.tabs {
            switch tab.content {
            case .file(let file):
                let path: String
                if let relative = Self.relativePath(of: file, under: root) {
                    path = relative
                } else if exactLocationIsInDependency(file.path) {
                    path = file.path
                } else {
                    return nil
                }
                entries.append(.file(.init(
                    path: path,
                    anchorContentID: tab.anchorContentID,
                    scrollAnchor: tab.scrollAnchor,
                    selectionAnchor: tab.selectionAnchor
                )))
            case .readingSet(let title, let excerpts):
                entries.append(.readingSet(.init(
                    title: title,
                    excerpts: excerpts,
                    scrollOffset: tab.readingSetScrollOffset,
                    skippedReasons: tab.readingSetSkippedReasons
                )))
            }
        }
        return SessionCodec.Snapshot(
            projectRoot: root.path,
            languages: languages,
            revision: lastInstalledRevision,
            activeTabOrdinal: tabStrip.activeIndex,
            panelPreset: panelPreset.rawValue,
            tabs: entries
        )
    }

    /// Shared open lifecycle for both entry points: cancels in-flight
    /// workspace work, advances the workspace generation, and resets
    /// per-project state. Snapshot switches and index refreshes keep their
    /// own narrower scopes (tabs, trail, and history survive those).
    private func beginWorkspaceOpen(
        root: URL,
        languages: [LanguageID]
    ) -> UInt64 {
        snapshotTask?.cancel()
        compareSnapshotTask?.cancel()
        replayTask?.cancel()
        semanticValidationTask?.cancel()
        compare.clear()
        generation &+= 1
        let openGeneration = generation
        bookmarkModel.workspaceDidChange(to: openGeneration)
        exactCoordinator.invalidate(generation: openGeneration)
        projectRoot = root
        projectLanguages = languages
        workspaceSessions.removeAll(keepingCapacity: true)
        commitPicker.setCurrentRevision(nil)
        commitPicker.load(repositoryURL: root)
        currentSnapshotID = nil
        snapshotDestinations.removeAll(keepingCapacity: true)
        pendingReplay = nil
        documentSource = nil
        transition(to: .indexing(root: root, startedAt: .now))
        snapshotPhase = nil
        coverage = SnapshotCoverage(filesIndexed: 0, filesTotal: 0)
        fileTree = nil
        selectedFile = nil
        selectedByteOffset = nil
        navigationGeneration &+= 1
        navigationHistory.reset()
        readingTrail.reset()
        resolutionExplanations.removeAll()
        replayNotice = nil
        staleIndexNotice = nil
        endIndexRefresh()
        tabStrip.reset()
        return openGeneration
    }

    public func openProject(root: URL, languages: [LanguageID]) async throws {
        let normalized = try LanguageMode.normalize(languages: languages)
        let root = root.standardizedFileURL
        let openGeneration = beginWorkspaceOpen(
            root: root,
            languages: normalized
        )
        // The staged capture/prepare/complete chain is shared with snapshot
        // switches and index refreshes; storing it in snapshotTask lets a
        // newer open cancel an in-flight one instead of abandoning it.
        snapshotTask = snapshotLoadTask(
            revision: nil,
            generation: openGeneration,
            root: root,
            languages: normalized
        ) { [weak self] generation, root, languages in
            self?.failWorkspace(
                generation: generation,
                root: root,
                languages: languages
            )
        }
        await snapshotTask?.value
    }

    private func failWorkspace(
        generation expectedGeneration: UInt64,
        root expectedRoot: URL,
        languages expectedLanguages: [LanguageID]
    ) {
        guard canPublishWorkspaceResult(
            generation: expectedGeneration,
            root: expectedRoot,
            languages: expectedLanguages
        ) else { return }
        pendingReplay = nil
        workspaceSessions.removeAll(keepingCapacity: true)
        publishProjectState(.failed, root: expectedRoot)
    }

    package func restoreSession(_ snapshot: SessionCodec.Snapshot) async -> Bool {
        let root = URL(
            fileURLWithPath: snapshot.projectRoot,
            isDirectory: true
        ).standardizedFileURL
        let languages: [LanguageID]
        do {
            languages = try LanguageMode.normalize(languages: snapshot.languages)
        } catch {
            return false
        }
        let worktreeGeneration: UInt64
        if languages.count == 1 {
            do {
                try openProject(root: root, language: languages[0])
            } catch {
                return false
            }
            worktreeGeneration = generation
            let worktreeTask = snapshotTask
            await worktreeTask?.value
        } else {
            worktreeGeneration = generation &+ 1
            do {
                try await openProject(root: root, languages: languages)
            } catch {
                return false
            }
        }
        guard canPublishWorkspaceResult(
                  generation: worktreeGeneration,
                  root: root,
                  languages: languages
              ),
              snapshotPhase == .fullReady
        else { return false }

        var revisionUnavailable = false
        if let revision = snapshot.revision {
            let revisionExists = await Task.detached {
                (try? CommitSnapshot(
                    repositoryURL: root,
                    revision: revision
                )) != nil
            }.value
            guard canPublishWorkspaceResult(
                generation: worktreeGeneration,
                root: root,
                languages: languages
            )
            else { return false }
            if revisionExists {
                switchSnapshot(revision: revision)
                let revisionGeneration = generation
                let revisionTask = snapshotTask
                await revisionTask?.value
                guard canPublishWorkspaceResult(
                    generation: revisionGeneration,
                    root: root,
                    languages: languages
                )
                else { return false }
                if snapshotPhase != .fullReady {
                    revisionUnavailable = true
                    let fallbackGeneration: UInt64
                    do {
                        if languages.count == 1 {
                            try openProject(root: root, language: languages[0])
                            fallbackGeneration = generation
                        } else {
                            fallbackGeneration = generation &+ 1
                            try await openProject(
                                root: root,
                                languages: languages
                            )
                        }
                    } catch {
                        return false
                    }
                    if languages.count == 1 {
                        let fallbackTask = snapshotTask
                        await fallbackTask?.value
                    }
                    guard canPublishWorkspaceResult(
                              generation: fallbackGeneration,
                              root: root,
                              languages: languages
                          ),
                          snapshotPhase == .fullReady
                    else { return false }
                }
            } else {
                revisionUnavailable = true
            }
        }

        let restoreGeneration = generation
        let source = documentSource
        var oldToNew: [Int: (
            index: Int,
            scrollFallback: ReplayFallbackKind?,
            selectionFallback: ReplayFallbackKind?
        )] = [:]
        var successfulOrdinals: [Int] = []
        for (oldOrdinal, entry) in snapshot.tabs.enumerated() {
            guard canPublishWorkspaceResult(
                generation: restoreGeneration,
                root: root,
                languages: languages
            )
            else { return false }
            switch entry {
            case .file(let saved):
                let dependency = exactLocationIsInDependency(saved.path)
                let file = dependency
                    ? URL(fileURLWithPath: saved.path).standardizedFileURL
                    : root.appendingPathComponent(saved.path).standardizedFileURL
                guard dependency || (
                    file.pathComponents.starts(with: root.pathComponents)
                        && file.pathComponents.count > root.pathComponents.count
                ) else { continue }
                if !dependency,
                   let selectionPath = fileTree?.selectionPath(for: file),
                   let node = selectionPath.last,
                   !node.isDirectory,
                   languageMode(for: file) == nil
                {
                    tabStrip.open(
                        file,
                        inNewTab: true,
                        selectionByteOffset: nil
                    )
                    guard let newIndex = tabStrip.activeIndex else { continue }
                    oldToNew[oldOrdinal] = (newIndex, nil, nil)
                    successfulOrdinals.append(oldOrdinal)
                    continue
                }
                guard let languageMode = languageMode(for: file) else {
                    continue
                }
                let resolved = await Self.resolveSessionFile(
                    saved,
                    file: file,
                    source: dependency ? nil : source,
                    revision: currentRevision,
                    languageMode: languageMode
                )
                let canPublish = canPublishWorkspaceResult(
                    generation: restoreGeneration,
                    root: root,
                    languages: languages
                )
                guard canPublish,
                      self.languageMode(for: file) == languageMode,
                      let resolved
                else {
                    if !canPublish { return false }
                    continue
                }
                tabStrip.open(
                    file,
                    inNewTab: true,
                    selectionByteOffset: resolved.selectionAnchor?.byteOffset
                )
                tabStrip.updateActiveSessionAnchors(
                    contentID: resolved.contentID,
                    scrollAnchor: resolved.scrollAnchor,
                    selectionAnchor: resolved.selectionAnchor
                )
                guard let newIndex = tabStrip.activeIndex else { continue }
                oldToNew[oldOrdinal] = (
                    newIndex,
                    resolved.scrollFallback,
                    resolved.selectionFallback
                )
                successfulOrdinals.append(oldOrdinal)
            case .readingSet(let saved):
                tabStrip.openReadingSet(
                    title: saved.title,
                    excerpts: saved.excerpts,
                    skippedReasons: saved.skippedReasons
                )
                tabStrip.updateActiveReadingSetScroll(saved.scrollOffset)
                guard let newIndex = tabStrip.activeIndex else { continue }
                oldToNew[oldOrdinal] = (newIndex, nil, nil)
                successfulOrdinals.append(oldOrdinal)
            }
        }
        guard canPublishWorkspaceResult(
            generation: restoreGeneration,
            root: root,
            languages: languages
        )
        else { return false }

        let selected = snapshot.activeTabOrdinal.flatMap { oldToNew[$0] }
            ?? successfulOrdinals.first.flatMap { oldToNew[$0] }
        if let selected {
            activateTab(selected.index)
        }
        var notices: [String] = []
        if revisionUnavailable {
            notices.append("saved revision unavailable; restored against current worktree")
        }
        if let selected {
            for (anchor, fallback) in [
                ("selection", selected.selectionFallback),
                ("scroll", selected.scrollFallback),
            ] {
                if let fallback,
                   let notice = Self.replayNotice(
                       fallback: fallback,
                       replayedAgainstCurrentWorktree: false
                   )
                {
                    notices.append("\(anchor) \(notice)")
                }
            }
        }
        replayNotice = notices.isEmpty ? nil : notices.joined(separator: " · ")
        return true
    }

    nonisolated private static func resolveSessionFile(
        _ saved: SessionCodec.FileTab,
        file: URL,
        source: DocumentLoader.ContentSource?,
        revision: String?,
        languageMode: LanguageMode
    ) async -> (
        contentID: ContentID,
        scrollAnchor: SessionCodec.Anchor?,
        selectionAnchor: SessionCodec.Anchor?,
        scrollFallback: ReplayFallbackKind?,
        selectionFallback: ReplayFallbackKind?
    )? {
        try? await detachedValue {
            let loader = source.map(DocumentLoader.init(source:))
                ?? DocumentLoader()
            let loaded = try loader.load(
                file: file,
                languageMode: languageMode
            )
            func resolve(
                _ anchor: SessionCodec.Anchor?
            ) -> (SessionCodec.Anchor?, ReplayFallbackKind?) {
                guard let anchor else { return (nil, nil) }
                let record = JumpRecord(
                    path: file.path,
                    contentID: saved.anchorContentID,
                    byteOffset: anchor.byteOffset,
                    line: anchor.line,
                    column: anchor.column,
                    symbolAnchor: anchor.symbolAnchor,
                    snapshotID: nil,
                    revision: revision
                )
                let replayed = replayOffset(
                    record,
                    document: loaded.document,
                    tier: loaded.tier
                )
                let coordinate = loaded.document.lineTable.lineColumn(
                    at: replayed.offset
                )
                return (
                    SessionCodec.Anchor(
                        byteOffset: replayed.offset,
                        line: coordinate?.line ?? 1,
                        column: coordinate?.column ?? 1,
                        symbolAnchor: anchor.symbolAnchor
                    ),
                    replayed.fallback
                )
            }
            let scroll = resolve(saved.scrollAnchor)
            let selection = resolve(saved.selectionAnchor)
            return (
                loaded.document.contentID,
                scroll.0,
                selection.0,
                scroll.1,
                selection.1
            )
        }
    }

    public func openProject(root: URL) {
        do {
            try openProject(root: root, language: .rust)
        } catch {
            assertionFailure("Rust product support unexpectedly failed: \(error)")
        }
    }

    public func openProject(root: URL, language: LanguageID) throws {
        try validateProductSupport(language)
        let root = root.standardizedFileURL
        // Shares the open lifecycle with the multi-language entry; plain
        // non-Git directories keep the index() fallback below, whose errors
        // propagate into .failed unchanged (never reclassified as "not a
        // Git repository").
        let openGeneration = beginWorkspaceOpen(root: root, languages: [language])

        snapshotTask = Task { [weak self, indexService] in
            do {
                let fileTree = try await detachedValue {
                    try FileTreeModel(root: root, language: language)
                }
                try Task.checkCancellation()
                guard let self,
                      canPublishProjectResult(
                          generation: openGeneration,
                          root: root,
                          language: language
                      )
                else { return }
                self.fileTree = fileTree
                coverage = SnapshotCoverage(
                    filesIndexed: 0,
                    filesTotal: sourceFileCount(
                        in: fileTree.children,
                        under: fileTree.root,
                        languages: [language]
                    )
                )
                let session = try await indexService.index(
                    root: root,
                    language: language
                )
                try Task.checkCancellation()
                finishIndexing(
                    session,
                    generation: openGeneration,
                    root: root,
                    language: language
                )
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      canPublishProjectResult(
                          generation: openGeneration,
                          root: root,
                          language: language
                      )
                else { return }
                workspaceSessions.removeAll(keepingCapacity: true)
                failIndexing(
                    generation: openGeneration,
                    root: root,
                    language: language
                )
            }
        }
    }

    public func flushPersistentIndexCache() {
        indexService.flushPersistentIndexCache()
    }

    public func grantCurrentRepositoryTrust() async throws {
        guard let root = projectRoot else { return }
        let trustGeneration = generation
        try await exactCoordinator.grantTrust(root)
        guard generation == trustGeneration,
              projectRoot?.standardizedFileURL == root.standardizedFileURL,
              case .ready = projectState
        else { return }
        prepareExact(generation: trustGeneration)
    }

    public func revokeRepositoryTrust(_ repositoryURL: URL) async throws {
        let trustGeneration = generation
        try await exactCoordinator.revokeTrust(repositoryURL)
        guard generation == trustGeneration,
              projectRoot?.resolvingSymlinksInPath().standardizedFileURL
                == repositoryURL.resolvingSymlinksInPath().standardizedFileURL,
              case .ready = projectState
        else { return }
        prepareExact(generation: trustGeneration)
    }

    public func switchFeatureSelection(_ featureSelection: FeatureSelection) {
        guard snapshotPhase == .fullReady,
              case let .ready(session, _) = projectState,
              session.analysisProfile.language == .rust,
              session.analysisProfile.featureSelection != featureSelection
        else { return }
        let activeRelation = relationTree.root?.symbol.map {
            ($0, relationTree.direction)
        }
        generation &+= 1
        let profileGeneration = generation
        bookmarkModel.workspaceDidChange(to: profileGeneration)
        let reprofiled = session.reprofiled(featureSelection: featureSelection)
        let oldProfileID = session.analysisProfile.id
        workspaceSessions[oldProfileID] = nil
        workspaceSessions[reprofiled.analysisProfile.id] = reprofiled
        guard transition(to: .ready(
            reprofiled,
            QueryContext(
                snapshotID: reprofiled.snapshotID,
                analysisProfileID: reprofiled.analysisProfile.id,
                generation: profileGeneration
            )
        )) else {
            assertionFailure("Illegal project state transition while reprofiling")
            return
        }
        if let activeRelation {
            relationTree.setRoot(
                target: .engine(activeRelation.0),
                direction: activeRelation.1
            )
        }
        prepareExact(generation: profileGeneration)
    }

    public func switchToCommit(
        _ revision: String,
        leaving current: JumpRecord? = nil
    ) {
        pendingReplay = nil
        if selectedFile != nil, let current {
            let record = NavigationRecord(
                jump: current,
                trailNodeID: readingTrail.activeNodeID
            )
            navigationHistory.push(record)
            pendingReplay = (record, false, false)
        }
        switchSnapshot(revision: revision)
    }

    public func switchToWorktree(leaving current: JumpRecord? = nil) {
        pendingReplay = nil
        if selectedFile != nil, let current {
            let record = NavigationRecord(
                jump: current,
                trailNodeID: readingTrail.activeNodeID
            )
            navigationHistory.push(record)
            pendingReplay = (record, false, false)
        }
        switchSnapshot(revision: nil)
    }

    /// State captured before a refresh so a failed refresh can restore the
    /// previous index instead of failing the workspace.
    @ObservationIgnored private var refreshRestoreState: (
        sessions: [AnalysisProfileID: EngineSession],
        phase: SnapshotPhase?,
        coverage: SnapshotCoverage,
        fileTree: FileTreeModel?,
        snapshotID: SnapshotID?,
        documentSource: DocumentLoader.ContentSource?,
        readySession: EngineSession?,
        staleNotice: String?
    )?

    /// Recaptures the current worktree (or selected commit) as a new index
    /// generation. Tabs, Reading Sets, bookmarks, the trail, history, and the
    /// selected file are preserved; file positions restore through the
    /// existing replay fallbacks. A failed refresh restores the previous
    /// index instead of failing the workspace. Repeated triggers cancel the
    /// in-flight capture; this never routes through openProject, which would
    /// reset tabs and trail.
    public func refreshIndex(leaving current: JumpRecord?) {
        guard let root = projectRoot,
              !projectLanguages.isEmpty,
              case .ready = projectState
        else { return }
        snapshotTask?.cancel()
        compareSnapshotTask?.cancel()
        replayTask?.cancel()
        semanticValidationTask?.cancel()
        compare.clear()
        generation &+= 1
        let refreshGeneration = generation
        isRefreshingIndex = true
        indexRefreshNotice = nil
        if refreshRestoreState == nil {
            let readySession: EngineSession?
            if case let .ready(session, _) = projectState {
                readySession = session
            } else {
                readySession = nil
            }
            refreshRestoreState = (
                workspaceSessions,
                snapshotPhase,
                coverage,
                fileTree,
                currentSnapshotID,
                documentSource,
                readySession,
                staleIndexNotice
            )
        }
        bookmarkModel.workspaceDidChange(to: refreshGeneration)
        exactCoordinator.invalidate(generation: refreshGeneration)
        workspaceSessions.removeAll(keepingCapacity: true)
        snapshotPhase = nil
        coverage = SnapshotCoverage(filesIndexed: 0, filesTotal: 0)
        publishProjectState(.indexing(root: root, startedAt: .now), root: root)
        pendingReplay = nil
        if selectedFile != nil, let current {
            // Position restore rides the existing replay fallback chain; a
            // refresh, unlike a destination switch, adds no history entry.
            pendingReplay = (
                NavigationRecord(
                    jump: current,
                    trailNodeID: readingTrail.activeNodeID
                ),
                false,
                false
            )
        }
        let languages = projectLanguages
        if languages.count == 1 {
            let language = languages[0]
            snapshotTask = Task { [weak self, indexService] in
                do {
                    let session = try await indexService.index(
                        root: root,
                        language: language
                    )
                    try Task.checkCancellation()
                    let tree = try await detachedValue {
                        try FileTreeModel(root: root, language: language)
                    }
                    try Task.checkCancellation()
                    guard let self,
                          self.canPublishWorkspaceResult(
                              generation: refreshGeneration,
                              root: root,
                              languages: languages
                          )
                    else { return }
                    self.fileTree = tree
                    if let selected = self.selectedFile,
                       self.fileTree?.selectionPath(for: selected)?
                           .last?.isDirectory != false
                    {
                        self.selectedFile = nil
                        self.selectedByteOffset = nil
                    }
                    self.finishIndexing(
                        session,
                        generation: refreshGeneration,
                        root: root,
                        language: language
                    )
                    guard case .ready = self.projectState else {
                        self.refreshIndexDidFail(
                            generation: refreshGeneration,
                            root: root,
                            languages: languages
                        )
                        return
                    }
                    self.refreshIndexDidSucceed(
                        generation: refreshGeneration,
                        root: root,
                        languages: languages
                    )
                    if let pending = self.pendingReplay {
                        self.pendingReplay = nil
                        self.replayWithinCurrentSnapshot(
                            pending.record,
                            replayedAgainstCurrentWorktree: false,
                            opensInNewTab: false
                        )
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard let self,
                          self.canPublishWorkspaceResult(
                              generation: refreshGeneration,
                              root: root,
                              languages: languages
                          )
                    else { return }
                    self.refreshIndexDidFail(
                        generation: refreshGeneration,
                        root: root,
                        languages: languages
                    )
                }
            }
        } else {
            snapshotTask = snapshotLoadTask(
                revision: currentRevision,
                generation: refreshGeneration,
                root: root,
                languages: languages
            ) { [weak self] generation, root, languages in
                self?.refreshIndexDidFail(
                    generation: generation,
                    root: root,
                    languages: languages
                )
            } onSuccess: { [weak self] in
                self?.refreshIndexDidSucceed(
                    generation: refreshGeneration,
                    root: root,
                    languages: languages
                )
            }
        }
    }

    /// Hands the workspace over to a new open or switch flow: any in-flight
    /// index refresh stops owning the state.
    private func endIndexRefresh() {
        isRefreshingIndex = false
        indexRefreshNotice = nil
        refreshRestoreState = nil
    }

    private func refreshIndexDidSucceed(
        generation: UInt64,
        root: URL,
        languages: [LanguageID]
    ) {
        guard canPublishWorkspaceResult(
            generation: generation,
            root: root,
            languages: languages
        ) else { return }
        isRefreshingIndex = false
        indexRefreshNotice = nil
        refreshRestoreState = nil
        staleIndexNotice = nil
    }

    private func refreshIndexDidFail(
        generation: UInt64,
        root: URL,
        languages: [LanguageID]
    ) {
        guard canPublishWorkspaceResult(
            generation: generation,
            root: root,
            languages: languages
        ) else { return }
        isRefreshingIndex = false
        indexRefreshNotice = "Index refresh failed — previous index restored"
        pendingReplay = nil
        guard let restore = refreshRestoreState else { return }
        refreshRestoreState = nil
        workspaceSessions = restore.sessions
        snapshotPhase = restore.phase
        coverage = restore.coverage
        fileTree = restore.fileTree
        currentSnapshotID = restore.snapshotID
        documentSource = restore.documentSource
        staleIndexNotice = restore.staleNotice
        if let session = restore.readySession {
            publishProjectState(.ready(
                session,
                QueryContext(
                    snapshotID: session.snapshotID,
                    analysisProfileID: session.analysisProfile.id,
                    generation: generation
                )
            ), root: root)
            prepareExact(generation: generation)
        }
    }

    public func selectCompareCommit(_ revision: String) {
        guard let root = projectRoot,
              !projectLanguages.isEmpty
        else { return }
        compareSnapshotTask?.cancel()
        let compareGeneration = compare.beginLoading(revision: revision)
        let mainGeneration = generation
        let languages = projectLanguages
        compareSnapshotTask = Task { [weak self, indexService] in
            do {
                let snapshot = try await indexService.captureSnapshot(
                    root: root,
                    revision: revision,
                    languages: languages
                )
                try Task.checkCancellation()
                guard let self,
                      canPublishWorkspaceResult(
                          generation: mainGeneration,
                          root: root,
                          languages: languages
                      )
                else { return }
                guard compare.install(
                    snapshot: snapshot,
                    root: root,
                    revision: revision,
                    generation: compareGeneration
                ) else { return }
                updateCompareFile()
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      canPublishWorkspaceResult(
                          generation: mainGeneration,
                          root: root,
                          languages: languages
                      )
                else { return }
                compare.fail(generation: compareGeneration, error: error)
            }
        }
    }

    public func clearCompare() {
        compareSnapshotTask?.cancel()
        compareSnapshotTask = nil
        compare.clear()
    }

    public func navigate(
        to url: URL,
        byteOffset: UInt32? = nil,
        leaving current: JumpRecord? = nil
    ) {
        navigate(
            NavigationRequest(
                destination: SourceDestination(file: url, byteOffset: byteOffset),
                cause: .fileSelection,
                policy: byteOffset == nil ? .passive : .explicitSemantic
            ),
            leaving: current
        )
    }

    public func navigate(
        _ request: NavigationRequest,
        leaving current: JumpRecord? = nil
    ) {
        // Index-derived positions carry the content identity of the bytes
        // that produced them. The shared entry verifies the destination
        // before committing viewport, history, or Trail changes; positions
        // from the currently displayed document (outline, in-file find) and
        // pre-validated replays/bookmarks pass nil and commit directly.
        guard let byteOffset = request.destination.byteOffset,
              let expectedContentID = request.destination.expectedContentID
        else {
            commitNavigation(request, leaving: current)
            return
        }
        let file = request.destination.file.standardizedFileURL
        // Fast path: the destination is what the active Reader already shows,
        // so compare against the displayed document without re-reading.
        if let activeFile = tabStrip.activeTab?.fileURL?.standardizedFileURL,
           activeFile == file,
           let displayed = tabStrip.activeDocument
        {
            if displayed.contentID == expectedContentID,
               displayed.byteUTF16Map.utf16Offset(forByte: Int(byteOffset)) != nil
            {
                commitNavigation(request, leaving: current)
            } else {
                markStaleIndexNavigation(to: file)
            }
            return
        }
        // Slow path: verify the bytes the Reader will load, off the main
        // actor, and only publish while the request is still current.
        guard let root = projectRoot else { return }
        let expectedLanguages = projectLanguages
        let workspaceGeneration = generation
        let navigationGenerationAtRequest = navigationGeneration
        let source = documentSource
        semanticValidationTask?.cancel()
        semanticValidationTask = Task { [weak self] in
            let verified: Bool
            do {
                verified = try await detachedValue {
                    try Self.semanticDestinationMatches(
                        expectedContentID: expectedContentID,
                        byteOffset: byteOffset,
                        file: file,
                        source: source
                    )
                }
            } catch {
                verified = false
            }
            guard let self,
                  !Task.isCancelled,
                  self.canPublishWorkspaceResult(
                      generation: workspaceGeneration,
                      root: root,
                      languages: expectedLanguages
                  ),
                  self.navigationGeneration == navigationGenerationAtRequest
            else { return }
            if verified {
                self.commitNavigation(request, leaving: current)
            } else {
                self.markStaleIndexNavigation(to: file)
            }
        }
    }

    private func commitNavigation(
        _ request: NavigationRequest,
        leaving current: JumpRecord?
    ) {
        replayTask?.cancel()
        if request.cause != .historyReplay { replayNotice = nil }
        if request.destination.expectedContentID != nil { staleIndexNotice = nil }
        var currentTrailNodeID = readingTrail.activeNodeID
        if request.policy.recordInTrail,
           let destination = trailJump(for: request.destination)
        {
            _ = readingTrail.recordNavigation(
                from: current,
                to: destination,
                cause: request.cause,
                explanation: request.explanation
            )
            currentTrailNodeID = currentTrailNodeID
                ?? readingTrail.edges.last?.from
        }
        if let current {
            navigationHistory.push(NavigationRecord(
                jump: current,
                trailNodeID: currentTrailNodeID
            ))
        }
        activeNavigationRequest = request
        tabStrip.open(
            request.destination.file,
            inNewTab: false,
            selectionByteOffset: request.destination.byteOffset
        )
        selectFile(
            request.destination.file,
            byteOffset: request.destination.byteOffset
        )
    }

    private func markStaleIndexNavigation(to file: URL) {
        markStaleIndexContent()
    }

    package func markStaleIndexContent() {
        staleIndexNotice = "File changed since indexing"
    }

    /// Verifies that the bytes the Reader would load for `file` still match
    /// the indexed identity and that `byteOffset` resolves inside them.
    /// Snapshot-backed destinations read through `source`; worktree files
    /// read the current disk content.
    nonisolated package static func semanticDestinationMatches(
        expectedContentID: ContentID,
        byteOffset: UInt32,
        file: URL,
        source: DocumentLoader.ContentSource?
    ) throws -> Bool {
        let bytes: [UInt8]
        if let source {
            bytes = try source(file)
        } else {
            bytes = Array(try Data(contentsOf: file, options: .mappedIfSafe))
        }
        guard String(bytes: bytes, encoding: .utf8) != nil else { return false }
        guard ContentID.sha256(of: bytes) == expectedContentID else { return false }
        return ByteUTF16Map(validUTF8: bytes)
            .utf16Offset(forByte: Int(byteOffset)) != nil
    }

    /// Content identity the current index holds for a project-relative path,
    /// for producers of index-derived navigation positions. Dependency
    /// targets return nil; their identity comes from their own source.
    public func indexedContentID(forPath path: String) -> ContentID? {
        guard let root = projectRoot,
              !exactLocationIsInDependency(path)
        else { return nil }
        let file = root.appendingPathComponent(path).standardizedFileURL
        guard let relative = Self.relativePath(of: file, under: root) else {
            return nil
        }
        for (session, _) in querySessions {
            if let entry = session.manifest.files.first(where: {
                session.paths.resolve($0.pathID) == relative
            }) {
                return entry.contentID
            }
        }
        return nil
    }

    public func openInNewTab(
        _ url: URL,
        selectionByteOffset: UInt32? = nil
    ) {
        replayTask?.cancel()
        tabStrip.open(
            url,
            inNewTab: true,
            selectionByteOffset: selectionByteOffset
        )
        selectFile(url, byteOffset: selectionByteOffset)
    }

    package func openReadingSet(
        title: String,
        excerpts: [ReadingSetExcerpt],
        skippedReasons: [String] = []
    ) {
        replayTask?.cancel()
        tabStrip.openReadingSet(
            title: title,
            excerpts: excerpts,
            skippedReasons: skippedReasons
        )
        selectReadingSet()
    }

    package func capturedProjectSource(
        at path: String
    ) -> (contentID: ContentID, bytes: [UInt8])? {
        let language = LanguageMode.classify(
            path: path,
            languages: projectLanguages
        )?.language
        guard let language else { return nil }
        let session = workspaceSessions.values.first {
            $0.snapshotID == currentSnapshotID
                && $0.analysisProfile.language == language
        }
        guard let session else { return nil }
        return session.capturedSource(atManifestPath: path)
    }

    package func bookmarkEligibility() -> BookmarkEligibility {
        guard let root = projectRoot, tabStrip.activeTab != nil else {
            return .unavailable(.empty)
        }
        guard let file = tabStrip.activeTab?.fileURL else {
            return .unavailable(.readingSet)
        }
        guard compare.rightRevision == nil else {
            return .unavailable(.comparison)
        }
        guard selectedFile?.standardizedFileURL == file.standardizedFileURL,
              let document = tabStrip.activeDocument
        else { return .unavailable(.readerNotReady) }
        guard let path = Self.relativePath(of: file, under: root) else {
            return .unavailable(.dependency)
        }
        guard let byteOffset = selectedByteOffset ?? tabStrip.activeTab?.selectionByteOffset,
              document.byteUTF16Map.utf16Offset(forByte: Int(byteOffset)) != nil
        else {
            return .unavailable(.noSelection)
        }
        guard currentBookmarkAnchor() != nil,
              let captured = capturedProjectSource(at: path),
              captured.contentID == document.contentID
        else { return .unavailable(.capturedSourceMismatch) }
        return .eligible
    }

    package func captureCurrentBookmark() -> BookmarkRecord? {
        guard bookmarkEligibility() == .eligible,
              let root = projectRoot,
              let file = tabStrip.activeTab?.fileURL,
              let path = Self.relativePath(of: file, under: root),
              let document = tabStrip.activeDocument,
              let byteOffset = selectedByteOffset ?? tabStrip.activeTab?.selectionByteOffset,
              document.byteUTF16Map.utf16Offset(forByte: Int(byteOffset)) != nil,
              let line = document.lineTable.lineColumn(at: byteOffset)?.line,
              let anchor = currentBookmarkAnchor(),
              let captured = capturedProjectSource(at: path),
              captured.contentID == document.contentID
        else { return nil }
        bookmarkModel.clearAttempt()
        let facet = document.outlineFacets
            .filter { $0.range.contains(byteOffset) }
            .min { $0.range.length < $1.range.length }
        return BookmarkRecord(
            id: UUID(),
            projectPath: root.path,
            snapshot: anchor,
            path: path,
            contentID: document.contentID,
            byteOffset: byteOffset,
            line: line,
            symbolName: facet?.name,
            symbolKind: facet?.kind.rawValue,
            note: "",
            updatedAt: .now
        )
    }

    package func bookmarkStatus(for record: BookmarkRecord) -> BookmarkStatus {
        guard let anchor = currentBookmarkAnchor(), anchor == record.snapshot else {
            return .notEvaluated
        }
        return BookmarkStatus.evaluate(
            record: record,
            snapshot: anchor,
            revisionAvailable: true,
            capturedSource: capturedProjectSource(at: record.path)
        )
    }

    package func bookmarkMarkers(
        for file: URL,
        document: ReaderDocument
    ) -> [Int: [String]] {
        guard let root = projectRoot,
              let path = Self.relativePath(of: file, under: root),
              let anchor = currentBookmarkAnchor(),
              let captured = capturedProjectSource(at: path),
              captured.contentID == document.contentID
        else { return [:] }
        return bookmarkModel.records.reduce(into: [:]) { result, record in
            guard record.projectPath == root.path,
                  record.snapshot == anchor,
                  record.path == path,
                  record.contentID == document.contentID,
                  bookmarkStatus(for: record) == .exactContent
            else { return }
            result[Int(record.line), default: []].append(bookmarkModel.title(for: record))
        }
    }

    package func explicitBookmarkLineOpen(
        _ record: BookmarkRecord,
        line: UInt32
    ) -> (file: URL, byteOffset: UInt32, line: UInt32)? {
        guard let captured = capturedBookmarkDocument(for: record) else { return nil }
        guard let target = bookmarkModel.lineTarget(
            in: captured.document,
            requestedLine: line
        ) else { return nil }
        return (captured.file, target.byteOffset, target.line)
    }

    package func reanchorBookmark(
        id: UUID,
        line: UInt32,
        updatedAt: Date = .now
    ) -> BookmarkReanchorResult {
        guard let record = bookmarkModel.records.first(where: { $0.id == id }),
              let captured = capturedBookmarkDocument(for: record)
        else { return .unsupportedSnapshot }
        return bookmarkModel.reanchorWorktree(
            id: id,
            document: captured.document,
            line: line,
            updatedAt: updatedAt
        )
    }

    private func capturedBookmarkDocument(
        for record: BookmarkRecord
    ) -> (file: URL, document: ReaderDocument)? {
        guard let root = projectRoot,
              record.projectPath == root.path,
              record.snapshot == .worktree,
              currentBookmarkAnchor() == .worktree,
              let file = safeProjectFile(record.path, under: root),
              let languageMode = languageMode(for: file),
              let captured = capturedProjectSource(at: record.path),
              let loaded = try? DocumentLoader(source: { _ in captured.bytes })
                .load(file: file, languageMode: languageMode),
              loaded.document.contentID == captured.contentID
        else { return nil }
        return (file, loaded.document)
    }

    package func openStrictBookmark(
        _ record: BookmarkRecord,
        leaving original: JumpRecord
    ) {
        guard let root = projectRoot,
              root.path == record.projectPath,
              let anchor = currentBookmarkAnchor()
        else {
            bookmarkModel.beginAttempt(
                for: record,
                workspaceGeneration: generation,
                message: "Bookmark belongs to a different project or snapshot."
            )
            return
        }
        guard anchor == record.snapshot else {
            openStrictBookmarkAcrossSnapshots(
                record,
                root: root,
                leaving: original
            )
            return
        }
        let status = bookmarkStatus(for: record)
        guard status == .exactContent else {
            if let message = status.attemptMessage {
                bookmarkModel.beginAttempt(
                    for: record,
                    workspaceGeneration: generation,
                    message: message
                )
            }
            return
        }
        guard let source = capturedDocumentSource(for: root),
              let file = safeProjectFile(record.path, under: root)
        else {
            bookmarkModel.beginAttempt(
                for: record,
                workspaceGeneration: generation,
                message: "Bookmark captured source is unavailable."
            )
            return
        }
        do {
            let bytes = try source(file)
            guard ContentID.sha256(of: Data(bytes)) == record.contentID else {
                bookmarkModel.beginAttempt(
                    for: record,
                    workspaceGeneration: generation,
                    message: "Bookmark captured source does not match its content."
                )
                return
            }
        } catch {
            bookmarkModel.beginAttempt(
                for: record,
                workspaceGeneration: generation,
                message: "Bookmark file is absent."
            )
            return
        }
        documentSource = source
        publishProjectState(projectState, root: root)
        navigate(to: file, byteOffset: record.byteOffset, leaving: original)
        bookmarkModel.clearAttempt()
    }

    private func openStrictBookmarkAcrossSnapshots(
        _ record: BookmarkRecord,
        root: URL,
        leaving original: JumpRecord
    ) {
        let workspaceGeneration = generation
        let languages = projectLanguages
        guard !languages.isEmpty else {
            bookmarkModel.beginAttempt(
                for: record,
                workspaceGeneration: workspaceGeneration,
                message: "Bookmark snapshot capture failed."
            )
            return
        }
        let revision: String? = switch record.snapshot {
        case .worktree: nil
        case let .commit(fullOID): fullOID
        }
        let indexService = indexService
        bookmarkModel.beginStrictJump(
            for: record,
            workspaceGeneration: workspaceGeneration
        ) { [weak self, indexService] attemptGeneration in
            guard let self,
                  self.canPublishWorkspaceResult(
                      generation: workspaceGeneration,
                      root: root,
                      languages: languages
                  ),
                  self.bookmarkModel.isCurrentJump(
                      attemptGeneration,
                      workspaceGeneration: workspaceGeneration
                  )
            else { return nil }

            let snapshot: any Snapshot
            do {
                snapshot = try await indexService.captureSnapshot(
                    root: root,
                    revision: revision,
                    languages: languages
                )
            } catch is CancellationError {
                return nil
            } catch {
                return switch record.snapshot {
                case .worktree: "Bookmark snapshot capture failed."
                case .commit: BookmarkStatus.revisionUnavailable.attemptMessage
                }
            }
            guard self.canPublishWorkspaceResult(
                      generation: workspaceGeneration,
                      root: root,
                      languages: languages
                  ),
                  self.bookmarkModel.isCurrentJump(
                      attemptGeneration,
                      workspaceGeneration: workspaceGeneration
                  )
            else { return nil }
            if case let .commit(fullOID) = record.snapshot {
                guard let commit = snapshot as? CommitSnapshot,
                      commit.commitOID.hex == fullOID
                else { return "Bookmark snapshot capture failed." }
            }
            let files = snapshot.listFiles().filter {
                switch $0.fileMode {
                case .symlink, .gitlink:
                    false
                case .regular, .lfsPointer:
                    true
                }
            }
            guard let entry = files.first(where: { $0.path == record.path }) else {
                return BookmarkStatus.fileAbsent.attemptMessage
            }
            guard entry.contentID == record.contentID else {
                return switch record.snapshot {
                case .worktree: BookmarkStatus.drifted.attemptMessage
                case .commit: BookmarkStatus.fileAbsent.attemptMessage
                }
            }
            let bytes: [UInt8]
            do {
                bytes = try snapshot.readBytes(path: record.path)
            } catch {
                return BookmarkStatus.fileAbsent.attemptMessage
            }
            guard ContentID.sha256(of: bytes) == record.contentID else {
                return switch record.snapshot {
                case .worktree: BookmarkStatus.drifted.attemptMessage
                case .commit: BookmarkStatus.fileAbsent.attemptMessage
                }
            }
            guard ByteUTF16Map(validUTF8: bytes).utf16Offset(
                forByte: Int(record.byteOffset)
            ) != nil else {
                return BookmarkStatus.offsetInvalid.attemptMessage
            }

            let prepared: [ProjectIndexer.PreparedSnapshot]
            do {
                prepared = try await indexService.prepareSnapshots(
                    snapshot,
                    root: root,
                    languages: languages
                )
            } catch is CancellationError {
                return nil
            } catch {
                return "Bookmark snapshot preparation failed."
            }
            guard self.canPublishWorkspaceResult(
                      generation: workspaceGeneration,
                      root: root,
                      languages: languages
                  ),
                  self.bookmarkModel.isCurrentJump(
                      attemptGeneration,
                      workspaceGeneration: workspaceGeneration
                  ),
                  let cached = self.validatedWorkspaceSessions(
                      prepared.map(\.cachedSession),
                      languages: languages,
                      snapshotID: snapshot.snapshotID
                  )
            else { return "Bookmark snapshot install failed." }
            let active = cached.values
                .first(where: { Self.sessionCoverage(for: $0).filesTotal > 0 })
                ?? cached.values.first!

            self.generation &+= 1
            let installedGeneration = self.generation
            guard self.bookmarkModel.advanceWorkspace(
                to: installedGeneration,
                attemptGeneration: attemptGeneration
            ) else { return nil }
            self.snapshotTask?.cancel()
            self.compareSnapshotTask?.cancel()
            self.replayTask?.cancel()
            self.snapshotTask = nil
            self.compareSnapshotTask = nil
            self.replayTask = nil
            self.exactCoordinator.invalidate(generation: installedGeneration)
            self.compare.clear()
            self.commitPicker.setCurrentRevision(revision)
            self.fileTree = FileTreeModel(
                root: root,
                snapshotPaths: files.map(\.path),
                languages: languages
            )
            self.currentSnapshotID = snapshot.snapshotID
            self.snapshotDestinations[snapshot.snapshotID] = switch record.snapshot {
            case .worktree: .worktree
            case let .commit(fullOID): .commit(revision: fullOID, fullOID: fullOID)
            }
            self.documentSource = { file in
                guard let path = Self.relativePath(of: file, under: root),
                      files.contains(where: { $0.path == path })
                else { throw CocoaError(.fileReadNoSuchFile) }
                return try snapshot.readBytes(path: path)
            }
            self.workspaceSessions = cached
            self.snapshotPhase = .cachedReady
            self.coverage = self.workspaceCoverage()
            self.publishProjectState(.ready(
                active,
                QueryContext(
                    snapshotID: snapshot.snapshotID,
                    analysisProfileID: active.analysisProfile.id,
                    generation: installedGeneration
                )
            ), root: root)
            self.navigate(
                to: root.appendingPathComponent(record.path),
                byteOffset: record.byteOffset,
                leaving: original
            )
            self.snapshotTask = Task { [weak self, indexService] in
                var completed: [EngineSession] = []
                do {
                    for item in prepared {
                        completed.append(try await indexService.completeSnapshot(item))
                        guard let self,
                              self.canPublishWorkspaceResult(
                                  generation: installedGeneration,
                                  root: root,
                                  languages: languages
                              )
                        else { return }
                    }
                } catch {
                    return
                }
                guard let self,
                      self.canPublishWorkspaceResult(
                          generation: installedGeneration,
                          root: root,
                          languages: languages
                      ),
                      self.installWorkspaceSessions(
                          completed,
                          generation: installedGeneration,
                          root: root,
                          languages: languages,
                          expectedSnapshotID: snapshot.snapshotID,
                          phase: .fullReady
                      )
                else { return }
                self.lastInstalledRevision = revision
                self.lastInstalledProjectRoot = root
                self.lastInstalledGeneration = installedGeneration
                self.prepareExact(generation: installedGeneration)
            }
            return nil
        }
    }

    package func preflightBookmark(_ record: BookmarkRecord) {
        let workspaceGeneration = generation
        guard let root = projectRoot, !projectLanguages.isEmpty else {
            bookmarkModel.beginAttempt(for: record, workspaceGeneration: workspaceGeneration) {
                .revisionUnavailable
            }
            return
        }
        let indexService = indexService
        let languages = projectLanguages
        bookmarkModel.beginAttempt(for: record, workspaceGeneration: workspaceGeneration) {
            guard case let .commit(fullOID) = record.snapshot else {
                return .notEvaluated
            }
            do {
                let snapshot = try await indexService.captureSnapshot(
                    root: root,
                    revision: fullOID,
                    languages: languages
                )
                guard let file = snapshot.listFiles().first(where: {
                    $0.path == record.path
                }) else {
                    return BookmarkStatus.evaluate(
                        record: record,
                        snapshot: record.snapshot,
                        revisionAvailable: true,
                        capturedSource: nil
                    )
                }
                let bytes = try snapshot.readBytes(path: record.path)
                return BookmarkStatus.evaluate(
                    record: record,
                    snapshot: record.snapshot,
                    revisionAvailable: true,
                    capturedSource: (file.contentID, bytes)
                )
            } catch {
                return .revisionUnavailable
            }
        }
    }

    package func readingSetSources(
        for excerpts: [ReadingSetExcerpt]
    ) -> [[UInt8]?] {
        var commitSnapshots: [String: CommitSnapshot] = [:]
        return excerpts.map { excerpt in
            let bytes: [UInt8]?
            switch excerpt.sourceKind {
            case .projectCommit:
                guard let root = projectRoot,
                      let revision = excerpt.revision
                else { return nil }
                if currentRevision == revision,
                   let captured = capturedProjectSource(at: excerpt.path)
                {
                    bytes = captured.bytes
                    break
                }
                let snapshot: CommitSnapshot
                if let cached = commitSnapshots[revision] {
                    snapshot = cached
                } else {
                    guard let loaded = try? CommitSnapshot(
                        repositoryURL: root,
                        revision: revision
                    ) else { return nil }
                    commitSnapshots[revision] = loaded
                    snapshot = loaded
                }
                bytes = try? snapshot.readBytes(path: excerpt.path)
            case .worktreeCaptured:
                guard currentRevision == nil else { return nil }
                bytes = capturedProjectSource(at: excerpt.path)?.bytes
            case .dependencyCaptured:
                guard exactLocationIsInDependency(excerpt.path),
                      let data = try? Data(
                          contentsOf: URL(fileURLWithPath: excerpt.path),
                          options: .mappedIfSafe
                      )
                else { return nil }
                bytes = Array(data)
            }
            guard let bytes,
                  ContentID.sha256(of: bytes) == excerpt.contentID
            else { return nil }
            return bytes
        }
    }

    package func trailReadingSet(
        to selectedNodeID: TrailNodeID
    ) -> (
        title: String,
        excerpts: [ReadingSetExcerpt],
        skippedReasons: [String]
    ) {
        guard let selectedNode = readingTrail.nodes[selectedNodeID] else {
            return ("Trail", [], ["selected node is unavailable"])
        }
        var cursor = selectedNodeID
        var edges: [TrailEdge] = []
        var visited: Set<TrailNodeID> = [cursor]
        while let edge = readingTrail.edges.last(where: { $0.to == cursor }),
              visited.insert(edge.from).inserted
        {
            edges.append(edge)
            cursor = edge.from
        }
        edges.reverse()

        var commitSnapshots: [String: CommitSnapshot] = [:]
        var excerpts: [ReadingSetExcerpt] = []
        var skippedReasons: [String] = []
        for edge in edges {
            guard let inspector = edge.frozenInspectorDisplay else {
                skippedReasons.append("no frozen evidence")
                continue
            }
            guard let node = readingTrail.nodes[edge.to],
                  let contentID = node.jump.contentID
            else {
                skippedReasons.append("missing content identity")
                continue
            }
            let jump = node.jump
            let sourceKind: ReadingSetExcerpt.SourceKind
            let bytes: [UInt8]?
            if exactLocationIsInDependency(jump.path) {
                sourceKind = .dependencyCaptured
                guard languageMode(for: URL(fileURLWithPath: jump.path)) != nil else {
                    skippedReasons.append("recorded source language is unsupported")
                    continue
                }
                bytes = (try? Data(
                    contentsOf: URL(fileURLWithPath: jump.path),
                    options: .mappedIfSafe
                )).map(Array.init)
            } else if let revision = jump.revision {
                sourceKind = .projectCommit
                guard let root = projectRoot,
                      !jump.path.hasPrefix("/"),
                      !jump.path.split(separator: "/").contains("..")
                else {
                    skippedReasons.append("recorded project path is invalid")
                    continue
                }
                let snapshot: CommitSnapshot
                if let cached = commitSnapshots[revision] {
                    snapshot = cached
                } else if let loaded = try? CommitSnapshot(
                    repositoryURL: root,
                    revision: revision
                ) {
                    commitSnapshots[revision] = loaded
                    snapshot = loaded
                } else {
                    skippedReasons.append("recorded revision is unavailable")
                    continue
                }
                bytes = try? snapshot.readBytes(path: jump.path)
            } else {
                sourceKind = .worktreeCaptured
                guard currentRevision == nil,
                      jump.snapshotID == currentSnapshotID
                else {
                    skippedReasons.append("recorded worktree snapshot is unavailable")
                    continue
                }
                bytes = capturedProjectSource(at: jump.path)?.bytes
            }
            guard let bytes else {
                skippedReasons.append("recorded source is unreadable")
                continue
            }
            guard ContentID.sha256(of: bytes) == contentID else {
                skippedReasons.append("recorded source content changed")
                continue
            }
            guard let root = projectRoot else {
                skippedReasons.append("project language is unavailable")
                continue
            }
            let file = exactLocationIsInDependency(jump.path)
                ? URL(fileURLWithPath: jump.path)
                : root.appendingPathComponent(jump.path)
            guard let languageMode = languageMode(for: file) else {
                skippedReasons.append("recorded source language is unsupported")
                continue
            }
            guard let excerpt = makeReadingSetExcerpt(
                role: edge.readingSetRole ?? "TRAIL TARGET",
                symbol: jump.symbolAnchor ?? inspector.nodeTitle,
                path: jump.path,
                targetByte: jump.byteOffset,
                languageMode: languageMode,
                bytes: bytes,
                contentID: contentID,
                revision: jump.revision,
                sourceKind: sourceKind,
                inspector: inspector
            ) else {
                skippedReasons.append("recorded excerpt could not be frozen")
                continue
            }
            excerpts.append(excerpt)
        }
        let title = selectedNode.jump.symbolAnchor
            ?? URL(fileURLWithPath: selectedNode.jump.path).lastPathComponent
        return (title, excerpts, skippedReasons)
    }

    package func openReadingSetExcerpt(_ excerpt: ReadingSetExcerpt) {
        guard excerpt.sourceKind != .dependencyCaptured,
              let bytes = readingSetSources(for: [excerpt]).first ?? nil,
              let offset = LineTable(bytes: bytes).byteOffset(
                  line: excerpt.line,
                  column: excerpt.column
              ),
              let root = projectRoot
        else { return }
        let file = root.appendingPathComponent(excerpt.path).standardizedFileURL
        guard file.pathComponents.starts(with: root.pathComponents),
              file.pathComponents.count > root.pathComponents.count
        else { return }
        switch excerpt.sourceKind {
        case .worktreeCaptured:
            guard currentRevision == nil else { return }
            openInNewTab(file, selectionByteOffset: offset)
        case .projectCommit:
            guard let revision = excerpt.revision else { return }
            if currentRevision == revision {
                openInNewTab(file, selectionByteOffset: offset)
                return
            }
            pendingReplay = (
                NavigationRecord(jump: JumpRecord(
                    path: excerpt.path,
                    contentID: excerpt.contentID,
                    byteOffset: offset,
                    line: excerpt.line,
                    column: excerpt.column,
                    symbolAnchor: excerpt.symbol,
                    snapshotID: nil,
                    revision: revision
                )),
                false,
                true
            )
            switchSnapshot(revision: revision)
        case .dependencyCaptured:
            break
        }
    }

    public func activateTab(_ index: Int) {
        guard tabStrip.tabs.indices.contains(index) else { return }
        tabStrip.activate(index)
        guard let tab = tabStrip.activeTab else { return }
        guard let file = tab.fileURL else {
            selectReadingSet()
            return
        }
        activeNavigationRequest = NavigationRequest(
            destination: SourceDestination(
                file: file,
                byteOffset: tab.selectionByteOffset
            ),
            cause: .tabActivation,
            policy: .passive
        )
        selectFile(file, byteOffset: tab.selectionByteOffset)
    }

    public func selectRelativeTab(_ delta: Int) {
        guard tabStrip.tabs.count > 1 else { return }
        tabStrip.selectRelative(delta)
        guard let tab = tabStrip.activeTab else { return }
        guard let file = tab.fileURL else {
            selectReadingSet()
            return
        }
        activeNavigationRequest = NavigationRequest(
            destination: SourceDestination(
                file: file,
                byteOffset: tab.selectionByteOffset
            ),
            cause: .tabActivation,
            policy: .passive
        )
        selectFile(file, byteOffset: tab.selectionByteOffset)
    }

    public func closeTab(_ index: Int) {
        let closesActive = tabStrip.activeIndex == index
        _ = tabStrip.close(index)
        guard closesActive else { return }
        if let tab = tabStrip.activeTab, let file = tab.fileURL {
            selectFile(file, byteOffset: tab.selectionByteOffset)
        } else if tabStrip.activeTab != nil {
            selectReadingSet()
        } else {
            selectedFile = nil
            selectedByteOffset = nil
            navigationGeneration &+= 1
            updateCompareFile()
        }
    }

    public func goBack(from current: JumpRecord) {
        guard let record = navigationHistory.goBack(from: NavigationRecord(
            jump: current,
            trailNodeID: readingTrail.activeNodeID
        )) else { return }
        replay(record)
    }

    public func goForward() {
        guard let record = navigationHistory.goForwardRecord() else { return }
        replay(record)
    }

    public func restoreTrailNode(_ id: TrailNodeID) {
        guard let node = readingTrail.nodes[id] else { return }
        replay(NavigationRecord(jump: node.jump, trailNodeID: id))
    }

    public func navigationExplanation(
        for node: RelationTreeModel.Node
    ) -> NavigationExplanation? {
        navigationExplanation(
            for: node,
            frozenInspectorDisplay: nil,
            readingSetRole: ""
        )
    }

    package func navigationExplanation(
        for node: RelationTreeModel.Node,
        frozenInspectorDisplay: ReadingSetExcerpt.FrozenInspectorDisplay?,
        readingSetRole: String
    ) -> NavigationExplanation? {
        guard let materialized = relationTree.materializedExplanation(for: node)
        else { return nil }
        let id: ResolutionExplanationID
        if let existing = node.explanationID {
            resolutionExplanations.update(existing, to: materialized)
            id = existing
        } else {
            id = resolutionExplanations.create(materialized)
            node.explanationID = id
        }
        let observed = ResolutionExplanationSnapshot(explanation: materialized)
        if let frozenInspectorDisplay {
            return NavigationExplanation(
                explanationID: id,
                observedAtNavigation: observed,
                frozenInspectorDisplay: frozenInspectorDisplay,
                readingSetRole: readingSetRole
            )
        }
        return NavigationExplanation(
            explanationID: id,
            observedAtNavigation: observed
        )
    }

    @discardableResult
    public func transition(to next: ProjectState) -> Bool {
        switch (projectState, next) {
        case (.empty, .indexing),
             (.ready, .indexing),
             (.failed, .indexing),
             (.indexing, .ready),
             (.indexing, .failed),
             (.ready, .failed),
             (.ready, .ready):
            projectState = next
            let root = if case let .indexing(root, _) = next {
                root
            } else {
                fileTree?.root
            }
            contextWindow.updateProjectState(
                next,
                root: root,
                contentSource: documentSource
            )
            relationTree.updateProjectState(next)
            return true
        case let (.indexing(currentRoot, _), .indexing(nextRoot, _))
            where currentRoot.standardizedFileURL != nextRoot.standardizedFileURL:
            projectState = next
            contextWindow.updateProjectState(
                next,
                root: nextRoot,
                contentSource: documentSource
            )
            relationTree.updateProjectState(next)
            return true
        default:
            return false
        }
    }

    private func finishIndexing(
        _ session: EngineSession,
        generation: UInt64,
        root: URL,
        language: LanguageID
    ) {
        guard canPublishProjectResult(
            generation: generation,
            root: root,
            language: language
        ) else { return }
        guard session.analysisProfile.language == language else {
            failIndexing(
                generation: generation,
                root: root,
                language: language
            )
            return
        }
        workspaceSessions = [session.analysisProfile.id: session]
        currentSnapshotID = session.snapshotID
        snapshotDestinations[session.snapshotID] = .worktree
        snapshotPhase = .fullReady
        coverage = Self.sessionCoverage(for: session)
        guard transition(to: .ready(
            session,
            QueryContext(
                snapshotID: session.snapshotID,
                analysisProfileID: session.analysisProfile.id,
                generation: generation
            )
        )) else {
            assertionFailure("Illegal project state transition to ready")
            return
        }
        lastInstalledRevision = nil
        lastInstalledProjectRoot = projectRoot
        lastInstalledGeneration = generation
        prepareExact(generation: generation)
    }

    private func failIndexing(
        generation: UInt64,
        root: URL,
        language: LanguageID
    ) {
        guard canPublishProjectResult(
            generation: generation,
            root: root,
            language: language
        ) else { return }
        workspaceSessions.removeAll(keepingCapacity: true)
        pendingReplay = nil
        guard transition(to: .failed) else {
            assertionFailure("Illegal project state transition to failed")
            return
        }
    }

    private func switchSnapshot(revision: String?) {
        guard let root = projectRoot,
              !projectLanguages.isEmpty
        else { return }
        snapshotTask?.cancel()
        compareSnapshotTask?.cancel()
        replayTask?.cancel()
        endIndexRefresh()
        compare.clear()
        generation &+= 1
        let switchGeneration = generation
        bookmarkModel.workspaceDidChange(to: switchGeneration)
        exactCoordinator.invalidate(generation: switchGeneration)
        commitPicker.setCurrentRevision(revision)
        workspaceSessions.removeAll(keepingCapacity: true)
        snapshotPhase = nil
        coverage = SnapshotCoverage(filesIndexed: 0, filesTotal: 0)
        publishProjectState(.indexing(root: root, startedAt: .now), root: root)

        snapshotTask = snapshotLoadTask(
            revision: revision,
            generation: switchGeneration,
            root: root,
            languages: projectLanguages
        ) { [weak self] generation, root, languages in
            self?.failWorkspace(
                generation: generation,
                root: root,
                languages: languages
            )
        }
    }

    /// The staged capture/prepare/complete publication chain shared by
    /// destination switches and index refreshes.
    private func snapshotLoadTask(
        revision: String?,
        generation: UInt64,
        root: URL,
        languages: [LanguageID],
        onFailure: @escaping @MainActor (UInt64, URL, [LanguageID]) -> Void,
        onSuccess: (@MainActor () -> Void)? = nil
    ) -> Task<Void, Never> {
        Task { [weak self, indexService] in
            do {
                let snapshot = try await indexService.captureSnapshot(
                    root: root,
                    revision: revision,
                    languages: languages
                )
                try Task.checkCancellation()
                guard let self,
                      self.canPublishWorkspaceResult(
                          generation: generation,
                          root: root,
                          languages: languages
                      )
                else { return }
                self.publishFirstPaint(
                    snapshot,
                    root: root,
                    revision: revision,
                    generation: generation,
                    languages: languages
                )
                await Task.yield()
                guard self.canPublishWorkspaceResult(
                    generation: generation,
                    root: root,
                    languages: languages
                ) else { return }

                let prepared = try await indexService.prepareSnapshots(
                    snapshot,
                    root: root,
                    languages: languages
                )
                try Task.checkCancellation()
                guard self.canPublishWorkspaceResult(
                    generation: generation,
                    root: root,
                    languages: languages
                ) else { return }
                guard self.installWorkspaceSessions(
                    prepared.map(\.cachedSession),
                    generation: generation,
                    root: root,
                    languages: languages,
                    expectedSnapshotID: snapshot.snapshotID,
                    phase: .cachedReady
                ) else {
                    onFailure(generation, root, languages)
                    return
                }
                await Task.yield()
                guard self.canPublishWorkspaceResult(
                    generation: generation,
                    root: root,
                    languages: languages
                ) else { return }

                var completed: [EngineSession] = []
                for item in prepared {
                    let session = try await indexService.completeSnapshot(item)
                    completed.append(session)
                    try Task.checkCancellation()
                    guard self.canPublishWorkspaceResult(
                        generation: generation,
                        root: root,
                        languages: languages
                    ) else { return }
                }
                guard self.installWorkspaceSessions(
                    completed,
                    generation: generation,
                    root: root,
                    languages: languages,
                    expectedSnapshotID: snapshot.snapshotID,
                    phase: .fullReady
                ) else {
                    onFailure(generation, root, languages)
                    return
                }
                self.lastInstalledRevision = self.currentRevision
                self.lastInstalledProjectRoot = self.projectRoot
                self.lastInstalledGeneration = self.generation
                self.prepareExact(generation: self.generation)
                onSuccess?()
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      self.canPublishWorkspaceResult(
                          generation: generation,
                          root: root,
                          languages: languages
                      )
                else { return }
                onFailure(generation, root, languages)
            }
        }
    }

    private func publishFirstPaint(
        _ snapshot: any Snapshot,
        root: URL,
        revision: String?,
        generation: UInt64,
        languages: [LanguageID]
    ) {
        guard canPublishWorkspaceResult(
            generation: generation,
            root: root,
            languages: languages
        ) else { return }
        let files = snapshot.listFiles().filter {
            switch $0.fileMode {
            case .symlink, .gitlink:
                false
            case .regular, .lfsPointer:
                true
            }
        }
        let paths = files.map(\.path)
        let selectedPath = selectedFile.flatMap {
            Self.relativePath(of: $0, under: root)
        }
        fileTree = FileTreeModel(
            root: root,
            snapshotPaths: paths,
            languages: languages
        )
        if let selectedPath, paths.contains(selectedPath) {
            selectedFile = root.appendingPathComponent(selectedPath)
        } else if selectedFile != nil {
            selectedFile = nil
            selectedByteOffset = nil
        }
        currentSnapshotID = snapshot.snapshotID
        snapshotDestinations[snapshot.snapshotID] = if let revision {
            .commit(
                revision: revision,
                fullOID: (snapshot as? CommitSnapshot)?.commitOID.hex
            )
        } else {
            .worktree
        }
        documentSource = if revision == nil {
            nil
        } else {
            { file in
                guard let path = Self.relativePath(of: file, under: root) else {
                    throw CocoaError(.fileReadNoSuchFile)
                }
                guard paths.contains(path) else {
                    throw CocoaError(.fileReadNoSuchFile)
                }
                return try snapshot.readBytes(path: path)
            }
        }
        snapshotPhase = .firstPaint
        coverage = SnapshotCoverage(
            filesIndexed: 0,
            filesTotal: paths.filter {
                LanguageMode.classify(path: $0, languages: languages) != nil
            }.count
        )
        navigationGeneration &+= 1
        staleIndexNotice = nil
        if let pending = pendingReplay {
            pendingReplay = nil
            replayWithinCurrentSnapshot(
                pending.record,
                replayedAgainstCurrentWorktree:
                    pending.replayedAgainstCurrentWorktree
                        && pending.record.jump.snapshotID != currentSnapshotID,
                opensInNewTab: pending.opensInNewTab
            )
        }
    }

    private func canPublishProjectResult(
        generation expectedGeneration: UInt64,
        root expectedRoot: URL,
        language expectedLanguage: LanguageID
    ) -> Bool {
        canPublishWorkspaceResult(
            generation: expectedGeneration,
            root: expectedRoot,
            languages: [expectedLanguage]
        )
    }

    private func canPublishWorkspaceResult(
        generation expectedGeneration: UInt64,
        root expectedRoot: URL,
        languages expectedLanguages: [LanguageID]
    ) -> Bool {
        !Task.isCancelled
            && generation == expectedGeneration
            && projectRoot?.standardizedFileURL == expectedRoot.standardizedFileURL
            && projectLanguages == expectedLanguages
    }

    private func prepareExact(generation: UInt64) {
        guard let projectRoot,
              case let .ready(session, _) = projectState,
              canPublishWorkspaceResult(
                  generation: generation,
                  root: projectRoot,
                  languages: projectLanguages
              )
        else { return }
        do {
            try exactCoordinator.prepare(
                projectURL: projectRoot,
                revision: currentRevision,
                analysisProfile: session.analysisProfile,
                profileRoot: session.paths.resolve(
                    session.analysisProfile.projectRoot
                ),
                generation: generation
            )
        } catch {
            assertionFailure("Exact preflight failed for an installed profile: \(error)")
        }
    }

    private func updateCompareFile() {
        compare.update(
            file: selectedFile,
            leftSource: documentSource,
            languageMode: selectedFile.flatMap(languageMode(for:))
        )
    }

    private func currentBookmarkAnchor() -> BookmarkRecord.SnapshotAnchor? {
        guard let snapshotID = currentSnapshotID,
              let destination = snapshotDestinations[snapshotID]
        else { return nil }
        switch destination {
        case .worktree: return .worktree
        case let .commit(_, fullOID?): return .commit(fullOID: fullOID)
        case .commit: return nil
        }
    }

    private func capturedDocumentSource(
        for root: URL
    ) -> DocumentLoader.ContentSource? {
        let sessions = workspaceSessions.values.filter {
            $0.snapshotID == currentSnapshotID
        }
        guard !sessions.isEmpty else { return nil }
        return { file in
            guard let path = Self.relativePath(of: file, under: root),
                  let bytes = sessions.lazy.compactMap({
                      $0.capturedSource(atManifestPath: path)?.bytes
                  }).first
            else { throw CocoaError(.fileReadNoSuchFile) }
            return bytes
        }
    }

    private func safeProjectFile(_ path: String, under root: URL) -> URL? {
        let file = root.appendingPathComponent(path).standardizedFileURL
        guard file.pathComponents.starts(with: root.pathComponents),
              file.pathComponents.count > root.pathComponents.count
        else { return nil }
        return file
    }

    private func selectFile(_ file: URL, byteOffset: UInt32?) {
        let file = file.standardizedFileURL
        selectedFile = file
        selectedByteOffset = byteOffset
        navigationGeneration &+= 1
        navigationSink(file, byteOffset)
        if let active = routedSession(for: file),
           case let .ready(_, context) = projectState,
           context.analysisProfileID != active.1.analysisProfileID,
           let root = projectRoot
        {
            publishProjectState(.ready(active.0, active.1), root: root)
            prepareExact(generation: active.1.generation)
        }
        updateCompareFile()
    }

    private func selectReadingSet() {
        activeNavigationRequest = nil
        selectedFile = nil
        selectedByteOffset = nil
        navigationGeneration &+= 1
        updateCompareFile()
    }

    private func publishProjectState(_ state: ProjectState, root: URL?) {
        projectState = state
        contextWindow.updateProjectState(
            state,
            root: root,
            contentSource: documentSource
        )
        relationTree.updateProjectState(state)
    }

    private static func sessionCoverage(for session: EngineSession) -> SnapshotCoverage {
        let language = session.analysisProfile.language
        let activeFiles = session.manifest.files.filter {
            LanguageMode.classify(
                path: session.paths.resolve($0.pathID),
                language: language
            ) != nil
        }
        return SnapshotCoverage(
            filesIndexed: activeFiles.filter {
                session.content(at: $0.pathID) != nil
            }.count,
            filesTotal: activeFiles.count
        )
    }

    private func querySessionTuples() -> [(EngineSession, QueryContext)] {
        let languages = projectLanguages
        guard !languages.isEmpty,
              workspaceSessions.count == languages.count
        else { return [] }
        var result: [(EngineSession, QueryContext)] = []
        result.reserveCapacity(languages.count)
        var snapshotID: SnapshotID?
        for language in languages {
            let matches = workspaceSessions.values.filter {
                $0.analysisProfile.language == language
            }
            guard matches.count == 1, let session = matches.first else { return [] }
            if let snapshotID, snapshotID != session.snapshotID { return [] }
            snapshotID = session.snapshotID
            result.append((
                session,
                QueryContext(
                    snapshotID: session.snapshotID,
                    analysisProfileID: session.analysisProfile.id,
                    generation: generation
                )
            ))
        }
        guard Set(result.map(\.0.snapshotID)).count == 1 else { return [] }
        return result
    }

    private func installWorkspaceSessions(
        _ candidates: [EngineSession],
        generation expectedGeneration: UInt64,
        root expectedRoot: URL,
        languages expectedLanguages: [LanguageID],
        expectedSnapshotID: SnapshotID,
        phase: SnapshotPhase
    ) -> Bool {
        guard canPublishWorkspaceResult(
            generation: expectedGeneration,
            root: expectedRoot,
            languages: expectedLanguages
        ) else { return false }
        guard let byProfile = validatedWorkspaceSessions(
            candidates,
            languages: expectedLanguages,
            snapshotID: expectedSnapshotID
        ) else { return false }
        workspaceSessions = byProfile
        snapshotPhase = phase
        coverage = workspaceCoverage()
        if let active = selectedFile.flatMap(routedSession(for:)) {
            publishProjectState(.ready(active.0, active.1), root: expectedRoot)
        } else {
            let tuples = querySessionTuples()
            let active = tuples.first(where: {
                Self.sessionCoverage(for: $0.0).filesTotal > 0
            }) ?? tuples.first
            guard let active else { return false }
            publishProjectState(.ready(active.0, active.1), root: expectedRoot)
        }
        return true
    }

    private func validatedWorkspaceSessions(
        _ candidates: [EngineSession],
        languages: [LanguageID],
        snapshotID: SnapshotID
    ) -> [AnalysisProfileID: EngineSession]? {
        var byProfile: [AnalysisProfileID: EngineSession] = [:]
        for session in candidates { byProfile[session.analysisProfile.id] = session }
        guard byProfile.count == languages.count,
              byProfile.values.allSatisfy({ $0.snapshotID == snapshotID }),
              Set(byProfile.keys) == Set(byProfile.values.map { $0.analysisProfile.id }),
              Set(byProfile.values.map { $0.snapshotID }).count == 1,
              Set(byProfile.values.map { $0.analysisProfile.language }) == Set(languages),
              Set(byProfile.values.map { ObjectIdentifier($0.paths) }).count == 1
        else { return nil }
        return byProfile
    }

    private func workspaceCoverage() -> SnapshotCoverage {
        let sessions = workspaceSessions.values
        let indexed = sessions.reduce(0) { $0 + Self.sessionCoverage(for: $1).filesIndexed }
        let total = sessions.reduce(0) { $0 + Self.sessionCoverage(for: $1).filesTotal }
        return SnapshotCoverage(filesIndexed: indexed, filesTotal: total)
    }

    private func routedSession(for file: URL) -> (EngineSession, QueryContext)? {
        guard let mode = languageMode(for: file),
              let session = workspaceSessions.values.first(where: {
                  $0.analysisProfile.language == mode.language
              })
        else { return nil }
        return (
            session,
            QueryContext(
                snapshotID: session.snapshotID,
                analysisProfileID: session.analysisProfile.id,
                generation: generation
            )
        )
    }

    nonisolated private static func relativePath(
        of file: URL,
        under root: URL
    ) -> String? {
        let root = root.standardizedFileURL
        let file = file.standardizedFileURL
        guard file.pathComponents.starts(with: root.pathComponents),
              file.pathComponents.count > root.pathComponents.count
        else { return nil }
        return file.pathComponents.dropFirst(root.pathComponents.count)
            .joined(separator: "/")
    }

    package func languageMode(for file: URL) -> LanguageMode? {
        guard let root = projectRoot
        else { return nil }
        let file = file.standardizedFileURL
        if let path = Self.relativePath(of: file, under: root) {
            let classified = LanguageMode.classify(
                path: path,
                languages: projectLanguages
            )
            if let classified,
               let session = workspaceSessions.values.first(where: {
                   $0.analysisProfile.language == classified.language
               }),
               let occurrence = session.manifest.files.first(where: {
                   session.paths.resolve($0.pathID) == path
               }),
               let key = session.content(at: occurrence.pathID)?.0,
               key.languageMode == classified
            {
                return key.languageMode
            }
            return classified
        }
        guard exactLocationIsInDependency(file.path) else { return nil }
        if let classified = LanguageMode.classify(
            path: file.path,
            languages: projectLanguages
        ) {
            return classified
        }
        return nil
    }

    private func trailJump(
        for destination: SourceDestination
    ) -> JumpRecord? {
        guard let byteOffset = destination.byteOffset else { return nil }
        let file = destination.file.standardizedFileURL
        let path: String
        let captured: (contentID: ContentID, bytes: [UInt8])?
        let isDependency: Bool
        if let root = fileTree?.root,
           let relative = Self.relativePath(of: file, under: root)
        {
            path = relative
            captured = capturedProjectSource(at: relative)
            isDependency = false
        } else if exactLocationIsInDependency(file.path) {
            path = file.path
            captured = (try? Data(contentsOf: file, options: .mappedIfSafe)).map {
                let bytes = Array($0)
                return (ContentID.sha256(of: bytes), bytes)
            }
            isDependency = true
        } else {
            return nil
        }
        let coordinate = captured.flatMap {
            LineTable(bytes: $0.bytes).lineColumn(at: byteOffset)
        }
        return JumpRecord(
            path: path,
            contentID: captured?.contentID,
            byteOffset: byteOffset,
            line: coordinate?.line ?? 1,
            column: coordinate?.column ?? 1,
            symbolAnchor: destination.symbolAnchor,
            snapshotID: currentSnapshotID,
            revision: isDependency ? nil : currentRevision
        )
    }

    private func refreshExplanation(for node: RelationTreeModel.Node) {
        guard let id = node.explanationID,
              let materialized = relationTree.materializedExplanation(for: node)
        else { return }
        resolutionExplanations.update(id, to: materialized)
    }

    private func retainTrailExplanations() {
        resolutionExplanations.retain(readingTrail.referencedExplanationIDs)
    }

    private func replay(_ record: NavigationRecord) {
        guard let targetSnapshotID = record.jump.snapshotID,
              targetSnapshotID != currentSnapshotID
        else {
            replayWithinCurrentSnapshot(record)
            return
        }
        guard projectRoot != nil else { return }
        guard let destination = snapshotDestinations[targetSnapshotID] else {
            if currentSnapshotID == nil {
                replayWithinCurrentSnapshot(record)
            }
            return
        }
        let replaysWorktree: Bool = if case .worktree = destination {
            true
        } else {
            false
        }
        pendingReplay = (record, replaysWorktree, false)
        switch destination {
        case .worktree:
            switchSnapshot(revision: nil)
        case let .commit(revision, _):
            switchSnapshot(revision: revision)
        }
    }

    private func replayWithinCurrentSnapshot(
        _ record: NavigationRecord,
        replayedAgainstCurrentWorktree: Bool = false,
        opensInNewTab: Bool = false
    ) {
        guard let root = fileTree?.root else { return }
        let jump = record.jump
        let dependency = exactLocationIsInDependency(jump.path)
        let file = dependency
            ? URL(fileURLWithPath: jump.path).standardizedFileURL
            : root.appendingPathComponent(jump.path).standardizedFileURL
        guard dependency || file.pathComponents.starts(with: root.pathComponents)
        else { return }
        if !dependency,
           let selectionPath = fileTree?.selectionPath(for: file),
           let node = selectionPath.last,
           !node.isDirectory,
           languageMode(for: file) == nil
        {
            readingTrail.restore(record.trailNodeID)
            replayNotice = nil
            if opensInNewTab {
                openInNewTab(file, selectionByteOffset: nil)
            } else {
                navigate(
                    NavigationRequest(
                        destination: SourceDestination(file: file),
                        cause: .historyReplay,
                        policy: .replay
                    )
                )
            }
            return
        }
        guard let languageMode = languageMode(for: file) else { return }
        let source = dependency ? nil : documentSource
        let replayGeneration = generation
        navigationGeneration &+= 1
        let replayNavigationGeneration = navigationGeneration
        let replaySnapshotID = currentSnapshotID
        replayTask?.cancel()
        replayTask = Task { [weak self] in
            let replayed: (offset: UInt32, fallback: ReplayFallbackKind)
            do {
                replayed = try await detachedValue {
                    try Self.replayOffset(
                        jump,
                        file: file,
                        source: source,
                        languageMode: languageMode
                    )
                }
                try Task.checkCancellation()
            } catch {
                return
            }
            guard let self,
                  canPublishWorkspaceResult(
                      generation: replayGeneration,
                      root: root,
                      languages: projectLanguages
                  ),
                  navigationGeneration == replayNavigationGeneration,
                  currentSnapshotID == replaySnapshotID,
                  self.languageMode(for: file) == languageMode
            else { return }
            readingTrail.restore(record.trailNodeID)
            replayNotice = Self.replayNotice(
                fallback: replayed.fallback,
                replayedAgainstCurrentWorktree: replayedAgainstCurrentWorktree
            )
            if opensInNewTab {
                openInNewTab(file, selectionByteOffset: replayed.offset)
            } else {
                navigate(
                    NavigationRequest(
                        destination: SourceDestination(
                            file: file,
                            byteOffset: replayed.offset
                        ),
                        cause: .historyReplay,
                        policy: .replay
                    )
                )
            }
        }
    }

    nonisolated package static func replayOffset(
        _ record: JumpRecord,
        file: URL,
        source: DocumentLoader.ContentSource?
    ) throws -> (offset: UInt32, fallback: ReplayFallbackKind) {
        try replayOffset(
            record,
            file: file,
            source: source,
            languageMode: LanguageMode(language: .rust)
        )
    }

    nonisolated package static func replayOffset(
        _ record: JumpRecord,
        file: URL,
        source: DocumentLoader.ContentSource?,
        languageMode: LanguageMode
    ) throws -> (offset: UInt32, fallback: ReplayFallbackKind) {
        let loader = if let source {
            DocumentLoader(source: source)
        } else {
            DocumentLoader()
        }
        let loaded = try loader.load(file: file, languageMode: languageMode)
        return replayOffset(
            record,
            document: loaded.document,
            tier: loaded.tier
        )
    }

    nonisolated private static func replayOffset(
        _ record: JumpRecord,
        document: ReaderDocument,
        tier: FileTier
    ) -> (offset: UInt32, fallback: ReplayFallbackKind) {
        let byteIsValid = document.byteUTF16Map.utf16Offset(
            forByte: Int(record.byteOffset)
        ) != nil
        if let contentID = record.contentID,
           contentID == document.contentID,
           byteIsValid
        {
            return (record.byteOffset, .exact)
        }
        if record.contentID == nil, byteIsValid {
            return (record.byteOffset, .byteUnverified)
        }
        if let lineOffset = document.lineTable.byteOffset(
            line: record.line,
            column: record.column
        ) {
            return (lineOffset, .line)
        }
        if let symbolAnchor = record.symbolAnchor {
            let facets = if tier == .regular {
                document.outlineFacets
            } else {
                (try? DocumentLoader().loadSyntax(for: document))?
                    .outlineFacets ?? []
            }
            let matches = facets.filter { $0.name == symbolAnchor }
            if matches.count == 1, let facet = matches.first {
                return (facet.nameRange.lowerBound, .symbol)
            }
        }
        return (0, .fileHead)
    }

    nonisolated private static func replayNotice(
        fallback: ReplayFallbackKind,
        replayedAgainstCurrentWorktree: Bool
    ) -> String? {
        var parts: [String] = []
        if replayedAgainstCurrentWorktree {
            parts.append("replayed against current worktree")
        }
        switch fallback {
        case .exact:
            break
        case .byteUnverified:
            parts.append("restored by unverified byte offset")
        case .line:
            parts.append("restored by line and column")
        case .symbol:
            parts.append("restored by unique symbol anchor")
        case .fileHead:
            parts.append("restored at file head")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private func sourceFileCount(
    in nodes: [FileTreeNode],
    under root: URL,
    languages: [LanguageID]
) -> Int {
    nodes.reduce(0) { count, node in
        if node.isDirectory {
            return count + sourceFileCount(
                in: node.children,
                under: root,
                languages: languages
            )
        }
        let rootComponents = root.standardizedFileURL.pathComponents
        let fileComponents = node.url.standardizedFileURL.pathComponents
        guard fileComponents.starts(with: rootComponents),
              fileComponents.count > rootComponents.count
        else { return count }
        let path = fileComponents.dropFirst(rootComponents.count)
            .joined(separator: "/")
        return count + (LanguageMode.classify(path: path, languages: languages) != nil ? 1 : 0)
    }
}

private func validateProductSupport(_ language: LanguageID) throws {
    switch language {
    case .rust, .python, .typescript:
        return
    case .javascript:
        throw CocoaError(.featureUnsupported, userInfo: [
            NSLocalizedFailureReasonErrorKey:
                "CodeInsight app does not support \(String(describing: language))",
        ])
    }
}
