import Foundation

/// Opt-in workload observations, counted at the work site, never used to gate work.
/// A snapshot is process-wide: runners must isolate measured scenarios.
package enum ReaderWorkCounters {
    package struct Snapshot: Codable, Equatable, Sendable {
        package var identifierDecodedBytes = 0
        package var identifierScannedBytes = 0
        package var identifierBuildCount = 0
        package var projectionPlanBuildCount = 0
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

    private static let lock = NSLock()
    nonisolated(unsafe) private static var enabled = false
    nonisolated(unsafe) private static var value = Snapshot()

    package static func setEnabled(_ enabled: Bool) {
        lock.withLock { self.enabled = enabled }
    }

    package static func reset() { lock.withLock { value = Snapshot() } }
    package static func snapshot() -> Snapshot { lock.withLock { value } }

    package static func record(_ key: WritableKeyPath<Snapshot, Int>, _ amount: Int = 1) {
        lock.withLock {
            guard enabled else { return }
            value[keyPath: key] += amount
        }
    }
}
