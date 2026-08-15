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
        children = try Self.children(in: self.root, language: language)
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
        let paths = snapshotPaths
            .filter { LanguageMode.classify(path: $0, language: language) != nil }
            .map { $0.split(separator: "/").map(String.init) }
        children = Self.children(from: paths, under: self.root)
        fileCount = Self.fileCount(in: children)
    }

    public init(
        root: URL,
        snapshotPaths: [String],
        languages: [LanguageID]
    ) {
        self.root = root.standardizedFileURL
        let paths = snapshotPaths
            .filter { path in
                LanguageMode.classify(path: path, languages: languages) != nil
            }
            .map { $0.split(separator: "/").map(String.init) }
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

    private static func children(
        in directory: URL,
        language: LanguageID
    ) throws -> [FileTreeNode] {
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
                let children = try children(in: url, language: language)
                if !children.isEmpty {
                    nodes.append(FileTreeNode(
                        url: url,
                        isDirectory: true,
                        children: children
                    ))
                }
            } else if values.isRegularFile == true,
                      LanguageMode.classify(path: url.path, language: language) != nil
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
        case commit(String)
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
    @ObservationIgnored private var sessionCheckpointTask: Task<Void, Never>?
    @ObservationIgnored private var sessionURL: URL?
    package private(set) var projectRoot: URL?
    private var lastInstalledProjectRoot: URL?
    private var lastInstalledRevision: String?
    private var lastInstalledGeneration: UInt64?
    @ObservationIgnored private var snapshotDestinations: [
        SnapshotID: SnapshotDestination
    ] = [:]
    @ObservationIgnored private var pendingReplay: (
        record: NavigationRecord,
        replayedAgainstCurrentWorktree: Bool,
        opensInNewTab: Bool
    )?

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
        guard sessionURL != nil else { return }
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

    public func openProject(root: URL, languages: [LanguageID]) async throws {
        let normalized = try LanguageMode.normalize(languages: languages)
        let root = root.standardizedFileURL
        snapshotTask?.cancel()
        compareSnapshotTask?.cancel()
        replayTask?.cancel()
        compare.clear()
        generation &+= 1
        let openGeneration = generation
        exactCoordinator.invalidate(generation: openGeneration)
        projectRoot = root
        projectLanguages = normalized
        workspaceSessions.removeAll(keepingCapacity: true)
        commitPicker.setCurrentRevision(nil)
        commitPicker.load(repositoryURL: root)
        snapshotDestinations.removeAll(keepingCapacity: true)
        pendingReplay = nil
        documentSource = nil
        transition(to: .indexing(root: root, startedAt: .now))
        snapshotPhase = nil
        coverage = SnapshotCoverage(filesIndexed: 0, filesTotal: 0)
        currentSnapshotID = nil
        fileTree = nil
        selectedFile = nil
        selectedByteOffset = nil
        navigationGeneration &+= 1
        navigationHistory.reset()
        readingTrail.reset()
        resolutionExplanations.removeAll()
        replayNotice = nil
        tabStrip.reset()

        do {
            let snapshot = try await indexService.captureSnapshot(
                root: root,
                revision: nil,
                languages: normalized
            )
            try Task.checkCancellation()
            guard canPublishWorkspaceResult(
                generation: openGeneration,
                root: root,
                languages: normalized
            ) else { return }
            publishFirstPaint(
                snapshot,
                root: root,
                revision: nil,
                generation: openGeneration,
                languages: normalized
            )
            try Task.checkCancellation()
            guard canPublishWorkspaceResult(
                generation: openGeneration,
                root: root,
                languages: normalized
            ) else { return }

            let prepared = try await indexService.prepareSnapshots(
                snapshot,
                root: root,
                languages: normalized
            )
            try Task.checkCancellation()
            guard canPublishWorkspaceResult(
                generation: openGeneration,
                root: root,
                languages: normalized
            ) else { return }
            guard installWorkspaceSessions(
                prepared.map(\.cachedSession),
                generation: openGeneration,
                root: root,
                languages: normalized,
                expectedSnapshotID: snapshot.snapshotID,
                phase: .cachedReady
            ) else {
                failWorkspace(
                    generation: openGeneration,
                    root: root,
                    languages: normalized
                )
                return
            }

            var completed: [AnalysisProfileID: EngineSession] = [:]
            for item in prepared {
                let session = try await indexService.completeSnapshot(item)
                completed[session.analysisProfile.id] = session
            }
            guard installWorkspaceSessions(
                completed.values.map(\.self),
                generation: openGeneration,
                root: root,
                languages: normalized,
                expectedSnapshotID: snapshot.snapshotID,
                phase: .fullReady
            ) else {
                workspaceSessions.removeAll(keepingCapacity: true)
                failWorkspace(
                    generation: openGeneration,
                    root: root,
                    languages: normalized
                )
                return
            }
            lastInstalledRevision = currentRevision
            lastInstalledProjectRoot = projectRoot
            lastInstalledGeneration = generation
            prepareExact(generation: openGeneration)
        } catch is CancellationError {
            return
        } catch {
            failWorkspace(
                generation: openGeneration,
                root: root,
                languages: normalized
            )
        }
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
        guard transition(to: .indexing(root: root, startedAt: .now)) else {
            assertionFailure("Illegal project state transition to indexing")
            return
        }
        snapshotTask?.cancel()
        compareSnapshotTask?.cancel()
        replayTask?.cancel()
        compare.clear()
        generation &+= 1
        let openGeneration = generation
        exactCoordinator.invalidate(generation: openGeneration)
        projectRoot = root
        projectLanguages = [language]
        workspaceSessions.removeAll(keepingCapacity: true)
        commitPicker.setCurrentRevision(nil)
        commitPicker.load(repositoryURL: root)
        currentSnapshotID = nil
        snapshotDestinations.removeAll(keepingCapacity: true)
        pendingReplay = nil
        documentSource = nil
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
        tabStrip.reset()

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
                    filesTotal: fileTree.fileCount
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
        replayTask?.cancel()
        if request.cause != .historyReplay { replayNotice = nil }
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
        compare.clear()
        generation &+= 1
        let switchGeneration = generation
        exactCoordinator.invalidate(generation: switchGeneration)
        commitPicker.setCurrentRevision(revision)
        workspaceSessions.removeAll(keepingCapacity: true)
        snapshotPhase = nil
        coverage = SnapshotCoverage(filesIndexed: 0, filesTotal: 0)
        publishProjectState(.indexing(root: root, startedAt: .now), root: root)

        let expectedLanguages = projectLanguages
        snapshotTask = Task { [weak self, indexService] in
            do {
                let snapshot = try await indexService.captureSnapshot(
                    root: root,
                    revision: revision,
                    languages: expectedLanguages
                )
                try Task.checkCancellation()
                guard let self,
                      canPublishWorkspaceResult(
                          generation: switchGeneration,
                          root: root,
                          languages: expectedLanguages
                      )
                else { return }
                publishFirstPaint(
                    snapshot,
                    root: root,
                    revision: revision,
                    generation: switchGeneration,
                    languages: expectedLanguages
                )
                await Task.yield()
                guard canPublishWorkspaceResult(
                    generation: switchGeneration,
                    root: root,
                    languages: expectedLanguages
                ) else { return }

                let prepared = try await indexService.prepareSnapshots(
                    snapshot,
                    root: root,
                    languages: expectedLanguages
                )
                try Task.checkCancellation()
                guard canPublishWorkspaceResult(
                    generation: switchGeneration,
                    root: root,
                    languages: expectedLanguages
                ) else { return }
                guard installWorkspaceSessions(
                    prepared.map(\.cachedSession),
                    generation: switchGeneration,
                    root: root,
                    languages: expectedLanguages,
                    expectedSnapshotID: snapshot.snapshotID,
                    phase: .cachedReady
                ) else {
                    failWorkspace(
                        generation: switchGeneration,
                        root: root,
                        languages: expectedLanguages
                    )
                    return
                }
                await Task.yield()
                guard canPublishWorkspaceResult(
                    generation: switchGeneration,
                    root: root,
                    languages: expectedLanguages
                ) else { return }

                var completed: [EngineSession] = []
                for item in prepared {
                    let session = try await indexService.completeSnapshot(item)
                    completed.append(session)
                    try Task.checkCancellation()
                    guard canPublishWorkspaceResult(
                        generation: switchGeneration,
                        root: root,
                        languages: expectedLanguages
                    ) else { return }
                }
                guard installWorkspaceSessions(
                    completed,
                    generation: switchGeneration,
                    root: root,
                    languages: expectedLanguages,
                    expectedSnapshotID: snapshot.snapshotID,
                    phase: .fullReady
                ) else {
                    failWorkspace(
                        generation: switchGeneration,
                        root: root,
                        languages: expectedLanguages
                    )
                    return
                }
                lastInstalledRevision = currentRevision
                lastInstalledProjectRoot = projectRoot
                lastInstalledGeneration = generation
                prepareExact(generation: generation)
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      canPublishWorkspaceResult(
                          generation: switchGeneration,
                          root: root,
                          languages: expectedLanguages
                      )
                else { return }
                failWorkspace(
                    generation: switchGeneration,
                    root: root,
                    languages: expectedLanguages
                )
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
        let files = snapshot.listFiles()
        let paths = files.map(\.path).filter {
            LanguageMode.classify(path: $0, languages: languages) != nil
        }
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
        if let revision {
            snapshotDestinations[snapshot.snapshotID] = .commit(revision)
        } else {
            snapshotDestinations[snapshot.snapshotID] = .worktree
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
            filesTotal: paths.count
        )
        navigationGeneration &+= 1
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
        var byProfile: [AnalysisProfileID: EngineSession] = [:]
        for session in candidates {
            byProfile[session.analysisProfile.id] = session
        }
        guard byProfile.count == expectedLanguages.count,
              byProfile.values.allSatisfy({ $0.snapshotID == expectedSnapshotID }),
              Set(byProfile.keys) == Set(byProfile.values.map { $0.analysisProfile.id }),
              Set(byProfile.values.map { $0.snapshotID }).count == 1,
              Set(byProfile.values.map { $0.analysisProfile.language }) == Set(expectedLanguages),
              Set(byProfile.values.map { ObjectIdentifier($0.paths) }).count == 1
        else {
            return false
        }
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
        case let .commit(revision):
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
