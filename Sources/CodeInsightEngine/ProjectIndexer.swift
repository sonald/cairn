import CodeInsightCore
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
}

public struct ProjectIndexer: Sendable {
    public static let skippedDirectories: Set<String> = [
        ".git", "target", "node_modules", ".build", "venv", ".venv",
        "__pycache__", "dist", "build",
    ]

    private let parallelism: Int

    public init() {
        parallelism = max(1, ProcessInfo.processInfo.activeProcessorCount)
    }

    init(parallelism: Int) {
        self.parallelism = max(1, parallelism)
    }

    public func index(root: URL) throws -> EngineSession {
        let startedAt = Date()
        let root = root.standardizedFileURL
        let files = try rustFiles(in: root).sorted {
            relativePath(of: $0, under: root) < relativePath(of: $1, under: root)
        }
        let names = Interner<NameID>()
        let paths = Interner<PathID>()
        let strings = Interner<StringID>()

        var occurrences: [FileOccurrence] = []
        var indexes: [ContentIndexKey: ContentIndex] = [:]
        var bytesByContent: [ContentID: [UInt8]] = [:]
        var hasErrors: [ContentIndexKey: Bool] = [:]
        var fileInputs: [FileInput] = []
        var uniqueInputs: [ExtractionInput] = []
        var seenKeys: Set<ContentIndexKey> = []

        for fileURL in files {
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            let bytes = [UInt8](data)
            let contentID = ContentID.sha256(of: data)
            let key = ContentIndexKey(
                contentID: contentID,
                languageMode: LanguageMode(language: .rust),
                grammarVersion: RustExtractorInfo.grammarVersion,
                extractorVersion: RustExtractorInfo.extractorVersion
            )
            fileInputs.append(FileInput(
                relativePath: relativePath(of: fileURL, under: root),
                contentID: contentID,
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

        // Each worker owns its parser and temporary interners. Global IDs are
        // assigned only here, in first-path order, so scheduling cannot change
        // NameID/StringID allocation.
        for draft in try extract(uniqueInputs) {
            indexes[draft.index.key] = remap(
                draft.index,
                localNames: draft.names,
                localStrings: draft.strings,
                names: names,
                strings: strings
            )
            hasErrors[draft.index.key] = draft.containsErrorNodes
            bytesByContent[draft.index.key.contentID] = draft.bytes
        }

        for (offset, input) in fileInputs.enumerated() {
            guard let occurrenceID = UInt32(exactly: offset) else {
                preconditionFailure("File count exceeds UInt32")
            }
            occurrences.append(FileOccurrence(
                occurrenceID: FileOccurrenceID(rawValue: occurrenceID),
                pathID: paths.intern(input.relativePath),
                contentID: input.contentID,
                detectedLanguage: .rust,
                sourceKind: .untracked,
                fileMode: .regular,
                size: input.size
            ))
        }

        let manifest = SnapshotManifest(
            snapshotID: SnapshotID(rawValue: UUID()),
            files: occurrences
        )
        let moduleMap = ModuleMap(
            manifest: manifest,
            indexes: indexes,
            bytesByContent: bytesByContent,
            names: names,
            paths: paths
        )
        let stats = IndexStats(
            fileCount: occurrences.count,
            uniqueContentCount: indexes.count,
            scopeCount: indexes.values.reduce(0) { $0 + $1.scopes.count },
            bindingCount: indexes.values.reduce(0) { $0 + $1.bindings.count },
            symbolCount: indexes.values.reduce(0) { $0 + $1.symbols.count },
            callCount: indexes.values.reduce(0) { $0 + $1.calls.count },
            importCount: indexes.values.reduce(0) { $0 + $1.imports.count },
            elapsedMilliseconds: UInt64(max(0, Date().timeIntervalSince(startedAt) * 1_000)),
            filesWithErrorNodes: occurrences.reduce(0) { count, file in
                let key = ContentIndexKey(
                    contentID: file.contentID,
                    languageMode: LanguageMode(language: .rust),
                    grammarVersion: RustExtractorInfo.grammarVersion,
                    extractorVersion: RustExtractorInfo.extractorVersion
                )
                return count + (hasErrors[key] == true ? 1 : 0)
            }
        )
        let profile = AnalysisProfile.placeholder(
            language: .rust,
            root: paths.intern(".")
        )
        return EngineSession(
            manifest: manifest,
            contentIndexes: indexes,
            stats: stats,
            names: names,
            paths: paths,
            strings: strings,
            analysisProfile: profile,
            moduleMap: moduleMap,
            sourceBytesByContent: bytesByContent
        )
    }

    private func rustFiles(in root: URL) throws -> [URL] {
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
                result += try rustFiles(in: url)
            } else if values.isRegularFile == true && url.pathExtension == "rs" {
                result.append(url)
            }
        }
        return result
    }

    private func relativePath(of file: URL, under root: URL) -> String {
        file.standardizedFileURL.pathComponents
            .dropFirst(root.pathComponents.count)
            .joined(separator: "/")
    }

    private func extract(_ inputs: [ExtractionInput]) throws -> [ExtractionDraft] {
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
                                let result = try RustExtractor().extractWithDiagnostics(
                                    bytes: input.bytes,
                                    key: input.key,
                                    interner: ExtractionInterners(
                                        names: names,
                                        strings: strings
                                    )
                                )
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
            calls: index.calls.map {
                UnresolvedCall(
                    regionID: $0.regionID,
                    nameID: name($0.nameID),
                    range: $0.range,
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
        let size: UInt64
    }

    private struct ExtractionInput: Sendable {
        let order: Int
        let bytes: [UInt8]
        let key: ContentIndexKey
    }

    private struct ExtractionDraft: Sendable {
        let order: Int
        let bytes: [UInt8]
        let index: ContentIndex
        let names: Interner<NameID>
        let strings: Interner<StringID>
        let containsErrorNodes: Bool
    }
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
