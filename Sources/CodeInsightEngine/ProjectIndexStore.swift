import CodeInsightCore
import Foundation

public final class ProjectIndexStore: @unchecked Sendable {
    struct State: Sendable {
        let contentIndexes: [ContentIndexKey: ContentIndex]
        let sourceBytesByContent: [ContentID: [UInt8]]
        let namePosting: NamePosting
        let containsErrorNodes: [ContentIndexKey: Bool]
    }

    let names = Interner<NameID>()
    let paths = Interner<PathID>()
    let strings = Interner<StringID>()

    private let lock = NSLock()
    private var storedContentIndexes: [ContentIndexKey: ContentIndex] = [:]
    private var storedSourceBytes: [ContentID: [UInt8]] = [:]
    private var storedNamePosting = NamePosting(indexes: [:])
    private var storedContainsErrorNodes: [ContentIndexKey: Bool] = [:]

    public init() {}

    func snapshot() -> State {
        lock.withLock {
            State(
                contentIndexes: storedContentIndexes,
                sourceBytesByContent: storedSourceBytes,
                namePosting: storedNamePosting,
                containsErrorNodes: storedContainsErrorNodes
            )
        }
    }

    var contentIndexes: [ContentIndexKey: ContentIndex] {
        lock.withLock { storedContentIndexes }
    }

    var sourceBytesByContent: [ContentID: [UInt8]] {
        lock.withLock { storedSourceBytes }
    }

    var namePosting: NamePosting {
        lock.withLock { storedNamePosting }
    }

    func insert(_ bytesByContent: [ContentID: [UInt8]]) {
        lock.withLock {
            for (contentID, bytes) in bytesByContent
                where storedSourceBytes[contentID] == nil
            {
                storedSourceBytes[contentID] = bytes
            }
        }
    }

    func insert(
        _ index: ContentIndex,
        bytes: [UInt8],
        containsErrorNodes: Bool
    ) {
        lock.withLock {
            guard storedContentIndexes[index.key] == nil else { return }
            storedContentIndexes[index.key] = index
            storedSourceBytes[index.key.contentID] = bytes
            storedNamePosting.add(index, for: index.key)
            storedContainsErrorNodes[index.key] = containsErrorNodes
        }
    }
}

struct SnapshotView: Sendable {
    let store: ProjectIndexStore
    let manifest: SnapshotManifest
    let stats: IndexStats
    let analysisProfile: AnalysisProfile
    let moduleMap: ModuleMap
    let storeState: ProjectIndexStore.State

    init(
        store: ProjectIndexStore,
        manifest: SnapshotManifest,
        stats: IndexStats,
        analysisProfile: AnalysisProfile
    ) {
        self.store = store
        self.manifest = manifest
        self.stats = stats
        self.analysisProfile = analysisProfile
        storeState = store.snapshot()
        moduleMap = ModuleMap(
            manifest: manifest,
            indexes: storeState.contentIndexes,
            bytesByContent: storeState.sourceBytesByContent,
            names: store.names,
            paths: store.paths
        )
    }
}
