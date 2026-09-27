import Foundation

/// Application-owned, bounded cache. Views own subscriptions, never the shared worker.
package actor ReaderDerivedDataStore {
    package typealias Builder = @Sendable (ReaderDocument) async throws -> IdentifierIndex

    package struct Subscription: Hashable, Sendable {
        fileprivate let id: UUID
        fileprivate let key: ReaderAnalysisKey
    }

    package struct Statistics: Sendable {
        package let buildCount: Int
        package let entryCount: Int
        package let inFlightCount: Int
        package let subscriptionCount: Int
        package let retainedDerivedBytes: Int
        package let activeDerivedBytes: Int
        package let activeOverBudgetBytes: Int
    }

    private struct Entry {
        let generation: UUID
        var task: Task<IdentifierIndex, Error>?
        var index: IdentifierIndex?
        var failure: (any Error)?
        var byteCount = 256
        var subscribers: Set<UUID>
        var lastUse: UInt64
    }

    private let reuseCachedData: Bool
    private let byteBudget: Int
    private let builder: Builder
    private var entries: [ReaderAnalysisKey: Entry] = [:]
    private var clock: UInt64 = 0
    private var buildCount = 0

    package init(
        byteBudget: Int = 32 * 1024 * 1024,
        reuseCachedData: Bool = ProcessInfo.processInfo.environment["CAIRN_READONLY_IDENTIFIER_CACHE"] != "0",
        builder: @escaping Builder = { try IdentifierIndex(document: $0) }
    ) {
        self.reuseCachedData = reuseCachedData
        self.byteBudget = max(0, byteBudget)
        self.builder = builder
    }

    deinit {
        for entry in entries.values { entry.task?.cancel() }
    }

    /// Register before any await, including cache hits, so cancellation belongs to one view.
    package func subscribe(key: ReaderAnalysisKey, document: ReaderDocument) -> Subscription {
        // Internal rollback disables reuse, but keeps all construction off the UI thread.
        let key = reuseCachedData ? key : ReaderAnalysisKey(
            contentID: key.contentID, languageMode: key.languageMode, readerVersion: key.readerVersion
        )
        let token = Subscription(id: UUID(), key: key)
        clock &+= 1
        if var entry = entries[key] {
            entry.subscribers.insert(token.id)
            entry.lastUse = clock
            entries[key] = entry
        } else {
            let builder = self.builder
            let generation = UUID()
            let task = Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    try Task.checkCancellation()
                    let index = try await builder(document)
                    await self?.complete(key: key, generation: generation, result: .success(index))
                    return index
                } catch {
                    await self?.complete(key: key, generation: generation, result: .failure(error))
                    throw error
                }
            }
            entries[key] = Entry(
                generation: generation, task: task, byteCount: max(256, document.bytes.count),
                subscribers: [token.id], lastUse: clock
            )
            buildCount += 1
        }
        return token
    }

    package func value(for token: Subscription) async throws -> IdentifierIndex {
        try Task.checkCancellation()
        guard let original = entries[token.key], original.subscribers.contains(token.id) else {
            throw CancellationError()
        }
        if let index = original.index { return index }
        if let failure = original.failure { throw failure }
        guard let task = original.task else { throw CancellationError() }
        let index = try await task.value
        try Task.checkCancellation()
        guard let current = entries[token.key],
              current.generation == original.generation,
              current.subscribers.contains(token.id)
        else { throw CancellationError() }
        return index
    }

    private func complete(
        key: ReaderAnalysisKey, generation: UUID, result: Result<IdentifierIndex, Error>
    ) {
        guard var entry = entries[key], entry.generation == generation else { return }
        entry.task = nil
        switch result {
        case .success(let index):
            entry.index = index
            entry.byteCount = max(256, index.estimatedByteCount)
        case .failure(let error):
            entry.failure = error
        }
        entries[key] = entry
        evictIdleEntries()
    }

    package func cancel(_ token: Subscription) {
        guard var entry = entries[token.key], entry.subscribers.remove(token.id) != nil else { return }
        if entry.subscribers.isEmpty && (entry.index == nil || !reuseCachedData) {
            entry.task?.cancel()
            entries.removeValue(forKey: token.key)
        } else {
            entries[token.key] = entry
            evictIdleEntries()
        }
    }

    package var statistics: Statistics {
        let retained = entries.values.reduce(0) { $0 + $1.byteCount }
        let active = entries.values.filter { !$0.subscribers.isEmpty }.reduce(0) { $0 + $1.byteCount }
        return Statistics(
            buildCount: buildCount, entryCount: entries.count,
            inFlightCount: entries.values.filter { $0.task != nil }.count,
            subscriptionCount: entries.values.reduce(0) { $0 + $1.subscribers.count },
            retainedDerivedBytes: retained, activeDerivedBytes: active,
            activeOverBudgetBytes: max(0, active - byteBudget)
        )
    }

    private func evictIdleEntries() {
        var retained = entries.values.reduce(0) { $0 + $1.byteCount }
        // ponytail: eviction sorts the small bounded cache; use an LRU list if cache churn becomes hot.
        let idle = entries.filter { $0.value.subscribers.isEmpty }.sorted {
            $0.value.lastUse < $1.value.lastUse
        }
        // Active subscriptions may exceed either soft limit; idle results never do.
        for (key, entry) in idle where retained > byteBudget || entries.count > 128 {
            retained -= entry.byteCount
            entries.removeValue(forKey: key)
        }
    }
}
