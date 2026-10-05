import CodeInsightCore
import CodeInsightRustExtractor
@testable import CodeInsightEngine
import Dispatch
import Foundation
import Testing

@Test
func parallelSnapshotSearchMatchesSingleWorkerIncludingTruncation() async throws {
    let root = try parallelSearchFixture([
        "// needle NEEDLE needle_suffix needle\nfn a() {}\n",
        "// nothing here\nfn b() {}\n",
        "// needle NEEDLE needle_suffix needle\nfn a() {}\n",
        "// 源 needle\n// needle needle needle\nfn c() {}\n",
        "// needle needle\nfn d() {}\n",
        "// no matches\nfn e() {}\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try ProjectIndexer(parallelism: 1).index(root: root)
    #expect(session.manifest.files.count == 6)
    #expect(Set(session.manifest.files.map(\.contentID)).count == 5)
    let queries = [
        ContentSearchQuery(pattern: "needle"),
        ContentSearchQuery(pattern: "needle", caseSensitive: true),
        ContentSearchQuery(pattern: "needle", wholeWord: true),
        ContentSearchQuery(pattern: "needle", isRegex: true),
        ContentSearchQuery(pattern: "needle", isRegex: true, wholeWord: true),
    ]
    for query in queries {
        for (fileLimit, totalLimit) in [(200, 5_000), (2, 5_000), (200, 5), (2, 5)] {
            let serial = try await parallelSearchResult(
                source: session, query: query, workers: 1,
                fileLimit: fileLimit, totalLimit: totalLimit
            )
            let parallel = try await parallelSearchResult(
                source: session, query: query, workers: 4,
                fileLimit: fileLimit, totalLimit: totalLimit
            )
            #expect(!serial.matches.isEmpty)
            #expect(parallel.matches.count == serial.matches.count)
            for (actual, expected) in zip(parallel.matches, serial.matches) {
                #expect(actual.pathID == expected.pathID)
                #expect(actual.byteRange == expected.byteRange)
                #expect(actual.line == expected.line)
                #expect(actual.column == expected.column)
                #expect(actual.lineText == expected.lineText)
                #expect(actual.lineTextRange == expected.lineTextRange)
            }
            #expect(parallel.final.completeness == serial.final.completeness)
            #expect(parallel.final.truncatedPathIDs == serial.final.truncatedPathIDs)
            #expect(parallel.final.searchedPathCount == serial.final.searchedPathCount)
            #expect(parallel.final.excludedPathCount == serial.final.excludedPathCount)
            #expect(parallel.final.completeness == (fileLimit == 200 && totalLimit == 5_000 ? .complete : .truncated))
        }
    }
}

@Test
func parallelSnapshotSearchRegexDeadlineStopsUnsuccessfulBacktracking() async throws {
    let root = try parallelSearchFixture(["// " + String(repeating: "a", count: 4_000) + "!\n"])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try ProjectIndexer(parallelism: 1).index(root: root)
    let stream = try SnapshotSearchService(
        source: session, language: .rust, extractor: RustExtractor(),
        wallClockLimit: .milliseconds(10), workerCount: 4
    ).search(ContentSearchQuery(pattern: "(a+)+$", isRegex: true), context: QueryContext(
        snapshotID: session.snapshotID,
        analysisProfileID: AnalysisProfileID(rawValue: UUID()), generation: 1
    ))
    var final: SearchBatch?
    let start = ContinuousClock.now
    for try await batch in stream {
        #expect(batch.matchesByPath.isEmpty)
        if batch.isFinal { final = batch }
    }
    #expect(start.duration(to: .now) < .seconds(2))
    #expect(try #require(final).completeness == .truncated)
    #expect(final?.truncatedPathIDs == Set(session.manifest.files.map(\.pathID)))
}

@Test
func parallelSnapshotSearchCancellationStopsAllReadersAndBatches() async throws {
    let root = try parallelSearchFixture((0..<16).map { "// needle \($0)\n" })
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try ProjectIndexer(parallelism: 1).index(root: root)
    let source = PausedSearchSource(session: session, blocked: Set(session.manifest.files.map(\.contentID)))
    defer { source.releaseAll() }
    let stream = try parallelSearchStream(source: source, workers: 4)
    let consumer = Task {
        defer { source.recordFinished() }
        do {
            for try await batch in stream { source.record(batch) }
        } catch is CancellationError {}
    }
    defer { consumer.cancel() }
    try await waitForSearchCondition { source.pausedCount == 4 }
    consumer.cancel()
    try await waitForSearchCondition { source.finished }
    #expect(source.batches.isEmpty)
    source.releaseAll()
    try await waitForSearchCondition { source.cancelledReadCount == 4 }
    #expect(source.readCount == 4, "Each cancelled worker must stop before reading its next file")
    #expect(source.batches.isEmpty, "No batch may arrive after cancellation")
    try await consumer.value
}

@Test
func parallelSnapshotSearchPublishesFirstHitAndFlushesPendingHitsWhileReaderWaits() async throws {
    let root = try parallelSearchFixture((0..<3).map { "// needle \($0)\n" })
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try ProjectIndexer(parallelism: 1).index(root: root)
    let files = session.manifest.files
    let source = PausedSearchSource(session: session, blocked: Set(files.dropFirst().map(\.contentID)))
    defer { source.releaseAll() }
    let stream = try parallelSearchStream(source: source, workers: 1)
    let consumer = Task {
        defer { source.recordFinished() }
        for try await batch in stream { source.record(batch) }
    }
    defer { consumer.cancel() }
    // With the second file held, the first hit must be published without waiting
    // for the file/match thresholds or completion of the source scan.
    try await waitForSearchCondition { source.pausedCount == 1 && source.batches.count == 1 }
    #expect(source.batches[0].isFinal == false)
    #expect(Set(source.batches[0].matchesByPath.keys) == [files[0].pathID])
    source.release(files[1].contentID)
    // The third file stays blocked. Only the 50 ms timer can flush the second
    // file's single pending hit: neither the 16-file nor 200-match threshold is met.
    try await waitForSearchCondition { source.pausedCount == 2 && source.batches.count == 2 }
    #expect(source.batches[1].isFinal == false)
    #expect(Set(source.batches[1].matchesByPath.keys) == [files[1].pathID])
    #expect(!source.finished)
    source.release(files[2].contentID)
    try await waitForSearchCondition { source.finished }
    try await consumer.value
    #expect(source.batches.last?.isFinal == true)
    #expect(source.batches.last?.completeness == .complete)
}

private func parallelSearchFixture(_ contents: [String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("parallel-search-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for (index, content) in contents.enumerated() {
        try content.write(to: root.appendingPathComponent(String(format: "%03d.rs", index)), atomically: true, encoding: .utf8)
    }
    return root
}

private func parallelSearchStream(
    source: any SnapshotContentSource,
    query: ContentSearchQuery = ContentSearchQuery(pattern: "needle"),
    workers: Int,
    fileLimit: Int = 200,
    totalLimit: Int = 5_000
) throws -> AsyncThrowingStream<SearchBatch, Error> {
    try SnapshotSearchService(
        source: source, language: .rust, extractor: RustExtractor(),
        workerCount: workers, matchesPerFile: fileLimit, totalMatches: totalLimit
    ).search(query, context: QueryContext(
        snapshotID: source.manifest.snapshotID,
        analysisProfileID: AnalysisProfileID(rawValue: UUID()), generation: 1
    ))
}

private func parallelSearchResult(
    source: any SnapshotContentSource,
    query: ContentSearchQuery,
    workers: Int,
    fileLimit: Int,
    totalLimit: Int
) async throws -> (matches: [SearchMatch], final: SearchBatch) {
    var matches: [SearchMatch] = []
    var final: SearchBatch?
    for try await batch in try parallelSearchStream(
        source: source, query: query, workers: workers, fileLimit: fileLimit, totalLimit: totalLimit
    ) {
        matches.append(contentsOf: batch.matchesByPath.values.flatMap { $0 })
        if batch.isFinal { final = batch }
    }
    // Dictionary order and batch boundaries are unspecified; compare every
    // retained occurrence and its coordinates in a stable path/range order.
    matches.sort {
        $0.pathID.rawValue == $1.pathID.rawValue
            ? $0.byteRange.lowerBound < $1.byteRange.lowerBound
            : $0.pathID.rawValue < $1.pathID.rawValue
    }
    return (matches, try #require(final))
}

private func waitForSearchCondition(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    try #require(condition(), "Search did not make progress within two seconds")
}

private final class PausedSearchSource: SnapshotContentSource, @unchecked Sendable {
    private let session: EngineSession
    private let gates: [ContentID: DispatchSemaphore]
    private let lock = NSLock()
    private var reads = 0
    private var paused = 0
    private var cancelledReads = 0
    private var received: [SearchBatch] = []
    private var consumerFinished = false

    init(session: EngineSession, blocked: Set<ContentID>) {
        self.session = session
        gates = Dictionary(uniqueKeysWithValues: blocked.map { ($0, DispatchSemaphore(value: 0)) })
    }

    var manifest: SnapshotManifest { session.manifest }
    var readCount: Int { lock.withLock { reads } }
    var pausedCount: Int { lock.withLock { paused } }
    var cancelledReadCount: Int { lock.withLock { cancelledReads } }
    var batches: [SearchBatch] { lock.withLock { received } }
    var finished: Bool { lock.withLock { consumerFinished } }
    func path(for pathID: PathID) -> String? { session.path(for: pathID) }
    func record(_ batch: SearchBatch) { lock.withLock { received.append(batch) } }
    func recordFinished() { lock.withLock { consumerFinished = true } }
    func release(_ contentID: ContentID) { gates[contentID]?.signal() }
    func releaseAll() { for gate in gates.values { gate.signal() } }

    func bytes(for contentID: ContentID) -> [UInt8]? {
        lock.withLock { reads += 1 }
        if let gate = gates[contentID] {
            lock.withLock { paused += 1 }
            // A test failure must never strand an executor thread indefinitely.
            _ = gate.wait(timeout: .now() + 3)
            if Task.isCancelled { lock.withLock { cancelledReads += 1 } }
        }
        return session.bytes(for: contentID)
    }
}
