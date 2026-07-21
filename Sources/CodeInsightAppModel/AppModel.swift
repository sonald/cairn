import CodeInsightCore
import CodeInsightEngine
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
    /// M3 S4 does not yet expose an honest module-import reachability count.
    public let importsResolved: Int?

    public init(filesIndexed: Int, filesTotal: Int, importsResolved: Int? = nil) {
        self.filesIndexed = filesIndexed
        self.filesTotal = filesTotal
        self.importsResolved = importsResolved
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
}

public struct ProjectIndexService: IndexService {
    private static let snapshotCaptureLock = NSLock()
    private let store = ProjectIndexStore()

    public init() {}

    public func index(root: URL) async throws -> EngineSession {
        let store = store
        return try await detachedValue {
            let snapshot: WorktreeSnapshot
            do {
                snapshot = try Self.snapshotCaptureLock.withLock {
                    try WorktreeSnapshot(repositoryURL: root)
                }
            } catch {
                return try ProjectIndexer().index(root: root)
            }
            return try ProjectIndexer().indexSnapshot(snapshot, into: store)
        }
    }

    public func captureSnapshot(
        root: URL,
        revision: String?
    ) async throws -> any Snapshot {
        try await detachedValue {
            try Task.checkCancellation()
            let snapshot: any Snapshot = try Self.snapshotCaptureLock.withLock {
                if let revision {
                    try CommitSnapshot(repositoryURL: root, revision: revision)
                } else {
                    try WorktreeSnapshot(repositoryURL: root)
                }
            }
            try Task.checkCancellation()
            return snapshot
        }
    }

    public func prepareSnapshot(
        _ snapshot: any Snapshot
    ) async throws -> ProjectIndexer.PreparedSnapshot {
        let store = store
        return try await detachedValue {
            try ProjectIndexer().prepareSnapshot(snapshot, into: store)
        }
    }

    public func completeSnapshot(
        _ prepared: ProjectIndexer.PreparedSnapshot
    ) async throws -> EngineSession {
        try await detachedValue {
            try ProjectIndexer().completeSnapshot(prepared)
        }
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
}

@MainActor
@Observable
public final class AppModel {
    public private(set) var projectState: ProjectState = .empty
    public private(set) var generation: UInt64 = 0
    public private(set) var snapshotPhase: SnapshotPhase?
    public private(set) var coverage = SnapshotCoverage(filesIndexed: 0, filesTotal: 0)
    public private(set) var currentRevision: String?
    public private(set) var currentSnapshotID: SnapshotID?
    public private(set) var fileTree: FileTreeModel?
    public private(set) var selectedFile: URL?
    public private(set) var selectedByteOffset: UInt32?
    public private(set) var navigationGeneration: UInt64 = 0
    @ObservationIgnored public private(set) var documentSource: DocumentLoader.ContentSource?
    public let contextWindow: ContextWindowModel
    public let relationTree = RelationTreeModel()
    public let navigationHistory = NavigationHistory()

    private let indexService: any IndexService
    private let navigationSink: @MainActor (URL, UInt32?) -> Void
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    private var projectRoot: URL?

    public init(
        indexService: any IndexService = ProjectIndexService(),
        contextWindow: ContextWindowModel = ContextWindowModel(),
        navigationSink: @MainActor @escaping (URL, UInt32?) -> Void = { _, _ in }
    ) {
        self.indexService = indexService
        self.contextWindow = contextWindow
        self.navigationSink = navigationSink
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
        generation &+= 1
        let openGeneration = generation
        projectRoot = root
        currentRevision = nil
        currentSnapshotID = nil
        documentSource = nil
        snapshotPhase = nil
        coverage = SnapshotCoverage(filesIndexed: 0, filesTotal: 0)
        fileTree = nil
        selectedFile = nil
        selectedByteOffset = nil
        navigationGeneration &+= 1
        navigationHistory.reset()

        do {
            fileTree = try FileTreeModel(root: root)
            coverage = SnapshotCoverage(
                filesIndexed: 0,
                filesTotal: fileTree?.fileCount ?? 0
            )
        } catch {
            guard transition(to: .failed) else {
                assertionFailure("Illegal project state transition to failed")
                return
            }
            return
        }

        Task { [weak self, indexService] in
            do {
                let session = try await indexService.index(root: root)
                self?.finishIndexing(session, generation: openGeneration)
            } catch {
                self?.failIndexing(generation: openGeneration)
            }
        }
    }

    public func switchToCommit(_ revision: String) {
        switchSnapshot(revision: revision)
    }

    public func switchToWorktree() {
        switchSnapshot(revision: nil)
    }

    public func navigate(
        to url: URL,
        byteOffset: UInt32? = nil,
        leaving current: JumpRecord? = nil
    ) {
        if let current { navigationHistory.push(current) }
        selectedFile = url.standardizedFileURL
        selectedByteOffset = byteOffset
        navigationGeneration &+= 1
        navigationSink(url.standardizedFileURL, byteOffset)
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
    }

    private func failIndexing(generation: UInt64) {
        guard self.generation == generation else { return }
        guard transition(to: .failed) else {
            assertionFailure("Illegal project state transition to failed")
            return
        }
    }

    private func switchSnapshot(revision: String?) {
        guard let root = projectRoot else { return }
        snapshotTask?.cancel()
        generation &+= 1
        let switchGeneration = generation
        currentRevision = revision
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
        guard let root = fileTree?.root else { return }
        let file = root.appendingPathComponent(record.path).standardizedFileURL
        guard file.pathComponents.starts(with: root.pathComponents),
              let bytes = try? (documentSource.map { try $0(file) }
                  ?? Array(Data(contentsOf: file)))
        else { return }
        let offset: UInt32
        if Int(record.byteOffset) <= bytes.count {
            offset = record.byteOffset
        } else {
            offset = LineTable(bytes: bytes).byteOffset(
                line: record.line,
                column: record.column
            ) ?? 0
        }
        navigate(to: file, byteOffset: offset)
    }
}
