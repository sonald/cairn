import CodeInsightCore
@testable import CodeInsightEngine
import Foundation
import Testing

private let snapshotSearchRepositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

@Test
func snapshotSearchScansDuplicateContentOnceAndProjectsEveryPath() async throws {
    let source = FakeSnapshotSource([
        ("a.rs", Array("Alpha alpha ALPHA\n".utf8)),
        ("copy.rs", Array("Alpha alpha ALPHA\n".utf8)),
    ])
    let result = try await search(
        ContentSearchQuery(pattern: "alpha"),
        source: source
    )

    #expect(source.totalScanCount == 1)
    #expect(result.matches.count == 6)
    #expect(Set(result.matches.map(\.pathID)) == Set(source.manifest.files.map(\.pathID)))
    #expect(result.matches.map(\.column).sorted() == [1, 1, 7, 7, 13, 13])
    #expect(result.final.completeness == .complete)
}

@Test
func snapshotSearchHonorsCaseSensitivityAndRegex() async throws {
    let source = FakeSnapshotSource([
        ("main.rs", Array("Alpha alpha foo1 foo22\n".utf8)),
    ])
    let sensitive = try await search(
        ContentSearchQuery(pattern: "Alpha", caseSensitive: true),
        source: source
    )
    let regex = try await search(
        ContentSearchQuery(pattern: #"foo\d+"#, isRegex: true),
        source: source
    )

    #expect(sensitive.matches.count == 1)
    #expect(regex.matches.map(\.column) == [13, 18])

    var rejected = false
    do {
        _ = try SnapshotSearchService(source: source).search(
            ContentSearchQuery(pattern: "(", isRegex: true),
            context: context(for: source)
        )
    } catch {
        rejected = true
    }
    #expect(rejected)
}

@Test
func snapshotSearchCapsEachFileAtTwoHundredMatches() async throws {
    let source = FakeSnapshotSource([
        ("main.rs", Array(String(repeating: "x", count: 201).utf8)),
    ])
    let result = try await search(
        ContentSearchQuery(pattern: "x"),
        source: source
    )

    #expect(result.matches.count == 200)
    #expect(result.final.completeness == .truncated)
    #expect(result.final.truncatedPathIDs == Set(source.manifest.files.map(\.pathID)))
}

@Test
func snapshotSearchCapsAllFilesAtFiveThousandMatches() async throws {
    let bytes = Array(String(repeating: "x", count: 200).utf8)
    let source = FakeSnapshotSource((0..<26).map { ("file-\($0).rs", bytes) })
    let result = try await search(
        ContentSearchQuery(pattern: "x"),
        source: source
    )

    #expect(source.totalScanCount == 1)
    #expect(result.matches.count == 5_000)
    #expect(result.final.completeness == .truncated)
    #expect(result.final.truncatedPathIDs.count == 1)
}

@Test
func snapshotRegexSearchMarksOversizeAndInvalidUTF8FilesTruncated() async throws {
    let oversized = [UInt8](repeating: 0x61, count: 4 * 1_024 * 1_024 + 1)
    let source = FakeSnapshotSource([
        ("oversized.rs", oversized),
        ("invalid.rs", [0x66, 0x80, 0x6F]),
    ])
    let result = try await search(
        ContentSearchQuery(pattern: ".", isRegex: true),
        source: source
    )

    #expect(result.matches.isEmpty)
    #expect(result.final.completeness == .truncated)
    #expect(result.final.truncatedPathIDs == Set(source.manifest.files.map(\.pathID)))
}

@Test
func snapshotSearchTimesOutAfterASlowSourceRead() async throws {
    let source = FakeSnapshotSource(
        [("main.rs", Array("needle\n".utf8))],
        readDelay: 0.02
    )
    let service = SnapshotSearchService(
        source: source,
        wallClockLimit: .milliseconds(1)
    )
    let result = try await collect(
        try service.search(
            ContentSearchQuery(pattern: "needle"),
            context: context(for: source)
        )
    )

    #expect(result.matches.isEmpty)
    #expect(result.final.completeness == .truncated)
    #expect(result.final.truncatedPathIDs == Set(source.manifest.files.map(\.pathID)))
}

@Test
func snapshotSearchCancellationTerminatesConsumer() async throws {
    let source = FakeSnapshotSource(
        (0..<100).map { index in
            ("file-\(index).rs", Array("needle \(index)\n".utf8))
        },
        readDelay: 0.002
    )
    let stream = try SnapshotSearchService(source: source).search(
        ContentSearchQuery(pattern: "needle"),
        context: context(for: source)
    )
    let consumer = Task {
        for try await _ in stream {}
    }

    while source.totalScanCount == 0 { await Task.yield() }
    consumer.cancel()
    _ = await consumer.result

    #expect(source.totalScanCount < 100)
}

@Test
func snapshotSearchCentersLongLineExcerptOnMatch() async throws {
    let line = String(repeating: "a", count: 300)
        + "NEEDLE"
        + String(repeating: "b", count: 300)
    let source = FakeSnapshotSource([("main.rs", Array(line.utf8))])
    let result = try await search(
        ContentSearchQuery(pattern: "NEEDLE", caseSensitive: true),
        source: source
    )
    let match = try #require(result.matches.first)

    #expect(match.lineText.utf8.count == 240)
    #expect(match.lineTextRange == ByteRange(lowerBound: 183, upperBound: 423))
    #expect(match.byteRange.lowerBound - match.lineTextRange.lowerBound == 117)
    #expect(match.lineText.contains("NEEDLE"))
    #expect(match.lineText.first == "a")
    #expect(match.lineText.last == "b")
}

@Test
func snapshotContentSearchCLIAlignsWithGrepSample() throws {
    let fixture = snapshotSearchRepositoryRoot.appendingPathComponent(
        "Tests/RustExtractorTests/Fixtures/use_alias"
    )
    let cli = try runProcess(
        snapshotSearchRepositoryRoot.appendingPathComponent(".build/debug/codeinsight"),
        arguments: ["search", "connect", "--project", fixture.path]
    )
    let grep = try runProcess(
        URL(fileURLWithPath: "/usr/bin/grep"),
        arguments: ["-rn", "--include=*.rs", "connect", fixture.path]
    )

    for sample in ["db.rs:1", "main.rs:2"] {
        #expect(grep.contains(sample))
        #expect(cli.contains("\(sample):"))
    }
    #expect(cli.contains("2 matches in 2 files"))
}

private final class FakeSnapshotSource: SnapshotContentSource, @unchecked Sendable {
    let manifest: SnapshotManifest
    private let contents: [ContentID: [UInt8]]
    private let readDelay: TimeInterval
    private let lock = NSLock()
    private var scanCounts: [ContentID: Int] = [:]

    init(
        _ files: [(path: String, bytes: [UInt8])],
        readDelay: TimeInterval = 0
    ) {
        var contents: [ContentID: [UInt8]] = [:]
        let occurrences = files.enumerated().map { offset, file in
            let contentID = ContentID.sha256(of: file.bytes)
            contents[contentID] = file.bytes
            return FileOccurrence(
                occurrenceID: FileOccurrenceID(rawValue: UInt32(offset)),
                pathID: PathID(rawValue: UInt32(offset)),
                contentID: contentID,
                detectedLanguage: .rust,
                sourceKind: .untracked,
                fileMode: .regular,
                size: UInt64(file.bytes.count)
            )
        }
        manifest = SnapshotManifest(
            snapshotID: SnapshotID(rawValue: UUID()),
            files: occurrences
        )
        self.contents = contents
        self.readDelay = readDelay
    }

    var totalScanCount: Int {
        lock.withLock { scanCounts.values.reduce(0, +) }
    }

    func bytes(for contentID: ContentID) -> [UInt8]? {
        lock.withLock { scanCounts[contentID, default: 0] += 1 }
        if readDelay > 0 { Thread.sleep(forTimeInterval: readDelay) }
        return contents[contentID]
    }
}

private func search(
    _ query: ContentSearchQuery,
    source: FakeSnapshotSource
) async throws -> (matches: [SearchMatch], final: SearchBatch) {
    try await collect(try SnapshotSearchService(source: source).search(
        query,
        context: context(for: source)
    ))
}

private func collect(
    _ stream: AsyncThrowingStream<SearchBatch, Error>
) async throws -> (matches: [SearchMatch], final: SearchBatch) {
    var matches: [SearchMatch] = []
    var final: SearchBatch?
    for try await batch in stream {
        for pathMatches in batch.matchesByPath.values {
            matches.append(contentsOf: pathMatches)
        }
        if batch.isFinal { final = batch }
    }
    return (matches, try #require(final))
}

private func context(for source: FakeSnapshotSource) -> QueryContext {
    QueryContext(
        snapshotID: source.manifest.snapshotID,
        analysisProfileID: AnalysisProfileID(rawValue: UUID()),
        generation: 1
    )
}

private func runProcess(_ executable: URL, arguments: [String]) throws -> String {
    let process = Process()
    let output = Pipe()
    let errors = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw ProcessFailure.failed(
            String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }
    return String(
        decoding: output.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self
    )
}

private enum ProcessFailure: Error {
    case failed(String)
}
