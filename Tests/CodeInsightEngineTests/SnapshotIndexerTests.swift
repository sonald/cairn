import CodeInsightCore
@testable import CodeInsightEngine
import CodeInsightGit
import CodeInsightPythonExtractor
import CodeInsightTypeScriptExtractor
import Foundation
import Testing

private let snapshotIndexerRepositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

@Test
func cacheKeyUsesStableLengthFramedLanguageModeIdentity() {
    let key = ContentIndexKey(
        contentID: ContentID(algorithm: 1, bytes: [0x00, 0xab]),
        languageMode: LanguageMode(language: .rust),
        grammarVersion: 1,
        extractorVersion: 7
    )

    #expect(cacheKey(for: key) == "1:2#00ab:0:n:1:7")
    #expect(cacheKey(for: ContentIndexKey(
        contentID: key.contentID,
        languageMode: LanguageMode(language: .python),
        grammarVersion: key.grammarVersion,
        extractorVersion: key.extractorVersion
    )) == "1:2#00ab:1:n:1:7")

    func typescriptKey(variant: String?) -> String {
        cacheKey(for: ContentIndexKey(
            contentID: key.contentID,
            languageMode: LanguageMode(language: .typescript, variant: variant),
            grammarVersion: key.grammarVersion,
            extractorVersion: key.extractorVersion
        ))
    }

    #expect(Set([
        typescriptKey(variant: nil),
        typescriptKey(variant: ""),
        typescriptKey(variant: "a:b"),
    ]).count == 3)
    #expect(typescriptKey(variant: "ts") == "1:2#00ab:2:v2#7473:1:7")
    #expect(typescriptKey(variant: "tsx") == "1:2#00ab:2:v3#747378:1:7")
    #expect(typescriptKey(variant: "caf\u{e9}")
        == typescriptKey(variant: "cafe\u{301}"))
    #expect(typescriptKey(variant: "caf\u{e9}") == "1:2#00ab:2:v5#636166c3a9:1:7")
}

@Test
func snapshotIndexerReusesContentAndResolvesEachCommit() throws {
    let fixture = try SnapshotGitFixture()
    defer { fixture.remove() }

    let store = ProjectIndexStore()
    let indexer = ProjectIndexer(parallelism: 2)
    let newerSnapshot = try CommitSnapshot(repositoryURL: fixture.root)
    let newer = try indexer.indexSnapshot(newerSnapshot, into: store)
    let olderSnapshot = try CommitSnapshot(
        repositoryURL: fixture.root,
        revision: "HEAD~1"
    )
    let preparedOlder = try indexer.prepareSnapshot(olderSnapshot, into: store)

    #expect(preparedOlder.pendingExtractionCount == 1)
    #expect(preparedOlder.cachedSession.stats.reusedCount == 1)
    #expect(preparedOlder.cachedSession.stats.extractedCount == 0)
    let olderContentIDs = Set(preparedOlder.cachedSession.manifest.files.compactMap {
        $0.detectedLanguage == .rust ? $0.contentID : nil
    })
    #expect(preparedOlder.cachedSession.contentIndexes.keys.allSatisfy {
        olderContentIDs.contains($0.contentID)
    })
    #expect(try preparedOlder.cachedSession.definitions(
        of: "shared",
        context: snapshotQueryContext(for: preparedOlder.cachedSession)
    ).count == 1)
    #expect(try preparedOlder.cachedSession.definitions(
        of: "a",
        context: snapshotQueryContext(for: preparedOlder.cachedSession)
    ).isEmpty)

    let older = try indexer.completeSnapshot(preparedOlder)
    #expect(newer.stats.reusedCount == 0)
    #expect(newer.stats.extractedCount == 2)
    #expect(older.stats.reusedCount == 1)
    #expect(older.stats.extractedCount == 1)
    #expect(try resolvedName("b", in: newer) == "b")
    #expect(try resolvedName("a", in: older) == "a")

    let package = try #require(older.manifest.files.first {
        older.paths.resolve($0.pathID) == "Package.swift"
    })
    #expect(package.detectedLanguage == nil)
    if case .tracked = package.sourceKind {} else {
        Issue.record("Commit snapshot files must be tracked")
    }
    #expect(!older.contentIndexes.keys.contains {
        $0.contentID == package.contentID
    })
    #expect(older.sourceBytesByContent[package.contentID] != nil)

    let repeated = try indexer.indexSnapshot(olderSnapshot, into: store)
    #expect(repeated.stats.reusedCount == 2)
    #expect(repeated.stats.extractedCount == 0)
    #expect(repeated.contentIndexes.count == older.contentIndexes.count)

    let worktree = try indexer.indexSnapshot(
        WorktreeSnapshot(repositoryURL: fixture.root),
        into: ProjectIndexStore()
    )
    #expect(worktree.manifest.files.allSatisfy {
        if case .untracked = $0.sourceKind { return true }
        return false
    })
}

@Test
func explicitRustIndexerMatchesEveryCompatibilityPipeline() throws {
    let fixture = try SnapshotGitFixture()
    defer { fixture.remove() }
    let indexer = ProjectIndexer(parallelism: 2)

    let compatibilityRoot = try indexer.index(root: fixture.root)
    let explicitRoot = try indexer.index(root: fixture.root, language: .rust)
    try expectEquivalentContent(compatibilityRoot, explicitRoot)
    #expect(compatibilityRoot.analysisProfile.id == explicitRoot.analysisProfile.id)
    #expect(manifestDump(compatibilityRoot) == manifestDump(explicitRoot))

    let snapshot = try CommitSnapshot(repositoryURL: fixture.root)
    let compatibilitySnapshot = try indexer.indexSnapshot(
        snapshot,
        into: ProjectIndexStore()
    )
    let explicitSnapshot = try indexer.indexSnapshot(
        snapshot,
        into: ProjectIndexStore(),
        language: .rust
    )
    let prepared = try indexer.prepareSnapshot(
        snapshot,
        into: ProjectIndexStore(),
        language: .rust
    )
    let explicitPrepared = try indexer.completeSnapshot(prepared)

    for session in [explicitSnapshot, explicitPrepared] {
        try expectEquivalentContent(compatibilitySnapshot, session)
        #expect(compatibilitySnapshot.analysisProfile.id == session.analysisProfile.id)
        #expect(manifestDump(compatibilitySnapshot) == manifestDump(session))
    }
}

@Test
func moduleMapIgnoresForeignOccurrenceWithActiveContentID() throws {
    let parent = Array("mod child;\nfn root() {}\n".utf8)
    let child = Array("use super::root;\nfn call() { root(); }\n".utf8)
    let snapshot = CountingSnapshot(files: [
        "child.rs": child,
        "main.rs": parent,
        "z.py": parent,
    ])
    let session = try ProjectIndexer(parallelism: 1).indexSnapshot(
        snapshot,
        into: ProjectIndexStore(),
        language: .rust
    )
    let childPath = try #require(session.manifest.files.first {
        session.paths.resolve($0.pathID) == "child.rs"
    }?.pathID)
    let childIndex = try #require(session.content(at: childPath)?.1)
    let importBinding = try #require(childIndex.imports.first)
    let target = try #require(session.moduleMap.targetFile(
        for: importBinding,
        from: childPath,
        names: session.names,
        strings: session.strings
    ))

    #expect(session.paths.resolve(target) == "main.rs")
}

@Test
func unsupportedIndexerLanguageFailsBeforeFilesystemSnapshotOrStoreAccess() {
    let indexer = ProjectIndexer(parallelism: 1)
    let snapshot = CountingSnapshot(
        files: ["never.js": Array("never".utf8)]
    )
    let store = ProjectIndexStore()

    do {
        _ = try indexer.prepareSnapshot(snapshot, into: store, language: .javascript)
        Issue.record("JavaScript snapshot indexing unexpectedly succeeded")
    } catch let error as CocoaError {
        #expect(error.code == .featureUnsupported)
        #expect((error as NSError).localizedFailureReason?.contains("javascript") == true)
    } catch {
        Issue.record("Unexpected unsupported snapshot error: \(error)")
    }
    #expect(snapshot.counts.list == 0)
    #expect(snapshot.counts.read == 0)
    #expect(store.contentIndexes.isEmpty)
    #expect(store.sourceBytesByContent.isEmpty)

    let nonexistent = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodeInsightUnsupportedIndexer-\(UUID().uuidString)")
    do {
        _ = try indexer.index(root: nonexistent, language: .javascript)
        Issue.record("JavaScript filesystem indexing unexpectedly succeeded")
    } catch let error as CocoaError {
        #expect(error.code == .featureUnsupported)
        #expect((error as NSError).localizedFailureReason?.contains("javascript") == true)
    } catch {
        Issue.record("Unsupported preflight happened after filesystem access: \(error)")
    }
}

@Test
func pythonIndexerIndexesFixtureCountsAndProfileAndSearchView() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "CodeInsightPythonIndexerFixture-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("pkg"),
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try "".write(to: root.appendingPathComponent("pkg/__init__.py"), atomically: true, encoding: .utf8)
    try """
        class Model:
            def build(self):
                return 1

        def make():
            return Model().build()
        """.write(
        to: root.appendingPathComponent("pkg/models.py"),
        atomically: true,
        encoding: .utf8
    )
    try """
        from .models import make as go

        go()
        """.write(
        to: root.appendingPathComponent("main.py"),
        atomically: true,
        encoding: .utf8
    )

    let session = try ProjectIndexer(parallelism: 1).index(
        root: root,
        language: .python
    )

    #expect(session.analysisProfile.language == .python)
    #expect(session.stats.fileCount == 3)
    #expect(session.stats.uniqueContentCount == 3)
    #expect(session.stats.symbolCount == 3)
    #expect(session.stats.callCount == 3)
    #expect(session.stats.importCount == 1)
    let files = session.manifest.files.map { session.paths.resolve($0.pathID) }
    #expect(files == ["main.py", "pkg/__init__.py", "pkg/models.py"])
    #expect(try session.searchSymbols(
        query: "Model",
        limit: 10,
        boost: SearchBoost(),
        context: snapshotQueryContext(for: session)
    ).map(\.path).contains("pkg/models.py"))
}

@Test
func pythonAndRustSameContentKeysStayIsolated() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "CodeInsightPythonRustSameContent-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let bytes = Array("fn same() {}\n".utf8)
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    try Data(bytes).write(to: root.appendingPathComponent("same.py"))
    try Data(bytes).write(to: root.appendingPathComponent("same.rs"))

    let python = try ProjectIndexer(parallelism: 1).index(
        root: root,
        language: .python
    )
    let rust = try ProjectIndexer(parallelism: 1).index(
        root: root,
        language: .rust
    )

    #expect(python.manifest.files.allSatisfy {
        $0.detectedLanguage == .python
    })
    #expect(rust.manifest.files.allSatisfy {
        $0.detectedLanguage == .rust
    })
    #expect(python.contentIndexes.count == 1)
    #expect(rust.contentIndexes.count == 1)
    #expect(Set(python.contentIndexes.keys.map(\.languageMode.language))
        == [.python])
    #expect(Set(rust.contentIndexes.keys.map(\.languageMode.language))
        == [.rust])
    #expect(python.contentIndexes.keys.first?.contentID
        == rust.contentIndexes.keys.first?.contentID)
}

@Test
func typescriptIndexerIndexesTsAndTsxTogether() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "CodeInsightTypeScriptIndexerFixture-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try """
        export function greet(name: string) {
            return name
        }
        """.write(
        to: root.appendingPathComponent("greet.ts"),
        atomically: true,
        encoding: .utf8
    )
    try """
        export function Welcome() {
            return greet("hi")
        }
        """.write(
        to: root.appendingPathComponent("Welcome.tsx"),
        atomically: true,
        encoding: .utf8
    )
    try "ignored".write(
        to: root.appendingPathComponent("legacy.js"),
        atomically: true,
        encoding: .utf8
    )

    let session = try ProjectIndexer(parallelism: 1).index(
        root: root,
        language: .typescript
    )

    #expect(session.analysisProfile.language == .typescript)
    #expect(session.analysisProfile.projectUnitName == root.lastPathComponent)
    #expect(session.stats.fileCount == 2)
    #expect(session.stats.uniqueContentCount == 2)
    #expect(Set(session.contentIndexes.keys.map(\.languageMode.language))
        == [.typescript])
    #expect(Set(session.contentIndexes.keys.compactMap(\.languageMode.variant))
        == Set(["tsx"] as [String?]))
    let files = session.manifest.files.map { session.paths.resolve($0.pathID) }
    #expect(files == ["Welcome.tsx", "greet.ts"])
    #expect(files.allSatisfy {
        LanguageMode.classify(path: $0, language: .typescript) != nil
    })
    #expect(try session.searchSymbols(
        query: "Welcome",
        limit: 10,
        boost: SearchBoost(),
        context: snapshotQueryContext(for: session)
    ).map(\.path).contains("Welcome.tsx"))
}

@Test
func typescriptPersistentCacheExtractsOnceThenVariantOnlyMisses() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "CodeInsightTypeScriptCache-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = """
        export const value = "value"
        export function run() { return value }
        """
    try source.write(to: root.appendingPathComponent("a.ts"), atomically: true, encoding: .utf8)
    try source.write(to: root.appendingPathComponent("b.tsx"), atomically: true, encoding: .utf8)
    try "fn keep() {}\n".write(
        to: root.appendingPathComponent("keep.rs"),
        atomically: true,
        encoding: .utf8
    )
    try "def keep():\n    pass\n".write(
        to: root.appendingPathComponent("keep.py"),
        atomically: true,
        encoding: .utf8
    )

    let cacheURL = temporaryCacheURL()
    defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
    var cache: IndexCache? = try IndexCache(fileURL: cacheURL)
    let writer = ProjectIndexer(parallelism: 1, cache: cache!)
    let cold = try writer.index(root: root, language: .typescript)
    _ = try writer.index(root: root, language: .rust)
    _ = try writer.index(root: root, language: .python)
    writer.flushPersistentWrites()
    cache?.flush()
    cache = nil

    let hot = try ProjectIndexer(
        parallelism: 1,
        cache: try IndexCache(fileURL: cacheURL)
    ).index(root: root, language: .typescript)
    cache = try IndexCache(fileURL: cacheURL)
    let hotRust = try ProjectIndexer(
        parallelism: 1,
        cache: cache
    ).index(root: root, language: .rust)
    cache?.flush()
    cache = nil
    let hotPython = try ProjectIndexer(
        parallelism: 1,
        cache: try IndexCache(fileURL: cacheURL)
    ).index(root: root, language: .python)

    #expect(cold.stats.fileCount == 2)
    #expect(cold.stats.uniqueContentCount == 2)
    #expect(cold.stats.extractedCount == 2)
    #expect(hot.stats.uniqueContentCount == 2)
    #expect(hot.stats.reusedCount == 2)
    #expect(hot.stats.extractedCount == 0)
    #expect(hotRust.stats.reusedCount == 1)
    #expect(hotRust.stats.extractedCount == 0)
    #expect(hotPython.stats.reusedCount == 1)
    #expect(hotPython.stats.extractedCount == 0)

    cache = try IndexCache(fileURL: cacheURL)
    let bumped = try ProjectIndexer(
        parallelism: 1,
        cache: cache!,
        extractor: VersionedTypeScriptExtractor(version: 2)
    ).index(root: root, language: .typescript)
    cache?.flush()
    cache = nil
    let rustAfterTypeScriptMiss = try ProjectIndexer(
        parallelism: 1,
        cache: try IndexCache(fileURL: cacheURL)
    ).index(root: root, language: .rust)
    let pythonAfterTypeScriptMiss = try ProjectIndexer(
        parallelism: 1,
        cache: try IndexCache(fileURL: cacheURL)
    ).index(root: root, language: .python)

    #expect(bumped.stats.reusedCount == 0)
    #expect(bumped.stats.extractedCount == 2)
    #expect(rustAfterTypeScriptMiss.stats.reusedCount == 1)
    #expect(rustAfterTypeScriptMiss.stats.extractedCount == 0)
    #expect(pythonAfterTypeScriptMiss.stats.reusedCount == 1)
    #expect(pythonAfterTypeScriptMiss.stats.extractedCount == 0)
}

@Test
func typescriptVariantOnlyMissExtractsSecondVariantAfterTsCacheHit() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "CodeInsightTypeScriptVariantCache-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = """
        export const value = 1
        export function identical() {}
        """
    try source.write(to: root.appendingPathComponent("a.ts"), atomically: true, encoding: .utf8)

    let cacheURL = temporaryCacheURL()
    defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
    var cache: IndexCache? = try IndexCache(fileURL: cacheURL)
    let indexer = ProjectIndexer(parallelism: 1, cache: cache!)
    let first = try indexer.index(root: root, language: .typescript)
    indexer.flushPersistentWrites()
    cache?.flush()
    cache = nil

    try source.write(to: root.appendingPathComponent("b.tsx"), atomically: true, encoding: .utf8)
    let second = try ProjectIndexer(
        parallelism: 1,
        cache: try IndexCache(fileURL: cacheURL)
    ).index(root: root, language: .typescript)

    #expect(first.stats.fileCount == 1)
    #expect(first.stats.uniqueContentCount == 1)
    #expect(first.stats.extractedCount == 1)
    #expect(second.stats.fileCount == 2)
    #expect(second.stats.uniqueContentCount == 2)
    #expect(second.stats.reusedCount == 1)
    #expect(second.stats.extractedCount == 1)
    #expect(Set(second.contentIndexes.keys.map(\.languageMode.variant))
        == Set([nil, "tsx"] as [String?]))
}

@Test
func typescriptSnapshotExtractsWithoutForeignActiveFiles() throws {
    let snapshot = CountingSnapshot(files: [
        "src/main.ts": Array("export function main() {}\n".utf8),
        "src/component.tsx": Array("export function View() { return null }\n".utf8),
        "legacy.js": Array("function legacy() {}\n".utf8),
        "types.d.ts": Array("export type T = string\n".utf8),
    ])
    let session = try ProjectIndexer(parallelism: 1).indexSnapshot(
        snapshot,
        into: ProjectIndexStore(),
        language: .typescript
    )

    #expect(session.analysisProfile.language == .typescript)
    #expect(session.stats.fileCount == 2)
    #expect(session.stats.uniqueContentCount == 2)
    #expect(session.manifest.files.map { session.paths.resolve($0.pathID) }
        == ["legacy.js", "src/component.tsx", "src/main.ts", "types.d.ts"])
    #expect(Set(session.contentIndexes.keys.map(\.languageMode.variant))
        == Set([nil, "tsx"] as [String?]))
}

@Test
func typescriptCommitAndWorktreeIndexAreContentEquivalent() throws {
    let fixture = try SnapshotGitFixture(typescript: true)
    defer { fixture.remove() }
    let root = fixture.root

    let worktree = try ProjectIndexer(parallelism: 1).indexSnapshot(
        WorktreeSnapshot(repositoryURL: root, language: .typescript),
        into: ProjectIndexStore(),
        language: .typescript
    )
    let commit = try ProjectIndexer(parallelism: 1).indexSnapshot(
        CommitSnapshot(repositoryURL: root),
        into: ProjectIndexStore(),
        language: .typescript
    )

    #expect(worktree.analysisProfile.id == commit.analysisProfile.id)
    #expect(worktree.analysisProfile.language == .typescript)
    let worktreeActive = worktree.contentIndexes
    let commitActive = commit.contentIndexes
    #expect(Set(worktreeActive.keys) == Set(commitActive.keys))
    #expect(worktreeActive.count == 2)
    for key in worktreeActive.keys {
        #expect(try encodedIndex(worktreeActive[key]!)
            == encodedIndex(commitActive[key]!))
        #expect(worktree.sourceBytesByContent[key.contentID]
            == commit.sourceBytesByContent[key.contentID])
        #expect(CanonicalDump.render(
            worktreeActive[key]!,
            names: worktree.names,
            strings: worktree.strings
        ) == CanonicalDump.render(
            commitActive[key]!,
            names: commit.names,
            strings: commit.strings
        ))
    }
    #expect(Set(worktree.manifest.files.map(\.sourceKind))
        == Set([SourceKind.untracked]))
    #expect(Set(commit.manifest.files.map(\.sourceKind))
        == Set([SourceKind.tracked]))
    #expect(commit.manifest.files.contains {
        commit.paths.resolve($0.pathID) == "tsconfig.json"
            && $0.detectedLanguage == nil
    })
}

@Test
func pythonPersistentCacheExtractsOnceThenOnlyVersionMissesPython() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "CodeInsightPythonCache-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let pythonBytes = Array("""
        class Model:
            def build(self):
                return 1
        """.utf8)
    let rustBytes = Array("fn keep() {}\n".utf8)
    try Data(pythonBytes).write(to: root.appendingPathComponent("models.py"))
    try Data(rustBytes).write(to: root.appendingPathComponent("keep.rs"))

    let cacheURL = temporaryCacheURL()
    defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
    var cache: IndexCache? = try IndexCache(fileURL: cacheURL)
    let writer = ProjectIndexer(parallelism: 1, cache: cache!)
    let coldPython = try writer.index(root: root, language: .python)
    _ = try writer.index(root: root, language: .rust)
    writer.flushPersistentWrites()
    cache?.flush()
    cache = nil

    let hotPython = try ProjectIndexer(
        parallelism: 1,
        cache: try IndexCache(fileURL: cacheURL)
    ).index(root: root, language: .python)
    cache = try IndexCache(fileURL: cacheURL)
    let hotRust = try ProjectIndexer(
        parallelism: 1,
        cache: cache
    ).index(root: root, language: .rust)
    cache?.flush()
    cache = nil

    #expect(coldPython.stats.uniqueContentCount == 1)
    #expect(coldPython.stats.extractedCount == 1)
    #expect(hotPython.stats.uniqueContentCount == 1)
    #expect(hotPython.stats.reusedCount == 1)
    #expect(hotPython.stats.extractedCount == 0)
    #expect(hotRust.stats.uniqueContentCount == 1)
    #expect(hotRust.stats.extractedCount == 0)
    #expect(hotRust.stats.reusedCount == 1)

    cache = try IndexCache(fileURL: cacheURL)
    let bumped = try ProjectIndexer(
        parallelism: 1,
        cache: cache!,
        extractor: VersionedPythonExtractor(version: 2)
    ).index(root: root, language: .python)
    cache?.flush()
    cache = nil
    let rustAfterPythonMiss = try ProjectIndexer(
        parallelism: 1,
        cache: try IndexCache(fileURL: cacheURL)
    ).index(root: root, language: .rust)
    #expect(bumped.stats.reusedCount == 0)
    #expect(bumped.stats.extractedCount == 1)
    #expect(bumped.stats.uniqueContentCount == 1)
    #expect(rustAfterPythonMiss.stats.reusedCount == 1)
    #expect(rustAfterPythonMiss.stats.extractedCount == 0)
}

@Test
func indexerRejectsExtractorAndResultIdentityMismatches() throws {
    let snapshot = CountingSnapshot()
    let mismatchedExtractor = ProjectIndexer(
        parallelism: 1,
        cache: nil,
        extractor: ContractExtractor(language: .python, returnsForeignKey: false)
    )
    do {
        _ = try mismatchedExtractor.prepareSnapshot(
            snapshot,
            into: ProjectIndexStore(),
            language: .rust
        )
        Issue.record("Rust request accepted a Python extractor")
    } catch let error as CocoaError {
        #expect(error.code == .coderInvalidValue)
    }
    #expect(snapshot.counts.list == 0)
    #expect(snapshot.counts.read == 0)

    let foreignResult = ProjectIndexer(
        parallelism: 1,
        cache: nil,
        extractor: ContractExtractor(language: .rust, returnsForeignKey: true)
    )
    let prepared = try foreignResult.prepareSnapshot(
        snapshot,
        into: ProjectIndexStore(),
        language: .rust
    )
    do {
        _ = try foreignResult.completeSnapshot(prepared)
        Issue.record("Indexer accepted a foreign ContentIndexKey")
    } catch let error as CocoaError {
        #expect(error.code == .coderInvalidValue)
        #expect((error as NSError).localizedFailureReason?
            .contains("different ContentIndexKey") == true)
    }
}

@Test
func ambiguousIndependentRootsFailBeforeSnapshotReadOrStoreWrite() throws {
    let snapshot = CountingSnapshot(files: [
        "a/src/main.rs": Array("fn main() {}\n".utf8),
        "b/src/main.rs": Array("fn b() {}\n".utf8),
        "a/Cargo.toml": Array("[package]\nname = \"a\"\n".utf8),
        "b/Cargo.toml": Array("[package]\nname = \"b\"\n".utf8),
    ], configurationPaths: [
        "a/Cargo.toml",
        "b/Cargo.toml",
    ])
    let store = ProjectIndexStore()
    let beforePaths = store.paths.values

    do {
        _ = try ProjectIndexer(parallelism: 1).prepareSnapshot(
            snapshot,
            into: store,
            language: .rust,
            discoverUnitRoot: true
        )
        Issue.record("Ambiguous same-language roots unexpectedly indexed")
    } catch let error as CocoaError {
        #expect(error.code == .featureUnsupported)
        #expect((error as NSError).localizedFailureReason?
            .contains("multiple rust project units") == true)
    }
    #expect(snapshot.counts.read == 0)
    #expect(store.paths.values == beforePaths)
}

@Test
func publicSingletonIndexKeepsRootProfileWhileStrictOverloadRejectsMarkerOutsideSource() throws {
    let snapshot = CountingSnapshot(files: [
        "nested/src/inside.rs": Array("fn inside() {}\n".utf8),
        "outside.rs": Array("fn outside() {}\n".utf8),
        "nested/Cargo.toml": Array("[package]\nname = \"nested\"\n".utf8),
    ], configurationPaths: [
        "nested/Cargo.toml",
    ])

    let singleton = try ProjectIndexer(parallelism: 1).indexSnapshot(
        snapshot,
        into: ProjectIndexStore(),
        language: .rust
    )
    #expect(singleton.paths.resolve(singleton.analysisProfile.projectRoot) == ".")

    #expect(throws: CocoaError.self) {
        _ = try ProjectIndexer(parallelism: 1).prepareSnapshot(
            snapshot,
            into: ProjectIndexStore(),
            language: .rust,
            discoverUnitRoot: true
        )
    }
}

@Test
func nestedPythonActiveViewTrimsUnitRootBeforeModuleIdentity() throws {
    let files: [String: [UInt8]] = [
        "tools/py/src/pkg/__init__.py": Array("\n".utf8),
        "tools/py/src/pkg/a.py": Array("def f():\n    return 1\n".utf8),
        "tools/py/src/main.py": Array("from pkg.a import f\nf()\n".utf8),
        "tools/py/pyproject.toml": Array("[project]\nname = \"tools-py\"\n".utf8),
    ]
    let snapshot = CountingSnapshot(files: files, configurationPaths: [
        "tools/py/pyproject.toml",
    ])
    let prepared = try ProjectIndexer(parallelism: 1).prepareSnapshot(
        snapshot,
        into: ProjectIndexStore(),
        language: .python,
        discoverUnitRoot: true
    )
    let session = try ProjectIndexer().completeSnapshot(prepared)

    #expect(session.paths.resolve(session.analysisProfile.projectRoot)
        == "tools/py")
    #expect(session.manifest.files.map { session.paths.resolve($0.pathID) }
        == [
            "tools/py/src/main.py",
            "tools/py/src/pkg/__init__.py",
            "tools/py/src/pkg/a.py",
        ])
    let mainPath = try #require(session.manifest.files.first {
        session.paths.resolve($0.pathID) == "tools/py/src/main.py"
    }?.pathID)
    let callOffset = try #require(utf8Offset(
        of: "f()",
        in: "from pkg.a import f\nf()\n"
    ))
    let resolved = try session.resolve(
        file: mainPath,
        offset: callOffset,
        context: snapshotQueryContext(for: session)
    )
    let top = try #require(resolved.first)
    #expect(session.paths.resolve(top.target.pathID) == "tools/py/src/pkg/a.py")
    #expect(top.certainty == .strong)
    #expect(top.evidence.contains {
        if case .uniqueImport = $0 { return true }
        return false
    })
}

@Test
func nestedRustCrateAndSuperStayInsideUnitRoot() throws {
    let libSource = "pub mod child;\npub fn root() {}\n"
    let childSource = "use super::root;\nfn call() { root(); }\n"
    let snapshot = CountingSnapshot(files: [
        "crates/x/src/lib.rs": Array(libSource.utf8),
        "crates/x/src/child.rs": Array(childSource.utf8),
        "crates/x/Cargo.toml": Array("[package]\nname = \"x\"\n".utf8),
    ], configurationPaths: [
        "crates/x/Cargo.toml",
    ])
    let prepared = try ProjectIndexer(parallelism: 1).prepareSnapshot(
        snapshot,
        into: ProjectIndexStore(),
        language: .rust,
        discoverUnitRoot: true
    )
    let session = try ProjectIndexer().completeSnapshot(prepared)

    #expect(session.paths.resolve(session.analysisProfile.projectRoot)
        == "crates/x")
    let child = try #require(session.manifest.files.first {
        session.paths.resolve($0.pathID) == "crates/x/src/child.rs"
    }?.pathID)
    let offset = try #require(utf8Offset(of: "root()", in: childSource))
    let resolved = try session.resolve(
        file: child,
        offset: offset,
        context: snapshotQueryContext(for: session)
    )
    let top = try #require(resolved.first)
    #expect(session.paths.resolve(top.target.pathID) == "crates/x/src/lib.rs")
    #expect(top.certainty == .strong)
    #expect(top.evidence.contains {
        if case .uniqueImport = $0 { return true }
        return false
    })
}

@Test
func activeViewKeepsUnionManifestButExcludesPathsOutsideManualUnitRoot() throws {
    let appSource = """
        import { b } from './b'
        import { outside } from '../../../outside'
        b()
        outside()
        """
    let files: [String: [UInt8]] = [
        "tools/ts/src/app.ts": Array(appSource.utf8),
        "tools/ts/src/b.ts": Array("export function b() {}\n".utf8),
        "outside.ts": Array("export const outside = 1\n".utf8),
        "tools/ts/tsconfig.json": Array("{}".utf8),
    ]
    let snapshot = CountingSnapshot(files: files, configurationPaths: [
        "tools/ts/tsconfig.json",
    ])
    let store = ProjectIndexStore()
    let base = try ProjectIndexer(parallelism: 1).indexSnapshot(
        snapshot,
        into: store,
        language: .typescript
    )
    let nestedRoot = store.paths.intern("tools/ts")
    let nestedProfile = AnalysisProfile(
        language: .typescript,
        projectRoot: nestedRoot,
        projectUnitName: "tsconfig.json",
        configFingerprint: base.analysisProfile.configFingerprint,
        environmentFingerprint: base.analysisProfile.environmentFingerprint,
        featureSelection: .defaultFeatures,
        featureNames: [],
        edition: nil,
        trustMode: .safe
    )
    let view = SnapshotView(
        store: store,
        manifest: base.manifest,
        stats: base.stats,
        analysisProfile: nestedProfile,
        extractor: base.extractor
    )
    let session = EngineSession(store: store, snapshotView: view)

    #expect(session.manifest.files.map { session.paths.resolve($0.pathID) }
        == ["outside.ts", "tools/ts/src/app.ts", "tools/ts/src/b.ts"])
    let outside = try #require(session.manifest.files.first {
        session.paths.resolve($0.pathID) == "outside.ts"
    }?.pathID)
    #expect(session.content(at: outside) == nil)
    #expect(try session.definitions(
        of: "outside",
        context: snapshotQueryContext(for: session)
    ).isEmpty)
    let app = try #require(session.manifest.files.first {
        session.paths.resolve($0.pathID) == "tools/ts/src/app.ts"
    }?.pathID)
    #expect(session.content(at: app) != nil)
    #expect(session.content(at: outside) == nil)
    let appIndex = try #require(session.content(at: app)?.1)
    let specs = appIndex.imports.map {
        session.strings.resolve($0.moduleSpecifier)
    }
    #expect(Set(specs) == Set(["./b", "../../../outside"]))
    for importBinding in appIndex.imports {
        let specifier = session.strings.resolve(importBinding.moduleSpecifier)
        let target = session.moduleMap.targetFile(
            for: importBinding,
            from: app,
            names: session.names,
            strings: session.strings
        )
        #expect(target.map { session.paths.resolve($0) }
            == (specifier == "./b" ? "tools/ts/src/b.ts" : nil))
    }
    #expect(session.contentIndexes.count == 2)
}

@Test
func snapshotIndexingIsDeterministicForTheSameSequence() throws {
    let fixture = try SnapshotGitFixture()
    defer { fixture.remove() }

    let newer = try CommitSnapshot(repositoryURL: fixture.root)
    let older = try CommitSnapshot(repositoryURL: fixture.root, revision: "HEAD~1")

    func runSequence() throws -> String {
        let indexer = ProjectIndexer(parallelism: 4)
        let store = ProjectIndexStore()
        let first = try indexer.indexSnapshot(newer, into: store)
        let second = try indexer.indexSnapshot(older, into: store)
        return try [first, second].map(snapshotQueryDump).joined(separator: "\n---\n")
    }

    #expect(try runSequence() == runSequence())
}

@Test
func repositoryAdjacentCommitReuseExceedsEightyPercent() throws {
    let indexer = ProjectIndexer()
    let store = ProjectIndexStore()
    let head = try countingCopyOf(
        CommitSnapshot(repositoryURL: snapshotIndexerRepositoryRoot)
    )
    _ = try indexer.indexSnapshot(head, into: store)

    let startedAt = Date()
    let previous = try countingCopyOf(
        CommitSnapshot(
            repositoryURL: snapshotIndexerRepositoryRoot,
            revision: "HEAD~1"
        )
    )
    let session = try indexer.indexSnapshot(previous, into: store)
    let elapsed = Date().timeIntervalSince(startedAt) * 1_000
    let total = session.stats.reusedCount + session.stats.extractedCount
    let hitRate = total == 0 ? 0 : Double(session.stats.reusedCount) / Double(total)

    print(String(
        format: "S3 HEAD->HEAD~1 totalFiles=%d reusedCount=%d extractedCount=%d hitRate=%.1f%% switchMS=%.3f",
        total,
        session.stats.reusedCount,
        session.stats.extractedCount,
        hitRate * 100,
        elapsed
    ))
    #expect(hitRate > 0.8)
}

@Test
func snapshotIndexerCountsLFSPointerWithoutParsingItAsRust() throws {
    let fixture = try SnapshotGitFixture()
    defer { fixture.remove() }
    let pointer = Array("""
        version https://git-lfs.github.com/spec/v1
        oid sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
        size 123456

        """.utf8)
    try fixture.commitLFSPointer(pointer)

    let session = try ProjectIndexer().indexSnapshot(
        CommitSnapshot(repositoryURL: fixture.root),
        into: ProjectIndexStore()
    )
    let file = try #require(session.manifest.files.first {
        session.paths.resolve($0.pathID) == "src/large.rs"
    })

    #expect(file.fileMode == .lfsPointer)
    #expect(file.detectedLanguage == .rust)
    #expect(session.stats.fileCount == 3)
    #expect(session.stats.extractedCount == 2)
    #expect(session.sourceBytesByContent[file.contentID] == pointer)
    #expect(!session.contentIndexes.keys.contains { $0.contentID == file.contentID })
}

@Test
func persistentDraftRoundTripMatchesDirectExtractionFieldForField() throws {
    let fixture = try SnapshotGitFixture()
    defer { fixture.remove() }
    let cacheURL = temporaryCacheURL()
    defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }

    let direct = try ProjectIndexer(parallelism: 1).index(root: fixture.root)
    let cache = try IndexCache(fileURL: cacheURL)
    let writer = ProjectIndexer(
        parallelism: 2,
        cache: cache
    )
    let first = try writer.index(root: fixture.root)
    writer.flushPersistentWrites()
    let storedKey = try #require(first.contentIndexes.keys.first)
    let reloaded = try ProjectIndexer(
        parallelism: 2,
        cache: try IndexCache(fileURL: cacheURL)
    ).index(root: fixture.root)

    #expect(first.stats.extractedCount == 2)
    #expect(cache.payload(for: cacheKey(for: storedKey))?
        .starts(with: Data([0x43, 0x49, 0x44, 0x58, 0x02])) == true)
    #expect(reloaded.stats.extractedCount == 0)
    #expect(reloaded.stats.reusedCount == 2)
    try expectEquivalentContent(direct, reloaded)
}

@Test
func persistentCacheRemapsAndPersistsCallNamesAcrossFiles() throws {
    let fixture = snapshotIndexerRepositoryRoot.appendingPathComponent(
        "Tests/RustExtractorTests/Fixtures/receiver_type",
        isDirectory: true
    )
    let cacheURL = temporaryCacheURL()
    defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }

    let cache = try IndexCache(fileURL: cacheURL)
    let writer = ProjectIndexer(parallelism: 2, cache: cache)
    let first = try writer.index(root: fixture)
    writer.flushPersistentWrites()
    let reloaded = try ProjectIndexer(
        parallelism: 2,
        cache: try IndexCache(fileURL: cacheURL)
    ).index(root: fixture)

    #expect(first.stats.extractedCount == 2)
    #expect(reloaded.stats.extractedCount == 0)
    #expect(reloaded.stats.reusedCount == 2)
    try expectEquivalentContent(first, reloaded)

    let mainPath = try #require(reloaded.manifest.files.first {
        reloaded.paths.resolve($0.pathID) == "main.rs"
    }?.pathID)
    let mainIndex = try #require(reloaded.content(at: mainPath)?.1)
    let source = try #require(reloaded.sourceBytes(at: mainPath))
    let call = try #require(mainIndex.calls.first {
        reloaded.names.resolve($0.nameID) == "foo"
    })
    #expect(String(decoding: source[
        Int(call.nameRange.lowerBound)..<Int(call.nameRange.upperBound)
    ], as: UTF8.self) == "foo")
    #expect(String(decoding: source[
        Int(call.range.lowerBound)..<Int(call.range.upperBound)
    ], as: UTF8.self) == "receiver.foo()")

    let receiver = try #require(mainIndex.bindings.first {
        reloaded.names.resolve($0.localNameID) == "receiver"
            && $0.kind == .param
    })
    let targetHint = try #require(receiver.targetHint)
    #expect(reloaded.names.resolve(targetHint.nameID) == "T")
    #expect(targetHint.hintKind == .unqualified)

    let callOffset = try #require(mainIndex.lineTable.byteOffset(line: 5, column: 14))
    let candidate = try #require(try reloaded.resolve(
        file: mainPath,
        offset: callOffset,
        context: snapshotQueryContext(for: reloaded)
    ).first)
    #expect(candidate.certainty == .strong)
    #expect(reloaded.paths.resolve(candidate.target.pathID) == "a.rs")
    #expect(candidate.evidence.contains {
        if case let .receiverType(nameID) = $0 {
            return reloaded.names.resolve(nameID) == "T"
        }
        return false
    })
}

@Test
func corruptPersistentPayloadSilentlyFallsBackToExtraction() throws {
    let fixture = try SnapshotGitFixture()
    defer { fixture.remove() }
    let cacheURL = temporaryCacheURL()
    defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
    let cache = try IndexCache(fileURL: cacheURL)
    let indexer = ProjectIndexer(parallelism: 1, cache: cache)
    let snapshot = try WorktreeSnapshot(repositoryURL: fixture.root)
    let direct = try ProjectIndexer(parallelism: 1).indexSnapshot(
        snapshot,
        into: ProjectIndexStore()
    )
    _ = try indexer.indexSnapshot(snapshot, into: ProjectIndexStore())
    indexer.flushPersistentWrites()
    let firstRustContentID = try #require(direct.manifest.files.first {
        $0.detectedLanguage == .rust
    }?.contentID)
    let poisonedKey = try #require(direct.contentIndexes.keys.first {
        $0.contentID == firstRustContentID
    })
    cache.storeSynchronously([
        (cacheKey(for: poisonedKey), Data("not a draft".utf8), 1),
    ])

    let prepared = try indexer.prepareSnapshot(snapshot, into: ProjectIndexStore())
    #expect(prepared.pendingExtractionCount == 1)
    #expect(prepared.cachedSession.stats.reusedCount == 0)
    let recovered = try indexer.completeSnapshot(prepared)
    #expect(recovered.stats.extractedCount == 1)
    #expect(recovered.stats.reusedCount == 1)
    try expectEquivalentContent(direct, recovered)
}

@Test
func schemaMismatchRebuildsTheWholeDatabase() throws {
    let cacheURL = temporaryCacheURL()
    defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
    var cache: IndexCache? = try IndexCache(fileURL: cacheURL, schemaVersionOverride: 1)
    cache?.storeSynchronously([("old", Data([1, 2, 3]), 1)])
    #expect(cache?.payload(for: "old") == Data([1, 2, 3]))
    // payload(...) schedules an async LRU touch that retains the cache, so simply
    // dropping the reference would not close the old SQLite connection yet. Drain
    // the queue, then release, so the connection (and its -wal/-shm) is fully
    // closed before we reopen the same file. This models an app upgrade — a new
    // process opening the DB. Reopening while that connection is still live races
    // the rebuild's file removal against it and can surface SQLITE_IOERR under load.
    cache?.flush()
    cache = nil

    let bumped = try IndexCache(fileURL: cacheURL)
    #expect(bumped.payload(for: "old") == nil)
    #expect(bumped.metadata == IndexCache.Metadata(schemaVersion: 2))
}

@Test
func extractorVersionsCoexistInSchemaTwoCache() throws {
    let cacheURL = temporaryCacheURL()
    defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
    let contentID = ContentID(algorithm: 1, bytes: [0x01])
    func key(extractorVersion: UInt32) -> String {
        cacheKey(for: ContentIndexKey(
            contentID: contentID,
            languageMode: LanguageMode(language: .rust),
            grammarVersion: 1,
            extractorVersion: extractorVersion
        ))
    }

    var cache: IndexCache? = try IndexCache(fileURL: cacheURL)
    cache?.storeSynchronously([
        (key(extractorVersion: 40), Data([40]), 1),
        (key(extractorVersion: 41), Data([41]), 2),
    ])
    cache?.flush()
    cache = nil

    let reopened = try IndexCache(fileURL: cacheURL)
    #expect(reopened.payload(for: key(extractorVersion: 40)) == Data([40]))
    #expect(reopened.payload(for: key(extractorVersion: 41)) == Data([41]))
}

@Test
func persistentCacheEvictsLeastRecentlyUsedPayloads() throws {
    let cacheURL = temporaryCacheURL()
    defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }
    let cache = try IndexCache(fileURL: cacheURL, quotaBytes: 8)
    cache.storeSynchronously([
        ("a", Data(repeating: 1, count: 4), 1),
        ("b", Data(repeating: 2, count: 4), 2),
    ])
    #expect(cache.payload(for: "a") != nil)
    cache.storeSynchronously([("c", Data(repeating: 3, count: 4), 3)])

    #expect(cache.payload(for: "a") != nil)
    #expect(cache.payload(for: "b") == nil)
    #expect(cache.payload(for: "c") != nil)
}

@Test
func batchInsertMatchesSequentialInsert() throws {
    let fixture = try SnapshotGitFixture()
    defer { fixture.remove() }
    let session = try ProjectIndexer(parallelism: 1).index(root: fixture.root)
    let entries = session.contentIndexes.values.sorted {
        cacheKey(for: $0.key) < cacheKey(for: $1.key)
    }.map { index in
        (
            index,
            session.sourceBytesByContent[index.key.contentID]!,
            false
        )
    }
    let sequential = ProjectIndexStore()
    for entry in entries {
        sequential.insert(
            entry.0,
            bytes: entry.1,
            containsErrorNodes: entry.2
        )
    }
    let batch = ProjectIndexStore()
    batch.insert(entries)

    let sequentialState = sequential.snapshot()
    let batchState = batch.snapshot()
    #expect(Set(sequentialState.contentIndexes.keys) == Set(batchState.contentIndexes.keys))
    #expect(sequentialState.sourceBytesByContent == batchState.sourceBytesByContent)
    #expect(sequentialState.containsErrorNodes == batchState.containsErrorNodes)
    for key in sequentialState.contentIndexes.keys {
        #expect(try encodedIndex(sequentialState.contentIndexes[key]!)
            == encodedIndex(batchState.contentIndexes[key]!))
    }
    #expect(postingDump(sequentialState.namePosting) == postingDump(batchState.namePosting))
}

private func expectEquivalentContent(
    _ direct: EngineSession,
    _ cached: EngineSession
) throws {
    #expect(Set(direct.contentIndexes.keys) == Set(cached.contentIndexes.keys))
    #expect(direct.sourceBytesByContent == cached.sourceBytesByContent)
    for key in direct.contentIndexes.keys {
        let directIndex = direct.contentIndexes[key]!
        let cachedIndex = cached.contentIndexes[key]!
        #expect(try encodedIndex(directIndex) == encodedIndex(cachedIndex))
        #expect(CanonicalDump.render(
            directIndex,
            names: direct.names,
            strings: direct.strings
        ) == CanonicalDump.render(
            cachedIndex,
            names: cached.names,
            strings: cached.strings
        ))
    }
}

private func encodedIndex(_ index: ContentIndex) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(index)
}

private func postingDump(_ posting: NamePosting) -> [String] {
    let definitions = posting.definitions.flatMap { name, values in
        values.map { "d:\(name.rawValue):\(cacheKey(for: $0.key)):\($0.facetIndex)" }
    }
    let calls = posting.calls.flatMap { name, values in
        values.map { "c:\(name.rawValue):\(cacheKey(for: $0.key)):\($0.callIndex)" }
    }
    return (definitions + calls).sorted()
}

private func temporaryCacheURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("CodeInsightIndexCacheTests-\(UUID().uuidString)")
        .appendingPathComponent("cache.sqlite3")
}

private func resolvedName(_ name: String, in session: EngineSession) throws -> String {
    let source = "fn \(name)() {}\nfn call() { \(name)(); }\n"
    let path = try #require(session.manifest.files.first {
        session.paths.resolve($0.pathID) == "src/main.rs"
    }?.pathID)
    let callOffset = UInt32(source.utf8.distance(
        from: source.utf8.startIndex,
        to: source.range(of: "\(name)();")!.lowerBound.samePosition(in: source.utf8)!
    ))
    let candidate = try #require(session.resolve(
        file: path,
        offset: callOffset,
        context: snapshotQueryContext(for: session)
    ).first)
    let (_, index) = try #require(session.content(at: candidate.target.pathID))
    let facet = try #require(index.symbols.indices.contains(Int(candidate.target.localIndex))
        ? index.symbols[Int(candidate.target.localIndex)] : nil)
    return session.names.resolve(facet.nameID)
}

private func snapshotQueryDump(_ session: EngineSession) throws -> String {
    let context = snapshotQueryContext(for: session)
    var lines: [String] = []
    var seen: Set<ContentIndexKey> = []
    for file in session.manifest.files {
        lines.append("path #\(file.pathID.rawValue) \(session.paths.resolve(file.pathID))")
        guard let (key, index) = session.content(at: file.pathID),
              seen.insert(key).inserted
        else { continue }
        lines.append(CanonicalDump.render(
            index,
            names: session.names,
            strings: session.strings
        ))
        lines.append("bindingNames \(index.bindings.map { $0.localNameID.rawValue })")
        lines.append("symbolNames \(index.symbols.map { $0.nameID.rawValue })")
        lines.append("callNames \(index.calls.map { $0.nameID.rawValue })")
        lines.append("importStrings \(index.imports.map { $0.moduleSpecifier.rawValue })")
    }
    lines += try ["a", "b", "shared"].map { name in
        let definitions = try session.definitions(of: name, context: context).map {
            occurrence, facet, pathID in
            "\(session.paths.resolve(pathID)):\(occurrence.localIndex):\(facet.nameID.rawValue)"
        }
        return "\(name)=\(definitions.joined(separator: ","))"
    }
    return lines.joined(separator: "\n")
}

private func manifestDump(_ session: EngineSession) -> [String] {
    session.manifest.files.map { file in
        let language = file.detectedLanguage.map { String($0.rawValue) } ?? "-"
        return "\(session.paths.resolve(file.pathID)):\(file.contentID.algorithm):"
            + "\(file.contentID.bytes):\(language):\(file.fileMode):\(file.size)"
    }
}

private func snapshotQueryContext(for session: EngineSession) -> QueryContext {
    QueryContext(
        snapshotID: session.snapshotID,
        analysisProfileID: session.analysisProfile.id,
        generation: 1
    )
}

private final class SnapshotGitFixture {
    let root: URL

    init(typescript: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CodeInsightSnapshotIndexerTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git("init", "-q")
        if typescript {
            try write("src/main.ts", "export function main() {}\n")
            try write("src/component.tsx", "export function View() { return null }\n")
            try write("tsconfig.json", "{}")
            try write("package.json", "{\"name\":\"sample\"}")
            try git("add", ".")
            try commit("typescript")
        } else {
            try write("Package.swift", "// non-Rust manifest entry\n")
            try write("src/main.rs", "fn a() {}\nfn call() { a(); }\n")
            try write("src/shared.rs", "pub fn shared() {}\n")
            try git("add", ".")
            try commit("older")
            try write("src/main.rs", "fn b() {}\nfn call() { b(); }\n")
            try git("add", "src/main.rs")
            try commit("newer")
        }
    }

    func commitLFSPointer(_ bytes: [UInt8]) throws {
        let file = root.appendingPathComponent("src/large.rs")
        try Data(bytes).write(to: file)
        try git("add", "src/large.rs")
        try commit("lfs pointer")
    }

    private func write(_ path: String, _ contents: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func commit(_ message: String) throws {
        try git(
            "-c", "user.name=CodeInsight",
            "-c", "user.email=codeinsight@example.com",
            "commit", "-q", "-m", message
        )
    }

    @discardableResult
    private func git(_ arguments: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = root
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "git failed"
            throw SnapshotFixtureError.git(message)
        }
        return String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class CountingSnapshot: Snapshot, @unchecked Sendable {
    let snapshotID = SnapshotID(rawValue: UUID())
    let objectFormat = GitObjectFormat.sha1
    let sourceKind = SourceKind.tracked
    let configurationPaths: [String]

    private let files: [String: [UInt8]]
    private let lock = NSLock()
    private var listCount = 0
    private var readCount = 0

    init(files: [String: [UInt8]] = [
        "never.rs": Array("never".utf8),
    ], configurationPaths: [String] = []) {
        self.files = files
        self.configurationPaths = configurationPaths
    }

    var counts: (list: Int, read: Int) {
        lock.withLock { (listCount, readCount) }
    }

    func listFiles() -> [(path: String, contentID: ContentID, fileMode: FileMode)] {
        lock.withLock { listCount += 1 }
        return files.compactMap { path, bytes in
            guard !configurationPaths.contains(path) else { return nil }
            return (path, ContentID.sha256(of: bytes), .regular)
        }.sorted { $0.path < $1.path }
    }

    func readBytes(path: String) throws -> [UInt8] {
        lock.withLock { readCount += 1 }
        guard let bytes = files[path] else { throw GitError.missingPath(path) }
        return bytes
    }
}

private func countingCopyOf(_ snapshot: any Snapshot) throws -> CountingSnapshot {
    var bytes: [String: [UInt8]] = [:]
    for file in snapshot.listFiles() {
        bytes[file.path] = try snapshot.readBytes(path: file.path)
    }
    return CountingSnapshot(files: bytes)
}

private func utf8Offset(of needle: String, in source: String) -> UInt32? {
    guard let range = source.range(of: needle) else { return nil }
    return UInt32(source[..<range.lowerBound].utf8.count)
}

private struct ContractExtractor: LanguageExtractor {
    let language: LanguageID
    let returnsForeignKey: Bool
    let grammarVersion: UInt32 = 1
    let extractorVersion: UInt32 = 1

    func extractWithDiagnostics(
        bytes: [UInt8],
        key: ContentIndexKey,
        interner _: ExtractionInterners
    ) throws -> (index: ContentIndex, containsErrorNodes: Bool) {
        let resultKey = returnsForeignKey
            ? ContentIndexKey(
                contentID: key.contentID,
                languageMode: LanguageMode(language: .python),
                grammarVersion: key.grammarVersion,
                extractorVersion: key.extractorVersion
            )
            : key
        return (ContentIndex(
            key: resultKey,
            scopes: [],
            bindings: [],
            executableRegions: [],
            symbols: [],
            calls: [],
            imports: [],
            exports: [],
            lineTable: LineTable(bytes: bytes)
        ), false)
    }

    func identifierRanges(
        named _: String,
        in _: [UInt8],
        mode _: LanguageMode
    ) throws -> [ByteRange] {
        []
    }
}

private struct VersionedPythonExtractor: LanguageExtractor {
    let version: UInt32

    var language: LanguageID { .python }
    var grammarVersion: UInt32 { PythonExtractor.grammarVersion }
    var extractorVersion: UInt32 { version }

    func extractWithDiagnostics(
        bytes: [UInt8],
        key: ContentIndexKey,
        interner: ExtractionInterners
    ) throws -> (index: ContentIndex, containsErrorNodes: Bool) {
        try PythonExtractor().extractWithDiagnostics(
            bytes: bytes,
            key: key,
            interner: interner
        )
    }

    func identifierRanges(
        named name: String,
        in bytes: [UInt8],
        mode: LanguageMode
    ) throws -> [ByteRange] {
        try PythonExtractor().identifierRanges(
            named: name,
            in: bytes,
            mode: mode
        )
    }
}

private struct VersionedTypeScriptExtractor: LanguageExtractor {
    let version: UInt32

    var language: LanguageID { .typescript }
    var grammarVersion: UInt32 { TypeScriptExtractor.grammarVersion }
    var extractorVersion: UInt32 { version }

    func extractWithDiagnostics(
        bytes: [UInt8],
        key: ContentIndexKey,
        interner: ExtractionInterners
    ) throws -> (index: ContentIndex, containsErrorNodes: Bool) {
        try TypeScriptExtractor().extractWithDiagnostics(
            bytes: bytes,
            key: key,
            interner: interner
        )
    }

    func identifierRanges(
        named name: String,
        in bytes: [UInt8],
        mode: LanguageMode
    ) throws -> [ByteRange] {
        try TypeScriptExtractor().identifierRanges(
            named: name,
            in: bytes,
            mode: mode
        )
    }
}

private enum SnapshotFixtureError: Error {
    case git(String)
}
