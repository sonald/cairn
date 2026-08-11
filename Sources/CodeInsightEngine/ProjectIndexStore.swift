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
        insert([(index, bytes, containsErrorNodes)])
    }

    func insert(_ entries: [(ContentIndex, [UInt8], Bool)]) {
        lock.withLock {
            for (index, bytes, containsErrorNodes) in entries {
                guard storedContentIndexes[index.key] == nil else { continue }
                storedContentIndexes[index.key] = index
                storedSourceBytes[index.key.contentID] = bytes
                storedNamePosting.add(index, for: index.key)
                storedContainsErrorNodes[index.key] = containsErrorNodes
            }
        }
    }
}

struct SnapshotView: Sendable {
    let store: ProjectIndexStore
    let manifest: SnapshotManifest
    let stats: IndexStats
    let analysisProfile: AnalysisProfile
    let extractor: any LanguageExtractor
    let contentIndexes: [ContentIndexKey: ContentIndex]
    let contentKeysByPath: [PathID: ContentIndexKey]
    let moduleMap: ModuleMap
    let storeState: ProjectIndexStore.State

    init(
        store: ProjectIndexStore,
        manifest: SnapshotManifest,
        stats: IndexStats,
        analysisProfile: AnalysisProfile,
        extractor: any LanguageExtractor
    ) {
        precondition(extractor.language == analysisProfile.language)
        self.store = store
        self.manifest = manifest
        self.stats = stats
        self.analysisProfile = analysisProfile
        self.extractor = extractor
        storeState = store.snapshot()
        var contentIndexes: [ContentIndexKey: ContentIndex] = [:]
        var contentKeysByPath: [PathID: ContentIndexKey] = [:]
        for file in manifest.files {
            guard let mode = LanguageMode.classify(
                path: store.paths.resolve(file.pathID),
                language: analysisProfile.language
            ) else { continue }
            let key = ContentIndexKey(
                contentID: file.contentID,
                languageMode: mode,
                grammarVersion: extractor.grammarVersion,
                extractorVersion: extractor.extractorVersion
            )
            guard let index = storeState.contentIndexes[key] else { continue }
            contentIndexes[key] = index
            contentKeysByPath[file.pathID] = key
        }
        self.contentIndexes = contentIndexes
        self.contentKeysByPath = contentKeysByPath
        moduleMap = ModuleMap(
            manifest: manifest,
            language: analysisProfile.language,
            indexes: contentIndexes,
            bytesByContent: storeState.sourceBytesByContent,
            names: store.names,
            paths: store.paths
        )
    }

    init(
        reprofiling view: SnapshotView,
        analysisProfile: AnalysisProfile
    ) {
        store = view.store
        manifest = view.manifest
        stats = IndexStats(
            fileCount: view.stats.fileCount,
            uniqueContentCount: view.stats.uniqueContentCount,
            scopeCount: view.stats.scopeCount,
            bindingCount: view.stats.bindingCount,
            symbolCount: view.stats.symbolCount,
            callCount: view.stats.callCount,
            importCount: view.stats.importCount,
            elapsedMilliseconds: 0,
            filesWithErrorNodes: view.stats.filesWithErrorNodes,
            reusedCount: view.stats.uniqueContentCount,
            extractedCount: 0
        )
        self.analysisProfile = analysisProfile
        extractor = view.extractor
        contentIndexes = view.contentIndexes
        contentKeysByPath = view.contentKeysByPath
        moduleMap = view.moduleMap
        storeState = view.storeState
    }
}
