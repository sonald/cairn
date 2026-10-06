import CodeInsightCore
import CodeInsightRustExtractor
@testable import CodeInsightEngine
import Foundation
import Testing

/// The oracle uses generated line records, never scopes, byte ranges, or the production parser.
@Test
func composableSearchMatchesIndependentLineOracle() async throws {
    var seed: UInt64 = 0xCA17_2026
    func next(_ limit: Int) -> Int {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Int((seed >> 32) % UInt64(limit))
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let words = ["alpha", "beta", "gamma", "ban"]
    for _ in 0..<24 {
        var text = ""
        var records: [(line: UInt32, function: Int, word: String, area: ProjectSearchQuery.Area)] = []
        var line: UInt32 = 1
        for function in 0..<3 {
            text += "fn f\(function)() {\n"; line += 1
            for _ in 0..<8 {
                let word = words[next(words.count)]
                let area = ProjectSearchQuery.Area.allCases[next(3)]
                switch area {
                case .code: text += "    \(word)();\n"
                case .comment: text += "    // \(word)\n"
                case .string: text += "    let s = \"\(word)\";\n"
                }
                records.append((line, function, word, area)); line += 1
            }
            text += "}\n"; line += 1
        }
        try text.write(to: root.appendingPathComponent("sample.rs"), atomically: true, encoding: .utf8)
        let session = try ProjectIndexer().index(root: root)
        let context = QueryContext(snapshotID: session.snapshotID, analysisProfileID: session.analysisProfile.id, generation: 0)
        for variant in 0..<8 {
            let near: Int? = variant & 1 == 0 ? nil : 3
            let same = variant & 2 != 0
            let filtered = variant & 4 != 0
            let query = ProjectSearchQuery(includes: [[.init(text: "alpha"), .init(text: "gamma")], [.init(text: "beta")]],
                excludes: [.init(text: "ban")], excludedAreas: filtered ? [.comment] : [], near: near, sameFunction: same)
            let allowed = records.filter { !filtered || $0.area != .comment }
            let expected = Set(allowed.filter { hit in
                guard hit.word != "ban" else { return false }
                let unit = allowed.filter {
                    (!same || hit.function == $0.function) && (near == nil || abs(Int(hit.line) - Int($0.line)) <= near!)
                }
                return unit.contains { $0.word == "alpha" || $0.word == "gamma" }
                    && unit.contains { $0.word == "beta" } && !unit.contains { $0.word == "ban" }
            }.map(\.line))
            var actual: Set<UInt32> = []
            for try await batch in try session.search(query, context: context) {
                #expect(batch.completeness == .complete)
                for hit in batch.matchesByPath.values.flatMap({ $0 }) {
                    actual.insert(hit.line)
                    #expect(hit.symbolName?.hasPrefix("f") == true)
                    #expect(!hit.conditionIndices.isEmpty)
                }
            }
            #expect(actual == expected, "seed=0xCA172026 variant=\(variant)")
        }
    }
}

@Test
func nearIsCenteredOnEachHitAndRegionsFilterBeforeLimits() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let text = String(repeating: "// alpha\n", count: 220) + "fn f() {\nalpha();\n\nbeta();\n\ngamma();\n}\n"
    try text.write(to: root.appendingPathComponent("sample.rs"), atomically: true, encoding: .utf8)
    let session = try ProjectIndexer().index(root: root)
    let context = QueryContext(snapshotID: session.snapshotID, analysisProfileID: session.analysisProfile.id, generation: 0)
    var hits: [SearchMatch] = []
    for try await batch in try session.search(ProjectSearchQuery.parse("alpha beta gamma near:2 in:code"), context: context) {
        hits += batch.matchesByPath.values.flatMap { $0 }
        #expect(batch.completeness == .complete)
    }
    #expect(hits.map(\.line) == [224])
    #expect(hits.first?.conditionIndices == [1])
}

@Test
func sameFunctionIncludesNestedClosuresButSeparatesNestedFunctions() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let text = """
    fn outer() {
        alpha();
        let closure = || { beta(); };
        fn nested() { ban(); }
    }
    fn other() { alpha(); ban(); }
    const RUN: fn() = || { alpha(); let nested = || { beta(); }; };
    """
    try text.write(to: root.appendingPathComponent("sample.rs"), atomically: true, encoding: .utf8)
    let session = try ProjectIndexer().index(root: root)
    let context = QueryContext(snapshotID: session.snapshotID, analysisProfileID: session.analysisProfile.id, generation: 0)
    var hits: [SearchMatch] = []
    for try await batch in try session.search(ProjectSearchQuery.parse("alpha beta -ban same:fn"), context: context) {
        hits += batch.matchesByPath.values.flatMap { $0 }
    }
    #expect(hits.map(\.line) == [2, 3, 7])
    #expect(hits.map(\.symbolName) == ["outer", "outer", nil])
}

@Test
func alternativeTermsShareConditionLimitsAndReportTruncation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "fn f() {\nalpha();\nbeta();\nalpha();\n}\n".write(
        to: root.appendingPathComponent("sample.rs"), atomically: true, encoding: .utf8)
    let session = try ProjectIndexer().index(root: root)
    let context = QueryContext(snapshotID: session.snapshotID, analysisProfileID: session.analysisProfile.id, generation: 0)
    let service = SnapshotSearchService(source: session, language: .rust, extractor: RustExtractor(), matchesPerFile: 2)
    var hits: [SearchMatch] = []
    var final: SearchBatch?
    for try await batch in try service.search(ProjectSearchQuery.parse("alpha OR beta"), context: context) {
        hits += batch.matchesByPath.values.flatMap { $0 }
        final = batch
    }
    #expect(hits.map(\.line) == [2, 3])
    #expect(final?.truncatedConditionIndices == [0])
    #expect(final?.truncatedPathIDs.count == 1)
    #expect(final?.completeness == .truncated)
}

@Test
func exclusionsRemainEffectivePastPositiveMatchLimits() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["a", "b", "c"] {
        try "fn f() { ban(); ban(); ban(); }\n".write(to: root.appendingPathComponent(name + ".rs"), atomically: true, encoding: .utf8)
    }
    try "fn early() { ban(); ban(); ban(); }\n\n\nfn late() { foo(); ban(); }\n".write(
        to: root.appendingPathComponent("z.rs"), atomically: true, encoding: .utf8)
    let session = try ProjectIndexer().index(root: root)
    let context = QueryContext(snapshotID: session.snapshotID, analysisProfileID: session.analysisProfile.id, generation: 0)
    let service = SnapshotSearchService(source: session, language: .rust, extractor: RustExtractor(), matchesPerFile: 2, totalMatches: 2)
    for suffix in ["", "near:0", "same:fn", "near:0 same:fn"] {
        var hits: [SearchMatch] = []
        var final: SearchBatch?
        for try await batch in try service.search(ProjectSearchQuery.parse("foo -ban " + suffix), context: context) {
            hits += batch.matchesByPath.values.flatMap { $0 }
            final = batch
        }
        #expect(hits.isEmpty, "Exclusion must not be capped: \(suffix)")
        #expect(final?.completeness == .complete)
    }
}

@Test
func singleTermFiltersPreserveEveryLiteralOccurrence() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "fn work() { foo(); foo(); foo(); }\n".write(to: root.appendingPathComponent("sample.rs"), atomically: true, encoding: .utf8)
    let session = try ProjectIndexer().index(root: root)
    let context = QueryContext(snapshotID: session.snapshotID, analysisProfileID: session.analysisProfile.id, generation: 0)
    var expected: [ByteRange] = []
    for try await batch in try session.search(ContentSearchQuery(pattern: "foo"), context: context) {
        expected += batch.matchesByPath.values.flatMap { $0 }.map(\.byteRange)
    }
    #expect(expected.count == 3)
    for text in ["\"foo\"", "foo path:sample.rs", "foo in:code", "foo -ban", "/foo/ path:sample.rs"] {
        var actual: [ByteRange] = []
        for try await batch in try session.search(ProjectSearchQuery.parse(text), context: context) {
            actual += batch.matchesByPath.values.flatMap { $0 }.map(\.byteRange)
        }
        #expect(actual == expected, "Preserve occurrences: \(text)")
    }
}

@Test
func unverifiedExclusionsNeverPublishPositiveResults() async throws {
    struct Source: SnapshotContentSource {
        let payload: [UInt8] = Array("foo foo ".utf8) + [0xFF]
        var manifest: SnapshotManifest
        init() {
            manifest = SnapshotManifest(snapshotID: SnapshotID(rawValue: UUID()), files: [
                FileOccurrence(occurrenceID: FileOccurrenceID(rawValue: 0), pathID: PathID(rawValue: 0),
                    contentID: ContentID.sha256(of: Array("foo foo ".utf8) + [0xFF]), detectedLanguage: .rust,
                    sourceKind: .tracked, fileMode: .regular, size: 9)
            ])
        }
        func bytes(for contentID: ContentID) -> [UInt8]? { payload }
        func path(for pathID: PathID) -> String? { "sample.rs" }
    }
    let source = Source()
    let context = QueryContext(snapshotID: source.manifest.snapshotID,
        analysisProfileID: AnalysisProfileID(rawValue: UUID()), generation: 0)
    for text in ["foo -/ban/", "foo foo -/ban/"] {
        var hits: [SearchMatch] = []
        var final: SearchBatch?
        for try await batch in try SnapshotSearchService(source: source).search(ProjectSearchQuery.parse(text), context: context) {
            hits += batch.matchesByPath.values.flatMap { $0 }
            final = batch
        }
        #expect(hits.isEmpty)
        #expect(final?.completeness == .truncated)
        #expect(final?.regexSkippedPathCount == 1)
    }
}

@Test
func resultSymbolsUseOwningTypeWithoutModulePrefixes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "mod imp { struct Mutex; impl Mutex { fn lock() { token(); } } fn free() { token(); } }\n".write(
        to: root.appendingPathComponent("sample.rs"), atomically: true, encoding: .utf8)
    let session = try ProjectIndexer().index(root: root)
    let context = QueryContext(snapshotID: session.snapshotID, analysisProfileID: session.analysisProfile.id, generation: 0)
    var names: [String?] = []
    for try await batch in try session.search(ProjectSearchQuery.parse("token"), context: context) {
        names += batch.matchesByPath.values.flatMap { $0 }.map(\.symbolName)
    }
    #expect(names == ["Mutex::lock", "free"])
}

@Test
func regionFilteredSearchKeepsDistinctGrammarsForIdenticalBytes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let text = "const x = <div>\n// ban\nfoo\n</div>;\n"
    for filename in ["a.ts", "b.tsx"] {
        try text.write(to: root.appendingPathComponent(filename), atomically: true, encoding: .utf8)
    }
    let session = try ProjectIndexer().index(root: root, language: .typescript)
    let context = QueryContext(snapshotID: session.snapshotID, analysisProfileID: session.analysisProfile.id, generation: 0)
    var paths: [String] = []
    for try await batch in try session.search(ProjectSearchQuery.parse("foo -ban in:code"), context: context) {
        paths += batch.matchesByPath.filter { !$0.value.isEmpty }.keys.map { session.paths.resolve($0) }
    }
    #expect(paths == ["a.ts"])
}

@Test
func nearbyExclusionsUseLineExistenceForDenseMatches() async throws {
    struct Source: SnapshotContentSource {
        let payload: [UInt8]
        let manifest: SnapshotManifest
        init() {
            payload = Array((String(repeating: "ban ", count: 100_000) + "\n" + String(repeating: "foo ", count: 200)).utf8)
            manifest = SnapshotManifest(snapshotID: SnapshotID(rawValue: UUID()), files: [
                FileOccurrence(occurrenceID: FileOccurrenceID(rawValue: 0), pathID: PathID(rawValue: 0),
                    contentID: ContentID.sha256(of: payload), detectedLanguage: .rust,
                    sourceKind: .tracked, fileMode: .regular, size: UInt64(payload.count))
            ])
        }
        func bytes(for contentID: ContentID) -> [UInt8]? { payload }
        func path(for pathID: PathID) -> String? { "sample.rs" }
    }
    let source = Source()
    let context = QueryContext(snapshotID: source.manifest.snapshotID,
        analysisProfileID: AnalysisProfileID(rawValue: UUID()), generation: 0)
    for distance in [0, 1] {
        var hits: [SearchMatch] = []
        var final: SearchBatch?
        for try await batch in try SnapshotSearchService(source: source).search(
            ProjectSearchQuery.parse("foo -ban near:\(distance)"), context: context) {
            hits += batch.matchesByPath.values.flatMap { $0 }
            final = batch
        }
        #expect(hits.count == (distance == 0 ? 1 : 0))
        if distance == 0 { #expect(hits.first?.conditionRanges[0]?.count == 200) }
        #expect(final?.completeness == .complete)
    }
    let expired = SnapshotSearchService(source: source, language: .rust, extractor: RustExtractor(), wallClockLimit: .zero)
    for try await batch in try expired.search(ProjectSearchQuery.parse("foo -ban near:0"), context: context) {
        #expect(batch.matchesByPath.isEmpty)
        #expect(batch.completeness == .truncated)
    }
}
