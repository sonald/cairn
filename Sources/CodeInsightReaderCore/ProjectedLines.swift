import CodeInsightCore

/// Display-line arithmetic for a projection without scanning its text: each
/// rendered fold collapses the line breaks it hides into the line that shows
/// its placeholder. Lines are 0-based and follow `LineTable` (LF breaks).
package struct ProjectedLines: Sendable {
    private let lineStarts: [UInt32]
    private let foldLowers: [UInt32]
    private let foldUppers: [UInt32]
    /// Line breaks hidden by folds `0...i`.
    private let hiddenThrough: [Int]
    package let count: Int

    package init(projection: ReaderProjection, lineStarts: [UInt32]) {
        self.lineStarts = lineStarts
        var lowers: [UInt32] = [], uppers: [UInt32] = [], hidden: [Int] = []
        var total = 0
        for case .folded(_, let range) in projection.segments {
            total += Self.line(of: range.upperBound, in: lineStarts) - Self.line(of: range.lowerBound, in: lineStarts)
            lowers.append(range.lowerBound)
            uppers.append(range.upperBound)
            hidden.append(total)
        }
        foldLowers = lowers
        foldUppers = uppers
        hiddenThrough = hidden
        count = max(1, lineStarts.count - total)
    }

    /// The display line showing `byte`; `folded` when a fold hides it and
    /// the line is the one holding that fold's placeholder.
    package func displayLine(ofByte byte: UInt32) -> (line: Int, folded: Bool) {
        let folds = Self.countNotAbove(byte, in: foldLowers)
        if folds > 0, byte < foldUppers[folds - 1] {
            let before = folds > 1 ? hiddenThrough[folds - 2] : 0
            return (Self.line(of: foldLowers[folds - 1], in: lineStarts) - before, true)
        }
        let before = folds > 0 ? hiddenThrough[folds - 1] : 0
        return (Self.line(of: byte, in: lineStarts) - before, false)
    }

    /// The start of the first source line shown on `displayLine`.
    package func sourceByte(ofDisplayLine displayLine: Int) -> UInt32 {
        guard !lineStarts.isEmpty else { return 0 }
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let middle = (low + high) / 2
            if self.displayLine(ofByte: lineStarts[middle]).line < displayLine { low = middle + 1 } else { high = middle }
        }
        return lineStarts[low]
    }

    private static func line(of byte: UInt32, in starts: [UInt32]) -> Int {
        max(0, countNotAbove(byte, in: starts) - 1)
    }

    private static func countNotAbove(_ value: UInt32, in sorted: [UInt32]) -> Int {
        var low = 0, high = sorted.count
        while low < high {
            let middle = (low + high) / 2
            if sorted[middle] <= value { low = middle + 1 } else { high = middle }
        }
        return low
    }
}
