import CodeInsightCore
import Foundation
import os

/// Source bytes by content identity, within a byte budget; the least
/// recently used entries leave first. A miss is filled by the caller's
/// reader, and the bytes must hash to the content ID they are asked for:
/// a reader that fails or returns other bytes is an error, never content.
/// A remote link that is lost passes through as `SSHTransport.Failure`.
public final class SourceByteCache: @unchecked Sendable {
    public struct Unavailable: Error, LocalizedError {
        public let contentID: ContentID
        public let reason: String

        public var errorDescription: String? {
            "source \(contentID) is unavailable: \(reason)"
        }
    }

    public let budget: Int

    // Parallel search workers take this once per file.
    private let lock = OSAllocatedUnfairLock()
    private var entries: [ContentID: (bytes: [UInt8], lastUse: UInt64)] = [:]
    private var clock: UInt64 = 0
    private var used = 0

    /// `budgetBytes` nil takes `defaultBudget`.
    public init(budgetBytes: Int? = nil) {
        budget = max(0, budgetBytes ?? Self.defaultBudget)
    }

    /// Physical memory / 8, between 64 MiB and 4 GiB. The defaults key
    /// `Cairn.sourceByteCacheBudgetMiB`, or the environment variable
    /// `CAIRN_SOURCE_BYTE_CACHE_MIB` (for the CLI), overrides it.
    public static var defaultBudget: Int {
        let mib = 1 << 20
        if let value = ProcessInfo.processInfo.environment["CAIRN_SOURCE_BYTE_CACHE_MIB"].flatMap(Int.init),
           value >= 0
        {
            return value * mib
        }
        let configured = UserDefaults.standard.integer(forKey: "Cairn.sourceByteCacheBudgetMiB")
        if configured > 0 { return configured * mib }
        let physical = Int(clamping: ProcessInfo.processInfo.physicalMemory)
        return min(max(physical / 8, 64 * mib), 4096 * mib)
    }

    public var usedBytes: Int { lock.withLock { used } }

    public var contentIDs: Set<ContentID> { lock.withLock { Set(entries.keys) } }

    func byteCount(of contentIDs: Set<ContentID>) -> Int {
        lock.withLock { contentIDs.reduce(0) { $0 + (entries[$1]?.bytes.count ?? 0) } }
    }

    func cachedBytes(_ contentIDs: [ContentID]) -> [[UInt8]?] {
        lock.withLock {
            contentIDs.map { id in
                guard let index = entries.index(forKey: id) else { return nil }
                clock += 1
                entries.values[index].lastUse = clock
                return entries.values[index].bytes
            }
        }
    }

    func cachedBytes(_ contentID: ContentID) -> [UInt8]? {
        lock.withLock {
            guard let entry = entries[contentID] else { return nil }
            clock += 1
            entries[contentID]?.lastUse = clock
            return entry.bytes
        }
    }

    /// The cached bytes, else `read()`'s bytes once they hash to
    /// `contentID` (`verifying` false: the reader already guarantees it).
    /// The lock is not held while reading or hashing.
    func bytes(
        for contentID: ContentID,
        verifying: Bool = true,
        read: () throws -> [UInt8]
    ) throws -> [UInt8] {
        if let bytes = cachedBytes(contentID) { return bytes }
        let bytes: [UInt8]
        do {
            bytes = try read()
        } catch let failure as SSHTransport.Failure where failure.isConnectionLoss {
            // A lost link is not a missing source: callers that would record
            // the file as unavailable must fail (and say so) instead.
            throw failure
        } catch {
            throw Unavailable(contentID: contentID, reason: error.localizedDescription)
        }
        guard !verifying || ContentID.sha256(of: bytes) == contentID else {
            throw Unavailable(contentID: contentID, reason: "the bytes read back have another identity")
        }
        insert(bytes, for: contentID)
        return bytes
    }

    /// The caller vouches that `bytes` hash to `contentID`. An entry larger
    /// than the whole budget is not kept.
    func insert(_ bytes: [UInt8], for contentID: ContentID) {
        guard bytes.count <= budget else { return }
        lock.withLock {
            clock += 1
            if entries[contentID] != nil {
                entries[contentID]?.lastUse = clock
                return
            }
            entries[contentID] = (bytes, clock)
            used += bytes.count
            guard used > budget else { return }
            // ponytail: one sort per overflow, trimming to 7/8 of the budget
            // so the sort is amortized; a linked LRU list if this shows up.
            let target = budget - budget / 8
            for (id, entry) in entries.sorted(by: { $0.value.lastUse < $1.value.lastUse }) {
                if used <= target { break }
                if id == contentID { continue }
                entries[id] = nil
                used -= entry.bytes.count
            }
        }
    }
}
