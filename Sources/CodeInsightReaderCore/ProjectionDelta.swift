import CodeInsightCore
import Foundation

/// Monotone source windows changed by folding. Apply patches in reverse old-display order.
package struct ProjectionDelta: Sendable {
    package struct Patch: Equatable, Sendable {
        package let oldDisplayRange: NSRange
        package let newDisplayRange: NSRange
        package let sourceRange: ByteRange
    }

    package let patches: [Patch]
    package let oldIdentity: UUID
    package let newIdentity: UUID
    private let contentID: ContentID
    private let oldLength: Int
    private let newLength: Int

    package init?(old: ReaderProjection, new: ReaderProjection) {
        guard old.contentID == new.contentID, old.sourceByteCount == new.sourceByteCount else { return nil }
        var oldFolds: [FoldID: ByteRange] = [:]
        var newFolds: [FoldID: ByteRange] = [:]
        for segment in old.segments {
            if case .folded(let id, let range) = segment { oldFolds[id] = range }
        }
        for segment in new.segments {
            if case .folded(let id, let range) = segment { newFolds[id] = range }
        }
        let changed = oldFolds.compactMap { id, range in newFolds[id] == range ? nil : range }
            + newFolds.compactMap { id, range in oldFolds[id] == range ? nil : range }
        let sorted = changed.sorted {
            ($0.lowerBound, $0.upperBound) < ($1.lowerBound, $1.upperBound)
        }
        var windows: [ByteRange] = []
        for range in sorted {
            if let last = windows.last, range.lowerBound <= last.upperBound {
                windows[windows.count - 1] = ByteRange(lowerBound: last.lowerBound, upperBound: max(last.upperBound, range.upperBound))
            } else { windows.append(range) }
        }
        func boundary(_ byte: UInt32, projection: ReaderProjection, folds: [FoldID: ByteRange]) -> Int? {
            switch projection.displayPosition(ofByte: byte) {
            case .visible(let offset): return offset
            case .hidden(let id):
                // A window edge may meet a placeholder start, but may never bisect hidden source.
                guard folds[id]?.lowerBound == byte else { return nil }
                return projection.placeholderOffset(for: id)
            case nil: return nil
            }
        }
        var patches: [Patch] = []
        var expectedLength = old.projectedUTF16Length
        for window in windows {
            guard let oldLower = boundary(window.lowerBound, projection: old, folds: oldFolds),
                  let oldUpper = boundary(window.upperBound, projection: old, folds: oldFolds),
                  let newLower = boundary(window.lowerBound, projection: new, folds: newFolds),
                  let newUpper = boundary(window.upperBound, projection: new, folds: newFolds),
                  oldLower <= oldUpper, newLower <= newUpper else { return nil }
            let patch = Patch(oldDisplayRange: NSRange(location: oldLower, length: oldUpper - oldLower),
                              newDisplayRange: NSRange(location: newLower, length: newUpper - newLower),
                              sourceRange: window)
            let (nextLength, overflow) = expectedLength.addingReportingOverflow(patch.newDisplayRange.length - patch.oldDisplayRange.length)
            guard !overflow, nextLength >= 0 else { return nil }
            expectedLength = nextLength
            patches.append(patch)
        }
        guard expectedLength == new.projectedUTF16Length else { return nil }
        self.patches = patches
        oldIdentity = old.identity
        newIdentity = new.identity
        contentID = old.contentID
        oldLength = old.projectedUTF16Length
        newLength = new.projectedUTF16Length
    }

    /// Call before any storage mutation. A separately rebuilt plan is not the captured old plan.
    package func isApplicable(current: ReaderProjection, target: ReaderProjection, storageUTF16Length: Int) -> Bool {
        current.identity == oldIdentity && target.identity == newIdentity
            && current.contentID == contentID && target.contentID == contentID
            && current.projectedUTF16Length == oldLength && target.projectedUTF16Length == newLength
            && storageUTF16Length == oldLength
    }
}
