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

    private let indexService: any IndexService

    public init(
        indexService: any IndexService = ProjectIndexService(),
        contextWindow: ContextWindowModel = ContextWindowModel()
    ) {
        self.indexService = indexService
        self.contextWindow = contextWindow
    }

    public func openProject(root: URL) {
        generation &+= 1
        let openGeneration = generation
        let root = root.standardizedFileURL
        fileTree = nil
        selectedFile = nil
        selectedByteOffset = nil
        navigationGeneration &+= 1
        projectState = .indexing(root: root, startedAt: .now)
        contextWindow.updateProjectState(projectState, root: root)

        do {
            fileTree = try FileTreeModel(root: root)
        } catch {
            projectState = .failed
            contextWindow.updateProjectState(projectState, root: root)
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

    public func selectFile(_ url: URL) {
        openFile(url)
    }

    public func openFile(_ url: URL, byteOffset: UInt32? = nil) {
        selectedFile = url
        selectedByteOffset = byteOffset
        navigationGeneration &+= 1
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
    }

    private func failIndexing(generation: UInt64) {
        guard self.generation == generation else { return }
        projectState = .failed
        contextWindow.updateProjectState(projectState, root: fileTree?.root)
    }
}
