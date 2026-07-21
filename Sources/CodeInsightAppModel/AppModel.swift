import CodeInsightCore
import CodeInsightEngine
import Foundation
import Observation

public enum ProjectState: Sendable {
    case empty
    case indexing(root: URL, startedAt: ContinuousClock.Instant)
    case ready(EngineSession, QueryContext)
    case failed
}

public protocol IndexService: Sendable {
    func index(root: URL) async throws -> EngineSession
}

public struct ProjectIndexService: IndexService {
    public init() {}

    public func index(root: URL) async throws -> EngineSession {
        try await Task.detached(priority: .userInitiated) {
            try ProjectIndexer().index(root: root)
        }.value
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
    public private(set) var fileTree: FileTreeModel?
    public private(set) var selectedFile: URL?
    public private(set) var selectedByteOffset: UInt32?
    public private(set) var navigationGeneration: UInt64 = 0
    public let contextWindow: ContextWindowModel
    public let relationTree = RelationTreeModel()
    public let navigationHistory = NavigationHistory()

    private let indexService: any IndexService
    private let navigationSink: @MainActor (URL, UInt32?) -> Void

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
        generation &+= 1
        let openGeneration = generation
        let root = root.standardizedFileURL
        fileTree = nil
        selectedFile = nil
        selectedByteOffset = nil
        navigationGeneration &+= 1
        navigationHistory.reset()
        projectState = .indexing(root: root, startedAt: .now)
        contextWindow.updateProjectState(projectState, root: root)
        relationTree.updateProjectState(projectState)

        do {
            fileTree = try FileTreeModel(root: root)
        } catch {
            projectState = .failed
            contextWindow.updateProjectState(projectState, root: root)
            relationTree.updateProjectState(projectState)
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
             (.indexing, .failed):
            projectState = next
            contextWindow.updateProjectState(next, root: fileTree?.root)
            relationTree.updateProjectState(next)
            return true
        default:
            return false
        }
    }

    private func finishIndexing(_ session: EngineSession, generation: UInt64) {
        guard self.generation == generation else { return }
        projectState = .ready(
            session,
            QueryContext(
                snapshotID: session.snapshotID,
                analysisProfileID: session.analysisProfile.id,
                generation: generation
            )
        )
        contextWindow.updateProjectState(projectState, root: fileTree?.root)
        relationTree.updateProjectState(projectState)
    }

    private func failIndexing(generation: UInt64) {
        guard self.generation == generation else { return }
        projectState = .failed
        contextWindow.updateProjectState(projectState, root: fileTree?.root)
        relationTree.updateProjectState(projectState)
    }

    private func replay(_ record: JumpRecord) {
        guard let root = fileTree?.root else { return }
        let file = root.appendingPathComponent(record.path).standardizedFileURL
        guard file.pathComponents.starts(with: root.pathComponents),
              let values = try? file.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = values.fileSize
        else { return }
        let offset: UInt32
        if Int(record.byteOffset) <= fileSize {
            offset = record.byteOffset
        } else if let bytes = try? Data(contentsOf: file).map({ $0 }) {
            offset = LineTable(bytes: bytes).byteOffset(
                line: record.line,
                column: record.column
            ) ?? 0
        } else {
            offset = 0
        }
        navigate(to: file, byteOffset: offset)
    }
}
