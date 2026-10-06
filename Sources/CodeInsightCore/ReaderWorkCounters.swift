import Foundation

/// Opt-in workload observations, counted at the work site, never used to gate work.
/// Outside an isolated scope a snapshot is process-wide: runners must isolate
/// measured scenarios. Inside `withIsolatedScope` only work done by that task,
/// the synchronous code it calls and the tasks that inherit its task-local
/// values is counted, so concurrently running tests cannot change its deltas.
package enum ReaderWorkCounters {
    package struct Snapshot: Codable, Equatable, Sendable {
        package var identifierDecodedBytes = 0
        package var identifierScannedBytes = 0
        package var identifierBuildCount = 0
        package var projectionPlanBuildCount = 0
        package var projectionPlaceholderRecordsVisited = 0
        package var materializedUTF8Bytes = 0
        package var fullTextReplacementCount = 0
        package var partialTextReplacementCount = 0
        package var replacedUTF16Units = 0
        package var attributeUpdatedUTF16Units = 0
        package var renderingAttributeUpdatedUTF16Units = 0
        package var paragraphRecordsVisited = 0
        package var decorationBuildCount = 0
        package var drawGlobalRecordVisits = 0
        package var regionQueryRecordVisits = 0
        package var topologyBuildCount = 0
        package var ownershipBuildCount = 0
        package var applicationFullLayoutCount = 0
    }

    private final class Scope: @unchecked Sendable {
        let lock = NSLock()
        var value = Snapshot()
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var enabled = false
    nonisolated(unsafe) private static var value = Snapshot()
    @TaskLocal private static var scope: Scope?

    package static func setEnabled(_ enabled: Bool) {
        lock.withLock { self.enabled = enabled }
    }

    /// Counts the work `body` does in a fresh scope; `snapshot()` and `reset()`
    /// inside it see only that scope. Counting is always on within the scope.
    package static func withIsolatedScope<R>(_ body: () throws -> R) rethrows -> R {
        try $scope.withValue(Scope(), operation: body)
    }

    package static func withIsolatedScope<R>(
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> R
    ) async rethrows -> R {
        try await $scope.withValue(Scope(), operation: body)
    }

    package static func reset() {
        if let scope {
            scope.lock.withLock { scope.value = Snapshot() }
        } else {
            lock.withLock { value = Snapshot() }
        }
    }

    package static func snapshot() -> Snapshot {
        if let scope { return scope.lock.withLock { scope.value } }
        return lock.withLock { value }
    }

    package static func record(_ key: WritableKeyPath<Snapshot, Int>, _ amount: Int = 1) {
        if let scope {
            scope.lock.withLock { scope.value[keyPath: key] += amount }
            return
        }
        lock.withLock {
            guard enabled else { return }
            value[keyPath: key] += amount
        }
    }
}
