import CodeInsightCore
import CodeInsightGit
import Foundation

public final class ProjectIndexStore: @unchecked Sendable {
    struct State: Sendable {
        let contentIndexes: [ContentIndexKey: ContentIndex]
        let namePosting: NamePosting
        let containsErrorNodes: [ContentIndexKey: Bool]
    }

    let names = Interner<NameID>()
    let paths = Interner<PathID>()
    let strings = Interner<StringID>()
    /// Shared with every store of the application; holds no bytes of its own
    /// that a session cannot read again from its snapshot.
    let sourceBytes: SourceByteCache

    private let lock = NSLock()
    private var storedContentIndexes: [ContentIndexKey: ContentIndex] = [:]
    /// Contents this store serves as source or configuration bytes.
    private var storedSourceContentIDs: Set<ContentID> = []
    private var storedNamePosting = NamePosting(indexes: [:])
    private var storedContainsErrorNodes: [ContentIndexKey: Bool] = [:]

    public init(sourceBytes: SourceByteCache = SourceByteCache()) {
        self.sourceBytes = sourceBytes
    }

    /// Content identities this store serves as source bytes, whether or not
    /// the cache holds them now. Diagnostic and regression surface for
    /// store lifetime boundaries.
    public func retainedContentIDs() -> Set<ContentID> {
        lock.withLock { storedSourceContentIDs }
    }

    /// Bytes the shared cache holds now for this store's contents. Diagnostic.
    public func retainedContentByteCount() -> Int {
        sourceBytes.byteCount(of: retainedContentIDs())
    }

    func snapshot() -> State {
        lock.withLock {
            State(
                contentIndexes: storedContentIndexes,
                namePosting: storedNamePosting,
                containsErrorNodes: storedContainsErrorNodes
            )
        }
    }

    package var contentIndexes: [ContentIndexKey: ContentIndex] {
        lock.withLock { storedContentIndexes }
    }

    var namePosting: NamePosting {
        lock.withLock { storedNamePosting }
    }

    /// Registers source contents; `cachingBytes` also offers the bytes to
    /// the shared cache (false when they went through it already).
    func insert(_ bytesByContent: [ContentID: [UInt8]], cachingBytes: Bool = true) {
        if cachingBytes {
            for (contentID, bytes) in bytesByContent { sourceBytes.insert(bytes, for: contentID) }
        }
        lock.withLock { storedSourceContentIDs.formUnion(bytesByContent.keys) }
    }

    func insert(
        _ index: ContentIndex,
        bytes: [UInt8],
        containsErrorNodes: Bool
    ) {
        insert([(index, bytes, containsErrorNodes)])
    }

    func insert(_ entries: [(ContentIndex, [UInt8], Bool)], cachingBytes: Bool = true) {
        lock.withLock {
            for (index, _, containsErrorNodes) in entries {
                guard storedContentIndexes[index.key] == nil else { continue }
                storedContentIndexes[index.key] = index
                storedSourceContentIDs.insert(index.key.contentID)
                storedNamePosting.add(index, for: index.key)
                storedContainsErrorNodes[index.key] = containsErrorNodes
            }
        }
        if cachingBytes {
            for (index, bytes, _) in entries { sourceBytes.insert(bytes, for: index.key.contentID) }
        }
    }
}

/// Where a view reads its source bytes again.
struct SourceReader: Sendable {
    /// The reader itself guarantees the bytes have the content ID they are
    /// read for, so the cache does not hash them again: a commit read by
    /// object ID (libgit2 checks the object hash), a worktree read (the
    /// snapshot checks the SHA-256).
    let vouchesIdentity: Bool
    let read: @Sendable (String) throws -> [UInt8]

    static func reading(_ snapshot: any Snapshot) -> SourceReader {
        // ponytail: only the two Git snapshot types are known to check what
        // they read; any other snapshot (a wrapper, a test double) is hashed.
        SourceReader(vouchesIdentity: snapshot is CommitSnapshot || snapshot is WorktreeSnapshot) {
            try snapshot.readBytes(path: $0)
        }
    }

    /// For views built without a snapshot; every read misses.
    static let none = SourceReader(vouchesIdentity: false) { path in throw GitError.missingPath(path) }

    func bytes(for contentID: ContentID, path: @autoclosure () -> String, in cache: SourceByteCache) throws -> [UInt8] {
        try cache.bytes(for: contentID, verifying: !vouchesIdentity) { try read(path()) }
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
    /// This unit's sources, indexed or not.
    let activePathIDs: Set<PathID>
    let moduleMap: ModuleMap
    let storeState: ProjectIndexStore.State
    let sourceReader: SourceReader
    /// One path per source content of the snapshot, to read it again by.
    private let sourcePathByContent: [ContentID: PathID]

    /// `unitFiles` are this unit's sources in manifest order, already split
    /// among the language's units (`ProjectIndexer.unitSessions`). Omitted,
    /// the unit is alone and holds every source under its root.
    init(
        store: ProjectIndexStore,
        manifest: SnapshotManifest,
        stats: IndexStats,
        analysisProfile: AnalysisProfile,
        extractor: any LanguageExtractor,
        unitFiles: [FileOccurrence]? = nil,
        sourceReader: SourceReader = .none,
        sourcePaths: [ContentID: PathID]? = nil
    ) throws {
        precondition(extractor.language == analysisProfile.language)
        self.store = store
        self.manifest = manifest
        self.stats = stats
        self.analysisProfile = analysisProfile
        self.extractor = extractor
        self.sourceReader = sourceReader
        storeState = store.snapshot()
        let sourcePathByContent = sourcePaths ?? Self.sourcePaths(manifest: manifest, store: store)
        self.sourcePathByContent = sourcePathByContent
        let rootPath = store.paths.resolve(analysisProfile.projectRoot)
        let activeFiles = unitFiles ?? manifest.files.filter { file in
            let path = store.paths.resolve(file.pathID)
            return LanguageMode.classify(
                path: path,
                language: analysisProfile.language
            ) != nil && isWithin(root: rootPath, path: path)
        }
        activePathIDs = Set(activeFiles.map(\.pathID))
        let activeManifest = SnapshotManifest(
            snapshotID: manifest.snapshotID,
            files: activeFiles,
            ruleExcludedPathCount: manifest.ruleExcludedPathCount,
            nonSourcePathCount: manifest.nonSourcePathCount,
            unreadablePathCount: manifest.unreadablePathCount
        )
        var contentIndexes: [ContentIndexKey: ContentIndex] = [:]
        var contentKeysByPath: [PathID: ContentIndexKey] = [:]
        for file in activeFiles {
            let path = store.paths.resolve(file.pathID)
            guard let mode = LanguageMode.classify(
                path: path,
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
        let bytes = { [sourcePathByContent] (contentID: ContentID) throws -> [UInt8]? in
            try Self.sourceBytes(for: contentID, store: store, reader: sourceReader, paths: sourcePathByContent)
        }
        moduleMap = try ModuleMap(
            manifest: activeManifest,
            language: analysisProfile.language,
            indexes: contentIndexes,
            bytes: bytes,
            names: store.names,
            paths: store.paths,
            projectRoot: rootPath,
            goModules: analysisProfile.language == .go
                ? Self.goModules(manifest: manifest, paths: store.paths, root: rootPath, bytes: bytes)
                : [:]
        )
    }

    /// One path per source content of the manifest; every unit view of a
    /// snapshot shares the one map.
    static func sourcePaths(manifest: SnapshotManifest, store: ProjectIndexStore) -> [ContentID: PathID] {
        let sourceContentIDs = store.retainedContentIDs()
        var paths: [ContentID: PathID] = [:]
        for file in manifest.files where sourceContentIDs.contains(file.contentID) {
            if paths[file.contentID] == nil { paths[file.contentID] = file.pathID }
        }
        return paths
    }

    /// The bytes of a source content of this snapshot: nil when no source
    /// file of the snapshot has it; throws when it cannot be read back with
    /// the same identity.
    func sourceBytes(for contentID: ContentID) throws -> [UInt8]? {
        try Self.sourceBytes(for: contentID, store: store, reader: sourceReader, paths: sourcePathByContent)
    }

    private static func sourceBytes(
        for contentID: ContentID,
        store: ProjectIndexStore,
        reader: SourceReader,
        paths: [ContentID: PathID]
    ) throws -> [UInt8]? {
        guard let pathID = paths[contentID] else { return nil }
        // A hit does not resolve the path.
        return try reader.bytes(for: contentID, path: store.paths.resolve(pathID), in: store.sourceBytes)
    }

    /// The unit's `go.mod` directories (relative to `root`, `.` for the root)
    /// and the module paths they declare.
    private static func goModules(
        manifest: SnapshotManifest,
        paths: Interner<PathID>,
        root: String,
        bytes: (ContentID) throws -> [UInt8]?
    ) throws -> [String: String] {
        var modules: [String: String] = [:]
        for file in manifest.files {
            let path = paths.resolve(file.pathID)
            guard path == "go.mod" || path.hasSuffix("/go.mod"), isWithin(root: root, path: path),
                  let module = try bytes(file.contentID).flatMap(ModuleMap.goModulePath(inGoMod:))
            else { continue }
            var directory = String(path.dropLast("go.mod".count).dropLast())
            if root != ".", !root.isEmpty {
                directory = directory == root ? "" : String(directory.dropFirst(root.count + 1))
            }
            modules[directory.isEmpty ? "." : directory] = module
        }
        return modules
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
        activePathIDs = view.activePathIDs
        moduleMap = view.moduleMap
        storeState = view.storeState
        sourceReader = view.sourceReader
        sourcePathByContent = view.sourcePathByContent
    }
}
