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
    func index(root: URL) async throws -> EngineSession
    func captureSnapshot(root: URL, revision: String?) async throws -> any Snapshot
    func prepareSnapshot(
        _ snapshot: any Snapshot
    ) async throws -> ProjectIndexer.PreparedSnapshot
    func completeSnapshot(
        _ prepared: ProjectIndexer.PreparedSnapshot
    ) async throws -> EngineSession
    func flushPersistentIndexCache()
}

public extension IndexService {
    func captureSnapshot(root: URL, revision: String?) async throws -> any Snapshot {
        throw CocoaError(.featureUnsupported)
    }

    func prepareSnapshot(
        _ snapshot: any Snapshot
    ) async throws -> ProjectIndexer.PreparedSnapshot {
        throw CocoaError(.featureUnsupported)
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

    public func index(root: URL) async throws -> EngineSession {
        let store = store
        let indexer = ProjectIndexer(persistingProjectAt: root)
        lock.withLock { self.indexer = indexer }
        return try await detachedValue {
            let snapshot: WorktreeSnapshot
            do {
                snapshot = try WorktreeSnapshot(repositoryURL: root)
            } catch {
                return try indexer.index(root: root)
            }
            return try indexer.indexSnapshot(snapshot, into: store)
        }
    }

    public func captureSnapshot(
        root: URL,
        revision: String?
    ) async throws -> any Snapshot {
        try await detachedValue {
            try Task.checkCancellation()
            let snapshot: any Snapshot = if let revision {
                try CommitSnapshot(repositoryURL: root, revision: revision)
            } else {
                try WorktreeSnapshot(repositoryURL: root)
            }
            try Task.checkCancellation()
            return snapshot
        }
    }

    public func prepareSnapshot(
        _ snapshot: any Snapshot
    ) async throws -> ProjectIndexer.PreparedSnapshot {
        let store = store
        let indexer: ProjectIndexer = lock.withLock { self.indexer }
        return try await detachedValue {
            try indexer.prepareSnapshot(snapshot, into: store)
        }
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
        self.root = root.standardizedFileURL
        children = try Self.children(in: self.root)
        fileCount = Self.fileCount(in: children)
    }

    public init(root: URL, snapshotPaths: [String]) {
        self.root = root.standardizedFileURL
        let paths = snapshotPaths
            .filter { URL(fileURLWithPath: $0).pathExtension == "rs" }
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
            } else if values.isRegularFile == true && url.pathExtension == "rs" {
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
    private enum SnapshotDestination {
        case worktree
        case commit(String)
    }

    public private(set) var projectState: ProjectState = .empty
    public private(set) var generation: UInt64 = 0
    public private(set) var snapshotPhase: SnapshotPhase?
    public private(set) var coverage = SnapshotCoverage(filesIndexed: 0, filesTotal: 0)
    public var currentRevision: String? { commitPicker.currentRevision }
    public private(set) var currentSnapshotID: SnapshotID?
    public private(set) var fileTree: FileTreeModel?
    public private(set) var selectedFile: URL?
    public private(set) var selectedByteOffset: UInt32?
    public private(set) var navigationGeneration: UInt64 = 0
    @ObservationIgnored public private(set) var documentSource: DocumentLoader.ContentSource?
    public let contextWindow: ContextWindowModel
    public let exactCoordinator: ExactCoordinator
    public let commitPicker: CommitPickerModel
    public let compare: CompareModel
    public let relationTree = RelationTreeModel()
    public let navigationHistory = NavigationHistory()

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

    public var currentFeatureSelection: FeatureSelection? {
        activeAnalysisProfileDisplay?.featureSelection
    }

    public var availableFeatureSelections: [FeatureSelection] {
        FeatureSelection.allCases
    }

    private let indexService: any IndexService
    private let navigationSink: @MainActor (URL, UInt32?) -> Void
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    @ObservationIgnored private var compareSnapshotTask: Task<Void, Never>?
    @ObservationIgnored private var replayTask: Task<Void, Never>?
    private var projectRoot: URL?
    @ObservationIgnored private var snapshotDestinations: [
        SnapshotID: SnapshotDestination
    ] = [:]
    @ObservationIgnored private var pendingReplay: JumpRecord?

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
        relationTree.onSelect = { [weak self] node in
            guard let self,
                  contextWindow.mode != .pinned,
                  let target = node.target
            else { return }
            Task { [weak self] in
                _ = await self?.contextWindow.explicitJump(
                    file: target.path,
                    offset: target.byteOffset
                )
            }
        }
    }

    public func openProject(root: URL) {
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

        snapshotTask = Task { [weak self, indexService] in
            do {
                let fileTree = try await detachedValue {
                    try FileTreeModel(root: root)
                }
                try Task.checkCancellation()
                guard let self, generation == openGeneration else { return }
                self.fileTree = fileTree
                coverage = SnapshotCoverage(
                    filesIndexed: 0,
                    filesTotal: fileTree.fileCount
                )
                let session = try await indexService.index(root: root)
                try Task.checkCancellation()
                finishIndexing(session, generation: openGeneration)
            } catch is CancellationError {
                return
            } catch {
                self?.failIndexing(generation: openGeneration)
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
              session.analysisProfile.featureSelection != featureSelection
        else { return }
        generation &+= 1
        let profileGeneration = generation
        let reprofiled = session.reprofiled(featureSelection: featureSelection)
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
        prepareExact(generation: profileGeneration)
    }

    public func switchToCommit(
        _ revision: String,
        leaving current: JumpRecord? = nil
    ) {
        pendingReplay = nil
        if selectedFile != nil, let current { navigationHistory.push(current) }
        switchSnapshot(revision: revision)
    }

    public func switchToWorktree(leaving current: JumpRecord? = nil) {
        pendingReplay = nil
        if selectedFile != nil, let current { navigationHistory.push(current) }
        switchSnapshot(revision: nil)
    }

    public func selectCompareCommit(_ revision: String) {
        guard let root = projectRoot else { return }
        compareSnapshotTask?.cancel()
        let compareGeneration = compare.beginLoading(revision: revision)
        let mainGeneration = generation
        compareSnapshotTask = Task { [weak self, indexService] in
            do {
                let snapshot = try await indexService.captureSnapshot(
                    root: root,
                    revision: revision
                )
                try Task.checkCancellation()
                guard let self, generation == mainGeneration else { return }
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
                self?.compare.fail(generation: compareGeneration, error: error)
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
        replayTask?.cancel()
        if let current { navigationHistory.push(current) }
        selectedFile = url.standardizedFileURL
        selectedByteOffset = byteOffset
        navigationGeneration &+= 1
        navigationSink(url.standardizedFileURL, byteOffset)
        updateCompareFile()
    }

    public func goBack(from current: JumpRecord) {
        guard let record = navigationHistory.goBack(from: current) else { return }
        replay(record)
    }

    public func goForward() {
        guard let record = navigationHistory.goForward() else { return }
        replay(record)
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

    private func finishIndexing(_ session: EngineSession, generation: UInt64) {
        guard self.generation == generation else { return }
        currentSnapshotID = session.snapshotID
        snapshotDestinations[session.snapshotID] = .worktree
        snapshotPhase = .fullReady
        coverage = Self.coverage(for: session)
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
        prepareExact(generation: generation)
    }

    private func failIndexing(generation: UInt64) {
        guard self.generation == generation else { return }
        pendingReplay = nil
        guard transition(to: .failed) else {
            assertionFailure("Illegal project state transition to failed")
            return
        }
    }

    private func switchSnapshot(revision: String?) {
        guard let root = projectRoot else { return }
        snapshotTask?.cancel()
        compareSnapshotTask?.cancel()
        replayTask?.cancel()
        compare.clear()
        generation &+= 1
        let switchGeneration = generation
        exactCoordinator.invalidate(generation: switchGeneration)
        commitPicker.setCurrentRevision(revision)
        snapshotPhase = nil
        coverage = SnapshotCoverage(filesIndexed: 0, filesTotal: 0)
        publishProjectState(.indexing(root: root, startedAt: .now), root: root)

        snapshotTask = Task { [weak self, indexService] in
            do {
                let snapshot = try await indexService.captureSnapshot(
                    root: root,
                    revision: revision
                )
                try Task.checkCancellation()
                guard let self, generation == switchGeneration else { return }
                publishFirstPaint(
                    snapshot,
                    root: root,
                    revision: revision,
                    generation: switchGeneration
                )
                await Task.yield()

                let prepared = try await indexService.prepareSnapshot(snapshot)
                try Task.checkCancellation()
                guard generation == switchGeneration else { return }
                publishSession(
                    prepared.cachedSession,
                    phase: .cachedReady,
                    generation: switchGeneration
                )
                await Task.yield()

                let session = try await indexService.completeSnapshot(prepared)
                try Task.checkCancellation()
                guard generation == switchGeneration else { return }
                publishSession(
                    session,
                    phase: .fullReady,
                    generation: switchGeneration
                )
            } catch is CancellationError {
                return
            } catch {
                guard let self, generation == switchGeneration else { return }
                failIndexing(generation: switchGeneration)
            }
        }
    }

    private func publishFirstPaint(
        _ snapshot: any Snapshot,
        root: URL,
        revision: String?,
        generation: UInt64
    ) {
        guard self.generation == generation, !Task.isCancelled else { return }
        let files = snapshot.listFiles()
        let paths = files.map(\.path)
        let selectedPath = selectedFile.flatMap {
            Self.relativePath(of: $0, under: root)
        }
        fileTree = FileTreeModel(root: root, snapshotPaths: paths)
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
                return try snapshot.readBytes(path: path)
            }
        }
        snapshotPhase = .firstPaint
        coverage = SnapshotCoverage(
            filesIndexed: 0,
            filesTotal: paths.filter {
                URL(fileURLWithPath: $0).pathExtension == "rs"
            }.count
        )
        navigationGeneration &+= 1
        if let record = pendingReplay {
            pendingReplay = nil
            replayWithinCurrentSnapshot(record)
        }
    }

    private func publishSession(
        _ session: EngineSession,
        phase: SnapshotPhase,
        generation: UInt64
    ) {
        guard self.generation == generation, !Task.isCancelled else { return }
        currentSnapshotID = session.snapshotID
        snapshotPhase = phase
        coverage = Self.coverage(for: session)
        let context = QueryContext(
            snapshotID: session.snapshotID,
            analysisProfileID: session.analysisProfile.id,
            generation: generation
        )
        guard transition(to: .ready(session, context)) else {
            assertionFailure("Illegal project state transition to ready")
            return
        }
        if phase == .fullReady { prepareExact(generation: generation) }
    }

    private func prepareExact(generation: UInt64) {
        guard let projectRoot,
              case let .ready(session, _) = projectState
        else { return }
        exactCoordinator.prepare(
            projectURL: projectRoot,
            revision: currentRevision,
            featureSelection: session.analysisProfile.featureSelection,
            generation: generation
        )
    }

    private func updateCompareFile() {
        compare.update(file: selectedFile, leftSource: documentSource)
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

    private static func coverage(for session: EngineSession) -> SnapshotCoverage {
        let indexedContent = Set(session.contentIndexes.keys.map(\.contentID))
        let rustFiles = session.manifest.files.filter { $0.detectedLanguage == .rust }
        return SnapshotCoverage(
            filesIndexed: rustFiles.filter {
                indexedContent.contains($0.contentID)
            }.count,
            filesTotal: rustFiles.count
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

    private func replay(_ record: JumpRecord) {
        guard let targetSnapshotID = record.snapshotID,
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
        pendingReplay = record
        switch destination {
        case .worktree:
            switchSnapshot(revision: nil)
        case let .commit(revision):
            switchSnapshot(revision: revision)
        }
    }

    private func replayWithinCurrentSnapshot(_ record: JumpRecord) {
        guard let root = fileTree?.root else { return }
        let dependency = exactLocationIsInDependency(record.path)
        let file = dependency
            ? URL(fileURLWithPath: record.path).standardizedFileURL
            : root.appendingPathComponent(record.path).standardizedFileURL
        guard dependency || file.pathComponents.starts(with: root.pathComponents)
        else { return }
        let source = dependency ? nil : documentSource
        let replayGeneration = generation
        let replayNavigationGeneration = navigationGeneration
        let replaySnapshotID = currentSnapshotID
        replayTask?.cancel()
        replayTask = Task { [weak self] in
            let offset: UInt32
            do {
                offset = try await detachedValue {
                    try Self.replayOffset(record, file: file, source: source)
                }
                try Task.checkCancellation()
            } catch {
                return
            }
            guard let self,
                  generation == replayGeneration,
                  navigationGeneration == replayNavigationGeneration,
                  currentSnapshotID == replaySnapshotID
            else { return }
            navigate(to: file, byteOffset: offset)
        }
    }

    nonisolated private static func replayOffset(
        _ record: JumpRecord,
        file: URL,
        source: DocumentLoader.ContentSource?
    ) throws -> UInt32 {
        let loader = if let source {
            DocumentLoader(source: source)
        } else {
            DocumentLoader()
        }
        let loaded = try loader.load(file: file)
        let document = loaded.document
        // 1. Preserve the exact byte position whenever it still fits this version.
        if Int(record.byteOffset) <= document.bytes.count {
            return record.byteOffset
        // 2. A shorter file invalidates the byte; retry its recorded line/column.
        } else if let lineOffset = document.lineTable.byteOffset(
            line: record.line,
            column: record.column
        ) {
            return lineOffset
        // 3. Invalid coordinates fall back to the same named symbol's declaration.
        } else if let symbolAnchor = record.symbolAnchor {
            let facets = if loaded.tier == .regular {
                document.outlineFacets
            } else {
                (try? RustHighlighter().highlight(bytes: document.bytes))?
                    .outlineFacets ?? []
            }
            if let facet = facets.first(where: { $0.name == symbolAnchor }) {
                return facet.nameRange.lowerBound
            } else {
                // 4. A missing symbol leaves the file head as the last safe target.
                return 0
            }
        } else {
            // 4. No valid coordinate or anchor remains, so open the file head.
            return 0
        }
    }
}
