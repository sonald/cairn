/// Source cost derived once from the already-built line table.
/// Projected UTF-16 length remains owned by ReaderProjection/DisplayMap and is
/// recorded beside this value; it must not be frozen into source metadata.
package struct ReaderDocumentCost: Equatable, Sendable {
    package let byteCount: Int
    package let logicalLineCount: Int
    /// Includes the line terminator, matching the current 64 KiB restore check.
    package let maximumLineByteLength: Int
    package let highlightSpanCount: Int
    package let foldRegionCount: Int

    /// Failable solely so malformed external/test line metadata cannot understate cost.
    /// Production supplies LineTable.lineStarts, not a second source byte scan.
    package init?(
        byteCount: Int,
        lineStarts: [UInt32],
        highlightSpanCount: Int,
        foldRegionCount: Int
    ) {
        guard byteCount >= 0, UInt32(exactly: byteCount) != nil,
              highlightSpanCount >= 0, foldRegionCount >= 0,
              lineStarts.first == 0 else { return nil }
        var longest = 0
        for index in lineStarts.indices {
            let start = Int(lineStarts[index])
            let end = index + 1 < lineStarts.count ? Int(lineStarts[index + 1]) : byteCount
            guard start <= byteCount, end >= start,
                  index == lineStarts.count - 1 || end > start else { return nil }
            longest = max(longest, end - start)
        }
        self.byteCount = byteCount
        logicalLineCount = lineStarts.count
        maximumLineByteLength = longest
        self.highlightSpanCount = highlightSpanCount
        self.foldRegionCount = foldRegionCount
    }
}

/// Two existing limits in one injectable place, not a new performance budget.
package struct ReaderReflowPolicy: Equatable, Sendable {
    package let maximumSynchronousLineCount: Int
    package let maximumSynchronousLineBytes: Int

    package init(maximumSynchronousLineCount: Int = 8_000,
                 maximumSynchronousLineBytes: Int = 64 * 1024) {
        precondition(maximumSynchronousLineCount >= 0 && maximumSynchronousLineBytes >= 0)
        self.maximumSynchronousLineCount = maximumSynchronousLineCount
        self.maximumSynchronousLineBytes = maximumSynchronousLineBytes
    }

    /// Must be tested BEFORE looking for a previous viewport. No prior viewport
    /// never grants permission to enumerate full-document ensuresLayout fragments.
    package func requiresViewportOnlyLayout(for cost: ReaderDocumentCost) -> Bool {
        cost.logicalLineCount > maximumSynchronousLineCount
            || cost.maximumLineByteLength > maximumSynchronousLineBytes
    }
}
