import CodeInsightCore
import Foundation

final class ProjectIndexStore: @unchecked Sendable {
    let names = Interner<NameID>()
    let paths = Interner<PathID>()
    let strings = Interner<StringID>()

    private let lock = NSLock()
    private var storedContentIndexes: [ContentIndexKey: ContentIndex] = [:]
    private var storedSourceBytes: [ContentID: [UInt8]] = [:]
    private var storedNamePosting = NamePosting(indexes: [:])

    init() {}

    var contentIndexes: [ContentIndexKey: ContentIndex] {
        lock.withLock { storedContentIndexes }
    }

    var sourceBytesByContent: [ContentID: [UInt8]] {
        lock.withLock { storedSourceBytes }
    }

    var namePosting: NamePosting {
        lock.withLock { storedNamePosting }
    }

    func insert(_ index: ContentIndex, bytes: [UInt8]) {
        lock.withLock {
            guard storedContentIndexes[index.key] == nil else { return }
            storedContentIndexes[index.key] = index
            storedSourceBytes[index.key.contentID] = bytes
            storedNamePosting.add(index, for: index.key)
        }
    }
}

struct SnapshotView: Sendable {
    let store: ProjectIndexStore
    let manifest: SnapshotManifest
    let stats: IndexStats
    let analysisProfile: AnalysisProfile
    let moduleMap: ModuleMap

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
        moduleMap = ModuleMap(
            manifest: manifest,
            indexes: store.contentIndexes,
            bytesByContent: store.sourceBytesByContent,
            names: store.names,
            paths: store.paths
        )
    }
}
