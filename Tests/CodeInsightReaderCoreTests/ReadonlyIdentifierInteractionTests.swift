import AppKit
import CodeInsightCore
import CodeInsightReaderCore
import CodeInsightReaderUI
import Foundation
import Testing

@MainActor
@Test(.isolatedReaderWorkCounters)
func readonlyIdentifierPendingClicksPublishOnlyLatestIntentWithoutHotScans() async throws {
    let gate = ReadonlyBuildGate()
    let store = ReaderDerivedDataStore(builder: { try await gate.build($0) })
    let document = ReaderDocument(bytes: Array("alpha alpha beta beta beta".utf8))
    let reader = ReaderTextView(derivedDataStore: store)
    reader.display(document: document)
    await gate.waitUntilStarted(1)
    #expect(reader.identifierPreparationState == .building)
    #expect(reader.activate(atByteOffset: 0) == 0)
    #expect(reader.activate(atByteOffset: 12) == 0)
    var settings = ReaderSettings()
    settings.theme = .dark
    reader.apply(settings: settings)
    await gate.finish(1)
    await reader.waitForIdentifierPreparation()
    #expect(reader.identifierPreparationState == .ready)
    #expect(reader.occurrenceCount == 3)
    #expect(reader.view.selectedRange() == NSRange(location: 12, length: 4))
    let before = ReaderWorkCounters.snapshot()
    for _ in 0..<20 { #expect(reader.activate(atByteOffset: 0) == 2) }
    reader.setFindMatches([ByteRange(lowerBound: 0, upperBound: 5)], selectedIndex: 0)
    reader.clearFindMatches(restoringSymbolAt: 12)
    let after = ReaderWorkCounters.snapshot()
    #expect(reader.occurrenceCount == 3)
    #expect(before.identifierScannedBytes == after.identifierScannedBytes)
    #expect(before.identifierBuildCount == after.identifierBuildCount)
    #expect(await store.statistics.buildCount == 1)
    reader.clear()
}

@MainActor
@Test
func readonlyIdentifierClearedIntentDoesNotReplaceLaterSelection() async {
    let gate = ReadonlyBuildGate()
    let store = ReaderDerivedDataStore(builder: { try await gate.build($0) })
    let reader = ReaderTextView(derivedDataStore: store)
    reader.display(document: ReaderDocument(bytes: Array("alpha alpha".utf8)))
    await gate.waitUntilStarted(1)
    _ = reader.activate(atByteOffset: 0)
    reader.clearOccurrences()
    reader.view.setSelectedRange(NSRange(location: 2, length: 6))
    await gate.finish(1)
    await reader.waitForIdentifierPreparation()
    #expect(reader.view.selectedRange() == NSRange(location: 2, length: 6))
    #expect(reader.occurrenceCount == 0)
    reader.clear()
}

@MainActor
@Test
func readonlyIdentifierTwoViewsShareBuildAndClosedViewDoesNotReceiveIt() async {
    let gate = ReadonlyBuildGate()
    let store = ReaderDerivedDataStore(builder: { try await gate.build($0) })
    let document = ReaderDocument(bytes: Array("alpha alpha".utf8))
    let first = ReaderTextView(derivedDataStore: store)
    let second = ReaderTextView(derivedDataStore: store)
    first.display(document: document)
    second.display(document: document)
    await gate.waitUntilStarted(1)
    _ = first.activate(atByteOffset: 0)
    _ = second.activate(atByteOffset: 0)
    first.clear()
    await gate.finish(1)
    await second.waitForIdentifierPreparation()
    #expect(second.occurrenceCount == 2)
    #expect(first.identifierPreparationState == .notRequested)
    #expect(first.displayedBytes == nil)
    #expect(await store.statistics.buildCount == 1)
    second.clear()
}

@MainActor
@Test
func readonlyIdentifierSyntaxUpgradeUsesNewExclusionsAndIsolatedCustomIdentity() async throws {
    let bytes = Array("let alpha = 1; // alpha\nalpha".utf8)
    let plain = ReaderDocument(bytes: bytes)
    let loader = DocumentLoader(source: { _ in bytes })
    let syntax = try loader.load(file: URL(fileURLWithPath: "/syntax.rs")).document
    #expect(plain.contentID == syntax.contentID)
    #expect(plain.analysisKey != syntax.analysisKey)
    #expect(syntax.analysisKey.phase == .syntax)
    #expect(plain.analysisKey != ReaderDocument(bytes: bytes).analysisKey)
    let reader = ReaderTextView()
    reader.display(document: plain)
    await reader.waitForIdentifierPreparation()
    #expect(reader.activate(atByteOffset: 4) == 3)
    reader.updateSyntax(document: syntax)
    #expect(reader.identifierPreparationState == .building)
    await reader.waitForIdentifierPreparation()
    #expect(reader.occurrenceCount == 2)
    reader.clear()
}

@MainActor
@Test
func readonlyIdentifierReopenedDocumentIgnoresOldViewSubscription() async {
    let gate = ReadonlyBuildGate(respectsCancellation: false)
    let store = ReaderDerivedDataStore(builder: { try await gate.build($0) })
    let reader = ReaderTextView(derivedDataStore: store)
    let a = ReaderDocument(bytes: Array("alpha alpha beta".utf8))
    let b = ReaderDocument(bytes: Array("other other".utf8))
    reader.display(document: a)
    _ = reader.activate(atByteOffset: 0)
    let oldA = Task { await reader.waitForIdentifierPreparation() }
    await gate.waitUntilStarted(1)
    reader.display(document: b)
    let oldB = Task { await reader.waitForIdentifierPreparation() }
    await gate.waitUntilStarted(2)
    reader.display(document: a)
    _ = reader.activate(atByteOffset: 12)
    await gate.waitUntilStarted(3)
    await gate.finish(3)
    await reader.waitForIdentifierPreparation()
    #expect(reader.view.selectedRange() == NSRange(location: 12, length: 4))
    await gate.finish(1)
    await gate.finish(2)
    await oldA.value
    await oldB.value
    #expect(reader.occurrenceCount == 1)
    #expect(reader.view.selectedRange() == NSRange(location: 12, length: 4))
    #expect(reader.displayedBytes == a.bytes)
    reader.clear()
}

@MainActor
@Test
func readonlyIdentifierCompletedCacheDoesNotRetainReaderOrDocument() async {
    let store = ReaderDerivedDataStore()
    weak var releasedReader: ReaderTextView?
    weak var releasedDocument: ReaderDocument?
    do {
        let document = ReaderDocument(bytes: Array("alpha alpha".utf8))
        let reader = ReaderTextView(derivedDataStore: store)
        releasedReader = reader
        releasedDocument = document
        reader.display(document: document)
        await reader.waitForIdentifierPreparation()
        reader.clear()
    }
    #expect(releasedReader == nil)
    #expect(releasedDocument == nil)
    for _ in 0..<100 {
        if await store.statistics.subscriptionCount == 0 { break }
        await Task.yield()
    }
    #expect(await store.statistics.subscriptionCount == 0)
    #expect(await store.statistics.entryCount == 1)
    #expect(await store.statistics.retainedDerivedBytes > 0)
}

@MainActor
@Test
func readonlyIdentifierBuilderStartsBeforeMainActorYields() async {
    let started = DispatchSemaphore(value: 0)
    let store = ReaderDerivedDataStore(builder: { document in
        func isBackgroundThread() -> Bool { !Thread.isMainThread }
        #expect(isBackgroundThread())
        started.signal()
        return try IdentifierIndex(document: document)
    })
    let reader = ReaderTextView(derivedDataStore: store)
    reader.display(document: ReaderDocument(bytes: Array("alpha alpha".utf8)))
    // Deliberately do not yield MainActor: the old inherited Task cannot reach
    // subscribe until this wait times out. The builder's signal is the evidence.
    func waitForBackgroundStart() -> DispatchTimeoutResult { started.wait(timeout: .now() + 2) }
    #expect(waitForBackgroundStart() == .success)
    #expect(reader.identifierPreparationState == .building)
    await reader.waitForIdentifierPreparation()
    #expect(reader.identifierPreparationState == .ready)
    reader.clear()
}

@Test
func readonlyIdentifierCancelledSubscribeNeverStartsAWorker() async {
    let store = ReaderDerivedDataStore(builder: { document in
        Issue.record("A task cancelled before subscribe started a builder")
        return try IdentifierIndex(document: document)
    })
    let document = ReaderDocument(bytes: Array("alpha".utf8))
    await Task.detached {
        withUnsafeCurrentTask { $0?.cancel() }
        let subscription = await store.subscribe(key: document.analysisKey, document: document)
        do { _ = try await store.value(for: subscription); Issue.record("Cancelled token returned data") }
        catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
        await store.cancel(subscription)
    }.value
    #expect(await store.statistics.buildCount == 0)
    #expect(await store.statistics.subscriptionCount == 0)
}

@MainActor
@Test
func readonlyIdentifierDroppedReaderCancelsUnpublishedSubscription() async {
    let gate = ReadonlyBuildGate()
    let store = ReaderDerivedDataStore(builder: { try await gate.build($0) })
    var reader: ReaderTextView? = ReaderTextView(derivedDataStore: store)
    weak var released = reader
    reader?.display(document: ReaderDocument(bytes: Array("alpha alpha".utf8)))
    await gate.waitUntilStarted(1)
    reader = nil
    #expect(released == nil)
    await gate.waitForCancellation()
    #expect(await store.statistics.subscriptionCount == 0)
    #expect(await store.statistics.entryCount == 0)
}
