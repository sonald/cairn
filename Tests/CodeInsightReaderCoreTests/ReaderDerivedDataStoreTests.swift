import CodeInsightCore
import CodeInsightReaderCore
import Foundation
import Testing

actor ReadonlyBuildGate {
    private var started = 0
    private var pending: [Int: CheckedContinuation<Void, Error>] = [:]
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []
    private var cancellations = 0
    private var cancellationObserver: CheckedContinuation<Void, Never>?
    let respectsCancellation: Bool

    init(respectsCancellation: Bool = true) { self.respectsCancellation = respectsCancellation }

    func build(_ document: ReaderDocument) async throws -> IdentifierIndex {
        started += 1
        let ordinal = started
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                pending[ordinal] = continuation
                let ready = observers.filter { $0.0 <= started }
                observers.removeAll { $0.0 <= started }
                for (_, observer) in ready { observer.resume() }
            }
        } onCancel: {
            Task { await self.cancel(ordinal) }
        }
        // For the stale-result test deliberately finish an uncancellable builder.
        if !respectsCancellation {
            return try await Task.detached { try IdentifierIndex(document: document) }.value
        }
        return try IdentifierIndex(document: document)
    }

    func waitUntilStarted(_ count: Int) async {
        if started >= count { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }

    func finish(_ ordinal: Int, error: (any Error)? = nil) {
        guard let continuation = pending.removeValue(forKey: ordinal) else { return }
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
    }

    private func cancel(_ ordinal: Int) {
        cancellations += 1
        cancellationObserver?.resume()
        cancellationObserver = nil
        if respectsCancellation { finish(ordinal, error: CancellationError()) }
    }

    func waitForCancellation() async {
        if cancellations > 0 { return }
        await withCheckedContinuation { cancellationObserver = $0 }
    }
}

private func readonlyKey(_ document: ReaderDocument, phase: ReaderAnalysisKey.Phase = .syntax) -> ReaderAnalysisKey {
    ReaderAnalysisKey(contentID: document.contentID, languageMode: document.languageMode, phase: phase)
}

@Test
func readonlyIdentifierAnalysisKeysSeparatePhaseVersionLanguageAndCustomDocuments() {
    let document = ReaderDocument(bytes: Array("value value".utf8))
    let syntax = readonlyKey(document)
    #expect(syntax == readonlyKey(document))
    #expect(syntax != readonlyKey(document, phase: .plain))
    #expect(syntax != ReaderAnalysisKey(contentID: document.contentID, languageMode: document.languageMode,
                                       readerVersion: 2, phase: .syntax))
    #expect(syntax != ReaderAnalysisKey(contentID: document.contentID,
                                       languageMode: .init(language: .typescript, variant: "tsx"), phase: .syntax))
    let custom = ReaderAnalysisKey(contentID: document.contentID, languageMode: document.languageMode)
    #expect(custom != ReaderAnalysisKey(contentID: document.contentID, languageMode: document.languageMode))
}

@Test
func readonlyIdentifierSharedBuildSurvivesOneSubscriberCancellation() async throws {
    let gate = ReadonlyBuildGate()
    let store = ReaderDerivedDataStore(builder: { try await gate.build($0) })
    let document = ReaderDocument(bytes: Array("value value".utf8))
    let first = await store.subscribe(key: readonlyKey(document), document: document)
    let second = await store.subscribe(key: readonlyKey(document), document: document)
    await gate.waitUntilStarted(1)
    await store.cancel(first)
    await gate.finish(1)
    let result = try await store.value(for: second)
    #expect(result.occurrences(at: 0).count == 2)
    #expect(await store.statistics.buildCount == 1)
    #expect(await store.statistics.subscriptionCount == 1)
    do { _ = try await store.value(for: first); Issue.record("Cancelled subscription returned a result") }
    catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
    await store.cancel(second)
}

@Test
func readonlyIdentifierLastSubscriberCancelsWorkerAndReleasesEntry() async {
    let gate = ReadonlyBuildGate()
    let store = ReaderDerivedDataStore(builder: { try await gate.build($0) })
    let document = ReaderDocument(bytes: Array("value".utf8))
    let token = await store.subscribe(key: readonlyKey(document), document: document)
    await gate.waitUntilStarted(1)
    await store.cancel(token)
    await gate.waitForCancellation()
    #expect(await store.statistics.entryCount == 0)
    #expect(await store.statistics.subscriptionCount == 0)
    #expect(await store.statistics.inFlightCount == 0)
}

@Test
func readonlyIdentifierCacheEvictsLeastRecentlyUsedIdleResult() async throws {
    let a = ReaderDocument(bytes: Array("alpha alpha".utf8))
    let b = ReaderDocument(bytes: Array("bravo bravo".utf8))
    let c = ReaderDocument(bytes: Array("charm charm".utf8))
    let cost = max(256, try IdentifierIndex(document: a).estimatedByteCount)
    let store = ReaderDerivedDataStore(byteBudget: cost * 2)
    for document in [a, b, a, c, a] {
        let token = await store.subscribe(key: readonlyKey(document), document: document)
        _ = try await store.value(for: token)
        await store.cancel(token)
    }
    #expect(await store.statistics.buildCount == 3)
    #expect(await store.statistics.retainedDerivedBytes <= cost * 2)
    let bAgain = await store.subscribe(key: readonlyKey(b), document: b)
    _ = try await store.value(for: bAgain)
    #expect(await store.statistics.buildCount == 4)
    await store.cancel(bAgain)
}

@Test
func readonlyIdentifierOversizedActiveResultDoesNotRebuildUntilReleased() async throws {
    let document = ReaderDocument(bytes: Array("value value value".utf8))
    let store = ReaderDerivedDataStore(byteBudget: 1)
    let first = await store.subscribe(key: readonlyKey(document), document: document)
    _ = try await store.value(for: first)
    let second = await store.subscribe(key: readonlyKey(document), document: document)
    _ = try await store.value(for: second)
    #expect(await store.statistics.buildCount == 1)
    #expect(await store.statistics.activeOverBudgetBytes > 0)
    await store.cancel(first)
    #expect(await store.statistics.entryCount == 1)
    await store.cancel(second)
    #expect(await store.statistics.entryCount == 0)
    #expect(await store.statistics.retainedDerivedBytes == 0)
}

@Test
func readonlyIdentifierFailedBuildCanBeRetriedAfterUnsubscribe() async throws {
    let gate = ReadonlyBuildGate()
    let store = ReaderDerivedDataStore(builder: { try await gate.build($0) })
    let document = ReaderDocument(bytes: Array("value".utf8))
    let first = await store.subscribe(key: readonlyKey(document), document: document)
    await gate.waitUntilStarted(1)
    await gate.finish(1, error: CocoaError(.fileReadCorruptFile))
    do { _ = try await store.value(for: first); Issue.record("Failed builder returned a result") }
    catch { #expect((error as? CocoaError)?.code == .fileReadCorruptFile) }
    await store.cancel(first)
    let retry = await store.subscribe(key: readonlyKey(document), document: document)
    await gate.waitUntilStarted(2)
    await gate.finish(2)
    #expect(try await store.value(for: retry).occurrences(at: 0).count == 1)
    #expect(await store.statistics.buildCount == 2)
    await store.cancel(retry)
}

@Test
func readonlyIdentifierOldSubscriptionCannotPublishIntoReopenedSameKey() async throws {
    let gate = ReadonlyBuildGate(respectsCancellation: false)
    let store = ReaderDerivedDataStore(builder: { try await gate.build($0) })
    let a = ReaderDocument(bytes: Array("alpha alpha".utf8))
    let b = ReaderDocument(bytes: Array("bravo".utf8))
    let old = await store.subscribe(key: readonlyKey(a), document: a)
    let oldValue = Task { try await store.value(for: old) }
    await gate.waitUntilStarted(1)
    await store.cancel(old)
    let middle = await store.subscribe(key: readonlyKey(b), document: b)
    await gate.waitUntilStarted(2)
    let reopened = await store.subscribe(key: readonlyKey(a), document: a)
    await gate.waitUntilStarted(3)
    await gate.finish(1)
    do { _ = try await oldValue.value; Issue.record("Old subscription published") }
    catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
    #expect(await store.statistics.subscriptionCount == 2)
    await gate.finish(3)
    #expect(try await store.value(for: reopened).occurrences(at: 0).count == 2)
    await gate.finish(2)
    _ = try await store.value(for: middle)
    await store.cancel(middle)
    await store.cancel(reopened)
}

@Test
func readonlyIdentifierCacheBoundsTinyEntriesAndAccountsForRetainedSource() async throws {
    let empty = ReaderDocument(bytes: [])
    let store = ReaderDerivedDataStore(byteBudget: 1_000_000)
    for _ in 0..<129 {
        let key = ReaderAnalysisKey(contentID: empty.contentID, languageMode: empty.languageMode)
        let token = await store.subscribe(key: key, document: empty)
        _ = try await store.value(for: token)
        await store.cancel(token)
    }
    #expect(await store.statistics.entryCount == 128)
    #expect(await store.statistics.retainedDerivedBytes == 128 * 256)
    let source = ReaderDocument(bytes: Array(repeating: 32, count: 100_000))
    #expect(try IdentifierIndex(document: source).estimatedByteCount >= source.bytes.count)
}

@Test
func readonlyIdentifierCacheRollbackKeepsResultsAndReleasesEachBuild() async throws {
    let document = ReaderDocument(bytes: Array("alpha alpha".utf8))
    let store = ReaderDerivedDataStore(reuseCachedData: false)
    let first = await store.subscribe(key: document.analysisKey, document: document)
    let second = await store.subscribe(key: document.analysisKey, document: document)
    let a = try await store.value(for: first)
    let b = try await store.value(for: second)
    #expect(Array(a.occurrences(at: 0)) == Array(b.occurrences(at: 0)))
    #expect(a.occurrences(at: 0).count == 2)
    #expect(await store.statistics.buildCount == 2)
    await store.cancel(first)
    await store.cancel(second)
    #expect(await store.statistics.entryCount == 0)
}
