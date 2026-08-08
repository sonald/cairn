import CodeInsightCore
import CodeInsightReaderCore
import Foundation

internal enum DisplayPosition: Equatable, Sendable {
    case visible(Int)
    case hidden(FoldID)
}

internal enum SourcePosition: Equatable, Sendable {
    case source(UInt32)
    case placeholder(FoldID)
}

internal struct DisplayMap: Sendable {
    private struct FoldEntry: Sendable {
        let id: FoldID
        let bodyRange: ByteRange
        let placeholderOffset: Int
    }

    private let sourceMap: ByteUTF16Map
    private let folds: [FoldEntry]
    private let removedUTF16Prefix: [Int]

    internal let projectedString: String
    internal let projectedUTF16Length: Int

    internal init?(
        document: ReaderDocument,
        renderedFoldIDs: Set<FoldID>
    ) {
        sourceMap = document.byteUTF16Map
        let selected = document.foldRegions.filter {
            renderedFoldIDs.contains($0.id)
        }.sorted {
            $0.bodyRange.lowerBound < $1.bodyRange.lowerBound
                || ($0.bodyRange.lowerBound == $1.bodyRange.lowerBound
                    && $0.bodyRange.upperBound < $1.bodyRange.upperBound)
        }
        guard selected.count == renderedFoldIDs.count else { return nil }

        var entries: [FoldEntry] = []
        entries.reserveCapacity(selected.count)
        var prefix = [0]
        prefix.reserveCapacity(selected.count + 1)
        var projected = ""
        projected.reserveCapacity(document.bytes.count)
        var sourceCursor: UInt32 = 0
        var displayCursor = 0

        for region in selected {
            let body = region.bodyRange
            guard sourceCursor <= body.lowerBound,
                  body.lowerBound < body.upperBound,
                  Int(body.upperBound) <= document.bytes.count,
                  let visibleRange = sourceMap.nsRange(
                      byteLowerBound: Int(sourceCursor),
                      byteUpperBound: Int(body.lowerBound)
                  ),
                  let hiddenRange = sourceMap.nsRange(
                      byteLowerBound: Int(body.lowerBound),
                      byteUpperBound: Int(body.upperBound)
                  )
            else { return nil }

            projected += String(
                decoding: document.bytes[Int(sourceCursor)..<Int(body.lowerBound)],
                as: UTF8.self
            )
            projected.append("\u{FFFC}")
            displayCursor += visibleRange.length
            let removed = hiddenRange.length - 1
            entries.append(FoldEntry(
                id: region.id,
                bodyRange: body,
                placeholderOffset: displayCursor
            ))
            prefix.append(prefix.last! + removed)
            displayCursor += 1
            sourceCursor = body.upperBound
        }

        guard let tailRange = sourceMap.nsRange(
            byteLowerBound: Int(sourceCursor),
            byteUpperBound: document.bytes.count
        ) else { return nil }
        projected += String(
            decoding: document.bytes[Int(sourceCursor)..<document.bytes.count],
            as: UTF8.self
        )
        displayCursor += tailRange.length

        folds = entries
        removedUTF16Prefix = prefix
        projectedString = projected
        projectedUTF16Length = displayCursor
        guard (projected as NSString).length == displayCursor else { return nil }
    }

    internal func displayPosition(ofByte byteOffset: UInt32) -> DisplayPosition? {
        guard let sourceUTF16 = sourceMap.utf16Offset(forByte: Int(byteOffset)) else {
            return nil
        }
        if let fold = fold(containingByte: byteOffset) {
            return .hidden(fold.id)
        }
        let preceding = foldCount(endingAtOrBeforeByte: byteOffset)
        return .visible(sourceUTF16 - removedUTF16Prefix[preceding])
    }

    internal func project(
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

    internal func sourcePosition(ofDisplay displayOffset: Int) -> SourcePosition? {
        guard displayOffset >= 0, displayOffset <= projectedUTF16Length else {
            return nil
        }
        if let fold = fold(atPlaceholder: displayOffset) {
            return .placeholder(fold.id)
        }
        return sourceByte(forVisibleDisplay: displayOffset).map(SourcePosition.source)
    }

    internal func sourceRanges(forDisplay range: NSRange) -> [ByteRange]? {
        sourceRanges(forDisplay: range, includeHidden: true)
    }

    internal func visibleSourceRanges(forDisplay range: NSRange) -> [ByteRange]? {
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
