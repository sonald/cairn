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
    private static let skippedDirectories: Set<String> = [
        ".git", "target", "node_modules", ".build", "venv", ".venv",
        "__pycache__", "dist", "build",
    ]

    public init() {}

    public func index(root: URL) throws -> EngineSession {
        let startedAt = Date()
        let root = root.standardizedFileURL
        let files = try rustFiles(in: root).sorted {
            relativePath(of: $0, under: root) < relativePath(of: $1, under: root)
        }
        let names = Interner<NameID>()
        let paths = Interner<PathID>()
        let strings = Interner<StringID>()
        let interners = ExtractionInterners(names: names, strings: strings)
        let extractor = RustExtractor()

        var occurrences: [FileOccurrence] = []
        var indexes: [ContentIndexKey: ContentIndex] = [:]
        var bytesByContent: [ContentID: [UInt8]] = [:]
        var hasErrors: [ContentIndexKey: Bool] = [:]

        for (offset, fileURL) in files.enumerated() {
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            let bytes = [UInt8](data)
            let contentID = ContentID.sha256(of: data)
            let key = ContentIndexKey(
                contentID: contentID,
                languageMode: LanguageMode(language: .rust),
                grammarVersion: RustExtractorInfo.grammarVersion,
                extractorVersion: RustExtractorInfo.extractorVersion
            )
            if indexes[key] == nil {
                let result = try extractor.extractWithDiagnostics(
                    bytes: bytes,
                    key: key,
                    interner: interners
                )
                indexes[key] = result.index
                hasErrors[key] = result.containsErrorNodes
                bytesByContent[contentID] = bytes
            }
            guard let occurrenceID = UInt32(exactly: offset) else {
                preconditionFailure("File count exceeds UInt32")
            }
            occurrences.append(FileOccurrence(
                occurrenceID: FileOccurrenceID(rawValue: occurrenceID),
                pathID: paths.intern(relativePath(of: fileURL, under: root)),
                contentID: contentID,
                detectedLanguage: .rust,
                sourceKind: .untracked,
                fileMode: .regular,
                size: UInt64(data.count)
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
}
