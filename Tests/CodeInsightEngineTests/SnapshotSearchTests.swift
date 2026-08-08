import CodeInsightCore
import CodeInsightRustExtractor
@testable import CodeInsightEngine
import Dispatch
import Foundation
import os
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

#if DEBUG
@Test
func snapshotReferenceSearchParsesUniqueContentOnceAndRejectsTokenSpoofs()
    async throws
{
    let bytes = Array("""
        fn foo() {}
        fn call_site() { foo(); }
        const TEXT: &str = "foo";
        // foo
        /* foo */
        fn foo_suffix() {}
        """.utf8)
    let source = FakeSnapshotSource([
        ("a.rs", bytes),
        ("copy.rs", bytes),
    ])
    let parseCount = OSAllocatedUnfairLock(initialState: 0)

    let result = try await RustExtractor.$parseObserver.withValue({
        parseCount.withLock { $0 += 1 }
    }) {
        try await referenceSearch(
            ContentSearchQuery(pattern: "foo", caseSensitive: true),
            source: source,
            excludingPathID: source.manifest.files[0].pathID,
            excludingRange: ByteRange(lowerBound: 3, upperBound: 6)
        )
    }

    #expect(parseCount.withLock { $0 } == 1)
    #expect(result.matches.count == 3)
    #expect(result.matches.map(\.line).sorted() == [1, 2, 2])
    #expect(result.matches.allSatisfy { $0.line <= 2 })
    #expect(result.final.completeness == .complete)
}
#endif

@Test
func snapshotReferenceSearchAppliesCapsAfterIdentifierVerification() async throws {
    let source = FakeSnapshotSource([
        (
            "main.rs",
            Array((
                String(repeating: "// Foo\n", count: 5_001)
                    + "fn use_foo() { Foo; }\n"
            ).utf8)
        ),
    ])

    let result = try await referenceSearch(
        ContentSearchQuery(pattern: "Foo", caseSensitive: true),
        source: source,
        excludingPathID: source.manifest.files[0].pathID,
        excludingRange: ByteRange(lowerBound: 0, upperBound: 0)
    )

    #expect(result.matches.count == 1)
    #expect(result.matches.first?.line == 5_002)
    #expect(result.final.completeness == .complete)
}

@Test
func snapshotReferenceSearchMarksVerifiedResultCapPartial() async throws {
    let source = FakeSnapshotSource([
        (
            "main.rs",
            Array((
                "fn f() {\n"
                    + String(repeating: "    foo;\n", count: 201)
                    + "}\n"
            ).utf8)
        ),
    ])

    let result = try await referenceSearch(
        ContentSearchQuery(pattern: "foo", caseSensitive: true),
        source: source,
        excludingPathID: source.manifest.files[0].pathID,
        excludingRange: ByteRange(lowerBound: 0, upperBound: 0)
    )

    #expect(result.matches.count == 200)
    #expect(result.final.completeness == .truncated)
    #expect(result.final.truncatedPathIDs == [source.manifest.files[0].pathID])
}

@Test
func snapshotReferenceSearchMarksTimeoutPartial() async throws {
    let source = FakeSnapshotSource(
        [("main.rs", Array("fn f() { foo; }\n".utf8))],
        readDelay: 0.02
    )
    let service = SnapshotSearchService(
        source: source,
        wallClockLimit: .milliseconds(1)
    )

    let result = try await collect(try service.searchReferences(
        ContentSearchQuery(pattern: "foo", caseSensitive: true),
        excludingPathID: source.manifest.files[0].pathID,
        excludingRange: ByteRange(lowerBound: 0, upperBound: 0),
        context: context(for: source)
    ))

    #expect(result.matches.isEmpty)
    #expect(result.final.completeness == .truncated)
    #expect(result.final.truncatedPathIDs == [source.manifest.files[0].pathID])
}

@Test
func snapshotReferenceSearchCancellationTerminatesConsumer() async throws {
    let source = FakeSnapshotSource(
        (0..<100).map { index in
            ("file-\(index).rs", Array("fn f\(index)() { needle; }\n".utf8))
        },
        pauseAtScanCount: 3
    )
    let stream = try SnapshotSearchService(source: source).searchReferences(
        ContentSearchQuery(pattern: "needle", caseSensitive: true),
        excludingPathID: source.manifest.files[0].pathID,
        excludingRange: ByteRange(lowerBound: 0, upperBound: 0),
        context: context(for: source)
    )
    let consumer = Task {
        for try await _ in stream {}
    }

    source.waitForPausedScan()
    consumer.cancel()
    _ = await consumer.result
    source.resumePausedScan()

    #expect(source.cancellationObservedAfterPause)
    #expect(source.totalScanCount == 3)
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
        pauseAtScanCount: 3
    )
    let stream = try SnapshotSearchService(source: source).search(
        ContentSearchQuery(pattern: "needle"),
        context: context(for: source)
    )
    let consumer = Task {
        for try await _ in stream {}
    }

    source.waitForPausedScan()
    consumer.cancel()
    _ = await consumer.result
    source.resumePausedScan()

    #expect(source.cancellationObservedAfterPause)
    #expect(source.totalScanCount == 3)
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
    private let pauseAtScanCount: Int?
    private let scanPaused = DispatchSemaphore(value: 0)
    private let resumeScan = DispatchSemaphore(value: 0)
    private let resumedScan = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var scanCounts: [ContentID: Int] = [:]
    private var observedCancellationAfterPause = false

    init(
        _ files: [(path: String, bytes: [UInt8])],
        readDelay: TimeInterval = 0,
        pauseAtScanCount: Int? = nil
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
        self.pauseAtScanCount = pauseAtScanCount
    }

    var totalScanCount: Int {
        lock.withLock { scanCounts.values.reduce(0, +) }
    }

    var cancellationObservedAfterPause: Bool {
        lock.withLock { observedCancellationAfterPause }
    }

    func waitForPausedScan() {
        scanPaused.wait()
    }

    func resumePausedScan() {
        resumeScan.signal()
        resumedScan.wait()
    }

    func bytes(for contentID: ContentID) -> [UInt8]? {
        let shouldPause = lock.withLock {
            scanCounts[contentID, default: 0] += 1
            return scanCounts.values.reduce(0, +) == pauseAtScanCount
        }
        if shouldPause {
            scanPaused.signal()
            resumeScan.wait()
            lock.withLock { observedCancellationAfterPause = Task.isCancelled }
            resumedScan.signal()
        }
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

private func referenceSearch(
    _ query: ContentSearchQuery,
    source: FakeSnapshotSource,
    excludingPathID: PathID,
    excludingRange: ByteRange
) async throws -> (matches: [SearchMatch], final: SearchBatch) {
    try await collect(try SnapshotSearchService(source: source).searchReferences(
        query,
        excludingPathID: excludingPathID,
        excludingRange: excludingRange,
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
