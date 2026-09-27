import CodeInsightCore
import Foundation

/// Validated source geometry only; constructing a plan never decodes source text.
package struct ReaderProjection: Sendable {
    package enum Segment: Equatable, Sendable {
        case source(range: ByteRange, utf16Length: Int)
        case folded(id: FoldID, hidden: ByteRange)
    }

    package enum DisplayPosition: Equatable, Sendable {
        case visible(Int)
        case hidden(FoldID)
    }

    package enum SourcePosition: Equatable, Sendable {
        case source(UInt32)
        case placeholder(FoldID)
    }

    private struct FoldEntry: Sendable {
        let id: FoldID
        let bodyRange: ByteRange
        let placeholderOffset: Int
    }

    package let contentID: ContentID
    package let segments: [Segment]
    package let displayUTF16Starts: [Int]
    package let projectedUTF16Length: Int
    private let sourceMap: ByteUTF16Map
    private let folds: [FoldEntry]
    private let removedUTF16Prefix: [Int]
    private let placeholderOffsetsByID: [FoldID: Int]

    package var renderedFoldIDs: Set<FoldID> { Set(folds.map(\.id)) }
    package var foldPlaceholders: [(id: FoldID, offset: Int)] {
        folds.map { ($0.id, $0.placeholderOffset) }
    }
    package func placeholderOffset(for id: FoldID) -> Int? { placeholderOffsetsByID[id] }

    package init?(document: ReaderDocument, renderedFoldIDs: Set<FoldID>) {
        ReaderWorkCounters.record(\.projectionPlanBuildCount)
        guard let byteCount = UInt32(exactly: document.bytes.count) else { return nil }
        contentID = document.contentID
        sourceMap = document.byteUTF16Map
        let selected = document.foldRegions.filter { renderedFoldIDs.contains($0.id) }.sorted {
            $0.bodyRange.lowerBound < $1.bodyRange.lowerBound
                || ($0.bodyRange.lowerBound == $1.bodyRange.lowerBound
                    && $0.bodyRange.upperBound < $1.bodyRange.upperBound)
        }
        guard selected.count == renderedFoldIDs.count,
              Set(selected.map(\.id)) == renderedFoldIDs else { return nil }
        var entries: [FoldEntry] = []
        var prefix = [0]
        var segments: [Segment] = []
        var starts: [Int] = []
        var offsets: [FoldID: Int] = [:]
        var sourceCursor: UInt32 = 0
        var displayCursor = 0
        for region in selected {
            let body = region.bodyRange
            guard sourceCursor <= body.lowerBound,
                  body.lowerBound < body.upperBound, body.upperBound <= byteCount,
                  let visible = sourceMap.nsRange(byteLowerBound: Int(sourceCursor), byteUpperBound: Int(body.lowerBound)),
                  let hidden = sourceMap.nsRange(byteLowerBound: Int(body.lowerBound), byteUpperBound: Int(body.upperBound))
            else { return nil }
            let (placeholder, sourceOverflow) = displayCursor.addingReportingOverflow(visible.length)
            let (nextDisplay, placeholderOverflow) = placeholder.addingReportingOverflow(1)
            let (removed, prefixOverflow) = prefix[prefix.count - 1].addingReportingOverflow(hidden.length - 1)
            guard !sourceOverflow, !placeholderOverflow, !prefixOverflow else { return nil }
            if sourceCursor < body.lowerBound {
                starts.append(displayCursor)
                segments.append(.source(range: ByteRange(lowerBound: sourceCursor, upperBound: body.lowerBound),
                                        utf16Length: visible.length))
            }
            starts.append(placeholder)
            segments.append(.folded(id: region.id, hidden: body))
            entries.append(FoldEntry(id: region.id, bodyRange: body, placeholderOffset: placeholder))
            guard offsets.updateValue(placeholder, forKey: region.id) == nil else { return nil }
            prefix.append(removed)
            displayCursor = nextDisplay
            sourceCursor = body.upperBound
        }
        guard let tail = sourceMap.nsRange(byteLowerBound: Int(sourceCursor), byteUpperBound: Int(byteCount)) else { return nil }
        let (length, overflow) = displayCursor.addingReportingOverflow(tail.length)
        guard !overflow else { return nil }
        if sourceCursor < byteCount || segments.isEmpty {
            starts.append(displayCursor)
            segments.append(.source(range: ByteRange(lowerBound: sourceCursor, upperBound: byteCount), utf16Length: tail.length))
        }
        self.segments = segments
        displayUTF16Starts = starts
        folds = entries
        removedUTF16Prefix = prefix
        placeholderOffsetsByID = offsets
        projectedUTF16Length = length
    }

    /// Explicit compatibility materialization; callers doing geometry must not request this.
    package func materialize() -> String {
        var result = ""
        for segment in segments {
            switch segment {
            case .source(let range, _):
                ReaderWorkCounters.record(\.materializedUTF8Bytes, Int(range.upperBound - range.lowerBound))
                result += String(decoding: sourceMap.bytes[Int(range.lowerBound)..<Int(range.upperBound)], as: UTF8.self)
            case .folded:
                result.append("\u{FFFC}")
            }
        }
        return result
    }

    package func displayPosition(ofByte byteOffset: UInt32) -> DisplayPosition? {
        guard let sourceUTF16 = sourceMap.utf16Offset(forByte: Int(byteOffset)) else {
            return nil
        }
        if let fold = fold(containingByte: byteOffset) {
            return .hidden(fold.id)
        }
        let preceding = foldCount(endingAtOrBeforeByte: byteOffset)
        return .visible(sourceUTF16 - removedUTF16Prefix[preceding])
    }

    package func project(
        byteRange: ByteRange
    ) -> (visible: [NSRange], folds: [FoldID])? {
        guard sourceMap.utf16Offset(forByte: Int(byteRange.lowerBound)) != nil,
              sourceMap.utf16Offset(forByte: Int(byteRange.upperBound)) != nil
        else { return nil }
        guard byteRange.lowerBound < byteRange.upperBound else {
            return ([], [])
        }

        var visible: [NSRange] = []
        var hidden: [FoldID] = []
        var cursor = byteRange.lowerBound
        var index = firstFold(endingAfterByte: byteRange.lowerBound)
        while index < folds.count,
              folds[index].bodyRange.lowerBound < byteRange.upperBound
        {
            let fold = folds[index]
            if cursor < fold.bodyRange.lowerBound {
                guard let range = visibleRange(
                    lower: cursor,
                    upper: min(fold.bodyRange.lowerBound, byteRange.upperBound)
                ) else { return nil }
                if range.length > 0 { visible.append(range) }
            }
            if fold.bodyRange.overlaps(byteRange) {
                hidden.append(fold.id)
                cursor = max(cursor, fold.bodyRange.upperBound)
            }
            index += 1
        }
        if cursor < byteRange.upperBound {
            guard let range = visibleRange(lower: cursor, upper: byteRange.upperBound)
            else { return nil }
            if range.length > 0 { visible.append(range) }
        }
        return (visible, hidden)
    }

    package func sourcePosition(ofDisplay displayOffset: Int) -> SourcePosition? {
        guard displayOffset >= 0, displayOffset <= projectedUTF16Length else {
            return nil
        }
        if let fold = fold(atPlaceholder: displayOffset) {
            return .placeholder(fold.id)
        }
        return sourceByte(forVisibleDisplay: displayOffset).map(SourcePosition.source)
    }

    package func sourceRanges(forDisplay range: NSRange) -> [ByteRange]? {
        sourceRanges(forDisplay: range, includeHidden: true)
    }

    package func visibleSourceRanges(forDisplay range: NSRange) -> [ByteRange]? {
        sourceRanges(forDisplay: range, includeHidden: false)
    }

    private func sourceRanges(
        forDisplay range: NSRange,
        includeHidden: Bool
    ) -> [ByteRange]? {
        guard range.location >= 0,
              range.length >= 0,
              range.location <= Int.max - range.length
        else { return nil }
        let upper = range.location + range.length
        guard upper <= projectedUTF16Length,
              displayBoundaryIsValid(range.location),
              displayBoundaryIsValid(upper)
        else { return nil }
        guard range.length > 0 else { return [] }

        var result: [ByteRange] = []
        var cursor = range.location
        var index = firstFold(placeholderEndingAfter: range.location)
        while index < folds.count, folds[index].placeholderOffset < upper {
            let fold = folds[index]
            if cursor < fold.placeholderOffset {
                guard let source = visibleSourceRange(
                    displayLower: cursor,
                    displayUpper: min(fold.placeholderOffset, upper)
                ) else { return nil }
                append(source, to: &result)
            }
            let placeholderUpper = fold.placeholderOffset + 1
            if includeHidden,
               range.location < placeholderUpper,
               fold.placeholderOffset < upper
            {
                append(fold.bodyRange, to: &result)
            }
            cursor = max(cursor, placeholderUpper)
            index += 1
        }
        if cursor < upper {
            guard let source = visibleSourceRange(
                displayLower: cursor,
                displayUpper: upper
            ) else { return nil }
            append(source, to: &result)
        }
        return result
    }

    private func visibleRange(lower: UInt32, upper: UInt32) -> NSRange? {
        guard let sourceLower = sourceMap.utf16Offset(forByte: Int(lower)),
              let sourceUpper = sourceMap.utf16Offset(forByte: Int(upper))
        else { return nil }
        let precedingLower = foldCount(endingAtOrBeforeByte: lower)
        let precedingUpper = foldCount(endingAtOrBeforeByte: upper)
        let displayLower = sourceLower - removedUTF16Prefix[precedingLower]
        let displayUpper = sourceUpper - removedUTF16Prefix[precedingUpper]
        guard displayLower <= displayUpper else { return nil }
        return NSRange(location: displayLower, length: displayUpper - displayLower)
    }

    private func visibleSourceRange(
        displayLower: Int,
        displayUpper: Int
    ) -> ByteRange? {
        guard let lower = sourceByte(forVisibleDisplay: displayLower),
              let upper = sourceByte(forVisibleDisplay: displayUpper),
              lower <= upper
        else { return nil }
        return ByteRange(lowerBound: lower, upperBound: upper)
    }

    private func sourceByte(forVisibleDisplay displayOffset: Int) -> UInt32? {
        let preceding = foldCount(placeholderEndingAtOrBefore: displayOffset)
        let sourceUTF16 = displayOffset + removedUTF16Prefix[preceding]
        return sourceMap.byteOffset(forUTF16: sourceUTF16)
            .flatMap(UInt32.init(exactly:))
    }

    private func displayBoundaryIsValid(_ offset: Int) -> Bool {
        if fold(atPlaceholder: offset) != nil { return true }
        return sourceByte(forVisibleDisplay: offset) != nil
    }

    private func fold(containingByte byteOffset: UInt32) -> FoldEntry? {
        var low = 0
        var high = folds.count
        while low < high {
            let middle = low + (high - low) / 2
            if folds[middle].bodyRange.lowerBound <= byteOffset {
                low = middle + 1
            } else {
                high = middle
            }
        }
        guard low > 0, folds[low - 1].bodyRange.contains(byteOffset) else {
            return nil
        }
        return folds[low - 1]
    }

    private func fold(atPlaceholder displayOffset: Int) -> FoldEntry? {
        var low = 0
        var high = folds.count
        while low < high {
            let middle = low + (high - low) / 2
            if folds[middle].placeholderOffset < displayOffset {
                low = middle + 1
            } else {
                high = middle
            }
        }
        guard low < folds.count,
              folds[low].placeholderOffset == displayOffset
        else { return nil }
        return folds[low]
    }

    private func foldCount(endingAtOrBeforeByte byteOffset: UInt32) -> Int {
        var low = 0
        var high = folds.count
        while low < high {
            let middle = low + (high - low) / 2
            if folds[middle].bodyRange.upperBound <= byteOffset {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    private func firstFold(endingAfterByte byteOffset: UInt32) -> Int {
        foldCount(endingAtOrBeforeByte: byteOffset)
    }

    private func foldCount(placeholderEndingAtOrBefore displayOffset: Int) -> Int {
        var low = 0
        var high = folds.count
        while low < high {
            let middle = low + (high - low) / 2
            if folds[middle].placeholderOffset + 1 <= displayOffset {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    private func firstFold(placeholderEndingAfter displayOffset: Int) -> Int {
        foldCount(placeholderEndingAtOrBefore: displayOffset)
    }

    private func append(_ range: ByteRange, to result: inout [ByteRange]) {
        guard range.lowerBound < range.upperBound else { return }
        if let last = result.last, last.upperBound == range.lowerBound {
            result[result.count - 1] = ByteRange(
                lowerBound: last.lowerBound,
                upperBound: range.upperBound
            )
        } else {
            result.append(range)
        }
    }
}
