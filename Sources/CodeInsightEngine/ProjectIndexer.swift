import CodeInsightCore
import CodeInsightGit
import CodeInsightPythonExtractor
import CodeInsightRustExtractor
import Foundation

public struct IndexStats: Sendable {
    public let fileCount: Int
    public let uniqueContentCount: Int
    public let scopeCount: Int
    public let bindingCount: Int
    public let symbolCount: Int
    public let callCount: Int
    public let importCount: Int
    public let elapsedMilliseconds: UInt64
    public let filesWithErrorNodes: Int
    public let reusedCount: Int
    public let extractedCount: Int
}

public struct ProjectIndexer: Sendable {
    public struct PreparedSnapshot: Sendable {
        public let cachedSession: EngineSession
        public var pendingExtractionCount: Int { missingInputs.count }

        fileprivate let store: ProjectIndexStore
        fileprivate let manifest: SnapshotManifest
        fileprivate let analysisProfile: AnalysisProfile
        fileprivate let extractor: any LanguageExtractor
        fileprivate let missingInputs: [ExtractionInput]
        fileprivate let deferredDrafts: [ExtractionDraft]
        fileprivate let cache: IndexCache?
        fileprivate let reusedCount: Int
        fileprivate let startedAt: Date
    }

    public static let skippedDirectories: Set<String> = [
        ".git", "target", "node_modules", ".build", "venv", ".venv",
        "__pycache__", "dist", "build",
    ]

    private let parallelism: Int
    private let cache: IndexCache?
    private let extractorOverride: (any LanguageExtractor)?

    public init() {
        parallelism = max(1, ProcessInfo.processInfo.activeProcessorCount)
        cache = nil
        extractorOverride = nil
    }

    public init(persistingProjectAt root: URL) {
        parallelism = max(1, ProcessInfo.processInfo.activeProcessorCount)
        cache = try? IndexCache(projectURL: root)
        extractorOverride = nil
    }

    init(
        parallelism: Int,
        cache: IndexCache? = nil,
        extractor: (any LanguageExtractor)? = nil
    ) {
        self.parallelism = max(1, parallelism)
        self.cache = cache
        extractorOverride = extractor
    }

    public func flushPersistentWrites() {
        cache?.flush()
    }

    public func index(root: URL) throws -> EngineSession {
        try index(root: root, language: .rust)
    }

    public func index(root: URL, language: LanguageID) throws -> EngineSession {
        let extractor = try languageExtractor(for: language)
        let startedAt = Date()
        let root = root.standardizedFileURL
        let files = try sourceFiles(in: root, language: language).sorted {
            relativePath(of: $0, under: root) < relativePath(of: $1, under: root)
        }
        let store = ProjectIndexStore()

        var occurrences: [FileOccurrence] = []
        var hasErrors: [ContentIndexKey: Bool] = [:]
        var fileInputs: [FileInput] = []
        var uniqueInputs: [ExtractionInput] = []
        var seenKeys: Set<ContentIndexKey> = []

        for fileURL in files {
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            let bytes = [UInt8](data)
            let contentID = ContentID.sha256(of: data)
            let relativePath = relativePath(of: fileURL, under: root)
            guard let mode = LanguageMode.classify(path: relativePath, language: language)
            else { continue }
            let key = try contentKey(
                contentID: contentID,
                mode: mode,
                extractor: extractor
            )
            fileInputs.append(FileInput(
                relativePath: relativePath,
                contentID: contentID,
                key: key,
                size: UInt64(data.count)
            ))
            if seenKeys.insert(key).inserted {
                uniqueInputs.append(ExtractionInput(
                    order: uniqueInputs.count,
                    bytes: bytes,
                    key: key
                ))
            }
        }

        var cachedDrafts: [ExtractionDraft] = []
        var extractionInputs: [ExtractionInput] = []
        let cachedByOrder = Dictionary(uniqueKeysWithValues: loadCachedDrafts(
            for: uniqueInputs
        ).map { ($0.order, $0) })
        for input in uniqueInputs {
            if let draft = cachedByOrder[input.order] {
                cachedDrafts.append(draft)
            } else {
                extractionInputs.append(input)
            }
        }
        let extractedDrafts = try extract(extractionInputs, using: extractor)
        let drafts = (cachedDrafts + extractedDrafts).sorted { $0.order < $1.order }
        // Each worker owns its parser and temporary interners. Global IDs are
        // assigned only here, in first-path order, so scheduling and cache hits
        // cannot change NameID/StringID allocation.
        store.insert(remap(drafts, into: store))
        for draft in drafts {
            hasErrors[draft.index.key] = draft.containsErrorNodes
        }
        persist(extractedDrafts)

        for (offset, input) in fileInputs.enumerated() {
            guard let occurrenceID = UInt32(exactly: offset) else {
                preconditionFailure("File count exceeds UInt32")
            }
            occurrences.append(FileOccurrence(
                occurrenceID: FileOccurrenceID(rawValue: occurrenceID),
                pathID: store.paths.intern(input.relativePath),
                contentID: input.contentID,
                detectedLanguage: input.key.languageMode.language,
                sourceKind: .untracked,
                fileMode: .regular,
                size: input.size
            ))
        }

        let manifest = SnapshotManifest(
            snapshotID: SnapshotID(rawValue: UUID()),
            files: occurrences
        )
        let indexes = store.contentIndexes
        let stats = IndexStats(
            fileCount: occurrences.count,
            uniqueContentCount: indexes.count,
            scopeCount: indexes.values.reduce(0) { $0 + $1.scopes.count },
            bindingCount: indexes.values.reduce(0) { $0 + $1.bindings.count },
            symbolCount: indexes.values.reduce(0) { $0 + $1.symbols.count },
            callCount: indexes.values.reduce(0) { $0 + $1.calls.count },
            importCount: indexes.values.reduce(0) { $0 + $1.imports.count },
            elapsedMilliseconds: UInt64(max(0, Date().timeIntervalSince(startedAt) * 1_000)),
            filesWithErrorNodes: fileInputs.reduce(0) { count, input in
                count + (hasErrors[input.key] == true ? 1 : 0)
            },
            reusedCount: cachedDrafts.count,
            extractedCount: extractedDrafts.count
        )
        let profile = try analysisProfile(
            root: root,
            language: language,
            projectRoot: store.paths.intern(".")
        )
        let snapshotView = SnapshotView(
            store: store,
            manifest: manifest,
            stats: stats,
            analysisProfile: profile,
            extractor: extractor
        )
        return EngineSession(
            store: store,
            snapshotView: snapshotView
        )
    }

    /// Builds a manifest and a queryable cached-only session. S4 can publish
    /// `cachedSession` for first paint, then run `completeSnapshot` off-thread.
    public func prepareSnapshot(
        _ snapshot: any Snapshot,
        into store: ProjectIndexStore
    ) throws -> PreparedSnapshot {
        try prepareSnapshot(snapshot, into: store, language: .rust)
    }

    public func prepareSnapshot(
        _ snapshot: any Snapshot,
        into store: ProjectIndexStore,
        language: LanguageID
    ) throws -> PreparedSnapshot {
        let extractor = try languageExtractor(for: language)
        try Task.checkCancellation()
        let startedAt = Date()
        let stored = store.snapshot()
        let files = snapshot.listFiles().sorted { $0.path < $1.path }
        var occurrences: [FileOccurrence] = []
        var newInputs: [ExtractionInput] = []
        var missingKeys: Set<ContentIndexKey> = []
        var reusedKeys: Set<ContentIndexKey> = []
        var capturedBytes: [ContentID: [UInt8]] = [:]

        for (offset, file) in files.enumerated() {
            try Task.checkCancellation()
            let bytes = try snapshot.readBytes(path: file.path)
            capturedBytes[file.contentID] = bytes
            let mode = LanguageMode.classify(path: file.path, language: language)
            guard let occurrenceID = UInt32(exactly: offset) else {
                preconditionFailure("File count exceeds UInt32")
            }
            occurrences.append(FileOccurrence(
                occurrenceID: FileOccurrenceID(rawValue: occurrenceID),
                pathID: store.paths.intern(file.path),
                contentID: file.contentID,
                detectedLanguage: mode?.language,
                sourceKind: snapshot.sourceKind,
                fileMode: file.fileMode,
                size: UInt64(bytes.count)
            ))
            guard let mode, file.fileMode != .lfsPointer else { continue }
            let key = try contentKey(
                contentID: file.contentID,
                mode: mode,
                extractor: extractor
            )
            if stored.contentIndexes[key] != nil {
                reusedKeys.insert(key)
            } else if missingKeys.insert(key).inserted {
                newInputs.append(ExtractionInput(
                    order: newInputs.count,
                    bytes: bytes,
                    key: key
                ))
            }
        }
        try Task.checkCancellation()
        var missingInputs: [ExtractionInput] = []
        var leadingDrafts: [ExtractionDraft] = []
        var deferredDrafts: [ExtractionDraft] = []
        var canInstallCachedDraft = true
        var readyReusedKeys = reusedKeys
        let cachedByOrder = Dictionary(uniqueKeysWithValues: loadCachedDrafts(
            for: newInputs
        ).map { ($0.order, $0) })
        for input in newInputs {
            if let draft = cachedByOrder[input.order] {
                reusedKeys.insert(input.key)
                if canInstallCachedDraft {
                    leadingDrafts.append(draft)
                    readyReusedKeys.insert(input.key)
                } else {
                    deferredDrafts.append(draft)
                }
            } else {
                canInstallCachedDraft = false
                missingInputs.append(input)
            }
        }
        store.insert(capturedBytes)
        store.insert(remap(leadingDrafts, into: store))
        let storedAfterCache = store.snapshot()

        let manifest = SnapshotManifest(
            snapshotID: snapshot.snapshotID,
            files: occurrences
        )
        let analysisProfile = try analysisProfile(
            snapshot: snapshot,
            language: language,
            projectRoot: store.paths.intern(".")
        )
        let stats = try snapshotStats(
            manifest: manifest,
            paths: store.paths,
            stored: storedAfterCache,
            extractor: extractor,
            reusedCount: readyReusedKeys.count,
            extractedCount: 0,
            startedAt: startedAt
        )
        let view = SnapshotView(
            store: store,
            manifest: manifest,
            stats: stats,
            analysisProfile: analysisProfile,
            extractor: extractor
        )
        return PreparedSnapshot(
            cachedSession: EngineSession(store: store, snapshotView: view),
            store: store,
            manifest: manifest,
            analysisProfile: analysisProfile,
            extractor: extractor,
            missingInputs: missingInputs,
            deferredDrafts: deferredDrafts,
            cache: cache,
            reusedCount: reusedKeys.count,
            startedAt: startedAt
        )
    }

    public func completeSnapshot(
        _ prepared: PreparedSnapshot
    ) throws -> EngineSession {
        try Task.checkCancellation()
        let extractedDrafts = try extract(
            prepared.missingInputs,
            using: prepared.extractor
        )
        let drafts = (prepared.deferredDrafts + extractedDrafts)
            .sorted { $0.order < $1.order }
        // Extraction is pure and completes before the shared store changes;
        // failed work therefore leaves no partially extracted snapshot behind.
        try Task.checkCancellation()
        prepared.store.insert(remap(drafts, into: prepared.store))
        persist(extractedDrafts, to: prepared.cache)
        let stored = prepared.store.snapshot()
        let stats = try snapshotStats(
            manifest: prepared.manifest,
            paths: prepared.store.paths,
            stored: stored,
            extractor: prepared.extractor,
            reusedCount: prepared.reusedCount,
            extractedCount: extractedDrafts.count,
            startedAt: prepared.startedAt
        )
        let view = SnapshotView(
            store: prepared.store,
            manifest: prepared.manifest,
            stats: stats,
            analysisProfile: prepared.analysisProfile,
            extractor: prepared.extractor
        )
        return EngineSession(store: prepared.store, snapshotView: view)
    }

    public func indexSnapshot(
        _ snapshot: any Snapshot,
        into store: ProjectIndexStore
    ) throws -> EngineSession {
        try indexSnapshot(snapshot, into: store, language: .rust)
    }

    public func indexSnapshot(
        _ snapshot: any Snapshot,
        into store: ProjectIndexStore,
        language: LanguageID
    ) throws -> EngineSession {
        try completeSnapshot(prepareSnapshot(
            snapshot,
            into: store,
            language: language
        ))
    }

    private func snapshotStats(
        manifest: SnapshotManifest,
        paths: Interner<PathID>,
        stored: ProjectIndexStore.State,
        extractor: any LanguageExtractor,
        reusedCount: Int,
        extractedCount: Int,
        startedAt: Date
    ) throws -> IndexStats {
        var activeFiles: [(FileOccurrence, ContentIndexKey)] = []
        for file in manifest.files {
            guard file.detectedLanguage == extractor.language,
                  let mode = LanguageMode.classify(
                    path: paths.resolve(file.pathID),
                    language: extractor.language
                  )
            else { continue }
            activeFiles.append((file, try contentKey(
                contentID: file.contentID,
                mode: mode,
                extractor: extractor
            )))
        }
        let keys = Set(activeFiles.map(\.1))
        let indexes = keys.compactMap { stored.contentIndexes[$0] }
        return IndexStats(
            fileCount: activeFiles.count,
            uniqueContentCount: indexes.count,
            scopeCount: indexes.reduce(0) { $0 + $1.scopes.count },
            bindingCount: indexes.reduce(0) { $0 + $1.bindings.count },
            symbolCount: indexes.reduce(0) { $0 + $1.symbols.count },
            callCount: indexes.reduce(0) { $0 + $1.calls.count },
            importCount: indexes.reduce(0) { $0 + $1.imports.count },
            elapsedMilliseconds: UInt64(max(
                0,
                Date().timeIntervalSince(startedAt) * 1_000
            )),
            filesWithErrorNodes: activeFiles.reduce(0) { count, input in
                count + (stored.containsErrorNodes[input.1] == true
                    ? 1 : 0)
            },
            reusedCount: reusedCount,
            extractedCount: extractedCount
        )
    }

    private func sourceFiles(
        in root: URL,
        language: LanguageID
    ) throws -> [URL] {
        var result: [URL] = []
        for url in try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        ) {
            if url.lastPathComponent == ".DS_Store" { continue }
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            ])
            if values.isDirectory == true {
                guard values.isSymbolicLink != true,
                      !Self.skippedDirectories.contains(url.lastPathComponent)
                else { continue }
                result += try sourceFiles(in: url, language: language)
            } else if values.isRegularFile == true,
                      LanguageMode.classify(path: url.path, language: language) != nil
            {
                result.append(url)
            }
        }
        return result
    }

    private func languageExtractor(
        for language: LanguageID
    ) throws -> any LanguageExtractor {
        if let extractorOverride {
            guard extractorOverride.language == language else {
                throw invalidIdentity(
                    "Requested \(String(describing: language)) does not match extractor "
                        + "\(String(describing: extractorOverride.language))"
                )
            }
            return extractorOverride
        }
        switch language {
        case .rust:
            return RustExtractor()
        case .python:
            return PythonExtractor()
        case .typescript, .javascript:
            throw unsupportedLanguage(language)
        }
    }

    private func contentKey(
        contentID: ContentID,
        mode: LanguageMode,
        extractor: any LanguageExtractor
    ) throws -> ContentIndexKey {
        guard mode.language == extractor.language else {
            throw invalidIdentity(
                "Mode \(String(describing: mode.language)) does not match extractor "
                    + "\(String(describing: extractor.language))"
            )
        }
        return ContentIndexKey(
            contentID: contentID,
            languageMode: mode,
            grammarVersion: extractor.grammarVersion,
            extractorVersion: extractor.extractorVersion
        )
    }

    private func analysisProfile(
        root: URL,
        language: LanguageID,
        projectRoot: PathID
    ) throws -> AnalysisProfile {
        let profile: AnalysisProfile
        switch language {
        case .rust:
            profile = ProfileDetector.detect(root: root, projectRoot: projectRoot)
        case .python:
            profile = ProfileDetector.detect(
                projectURL: root,
                language: language,
                projectRoot: projectRoot
            )
        case .typescript, .javascript:
            throw unsupportedLanguage(language)
        }
        return try validated(profile, for: language)
    }

    private func analysisProfile(
        snapshot: any Snapshot,
        language: LanguageID,
        projectRoot: PathID
    ) throws -> AnalysisProfile {
        let profile: AnalysisProfile
        switch language {
        case .rust:
            profile = ProfileDetector.detect(
                snapshot: snapshot,
                projectRoot: projectRoot
            )
        case .python:
            profile = ProfileDetector.detect(
                snapshot: snapshot,
                language: language,
                projectRoot: projectRoot
            )
        case .typescript, .javascript:
            throw unsupportedLanguage(language)
        }
        return try validated(profile, for: language)
    }

    private func validated(
        _ profile: AnalysisProfile,
        for language: LanguageID
    ) throws -> AnalysisProfile {
        guard profile.language == language else {
            throw invalidIdentity(
                "Profile \(String(describing: profile.language)) does not match requested "
                    + "\(String(describing: language))"
            )
        }
        return profile
    }

    private func unsupportedLanguage(_ language: LanguageID) -> CocoaError {
        CocoaError(.featureUnsupported, userInfo: [
            NSLocalizedFailureReasonErrorKey:
                "ProjectIndexer does not support \(String(describing: language))",
        ])
    }

    private func invalidIdentity(_ reason: String) -> CocoaError {
        CocoaError(.coderInvalidValue, userInfo: [
            NSLocalizedFailureReasonErrorKey: reason,
        ])
    }

    private func relativePath(of file: URL, under root: URL) -> String {
        file.standardizedFileURL.pathComponents
            .dropFirst(root.pathComponents.count)
            .joined(separator: "/")
    }

    private func loadCachedDrafts(
        for inputs: [ExtractionInput]
    ) -> [ExtractionDraft] {
        guard let cache else { return [] }
        let payloads = cache.payloads(for: inputs.map { cacheKey(for: $0.key) })
        let result = BlockingResult<[ExtractionDraft]>()
        let operation: @Sendable () async -> Void = {
            var drafts: [ExtractionDraft] = []
            for start in stride(from: 0, to: inputs.count, by: parallelism) {
                let end = min(start + parallelism, inputs.count)
                drafts += await withTaskGroup(of: ExtractionDraft?.self) { group in
                    for input in inputs[start..<end] {
                        group.addTask {
                            guard let payload = payloads[cacheKey(for: input.key)] else {
                                return nil
                            }
                            do {
                                return try ContentIndexDraftCodec.decode(
                                    payload,
                                    order: input.order,
                                    bytes: input.bytes,
                                    expectedKey: input.key
                                )
                            } catch {
                                cache.removePayload(for: cacheKey(for: input.key))
                                return nil
                            }
                        }
                    }
                    return await group.reduce(into: []) { drafts, draft in
                        if let draft { drafts.append(draft) }
                    }
                }
            }
            result.complete(.success(drafts.sorted { $0.order < $1.order }))
        }
        if #available(macOS 15.4, *) {
            Task.detached(
                executorPreference: DispatchQueue.global(qos: .userInitiated),
                operation: operation
            )
        } else {
            Task.detached(operation: operation)
        }
        return (try? result.wait().get()) ?? []
    }

    private func remap(
        _ drafts: [ExtractionDraft],
        into store: ProjectIndexStore
    ) -> [(ContentIndex, [UInt8], Bool)] {
        drafts.map { draft in
            (
                remap(
                    draft.index,
                    localNames: draft.names,
                    localStrings: draft.strings,
                    names: store.names,
                    strings: store.strings
                ),
                draft.bytes,
                draft.containsErrorNodes
            )
        }
    }

    private func persist(
        _ drafts: [ExtractionDraft],
        to cache: IndexCache? = nil
    ) {
        let cache = cache ?? self.cache
        guard let cache else { return }
        cache.store(drafts)
    }

    private func extract(
        _ inputs: [ExtractionInput],
        using extractor: any LanguageExtractor
    ) throws -> [ExtractionDraft] {
        guard inputs.allSatisfy({
            $0.key.languageMode.language == extractor.language
        }) else {
            throw invalidIdentity("Extraction input language does not match extractor")
        }
        let result = BlockingResult<[ExtractionDraft]>()
        let operation: @Sendable () async -> Void = {
            do {
                var drafts: [ExtractionDraft] = []
                for start in stride(from: 0, to: inputs.count, by: parallelism) {
                    let end = min(start + parallelism, inputs.count)
                    drafts += try await withThrowingTaskGroup(
                        of: ExtractionDraft.self
                    ) { group in
                        for input in inputs[start..<end] {
                            group.addTask {
                                let names = Interner<NameID>()
                                let strings = Interner<StringID>()
                                let result = try extractor.extractWithDiagnostics(
                                    bytes: input.bytes,
                                    key: input.key,
                                    interner: ExtractionInterners(
                                        names: names,
                                        strings: strings
                                    )
                                )
                                guard result.index.key == input.key else {
                                    throw invalidIdentity(
                                        "Extractor returned a different ContentIndexKey"
                                    )
                                }
                                return ExtractionDraft(
                                    order: input.order,
                                    bytes: input.bytes,
                                    index: result.index,
                                    names: names,
                                    strings: strings,
                                    containsErrorNodes: result.containsErrorNodes
                                )
                            }
                        }
                        return try await group.reduce(into: []) { $0.append($1) }
                    }
                }
                result.complete(.success(drafts.sorted { $0.order < $1.order }))
            } catch {
                result.complete(.failure(error))
            }
        }
        if #available(macOS 15.4, *) {
            Task.detached(
                executorPreference: DispatchQueue.global(qos: .userInitiated),
                operation: operation
            )
        } else {
            Task.detached(operation: operation)
        }
        return try result.wait().get()
    }

    private func remap(
        _ index: ContentIndex,
        localNames: Interner<NameID>,
        localStrings: Interner<StringID>,
        names: Interner<NameID>,
        strings: Interner<StringID>
    ) -> ContentIndex {
        var referencedNames = Set(index.bindings.map(\.localNameID))
        referencedNames.formUnion(index.bindings.compactMap { $0.targetHint?.nameID })
        referencedNames.formUnion(index.symbols.map(\.nameID))
        referencedNames.formUnion(index.implRelations.compactMap(\.traitNameID))
        referencedNames.formUnion(index.implRelations.map(\.typeNameID))
        referencedNames.formUnion(index.calls.map(\.nameID))
        referencedNames.formUnion(index.imports.compactMap(\.importedName))
        referencedNames.formUnion(index.imports.compactMap(\.localName))
        referencedNames.formUnion(index.exports.map(\.exportedName))

        let nameMap = Dictionary(uniqueKeysWithValues: referencedNames
            .sorted { $0.rawValue < $1.rawValue }
            .map { ($0, names.intern(localNames.resolve($0))) })
        let stringMap = Dictionary(uniqueKeysWithValues: Set(index.imports.map(\.moduleSpecifier))
            .sorted { $0.rawValue < $1.rawValue }
            .map { ($0, strings.intern(localStrings.resolve($0))) })

        func name(_ id: NameID) -> NameID { nameMap[id]! }
        func optionalName(_ id: NameID?) -> NameID? { id.map(name) }

        return ContentIndex(
            key: index.key,
            scopes: index.scopes,
            bindings: index.bindings.map {
                BindingRecord(
                    scopeID: $0.scopeID,
                    localNameID: name($0.localNameID),
                    space: $0.space,
                    kind: $0.kind,
                    declarationRange: $0.declarationRange,
                    targetHint: $0.targetHint.map {
                        UnresolvedSymbolRef(
                            nameID: name($0.nameID),
                            hintKind: $0.hintKind
                        )
                    }
                )
            },
            executableRegions: index.executableRegions,
            symbols: index.symbols.map {
                DeclarationFacet(
                    symbolGroupID: $0.symbolGroupID,
                    space: $0.space,
                    kind: $0.kind,
                    nameID: name($0.nameID),
                    range: $0.range,
                    nameRange: $0.nameRange,
                    parentFacetIndex: $0.parentFacetIndex,
                    signatureFingerprint: $0.signatureFingerprint,
                    bodyFingerprint: $0.bodyFingerprint
                )
            },
            implRelations: index.implRelations.map {
                ImplRelation(
                    implFacetIndex: $0.implFacetIndex,
                    traitNameID: optionalName($0.traitNameID),
                    traitNameRange: $0.traitNameRange,
                    typeNameID: name($0.typeNameID)
                )
            },
            calls: index.calls.map {
                UnresolvedCall(
                    regionID: $0.regionID,
                    nameID: name($0.nameID),
                    range: $0.range,
                    nameRange: $0.nameRange,
                    syntacticKind: $0.syntacticKind,
                    qualifierRange: $0.qualifierRange,
                    receiverRange: $0.receiverRange,
                    argumentCount: $0.argumentCount
                )
            },
            imports: index.imports.map {
                ImportBinding(
                    moduleSpecifier: stringMap[$0.moduleSpecifier]!,
                    importedName: optionalName($0.importedName),
                    localName: optionalName($0.localName),
                    kind: $0.kind,
                    flags: $0.flags,
                    scopeID: $0.scopeID,
                    range: $0.range
                )
            },
            exports: index.exports.map {
                ExportRecord(
                    exportedName: name($0.exportedName),
                    sourceBindingIndex: $0.sourceBindingIndex,
                    range: $0.range
                )
            },
            lineTable: index.lineTable
        )
    }

    private struct FileInput: Sendable {
        let relativePath: String
        let contentID: ContentID
        let key: ContentIndexKey
        let size: UInt64
    }

    fileprivate struct ExtractionInput: Sendable {
        let order: Int
        let bytes: [UInt8]
        let key: ContentIndexKey
    }

}

struct ExtractionDraft: Sendable {
    let order: Int
    let bytes: [UInt8]
    let index: ContentIndex
    let names: Interner<NameID>
    let strings: Interner<StringID>
    let containsErrorNodes: Bool
}

private final class BlockingResult<Value>: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Result<Value, Error>?

    func complete(_ result: Result<Value, Error>) {
        lock.withLock { self.result = result }
        semaphore.signal()
    }

    func wait() -> Result<Value, Error> {
        semaphore.wait()
        return lock.withLock { result! }
    }
}
